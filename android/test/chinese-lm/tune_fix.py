"""Tunes phrase-level correction (#478, core/src/chinese.cpp's kFixMargin and kFixFloor) on the harness's dumps.

  python3 -I tune_fix.py OUT_DIR SETS_DIR [MARGIN FLOOR]

OUT_DIR holds bench.sh --dev's model stack run with dump=1 fix=8 (rankWeight=0.5 generate=2 generatedRank=4,
core's weights): per set, model.dev-SET.tsv (rank, keys, target, …) and its .dump (item, Rime's rank or -1
for the model's own or -2 for a correction, log probability, text). For each set, the share of items with
the target first and on the first page (5) without corrections and with them, ranked as chinese.cpp does:
the model's list by its score less 0.5 · ln(1 + Rime's rank), its own and the correction at rank 4; the
correction first when it beats the list's first by MARGIN (negative: trails it by less than -MARGIN; core's
kFixLead is -MARGIN), else last on the first page when within FLOOR. Only Rime's first correction counts, as
in chinese.cpp. Without MARGIN and FLOOR, a sweep: each pair's slips gain and the clean sets' losses.
"""

import math
import sys
from collections import defaultdict
from pathlib import Path

PAGE = 5
W = 0.5


def load(out, sets, name):
    items = [
        l.split("\t")
        for l in (Path(sets) / f"dev-{name}.tsv")
        .read_text(encoding="utf-8")
        .splitlines()
    ]
    rows = [
        l.split("\t")
        for l in (Path(out) / f"model.dev-{name}.tsv")
        .read_text(encoding="utf-8")
        .splitlines()
    ]
    dump = defaultdict(list)
    for l in (
        (Path(out) / f"model.dev-{name}.tsv.dump")
        .read_text(encoding="utf-8")
        .splitlines()
    ):
        i, r, lp, text = l.split("\t")
        dump[int(i)].append((int(r), float(lp), text))
    out = []
    for i, (it, row) in enumerate(zip(items, rows)):
        target = it[2]
        lit, fixes = [], []
        for r, lp, text in dump[i]:
            if r == -2:
                if not fixes:
                    fixes.append((lp - W * math.log1p(4), text))
            elif not any(t == text for _, t in lit):
                lit.append((lp - W * math.log1p(4 if r < 0 else r), text))
        lit.sort(key=lambda x: -x[0])
        order = [t for _, t in lit]
        rank = order.index(target) if target in order else int(row[0])
        if rank >= 0 and target not in order:
            rank = max(rank, len(order))
        out.append(
            (
                target,
                rank,
                lit[0][0] if lit else None,
                fixes[0] if fixes else None,
                order,
            )
        )
    return out


def ranked(item, margin, floor):
    target, rank, first, fix, order = item
    if fix is None or first is None or (order and order[0] == fix[1]):
        return rank
    lp, text = fix
    if lp > first + margin:
        at = 0
    elif lp > first - floor:
        at = PAGE - 1
    else:
        return rank
    if text in order and order.index(text) <= at:
        return rank
    if text == target:
        return at
    if rank < 0:
        return rank
    moved = text in order and order.index(text) < rank
    return rank + (0 if moved else 1) if at <= rank else rank


def score(data, margin, floor):
    res = {}
    for name, items in data.items():
        ranks = [ranked(it, margin, floor) for it in items]
        n = len(ranks)
        res[name] = (
            100 * sum(r == 0 for r in ranks) / n,
            100 * sum(0 <= r < PAGE for r in ranks) / n,
        )
    return res


def main():
    out, sets = sys.argv[1], sys.argv[2]
    names = sorted(
        p.name[len("model.dev-") : -len(".tsv")]
        for p in Path(out).glob("model.dev-*.tsv")
    )
    data = {n: load(out, sets, n) for n in names}
    base = score(data, math.inf, -math.inf)
    if len(sys.argv) > 4:
        new = score(data, float(sys.argv[3]), float(sys.argv[4]))
        for n in names:
            print(
                f"{n}: {base[n][0]:.1f} / {base[n][1]:.1f} -> {new[n][0]:.1f} / {new[n][1]:.1f}"
            )
        return
    print("margin floor | " + " | ".join(names))
    print("base | " + " | ".join(f"{base[n][0]:.1f}/{base[n][1]:.1f}" for n in names))
    for margin in (1, 0, -0.25, -0.5, -0.75, -1, -1.5, -2, -3):
        for floor in (-math.inf, 2, 3, 4, 5):
            r = score(data, margin, floor)
            print(
                f"{margin} {floor} | "
                + " | ".join(f"{r[n][0]:.1f}/{r[n][1]:.1f}" for n in names)
            )


main()
