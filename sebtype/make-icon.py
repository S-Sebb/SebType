#!/usr/bin/env python3
"""Builds SebType's launcher icon resources in sebtype/res-stable, and the PC logo, from assets/icon.png (needs Pillow, NumPy).

- Adaptive foreground (mipmap-*/ic_launcher_pig.png, 108dp): the pig, keyboard and heart cut out of the art's
  black backdrop and glow onto transparency, over SebChat's cream background colour. It is scaled and centred so every part of the subject sits inside the 66dp safe circle.
- Monochrome (drawable/ic_launcher_foreground.xml): the bright parts of the pig and keyboard as a pixel-grid
  vector. FUTO's code also uses this drawable as a tinted silhouette (setup screen, notifications).
- Legacy icons (mipmap-*/ic_launcher.png and ic_launcher_round.png, 48dp): the visible 72dp of the adaptive
  icon, in a rounded square and a circle.
- PC candidate window logo (#94): pc/windows/weasel/sebtype-logo.png and pc/configurator/fcitx5-theme/logo.svg.

`make-icon.py --windows DIR` writes DIR/sebtype.ico (the legacy icon at every Windows size, 16-256 px) and
DIR/pig.png (the cut-out pig) for the Windows installer and Configurator (#73) instead.
"""

import base64
import io
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent.parent
res = root / "sebtype/res-stable"
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
SAFE_RADIUS = 32  # dp of the 108dp canvas; the mask-safe circle is 33dp, one dp spare
BACKGROUND = "#FFE4EC"  # SebChat's launcher background, cream (Decisions #2)
GRID = 144  # monochrome cells across the canvas (0.75dp each)

art = np.asarray(Image.open(root / "assets/icon.png").convert("RGB")).astype(np.float64)
lum = art @ [0.299, 0.587, 0.114]

# Cut the subject out of its black backdrop and dark purple glow. The outline is near-black (darker than the
# glow), so brightness alone can't tell them apart; connectivity can: the backdrop is the dark region joined to
# the corner, the glow is the purple (low green) region joined to that, and dark specks in the glow that touch
# nothing bright are backdrop too. What remains (outline, enclosed shading) is the subject, with a hard edge.
DARK, GLOW, BRIGHT, OUTLINE, BG = 0, 1, 2, 3, 9
glow = (art[..., 1] < 45) & (lum < 80)
cls = np.where(lum < 22, DARK, np.where(glow, GLOW, BRIGHT)).astype(np.uint8)


def fill(cls, kind, touching, value):
    """Set every 4-connected `kind` region next to a `touching` pixel to `value`."""
    img = Image.fromarray(cls).copy()
    while True:
        arr = np.asarray(img)
        t = arr == touching
        near = np.zeros_like(t)
        near[1:] |= t[:-1]
        near[:-1] |= t[1:]
        near[:, 1:] |= t[:, :-1]
        near[:, :-1] |= t[:, 1:]
        seeds = np.argwhere(near & (arr == kind))
        if not len(seeds):
            return arr.copy()
        ImageDraw.floodfill(img, (int(seeds[0][1]), int(seeds[0][0])), value)


img = Image.fromarray(cls).copy()
ImageDraw.floodfill(img, (0, 0), BG)
cls = fill(np.asarray(img), GLOW, BG, BG)
cls = fill(cls, DARK, BRIGHT, OUTLINE)
cls[cls == DARK] = BG
cls = fill(cls, GLOW, BG, BG)
subject = cls != BG

# Centre on the subject's bounding box and scale so its farthest pixel lands on SAFE_RADIUS.
ys, xs = np.nonzero(subject)
cx, cy = (xs.min() + xs.max()) / 2, (ys.min() + ys.max()) / 2
radius = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2).max()
scale = SAFE_RADIUS / radius  # dp per source pixel

rgba = Image.fromarray(np.dstack([art, subject * 255.0]).astype(np.uint8), "RGBA")


def canvas(px_per_dp, image, size_dp=108):
    """image placed on a size_dp canvas so (cx, cy) is its centre, at px_per_dp."""
    px = round(size_dp * px_per_dp)
    s = scale * px_per_dp
    scaled = image.resize(
        (round(image.width * s), round(image.height * s)), Image.LANCZOS
    )
    out = Image.new(image.mode, (px, px))
    out.paste(scaled, (round(px / 2 - cx * s), round(px / 2 - cy * s)))
    return out


def legacy(px, shape="square"):
    """The 48dp legacy icon at px pixels: the visible 72dp of the adaptive icon, rounded square or circle."""
    side = px * 4  # 4x supersampled
    big = canvas(side / 72, rgba)
    full = Image.new("RGBA", big.size, BACKGROUND)
    full.alpha_composite(big)
    off = (full.width - side) // 2
    view = full.crop((off, off, off + side, off + side))
    box = (0, 0, side - 1, side - 1)
    mask = Image.new("L", view.size)
    if shape == "square":
        ImageDraw.Draw(mask).rounded_rectangle(box, side * 0.18, 255)
    else:
        ImageDraw.Draw(mask).ellipse(box, 255)
    icon = Image.new("RGBA", view.size)
    icon.paste(view, mask=mask)
    return icon.resize((px, px), Image.LANCZOS)


if len(sys.argv) == 3 and sys.argv[1] == "--windows":
    # Windows (#73): the phone's icon at every size Windows asks for, each drawn from the art, in one .ico
    # (the installer's and the Configurator's), and the cut-out pig for the installer's pictures.
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    icons = [legacy(px) for px in sizes]
    icons[-1].save(
        out / "sebtype.ico", sizes=[(px, px) for px in sizes], append_images=icons[:-1]
    )
    pig = canvas(512 / 108, rgba)
    pig.crop(pig.getbbox()).save(out / "pig.png", optimize=True)
    sys.exit()

for name, d in DENSITIES.items():
    folder = res / f"mipmap-{name}"
    folder.mkdir(exist_ok=True)
    canvas(d, rgba).save(folder / "ic_launcher_pig.png", optimize=True)
    legacy(round(48 * d)).save(folder / "ic_launcher.png", optimize=True)
    legacy(round(48 * d), "round").save(folder / "ic_launcher_round.png", optimize=True)

# Monochrome: bright parts of the subject (pink, keycaps, keyboard body ~70) without the outline.
bright = Image.fromarray(((subject & (lum > 62)) * 255).astype(np.uint8), "L")
cells = np.asarray(canvas(GRID / 108, bright).resize((GRID, GRID), Image.BOX)) >= 128
cell = 108 / GRID
paths = []
for row in range(GRID):
    line = np.concatenate([[0], cells[row].astype(np.int8), [0]])
    edges = np.flatnonzero(np.diff(line))
    for start, end in zip(edges[::2], edges[1::2]):
        paths.append(
            f"M{start * cell:g},{row * cell:g}h{(end - start) * cell:g}v{cell:g}h{-(end - start) * cell:g}z"
        )
(
    res / "drawable/ic_launcher_foreground.xml"
).write_text(f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by sebtype/make-icon.py from assets/icon.png: SebType's pig as a one-colour silhouette. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#FFFFFF"
        android:pathData="{"".join(paths)}" />
</vector>
""")
print(f"subject radius {radius:.0f}px -> {SAFE_RADIUS}dp; monochrome {len(paths)} runs")

# PC candidate windows (#94): the subject cut to its bounding box, LOGO_HEIGHT px tall. Weasel draws the PNG
# (pc/windows/weasel/sebtype-logo.png); Fcitx5's Picnic theme gets it inside an SVG, so it stays sharp at any
# size and DPI, whose @WIDTH@ and @HEIGHT@ the Configurator sets from the font size.
LOGO_HEIGHT = 160
box = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
pig = rgba.crop(box)
pig = pig.resize(
    (round(pig.width * LOGO_HEIGHT / pig.height), LOGO_HEIGHT), Image.LANCZOS
)
pig.save(root / "pc/windows/weasel/sebtype-logo.png", optimize=True)
png = io.BytesIO()
pig.save(png, "PNG", optimize=True)
(root / "pc/configurator/fcitx5-theme/logo.svg").write_text(
    '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
    f'width="@WIDTH@" height="@HEIGHT@" viewBox="0 0 {pig.width} {pig.height}">'
    f'<image width="{pig.width}" height="{pig.height}" '
    f'xlink:href="data:image/png;base64,{base64.b64encode(png.getvalue()).decode()}"/></svg>\n'
)
print(f"PC logo {pig.width}x{pig.height}")
