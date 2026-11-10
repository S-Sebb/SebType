#!/usr/bin/env python3
"""Windows .ico files from SebType's tray icons (pc/icons, Set E) for SebType's Weasel.

    make-icons.py OUT_DIR    # needs rsvg-convert and Pillow

Each size uses the drawing made for it (16, 20, 24, 32 px), larger ones the 48 px scalable drawing,
so Windows picks a sharp one at 100-200 % scaling. Entries are 32-bit DIBs, which every Windows
icon loader reads.
"""

import io
import struct
import subprocess
import sys
from pathlib import Path

from PIL import Image

ICONS = Path(__file__).resolve().parents[2] / "icons"
SIZES = {
    16: "16",
    20: "20",
    24: "24",
    32: "32",
    40: "scalable",
    48: "scalable",
    64: "scalable",
}
# Weasel's icon file: SebType state (pc/icons/README.md)
FILES = {"zh.ico": "zh", "en.ico": "zh-a", "en_caps.ico": "zh-A"}


def render(svg: Path, size: int) -> Image.Image:
    png = subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), str(svg)],
        check=True,
        capture_output=True,
    ).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")


def dib(im: Image.Image) -> bytes:
    w, h = im.size
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    rows = [
        im.crop((0, y, w, y + 1)).tobytes("raw", "BGRA") for y in reversed(range(h))
    ]
    mask = bytes(((w + 31) // 32) * 4 * h)  # all opaque: the alpha channel decides
    return header + b"".join(rows) + mask


def ico(images: list[Image.Image]) -> bytes:
    blobs = [dib(im) for im in images]
    out = struct.pack("<HHH", 0, 1, len(blobs))
    offset = 6 + 16 * len(blobs)
    for im, blob in zip(images, blobs):
        w, h = im.size
        out += struct.pack(
            "<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(blob), offset
        )
        offset += len(blob)
    return out + b"".join(blobs)


def main() -> None:
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, state in FILES.items():
        images = [render(ICONS / d / f"{state}.svg", s) for s, d in SIZES.items()]
        (out / name).write_bytes(ico(images))


if __name__ == "__main__":
    main()
