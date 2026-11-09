#!/usr/bin/env python3
"""Writes SebType's tray icons (#63, "Set E" sticker keycap) as SVGs: pc/icons/<size>/<state>.svg.

Each size is drawn on its own pixel grid: 16, 20, 22, 24 and 32 px are hand-tuned, and "scalable" is a 48 px
drawing with the design's full proportions, for larger and HiDPI sizes. Glyphs are font outlines, so the
SVGs need no font: Noto Sans CJK Black (中 あ ア, from the system's Noto Sans CJK VF) and Nunito ExtraBold
(EN a A, sebtype/res/font), both OFL. Needs fontTools. Linux installs them as an icon theme (pc/linux/setup-ime.sh);
Windows reuses them (#13, #65).
"""

from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTCollection, TTFont
from fontTools.varLib.instancer import instantiateVariableFont

HERE = Path(__file__).resolve().parent
NOTO_CJK = "/usr/share/fonts/google-noto-sans-cjk-vf-fonts/NotoSansCJK-VF.ttc"


def cjk(index, chars):
    f = TTCollection(NOTO_CJK).fonts[index]
    s = Subsetter(Options())
    s.populate(text=chars)
    s.subset(f)
    return instantiateVariableFont(f, {"wght": 900})


FONTS = {
    "sc": cjk(2, "中"),
    "jp": cjk(0, "あア"),
    "lat": TTFont(HERE.parents[1] / "sebtype/res/font/sebtype_nunito_extrabold.ttf"),
}


def glyph(font, text):
    gs, cmap = font.getGlyphSet(), font.getBestCmap()
    pen, bp, x = SVGPathPen(gs), BoundsPen(gs), 0
    for ch in text:
        n = cmap[ord(ch)]
        gs[n].draw(TransformPen(pen, (1, 0, 0, -1, x, 0)))
        gs[n].draw(TransformPen(bp, (1, 0, 0, -1, x, 0)))
        x += gs[n].width - (60 if len(text) > 1 else 0)  # tighten "EN" a little
    return pen.getCommands(), bp.bounds


def place(g, box, h, stroke_px):
    """Glyph ink h px tall (or narrower to fit the box), centred in box, with a round stroke of stroke_px."""
    d, (xmin, ymin, xmax, ymax) = g
    s = h / (ymax - ymin)
    bw = box[2] - box[0]
    if (xmax - xmin) * s > bw:
        s = bw / (xmax - xmin)
    tx = (box[0] + box[2]) / 2 - (xmax - xmin) * s / 2 - xmin * s
    ty = (box[1] + box[3]) / 2 - (ymax - ymin) * s / 2 - ymin * s
    return f'<path transform="matrix({s:.5f} 0 0 {s:.5f} {tx:.3f} {ty:.3f})" stroke-width="{stroke_px / s:.2f}" d="{d}"/>'


INK, OUTLINE, STICKER, LIP, BLUSH = (
    "#4A2F22",
    "#5B331C",
    "#FFF8E8",
    "#F2DCC4",
    "#F2899E",
)
BASE = {
    "zh": ("#F6A9B9", "#E07A92"),
    "ja": ("#F9C252", "#EC962A"),
    "en": ("#CDBBF0", "#9D86D8"),
}  # key base top/bottom
STATES = {  # state: language, (font, text)
    "en": ("en", ("lat", "EN")),  # US layout
    "zh": ("zh", ("sc", "中")),
    "zh-a": ("zh", ("lat", "a")),  # Chinese, English mode
    "zh-A": ("zh", ("lat", "A")),  # ... with Caps Lock
    "hira": ("ja", ("jp", "あ")),
    "kata": ("ja", ("jp", "ア")),
    "ja-a": ("ja", ("lat", "a")),  # Japanese, English mode
    "ja-A": ("ja", ("lat", "A")),  # ... with Caps Lock
}
GLYPHS = {g: glyph(FONTS[g[0]], g[1]) for _, g in STATES.values()}
SIZES = {"16": 16, "20": 20, "22": 22, "24": 24, "32": 32, "scalable": 48}


def params(S):
    """Pixels for sticker border, shadow, outline, base side, flare, face inset, lip: whole pixels at tray sizes."""
    table = {
        16: (1, 0, 1, 2, 0, 0, 0),
        20: (1, 1, 1, 3, 0, 0, 1),
        22: (1, 1, 1, 4, 1, 1, 1),
        24: (1, 1, 1, 4, 1, 1, 1),
        32: (2, 2, 2, 5, 2, 2, 2),
    }
    return table.get(S) or tuple(
        S * f for f in (0.06, 0.03, 0.032, 0.19, 0.06, 0.03, 0.035)
    )


def trap(x0, y0, x1, y1, t, r):
    """Rounded trapezoid: top edge inset by t on each side (the key flares toward its base)."""
    return (
        f"M{x0 + t + r} {y0} H{x1 - t - r} Q{x1 - t} {y0} {x1 - t + t * r / max(y1 - y0, 1)} {y0 + r} L{x1} {y1 - r} Q{x1} {y1} {x1 - r} {y1} "
        f"H{x0 + r} Q{x0} {y1} {x0} {y1 - r} L{x0 + t - t * r / max(y1 - y0, 1)} {y0 + r} Q{x0 + t} {y0} {x0 + t + r} {y0} Z"
    )


def sticker(S, lang, g):
    sb, sh, bw, side, t, fi, lip = params(S)
    blush = S >= 20  # at 16 px the cheeks would cost the glyph a pixel
    H = S - sh
    r = S * 0.24
    top, bot = BASE[lang]
    o = [
        (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}"><defs>'
            f'<linearGradient id="s" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bot}"/></linearGradient>'
            f'<linearGradient id="f" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFCF5"/><stop offset="1" stop-color="#FFF1E2"/></linearGradient>'
            f'<filter id="b" x="-30%" y="-30%" width="160%" height="180%"><feGaussianBlur stdDeviation="{max(0.5, S / 40)}"/></filter></defs>'
        )
    ]
    if sh:  # soft shadow under the sticker
        o.append(
            f'<path d="{trap(0.5, sh, S - 0.5, H + sh * 0.6, t, r + sb)}" fill="{OUTLINE}" opacity="0.35" filter="url(#b)"/>'
        )
    o.append(
        f'<path d="{trap(0, 0, S, H, t, r + sb)}" fill="{STICKER}"/>'
    )  # sticker border
    o.append(
        f'<path d="{trap(sb, sb, S - sb, H - sb, t, r)}" fill="{OUTLINE}"/>'
    )  # key outline
    k0, k1, ky0, ky1 = sb + bw, S - sb - bw, sb + bw, H - sb - bw
    o.append(
        f'<path d="{trap(k0, ky0, k1, ky1, t, max(r - bw, 0))}" fill="url(#s)"/>'
    )  # coloured base
    if S >= 32:  # glint on the base, lower left
        o.append(
            f'<ellipse cx="{k0 + S * 0.1}" cy="{ky1 - side * 0.45}" rx="{S * 0.035}" ry="{S * 0.06}" fill="#FFFFFF" opacity="0.45"/>'
        )
    fx0, fx1, fy0, fy1 = k0 + t + fi, k1 - t - fi, ky0, ky1 - side
    rf = max(r - bw - fi, 0) * 0.9
    if S >= 22:  # top face with its own outline and a beige lip at its bottom
        o.append(
            f'<rect x="{fx0 - bw}" y="{fy0}" width="{fx1 - fx0 + 2 * bw}" height="{fy1 - fy0 + bw}" rx="{rf + bw}" fill="{OUTLINE}"/>'
        )
        o.append(
            f'<rect x="{fx0}" y="{fy0}" width="{fx1 - fx0}" height="{fy1 - fy0}" rx="{rf}" fill="{LIP}"/>'
        )
        o.append(
            f'<rect x="{fx0}" y="{fy0}" width="{fx1 - fx0}" height="{fy1 - fy0 - lip}" rx="{rf}" fill="url(#f)"/>'
        )
        fy1 -= lip
    else:  # 16/20 px: no inner outline; a darker rim where the top meets the base, so the glyph keeps its pixels
        o.append(
            f'<rect x="{fx0}" y="{fy0}" width="{fx1 - fx0}" height="{fy1 - fy0 + 1}" rx="{rf}" fill="{bot}"/>'
        )
        o.append(
            f'<rect x="{fx0}" y="{fy0}" width="{fx1 - fx0}" height="{fy1 - fy0}" rx="{rf}" fill="url(#f)"/>'
        )
    fw, fh = fx1 - fx0, fy1 - fy0
    if S >= 22:  # shine, top left
        cx, cy = fx0 + fw * 0.13, fy0 + fh * 0.2
        o.append(
            f'<ellipse cx="{cx}" cy="{cy}" rx="{S * 0.05}" ry="{S * 0.03}" fill="#FFFFFF" transform="rotate(-40 {cx} {cy})"/>'
        )
    margin = (fw * 0.17 if S >= 32 else fw * 0.1) if blush else fw * 0.06
    if blush and S >= 32:  # two short slanted dashes each side, as in the concept
        sw = S * 0.045
        ln = S * 0.05
        by = fy0 + fh * 0.62
        for side_x in (fx0 + fw * 0.085, fx1 - fw * 0.085):
            for dx in (-S * 0.035, S * 0.035):
                x = side_x + dx
                o.append(
                    f'<line x1="{x - ln * 0.35}" y1="{by + ln * 0.5}" x2="{x + ln * 0.35}" y2="{by - ln * 0.5}" stroke="{BLUSH}" '
                    f'stroke-width="{sw}" stroke-linecap="round"/>'
                )
    elif blush:  # 20-24 px: the dashes would merge into a strike-through, so one soft cheek per lower corner
        rx, ry = 1.3, 0.9
        for cx in (fx0 + rx + 0.3, fx1 - rx - 0.3):
            o.append(
                f'<ellipse cx="{cx}" cy="{fy1 - ry - 0.6}" rx="{rx}" ry="{ry}" fill="{BLUSH}" opacity="0.85"/>'
            )
    box = (fx0 + margin, fy0 + fh * 0.04, fx1 - margin, fy1 - fh * 0.04)
    gh = fh * (0.8 if g[0] != "lat" else 0.66 if g[1] != "a" else 0.6)
    o.append(
        f'<g fill="{INK}" stroke="{INK}" stroke-linejoin="round" stroke-linecap="round">'
        f"{place(GLYPHS[g], box, gh, 0.4 if S < 24 else S * 0.022)}</g></svg>\n"
    )
    return "".join(o)


for folder, S in SIZES.items():
    (HERE / folder).mkdir(exist_ok=True)
    for state, (lang, g) in STATES.items():
        (HERE / folder / f"{state}.svg").write_text(sticker(S, lang, g))
