# Building, testing and measuring SebType

Every build, test and measurement command, what it needs and where its results go. The READMEs in `pc/`
describe what each PC part does and list what each of its checks verifies.

- What SebType must do: [Requirements (#1)](https://github.com/S-Sebb/SebType/issues/1)
- Settled choices: [Decisions (#2)](https://github.com/S-Sebb/SebType/issues/2)
- Which licence covers which part: the README's [Licences](../README.md#credits-and-licences)
- Build and publish a release: `android/release.sh` ([install.md](install.md#publishing-a-release))
- The Chinese data: [`data/rime/build.sh`](../data/rime/build.sh) builds it from rime-ice's and
  rime-frost's pinned releases, and `data/rime/bench/bench.sh` measures its accuracy, on the host's
  librime with Lua, the same version as `engines/librime`.

## Layout

| Folder | What |
|---|---|
| `android/` | The Gradle build: `app/` (the keyboard, FUTO Keyboard with SebType's changes), `native/` (`libsebtype.so`: `core/` with librime and the JNI glue, and Mozc's `libmozc.so`, which it runs in-process), the build and release scripts, `test/` and `perf/` |
| `engines/` | `mozc/` and `librime/`: the one source of each engine, built for the phone and both PCs |
| `core/`, `linux/`, `windows/` | SebType's shared core and its frontends: the Fcitx5 add-on, the Windows text service and server |
| `pc/` | Linux (Fcitx5) and Windows (librime's build, Mozc's installer, SebType's installer), and the Configurator |
| `data/` | The Chinese data (`rime/`) and the English dictionary (`en-dict/`), built from pinned sources |
| `art/` | The icon, the fonts and the script that draws the launcher icons |
| `sync-server/` | The sync server you run yourself |
| `tools/` | Scripts shared by the others (`lib.sh`) and data tools |

## Building

### Where builds run

Every SebType build runs on yanglab16, the lab's machine (96 threads), not on nobara-pc (#225, #248):
`android/build.sh`, `linux/build.sh`, `linux/build-librime.sh`, and the builds test scripts need. Each
copies what it built back to the same path on nobara-pc, so the device tests and setup use it as before.
Only the tests themselves run on nobara-pc: the private Fcitx5 sessions, the emulator, the Configurator's
screens. One command, run on nobara-pc as always:

1. `build_host_ready` (`tools/lib.sh`) checks that `ssh yanglab16` answers. If it doesn't, it starts
   Zscaler (`gtk-launch ZSTray`) and tries once more; if it still doesn't, it says so on stderr and the
   build runs on nobara-pc.
2. `build_remotely` rsyncs the checkout, uncommitted changes included and what git ignores left out,
   to `~/scratch/SebType/<task>/<checkout>/` on yanglab16 (`<task>`: `ISSUE`, or the checkout's folder),
   runs the same script there, and copies back each file it prints. What git ignores stays on yanglab16,
   so its next build of the checkout is incremental.
3. On yanglab16 the script runs as on nobara-pc, in yanglab16's own build lock, with its tools from
   `~/scratch/SebType/cache/` on the NAS: the Android SDK and NDK, JDK 21 and sccache, pinned and installed
   on first use by `tools/android-tools.sh`, and Gradle's cache. The Android build runs in the pinned
   Fedora 44 (`linux/versions.sh`) with Fedora's librime and OpenCC, as on nobara-pc (`fedora_container`
   in `tools/lib.sh`); the Linux builds use their own Fedora container as before. Bazel's output roots (Mozc's builds) are in the podman volume
   `sebtype-bazel` on yanglab16's local disk: Bazel refuses a folder it doesn't own, and on the NAS every
   file belongs to the NAS's user. Every Podman call there (the build images, their containers and that
   volume) uses SebType's own store on the SSD, `/media/ssd2/tony/SebType/podman/` (#337): yanglab16's
   system disk, where tony's default store is, is full of other users' files. `tools/lib.sh` points
   Podman at it with `CONTAINERS_STORAGE_CONF` and `CONTAINERS_CONF_OVERRIDE`; tony's default store and
   Podman config, which hold other projects' images such as `gh-runner`, stay as they are. To look at
   SebType's images by hand there: `source tools/lib.sh; podman images`.

A release APK is built unsigned, on yanglab16 (`SEBTYPE_UNSIGNED=1`) or on nobara-pc, and signed on
nobara-pc with `apksigner` (scheme v2 alone, RSA), so the signing key never leaves nobara-pc and a release
is the same file from either.

Test scripts build through `tools/build.sh MINUTES NAME SCRIPT`, which runs SCRIPT on yanglab16 in that
same Fedora container (yanglab16's Ubuntu has neither Rust nor librime) and copies back the files it
prints: the Configurator and its unit tests' executable (`pc/configurator/build.sh`, for
`pc/configurator/test.sh` and `pc/linux/test-setup-ime.sh`, which run that executable instead of
`cargo test`), and the Chinese data (`data/rime/build.sh`, for `test-setup-ime.sh`, `pc/linux/compare.sh`
and `data/rime/bench/bench.sh`). In the container the checkout is at its nobara-pc path, so the paths Rust
compiles into the tests hold on nobara-pc. Rust's cache there is `~/scratch/SebType/cache/cargo`.

`SEBTYPE_BUILD_HOST=local <script>` builds on nobara-pc. Otherwise a build runs on nobara-pc only when
yanglab16 can't be reached. `android/test/build.sh` is the exception: it checks yanglab16's caches and
builds, so it needs yanglab16 and stops without it, and `SEBTYPE_BUILD_HOST=local` adds one release built
on nobara-pc, to compare with yanglab16's (#250). CI stays on GitHub's runners: SebType is public, and a fork's PR must not run on the
lab's machine. The Windows build runs only in CI (MSVC on GitHub's Windows runners).

### The build lock

Every heavy build runs through `build_lock` in `tools/lib.sh`: one SebType build at a time per machine,
in the queue `/tmp/agent-locks/sebtype/build.lock` (`devq status <lock>` shows it), waiting up to an
hour. The queue rank is `DEVQ_RANK` (default 2, lower goes first; it orders the queue, the lock still
lets one build in at a time): set it once and every build the script starts, however nested, queues at
that rank. A build that starts other builds runs them inside its own lock, not through `build_lock`
again.

Inside the lock a build runs at the lowest CPU and I/O priority (`nice -n 19 ionice -c 3`), capped in CPU
time and memory:

| | nobara-pc (16 threads, 15 GB, shared with the emulator, the person at it and other projects) | yanglab16 (96 threads, shared by the lab) |
|---|---|---|
| CPU (`BUILD_JOBS`) | 6 cores' worth: 6 compile jobs for Ninja, Bazel and cargo | 48 |
| Gradle workers (`GRADLE_WORKERS`) | 4 | 48 |
| Memory (`BUILD_MEMORY_GB`) | 8 GB | 32 GB |

### Android

```
android/build.sh release        # signed arm64-v8a release APK (keystore in ~/.config/sebtype)
android/build.sh debug          # debug arm64-v8a APK, the one the emulator tests run
android/build.sh debug-x86_64   # debug APK for an x86_64 emulator
android/build.sh test-x86_64    # debug APK and its instrumented-test APK
android/build.sh next           # signed arm64-v8a APK of next/, the new keyboard (#191, test-only)
android/build.sh next-debug     # its debug APK
```

It prints the APK's path last. Each run gets its own folder in `android/app/build/runs/` (hard links,
kept a day), so builds run at the same time in one checkout never hand each other's APK out. Debug
builds have a fixed version (`…-sebtype.dev`, code 1); release builds count main's commits. Android
Studio or `cd android && ./gradlew assembleDebug` work too, on nobara-pc and outside the lock.

What it builds from source, and the caches that make a rebuild quick:

| Part | Built by | Cache |
|---|---|---|
| Kotlin, Java, resources | Gradle | Gradle's build cache in `~/.gradle` (on yanglab16 `~/scratch/SebType/cache/gradle`), shared by every worktree |
| The app's C++ (`libjni_latinime.so`) and `libsebtype.so` (`core/` with librime, from `engines/librime` with librime-lua and octagram) | CMake | sccache; `-ffile-prefix-map` keeps the checkout's path out of the objects, so worktrees share them. Rime's third-party sources (pinned, checksum-checked) are downloaded once into `~/scratch/SebType/cache/rime-android` |
| Mozc (`libmozc.so`, from `engines/mozc`) | Bazel (`android/native/build-mozc.sh`) | Gradle's build cache, and Bazel's disk cache in `~/scratch/SebType/cache/mozc-android` (on yanglab16 in the `sebtype-bazel` volume, on its SSD) |
| The Chinese data | `data/rime/build.sh` | `~/scratch/SebType/cache/rime-data-*.zip` |
| Mozc's dictionary | `android/app/res-bundle/download-bundles.py` | `android/app/res-bundle/` |

Scripts write their test, perf and release outputs to the running task's folder,
`~/scratch/SebType/<issue>/` (`TASK_OUT` in `tools/lib.sh`): run them as `ISSUE=211 <script>`. Without
`ISSUE` the folder is named after the checkout's folder. Caches, the Linux setup's RPMs and Chinese data
zip included, go to `~/scratch/SebType/cache/` (`SCRATCH` in `tools/lib.sh`), shared by every worktree.
Nothing goes to `/tmp` or `~/.cache`, on either machine.

`android/release.sh` builds the release from main and publishes it ([install.md](install.md)).

### PCs

| Command | Builds |
|---|---|
| `linux/build.sh` | SebType's Linux input method RPM: the Fcitx5 add-on over `core/` and Mozc's library from `engines/mozc`, in a pinned Fedora container; it runs the core's unit tests |
| `linux/build-librime.sh` | SebType's librime RPMs (with its plugins) from `engines/librime`, in the same container |
| `pc/configurator/build.sh` (`cargo build --release` in `pc/configurator`) | the Configurator and its unit tests' executable; `tools/build.sh` runs it on yanglab16 |
| `pwsh pc/windows/mozc/build.ps1`, `pc/windows/rime/build.ps1`, `windows/build.ps1` | Mozc's DLL, SebType's librime and the text service, on Windows; CI (`.github/workflows/windows-setup.yml`) builds them with SebType's installer |

`pc/linux/setup-ime.sh` builds what it installs itself ([pc/linux/README.md](../pc/linux/README.md)).

## Testing

| Command | What it checks |
|---|---|
| `android/test/emulator.sh` | The full emulator suite (below) |
| `android/test/typing.sh` | The instrumented typing tests on the emulator |
| `android/test/privacy.sh` | The release APK's manifest and dex, and its install on the emulator |
| `android/test/build.sh` | The build's caches and that release builds are reproducible |
| `android/test/incognito-phone.sh` | Incognito on a phone |
| `android/test/emulator-pick.sh` | `android/emulator.sh`'s queue, with stub locks |
| `SEBTYPE_PACKAGE=dev.sebb.sebtype.next android/test/emulator.sh` | The same checks on the new keyboard (next/, #191); those for what it doesn't have yet SKIP with the stage that brings it |
| `android/emulator.sh -- android/test/compare-screens.py TODAY_APK NEW_APK FIELD_APK OUTDIR` | Screenshots of today's keyboard and the new one side by side, light and dark, for judging the look |
| `android/build.sh unit-tests` | The unit tests of the app and `next/` (on yanglab16) |
| `android/test/english/run.sh` | English quality next to pristine AOSP, on yanglab16, twice ([2026-11-15-english](perf/2026-11-15-english.md)) |
| `data/en-dict/test.sh`, `data/rime/bench/bench.sh` | The English list's rebuild and benchmark; the Chinese data's accuracy |
| `linux/build.sh` | The core's unit tests (`core/test/`: switching, Shift tap, 简/繁, あ ⇄ ア, popups, paging), in the RPM build |
| `linux/test-parallel-build.sh` | Two RPM builds from different checkouts at once each package their own code (#305) |
| `pc/linux/test-setup-ime.sh` | `setup-ime.sh` on a fake fresh account, and SebType's input method in private Fcitx5s ([pc/linux/README.md](../pc/linux/README.md)) |
| `pc/configurator/test.sh` | The Configurator in nested sessions |
| `pc/windows/setup/test-tcsbackend.sh` | SebType's installer and input methods on TCSBackEnd ([pc/windows/README.md](../pc/windows/README.md)) |
| `pc/windows/setup/test-unsynced.ps1` | Uninstall and language removal keep the words their sync couldn't send, on a Windows PC ([pc/windows/README.md](../pc/windows/README.md)) |

Each writes one line per check to a results file under `~/scratch/SebType/<issue>/`, and its logs next to it.

### Which checks a run takes

A PR runs the checks for what it changed; the full suite (40–60 minutes on an emulator) runs for a
release. `SEBTYPE_CHECKS` picks them by name prefix, comma-separated, from the names in the results:

```
SEBTYPE_CHECKS=settings-japanese,incognito android/test/emulator.sh
```

That runs those checks and what they need: always the build, the install beside FUTO Keyboard, the
locale, SebType enabled and the test field app; and the earlier `android/test/chinese.py` checks a named one
depends on (its `needs`, so `SEBTYPE_CHECKS=ranh` also runs `first-install`). The settings checks (`android/test/settings.py`) declare no such needs: a settings
check that relies on Chinese being set up runs with `first-install` named too.

Timing checks (`settings-smooth-scrolling` here; `round1-rime-p95` in
`pc/windows/setup/test-tcsbackend.sh`) measure
speed, so they run only in the final performance run (#54, Decisions #2 2026-11-11), with `PERF_RUN=1`
(`-PerfRun` for the PowerShell scripts). Without it they write no result line, unless `SEBTYPE_CHECKS` names
one: then it reports SKIP and says why. `android/perf/perf.sh` is a measurement of its own, run only then too.

### The emulator

SebType's device tests (`android/test/emulator.sh`, `typing.sh`, `privacy.sh`, `android/perf/perf.sh`) run on one headless emulator on nobara-pc, one run at a time: two
emulators ran the PC out of memory (Decisions #2, #170). `android/emulator.sh` queues each run for it:

| AVD | Serial | Guest RAM | Lock |
|---|---|---|---|
| `guide35` | `emulator-5554` | 2.5 GB | `/tmp/agent-locks/devices/emulator-guide35.lock` |

It holds that lock for the whole device part of the run, so no other run reinstalls SebType in the
middle of it; `android/test/emulator-pick.sh` checks the queue with stub locks, no emulator needed. If
the emulator isn't running it is started headless, and the run waits until it has settled (about 2
minutes after a cold boot). The run that started it stops it when its command ends, unless another run
waits in the lock's queue: then the last run of that queue stops it (#194). An idle emulator holds about
1 GB of RAM and swap. An emulator that `emulator.sh` didn't start (one started by hand or by another
project) is left running. Other projects' scripts (SebChat) that need it start it themselves. On the
emulator it also turns on `hide_error_dialogs`: under load an app can be slow enough to get an "isn't
responding" dialog, which covers the screen and fails every UI check after it. With the setting on,
Android closes that app instead. `ANDROID_SERIAL=<serial>` picks the device
instead, a phone included.

Once it holds the lock, `android/test/emulator.sh` sets the emulator's language list to `en-US` alone
(`android/test/set-locale`, the way Settings does it; its `locale` check logs the list it replaced). A fresh
install starts SebType's languages from that list, and other tasks change it.

The AVD is Android 15 Google APIs x86_64 (`system-images;android-35;google_apis;x86_64`), Pixel 7, with
root (`su`) and ARM translation for SebType's arm64 APK. Its `config.ini` says `hw.ramSize=2G`, but the
emulator raises that to 2560 MB, its minimum for this device and Android version. It uses about 3–4 GB
of the PC's memory at its peak. To start it by hand:

```
systemd-run --user --collect --unit=emulator-guide35 ~/Android/Sdk/emulator/emulator -avd guide35 -port 5554 \
  -no-window -no-audio -no-snapshot-load -no-boot-anim
adb -s emulator-5554 emu kill   # stops it
```

Start the emulator as a unit of the user's systemd, as `emulator.sh` does, not from a shell: one started
from an agent's shell (even with `setsid` or `&`) stops when that agent's session ends.

Take its lock while you use it (`devq -m <minutes> /tmp/agent-locks/devices/emulator-guide35.lock <command>`).

## Measuring size, memory and speed

Two scripts measure SebType the same way every time (#45). They run in the final performance run of a
batch (#54), after its clean-up, not before every merge. The budgets in Decisions #2 are provisional.
Each final run's report is in `docs/perf/`; the first, next to other IMEs, is
[2026-11-12](perf/2026-11-12.md), and Linux's SebType add-on (#190) is in [2026-11-15](perf/2026-11-15.md).

Next to other IMEs, the same way (#54), with a 12-minute mixed-typing run (`SOAK_MIN`) for leaks and crashes:

- Android: `android/perf/perf.sh --compare` (another installed keyboard: `IME_PKG`, `IME_ID`, `KEY_ROWS`,
  `KEY_SPACE`) and `--soak` (SebType as installed); `--compare-device` and `--soak-device` on a phone.
- Linux: `pc/linux/compare.sh` (SebType's input method next to Fedora's fcitx5-rime and fcitx5-mozc, each in a private Fcitx5).
- Windows: `ONLY=compare pc/windows/setup/test-tcsbackend.sh` (Microsoft Pinyin and Japanese IME;
  `COMPARE_IMES` narrows it).

### Android: `android/perf/perf.sh`

```
android/perf/perf.sh                     # builds the release APK, then measures on a free emulator (see The emulator, above)
APK=path/to.apk android/perf/perf.sh     # measures an APK you already built
ANDROID_SERIAL=<serial> android/perf/perf.sh   # any other device; the only way to run it on a phone
```

It reinstalls SebType, so everything SebType learned on that device is lost. It then types into its
own small test field (`android/perf/PerfField.java`) with `monkey` taps, and puts the previous keyboard
back at the end. The device needs Android 14 or newer and must run arm64 apps. It takes about 20
minutes. While it runs it holds the device's devq lock, shared by all projects:
`/tmp/agent-locks/devices/emulator-<AVD>.lock`, or on a phone the lock of the PC it is plugged
into (`nobara-pc.lock`), which other projects take for the phone too.

What it measures:

| Metric | How |
|---|---|
| APK size, biggest entries | the APK file; shrunk resource names mapped back with `aapt2` |
| Installed size | `du` of the app's code, internal and external data (root shell only: emulator) |
| Memory | `dumpsys meminfo` total PSS: idle, after typing in each language, in 日 alone (only Mozc loaded: past Rime's idle stop), with all three engines loaded (fast typing right after 中 and 日), idle again once unused engines unloaded (`IDLE_UNLOAD_S`, default 200 s, just over the app's 3 minutes), peak during the first Chinese setup. Each breakdown is kept in `run/meminfo-<point>.txt` |
| Keyboard open | until the keyboard's first frame on screen: first open after install (from the field's first frame), warm (from a tap on the field after hiding the keyboard), cold (from the keyboard's process start, switching back from Gboard or FUTO with SebType stopped) |
| Per key, per language | Perfetto: the keyboard's touch dispatch (handling), the field's next frame after its text changed (key → text), the frame that last redrew the candidate bar (key → candidates), the keyboard's last frame before the next key (key → idle), and the transformer thread's CPU time |
| Jank | `dumpsys gfxinfo` and the frame timeline while typing 10 keys a second, in an empty field and in a 20,000-character one |
| Every key arrives | the same 10 keys a second: the keyboard must get every tap (Perfetto), and the field's text (a UI dump) must be what was tapped, ignoring case. The check fails naming each missing, extra or out-of-order character with its position, kept in `run/<fast\|long>.diff`. A missing touch means the taps' injection lost it, not the keyboard; autocorrect can put back a key the keyboard never got, so touches are checked first |
| Chinese first-run setup | the app's own timing of installing the bundled data and Rime's check, after the first switch to 中, and how many tables or prisms were compiled on the device (should be 0; root shell only) |

English runs with FUTO's transformer on (the default), Chinese with Rime and the bundled data (rime-ice's schema, 白霜's dictionary), Japanese with
Mozc. Each typing set runs `RUNS` times (default 3), each time in a fresh test field; the table
gives the median and the 95th percentile over all keys. English types after one keyboard restart,
because the transformer can stay off in the first process after install.

Results, in `~/scratch/SebType/<issue>/perf/` (or `PERF_OUT`): `perf.md` (the table), `results.txt`
(one line per check), and traces and logs in `run/`. Open a `.pftrace` in https://ui.perfetto.dev to see where
the time goes.

No typed text is recorded: the test field logs only its text length, and timing comes from
framework trace slices and frame timelines; the trace records no logs.

Notes:

- **Engines load on demand (#56).** English's transformer loads once the first letter is typed (an
  empty field gets the dictionary's suggestions until then) and unloads when the language switches
  or after 3 minutes without a prediction (`ENGINE_IDLE_MS`). Rime stops 3 minutes after 中 was last
  in use, or after a background setup nobody types into. Mozc unloads 3 minutes after 日 was last in
  use, and the next 日 field loads it again. So "after typing 中" has no transformer in it, and "after
  fast typing EN" (right after 中 and 日) is the most that is ever loaded at once.
- **Idle is read once the keyboard settled**, 30 s after it opens (`SETTLE_S`). A new process reads
  about 25 MB higher for its first seconds (start-up Java garbage not yet collected): on the phone
  152 MB 3 s after the first open, 124 MB at 30 s.
- **The emulator gives relative numbers only.** It runs SebType's arm64 code through translation
  and renders in software. Compare an emulator run with another emulator run, never with the phone.
- **Key positions** come from SebType's uniform layout at the default keyboard height. Each typing
  check verifies the text length afterwards and fails with "taps missed the keys" if they didn't land.

#### On the phone

The phone is shared with its owner: run this only when they agree, with the phone unlocked and
idle. Turn on USB or wireless debugging, check that `adb devices` lists it, then run
`ANDROID_SERIAL=<serial> android/perf/perf.sh`. SebType is reinstalled, so anything it learned on the phone
is lost; export its settings first if that matters. Gboard must be enabled for the cold-open check.
The installed-size row needs root, so on the phone it is SKIP; Settings → Apps → SebType → Storage
shows the same numbers. Without root, the phone can't count what Rime compiled during setup either;
the emulator run shows it.

The phone's screen must stay on the test field for the whole run. Each set of taps checks that
it does, and fails naming the window that came to the front. In #76, another project's agent opened
its app on the phone during a run (it took a different lock), and the rest of the taps went into that
app. The failure looked like SebType had come back in the wrong language.

##### Phone results (Nothing A001, Android 16, #56's branch, 2026-11-11)

Against the budgets in Decisions #2. All phases passed; the full tables, before and after, are on #56's PR.

| Budget | Phone | Met |
|---|---|---|
| APK ≤ 150 MB | 105 MB | yes |
| PSS idle ≤ 110 MB | 103 MB at first open, 94 MB in a fresh process, 123 MB idle after using all three | first open, fresh |
| PSS: EN ≤ 250 MB, 中 and 日 ≤ 150 MB | EN 214 MB, 中 128 MB, 日 150 MB alone (156 MB right after 中, with Rime still loaded) | yes, 日 alone |
| PSS with all three ≤ 320 MB | 242 MB | yes |
| No Rime deploy on the phone | Chinese set up in 1362 ms (install 729 ms); files compiled not readable without root | emulator: 0 compiled |
| Key handling p95 ≤ 8 ms | EN 10, 中 8, 日 8 ms | 中, 日 |
| Key → text p95 ≤ 50 ms (日 ≤ 60) | EN 25, 日 52 ms | yes |
| Key → candidates p95 ≤ 100 ms | EN 85, 中 64, 日 53 ms | yes |
| Warm open ≤ 150 ms, cold ≤ 1 s | warm 67 / 75 ms, cold 455 / 501 ms (median / p95) | yes |
| 10 keys a second: ≤ 1 frame in 500 late from the app, every character arrives | 88 of 88 arrived; 32 of 846 frames late from the app (20,000-character field: 63 of 840); the run before, 1 of 699 | no |
| 0 crashes | 0 | yes |

### PC (Linux): `pc/linux/perf.sh`

```
pc/linux/perf.sh                    # RUNS (default 5) repeats each typing set
```

It never touches the running Fcitx5 session:

- **Rime with rime-ice:** times each key followed by reading the candidate menu (as Fcitx5 does)
  through SebType's librime, on a temporary copy of `~/.local/share/fcitx5/rime` (or `RIME_DIR`), deleted on
  exit. Then it deletes the copy's `build/` and times a full deploy with its peak memory.
- **Mozc:** loads SebType's `libsebtype-mozc.so` into Python, with its own empty profile, as the add-on runs
  it (`pc/linux/perf-mozc.py`): suggestions per key, and conversion with Space. Each word is
  reverted, so nothing is learned.
- **Memory:** RSS, PSS and swapped-out size of the running `fcitx5` (Mozc included), read from
  `ps` and `/proc`; skipped while the session runs another input method than SebType's.

It needs gcc, python3, bwrap, and librime with librime-lua; it unpacks SebType's input method and librime
(built first when they aren't cached) and times their Rime and Mozc. It compiles against
`engines/librime`'s headers. Results: `~/scratch/SebType/<issue>/pc-perf.md` and
`pc-perf-results.txt`.

### Build times on yanglab16 and nobara-pc (#225)

Measured on 2026-11-15 from nobara-pc. "yanglab16" includes the rsync there and copying the result back
("build" is the script's own time on yanglab16); nobara-pc's builds ran under the caps above, at nice 19,
beside other agents' builds.

| Build | yanglab16: build / in all | nobara-pc |
|---|---|---|
| `android/build.sh debug`, first build there (empty caches, the SDK just installed) | 62 s / 74 s | |
| debug, a new checkout copy (shared caches warm) | 81 s / 101 s; 65–106 s build with the lab's load at 55–60 (#250) | 14–15 s with warm caches (#58), 196 s measured in #223, 41 s in #250 |
| debug, nothing changed | 19 s in all | 7–8 s (#58) |
| debug, one Kotlin file changed | 27 s / 32 s | 17–31 s (#58, at 8 threads) |
| `android/build.sh release`, first build there | 128 s / 135 s | 298 s from the caches |
| release, nothing changed | 15 s / 23 s | 8–17 s (#58) |
| `linux/build.sh`, first build (Mozc from scratch, the builder image too) | 87 s / 120 s | 490 s (#58, at 8 threads) |
| `linux/build.sh`, nothing changed | 30 s in all | 11 s (#58) |

On nobara-pc a build also waits for the lock behind other agents' builds: 2 and 9 minutes for the two
measured here.

`android/test/build.sh` checks these caches on yanglab16 (#250): a new checkout copy's debug build stays
within 120 s and doesn't run Bazel (Mozc comes from Gradle's cache), and a changed Kotlin file compiles
incrementally. Most of a new copy's time is CMake configuring and building the native code, its compiles
from sccache, on the NAS (14–21 s per task under the lab's load). Until #250 a new copy also ran Bazel,
because `MODULE.bazel.lock`, which Bazel writes and git ignores, was an input of the Mozc task: copies
where Bazel had run never matched the cache.

Built both ways from the same commit, the RPMs have the same files, byte for byte; their headers differ in
build host and time, as two local builds do. The release APKs have the same entries except four:
`libjni_latinime.so` and `librime-jni.so` (#223), and `rime-data.zip` and `baseline.prof` (#229).

### Build and test times (#58)

Measured on nobara-pc (16 threads, 15 GB) on 2026-11-10, before Mozc and Rime were built from source (#186), with other agents' work running beside, so
numbers vary by about ±30 %. "Build" is `android/build.sh`'s own time, which it now prints apart from
the wait for the build lock; "peak" is the summed memory of the build's processes (Gradle, the Kotlin
daemon, clang, aapt2, R8). Since #250 `android/test/build.sh` checks the cache and reproducibility parts
on yanglab16, not here.

| `android/build.sh …` | Before | After |
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
| release, one Kotlin file changed | 163 s | 91–101 s (R8 shrinking the whole app is ~80 s of it; since #223 a release compiles all its Kotlin) |
| test-x86_64, clean | 130 s | 46 s |
| test-x86_64, one Kotlin file changed | 65 s | 27–29 s |
| peak memory, debug / release | 4.5 GB / 3.8 GB | 4.2 GB / 4.3–5.5 GB |

| Other builds and tests | Before | After |
|---|---|---|
| Mozc's Linux build (now in `linux/build.sh`), nothing changed / after a source change / first build | 11 s / 323 s / 490 s | unchanged |
| `pc/linux/test-setup-ime.sh` | 15 s | unchanged (mostly Fcitx5 and a Rime deploy starting) |
| `android/test/privacy.sh` (release rebuild + checks) | 13 s | 8 s |
| `android/test/typing.sh` (test APKs + 4 tests on the emulator) | 22 s build + about 55 s device | 7 s build, 58 s in all |
| `android/test/emulator.sh` | 12 s build + about 7 min device | 7 s build, 338 s in all |

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
  Each build starts its own sccache server with `SCCACHE_BASEDIRS` set to the checkout's root, and
  `-ffile-prefix-map` keeps the checkout's path out of the objects, so objects are shared between
  worktrees without one worktree's paths ending up in another's library. Its preprocessor cache stays
  off (`SCCACHE_DIRECT=false`, #318): it keyed entries by those relative paths but checked the headers
  at the absolute paths of the worktree that stored them, so a worktree that changed a header in
  `core/include` handed main its objects compiled against that header (the new keyboard's first-start
  crash), with depfiles that made ninja watch that worktree's headers. `android/build.sh` rebuilds a
  CMake folder whose ninja deps still name another checkout's files; `android/test/build.sh`'s
  `sccache-checkouts` check runs here.
- **Configuration cache**: Gradle reuses the configured build (nothing changed 11 → 6 s, one Kotlin file
  24 → 17 s). `build.gradle`'s git calls go through `providers.exec`, which it allows.

Release builds stay reproducible: on yanglab16, a release built with no build cache and with sccache
compiling everything again in one checkout and one built from the caches in another are the same file, and
so are two signed on nobara-pc (`android/test/build.sh`; with `SEBTYPE_BUILD_HOST=local` also one built on
nobara-pc). Before, they differed
between checkouts (folder name in the dex, checkout path in `libjni_latinime.so`; #223: AGP's per-checkout
`.cxx/<hash>/` folder, and Rime's third-party builds in it, in the libraries' debug info and so their
build IDs) and between machines (#229: the NDK's path; Rime's recorded file times and the zip's local
times in `rime-data.zip`; Compose code from an incremental Kotlin compile, so a release compiles Kotlin
from scratch; R8 marking one method differently in `baseline.prof` with several threads, so it runs on one: always
with 48, and in one of four yanglab16 builds with 4 (#250); a release from scratch there took 143–155 s with one thread and 119–182 s with 4, so the cost is lost in the lab's load; and
Gradle signing a local release but `apksigner` a remote one, which aligned the entries differently).

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
