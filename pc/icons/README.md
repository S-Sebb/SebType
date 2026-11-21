# Tray icons

SebType's input-method status icons ("Set E" sticker keycaps, #63): EN for the US layout, 中, あ, ア,
and **a** in the English mode of Chinese or Japanese, which becomes **A** while Caps Lock is on.

`<size>/<state>.png` and `scalable/<state>.svg` come from `build.py` (needs Pillow, `fontTools`, pycairo and the
Noto Sans CJK VF fonts):

```sh
python3 pc/icons/build.py
```

Each size in `build.py`'s `SIZES` (16 to 66 px: Windows' small icon and a 22 px Linux tray at each display scaling) is drawn at its own pixel size, never scaled from another
(#275), by the same rules at every size (#441): the keycap's parts are the same shares of the size in whole
pixels (at least one each), so 16 px is the 66 px key shrunk. The glyph is drawn from its strokes' centrelines,
traced from the fonts, with one pen for every glyph at a size and its strokes snapped to whole pixels; 中 and A
are their own mirror images. The pen is 0.065 of the size in whole pixels, thinner where a glyph would
otherwise join its strokes or fill its counters, and never thinner than a smaller size's. A 1 px pen draws pixel
lines (one pixel a row or column). The build fails on a drawing that breaks a rule:
- a glyph off-centre by a pixel;
- an upright or level stroke not the size's pen, a stroke narrowing to a pixel, a size whose glyphs have
  different pens, or a pen thinner than a smaller size's;
- strokes touching that are a pixel or more apart in the font shrunk to the glyph's size, a counter filled
  that holds a whole pixel there (あ's, 中's two, A's, a's), or strokes closing a counter the font hasn't;
- a glyph box more than a pixel off its share of the face;
- a face inset or base height more than a pixel off its share;
- a blush that's missing from 20 px up or touches the glyph;
- a key that isn't left-right symmetric. The mirror test leaves out only the blush (both sides slant the same
  way), the glint (lower left) and the badge (lower right).

Two rules bend, and the check says so:
- 中's centre stroke must sit on the face's middle, so it is a pixel wider than the pen where the pen hasn't
  the face's parity (no stroke of the pen's width can be centred there).
- Where even a 1 px pen closes a counter the font hasn't, the glyph's last stroke ends a point early (あ's tail
  at 16 and 20 px, which would close its right lobe).

`scalable` is a 48 px vector drawing for any other size. States: `en`, `zh`, `zh-a`, `zh-caps`, `hira`, `kata`, `ja-a`, `ja-caps`, and while 中文 or 日本語 isn't ready (#275)
the key in grey with a badge: `zh-wait` and `hira-wait` ("…", preparing), `zh-off` and `hira-off` ("!", unavailable).

Linux's RPM installs every size in `/usr/share/sebtype/tray`, which the tray item sends as its pixmaps so the tray takes the size it draws at (#441), and the menu's icons as `sebtype-<state>` in hicolor (`linux/CMakeLists.txt`, see `pc/linux/README.md`). The glyphs are
outlines from Noto Sans CJK Black (SIL Open Font License 1.1, Google) and Nunito ExtraBold
([OFL](../../art/fonts/OFL-Nunito.txt)).
