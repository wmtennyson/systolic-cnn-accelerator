// Batch testbench for the NLP mapping (alpha_ctrl): many sentences through the FSM controller.
//
// Input: a folder written by software/nlp_export.py (NLP_Quant_Training.ipynb), e.g.
// software/nlp_hw/dense_row8:
//   <DIR>/weight.txt              ff2 weights, loaded into xmem once
//   <DIR>/sent_XXXX/input.txt     activations of one sentence (n_it*T lines; T = tokens)
//   <DIR>/sent_XXXX/psum.txt      expected ReLU'd outputs (n_ot*T lines)
// Output, per sentence:
//   <DIR>/sent_XXXX/hw_out.txt    the hardware result (pmem output region), psum.txt format
// and one "SENT <s> T=<T> cycles=<c> errors=<e>" line per sentence on stdout.
//
// Plusargs: +DIR=<folder> (required), +FIRST=<first sentence, default 0>,
// +COUNT=<sentences, default 1>, or +LIST=<file of sentence numbers, one per line> instead of
// FIRST/COUNT; +IC=64 +OC=64 (layer size). K = 1, H = 1, W = T per sentence.
// Build: -Pcore_batch_tb.row=8 (dense) or -Pcore_batch_tb.row=16 -Pcore_batch_tb.SPARSE_NM=1 (2:4).
//
// Same memory map and preload timing as core_tiled_tb.v. Weights stay in xmem for the whole
// run; each sentence overwrites the activations, the psum region and the output region.
`timescale 1ns/1ps

module core_batch_tb;

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
localparam MAX_T     = 64;

reg clk = 0;
reg reset = 1;

wire [33:0] inst_q;
reg [bw*row-1:0] D_xmem = 0, D_xmem_q = 0;
reg CEN_xmem = 1, WEN_xmem = 1;  reg [10:0] A_xmem = 0;
reg CEN_xmem_q = 1, WEN_xmem_q = 1;  reg [10:0] A_xmem_q = 0;

// Only the xmem write path is driven by the testbench; the FSM does everything else.
assign inst_q[33]    = 1'b0;           // acc
assign inst_q[32]    = 1'b1;           // CEN_pmem
assign inst_q[31]    = 1'b1;           // WEN_pmem
assign inst_q[30:20] = 11'd0;
assign inst_q[19]    = CEN_xmem_q;
assign inst_q[18]    = WEN_xmem_q;
assign inst_q[17:7]  = A_xmem_q;
assign inst_q[6:0]   = 7'd0;

always @(posedge clk) begin
  D_xmem_q   <= D_xmem;
  CEN_xmem_q <= CEN_xmem;  WEN_xmem_q <= WEN_xmem;  A_xmem_q <= A_xmem;
end

reg         start = 0;
reg  [6:0]  cfg_w = 0;
reg  [3:0]  cfg_n_it = 0, cfg_n_ot = 0;
wire        busy, done, ofifo_valid;
wire [col*psum_bw-1:0] sfp_out;

core_ctrl #(.bw(bw), .psum_bw(psum_bw), .col(col), .row(row), .SPARSE_NM(SPARSE_NM), .CTRL_OPT(CTRL_OPT)) dut (
  .clk(clk), .reset(reset), .inst(inst_q), .D_xmem(D_xmem_q),
  .ofifo_valid(ofifo_valid), .sfp_out(sfp_out),
  .start(start), .cfg_k(2'd1), .cfg_h(7'd1), .cfg_w(cfg_w),
  .cfg_n_it(cfg_n_it), .cfg_n_ot(cfg_n_ot),
  .cfg_x_base(11'(X_BASE)), .cfg_w_base(11'(W_BASE)),
  .cfg_psum_base(11'(PSUM_BASE)), .cfg_out_base(11'(OUT_BASE)),
  .busy(busy), .done(done));

integer IC, OC, FIRST, COUNT, k;
integer idx [0:4095];
string  listf;
integer n_it, n_ot, n_x, T, s, i, f, r, cyc = 0, cyc_start, sent_err, total_err = 0, total_cyc = 0;
string  dir, fname;
reg [bw*row-1:0]      xbuf [0:16*MAX_T-1];
reg [col*psum_bw-1:0] expected, got;
reg [8*64:1] hdr;

task tick; begin #0.5 clk = 1'b1; #0.5 clk = 1'b0; cyc = cyc + 1; end endtask

task skip_header(input integer fd);
  begin r = $fscanf(fd, "%s", hdr); r = $fscanf(fd, "%s", hdr); r = $fscanf(fd, "%s", hdr); end
endtask

initial begin
  if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "+DIR=<folder> is required");
  if (!$value$plusargs("FIRST=%d", FIRST)) FIRST = 0;
  if (!$value$plusargs("COUNT=%d", COUNT)) COUNT = 1;
  if ($value$plusargs("LIST=%s", listf)) begin          // explicit sentence numbers
    f = $fopen(listf, "r");
    if (f == 0) $fatal(1, "cannot open %s", listf);
    COUNT = 0;
    while ($fscanf(f, "%d", idx[COUNT]) == 1) COUNT = COUNT + 1;
    $fclose(f);
  end else
    for (k = 0; k < COUNT; k = k + 1) idx[k] = FIRST + k;
  if (!$value$plusargs("IC=%d", IC)) IC = 64;
  if (!$value$plusargs("OC=%d", OC)) OC = 64;
  if (IC % row != 0 || OC % col != 0) $fatal(1, "IC must be a multiple of %0d, OC of %0d", row, col);
  n_it = IC / row;  n_ot = OC / col;
  cfg_n_it = n_it;  cfg_n_ot = n_ot;

  // reset
  reset = 1; for (i = 0; i < 11; i = i + 1) tick;
  reset = 0; tick;
  tick;

  // weights, once
  fname = {dir, "/weight.txt"};
  f = $fopen(fname, "r");
  if (f == 0) $fatal(1, "cannot open %s", fname);
  skip_header(f);
  for (i = 0; i < n_ot*n_it*col; i = i + 1) begin
    r = $fscanf(f, "%b", D_xmem);
    if (r != 1) $fatal(1, "%s too short", fname);
    WEN_xmem = 0; CEN_xmem = 0; A_xmem = W_BASE + i; tick;
  end
  WEN_xmem = 1; CEN_xmem = 1; tick;
  $fclose(f);

  for (k = 0; k < COUNT; k = k + 1) begin
    s = idx[k];
    // activations of sentence s: n_it*T lines, T from the line count
    fname = $sformatf("%s/sent_%04d/input.txt", dir, s);
    f = $fopen(fname, "r");
    if (f == 0) $fatal(1, "cannot open %s", fname);
    skip_header(f);
    n_x = 0;
    while ($fscanf(f, "%b", xbuf[n_x]) == 1) n_x = n_x + 1;
    $fclose(f);
    if (n_x % n_it != 0 || n_x == 0) $fatal(1, "%s: %0d lines, not a multiple of %0d", fname, n_x, n_it);
    T = n_x / n_it;
    if (T > MAX_T) $fatal(1, "%s: %0d tokens > %0d", fname, T, MAX_T);
    for (i = 0; i < n_x; i = i + 1) begin
      D_xmem = xbuf[i]; WEN_xmem = 0; CEN_xmem = 0; A_xmem = X_BASE + i; tick;
    end
    WEN_xmem = 1; CEN_xmem = 1; tick;

    // run the layer
    cfg_w = T;
    cyc_start = cyc;
    start = 1; tick;
    start = 0;
    while (!done) begin
      tick;
      if (cyc - cyc_start > 1000000) $fatal(1, "timeout on sentence %0d", s);
    end
    tick;
    total_cyc = total_cyc + (cyc - cyc_start);

    // check against psum.txt and write hw_out.txt from the pmem output region
    fname = $sformatf("%s/sent_%04d/psum.txt", dir, s);
    f = $fopen(fname, "r");
    if (f == 0) $fatal(1, "cannot open %s", fname);
    skip_header(f);
    r = $fopen($sformatf("%s/sent_%04d/hw_out.txt", dir, s), "w");
    $fwrite(r, "#hw_out:line=out_base+ot*T+t,read_from_pmem#\n");
    $fwrite(r, "#col7[msb-lsb],...,col0[msb-lsb]_of_output_tile_ot,after_ReLU#\n");
    $fwrite(r, "#................#\n");
    sent_err = 0;
    for (i = 0; i < n_ot*T; i = i + 1) begin
      got = dut.core_instance.pmem_inst.memory[OUT_BASE + i];
      $fwrite(r, "%b\n", got);
      if ($fscanf(f, "%b", expected) != 1) $fatal(1, "%s too short", fname);
      if (got !== expected) sent_err = sent_err + 1;
    end
    $fclose(r);
    $fclose(f);
    total_err = total_err + sent_err;
    $display("SENT %0d T=%0d cycles=%0d errors=%0d", s, T, cyc - cyc_start, sent_err);
  end

  $display("BATCH sentences=%0d cycles=%0d errors=%0d", COUNT, total_cyc, total_err);
  if (total_err == 0) $display("############ No error detected ##############");
  else                $display("####### RIP %0d errors #######", total_err);
  $finish;
end

endmodule
