"""Scores the English harness's runs.

  score.py RUN_DIR             a JSON summary of every STACK.SET.tsv in RUN_DIR
  score.py --compare S1 S2     exit 0 if two runs' results (every row but its latency) and quality numbers are equal
  score.py --table S1 S2 [T]   the baseline table in Markdown, run 1's numbers with run 2's latency next to them,
                               and today's from T (today.json) in the first column
  score.py --bar S T           exit 0 if the keyboard's English passes the plan's quality bar (§2) against
                               today's in T (today.json: the FUTO-based app's, measured before it was removed)

Each row of a result is: typed, target, committed word, top 3 of the strip, microseconds per key, and after
how many keys the target was first in the top 3 (0: never).
- Typo sets (phone-typos, text-typos, misspellings, and #556's contractions, apostrophes, homographs and
  capitals, where the intended word may be the typed one): fixed = a space commits the intended word; top1 / top3 = the
  intended word is first / among the first three suggestions. homographs' kept fixed / restored fixed: fixed
  over the rows whose target is the typed word / its contraction. capitalised: how many commits are the
  intended word with a capital it doesn't have ("O'Clock" for "o'clock").
- clean: changed = a space commits something other than the correct word that was typed; saved = keystrokes
  saved by tapping the word once it is in the top 3 (its letters so far and the tap, against all its letters
  and the space; the tap adds the space).
- next-chat, next-news, next-texts: top3 = the next word is among the three predictions with nothing typed.
Rates are percentages with one decimal. Latency: per key p50 / p95 and per word (all its keys) p50 / p95,
in milliseconds, over the typed sets; per prediction for the next-word sets.
"""

import json
import sys
from pathlib import Path


def pct(n, d):
    return round(100 * n / d, 1) if d else None


def quantile(v, q):
    v = sorted(v)
    return round(v[min(len(v) - 1, int(q * len(v)))] / 1000, 2) if v else None


QUALITY = ("changed", "fixed", "top1", "top3", "items")
STACKS = (
    ("today", "Today (2026-11-17, frozen): FUTO's decoder + transformer"),
    ("aosp", "Pristine AOSP decoder + AOSP's dictionary"),
    ("sebtype", "Pristine AOSP decoder + SebType's model"),
    ("core", "New keyboard: core/'s English + rebuilt dictionary"),
)


def compare(s1, s2):
    """Every row's results (all but its microseconds) and every quality number must match. Latency differs
    between runs and is left to the table and the perf checks."""
    da, db = Path(s1).parent, Path(s2).parent
    a, b = json.loads(Path(s1).read_text()), json.loads(Path(s2).read_text())
    problems = []
    names = sorted({f.name for d in (da, db) for f in d.glob("*.*.tsv")})
    for name in names:
        ra, rb = [
            [r.split("\t") for r in (d / name).read_text().splitlines()]
            if (d / name).exists()
            else []
            for d in (da, db)
        ]
        diff = [
            (i, x, y)
            for i, (x, y) in enumerate(zip(ra, rb), 1)
            if x[:4] + x[5:] != y[:4] + y[5:]
        ]
        if diff:
            i, x, y = diff[0]
            problems.append(
                f"{name}: {len(diff)} rows differ, first row {i} (typed {x[0]!r}): "
                f"committed, top 3, shown after {x[2]} | {x[3]} | {x[5]} vs {y[2]} | {y[3]} | {y[5]}"
            )
        if len(ra) != len(rb):
            problems.append(f"{name}: {len(ra)} vs {len(rb)} rows")
    for stack in sorted(set(a) | set(b)):
        for set_name in sorted(set(a.get(stack, {})) | set(b.get(stack, {}))):
            x, y = (
                a.get(stack, {}).get(set_name, {}),
                b.get(stack, {}).get(set_name, {}),
            )
            for k in QUALITY + ("saved",):
                if x.get(k) != y.get(k):
                    problems.append(f"{stack} {set_name} {k}: {x.get(k)} vs {y.get(k)}")
    if not names:
        problems.append("the runs have no results")
    print("\n".join(problems) or "every row's results and every quality number equal")
    return not problems


def table(s1, s2, today=None):
    a, b = json.loads(Path(s1).read_text()), json.loads(Path(s2).read_text())
    if today:
        a.update(json.loads(Path(today).read_text()))
        b.update(json.loads(Path(today).read_text()))
    cols = [k for k, _ in STACKS if k in a]

    def row(label, set_name, fmt):
        cells = []
        for k in cols:
            x, y = a[k].get(set_name), b[k].get(set_name)
            cells.append(fmt(x, y) if x else "–")
        print(f"| {label} | " + " | ".join(cells) + " |")

    n = lambda s: f"{next(a[k][s] for k in cols if s in a[k])['items']:,}"
    print(
        "| Measure (set, items) | " + " | ".join(dict(STACKS)[k] for k in cols) + " |"
    )
    print("|---|" + "---|" * len(cols))
    for s, name in (
        ("phone-typos", "phone typos"),
        ("text-typos", "phone typos in text messages"),
        ("misspellings", "Wikipedia misspellings"),
    ):
        row(
            f"Typo fixed: a space commits the intended word ({name}, {n(s)})",
            s,
            lambda x, y: f"{x['fixed']} %",
        )
        row(
            f"Intended word first / in the top 3 ({name})",
            s,
            lambda x, y: f"{x['top1']} / {x['top3']} %",
        )
    for s, name in (
        ("contractions", "contractions typed without the apostrophe"),
        ("apostrophes", "contractions in sentences, typed without it"),
        ("homographs", "bare forms that are words too; kept / restored in brackets"),
        ("capitals", "capitalised words"),
    ):
        row(
            f"Right word committed ({name}, {n(s)})",
            s,
            lambda x, y: (
                f"{x['fixed']} %"
                + (
                    f" ({x['kept fixed']} / {x['restored fixed']})"
                    if "kept fixed" in x
                    else ""
                )
            ),
        )
    row(
        f"Correct word wrongly changed (clean words, {n('clean')})",
        "clean",
        lambda x, y: f"{x['changed']} %",
    )
    for s, name in (
        ("next-chat", "chat sentences"),
        ("next-news", "news sentences"),
        ("next-texts", "text messages"),
    ):
        row(
            f"Next word in the top 3, nothing typed ({name}, {n(s)} words)",
            s,
            lambda x, y: f"{x['top3']} %",
        )
    row(
        "Keystrokes saved by tapping the word once in the top 3 (clean words)",
        "clean",
        lambda x, y: f"{x['saved']} %",
    )
    lat = lambda p50, p95: lambda x, y: f"{x[p50]} / {x[p95]} ({y[p50]} / {y[p95]})"
    for s, name in (("clean", "clean words"), ("phone-typos", "phone typos")):
        row(
            f"Per key, ms p50 / p95 ({name}; run 2 in brackets)",
            s,
            lat("key_ms_p50", "key_ms_p95"),
        )
        row(
            f"Per word, all its keys, ms p50 / p95 ({name})",
            s,
            lat("word_ms_p50", "word_ms_p95"),
        )
    row(
        "Per next-word prediction, ms p50 / p95 (chat)",
        "next-chat",
        lat("ms_p50", "ms_p95"),
    )


def bar(path, today_path):
    """The plan's quality bar (§2): the keyboard's English against today's, one line per gated row."""
    today = json.loads(Path(today_path).read_text())["today"]
    summary = json.loads(Path(path).read_text())
    ours, aosp = summary["core"], summary["aosp"]
    checks = []
    for set_name in ("phone-typos", "misspellings", "text-typos"):
        for k in ("fixed", "top1", "top3"):
            checks.append(
                (
                    f"{set_name} {k} >= today - 2",
                    ours[set_name][k],
                    today[set_name][k] - 2,
                    1,
                )
            )
    checks.append(
        (
            "clean changed <= today",
            ours["clean"]["changed"],
            today["clean"]["changed"],
            -1,
        )
    )
    for set_name in ("next-chat", "next-news", "next-texts"):
        checks.append(
            (
                f"{set_name} top3 >= 90 % of today",
                ours[set_name]["top3"],
                round(0.9 * today[set_name]["top3"], 1),
                1,
            )
        )
    # #556's sets: today.json has no numbers for them, so the bar is AOSP's decoder alone, in the same run.
    for set_name, k in (
        ("contractions", "fixed"),
        ("apostrophes", "fixed"),
        ("homographs", "kept fixed"),
        ("homographs", "restored fixed"),
        ("capitals", "fixed"),
    ):
        checks.append(
            (f"{set_name} {k} >= AOSP's", ours[set_name][k], aosp[set_name][k], 1)
        )
    # A contraction committed in a title's case, "O'Clock" for "o'clock" (#556).
    capitalised = lambda s: sum(
        s[n]["capitalised"] for n in ("contractions", "apostrophes", "homographs")
    )
    checks.append(
        (
            "contractions, apostrophes, homographs capitalised wrongly <= AOSP's",
            capitalised(ours),
            capitalised(aosp),
            -1,
        )
    )
    for set_name in ("clean", "phone-typos"):
        checks.append(
            (
                f"{set_name} per-key p95 <= today",
                ours[set_name]["key_ms_p95"],
                today[set_name]["key_ms_p95"],
                -1,
            )
        )
    ok = True
    for name, value, limit, sign in checks:
        passed = (value - limit) * sign >= 0
        ok &= passed
        print(f"{'PASS' if passed else 'FAIL'} {name}: {value} (bar {limit})")
    return ok


def main(run_dir):
    summary = {}
    for f in sorted(Path(run_dir).glob("*.tsv")):
        stack, set_name = f.name.split(".")[:2]
        rows = [line.split("\t") for line in f.read_text().splitlines()]
        keys = [int(t) for r in rows for t in r[4].split(",")]
        words = [sum(int(t) for t in r[4].split(",")) for r in rows]
        top3 = [r[3].split(",") if r[3] else [] for r in rows]
        s = {"items": len(rows)}
        if set_name.startswith("next-"):
            s["top3"] = pct(
                sum(r[1].lower() in [w.lower() for w in t] for r, t in zip(rows, top3)),
                len(rows),
            )
            s["ms_p50"], s["ms_p95"] = quantile(keys, 0.5), quantile(keys, 0.95)
        else:
            if set_name == "clean":
                s["changed"] = pct(sum(r[2] != r[1] for r in rows), len(rows))
                full = sum(len(r[1]) + 1 for r in rows)
                spent = sum(int(r[5]) + 1 if int(r[5]) else len(r[1]) + 1 for r in rows)
                s["saved"] = pct(full - spent, full)
            else:
                s["fixed"] = pct(sum(r[2] == r[1] for r in rows), len(rows))
                s["capitalised"] = sum(
                    r[2] != r[1]
                    and r[2].lower() == r[1].lower()
                    and any(c.isupper() and t.islower() for c, t in zip(r[2], r[1]))
                    for r in rows
                )
                if set_name == "homographs":
                    # Keeping every typed word fixes most rows: the rows that keep it and those that restore
                    # the apostrophe are barred apart.
                    for k, same in (("kept", True), ("restored", False)):
                        part = [r for r in rows if (r[0] == r[1]) == same]
                        s[f"{k} fixed"] = pct(
                            sum(r[2] == r[1] for r in part), len(part)
                        )
                s["top1"] = pct(
                    sum(t[:1] == [r[1]] for r, t in zip(rows, top3)), len(rows)
                )
                s["top3"] = pct(sum(r[1] in t for r, t in zip(rows, top3)), len(rows))
            s["key_ms_p50"], s["key_ms_p95"] = quantile(keys, 0.5), quantile(keys, 0.95)
            s["word_ms_p50"], s["word_ms_p95"] = (
                quantile(words, 0.5),
                quantile(words, 0.95),
            )
        summary.setdefault(stack, {})[set_name] = s
    json.dump(summary, sys.stdout, indent=1, sort_keys=True)
    print()


if __name__ == "__main__":
    if sys.argv[1] == "--compare":
        sys.exit(0 if compare(*sys.argv[2:4]) else 1)
    elif sys.argv[1] == "--bar":
        sys.exit(0 if bar(*sys.argv[2:4]) else 1)
    elif sys.argv[1] == "--table":
        table(*sys.argv[2:5])
    else:
        main(sys.argv[1])
