# SebType on Windows

On Windows, SebType's Chinese is Weasel (小狼毫) with the phone's Chinese data: rime-ice's schema and Lua
with 白霜's dictionary. English is Windows' plain US layout. Japanese is SebType's own
Mozc, set up by `mozc/install.ps1` (see Japanese below). `setup-ime.ps1` sets it up for this account with nothing done by
hand. `pc/windows/stage.sh` (on Linux) gathers what it needs into one folder.

```sh
pc/windows/stage.sh                      # on Linux: build/sebtype-windows/ and build/sebtype-windows.tar
xfer push yukarog build/sebtype-windows.tar
```

```powershell
xfer pull <id>; tar -xf <path>.tar; cd sebtype-windows
.\setup-ime.ps1 -DryRun                  # print what would change, change nothing
.\setup-ime.ps1                          # apply; asks for admin (UAC) only to install Weasel; safe to rerun
.\setup-ime.ps1 -Undo                    # put everything back; asks for admin to remove Weasel
```

`-NoAdmin` prints the admin command instead of asking for UAC. `-Weasel` and `-RimeData` take other paths
for the installer and the Chinese data (the installer, #73, can pass its own).

Installing Weasel needs admin: Windows' text services read their registration only from HKLM, so a
per-user Weasel isn't offered as an input method. Everything else is per user. The script runs in
Windows PowerShell 5.1 (started from PowerShell 7 it reruns itself there), whose language list cmdlets
PowerShell 7 can't load on every Windows.

The first run saves what it changes to `%LOCALAPPDATA%\SebType\windows-setup.json`: the input method list,
the switch keys, the per-window setting, whether Weasel was installed, and a copy of the Rime folder
`%APPDATA%\Rime` in `%LOCALAPPDATA%\SebType\backup\<time>\`. `-Undo` puts all of these back. It moves the
Rime folder it replaces to the backup too, so learned words are never deleted, and it removes SebType's
Weasel only if no Weasel was there before.

## What it does, and why

| Step | Change | Why |
|---|---|---|
| SebType's Weasel | Installs `sebtype-weasel-<version>-installer.exe` silently, as admin (UAC), when it isn't already the installed one. It replaces any other Weasel | Upstream Weasel 0.17.4 with SebType's patch and icons, see below |
| Chinese data | Unzips `rime-data.zip` into `%APPDATA%\Rime`, and removes dictionary sources (`*.dict.yaml`) the zip has prebuilt tables for. Its files are replaced; learned words, `*.custom.yaml` and an existing `custom_phrase.txt` stay. `sebtype-data.txt` there notes which data and Weasel it deployed | The zip the phone bundles (`tools/rime-data/build.sh`): rime-ice's schemas and Lua with 白霜's dictionary, compiled with librime 1.16.1, Weasel's too. librime uses its prebuilt tables as they are when their sources are missing, so Weasel never compiles the dictionary. Weasel's librime has librime-lua built in |
| Chinese name | `schema/name: 中文` in `rime_ice.custom.yaml`, keeping the file's other patches | Rime's schema menu (F4, Ctrl+`) and Weasel's status read 中文, not 雾凇拼音 (#69). Weasel shows the whole name, so no `.` prefix as on Linux. The schema id stays `rime_ice`, so learned words stay |
| Typo correction | `sebtype_typo/keyboard: pc` in `rime_ice.custom.yaml` | Chinese typo correction (#46) weighs a PC keyboard's neighbour keys instead of the phone's touch grid |
| 简/繁 | Ctrl+Shift+F toggles rime-ice's `traditionalization` option, in `default.custom.yaml` (both `f` and `F`, as Shift may send either) | Decisions #2 (#36). Only the output changes; Ctrl+F stays Find |
| Input methods | Language list EN (US layout first) → 中文 (Weasel only) → 日本語 (as it was) → any others. Other Chinese IMEs are taken off the list, not uninstalled | Win+Space cycles the list in this order. One input method per language, so Win+Space is the only switch |
| Switch keys | `HKCU\Keyboard Layout\Toggle`: Hotkey, Language Hotkey and Layout Hotkey = 3 (none), applied at once | Alt+Shift and Ctrl+Shift no longer switch language |
| Per-window input | "Let me use a different input method for each app window" off | One language for every window, as on Linux |
| Redeploy | Restarts WeaselServer as this user and runs `WeaselDeployer.exe /deploy` when anything above changed | Weasel builds the data once; its installer starts WeaselServer as admin |

Inside Chinese, a Shift tap types English (rime-ice's `Shift_L: commit_code`) and Shift again goes back,
as on Linux. Caps Lock in Chinese switches to English capitals (rime-ice's `good_old_caps_lock`).

Sync (#12) isn't set up yet. The layout is ready for it: everything Rime learns stays in `%APPDATA%\Rime`, and
#12 adds a `sync_dir` to `installation.yaml` there.

### SebType's Weasel

`weasel/build.ps1` builds upstream Weasel 0.17.4 with `weasel/sebtype.patch` and librime 1.16.1, the version
SebType's Android build uses. `.github/workflows/weasel.yml` runs it on GitHub's Windows runner whenever
something under `pc/windows/weasel/` or `pc/icons/` changes; the installer is that run's artifact
`sebtype-weasel`. Locally it needs Visual Studio 2022 with C++ and ATL, git, 7-Zip, NSIS and Git's bash.

The patch is about 20 lines:

- The input method is named **中文**, so Windows' Win+Space switcher shows 中文(简体，中国) / 中文 rather
  than 小狼毫 (#69).
- English mode shows **A** instead of **a** while Caps Lock is on, and the icon redraws when Caps Lock
  changes (Decisions #2, "Everywhere").
- The installer marks the build (`SebType` in Weasel's uninstall entry, which `setup-ime.ps1` checks) and
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

## Test

`test-setup-ime.ps1`, in the staged folder on the PC, is run three times with the admin step it prints
between runs: before setup, after SebType's Weasel is installed, and after it is removed. It checks the
settings, types in a text window of its own (keys go only to that window, checked before each key), and
measures Rime with `perf-rime.exe` (`pc/linux/perf-rime.c`, built 32-bit with Weasel as its rime.dll is) on a copy of the Rime folder.
Results go to `results.txt` next to it.

| Check | What passes |
|---|---|
| `pinyin-commit` | `ranhou` shows Weasel's candidate window, Space commits 然后 |
| `shift-tap-english` | `ni` Shift `ok` Shift `ranhou` Space gives `niok然后` |
| `ctrl-shift-f-traditional` | Ctrl+Shift+F, `houlai` Space → 後來, Ctrl+Shift+F, `houlai` Space → 后来 |
| `caps-lock-icon` | Weasel's icon goes 中 → a (Shift) → A (Caps Lock), and `ab` types `AB` |
| `win-space-cycle` | From EN, Win+Space gives 中, 日, EN |
| `label-zhongwen` | Weasel's Windows profile is named 中文 |
| `rime-p95-under-10ms` | Key → candidates p95 ≤ 10 ms (Decisions #2) |
| `undo-*` | Input methods, switch keys, per-window setting and the Rime folder are as before setup; Weasel is gone |

Caps Lock and the input method are put back as the test found them.

The checks reach Chinese by asking Windows for it directly, so only `win-space-cycle` sends Win+Space.
Windows Server 2022 (TCSBackEnd) ignores synthetic Win+Space in some runs; a desktop PC is where that check counts.

## Japanese: SebType's Mozc (#65)

Windows Japanese is open-source [Mozc](https://github.com/google/mozc), built by SebType, instead of
Google 日本語入力, whose tray icons are fixed in its signed program (#63). It is the same engine as on
Linux and the phone, with SebType's changes:

- **Tray icons:** the Set E keycaps from `pc/icons`: あ (hiragana), ア (katakana, full and half
  width), **a** in English (direct input, half and full width alphanumeric) and **A** in English while
  Caps Lock is on (Decisions #2, "Everywhere").
- **Keys:** a Shift tap and Alt+` toggle あ ⇄ English, as Shift does in Chinese; Win+Space is the only
  language switch and cycles EN → 中 → 日. The keymap is Linux's, `pc/linux/mozc-keymap.tsv`.

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

```powershell
powershell -File pc/windows/mozc/install.ps1 D:\sebtype-mozc\out\SebType-Mozc-....msi   # elevated: install or update
powershell -File pc/windows/mozc/install.ps1                                     # no admin: set up this user too
powershell -File pc/windows/mozc/install.ps1 -Undo                               # remove, put back what was there
```

With the MSI, `install.ps1` runs elevated (admin): it installs the MSI for the whole machine, then,
for the user running it, writes the keymap into Mozc's settings (`%USERPROFILE%\AppData\LocalLow\Mozc\config1.db`,
other settings kept) and makes Mozc Japanese's only input method, after Chinese in the language list.
Before the first install it saves the language list, the default input method, the input hotkeys, the
user's text service settings and Mozc's settings; `-Undo` puts them back and uninstalls Mozc (elevated).
Without the MSI it sets up only the user running it, with no admin, once Mozc is installed; its
`-Undo` keeps Mozc. Apps
opened before an install pick up the keymap once restarted. SebType's installer (#73) will pack it.

A no-admin install of Mozc itself doesn't work: Windows deletes a text service registered only for the user (under
HKEY_CURRENT_USER) as soon as the language list changes, and leaves Japanese with no input method
(tried on YukaROG). Changing the language list also drops other input methods' per-user settings,
which is why `install.ps1` saves and restores them.

Google 日本語入力, if installed, is left alone: both can be installed, and the language list decides
which one Japanese uses.

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

- `install.ps1` for that user, with the language order EN → 中 → 日 that Win+Space cycles through;
- the name Windows shows for Japanese, 日本語;
- typing in Notepad: Win+Space to 日本語, `nihongo` → 日本語, and the Shift tap there and back;
- typing in its own text field: `nihongo` → 日本語, あ ⇄ ア (from the tray menu: a US keyboard has no
  katakana key), Shift tap and Alt+` for English, Shift+letter staying Japanese in あ and English in
  English, and the tray icon in each mode and with Caps Lock;
- `install.ps1 -Undo` for that user.

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

Windows deletes Mozc's per-user profile key when the language list changes later (for example when
a language is added in Settings), which leaves Japanese without a working input method (seen on
TCSBackEnd); rerunning `install.ps1` sets the key again (not yet tested). SebType's installer (#73)
should handle this.

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
