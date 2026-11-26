"""Checks of the pipeline's own code, each for a fault #556 found in it; prepare.sh runs them first.

test.py RUN_DIR      (it reads RUN_DIR/data/tokenizer.model, and samples RUN_DIR/data/corpus for MIX's check)
"""

import contextlib
import io
import json
import random
import subprocess
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
# The bank lists txt among text's typos; a short form is meant, so it is never a typo of its word (#556).
text = Counter(pack.typed_for(rng, "text") for _ in range(4000))
check("typed_for: text never typed txt", text["txt"] == 0, text.most_common(4))
# Nor is a texting form another word's typo (rn for run, omg for long); ur for our stays (#556).
typed = {
    w: Counter(pack.typed_for(rng, w) for _ in range(4000))
    for w in ("run", "long", "plus", "our")
}
check(
    "typed_for: no texting form for another word, but ur for our",
    typed["run"]["rn"] == typed["long"]["omg"] == typed["plus"]["pls"] == 0
    and typed["our"]["ur"] > 0,
    {w: c.most_common(3) for w, c in typed.items()},
)
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
# Texting leaves out apostrophes only in the letters typed: the text the model predicts keeps them (#561).
texting = pack.Texting(random.Random(0))
texting.drop_apostrophes = texting.lower_i = texting.lower_starts = (
    texting.drop_stop
) = True
texting.short, texting.tail = 0, ""
check(
    "texting: the text keeps its apostrophes",
    texting.text("So what's up? I can't.", True, True) == "so what's up? i can't",
    texting.text("So what's up? I can't.", True, True),
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
got = written("we met at Ten O'Clock and YOU'RE late")
check(
    "examples: O'Clock and YOU'RE in the dictionary's case",
    "o'clock" in got and "you're" in got and "O'Clock" not in got,
    got,
)
starts = [
    written(line)[k].split()[0]
    for line, k in (
        ('"YOU\'RE late"', 0),
        ('He stopped. "DON\'T go"', 2),
        ("He stopped. (O'Clock news)", 2),
        ('He said, "YOU\'RE late"', 2),
    )
]
check(
    "examples: a quoted sentence start keeps its capital",
    starts == ["You're", "Don't", "O'clock", "You're"],
    starts,
)
got = [
    written(("a " * 149) + ". YOU'RE late")[
        -2
    ],  # the sentence starts at a segment's cut
    written(("a " * 149) + "and YOU'RE late")[-2],  # the cut is mid-sentence
    written("It was 1898. D'Estaing replaced him.")[2].split()[0],
    pack.standard("D'Estaing", True),
    pack.standard("iPhone's", True),
    pack.standard("eBay's", True),
]
check(
    "examples: a sentence start at a cut, and D'Estaing's, iPhone's and eBay's spelling",
    got == ["You're", "you're", "D'Estaing", "D'Estaing", "iPhone's", "eBay's"],
    got,
)
got = [
    written("The U.S. economy grew")[2],
    written("Shares fell. then they rose")[2],
    written("wait... what", chat=True)[1],
    written("He left. then", chat=True)[-1],
]
check(
    "examples: lowercase after U.S., ..., or a full stop stays, but not in chat",
    got == ["economy", "then", "what", "Then"],
    got,
)
got = [
    written("I didn't. then", chat=True)[-1],
    written("I met John's. then", chat=True)[-1],
    written("I'm. then", chat=True)[-1],
    written('He said "go." YOU\'RE late')[-2],
]
check(
    "examples: a sentence ends after a contraction, a possessive, or before a closing quote",
    got == ["Then", "Then", "Then", "You're"],
    got,
)
names = ["Thomas", "Americans", "Jesus", "Olympics", "iOS", "Mrs", "dont"]
got = [
    written('"What is it?" she asked', chat=True)[-2],
    written('"Go," he said', chat=True)[-2],
    written(("a " * 147) + '"Why?" she asked', chat=True)[-2],  # cut after the quote
    written('He said "go." YOU\'RE late')[-2],
]
check(
    "examples: a quote's lowercase attribution stays lowercase",
    got == ["she", "he", "she", "You're"],
    got,
)
got = [pack.standard(w, False) for w in names]
check(
    "examples: names and plurals get no apostrophe",
    got == names[:-1] + ["don't"],
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

# dev.sh: a harness run that fails first still waits for the slower ones, then fails.
with tempfile.TemporaryDirectory() as d:
    script = f"""set -euo pipefail
    source <(sed -n '/^wait_all() {{/,/^}}/p' {HERE / "dev.sh"})
    (exit 1) & a=$!
    (sleep 1; touch {d}/slow) & b=$!
    wait_all $a $b 2> /dev/null && exit 0
    [[ -e {d}/slow ]] && exit 3"""
    code = subprocess.run(["bash", "-c", script]).returncode
check("dev.sh: waits for every run, then fails", code == 3, code)

# MIX: windows drawn by token give each source the share pilot r4 trained on, with PILOT_MIX's windows drawn
# by <s> (segments). Estimated from 100 runs of 50 lines of each corpus file: runs, as the line after a random
# byte follows a long line more often (in oasst2 a short question follows a long answer).
rng = random.Random(0)
segs, toks = {}, {}
for name in pack.MIX:
    path = Path(run) / f"data/corpus/{name}.txt"
    size = path.stat().st_size
    with open(path, "rb") as f:
        lines = []
        for _ in range(100):
            f.seek(rng.randrange(size))
            f.readline()
            lines += [f.readline().decode().rstrip("\n") for _ in range(50)]
    pieces = [p for l in lines if l for p in pack.segments(l)]
    nbytes = sum(len(l) + 1 for l in lines)
    segs[name] = size * len(pieces) / nbytes
    toks[name] = (
        size * (sum(map(len, sp.encode(pieces))) + len(pieces) + len(lines)) / nbytes
    )
pilot = {n: pack.PILOT_MIX[n] * segs[n] for n in pack.MIX}
now = {n: pack.MIX[n] * toks[n] for n in pack.MIX}
ratio = {
    n: round(now[n] / sum(now.values()) / (pilot[n] / sum(pilot.values())), 2)
    for n in pack.MIX
}
check(
    "MIX: each source's share is pilot r4's, within 10 %",
    all(0.9 < r < 1.1 for r in ratio.values()),
    ratio,
)

# The bar: a model that fixes nothing in text messages fails it, and so does one that keeps every homograph
# as typed (19 of the harness's 31 rows: 61.3 %, over AOSP's 58.1 %).
today_path = HERE.parents[1] / "android/test/english/today.json"
today = json.loads(today_path.read_text())["today"]
# AOSP's numbers as in the pilots' runs (it loses 250 capitals); a keyboard that passes, as pilot r4's core
# would with the clean word fixed: no capital lost but 50 "i" for "I" and 3 names.
aosp = json.loads(json.dumps(today))
for k, lowered in (
    ("contractions", 55),
    ("apostrophes", 32),
    ("homographs", 0),
    ("capitals", 163),
):
    aosp[k] = {
        "fixed": 50.0,
        "kept fixed": 50.0,
        "restored fixed": 50.0,
        "capitalised": 0,
        "lowercased": lowered,
        "lowercased I": 0,
    }
aosp["homographs"].update({"fixed": 58.1, "kept fixed": 63.2, "restored fixed": 50.0})
good = json.loads(json.dumps(aosp))
for k in ("contractions", "apostrophes", "homographs"):
    good[k]["lowercased"] = 0
good["capitals"].update({"lowercased": 53, "lowercased I": 50})


# A lost capital, "I'M" for "I'm" (a gained one, not lowercased I) and "i" for "I" (both).
with (
    tempfile.TemporaryDirectory() as d,
    contextlib.redirect_stdout(io.StringIO()) as out,
):
    rows = [("bob", "Bob", "bob"), ("im", "I'm", "I'M"), ("i", "I", "i")]
    (Path(d) / "core.capitals.tsv").write_text(
        "".join("\t".join(r) + "\t\t1\n" for r in rows)
    )
    score.main(d)
got = json.loads(out.getvalue())["core"]["capitals"]
got = [got[k] for k in ("capitalised", "lowercased", "lowercased I")]
check(
    "score: lowercased I counts only I's forms that lost a capital",
    got == [1, 2, 1],
    got,
)
with (
    tempfile.TemporaryDirectory() as d,
    contextlib.redirect_stdout(io.StringIO()) as out,
):
    rows = [
        ("thomas", "Thomas", "Thoma's"),
        ("dont", "don't", "don't"),
        ("its", "its", "it's"),
    ]
    sets = {
        "capitals": rows,
        "clean": [("methods", "methods", "method's")],
        "text-typos": [
            ("its", "its", "it's")
        ],  # "Aw its": text-typos keeps the bare form
    }
    for name, rows in sets.items():
        (Path(d) / f"core.{name}.tsv").write_text(
            "".join("\t".join(r) + "\t\t1\t0\n" for r in rows)
        )
    score.main(d)
got = json.loads(out.getvalue())["core"]
got = [got[n]["gained apostrophes"] for n in sets]
check(
    "score: gained apostrophes, on clean too, not text-typos' its",
    got == [2, 1, 0],
    got,
)


def passes(change):
    """Whether the passing keyboard with CHANGE(core) applied passes the bar; the bar's rows aren't printed,
    as the failures here are meant."""
    core = json.loads(json.dumps(good))
    change(core)
    with tempfile.TemporaryDirectory() as d, contextlib.redirect_stdout(io.StringIO()):
        (Path(d) / "s.json").write_text(json.dumps({"core": core, "aosp": aosp}))
        return score.bar(Path(d) / "s.json", today_path)


check("bar: a keyboard that passes", passes(lambda c: None))
check(
    "bar: texting accuracy zero fails",
    not passes(lambda c: c["text-typos"].update(fixed=0.0, top1=0.0, top3=0.0)),
)
check(
    "bar: keeping every homograph fails",
    not passes(
        lambda c: c["homographs"].update(
            {"fixed": 61.3, "kept fixed": 100.0, "restored fixed": 0.0}
        )
    ),
)
check(
    "bar: a contraction in a title's case fails",
    not passes(lambda c: c["contractions"].update(capitalised=1)),
)
check(
    "bar: 30 sentence-start contractions lowercased fail, though AOSP loses 87",
    not passes(lambda c: c["contractions"].update(lowercased=30)),
)
check(
    "bar: 3 gained apostrophes fail",
    not passes(lambda c: c["capitals"].update({"gained apostrophes": 3})),
)
check(
    "bar: 6 capitals lost besides I fail",
    not passes(lambda c: c["capitals"].update(lowercased=56)),
)

sys.exit(1 if failures else 0)
