# Measuring SebType's size, memory and speed

Two scripts measure SebType the same way every time (#45). Run them before merging changes to the
engines, dictionaries or the keyboard UI, and compare against the baseline on #45.

## Android: `sebtype/perf.sh`

```
sebtype/perf.sh                     # builds the release APK, then measures on the first adb device
APK=path/to.apk sebtype/perf.sh     # measures an APK you already built
ANDROID_SERIAL=<serial> sebtype/perf.sh
```

It reinstalls SebType, so everything SebType learned on that device is lost. It then types into its
own small test field (`sebtype/perf/PerfField.java`) with `monkey` taps, and puts the previous keyboard
back at the end. The device needs Android 14 or newer and must run arm64 apps. It takes about 15
minutes. While it runs it holds the devq lock `/tmp/agent-locks/sebtype/emulator.lock`, or
`phone.lock` on a phone.

What it measures:

| Metric | How |
|---|---|
| APK size, biggest entries | the APK file; shrunk resource names mapped back with `aapt2` |
| Installed size | `du` of the app's code, internal and external data (root shell only: emulator) |
| Memory | `dumpsys meminfo` total PSS: idle, after typing in each language, peak during the Rime deploy |
| Keyboard open | ImeTracker log lines in the trace: first open after install, warm (hide and tap the field), cold (switch back from Gboard or FUTO with SebType stopped) |
| Per key, per language | Perfetto: the keyboard's touch dispatch (handling), the field's next frame after its text changed (key → text), the keyboard's last frame before the next key (key → candidates), and the transformer thread's CPU time |
| Jank | `dumpsys gfxinfo` and the frame timeline while typing 10 keys a second, in an empty field and in a 20,000-character one |
| Rime first deploy | time until rime-ice's compiled tables stop changing after the first switch to 中 |

English runs with FUTO's transformer on (the default), Chinese with Rime and rime-ice, Japanese with
Mozc. Each typing set runs `RUNS` times (default 3); the table gives the median and the 95th
percentile.

Results: `/tmp/sebtype/perf.md` (the table), `/tmp/sebtype/perf-results.txt` (one line per check),
and traces and logs in `/tmp/sebtype/perf/`. Open a `.pftrace` in https://ui.perfetto.dev to see where
the time goes.

No typed text is recorded: the test field logs only its text length, and timing comes from
framework trace slices, frame timelines and ImeTracker's log lines.

Notes:

- **The emulator gives relative numbers only.** It runs SebType's arm64 code through translation
  and renders in software. Compare an emulator run with another emulator run, never with the phone.
- **Key positions** come from SebType's uniform layout at the default keyboard height. Each typing
  check verifies the text length afterwards and fails with "taps missed the keys" if they didn't land.
- **rime-ice:** while the APK doesn't bundle rime-ice (#8), the script packs it with
  `tools/pack-rime-ice.sh` (no personal words) and pushes it into SebType's Rime folder.

### On the phone

The phone is shared with its owner: run this only when they agree, with the phone unlocked and
idle. Turn on USB or wireless debugging, check that `adb devices` lists it, then run
`ANDROID_SERIAL=<serial> sebtype/perf.sh`. SebType is reinstalled, so anything it learned on the phone
is lost; export its settings first if that matters. Gboard must be enabled for the cold-open check.
The installed-size row needs root, so on the phone it is SKIP; Settings → Apps → SebType → Storage
shows the same numbers.

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
