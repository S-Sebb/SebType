"""Tunes decide()'s weights (engines/sebtype-lm/sebtype_lm.cpp) on the dev sets, never the harness's sets.

  tune.py DEV_DIR

DEV_DIR holds dev_sets.py's sets and dev.sh's SET.dump files: what english-sebtype's model said for each
key. The weights that fix the most typos while changing no more correct words than MAX_CHANGED are printed,
with their dev numbers; they go into sebtype_lm.cpp by hand.
"""

import itertools
import math
import sys
from pathlib import Path

# % of correct words changed. Today's stack changes 0.3 % on the dev sets and on the harness's; a third of that
# leaves room for the harness's 1,000 words, where one word is 0.1 %.
MAX_CHANGED = 0.1
MIN_DECODER_SCORE = 1e-3


def items(dev, name):
    """Per item of set NAME: (typed, target, typed_is_word, [(word, decoder score, log prob)]), from the
    dump's line for its last key."""
    rows = [l.split("\t") for l in (dev / f"{name}.tsv").read_text().splitlines()]
    dump = [l.rstrip("\n").split("\t") for l in open(dev / f"{name}.dump")]
    out, i = [], 0
    for ctx, typed, target, *_ in rows:
        while not (dump[i][0] == ctx and dump[i][1] == typed):
            i += 1
        d = dump[i]
        words = [(d[k], float(d[k + 1]), float(d[k + 2])) for k in range(3, len(d), 3)]
        out.append((typed, target, d[2] == "1", words))
        i += 1
    return out


def decide(item, weight, margin_word, margin_non_word):
    typed, _, typed_is_word, words = item
    score = [
        lp + weight * math.log(max(dec, MIN_DECODER_SCORE)) for _, dec, lp in words
    ]
    order = sorted(
        range(len(words) - 1), key=lambda i: -score[i]
    )  # stable, as std::stable_sort
    strip = [words[i][0] for i in order]
    margin = margin_word if typed_is_word else margin_non_word
    committed = (
        strip[0]
        if order and len(typed) > 1 and score[order[0]] - score[-1] > margin
        else typed
    )
    return strip, committed


def evaluate(sets, params):
    r = {}
    for name, its in sets.items():
        res = [(decide(it, *params), it[1]) for it in its]
        if name == "clean":
            r["changed"] = 100 * sum(c != t for (_, c), t in res) / len(res)
        else:
            r[f"{name} fixed"] = 100 * sum(c == t for (_, c), t in res) / len(res)
            r[f"{name} top3"] = 100 * sum(t in s[:3] for (s, _), t in res) / len(res)
    return r


def main(dev):
    dev = Path(dev)
    sets = {n: items(dev, n) for n in ("clean", "phone-typos", "misspellings")}
    best = None
    for params in itertools.product(
        (0, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4),
        (0, 2, 4, 5, 6, 7, 8, 9, 10, 12, 14),
        (-6, -4, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12),
    ):
        r = evaluate(sets, params)
        if r["changed"] <= MAX_CHANGED:
            gain = (
                r["phone-typos fixed"]
                + r["misspellings fixed"]
                + 0.5 * (r["phone-typos top3"] + r["misspellings top3"])
            )
            if not best or gain > best[0]:
                best = (gain, params, r)
    if not best:
        sys.exit("no weights keep the changed correct words within the limit")
    print("DECODER_WEIGHT, MARGIN_WORD, MARGIN_NON_WORD =", best[1])
    for k, v in best[2].items():
        print(f"  {k}: {v:.1f} %")


if __name__ == "__main__":
    main(sys.argv[1])
