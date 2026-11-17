# Tray icons

SebType's input-method status icons ("Set E" sticker keycaps, #63): EN for the US layout, 中, あ, ア,
and **a** in the English mode of Chinese or Japanese, which becomes **A** while Caps Lock is on.

`<size>/<state>.png` and `scalable/<state>.svg` come from `build.py` (needs Pillow, `fontTools`, pycairo and the
Noto Sans CJK VF fonts):

```sh
python3 pc/icons/build.py
```

Each of 16, 20, 22, 24, 32, 40, 44, 48 and 64 px is drawn at its own pixel size, never scaled from another
(#275): the keycap's rim and outline are whole pixels with hard edges, and the glyph is hinted at that size
with no grey fringe. Small sizes keep the look with fewer details: blush from 20 px, the face's own outline
from 22 px. `scalable` is a 48 px vector drawing for any other size. States: `en`, `zh`, `zh-a`, `zh-caps`, `hira`, `kata`, `ja-a`, `ja-caps`, and while 中文 or 日本語 isn't ready (#275)
the key in grey with a badge: `zh-wait` and `hira-wait` ("…", preparing), `zh-off` and `hira-off` ("!", unavailable).

Linux's RPM installs them as `sebtype-<state>` in hicolor (`linux/CMakeLists.txt`, see `pc/linux/README.md`). The glyphs are
outlines from Noto Sans CJK Black (SIL Open Font License 1.1, Google) and Nunito ExtraBold
([OFL](../../art/fonts/OFL-Nunito.txt)).
