"""Writes the text service's tray icons, one .ico per state, from pc/icons.

    python -I make_icons.py RESVG ICONS_DIR OUT_DIR

RESVG is the resvg renderer, ICONS_DIR is pc/icons. Each .ico holds a PNG per tray size Windows uses (100 %
to 400 % scaling): pc/icons' hand-drawn 16, 20, 24 and 32 px drawings, and the 48 px "scalable" drawing for
the rest.
"""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

DRAWN = (16, 20, 24, 32)
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


def main(resvg, icons, out):
    Path(out).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for state in STATES:
            pngs = []
            for size in SIZES:
                svg = (
                    Path(icons)
                    / (str(size) if size in DRAWN else "scalable")
                    / f"{state}.svg"
                )
                png = Path(tmp) / f"{state}-{size}.png"
                subprocess.run(
                    [resvg, "-w", str(size), "-h", str(size), str(svg), str(png)],
                    check=True,
                )
                pngs.append((size, png.read_bytes()))
            (Path(out) / f"{state}.ico").write_bytes(ico(pngs))


if __name__ == "__main__":
    main(*sys.argv[1:])
