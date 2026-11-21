# Tray icons

SebType's input-method status icons ("Set E" sticker keycaps, #63): EN for the US layout, 中, あ, ア,
and **a** in the English mode of Chinese or Japanese, which becomes **A** while Caps Lock is on.

`<size>/<state>.png` and `scalable/<state>.svg` come from `build.py` (needs Pillow, `fontTools`, pycairo and the
Noto Sans CJK VF fonts):

```sh
python3 pc/icons/build.py
```

Each size in `build.py`'s `SIZES` (16 to 66 px: Windows' small icon and a 22 px Linux tray at each display scaling) is drawn at its own pixel size, never scaled from another
(#275): the keycap's rim and outline are whole pixels with hard edges, and the glyph is the vector glyph
rastered at that size with no grey fringe (a pixel is ink when at least half of it is), 中 and A drawn as their
own mirror images. The build fails if a glyph is off-centre by a pixel or a key isn't left-right symmetric;
the check leaves out only the blush (both sides slant the same way), the glint (lower left) and the badge
(lower right). Small sizes keep the look with fewer details: blush from 20 px, the face's own outline
from 22 px. `scalable` is a 48 px vector drawing for any other size. States: `en`, `zh`, `zh-a`, `zh-caps`, `hira`, `kata`, `ja-a`, `ja-caps`, and while 中文 or 日本語 isn't ready (#275)
the key in grey with a badge: `zh-wait` and `hira-wait` ("…", preparing), `zh-off` and `hira-off` ("!", unavailable).

Linux's RPM installs every size in `/usr/share/sebtype/tray`, which the tray item sends as its pixmaps so the tray takes the size it draws at (#441), and the menu's icons as `sebtype-<state>` in hicolor (`linux/CMakeLists.txt`, see `pc/linux/README.md`). The glyphs are
outlines from Noto Sans CJK Black (SIL Open Font License 1.1, Google) and Nunito ExtraBold
([OFL](../../art/fonts/OFL-Nunito.txt)).
