"""Names each character perf.sh's fast typing lost, added or swapped (#49).

    python3 -I textdiff.py TAPPED FIELD_FILE [FILLER_CHARS]

TAPPED is the text tapped, FIELD_FILE holds the field's text afterwards and FILLER_CHARS is the test
field's starting filler (PerfField's "chars" extra). Prints "ok", or one line per difference with its
position in the typed text, and exits 1. Case is ignored: the field capitalises sentence starts.
"""

import difflib
import sys
from pathlib import Path

tapped, field = sys.argv[1], Path(sys.argv[2]).read_text(encoding="utf-8").rstrip("\n")
chars = int(sys.argv[3]) if len(sys.argv) > 3 else 0
filler = ""
while len(filler) < chars:  # as PerfField builds it
    filler += "The quick brown fox jumps over the lazy dog. "
want, got = (filler + tapped).lower(), field.lower()

ops = [
    o
    for o in difflib.SequenceMatcher(None, want, got, autojunk=False).get_opcodes()
    if o[0] != "equal"
]
diffs = []
while ops:
    op, i1, i2, j1, j2 = ops.pop(0)
    at = f"at {i1 - len(filler) + 1} after {want[max(len(filler), i1 - 12) : i1]!r}"
    # A key that arrived late shows as an insert and a delete of the same text next to each other.
    nxt = ops[0] if ops else None
    if (
        nxt
        and {op, nxt[0]} == {"insert", "delete"}
        and nxt[1] - i2 <= 1
        and (want[i1:i2] or got[j1:j2])
        == (want[nxt[1] : nxt[2]] or got[nxt[3] : nxt[4]])
    ):
        ops.pop(0)
        diffs.append(
            f"out of order: {want[i1 : nxt[2]]!r} became {got[j1 : nxt[4]]!r} {at}"
        )
    elif op == "delete":
        diffs.append(f"missing {want[i1:i2]!r} {at}")
    elif op == "insert":
        diffs.append(f"extra {got[j1:j2]!r} {at}")
    else:
        diffs.append(f"{want[i1:i2]!r} became {got[j1:j2]!r} {at}")
print("\n".join(diffs) or "ok")
sys.exit(1 if diffs else 0)
