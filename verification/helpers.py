import logging
from pathlib import Path

import cocotb
from cocotb.triggers import RisingEdge
from cocotb.types import LogicArray

import numpy as np


import instructions

logger = None


sofware_dir = Path(__file__).resolve().parent.parent / 'software'
w_int = np.uint8(np.load(sofware_dir / 'w_int.npy'))
x_int = np.int8(np.load(sofware_dir / 'x_int.npy'))
y = np.load(sofware_dir / 'next_in.npy')


async def reset(dut):
  dut.inst.value = instructions.idle()
  dut.D_xmem.value = 0
  
  dut.reset.value = 1
  for _ in range(8):
    # The extra cycles of reset flush the instructions already in the array
    await RisingEdge(dut.clk)
  dut.reset.value = 0

def array_to_LogicArray(arr, size):
  bitstring = ''.join([str(LogicArray(int(x), size)) for x in arr[::-1]])
  return LogicArray(bitstring)

xmem_act_base = 0x000
xmem_wgt_base = 0x400

async def load_xint_into_xmem(dut):
  padded_input = np.pad(x_int, {0: 0, 1: (1,1), 2: (1,1)})
  flat_input = np.reshape(padded_input, (8, -1))
  xmem_input = flat_input.T
  (x_len, cin_len) = xmem_input.shape
  # Check that input matrix has expected shape
  assert(x_len == 36)
  assert(cin_len == 8)
  
  words = [array_to_LogicArray(arr, 4) for arr in xmem_input]
  
  # Begin loading routine
  for xij, word in enumerate(words):
    dut.D_xmem.value = word
    dut.inst.value = instructions.load_xmem(xmem_act_base + xij) | instructions.pmem_idle()
    await RisingEdge(dut.clk)
  dut.D_xmem.value = 0
  dut.inst.value = 0
  await RisingEdge(dut.clk)
  
  # Check that written memory is corect
  mem = dut.xmem_inst.memory
  for xij, word in enumerate(words):
    assert(mem[xij].value == word)
  

  