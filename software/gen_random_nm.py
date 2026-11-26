"""
Random 2:4 structured-sparse stimulus generator for core_tb.v (alpha_nm)

Same as gen_random.py, but the weights follow a 2:4 pattern: in every group of
4 consecutive input channels (for each kij and output channel) at most 2 weights
are nonzero. Writes input.txt, weight.txt and psum.txt:

  * input.txt : 36 lines (6x6 nij), each = row7 ... row0, 4-bit unsigned (same as gen_random.py)
  * weight.txt: 72 lines (9 kij x 8 cols), one of two formats:
      compressed (default), for the SPARSE_NM=1 build:
        each line = row3 ... row0 of the 4-row array, one byte per row = {2'b00, idx[1:0], w[3:0]}
        array rows 2g and 2g+1 hold the 2 kept weights of channel group g (channels 4g..4g+3),
        lower channel index on the even row; idx = channel within the group.
        A group with fewer than 2 nonzeros is padded with w = 0 at an unused idx.
      dense (--dense), for the SPARSE_NM=0 build:
        same format as gen_random.py (row7 ... row0, 4-bit 2's complement), zeros included
  * psum.txt  : 16 lines (4x4 onij), each = col7 ... col0, 16-bit 2's complement, after ReLU

Both formats come from the same weights, so input.txt and psum.txt are identical for a
given seed. Running --dense on the dense build checks the masking and expected psums
without the new RTL; the compressed file then checks the compressed array.

Header lines contain no spaces: core_tb.v skips them with $fscanf("%s"), one word each.

Usage:  python3 gen_random_nm.py <out_dir> <seed> [--dense]
"""
import sys
import numpy as np

ROW, COL = 8, 8                 # input channels, output channels (array cols)
NIJ, ONIJ, KIJ = 36, 16, 9      # 6x6 padded input, 4x4 output, 3x3 kernel
IN_W, OUT_W = 6, 4              # padded input width, output width
M, N = 4, 2                     # N:M sparsity: keep at most N of every M input channels
GROUPS = ROW // M               # channel groups (2), each feeds N array rows
P_EXTRA_ZERO = 0.1              # chance a group keeps only 1 nonzero (tests the w = 0 padding)

args = [a for a in sys.argv[1:] if a != '--dense']
dense_out = '--dense' in sys.argv[1:]
if len(args) != 2:
    sys.exit("usage: python3 gen_random_nm.py <out_dir> <seed> [--dense]")
out_dir, seed = args[0], int(args[1])
rng = np.random.default_rng(seed)

X = rng.integers(1, 16, size=(NIJ, ROW))
W = rng.integers(-7, 8, size=(KIJ, COL, ROW))

# 2:4 mask along input channels: zero M-N random positions per group,
# and sometimes one more so groups with < N nonzeros are covered
for k in range(KIJ):
    for c in range(COL):
        for g in range(GROUPS):
            drop = rng.choice(M, size=M - N, replace=False)
            W[k, c, M * g + drop] = 0
            if rng.random() < P_EXTRA_ZERO:
                kept = [i for i in range(M) if i not in drop]
                W[k, c, M * g + rng.choice(kept)] = 0

grouped = W.reshape(KIJ, COL, GROUPS, M)
assert ((grouped != 0).sum(axis=3) <= N).all(), "2:4 pattern violated"

# Integer conv: output (oy, ox) uses input position (oy+ky, ox+kx) for kernel tap (ky, kx)
psum = np.zeros((ONIJ, COL), dtype=np.int64)
for o in range(ONIJ):
    oy, ox = divmod(o, OUT_W)
    for k in range(KIJ):
        ky, kx = divmod(k, 3)
        psum[o] += W[k] @ X[(oy + ky) * IN_W + (ox + kx)]
relu = np.maximum(psum, 0)
assert np.abs(psum).max() < 2**15, "psum overflows 16 bits"

b2 = lambda v: format(int(v) & 0x3, '02b')
b4 = lambda v: format(int(v) & 0xF, '04b')
b16 = lambda v: format(int(v) & 0xFFFF, '016b')


def compress(w):
    """Dense weights of one (kij, col), shape (ROW,) -> list of (idx, w) per array row 0..N*GROUPS-1."""
    entries = []
    for g in range(GROUPS):
        nz = [i for i in range(M) if w[M * g + i] != 0]
        pad = [i for i in range(M) if i not in nz][:N - len(nz)]   # unused idx, weight 0
        for i in sorted(nz + pad):                                 # lower channel -> even row
            entries.append((i, w[M * g + i]))
    return entries


def decompress(entries):
    """Inverse of compress, used to check the packing."""
    w = np.zeros(ROW, dtype=np.int64)
    for r, (i, v) in enumerate(entries):
        w[M * (r // N) + i] += v
    return w


with open(f'{out_dir}/input.txt', 'w') as f:
    f.write('#time0row7[msb-lsb],time0row6[msb-lst],....,time0row0[msb-lst]#\n')
    f.write('#time1row7[msb-lsb],time1row6[msb-lst],....,time1row0[msb-lst]#\n')
    f.write('#................#\n')
    for n in range(NIJ):
        f.write(''.join(b4(X[n, r]) for r in reversed(range(ROW))) + '\n')

with open(f'{out_dir}/weight.txt', 'w') as f:
    if dense_out:
        f.write('#col0row7[msb-lsb],...,col0row0[msb-lsb]#\n')
        f.write('#col1row7[msb-lsb],...,col1row0[msb-lsb]#\n')
        f.write('#................#\n')
        for k in range(KIJ):
            for c in range(COL):
                f.write(''.join(b4(W[k, c, r]) for r in reversed(range(ROW))) + '\n')
    else:
        f.write('#2:4_compressed:col0_arrayrow3..arrayrow0,byte={00,idx,w}#\n')
        f.write('#rows2g,2g+1=kept_weights_of_channels4g..4g+3,lower_ch_on_even_row#\n')
        f.write('#................#\n')
        for k in range(KIJ):
            for c in range(COL):
                entries = compress(W[k, c])
                assert (decompress(entries) == W[k, c]).all(), "compress/decompress mismatch"
                f.write(''.join('00' + b2(i) + b4(v) for i, v in reversed(entries)) + '\n')

with open(f'{out_dir}/psum.txt', 'w') as f:
    f.write('#time0col7[msb-lsb],time0col6[msb-lst],....,time0col0[msb-lst]#\n')
    f.write('#time1col7[msb-lsb],time1col6[msb-lst],....,time1col0[msb-lst]#\n')
    f.write('#................#\n')
    for o in range(ONIJ):
        f.write(''.join(b16(relu[o, c]) for c in reversed(range(COL))) + '\n')

nz_per_group = (grouped != 0).sum(axis=3)
print(f'seed {seed}: wrote {out_dir}/input.txt, weight.txt ({"dense" if dense_out else "2:4 compressed"}), psum.txt '
      f'({int((psum < 0).sum())} of {psum.size} psums negative before ReLU, '
      f'{int((nz_per_group < N).sum())} of {nz_per_group.size} groups with < {N} nonzeros)')
