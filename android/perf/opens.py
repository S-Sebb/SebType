"""Keyboard open times from opens.sql's rows for one perf.sh trace.

    python3 -I opens.py first|warm|cold OPENS.csv     (CSV of kind,ms from opens.sql)

first: the first open after install, from the test field's first frame to the keyboard's first frame.
warm:  each tap on the test field to the keyboard's first frame, with the keyboard's process running.
cold:  each keyboard process start to its first frame (switching back from another keyboard).
"""

import csv
import io
import statistics
import sys
from pathlib import Path

kind, path = sys.argv[1], sys.argv[2]
ms = [
    float(r["ms"])
    for r in csv.DictReader(io.StringIO(Path(path).read_text(encoding="utf-8")))
    if r["kind"] == kind and r["ms"] not in ("", "[NULL]")
]
if not ms:
    sys.exit(f"no {kind} keyboard open (request → keyboard frame) in the trace")
if kind == "first":
    print(f"open_ms={ms[0]:.0f}")
else:
    ms.sort()
    print(
        f"n={len(ms)}\np50_ms={statistics.median(ms):.0f}\n"
        f"p95_ms={ms[min(len(ms) - 1, round(0.95 * (len(ms) - 1)))]:.0f}\nmax_ms={ms[-1]:.0f}"
    )
