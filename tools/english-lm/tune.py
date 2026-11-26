"""Tunes decide()'s weights (engines/sebtype-lm/sebtype_lm.cpp) on the dev sets, never the harness's sets.

  tune.py DEV_DIR

DEV_DIR holds dev_sets.py's sets, dev.sh's SET.dump files (decide()'s inputs for each key, which the replay
below runs the rule on) and the harness's results in out/, which the replay must commit at the shipped weights
or tune.py stops. The weights that fix the most typos while changing no more correct words than MAX_CHANGED are printed,
with their dev numbers; they go into sebtype_lm.cpp by hand. The typos: phone typos and misspellings, in text
messages too, contractions typed without their apostrophe, capitals, and bare forms that are words too, which
are fixed by keeping them (#556). select.sh compares checkpoints by the same gain.
"""

import functools
import itertools
import math
import re
import sys
import unicodedata
from pathlib import Path

# % of correct words changed. Today's stack changes 0.3 % on the dev sets and on the harness's; a third of that
# leaves room for the harness's 1,000 words, where one word is 0.1 %.
MAX_CHANGED = 0.1
SCORER = Path(__file__).resolve().parents[2] / "engines/sebtype-lm/sebtype_lm.cpp"
CONST = dict(re.findall(r"constexpr float (\w+) = ([\d.e-]+)f;", SCORER.read_text()))
MIN_DECODER_SCORE, MAX_DECODER_SCORE = (
    float(CONST["MIN_DECODER_SCORE"]),
    float(CONST["MAX_DECODER_SCORE"]),
)
SHIPPED = tuple(
    float(CONST[k]) for k in ("DECODER_WEIGHT", "MARGIN_WORD", "MARGIN_NON_WORD")
)


def items(dev, name):
    """Per item of set NAME: (typed, target, typed_is_word, typed's ending term, [(word, decoder score, log
    prob, log prob after the typed letters' hint)]), from the dump's line for its last key."""
    rows = [l.split("\t") for l in (dev / f"{name}.tsv").read_text().splitlines()]
    dump = [l.rstrip("\n").split("\t") for l in open(dev / f"{name}.dump")]
    out, i = [], 0
    for ctx, typed, target, *_ in rows:
        while not (dump[i][0] == ctx and dump[i][1] == typed):
            i += 1
        d = dump[i]
        words = [
            tuple([d[k]] + [float(x) for x in d[k + 1 : k + 4]])
            for k in range(4, len(d), 5)
        ]
        out.append((typed, target, d[2] == "1", float(d[3]), words))
        i += 1
    return out


# sebtype_lm.cpp's helpers that decide() reads words by. Its fold() keeps ASCII, drops accents and makes curly
# quotes straight; only the letters a hint holds matter here. Cached: the grid replays each item ~1,500 times.
@functools.cache
def hint_letters(word):
    word = unicodedata.normalize(
        "NFKD", word.translate({0x2018: "'", 0x2019: "'", 0x201A: "'"})
    )
    return "".join(c for c in ascii_lower(word) if c in "abcdefghijklmnopqrstuvwxyz'")


@functools.cache
def ascii_lower(s):
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in s)


IS = {"it", "he", "she", "that", "there", "here", "what", "where", "when", "why", "how", "who", "let", "this",
      "everyone", "everybody", "someone", "somebody", "nobody", "one"}  # fmt: skip


def common(own):
    stem, _, end = own.rpartition("'")
    return (
        (end == "t" and stem.endswith("n"))
        or end in ("re", "ve", "ll", "d")
        or (end == "m" and stem == "i")
        or (end == "s" and stem in IS)
        or own in ("o'clock", "y'all", "ma'am")
    )


@functools.cache
def contraction_of(word, letters):
    own = hint_letters(word)
    return (
        " " not in word
        and (not "A" <= word[0] <= "Z" or word.startswith("I'"))
        and own != letters
        and "'" in own
        and own.replace("'", "") == letters.replace("'", "")
        and common(own)
    )


def decide(item, weight, margin_word, margin_non_word):
    """sebtype_lm.cpp's decide() on a dumped item, with these weights: the strip and the word committed."""
    typed, _, typed_is_word, typed_end, words = item
    log = lambda d: weight * math.log(d)
    dec = lambda d: max(d, MIN_DECODER_SCORE)
    cap = MAX_DECODER_SCORE if typed_is_word else math.inf
    n = len(words) - 1  # the typed word is last
    typed_dec = min(dec(words[n][1]), cap)
    score = [0.0] * n + [words[n][2] + log(typed_dec)]
    commit = [-math.inf] * n
    letters = hint_letters(typed)
    contraction = [contraction_of(w[0], letters) for w in words[:n]]
    typed_best = max(
        [words[n][2]]
        + [lp for w, _, lp, _ in words[:n] if ascii_lower(w) == ascii_lower(typed)]
    )
    for i, (w, d, lp, as_typed) in enumerate(words[:n]):
        own_letters = hint_letters(w).replace("'", "") == letters.replace("'", "")
        score[i] = lp + log(min(dec(d), cap if own_letters else MAX_DECODER_SCORE))
        if not typed_is_word or not contraction[i]:
            if typed_is_word or not any(contraction) or contraction[i]:
                commit[i] = score[i]
            if not typed_is_word or ascii_lower(w) != ascii_lower(typed):
                commit[i] += typed_end
            continue
        score[i] = lp + log(typed_dec)
        if lp > typed_best:
            commit[i] = score[n] + as_typed - words[n][3] + log(dec(d) / typed_dec)
            score[i] = max(score[i], commit[i])
    order = sorted(range(n), key=lambda i: -score[i])  # stable, as std::stable_sort
    strip = [words[i][0] for i in order]
    if not n:
        return strip, typed
    best = max(
        range(n), key=lambda i: commit[i]
    )  # the first of equals, as std::max_element
    upper = lambda c: "A" <= c <= "Z"
    titled = upper(typed[0]) and not any(map(upper, typed[1:]))
    same = ascii_lower(words[best][0]) == ascii_lower(typed)
    margin = (
        0
        if (same and len(typed) > 1 and titled)
        or (not typed_is_word and any(contraction))
        else margin_word
        if typed_is_word
        else margin_non_word
    )
    ok = (len(typed) > 1 or same) and commit[best] - score[n] > margin
    return strip, words[best][0] if ok else typed


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


TYPOS = (
    "phone-typos",
    "misspellings",
    "text-typos",
    "apostrophes",
    "capitals",
    "homographs",
)


def gain(r):
    return sum(r[f"{n} fixed"] + 0.5 * r[f"{n} top3"] for n in TYPOS) / len(TYPOS)


def main(dev):
    dev = Path(dev)
    sets = {n: items(dev, n) for n in ("clean",) + TYPOS}
    # The replay is the rule only if, at the shipped weights, it commits what the harness did (#568).
    differ = []
    for name, its in sets.items():
        harness = [
            r.split("\t")[2]
            for r in (dev / f"out/sebtype.{name}.tsv").read_text().splitlines()
        ]
        differ += [
            (name, it[0], c, h)
            for it, h in zip(its, harness)
            if (c := decide(it, *SHIPPED)[1]) != h
        ]
    if differ:
        sys.exit(
            f"tune.py's decide() differs from the harness's on {len(differ)} items, e.g. {differ[:5]}"
        )
    best = None
    for params in itertools.product(
        (0, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4),
        (0, 2, 4, 5, 6, 7, 8, 9, 10, 12, 14),
        (-6, -4, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12),
    ):
        r = evaluate(sets, params)
        if r["changed"] <= MAX_CHANGED:
            if not best or gain(r) > best[0]:
                best = (gain(r), params, r)
    if not best:
        sys.exit("no weights keep the changed correct words within the limit")
    print("DECODER_WEIGHT, MARGIN_WORD, MARGIN_NON_WORD =", best[1])
    print(f"GAIN {best[0]:.2f}")
    print(f"SHIPPED {SHIPPED} GAIN {gain(evaluate(sets, SHIPPED)):.2f}")
    for k, v in best[2].items():
        print(f"  {k}: {v:.1f} %")


if __name__ == "__main__":
    main(sys.argv[1])
