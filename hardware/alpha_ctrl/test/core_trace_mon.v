// Cycle trace monitor for core (alpha_ctrl).
//
// Compiled as an extra top-level module next to a testbench; it never drives anything.
// Every rising clock edge it logs what the core samples on that edge: reset, the decoded
// inst bits, the xmem / pmem access, and a few internal events (L0 FIFO pops, OFIFO pops,
// array valid, per-row execute). Values are read in the active region of the edge, so
// they are the pre-edge values the flops actually see.
//
// Select the core instance with +define+TRACE_CORE=<hier path> (default: core_tb.core_instance)
// and enable logging at run time with +trace=<file>. Lines start with "c=<cycle>" so two
// traces can be compared after stripping the cycle number (see trace_tools.py).
//
//   iverilog -g2012 -DTRACE_CORE=core_tb.core_instance -o sim -c filelist test/core_trace_mon.v
//   vvp sim +trace=trace.txt
`timescale 1ns/1ps

`ifndef TRACE_CORE
  `define TRACE_CORE core_tb.core_instance
`endif

module core_trace_mon;

  integer fd = 0;
  integer cyc = 0;
  reg [8*256:1] fname;

  initial begin
    if ($value$plusargs("trace=%s", fname)) begin
      fd = $fopen(fname, "w");
      if (fd == 0) $fatal(1, "core_trace_mon: cannot open trace file");
    end
  end

  wire        clk   = `TRACE_CORE.clk;
  wire        rst   = `TRACE_CORE.reset;
  wire [33:0] inst  = `TRACE_CORE.inst;

  wire        x_cen = inst[19], x_wen = inst[18];
  wire [10:0] x_a   = inst[17:7];
  wire        p_cen = inst[32], p_wen = inst[31];
  wire [10:0] p_a   = inst[30:20];

  always @(posedge clk) begin
    if (fd != 0) begin
      $fwrite(fd, "c=%0d rst=%b | wr=%b rd=%b ld=%b ex=%b ofrd=%b acc=%b wb=%b | ",
              cyc, rst, inst[2], inst[3], inst[0], inst[1], inst[6], inst[33], inst[4]);
      if (!x_cen &&  x_wen) $fwrite(fd, "X:R%0d ", x_a);
      else if (!x_cen && !x_wen) $fwrite(fd, "X:W%0d ", x_a);
      else $fwrite(fd, "X:- ");
      if (!p_cen &&  p_wen) $fwrite(fd, "P:R%0d ", p_a);
      else if (!p_cen && !p_wen) $fwrite(fd, "P:W%0d=%h ", p_a, `TRACE_CORE.pmem_d);
      else $fwrite(fd, "P:- ");
      $fwrite(fd, "| l0pop=%b ofpop=%b aval=%b rowex=%b\n",
              `TRACE_CORE.corelet_inst.l0_inst.rd_en & ~`TRACE_CORE.corelet_inst.l0_inst.empty,
              `TRACE_CORE.corelet_inst.ofifo_inst.rd_en & ~|`TRACE_CORE.corelet_inst.ofifo_inst.empty,
              `TRACE_CORE.corelet_inst.array_valid,
              row_ex(`TRACE_CORE.corelet_inst.mac_array_inst.inst_w_temp));
    end
    cyc = cyc + 1;
  end

  // execute bit of each array row's instruction (inst_w_temp holds {execute, load} per row)
  function [15:0] row_ex(input [31:0] t);
    integer k;
    begin
      row_ex = 0;
      for (k = 0; k < 16; k = k + 1) row_ex[k] = t[2*k+1];
    end
  endfunction

endmodule
