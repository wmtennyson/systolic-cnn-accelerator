// Sim-only: per-cycle trace of everything corelet hands to the outside world plus every
// OFIFO write. Run once on baseline and once on alpha_cg, then diff (see run_cg_equiv.sh).
// Any difference means the gating changed behaviour, even if core_tb's final check passes.
module cg_trace_mon;
  integer f, cyc = 0;
  initial f = $fopen("cg_trace.txt", "w");
  always @(posedge core_tb.clk) begin
    cyc = cyc + 1;
    if (|core_tb.core_instance.corelet_inst.array_valid)
      $fdisplay(f, "%0d W %b %h", cyc, core_tb.core_instance.corelet_inst.array_valid,
                core_tb.core_instance.corelet_inst.array_out);
    $fdisplay(f, "%0d O %b %h %h", cyc, core_tb.core_instance.corelet_inst.ofifo_valid,
              core_tb.core_instance.corelet_inst.ofifo_out, core_tb.core_instance.corelet_inst.sfp_out);
  end
  final $fclose(f);
endmodule
