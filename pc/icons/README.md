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
traced from the fonts, with one pen width per size and its strokes snapped to whole pixels; 中 and A are their
own mirror images. The build fails on a drawing that breaks a rule:
- a glyph off-centre by a pixel;
- an upright or level stroke not the size's width, or a stroke narrowing to a pixel;
- a glyph box more than a pixel off its share of the face;
- a face inset or base height more than a pixel off its share;
- a blush that's missing from 20 px up or touches the glyph;
- a key that isn't left-right symmetric. The mirror test leaves out only the blush (both sides slant the same
  way), the glint (lower left) and the badge (lower right).

Two sizes bend a rule, and the check says so:
- 中's centre stroke must sit on the face's middle column(s), so 中 takes the next stroke width up where the
  size's width hasn't the face's parity.
- At 16 px, 中's 2 px strokes would close its box, so its box is 1 px.

`scalable` is a 48 px vector drawing for any other size. States: `en`, `zh`, `zh-a`, `zh-caps`, `hira`, `kata`, `ja-a`, `ja-caps`, and while 中文 or 日本語 isn't ready (#275)
the key in grey with a badge: `zh-wait` and `hira-wait` ("…", preparing), `zh-off` and `hira-off` ("!", unavailable).

Linux's RPM installs every size in `/usr/share/sebtype/tray`, which the tray item sends as its pixmaps so the tray takes the size it draws at (#441), and the menu's icons as `sebtype-<state>` in hicolor (`linux/CMakeLists.txt`, see `pc/linux/README.md`). The glyphs are
outlines from Noto Sans CJK Black (SIL Open Font License 1.1, Google) and Nunito ExtraBold
([OFL](../../art/fonts/OFL-Nunito.txt)).
