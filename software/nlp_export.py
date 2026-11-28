"""
Export helpers for the NLP mapping (alpha_ctrl): write one sentence's ff2 layer in the file
format of software/gen_random_tiled.py, which hardware/alpha_ctrl/verilog/core_tiled_tb.v reads.

The mapped layer is a 64 -> 64 linear layer over T tokens: IC = OC = 64, K = 1, H = 1, W = T.
  input.txt   n_it*T lines   channels of input tile `it` for token t     (row-1 .. 0, 4-bit unsigned)
  weight.txt  8*n_it*8 lines weight line ((ot*n_it + it)*1 + 0)*8 + c     (dense or 2:4 compressed)
  psum.txt    8*T lines      ReLU(psum) of output tile `ot` for token t   (col7 .. col0, 16-bit)
  plusargs.txt "+IC=64 +OC=64 +K=1 +H=1 +W=T"
`row` = channels per input tile = the core's `row` parameter: 8 (dense, or 2:4 on the 4x8 array)
or 16 (2:4 on the 8x8 compressed array, use nm=True). Header lines contain no spaces.

Hardware results come back in the same format as psum.txt (read_psum_file), so the
feed-back code works on psum.txt itself as a stand-in before the hardware runs.
"""
import os
import numpy as np

COL = 8          # output channels per tile (array columns)
M, N = 4, 2      # 2:4

b2 = lambda v: format(int(v) & 0x3, '02b')
b4 = lambda v: format(int(v) & 0xF, '04b')
b16 = lambda v: format(int(v) & 0xFFFF, '016b')


def _np(t):
    return t.detach().cpu().numpy() if hasattr(t, 'detach') else np.asarray(t)


def check_layer(x_int, w_int, psum_int):
    """Range checks for the hardware: x 0..15, w -8..7, |psum| < 2^15."""
    assert x_int.min() >= 0 and x_int.max() <= 15, f'activations out of 4-bit unsigned range: {x_int.min()}..{x_int.max()}'
    assert w_int.min() >= -8 and w_int.max() <= 7, f'weights out of 4-bit signed range: {w_int.min()}..{w_int.max()}'
    assert np.abs(psum_int).max() < 2**15, 'psum overflows 16-bit signed'


def check_nm(w_int):
    """True if every group of 4 consecutive input channels has <= 2 non-zero weights."""
    oc, ic = w_int.shape
    return bool(((w_int.reshape(oc, ic // M, M) != 0).sum(-1) <= N).all())


def compress(w, row):
    """Dense weights of one tile (row,) -> [(idx, w)] for array rows 0..row/2-1 (lower channel on the even row)."""
    entries = []
    for g in range(row // M):
        nz = [i for i in range(M) if w[M * g + i] != 0]
        assert len(nz) <= N, 'weights are not 2:4'
        pad = [i for i in range(M) if i not in nz][:N - len(nz)]
        for i in sorted(nz + pad):
            entries.append((i, w[M * g + i]))
    return entries


def write_weight(path, w_int, row=8, nm=False):
    """w_int [OC, IC] integer weights."""
    w_int = np.rint(_np(w_int)).astype(np.int64)
    oc, ic = w_int.shape
    n_it, n_ot = ic // row, oc // COL
    with open(path, 'w') as f:
        f.write(f'#nlp_ff2_IC{ic}_OC{oc}_K1:line=w_base+((ot*n_it+it)*1+0)*8+c#\n')
        f.write(f'#2:4_compressed:arrayrow{row//2-1}..arrayrow0,byte={{00,idx,w}}#\n' if nm
                else f'#dense:row{row-1}[msb-lsb],...,row0[msb-lsb]#\n')
        f.write('#................#\n')
        for ot in range(n_ot):
            for it in range(n_it):
                for c in range(COL):
                    w = w_int[ot * COL + c, it * row:(it + 1) * row]
                    if nm:
                        f.write(''.join('00' + b2(i) + b4(v) for i, v in reversed(compress(w, row))) + '\n')
                    else:
                        f.write(''.join(b4(w[r]) for r in reversed(range(row))) + '\n')


def write_sentence(out_dir, x_int, psum_int, row=8):
    """x_int [IC, T] (0..15), psum_int [OC, T] (pre-ReLU integer sums) for one sentence."""
    os.makedirs(out_dir, exist_ok=True)
    x_int = np.rint(_np(x_int)).astype(np.int64)
    psum_int = np.rint(_np(psum_int)).astype(np.int64)
    ic, T = x_int.shape
    oc = psum_int.shape[0]
    assert T <= 64, f'{T} tokens > 64 (L0 / OFIFO depth)'
    n_it, n_ot = ic // row, oc // COL
    relu = np.maximum(psum_int, 0)
    with open(f'{out_dir}/input.txt', 'w') as f:
        f.write(f'#nlp_ff2_in_T{T}:line=x_base+it*T+t#\n')
        f.write(f'#row{row-1}[msb-lsb],...,row0[msb-lsb]_of_input_tile_it#\n')
        f.write('#................#\n')
        for it in range(n_it):
            for t in range(T):
                f.write(''.join(b4(x_int[it * row + r, t]) for r in reversed(range(row))) + '\n')
    with open(f'{out_dir}/psum.txt', 'w') as f:
        f.write('#line=out_base+ot*T+t#\n')
        f.write('#col7[msb-lsb],...,col0[msb-lsb]_of_output_tile_ot,after_ReLU#\n')
        f.write('#................#\n')
        for ot in range(n_ot):
            for t in range(T):
                f.write(''.join(b16(relu[ot * COL + c, t]) for c in reversed(range(COL))) + '\n')
    with open(f'{out_dir}/plusargs.txt', 'w') as f:
        f.write(f'+IC={ic} +OC={oc} +K=1 +H=1 +W={T}\n')


def read_psum_file(path, T, oc=64):
    """Read psum.txt-format results (3 header lines, then oc/8*T lines) -> int array [oc, T]."""
    with open(path) as f:
        lines = [ln.strip() for ln in f if ln.strip() and not ln.startswith('#')]
    n_ot = oc // COL
    assert len(lines) >= n_ot * T, f'{path}: {len(lines)} lines, expected {n_ot * T}'
    out = np.zeros((oc, T), dtype=np.int64)
    for ot in range(n_ot):
        for t in range(T):
            ln = lines[ot * T + t]
            for c in range(COL):
                v = int(ln[(COL - 1 - c) * 16:(COL - c) * 16], 2)
                out[ot * COL + c, t] = v - (1 << 16) if v >= (1 << 15) else v
    return out
