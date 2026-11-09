"""Keyboard open times from the ImeTracker and ActivityManager log lines of a perf.sh trace.

    python3 -I opens.py first|warm|cold LOGS.csv     (CSV of ts,msg from perf.sh's ime_logs)

first: the first open after install, from the show request (and from the process start) to shown.
warm:  each show request to shown, with the keyboard's process running.
cold:  each keyboard process start to the next shown (switching back from another keyboard).
"""

import csv
import io
import statistics
import sys
from pathlib import Path

kind, path = sys.argv[1], sys.argv[2]
rows = [
    (int(r["ts"]), r["msg"])
    for r in csv.DictReader(io.StringIO(Path(path).read_text(encoding="utf-8")))
]
requests, starts, opens = {}, [], []
for ts, msg in rows:
    if msg.startswith("Start proc"):
        starts.append(ts)
        continue
    token, _, event = msg.partition(": ")
    if event.startswith("onRequestShow"):
        requests[token] = ts
    elif event.startswith("onShown") and token in requests:
        start = requests.pop(token)
        process = max((s for s in starts if s <= ts), default=None)
        opens.append(
            ((ts - start) / 1e6, None if process is None else (ts - process) / 1e6)
        )
        starts = [s for s in starts if s > ts]  # each process start counts once

if not opens:
    sys.exit("no keyboard open (onRequestShow → onShown) in the trace")
if kind == "first":
    print(f"open_ms={opens[0][0]:.0f}")
    if opens[0][1] is not None:
        print(f"from_process_start_ms={opens[0][1]:.0f}")
else:
    ms = sorted(
        o[0] if kind == "warm" else o[1]
        for o in opens
        if kind == "warm" or o[1] is not None
    )
    if not ms:
        sys.exit("no keyboard process start before an open")
    print(
        f"n={len(ms)}\np50_ms={statistics.median(ms):.0f}\n"
        f"p95_ms={ms[min(len(ms) - 1, round(0.95 * (len(ms) - 1)))]:.0f}\nmax_ms={ms[-1]:.0f}"
    )
