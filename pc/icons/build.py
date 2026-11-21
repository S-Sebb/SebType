#!/usr/bin/env python3
"""Writes SebType's tray icons (#63, "Set E" sticker keycap): pc/icons/<size>/<state>.png and
pc/icons/scalable/<state>.svg.

Each tray size (16 to 66 px, SIZES) is drawn at its own pixel size, not scaled from a
larger drawing, with the same shapes as the scalable one: its straight edges, strokes and glyphs fall on whole
pixels with hard edges, and only the round corners shade their edge pixels; the glyph is the font hinted at
that size (#275: a large drawing scaled down had soft grey edges). Small
sizes keep the look with fewer details: blush from 20 px, the face's own outline from 22 px. "scalable" is a
48 px vector drawing with the design's full proportions, for other sizes; its glyphs are font outlines, so it
needs no font. Fonts: Noto Sans CJK Black (中 あ ア, from the system's Noto Sans CJK VF) and Nunito ExtraBold
(EN a A, android/app/src/main/res/font), both OFL. Needs fontTools, Pillow and pycairo. Linux's RPM installs them in
hicolor (linux/CMakeLists.txt); Windows' .ico files hold the PNGs (windows/make_icons.py, #13, #65).
"""

import io
import sys
from math import pi
from pathlib import Path

import cairo
import numpy as np
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTCollection, TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from PIL import Image, ImageChops, ImageDraw, ImageFont

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
SYMMETRIC = {
    "中",
    "A",
}  # centred exactly; the others within a pixel, as their shapes lean
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


# The approved drawings' whole pixels per tray size (#63): sticker border, shadow, outline, base side, flare,
# face inset, lip. Other sizes take params()' proportions, rounded (32 px too: its own grid's 2 px outline and
# shadow made a smaller face than the scalable drawing's, #441).
GRID = {
    16: (1, 0, 1, 2, 0, 0, 0),
    20: (1, 1, 1, 3, 0, 0, 1),
    22: (1, 1, 1, 4, 1, 1, 1),
    24: (1, 1, 1, 4, 1, 1, 1),
}
# Windows' small icon at 100 % to 400 % (16 to 64 by 4, 48 and 56) and a 22 px Linux tray at 100 % to 300 %
# (22, 28, 33, 39, 44, 55, 66), so neither scales one (#441).
SIZES = (16, 20, 22, 24, 28, 32, 33, 36, 39, 40, 44, 48, 55, 56, 64, 66)


def grid(S):
    return GRID.get(S) or tuple(max(1, round(v)) for v in params(S))


def font(kind, px):
    """Nunito ExtraBold, or Noto Sans CJK at its Black weight."""
    if kind == "lat":
        return ImageFont.truetype(str(NUNITO), px)
    f = ImageFont.truetype(NOTO_CJK, px, index=2 if kind == "sc" else 0)
    f.set_variation_by_axes([900])
    return f


def holes(im):
    """The closed counters in a glyph mask: background areas that don't reach its edge."""
    w, h = im.size
    px = im.load()
    seen, n = set(), 0
    for start in ((x, y) for y in range(h) for x in range(w)):
        if start in seen or px[start]:
            continue
        n += 1
        todo, seen_here = [start], {start}
        while todo:
            x, y = todo.pop()
            for q in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if 0 <= q[0] < w and 0 <= q[1] < h and q not in seen_here and not px[q]:
                    seen_here.add(q)
                    todo.append(q)
        seen |= seen_here
    return n - 1  # the area around the glyph


def bitmap(kind, text, w, h, parity):
    """The glyph's ink as an L mask at most w x h, hinted at its own size: the largest that fits whose width
    is even or odd as parity says (when it says), so it centres on whole pixels. Below 20 px its strokes are a pixel wider
    (its ink twice, a pixel apart, letters a pixel further apart), as bold as the larger sizes, unless that
    would close a counter: a size smaller rather than a lighter glyph."""
    for px in range(h * 2, 4, -1):
        f = font(kind, px)
        bold = px < 20
        im = Image.new("L", (px * 4, px * 2), 0)
        d = ImageDraw.Draw(im)
        d.fontmode = "1"  # hinted to whole pixels, no grey fringe
        x = 2
        for ch in text:
            d.text((x, 2), ch, font=f, fill=255)
            x += round(f.getlength(ch)) + bold
        if bold:
            wide = ImageChops.lighter(im, ImageChops.offset(im, 1, 0))
            if holes(wide.crop(wide.getbbox())) == holes(im.crop(im.getbbox())):
                im = wide
        box = im.getbbox()
        if (
            box
            and box[2] - box[0] <= w
            and box[3] - box[1] <= h
            and parity in (None, (box[2] - box[0]) % 2)
        ):
            return im.crop(box)
    raise ValueError(text)


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


def face(S):
    """The face's inside columns, x0 to x1 (exclusive), as pixels() draws it."""
    sb, sh, bw, side, t, fi, lip = grid(S)
    return sb + bw + t + fi, S - sb - bw - t - fi


def check(S, state, im):
    """What is wrong with a drawing: the glyph off centre in the face (its ink's left and right margins
    differ, by more than a pixel for a glyph that isn't symmetric), or the body not a mirror image (the glyph, blush, glint and badge aside)."""
    lang, (kind, text) = STATES[state]
    px = np.asarray(im.convert("RGBA")).astype(int)
    rgb_ = px[..., :3]
    ink = (rgb_ == np.array(rgb(GREY_INK if lang == "grey" else INK)[:3]) * 255).all(
        axis=2
    ) & (px[..., 3] == 255)
    x0, x1 = face(S)
    keep = np.ones((S, S), bool)
    if (
        state.rpartition("-")[2] in BADGE
    ):  # the badge sits bottom right, over the face's corner
        br = max(S * 0.25, 4.5)
        keep[int(S - 2 * br - 1) :, int(S - 2 * br - 1) :] = False
    cols = np.nonzero((ink & keep)[:, x0:x1].any(axis=0))[0]
    problems = []
    if len(cols):
        left, right = cols[0], x1 - x0 - 1 - cols[-1]
        if abs(left - right) > (0 if text in SYMMETRIC else 1):
            problems.append(f"glyph margins {left} left, {right} right")
    blush = (rgb_ == np.array(rgb(BLUSH)[:3]) * 255).all(axis=2)
    sb, sh, bw, side, t, fi, lip = grid(S)
    gx, gy, gw, gh = GLINT(S, sb + bw, S - sh - sb - bw, side)
    keep &= ~ink & ~blush
    if S >= 32:
        keep[gy : gy + gh, gx : gx + gw] = False
    both = keep & keep[:, ::-1]
    rows = sorted(
        {int(y) for y in np.nonzero(((px != px[:, ::-1]).any(axis=2)) & both)[0]}
    )
    if rows:
        problems.append(f"body not symmetric in rows {rows}")
    return problems


def pixels(S, state):
    """sticker()'s key at S px on its pixel grid: its edges on whole pixels (only round corners are partly
    covered), its shadow, glint and blush in whole pixels, and the glyph hinted at its size."""
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

    def under_face(cr):  # the face with its outline or rim, which covers the base
        if S >= 22:
            rounded(cr, fx0 - bw, fy0, fx1 + bw, fy1 + bw, rf + bw)
        else:
            rounded(cr, fx0, fy0, fx1, fy1 + 1, rf)

    under_face(cr)
    fill(cr, rgb(OUTLINE if S >= 22 else bot))
    if S >= 22:  # top face with its own outline and a beige lip at its bottom
        rounded(cr, fx0, fy0, fx1, fy1, rf)
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
    d = ImageDraw.Draw(im)
    fw, fh = fx1 - fx0, fy1 - fy0
    blush = S >= 20 and lang != "grey"
    if blush and S >= 32:  # two short slanted dashes each side
        w = 1 if S < 48 else 2
        n = 2 if S < 40 else 3
        by = round(fy0 + fh * 0.62)
        for side_x in (fx0 + fw * 0.085, fx1 - fw * 0.085):
            for dx in (-S * 0.035, S * 0.035):
                x = round(side_x + dx - (n + w - 1) / 2)
                for i in range(n):
                    d.rectangle(
                        (x + i, by - i, x + i + w - 1, by - i + w - 1), fill=BLUSH
                    )
    elif blush:  # 20-24 px: one cheek per lower corner
        for x in (fx0, fx1 - 2):
            d.rectangle((x, fy1 - 2, x + 1, fy1 - 2), fill=BLUSH)
    margin = (fw * 0.17 if S >= 32 else fw * 0.1) if blush else fw * 0.06
    bx0, bx1, by0, by1 = fx0 + margin, fx1 - margin, fy0 + fh * 0.04, fy1 - fh * 0.04
    # As tall as sticker()'s glyph with its stroke, which made the outlines bolder.
    stroke = 0.4 if S < 24 else S * 0.022
    gh = fh * (0.8 if kind != "lat" else 0.66 if text != "a" else 0.6) + stroke
    m = bitmap(
        kind,
        text,
        round(bx1 - bx0 + stroke),
        round(min(gh, by1 - by0 + stroke)),
        fw % 2 if text in SYMMETRIC else None,
    )
    d.bitmap(
        ((fx0 + fx1 - m.width) // 2, round((by0 + by1 - m.height) / 2)),
        m,
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
print("\n".join(bad) or f"{len(STATES) * len(SIZES)} drawings centred and symmetric")
sys.exit(1 if bad else 0)
