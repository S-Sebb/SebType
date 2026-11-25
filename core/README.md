# SebType core

One C++ library for every platform's frontend (#190): it hosts librime for 中文 (`src/rime.cpp`) and Mozc's
for 日本語 (`src/mozc.cpp`) and, for the phone, SebType's English (`src/english.cpp`, #244); on the PCs English
passes through. Mozc's session handler runs in the frontend's own process (`src/mozc_inprocess.cpp`, behind
`src/mozc_transport.h`), through the C interface in `src/sebtype_mozc.h`; `SEBTYPE_MOZC_LIB` names the
library that exports it, built from `engines/mozc/src/sebtype`: `libsebtype-mozc.so` on Linux,
`sebtype-mozc.dll` on Windows, and the phone's `libmozc.so` (#233). The transport saves Mozc's learned words
after a commit, at most every 180 s, and when it closes. It owns what SebType's languages share:

- the languages and switching: Win+Space (home ⇄ the last other language; Windows keeps its own switcher), the Shift tap for English
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

## 中文's model

`src/chinese.cpp` (`withChineseModel` in `include/sebtype/hosts.h`, `-DSEBTYPE_CHINESE_MODEL=ON`, #264) puts
SebType's Chinese model ([`engines/sebtype-lm`](../engines/sebtype-lm), `zh_lm`) around the Rime engine, as the
experiment of #259 measured it ([report](../docs/experiments/2026-11-16-chinese-lm.md)). Rime's list shows at
once. On a worker thread the model scores Rime's first 4 candidates that spell the whole input, adds a beam of 2
of its own, and with nothing typed predicts the next words; the `ready` callback announces its list, which
replaces Rime's first ones. Each list carries the revision it was asked for, which every key, pick and field or
setting change moves on; a late one never shows, and a beam still running for an old revision stops. Picking the
model's own candidate selects the Rime candidates that spell it, piece by piece, so Rime's user dictionary learns
it; where Rime has no such piece (a typo the model fixed) only the text is committed. A word the user taught
Rime, which its user dictionary puts first, stays ahead of Rime's other candidates: the data's last filter
(`data/rime/sebtype_learned.lua`, #369) names it, and `src/rime.cpp` marks it `learned`. With 繁, OpenCC's `t2s`
gives the model simplified text and `s2t` converts its own candidates. The model loads when the engine is made
and goes with it, so it starts and stops with Rime.

A slip that still reads as pinyin (`yuelaiyuxiao`, #478) gets a second look once the model's list has shown: the
worker's list comes with a second `ready`, and on that turn the engine's thread asks Rime for its readings of the
input with typo corrections (the data's `sebtype_corr` schema, in a session of its own, since librime isn't
thread-safe). Once typing pauses for 0.3 s the model weighs Rime's best one against its list: it goes first when
the model is at most 0.5 (in log probability) less sure of it than of the list's first, otherwise last on the
first page when at most 4 less sure, tuned on `data/rime/bench/sets/slips.tsv` (`android/test/chinese-lm/tune_fix.py`). A
key or a pick before the corrected list comes drops it; only a key during the weighing itself, one phrase's
score, waits for it. Its trace sections, "SebType zh load", "zh rank", "zh next", "zh
fixes" (the lookup), "zh fix" (the weighing) and "zh pick", are in `android/perf`'s traces.

The PCs run it too (#495), without next words (`ChineseModelPaths::nextWords`): their box shows only while typing.
Nor do they pass the field's text (`fieldText`): the model's context is what was typed, and a key the app takes
itself with nothing composing (Backspace, an arrow, Ctrl+A) or a focus change ends it. Their hosts read the box
through `page()`, whose next read is the turn for Rime's corrections, and `updating()` holds until those are weighed.
The characters' readings (`readings`, which tell the model's misreadings and its candidates that leave letters out,
#563) are `sebtype_readings.txt` in Rime's user folder, where setup unzips SebType's Chinese data.
llama.cpp is built for AVX2 (`GGML_NATIVE=OFF`), and an older CPU gets Rime alone. The Fcitx5 add-on draws the
model's list from Fcitx5's loop when `ready` comes; Windows' text service, across the server's pipe, asks again
(`Op::Refresh`) every 16 ms while the reply says `Engine::updating()`. `chinese.gguf` ships in the RPM
(`/usr/share/sebtype`) and beside `sebtype-server.exe`.

## Tests

`test/core_test.cpp` checks the riskiest paths with stand-in engines: language switching, the Shift tap,
简/繁, あ ⇄ ア, the popups and paging 6 to a page, the touch paths and both `commitOnSwitch` values. `linux/build.sh` runs them in its container on every
build (`%check` in `linux/sebtype.spec`), with 中文's model. Built with English, it also tests the English engine on the real
dictionary and model: `test/english.sh` builds and runs that on yanglab16. The English harness
(`android/test/english/run.sh`) measures its quality against today's keyboard. Built with 中文's model, it tests
the model around a stand-in Rime: `test/chinese.sh` builds and runs that on yanglab16, and the Chinese harness
(`android/test/chinese-lm/run.sh`, `SEBTYPE_ZH_CORE=1`) measures this code on the real Rime.

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
  Apache-2.0. SebType's English and Chinese models are CC BY-SA 4.0 (`engines/LICENSE`, `NOTICE`); OpenCC,
for 繁 around the Chinese model, is Apache-2.0.
