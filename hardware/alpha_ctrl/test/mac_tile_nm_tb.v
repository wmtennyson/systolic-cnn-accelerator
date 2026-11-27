// Unit test for the 2:4 compressed mac_tile (SPARSE_NM = 1, abw = 16).
//
// Two tiles share one 16-bit west bus, like array rows 2k (W_SLOT = 0) and 2k+1 (W_SLOT = 1).
// For each case:
//   1. reset, then load one weight word: byte 0 = {2'b00, idx0, w0}, byte 1 = {2'b00, idx1, w1}
//   2. execute one cycle with 4 different activations on the bus and in_n = 100
//   3. check out_s = act[idx] * w + in_n for both tiles, and that out_e passes all 16 bits east
// Covers all 4 index values for each tile (the two tiles use different indices) and
// weights that are positive, the most negative (-8), and zero.
//
// Run from hardware/alpha_nm:
//   iverilog -g2012 -Wall -o mac_tile_nm_tb.vvp -s mac_tile_nm_tb test/mac_tile_nm_tb.v verilog/mac_tile.v verilog/mac.v
//   vvp mac_tile_nm_tb.vvp
`timescale 1ns/1ps

module mac_tile_nm_tb;

  reg         clk = 0;
  reg         reset = 1;
  reg  [15:0] in_w = 0;
  reg  [1:0]  inst_w = 0;   // {execute, load}
  reg  [15:0] in_n = 0;

  wire [15:0] s0, s1;       // out_s of tile 0 / tile 1
  wire [15:0] e0, e1;       // out_e of tile 0 / tile 1
  wire [1:0]  ie0, ie1;

  mac_tile #(.abw(16), .SPARSE_NM(1), .W_SLOT(0)) tile0 (
    .clk(clk), .reset(reset), .in_w(in_w), .out_e(e0), .in_n(in_n),
    .inst_w(inst_w), .inst_e(ie0), .out_s(s0));

  mac_tile #(.abw(16), .SPARSE_NM(1), .W_SLOT(1)) tile1 (
    .clk(clk), .reset(reset), .in_w(in_w), .out_e(e1), .in_n(in_n),
    .inst_w(inst_w), .inst_e(ie1), .out_s(s1));

  always #1 clk = ~clk;

  localparam [15:0] ACT = 16'hD3A5;  // x3 = 13, x2 = 3, x1 = 10, x0 = 5 (all different)

  integer idx, wcase, errors, cases;
  reg [1:0]          idx0, idx1;
  reg signed [3:0]   w0, w1;
  reg signed [15:0]  exp0, exp1;

  initial begin
    errors = 0;
    cases  = 0;

    for (idx = 0; idx < 4; idx = idx + 1) begin
      for (wcase = 0; wcase < 3; wcase = wcase + 1) begin
        idx0 = idx;
        idx1 = 3 - idx;                          // the other tile uses a different index
        case (wcase)
          0: begin w0 =  4'sd3; w1 = -4'sd2; end // positive / negative
          1: begin w0 = -4'sd8; w1 =  4'sd7; end // extremes of 4-bit signed
          2: begin w0 =  4'sd0; w1 =  4'sd0; end // padded weight (group with < 2 nonzeros)
        endcase

        // 1. Reset so both tiles accept a new weight (load_ready_q = 1)
        @(negedge clk) reset = 1; inst_w = 2'b00; in_w = 0; in_n = 0;
        @(negedge clk) reset = 0;

        // 2. Load: both tiles see the same word and each takes its own byte
        @(negedge clk) inst_w = 2'b01; in_w = {2'b00, idx1, w1, 2'b00, idx0, w0};
        @(negedge clk) inst_w = 2'b00; in_w = 0;

        // 3. Execute: the group's 4 activations on the bus, psum 100 from above
        @(negedge clk) inst_w = 2'b10; in_w = ACT; in_n = 16'd100;
        @(negedge clk) inst_w = 2'b00;

        // a_q, b_q, idx_q, c_q are all registered by now, so out_s is the MAC result
        exp0 = $signed({1'b0, ACT[idx0*4 +: 4]}) * w0 + 16'sd100;
        exp1 = $signed({1'b0, ACT[idx1*4 +: 4]}) * w1 + 16'sd100;
        cases = cases + 1;

        if (s0 !== exp0 || s1 !== exp1 || e0 !== ACT || e1 !== ACT) begin
          errors = errors + 1;
          $display("FAIL idx0=%0d w0=%0d idx1=%0d w1=%0d | out_s0=%0d (exp %0d) out_s1=%0d (exp %0d) | out_e0=%h out_e1=%h (exp %h)",
                   idx0, w0, idx1, w1, $signed(s0), exp0, $signed(s1), exp1, e0, e1, ACT);
        end
      end
    end

    if (errors == 0) $display("mac_tile_nm_tb: all %0d cases passed", cases);
    else             $display("mac_tile_nm_tb: %0d of %0d cases FAILED", errors, cases);
    $finish;
  end

endmodule
