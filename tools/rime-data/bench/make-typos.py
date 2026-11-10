"""Makes the typo sets (#46) from the clean full-pinyin clauses of 2-8 characters in sets/*-sent.tsv.

  python3 -I make-typos.py SETS_DIR            # writes typo-phone.tsv and typo-pc.tsv into SETS_DIR
  python3 -I make-typos.py SETS_DIR --dev DIR  # tuning sets from the other half of the clauses

Even clauses make the test sets, odd ones the dev sets, so tuning never sees a test clause. The error
mix follows the #46 study:
- typo-phone: phone typing (Palin et al. 2019): of the errors 6 % are swaps, the rest 55.6 % touch
  slips, 33.3 % missing and 11.1 % extra letters; 10 % of clauses have two errors. A slip is a tap with
  Gaussian scatter (sigma 1.9 mm) around the key centre on SebType's QWERTY grid (rows of 10/9/7 keys,
  offset 0 / 0.5 / 1.5 keys, key pitch 108 x 160 px on a 1080 px phone, about 6.8 x 10.1 mm), drawn
  until it lands on another key.
- typo-pc: desktop typing (Dhakal et al. 2018): 47 % neighbour keys on an ANSI staggered layout (keys
  within 1.25 key pitches), 26 % missing, 21 % extra and 6 % swapped letters; one error each.
"""

import random
import sys

ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
PHONE = {
    k: ((i + (0, 0.5, 1.5)[r]) * 108 + 54, r * 160 + 80)
    for r, row in enumerate(ROWS)
    for i, k in enumerate(row)
}
ANSI = {
    k: (i + (0, 0.25, 0.75)[r], r)
    for r, row in enumerate(ROWS)
    for i, k in enumerate(row)
}
SIGMA_PX = 1.9 / (6.8 / 108)


def near(pos, x, y):
    return min(pos, key=lambda k: (pos[k][0] - x) ** 2 + (pos[k][1] - y) ** 2)


def ansi_neighbours(k):
    x, y = ANSI[k]
    return [
        j
        for j, (a, b) in ANSI.items()
        if j != k and (a - x) ** 2 + (b - y) ** 2 <= 1.25**2
    ]


def slip(rng, k):
    while True:
        x, y = PHONE[k]
        j = near(PHONE, rng.gauss(x, SIGMA_PX), rng.gauss(y, SIGMA_PX))
        if j != k:
            return j


def typo(rng, s, kind, pc):
    i = rng.randrange(len(s))
    if kind == "sub":
        return (
            s[:i]
            + (rng.choice(ansi_neighbours(s[i])) if pc else slip(rng, s[i]))
            + s[i + 1 :]
        )
    if kind == "omit":
        return s[:i] + s[i + 1 :]
    if kind == "insert":  # the key doubled, or a neighbour hit with it, on either side
        extra = (
            s[i]
            if rng.random() < 0.5
            else (rng.choice(ansi_neighbours(s[i])) if pc else slip(rng, s[i]))
        )
        return (
            s[:i] + extra + s[i:]
            if rng.random() < 0.5
            else s[: i + 1] + extra + s[i + 1 :]
        )
    j = [p for p in range(len(s) - 1) if s[p] != s[p + 1]]  # swap
    i = rng.choice(j)
    return s[:i] + s[i + 1] + s[i] + s[i + 2 :]


def make(rng, clauses, n, pc):
    kinds, weights = (
        (["sub", "omit", "insert", "swap"], [47, 26, 21, 6])
        if pc
        else (
            ["sub", "omit", "insert", "swap"],
            [55.6 * 0.94, 33.3 * 0.94, 11.1 * 0.94, 6],
        )
    )
    out = []
    while len(out) < n:
        keys, text = rng.choice(clauses)
        typed = keys
        for _ in range(2 if not pc and rng.random() < 0.1 else 1):
            typed = typo(rng, typed, rng.choices(kinds, weights)[0], pc)
        if typed != keys:
            out.append(f"{typed}\t{text}\n")
    return out


def main():
    sets, dev = sys.argv[1], sys.argv[3] if sys.argv[2:3] == ["--dev"] else None
    pools = {}
    for src in ("chat", "news"):
        with open(f"{sets}/{src}-sent.tsv", encoding="utf-8") as f:
            lines = [l.rstrip("\n").split("\t") for l in f]
        lines = [l for l in lines if 2 <= len(l[1]) <= 8]
        pools[src] = lines[1 if dev else 0 :: 2]
    rng = random.Random(4600 if dev else 46)
    # 5 chat to 3 news, as the study's phone mix (500 chat + 300 news).
    for name, pc in (("typo-phone", False), ("typo-pc", True)):
        n = 300 if dev else 800
        items = make(rng, pools["chat"], n * 5 // 8, pc) + make(
            rng, pools["news"], n - n * 5 // 8, pc
        )
        with open(
            f"{dev or sets}/{'dev-' if dev else ''}{name}.tsv", "w", encoding="utf-8"
        ) as f:
            f.writelines(items)
    if dev:
        clean = rng.sample(pools["chat"], 150) + rng.sample(pools["news"], 150)
        with open(f"{dev}/dev-clean.tsv", "w", encoding="utf-8") as f:
            f.writelines(f"{k}\t{t}\n" for k, t in clean)


main()
