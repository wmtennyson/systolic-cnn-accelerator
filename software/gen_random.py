"""
Random stimulus generator for core_tb.v

Writes input.txt, weight.txt and psum.txt in exactly the same format as the
notebook, but with random data and an expected psum.txt computed here in numpy:

  * input.txt : 36 lines (6x6 nij), each = row7 ... row0, 4-bit unsigned
  * weight.txt: 72 lines (9 kij x 8 cols), each = row7 ... row0, 4-bit 2's complement
  * psum.txt  : 16 lines (4x4 onij), each = col7 ... col0, 16-bit 2's complement, after ReLU

Every activation is non-zero (1..15), including the padding ring, so a dropped,
duplicated or shifted nij changes the answer instead of hiding behind zeros.

Usage:  python3 gen_random.py <out_dir> <seed>
"""
import sys
import numpy as np

ROW, COL = 8, 8                 # input channels (array rows), output channels (array cols)
NIJ, ONIJ, KIJ = 36, 16, 9      # 6x6 padded input, 4x4 output, 3x3 kernel
IN_W, OUT_W = 6, 4              # padded input width, output width

if len(sys.argv) != 3:
    sys.exit("usage: python3 gen_random.py <out_dir> <seed>")
out_dir, seed = sys.argv[1], int(sys.argv[2])
rng = np.random.default_rng(seed)

X = rng.integers(1, 16, size=(NIJ, ROW))
W = rng.integers(-7, 8, size=(KIJ, COL, ROW))

# Integer conv: output (oy, ox) uses input position (oy+ky, ox+kx) for kernel tap (ky, kx)
psum = np.zeros((ONIJ, COL), dtype=np.int64)
for o in range(ONIJ):
    oy, ox = divmod(o, OUT_W)
    for k in range(KIJ):
        ky, kx = divmod(k, 3)
        psum[o] += W[k] @ X[(oy + ky) * IN_W + (ox + kx)]
relu = np.maximum(psum, 0)
assert np.abs(psum).max() < 2**15, "psum overflows 16 bits"

b4 = lambda v: format(int(v) & 0xF, '04b')
b16 = lambda v: format(int(v) & 0xFFFF, '016b')

with open(f'{out_dir}/input.txt', 'w') as f:
    f.write('#time0row7[msb-lsb],time0row6[msb-lst],....,time0row0[msb-lst]#\n')
    f.write('#time1row7[msb-lsb],time1row6[msb-lst],....,time1row0[msb-lst]#\n')
    f.write('#................#\n')
    for n in range(NIJ):
        f.write(''.join(b4(X[n, r]) for r in reversed(range(ROW))) + '\n')

with open(f'{out_dir}/weight.txt', 'w') as f:
    f.write('#col0row7[msb-lsb],...,col0row0[msb-lsb]#\n')
    f.write('#col1row7[msb-lsb],...,col1row0[msb-lsb]#\n')
    f.write('#................#\n')
    for k in range(KIJ):
        for c in range(COL):
            f.write(''.join(b4(W[k, c, r]) for r in reversed(range(ROW))) + '\n')

with open(f'{out_dir}/psum.txt', 'w') as f:
    f.write('#time0col7[msb-lsb],time0col6[msb-lst],....,time0col0[msb-lst]#\n')
    f.write('#time1col7[msb-lsb],time1col6[msb-lst],....,time1col0[msb-lst]#\n')
    f.write('#................#\n')
    for o in range(ONIJ):
        f.write(''.join(b16(relu[o, c]) for c in reversed(range(COL))) + '\n')

print(f'seed {seed}: wrote {out_dir}/input.txt, weight.txt, psum.txt '
      f'({int((psum < 0).sum())} of {psum.size} psums negative before ReLU)')
