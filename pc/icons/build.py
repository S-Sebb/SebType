#!/usr/bin/env python3
"""Writes SebType's tray icons (#63, "Set E" sticker keycap): pc/icons/<size>/<state>.png and
pc/icons/scalable/<state>.svg.

Each tray size (16 to 66 px, SIZES) is drawn at its own pixel size, not scaled from a larger drawing (#275: a
large drawing scaled down had soft grey edges), by the same rules at every size (#441): the key's parts are
params()'s shares of the size in whole pixels, at least one each, so a 16 px key is a 66 px key shrunk; its
edges fall on whole pixels and only round corners shade their edge pixels. The glyph is drawn from its
strokes' centrelines (LINES, traced from the fonts' glyphs) with one pen for every glyph at a size (stroke()),
its strokes placed on the pixel grid by HINTS so they keep whole pixels and the font's counters
(topology()); 中 and A are their own
mirror images and every glyph is centred in the face to the pixel. The blush keeps a clear pixel from the
glyph. check() fails the build on any drawing that breaks these rules. "scalable" is a
48 px vector drawing with the design's full proportions, for other sizes; its glyphs are font outlines, so it
needs no font. Fonts: Noto Sans CJK Black (中 あ ア, from the system's Noto Sans CJK VF) and Nunito ExtraBold
(EN a A, android/app/src/main/res/font), both OFL. Needs fontTools, Pillow and pycairo. Linux's RPM installs them in
hicolor (linux/CMakeLists.txt); Windows' .ico files hold the PNGs (windows/make_icons.py, #13, #65).
"""

import io
import sys
from functools import cache
from math import pi
from pathlib import Path

import cairo
import numpy as np
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.cairoPen import CairoPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTCollection, TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
NOTO_CJK = "/usr/share/fonts/google-noto-sans-cjk-vf-fonts/NotoSansCJK-VF.ttc"
NUNITO = HERE.parents[1] / "android/app/src/main/res/font/sebtype_nunito_extrabold.ttf"


def cjk(index, chars):
    f = TTCollection(NOTO_CJK).fonts[index]
    s = Subsetter(Options())
    s.populate(text=chars)
    s.subset(f)
    return instantiateVariableFont(f, {"wght": 900})


FONTS = {
    "sc": cjk(2, "中"),
    "jp": cjk(0, "あア"),
    "lat": TTFont(NUNITO),
}


def draw(font, text, pen):
    gs, cmap = font.getGlyphSet(), font.getBestCmap()
    x = 0
    for ch in text:
        n = cmap[ord(ch)]
        gs[n].draw(TransformPen(pen, (1, 0, 0, -1, x, 0)))
        x += gs[n].width - (60 if len(text) > 1 else 0)  # tighten "EN" a little


def glyph(font, text):
    pen, bp = SVGPathPen(font.getGlyphSet()), BoundsPen(font.getGlyphSet())
    draw(font, text, pen)
    draw(font, text, bp)
    return pen.getCommands(), bp.bounds


def fit(g, box, h):
    """The scale and offset that make a glyph's ink h px tall (or narrower to fit the box), centred in box."""
    _, (xmin, ymin, xmax, ymax) = g
    s = min(h / (ymax - ymin), (box[2] - box[0]) / (xmax - xmin))
    tx = (box[0] + box[2]) / 2 - (xmax + xmin) * s / 2
    ty = (box[1] + box[3]) / 2 - (ymax + ymin) * s / 2
    return s, tx, ty


def place(g, box, h, stroke_px):
    """Glyph ink h px tall (or narrower to fit the box), centred in box, with a round stroke of stroke_px."""
    s, tx, ty = fit(g, box, h)
    return f'<path transform="matrix({s:.5f} 0 0 {s:.5f} {tx:.3f} {ty:.3f})" stroke-width="{stroke_px / s:.2f}" d="{g[0]}"/>'


INK, OUTLINE, STICKER, LIP, BLUSH, FACE = (
    "#4A2F22",
    "#5B331C",
    "#FFF8E8",
    "#F2DCC4",
    "#F2899E",
    "#FFF8EE",  # the pixel drawings' top face, one colour
)
BASE = {
    "grey": ("#D9D3CE", "#AFA6A0"),  # a language that isn't ready (#275)
    "zh": ("#F6A9B9", "#E07A92"),
    "ja": ("#F9C252", "#EC962A"),
    "en": ("#CDBBF0", "#9D86D8"),
}  # key base top/bottom
STATES = {  # state: language, (font, text)
    "en": ("en", ("lat", "EN")),  # US layout
    "zh": ("zh", ("sc", "中")),
    "zh-a": ("zh", ("lat", "a")),  # Chinese, English mode
    "zh-caps": ("zh", ("lat", "A")),  # ... with Caps Lock
    "hira": ("ja", ("jp", "あ")),
    "kata": ("ja", ("jp", "ア")),
    "ja-a": ("ja", ("lat", "a")),  # Japanese, English mode
    "ja-caps": ("ja", ("lat", "A")),  # ... with Caps Lock
    # Not ready (#275): the key in grey with a badge, "…" while it prepares (Rime deploying), "!" while it
    # can't take keys (the server doesn't answer, Mozc didn't load).
    "zh-wait": ("grey", ("sc", "中")),
    "zh-off": ("grey", ("sc", "中")),
    "hira-wait": ("grey", ("jp", "あ")),
    "hira-off": ("grey", ("jp", "あ")),
}
BADGE = {"wait": "#C2506A", "off": "#B03030"}
GREY_INK = "#7D706A"
SYMMETRIC = {"中", "A"}  # drawn as their own mirror images
GLYPHS = {g: glyph(FONTS[g[0]], g[1]) for _, g in STATES.values()}


def params(S):
    """The vector drawing's sticker border, shadow, outline, base side, flare, face inset and lip."""
    return tuple(S * f for f in (0.06, 0.03, 0.032, 0.19, 0.06, 0.03, 0.035))


def trap(x0, y0, x1, y1, t, r):
    """Rounded trapezoid: top edge inset by t on each side (the key flares toward its base)."""
    return (
        f"M{x0 + t + r} {y0} H{x1 - t - r} Q{x1 - t} {y0} {x1 - t + t * r / max(y1 - y0, 1)} {y0 + r} L{x1} {y1 - r} Q{x1} {y1} {x1 - r} {y1} "
        f"H{x0 + r} Q{x0} {y1} {x0} {y1 - r} L{x0 + t - t * r / max(y1 - y0, 1)} {y0 + r} Q{x0 + t} {y0} {x0 + t + r} {y0} Z"
    )


def badge(S, kind):
    """A round badge over the key's lower right corner, with a sticker-cream rim: three dots or "!"."""
    r = max(S * 0.25, 4.5)
    rim = max(1, round(S / 24)) if S < 48 else S * 0.04
    cx, cy = S - r - 0.2, S - r - 0.2
    o = [
        f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{STICKER}"/>',
        f'<circle cx="{cx}" cy="{cy}" r="{r - rim}" fill="{BADGE[kind]}"/>',
    ]
    if kind == "wait":
        d = (r - rim) * 0.5
        for dx in (-d, 0, d):
            o.append(
                f'<circle cx="{cx + dx}" cy="{cy}" r="{max((r - rim) * 0.17, 0.55)}" fill="#FFFFFF"/>'
            )
    else:
        w, h = (r - rim) * 0.36, (r - rim) * 1.4
        o.append(
            f'<rect x="{cx - w / 2}" y="{cy - h / 2}" width="{w}" height="{h * 0.62}" rx="{w / 2}" fill="#FFFFFF"/>'
        )
        o.append(
            f'<circle cx="{cx}" cy="{cy + h / 2 - w / 2}" r="{w / 2}" fill="#FFFFFF"/>'
        )
    return "".join(o)


def sticker(S, lang, g, state=""):
    sb, sh, bw, side, t, fi, lip = params(S)
    blush = (
        S >= 20 and lang != "grey"
    )  # at 16 px the cheeks would cost the glyph a pixel
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
    ink = GREY_INK if lang == "grey" else INK
    o.append(
        f'<g fill="{ink}" stroke="{ink}" stroke-linejoin="round" stroke-linecap="round">'
        f"{place(GLYPHS[g], box, gh, 0.4 if S < 24 else S * 0.022)}</g>"
    )
    kind = state.rpartition("-")[2]
    if kind in BADGE:
        o.append(badge(S, kind))
    o.append("</svg>\n")
    return "".join(o)


# Windows' small icon at 100 % to 400 % (16 to 64 by 4, 48 and 56) and a 22 px Linux tray at 100 % to 300 %
# (22, 28, 33, 39, 44, 55, 66), so neither scales one (#441).
SIZES = (16, 20, 22, 24, 28, 32, 33, 36, 39, 40, 44, 48, 55, 56, 64, 66)


def grid(S):
    """params() in whole pixels, one rule at every size: each part as it rounds, at least a pixel, so a 16 px
    key is a 66 px key shrunk (#441)."""
    return tuple(max(1, round(v)) for v in params(S))


def layout(S):
    """The face's inside on S px: columns x0 to x1 and rows y0 to y1 (exclusive, y1 is the lip's first row),
    and the base's height under the face's outline."""
    sb, sh, bw, side, t, fi, lip = grid(S)
    k0, ky1 = sb + bw, S - sh - sb - bw
    return k0 + t + fi, S - k0 - t - fi, k0, ky1 - side - lip, side - bw


@cache
def stroke(S):
    """The pen every glyph is drawn with at S px: 0.065 S in whole pixels, or thinner where a glyph would
    otherwise join strokes or close or fill counters unlike the font's (topology()), and never wider than a
    larger size's, so the weight doesn't drop as the size grows."""
    if S != SIZES[-1]:
        bigger = stroke(SIZES[SIZES.index(S) + 1])
    else:
        bigger = S
    w = min(max(1, round(S * 0.065)), bigger)
    keys = {g for _, g in STATES.values()}
    while w > 1 and any(topology(glyph_mask(S, k, w, 0), k) for k in keys):
        w -= 1
    return w


@cache
def cut(S, key):
    """How many points the glyph's last stroke loses at S px: none, or where even the thinnest pen joins its
    strokes unlike the font's, as few as part them (あ's tail at 16 px would close its right lobe)."""
    n = 0
    while topology(glyph_mask(S, key, stroke(S), n), key) and n < 3:
        n += 1
    return n


# Each glyph's ink height as a share of the face's (the README drawing's) and the strokes' centrelines, traced
# from the font's glyph: u across, v down its ink box. A list of points is straight strokes with square ends;
# ("curve", points) a smooth stroke through them. The outermost centrelines are put a half stroke inside the
# glyph's pixel box, so every glyph fills its box at every size.
HEIGHT = {"中": 0.8, "あ": 0.8, "ア": 0.8, "EN": 0.66, "A": 0.66, "a": 0.6}
WIDE = 0.84  # the widest a glyph is, as a share of the face's width (EN), leaving the blush its corners
LINES = {
    "中": [
        [(0.085, 0.25), (0.915, 0.25), (0.915, 0.66), (0.085, 0.66), (0.085, 0.25)],
        [(0.5, 0.04), (0.5, 0.96)],
    ],
    "EN": [
        [(0.375, 0.096), (0.063, 0.096), (0.063, 0.905), (0.375, 0.905)],
        [(0.063, 0.49), (0.33, 0.49)],
        [(0.535, 0.905), (0.535, 0.096), (0.937, 0.905), (0.937, 0.096)],
    ],
    "A": [[(0.1, 0.93), (0.5, 0.06), (0.9, 0.93)], [(0.21, 0.69), (0.79, 0.69)]],
    "a": [
        (
            "curve",
            [
                (0.2, 0.13),
                (0.3, 0.1),
                (0.5, 0.08),
                (0.7, 0.12),
                (0.83, 0.25),
                (0.85, 0.4),
            ],
        ),
        [(0.85, 0.4), (0.85, 0.92)],
        (
            "curve",
            [
                (0.85, 0.48),
                (0.5, 0.48),
                (0.2, 0.55),
                (0.08, 0.72),
                (0.17, 0.88),
                (0.4, 0.92),
                (0.65, 0.85),
                (0.85, 0.68),
            ],
        ),
    ],
    "ア": [
        [(0.03, 0.1), (0.88, 0.1)],
        ("curve", [(0.88, 0.1), (0.8, 0.25), (0.7, 0.36), (0.62, 0.43)]),
        ("curve", [(0.43, 0.3), (0.43, 0.5), (0.38, 0.68), (0.27, 0.82), (0.1, 0.93)]),
    ],
    "あ": [
        [(0.06, 0.18), (0.86, 0.14)],
        ("curve", [(0.39, 0.04), (0.38, 0.5), (0.38, 0.9)]),
        (
            "curve",
            [
                (0.7, 0.29),
                (0.67, 0.45),
                (0.61, 0.6),
                (0.5, 0.73),
                (0.3, 0.85),
                (0.15, 0.87),
                (0.06, 0.78),
                (0.07, 0.62),
                (0.2, 0.5),
                (0.42, 0.43),
                (0.65, 0.43),
                (0.85, 0.5),
                (0.94, 0.64),
                (0.88, 0.8),
                (0.72, 0.92),
            ],
        ),
    ],
}


# Where each glyph's strokes go on the pixel grid, across (u) and down (v): its stroke centres and stroke
# ends in order, and between two the least room in pixels: W is a clear pixel between two strokes (w + 1),
# N room for a slant between two strokes (2w + 1), 1 a stroke end that passes another by a pixel. Every point of the glyph is placed by the piecewise-linear
# map through these, so its straight strokes fall on whole pixels and its counters stay open.
W, N = "W", "N"
HINTS = {
    "中": ([0.085, W, 0.5, W, 0.915], [0.04, 1, 0.25, W, 0.66, 1, 0.96]),
    "EN": ([0.063, 1, 0.375, W, 0.535, N, 0.937], [0.096, W, 0.49, W, 0.905]),
    "A": ([0.1, W, 0.5, W, 0.9], [0.06, W, 0.69, W, 0.93]),
    "a": ([0.08, W, 0.85], [0.08, W, 0.48, W, 0.92]),
    "ア": ([0.03, 1, 0.43, W, 0.62, 1, 0.88], [0.1, W, 0.93]),
    "あ": (
        [0.06, W, 0.38, W, 0.72, 1, 0.94],
        [0.04, 1, 0.16, W, 0.29, 1, 0.43, W, 0.95],
    ),
}


def room(gap, w):
    return {W: w + 1, N: 2 * w + 1}.get(gap, gap)


def grid_map(hint, extent, w):
    """hint's stroke positions on extent px, as (u, pixel centre) pairs: spread as the glyph has them, each
    stroke's first pixel whole, and at least the hint's room between them."""
    keys, gaps = hint[::2], [room(g, w) for g in hint[1::2]]
    q = [round((k - keys[0]) / (keys[-1] - keys[0]) * (extent - w)) for k in keys]
    q[0], q[-1] = 0, extent - w
    for i in range(1, len(q)):
        q[i] = max(q[i], q[i - 1] + gaps[i - 1])
    q[-1] = extent - w
    for i in range(len(q) - 2, -1, -1):
        q[i] = min(q[i], q[i + 1] - gaps[i])
    return [(k, x + w / 2) for k, x in zip(keys, q)]


def least(hint, w):
    """The fewest pixels hint's strokes fit in."""
    return w + sum(room(g, w) for g in hint[1::2])


def label(m, eight):
    """m's connected parts (through corners too if eight) numbered from 1, and how many there are."""
    lab, n = np.zeros(m.shape, int), 0
    steps = [(-1, 0), (1, 0), (0, -1), (0, 1)]
    steps += [(-1, -1), (-1, 1), (1, -1), (1, 1)] if eight else []
    for y, x in zip(*np.nonzero(m)):
        if lab[y, x]:
            continue
        n += 1
        lab[y, x], todo = n, [(y, x)]
        while todo:
            cy, cx = todo.pop()
            for dy, dx in steps:
                yy, xx = cy + dy, cx + dx
                if (
                    0 <= yy < m.shape[0]
                    and 0 <= xx < m.shape[1]
                    and m[yy, xx]
                    and not lab[yy, xx]
                ):
                    lab[yy, xx] = n
                    todo.append((yy, xx))
    return lab, n


def regions(m):
    """m's ink parts (touching through corners) and its background regions (touching sideways) on a 1 px
    margin: region 1 is the outside, the others are counters."""
    p = np.pad(m, 1)
    return label(p, True)[1], label(~p, False)[0]


def window(m, k):
    """Where a k x k square fits entirely in m (indexed by its corner)."""
    c = np.pad(m.astype(int).cumsum(0).cumsum(1), ((1, 0), (1, 0)))
    return c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k] == k * k


@cache
def font_regions(key):
    """The font's glyph, its ink box drawn 120 px tall, and its regions()."""
    font, (xmin, ymin, xmax, ymax) = FONTS[key[0]], GLYPHS[key][1]
    s = 120 / (ymax - ymin)
    W, H = round((xmax - xmin) * s), 120
    surface = cairo.ImageSurface(cairo.FORMAT_A8, W, H)
    cr = cairo.Context(surface)
    cr.scale(s, s)
    cr.translate(-xmin, -ymin)
    draw(font, key[1], CairoPen(font.getGlyphSet(), cr))
    cr.fill()
    surface.flush()
    a = np.frombuffer(surface.get_data(), np.uint8).reshape(H, surface.get_stride())[
        :, :W
    ]
    return a >= 128, *regions(a >= 128)


@cache
def font_apart(key, k):
    """How many parts the font's glyph has whose gaps hold a k x k square."""
    fink = font_regions(key)[0]
    return label(~window(np.pad(~fink, k - 1, constant_values=True), k), True)[1]


@cache
def need(key, k):
    """The font's counters that hold a k x k square."""
    fbg = font_regions(key)[2]
    return {n for n in range(2, fbg.max() + 1) if window(fbg == n, k).any()}


def topology(m, key):
    """What m, a glyph's pixels on its box, joins or closes that the font's glyph hasn't, where the font's
    glyph shrunk to m's size has room for them: strokes touching that a pixel or more apart, a stroke broken,
    a counter filled that holds a whole pixel, or strokes closing a counter the font hasn't. Each of m's
    counters is the font's counter (or outside) that most of its pixels are nearest to."""
    parts, bg = regions(m)
    _, fparts, fbg = font_regions(key)
    H, W = fbg.shape
    k = max(1, round(H / m.shape[0]))  # a pixel of m on the font's drawing
    apart = font_apart(key, k)
    problems = (
        [f"{parts} strokes apart, the font's {fparts}"]
        if not apart <= parts <= fparts
        else []
    )
    ys, xs = np.nonzero(fbg)
    found = set()
    for n in range(2, bg.max() + 1):
        y, x = np.nonzero(bg == n)
        fy = ((y - 0.5) / m.shape[0] * H).astype(
            int
        )  # the padded pixel's centre on the font's drawing
        fx = ((x - 0.5) / m.shape[1] * W).astype(int)
        near = [
            fbg[a, b] or fbg[ys[i], xs[i]]
            for a, b in zip(fy.clip(0, H - 1), fx.clip(0, W - 1))
            for i in [np.argmin((ys - a) ** 2 + (xs - b) ** 2) if not fbg[a, b] else 0]
        ]
        found.add(max(set(near), key=near.count))
    if 1 in found:
        problems.append("strokes close a counter the font hasn't")
    if missing := need(key, k) - found:
        problems.append(f"{len(missing)} of the font's counters filled")
    return problems


def glyph_box(S, key, sw=None):
    """The glyph's pixel box: x, y, width, height. Its height is HEIGHT of the face's, or less where its width
    would pass WIDE of the face's; its width has the face's parity, so it centres to the pixel."""
    x0, x1, y0, y1, _ = layout(S)
    fw, fh = x1 - x0, y1 - y0
    _, (xmin, ymin, xmax, ymax) = GLYPHS[key]
    aspect = (xmax - xmin) / (ymax - ymin)
    w = min(HEIGHT[key[1]] * fh * aspect, WIDE * fw)
    gw = fw - 2 * round((fw - w) / 2)
    gh = round(w / aspect)
    # Never smaller than its strokes fit in, keeping the face's parity.
    us, vs = HINTS[key[1]]
    sw = sw or stroke(S)
    gw = max(gw, least(us, sw) + (fw - least(us, sw)) % 2)
    gh = max(gh, least(vs, sw))
    return x0 + (fw - gw) // 2, y0 + (fh - gh) // 2, gw, gh


def catmull(points, n=24):
    p = [points[0], *points, points[-1]]
    out = [points[0]]
    for i in range(1, len(p) - 2):
        for k in range(1, n + 1):
            t = k / n
            out.append(
                tuple(
                    0.5
                    * (
                        2 * p[i][d]
                        + (p[i + 1][d] - p[i - 1][d]) * t
                        + (
                            2 * p[i - 1][d]
                            - 5 * p[i][d]
                            + 4 * p[i + 1][d]
                            - p[i + 2][d]
                        )
                        * t
                        * t
                        + (3 * p[i][d] - p[i - 1][d] - 3 * p[i + 1][d] + p[i + 2][d])
                        * t**3
                    )
                    for d in (0, 1)
                )
            )
    return out


def segment(m, a, b, w, cap0, cap1):
    """A stroke w px wide from centre a to centre b: the pixels whose centre is less than w/2 from it, so an
    upright or level stroke is exactly w whole pixels and a slanted one as wide across; a square end
    reaches w/2 past its point, an open end (inside a curve) stops at it with a round join."""
    (x0, y0), (x1, y1) = a, b
    ys, xs = np.mgrid[0 : m.shape[0], 0 : m.shape[1]] + 0.5
    dx, dy = x1 - x0, y1 - y0
    length = np.hypot(dx, dy)
    if length == 0:
        m |= np.hypot(xs - x0, ys - y0) < w / 2
        return
    along = ((xs - x0) * dx + (ys - y0) * dy) / length
    across = ((xs - x0) * dy - (ys - y0) * dx) / length
    if (
        w == 1
    ):  # a pixel line: one pixel a row (steep) or a column (flat), ties to one side
        across *= length / max(abs(dx), abs(dy))
        across = np.where((across > -0.5) & (across <= 0.5), 0, 1)
    across = np.abs(across)
    square = dx == 0 or dy == 0
    lo, hi = (
        -w / 2 if cap0 and square else 0,
        length + (w / 2 if cap1 and square else 0),
    )
    m |= (across < w / 2) & (along >= lo) & (along < hi)
    for (x, y), cap in (((x0, y0), cap0), ((x1, y1), cap1)):
        if not (cap and square):
            m |= np.hypot(xs - x, ys - y) < w / 2


def glyph_mask(S, key, w=None, short=None):
    """The glyph on its pixel box: its centrelines, placed by HINTS, stroked w px wide (stroke()) by
    segment(). A SYMMETRIC glyph is united with its mirror image, so 中's centre stroke is a pixel wider
    where the pen's parity isn't the face's: no stroke that wide can sit on the face's middle."""
    text = key[1]
    w = w or stroke(S)
    short = cut(S, key) if short is None else short
    _, _, gw, gh = glyph_box(S, key, w)
    us, vs = HINTS[text]
    mu, mv = grid_map(us, gw, w), grid_map(vs, gh, w)

    def place(t, pairs):
        for (k0, p0), (k1, p1) in zip(pairs, pairs[1:]):
            if t <= k1 or (k1, p1) == pairs[-1]:
                return p0 + (t - k0) * (p1 - p0) / (k1 - k0)

    m = np.zeros((gh, gw), bool)
    for n, line in enumerate(LINES[text]):
        curve = line[0] == "curve"
        if n == len(LINES[text]) - 1 and short:
            line = ("curve", line[1][:-short]) if curve else line[:-short]
        path = [
            (place(u, mu), place(v, mv))
            for u, v in (catmull(line[1]) if curve else line)
        ]
        for i, (a, b) in enumerate(zip(path, path[1:])):
            segment(m, a, b, w, not curve or i == 0, not curve or i == len(path) - 2)
    if (
        text in SYMMETRIC
    ):  # mirrored onto itself: a stroke on the middle that can't centre is a pixel wider
        m |= m[:, ::-1]
    return m


def rgb(c, alpha=1.0):
    return tuple(int(c[i : i + 2], 16) / 255 for i in (1, 3, 5)) + (alpha,)


def arc(cr, cx, cy, rx, ry, a0, a1):
    cr.save()
    cr.translate(cx, cy)
    cr.scale(rx, ry)
    cr.arc(0, 0, 1, a0, a1)
    cr.restore()


def key(cr, x0, y0, x1, y1, t, r):
    """trap()'s shape on the pixel grid: the flare is taken into the top corners (each t px wider than tall),
    so the top edge is as long and the sides are straight: only the corners have partly covered pixels."""
    r = min(r, (x1 - x0) / 2 - t, (y1 - y0) / 2)
    cr.new_path()
    arc(cr, x1 - t - r, y0 + r, r + t, r, -pi / 2, 0)
    arc(cr, x1 - r, y1 - r, r, r, 0, pi / 2)
    arc(cr, x0 + r, y1 - r, r, r, pi / 2, pi)
    arc(cr, x0 + t + r, y0 + r, r + t, r, pi, 3 * pi / 2)
    cr.close_path()


def rounded(cr, x0, y0, x1, y1, r):
    key(cr, x0, y0, x1, y1, 0, r)


def gradient(y0, y1, top, bot):
    g = cairo.LinearGradient(0, y0, 0, y1)
    g.add_color_stop_rgb(0, *rgb(top)[:3])
    g.add_color_stop_rgb(1, *rgb(bot)[:3])
    return g


def fill(cr, source):
    cr.set_source_rgba(*source) if isinstance(source, tuple) else cr.set_source(source)
    cr.fill()


def image(surface):
    b = io.BytesIO()
    surface.write_to_png(b)
    return Image.open(io.BytesIO(b.getvalue())).convert("RGBA")


def GLINT(S, k0, ky1, side):
    """The glint's rectangle on the base: x, y, width, height."""
    return (
        round(k0 + S * 0.1 - S * 0.035),
        round(ky1 - side * 0.45 - S * 0.06),
        max(1, round(S * 0.07)),
        max(2, round(S * 0.12)),
    )


def runs(px):
    """A row or column of pixels as runs of kinds: c cream (face or sticker), o outline, l lip, b anything
    else (the base), _ not opaque. Returns (kind, start, length) for each run."""

    def kind(p):
        if p[3] < 128:
            return "_"
        if min(p[:3]) >= 0xE0:
            return "c"
        for k, c in (("o", OUTLINE), ("l", LIP)):
            if np.abs(p[:3] - np.array(rgb(c)[:3]) * 255).sum() < 60:
                return k
        return "b"

    out = []
    for i, k in enumerate(kind(p) for p in px):
        if out and out[-1][0] == k:
            out[-1][2] += 1
        else:
            out.append([k, i, 1])
    return out


def straight(m):
    """The widths of m's upright strokes: each run of ink across a row that more rows than it is wide have
    too, one under another at the same columns (a slant moves; a level stroke is wider than it is tall)."""
    widths, tall = set(), {}
    for row in m:
        d = np.diff(np.r_[0, row.astype(int), 0])
        spans = set(
            zip(np.nonzero(d == 1)[0].tolist(), np.nonzero(d == -1)[0].tolist())
        )
        tall = {span: tall.get(span, 0) + 1 for span in spans}
        widths |= {b - a for (a, b), n in tall.items() if n > b - a}
    return widths


def strokes(m, w, centre=False):
    """What is wrong with the widths of m's strokes, drawn w px wide: an upright or level stroke not w px
    across (a centre stroke may be a pixel wider, see glyph_mask()), or any stroke narrowing to a one-pixel
    neck (a pixel with no ink beside it across or down)."""
    widths = straight(m) | straight(m.T)
    problems = (
        [f"upright or level strokes {sorted(widths)} px wide, not {w}"]
        if widths - {w, w + centre}
        else []
    )
    if w > 1:
        p = np.pad(m, 1)
        neck = m & ~(p[1:-1, :-2] | p[1:-1, 2:]) & ~(p[:-2, 1:-1] | p[2:, 1:-1])
        if neck.any():
            problems.append(
                f"a stroke narrows to a pixel in rows {sorted(set(np.nonzero(neck)[0].tolist()))}"
            )
    return problems


def ink_of(px, lang):
    return (
        px[..., :3] == np.array(rgb(GREY_INK if lang == "grey" else INK)[:3]) * 255
    ).all(axis=2) & (px[..., 3] == 255)


def pens():
    """The pen each size's PNGs were drawn with, as their upright and level strokes measure (中's thinner
    ones: its centre stroke may be a pixel wider): {size: set of widths}."""
    out = {}
    for S in SIZES:
        out[S] = set()
        for state, (lang, (_, text)) in STATES.items():
            if lang == "grey":
                continue
            px = np.asarray(
                Image.open(HERE / str(S) / f"{state}.png").convert("RGBA")
            ).astype(int)
            ink = ink_of(px, lang)
            widths = straight(ink) | straight(ink.T)
            out[S] |= {min(widths)} if text == "中" and widths else widths
    return out


def check(S, state, im):
    """What is wrong with a drawing:
    - the glyph: not centred in the face to the pixel; not its own mirror image (SYMMETRIC); an upright or
      level stroke not stroke()'s width, or a stroke narrowing to a pixel; strokes joined or counters
      filled or closed unlike the font's (topology()); its box more than a pixel off glyph_box(); with a
      badge, not the ready key's glyph;
    - the key: not left-right symmetric; its face inset or base height more than a pixel off grid()'s;
    - the blush: missing from 20 px, or nearer the glyph than a clear pixel.
    Left out of the mirror test: the blush (both sides slant the same way, as in the concept), the glint
    (lower left only) and the badge (lower right). Keys with a badge are measured as their ready key."""
    lang, (kind, text) = STATES[state]
    px = np.asarray(im.convert("RGBA")).astype(int)
    rgb_ = px[..., :3]
    ink = ink_of(px, lang)
    x0, x1, y0, y1, base = layout(S)
    keep = np.ones((S, S), bool)
    problems = []
    ready, _, kind_badge = state.rpartition("-")
    if kind_badge in BADGE:  # the badge sits bottom right, over the face's corner
        br = max(S * 0.25, 4.5)
        keep[int(S - 2 * br - 1) :, int(S - 2 * br - 1) :] = False
        # The glyph is the ready key's, which is checked centred.
        r = np.asarray(
            Image.open(HERE / str(S) / f"{ready}.png").convert("RGBA")
        ).astype(int)
        r_ink = (r[..., :3] == np.array(rgb(INK)[:3]) * 255).all(axis=2) & (
            r[..., 3] == 255
        )
        if ((r_ink != ink) & keep).any():
            problems.append(f"glyph not {ready}'s")
    glyph_ink = ink & keep & keep[:, ::-1]
    cols = np.nonzero(ink[:, x0:x1].any(axis=0))[0]
    if len(cols) and kind_badge not in BADGE:
        left, right = cols[0], x1 - x0 - 1 - cols[-1]
        if left != right:
            problems.append(f"glyph margins {left} left, {right} right")
        rows = np.nonzero(ink.any(axis=1))[0]
        _, _, gw, gh = glyph_box(S, (kind, text))
        w, h = cols[-1] - cols[0] + 1, rows[-1] - rows[0] + 1
        if abs(w - gw) > 1 or abs(h - gh) > 1:
            problems.append(f"glyph {w} x {h} px, its box {gw} x {gh}")
        problems += strokes(ink, stroke(S), text == "中")
        problems += topology(
            ink[rows[0] : rows[-1] + 1, x0 + cols[0] : x0 + cols[-1] + 1], (kind, text)
        )
        row = px[(y0 + y1) // 2].copy()
        row[ink[(y0 + y1) // 2]] = (255, 255, 255, 255)  # the glyph is on the face
        across = runs(row)
        kinds = "".join(k for k, _, _ in across)
        if not kinds.lstrip("_").startswith("coboc"):
            problems.append(
                f"key's left side {kinds[:6]}, not sticker, outline, base, outline, face"
            )
        else:
            face_x = across[kinds.index("oc", 3) + 1][1]
            if abs(face_x - x0) > 1:
                problems.append(f"face inset {face_x} px, its formula {x0}")
        down = runs(px[::-1, S // 2])
        kinds = "".join(k for k, _, _ in down).lstrip("_")
        offset = len(down) - len(kinds)
        if not kinds.startswith("cob"):
            problems.append(
                f"base under the face {kinds[:3]}, not sticker, outline, base"
            )
        elif abs(down[offset + 2][2] - base) > 1:
            problems.append(f"base {down[offset + 2][2]} px high, its formula {base}")
    if text in SYMMETRIC and (glyph_ink != glyph_ink[:, ::-1]).any():
        problems.append("glyph not symmetric")
    blush = (rgb_ == np.array(rgb(BLUSH)[:3]) * 255).all(axis=2)
    if S >= 20 and lang != "grey" and not blush.any():
        problems.append("no blush")
    near = np.zeros_like(ink)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            near |= np.roll(np.roll(ink, dy, 0), dx, 1)
    if (near & blush).any():
        problems.append("blush touches the glyph")
    sb, sh, bw, side, t, fi, lip = grid(S)
    gx, gy, gw, gh = GLINT(S, sb + bw, S - sh - sb - bw, side)
    keep &= ~ink & ~blush
    if S >= 32:
        keep[gy : gy + gh, gx : gx + gw] = False
    both = keep & keep[:, ::-1]
    bad = sorted(
        {int(y) for y in np.nonzero(((px != px[:, ::-1]).any(axis=2)) & both)[0]}
    )
    if bad:
        problems.append(f"body not symmetric in rows {bad}")
    return problems


def rgb255(c):
    return tuple(round(v * 255) for v in rgb(c))


def cheeks(S, glyph, px):
    """The blush's pixels: from 32 px two short slanted dashes each side, as in the concept; at 20-28 px one
    2 px cheek per lower corner, as dashes would merge into a strike-through. They keep a clear pixel from
    the glyph (on either side, so the two sides match): where their place is taken they move down, then out
    to the face's edge, and only then shrink. Only face pixels take blush."""
    x0, x1, y0, y1, _ = layout(S)
    fw, fh = x1 - x0, y1 - y0
    taken = glyph | glyph[:, ::-1]
    near = np.zeros_like(taken)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            near |= np.roll(np.roll(taken, dy, 0), dx, 1)
    face = (px[..., 3] == 255) & (px[..., :3].min(axis=2) >= 0xE0)
    if S >= 32:
        w = 1 if S < 48 else 2
        n = 2 if S < 40 else 3
        y = round(y0 + fh * 0.62)
        side = x0 + fw * 0.085
        xs = [round(side + dx - (n + w - 1) / 2) for dx in (-S * 0.035, S * 0.035)]
        shapes = [(xs, n), (xs[:1], n), (xs[:1], 2)]
    else:
        w, y, shapes = 1, y1 - 2, [([x0, x0 + 1], 1), ([x0], 1)]
    # Each place it may take, nearest first: out to the face's edge, in by a quarter face, down to the lip, a
    # pixel up.
    for dashes, n in shapes:
        moves = sorted(
            (
                (dx, dy)
                for dx in range(x0 - dashes[0], fw // 4)
                for dy in range(-1, y1 - y)
            ),
            key=lambda m: (abs(m[0]) + abs(m[1]), m[1] < 0, m[0] > 0),
        )
        for dx, dy in moves:
            left = [
                (x + dx + i + a, y + dy - i + b)
                for x in dashes
                for i in range(n)
                for a in range(w)
                for b in range(w)
            ]
            lo, hi = min(p[0] for p in left), max(p[0] for p in left)
            right = [
                (x + x0 + x1 - 1 - hi - lo, yy) for x, yy in left
            ]  # mirrored place, same slant
            pts = left + right
            if all(0 <= yy < S and face[yy, x] and not near[yy, x] for x, yy in pts):
                return pts
    return []


def pixels(S, state):
    """sticker()'s key at S px on its pixel grid: its edges on whole pixels (only round corners are partly
    covered), its shadow, glint and blush in whole pixels, and the glyph by glyph_mask()."""
    lang, (kind, text) = STATES[state]
    sb, sh, bw, side, t, fi, lip = grid(S)
    H, r = S - sh, S * 0.24
    top, bot = BASE[lang]
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, S, S)
    cr = cairo.Context(surface)
    if sh:  # a hard shadow, sh px under the sticker
        key(cr, 0, sh, S, S, t, r + sb)
        fill(cr, rgb(OUTLINE, 0.35))
    key(cr, 0, 0, S, H, t, r + sb)
    fill(cr, rgb(STICKER))
    key(cr, sb, sb, S - sb, H - sb, t, r)
    fill(cr, rgb(OUTLINE))
    k0, k1, ky0, ky1 = sb + bw, S - sb - bw, sb + bw, H - sb - bw
    key(cr, k0, ky0, k1, ky1, t, max(r - bw, 0))
    fill(cr, gradient(ky0, ky1, top, bot))
    fx0, fx1, fy0, fy1 = k0 + t + fi, k1 - t - fi, ky0, ky1 - side
    rf = max(r - bw - fi, 0) * 0.9

    def under_face(cr):  # the face with its outline, which covers the base
        rounded(cr, fx0 - bw, fy0, fx1 + bw, fy1 + bw, rf + bw)

    under_face(cr)
    fill(cr, rgb(OUTLINE))
    rounded(cr, fx0, fy0, fx1, fy1, rf)  # the top face with a beige lip at its bottom
    fill(cr, rgb(LIP))
    fy1 -= lip
    rounded(cr, fx0, fy0, fx1, fy1, rf)
    fill(cr, gradient(fy0, fy1, "#FFFCF5", "#FFF1E2"))
    # The body is left-right symmetric: its left half mirrored (cairo shades the corners of the two sides a
    # little differently).
    px = np.asarray(image(surface)).copy()
    px[:, S - S // 2 :] = px[:, : S // 2][:, ::-1]
    im = Image.fromarray(px)
    if S >= 32:  # glint on the base, lower left, under the face's edge
        glint = cairo.ImageSurface(cairo.FORMAT_ARGB32, S, S)
        cr = cairo.Context(glint)
        cr.rectangle(*GLINT(S, k0, ky1, side))
        fill(cr, rgb("#FFFFFF", 0.45))
        cr.set_operator(cairo.OPERATOR_DEST_OUT)
        under_face(cr)
        fill(cr, rgb("#FFFFFF"))
        im.alpha_composite(image(glint))
    gx, gy, gw, gh = glyph_box(S, (kind, text))
    m = np.zeros((S, S), bool)
    m[gy : gy + gh, gx : gx + gw] = glyph_mask(S, (kind, text))
    if S >= 20 and lang != "grey":
        for x, y in cheeks(S, m, np.asarray(im)):
            im.putpixel((x, y), rgb255(BLUSH))
    d = ImageDraw.Draw(im)
    d.bitmap(
        (0, 0),
        Image.fromarray(m.astype(np.uint8) * 255),
        fill=GREY_INK if lang == "grey" else INK,
    )
    kind_badge = state.rpartition("-")[2]
    if kind_badge in BADGE:
        br = max(S * 0.25, 4.5)
        rim = max(1, round(S / 24)) if S < 48 else round(S * 0.04)
        c = S - br - 0.2
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, S, S)
        cr = cairo.Context(surface)
        cr.arc(c, c, br, 0, 2 * pi)
        fill(cr, rgb(STICKER))
        cr.arc(c, c, br - rim, 0, 2 * pi)
        fill(cr, rgb(BADGE[kind_badge]))
        im.alpha_composite(image(surface))
        d = ImageDraw.Draw(im)
        inner = br - rim
        if kind_badge == "wait":  # three square dots
            dot = max(1, round(inner * 0.34))
            pitch = max(
                dot + 1, round(inner * 0.5)
            )  # whole pixels, a gap at least a pixel wide
            x, y = round(c - dot / 2), round(c - dot / 2)
            for dx in (-pitch, 0, pitch):
                d.rectangle((x + dx, y, x + dx + dot - 1, y + dot - 1), fill="#FFFFFF")
        else:  # "!": a bar, a gap, a dot
            w, h = max(1, round(inner * 0.36)), inner * 1.4
            x, y0 = round(c - w / 2), round(c - h / 2)
            bar = round(h * 0.62)
            dot_y = max(round(c + h / 2 - w), y0 + bar + 1)
            d.rectangle((x, y0, x + w - 1, y0 + bar - 1), fill="#FFFFFF")
            d.rectangle((x, dot_y, x + w - 1, dot_y + w - 1), fill="#FFFFFF")
    return im


# --check: only checks the PNGs there are (exit 1 on a problem); otherwise draws them all, then checks them.
if __name__ == "__main__":
    if "--check" not in sys.argv:
        (HERE / "scalable").mkdir(exist_ok=True)
        for state, (lang, g) in STATES.items():
            (HERE / "scalable" / f"{state}.svg").write_text(sticker(48, lang, g, state))
            for S in SIZES:
                (HERE / str(S)).mkdir(exist_ok=True)
                pixels(S, state).save(HERE / str(S) / f"{state}.png", optimize=True)
    widths = pens()
    bad = [
        f"{S} px: glyphs drawn with pens {sorted(w)}"
        for S, w in widths.items()
        if len(w) != 1
    ]
    bad += [
        f"{S} px: pen {max(widths[S])}, {T} px: {min(widths[T])}"
        for S, T in zip(SIZES, SIZES[1:])
        if widths[S] and widths[T] and max(widths[S]) > min(widths[T])
    ]
    bad += [
        f"{S}/{state}.png: {p}"
        for state in STATES
        for S in SIZES
        for p in check(S, state, Image.open(HERE / str(S) / f"{state}.png"))
    ]
    print(
        "\n".join(bad) or f"{len(STATES) * len(SIZES)} drawings centred and symmetric"
    )
    sys.exit(1 if bad else 0)
