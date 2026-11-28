// SIMULATION-ONLY behavioral stand-in for verilog/fifo_mux_2_1.v (alpha_ctrl).
//
// The given fifo_mux_2_1 is gate level (one and/and/or per bit). Inside the 64-deep FIFOs that
// is ~24k gate primitives for the 8 x 16-bit OFIFO, and every pop ripples events through all of
// them: iverilog then spends ~18 ms per OFIFO pop (the whole design simulates at ~330 cycles/s).
// This version is functionally the same 2:1 mux and ~150x faster in simulation.
//
// Never synthesize this or list it in filelist / filelist_tiled: the real design (and Quartus)
// keeps verilog/fifo_mux_2_1.v unchanged. test/run_nlp_batch.py swaps it in for long batch runs
// and can cross-check against the gate-level file (--gate).
module fifo_mux_2_1(in0, in1, sel, out);
  parameter bw = 8;
  input  [bw-1:0] in0;
  input  [bw-1:0] in1;
  input           sel;
  output [bw-1:0] out;
  assign out = sel ? in1 : in0;
endmodule
