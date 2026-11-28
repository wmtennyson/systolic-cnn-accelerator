"""
Hardware-in-the-loop accuracy for the NLP mapping, without the notebook or the `datasets` package.

Same computation as feedback() in NLP_Quant_Training.ipynb: for every exported sentence, run the
model up to ff2 in PyTorch, replace ff2 + ReLU with the hardware result (sent_XXXX/hw_out.txt from
hardware/alpha_ctrl/test/run_nlp_batch.py), finish the model, and compare with pure PyTorch.

Needs: final_trained_model/SentimentNet_quant_64{,_nm24}_model.pth, nlp_hw/<variant>/ (with
hw_out.txt files), and the GLUE SST-2 zip (data/SST-2.zip, from
https://dl.fbaipublicfiles.com/glue/data/SST-2.zip; data/ is git-ignored). The HuggingFace GLUE
validation split used in the notebook is this zip's dev.tsv.

Before trusting the result it checks that this setup reproduces the export exactly: token counts
and labels of all sentences, and the pure-PyTorch predictions stored in meta.npz.

Usage (from software/):  python3 nlp_feedback.py
"""
import csv
import io
import os
import re
import sys
import zipfile

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from models.nlp_quant import SentimentNet_quant_64          # noqa: E402
from nlp_export import read_psum_file                        # noqa: E402

MAX_LEN = 64
VARIANTS = {   # nlp_hw folder -> checkpoint
    'dense_row8': 'final_trained_model/SentimentNet_quant_64_model.pth',
    'nm24_row16': 'final_trained_model/SentimentNet_quant_64_nm24_model.pth',
}


def tokenize(s):                       # identical to the notebook
    return re.findall(r"[a-z0-9']+|[^\sa-z0-9']", s.lower())


def load_dev(path):
    with zipfile.ZipFile(path) as z:
        text = z.read('SST-2/dev.tsv').decode('utf-8')
    rows = list(csv.DictReader(io.StringIO(text), delimiter='\t', quoting=csv.QUOTE_NONE))
    return [r['sentence'] for r in rows], [int(r['label']) for r in rows]


def run_variant(name, ckpt_path, sentences, labels):
    vdir = os.path.join(HERE, 'nlp_hw', name)
    ckpt = torch.load(os.path.join(HERE, ckpt_path), map_location='cpu', weights_only=False)
    vocab = ckpt['vocab']
    stoi = {w: i for i, w in enumerate(vocab)}
    model = SentimentNet_quant_64(len(vocab), max_len=MAX_LEN)
    model.load_state_dict(ckpt['state_dict'])
    model.eval()

    meta = np.load(os.path.join(vdir, 'meta.npz'))
    x_delta, w_delta = float(meta['x_delta']), float(meta['w_delta'])
    n = len(meta['lens'])
    torch_preds, hw_preds, n_hw = [], [], 0
    for s in range(n):
        ids = [stoi.get(w, 1) for w in tokenize(sentences[s])][:MAX_LEN] or [1]
        assert len(ids) == meta['lens'][s], f'sentence {s}: {len(ids)} tokens here, {meta["lens"][s]} at export'
        assert labels[s] == meta['labels'][s], f'sentence {s}: label mismatch'
        tokens = torch.tensor([ids])
        T = len(ids)
        f = os.path.join(vdir, f'sent_{s:04d}', 'hw_out.txt')
        if os.path.exists(f):
            n_hw += 1
        else:
            f = os.path.join(vdir, f'sent_{s:04d}', 'psum.txt')
        relu_int = read_psum_file(f, T)
        with torch.no_grad():
            torch_preds.append(model(tokens).argmax(1).item())
            h, _, mask = model.pre(tokens)
            y = torch.tensor(relu_int, dtype=torch.float32) * x_delta * w_delta
            hw_preds.append(model.post(h, y.view(1, 64, 1, T), mask).argmax(1).item())
    torch_preds, hw_preds, labs = np.array(torch_preds), np.array(hw_preds), np.array(labels[:n])
    assert (torch_preds == meta['torch_preds']).all(), 'local PyTorch predictions differ from the export'

    print(f'{name}: {n} sentences, hardware results used for {n_hw}/{n}')
    print(f'  local setup reproduces the export: token counts, labels, PyTorch predictions all identical')
    print(f'  predictions hardware-in-the-loop == PyTorch: {(hw_preds == torch_preds).sum()}/{n}')
    print(f'  accuracy: hardware-in-the-loop {100 * (hw_preds == labs).mean():.2f}%   '
          f'PyTorch {100 * (torch_preds == labs).mean():.2f}%')
    run_csv = os.path.join(vdir, 'hw_run.csv')
    if os.path.exists(run_csv):
        r = np.loadtxt(run_csv, delimiter=',', skiprows=1, dtype=np.int64, ndmin=2)
        print(f'  hardware: {r[:, 2].sum()} cycles for {r[:, 1].sum()} tokens '
              f'({r[:, 2].sum() / r[:, 1].sum():.1f} cycles/token), {r[:, 3].sum()} output mismatches')
    return n_hw == n and (hw_preds == torch_preds).all()


def main():
    torch.set_num_threads(1)           # tiny model, one sentence at a time: threads only add overhead
    zpath = os.path.join(HERE, 'data', 'SST-2.zip')
    if not os.path.exists(zpath):
        sys.exit(f'missing {zpath}: download https://dl.fbaipublicfiles.com/glue/data/SST-2.zip there')
    sentences, labels = load_dev(zpath)
    ok = all([run_variant(name, ck, sentences, labels) for name, ck in VARIANTS.items()])
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
