"""Checks of the pipeline's own code, each for a fault #556 found in it; prepare.sh runs them first.

test.py RUN_DIR      (RUN_DIR/data/tokenizer.model is all it reads)
"""

import json
import random
import sys
import tempfile
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parents[1] / "android/test/english")]
import corpus
import noise
import numpy as np
import pack
import score
import torch
import train

run = sys.argv[1]
pack.init(run, typos=False)
sp, T, S = pack.sp, pack.T, pack.S
piece = lambda ids: [sp.id_to_piece(int(i)) for i in ids]
failures = []


def check(name, ok, detail=""):
    print(
        f"{'PASS' if ok else 'FAIL'} {name}{': ' + str(detail) if detail and not ok else ''}"
    )
    if not ok:
        failures.append(name)


# Loss mask: a window that starts inside an example trains none of its letters, nor a later example's.
a = sp.piece_to_id("▁a")
x = torch.tensor(
    [
        [a, a, S]
        + sp.encode("I am here")
        + [T, a, S]
        + sp.encode("a word")
        + [sp.bos_id()]
        + sp.encode("so")
    ]
)
_, y = train.labels(x, T, S, sp.bos_id())
trained = [p for p, v in zip(piece(x[0, 1:]), y[0]) if v != -100]
check(
    "labels: a window starting inside an example",
    trained == piece(sp.encode("I am here") + sp.encode("a word") + sp.encode("so")),
    trained,
)
x = torch.tensor([sp.encode("so") + [T, a, a, S] + sp.encode("a word")])
_, y = train.labels(x, T, S, sp.bos_id())
trained = [p for p, v in zip(piece(x[0, 1:]), y[0]) if v != -100]
check("labels: a whole example", trained == piece(sp.encode("a word")), trained)

# Windows: a source's share of windows is its share of tokens, short segments or long. Here two sources of
# 50,000 tokens each, in segments of 10 and of 100 tokens; a draw by <s> took the first 91 % of the time.
data = np.full(100_000, 7, dtype=np.uint16)
data[0:50_000:10] = data[50_000::100] = sp.bos_id()
w = train.window_starts(
    train.segment_starts(data, sp.bos_id(), 256),
    20_000,
    torch.Generator().manual_seed(0),
)
share = (w < 50_000).mean()
check("windows: a source's share follows its tokens", 0.47 < share < 0.53, share)

# Typed letters: a contraction mostly without its apostrophe, and a word the bank lacks still gets typos.
rng = random.Random(1)
dont = Counter(pack.typed_for(rng, "don't") for _ in range(4000))
check(
    "typed_for: don't typed dont",
    dont["dont"] > 0.3 * 4000 and dont["don't"] < 0.2 * 4000,
    dont.most_common(4),
)
for w in ("to", "grandfathered"):
    same = sum(pack.typed_for(rng, w) == w for _ in range(4000)) / 4000
    check(f"typed_for: {w!r} typed as it is 40 % of the time", 0.35 < same < 0.5, same)
check("noise: suffixes both ways", ("ible", "able") in noise.SUFFIXES)
check(
    "noise: the bank keeps repeated typos", len(noise.variants("the")[1]) == noise.PHONE
)

# Examples: the word after <S> is the standard one, whatever the line or texting did to it.
pack.HINT = 1.0


def written(line, texting=None, seed=0, chat=False):
    """The words after <S> in LINE's tokens, each up to the next example."""
    ids = pack.encode_line(random.Random(seed), line, texting, chat)
    s = [k for k, t in enumerate(ids) if t == S]
    t = [k for k, t in enumerate(ids) if t == T][1:] + [len(ids)]
    return [sp.decode(ids[i + 1 : j]) for i, j in zip(s, t)]


got = written("i dont know but im sure")
check(
    "examples: standard words in a texted source",
    got[:5] == ["I", "don't", "know", "but", "I'm"],
    got,
)
texting = pack.Texting(random.Random(0))
texting.lower_i = texting.drop_apostrophes = texting.lower_starts = True
texting.short = 0
got = written("I'm sure. You're right, I've said so.", texting)
check(
    "examples: standard words under texting()",
    [w.split()[0] for w in got]
    == ["I'm", "sure.", "You're", "right,", "I've", "said", "so."],
    got,
)
check(
    "examples: a word after a quote",
    "Hello" in " ".join(written('He said "Hello there"')),
    written('He said "Hello there"'),
)
check(
    "examples: a homograph stays",
    written("she was ill")[-1] == "ill",
    written("she was ill"),
)
got = [w.split()[0] for w in written("i cant come, whats up, it wont", chat=True)]
check(
    "examples: cant, whats, wont in chat are contractions",
    {"can't", "what's", "won't"} <= set(got),
    got,
)
check(
    "examples: cant elsewhere stays",
    written("they speak in cant")[-1] == "cant",
    written("they speak in cant"),
)
pack.TWO_WORDS = 1.0
ids = pack.encode_line(random.Random(0), "could be fine", None)
typed = sp.decode(ids[ids.index(T) + 1 : ids.index(S)]).replace(" ", "")
check(
    "examples: two words typed as one",
    typed.startswith("c")
    and sp.decode(ids[ids.index(S) + 1 : ids.index(T, ids.index(S))]) == "Could be",
    (typed, piece(ids)),
)
pack.HINT, pack.TWO_WORDS = 0.05, 0.05
check(
    "texting: no gonna before a noun",
    "gonna"
    not in pack.SHORT_RE.sub(
        lambda m: pack.SHORT[m.group().lower()], "I am going to London"
    ),
)

# Segments: no context longer than the phone's, each after its own <s>.
pack.HINT = 0
ids = pack.encode_line(random.Random(0), " ".join(["word"] * 200), None)
pack.HINT = 0.05
starts = [k for k, t in enumerate(ids) if t == sp.bos_id()]
lens = [
    len(sp.decode(ids[i + 1 : j])) for i, j in zip(starts, starts[1:] + [len(ids) - 1])
]
check(
    "segments: at most 300 characters after each <s>",
    len(starts) > 1 and max(lens) <= 300,
    lens,
)

# Fractional passes: half a pass is half the lines, not all or none of them.
with tempfile.TemporaryDirectory() as d:
    f = Path(d) / "x.txt"
    f.write_text("".join(f"line number {i}\n" for i in range(2000)))
    pack.HINT = 0
    n = sum(
        t == sp.eos_id()
        for t in pack.encode((str(f), 0, f.stat().st_size, "0", 0.0, 0.5))
    )
    pack.HINT = 0.05
check("pack: half a pass keeps half the lines", 850 < n < 1150, n)

# Corpus: Markdown and list markers off; dialogue and double spaces kept.
corpus.EXCLUDE = set()
got = corpus.clean(
    [
        '1. **Central Processing Unit:** the  brain of it.\n"Hello there," she said to me.'
    ]
)
check(
    "corpus: Markdown, list markers, quotes, double spaces",
    got
    == [
        ["Central Processing Unit: the brain of it.", '"Hello there," she said to me.']
    ],
    got,
)

# The bar: a model that fixes nothing in text messages fails it, and so does one that keeps every homograph
# as typed (19 of the harness's 31 rows: 61.3 %, over AOSP's 58.1 %).
today_path = HERE.parents[1] / "android/test/english/today.json"
today = json.loads(today_path.read_text())["today"]
aosp = json.loads(json.dumps(today))
for k in ("contractions", "apostrophes", "homographs", "capitals"):
    aosp[k] = {"fixed": 50.0, "kept fixed": 50.0, "restored fixed": 50.0}
aosp["homographs"].update({"fixed": 58.1, "kept fixed": 63.2, "restored fixed": 50.0})


def passes(core):
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "s.json").write_text(json.dumps({"core": core, "aosp": aosp}))
        return score.bar(Path(d) / "s.json", today_path)


check("bar: AOSP's own numbers pass", passes(aosp))
core = json.loads(json.dumps(aosp))
core["text-typos"].update(fixed=0.0, top1=0.0, top3=0.0)
check("bar: texting accuracy zero fails", not passes(core))
core = json.loads(json.dumps(aosp))
core["homographs"].update({"fixed": 61.3, "kept fixed": 100.0, "restored fixed": 0.0})
check("bar: keeping every homograph fails", not passes(core))

sys.exit(1 if failures else 0)
