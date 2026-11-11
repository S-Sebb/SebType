# SebType on Windows

On Windows, SebType's Chinese is Weasel (小狼毫) with the phone's Chinese data: rime-ice's schema and Lua
with 白霜's dictionary. English is Windows' plain US layout. Japanese is SebType's own Mozc (see Japanese
below). One installer, `SebType-setup-<version>.exe`, installs, upgrades and removes all of it.

## The installer (#73)

`.github/workflows/windows-setup.yml` builds it on every change here and keeps it as the run's artifact
`sebtype-setup`. It is Inno Setup 6.7.4 (`setup/sebtype.iss`, as SebChat's), in SebType's Picnic look: the
checkered cloth behind every page, the cream card with the pig, Jersey 10 and Nunito for English, and the
phone's icon at every Windows size. `setup/pictures.py` draws the pictures from `sebtype/make-icon.py` and
`pc/icons`. The run builds what the installer packs in parallel jobs: SebType's Weasel (`weasel.yml`), the
Chinese data (`tools/rime-data/build.sh`, on Fedora for librime 1.16.1), SebType's Mozc (`mozc/build.ps1`,
cached until its inputs change) and the Configurator (`configurator.yml`).

Setup speaks English, 中文 and 日本語: it follows Windows' display language, English otherwise, and its
first dialog lets the person pick. Its pages are the welcome, the languages (English, 中文 and 日本語, each
optional, and a desktop shortcut to the Configurator), the progress and the finish page, which shows the
tray keys and Win+Space. It installs into `C:\Program Files\SebType` and lists SebType in Apps.

```powershell
SebType-setup-0.1.0.exe                                        # a person: UAC, then the pages
SebType-setup-0.1.0.exe /VERYSILENT /TASKS="en,zh,ja"          # silent; /TASKS picks the languages
& "C:\Program Files\SebType\unins000.exe" /VERYSILENT          # silent uninstall
```

Installing needs admin: Windows' text services read their registration only from HKLM, so a per-user
Weasel or Mozc isn't offered as an input method (and Windows deletes a per-user one when the language list
changes; tried on YukaROG). Setup runs elevated, does the machine's part, then sets up the account of the
person who started it, not elevated (`setup/setup.ps1`):

```powershell
setup.ps1 -User -Save                                                                    # as the person, first
setup.ps1 -Machine -Languages en,zh,ja -Weasel <installer.exe> -Mozc <msi> -Log <file>   # elevated
setup.ps1 -User -Languages en,zh,ja                                                      # as the person
setup.ps1 -Machine -Undo; setup.ps1 -User -Undo                                          # uninstall
```

It runs in Windows PowerShell 5.1, which every Windows has; PowerShell 7's language list cmdlets fail on
some (seen on Server 2022). A step that fails says so with its log (`C:\Program Files\SebType\setup.log`,
`%LOCALAPPDATA%\SebType\setup.log`), and Setup exits with code 1; running it again usually fixes it.

**Languages.** A language ticked is set up; one left out that was set up before is removed as at
uninstall, with its learned words. So an upgrade can add or drop Chinese or Japanese. Setup remembers
the choice for the next upgrade.

**Upgrade.** Running a newer (or the same) Setup again reinstalls Weasel or Mozc only when its version
changed, replaces the Chinese data and keeps everything learned: Rime's `*.userdb`, `*.custom.yaml` and
`custom_phrase.txt`, and Mozc's user dictionary and history.

**Uninstall** removes Weasel, Mozc, SebType's folder and the Start menu entry, then puts the account back
as it was before the first install. The first install saves, before the engines' installers run
(`-User -Save`), to `%LOCALAPPDATA%\SebType\setup.json` and `backup\` the language list, the default input
method, the switch keys, the per-window setting, the input hotkeys and text service settings, and copies
of the Rime and Mozc folders if there were any. Uninstall
restores those and deletes what SebType learned on this PC (Decisions #2): Setup's message says so.

**Sync (#12)** isn't built. `setup.ps1` has one marked place, `SYNC HOOK (#12)`, just before a language's
learned words are deleted (uninstall or a language left out): there, once SebType has sync and it was
ever on, the account's words are saved to the server first.

### What it does, and why

| Step | Change | Why |
|---|---|---|
| SebType's Weasel | Machine: installs `sebtype-weasel-<version>-installer.exe` silently when it isn't already the installed one. It replaces any other Weasel | Upstream Weasel 0.17.4 with SebType's patch and icons, see below |
| SebType's Mozc | Machine: installs `SebType-Mozc-<version>.msi` when it isn't already the installed one, and enables its 日本語 profile by default for every user (`HKLM\SOFTWARE\Microsoft\CTF\TIP\<Mozc>\LanguageProfile\0x00000411\<profile>`, `Enable=1`) | See Japanese below. Mozc registers its profile without enabling it by default, so Windows turned it off for the user when the language list changed later (#65) |
| Chinese data | Unzips `rime-data.zip` into `%APPDATA%\Rime`, and removes dictionary sources (`*.dict.yaml`) the zip has prebuilt tables for. Its files are replaced; learned words, `*.custom.yaml` and an existing `custom_phrase.txt` stay. `sebtype-data.txt` there notes which data and Weasel it deployed | The zip the phone bundles (`tools/rime-data/build.sh`): rime-ice's schemas and Lua with 白霜's dictionary, compiled with librime 1.16.1, Weasel's too. librime uses its prebuilt tables as they are when their sources are missing, so Weasel never compiles the dictionary. Weasel's librime has librime-lua built in |
| Chinese name | `schema/name: 中文` in `rime_ice.custom.yaml`, keeping the file's other patches | Rime's schema menu (F4, Ctrl+\`) and Weasel's status read 中文, not 雾凇拼音 (#69). Weasel shows the whole name, so no `.` prefix as on Linux. The schema id stays `rime_ice`, so learned words stay |
| Typo correction | `sebtype_typo/keyboard: pc` in `rime_ice.custom.yaml` | Chinese typo correction (#46) weighs a PC keyboard's neighbour keys instead of the phone's touch grid |
| 简/繁 | Ctrl+Shift+F toggles rime-ice's `traditionalization` option, in `default.custom.yaml` (both `f` and `F`, as Shift may send either) | Decisions #2 (#36). Only the output changes; Ctrl+F stays Find |
| Japanese keys | SebType's keymap (`pc/linux/mozc-keymap.tsv`) into Mozc's settings, `%USERPROFILE%\AppData\LocalLow\Mozc\config1.db`, its other settings kept | A Shift tap toggles あ ⇄ English, and Alt+\` あ ⇄ ア, as on Linux (#117) |
| Input methods | Language list: the chosen ones first, EN (US layout first) → 中文 (Weasel only) → 日本語 (Mozc only), then the account's other languages. Other Chinese and Japanese IMEs are taken off those two languages, not uninstalled | Win+Space cycles the list in this order. One input method per language, so Win+Space is the only switch |
| Switch keys | `HKCU\Keyboard Layout\Toggle`: Hotkey, Language Hotkey and Layout Hotkey = 3 (none), applied at once | Alt+Shift and Ctrl+Shift no longer switch language |
| Per-window input | "Let me use a different input method for each app window" off | One language for every window, as on Linux |
| Redeploy | Stops WeaselServer and runs `WeaselDeployer.exe /deploy` when the Chinese data or patches changed | Weasel builds the data once. WeaselServer isn't started by Setup, which would run it elevated, where apps can't reach it: Weasel's text service starts it at the first key, at the app's level |

Inside Chinese, a Shift tap types English (rime-ice's `Shift_L: commit_code`) and Shift again goes back,
as on Linux. Caps Lock in Chinese switches to English capitals (rime-ice's `good_old_caps_lock`).

Everything Rime learns stays in `%APPDATA%\Rime`, so sync (#12) can add a `sync_dir` to `installation.yaml` there.

### SebType's Weasel

`weasel/build.ps1` builds upstream Weasel 0.17.4 with `weasel/sebtype.patch` and librime 1.16.1, the version
SebType's Android build uses. `.github/workflows/weasel.yml` runs it on GitHub's Windows runner whenever
something under `pc/windows/weasel/` or `pc/icons/` changes; the installer is that run's artifact
`sebtype-weasel`. Locally it needs Visual Studio 2022 with C++ and ATL, git, 7-Zip, NSIS and Git's bash.

The patch is about 90 lines:

- The input method is named **中文**, so Windows' Win+Space switcher shows 中文(简体，中国) / 中文 rather
  than 小狼毫 (#69).
- English mode shows **A** instead of **a** while Caps Lock is on, and the icon redraws when Caps Lock
  changes (Decisions #2, "Everywhere").
- The menu of the tray icon (right-click) is Chinese's one switch with its key, `简 → 繁 Ctrl+Shift+F`
  (`繁 → 简` while traditional), as on Linux (#117), instead of Weasel's settings, dictionary manager,
  sync, folders, help, deploy, restart and exit. Rime's state reaches the text service as a new
  `status.traditional`, and the click sets `traditionalization` through WeaselServer. Rime's switcher
  (Ctrl+\`) has the same one switch: SebType's Chinese data keeps `states` only on traditionalization.
- The installer marks the build (`SebType` in Weasel's uninstall entry, which `setup.ps1` checks) and
  never turns on Weasel's update check, which would replace SebType's build with upstream's.

Its icons are SebType's Set E keycaps (`pc/icons`), made into `.ico` files by `weasel/make-icons.py`
with each size's own drawing (16, 20, 24, 32 px; 40–64 px from the 48 px one):

| Weasel state | Icon | Weasel resource |
|---|---|---|
| Chinese | 中 | `zh.ico` |
| Chinese, English mode | a | `en.ico` |
| Chinese, English mode with Caps Lock | A | `en_caps.ico` (new) |

Windows shows them in the taskbar's input indicator, where Weasel's language bar button sits, and Weasel
shows them in its status tip. Windows draws the indicator for the US layout itself (ENG), so plain English
can't show SebType's EN key there.

What Windows itself shows and SebType can't change (#117): the input indicator's left-click list of
input methods (with "More keyboard settings"), Windows' own items in the Win+Space switcher, and, in the
optional floating language bar, Windows' own buttons (Help, Options, Restore). The engines' items are
gone from all of them.

### Test

```sh
pc/windows/setup/test-tcsbackend.sh   # from nobara-pc; this commit's sebtype-setup artifact, or build/SebType-setup-*.exe
```

Like Mozc's test (below), it runs on TCSBackEnd under its device lock, in the background, and puts
TCSBackEnd back as it found it. `setup/test.ps1` creates a local admin, `sebtype-test` (the person
installing SebType is an admin), whose Remote Desktop session nobara-pc opens in a headless gamescope; a
logon task there runs Setup elevated, as UAC would, and drives its pages through their window messages.
The typing runs in a second task, not elevated, as apps run. The keys are real (`mozc/rdp-keys.py`).

| Check | What passes |
|---|---|
| `language-follows-windows` | Setup's language dialog offers Windows' display language (简体中文 on TCSBackEnd) |
| `welcome-zh`, `welcome-ja`, `round1-install-pages` | Each page shows and is saved as a picture (`/tmp/sebtype/73-*.png`): welcome in all three languages, languages, installing, finish |
| `round1-installed`, `-input-methods`, `-only-win-space`, `-chinese`, `-japanese` | The interactive install with all three: SebType in Apps with its icon, Weasel and Mozc, the list EN → 中 → 日 (the account's Chinese Microsoft Pinyin gone from it), Alt+Shift and Ctrl+Shift off, 中文 and 日本語 named so, the Chinese data deployed with its patches, Mozc's keymap |
| `win-space-cycle`, `chinese-pinyin`, `chinese-shift-tap`, `chinese-ctrl-shift-f`, `japanese-all` | In Notepad: Win+Space gives 中, 日, EN; `ranhou` → 然后; `ni` Shift `ok` Shift `ranhou` → `niok然后`; Ctrl+Shift+F `houlai` → 後來 and back → 后来; `nihongo` → 日本語 |
| `japanese-alt-grave` | In Notepad, in 日本語: Alt+\` types ア, again あ; after a Shift tap to English, Alt+\` still types `a`, and a Shift tap is あ again |
| `chinese-tray-menu` | In a TSF text field of the test's own: the tray icon's menu is the one item `简 → 繁 Ctrl+Shift+F`; picking it makes `houlai` → 後來, and the menu then reads `繁 → 简 Ctrl+Shift+F` and goes back (`/tmp/sebtype/117-menu-zh-*.png`) |
| `round1-upgrade`, `-upgrade-keeps-learned-words` | A silent rerun exits 0 and keeps the Rime and Mozc learned-word folders |
| `japanese-after-language-change` | After a language is added and removed, Japanese still types |
| `round1-uninstall-pages`, `-uninstall-deletes-learned-words`, `round1-everything-as-before` | The uninstaller's confirm, progress and done; the account's input methods, switch keys, per-window setting, hotkeys and folders as before; Weasel, Mozc and SebType gone |
| `round2-*` | Silent: install with 中文 and 日本語 only (English after them), upgrade to English and 中文 (Mozc and its words go), uninstall; as before |
| `machine-as-before`, `admin-input-as-before`, `tcsbackend-as-found` | No SebType, Weasel or Mozc registration left; the Administrator's input methods and TCSBackEnd's users, sessions and game backend as found |

Rime's speed (`perf-rime.ps1`, `rime-p95-under-10ms`) needs PowerShell 7, which TCSBackEnd lacks; it runs
on a PC with SebType installed.

## Japanese: SebType's Mozc (#65)

Windows Japanese is open-source [Mozc](https://github.com/google/mozc), built by SebType, instead of
Google 日本語入力, whose tray icons are fixed in its signed program (#63). It is the same engine as on
Linux and the phone, with SebType's changes:

- **Tray icons:** the Set E keycaps from `pc/icons`: あ (hiragana), ア (katakana, full and half
  width), **a** in English (direct input, half and full width alphanumeric) and **A** in English while
  Caps Lock is on (Decisions #2, "Everywhere").
- **Keys:** a Shift tap toggles あ ⇄ English, as Shift does in Chinese, and Alt+\` あ ⇄ ア before typing
  (#117); Win+Space is the only language switch and cycles EN → 中 → 日. The keymap is Linux's,
  `pc/linux/mozc-keymap.tsv`; `menu.patch` makes Mozc's kana switch a two-way あ ⇄ ア, without the
  half-width katakana step, and lets the keymap see Alt+\` (upstream's text service passes it on as the
  Kanji key, so it always turned English on and off).
- **Menu:** the tray icon's menu (right-click) is Japanese's one switch with its key, ``あ → ア Alt+` ``
  (`ア → あ` in katakana), as on Linux (#117), instead of Mozc's six input modes, dictionary tool, word
  registration, properties, about and help. The floating language bar loses Mozc's Tool button and
  Help items too (`menu.patch`).

### Build

```powershell
pwsh pc/windows/mozc/build.ps1 -WorkDir D:\sebtype-mozc   # -> D:\sebtype-mozc\out\SebType-Mozc-<version>-sebtype<n>.msi
```

It builds on Windows, because Mozc's Windows build needs MSVC's headers and libraries, ATL and the
Windows SDK, which don't cross-build from Linux. The build machine needs Visual Studio 2022 or its Build
Tools (C++ x64 tools, ATL, a Windows 11 SDK), Python 3.12+ and a .NET 8+ SDK; the preflight says which is
missing and prints the `winget` line to install it (as admin). Everything else is fetched and pinned:
`mozc/versions.psd1` pins Mozc's release tag with the checksum of its source, Bazelisk, resvg (the
SVG renderer for the icons) and a portable CMake (for Qt; the Build Tools lack it). Mozc's
`update_deps.py` pins LLVM, MSYS2, Ninja, Qt and WiX. The build itself needs no admin rights and no
Developer Mode (Bazel runs without symlinks).

The script unpacks Mozc's source over the kept tree in `-WorkDir`, applies SebType's patches with
`apply_patch.py` (exact match, no fuzz; YukaROG has no git), writes the icons with `make_icons.py`,
builds Qt once, then Mozc's installer with Bazel (8 jobs). A rebuild compiles only what changed. On
YukaROG the first build took about 40 minutes (update_deps 4, Qt 14, Bazel 22) and 9 GB, after about
40 minutes for the Build Tools install.

`pc/icons` has states whose names differ only by case (`ja-a`, `ja-A`), so on Windows the folder must
be case-sensitive before the repo's files go in (`fsutil file setCaseSensitiveInfo <dir> enable` for
each size folder, no admin needed), or the English icons all come out as **A** (#77).

| Patch | Change |
|---|---|
| `caps-lock-icon.patch` | The English modes' tray icon shows **A** while Caps Lock is on, and the tray redraws when Caps Lock toggles (`win32/tip`, about 35 lines) |
| `shift-tap.patch` | A Shift tap in English turns あ back on. Mozc's text service passes only key presses to the server in English, so the keymap's `DirectInput Shift IMEOn` never ran; now a bare Shift's release goes, as it does in あ, and its press doesn't (`win32/base/keyevent_handler.cc`, 6 lines). Without it the Shift tap in Notepad and in the test's field both fail (#65) |
| `japanese-name.patch` | Japanese reads **日本語** in Win+Space and the language settings, not "Mozc" (Decisions #2, #92), as Chinese reads 中文 (`win32/tip/tip_resource.rc`, `win32/base/tsf_registrar.cc`) |

`make_icons.py` replaces Mozc's mode icons with `.ico` files holding a PNG for each tray size from
100 % to 400 % scaling: pc/icons' hand-drawn 16, 20, 24 and 32 px drawings, and the 48 px drawing for
40, 48 and 64 px.

### Install

SebType's installer installs the MSI for the machine and sets each person's keymap and language list
(`setup.ps1`, above). `mozc/test.ps1` sets up its test user with `setup.ps1 -User` too.

Google 日本語入力, if installed, stays installed; SebType takes it off Japanese's input methods, and
uninstalling SebType puts it back.

### Test

```sh
pc/windows/mozc/test-tcsbackend.sh   # from nobara-pc; the newest MSI from build/ or ~/Downloads/xfer
```

The typing needs a Windows Server, which allows a second Remote Desktop session, so the script runs
`test.ps1` on TCSBackEnd under its device lock and puts TCSBackEnd back as it found it. It copies the
repo, the MSI and an embeddable Python there, starts `test.ps1` elevated, in the background, and logs
the test user on over Remote Desktop from nobara-pc (FreeRDP in a headless gamescope, through an SSH
tunnel), so nothing shows on any screen and no key on any real keyboard is read or sent. `test.ps1` checks
Mozc's key and conversion times through its own server (`pc/linux/perf-mozc.py`; Decisions #2:
p95 ≤ 5 ms) and the dictionary (below), installs the MSI for the machine, then runs the typing checks as
a local standard user it creates for the run (`sebtype-test`):

- `setup.ps1 -User -Languages en,ja` for that user: Japanese after English, Chinese where it was;
- the name Windows shows for Japanese, 日本語;
- typing in Notepad: Win+Space to 日本語, `nihongo` → 日本語, and the Shift tap there and back;
- typing in its own text field: `nihongo` → 日本語, the tray menu's one item ``あ → ア Alt+` `` and back
  (a picture of each, `menu-ja-*.png`), Alt+\` for あ ⇄ ア and nothing in English, the Shift tap for
  English, Shift+letter staying Japanese in あ and English in English, and the tray icon in each mode
  and with Caps Lock;
- `setup.ps1 -User -Undo` for that user.

After that it removes the user, its profile and Mozc. Last, it checks that your own language list,
default input method, hotkeys, text service settings and Caps Lock are as they were, and that no test
user or profile is left. One line per check goes to `%LOCALAPPDATA%\SebType\test\mozc-results.txt`.

The keys are real input: `mozc/rdp-keys.py` presses them through XTEST in the gamescope display that
FreeRDP runs in, FreeRDP sends their scancodes to the test user's session like any keyboard, and the
typing checks ask for them through a reverse SSH tunnel. So they reach Mozc the way a person's keys do,
through the session's input queue, the window's message loop and TSF's keystroke manager. Feeding keys
to TSF directly (`ITfKeystrokeMgr` with a faked key state, the first version of this test) made the
Shift tap fail where real keys work. The window in front gets the keys: first Notepad, read back
through its edit control, then a text field of the test's own (`mozc/TsfHost.cs`), whose text store
shows what Mozc composed and committed and whose language bar item shows Mozc's tray icon. Both run in
the test user's own Remote Desktop session, started by a logon task: a process started as another user
inside someone else's session fails to start (0xC0000142). Running it as a separate user keeps the
input settings of the person at the PC untouched. After the run the script logs the test user off,
waits for its profile to unload, then removes the profile and the user.

Windows deleted Mozc's per-user profile key when the language list changed later (for example when
a language is added in Settings), which left Japanese without a working input method (seen on
TCSBackEnd). The installer enables the profile by default for the machine; the installer's test checks
Japanese still types after such a change.

### Dictionary

`mozc/dict-words.tsv` holds 104 common words and phrases (everyday words, place and family names,
verbs and adjectives, loanwords, recent words, a classic homophone sentence) with the conversion
they should give. The test types each and counts how often Mozc's first candidate is that one.

On YukaROG (Mozc 3.35.6354, 2026-11-10): key p50/p95/max 0.39/1.38/3.34 ms, Space 0.42/0.73/2.25 ms,
server start 124 ms, 31 MB RAM; top-1 97/104. The misses are reasonable first guesses that need one
more Space: kodomo → 子ども (子供), kinou → 機能 (昨日), satou → 砂糖 (佐藤), suzuki → スズキ (鈴木),
yamada → ヤマダ (山田), takahashi → 高梁 (高橋), and the homophone sentence
(記者の記者が記者で帰社した for 貴社の記者が汽車で帰社した). Linux's fcitx5-mozc 2.30 got 100/104 with
the same list (it missed kinou, satou, suzuki and the sentence). Google 日本語入力 wasn't compared:
the test commits each word, which would teach it to the user's own Google 日本語入力 profile.
