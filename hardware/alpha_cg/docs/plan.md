# alpha_cg: clock gating on top of baseline

Branch `alpha/clock-gating` (worktree `../systolic-cnn-accelerator-cg`), forked from `main` @ 99df8e8.
`hardware/alpha_cg/` is a copy of `hardware/baseline/`. The only RTL file changed is `verilog/corelet.sv`
(changes are tagged `[alpha_cg]`, and the baseline lines are kept as comments).

## What was added (all in corelet.sv, on the free-running clk)
One gated clock per block, each made with a latch + AND (en latched while clk is low, `gclk = clk & en_l`):

| block | enable | extra state |
|---|---|---|
| l0        | `reset \| l0_wr \| l0_rd \| l0_cnt != 0`              | 4-bit counter, reloads `row` on l0_rd (flushes l0's internal rd_en shift register) |
| mac_array | `reset \| load \| execute \| array_cnt != 0`          | 5-bit counter, reloads `row+col+2` on load/execute (wavefront drain) |
| ofifo     | `reset \| \|array_valid \| ofifo_rd \| ofifo_rd_q`     | 1 FF (copy of ofifo's internal rd_en) |
| sfu       | `reset \| acc`                                       | none |

Total new logic: 4 latches, 4 AND gates, 10 FFs, 2 decrementers, a few ORs.
Reset is in every enable because every reset in the design is synchronous.

## Verification
- `regression_test.sh 10`: real + 10 seeds pass.
- `test/run_cg_equiv.sh N`: per-cycle diff of every OFIFO write (valid + data), ofifo_out, ofifo_valid
  and sfp_out against `hardware/baseline` passes for real + 3 seeds. core_tb's final check is too loose to prove
  the drain margins: a drain of `row` still passes it, but this diff catches it.
- Mutation results under the diff: an array drain of `row` fails, `row+col` is the minimum that passes, and the design uses `+2` margin.
  Removing `ofifo_rd_q` fails. Dropping reset from the sfu enable fails regression.
  L0_DRAIN = row-1 still passes, because the testbench resets between uses of l0, but `row` is the analytically correct value.
- `test/run_cg_duty.sh` gives the clock-enabled fraction on real data (1973 cycles):
  l0 53.8%, array 42.9%, ofifo 42.9%, sfu 13.7%.

## Quartus power evaluation (same flow for baseline and alpha_cg)
The existing `hardware/corelet.pow.rpt` is vectorless (12.5% toggle, low confidence), so it can't see gating.
Both designs must be re-run with simulation activity:
1. Compile corelet. Expect warnings about latches and gated clocks, which are intended here.
2. Write the gate-level netlist with EDA Netlist Writer (Questa, Verilog .vo).
3. Run core_tb + core.sv + SRAMs with the corelet .vo in Questa, dumping a VCD of `core_tb/core_instance/corelet_inst`.
4. Power Analyzer: add the VCD as the toggle-rate input, set entity `core_tb|core_instance|corelet_inst`, and check that
   the confidence is no longer Low.
5. Compare core dynamic power, the "Clock control block" and "Register cell" rows, the per-hierarchy rows
   (l0, mac_array, ofifo, sfu), and area (LEs/FFs, global clocks). The cycle count is unchanged, so energy changes by the same ratio as power.
