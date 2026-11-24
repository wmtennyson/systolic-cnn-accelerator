import cocotb
from cocotb.clock import Clock
from helpers import *
  

@cocotb.test()
async def test_core(dut):
  logger = cocotb.log.getChild("core_tb")
  set_logger(logger)
  logger.info("Getting PyTorch data ready")
  logger.info("Starting clock")
  Clock(
    signal = dut.clk, 
    period = 2, 
    unit = "step"
  ).start()
  logger.info("Performing reset")
  await reset(dut)
  
  logger.info("Testing activation load into xmem")
  await load_xint_into_xmem(dut)
  
  logger.info(f"Testing weight load into xmem")
  await load_wint_into_xmem(dut)
  
  logger.info("Beginning main processing loop")
  for kij in range(9):
    logger.debug(f"Loading kernel weights for {kij = }")
    await load_wint_into_l0(dut, kij)
    await load_l0_weights_into_array(dut)
    check_pe_weights(dut, kij)
    
    logger.debug("Loading activations into L0")
    await load_xint_into_l0(dut)
    
    logger.debug("Starting execution")
    await execution_phase(dut)
    
    logger.debug("Draining ofifos")
    await drain_ofifo_to_pmem(dut, kij)
    
    logger.debug("Resetting before next iteration")
    await reset(dut)
  
  logger.info("Beggining sfp accumulation loop")
  for yi in range(4):
    for yj in range(4):
      logger.debug("Resetting sfu accumulators")
      await reset(dut)
      
      logger.debug(f"Accumulating output pixel {yi = }, {yj = }")
      await sfp_accumulate(dut, yi, yj)
  
  logger.info("Checking final output")
  check_final_output(dut)