#!/usr/bin/env python3
"""The Windows installer's pictures (#73, look B "Picnic"), into OUT_DIR:

    pc/windows/setup/pictures.py OUT_DIR

- sebtype.ico and pig.png: the phone's icon at every Windows size and the cut-out pig (art/make-icon.py).
- cloth.png: SebChat's checkered picnic cloth with its pixel flowers, the wizard's background.
- welcome-{1,2}.png, finish-{1,2}.png: the cream card on the left of the welcome and finish pages (164 x 314
  at 100 % and 200 % scale): the pig on pink, "SebType", and the languages or the tray keys.
- small-{1,2}.png: the pig in the top right corner of the other pages (55 x 55).

Needs Pillow, NumPy, rsvg-convert (the tray keys, pc/icons) and Noto Sans CJK (the card's 中文 日本語).
"""

import glob
import io
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
subprocess.run(
    [sys.executable, str(root / "art/make-icon.py"), "--windows", str(out)],
    check=True,
)
pig = Image.open(out / "pig.png").convert("RGBA")

# Picnic's colours (pc/configurator/ui/theme.slint).
CREAM, CHECK, CARD, OUTLINE, INK, LINE, PINK = (
    "#FBE9D6",
    "#F8E2CC",
    "#FFF7E8",
    "#5B331C",
    "#4A2F22",
    "#ECD0AE",
    "#FDE0E6",
)
JERSEY = root / "art/fonts/Jersey10-Regular.ttf"
cjk = next(
    f
    for pattern in (
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
        "/usr/share/fonts/google-noto-sans-cjk*/NotoSansCJK-*.ttc",
    )
    for f in sorted(glob.glob(pattern))
)

# The cloth as SebChat's app draws it (look.rs): 32 px checks, three four-petal flowers, 2 image pixels per
# cloth pixel. Inno tiles it behind every page.
tile = Image.new("RGB", (64, 64), CREAM)
d = ImageDraw.Draw(tile)
d.rectangle((0, 0, 31, 31), CHECK)
d.rectangle((32, 32, 63, 63), CHECK)
for x, y, petals, middle in (
    (10, 12, "#F4B6C2", "#F0B443"),
    (44, 50, "#C9B6EF", "#F0B443"),
    (50, 16, "#F4B6C2", "#FFFFFF"),
):
    for dx, dy in ((0, -1), (-1, 0), (1, 0), (0, 1)):
        d.point((x + dx, y + dy), petals)
    d.point((x, y), middle)
tile = tile.resize((128, 128), Image.NEAREST)
cloth = Image.new("RGB", (640, 512))
for y in range(0, cloth.height, tile.height):
    for x in range(0, cloth.width, tile.width):
        cloth.paste(tile, (x, y))
cloth.save(out / "cloth.png", optimize=True)


def frame(w, h, u):
    """SebChat's PixelBorder: notched brown outline, white highlight, sand lowlight, hard shadow; u = one pixel."""
    img = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(img)
    r, b = w - u, h - u
    shadow = (0x5B, 0x33, 0x1C, 0x30)
    d.rectangle((r, 3 * u, r + u - 1, b + u - 1), shadow)
    d.rectangle((3 * u, b, r - 1, b + u - 1), shadow)
    d.rectangle((u, u, r - u - 1, b - u - 1), CARD)
    d.rectangle((u, b - 2 * u, r - u - 1, b - u - 1), LINE)
    d.rectangle((r - 2 * u, u, r - u - 1, b - u - 1), LINE)
    d.rectangle((u, u, r - u - 1, 2 * u - 1), "#FFFFFF")
    d.rectangle((u, u, 2 * u - 1, b - u - 1), "#FFFFFF")
    d.rectangle((u, 0, r - u - 1, u - 1), OUTLINE)
    d.rectangle((u, b - u, r - u - 1, b - 1), OUTLINE)
    d.rectangle((0, u, u - 1, b - u - 1), OUTLINE)
    d.rectangle((r - u, u, r - 1, b - u - 1), OUTLINE)
    return img


def key(state, px):
    """One Set E tray key (pc/icons, the 48 px drawing) at px pixels."""
    png = subprocess.run(
        [
            "rsvg-convert",
            "-w",
            str(px),
            "-h",
            str(px),
            str(root / f"pc/icons/scalable/{state}.svg"),
        ],
        check=True,
        capture_output=True,
    ).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")


for s in (1, 2):
    w, h = 164 * s, 314 * s
    middle = (w - 6 * s) // 2
    for name in ("welcome", "finish"):
        card = Image.new("RGBA", (w, h))
        card.alpha_composite(frame(w - 8 * s, h - 16 * s, 2 * s), (4 * s, 8 * s))
        d = ImageDraw.Draw(card)
        d.rectangle((14 * s, 20 * s, w - 20 * s, 150 * s), PINK)
        p = pig.resize(
            (128 * s, round(128 * s * pig.height / pig.width)), Image.NEAREST
        )
        card.alpha_composite(
            p, ((w - 6 * s - p.width) // 2, 24 * s + (126 * s - p.height) // 2)
        )
        d.text(
            (middle, 178 * s),
            "SebType",
            font=ImageFont.truetype(JERSEY, 34 * s),
            fill=INK,
            anchor="mm",
        )
        if name == "finish":
            k = 40 * s
            for i, state in enumerate(("en", "zh", "hira")):
                card.alpha_composite(key(state, k), (12 * s + i * (k + 4 * s), 205 * s))
            d.text(
                (middle, 268 * s),
                "Win + Space",
                font=ImageFont.truetype(JERSEY, 22 * s),
                fill=INK,
                anchor="mm",
            )
        else:
            font = ImageFont.truetype(cjk, 14 * s, index=0)
            try:  # the variable Noto Sans CJK (Fedora): its Bold, as Ubuntu's static file
                font.set_variation_by_name("Bold")
            except OSError:
                pass
            for i, line in enumerate(("中文", "日本語", "English")):
                d.text(
                    (middle, (216 + i * 22) * s), line, font=font, fill=INK, anchor="mm"
                )
        card.save(out / f"{name}-{s}.png", optimize=True)
    small = Image.new("RGBA", (55 * s, 55 * s))
    p = pig.resize((52 * s, round(52 * s * pig.height / pig.width)), Image.NEAREST)
    small.alpha_composite(
        p, ((small.width - p.width) // 2, (small.height - p.height) // 2)
    )
    small.save(out / f"small-{s}.png", optimize=True)
