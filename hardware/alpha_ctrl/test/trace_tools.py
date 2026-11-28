"""
Tools for traces written by core_trace_mon.v (alpha_ctrl).

  python3 trace_tools.py phases <trace>          run-length summary of the control sequence
  python3 trace_tools.py diff <trace_a> <trace_b> cycle-exact comparison of the compute part
  python3 trace_tools.py cycles <trace>          length of the compute part in cycles

Add --first to start after the FIRST xmem write burst instead of the last one (needed for
the original core_tb.v, which writes each kij's weights into xmem inside the kij loop).

The "compute part" of a trace starts at the first reset-high cycle after the last xmem
write (so SRAM preloading by the testbench is excluded, however long it takes) and ends
at the last cycle with any control activity. Inside it, lines are compared without the
cycle number, so the two runs must issue the same control and see the same internal
events on every cycle.
"""
import re
import sys


def load(path):
    with open(path) as f:
        return [re.sub(r'^c=\d+ ', '', ln.rstrip('\n')) for ln in f if ln.startswith('c=')]


def active(ln):
    ctrl = ln.split('|')[1]
    return ('=1' in ctrl) or ('X:-' not in ln) or ('P:-' not in ln)


FIRST = False


def compute_part(lines):
    xw = [i for i, ln in enumerate(lines) if 'X:W' in ln]
    if FIRST:   # end of the first contiguous burst of xmem writes
        last_xw = xw[0]
        while last_xw + 1 in xw:
            last_xw += 1
    else:
        last_xw = xw[-1] if xw else -1
    start = next(i for i in range(last_xw + 1, len(lines)) if lines[i].startswith('rst=1'))
    end = max(i for i, ln in enumerate(lines) if active(ln) or ln.startswith('rst=1'))
    return start, lines[start:end + 1]


def sig(ln):
    """Control signature of a cycle: what the core is told to do, without addresses."""
    rst = ln[4]
    ctrl = re.findall(r'(\w+)=([01])', ln.split('|')[1])
    on = [k for k, v in ctrl if v == '1']
    x = re.search(r'X:(\S)', ln).group(1)
    p = re.search(r'P:(\S)', ln).group(1)
    parts = (['RST'] if rst == '1' else []) + on
    if x != '-': parts.append('xmem_' + x)
    if p != '-': parts.append('pmem_' + p)
    return ' '.join(parts) if parts else 'idle'


def phases(path):
    lines = load(path)
    start, part = compute_part(lines)
    print(f'compute part: {len(part)} cycles (trace cycles {start}..{start + len(part) - 1})')
    run, prev, first = 0, None, 0
    for i, ln in enumerate(part + [None]):
        s = sig(ln) if ln is not None else None
        if s != prev and prev is not None:
            addr = ''
            seg = part[first:i]
            a = [re.search(r'([XP]):([RW])(\d+)', l) for l in seg]
            a = [m for m in a if m]
            if a:
                addr = f'  {a[0].group(1)}{a[0].group(2)} {a[0].group(3)}..{a[-1].group(3)}'
            print(f'{start + first:6d} +{run:4d}  {prev}{addr}')
            run, first = 0, i
        prev, run = s, run + 1


def diff(pa, pb):
    _, a = compute_part(load(pa))
    _, b = compute_part(load(pb))
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            print(f'MISMATCH at compute cycle {i}:\n  A: {x}\n  B: {y}')
            sys.exit(1)
    if len(a) != len(b):
        print(f'MISMATCH: lengths differ ({len(a)} vs {len(b)} cycles)')
        sys.exit(1)
    print(f'IDENTICAL: {len(a)} compute cycles')


if __name__ == '__main__':
    if '--first' in sys.argv:
        sys.argv.remove('--first')
        FIRST = True
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'phases' and len(sys.argv) == 3:
        phases(sys.argv[2])
    elif cmd == 'diff' and len(sys.argv) == 4:
        diff(sys.argv[2], sys.argv[3])
    elif cmd == 'cycles' and len(sys.argv) == 3:
        print(len(compute_part(load(sys.argv[2]))[1]))
    else:
        sys.exit(__doc__)
