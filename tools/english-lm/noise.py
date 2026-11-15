"""Builds the typo bank: for each common word of the corpus, misspelt forms a person could type for it.

  noise.py RUN_DIR

Writes RUN_DIR/data/typos.tsv: word, then phone typos, then spelling mistakes, each list comma-separated.
pack.py draws the typed letters of its correction examples from it.

- Phone typos: #46's error mix (Palin et al. 2019), with the harness's keyboard and touch model (make_sets.py's
  typo()): taps that slip onto another key, letters left out or typed twice, neighbours swapped.
- Spelling mistakes: the kind people make knowing the sound but not the spelling, as in Wikipedia's list of
  common misspellings, made by rule here (the list itself is the harness's set, so it isn't used).
"""

import multiprocessing as mp
import random
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "android/test/english"))
from make_sets import typo

WORD = re.compile(r"[A-Za-z]+(?:'[a-z]+)?")
VOWELS = "aeiou"
SUFFIXES = [
    ("able", "ible"),
    ("ance", "ence"),
    ("ant", "ent"),
    ("ary", "ery"),
    ("ise", "ize"),
    ("tion", "sion"),
    ("ous", "us"),
    ("ful", "full"),
    ("ly", "ley"),
    ("er", "or"),
    ("ar", "er"),
    ("ence", "ense"),
]
SOUNDS = [
    ("ie", "ei"),
    ("ei", "ie"),
    ("ph", "f"),
    ("f", "ph"),
    ("c", "s"),
    ("s", "c"),
    ("c", "k"),
    ("k", "c"),
    ("ck", "k"),
    ("s", "z"),
    ("z", "s"),
    ("wh", "w"),
    ("gh", ""),
    ("ou", "o"),
    ("ea", "ee"),
    ("ee", "ea"),
    ("y", "i"),
    ("i", "y"),
    ("sc", "s"),
    ("x", "cs"),
    ("qu", "kw"),
    ("ai", "ay"),
    ("au", "aw"),
    ("j", "g"),
    ("g", "j"),
    ("ch", "tch"),
    ("tch", "ch"),
]
PHONE, SPELLING = 24, 12


def spelling(rng, w):
    """W with one spelling mistake, never W itself (None if no rule changes it)."""
    for _ in range(20):
        r = rng.random()
        s = w
        if r < 0.25:  # a double letter made single, or a single one doubled
            i = rng.randrange(1, len(w))
            s = (
                w[:i] + w[i + 1 :]
                if w[i] == w[i - 1]
                else (w[:i] + w[i] + w[i:] if w[i] not in VOWELS else w)
            )
        elif r < 0.45:  # a vowel heard wrong
            idx = [i for i, c in enumerate(w) if c in VOWELS and i > 0]
            if idx:
                i = rng.choice(idx)
                s = w[:i] + rng.choice([v for v in VOWELS if v != w[i]]) + w[i + 1 :]
        elif r < 0.60:  # a suffix spelt like its twin
            for a, b in rng.sample(SUFFIXES, len(SUFFIXES)):
                if w.endswith(a):
                    s = w[: -len(a)] + b
                    break
        elif r < 0.80:  # a sound spelt another way
            for a, b in rng.sample(SOUNDS, len(SOUNDS)):
                hits = [m.start() for m in re.finditer(a, w)]
                if hits:
                    i = rng.choice(hits)
                    s = w[:i] + b + w[i + len(a) :]
                    break
        elif r < 0.90:  # a silent or unheard letter left out
            i = rng.randrange(1, len(w))
            s = w[:i] + w[i + 1 :]
        else:  # two letters the wrong way round
            i = rng.randrange(1, len(w) - 1)
            s = w[:i] + w[i + 1] + w[i] + w[i + 2 :]
        if s != w and len(s) >= 2 and s.isalpha():
            return s
    return None


def variants(word):
    rng = random.Random(word)
    phone = sorted({typo(rng, word)[0] for _ in range(PHONE)}) if len(word) >= 2 else []
    spell = (
        sorted({s for s in (spelling(rng, word) for _ in range(SPELLING)) if s})
        if len(word) >= 3
        else []
    )
    return word, phone, spell


def count(part):
    """Word counts of the lines that start in the byte range PART = (path, start, end)."""
    path, start, end = part
    c = Counter()
    with open(path, "rb") as f:
        f.seek(start)
        if start:
            f.readline()
        while f.tell() <= end:
            line = f.readline()
            if not line:
                break
            c.update(w.lower() for w in WORD.findall(line.decode()))
    return c


def parts(files, size=256 << 20):
    return [
        (f, s, min(s + size, f.stat().st_size))
        for f in files
        for s in range(0, f.stat().st_size, size)
    ]


def main(run):
    corpus = Path(run) / "data/corpus"
    with mp.Pool(16) as pool:
        files = [
            f for f in sorted(corpus.glob("*.txt")) if not f.name.endswith(".dev.txt")
        ]
        counts = Counter()
        for c in pool.imap_unordered(count, parts(files)):
            counts.update(c)
        # The 200,000 most frequent words, each seen at least 20 times.
        words = [w for w, n in counts.most_common(200_000) if n >= 20 and w.isalpha()]
        with open(Path(run) / "data/typos.tsv", "w") as out:
            out.writelines(
                f"{word}\t{','.join(phone)}\t{','.join(spell)}\n"
                for word, phone, spell in pool.imap(variants, words, chunksize=500)
            )
    print(f"typos.tsv: {len(words):,} words")


if __name__ == "__main__":
    main(sys.argv[1])
