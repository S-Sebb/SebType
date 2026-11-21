#!/usr/bin/env python3
"""Writes SebType's tray icons (#63, "Set E" sticker keycap): pc/icons/<size>/<state>.png and
pc/icons/scalable/<state>.svg.

The README drawing (sticker(), written as "scalable", a 48 px vector drawing with font outlines) is the design.
Each tray size (16 to 66 px, SIZES) is that drawing drawn again at its own size and grid-fitted, so it looks
like the vector drawing but crisp (#441): the key's parts are params()'s shares in whole pixels (at least one),
so its outlines, face and base have hard edges; the glyph's outline (Noto Sans CJK Black for 中 あ ア, from the
system's Noto Sans CJK VF; Nunito ExtraBold for EN a A, android/app/src/main/res/font; both OFL) has its stems,
bars and extremes moved onto whole pixels, 中 and A mirror-exact and every glyph centred in the face to the
pixel, and keeps its antialiased curves. Up to 24 px the shadow is hard and the face has no shine, as blurred
they only smear. check() fails the build on a drawing that isn't grid-fitted or symmetric, or that strays from
the vector drawing at its size. Needs fontTools, Pillow, pycairo and CairoSVG. Linux's RPM installs the PNGs
(linux/CMakeLists.txt); Windows' .ico files hold them (windows/make_icons.py, #13, #65).
"""

import io
import re
import sys
from functools import cache
from math import pi
from pathlib import Path

import cairo
import cairosvg
import numpy as np
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.cairoPen import CairoPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTCollection, TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from PIL import Image, ImageFilter

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
SOFT = 24  # up to this size the shadow is hard and the face has no shine: blurred they only smear


def grid(S):
    """params() snapped to the pixel grid: each part in whole pixels, at least one (#441). Below 24 px, a
    pixel a part would leave the glyph a cramped face, so 16 and 20 px are set to look like 24 px's key
    shrunk: 16 px has no cream border and no lip, and 20 px's face has no inset, so its sides meet the base
    with no outline of their own."""
    return SMALL.get(S) or tuple(max(1, round(v)) for v in params(S))


SMALL = {16: (0, 1, 1, 4, 1, 1, 0), 20: (1, 1, 1, 4, 1, 0, 1)}  # as params() for S


def layout(S):
    """The face's inside on S px: columns x0 to x1 and rows y0 to y1 (exclusive, y1 is the lip's first row),
    and the base's height under the face's outline."""
    sb, sh, bw, side, t, fi, lip = grid(S)
    k0, ky1 = sb + bw, S - sh - sb - bw
    return k0 + t + fi, S - k0 - t - fi, k0, ky1 - side - lip, side - bw


def rgb(c, alpha=1.0):
    return tuple(int(c[i : i + 2], 16) / 255 for i in (1, 3, 5)) + (alpha,)


def key(cr, x0, y0, x1, y1, t, r):
    """trap()'s shape as cairo's path."""
    h = max(y1 - y0, 1)

    def quad(c, e):  # SVG's Q as a cubic
        p = cr.get_current_point()
        cr.curve_to(
            p[0] + 2 / 3 * (c[0] - p[0]),
            p[1] + 2 / 3 * (c[1] - p[1]),
            e[0] + 2 / 3 * (c[0] - e[0]),
            e[1] + 2 / 3 * (c[1] - e[1]),
            *e,
        )

    cr.new_path()
    cr.move_to(x0 + t + r, y0)
    cr.line_to(x1 - t - r, y0)
    quad((x1 - t, y0), (x1 - t + t * r / h, y0 + r))
    cr.line_to(x1, y1 - r)
    quad((x1, y1), (x1 - r, y1))
    cr.line_to(x0 + r, y1)
    quad((x0, y1), (x0, y1 - r))
    cr.line_to(x0 + t - t * r / h, y0 + r)
    quad((x0 + t, y0), (x0 + t + r, y0))
    cr.close_path()


def rounded(cr, x0, y0, x1, y1, r):
    """SVG's rect with rx = ry = r."""
    r = min(r, (x1 - x0) / 2, (y1 - y0) / 2)
    cr.new_path()
    for cx, cy, a in (
        (x1 - r, y0 + r, -pi / 2),
        (x1 - r, y1 - r, 0),
        (x0 + r, y1 - r, pi / 2),
        (x0 + r, y0 + r, pi),
    ):
        cr.arc(cx, cy, r, a, a + pi / 2)
    cr.close_path()


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


def outline(key):
    """The glyph's outline in font units, y down, as pen calls."""
    pen = RecordingPen()
    draw(FONTS[key[0]], key[1], pen)
    return pen.value


def replay(rec, cr, f=lambda p: p):
    """rec's outline as cairo's path, each point through f."""
    pen = CairoPen(None, cr)
    for op, pts in rec:
        getattr(pen, op)(*[f(p) for p in pts])


@cache
def edges(key):
    """The glyph's edges across each axis, as (position, ink side) in font units: its upright (x) and level
    (y) straight segments and each contour's extremes. Side +1: the ink is before the edge, -1 after it. The
    side is looked for at several points of an edge, as the font's strokes overlap."""
    rec = outline(key)
    cr = cairo.Context(cairo.ImageSurface(cairo.FORMAT_A8, 1, 1))
    replay(rec, cr)
    found = ([], [])
    contour, prev = [], None
    for op, pts in rec + [("moveTo", [None])]:
        if op == "closePath" and contour:  # its closing segment
            op, pts = "lineTo", [contour[0]]
            for a in (0, 1):
                end = pts[-1]
                if abs(end[a] - prev[a]) < 1 and abs(end[1 - a] - prev[1 - a]) > 20:
                    found[a].extend(
                        (end[a], end[1 - a] + (prev[1 - a] - end[1 - a]) * f)
                        for f in (0.2, 0.5, 0.8)
                    )
            op, pts = "closePath", ()
        if op in ("moveTo", "closePath", "endPath") and contour:
            for a in (0, 1):
                ends = (
                    min(contour, key=lambda p: p[a]),
                    max(contour, key=lambda p: p[a]),
                )
                found[a].extend((p[a], p[1 - a]) for p in ends)
            contour = []
        if op in ("lineTo", "qCurveTo", "curveTo") and prev:
            end = pts[-1]
            for a in (0, 1):  # straight along the other axis
                if (
                    op == "lineTo"
                    and abs(end[a] - prev[a]) < 1
                    and abs(end[1 - a] - prev[1 - a]) > 20
                ):
                    found[a].extend(
                        (end[a], end[1 - a] + (prev[1 - a] - end[1 - a]) * f)
                        for f in (0.2, 0.5, 0.8)
                    )
        if pts and pts[-1] is not None:
            prev = pts[-1]
            contour.append(prev)
    out = []
    for a in (0, 1):
        sided = set()
        for pos, at in found[a]:
            point = lambda d: (pos + d, at) if a == 0 else (at, pos + d)
            if cr.in_fill(*point(-3)) and not cr.in_fill(*point(3)):
                sided.add((pos, 1))
            elif cr.in_fill(*point(3)) and not cr.in_fill(*point(-3)):
                sided.add((pos, -1))
        out.append(sorted(sided))
    return out


def fit_axis(edges, scale, offset, half, centre, mirror):
    """The piecewise-linear map from font to device position that puts every edge's ink boundary (the
    outline plus half the README drawing's stroke) on a whole pixel, keeping each stem's width rounded (at
    least a pixel) and the order of the edges. The outermost boundaries are put the same distance from
    centre; with mirror, every edge is put where its mirror image across centre is, and a stem across the
    middle takes the nearest width that can be centred there."""
    marks = [(p * scale + offset, side) for p, side in edges]  # device position, side
    own = sorted(marks)
    if mirror:
        marks = [m for m in marks if m[0] < centre - 0.01]
        marks += [(2 * centre - d, -side) for d, side in marks]
    marks.sort()
    left = [m for m in marks if m[0] + m[1] * half <= centre] if mirror else marks
    knots, last = [], None  # last: the previous kept edge's boundary, target and side
    for d, side in left:
        b = d + side * half
        if (
            last and side == 1 and last[2] == -1
        ):  # a stem's far side: its width rounded, at least a pixel
            t = last[1] + max(1, round(b - last[0]))
        else:
            t = round(b)
        if last is not None and t <= last[1]:
            if b - last[0] < 0.5:
                continue
            t = last[1] + 1
        knots.append((d, t, side))
        last = (b, t, side)
    if mirror:
        if (
            left and left[-1][1] == -1
        ):  # a stem across the middle: the width of the middle's parity nearest
            i = own.index(
                left[-1]
            )  # its own (the font's, which may be a little off the middle), the
            wd = (
                own[i + 1][0] + half - last[0]
                if i + 1 < len(own)
                else 2 * (centre - last[0])
            )
            w = max(1, round(wd))
            if (w - 2 * centre) % 2:
                w = (
                    w - 1 if w > 1 and wd - (w - 1) <= w + 1 - wd else w + 1
                )  # thinner of two as near
            knots[-1] = (knots[-1][0], centre - w / 2, -1)
            for i in range(len(knots) - 2, -1, -1):
                knots[i] = (
                    knots[i][0],
                    min(knots[i][1], knots[i + 1][1] - 1),
                    knots[i][2],
                )
        knots += [(2 * centre - d, 2 * centre - t, -side) for d, t, side in knots]
    elif knots:  # the outermost boundaries, centred
        knots[-1] = (knots[-1][0], 2 * centre - knots[0][1], knots[-1][2])
    knots = sorted((d, t - side * half) for d, t, side in knots)
    ds, ts = [], []
    for d, t in knots:
        if not ds or (d > ds[-1] + 1e-6 and t > ts[-1] + 1e-6):
            ds.append(d)
            ts.append(t)
    return ds, ts


def warp(ds, ts, v):
    if v <= ds[0]:
        return v + ts[0] - ds[0]
    if v >= ds[-1]:
        return v + ts[-1] - ds[-1]
    return float(np.interp(v, ds, ts))


# Each glyph's ink height as a share of the face's, as the README drawing has it.
HEIGHT = {"中": 0.8, "あ": 0.8, "ア": 0.8, "EN": 0.66, "A": 0.66, "a": 0.6}


def glyph_alpha(S, state):
    """The glyph's coverage on S px, from the README drawing's outline and stroke, grid-fitted: its stems,
    bars and extremes on whole pixels, centred in the face to the pixel, 中 and A mirror-exact. Curves keep
    their antialiasing."""
    lang, g = STATES[state]
    x0, x1, y0, y1, _ = layout(S)
    fw, fh = x1 - x0, y1 - y0
    margin = fw * (
        0.17 if lang != "grey" else 0.06
    )  # the README drawing's room for the blush
    if S < SOFT:  # no blush to leave room for: as wide as the face less a pixel a side
        margin = 1
    box = (x0 + margin, y0 + fh * 0.04, x1 - margin, y1 - fh * 0.04)
    s, tx, ty = fit(GLYPHS[g], box, fh * HEIGHT[g[1]])
    # The README drawing's stroke round the outline; below 24 px it would close the glyphs' counters.
    sw = S * 0.022 if S >= SOFT else 0.25
    ex, ey = edges(g)
    mirror = g[1] in SYMMETRIC
    mx = fit_axis(ex, s, tx, sw / 2, (x0 + x1) / 2, mirror)
    my = fit_axis(ey, s, ty, sw / 2, (box[1] + box[3]) / 2, False)
    # Filled and stroked as the README drawing, 8 x 8 samples a pixel, so a pixel both partly cover is
    # covered by their union (cairo's antialiasing would add the two coverages as layers).
    n = 8
    surface = cairo.ImageSurface(cairo.FORMAT_A8, S * n, S * n)
    cr = cairo.Context(surface)
    cr.set_antialias(cairo.ANTIALIAS_NONE)
    cr.scale(n, n)
    replay(
        outline(g), cr, lambda p: (warp(*mx, p[0] * s + tx), warp(*my, p[1] * s + ty))
    )
    cr.set_line_width(sw)
    cr.set_line_join(cairo.LINE_JOIN_ROUND)
    cr.fill_preserve()
    cr.stroke()
    surface.flush()
    a = np.frombuffer(surface.get_data(), np.uint8).reshape(
        S * n, surface.get_stride()
    )[:, : S * n]
    a = np.round(a.reshape(S, n, S, n).mean(axis=(1, 3))).astype(int)
    if (
        mirror
    ):  # its outline is near enough its mirror image; the pixels are made exactly so
        c2 = x0 + x1
        m = a.copy()
        m[:, max(0, c2 - S) : min(S, c2)] = a[
            :, min(S, c2) - 1 : max(0, c2 - S) - 1 if c2 > S else None : -1
        ]
        a = np.maximum(a, m)
    return a


def ellipse(cr, cx, cy, rx, ry, angle=0):
    cr.save()
    cr.translate(cx, cy)
    cr.rotate(angle)
    cr.scale(rx, ry)
    cr.arc(0, 0, 1, 0, 2 * pi)
    cr.restore()


def layers(S, state):
    """sticker()'s README drawing at S px, grid-fitted: the key's parts params()'s shares in whole pixels,
    so its straight edges fall on whole pixels, left-right symmetric; its corners and slanted sides
    antialiased; the shine, glint and blush as drawn (Set E's blush: none below 24 px, a cheek a side to 28 px,
    two dashes a side from 32 px); the glyph by glyph_alpha(); the badge over it. Returns the drawing, what
    check()'s mirror test leaves out (shine, glint, blush, badge, an asymmetric glyph), the glyph's coverage
    and the badge's pixels."""
    lang, (kind, text) = STATES[state]
    sb, sh, bw, side, t, fi, lip = grid(S)
    H, r = S - sh, round(S * 0.24)
    top, bot = BASE[lang]
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, S, S)
    cr = cairo.Context(surface)
    key(
        cr, sb, sb, S - sb, H - sb, t, r
    )  # the key's outline, which the sticker's border is drawn under
    k0, k1, ky0, ky1 = sb + bw, S - sb - bw, sb + bw, H - sb - bw
    fx0, fx1, fy0, fy1 = k0 + t + fi, k1 - t - fi, ky0, ky1 - side
    rf = round(max(r - bw - fi, 0) * 0.9)
    shadow = cairo.ImageSurface(cairo.FORMAT_ARGB32, S, S)
    sc = cairo.Context(shadow)
    if S <= SOFT:  # a hard shadow sh px under the sticker
        key(sc, 0, sh, S, S, t, r + sb)
    else:  # the README drawing's soft one
        key(sc, 0.5, sh, S - 0.5, H + sh * 0.6, t, r + sb)
    fill(sc, rgb(OUTLINE, 0.35))
    shade = image(shadow)
    if S > SOFT:
        shade = shade.filter(ImageFilter.GaussianBlur(S / 40))
    key(cr, 0, 0, S, H, t, r + sb)
    fill(cr, rgb(STICKER))
    key(cr, sb, sb, S - sb, H - sb, t, r)
    fill(cr, rgb(OUTLINE))
    key(cr, k0, ky0, k1, ky1, t, max(r - bw, 0))
    fill(cr, gradient(ky0, ky1, top, bot))

    fo = bw if fi else 0  # the face's side outline, none without an inset

    def under_face(cr):  # the face with its outline, which covers the base
        rounded(cr, fx0 - fo, fy0, fx1 + fo, fy1 + bw, rf + fo)

    under_face(cr)
    fill(cr, rgb(OUTLINE))
    rounded(cr, fx0, fy0, fx1, fy1, rf)  # the top face with a beige lip at its bottom
    fill(cr, rgb(LIP))
    rounded(cr, fx0, fy0, fx1, fy1 - lip, rf)
    fill(cr, gradient(fy0, fy1 - lip, "#FFFCF5", "#FFF1E2"))
    im = shade
    im.alpha_composite(image(surface))
    # Left-right symmetric: its left half mirrored (cairo shades the two sides' corners a little differently).
    px = np.asarray(im).copy()
    px[:, S - S // 2 :] = px[:, : S // 2][:, ::-1]
    im = Image.fromarray(px)
    extra = cairo.ImageSurface(cairo.FORMAT_ARGB32, S, S)
    cr = cairo.Context(extra)
    fy1 -= lip
    fw, fh = fx1 - fx0, fy1 - fy0
    if S >= 32:  # glint on the base, lower left, under the face's edge
        ellipse(cr, k0 + S * 0.1, ky1 - side * 0.45, S * 0.035, S * 0.06)
        fill(cr, rgb("#FFFFFF", 0.45))
        cr.set_operator(cairo.OPERATOR_DEST_OUT)
        under_face(cr)
        fill(cr, rgb("#FFFFFF"))
        cr.set_operator(cairo.OPERATOR_OVER)
    if S > SOFT:  # shine, top left of the face
        ellipse(cr, fx0 + fw * 0.13, fy0 + fh * 0.2, S * 0.05, S * 0.03, -40 * pi / 180)
        fill(cr, rgb("#FFFFFF"))
    if S >= 32 and lang != "grey":  # two short slanted dashes each side
        ln = S * 0.05
        cr.set_line_width(S * 0.045)
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        cr.set_source_rgba(*rgb(BLUSH))
        for side_x in (fx0 + fw * 0.085, fx1 - fw * 0.085):
            for dx in (-S * 0.035, S * 0.035):
                x, y = side_x + dx, fy0 + fh * 0.62
                cr.move_to(x - ln * 0.35, y + ln * 0.5)
                cr.line_to(x + ln * 0.35, y - ln * 0.5)
                cr.stroke()
    elif (
        S >= SOFT and lang != "grey"
    ):  # one soft cheek per lower corner, as dashes would merge; below 24 px they would crowd the glyph
        for cx in (fx0 + 1.6, fx1 - 1.6):
            ellipse(cr, cx, fy1 - 1.5, 1.3, 0.9)
            fill(cr, rgb(BLUSH, 0.85))
    over = image(extra)
    badge = Image.new("RGBA", (S, S))
    kind_badge = state.rpartition("-")[2]
    if kind_badge in BADGE:  # over the glyph
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, S, S)
        cr = cairo.Context(surface)
        br = max(S * 0.25, 4.5)
        rim = max(1, round(S / 24)) if S < 48 else round(S * 0.04)
        c = S - br - 0.2
        cr.arc(c, c, br, 0, 2 * pi)
        fill(cr, rgb(STICKER))
        cr.arc(c, c, br - rim, 0, 2 * pi)
        fill(cr, rgb(BADGE[kind_badge]))
        inner = br - rim
        if kind_badge == "wait":  # three square dots
            dot = max(1, round(inner * 0.34))
            pitch = max(
                dot + 1, round(inner * 0.5)
            )  # whole pixels, a gap at least a pixel wide
            x = y = round(c - dot / 2)
            for dx in (-pitch, 0, pitch):
                cr.rectangle(x + dx, y, dot, dot)
        else:  # "!": a bar, a gap, a dot
            w, h = max(1, round(inner * 0.36)), inner * 1.4
            x, top_y = round(c - w / 2), round(c - h / 2)
            bar = round(h * 0.62)
            cr.rectangle(x, top_y, w, bar)
            cr.rectangle(x, max(round(c + h / 2 - w), top_y + bar + 1), w, w)
        fill(cr, rgb("#FFFFFF"))
        badge = image(surface)
    glyph = glyph_alpha(S, state)
    ink = Image.new("RGBA", (S, S), GREY_INK if lang == "grey" else INK)
    ink.putalpha(Image.fromarray(glyph.astype(np.uint8)))
    for layer in (over, ink, badge):
        im.alpha_composite(layer)
    badge_px = np.asarray(badge)[..., 3] > 0
    skip = (
        (np.asarray(over)[..., 3] > 0)
        | badge_px
        | ((glyph > 0) & (text not in SYMMETRIC))
    )
    return im, skip, glyph, badge_px


def pixels(S, state):
    return layers(S, state)[0]


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


def vector(S, state):
    """The README drawing (the 48 px design) drawn straight at S px."""
    lang, g = STATES[state]
    png = cairosvg.svg2png(
        bytestring=sticker(48, lang, g, state).encode(), output_width=S, output_height=S
    )
    return Image.open(io.BytesIO(png)).convert("RGBA")


def premultiplied(im, blur):
    a = np.asarray(im.filter(ImageFilter.GaussianBlur(blur)) if blur else im).astype(
        float
    )
    return a[..., :3] * a[..., 3:] / 255


def check(S, state, im):
    """What is wrong with a drawing:
    - not what layers() draws now;
    - the key: not left-right symmetric (the shine, glint, blush, badge and an asymmetric glyph left out);
      a blended pixel where its straight edges meet, i.e. an edge off the pixel grid: the face's side (its
      outline, then the face, across the middle row), the top (sticker, outline, face down the middle column) and the
      bottom (base, outline, sticker up it);
    - the glyph: not centred in the face to the pixel; 中 and A not mirror-exact;
    - unlike the README drawing at that size: their pixels, each blurred by a pixel, further apart on
      average than DESIGN allows."""
    lang, (kind, text) = STATES[state]
    drawn, skip, glyph, badge_px = layers(S, state)
    px = np.asarray(im.convert("RGBA")).astype(int)
    problems = []
    if (px != np.asarray(drawn)).any():
        problems.append("not what build.py draws: run it")
    both = ~skip & ~skip[:, ::-1]
    bad = sorted(
        {int(y) for y in np.nonzero((px != px[:, ::-1]).any(axis=2) & both)[0]}
    )
    if bad:
        problems.append(f"not symmetric in rows {bad}")
    x0, x1, y0, y1, _ = layout(S)
    sb, _, bw, _, _, fi, _ = grid(S)
    ring = "c" if sb else ""  # the sticker's cream border
    if fi:  # the face's outline, then the face, neither blended
        row = px[(y0 + y1) // 2, x0 - bw : x0 + 1]
        side = (row[:-1] == rgb255(OUTLINE)).all()
    else:  # the base, opaque, then the face
        row = px[(y0 + y1) // 2, x0 - 1 : x0 + 1]
        side = runs(row[:1])[0][0] == "b" and row[0, 3] == 255
    if not side or row[-1, :3].min() < 0xE0:
        problems.append("the face's side off the grid")
    kinds = "".join(k for k, _, _ in runs(px[: y0 + 1, S // 2]))
    if not re.fullmatch(f"_*{ring}o+c", kinds):
        problems.append(f"top {kinds}: a straight edge off the grid")
    kinds = "".join(k for k, _, _ in runs(px[::-1, S // 2][: S - y1]))
    if not re.fullmatch(f"[_b]*{ring}o+b+[lo]*", kinds) and not badge_px.any():
        problems.append(f"bottom {kinds}: a straight edge off the grid")
    g = glyph * ~badge_px
    cols, rows = np.nonzero(g.any(axis=0))[0], np.nonzero(g.any(axis=1))[0]
    if not badge_px.any() and cols[0] - x0 != x1 - 1 - cols[-1]:
        problems.append(f"glyph margins {cols[0] - x0} left, {x1 - 1 - cols[-1]} right")
    if (
        text in SYMMETRIC
        and (glyph != np.roll(glyph[:, ::-1], x0 + x1 - S, axis=1)).any()
    ):
        problems.append("glyph not its mirror image")
    diff = (
        np.abs(
            premultiplied(im.convert("RGBA"), 1) - premultiplied(vector(S, state), 1)
        ).mean()
        / 255
    )
    limit = DESIGN[S <= SOFT]
    if diff > limit:
        problems.append(
            f"{diff:.1%} from the README drawing (blurred), over {limit:.0%}"
        )
    return problems


# How far a drawing may be from the README drawing at its size (check()), above SOFT and up to it: whole-pixel
# outlines, a hard shadow and 16 and 20 px's own keys change small keys more.
DESIGN = (0.09, 0.15)


def rgb255(c):
    return tuple(round(v * 255) for v in rgb(c))


# --check: only checks the PNGs there are (exit 1 on a problem); otherwise draws them all, then checks them.
if __name__ == "__main__":
    if "--check" not in sys.argv:
        (HERE / "scalable").mkdir(exist_ok=True)
        for state, (lang, g) in STATES.items():
            (HERE / "scalable" / f"{state}.svg").write_text(sticker(48, lang, g, state))
            for S in SIZES:
                (HERE / str(S)).mkdir(exist_ok=True)
                pixels(S, state).save(HERE / str(S) / f"{state}.png", optimize=True)
    bad = [
        f"{S}/{state}.png: {p}"
        for state in STATES
        for S in SIZES
        for p in check(S, state, Image.open(HERE / str(S) / f"{state}.png"))
    ]
    print(
        "\n".join(bad)
        or f"{len(STATES) * len(SIZES)} drawings grid-fitted, symmetric and like the README drawing"
    )
    sys.exit(1 if bad else 0)
