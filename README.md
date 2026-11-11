<img src="assets/icon.png" width="96" height="96" alt="">

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
| FUTO Keyboard's code: `java/`, `native/`, `common/`, `tests/`, `tools/` other than SebType's files below, `.github/ISSUE_TEMPLATE/`, the root build files and the submodules. SebType's edits inside these files count as FUTO-derived | [FUTO Source First License 1.1](LICENSE.md) |
| The original AOSP keyboard code in those folders, up to commit `d847619a` | Apache-2.0 ([NOTICE](NOTICE)) |
| Code from other projects that FUTO vendored (sentencepiece, protobuf, ggml, llama.cpp, gemoji and others) | each project's own, in its folder |
| SebType's own code: `pc/`, `rime-android/`, `sebtype/`, `sync-server/`, `tools/rime-data/`, `tools/en-dict/`, `docs/`, with the exceptions below. Each folder's `LICENSE` file lists its exceptions. Also `tools/trim-emoji.sh`, `tools/pack-rime-ice.sh`, `tools/userdb-to-futo-backup.py` and `.github/workflows/` | MIT ([LICENSE-SebType](LICENSE-SebType)), Copyright (c) 2026 S-Sebb |
| `sebtype/assets/layouts/`: adapted from FUTO's layouts | Apache-2.0, like FUTO's layouts |
| `sebtype/res-stable/raw/emoji_i18n.jsondlgz` (FUTO's emoji names, trimmed) and `sebtype/res-stable/values*/*-sebtype-overrides.xml` (changed copies of FUTO's resources) | FUTO Source First License 1.1 |
| `sebtype/res-stable/raw/main_en.dict`, the English dictionary: FUTO's words with [wordfreq](https://github.com/rspeer/wordfreq)'s frequencies; its added words were checked against [SCOWL](https://wordlist.aspell.net) | FUTO Source First License 1.1, and CC BY-SA 4.0 for the frequencies ([NOTICE](NOTICE)) |
| The Picnic theme's fonts Nunito and Pixelify Sans, and the glyph outlines in the `pc/icons/` tray icons (Noto Sans CJK and Nunito) | SIL Open Font License 1.1 ([sebtype/fonts/OFL-Nunito.txt](sebtype/fonts/OFL-Nunito.txt), [sebtype/fonts/OFL-PixelifySans.txt](sebtype/fonts/OFL-PixelifySans.txt)) |
| SebType's patches to Mozc (`pc/linux/mozc/`, `pc/windows/mozc/`) and `pc/linux/mozc-keymap.tsv` (Mozc's MS-IME keymap with SebType's keys); Mozc itself | BSD-3-Clause, like Mozc |
| SebType's patch to Weasel (`pc/windows/weasel/sebtype.patch`); Weasel itself | GPL-3.0, like Weasel |
| SebType's patch to fcitx5-rime (`pc/linux/rime/menu.patch`); fcitx5-rime itself | LGPL-2.1-or-later, like fcitx5-rime |
| SebType's patches to RimeJni (`rime-android/patches/`); RimeJni itself | MIT, like RimeJni |
| librime | BSD-3-Clause |
| The rime-ice and 白霜 data in the APK and on the PCs (see Chinese below) | GPL-3.0 |

- What it must do: [Requirements (#1)](https://github.com/S-Sebb/sebtype/issues/1)
- Settled choices: [Decisions (#2)](https://github.com/S-Sebb/sebtype/issues/2)
- Device tests and the emulator: [docs/testing.md](docs/testing.md)
- Sync 中文's learned words with your own server: [sync-server/README.md](sync-server/README.md)
- Install on a phone (Obtainium, GitHub releases): [docs/install.md](docs/install.md)
- Build and publish a release: `sebtype/release.sh` (see [docs/install.md](docs/install.md))

**Chinese** is [rime-ice (雾凇拼音)](https://github.com/iDvel/rime-ice)'s schemas, Lua and settings with the
core dictionary and zh-moqi grammar of [白霜拼音 (rime-frost)](https://github.com/gaboolic/rime-frost), compiled
and bundled in the APK. Both are under the [GNU GPL v3](https://www.gnu.org/licenses/gpl-3.0.html); the licence
and a note of what was changed travel inside the bundle. Sources: rime-ice 2026.06.30 at
[6810e891](https://github.com/iDvel/rime-ice/tree/6810e8916d160498620a16fef2135956fecbd485) and rime-frost 1.0.4 at
[89ad92e4](https://github.com/gaboolic/rime-frost/tree/89ad92e450f9a5f4dcc2de67ba28004f9af0cc1e).
[`tools/rime-data/build.sh`](tools/rime-data/build.sh) builds the bundle from those pinned releases, and
`tools/rime-data/bench/bench.sh` measures its accuracy. It runs on librime with Lua from [rime-android/](rime-android/README.md).

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

When cloning the repository, you must perform a recursive clone to fetch all dependencies:
```
git clone --recursive https://gitlab.futo.org/keyboard/latinime.git
```

If you forgot to specify recursive clone, use this to fetch submodules:
```
git submodule update --init --recursive
```

You can then open the project in Android Studio and build it that way, or use gradle commands:
```
./gradlew assembleUnstableDebug
./gradlew assembleStableRelease
```

## APK signing

For official FUTO Keyboard versions, you can verify the APK's signing key fingerprint for integrity.

```
Signing key fingerprint for all versions except Google Play:

MD5: 3A:BB:71:C6:BB:E4:92:27:B1:E3:5D:81:01:48:6A:B0
SHA1: 5D:15:B3:6E:C9:6A:96:28:41:09:DD:62:93:0D:9C:39:9F:5F:06:43
SHA-256: 74:3F:AD:58:64:AB:C4:26:50:0B:2D:C2:C4:7C:8A:D3:24:CB:CD:16:03:3F:80:16:99:48:41:35:63:74:F9:95

```
