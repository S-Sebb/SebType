# SebType core

One C++ library for every platform's frontend (#190): it hosts librime for 中文 (`src/rime.cpp`) and Mozc's
server for 日本語 (`src/mozc.cpp`, over Mozc's IPC), and passes English through. It owns what SebType's
languages share:

- the languages and switching: Win+Space (home ⇄ the last other language), the Shift tap for English
  letters, Ctrl+Shift+F for 简/繁 and Alt+` for あ ⇄ ア (`src/core.cpp`);
- the candidate list and paging (`src/pager.cpp`; Rime pages 6 at a time, as its settings say);
- the settings the Configurator writes (`~/.config/sebtype/sebtype.conf` on Linux: `[Languages] Order=`);
- the tray: its icon names (the files in `pc/icons/`) and its menu.

A frontend feeds it keys and draws what it says: on Linux the Fcitx5 add-on in [`linux/`](../linux).

## Tests

`test/core_test.cpp` checks the riskiest paths with stand-in engines: language switching, the Shift tap,
简/繁, あ ⇄ ア, the popups and paging 6 to a page. `linux/build.sh` runs them in its container on every
build (`%check` in `linux/sebtype.spec`).

## Licences and credits

- SebType's own code here is MIT ([LICENSE-SebType](../LICENSE-SebType)), but for these files:
  - `src/rime.cpp` follows [fcitx5-rime](https://github.com/fcitx/fcitx5-rime) (Copyright 2017 Xuetian
    Weng and contributors): LGPL-2.1-or-later, like fcitx5-rime.
  - `src/mozc.cpp` follows fcitx5-mozc, the Fcitx 5 frontend in `engines/mozc/src/unix/fcitx5`
    (Copyright 2010-2018 Google Inc. and 2017 Weng Xuetian): BSD-3-Clause, like Mozc.
- The protocol it speaks to Mozc's server is generated from Mozc's own `.proto` files in `engines/mozc`
  (BSD-3-Clause).
- The engines keep their licences: librime BSD-3-Clause, Mozc BSD-3-Clause.
