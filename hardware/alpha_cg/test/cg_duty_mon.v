// Sim-only: counts how many clk cycles each gated clock was enabled.
// Compile it as an extra top next to core_tb (see run_cg_duty.sh). Not for Quartus.
module cg_duty_mon;
  integer total = 0, n_l0 = 0, n_array = 0, n_ofifo = 0, n_sfu = 0;
  always @(posedge core_tb.clk) begin
    total   = total + 1;
    n_l0    = n_l0    + core_tb.core_instance.corelet_inst.en_l0_l;
    n_array = n_array + core_tb.core_instance.corelet_inst.en_array_l;
    n_ofifo = n_ofifo + core_tb.core_instance.corelet_inst.en_ofifo_l;
    n_sfu   = n_sfu   + core_tb.core_instance.corelet_inst.en_sfu_l;
  end
  final begin
    $display("CG duty (clock-enabled cycles / %0d total):", total);
    $display("  l0    %6d  %5.1f%%", n_l0,    100.0*n_l0/total);
    $display("  array %6d  %5.1f%%", n_array, 100.0*n_array/total);
    $display("  ofifo %6d  %5.1f%%", n_ofifo, 100.0*n_ofifo/total);
    $display("  sfu   %6d  %5.1f%%", n_sfu,   100.0*n_sfu/total);
  end
endmodule
