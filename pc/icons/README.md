# Tray icons

SebType's input-method status icons ("Set E" sticker keycaps, #63): EN for the US layout, 中, あ, ア,
and **a** in the English mode of Chinese or Japanese, which becomes **A** while Caps Lock is on.

`<size>/<state>.svg` comes from `build.py` (needs `fontTools` and the Noto Sans CJK VF fonts):

```sh
python3 pc/icons/build.py
```

Each of 16, 20, 22, 24 and 32 px has its own drawing, so its lines land on whole pixels: no blush at
16 px, blush cheeks from 20 px and the two-dash blush from 32 px. `scalable` is a 48 px drawing for
larger and HiDPI sizes. States: `en`, `zh`, `zh-a`, `zh-caps`, `hira`, `kata`, `ja-a`, `ja-caps`.

Linux installs them as an icon theme (`pc/linux/setup-ime.sh`, see `pc/linux/README.md`). The glyphs are
outlines from Noto Sans CJK Black (SIL Open Font License 1.1, Google) and Nunito ExtraBold
([OFL](../../sebtype/fonts/OFL-Nunito.txt)).
