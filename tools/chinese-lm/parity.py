"""Checks an exported GGUF against its checkpoint (#557): the scores the phone's scorer gave Rime's candidates
on a dev set (zhbench's dump=1, through llama.cpp: engines/sebtype-lm/zh_lm.cpp's score()) against the
checkpoint's own for the same examples, on the CPU.

  parity.py CKPT_DIR SET.tsv SET.dump [ITEMS]     (default 200 items)

Exits 1 if the median difference is over MEDIAN nats, or if the two put another candidate first in more than
TOP_MISS of the items: quantising to Q6_K costs a little, a wrong export (or a scorer that reads the model
differently from training) far more. The largest difference is only printed: it falls on candidates scored
tens of nats below the first (#557's checkpoints: 1.6 nats on one at -65), which no ranking turns on.
"""

import statistics
import sys

import sentencepiece as spm
import torch
from transformers import LlamaForCausalLM

MEDIAN, TOP_MISS = 0.15, 0.01
CONTEXT_CHARS, MAX_LETTERS = 64, 64  # zh_lm.cpp's


def main(ckpt, set_path, dump_path, items=200):
    torch.set_num_threads(8)
    sp = spm.SentencePieceProcessor(model_file=f"{ckpt}/tokenizer.model")
    model = LlamaForCausalLM.from_pretrained(ckpt, torch_dtype=torch.float32).eval()
    T, S, E, B = (sp.piece_to_id(p) for p in ("<T>", "<S>", "<E>", "<B>"))

    def tokens(text):
        """zh_lm.cpp's tokenize(): a piece per character, or its bytes'."""
        out = []
        for ch in text:
            p = sp.piece_to_id("▁" if ch == " " else ch)
            out += (
                [p]
                if p != sp.unk_id()
                else [sp.piece_to_id(f"<0x{b:02X}>") for b in ch.encode()]
            )
        return out

    rows = open(set_path, encoding="utf-8").read().splitlines()[: int(items)]
    scored = {}
    for line in open(dump_path, encoding="utf-8"):
        item, rank, lp, text = line.rstrip("\n").split("\t", 3)
        if (
            int(item) < len(rows) and int(rank) >= 0
        ):  # Rime's candidates, which score() scored
            scored.setdefault(int(item), []).append((text, float(lp)))
    diffs, firsts = [], []
    for i, (ctx, typed, *_) in enumerate(r.split("\t") for r in rows):
        line = ctx.rsplit("\n", 1)[-1]
        prefix = [sp.bos_id()] + tokens(line[-CONTEXT_CHARS:])[-CONTEXT_CHARS:] + [T]
        prefix += [
            sp.piece_to_id(c) for c in typed[:MAX_LETTERS] if "a" <= c <= "z"
        ] + [S]
        pairs = []
        for text, lp in scored.get(i, []):
            ids = tokens(text) + [E]
            with torch.no_grad():
                logits = model(torch.tensor([prefix + ids])).logits[
                    0, len(prefix) - 1 :
                ]
            # As score(): each token against the others but <B>, and <B>'s logit for the word ending at <E>.
            norm = torch.cat([logits[:, :B], logits[:, B + 1 :]], 1).logsumexp(-1)
            ours = sum(logits[j, t].item() - norm[j].item() for j, t in enumerate(ids))
            ours += torch.nn.functional.logsigmoid(logits[len(ids) - 1, B]).item()
            pairs.append((ours, lp))
            if lp != float("-inf"):
                diffs.append(abs(ours - lp))
        if len(pairs) > 1:  # does the checkpoint put first what the phone does?
            firsts.append(max(pairs)[1] == max(lp for _, lp in pairs))
    median, worst = statistics.median(diffs), max(diffs)
    miss = firsts.count(False)
    print(
        f"parity: {len(diffs)} scores of {len(scored)} items, median difference {median:.3f}, largest {worst:.3f} nats;"
        f" another first in {miss} of {len(firsts)} items"
    )
    return median <= MEDIAN and miss <= TOP_MISS * len(firsts)


if __name__ == "__main__":
    sys.exit(0 if main(*sys.argv[1:]) else 1)
