"""Writes SebType's Mozc tray icons (#65) as .ico files over upstream Mozc's, from pc/icons.

    python -I make_icons.py RESVG ICONS_DIR MOZC_SRC

RESVG is the resvg renderer, ICONS_DIR is pc/icons, MOZC_SRC is Mozc's src folder. Each .ico holds a PNG
per tray size Windows uses (100 % to 400 % scaling): pc/icons' hand-drawn 16, 20, 24 and 32 px drawings,
and the 48 px "scalable" drawing for the rest.
"""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

DRAWN = (16, 20, 24, 32)
SIZES = (16, 20, 24, 32, 40, 48, 64)

# Mozc's icon file -> SebType state (pc/icons/<size>/<state>.svg). Mozc's direct input, half and full
# width alphanumeric and disabled modes are all English; sebtype_english_upper.ico is new, for Caps Lock.
ICONS = {
    "ms_direct_input_a.ico": "ja-a",
    "ms_alpha_half_a.ico": "ja-a",
    "ms_alpha_a.ico": "ja-a",
    "ms_disabled_a.ico": "ja-a",
    "sebtype_english_upper.ico": "ja-A",
    "ms_hiragana_a.ico": "hira",
    "ms_katakana_a.ico": "kata",
    "ms_katakana_half_a.ico": "kata",
}


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


def main(resvg, icons, src):
    out = Path(src) / "data/images/win"
    with tempfile.TemporaryDirectory() as tmp:
        for name, state in ICONS.items():
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
            (out / name).write_bytes(ico(pngs))


if __name__ == "__main__":
    main(*sys.argv[1:])
