"""train.py's labels: the typed letters stay out of the loss wherever the window starts (#502), and <s> is
never a target. pack.py's examples: a cut word keeps its whole word's reading, and a loader-shaped example
holds no earlier one, and 白霜's readings override pypinyin's (#557).

python tools/chinese-lm/test_train.py
"""

import random

import pack
import torch
from train import between, labels

T, S, E = 1, 2, 3
L = 10  # a letter
H = 20  # a Han character
BOS = 4


def check(x, expected):
    _, y = labels(torch.tensor([x]), T, S, BOS)
    got = [int(v != -100) for v in y[0]]
    assert got == expected, f"{x}: {got} != {expected}"


# A window from the text before an example: the letters, <T> and <S> aren't targets.
check([H, T, L, L, S, H, E, H, T, L, S, H], [0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1])
# A window that starts among the letters: they and the next example's letters aren't targets either.
check([L, L, S, H, E, H, T, L, S, H], [0, 0, 1, 1, 1, 0, 0, 0, 1])
# <s> isn't a target: a segment's start can't be told from the one before.
check([BOS, H, E, BOS, H], [1, 1, 0, 1])
# The spans, also from a window that starts inside one.
assert between(torch.tensor([[H, E, H, S, H, H, E]]), S, E).int().tolist() == [
    [1, 0, 0, 1, 1, 1, 0]
]
print("PASS labels")


# pack.py with a stand-in tokenizer: a character is its own token, letters included.
class Pieces:
    def encode(self, ch):
        return [ord(ch)]


pack.sp, pack.piece = Pieces(), {}
pack.BOS, pack.EOS, pack.T, pack.S, pack.E = -1, -2, -3, -4, -5
text = "我们明天去重庆吃火锅"
cut_keys, typed, records = [], [], 0
for seed in range(3000):
    toks, wb, recs = [], [], []
    pack.segment(random.Random(seed), text, toks, wb, recs)
    assert len(toks) == len(wb)
    for i in [i for i, t in enumerate(toks) if t == pack.T]:
        s = toks.index(pack.S, i)
        keys = "".join(map(chr, toks[i + 1 : s]))
        span = "".join(chr(t) for t in toks[s + 1 :] if t > 0)[:1]
        if span == "重":
            typed.append(keys)
            # A cut span: <E> right after 重, 庆 as text after it.
            if toks[s + 2] == pack.E:
                cut_keys.append(keys)
    for rec, rb in recs:
        records += 1
        assert (
            rec[0] == pack.BOS and rec.count(pack.T) == 1 and rec.count(pack.BOS) == 1
        )
        assert len(rec) == len(rb)
assert cut_keys and records
assert not [k for k in typed if k.startswith("zhong")], "重 of 重庆 typed as zhong"
assert any(k.startswith("chong") for k in cut_keys), cut_keys[:5]
print(
    f"PASS pack: 重 of 重庆 is chong in {len(typed)} examples, {len(cut_keys)} cut; {records} loader examples"
)

# 白霜's readings override pypinyin's (common.use_readings): 很长 is hen chang, not hen zhang, and 嗯 is en, not
# n (Rime has no n for it).
import tempfile
import zipfile

import common

before = common.reading("嗯这条路很长")
with tempfile.TemporaryDirectory() as d:
    # A stand-in for rime-frost-schemas.zip: its word lists, with their header.
    with zipfile.ZipFile(f"{d}/frost.zip", "w") as z:
        for name in common.FROST_DICTS:
            z.writestr(
                f"cn_dicts/{name}.dict.yaml",
                "---\nname: x\n...\n" + "嗯\ten\t10\n很长\then chang\t5\n",
            )
    common.make_readings(f"{d}/frost.zip", f"{d}/readings.tsv")
    common.use_readings(f"{d}/readings.tsv")
after = common.reading("嗯这条路很长")
assert after[0] == "en" and after[-2:] == ["hen", "chang"], after
print(
    f"PASS readings: 嗯这条路很长 read {' '.join(before)} by pypinyin, {' '.join(after)} with 白霜's"
)
