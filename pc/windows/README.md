# SebType on Windows

On Windows, SebType's Chinese is Weasel (小狼毫) with the phone's Chinese data: rime-ice's schema and Lua
with 白霜's dictionary. English is Windows' plain US layout. Japanese stays whatever the PC has until
SebType's own Mozc (#65) replaces it. `setup-ime.ps1` sets it up for this account with nothing done by
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
