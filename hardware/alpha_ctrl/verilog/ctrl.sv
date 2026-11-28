// On-chip controller (alpha_ctrl, stages 2-3): runs a tiled conv / linear layer with
// n_it input-channel tiles (row channels each) and n_ot output-channel tiles (col channels
// each), kernel K in {1, 3}, output H x W. Every pass uses the exact cycle sequence of
// core_tb.v, minus the testbench's in-loop weight writes.
//
// Loop order (same as core_tiled_tb.v): output tile -> input tile -> kij -> pass phases,
// then the SFU for that output tile (n_it*K*K psums per output pixel).
//
// Output timing matches the testbench:
//   * the FSM's Moore outputs play the role of the testbench's per-cycle values,
//   * inst passes through one register (the testbench's "_q" stage),
//   * core_rst is not registered (the testbench's reset is not delayed either).
//     All resets in the design are synchronous, so a decoded reset is safe.
//
// Memory map comes from the config inputs (latched on start):
//   weights  cfg_w_base    + ((ot*n_it + it)*K*K + kij)*col + c
//   pixels   cfg_x_base    + it*npix + p          p = 0 .. npix-1, npix = (H+K-1)*(W+K-1)
//   psums    cfg_psum_base + (it*K*K + kij)*npix + p   (region reused for every output tile)
//   outputs  cfg_out_base  + ot*H*W + o           o = oy*W + ox
// All pointers step by addition; there are no multipliers in the loops.
//
// Cycle-saving options (OPT bit mask, default 0 = the exact core_tb.v sequence, trace-identical
// to the testbench-driven flow). C1-C4 only shorten phases; C5-C6 overlap them.
//   OPT[0] C1: per-pass reset 1 cycle instead of 11 high + 2 idle (all resets are synchronous).
//   OPT[1] C2: no idle gap after load (row r still pops weights r cycles after load ends, but its
//              execute also arrives r cycles late, so per-row order is kept).
//   OPT[2] C3: gap after execute only as long as the array needs: the drain's first pop must come
//              after the last column's first output (row+col cycles after execute starts), so
//              EXEC lasts max(npix+1, row+col+1) instead of npix+row+col+5.
//   OPT[3] C4: SFU per output pixel n_acc+3 cycles instead of n_acc+6 (no idle after the clear,
//              write-back in the cycle after the last acc, next clear right after the write-back).
//   OPT[4] C5: drain the OFIFO while executing: the drain starts row+col+1 cycles after execute
//              starts (the last column's first output exists after row+col), whatever npix is.
//              Pops then follow the writes at the same rate, so no column FIFO is read empty.
//   OPT[5] C6: stream pixels into L0 while executing: execute starts 3 cycles after the L0 write
//              phase starts (the first pixel is in FIFO 0 one cycle before its first pop, and
//              writes and pops then advance at the same rate) instead of after all npix writes.
//
// Pixels -> L0, execute and drain are one phase (S_STREAM) with three windows at offsets
//   L0 writes: cnt 0 .. npix          (prime + npix writes)
//   execute:   cnt E .. E+npix-1      E = npix+2 (C6: 3)
//   drain:     cnt P .. P+npix        P = E + D, D = npix + row+col+5 (C3: max(npix+1, row+col+1);
//                                     C5: row+col+1)
// With no option set these are exactly the three back-to-back phases of core_tb.v.
//
//   OPT[6] C7: next pass's weights overlap the current pass (needs corelet's arr_clr port).
//              While this pass executes, its 8 next weight lines are written into L0 behind the
//              pixels (window W, after this pass's L0 writes and once L0 has room); as soon as
//              the array has produced its last output, arr_clr re-arms only the PEs (L0 and the
//              OFIFO keep their contents) and the next weights are loaded (window A) while the
//              OFIFO is still draining. The next pass then starts directly with its S_STREAM:
//              no S_RST / S_WL0 / S_LOAD for it. Not done across output tiles (the SFU phase in
//              between uses the global reset), so each output tile's first pass is as before.
//   C7 windows in S_STREAM (only when another pass of this output tile follows):
//     next weights -> L0: cnt W .. W+col   W = max(npix+1, E+row+10)
//     arr_clr:            cnt A            A = E+npix+row+col+1  (array finished)
//     load:               cnt A+1 .. A+col, then the usual gap after load (none with C2)
module ctrl #(
  parameter col = 8,
  parameter row = 8,
  parameter OPT = 0
) (
  input  logic        clk,
  input  logic        reset,

  input  logic        start,       // pulse while idle
  input  logic [1:0]  cfg_k,       // kernel size: 1 or 3
  input  logic [6:0]  cfg_h,       // output height
  input  logic [6:0]  cfg_w,       // output width
  input  logic [3:0]  cfg_n_it,    // input-channel tiles (>= 1)
  input  logic [3:0]  cfg_n_ot,    // output-channel tiles (>= 1)
  input  logic [10:0] cfg_x_base,
  input  logic [10:0] cfg_w_base,
  input  logic [10:0] cfg_psum_base,
  input  logic [10:0] cfg_out_base,

  output logic        busy,        // FSM not idle
  output logic        done,        // 1-cycle pulse at the end
  output logic        inst_valid,  // inst below is driven by the FSM (select for the inst mux)
  output logic [33:0] inst,        // registered, same encoding as core_tb.v
  output logic        core_rst,    // per-kij array reset and SFU clear
  output logic        arr_clr      // C7 only: array-only clear (corelet arr_clr); 0 otherwise
);

  // ---------------- phase lengths (core_tb.v) ----------------
  // localparam bit C1 = OPT[0], C2 = OPT[1], C3 = OPT[2], C4 = OPT[3], C5 = OPT[4], C6 = OPT[5];  // C7: + C7
  localparam bit C1 = OPT[0], C2 = OPT[1], C3 = OPT[2], C4 = OPT[3], C5 = OPT[4], C6 = OPT[5],
                 C7 = OPT[6];
  localparam int RST_HI   = C1 ? 1 : 11;   // reset high, then 2 idle cycles (C1: none)
  localparam int RST_LEN  = C1 ? 1 : RST_HI + 2;
  localparam int GAP_LOAD = 11;            // idle after load
  localparam int GAP_EXEC = row + col + 5; // idle after execute (1 + row+col+4)

  typedef enum logic [3:0] {
    S_IDLE,
    S_RST,     // per-kij reset (mac_tile re-arms its weight latch)
    S_WL0,     // weights xmem -> L0
    S_LOAD,    // L0 -> PE weight registers
    S_GAP,     // idle after load
    S_STREAM,  // pixels xmem -> L0, execute, OFIFO -> pmem (three windows, see above)
    S_SCLR,    // SFU clear (core reset)
    S_SACC,    // SFU accumulate K*K psums (tap (ky, kx) -> tapr + kx)
    S_SWB,     // SFU write-back
    S_DONE
  } state_t;

  state_t state;
  logic [7:0] cnt;               // cycle within the phase

  // ---------------- config (latched on start) ----------------
  logic [1:0]  k_r;
  logic [6:0]  w_r, wp_r;        // output width, padded input width
  logic [6:0]  npix_r;           // padded pixels (<= 64)
  logic [3:0]  nkij_r;           // K*K
  logic [7:0]  nacc_r;           // n_it*K*K psums per output pixel
  logic [3:0]  n_it_r, n_ot_r;
  logic [10:0] xb_r;
  logic [12:0] npix_out_r;       // H*W

  // ---------------- loop counters / address pointers ----------------
  logic [3:0]  kij, it, ot;      // pass indices
  logic [10:0] wptr;             // cfg_w_base + ((ot*n_it + it)*K*K + kij)*col  (never rewinds)
  logic [10:0] xptr;             // cfg_x_base + it*npix
  logic [10:0] pptr;             // cfg_psum_base + (it*K*K + kij)*npix
  logic [10:0] optr;             // cfg_out_base + ot*H*W
  logic [12:0] o_idx;            // output pixel
  logic [6:0]  ox;
  logic [10:0] rowb;             // oy*WP
  logic [1:0]  ky, kx;           // current tap
  logic [10:0] tapr;             // ky*WP (row offset of the current tap)
  logic [10:0] plane;            // j*npix (j = SFU read index)
  logic [10:0] pb_r;             // cfg_psum_base

  // Moore outputs (one testbench "cycle value" each)
  logic        s_l0_wr, s_l0_rd, s_load, s_exec, s_ofifo_rd, s_acc, s_sfu_wb;
  logic        s_xcen, s_xwen, s_pcen, s_pwen;
  logic [10:0] s_xa, s_pa;

  // S_STREAM window offsets (see the header)
  logic [7:0] npix8, off_e, off_d, off_p;
  always_comb begin
    npix8 = 8'(npix_r);
    off_e = C6 ? 8'd3 : npix8 + 8'd2;
    if (C5)      off_d = 8'(row + col + 1);
    else if (C3) off_d = (npix8 > 8'(row + col)) ? npix8 + 8'd1 : 8'(row + col + 1);
    else         off_d = npix8 + 8'(GAP_EXEC);
    off_p = off_e + off_d;
  end

  // C7 windows; `more` = another pass of this output tile follows this one
  logic       more;
  logic [7:0] off_w, off_a, end_c7;
  always_comb begin
    more   = C7 && !((kij == nkij_r - 4'd1) && (it == n_it_r - 4'd1));
    off_w  = (npix8 + 8'd1 > off_e + 8'(row + 10)) ? npix8 + 8'd1 : off_e + 8'(row + 10);
    off_a  = off_e + npix8 + 8'(row + col + 1);
    end_c7 = off_a + 8'(col + 1) + (C2 ? 8'd0 : 8'(GAP_LOAD));   // load + gap after load
  end

  logic [7:0] len;               // length of the current phase
  always_comb begin
    case (state)
      S_RST:   len = 8'(RST_LEN);
      S_WL0:   len = 8'(col + 2);
      S_LOAD:  len = 8'(col);
      S_GAP:   len = 8'(GAP_LOAD);
      // S_STREAM: len = off_p + npix8 + 8'd2;      // C7: replaced by the next line
      S_STREAM: len = (more && end_c7 > off_p + npix8 + 8'd2) ? end_c7 : off_p + npix8 + 8'd2;
      S_SCLR:  len = C4 ? 8'd1 : 8'd2;
      S_SACC:  len = nacc_r + (C4 ? 8'd1 : 8'd2);
      S_SWB:   len = C4 ? 8'd1 : 8'd2;
      default: len = 8'd1;
    endcase
  end
  wire last = (cnt == len - 8'd1);

  // ---------------- Moore output decode ----------------
  always_comb begin
    s_l0_wr = 0; s_l0_rd = 0; s_load = 0; s_exec = 0; s_ofifo_rd = 0; s_acc = 0; s_sfu_wb = 0;
    s_xcen = 1; s_xwen = 1; s_xa = '0;
    s_pcen = 1; s_pwen = 1; s_pa = '0;
    core_rst = 0;
    arr_clr  = 0;

    case (state)
      S_RST: core_rst = (cnt < 8'(RST_HI));

      S_WL0: if (cnt <= 8'(col)) begin                // prime + col writes
        s_xcen = 0;
        s_xa   = wptr + 11'((cnt < 8'(col-1)) ? cnt : 8'(col-1));  // clamp the last address
        s_l0_wr = (cnt != 0);
      end

      S_LOAD: begin s_l0_rd = 1; s_load = 1; end

      S_STREAM: begin
        if (cnt <= npix8) begin                       // L0 writes: prime + npix writes
          s_xcen = 0;
          s_xa   = xptr + 11'((cnt < npix8 - 8'd1) ? cnt : npix8 - 8'd1);
          s_l0_wr = (cnt != 0);
        end
        if (cnt >= off_e && cnt < off_e + npix8) begin  // execute
          s_exec = 1; s_l0_rd = 1;
        end
        if (cnt >= off_p && cnt < off_p + npix8)        // drain: prime + npix-1 reads
          s_ofifo_rd = 1;
        if (cnt > off_p && cnt <= off_p + npix8) begin  // npix pmem writes, one cycle behind
          s_pcen = 0; s_pwen = 0;
          s_pa   = pptr + 11'(cnt - off_p - 8'd1);
        end
        if (more) begin                                 // C7: next pass's weights
          if (cnt >= off_w && cnt <= off_w + 8'(col)) begin  // next weights -> L0 (prime + col)
            s_xcen = 0;
            s_xa   = wptr + 11'(col) + 11'((cnt - off_w < 8'(col - 1)) ? cnt - off_w : 8'(col - 1));
            s_l0_wr = (cnt != off_w);
          end
          arr_clr = (cnt == off_a);                     // re-arm the PEs only
          if (cnt > off_a && cnt <= off_a + 8'(col)) begin   // load the next weights
            s_l0_rd = 1; s_load = 1;
          end
        end
      end

      S_SCLR: core_rst = (cnt == 0);

      S_SACC: begin
        if (cnt < nacc_r) begin
          s_pcen = 0;
          s_pa   = pb_r + plane + rowb + 11'(ox) + tapr + 11'(kx);
        end
        s_acc = (cnt != 0) && (cnt <= nacc_r);          // read data arrives one cycle later
      end

      S_SWB: if (cnt == 0) begin
        s_sfu_wb = 1; s_pcen = 0; s_pwen = 0;
        s_pa = optr + 11'(o_idx);
      end

      default: ;
    endcase
  end

  // ---------------- state, counters ----------------
  always_ff @(posedge clk) begin
    if (reset) begin
      state <= S_IDLE;
      cnt   <= '0;
      done  <= 1'b0;
    end else begin
      done <= 1'b0;
      cnt  <= last ? 8'd0 : cnt + 8'd1;

      case (state)
        S_IDLE: begin
          cnt <= '0;
          if (start) begin
            k_r        <= cfg_k;
            w_r        <= cfg_w;
            wp_r       <= cfg_w + 7'(cfg_k) - 7'd1;
            npix_r     <= 7'((cfg_h + 7'(cfg_k) - 7'd1) * (cfg_w + 7'(cfg_k) - 7'd1));  // <= 64
            nkij_r     <= (cfg_k == 2'd3) ? 4'd9 : 4'd1;
            nacc_r     <= (cfg_k == 2'd3) ? 8'(cfg_n_it) * 8'd9 : 8'(cfg_n_it);
            n_it_r     <= cfg_n_it;
            n_ot_r     <= cfg_n_ot;
            npix_out_r <= 13'(cfg_h) * 13'(cfg_w);
            xb_r       <= cfg_x_base;
            pb_r       <= cfg_psum_base;
            kij        <= '0;
            it         <= '0;
            ot         <= '0;
            wptr       <= cfg_w_base;
            xptr       <= cfg_x_base;
            pptr       <= cfg_psum_base;
            optr       <= cfg_out_base;
            state      <= S_RST;
          end
        end

        S_RST:   if (last) state <= S_WL0;
        S_WL0:   if (last) state <= S_LOAD;
        S_LOAD:  if (last) state <= C2 ? S_STREAM : S_GAP;
        S_GAP:   if (last) state <= S_STREAM;

        S_STREAM: if (last) begin
          // weights and psum planes are laid out in pass order, so they always step
          wptr <= wptr + 11'(col);
          pptr <= pptr + 11'(npix_r);
          if (kij != nkij_r - 4'd1) begin           // next kij
            kij   <= kij + 4'd1;
            // state <= S_RST;                      // C7: replaced by the next line
            state <= C7 ? S_STREAM : S_RST;         // C7: weights already loaded during this pass
          end else if (it != n_it_r - 4'd1) begin   // next input tile
            kij   <= '0;
            it    <= it + 4'd1;
            xptr  <= xptr + 11'(npix_r);
            // state <= S_RST;                      // C7: replaced by the next line
            state <= C7 ? S_STREAM : S_RST;
          end else begin                            // output tile complete -> SFU
            o_idx <= '0; ox <= '0; rowb <= '0;
            state <= S_SCLR;
          end
        end

        S_SCLR: if (last) begin
          ky <= '0; kx <= '0; tapr <= '0; plane <= '0;
          state <= S_SACC;
        end

        S_SACC: begin
          if (cnt < nacc_r) begin                   // step to the next (it, ky, kx)
            plane <= plane + 11'(npix_r);
            if (kx != k_r - 2'd1)
              kx <= kx + 2'd1;
            else begin
              kx <= '0;
              if (ky != k_r - 2'd1) begin
                ky   <= ky + 2'd1;
                tapr <= tapr + 11'(wp_r);
              end else begin                        // kernel done: next input tile's plane
                ky   <= '0;
                tapr <= '0;
              end
            end
          end
          if (last) state <= S_SWB;
        end

        S_SWB: if (last) begin
          if (o_idx == npix_out_r - 13'd1) begin
            if (ot == n_ot_r - 4'd1)
              state <= S_DONE;
            else begin                              // next output tile: rewind it / x / psums
              ot    <= ot + 4'd1;
              it    <= '0;
              kij   <= '0;
              xptr  <= xb_r;
              pptr  <= pb_r;
              optr  <= optr + 11'(npix_out_r);
              state <= S_RST;
            end
          end else begin
            o_idx <= o_idx + 13'd1;
            if (ox == w_r - 7'd1) begin
              ox   <= '0;
              rowb <= rowb + 11'(wp_r);
            end else
              ox <= ox + 7'd1;
            state <= S_SCLR;
          end
        end

        S_DONE: begin
          done  <= 1'b1;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  assign busy = (state != S_IDLE);

  // ---------------- registered inst (the testbench's _q stage) ----------------
  always_ff @(posedge clk) begin
    if (reset) begin
      inst       <= {1'b0, 2'b11, 11'd0, 2'b11, 11'd0, 7'd0};  // SRAMs deselected
      inst_valid <= 1'b0;
    end else begin
      inst_valid <= busy;
      inst <= {s_acc,
               s_pcen, s_pwen, s_pa,
               s_xcen, s_xwen, s_xa,
               s_ofifo_rd, 1'b0, s_sfu_wb, s_l0_rd, s_l0_wr, s_exec, s_load};
    end
  end

endmodule
