from pathlib import Path

from cocotb.triggers import RisingEdge
from cocotb.types import LogicArray

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

import instructions as inst


def im2col(x, kernel_size):
  kH, kW = (kernel_size, kernel_size)

  if x.ndim == 3:
    x = np.reshape(x, (1,) + x.shape)

  N, C, H, W = x.shape

  windows = sliding_window_view(x, (kH, kW), axis=(2, 3))

  cols = windows.transpose(1, 4, 5, 0, 2, 3).reshape(C * kH * kW, -1)
  return cols


logger = None

def set_logger(new_logger):
  global logger
  logger = new_logger

bw = 4
psum_bw = 16
row = 8
col = 8

n_steps = 9 * row            # reduction length: 9 taps x 8 input channels
n_pix = 16                   # 4x4 output pixels
n_tiles = n_pix // row       # output pixels are mapped onto array rows, 8 per tile

# hardware/output_stationary/helpers.py -> repo root is two levels above this dir
software_dir = Path(__file__).resolve().parents[2] / 'software'
w_signed = np.int8(np.load(software_dir / 'w_int.npy'))          # [oc, ic, ki, kj]
w_int = np.uint8(w_signed) % (2**bw)                             # same, 4-bit two's complement
x_int = np.uint8(np.load(software_dir / 'x_int.npy'))            # [ic, i, j], unsigned
psum_int = np.int64(np.load(software_dir / 'psum_int.npy'))      # [oc, i, j], post-ReLU


x_padded = np.pad(x_int, ((0, 0), (1, 1), (1, 1)))

def golden_raw_psum():
  """Pre-ReLU psums, shape [oc, pixel] with pixel = oi*4 + oj, signed."""
  out = np.zeros((col, n_pix), dtype=np.int64)
  for oc in range(col):
    for p in range(n_pix):
      oi, oj = divmod(p, 4)
      total = 0
      for ic in range(row):
        for ki in range(3):
          for kj in range(3):
            total += int(x_padded[ic, oi + ki, oj + kj]) * int(w_signed[oc, ic, ki, kj])
      out[oc, p] = total
  return out

raw_golden = golden_raw_psum()


def check_golden_consistency():
  """The notebook's post-ReLU psums must equal ReLU of our direct computation."""
  expected = psum_int.reshape(col, n_pix)
  assert np.array_equal(np.maximum(raw_golden, 0), expected), \
    "golden model disagrees with software/psum_int.npy"
  # A test that never sees a negative psum cannot tell ReLU from a wire
  assert (raw_golden < 0).any(), "no negative psums: ReLU path is not exercised"


def array_to_LogicArray(arr, size):
  bitstring = ''.join([str(LogicArray(int(x), size)) for x in arr[::-1]])
  return LogicArray(bitstring)

def word_to_fields(value, n, size, signed=False):
  """Split a packed memory word into n fields of `size` bits, field 0 = LSBs."""
  v = int(value.to_unsigned())          # raises on X/Z, which is what we want
  fields = []
  for i in range(n):
    f = (v >> (size * i)) & (2**size - 1)
    if signed and f >= 2**(size - 1):
      f -= 2**size
    fields.append(f)
  return fields


async def issue(dut, instruction, sfu_wb=0):
  """Apply one instruction (plus the sfu_wb port) for exactly one clock cycle."""
  dut.inst.value = instruction
  dut.sfu_wb.value = sfu_wb
  await RisingEdge(dut.clk)

async def idle_cycles(dut, n):
  for _ in range(n):
    await issue(dut, inst.idle())


# Value driven on core.mode_os (1 = output stationary, 0 = weight stationary)
mode_os_value = 1

async def reset(dut):
  dut.inst.value = inst.idle()
  dut.D_xmem.value = 0
  dut.mode_os.value = mode_os_value
  dut.sfu_wb.value = 0

  dut.reset.value = 1
  for _ in range(8):
    # The extra cycles of reset flush the instructions already in the array
    await RisingEdge(dut.clk)
  dut.reset.value = 0

async def set_mode(dut, output_stationary):
  """Switch dataflow at runtime. The reset flushes the array's mode-specific
  state (instruction chain, tile registers, FIFO pointers); memories are kept."""
  global mode_os_value
  mode_os_value = 1 if output_stationary else 0
  await reset(dut)


xmem_act_base = 0x000
xmem_wgt_base = 0x400
pmem_psum_base = 0x000
pmem_relu_base = 0x400

# Steps staged into the 64-deep FIFOs at a time (single SRAM read port means
# activations and weights must be staged one after the other)
os_chunk = 36
assert os_chunk <= 64


def build_act_words():
  cols = im2col(x_padded, 3)                      # [72, 16]
  assert cols.shape == (n_steps, n_pix)
  words = []
  for t in range(n_tiles):
    for k in range(n_steps):
      # nibble r = activation of output pixel (t*8 + r) at step k
      words.append(array_to_LogicArray(cols[k, t*row:(t+1)*row], bw))
  return words

def build_wgt_words():
  w_mat = np.reshape(w_int, (col, n_steps))        # [oc, step]
  # nibble c = weight of output channel c at step k
  return [array_to_LogicArray(w_mat[:, k], bw) for k in range(n_steps)]


async def write_words_to_xmem(dut, base, words):
  for idx, word in enumerate(words):
    dut.D_xmem.value = word
    await issue(dut, inst.load_xmem(base + idx) | inst.pmem_idle())
  dut.D_xmem.value = 0
  await issue(dut, inst.idle())

async def load_xint_into_xmem(dut):
  await write_words_to_xmem(dut, xmem_act_base, build_act_words())

  # Back-door check, expected nibbles built by direct indexing (not im2col)
  mem = dut.xmem_inst.memory
  for t in range(n_tiles):
    for k in range(n_steps):
      ic, kij = divmod(k, 9)
      ki, kj = divmod(kij, 3)
      expected = []
      for r in range(row):
        oi, oj = divmod(t*row + r, 4)
        expected.append(int(x_padded[ic, oi + ki, oj + kj]))
      got = word_to_fields(mem[xmem_act_base + t*n_steps + k].value, row, bw)
      assert got == expected, f"act word tile {t} step {k}: {got} != {expected}"

async def load_wint_into_xmem(dut):
  await write_words_to_xmem(dut, xmem_wgt_base, build_wgt_words())

  mem = dut.xmem_inst.memory
  for k in range(n_steps):
    ic, kij = divmod(k, 9)
    ki, kj = divmod(kij, 3)
    expected = [int(w_signed[oc, ic, ki, kj]) for oc in range(col)]
    got = word_to_fields(mem[xmem_wgt_base + k].value, col, bw, signed=True)
    assert got == expected, f"weight word step {k}: {got} != {expected}"


async def stage_into_buffer(dut, base, n, wr_inst):
  """Copy n xmem words into the L0 or weight buffer (wr_inst picks which).

  The SRAM data appears one cycle after the read, so the buffer write for a
  word is issued one cycle after its read.
  """
  for idx in range(n):
    if idx == 0:
      await issue(dut, inst.read_xmem(base + idx) | inst.pmem_idle())
    else:
      await issue(dut, inst.read_xmem(base + idx) | wr_inst | inst.pmem_idle())
  await issue(dut, wr_inst | inst.mem_idle())
  await issue(dut, inst.idle())

async def execute_steps(dut, n):
  # ACC command plus L0 and weight-buffer pops in the same cycle; the skew of
  # the activations (L0), weights (weight buffer) and the ACC command (mac_array)
  # are matched, so nothing is offset here.
  for _ in range(n):
    await issue(dut, inst.os_acc_step() | inst.mem_idle())
  await issue(dut, inst.idle())

def check_accumulators(dut, t):
  """Back-door check of every PE accumulator before draining."""
  mac_array = dut.corelet_inst.mac_array_inst
  for r in range(row):
    for c in range(col):
      tile = mac_array.row_num[r+1].mac_row_instance.col_num[c+1].mac_tile_instance
      got = word_to_fields(tile.c_q.value, 1, psum_bw, signed=True)[0]
      expected = int(raw_golden[c, t*row + r])
      assert got == expected, f"tile {t} PE(row {r}, col {c}): {got} != {expected}"

async def run_tile_compute(dut, t):
  for start in range(0, n_steps, os_chunk):
    n = min(os_chunk, n_steps - start)
    await stage_into_buffer(dut, xmem_act_base + t*n_steps + start, n, inst.load_l0())
    await stage_into_buffer(dut, xmem_wgt_base + start, n, inst.load_weight_buf())
    await execute_steps(dut, n)
  # Last ACC must reach the bottom-right PE and update its accumulator before
  # the drain starts. The drain is a broadcast, so it would overtake ACCs that
  # are still skewing down the rows.
  await idle_cycles(dut, row + col + 2)

async def drain_array(dut):
  # One DRAIN cycle per array row: the accumulators shift south one row per
  # cycle (zeros enter at the top) and the bottom row feeds the OFIFO.
  for _ in range(row):
    await issue(dut, inst.os_drain() | inst.mem_idle())
  # Columns drain staggered by one cycle per column
  await idle_cycles(dut, col + 4)

async def store_ofifo_to_pmem(dut, t):
  # OFIFO words come out bottom row first, i.e. pixel order is reversed
  def addr(n):
    return pmem_psum_base + t*row + (row - 1 - n)

  await issue(dut, inst.read_ofifo() | inst.mem_idle())
  for n in range(row):
    if n == row - 1:
      await issue(dut, inst.load_pmem(addr(n)) | inst.xmem_idle())
    else:
      await issue(dut, inst.read_ofifo() | inst.load_pmem(addr(n)) | inst.xmem_idle())
  await issue(dut, inst.idle())
  assert dut.ofifo_valid.value == False

def check_raw_psums(dut, t):
  mem = dut.pmem_inst.memory
  for r in range(row):
    p = t*row + r
    got = word_to_fields(mem[pmem_psum_base + p].value, col, psum_bw, signed=True)
    expected = [int(raw_golden[c, p]) for c in range(col)]
    assert got == expected, f"raw psum pixel {p}: {got} != {expected}"


async def sfu_relu_all(dut):
  """ReLU every pixel through the SFU: accumulate one word onto zero, write back."""
  for p in range(n_pix):
    await reset(dut)         # clears the SFU accumulators
    await issue(dut, inst.read_pmem(pmem_psum_base + p) | inst.xmem_idle())
    await issue(dut, inst.accumulate() | inst.mem_idle())
    await issue(dut, inst.load_pmem(pmem_relu_base + p) | inst.xmem_idle(), sfu_wb=1)
    await issue(dut, inst.idle())

def check_final_output(dut, relu_base=pmem_relu_base):
  expected_all = psum_int.reshape(col, n_pix)
  mem = dut.pmem_inst.memory
  for p in range(n_pix):
    got = word_to_fields(mem[relu_base + p].value, col, psum_bw)
    expected = [int(expected_all[c, p]) for c in range(col)]
    assert got == expected, \
      f"output pixel {p}: {[hex(v) for v in got]} != {[hex(v) for v in expected]}"


ws_xmem_act_base = 0x200
ws_xmem_wgt_base = 0x600
ws_pmem_psum_base = 0x200
ws_pmem_relu_base = 0x600
ws_len_nij = 36


def build_ws_act_words():
  words = []
  for q in range(ws_len_nij):
    qi, qj = divmod(q, 6)
    words.append(array_to_LogicArray(x_padded[:, qi, qj], bw))
  return words

def build_ws_wgt_words():
  words = []
  for kij in range(9):
    ki, kj = divmod(kij, 3)
    for oc in range(col):
      words.append(array_to_LogicArray(w_int[oc, :, ki, kj], bw))
  return words


async def ws_load_data_into_xmem(dut):
  await write_words_to_xmem(dut, ws_xmem_act_base, build_ws_act_words())
  await write_words_to_xmem(dut, ws_xmem_wgt_base, build_ws_wgt_words())

  mem = dut.xmem_inst.memory
  for q in range(ws_len_nij):
    qi, qj = divmod(q, 6)
    expected = [int(x_padded[ic, qi, qj]) for ic in range(row)]
    got = word_to_fields(mem[ws_xmem_act_base + q].value, row, bw)
    assert got == expected, f"WS act word {q}: {got} != {expected}"
  for kij in range(9):
    ki, kj = divmod(kij, 3)
    for oc in range(col):
      expected = [int(w_signed[oc, ic, ki, kj]) for ic in range(row)]
      got = word_to_fields(mem[ws_xmem_wgt_base + kij*col + oc].value, row, bw, signed=True)
      assert got == expected, f"WS weight word kij {kij} oc {oc}: {got} != {expected}"


async def ws_load_weights_into_array(dut, kij):
  # Weights go xmem -> L0 -> array west port; word k lands in column k
  await stage_into_buffer(dut, ws_xmem_wgt_base + kij*col, col, inst.load_l0())
  for _ in range(col):
    await issue(dut, inst.load_mac_arr() | inst.mem_idle())
  # allow the weights to reach the far tiles
  await idle_cycles(dut, row*col//2)

def ws_check_pe_weights(dut, kij):
  ki, kj = divmod(kij, 3)
  mac_array = dut.corelet_inst.mac_array_inst
  for r in range(row):          # array row = input channel
    for c in range(col):        # array column = output channel
      tile = mac_array.row_num[r+1].mac_row_instance.col_num[c+1].mac_tile_instance
      got = word_to_fields(tile.b_q.value, 1, bw, signed=True)[0]
      expected = int(w_signed[c, r, ki, kj])
      assert got == expected, f"kij {kij} PE(row/ic {r}, col/oc {c}): {got} != {expected}"

async def ws_execute(dut):
  for _ in range(ws_len_nij):
    await issue(dut, inst.execute() | inst.mem_idle())
  await issue(dut, inst.idle())

async def ws_drain_ofifo_to_pmem(dut, kij):
  await issue(dut, inst.read_ofifo() | inst.mem_idle())
  for q in range(ws_len_nij):
    addr = ws_pmem_psum_base + kij*ws_len_nij + q
    if q == ws_len_nij - 1:
      await issue(dut, inst.load_pmem(addr) | inst.xmem_idle())
    else:
      await issue(dut, inst.read_ofifo() | inst.load_pmem(addr) | inst.xmem_idle())
  await issue(dut, inst.idle())
  assert dut.ofifo_valid.value == False

def ws_check_pass_psums(dut, kij):
  """Per-tap psums of all 36 padded positions, before any SFU accumulation."""
  ki, kj = divmod(kij, 3)
  mem = dut.pmem_inst.memory
  for q in range(ws_len_nij):
    qi, qj = divmod(q, 6)
    expected = [sum(int(x_padded[ic, qi, qj]) * int(w_signed[oc, ic, ki, kj])
                    for ic in range(row)) for oc in range(col)]
    got = word_to_fields(mem[ws_pmem_psum_base + kij*ws_len_nij + q].value,
                         col, psum_bw, signed=True)
    assert got == expected, f"WS kij {kij} position {q}: {got} != {expected}"

async def ws_sfp_accumulate(dut, yi, yj):
  # Sum the 9 taps' psums for one output pixel, then ReLU + write back
  for ki in range(3):
    for kj in range(3):
      kij = ki*3 + kj
      addr = ws_pmem_psum_base + kij*ws_len_nij + (yi+ki)*6 + (yj+kj)
      if kij == 0:
        await issue(dut, inst.read_pmem(addr) | inst.xmem_idle())
      else:
        await issue(dut, inst.read_pmem(addr) | inst.accumulate() | inst.xmem_idle())
  await issue(dut, inst.accumulate() | inst.mem_idle())
  await issue(dut, inst.load_pmem(ws_pmem_relu_base + yi*4 + yj) | inst.xmem_idle(), sfu_wb=1)
  await issue(dut, inst.idle())