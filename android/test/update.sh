#!/usr/bin/env bash
# The update check and install (#422) on SebType's emulator (android/emulator.sh), with a debug build and a
# made-up release: a debug build asks only the URL in its files/update-test-url, so release builds keep no
# test hook. android/test/update.py serves the release's JSON (v9.9.9) with the debug APK as its asset on this
# PC, reached as the emulator's own 127.0.0.1 through adb reverse, and checks: About asks to notify, "Check
# for updates" finds 9.9.9, the home screen's card, the request sends nothing but itself, the daily job's
# notification, and that tapping it leads to "Install unknown apps", then, allowed, to Android's install
# prompt. Screenshots update-*.png next to the results. SebType is uninstalled before and after.
# One line per check in ~/scratch/SebType/<issue>/test-update/results.txt; logs next to it. Exit 0 only if all pass.
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh

out=$TASK_OUT/test-update; mkdir -p "$out"
results=$out/results.txt; : > "$results"
adb=$ANDROID_HOME/platform-tools/adb

# Preflight
[[ -x $adb ]] || { echo "preflight: adb missing in $ANDROID_HOME"; exit 1; }
apk=$(android/build.sh debug 2> "$out/build.log" | tail -1)
[[ -f $apk ]] || { echo "preflight: debug build failed, see $out/build.log"; exit 1; }

PATH=$(dirname "$adb"):$PATH timeout 1500 android/emulator.sh -P 4 -w 1800 -m 8 -n "sebtype #422 test-update" -- \
  python3 -I android/test/update.py "$apk" "$results" "$out" > "$out/update.log" 2>&1
rc=$?
cat "$results"
[[ -s $results ]] || echo "FAIL update: no checks ran (exit $rc; $(tail -1 "$out/update.log"))" | tee -a "$results"
! grep -qv '^PASS' "$results"
