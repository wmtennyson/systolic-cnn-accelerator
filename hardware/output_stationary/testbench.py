import cocotb
from cocotb.clock import Clock
from helpers import *


async def run_output_stationary(dut):
  logger.info("=== Output-stationary pass (mode_os = 1) ===")

  logger.info("Loading activations into xmem")
  await load_xint_into_xmem(dut)

  logger.info("Loading weights into xmem")
  await load_wint_into_xmem(dut)

  for t in range(n_tiles):
    logger.info(f"Tile {t}: streaming activations and weights through the array")
    await run_tile_compute(dut, t)

    logger.debug("Checking PE accumulators")
    check_accumulators(dut, t)

    logger.debug("Draining accumulators to OFIFO")
    await drain_array(dut)

    logger.debug("Moving OFIFO contents to pmem")
    await store_ofifo_to_pmem(dut, t)
    check_raw_psums(dut, t)

  logger.info("Applying ReLU through the SFU")
  await sfu_relu_all(dut)

  logger.info("Checking output-stationary result")
  check_final_output(dut)


async def run_weight_stationary(dut):
  logger.info("=== Weight-stationary pass (mode_os = 0) ===")

  logger.info("Switching mode at runtime")
  await set_mode(dut, output_stationary=False)

  logger.info("Loading WS activations and weights into xmem")
  await ws_load_data_into_xmem(dut)

  for kij in range(9):
    logger.debug(f"Loading kernel weights for {kij = }")
    await ws_load_weights_into_array(dut, kij)
    ws_check_pe_weights(dut, kij)

    logger.debug("Loading activations into L0")
    await stage_into_buffer(dut, ws_xmem_act_base, ws_len_nij, inst.load_l0())

    logger.debug("Starting execution")
    await ws_execute(dut)

    logger.debug("Draining ofifo")
    await ws_drain_ofifo_to_pmem(dut, kij)
    ws_check_pass_psums(dut, kij)

    logger.debug("Resetting before next iteration")
    await reset(dut)

  logger.info("Accumulating taps in the SFU")
  for yi in range(4):
    for yj in range(4):
      await reset(dut)      # clears the SFU accumulators
      await ws_sfp_accumulate(dut, yi, yj)

  logger.info("Checking weight-stationary result")
  check_final_output(dut, ws_pmem_relu_base)


@cocotb.test()
async def test_core(dut):
  global logger
  logger = cocotb.log.getChild("core_tb")
  set_logger(logger)

  logger.info("Checking golden model")
  check_golden_consistency()

  logger.info("Starting clock")
  Clock(
    signal = dut.clk,
    period = 2,
    unit = "step"
  ).start()

  logger.info("Performing reset")
  await reset(dut)

  await run_output_stationary(dut)
  await run_weight_stationary(dut)

  # The two passes use disjoint memory regions, so the OS result must have
  # survived the mode switch and the whole WS pass untouched
  logger.info("Re-checking output-stationary result after the WS pass")
  check_final_output(dut)