"""Checks an exported GGUF against its checkpoint: the log probabilities the phone's scorer gave on a dev set
(dev.sh's SET.dump, through llama.cpp) against the checkpoint's own for the same prompts, on the CPU. Each
word's pieces' alone: its score adds where it ends and a contraction's share, which no token gives (#609).

  parity.py CKPT_DIR SET.tsv SET.dump [ITEMS]     (default every item)

dev.sh runs it on dev_sets.py's parity.tsv, which has capital targets, empty contexts, contractions typed
bare, bare forms that are words too and contexts longer than the phone's window; their counts are printed.

Exits 1 if the median difference is over MEDIAN or the largest over WORST nats. r2's Q8_0 file: median 0.06,
largest 0.50 over 280 scores (#556); quantising costs that much, a wrong export far more.
"""

import statistics
import sys
import unicodedata

import sentencepiece as spm
import torch
from transformers import LlamaForCausalLM

MEDIAN, WORST = 0.15, 1.5
CONTEXT_CHARS, CONTEXT_STEP = 300, 150  # sebtype_lm.cpp's


def window(line):
    """sebtype_lm.cpp's window() of a context line, when the last window isn't in it (the first key of an
    item whose line no earlier item had; later keys keep that window)."""
    if len(line) <= CONTEXT_CHARS:
        return line
    space = line.find(" ", len(line) - (CONTEXT_CHARS - CONTEXT_STEP))
    return "" if space < 0 else line[space + 1 :]


def main(ckpt, set_path, dump_path, items=None):
    torch.set_num_threads(8)
    sp = spm.SentencePieceProcessor(model_file=f"{ckpt}/tokenizer.model")
    model = LlamaForCausalLM.from_pretrained(ckpt, torch_dtype=torch.float32).eval()
    T, S = sp.piece_to_id("<T>"), sp.piece_to_id("<S>")
    rows = [l.split("\t") for l in open(set_path).read().splitlines()][
        : int(items or 1e9)
    ]
    print(
        "parity items:",
        len(rows),
        "capital targets",
        sum(r[2][:1].isupper() for r in rows),
        "empty contexts",
        sum(not r[0] for r in rows),
        "contractions typed bare",
        sum("'" in r[2] and "'" not in r[1] for r in rows),
        "typed words kept",
        sum(r[1] == r[2] for r in rows),
        "contexts over the window",
        sum(len(r[0].split("\n")[-1].rstrip(" ")) > CONTEXT_CHARS for r in rows),
    )
    dump = [l.rstrip("\n").split("\t") for l in open(dump_path)]
    diffs, i = [], 0
    for ctx, typed, *_ in rows:
        while not (dump[i][0] == ctx and dump[i][1] == typed):  # the item's last key
            i += 1
        d = dump[i]
        i += 1
        # As sebtype_lm.cpp's score(): the context's last line, then the example, a capital at a sentence start
        # or where the letters typed start with one (dev_sets.py types none all in capitals, which it reads
        # otherwise), and the words folded to ASCII as the corpus was ("débuts": debuts).
        line = window(ctx.split("\n")[-1].rstrip(" "))
        end = ctx.rstrip(" \n")
        capital = not end or end[-1] in ".!?\n" or typed[:1].isupper()
        prefix = [sp.bos_id()] + (sp.encode(line) if line else []) + [T]
        prefix += [
            sp.piece_to_id(c)
            for c in typed.lower()
            if c in "abcdefghijklmnopqrstuvwxyz'"
        ] + [S]
        for k in range(4, len(d), 5):  # sebtype.cpp's columns
            w = "".join(c for c in unicodedata.normalize("NFKD", d[k]) if c.isascii())
            w = w[0].upper() + w[1:] if capital else w
            ids = sp.encode(w)
            with torch.no_grad():
                lsm = model(torch.tensor([prefix + ids])).logits[0].log_softmax(-1)
            lp = sum(lsm[len(prefix) - 1 + j, t].item() for j, t in enumerate(ids))
            diffs.append(abs(lp - float(d[k + 4])))
    median, worst = statistics.median(diffs), max(diffs)
    print(
        f"parity: {len(diffs)} scores, median |difference| {median:.3f}, largest {worst:.3f} nats"
    )
    return median <= MEDIAN and worst <= WORST


if __name__ == "__main__":
    sys.exit(0 if main(*sys.argv[1:]) else 1)
