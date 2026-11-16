"""Scores the Chinese harness's results (#259).

score.py OUT_DIR                 summary.json of one run (bench.sh's STACK.SET.tsv and .keys files)
score.py --compare RUN1 RUN2     exit 1 unless the quality numbers are equal and per-key p50 within 25 %
score.py --table RUN1 RUN2       the report's table: run 1, with run 2's latency in brackets
score.py --profile OUT_DIR       where a key's time goes, per stack (zhbench's profile=1 .prof files)
"""

import difflib
import json
import sys
from pathlib import Path

SETS = Path(__file__).resolve().parent / "sets"
STACKS = {
    "rime": "Today: Rime, rime-ice + 白霜 + octagram",
    "model": "Rime, re-ranked by SebType's Chinese model",
    "gen": "… and the model's own candidates",
}


def pct(n, d):
    return round(100 * n / d, 1) if d else 0.0


def words_right(target, words, top1):
    """The target's words that the first candidate has, aligned by difflib."""
    matched = set()
    for b in difflib.SequenceMatcher(
        None, target, top1, autojunk=False
    ).get_matching_blocks():
        matched.update(range(b.a, b.a + b.size))
    right, at = 0, 0
    for w in words:
        right += all(i in matched for i in range(at, at + len(w)))
        at += len(w)
    return right


def percentile(xs, p):
    return (
        round(sorted(xs)[min(len(xs) - 1, int(len(xs) * p))] / 1000, 2) if xs else 0.0
    )


def summarise(out):
    out = Path(out)
    summary = {}
    for stack in STACKS:
        files = sorted(out.glob(f"{stack}.*.tsv"))
        if not files:
            continue
        s = summary[stack] = {}
        keys, nxt, rss = [], [], 0
        for f in files:
            name = f.stem.split(".", 1)[1]
            items = [
                l.split("\t")
                for l in (SETS / f"{name}.tsv").read_text(encoding="utf-8").splitlines()
            ]
            rows = [l.split("\t") for l in f.read_text(encoding="utf-8").splitlines()]
            assert len(rows) == len(items), f"{f}: {len(rows)} of {len(items)} items"
            ranks = [int(r[0]) for r in rows]
            n = len(ranks)
            m = {
                "items": n,
                "top1": pct(sum(r == 0 for r in ranks), n),
                "top3": pct(sum(0 <= r < 3 for r in ranks), n),
            }
            if name.startswith("sent-"):
                total = right = 0
                for it, r in zip(items, rows):
                    words = it[3].split(" ")
                    total += len(words)
                    right += words_right(
                        it[2], words, r[3].split("|")[0] if r[3] else ""
                    )
                m["words"] = pct(right, total)
            if name == "typo":
                kinds = {}
                for it, r in zip(items, ranks):
                    k = it[3].split("+")[0] if "+" not in it[3] else "two"
                    kinds.setdefault(k, []).append(r == 0)
                m["top1_by_kind"] = {
                    k: pct(sum(v), len(v)) for k, v in sorted(kinds.items())
                }
            s[name] = m
            times = [l for l in (out / f"{f.name}.keys").read_text().splitlines()]
            rss = max(rss, int(times[-1].split()[1]))
            (nxt if name.startswith("next-") else keys).extend(
                float(t) for t in times[:-1]
            )
        s["key_ms"] = [percentile(keys, 0.5), percentile(keys, 0.95)]
        s["next_ms"] = [percentile(nxt, 0.5), percentile(nxt, 0.95)]
        s["rss_mb"] = round(rss / 1024)
    return summary


def quality(s):
    return {
        st: {k: v for k, v in m.items() if not k.endswith("_ms")} for st, m in s.items()
    }


def compare(a, b):
    a, b = json.loads(Path(a).read_text()), json.loads(Path(b).read_text())
    qa, qb = quality(a), quality(b)
    for st in qa:
        qa[st].pop("rss_mb", None), qb[st].pop("rss_mb", None)
    if qa != qb:
        print("quality differs between the runs")
        return 1
    for st in a:
        p1, p2 = a[st]["key_ms"][0], b[st]["key_ms"][0]
        if abs(p1 - p2) > 0.25 * max(p1, p2):
            print(f"{st}: per-key p50 {p1} vs {p2} ms")
            return 1
    print("same quality, per-key p50 within 25 %")
    return 0


def table(a, b):
    a, b = json.loads(Path(a).read_text()), json.loads(Path(b).read_text())
    stacks = [s for s in STACKS if s in a]
    rows = []

    def row(label, f):
        rows.append(f"| {label} | " + " | ".join(f(s) for s in stacks) + " |")

    for src in ("chat", "news"):
        n = a[stacks[0]][f"sent-{src}"]["items"]
        row(
            f"Sentence right at rank 1, full pinyin ({src}, {n} clauses)",
            lambda s: f"{a[s][f'sent-{src}']['top1']} %",
        )
        row(
            f"Words right in the first candidate ({src})",
            lambda s: f"{a[s][f'sent-{src}']['words']} %",
        )
    for kind, what in (
        ("abbr", "abbreviated, zd → 知道"),
        ("partial", "last syllable abbreviated, ranh → 然后"),
    ):
        for src in ("chat", "news"):
            n = a[stacks[0]][f"{kind}-{src}"]["items"]
            row(
                f"Word first / in the top 3, {what} ({src}, {n})",
                lambda s: (
                    f"{a[s][f'{kind}-{src}']['top1']} / {a[s][f'{kind}-{src}']['top3']} %"
                ),
            )
    n = a[stacks[0]]["typo"]["items"]
    row(
        f"Typo fixed: intended text first / in the top 3 (phone typos and confusions, {n})",
        lambda s: f"{a[s]['typo']['top1']} / {a[s]['typo']['top3']} %",
    )
    for k in a[stacks[0]]["typo"]["top1_by_kind"]:
        row(f"… first, {k}", lambda s: f"{a[s]['typo']['top1_by_kind'][k]} %")
    for src in ("chat", "news"):
        n = a[stacks[0]][f"next-{src}"]["items"]
        row(
            f"Next word in the top 3, nothing typed ({src}, {n})",
            lambda s: f"{a[s][f'next-{src}']['top3']} %",
        )
    row(
        "Per key, ms p50 / p95 (run 2 in brackets)",
        lambda s: (
            f"{a[s]['key_ms'][0]} / {a[s]['key_ms'][1]} ({b[s]['key_ms'][0]} / {b[s]['key_ms'][1]})"
        ),
    )
    row(
        "Per next-word prediction, ms p50 / p95",
        lambda s: f"{a[s]['next_ms'][0]} / {a[s]['next_ms'][1]}",
    )
    row("Peak RSS of the process", lambda s: f"{a[s]['rss_mb']} MB")
    head = "| Measure (set, items) | " + " | ".join(STACKS[s] for s in stacks) + " |"
    print("\n".join([head, "|---|" + "---|" * len(stacks)] + rows))


def profile(out):
    """Mean ms per key of each step, over all keys and over the slowest 5 %, and the decodes per key."""
    for stack in STACKS:
        rows = []
        for f in sorted(Path(out).glob(f"{stack}.*.tsv.prof")):
            lines = f.read_text().splitlines()
            head = lines[0].split("\t")
            rows += [dict(zip(head, map(float, l.split("\t")))) for l in lines[1:]]
        if not rows:
            continue
        steps = head[1:-2]
        for r in rows:
            r["total"] = sum(r[s] for s in steps)
        rows.sort(key=lambda r: r["total"])
        slow = rows[int(len(rows) * 0.95) :]
        print(f"{stack}: {len(rows)} keys, mean ms (slowest 5 %)")
        for s in steps + ["total"]:
            mean = lambda rs: sum(r[s] for r in rs) / len(rs) / 1000
            print(f"  {s:14} {mean(rows):6.2f} ({mean(slow):6.2f})")
        for s in ("decodes", "tokens"):
            mean = lambda rs: sum(r[s] for r in rs) / len(rs)
            print(f"  {s:14} {mean(rows):6.1f} ({mean(slow):6.1f})")


if __name__ == "__main__":
    if sys.argv[1] == "--compare":
        sys.exit(compare(*sys.argv[2:4]))
    if sys.argv[1] == "--table":
        table(*sys.argv[2:4])
    elif sys.argv[1] == "--profile":
        profile(sys.argv[2])
    else:
        print(json.dumps(summarise(sys.argv[1]), ensure_ascii=False, indent=1))
