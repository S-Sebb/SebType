# SebType on Windows

On Windows, SebType is one text service with two input methods, 中文 and 日本語, over SebType's core
([`windows/`](../../windows), #190): Chinese is Rime with the phone's Chinese data (rime-ice's schema and
Lua with 白霜's dictionary), Japanese is SebType's Mozc (see Japanese below). English is Windows' plain US
layout. One installer, `SebType-setup-<version>.exe`, installs, upgrades and removes all of it.

## The installer (#73)

`.github/workflows/windows-setup.yml` builds it on every change here and keeps it as the run's artifact
`sebtype-setup`. It is Inno Setup 6.7.4 (`setup/sebtype.iss`, as SebChat's), in SebType's Picnic look: the
checkered cloth behind every page, the cream card with the pig, Jersey 10 and Nunito for English, and the
phone's icon at every Windows size. `setup/pictures.py` draws the pictures from `art/make-icon.py` and
`pc/icons`. The run builds what the installer packs in parallel jobs: SebType's librime (`rime/build.ps1`), the text
service and its server (`windows/build.ps1`), the Chinese data (`data/rime/build.sh`, on Fedora for librime
1.16.1), Mozc (`mozc/build.ps1`, cached until its inputs change) and the Configurator
(`configurator.yml`).

Setup speaks English, 中文 and 日本語: it follows Windows' display language, English otherwise, and its
first dialog lets the person pick. Its pages are the welcome, the languages (English, 中文 and 日本語, each
optional, and a desktop shortcut to the Configurator) and the progress. Once the files are copied, Setup
closes and the installed Configurator shows the rest in the setup wizard Linux uses
(`--setup-after-install`): Common settings (简/繁, the theme, layout and page size; Picnic for a new
account), Account sync and the tray keys. A silent install shows none of it: a new account gets the
defaults, an update keeps its settings, and `/COMMON="picnic=0 vertical=0 page-size=8 traditional=1"` sets any of them. It
installs into `C:\Program Files\SebType` and lists SebType in Apps.

```powershell
SebType-setup-0.1.0.exe                                        # a person: UAC, then the pages
SebType-setup-0.1.0.exe /VERYSILENT /TASKS="en,zh,ja"          # silent; /TASKS picks the languages
& "C:\Program Files\SebType\unins000.exe" /VERYSILENT          # silent uninstall
```

Installing needs admin: Windows' text services read their registration only from HKLM, so a per-user
text service isn't offered as an input method (and Windows deletes a per-user one when the language list
changes; tried on YukaROG). Setup runs elevated, does the machine's part, then sets up the account of the
person who started it, not elevated (`setup/setup.ps1`):

```powershell
setup.ps1 -User -Save                                  # as the person, first
setup.ps1 -Machine -Languages en,zh,ja -Log <file>     # elevated
setup.ps1 -User -Languages en,zh,ja                    # as the person
setup.ps1 -Machine -Undo; setup.ps1 -User -Undo        # uninstall
```

It runs in Windows PowerShell 5.1, which every Windows has; PowerShell 7's language list cmdlets fail on
some (seen on Server 2022). A step that fails says so with its log (`C:\Program Files\SebType\setup.log`,
`%LOCALAPPDATA%\SebType\setup.log`), and Setup exits with code 1; running it again usually fixes it.

**Languages.** A language ticked is set up; one left out that was set up before is removed as at
uninstall, with its learned words. So an upgrade can add or drop Chinese or Japanese. Setup remembers
the choice for the next upgrade.

**Upgrade.** Running a newer (or the same) Setup again replaces the program files, the text service and
the Chinese data, and keeps everything learned: Rime's `*.userdb`, `*.custom.yaml` and
`custom_phrase.txt`, and Mozc's user dictionary and history. Apps that have the text service loaded keep
the old DLL until they close: Setup moves it aside (`sebtype.dll.<n>.old`, deleted at the next restart)
and never asks to close apps. Over a SebType from before #190, Setup uninstalls its Weasel and Mozc;
their learned words are in the same folders and stay. The candidate window starts in its default look
there; the Configurator sets it again.

**Uninstall** removes the text service, SebType's folder and the Start menu entry, then puts the account back
as it was before the first install. The first install saves, before the engines' installers run
(`-User -Save`), to `%LOCALAPPDATA%\SebType\setup.json` and `backup\` the language list, the default input
method, the switch keys, the per-window setting, the input hotkeys and text service settings, and copies
of the Rime and Mozc folders if there were any. Uninstall
restores those and deletes what SebType learned on this PC (Decisions #2): Setup's message says so.

**Sync (#180)** is the Configurator's (Sync & backup, [sync-server/README.md](../../sync-server/README.md)).
Setup packs Python's embeddable package into `{app}\python` for it, since Windows has no Python: the
setup CI fetches it with `python.ps1`, which checks its SHA-256, and caches it. Just before a language's learned words are deleted
(uninstall or a language left out), `setup.ps1` runs `sebtype-configurator.exe --sync-before-removal`:
if sync was ever on since the last delete on the server, the account's words go to the server first.
It never deletes anything on the server. If that sync fails (offline, a wrong password), the
Configurator exits 1 and Setup keeps the language's folder in `%LOCALAPPDATA%\SebType\unsynced\`
instead of deleting it, and says so (#271); setting up that language again moves it back, and the next
sync sends its words. When sync was never on, the words are deleted as before. `-User -Undo` then removes sync's scheduled task, its login in
Credential Manager and its files in `%LOCALAPPDATA%\SebType`.

**Updates (#422).** `setup.ps1 -User` schedules the task "SebType update check": `sebtype-configurator.exe
--check-updates` once a day at noon, as the person while they are logged on, and at the next chance after a
missed day. It asks GitHub for SebType's latest release (`releases/latest`; tags `v<MAJOR.MINOR.PATCH>`
only, so the `v0.1.30-sebtype.N` tags from before 0.1.0 are never newer) and compares it with the
Configurator's version (`VERSION`). A newer release shows a toast once, under the Start menu shortcut's
AppUserModelID `SebType.Configurator`; clicking it opens `sebtype-configurator:update`, which Setup
registers to open the Configurator's About page. There, Update… downloads `SebType-setup-<version>.exe` from
the release's download address into a new folder in `%LOCALAPPDATA%\SebType\updates` and checks its size
and SHA-256 against GitHub's (the asset's `digest`; none, no install). The update's own side
(`update-user.ps1`, as the person, not elevated) then does Setup's steps for the person first (their server
saves the learned words and quits; `setup.ps1 -User -Save`), and one UAC prompt elevates the admin side
(`start-setup.ps1`). Setup installs both next to the Configurator in Program Files, where only admins can
write, and they run from there with `-File`, the download and its SHA-256 as arguments. That copies the setup into a new folder in `%ProgramFiles%\SebType\updates`, where only
admins can write, checks the copy's SHA-256 there and runs that copy as an upgrade (`/SILENT
/SUPPRESSMSGBOXES /NORESTART`, the languages chosen before) with `/NOUSERSTEPS`: only the machine's part, so
an administrator who approves UAC for someone else gets none of that person's steps. A download changed after
the check never runs; the next update and the uninstall remove the copies, and the own side removes the
download once Setup has finished. The Configurator closes once UAC
is approved, so Setup can replace it. After Setup, the own side runs `setup.ps1 -User` with the languages
Setup keeps, as the person, and opens the About page again, with what failed if anything did. The test build `sebtype-configurator-update-test` (CI's artifact of that name) is the only one that
takes `SEBTYPE_UPDATE_URL`, a release on 127.0.0.1 (`test-update.ps1`). About's "Check for updates automatically" turns the daily
check off, Check now checks at once. `-User -Undo` removes the task, `update.json` and the downloads.

### What it does, and why

| Step | Change | Why |
|---|---|---|
| Text service | Machine: Setup registers `sebtype.dll` (64-bit, and `x86\sebtype.dll` for 32-bit apps) with both profiles enabled by default (`HKLM\SOFTWARE\Microsoft\CTF\TIP\<SebType>\LanguageProfile\…`), and starts `sebtype-server.exe` at every logon (`HKLM\…\Run`). It removes the Weasel and Mozc SebType installed before #190 | See [`windows/`](../../windows). Profiles enabled by default stay on when the language list changes later (#65) |
| Chinese data | Unzips `rime-data.zip` into `%APPDATA%\Rime`, and removes dictionary sources (`*.dict.yaml`) the zip has prebuilt tables for. Its files are replaced; learned words, `*.custom.yaml` and an existing `custom_phrase.txt` stay. `sebtype-data.txt` there notes which data and librime it deployed | The zip the phone bundles (`data/rime/build.sh`): rime-ice's schemas and Lua with 白霜's dictionary, compiled with librime 1.16.1, SebType's too. librime uses its prebuilt tables as they are when their sources are missing, so it never compiles the dictionary. SebType's librime has librime-lua built in |
| Chinese name | `schema/name: 中文` in `rime_ice.custom.yaml`, keeping the file's other patches | Rime's status reads 中文, not 雾凇拼音 (#69). The schema id stays `rime_ice`, so learned words stay |
| Typo correction | `sebtype_typo/keyboard: pc` in `rime_ice.custom.yaml` | Chinese typo correction (#46) weighs a PC keyboard's neighbour keys instead of the phone's touch grid |
| 简/繁 | Ctrl+Shift+F toggles rime-ice's `traditionalization` option, in `default.custom.yaml` (both `f` and `F`, as Shift may send either) | Decisions #2 (#36). Only the output changes; Ctrl+F stays Find |
| Candidates per page | `menu/page_size: 6` in `default.custom.yaml`, only when it has no page size yet | 6 Chinese candidates per page instead of rime-ice's 5 (Decisions #2, #163). A page size of the user's own, which the Configurator writes there too, stays |
| Japanese keys | SebType's keymap (`pc/linux/mozc-keymap.tsv`) into Mozc's settings, `%USERPROFILE%\AppData\LocalLow\Mozc\config1.db`, its other settings kept; then `sebtype-server.exe /mozc` restarts Mozc, as it reads the keymap only when it starts | The same keymap as on Linux; the core handles the Shift tap (あ ⇄ English) and Alt+\` (あ ⇄ ア) itself (#117) |
| Input methods | Language list: the chosen ones first, EN (US layout first) → 中文 (SebType's only) → 日本語 (SebType's only), then the account's other languages. Other Chinese and Japanese IMEs are taken off those two languages, not uninstalled | Win+Space cycles the list in this order. One input method per language, so Win+Space is the only switch |
| Switch keys | `HKCU\Keyboard Layout\Toggle`: Hotkey, Language Hotkey and Layout Hotkey = 3 (none), applied at once | Alt+Shift and Ctrl+Shift no longer switch language |
| Per-window input | "Let me use a different input method for each app window" off | One language for every window, as on Linux |
| Redeploy | Runs `sebtype-server.exe /deploy` as the person when the Chinese data or patches changed; it returns when Rime is done | Rime builds the data once. With no server running, `/deploy` runs Rime itself and starts none: one started from an elevated Setup would be out of the apps' reach. The text service starts the server at the first key |

Inside Chinese, a Shift tap types English and Shift again goes back, as on Linux (SebType's core). Caps Lock in Chinese switches to English capitals (rime-ice's `good_old_caps_lock`).

Everything Rime learns stays in `%APPDATA%\Rime`, so sync (#12) can add a `sync_dir` to `installation.yaml` there.

### The text service

[`windows/`](../../windows) has the text service and its server, and how they are built. `rime/build.ps1`
builds SebType's librime (`engines/librime`, 1.16.1, with librime-lua and -octagram at the
commits librime's own release merges in) with librime's own `build.bat`, Rime's shared data (plum's
preset) and `perf-rime.exe`; its `sebtype-rime` artifact is what the text service's server links. With
SebType's librime, Chinese typo correction also fixes a slip onto the key above or below, so `xkaoshi`
gives 小时 first (#101, #133).

What Windows itself shows and SebType can't change (#117): the input indicator's left-click list of
input methods (with "More keyboard settings"), Windows' own items in the Win+Space switcher, and, in the
optional floating language bar, Windows' own buttons (Help, Options, Restore).

### Test

```sh
pc/windows/setup/test-tcsbackend.sh   # from nobara-pc; this commit's sebtype-setup artifact, or build/SebType-setup-*.exe
ONLY=upgrade pc/windows/setup/test-tcsbackend.sh   # the update from the SebType before #190
ONLY=forget pc/windows/setup/test-tcsbackend.sh    # forgetting learned words while the server runs (#375)
```

It runs on TCSBackEnd under its device lock, in the background, and puts TCSBackEnd back as it found it
(the typing needs a Windows Server, which allows a second Remote Desktop session). `setup/test.ps1` creates a local admin, `sebtype-test` (the person
installing SebType is an admin), whose Remote Desktop session nobara-pc opens in a headless gamescope; a
logon task there runs Setup elevated, as UAC would, and drives its pages through their window messages.
The typing runs in a second task, not elevated, as apps run. The keys are real (`setup/rdp-keys.py`, below).

`setup/test-unsynced.ps1` checks the words kept when the sync before a removal fails (#271) on any
Windows PC without installing SebType: `setup.ps1`'s account steps and the Configurator's sync, offline,
synced and never on, as a throwaway local user it removes after. It runs elevated on TCSBackEnd
(its header says what its folder holds); the user's profile stays loaded until Windows restarts, so it
needs a PC that can be restarted after.

| Check | What passes |
|---|---|
| `language-follows-windows` | Setup's language dialog offers Windows' display language (简体中文 on TCSBackEnd) |
| `welcome-zh`, `welcome-ja`, `round1-install-pages` | Each page shows and is saved as a picture (`~/scratch/SebType/<issue>/73-*.png`): welcome in all three languages, languages, installing, then the wizard's common settings, sync (skipped) and ready pages |
| `round1-installed`, `-input-methods`, `-only-win-space`, `-chinese`, `-japanese` | The interactive install with all three: SebType in Apps with its icon, its text service registered and no Weasel or Mozc, the list EN → 中 → 日 (the account's Chinese Microsoft Pinyin gone from it), Alt+Shift and Ctrl+Shift off, 中文 and 日本語 named so, the Chinese data deployed with its patches and 6 candidates per page, Mozc's keymap |
| `win-space-cycle`, `chinese-pinyin`, `chinese-shift-tap`, `chinese-ctrl-shift-f`, `japanese-all` | In Notepad: Win+Space gives 中, 日, EN; `ranhou` → 然后; `ni` Shift `ok` Shift `ranhou` → `niok然后`; Ctrl+Shift+F `houlai` → 後來 and back → 后来; `nihongo` → 日本語 |
| `chinese-focus-out` | In Notepad, `nihao` typed, a second Notepad brought to the front and back: `nihao` is in the text, and `ni` Space then gives `nihao你` (#277) |
| `chinese-model`, `chinese-correction` | 中文's model (#495): `shide`, a second, Space → 是的 (Rime alone: 使得), and server.log says it loaded; `youkuaiyoouhao` has 又快又好 on page 1, Rime's correction weighed by the model (#478) |
| `chinese-typo-xkaoshi` | SebType's librime corrects a slip onto the key under i: `xkaoshi` → 小时, and `kaoshi` stays 考试 (#133) |
| `round1-rime-p95` | Rime per key on the installed librime and Chinese data (`perf-rime.ps1` with the librime build's `perf-rime.exe`): p95 ≤ 10 ms (Decisions #2); only with `PERF_RUN=1` (the final performance run, #54) |
| `japanese-alt-grave` | In Notepad, in 日本語: Alt+\` types ア, again あ; after a Shift tap to English, Alt+\` still types `a`, and a Shift tap is あ again |
| `chinese-tray-menu`, `japanese-tray-menu` | In a TSF text field of the test's own: the tray icon's menu is the one item `简 → 繁 Ctrl+Shift+F`; picking it makes `houlai` → 後來, and the menu then reads `繁 → 简 Ctrl+Shift+F` and goes back; the same with ``あ → ア Alt+` `` and `a` (`~/scratch/SebType/<issue>/117-menu-*.png`) |
| `picnic-window` | The Picnic candidate window with the pig, across and down, for 中文 and 日本語 at 14 pt (`~/scratch/SebType/<issue>/162-sebtype-*.png`) |
| `round1-upgrade`, `-upgrade-keeps-learned-words` | A silent rerun exits 0 and keeps the Rime and Mozc learned-word folders |
| `japanese-after-language-change` | After a language is added and removed, Japanese still types |
| `round1-uninstall-pages`, `-uninstall-deletes-learned-words`, `round1-everything-as-before` | The uninstaller's confirm, progress and done; the account's input methods, switch keys, per-window setting, hotkeys and folders as before; SebType gone |
| `round2-*` | Silent: install with 中文 and 日本語 only (English after them), upgrade to English and 中文 (Japanese's words go) keeping a page size of 8 set before it, uninstall; as before |
| `upgrade-*` (`ONLY=upgrade`) | The SebType before #190 (Weasel and Mozc, from main's last setup before it) with learned words, then this one over it: Weasel and Mozc gone with their registrations, the learned words kept; typing as in round 1; uninstall; as before |
| `zh-*`, `ja-*`, `configurator-forgets-*` (`ONLY=forget`) | `setup/test-forget.ps1` as the test user: a picked 4th candidate of shishi and kisha is learned; the Configurator's Forget (`sebtype-configurator.exe --forget zh`, `ja`) while both engines are open, Mozc's history in memory only and its DLL's next read held 8 s as an antivirus scan holds it; the first candidate is the original one again at once and after the server restarts; so is きし's first prediction (Tab) and a digit's width Mozc learned; Forget zh answers while a sync's deploy waits for idle typing, and Forget ja is still going while Mozc's DLL is held (#375) |
| `update-*` (`ONLY=update`) | The "SebType update check" task after Setup (daily, as the test user); `setup/test-update.ps1` as the test user: `--check-updates` against a release served on TCSBackEnd finds it, shows one toast and not a second, and `sebtype-configurator:update` opens the Configurator with `--update`; after the uninstall the task and the link are gone (#422) |
| `machine-as-before`, `admin-input-as-before`, `tcsbackend-as-found` | No SebType, Weasel or Mozc registration left; the Administrator's input methods and TCSBackEnd's users, sessions and game backend as found |

`setup/test-focus-out.ps1` checks, on a PC with SebType installed and in the logged-on person's session,
that focus moving away mid-word types in what was typed (#277): `nihao` stays in the field after TSF's
focus goes to another document and back, and Japanese stays as converted. Switching between SebType's
中 and 日 types it in the same way (#301): `nihongo` Space then 中 leaves `日本語`, `nihao` then 日
leaves `nihao`. Switching to the language list's first other input
method leaves nothing (skipped when there is none; only the test's process switches). It makes no input of its own
(keys go to TSF's keystroke manager), so a screen that is off stays off, and it fails if Windows reports
the display on (`-Trial` checks just that, without SebType; `-WatchTo` watches it around a whole session).

`setup/test-private.ps1` checks the same way that a private field learns nothing new (#270): TsfHost.cs's field
with the input scope `IS_PRIVATE`, which Chrome's and Edge's incognito windows and Firefox's private
windows give, learns no 中文 or 日本語 pick and still suggests what was learned, and that with learning off
in the Configurator (`--learning off`, #374) every field does the same, and on again learns. `-AnyDisplay` runs it
where no one sits, as `test-tcsbackend.sh`'s `ONLY=private` does in the test user's session. `-Browsers` opens a page
in Edge (and Chrome) InPrivate and normal, brings it to the front without a key and reads server.log,
where the server notes each change of the field's learning. It needs a session with a display: a
disconnected Remote Desktop session has no window in front (on TCSBackEnd, Administrator's session
attached in FreeRDP inside headless gamescope, sending no keys).

The keys are real input: `setup/rdp-keys.py` presses them through XTEST in the gamescope display that
FreeRDP runs in, FreeRDP sends their scancodes to the test user's session like any keyboard, and the
typing checks ask for them through a reverse SSH tunnel. So they reach SebType the way a person's keys do,
through the session's input queue, the window's message loop and TSF's keystroke manager. Feeding keys
to TSF directly (`ITfKeystrokeMgr` with a faked key state) made the Shift tap fail where real keys work.
The window in front gets the keys: Notepad, read back through its edit control, or a text field of the
test's own (`setup/TsfHost.cs`), whose text store shows what was composed and committed and whose
language bar item shows the tray icon. Both run in the test user's own Remote Desktop session, started by
a logon task: a process started as another user inside someone else's session fails to start
(0xC0000142).

## Japanese: SebType's Mozc (#65)

Windows Japanese is open-source [Mozc](https://github.com/google/mozc), built by SebType, instead of
Google 日本語入力, whose tray icons are fixed in its signed program (#63). It is the same engine as on
Linux and the phone: `sebtype-server.exe` runs Mozc in its own process, from `sebtype-mozc.dll`, as the
Linux add-on does (#233), and the tray, keys and menu come from the text service and the core. Setup writes SebType's keymap,
`pc/linux/mozc-keymap.tsv`, into Mozc's settings (above). Mozc's own Windows text service, renderer and
installer are not built: SebType's text service replaces them (#190).

### Build

```powershell
pwsh pc/windows/mozc/build.ps1 -WorkDir D:\sebtype-mozc   # -> D:\sebtype-mozc\out\mozc\sebtype-mozc.dll
```

It builds on Windows, because Mozc's Windows build needs MSVC's headers and libraries and the Windows SDK,
which don't cross-build from Linux. The build machine needs Visual Studio 2022 or its Build Tools (C++ x64
tools, a Windows 11 SDK) and Python 3.12+; the preflight says which is missing and prints the `winget` line
to install it (as admin). Everything else is fetched and pinned: `mozc/versions.psd1` pins Bazelisk, and
Mozc's `update_deps.py` pins LLVM and MSYS2. The build itself needs no admin rights and no Developer Mode
(Bazel runs without symlinks).

The script copies SebType's Mozc, `engines/mozc` (Mozc 3.35.6354 with SebType's changes), over the kept
tree in `-WorkDir` and builds `//sebtype:sebtype_mozc_win` with Bazel (8 jobs). A rebuild compiles only what
changed. The DLL exports only the C interface in `engines/mozc/src/sebtype/sebtype_mozc.def` and has the C++
runtime built in (`/MT`), so it needs no runtime DLLs and shares no C++ types with the server, which loads
it at the first 日本語 key (delay-loaded). The installer removes `mozc_server.exe` and its runtime DLLs from
installs before #233.

### Dictionary

On YukaROG (Mozc 3.35.6354, 2026-11-10, through Mozc's own text service): key p50/p95/max
0.39/1.38/3.34 ms, Space 0.42/0.73/2.25 ms, server start 124 ms, 31 MB RAM; top-1 97 of 104 common words
and phrases. The misses were reasonable first guesses that need one more Space: kodomo → 子ども (子供),
kinou → 機能 (昨日), satou → 砂糖 (佐藤), suzuki → スズキ (鈴木), yamada → ヤマダ (山田), takahashi → 高梁
(高橋), and the homophone sentence (記者の記者が記者で帰社した for 貴社の記者が汽車で帰社した). The
engine is the same on Linux, where `pc/linux/perf.sh` measures it.
