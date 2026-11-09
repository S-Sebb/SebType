"""Turns a sebtype/perf.sh run into one Markdown table (printed).

python3 -I table.py WORK_DIR RESULTS_FILE
"""

import csv
import io
import statistics
import sys
from pathlib import Path

work, results = Path(sys.argv[1]), Path(sys.argv[2])


def read(path):
    return path.read_text(encoding="utf-8")


def out(phase):
    try:
        lines = read(work / f"{phase}.out").split("\n")
    except FileNotFoundError:
        return {}
    return dict(l.split("=", 1) for l in lines if "=" in l)


def column(phase, name):
    try:
        rows = list(csv.DictReader(io.StringIO(read(work / f"{phase}.csv"))))
    except FileNotFoundError:
        return []
    return [float(r[name]) for r in rows if r.get(name) not in (None, "", "[NULL]")]


def p(values, unit="ms"):  # "median / p95"
    if not values:
        return "–"
    v = sorted(values)
    return f"{statistics.median(v):.0f} / {v[min(len(v) - 1, round(0.95 * (len(v) - 1)))]:.0f} {unit}"


def mb(kb):
    return f"{int(kb) / 1024:.0f} MB" if kb else "–"


status = {}
for line in read(results).splitlines():
    word, _, rest = line.partition(" ")
    status[rest.split(":")[0].strip()] = word


def row(metric, value, phase=None, note=""):
    s = status.get(phase, "") if phase else ""
    if s in ("FAIL", "SKIP") or (phase and not s):
        value = s or "not run"
    print(f"| {metric} | {value} | {note} |")


i, fo, en, zd, zh, ja, wo, co, sz = (
    out(x)
    for x in (
        "install",
        "first-open",
        "en",
        "zh-deploy",
        "zh",
        "ja",
        "warm-open",
        "cold-open",
        "sizes",
    )
)
fast, long_ = out("fast"), out("long")
lm = column("en", "lm_ms")

print("| Metric | Value | Notes |")
print("|---|---|---|")
row("APK size", f"{out('apk').get('size_mb', '–')} MB", "apk")
row(
    "Installed: code / internal data / external data",
    f"{sz.get('code_mb', '–')} / {sz.get('data_mb', '–')} / {sz.get('external_mb', '–')} MB",
    "sizes",
    "after the whole run: Rime's build/ is in external data",
)
row("Memory (PSS) idle, first open, EN", mb(fo.get("pss_idle_kb")), "first-open")
row("Memory (PSS) after typing EN", mb(en.get("pss_kb")), "en", "transformer loaded")
row("Memory (PSS) peak during Rime deploy", mb(zd.get("pss_peak_kb")), "zh-deploy")
row("Memory (PSS) after typing 中", mb(zh.get("pss_kb")), "zh")
row("Memory (PSS) after typing 日", mb(ja.get("pss_kb")), "ja")
row("Memory (PSS) idle, fresh process, EN", mb(co.get("pss_idle_kb")), "cold-open")
row(
    "Keyboard open, first after install",
    f"{fo.get('open_ms', '–')} ms",
    "first-open",
    "show request → shown",
)
row(
    "Keyboard open, warm, median / p95",
    f"{wo.get('p50_ms', '–')} / {wo.get('p95_ms', '–')} ms",
    "warm-open",
    f"hide, tap the field; n={wo.get('n', 0)}",
)
row(
    "Keyboard open, cold, median / p95",
    f"{co.get('p50_ms', '–')} / {co.get('p95_ms', '–')} ms",
    "cold-open",
    f"switch back from another keyboard, process start → shown; n={co.get('n', 0)}",
)
row(
    "Rime first deploy (rime-ice)",
    f"{zd.get('deploy_s', '–')} s, build/ {zd.get('build_mb', '–')} MB",
    "zh-deploy",
)
for lang, d, name in (("en", en, "EN"), ("zh", zh, "中"), ("ja", ja, "日")):
    n = f"{d.get('keys', 0)} keys"
    row(
        f"{name} key handling (main thread), median / p95",
        p(column(lang, "handle_ms")),
        lang,
        n,
    )
    if lang != "zh":
        row(
            f"{name} key → text on screen, median / p95",
            p(column(lang, "text_ms")),
            lang,
        )
    row(
        f"{name} key → candidates drawn, median / p95",
        p(column(lang, "settle_ms")),
        lang,
        "last keyboard frame before the next key (700 ms apart)",
    )
row(
    "EN transformer CPU per key it ran on, median / p95",
    p([x for x in lm if x > 0]),
    "en",
    # FUTO waits 350 ms for the transformer and turns it off after 6 misses in a row.
    f"ran on {sum(x > 0 for x in lm)} of {len(lm)} keys, {sum(x > 350 for x in lm)} over FUTO's "
    "350 ms limit; after 6 misses in a row FUTO turns it off until the next text field",
)
for name, d, ph, note in (
    ("Fast typing", fast, "fast", "100 ms per key"),
    ("Long field", long_, "long", "20,000 characters, 100 ms per key"),
):
    jank, frames = sum(column(ph, "app_jank")), sum(column(ph, "frames"))
    row(
        f"{name}: janky frames keyboard / field (gfxinfo)",
        f"{d.get('ime_janky_pct', '–')}% / {d.get('field_janky_pct', '–')}%",
        ph,
        f"{note}; p95 frame {d.get('ime_p95_ms', '–')} / {d.get('field_p95_ms', '–')} ms",
    )
    row(
        f"{name}: frames late because of the app (frame timeline)",
        f"{jank:.0f} of {frames:.0f}",
        ph,
    )
    row(
        f"{name}: key → text on screen, median / p95",
        p(column(ph, "text_ms")),
        ph,
        f"{d.get('typed', '–')} of {d.get('taps', '–')} characters arrived within 5 s",
    )

phases = (("EN", en), ("中", zh), ("日", ja), ("fast", fast), ("long", long_))
row(
    "Keyboard crashes while typing",
    ", ".join(f"{name} {d.get('crashes', '–')}" for name, d in phases),
    None,
    "keyboard process deaths during each typing trace",
)

print("\nBiggest APK entries (compressed):\n")
for line in read(work / "apk-top.txt").splitlines():
    print(f"- {line.strip()}")
