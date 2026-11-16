# SebType on Windows

SebType's Windows input methods, 中文 and 日本語, over SebType's [core](../core) (#190). They replace
Weasel and Mozc's Windows text service. The installer is [`pc/windows/setup`](../pc/windows), which also
says what it sets up.

- `sebtype-server.exe` (`src/server.cpp`): one per user and session, started at logon (or by the text
  service at the first key). It hosts the core, so librime and Mozc (`sebtype-mozc.dll`, #233) run in it, and every app reaches it over a named pipe, `\\.\pipe\SebType.<session>.<user>` (`src/pipe.h`,
  `src/protocol.h`). One process means one writer for Rime's learned words and one language for every
  window. `sebtype-server.exe /deploy`, `/sync`, `/mozc` (restart Mozc, which reads its files again) and `/quit`
  are for Setup and the Configurator; `/deploy`
  and `/sync` return when Rime is done, and run Rime themselves when no server runs (as Weasel's deployer
  did), so a Setup started elevated leaves no server the apps can't reach. Rime's log and the server's
  (`server.log`: starts, requests over a second, the commands' failures) are in `%TEMP%\rime.sebtype`.
- `sebtype.dll` (`src/tip/`): the text service, one COM class with a 中文 (zh-CN) and a 日本語 (ja-JP)
  profile. It sends each key to the server and shows its reply:
  - Chinese keeps the pinyin in the candidate window, Japanese types inline with Mozc's underlines
    (`edit.cpp`).
  - The candidate window (`candidate_window.cpp`) has Weasel's layout and metrics, in Weasel's aqua colours
    or SebType's Picnic with the pig at the start (#162), with the same space between the candidates and
    the pig as on Linux. `%APPDATA%\SebType\sebtype.conf` `[Candidates]` sets it (`Vertical`, `FontSize`,
    `Picnic`); the Configurator writes it, and the window reads it each time it shows.
  - The input indicator's button (`langbar.cpp`) shows SebType's keycaps (`pc/icons`, made into `.ico`
    files by `make_icons.py`); its right-click menu is the language's one switch, and a left click
    toggles English letters.
  - A short popup names the mode after 中文's Shift tap, in Windows' display language (#205).
  A 32-bit build of it (`x86\sebtype.dll`) serves 32-bit apps over the same pipe.

## Build

```powershell
windows/build.ps1 -Rime <SebType's librime> -Out <dir>
```

It needs Visual Studio 2022 with C++, vcpkg (protobuf, linked statically), Python and curl, and the librime
that `pc/windows/rime/build.ps1` leaves (CI's `sebtype-rime` artifact). `.github/workflows/windows-setup.yml`
runs it on GitHub's Windows runner and packs the result into Setup. The C++ runtime is linked into each
file, since the DLL loads into every app.

## Test

`pc/windows/setup/test-tcsbackend.sh` installs Setup on TCSBackEnd and types into Notepad and a TSF text
field with real keys (see [`pc/windows`](../pc/windows)). The core's own tests are in [`core/`](../core).

## Licences and credits

SebType's own code here is MIT ([LICENSE-SebType](../LICENSE-SebType)). The candidate window is SebType's
code that takes Weasel's layout numbers (margins, spacing, corner radii, the aqua colours) from
[Weasel](https://github.com/rime/weasel) (GPL-3.0) as settings, not its code. librime (BSD-3-Clause) and
Mozc (BSD-3-Clause) keep their licences.
