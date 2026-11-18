#!/usr/bin/env python3
"""Fails on a download in the repository that isn't capped at 300 Mbit/s (#365).

The lab's servers share one 1 Gbit/s port, and an uncapped download stalls SSH and the NAS for everyone.
Every curl or wget call needs --limit-rate of at most 35M (curl --limit-rate 35M, wget --limit-rate=35m)
in the same command: continuation lines (\\, and PowerShell's `) count, comments don't. PowerShell's
Invoke-WebRequest and Invoke-RestMethod can't be capped (use curl.exe), and curl or wget run through a
variable can't be checked, so both fail.

    tools/check-downloads.py               the tracked files
    tools/check-downloads.py --self-test   the check's own cases
"""

import re
import subprocess
import sys
from pathlib import Path

CAP = 35 * 1024**2  # bytes a second: 35 MiB, about 294 Mbit/s
POWERSHELL = (".ps1", ".psm1", ".yml", ".yaml")
# A call: the name at the start of a command or word, then an option, a quoted or variable argument, or a URL.
CALL = re.compile(
    r"""(?:^|(?<=[\s(;|&{`!"'\\]))(curl|curl\.exe|wget|wget\.exe)\s+(?=[-"'$]|https?:)"""
)
UNCAPPABLE = re.compile(
    r"(?:^|(?<=[\s(;|&{`!\"']))(invoke-webrequest|iwr|invoke-restmethod|irm)\s",
    re.IGNORECASE,
)
VIA_VARIABLE = re.compile(r"\$\{?\w*(curl|wget)", re.IGNORECASE)
RATE = re.compile(r"--limit-rate(=|\s+)(\S+)")
SIZE = re.compile(r"""["']?(\d+(?:\.\d+)?)([kmg]?)(?![\w.$])""", re.IGNORECASE)


def logical_lines(path, text):
    """(first line number, command) with comments gone and continuation lines joined."""
    joined, start = "", None
    for n, line in enumerate(text.splitlines(), 1):
        line = re.sub(r"(^|\s)#.*", "", line).rstrip()
        start = start or n
        if line.endswith("\\") or (path.endswith(POWERSHELL) and line.endswith("`")):
            joined += line[:-1] + " "
            continue
        yield start, joined + line
        joined, start = "", None
    if joined:
        yield start, joined


def capped(name, args):
    m = RATE.search(args)
    if not m or (m[1] == "=" and not name.startswith("wget")):
        return False
    size = SIZE.match(m[2])
    if not size:
        return False  # a variable or anything else that can't be read here
    rate = float(size[1]) * 1024 ** " kmg".index(size[2].lower() or " ")
    return 0 < rate <= CAP


def problems(path, text):
    for n, line in logical_lines(path, text):
        if VIA_VARIABLE.search(line):
            yield (
                n,
                "curl or wget through a variable: call it by name, with --limit-rate",
            )
        if UNCAPPABLE.search(line):
            yield (
                n,
                "Invoke-WebRequest or Invoke-RestMethod can't be capped: use curl.exe --limit-rate 35M",
            )
        calls = list(CALL.finditer(line))
        for i, m in enumerate(calls):
            # The call's arguments: up to the next command (a pipe, ; or &) or the next call.
            end = calls[i + 1].start() if i + 1 < len(calls) else len(line)
            args = re.split(r"[|;&]", line[m.end() : end])[0]
            if not capped(m[1], args):
                yield n, f"{m[1]} without --limit-rate of 35M or less"


SELF_TEST = [  # (file name, text, fails)
    ("a.sh", "curl --limit-rate 35M -fsSL -o x https://e/x", False),
    ("a.sh", "curl -fsSL -o x https://e/x", True),
    ("a.sh", "curl \\\n  -fsSL -o x https://e/x", True),
    ("a.sh", "curl \\\n  --limit-rate 35M -fsSL -o x https://e/x", False),
    ("a.ps1", "curl.exe `\n  -sfL -o $f $u", True),
    ("a.ps1", "curl.exe `\n  --limit-rate 35M -sfL -o $f $u", False),
    ("a.ps1", "Invoke-Webrequest $u -OutFile $f", True),
    ("a.ps1", "$x = (iwr 'https://e/x')", True),
    ("a.sh", 'curl=curl\n"$curl" --limit-rate 35M https://e/x', True),
    ("a.sh", '"${curl[@]}" https://e/x', True),
    ("a.sh", "curl --limit-rate 0 -fsSL https://e/x", True),
    ("a.sh", "curl --limit-rate 36M https://e/x", True),
    ("a.sh", "curl --limit-rate 100k https://e/x", False),
    ("a.sh", 'curl --limit-rate "$rate" https://e/x', True),
    ("a.sh", "curl -fsSL https://e/x  # add --limit-rate later", True),
    ("a.sh", "curl -fsSL https://e/x \\\n  # --limit-rate 35M", True),
    ("a.sh", 'wget --limit-rate=35m "$u"', False),
    ("a.sh", 'wget --limit-rate=1g "$u"', True),
    ("a.sh", "curl --limit-rate=35M https://e/x", True),  # curl has no = form
    ("a.sh", 'curl --limit-rate 35M -fsSL "$1" | ${4:-cat} > f', False),
    ("a.sh", "curl -fsSL a | wget --limit-rate=1m b", True),
    ("a.sh", 'bash -c "curl -fsSL https://e/x"', True),
    ("a.sh", "for x in python3 curl unzip; do :; done", False),
    ("a.sh", "# curl ... -o FILE URL", False),
    ("a.md", "It needs Python and curl, and the sources.", False),
]


def main():
    if sys.argv[1:] == ["--self-test"]:
        wrong = [(f, t) for f, t, fails in SELF_TEST if any(problems(f, t)) != fails]
        for f, t in wrong:
            print(f"FAIL check-downloads-self-test: {f}: {t!r}")
        if wrong:
            return 1
        print("PASS check-downloads-self-test")
        return 0
    root = Path(__file__).resolve().parent.parent
    # The tracked text files that name one at all (git grep is fast, the dictionaries are large).
    files = subprocess.run(
        ["git", "-C", root, "grep", "-lzIiE", "curl|wget|invoke-|iwr|irm"],
        capture_output=True,
        check=True,
    ).stdout
    found = []
    for name in files.decode().split("\0"):
        path = root / name
        if not name or name == "tools/check-downloads.py" or not path.is_file():
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        found += [f"{name}:{n}: {why}" for n, why in problems(name, text)]
    if found:
        print("FAIL downloads-capped:", *found, sep="\n")
        return 1
    print("PASS downloads-capped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
