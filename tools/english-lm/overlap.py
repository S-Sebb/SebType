"""Checks that the training corpus doesn't hold the English harness's test sentences.

  overlap.py RUN_DIR

Counts, over every corpus file (train and dev lines):
- lines that share 8 words in a row with a harness item (its context and word), or hold a whole item of 5 to
  7 words: corpus.py drops these, so it should be 0;
- the harness items of 5 words or more that share 8 words in a row (or all of theirs) with a corpus line;
- the next-word items whose last 3 context words and the word appear in the corpus: ordinary English
  overlaps here, so this is reported, not a leak.
"""

import multiprocessing as mp
import re
import sys
from pathlib import Path

HARNESS = Path(__file__).resolve().parents[2] / "android/test/english/sets"
WORDS = re.compile(r"[a-z0-9']+")


def harness():
    items, tails = [], set()
    for f in sorted(HARNESS.glob("*.tsv")):
        if f.name == "wikinews-articles.tsv":
            continue
        for line in f.read_text().splitlines():
            ctx, typed, target = line.split("\t")[:3]
            w = WORDS.findall(f"{ctx} {target}".lower())
            if len(w) >= 5:
                items.append((f.stem, tuple(w)))
            if f.stem.startswith("next-") and len(w) >= 4:
                tails.add(" ".join(w[-4:]))
    return items, tails


def grams(items):
    g = {}
    for k, (_, w) in enumerate(items):
        n = min(8, len(w))
        for i in range(len(w) - n + 1):
            g.setdefault(" ".join(w[i : i + n]), set()).add(k)
    return g


ITEMS, TAILS = harness()
GRAMS = grams(ITEMS)


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
            w = WORDS.findall(line.decode().lower())
            hit = False
            for n in (5, 6, 7, 8):
                for i in range(len(w) - n + 1):
                    g = " ".join(w[i : i + n])
                    if g in GRAMS:
                        hit = True
                        hit_items |= GRAMS[g]
            for i in range(len(w) - 3):
                t = " ".join(w[i : i + 4])
                if t in TAILS:
                    hit_tails.add(t)
            lines += hit
    return lines, hit_items, hit_tails


def main(run):
    files = sorted((Path(run) / "data/corpus").glob("*.txt"))
    size = 256 << 20
    parts = [
        (f, s, min(s + size, f.stat().st_size))
        for f in files
        for s in range(0, f.stat().st_size, size)
    ]
    lines, items, tails = 0, set(), set()
    with mp.Pool(16) as pool:
        for n, i, t in pool.imap_unordered(scan, parts):
            lines, items, tails = lines + n, items | i, tails | t
    print(
        f"corpus lines sharing 8 words in a row (or a whole short item) with a harness item: {lines}"
    )
    by_set = {}
    for k in items:
        by_set[ITEMS[k][0]] = by_set.get(ITEMS[k][0], 0) + 1
    print(
        f"harness items (5+ words) sharing 8 words in a row with the corpus: {len(items)} of {len(ITEMS)} {by_set}"
    )
    print(
        f"next-word items whose last 3 context words and the word occur in the corpus: "
        f"{len(tails)} of {len(TAILS)} distinct (ordinary English, not a leak)"
    )


if __name__ == "__main__":
    main(sys.argv[1])
