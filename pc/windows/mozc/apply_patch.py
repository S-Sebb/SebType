"""Applies a git-style unified diff exactly, with no fuzz: YukaROG has no git or patch.

    python -I apply_patch.py PATCH DIR

Every hunk's context and removed lines must match the file at the hunk's line number, else it stops.
"""

import re
import sys
from pathlib import Path


def apply(patch, root):
    lines = Path(patch).read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        if not lines[i].startswith("+++ b/"):
            i += 1
            continue
        path = Path(root) / lines[i][6:]
        old = path.read_text(encoding="utf-8").split("\n")
        new, pos = [], 0
        i += 1
        while i < len(lines) and lines[i].startswith("@@"):
            start = int(re.match(r"@@ -(\d+)", lines[i])[1]) - 1
            new += old[pos:start]
            pos = start
            i += 1
            while i < len(lines) and lines[i][:1] in (" ", "-", "+", "\\"):
                tag, text = lines[i][:1], lines[i][1:]
                if tag in " -":
                    if old[pos] != text:
                        sys.exit(f"{path}:{pos + 1}: patch doesn't match: {text!r}")
                    pos += 1
                if tag in " +":
                    new.append(text)
                i += 1
        path.write_text("\n".join(new + old[pos:]), encoding="utf-8", newline="\n")


if __name__ == "__main__":
    apply(*sys.argv[1:])
