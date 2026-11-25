"""#556 eval: cmp.py OUT_DIR... — rows right per stack and set, then the owner's rows one by one."""

import sys
from pathlib import Path


def rows(d, stack, s):
    f = Path(d) / f"{stack}.{s}.tsv"
    return [l.split("\t") for l in f.read_text().splitlines()] if f.exists() else None


dirs = sys.argv[1:]
names = [Path(d).name for d in dirs]
print("| set (stack) | " + " | ".join(names) + " |")
print("|---" * (len(dirs) + 1) + "|")
for s in ("contractions", "homographs", "owner", "lone-i"):
    for stack in ("core", "sebtype"):
        cells = []
        for d in dirs:
            r = rows(d, stack, s)
            cells.append(f"{sum(x[1] == x[2] for x in r)}/{len(r)}" if r else "-")
        print(f"| {s} ({stack}) | " + " | ".join(cells) + " |")
for stack in ("core", "sebtype"):
    cells = []
    for d in dirs:
        r = rows(d, stack, "next-contr")
        cells.append(
            str(sum(any(w.endswith("'") for w in x[3].split(",") if w) for x in r))
            if r
            else "-"
        )
    print(f"| next-contr rows with a half word ({stack}) | " + " | ".join(cells) + " |")

ctx = [
    l.split("\t")[0]
    for l in (Path(__file__).parent / "sets/owner.tsv").read_text().splitlines()
]
print("\nOwner's rows, core stack (committed):\n")
print("| context | typed | want | " + " | ".join(names) + " |")
print("|---" * (len(dirs) + 3) + "|")
res = [rows(d, "core", "owner") for d in dirs]
for i, c in enumerate(ctx):
    r0 = res[0][i]
    cells = [r[i][2] if r[i][2] == r[i][1] else f"**{r[i][2]}** ✗" for r in res]
    print(f"| {c or '(none)'} | {r0[0]} | {r0[1]} | " + " | ".join(cells) + " |")
