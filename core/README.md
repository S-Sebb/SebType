# SebType core

One C++ library for every platform's frontend (#190): it hosts librime for 中文 (`src/rime.cpp`) and Mozc's
for 日本語 (`src/mozc.cpp`) and, for the phone, SebType's English (`src/english.cpp`, #244); on the PCs English
passes through. Mozc's session handler runs in the frontend's own process (`src/mozc_inprocess.cpp`, behind
`src/mozc_transport.h`), through the C interface in `src/sebtype_mozc.h`; `SEBTYPE_MOZC_LIB` names the
library that exports it, built from `engines/mozc/src/sebtype`: `libsebtype-mozc.so` on Linux,
`sebtype-mozc.dll` on Windows, and the phone's `libmozc.so` (#233). The transport saves Mozc's learned words
after a commit, at most every 180 s, and when it closes. It owns what SebType's languages share:

- the languages and switching: Win+Space (home ⇄ the last other language), the Shift tap for English
  letters, Ctrl+Shift+F for 简/繁 and Alt+` for あ ⇄ ア (`src/core.cpp`);
- the candidate list and paging (`src/pager.cpp`; Rime pages 6 at a time, as its settings say), and the
  phone's unpaged list and touch paths (pick a candidate by index, retype, move the cursor);
- what 🌐 does to unchosen text: the PCs type it in as focus loss does, the phone drops it (`commitOnSwitch`);
- the settings (`sebtype.conf`: `~/.config/sebtype/` on Linux, the app's files on the phone);
- the tray: its icon names (the files in `pc/icons/`) and its menu.

A frontend feeds it keys and draws what it says: on Linux the Fcitx5 add-on in [`linux/`](../linux), on
Windows the text service and its server in [`windows/`](../windows), on Android the app through JNI in
[`android/native/`](../android/native).

## English

`src/english.cpp` (`makeEnglish` in `include/sebtype/hosts.h`) runs AOSP LatinIME's decoder, copied unchanged
into [`engines/latinime`](../engines/latinime), called directly without Java, on the dictionary
`data/en-dict/en_US.dict`, and SebType's model ([`engines/sebtype-lm`](../engines/sebtype-lm)) on llama.cpp.
The decoder finds the words near the keys tapped (`Engine::setLayout` gives their rectangles, `Key::x` and `y`
the touch point); the model ranks them and decides what a space corrects. The model loads on a worker thread when
the first letter is typed; until then AOSP's own autocorrect rule decides. Next words are computed on that thread
for the text before the cursor (`Engine::setContext`) and announced through the `ready` callback; before the
model has loaded, the dictionaries' word pairs stand in. Learned words go to AOSP's user-history dictionary in
the user folder (none when learning is off), offensive words are never suggested or learned, a word after "@"
lists e-mail domains, and punctuation after a picked word joins it (#39). CMake builds it with
`-DSEBTYPE_ENGLISH=ON` (`-DSEBTYPE_CJK=OFF` leaves out librime and Mozc).

## Tests

`test/core_test.cpp` checks the riskiest paths with stand-in engines: language switching, the Shift tap,
简/繁, あ ⇄ ア, the popups and paging 6 to a page, the touch paths and both `commitOnSwitch` values. `linux/build.sh` runs them in its container on every
build (`%check` in `linux/sebtype.spec`). Built with English, it also tests the English engine on the real
dictionary and model: `test/english.sh` builds and runs that on yanglab16. The English harness
(`android/test/english/run.sh`) measures its quality against today's keyboard.

## Licences and credits

- SebType's own code here is MIT ([LICENSE-SebType](../LICENSE-SebType)), but for these files:
  - `src/rime.cpp` follows [fcitx5-rime](https://github.com/fcitx/fcitx5-rime) (Copyright 2017 Xuetian
    Weng and contributors): LGPL-2.1-or-later, like fcitx5-rime
    ([LICENSE-LGPL-2.1](../LICENSE-LGPL-2.1)).
  - `src/mozc.cpp` follows fcitx5-mozc, the Fcitx 5 frontend of [fcitx/mozc](https://github.com/fcitx/mozc)
    (`src/unix/fcitx5`, Copyright 2010-2018 Google Inc. and 2017 Weng Xuetian): BSD-3-Clause, like Mozc.
- The protocol it speaks to Mozc is generated from Mozc's own `.proto` files in `engines/mozc`
  (BSD-3-Clause).
- The engines keep their licences: librime BSD-3-Clause, Mozc BSD-3-Clause, AOSP LatinIME's decoder
  Apache-2.0. SebType's English model is CC BY-SA 4.0 (`engines/LICENSE`, `NOTICE`).
