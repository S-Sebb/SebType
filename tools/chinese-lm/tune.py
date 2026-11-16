"""Tunes how the model's scores and Rime's order combine, on the dev sets only (make_sets.py --dev), never on
the harness's test sets.

  tune.py DEV_DIR DUMP_DIR

DUMP_DIR holds zhbench's results for the dev sets with dump=1 and the widest settings (bench.sh --dev ...
rerank=10 generate=W): for each item, every candidate the model scored, with Rime's rank (-1: the model's own)
and its log probability. Prints the best rerank, rankWeight and generatedRank (as zhbench's NAME=VALUE) for the
mean top-1 over the dev sets of typed text, and that mean, beside Rime's own order.
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
    best, best_score = None, -math.inf
    for rank, lp, text in pool:
        if rank >= rerank or (rank < 0 and generated is None):
            continue
        r = generated if rank < 0 else rank
        s = lp - weight * math.log1p(r)
        if s > best_score:
            best, best_score = text, s
    return best


def mean_top1(sets, *args):
    per = {
        n: sum(first(p, *args) == t for t, p in items) / len(items)
        for n, items in sets.items()
    }
    return sum(per.values()) / len(per), per


def main(dev, dumps):
    sets = load(dev, dumps)
    rime = {
        n: sum(any(r == 0 and x == t for r, _, x in p) for t, p in items) / len(items)
        for n, items in sets.items()
    }
    print(
        f"Rime's order: mean top-1 {100 * sum(rime.values()) / len(rime):.1f} "
        + " ".join(f"{n} {100 * v:.1f}" for n, v in rime.items())
    )
    grid = itertools.product(
        [1, 2, 3, 4, 6, 8, 10],
        [0, 0.5, 1, 1.5, 2, 3, 4, 6, 8],
        [None, 0, 2, 4, 8, 12, 16],
    )
    best = max(grid, key=lambda g: mean_top1(sets, *g)[0])
    m, per = mean_top1(sets, *best)
    print(
        f"best: rerank={best[0]} rankWeight={best[1]} generatedRank={best[2]} (None: without the model's own): mean top-1 {100 * m:.1f} "
        + " ".join(f"{n} {100 * v:.1f}" for n, v in per.items())
    )
    no_gen = max(
        itertools.product(
            [1, 2, 3, 4, 6, 8, 10], [0, 0.5, 1, 1.5, 2, 3, 4, 6, 8], [None]
        ),
        key=lambda g: mean_top1(sets, *g)[0],
    )
    m, per = mean_top1(sets, *no_gen)
    print(
        f"best without the model's own: rerank={no_gen[0]} rankWeight={no_gen[1]}: mean top-1 {100 * m:.1f} "
        + " ".join(f"{n} {100 * v:.1f}" for n, v in per.items())
    )


if __name__ == "__main__":
    main(*sys.argv[1:3])
