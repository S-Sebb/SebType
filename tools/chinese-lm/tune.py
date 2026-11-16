"""Tunes how the model's scores and Rime's order combine, on the dev sets only (make_sets.py --dev), never on
the harness's test sets.

  tune.py DEV_DIR DUMP_DIR...

Each DUMP_DIR holds zhbench's results for the dev sets with dump=1, rerank=10 and one beam width (bench.sh
--dev ... rerank=10 generate=W): for each item, Rime's first 10 candidates and the model's own, each with the
model's log probability. A smaller rerank is simulated by dropping Rime's later candidates and adding back the
model's own that only those matched, as zhbench does; a beam width needs a dump of its own, as a wider search
doesn't contain a narrower one's results. Prints, per DUMP_DIR, the best rerank, rankWeight and generatedRank
(as zhbench's NAME=VALUE) for the mean top-1 over the dev sets of typed text, and that mean, beside Rime's own
order and the best without the model's own candidates.
"""

import itertools
import math
import sys
from collections import defaultdict
from pathlib import Path


def load(dev, dumps):
    sets = {}
    for f in sorted(Path(dumps).glob("model.dev-*.tsv.dump")):
        name = f.name.split(".")[1]
        if name.startswith("dev-next"):
            continue
        targets = [
            l.split("\t")[2]
            for l in (Path(dev) / f"{name}.tsv")
            .read_text(encoding="utf-8")
            .splitlines()
        ]
        pools = defaultdict(list)
        for line in f.read_text(encoding="utf-8").splitlines():
            item, rank, lp, text = line.split("\t", 3)
            pools[int(item)].append((int(rank), float(lp), text))
        sets[name] = [(t, pools[i]) for i, t in enumerate(targets)]
    return sets


def first(pool, rerank, weight, generated):
    """zhbench's first candidate: the first best of Rime's first RERANK, then the model's own not among them."""
    rime = [(lp - weight * math.log1p(r), t) for r, lp, t in pool if 0 <= r < rerank]
    if generated is not None:
        seen = {t for _, t in rime}
        rime += [
            (lp - weight * math.log1p(generated), t)
            for r, lp, t in pool
            if r < 0 and t not in seen
        ]
    return max(rime, key=lambda c: c[0], default=(0, None))[1]


def mean_top1(sets, *args):
    per = {
        n: sum(first(p, *args) == t for t, p in items) / len(items)
        for n, items in sets.items()
    }
    return sum(per.values()) / len(per), per


def main(dev, *dumps):
    base = load(dev, dumps[0])
    rime = {
        n: sum(any(r == 0 and x == t for r, _, x in p) for t, p in items) / len(items)
        for n, items in base.items()
    }
    print(
        f"Rime's order: mean top-1 {100 * sum(rime.values()) / len(rime):.1f} "
        + " ".join(f"{n} {100 * v:.1f}" for n, v in rime.items())
    )
    for d in dumps:
        sets = load(dev, d)
        grid = itertools.product(
            [1, 2, 3, 4, 6, 8, 10],
            [0, 0.5, 1, 1.5, 2, 3, 4, 6, 8],
            [0, 2, 4, 8, 12, 16],
        )
        best = max(grid, key=lambda g: mean_top1(sets, *g)[0])
        m, per = mean_top1(sets, *best)
        print(
            f"{d}: rerank={best[0]} rankWeight={best[1]} generatedRank={best[2]}: mean top-1 {100 * m:.1f} "
            + " ".join(f"{n} {100 * v:.1f}" for n, v in per.items())
        )
    no_gen = max(
        itertools.product(
            [1, 2, 3, 4, 6, 8, 10], [0, 0.5, 1, 1.5, 2, 3, 4, 6, 8], [None]
        ),
        key=lambda g: mean_top1(base, *g)[0],
    )
    m, per = mean_top1(base, *no_gen)
    print(
        f"best without the model's own: rerank={no_gen[0]} rankWeight={no_gen[1]}: mean top-1 {100 * m:.1f} "
        + " ".join(f"{n} {100 * v:.1f}" for n, v in per.items())
    )


if __name__ == "__main__":
    main(*sys.argv[1:])
