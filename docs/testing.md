# Testing on the emulators

SebType's device tests (`sebtype/test-emulator.sh`, `test-typing.sh`, `test-privacy.sh`, `perf.sh`,
`rime-android/smoke-test.sh`) run on one of two headless emulators on nobara-pc, so two of them can
run at once (Decisions #2). `sebtype/emulator.sh` picks one for each run:

| AVD | Serial | Guest RAM | Lock |
|---|---|---|---|
| `guide35` | `emulator-5554` | 2 GB | `/tmp/agent-locks/devices/emulator-guide35.lock` |
| `guide35b` | `emulator-5580` | 1.5 GB | `/tmp/agent-locks/devices/emulator-guide35b.lock` |

It takes the emulator whose lock is free (a running one first), else the one with the shorter queue,
and holds that lock for the whole device part of the run, so no other run reinstalls SebType in the
middle of it. An emulator that isn't running is started headless and stopped again when the run ends;
one that was already running is left running. Other projects (SebChat) use `guide35` through the same
lock. `ANDROID_SERIAL=<serial>` picks the device instead, a phone included.

Both AVDs are Android 15 Google APIs x86_64 (`system-images;android-35;google_apis;x86_64`), Pixel 7,
with root (`su`) and ARM translation for SebType's arm64 APK. To start one by hand:

```
~/Android/Sdk/emulator/emulator -avd guide35b -port 5580 -no-window -no-audio -no-snapshot-load -no-boot-anim &
adb -s emulator-5580 emu kill   # stops it
```

Take its lock while you use it (`devq -m <minutes> /tmp/agent-locks/devices/emulator-guide35b.lock <command>`).

To create `guide35b` again on another PC: `avdmanager create avd -n guide35b -k
"system-images;android-35;google_apis;x86_64" -d pixel_7`, then copy `guide35`'s `config.ini` into
`~/.android/avd/guide35b.avd/` and set `hw.ramSize=1536M`.
