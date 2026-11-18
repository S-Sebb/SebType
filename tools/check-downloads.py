#!/usr/bin/env python3
"""Fails on a download in the repository that isn't capped at 300 Mbit/s (#365).

The lab's servers share one 1 Gbit/s port, and an uncapped download stalls SSH and the NAS for everyone.
Every curl or wget call needs --limit-rate of at most 35M (curl --limit-rate 35M, wget --limit-rate=35m)
in the same command; the last one counts, as in curl. PowerShell's Invoke-WebRequest and Invoke-RestMethod
can't be capped (use curl.exe), and curl or wget run through a variable can't be checked, so both fail.

It guards against an accidental uncapped download, not a deliberate one: commands are split into words
with a forgiving quote-aware split, not parsed. Heredocs and echo text count as commands, which can only
give a false alarm that a contributor rewords.

    tools/check-downloads.py               the tracked files
    tools/check-downloads.py --self-test   the check's own cases
"""

import re
import subprocess
import sys
from pathlib import Path

CAP = 35 * 1024**2  # bytes a second: 35 MiB, about 294 Mbit/s
POWERSHELL = (
    ".ps1",
    ".psm1",
    ".yml",
    ".yaml",
)  # the workflows' run steps are PowerShell on Windows
DOWNLOADERS = {"curl", "curl.exe", "wget", "wget.exe"}
UNCAPPABLE = {"invoke-webrequest", "iwr", "invoke-restmethod", "irm"}
VIA_VARIABLE = re.compile(r"\$\{?\w*(curl|wget)", re.IGNORECASE)
SIZE = re.compile(r"(\d+(?:\.\d+)?)([kmg]?)", re.IGNORECASE)


def logical_lines(path, text):
    """(first line number, line) with continuation lines (\\, and PowerShell's `) joined."""
    joined, start = "", None
    for n, line in enumerate(text.splitlines(), 1):
        start = start or n
        if line.endswith("\\") or (path.endswith(POWERSHELL) and line.endswith("`")):
            joined += line[:-1] + " "
            continue
        yield start, joined + line
        joined, start = "", None
    if joined:
        yield start, joined


def commands(line, powershell):
    """The line's commands as lists of words, quotes removed, up to an unquoted #. A command ends at an
    unquoted ; & | ( ) { } (and ` outside PowerShell). An unclosed quote runs to the line's end."""
    escape = "`" if powershell else "\\"
    ends = ";&|(){}" + ("" if powershell else "`")
    cmds, words, word, quote = [], [], None, None
    chars = iter(line)
    for c in chars:
        if quote:
            if c == quote:
                quote = None
            elif c == escape and quote == '"':
                word += next(chars, "")
            else:
                word += c
        elif c == escape:
            word = (word or "") + next(chars, "")
        elif c in "'\"":
            quote, word = c, word or ""
        elif c.isspace() or c in ends or (c == "#" and word is None):
            if word is not None:
                words.append(word)
                word = None
            if c == "#":
                break
            if c in ends and words:
                cmds.append(words)
                words = []
        else:
            word = (word or "") + c
    if word is not None:
        words.append(word)
    if words:
        cmds.append(words)
    # A quoted word with spaces may hold commands of its own: bash -c "...", "$(curl ...)".
    return cmds + [
        c for cmd in cmds for w in cmd if " " in w for c in commands(w, powershell)
    ]


def capped(name, args):
    rate = None  # the last --limit-rate wins
    for i, arg in enumerate(args):
        if arg == "--limit-rate":
            rate = args[i + 1] if i + 1 < len(args) else ""
        elif arg.startswith("--limit-rate="):
            rate = (
                arg.split("=", 1)[1] if name.startswith("wget") else ""
            )  # curl has no = form
    size = SIZE.fullmatch(rate or "")
    if not size:
        return False  # none, or a variable or anything else that can't be read here
    return 0 < float(size[1]) * 1024 ** " kmg".index(size[2].lower() or " ") <= CAP


def problems(path, text):
    for n, line in logical_lines(path, text):
        for cmd in commands(line, path.endswith(POWERSHELL)):
            for i, word in enumerate(cmd):
                name, args = word.lower(), cmd[i + 1 :]
                if VIA_VARIABLE.search(word):
                    yield (
                        n,
                        "curl or wget through a variable: call it by name, with --limit-rate",
                    )
                elif name in UNCAPPABLE and args:
                    yield n, f"{word} can't be capped: use curl.exe --limit-rate 35M"
                # A call: the name, then an option, a variable or a URL (not "for x in curl unzip").
                elif (
                    name in DOWNLOADERS
                    and args
                    and args[0].startswith(("-", "$", "http"))
                ):
                    if not capped(name, args):
                        yield n, f"{word} without --limit-rate of 35M or less"


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
    ("a.ps1", "CURL.EXE -sfL -o $f $u", True),
    ("a.ps1", "Curl.Exe -sfL -o $f $u", True),
    ("a.sh", "curl --limit-rate 35M --limit-rate 0 https://e/x", True),
    ("a.sh", 'curl -H "X-Note: --limit-rate 35M" https://e/x', True),
    ("a.sh", 'curl "https://example.com/?a=1&b=2" --limit-rate 35M', False),
    ("a.sh", 'curl -H "X-Tag: a #b" --limit-rate 35M https://e/x', False),
    ("a.ps1", 'curl.exe -H "X-Tag: a #b" --limit-rate 35M $u', False),
    ("a.sh", 'f=$(curl -fsSL "$u")', True),
    ("a.sh", 'f="$(curl --limit-rate 35M -fsSL "$u")"', False),
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
