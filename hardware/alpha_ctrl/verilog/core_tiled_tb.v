// Tiled-layer testbench for alpha_ctrl (stage 1 and stage 2).
//
// Layer: IC x OC channels (multiples of row / col), kernel K in {1, 3}, output H x W, set with
// plusargs (+IC= +OC= +K= +H= +W=, defaults 8 8 3 4 4 = the original layer). Data comes from
// software/gen_random_tiled.py (or the notebook files for the default layer).
//
// Memory map (fixed):
//   xmem  activations X_BASE + it*npix + p                       (it = input tile, p = padded pixel)
//         weights     W_BASE + ((ot*n_it + it)*K*K + kij)*col + c (ot = output tile, c = column)
//   pmem  psums       PSUM_BASE + (it*K*K + kij)*npix + p          (reused for every output tile)
//         outputs     OUT_BASE + ot*H*W + o                         (ReLU'd SFU results)
//
// Both builds preload xmem through inst, exactly like core_tb.v, then:
//   default build  : the testbench drives the control sequence (stage 1). Loop order is
//                    output tile -> input tile -> kij -> phases, then the SFU for that output
//                    tile. Every phase is cycle-for-cycle the one in core_tb.v, minus the
//                    in-loop weight writes.
//   -DUSE_CTRL     : core_ctrl (ctrl.sv FSM + core) runs the whole layer, tile loops included
//                    (stage 3); the testbench only sets the config, pulses start and waits
//                    for done.
// Checks: sfp_out at every SFU result (default build), the output region of pmem at the end
// (both builds). Prints "No error detected" on success.
//
// Optional: +vcd dumps core_tiled_tb.vcd. With test/core_trace_mon.v compiled in, +trace=<file>
// writes a cycle trace; the two builds must give identical traces (trace_tools.py diff).
`timescale 1ns/1ps

module core_tiled_tb;

parameter bw        = 4;
parameter psum_bw   = 16;
parameter col       = 8;
parameter row       = 8;
parameter SPARSE_NM = 0;
parameter CTRL_OPT  = 0;   // ctrl.sv cycle-saving options (FSM builds only)

localparam X_BASE    = 0;
localparam W_BASE    = 1024;
localparam PSUM_BASE = 0;
localparam OUT_BASE  = 1024;

reg clk = 0;
reg reset = 1;

wire [33:0] inst_q;
reg [bw*row-1:0] D_xmem = 0, D_xmem_q = 0;
reg CEN_xmem = 1, WEN_xmem = 1;  reg [10:0] A_xmem = 0;
reg CEN_pmem = 1, WEN_pmem = 1;  reg [10:0] A_pmem = 0;
reg CEN_xmem_q = 1, WEN_xmem_q = 1;  reg [10:0] A_xmem_q = 0;
reg CEN_pmem_q = 1, WEN_pmem_q = 1;  reg [10:0] A_pmem_q = 0;
reg ofifo_rd = 0, l0_rd = 0, l0_wr = 0, execute = 0, load = 0, acc = 0, sfu_wb = 0;
reg ofifo_rd_q = 0, l0_rd_q = 0, l0_wr_q = 0, execute_q = 0, load_q = 0, acc_q = 0, sfu_wb_q = 0;

wire ofifo_valid;
wire [col*psum_bw-1:0] sfp_out;

assign inst_q[33]    = acc_q;
assign inst_q[32]    = CEN_pmem_q;
assign inst_q[31]    = WEN_pmem_q;
assign inst_q[30:20] = A_pmem_q;
assign inst_q[19]    = CEN_xmem_q;
assign inst_q[18]    = WEN_xmem_q;
assign inst_q[17:7]  = A_xmem_q;
assign inst_q[6]     = ofifo_rd_q;
assign inst_q[5]     = 1'b0;
assign inst_q[4]     = sfu_wb_q;
assign inst_q[3]     = l0_rd_q;
assign inst_q[2]     = l0_wr_q;
assign inst_q[1]     = execute_q;
assign inst_q[0]     = load_q;

always @(posedge clk) begin
  D_xmem_q   <= D_xmem;
  CEN_xmem_q <= CEN_xmem;  WEN_xmem_q <= WEN_xmem;  A_xmem_q <= A_xmem;
  CEN_pmem_q <= CEN_pmem;  WEN_pmem_q <= WEN_pmem;  A_pmem_q <= A_pmem;
  ofifo_rd_q <= ofifo_rd;  acc_q <= acc;  sfu_wb_q <= sfu_wb;
  l0_rd_q <= l0_rd;  l0_wr_q <= l0_wr;  execute_q <= execute;  load_q <= load;
end

// ---------------- DUT ----------------
`ifdef USE_CTRL
reg         start = 0;
reg  [1:0]  cfg_k = 0;
reg  [6:0]  cfg_h = 0, cfg_w = 0;
reg  [3:0]  cfg_n_it = 0, cfg_n_ot = 0;
wire        busy, done;

core_ctrl #(.bw(bw), .psum_bw(psum_bw), .col(col), .row(row), .SPARSE_NM(SPARSE_NM), .CTRL_OPT(CTRL_OPT)) dut (
  .clk(clk), .reset(reset), .inst(inst_q), .D_xmem(D_xmem_q),
  .ofifo_valid(ofifo_valid), .sfp_out(sfp_out),
  .start(start), .cfg_k(cfg_k), .cfg_h(cfg_h), .cfg_w(cfg_w),
  .cfg_n_it(cfg_n_it), .cfg_n_ot(cfg_n_ot),
  .cfg_x_base(11'(X_BASE)), .cfg_w_base(11'(W_BASE)),
  .cfg_psum_base(11'(PSUM_BASE)), .cfg_out_base(11'(OUT_BASE)),
  .busy(busy), .done(done));
`define CORE dut.core_instance
`else
core #(.bw(bw), .psum_bw(psum_bw), .col(col), .row(row), .SPARSE_NM(SPARSE_NM)) dut (
  .clk(clk), .inst(inst_q), .ofifo_valid(ofifo_valid), .D_xmem(D_xmem_q),
  .sfp_out(sfp_out), .reset(reset));
`define CORE dut
`endif

// ---------------- layer config ----------------
integer IC, OC, K, H, W;
integer n_it, n_ot, nkij, HP, WP, npix, npix_out, n_wlines;

reg [col*psum_bw-1:0] expected [0:1023];

integer f, r, t, i, j, ot, it, kij, o, oy, ox, ky, kx, jj;
integer error = 0, n_checked = 0;
integer cyc = 0, cyc_start;
reg [8*64:1] hdr;

// One clock cycle. Signals are set while clk is low; the edge samples them.
task tick; begin #0.5 clk = 1'b1; #0.5 clk = 1'b0; cyc = cyc + 1; end endtask

task skip_header(input integer fd);
  begin r = $fscanf(fd, "%s", hdr); r = $fscanf(fd, "%s", hdr); r = $fscanf(fd, "%s", hdr); end
endtask

// ---------------- stage 1: testbench-driven phases (core_tb.v timing) ----------------
// Reset before each kij: mac_tile latches its weight once per reset.
task pass_reset; begin
  reset = 1; for (t = 0; t < 11; t = t + 1) tick;
  reset = 0; tick;
  tick;
end endtask

// xmem -> L0: prime the read, then n writes; L0 stores the word addressed one cycle earlier.
task xmem_to_l0(input integer base, input integer n); begin
  CEN_xmem = 0; WEN_xmem = 1; A_xmem = base; l0_wr = 0; tick;
  for (t = 0; t < n; t = t + 1) begin
    A_xmem = base + ((t < n-1) ? t+1 : n-1);  // clamp: the last address is read twice
    l0_wr = 1; tick;
  end
  CEN_xmem = 1; l0_wr = 0; tick;
end endtask

task pass_load; begin
  for (t = 0; t < col; t = t + 1) begin l0_rd = 1; load = 1; tick; end
  load = 0; l0_rd = 0; tick;
  for (t = 0; t < 10; t = t + 1) tick;
end endtask

task pass_execute; begin
  for (t = 0; t < npix; t = t + 1) begin execute = 1; l0_rd = 1; tick; end
  execute = 0; l0_rd = 0; tick;
  for (t = 0; t < row+col+4; t = t + 1) tick;
end endtask

// OFIFO -> pmem. ofifo_rd is registered inside ofifo, hence the prime cycle.
task pass_drain(input integer base); begin
  ofifo_rd = 1; CEN_pmem = 1; WEN_pmem = 1; tick;
  for (t = 0; t < npix; t = t + 1) begin
    ofifo_rd = (t < npix-1);
    A_pmem = base + t; CEN_pmem = 0; WEN_pmem = 0; tick;
  end
  ofifo_rd = 0; CEN_pmem = 1; WEN_pmem = 1; tick;
end endtask

// SFU for one output tile: per output pixel, accumulate n_it*K*K psums, ReLU, write back.
task sfu_tile(input integer ot_i);
  integer nacc;
  begin
    nacc = n_it * nkij;
    for (o = 0; o < npix_out; o = o + 1) begin
      oy = o / W; ox = o % W;
      reset = 1; tick;          // clears the SFU accumulators (global reset, as in core_tb.v)
      reset = 0; tick;
      for (j = 0; j < nacc + 1; j = j + 1) begin
        if (j < nacc) begin
          ky = (j % nkij) / K; kx = (j % nkij) % K;
          CEN_pmem = 0; WEN_pmem = 1;
          A_pmem = PSUM_BASE + j*npix + (oy+ky)*WP + (ox+kx);
        end else begin
          CEN_pmem = 1; WEN_pmem = 1;
        end
        acc = (j > 0);
        tick;
      end
      acc = 0; tick;
      #0.1;
      check(sfp_out, ot_i*npix_out + o, "sfp_out");
      sfu_wb = 1; CEN_pmem = 0; WEN_pmem = 0; A_pmem = OUT_BASE + ot_i*npix_out + o; tick;
      sfu_wb = 0; CEN_pmem = 1; WEN_pmem = 1; tick;
    end
  end
endtask

task check(input [col*psum_bw-1:0] got, input integer idx, input [8*8:1] what); begin
  n_checked = n_checked + 1;
  if (got !== expected[idx]) begin
    error = error + 1;
    if (error <= 10) begin
      $display("%0s ERROR at output %0d (ot %0d, o %0d)", what, idx, idx / npix_out, idx % npix_out);
      $display("  got:    %h", got);
      $display("  answer: %h", expected[idx]);
    end
  end
end endtask

// ---------------- main ----------------
initial begin
  if (!$value$plusargs("IC=%d", IC)) IC = 8;
  if (!$value$plusargs("OC=%d", OC)) OC = 8;
  if (!$value$plusargs("K=%d",  K))  K  = 3;
  if (!$value$plusargs("H=%d",  H))  H  = 4;
  if (!$value$plusargs("W=%d",  W))  W  = 4;
  if (IC % row != 0 || OC % col != 0 || !(K == 1 || K == 3))
    $fatal(1, "bad layer: IC=%0d OC=%0d K=%0d", IC, OC, K);
  n_it = IC / row;  n_ot = OC / col;  nkij = K*K;
  HP = H + K - 1;   WP = W + K - 1;   npix = HP*WP;  npix_out = H*W;
  n_wlines = n_ot * n_it * nkij * col;
  if (npix > 64) $fatal(1, "npix = %0d > 64 (L0 / OFIFO depth)", npix);
`ifdef USE_CTRL
  if (n_it > 15 || n_ot > 15) $fatal(1, "controller: at most 15 tiles per dimension (4-bit config)");
`endif
  $display("Layer IC=%0d OC=%0d K=%0d out %0dx%0d: %0d in x %0d out tiles, npix=%0d, SPARSE_NM=%0d",
           IC, OC, K, H, W, n_it, n_ot, npix, SPARSE_NM);

  if ($test$plusargs("vcd")) begin $dumpfile("core_tiled_tb.vcd"); $dumpvars(0, core_tiled_tb); end

  f = $fopen("sys_data/psum.txt", "r");
  if (f == 0) $fatal(1, "CANT READ PSUM.TXT");
  skip_header(f);
  for (i = 0; i < n_ot*npix_out; i = i + 1) begin
    r = $fscanf(f, "%b", expected[i]);
    if (r != 1) $fatal(1, "psum.txt too short (%0d of %0d lines)", i, n_ot*npix_out);
  end
  $fclose(f);

  // reset
  reset = 1; for (t = 0; t < 11; t = t + 1) tick;
  reset = 0; tick;
  tick;

  // preload activations, then all weights, through inst (same timing as core_tb.v)
  f = $fopen("sys_data/input.txt", "r");
  if (f == 0) $fatal(1, "CANT READ INPUT.TXT");
  skip_header(f);
  for (t = 0; t < n_it*npix; t = t + 1) begin
    r = $fscanf(f, "%b", D_xmem);
    if (r != 1) $fatal(1, "input.txt too short");
    WEN_xmem = 0; CEN_xmem = 0; A_xmem = X_BASE + t; tick;
  end
  WEN_xmem = 1; CEN_xmem = 1; tick;
  $fclose(f);

  f = $fopen("sys_data/weight.txt", "r");
  if (f == 0) $fatal(1, "CANT READ WEIGHT.TXT");
  skip_header(f);
  for (t = 0; t < n_wlines; t = t + 1) begin
    r = $fscanf(f, "%b", D_xmem);
    if (r != 1) $fatal(1, "weight.txt too short");
    WEN_xmem = 0; CEN_xmem = 0; A_xmem = W_BASE + t; tick;
  end
  WEN_xmem = 1; CEN_xmem = 1; tick;
  $fclose(f);

  cyc_start = cyc;

`ifdef USE_CTRL
  // stages 2-3: config + start pulse, wait for done
  cfg_k = K; cfg_h = H; cfg_w = W; cfg_n_it = n_it; cfg_n_ot = n_ot;
  start = 1; tick;
  start = 0;
  while (!done) begin
    tick;
    if (cyc - cyc_start > 1000000) $fatal(1, "timeout waiting for done");
  end
  tick;
`else
  // stage 1: tile loops in the testbench
  for (ot = 0; ot < n_ot; ot = ot + 1) begin
    for (it = 0; it < n_it; it = it + 1) begin
      for (kij = 0; kij < nkij; kij = kij + 1) begin
        pass_reset;
        xmem_to_l0(W_BASE + ((ot*n_it + it)*nkij + kij)*col, col);
        pass_load;
        xmem_to_l0(X_BASE + it*npix, npix);
        pass_execute;
        pass_drain(PSUM_BASE + (it*nkij + kij)*npix);
      end
    end
    sfu_tile(ot);
  end
`endif

  $display("compute cycles (after preload): %0d", cyc - cyc_start);

  // output region of pmem
  for (i = 0; i < n_ot*npix_out; i = i + 1)
    check(`CORE.pmem_inst.memory[OUT_BASE + i], i, "pmem");

  if (error == 0) begin
    $display("############ No error detected (%0d checks) ##############", n_checked);
  end else
    $display("####### RIP %0d errors (%0d checks) #######", error, n_checked);

  for (t = 0; t < 4; t = t + 1) tick;
  $finish;
end

endmodule
