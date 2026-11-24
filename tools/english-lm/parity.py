"""Checks an exported GGUF against its checkpoint: the log probabilities the phone's scorer gave on a dev set
(dev.sh's SET.dump, through llama.cpp) against the checkpoint's own for the same prompts, on the CPU.

  parity.py CKPT_DIR SET.tsv SET.dump [ITEMS]     (default 200 items)

Exits 1 if the median difference is over MEDIAN or the largest over WORST nats. r2's Q8_0 file: median 0.06,
largest 0.50 over 280 scores (#556); quantising costs that much, a wrong export far more.
"""

import statistics
import sys

import sentencepiece as spm
import torch
from transformers import LlamaForCausalLM

MEDIAN, WORST = 0.15, 1.5


def main(ckpt, set_path, dump_path, items=200):
    torch.set_num_threads(8)
    sp = spm.SentencePieceProcessor(model_file=f"{ckpt}/tokenizer.model")
    model = LlamaForCausalLM.from_pretrained(ckpt, torch_dtype=torch.float32).eval()
    T, S = sp.piece_to_id("<T>"), sp.piece_to_id("<S>")
    rows = [l.split("\t") for l in open(set_path).read().splitlines()][: int(items)]
    dump = [l.rstrip("\n").split("\t") for l in open(dump_path)]
    diffs, i = [], 0
    for ctx, typed, *_ in rows:
        while not (dump[i][0] == ctx and dump[i][1] == typed):  # the item's last key
            i += 1
        d = dump[i]
        i += 1
        # As sebtype_lm.cpp's score(): the context's last line, then the example, a capital at a sentence start.
        line = ctx.split("\n")[-1].rstrip(" ")
        assert len(line) <= 300, "parity.py doesn't cut long contexts as window() does"
        end = ctx.rstrip(" \n")
        capital = not end or end[-1] in ".!?\n"
        prefix = [sp.bos_id()] + (sp.encode(line) if line else []) + [T]
        prefix += [
            sp.piece_to_id(c)
            for c in typed.lower()
            if c in "abcdefghijklmnopqrstuvwxyz'"
        ] + [S]
        for k in range(3, len(d), 3):
            w = d[k][0].upper() + d[k][1:] if capital else d[k]
            ids = sp.encode(w)
            with torch.no_grad():
                lsm = model(torch.tensor([prefix + ids])).logits[0].log_softmax(-1)
            lp = sum(lsm[len(prefix) - 1 + j, t].item() for j, t in enumerate(ids))
            diffs.append(abs(lp - float(d[k + 2])))
    median, worst = statistics.median(diffs), max(diffs)
    print(
        f"parity: {len(diffs)} scores, median |difference| {median:.3f}, largest {worst:.3f} nats"
    )
    return median <= MEDIAN and worst <= WORST


if __name__ == "__main__":
    sys.exit(0 if main(*sys.argv[1:]) else 1)
