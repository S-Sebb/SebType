# Tray icons

SebType's input-method status icons ("Set E" sticker keycaps, #63): EN for the US layout, 中, あ, ア,
and **a** in the English mode of Chinese or Japanese, which becomes **A** while Caps Lock is on.

`<size>/<state>.png` and `scalable/<state>.svg` come from `build.py` (needs Pillow, `fontTools`, pycairo, CairoSVG and
the Noto Sans CJK VF fonts):

```sh
python3 pc/icons/build.py
```

`scalable/<state>.svg`, the README drawing, is the design. Each size in `build.py`'s `SIZES` (16 to 66 px:
Windows' small icon and a 22 px Linux tray at each display scaling) is that drawing drawn again at its own
size, never scaled from another (#275), and grid-fitted so it looks like the vector drawing but crisp (#441):
- The keycap's parts (sticker border, shadow, outline, base, flare, face inset, lip, corner radius) are the
  same shares of the size in whole pixels, at least one each, so its outlines, face and base have hard edges.
  Its slanted sides and round corners stay antialiased. It is left-right symmetric. At 16 px a pixel a part
  would leave the glyph a cramped face, so it is set to look like the 24 px key shrunk: no cream border and
  no lip.
- The glyph is the font's outline with the README drawing's stroke round it. Its upright and level stems and
  bars and its extremes are moved onto whole pixels, each stem keeping its rounded width (at least a pixel);
  curves keep their antialiasing. Every glyph is centred in the face to the pixel; 中 and A are mirror-exact,
  and a stem across the middle takes the nearest width that can be centred there. Below 24 px the glyph is as
  wide as the face less a pixel a side, and its stroke is a quarter pixel: the drawing's would close あ's
  counters. Where grid-fitting can't keep 24 px's look, `BITMAPS` draws the glyph by hand: 中 at 16 and 20 px
  (a 2 px stem through a box of 24 px's proportions) and EN at 20 px (2 px uprights).
- Up to 24 px the shadow is hard and the face has no shine: blurred, they only smear. The blush follows Set
  E: a soft cheek a side at 24–28 px and two dashes a side from 32 px; below 24 px none, as it would crowd
  the glyph.

The build fails on a drawing that:
- isn't what `build.py` draws;
- isn't left-right symmetric, leaving out the shine, glint, blush, badge and an asymmetric glyph;
- has a blended pixel where the key's straight edges meet (the face's side, its top, the base's bottom),
  i.e. an edge off the pixel grid;
- has its glyph off-centre by a pixel, or 中 or A not its own mirror image;
- strays from the README drawing at its size: both blurred by a pixel, their pixels more than 9 % apart on
  average (15 % up to 24 px, where whole-pixel outlines, the hard shadow and 16 px's own key change more).

`scalable` is a 48 px vector drawing for any other size. States: `en`, `zh`, `zh-a`, `zh-caps`, `hira`, `kata`, `ja-a`, `ja-caps`, and while 中文 or 日本語 isn't ready (#275)
the key in grey with a badge: `zh-wait` and `hira-wait` ("…", preparing), `zh-off` and `hira-off` ("!", unavailable).

Linux's RPM installs every size in `/usr/share/sebtype/tray`, which the tray item sends as its pixmaps so the tray takes the size it draws at (#441), and the menu's icons as `sebtype-<state>` in hicolor (`linux/CMakeLists.txt`, see `pc/linux/README.md`). The glyphs are
outlines from Noto Sans CJK Black (SIL Open Font License 1.1, Google) and Nunito ExtraBold
([OFL](../../art/fonts/OFL-Nunito.txt)).
