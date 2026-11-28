"""
Run exported NLP sentences through the FSM-controlled core (alpha_ctrl) and collect results.

For each variant folder written by NLP_Quant_Training.ipynb (software/nlp_hw/<variant>), this
compiles verilog/core_batch_tb.v for the right build (row / SPARSE_NM come from meta.npz), splits
the sentences into shards, runs the shards in parallel, and then:
  * every sent_XXXX/hw_out.txt holds the hardware result (read by the notebook's feedback()),
  * <variant>/hw_run.csv has one line per sentence: sentence, tokens, cycles, errors,
  * a summary is printed (errors vs psum.txt, total / per-token cycles).

By default the simulation uses test/sim_fast/fifo_mux_2_1.v, a behavioral stand-in for the given
gate-level 2:1 mux (~150x faster; see that file). --gate uses the real verilog/fifo_mux_2_1.v.
--check N reruns the first N sentences with the gate-level mux and requires identical hw_out.txt.
--opt M builds the FSM with ctrl.sv cycle-saving options (bit mask, default 0 = baseline sequence);
the per-sentence results then go to hw_run_opt<M>.csv instead of hw_run.csv.
--per-length runs one sentence per distinct token count instead of all of them. The controller's
schedule depends only on the layer shape (verified: in every full run each token count has exactly
one cycle count), so total cycles = sum over lengths of cycles(T) x sentences(T) is exact, ~18x
faster. Outputs of the representative sentences are still checked. Results: hw_len_opt<M>.csv.

Usage (from anywhere):
  python3 hardware/alpha_ctrl/test/run_nlp_batch.py                       # both default variants
  python3 hardware/alpha_ctrl/test/run_nlp_batch.py software/nlp_hw/dense_row8 --jobs 12 --check 20
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np

HW_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(os.path.dirname(HW_DIR))
DEFAULT_VARIANTS = [os.path.join(REPO, 'software', 'nlp_hw', v) for v in ('dense_row8', 'nm24_row16')]


def rtl_files(gate):
    """filelist_tiled without its testbench, plus the batch testbench; optionally the fast mux."""
    with open(os.path.join(HW_DIR, 'filelist_tiled')) as f:
        files = [os.path.join(HW_DIR, ln.strip()) for ln in f if ln.strip() and 'core_tiled_tb' not in ln]
    files.append(os.path.join(HW_DIR, 'verilog', 'core_batch_tb.v'))
    if not gate:
        files = [os.path.join(HW_DIR, 'test', 'sim_fast', 'fifo_mux_2_1.v') if f.endswith('fifo_mux_2_1.v') else f
                 for f in files]
    return files


def compile_tb(work, row, nm, gate, opt):
    out = os.path.join(work, f'batch_row{row}_nm{int(nm)}_opt{opt}_{"gate" if gate else "fast"}')
    cmd = ['iverilog', '-g2012', '-s', 'core_batch_tb', f'-Pcore_batch_tb.row={row}',
           f'-Pcore_batch_tb.SPARSE_NM={int(nm)}', f'-Pcore_batch_tb.CTRL_OPT={opt}', '-o', out] + rtl_files(gate)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f'compile failed:\n{r.stderr}')
    return out


def run_shard(binary, vdir, first, count, work, sents=None):
    log = os.path.join(work, f'{os.path.basename(binary)}_{first}.log')
    args = [f'+FIRST={first}', f'+COUNT={count}']
    if sents is not None:                                     # explicit sentence list
        lst = os.path.join(work, f'{os.path.basename(binary)}_{first}.list')
        with open(lst, 'w') as f:
            f.writelines(f'{s}\n' for s in sents[first:first + count])
        args = [f'+LIST={lst}']
    with open(log, 'w') as f:
        subprocess.run(['vvp', binary, f'+DIR={vdir}'] + args,
                       stdout=f, stderr=subprocess.STDOUT, cwd=work)
    with open(log) as f:
        text = f.read()
    sents = [tuple(map(int, m)) for m in re.findall(r'SENT (\d+) T=(\d+) cycles=(\d+) errors=(\d+)', text)]
    if len(sents) != count:
        sys.exit(f'shard {first}+{count} failed, see {log}:\n{text[-2000:]}')
    return sents


def run_variant(vdir, n, jobs, gate, work, opt=0, sents=None):
    """sents: explicit sentence numbers (per-length mode); otherwise sentences 0 .. n-1."""
    meta = np.load(os.path.join(vdir, 'meta.npz'))
    row, nm = int(meta['row']), bool(meta['nm'])
    n = len(sents) if sents is not None else min(n or len(meta['lens']), len(meta['lens']))
    binary = compile_tb(work, row, nm, gate, opt)
    step = (n + jobs - 1) // jobs
    shards = [(s, min(n, s + step) - s) for s in range(0, n, step)]
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        results = sorted(sum(ex.map(lambda sh: run_shard(binary, vdir, sh[0], sh[1], work, sents), shards), []))
    return row, nm, results, time.time() - t0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('variants', nargs='*', default=DEFAULT_VARIANTS, help='nlp_hw/<variant> folders')
    ap.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) - 2))
    ap.add_argument('--n', type=int, default=0, help='only the first N sentences (default: all)')
    ap.add_argument('--gate', action='store_true', help='use the real gate-level fifo_mux_2_1 (slow)')
    ap.add_argument('--opt', type=int, default=0, help='ctrl.sv cycle-saving option bits (default 0)')
    ap.add_argument('--per-length', action='store_true',
                    help='one sentence per distinct token count; exact totals weighted by length histogram')
    ap.add_argument('--check', type=int, default=0,
                    help='rerun the first N sentences with the gate-level mux; hw_out.txt must be identical')
    a = ap.parse_args()

    work = tempfile.mkdtemp(prefix='nlp_batch_')
    ok = True
    for vdir in map(os.path.abspath, a.variants):
        if a.per_length:
            lens = np.load(os.path.join(vdir, 'meta.npz'))['lens']
            first_of = {}
            for s, T in enumerate(lens):
                first_of.setdefault(int(T), s)
            reps = sorted(first_of.values())
            row, nm, res, dt = run_variant(vdir, 0, a.jobs, a.gate, work, a.opt, reps)
            cyc_of = {t: c for _, t, c, _ in res}
            hist = {t: int((lens == t).sum()) for t in cyc_of}
            with open(os.path.join(vdir, f'hw_len_opt{a.opt}.csv'), 'w') as f:
                f.write('tokens,sentences,cycles_per_sentence\n')
                f.writelines(f'{t},{hist[t]},{cyc_of[t]}\n' for t in sorted(cyc_of))
            toks = int(lens.sum())
            cyc = sum(cyc_of[t] * hist[t] for t in cyc_of)
            err = sum(r[3] for r in res)
            print(f'{os.path.basename(vdir)} (row={row}, SPARSE_NM={int(nm)}, CTRL_OPT={a.opt}, per-length: '
                  f'{len(res)} representative sentences for {len(lens)}, {dt:.0f} s wall)')
            print(f'  output mismatches vs psum.txt (representatives): {err}')
            print(f'  cycles: total {cyc}, per sentence {cyc / len(lens):.0f}, per token {cyc / toks:.1f}')
            ok &= err == 0
            continue
        row, nm, res, dt = run_variant(vdir, a.n, a.jobs, a.gate, work, a.opt)
        with open(os.path.join(vdir, 'hw_run.csv' if a.opt == 0 else f'hw_run_opt{a.opt}.csv'), 'w') as f:
            f.write('sentence,tokens,cycles,errors\n')
            f.writelines(f'{s},{t},{c},{e}\n' for s, t, c, e in res)
        toks = sum(r[1] for r in res)
        cyc = sum(r[2] for r in res)
        err = sum(r[3] for r in res)
        bad = [r[0] for r in res if r[3]]
        print(f'{os.path.basename(vdir)} (row={row}, SPARSE_NM={int(nm)}, CTRL_OPT={a.opt}, '
              f'{"gate-level" if a.gate else "fast"} mux): {len(res)} sentences, {toks} tokens, '
              f'{dt:.0f} s wall')
        print(f'  output mismatches vs psum.txt: {err} lines in {len(bad)} sentences {bad[:10]}')
        print(f'  cycles: total {cyc}, per sentence {cyc / len(res):.0f}, per token {cyc / toks:.1f}')
        ok &= err == 0

        if a.check and not a.gate:
            k = min(a.check, len(res))
            fast = {s: open(os.path.join(vdir, f'sent_{s:04d}', 'hw_out.txt')).read() for s in range(k)}
            ref = os.path.join(work, 'gate_ref')
            os.makedirs(ref, exist_ok=True)
            for s in range(k):                                    # gate-level copy of the first k sentences
                shutil.copytree(os.path.join(vdir, f'sent_{s:04d}'), os.path.join(ref, f'sent_{s:04d}'), dirs_exist_ok=True)
            shutil.copy(os.path.join(vdir, 'weight.txt'), ref)
            shutil.copy(os.path.join(vdir, 'meta.npz'), ref)
            _, _, gres, gdt = run_variant(ref, k, a.jobs, True, work, a.opt)
            same = all(open(os.path.join(ref, f'sent_{s:04d}', 'hw_out.txt')).read() == fast[s] for s in range(k))
            same &= [r[2] for r in gres] == [r[2] for r in res[:k]]
            print(f'  gate-level cross-check, first {k} sentences: '
                  f'{"IDENTICAL outputs and cycles" if same else "MISMATCH"} ({gdt:.0f} s wall)')
            shutil.rmtree(ref)
            ok &= same
    shutil.rmtree(work)
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
