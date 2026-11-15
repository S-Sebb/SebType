# Experiment: Mozc's engine in-process in core/ (#220, 2026-11-15)

Today SebType's core talks to a separate `mozc_server` over Mozc's IPC, on Linux (the Fcitx5 add-on)
and on Windows (behind `sebtype-server.exe`). Android already links Mozc in-process. The question is
whether the PCs should link it in-process too: one process instead of two, no IPC on each key, and no
watchdog or server-path code.

**Recommendation: adopt it,** on Linux first and on Windows in the same change. Japanese is ready
sooner (223 ms against 266 ms) and uses 4.4 MB (11 %) less PSS than Fcitx5 plus `mozc_server`. Per key
it is level or slightly faster (p95 1.45 ms against 1.67 ms), and the build is no harder. It also removes the code behind the two server-path bugs (#215, #217). The cost is crash
isolation: a crash in Mozc now takes down Fcitx5 (Linux) or `sebtype-server` (Windows), not just
`mozc_server`. That trade is the same one Rime already makes in both places, and Android already makes
it for Mozc. [What the real PR changes](#what-the-real-implementation-pr-changes) is listed at the end.

The prototype is on the branch
[`exp/220-mozc-in-process`](https://github.com/S-Sebb/SebType/tree/exp/220-mozc-in-process). It is not
for merging.

## The prototype

- `engines/mozc/src/sebtype/`: a Bazel target `//sebtype:libsebtype-mozc.so`. It holds Mozc's
  `SessionHandler` over its desktop engine (`EngineFactory`, the same engine `mozc_server` runs, with its
  data built in), behind a C interface: `sebtype_mozc_open(profile_dir)`, `sebtype_mozc_eval(Input bytes)
  -> Output bytes`, `sebtype_mozc_free` and `sebtype_mozc_close`. This is what `SessionServer::Process`
  does for each request, without the IPC server, the watchdog or the process (about 50 lines). A version
  script exports only `sebtype_mozc_*`, so Mozc's own protobuf and Abseil stay hidden inside the library
  and can't clash with the system protobuf the add-on links. Android's `mozcjni.cc` does the same thing
  through JNI.
- `core/src/mozc.cpp`: with `SEBTYPE_MOZC_INPROC`, the `Ipc` class's `call()` serializes the same
  `Input`, calls `sebtype_mozc_eval` and parses the `Output`. The rest of the file (key translation,
  sessions, the candidate window) did not change. Serializing in place of a direct `Command` costs
  microseconds. It is what let core keep using Fedora's protobuf.
- `linux/sebtype.spec` builds the library with Bazel before CMake and links the add-on to it. It installs
  the library as `%{_libdir}/sebtype/libsebtype-mozc.so` (the add-on's RUNPATH is `$ORIGIN/../sebtype`)
  in place of `/usr/libexec/sebtype/mozc_server`.

Two visibility lines were added to Mozc's BUILD files (`session_handler`, `engine_factory`). Nothing in
`gui/`, `win32/`, `unix/`, `renderer/`, `mac/` or `ios/` is used (#219 removes them).

## Linux measurements (nobara-pc)

Method as in [docs/perf/2026-11-15.md](../perf/2026-11-15.md): `pc/linux/compare.sh` runs each setup in
a private Fcitx5 with a throwaway profile, in a private D-Bus session. It ran with `RUNS=5` (405 romaji
keys) and `SOAK_MIN=5`, once on main's build (`4.fc44`) and once on the prototype's. Both packages are
built from the same Mozc source with the same Bazel flags.

The timing runs started only when the 1-minute load was below 4 for 2 minutes, with no other SebType
build in the build lock. The PC was shared with other agents' builds this afternoon, and the load still
rose during runs, as noted under the table.

| Japanese (Mozc) | main: Fcitx5 + mozc_server | prototype: Fcitx5 alone | Notes |
|---|---|---|---|
| Per key: reply p50 / p95 / max | 1.10 / 1.67 / 10.7 ms | 0.95 / 1.45 / 1.8 ms | |
| Per key: candidates shown p50 / p95 | 1.21 / 1.77 ms | 1.04 / 1.55 ms | |
| Conversion (Space) p50 / p95 | 1.20 / 1.67 ms | 1.07 / 1.73 ms | |
| Ready on a fresh profile / second start | 266 / 268 ms | 223 / 222 ms | first key to candidates, Fcitx5 start included |
| Memory after typing, RSS | 21.2 + 26.5 = 47.7 MB | 39.2 MB | |
| Memory after typing, PSS | 16.0 + 22.7 = 38.7 MB | 34.3 MB (4.4 MB, 11 % less) | |
| Mixed 中文/日本語 typing, 5 min: PSS plateau | 28.6 + 23.0 = 51.6 MB | 49.3–50.3 MB | 0 crashes in both |

The prototype's run had a load of 1.4 to 2.7 throughout. Main's run started at 1.2, but other builds
pushed the load to 11.5 by its end. Fedora's stock fcitx5-mozc ran in both as a control: 1.02 / 1.61 ms
per key in main's run and 0.95 / 1.53 ms in the prototype's. So about 5 % of the per-key difference is
the quieter window, and the rest (about 10 %) is the IPC round trip going away. Main's 10.7 ms max was
one key. Read the per-key result as level, or slightly faster. The memory and ready rows don't depend
on the load. On a fresh profile, the prototype's Fcitx5 alone starts at 37.3 MB PSS in the mixed run,
against 38.6 MB (23.4 + 15.2) for the two processes.

Stock fcitx5-mozc was ready in 418–424 ms in both runs. Rime (中文)
is unaffected by this change; main's Rime in the same run had a per-key p50 / p95 of 2.08 / 2.71 ms.

**Build and package**

| | main | prototype |
|---|---|---|
| Cold build, `linux/build.sh` (Bazel's repository cache only, other caches empty) | 361 s, of which Bazel 324 s (1771 actions) | 510 s, of which Bazel 327 s (1756 actions); the rest is a one-off rebuild of the builder image for the changed spec |
| Rebuild after a change to core/ or the spec | – | 132 s |
| RPM size | 14.57 MB | 14.51 MB |
| Installed | `mozc_server` 24.8 MB + `sebtype.so` 1.04 MB | `libsebtype-mozc.so` 24.7 MB + `sebtype.so` 1.02 MB |

Both builds ran on a busy PC (load 10–20, before the orchestrator capped build jobs), so the build
times compare only with each other. The Bazel work is the same size: the library has the server's
engine, minus its IPC server. The build gets no harder: the spec still runs Bazel once and CMake once,
in the other order. Mozc's data still sits inside the one ELF file and is mapped from it, so the
package size doesn't change.

## What changes besides speed and memory

- **Gone:** the IPC client in `core/src/mozc.cpp` (about 170 lines for Linux and Windows): the socket
  and named pipe, the `.session.ipc` key file, launching the server with a Windows impersonation token,
  the retry and back-off. Also gone: Mozc's `SessionWatchDog`, whose path check aborted the server every
  3 minutes in #215 and #217, the `/usr/libexec` overlay in the tests (`linux/versions.sh`), and the
  Windows `GetServerDirectory()` patch. On Windows, the installer's `taskkill mozc_server.exe` and
  move-aside steps go too.
- **One Mozc per Fcitx5 / per `sebtype-server`**, not one per user. Today, Mozc's process mutex means
  every Mozc client shares one `mozc_server`. That doesn't matter for SebType: there is one Fcitx5 per
  session and one `sebtype-server` per session on Windows. A second process opening the same profile
  (such as a stock fcitx5-mozc beside SebType) would now have its own engine on the same
  `~/.config/mozc`. It is the same as two `mozc_server`s with different paths, which Mozc tolerates
  (its storage writes whole files).
- **When learned words are saved.** The watchdog's Cleanup every 180 s also called `engine->Sync()`.
  In-process, Mozc saves on `DeleteSession`, on `SYNC_DATA` (core's `save()`) and on close. Fcitx5 calls
  `save()` on its auto-save timer and on exit. The real implementation should keep a periodic sync (for
  example a `SYNC_DATA` at most every few minutes after a commit), so a crash doesn't lose more learned
  words than today.
- **Startup:** the engine loads on the first Japanese key, in Fcitx5's thread, as Rime's session does.
  The table's ready time includes it. No server needs to be started or connected to.

## Crash isolation

What the separate process gave:

- A crash or `LOG(FATAL)` in Mozc ended only `mozc_server`. Core started a new one on the next key
  (`Ipc::call`, at most once every 10 s) and made a new session. The user lost the Japanese text being
  composed, but Rime, English and every app's connection stayed up.
- A hang in Mozc cost each key at most the 5 s socket or pipe timeout, without blocking Fcitx5 forever.
- Mozc's memory (dictionary, learned words) stayed in its own address space. Its leaks or growth showed
  up in `mozc_server`, not in Fcitx5.

What in-process loses, and how much it matters:

- **Linux:** a crash in Mozc takes Fcitx5 down: all three languages in every app, until it is started
  again. Under Plasma Wayland, KWin starts the input method and starts it again after it exits (not
  tested here). This is already true of Rime, which runs in Fcitx5 too, and of every Fcitx5 engine
  (fcitx5-rime, fcitx5-anthy, fcitx5-chewing). In the test runs, Mozc's only crash was the watchdog's
  own abort, which this change removes. The mixed-typing runs (13,178 keys on 2026-11-15, plus this
  experiment's) had no other Mozc crash.
- **A hang** in Mozc would block Fcitx5's event loop, where today it costs a timeout. Mozc's engine
  doesn't wait on anything outside itself (no network, no locks held across calls). Its slowest key
  above is in the same range as main's.
- **Windows:** the text service in each app already talks to `sebtype-server.exe`, which hosts Rime
  in-process (`windows/src/server.cpp`). Mozc would move into that server. A Mozc crash would then end
  `sebtype-server`, and the text service starts it again on the next key (`TextService::send`, at most
  once every 10 s). The cost is Rime's reload (a second start: 237 ms session on TCSBackEnd) and the
  composing text in both languages. The apps stay up either way, because no engine runs in the app's
  process. So the isolation that matters most on Windows, a crash not taking down the user's app, is
  kept.

## Windows, on paper

Not built for Windows in this experiment. What the change takes:

- `pc/windows/mozc/build.ps1` builds `//sebtype:sebtype-mozc.dll` (the same target as a Windows DLL,
  `mozc_cc_binary(linkshared)` with a `.def` exporting `sebtype_mozc_*`) instead of
  `server:mozc_server_win`, with the same clang-cl toolchain and the same C++ runtime DLLs. A C
  interface across the DLL boundary avoids any ABI or CRT match between Bazel's clang-cl build and the
  CMake/MSVC build of `sebtype-server.exe`. Mozc's protobuf stays inside the DLL, as on Linux.
- `windows/src/server.cpp`'s `makeEngine` passes Mozc's profile folder
  (`%LOCALAPPDATA%Low\Mozc`, as now) and no server path. `sebtype-server.exe` links the DLL's import
  library.
- Gone: `mozc_server.exe`, its impersonation-token launch (`Ipc::launch`), the named pipe client, the
  `GetServerDirectory()` patch, and the installer's Mozc process steps.
- Expected effect: one process fewer (`mozc_server` was 21.6 MB working set, 6.1 MB private on
  TCSBackEnd). The pipe round trip goes too. On TCSBackEnd the Japanese per-key p50 was 2.2 ms against
  0.26 ms for the engine alone, but most of that gap is the app-to-`sebtype-server` pipe, which stays.
- Risk: Mozc's Windows code expects to run as `mozc_server` in places: `RunLevel` checks and
  `SystemUtil::DisableIME()` in `InitMozcAndMozcServer`. The prototype calls neither, as Android's JNI
  doesn't. The Windows build should check that the engine starts without them, which CI's
  `windows-setup` run and TCSBackEnd's `ONLY=compare` would show.

## What the real implementation PR changes

1. `engines/mozc/src/sebtype/` (the library and its C interface, as in the prototype) plus the two
   visibility lines. Add a periodic `SYNC_DATA` (see above).
2. `core/src/mozc.cpp`: the in-process call becomes the only path; the IPC class, `ipc/ipc.proto` and
   `MozcPaths::server` go. Android's split of `mozc.cpp` (#190 step 3) can share the same `Engine`
   class: on Android the call goes to FUTO's JNI library, on the PCs to `sebtype_mozc_eval`.
3. `linux/`: the spec and CMake changes from the prototype, with the RUNPATH set on the add-on target
   (Fcitx5's CMake settings override `CMAKE_INSTALL_RPATH`). `linux/versions.sh` loses the
   `/usr/libexec` overlay. `pc/linux/perf.sh`'s Mozc rows time the library directly instead of
   `mozc_server` over IPC (`perf-mozc.py`). `compare-keys.py` stops looking for a `mozc_server`.
4. `windows/` and `pc/windows/`: as in [Windows, on paper](#windows-on-paper), checked by CI's
   `windows-setup` and TCSBackEnd's `ONLY=compare` and 12-minute mixed run.
5. Licences: `core/README.md` and the spec's `License:` stay (Mozc is still BSD-3-Clause, now linked).
