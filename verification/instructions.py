import cocotb
from cocotb.types import LogicArray
# These functions return logic vectors encoding the associated instruction

def bitvecshft(bit, width, loc):
  return (bit & (2**(width) - 1)) << loc

def _load(b: int) -> int:
  return bitvecshft(b, 1, 0)

def _execute(b: int) -> int:
  return bitvecshft(b, 1, 1)

def _l0_wr(b: int) -> int:
  return bitvecshft(b, 1, 2)

def _l0_rd(b: int) -> int:
  return bitvecshft(b, 1, 3)

def _sfu_wb(b: int) -> int:
  return bitvecshft(b, 1, 4)

def _ofifo_rd(b: int) -> int:
  return bitvecshft(b, 1, 6)

def _xmem_addr(b: int) -> int:
  return bitvecshft(b, 11, 7)

def _xmem_wen(b: int) -> int:
  # CAREFUL: active-low
  return bitvecshft(b, 1, 18)

def _xmem_cen(b: int) -> int:
  # CAREFUL: active-low
  return bitvecshft(b, 1, 19)

def _pmem_addr(b: int) -> int:
  return bitvecshft(b, 11, 20)

def _pmem_wen(b: int) -> int:
  # CAREFUL: active-low
  return bitvecshft(b, 1, 31)

def _pmem_cen(b: int) -> int:
  # CAREFUL: active-low
  return bitvecshft(b, 1, 32)

def _acc(b: int) -> int:
  return bitvecshft(b, 1, 33)

def _to_inst(bitvec: int) -> LogicArray:
  return LogicArray(bitvec, range = 34)
  
def xmem_idle() -> LogicArray:
  return _to_inst(_xmem_wen(1) | _xmem_cen(1))

def pmem_idle() -> LogicArray:
  return _to_inst(_pmem_wen(1) | _pmem_cen(1))

def mem_idle() -> LogicArray:
  return xmem_idle() | pmem_idle()

def idle() -> LogicArray:
  return mem_idle()
  
def load_xmem(addr: int) -> LogicArray:
  return _to_inst(
    _xmem_addr(addr) |
    _xmem_wen(0) | _xmem_cen(0) # while explicit here, note this is default
  )

def read_xmem(addr: int) -> LogicArray:
  return _to_inst(
    _xmem_addr(addr) |
    _xmem_wen(1) | _xmem_cen(0)
  )
  
def load_l0() -> LogicArray:
  return _to_inst(
    _l0_wr(1)
  )

def load_mac_arr() -> LogicArray:
  return _to_inst(
    _load(1) | _l0_rd(1)
  )

def execute() -> LogicArray:
  return _to_inst(
    _execute(1) | _l0_rd(1)
  )
  
def read_ofifo() -> LogicArray:
  return _to_inst(
    _ofifo_rd(1)
  )
  
def load_pmem(addr: int) -> LogicArray:
  return _to_inst(
    _pmem_addr(addr) |
    _pmem_wen(0) | _pmem_cen(0)
  )
  
def read_pmem(addr: int) -> LogicArray:
  return _to_inst(
    _pmem_addr(addr) |
    _pmem_wen(1) | _pmem_cen(0)
  )

def accumulate() -> LogicArray:
  return _to_inst(
    _acc(1)
  )
  
def read_sfu_output() -> LogicArray:
  return _to_inst(
    _sfu_wb(1)
  )