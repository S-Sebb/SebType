#!/usr/bin/env bash
# Runs SebType's instrumented typing tests (android/app/src/androidTest/java/.../LiveSpacingTests) on a free emulator (android/emulator.sh),
# typing through the live keyboard with fresh-install settings.
# One line per test in /tmp/sebtype/test-typing-results.txt; logs next to it. Exit 0 only if all pass.
# The debug build replaces any installed SebType (same package); test-emulator.sh reinstalls the release.
set -uo pipefail
cd "$(dirname "$0")/../.."

out=/tmp/sebtype; mkdir -p "$out"
results=$out/test-typing-results.txt; : > "$results"
adb=${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools/adb
tests=( # LiveSpacingTests methods
  spaceThenPeriodStaysPut pickedSuggestionThenPeriod sentenceThenCapital storedFutoDefaultMigratesOnce # #39
)

# Preflight
[[ -x $adb ]] || { echo "preflight: adb missing"; exit 1; }
mapfile -t apks < <(android/build.sh test-x86_64 2> "$out/test-typing-build.log" | tail -2)
[[ ${#apks[@]} == 2 && -f ${apks[0]} && -f ${apks[1]} ]] ||
  { echo "preflight: build failed, see $out/test-typing-build.log"; exit 1; }

device_run() {
  local t serial=$ANDROID_SERIAL
  [[ $("$adb" -s "$serial" shell getprop ro.product.cpu.abilist) == *x86_64* ]] || { echo "FAIL device: $serial isn't x86_64"; return; }
  "$adb" -s "$serial" uninstall dev.sebb.sebtype >/dev/null
  "$adb" -s "$serial" uninstall org.futo.inputmethod.latin.tests >/dev/null
  "$adb" -s "$serial" install "$app" >/dev/null && "$adb" -s "$serial" install "$testapk" >/dev/null ||
    { echo "FAIL install"; return; }
  for t in $names; do
    if timeout 300 "$adb" -s "$serial" shell am instrument -w \
        -e class "org.futo.inputmethod.latin.LiveSpacingTests#$t" \
        org.futo.inputmethod.latin.tests/androidx.test.runner.AndroidJUnitRunner > "$out/test-typing-$t.log" 2>&1 &&
        grep -q 'OK (1 test)' "$out/test-typing-$t.log"; then echo "PASS $t"
    else echo "FAIL $t: see $out/test-typing-$t.log"; fi
  done
  "$adb" -s "$serial" uninstall org.futo.inputmethod.latin.tests >/dev/null
  "$adb" -s "$serial" shell ime reset >/dev/null
}
export -f device_run; export adb out app=${apks[0]} testapk=${apks[1]} names="${tests[*]}"
android/emulator.sh -P 5 -w 1800 -m 10 -n "sebtype test-typing" -- bash -c device_run 2> "$out/test-typing-emulator.log" |
  grep --line-buffered -E "^(PASS|FAIL)" | tee -a "$results"
[[ -s $results ]] || echo "FAIL device: no results: $(head -1 "$out/test-typing-emulator.log")" | tee -a "$results"

! grep -qv '^PASS' "$results"
