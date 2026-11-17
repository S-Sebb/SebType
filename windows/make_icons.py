"""Writes the text service's tray icons, one .ico per state, from pc/icons.

    python -I make_icons.py ICONS_DIR OUT_DIR

ICONS_DIR is pc/icons. Each .ico holds pc/icons' PNG for every tray size Windows uses (100 % to 400 %
scaling), each drawn at its own pixel size, so Windows never has to scale one (#275).
"""

import struct
import sys
from pathlib import Path

SIZES = (16, 20, 24, 32, 40, 48, 64)
STATES = (
    "zh",
    "zh-a",
    "zh-caps",
    "hira",
    "kata",
    "ja-a",
    "ja-caps",
    "zh-wait",
    "zh-off",
    "hira-wait",
    "hira-off",
)


def ico(pngs):
    """An .ico file whose entries are PNGs (supported since Windows Vista)."""
    head = struct.pack("<HHH", 0, 1, len(pngs))
    offset, entries = len(head) + 16 * len(pngs), b""
    for size, data in pngs:
        entries += struct.pack(
            "<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset
        )
        offset += len(data)
    return head + entries + b"".join(data for _, data in pngs)


def main(icons, out):
    Path(out).mkdir(parents=True, exist_ok=True)
    for state in STATES:
        pngs = [
            (size, (Path(icons) / str(size) / f"{state}.png").read_bytes())
            for size in SIZES
        ]
        (Path(out) / f"{state}.ico").write_bytes(ico(pngs))


if __name__ == "__main__":
    main(*sys.argv[1:])
