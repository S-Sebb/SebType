"""Builds the typo bank: for each common word of the corpus, misspelt forms a person could type for it.

  noise.py RUN_DIR

Writes RUN_DIR/data/typos.tsv: word, then phone typos, then spelling mistakes, each list comma-separated, with
repeats: pack.py draws from them as they were drawn here, so a likelier typo comes up more often.

- Phone typos: phone_typo(), this file's own touch model on the harness's keyboard (layout.tsv). Its taps are
  not the harness's (make_sets.py's typo(), which makes the test sets): each draw is a person with their own
  spread and offset, whose taps slip onto another key by themselves, plus letters left out, typed twice or
  swapped. A model trained on the harness's own typos would be rewarded for learning that generator (#556).
- Spelling mistakes: the kind people make knowing the sound but not the spelling, as in Wikipedia's list of
  common misspellings, made by rule here (the list itself is the harness's set, so it isn't used).
A contraction is in the bank too, typed without its apostrophe: on the phone the apostrophe isn't on the
letter layer, so "don't" is typed "dont", and its typos are those of "dont".
"""

import multiprocessing as mp
import random
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "android/test/english"))
from make_sets import LETTERS, key_at

WORD = re.compile(r"[A-Za-z]+(?:'[a-z]+)?")
BANKED = re.compile(r"[a-z]+(?:'[a-z]+)?")
VOWELS = "aeiou"
# Suffixes spelt like their twins, both ways ("responsable" and "visable").
SUFFIXES = [
    (a, b)
    for x, y in [
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
    for a, b in ((x, y), (y, x))
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


def phone_typo(rng, word):
    """WORD's letters as one person taps them, with at least one error (None if none came)."""
    sigma, dx, dy = rng.uniform(20, 40), rng.gauss(0, 10), rng.gauss(12, 10)
    for _ in range(50):
        out = []
        for c in word:
            if len(word) > 1 and rng.random() < 0.03:  # left out
                continue
            x, y, w, h = LETTERS[c]
            k = key_at(
                round(rng.gauss(x + w / 2 + dx, sigma)),
                round(rng.gauss(y + h / 2 + dy, 1.2 * sigma)),
            )
            out.append(
                k if k in LETTERS else c
            )  # off the letters (space, shift): taken as the key aimed at
            if rng.random() < 0.015:  # tapped twice
                out.append(out[-1])
        if len(out) > 1 and rng.random() < 0.03:  # two taps the wrong way round
            i = rng.randrange(len(out) - 1)
            out[i], out[i + 1] = out[i + 1], out[i]
        typed = "".join(out)
        if typed and typed != word:
            return typed
    return None


def variants(word):
    """WORD, its phone typos and its spelling mistakes, all without apostrophes."""
    rng = random.Random(word)
    bare = word.replace("'", "")
    phone = (
        [t for t in (phone_typo(rng, bare) for _ in range(PHONE)) if t]
        if len(bare) >= 2
        else []
    )
    spell = (
        [s for s in (spelling(rng, bare) for _ in range(SPELLING)) if s]
        if len(bare) >= 3
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
        for c in pool.imap(
            count, parts(files)
        ):  # in order: most_common() breaks ties by it
            counts.update(c)
        # The 200,000 most frequent words, each seen at least 20 times, contractions too.
        words = [
            w for w, n in counts.most_common(200_000) if n >= 20 and BANKED.fullmatch(w)
        ]
        with open(Path(run) / "data/typos.tsv", "w") as out:
            out.writelines(
                f"{word}\t{','.join(phone)}\t{','.join(spell)}\n"
                for word, phone, spell in pool.imap(variants, words, chunksize=500)
            )
    print(f"typos.tsv: {len(words):,} words")


if __name__ == "__main__":
    main(sys.argv[1])
