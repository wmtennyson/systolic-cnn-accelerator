import logging
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from helpers import *
  

@cocotb.test()
async def test_core(dut):
  global logger
  logger = cocotb.log.getChild("core_tb")
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