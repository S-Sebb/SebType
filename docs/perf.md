# Measuring SebType's size, memory and speed

Two scripts measure SebType the same way every time (#45). Run them before merging changes to the
engines, dictionaries or the keyboard UI, and compare against the baseline on #45.

## Android: `sebtype/perf.sh`

```
sebtype/perf.sh                     # builds the release APK, then measures on a free emulator ([testing.md](testing.md))
APK=path/to.apk sebtype/perf.sh     # measures an APK you already built
ANDROID_SERIAL=<serial> sebtype/perf.sh   # any other device; the only way to run it on a phone
```

It reinstalls SebType, so everything SebType learned on that device is lost. It then types into its
own small test field (`sebtype/perf/PerfField.java`) with `monkey` taps, and puts the previous keyboard
back at the end. The device needs Android 14 or newer and must run arm64 apps. It takes about 15
minutes. While it runs it holds the device's devq lock, shared by all projects:
`/tmp/agent-locks/devices/emulator-<AVD>.lock`, or on a phone the lock named after its maker and
model (`nothing-a001.lock`), which other projects take for the phone too.

What it measures:

| Metric | How |
|---|---|
| APK size, biggest entries | the APK file; shrunk resource names mapped back with `aapt2` |
| Installed size | `du` of the app's code, internal and external data (root shell only: emulator) |
| Memory | `dumpsys meminfo` total PSS: idle, after typing in each language, with all three engines loaded (fast typing right after 中 and 日), idle again once unused engines unloaded (`IDLE_UNLOAD_S`, default 200 s, just over the app's 3 minutes), peak during the first Chinese setup. Each breakdown is kept in `run/meminfo-<point>.txt` |
| Keyboard open | until the keyboard's first frame on screen: first open after install (from the field's first frame), warm (from a tap on the field after hiding the keyboard), cold (from the keyboard's process start, switching back from Gboard or FUTO with SebType stopped) |
| Per key, per language | Perfetto: the keyboard's touch dispatch (handling), the field's next frame after its text changed (key → text), the frame that last redrew the candidate bar (key → candidates), the keyboard's last frame before the next key (key → idle), and the transformer thread's CPU time |
| Jank | `dumpsys gfxinfo` and the frame timeline while typing 10 keys a second, in an empty field and in a 20,000-character one |
| Every key arrives | the same 10 keys a second: the keyboard must get every tap (Perfetto), and the field's text (a UI dump) must be what was tapped, ignoring case. The check fails naming each missing, extra or out-of-order character with its position, kept in `run/<fast\|long>.diff`. A missing touch means the taps' injection lost it, not the keyboard; autocorrect can put back a key the keyboard never got, so touches are checked first |
| Chinese first-run setup | the app's own timing of installing the bundled data and Rime's check, after the first switch to 中, and how many tables or prisms were compiled on the device (should be 0; root shell only) |

English runs with FUTO's transformer on (the default), Chinese with Rime and the bundled data (rime-ice's schema, 白霜's dictionary), Japanese with
Mozc. Each typing set runs `RUNS` times (default 3), each time in a fresh test field; the table
gives the median and the 95th percentile over all keys. English types after one keyboard restart,
because the transformer can stay off in the first process after install.

Results, in `/tmp/sebtype/perf-<checkout>/` (or `PERF_OUT`): `perf.md` (the table), `results.txt`
(one line per check), and traces and logs in `run/`. Open a `.pftrace` in https://ui.perfetto.dev to see where
the time goes.

No typed text is recorded: the test field logs only its text length, and timing comes from
framework trace slices and frame timelines; the trace records no logs.

Notes:

- **Engines load on demand (#56).** English's transformer loads on the first prediction and unloads
  when the language switches or after 3 minutes without a prediction (`ENGINE_IDLE_MS`). Rime stops 3
  minutes after 中 was last in use, or after a background setup nobody types into. Mozc unloads 3
  minutes after 日 was last in use, and the next 日 field loads it again. So "after typing 中" has no transformer in it, and
  "after fast typing EN" (right after 中 and 日) is the most that is ever loaded at once.
- **Idle is read once the keyboard settled**, 30 s after it opens (`SETTLE_S`). A new process reads
  about 25 MB higher for its first seconds (start-up Java garbage not yet collected): on the phone
  152 MB 3 s after the first open, 124 MB at 30 s.
- **The emulator gives relative numbers only.** It runs SebType's arm64 code through translation
  and renders in software. Compare an emulator run with another emulator run, never with the phone.
- **Key positions** come from SebType's uniform layout at the default keyboard height. Each typing
  check verifies the text length afterwards and fails with "taps missed the keys" if they didn't land.

### On the phone

The phone is shared with its owner: run this only when they agree, with the phone unlocked and
idle. Turn on USB or wireless debugging, check that `adb devices` lists it, then run
`ANDROID_SERIAL=<serial> sebtype/perf.sh`. SebType is reinstalled, so anything it learned on the phone
is lost; export its settings first if that matters. Gboard must be enabled for the cold-open check.
The installed-size row needs root, so on the phone it is SKIP; Settings → Apps → SebType → Storage
shows the same numbers. Without root, the phone can't count what Rime compiled during setup either;
the emulator run shows it.

The phone's screen must stay on the test field for the whole run. Each set of taps checks that
it does, and fails naming the window that came to the front. In #76, another project's agent opened
its app on the phone during a run (it took a different lock), and the rest of the taps went into that
app. The failure looked like SebType had come back in the wrong language.

#### Phone results (Nothing A001, Android 16, main 8565c7161, 2026-11-10)

Against the budgets in Decisions #2. All phases passed; the full table is on #56.

| Budget | Phone | Met |
|---|---|---|
| APK ≤ 150 MB | 105 MB | yes |
| PSS idle ≤ 100 MB | 140 MB at first open, 132 MB in a fresh process, 187 MB idle after using all three | no |
| PSS in one language ≤ 150 MB | EN 232 MB, 中 143 MB, 日 163 MB | 中 only |
| PSS with all three ≤ 200 MB | 308 MB | no |
| No Rime deploy on the phone | Chinese set up in 1954 ms (install 701 ms); files compiled not readable without root | emulator: 0 compiled |
| Key handling p95 ≤ 8 ms | EN 10, 中 10, 日 7 ms | 日 only |
| Key → text p95 ≤ 50 ms (日 ≤ 60) | EN 24, 日 41 ms | yes |
| Key → candidates p95 ≤ 100 ms | EN 77, 中 67, 日 57 ms | yes |
| Warm open ≤ 150 ms, cold ≤ 1 s | warm 62 / 78 ms, cold 428 / 614 ms (median / p95) | yes |
| 10 keys a second: no late frames from the app, every character arrives | 88 of 88 arrived; 24 of 845 frames late from the app (20,000-character field: 69 of 843) | no |
| 0 crashes | 0 | yes |

## PC (Linux): `pc/linux/perf.sh`

```
pc/linux/perf.sh                    # RUNS (default 5) repeats each typing set
```

It never touches the running Fcitx5 session:

- **Rime with rime-ice:** times each key followed by reading the candidate menu (as Fcitx5 does)
  through librime, on a temporary copy of `~/.local/share/fcitx5/rime` (or `RIME_DIR`), deleted on
  exit. Then it deletes the copy's `build/` and times a full deploy with its peak memory.
- **Mozc:** starts a private `mozc_server` with its own empty profile and talks to it over Mozc's
  IPC (`pc/linux/perf-mozc.py`): suggestions per key, and conversion with Space. Each word is
  reverted, so nothing is learned.
- **Memory:** RSS, PSS and swapped-out size of the running `fcitx5` and `mozc_server`, read from
  `ps` and `/proc`.

It needs gcc, python3, librime with librime-lua, and fcitx5-mozc. It fetches librime's public headers
(pinned, checked by sha256) into `~/.cache/sebtype/`. Results: `/tmp/sebtype/pc-perf.md` and
`/tmp/sebtype/pc-perf-results.txt`.

## Build and test times (#58)

Measured on nobara-pc (16 threads, 15 GB) on 2026-11-10, with other agents' work running beside, so
numbers vary by about ±30 %. "Build" is `sebtype/build.sh`'s own time, which it now prints apart from
the wait for the build lock; "peak" is the summed memory of the build's processes (Gradle, the Kotlin
daemon, clang, aapt2, R8). `sebtype/test-build.sh` checks the cache and reproducibility parts.

| `sebtype/build.sh …` | Before | After |
|---|---|---|
| debug, first build in a new worktree (same sources built elsewhere before) | 116 s | 14–15 s |
| debug, clean rebuild in the same worktree | 110–140 s | 18 s |
| debug, nothing in the build cache (sources nobody built yet) | 110–140 s | 73 s |
| debug, nothing changed | 12–22 s | 7–8 s |
| debug, one Kotlin file changed | 54–61 s | 17–31 s |
| debug, one string resource changed | 58 s | 8–10 s |
| debug, one C++ file changed | 11–16 s | 9–10 s |
| release, nothing cached | 175 s | 170 s |
| release, first build in a new worktree | about 175 s (a clean build) | 16–22 s |
| release, nothing changed | 12 s | 8–17 s |
| release, one Kotlin file changed | 163 s | 91–101 s (R8 shrinking the whole app is ~80 s of it) |
| test-x86_64, clean | 130 s | 46 s |
| test-x86_64, one Kotlin file changed | 65 s | 27–29 s |
| peak memory, debug / release | 4.5 GB / 3.8 GB | 4.2 GB / 4.3–5.5 GB |

| Other builds and tests | Before | After |
|---|---|---|
| `rime-android/build.sh` (arm64 aar), rebuild in the same checkout | 130 s | 27–31 s, the same aar |
| `pc/linux/mozc/build.sh`, nothing changed / after a patch change / first build | 11 s / 323 s / 490 s | unchanged |
| `pc/linux/test-setup-ime.sh` | 15 s | unchanged (mostly Fcitx5 and a Rime deploy starting) |
| `sebtype/test-privacy.sh` (release rebuild + checks) | 13 s | 8 s |
| `sebtype/test-typing.sh` (test APKs + 4 tests on the emulator) | 22 s build + about 55 s device | 7 s build, 58 s in all |
| `sebtype/test-emulator.sh` | 12 s build + about 7 min device | 7 s build, 338 s in all |

The device steps are unchanged: they install fresh on purpose. A test's wall time is often mostly the
queue for the emulator's lock (`devq status /tmp/agent-locks/devices/emulator-<AVD>.lock`).

What made the difference, each measured on its own:

- **Kotlin compiles incrementally.** The in-process compiler recompiled all of the app's Kotlin on every
  change (its build report: "Non incremental … REBUILD_REASON: In-process execution"); the Kotlin daemon
  recompiles only what changed (one file: 54 → 21 s). It is capped at 2 GB and ends with the build.
- **Gradle's build cache** (`org.gradle.caching`, in `~/.gradle`, shared by every worktree) restores
  compiled Kotlin, dex and resources: a clean rebuild 103 → 41 s. To make the cache match across
  worktrees, `rootProject.name` is fixed (the project was named after the checkout's folder, which also
  went into Kotlin's internal names in the dex), and debug builds have a fixed version (code 1,
  `…-sebtype.dev`, branch `dev`): they compiled the commit count and branch into `BuildConfig`, so every
  commit missed the cache. Release builds keep the real version.
- **sccache for the app's C++** (when installed): a clean rebuild 41 → 17 s, a new worktree 41 → 15 s.
  Each build starts its own sccache server with `SCCACHE_BASEDIRS` set to the checkout, and
  `-ffile-prefix-map` keeps the checkout's path out of the objects, so objects are shared between
  worktrees without one worktree's paths ending up in another's library.
- **Configuration cache**: Gradle reuses the configured build (nothing changed 11 → 6 s, one Kotlin file
  24 → 17 s). `build.gradle`'s git calls go through `providers.exec`, which it allows.

Release builds stay reproducible: a release built with no build cache and no sccache in one worktree and
one built from the caches in another have the same APK entries (outside the signature). Before, they
differed between checkouts (folder name in the dex, checkout path in `libjni_latinime.so`).

Tried and not kept:

- **A Gradle daemon kept warm between builds** (10-minute idle timeout): one Kotlin file 17 → 7 s, a
  resource 8 → 3 s, nothing changed 7 → 2 s, but the idle Gradle and Kotlin daemons hold 3.5 GB until
  the timeout (`-XX:G1PeriodicGCInterval` doesn't shrink them), on a PC whose builds are capped because
  of an out-of-memory crash. Builds still end with no daemon left.
- **Gradle heap 2 GB instead of 3 GB**: no lower peak, no faster.
- **Kotlin out-of-process**: as non-incremental as in-process (60 s for one file).
- **One ABI, no minify, no lint for dev builds**: already so (each kind builds one ABI, debug doesn't
  minify, `assemble` doesn't lint).
- **ccache in the Mozc container**: a rebuild already recompiles only what changed (11 s with no change);
  ccache would only help the rare first build after a version bump.
- The PC librime build (#46) isn't on main yet, so it has no numbers here.
