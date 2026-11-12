# Testing on the emulators

## Which checks a run takes

A PR runs the checks for what it changed; the full suite (40–60 minutes on an emulator) runs for a
release. `SEBTYPE_CHECKS` picks them by name prefix, comma-separated, from the names in the results:

```
SEBTYPE_CHECKS=settings-japanese,incognito android/test/emulator.sh
```

That runs those checks and what they need: always the build, the install beside FUTO Keyboard, the
locale, SebType enabled and the test field app; and the earlier `test-chinese.py` checks a named one
depends on (its `needs`, so `SEBTYPE_CHECKS=ranh` also runs `first-install`). The settings checks (`test-settings.py`) declare no such needs: a settings
check that relies on Chinese being set up runs with `first-install` named too.

Timing checks (`settings-smooth-scrolling` here; `round1-rime-p95` in
`pc/windows/setup/test-tcsbackend.sh`; `mozc-speed-and-dictionary` in `pc/windows/mozc/test.ps1`) measure
speed, so they run only in the final performance run (#54, Decisions #2 2026-11-11), with `PERF_RUN=1`
(`-PerfRun` for the PowerShell scripts). Without it they write no result line, unless `SEBTYPE_CHECKS` names
one: then it reports SKIP and says why. `android/perf/perf.sh` is a measurement of its own, run only then too.

## The emulator

SebType's device tests (`android/test/emulator.sh`, `test-typing.sh`, `test-privacy.sh`, `perf.sh`,
`android/rime/smoke-test.sh`) run on one headless emulator on nobara-pc, one run at a time: two
emulators ran the PC out of memory (Decisions #2, #170). `android/emulator.sh` queues each run for it:

| AVD | Serial | Guest RAM | Lock |
|---|---|---|---|
| `guide35` | `emulator-5554` | 2.5 GB | `/tmp/agent-locks/devices/emulator-guide35.lock` |

It holds that lock for the whole device part of the run, so no other run reinstalls SebType in the
middle of it; `android/test/emulator-pick.sh` checks the queue with stub locks, no emulator needed. If
the emulator isn't running it is started headless, and the run waits until it has settled (about 2
minutes after a cold boot). It then stays up: other projects (SebChat) use it through the same lock and
expect it running. On the emulator it also turns on `hide_error_dialogs`: under load an app can be slow
enough to get an "isn't responding" dialog, which covers the screen and fails every UI check after it.
With the setting on, Android closes that app instead. `ANDROID_SERIAL=<serial>` picks the device
instead, a phone included.

Once it holds the lock, `test-emulator.sh` sets the emulator's language list to `en-US` alone
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
