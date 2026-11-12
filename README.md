<img src="art/icon.png" width="96" height="96" alt="">

# SebType

SebType is a **modified version of [FUTO Keyboard](https://github.com/futo-org/android-keyboard)**: a
personal Android keyboard for Chinese (pinyin), Japanese (romaji) and English, with one layout for all
three. It is not made, endorsed or supported by FUTO; please don't report SebType problems to FUTO.

**Licences:** the Android app is FUTO's code with SebType's changes, under FUTO's
[FUTO Source First License 1.1](LICENSE.md) (see also [NOTICE](NOTICE)). That licence makes it source-available, not
open source: anyone may use it, but it may be modified only for non-commercial purposes and shared only free of
charge and non-commercially, with FUTO's payment features and notices left in. SebType's own code outside FUTO's
files is under the [MIT licence](LICENSE-SebType). Each part keeps the licence of the project it came from:

| Part | Licence |
|---|---|
| FUTO Keyboard's code: `android/app/` other than SebType's files below, `android/tools/contributors.py`, `android/tools/make-keyboard-text-py/`, `.github/ISSUE_TEMPLATE/`, the Gradle files in `android/` (other than `android/build.gradle`), `android/app/libs/` (FUTO's Mozc library) and the FUTO files brought in from its submodules (`android/app/src/main/assets/layouts/`, the translations in `android/app/src/main/res/values-ja/` and `values-zh-rCN/`, `android/app/src/main/res/raw/ml4_q6_k.gguf`). SebType's edits inside these files count as FUTO-derived | [FUTO Source First License 1.1](LICENSE.md) |
| The original AOSP keyboard code in those folders, up to commit `d847619a` | Apache-2.0 ([NOTICE](NOTICE)) |
| Code from other projects that FUTO vendored (sentencepiece, protobuf, ggml, llama.cpp, gemoji and others) | each project's own, in its folder |
| SebType's own code: `pc/`, `art/`, `data/`, `docs/`, `sync-server/`, `tools/`, `.github/workflows/`, and SebType's own files in `android/` ([android/LICENSE](android/LICENSE) lists them: the scripts, `test/`, `perf/`, `rime/`, and in the app the `dev.sebb.sebtype` code, its strings and its launcher icon), with the exceptions below. Each folder's `LICENSE` file lists its exceptions | MIT ([LICENSE-SebType](LICENSE-SebType)), Copyright (c) 2026 S-Sebb |
| `android/app/src/main/assets/layouts/SebType/`: adapted from FUTO's layouts | Apache-2.0, like FUTO's layouts |
| `android/app/src/main/res/raw/emoji_i18n.jsondlgz` (FUTO's emoji names, trimmed) | FUTO Source First License 1.1 |
| `android/app/src/main/res/raw/main_en.dict`, the English dictionary: FUTO's words with [wordfreq](https://github.com/rspeer/wordfreq)'s frequencies; its added words were checked against [SCOWL](https://wordlist.aspell.net) | FUTO Source First License 1.1, and CC BY-SA 4.0 for the frequencies ([NOTICE](NOTICE)) |
| The Picnic theme's fonts Nunito and Pixelify Sans, and the glyph outlines in the `pc/icons/` tray icons (Noto Sans CJK and Nunito) | SIL Open Font License 1.1 ([art/fonts/OFL-Nunito.txt](art/fonts/OFL-Nunito.txt), [art/fonts/OFL-PixelifySans.txt](art/fonts/OFL-PixelifySans.txt)) |
| SebType's Mozc (`engines/mozc/`: Mozc with fcitx/mozc's Fcitx 5 frontend and SebType's changes) and `pc/linux/mozc-keymap.tsv` (Mozc's MS-IME keymap with SebType's keys) | BSD-3-Clause, like Mozc |
| SebType's Weasel (`pc/weasel/`: Weasel with SebType's changes) | GPL-3.0, like Weasel |
| SebType's fcitx5-rime (`pc/fcitx5-rime/`: fcitx5-rime with SebType's changes) | LGPL-2.1-or-later, like fcitx5-rime |
| SebType's Fcitx5 (`pc/fcitx5/`: Fcitx5 with SebType's changes) | LGPL-2.1-or-later, like Fcitx5 |
| SebType's librime (`engines/librime/`: librime with SebType's changes) | BSD-3-Clause, like librime |
| Fedora's RPM specs with SebType's changes (`pc/linux/mozc/*.spec`, `pc/linux/rime/*.spec`) | MIT, like Fedora's specs |
| SebType's patches to RimeJni (`android/rime/patches/`); RimeJni itself | MIT, like RimeJni |
| librime | BSD-3-Clause |
| The rime-ice and 白霜 data in the APK and on the PCs (see Chinese below) | GPL-3.0 |

- What it must do: [Requirements (#1)](https://github.com/S-Sebb/sebtype/issues/1)
- Settled choices: [Decisions (#2)](https://github.com/S-Sebb/sebtype/issues/2)
- Device tests and the emulator: [docs/testing.md](docs/testing.md)
- Sync 中文's learned words and your Japanese and English personal dictionaries with your own server: [sync-server/README.md](sync-server/README.md)
- Install on a phone (Obtainium, GitHub releases): [docs/install.md](docs/install.md)
- Bring in your own words (Rime word lists and learned words, Japanese and English dictionaries): [docs/import.md](docs/import.md)
- Build and publish a release: `android/release.sh` (see [docs/install.md](docs/install.md))

**Chinese** is [rime-ice (雾凇拼音)](https://github.com/iDvel/rime-ice)'s schemas, Lua and settings with the
core dictionary and zh-moqi grammar of [白霜拼音 (rime-frost)](https://github.com/gaboolic/rime-frost), compiled
and bundled in the APK. Both are under the [GNU GPL v3](https://www.gnu.org/licenses/gpl-3.0.html); the licence
and a note of what was changed travel inside the bundle. Sources: rime-ice 2026.06.30 at
[6810e891](https://github.com/iDvel/rime-ice/tree/6810e8916d160498620a16fef2135956fecbd485) and rime-frost 1.0.4 at
[89ad92e4](https://github.com/gaboolic/rime-frost/tree/89ad92e450f9a5f4dcc2de67ba28004f9af0cc1e).
[`data/rime/build.sh`](data/rime/build.sh) builds the bundle from those pinned releases, and
`data/rime/bench/bench.sh` measures its accuracy. It runs on librime with Lua from [android/rime/](android/rime/README.md).

SebType's application id is `dev.sebb.sebtype`, so it installs next to stock FUTO Keyboard.
FUTO's own README follows unchanged.

---

# FUTO Keyboard

The goal is to make a good modern keyboard that stays offline and doesn't spy on you. This keyboard is a fork of [LatinIME, The Android Open-Source Keyboard](https://android.googlesource.com/platform/packages/inputmethods/LatinIME), with significant changes made to it.

Check out the [FUTO Keyboard website](https://keyboard.futo.tech/) for downloads and more information.

The code is licensed under the [FUTO Source First License 1.1](LICENSE.md).

## Issue tracking and contributing

Please check the GitHub repository to report issues: [https://github.com/futo-org/android-keyboard/](https://github.com/futo-org/android-keyboard/)

The source code is hosted on our [internal GitLab](https://gitlab.futo.org/keyboard/latinime) and mirrored to [GitHub](https://github.com/futo-org/android-keyboard/). As registration is closed on our internal GitLab, we use GitHub instead for issues and pull requests.

Due to custom license, pull requests to this repository require signing a [CLA](https://cla.futo.org/) which you can do after opening a PR. Contributions to the [layouts repo](https://github.com/futo-org/futo-keyboard-layouts) don't require CLA as they're Apache-2.0

If you want to help translate the app, please do so via our Pontoon instance: https://i18n-keyboard.futo.org/

## Layouts

If you want to contribute layouts, check out the [layouts repo](https://github.com/futo-org/futo-keyboard-layouts).

## Building

`android/build.sh` builds SebType's APKs (`release`, `debug`, and the x86_64 emulator builds); see its header.
Android Studio or plain Gradle work too:
```
./gradlew assembleDebug
./gradlew assembleRelease
```

## APK signing

For official FUTO Keyboard versions, you can verify the APK's signing key fingerprint for integrity.

```
Signing key fingerprint for all versions except Google Play:

MD5: 3A:BB:71:C6:BB:E4:92:27:B1:E3:5D:81:01:48:6A:B0
SHA1: 5D:15:B3:6E:C9:6A:96:28:41:09:DD:62:93:0D:9C:39:9F:5F:06:43
SHA-256: 74:3F:AD:58:64:AB:C4:26:50:0B:2D:C2:C4:7C:8A:D3:24:CB:CD:16:03:3F:80:16:99:48:41:35:63:74:F9:95

```
