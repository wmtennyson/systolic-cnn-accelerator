"""
Tiny 4-bit sentiment classifier for the alpha_ctrl NLP mapping.

One transformer-style encoder block; the second feed-forward layer `ff2` is the layer mapped
onto the 8x8 systolic array:

  tokens -> embedding + position -> self-attention (float) -> +res, LayerNorm
         -> ff1: 1x1 conv 64->64 (float, bias) -> ReLU
         -> ff2: QuantConv2d 1x1 64->64, 4-bit act / 4-bit weight, NO bias   <- hardware
         -> ReLU                                                              <- hardware SFU
         -> +res, LayerNorm -> masked mean over tokens -> Linear(64 -> 2)

Hardware constraints this follows:
  * ff2's input comes right after a ReLU, so the 4-bit activations are unsigned (the MAC's `a`).
  * ff2 has no bias (the array has none) and is followed directly by a ReLU (the SFU always
    applies ReLU), with no BatchNorm in between, like the 'S8' layer in vgg_quant.py.
  * Tokens are the "pixels": a [B, T, 64] sequence is fed to ff2 as [B, 64, 1, T]
    (H = 1, W = T, K = 1), so one sentence of T tokens = one 64x64 K=1 layer of T pixels.

2:4 sparsity: ff2 is a QuantConv2dNM. Its mask is all ones (= plain QuantConv2d) until
set_nm_mask() is called; after that the mask is applied to the *quantized* weights, so pruned
weights are exactly 0 (quant_layer normalizes weights by mean/std before quantizing, so masking
the float weights would not give zeros).
"""
import torch
import torch.nn as nn
import torch.nn.functional as F
from models.quant_layer import QuantConv2d


class QuantConv2dNM(QuantConv2d):
    """QuantConv2d with an optional N:M mask along input channels (groups of M consecutive channels)."""

    def __init__(self, in_channels, out_channels, kernel_size, n=2, m=4, **kwargs):
        super().__init__(in_channels, out_channels, kernel_size, **kwargs)
        assert in_channels % m == 0
        self.n, self.m = n, m
        self.register_buffer('nm_mask', torch.ones(out_channels, in_channels, kernel_size, kernel_size))

    @torch.no_grad()
    def set_nm_mask(self):
        """Keep the N largest-magnitude (normalized) weights in every group of M input channels."""
        w = self.weight.data
        w = (w - w.mean()) / w.std()                              # same normalization as weight_quantize_fn
        o, i, kh, kw = w.shape
        g = w.abs().permute(0, 2, 3, 1).reshape(o, kh, kw, i // self.m, self.m)
        keep = g.topk(self.n, dim=-1).indices
        mask = torch.zeros_like(g).scatter_(-1, keep, 1.0)
        self.nm_mask.copy_(mask.reshape(o, kh, kw, i).permute(0, 3, 1, 2))

    def forward(self, x):
        weight_q = self.weight_quant(self.weight) * self.nm_mask
        self.weight_q = torch.nn.Parameter(weight_q)              # same bookkeeping as QuantConv2d
        x = self.act_alq(x, self.act_alpha)
        return F.conv2d(x, weight_q, self.bias, self.stride, self.padding, self.dilation, self.groups)


class SentimentNet_quant(nn.Module):
    def __init__(self, vocab_size, d=64, max_len=64, n_heads=4, n_classes=2, dropout=0.1):
        super().__init__()
        self.max_len = max_len
        self.embed = nn.Embedding(vocab_size, d, padding_idx=0)
        self.pos = nn.Embedding(max_len, d)
        self.attn = nn.MultiheadAttention(d, n_heads, dropout=dropout, batch_first=True)
        self.ln1 = nn.LayerNorm(d)
        self.ff1 = nn.Conv2d(d, d, kernel_size=1)                 # float
        self.relu1 = nn.ReLU()
        self.ff2 = QuantConv2dNM(d, d, kernel_size=1)             # hardware layer (bias=False)
        self.relu2 = nn.ReLU()                                    # hardware SFU ReLU
        self.ln2 = nn.LayerNorm(d)
        self.drop = nn.Dropout(dropout)
        self.classifier = nn.Linear(d, n_classes)

    # The forward pass is split so the hardware result can be spliced in (see post()).
    def pre(self, tokens):
        """tokens [B, T] (0 = pad) -> (h [B, T, d], ff2 input [B, d, 1, T], mask [B, T])."""
        mask = tokens != 0
        pos = torch.arange(tokens.size(1), device=tokens.device)
        x = self.drop(self.embed(tokens) + self.pos(pos))
        a, _ = self.attn(x, x, x, key_padding_mask=~mask, need_weights=False)
        h = self.ln1(x + self.drop(a))
        ff2_in = self.relu1(self.ff1(h.transpose(1, 2).unsqueeze(2)))
        return h, ff2_in, mask

    def post(self, h, ff2_out, mask):
        """ff2_out = ReLU(ff2(ff2_in)) [B, d, 1, T] -> logits [B, n_classes]."""
        y = ff2_out.squeeze(2).transpose(1, 2)
        h = self.ln2(h + self.drop(y))
        m = mask.unsqueeze(-1).float()
        pooled = (h * m).sum(1) / m.sum(1).clamp(min=1.0)
        return self.classifier(pooled)

    def forward(self, tokens):
        h, ff2_in, mask = self.pre(tokens)
        return self.post(h, self.relu2(self.ff2(ff2_in)), mask)

    def show_params(self):
        self.ff2.show_params()


def SentimentNet_quant_64(vocab_size, **kwargs):
    return SentimentNet_quant(vocab_size, d=64, **kwargs)
