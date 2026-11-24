"""Checks that the training corpus doesn't hold the Chinese harness's test and dev items (#557: the dev sets
choose the checkpoint, so they must be held out too).

  overlap.py RUN_DIR

Counts, over the corpus's training files (the dev lines come from the dev sets' own documents):
- lines that share 10 characters in a row with a test or dev item (its context and target), or hold a whole
  item of 6 to 9 characters: corpus.py drops these, so it must be 0, else overlap.py exits 1;
- the items that share 10 characters in a row (or all of theirs) with a corpus line, by set;
- the next-word items whose last 4 context characters and the word appear in the corpus: ordinary Chinese
  overlaps here, so this is reported, not a leak.
"""

import multiprocessing as mp
import sys
from pathlib import Path

SETS = Path(__file__).resolve().parents[2] / "android/test/chinese-lm/sets"
N = 10


def harness(dirs):
    items, tails = [], set()
    for f in sorted(f for d in dirs for f in d.glob("*.tsv")):
        if "wikinews-articles" in f.name:
            continue
        for line in f.read_text(encoding="utf-8").splitlines():
            ctx, _, target = line.split("\t")[:3]
            if len(ctx + target) >= 6:
                items.append((f.stem, ctx + target))
            if f.stem.removeprefix("dev-").startswith("next-") and len(ctx) >= 4:
                tails.add(ctx[-4:] + target)
    return items, tails


# The pool's workers inherit these (fork).
ITEMS, TAILS = harness([SETS, Path(sys.argv[1]) / "dev"])
GRAMS = {}
for k, (_, t) in enumerate(ITEMS):
    n = min(N, len(t))
    for i in range(len(t) - n + 1):
        GRAMS.setdefault(t[i : i + n], set()).add(k)
TAIL_LENS = sorted({len(t) for t in TAILS})


def scan(part):
    path, start, end = part
    lines, hit_items, hit_tails = 0, set(), set()
    with open(path, "rb") as f:
        f.seek(start)
        if start:
            f.readline()
        while f.tell() <= end:
            line = f.readline()
            if not line:
                break
            s = line.decode().rstrip("\n")
            hit = False
            for n in range(6, N + 1):
                for i in range(len(s) - n + 1):
                    g = s[i : i + n]
                    if g in GRAMS:
                        hit = True
                        hit_items |= GRAMS[g]
            for n in TAIL_LENS:
                for i in range(len(s) - n + 1):
                    if s[i : i + n] in TAILS:
                        hit_tails.add(s[i : i + n])
            lines += hit
    return lines, hit_items, hit_tails


def main(run):
    files = sorted(
        f
        for f in (Path(run) / "data/corpus").glob("*.txt")
        if not f.name.endswith(".dev.txt")
    )
    size = 64 << 20
    parts = [
        (f, s, min(s + size, f.stat().st_size))
        for f in files
        for s in range(0, f.stat().st_size, size)
    ]
    lines, items, tails = 0, set(), set()
    # yanglab16 is shared: 16 of its 96 CPUs.
    with mp.Pool(16) as pool:
        for n, i, t in pool.imap_unordered(scan, parts):
            lines, items, tails = lines + n, items | i, tails | t
    print(
        f"corpus lines sharing 10 characters in a row (or a whole short item) with an item: {lines}"
    )
    by_set = {}
    for k in items:
        by_set[ITEMS[k][0]] = by_set.get(ITEMS[k][0], 0) + 1
    print(
        f"items sharing 10 characters in a row with the corpus: {len(items)} of {len(ITEMS)} {by_set}"
    )
    print(
        f"next-word items whose last 4 context characters and the word occur in the corpus: "
        f"{len(tails)} of {len(TAILS)} distinct (ordinary Chinese, not a leak)"
    )
    return lines


if __name__ == "__main__":
    sys.exit(1 if main(sys.argv[1]) else 0)
