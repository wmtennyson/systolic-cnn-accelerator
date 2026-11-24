from pathlib import Path

from cocotb.triggers import RisingEdge
from cocotb.types import LogicArray

import numpy as np


import instructions as inst

logger = None

def set_logger(new_logger):
  global logger
  logger = new_logger

bw = 4
psum_bw = 16
row = 8
col = 8


sofware_dir = Path(__file__).resolve().parent.parent / 'software'
w_int = np.uint8(np.int8(np.load(sofware_dir / 'w_int.npy'))) % (2**bw)
x_int = np.uint8(np.load(sofware_dir / 'x_int.npy'))
psum_int = np.load(sofware_dir / 'psum_int.npy')


async def reset(dut):
  dut.inst.value = inst.idle()
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
  flat_input = np.reshape(padded_input, (row, -1))
  xmem_input = flat_input.T
  (x_len, cin_len) = xmem_input.shape
  # Check that input matrix has expected shape
  assert x_len == 36
  assert cin_len == row
  
  words = [array_to_LogicArray(arr, bw) for arr in xmem_input]
  
  # Begin loading routine
  for xij, word in enumerate(words):
    dut.D_xmem.value = word
    dut.inst.value = inst.load_xmem(xmem_act_base + xij) | inst.pmem_idle()
    await RisingEdge(dut.clk)
  dut.D_xmem.value = 0
  dut.inst.value = inst.idle()
  await RisingEdge(dut.clk)
  
  # Check that written memory is corect
  mem = dut.xmem_inst.memory
  for xij, word in enumerate(words):
    assert mem[xij].value == word
  
async def load_wint_into_xmem(dut):
  # Does not check that xmem writes happen correctly
  flat_weights = np.reshape(w_int, (row, col, -1))
  xmem_weight = np.rollaxis(flat_weights, -1)
  # # Pytorch puts input dim on outer dimension, we want inner to load rows
  # xmem_weight = np.matrix_transpose(xmem_weight)
  xmem_weight = np.reshape(xmem_weight, (-1, row))
  assert xmem_weight.shape == (9*col, row)
  
  words = [array_to_LogicArray(arr, bw) for arr in xmem_weight]
  
  for kijcol, word in enumerate(words):
    dut.D_xmem.value = word
    dut.inst.value = inst.load_xmem(xmem_wgt_base + kijcol) | inst.pmem_idle()
    await RisingEdge(dut.clk)
  dut.D_xmem.value = 0
  dut.inst.value = inst.idle()
  await RisingEdge(dut.clk)
  
async def load_xmem_into_l0(dut, base, n):
  for idx in range(n):
    addr = base + idx
    if idx == 0:
      dut.inst.value = inst.read_xmem(addr) | inst.pmem_idle()
    else:
      dut.inst.value = inst.read_xmem(addr) | inst.load_l0() | inst.pmem_idle()
    await RisingEdge(dut.clk)
  dut.inst.value = inst.load_l0() | inst.mem_idle()
  await RisingEdge(dut.clk)
  dut.inst.value = inst.idle()
  await RisingEdge(dut.clk)
  
async def load_wint_into_l0(dut, kij):
  base = xmem_wgt_base + kij*col
  await load_xmem_into_l0(dut, base, col);
  
async def load_l0_weights_into_array(dut):
  for _ in range(col):
    dut.inst.value = inst.load_mac_arr()
    await RisingEdge(dut.clk)
  # allow weights to finish loading into array
  dut.inst.value = inst.idle()
  for _ in range(row*col//2):
    await RisingEdge(dut.clk)
    
def check_pe_weights(dut, kij):
  ki = kij // 3
  kj = kij %  3
  mac_array = dut.corelet_inst.mac_array_inst
  for r in range(row):
    mac_row = mac_array.row_num[r+1].mac_row_instance
    for c in range(col):
      mac_tile = mac_row.col_num[c+1].mac_tile_instance
      loaded_weight = mac_tile.b_q.value
      desired_weight = LogicArray(int(w_int[c,r,ki,kj]), bw)
      assert loaded_weight == desired_weight, f"mismatch at row {r}, col {c}"

async def load_xint_into_l0(dut):
  await load_xmem_into_l0(dut, xmem_act_base, 36)

async def execution_phase(dut):
  for _ in range(36):
    dut.inst.value = inst.execute() | inst.mem_idle()
    await RisingEdge(dut.clk)
  dut.inst.value = inst.idle()
  await RisingEdge(dut.clk)
  
pmem_psum_base = 0x000
pmem_relu_base = 0x400
  
async def drain_ofifo_to_pmem(dut, kij):
  dut.inst.value = inst.read_ofifo() | inst.mem_idle()
  await RisingEdge(dut.clk)
  for nij in range(36):
    addr = pmem_psum_base + (kij*36) + nij
    if nij == 35:
      dut.inst.value = inst.load_pmem(addr) | inst.xmem_idle()
    else:
      dut.inst.value = inst.read_ofifo() | inst.load_pmem(addr) | inst.xmem_idle()
    await RisingEdge(dut.clk)
  dut.inst.value = inst.idle()
  await RisingEdge(dut.clk)
  assert dut.ofifo_valid.value == False

async def sfp_accumulate(dut, yi, yj):
  for ki in range(3):
    for kj in range(3):
      kij = (ki*3) + kj
      padded_position = ((yi+ki)*6) + yj + kj
      addr = pmem_psum_base + (kij*36) + padded_position
      if ki == 0 and kj == 0:
        dut.inst.value = inst.read_pmem(addr) | inst.xmem_idle()
      else:
        dut.inst.value = inst.read_pmem(addr) | inst.accumulate() | inst.xmem_idle()
      await RisingEdge(dut.clk)
  dut.inst.value = inst.accumulate() | inst.mem_idle()
  await RisingEdge(dut.clk)
  addr = pmem_relu_base + (yi*4) + yj
  dut.inst.value =  inst.read_sfu_output(addr) | inst.xmem_idle()
  await RisingEdge(dut.clk)
  dut.inst.value = inst.idle()
  await RisingEdge(dut.clk)
  
def check_final_output(dut):
  psum_flat = np.reshape(psum_int, (8, -1))
  words = [array_to_LogicArray(arr, psum_bw) for arr in psum_flat.T]
  mem = dut.pmem_inst.memory
  for yij, word in enumerate(words):
    assert mem[pmem_relu_base + yij].value == word, f"{hex(mem[pmem_relu_base+yij].value)} != {hex(word)}"