# Testing on the emulators

SebType's device tests (`sebtype/test-emulator.sh`, `test-typing.sh`, `test-privacy.sh`, `perf.sh`,
`rime-android/smoke-test.sh`) run on one of two headless emulators on nobara-pc, so two of them can
run at once (Decisions #2). `sebtype/emulator.sh` picks one for each run:

| AVD | Serial | Guest RAM | Lock |
|---|---|---|---|
| `guide35` | `emulator-5554` | 2.5 GB | `/tmp/agent-locks/devices/emulator-guide35.lock` |
| `guide35b` | `emulator-5580` | 2.5 GB | `/tmp/agent-locks/devices/emulator-guide35b.lock` |

It queues for the emulator whose lock is free (a running one first), else the one with the shorter
queue. If that turn doesn't come within 5 seconds (another run took the lock first, or both are
held), it queues for the other one too and runs on whichever comes first (#140);
`sebtype/test-emulator-pick.sh` checks that choice with stub locks, no emulator needed. It holds that lock for the whole device part of the run, so no other run reinstalls SebType in the
middle of it. An emulator that isn't running is started headless, and the run waits until it has
settled (about 2 minutes after a cold boot). `guide35` then stays up: other projects (SebChat) use it
through the same lock and expect it running. `guide35b` is stopped again when the run that started it
ends. On an emulator it also turns on `hide_error_dialogs`: under load an app can be slow enough to get
an "isn't responding" dialog, which covers the screen and fails every UI check after it. With the
setting on, Android closes that app instead. `ANDROID_SERIAL=<serial>` picks the device instead, a
phone included.

Once it holds the lock, `test-emulator.sh` sets the emulator's language list to `en-US` alone
(`sebtype/set-locale`, the way Settings does it; its `locale` check logs the list it replaced). A fresh
install starts SebType's languages from that list, and other tasks change it.

Both AVDs are Android 15 Google APIs x86_64 (`system-images;android-35;google_apis;x86_64`), Pixel 7,
with root (`su`) and ARM translation for SebType's arm64 APK. Their `config.ini` says `hw.ramSize=2G`, but
the emulator raises that to 2560 MB, its minimum for this device and Android version. Each emulator
uses about 3–4 GB of the PC's memory at its peak, so two of them leave little room for a build. That's
why `guide35b` runs only while a test needs it. Timing checks (`settings-smooth-scrolling`, `perf.sh`)
run slower while the other emulator is busy. The smoothness check keeps the best of three tries, and if
that is still over its limits while another emulator's lock is held, it reports SKIP with the numbers
instead of FAIL. Compare `perf.sh` numbers only between runs with the other emulator idle. To start one by hand:

```
systemd-run --user --collect --unit=emulator-guide35b ~/Android/Sdk/emulator/emulator -avd guide35b -port 5580 \
  -no-window -no-audio -no-snapshot-load -no-boot-anim
adb -s emulator-5580 emu kill   # stops it
```

Start an emulator as a unit of the user's systemd, as `emulator.sh` does, not from a shell: one started
from an agent's shell (even with `setsid` or `&`) stops when that agent's session ends.

Take its lock while you use it (`devq -m <minutes> /tmp/agent-locks/devices/emulator-guide35b.lock <command>`).

To create `guide35b` again on another PC: `avdmanager create avd -n guide35b -k
"system-images;android-35;google_apis;x86_64" -d pixel_7`, then copy `guide35`'s `config.ini` into
`~/.android/avd/guide35b.avd/`.
