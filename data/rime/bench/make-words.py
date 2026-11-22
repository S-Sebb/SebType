"""Makes the word set (#482): common words typed alone in full pinyin, each expecting the spelling mainland
text uses most for that pinyin, to check that a rarer spelling (硫黄 for 硫磺) doesn't come first.

  python3 make-words.py LARGE_ZH_MSGPACK_GZ SETS_DIR   # writes words.tsv (keys, word, wordfreq cB)

Words and frequencies are wordfreq's large Chinese list (v3.2, data CC BY-SA 4.0: Wikipedia, subtitles,
books, news and social media, in simplified characters). Drawn with seed 482 from the Han words of 2-4
characters at least 1 per million (cB <= 600) whose spelling is a choice: another word of the list with the
same toneless pinyin differs from it in one character (硫磺 and 硫黄, 北京 and 背景). 300 of 2 characters and
100 longer. A word is kept only when it is at least twice as frequent as any other word with the same
pinyin, so the expected word is clearly the common one. The words users reported (REPORTED) come last,
marked "reported" in a third column. Needs msgpack and pypinyin.
"""

import gzip
import random
import re
import sys

import msgpack
from pypinyin import Style, lazy_pinyin

HAN = re.compile(r"^[一-鿿]{2,4}$")
REPORTED = [("liuhuang", "硫磺")]  # #482
COMMON = 600  # cB: 1 per million
MARGIN = 30  # cB: twice as frequent

src, sets = sys.argv[1], sys.argv[2]
buckets = msgpack.unpackb(gzip.open(src).read(), raw=False)[1:]
cb = {w: i for i, b in enumerate(buckets) for w in b if HAN.match(w)}


def keys(w):
    p = lazy_pinyin(w, style=Style.NORMAL, errors=lambda x: ["?"] * len(x))
    return (
        "".join(p)
        if len(p) == len(w) and all(x.isascii() and x.isalpha() for x in p)
        else None
    )


# Competitors: every word frequent enough to matter next to a common one.
best = {}  # keys -> [(cB, word)] sorted, most frequent first
for w, c in cb.items():
    if c <= COMMON + MARGIN + 100 and (k := keys(w)):
        best.setdefault(k, []).append((c, w))
for v in best.values():
    v.sort()


def one_apart(a, b):
    return len(a) == len(b) and sum(x != y for x, y in zip(a, b)) == 1


clear = [
    (k, v[0][1], v[0][0])
    for k, v in sorted(best.items())
    if v[0][0] <= COMMON
    and len(v) > 1
    and v[1][0] - v[0][0] >= MARGIN
    and any(one_apart(v[0][1], w) for _, w in v[1:])
]
rng = random.Random(482)
two = [x for x in clear if len(x[1]) == 2]
longer = [x for x in clear if len(x[1]) > 2]
chosen = rng.sample(two, 300) + rng.sample(longer, 100)
with open(f"{sets}/words.tsv", "w", encoding="utf-8") as f:
    for k, w, c in chosen:
        f.write(f"{k}\t{w}\t{c}\n")
    f.writelines(f"{k}\t{w}\treported\n" for k, w in REPORTED)
print(
    f"{len(two)} two-character and {len(longer)} longer candidates; wrote {len(chosen)}",
    file=sys.stderr,
)
