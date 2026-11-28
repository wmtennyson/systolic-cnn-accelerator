"""
Random tiled-layer stimulus generator for core_tiled_tb.v (alpha_ctrl)

A conv layer with IC input channels (multiple of --row, default 8) and OC output channels
(multiple of 8), kernel K in {1, 3},
stride 1, output H x W. The input is the (H+K-1) x (W+K-1) grid, padding ring included,
filled with non-zero activations like gen_random.py (so a dropped or shifted pixel always
changes the answer). K = 1 is a linear layer: npix = H*W "tokens", one kij.

Tiling: input-channel tile `it` = channels ROW*it .. ROW*it+ROW-1 (ROW = --row, the core's `row`
parameter: 8, or 16 for the 8x8 compressed 2:4 array), output tile `ot` = 8*ot .. 8*ot+7.
Files (3 header lines each, no spaces in headers, as core_tb.v expects):

  input.txt  : n_it*npix lines, xmem order      x_base + it*npix + p   (row ROW-1 .. row0, 4-bit unsigned)
  weight.txt : n_ot*n_it*K*K*8 lines, xmem order w_base + ((ot*n_it + it)*K*K + kij)*8 + c
               dense (default): row ROW-1 .. row0, 4-bit 2's complement
               --nm           : 2:4 compressed, one byte per array row {2'b00, idx, w},
                                array rows ROW/2-1 .. 0 (same packing as gen_random_nm.py,
                                per tile of ROW channels)
  psum.txt   : n_ot*H*W lines, pmem order out_base + ot*H*W + o (col7 .. col0, 16-bit, after ReLU)
  plusargs.txt: the matching "+IC=.. +OC=.. +K=.. +H=.. +W=.." for the testbench

With the defaults (8 8 3 4 4) the layout is exactly that of input.txt / weight.txt / psum.txt
from the notebook, so the real data runs on core_tiled_tb.v unchanged.

Capacity checks (fixed memory map: activations xmem 0.., weights xmem 1024.., per-tile
psums pmem 0.. (reused for every output tile), outputs pmem 1024..):
  npix <= 64 (L0 and OFIFO depth), n_it*npix <= 1024, n_ot*n_it*K*K*8 <= 1024,
  n_it*K*K*npix <= 1024, n_ot*H*W <= 1024, and every final sum must fit 16-bit signed.

Usage:  python3 gen_random_tiled.py <out_dir> <seed> [--ic 8] [--oc 8] [--k 3] [--h 4] [--w 4] [--nm] [--row 8]
"""
import argparse
import numpy as np

COL = 8                             # channels per output tile (array columns)
M, N = 4, 2                         # 2:4 sparsity for --nm
X_LIM = W_LIM = P_LIM = O_LIM = 1024

ap = argparse.ArgumentParser()
ap.add_argument('out_dir')
ap.add_argument('seed', type=int)
ap.add_argument('--ic', type=int, default=8)
ap.add_argument('--oc', type=int, default=8)
ap.add_argument('--k', type=int, default=3, choices=[1, 3])
ap.add_argument('--h', type=int, default=4)
ap.add_argument('--w', type=int, default=4)
ap.add_argument('--nm', action='store_true', help='2:4 weights, compressed format (SPARSE_NM=1 build)')
ap.add_argument('--row', type=int, default=8, choices=[8, 16], help="input channels per tile (core's row)")
a = ap.parse_args()
ROW = a.row

IC, OC, K, H, W = a.ic, a.oc, a.k, a.h, a.w
assert IC % ROW == 0 and OC % COL == 0, f'IC must be a multiple of {ROW}, OC of {COL}'
n_it, n_ot, nkij = IC // ROW, OC // COL, K * K
HP, WP = H + K - 1, W + K - 1
npix, npix_out = HP * WP, H * W

checks = {
    f'npix = {npix} <= 64 (L0/OFIFO depth)': npix <= 64,
    f'activations n_it*npix = {n_it * npix} <= {X_LIM}': n_it * npix <= X_LIM,
    f'weights n_ot*n_it*K*K*8 = {n_ot * n_it * nkij * COL} <= {W_LIM}': n_ot * n_it * nkij * COL <= W_LIM,
    f'psums n_it*K*K*npix = {n_it * nkij * npix} <= {P_LIM}': n_it * nkij * npix <= P_LIM,
    f'outputs n_ot*H*W = {n_ot * npix_out} <= {O_LIM}': n_ot * npix_out <= O_LIM,
}
bad = [k for k, ok in checks.items() if not ok]
if bad:
    raise SystemExit('layer does not fit:\n  ' + '\n  '.join(bad))

rng = np.random.default_rng(a.seed)
X = rng.integers(1, 16, size=(npix, IC))                # padded input grid, all non-zero
Wt = rng.integers(-8, 8, size=(nkij, OC, IC))           # [kij, oc, ic]

if a.nm:  # 2:4 along input channels; sometimes keep only 1 (tests the w = 0 padding)
    for k in range(nkij):
        for c in range(OC):
            for g in range(IC // M):
                drop = rng.choice(M, size=M - N, replace=False)
                Wt[k, c, M * g + drop] = 0
                if rng.random() < 0.1:
                    kept = [i for i in range(M) if i not in drop]
                    Wt[k, c, M * g + rng.choice(kept)] = 0
    assert ((Wt.reshape(nkij, OC, IC // M, M) != 0).sum(axis=3) <= N).all()

# Integer conv: output (oy, ox) uses padded input (oy+ky, ox+kx) for tap (ky, kx)
psum = np.zeros((npix_out, OC), dtype=np.int64)
for o in range(npix_out):
    oy, ox = divmod(o, W)
    for k in range(nkij):
        ky, kx = divmod(k, K)
        psum[o] += Wt[k] @ X[(oy + ky) * WP + (ox + kx)]
assert np.abs(psum).max() < 2**15, 'final sum overflows 16-bit signed'
relu = np.maximum(psum, 0)

b2 = lambda v: format(int(v) & 0x3, '02b')
b4 = lambda v: format(int(v) & 0xF, '04b')
b16 = lambda v: format(int(v) & 0xFFFF, '016b')


def compress(w):
    """Dense weights of one tile (ROW,) -> [(idx, w)] for array rows 0..ROW/2-1 (lower channel on the even row)."""
    entries = []
    for g in range(ROW // M):
        nz = [i for i in range(M) if w[M * g + i] != 0]
        pad = [i for i in range(M) if i not in nz][:N - len(nz)]
        for i in sorted(nz + pad):
            entries.append((i, w[M * g + i]))
    return entries


with open(f'{a.out_dir}/input.txt', 'w') as f:
    f.write(f'#tiled_IC{IC}_OC{OC}_K{K}_H{H}_W{W}:line=x_base+it*npix+p#\n')
    f.write(f'#row{ROW-1}[msb-lsb],...,row0[msb-lsb]_of_input_tile_it#\n')
    f.write('#................#\n')
    for it in range(n_it):
        for p in range(npix):
            f.write(''.join(b4(X[p, it * ROW + r]) for r in reversed(range(ROW))) + '\n')

with open(f'{a.out_dir}/weight.txt', 'w') as f:
    f.write('#line=w_base+((ot*n_it+it)*K*K+kij)*8+c#\n')
    f.write(f'#2:4_compressed:arrayrow{ROW//2-1}..arrayrow0,byte={{00,idx,w}}#\n' if a.nm
            else f'#dense:row{ROW-1}[msb-lsb],...,row0[msb-lsb]#\n')
    f.write('#................#\n')
    for ot in range(n_ot):
        for it in range(n_it):
            for k in range(nkij):
                for c in range(COL):
                    w = Wt[k, ot * COL + c, it * ROW:(it + 1) * ROW]
                    if a.nm:
                        f.write(''.join('00' + b2(i) + b4(v) for i, v in reversed(compress(w))) + '\n')
                    else:
                        f.write(''.join(b4(w[r]) for r in reversed(range(ROW))) + '\n')

with open(f'{a.out_dir}/psum.txt', 'w') as f:
    f.write('#line=out_base+ot*H*W+o#\n')
    f.write('#col7[msb-lsb],...,col0[msb-lsb]_of_output_tile_ot,after_ReLU#\n')
    f.write('#................#\n')
    for ot in range(n_ot):
        for o in range(npix_out):
            f.write(''.join(b16(relu[o, ot * COL + c]) for c in reversed(range(COL))) + '\n')

with open(f'{a.out_dir}/plusargs.txt', 'w') as f:
    f.write(f'+IC={IC} +OC={OC} +K={K} +H={H} +W={W}\n')   # the build's row must equal --row

print(f'seed {a.seed}: IC={IC} OC={OC} K={K} out {H}x{W} row={ROW} ({n_it} in x {n_ot} out tiles, '
      f'npix={npix}, {"2:4 compressed" if a.nm else "dense"}), '
      f'{int((psum < 0).sum())} of {psum.size} sums negative, max |sum| {int(np.abs(psum).max())}')
