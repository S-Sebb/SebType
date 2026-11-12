"""Dictionary-only English benchmark from the #40 study (FUTO's transformer is not part of it).

  bench.py CHAT_PROMPTS_JSONL_GZ MISSPELLINGS_TXT DICT...

For each binary dictionary: coverage of 20,000 held-out chat word tokens (OpenAssistant oasst1
prompts), completion top-1/top-3 after 2 and 3 typed letters ranked by word frequency, and the
share of Wikipedia's common misspellings that the dictionary accepts as words (those would stop
autocorrect from fixing them). Words are compared in lowercase. Prints one line per dictionary.
"""

import bisect
import gzip
import json
import os
import random
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v202

WORD_RE = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")


def load(path):
    """{lowercase word: frequency} of the words a dictionary would suggest."""
    d = {}
    for w, (f, not_a_word, offensive, _) in v202.decode(Path(path).read_bytes())[
        1
    ].items():
        if not not_a_word and not offensive:
            d[w.lower()] = max(d.get(w.lower(), 0), f)
    return d


def chat_tokens(path, n=20000):
    random.seed(40)
    texts = [
        m["text"]
        for m in map(
            json.loads, gzip.decompress(Path(path).read_bytes()).decode().splitlines()
        )
        if m.get("lang") == "en"
    ]
    toks = [t.lower() for x in texts for t in WORD_RE.findall(x)]
    start = random.randrange(0, max(1, len(toks) - n))
    return toks[start : start + n]


def evaluate(d, toks, typos):
    words = sorted(d)
    cache = {}

    def top3(p):
        if p not in cache:
            i, j = bisect.bisect_left(words, p), bisect.bisect_left(words, p + "￿")
            cache[p] = sorted(words[i:j], key=lambda w: -d[w])[:3]
        return cache[p]

    multi = [t for t in toks if len(t) > 1]  # FUTO leaves single letters out on purpose
    r = {"coverage": sum(t in d for t in multi) / len(multi)}
    for k in (2, 3):
        long = [t for t in toks if len(t) > k]
        c = [top3(t[:k]) for t in long]
        r[f"p{k}_top1"] = sum(x[:1] == [t] for x, t in zip(c, long)) / len(long)
        r[f"p{k}_top3"] = sum(t in x for x, t in zip(c, long)) / len(long)
    r["typos_accepted"] = sum(t in d for t in typos) / len(typos)
    return r


def main(chat, misspellings, *dicts):
    toks = chat_tokens(chat)
    base = load(dicts[0])
    typos = [
        l.split("->")[0].strip().lower()
        for l in Path(misspellings).read_text(encoding="utf-8").splitlines()
        if "->" in l and l.split("->")[0].strip().isalpha()
    ]
    typos = [
        t for t in typos if t not in base
    ]  # count only typos the first dictionary rejects
    print(
        "dictionary".ljust(40),
        "words  ",
        " ".join(
            k.rjust(8)
            for k in ("cover", "p2top1", "p2top3", "p3top1", "p3top3", "typos_ok")
        ),
    )
    for path in dicts:
        d = base if path == dicts[0] else load(path)
        r = evaluate(d, toks, typos)
        print(
            path.ljust(40),
            str(len(d)).rjust(7),
            " ".join(f"{100 * v:8.1f}" for v in r.values()),
        )


if __name__ == "__main__":
    main(*sys.argv[1:])
