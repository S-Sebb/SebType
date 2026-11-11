#!/usr/bin/env bash
# The incognito checks of sebtype/test-settings.py (#31) on the user's phone (ANDROID_SERIAL, default the
# Nothing A001), under its lock. It installs SebType fresh, which wipes what SebType learned there, types
# made-up words only and never touches the screen lock. Afterwards SebType and the test field are
# uninstalled, Gboard is the keyboard again and the home screen shows. The clipboard check needs a root
# shell, so it SKIPs on a phone.
# One line per check in /tmp/sebtype/test-incognito-phone/results.txt; logs and screenshots next to it.
# Exit 0 only if nothing fails.
set -uo pipefail
cd "$(dirname "$0")/.."

out=/tmp/sebtype/test-incognito-phone; rm -rf "$out"; mkdir -p "$out"
results=$out/results.txt; : > "$results"
sdk=${ANDROID_HOME:-$HOME/Android/Sdk}
adb=$sdk/platform-tools/adb
serial=${ANDROID_SERIAL:-00193353J000665}
lock=/tmp/agent-locks/devices/nothing-a001.lock
gboard=com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME

# Preflight
[[ -x $adb ]] || { echo "preflight: adb missing in $sdk"; exit 1; }
[[ $("$adb" -s "$serial" get-state 2>/dev/null) == device ]] || { echo "preflight: phone $serial not connected"; exit 1; }
apk=$(sebtype/build.sh release 2> "$out/build.log" | tail -1)
[[ -f $apk ]] || { echo "preflight: release build failed, see $out/build.log"; exit 1; }
field_apk=$out/field.apk
sebtype/perf/build-field.sh "$field_apk" > "$out/field.log" 2>&1 && [[ -f $field_apk ]] ||
  { echo "preflight: test field build failed, see $out/field.log"; exit 1; }

phone_run() {
  "$adb" -s "$serial" shell input keyevent KEYCODE_WAKEUP
  # The PIN is the user's: a locked phone stops the run instead.
  if "$adb" -s "$serial" shell dumpsys window | grep -q 'mDreamingLockscreen=true\|isKeyguardShowing=true\|mShowingLockscreen=true'; then
    echo "FAIL phone-unlocked: the phone is locked; unlock it and run again"; return
  fi
  "$adb" -s "$serial" uninstall dev.sebb.sebtype >/dev/null
  if "$adb" -s "$serial" install "$apk" >/dev/null && "$adb" -s "$serial" install -r "$field_apk" >/dev/null; then
    "$adb" -s "$serial" shell ime enable dev.sebb.sebtype/org.futo.inputmethod.latin.LatinIME >/dev/null
    PATH=$(dirname "$adb"):$PATH CHECKS=incognito timeout 2400 \
      python3 -I sebtype/test-settings.py "$serial" "$results" "$out" > "$out/run.log" 2>&1 ||
      echo "FAIL incognito-run: ended early, see $out/run.log"
  else
    echo "FAIL install"
  fi
  "$adb" -s "$serial" uninstall dev.sebb.sebtype >/dev/null
  "$adb" -s "$serial" uninstall dev.sebb.sebtype.perffield >/dev/null
  "$adb" -s "$serial" shell ime set "$gboard" >/dev/null
  "$adb" -s "$serial" shell input keyevent KEYCODE_HOME
  [[ $("$adb" -s "$serial" shell settings get secure default_input_method | tr -d '\r') == "$gboard" ]] &&
    echo "PASS phone-restored: SebType uninstalled, Gboard selected, home screen" ||
    echo "FAIL phone-restored: the keyboard is $("$adb" -s "$serial" shell settings get secure default_input_method)"
}
export -f phone_run; export adb serial apk field_apk results out gboard
devq -P 1 -w 1800 -m 30 -n "sebtype #31 incognito on the phone" "$lock" bash -c phone_run >> "$results"
[[ -s $results ]] || echo "FAIL device: no results (lock timeout? devq status $lock)" >> "$results"
cat "$results"

! grep -qv '^\(PASS\|SKIP\)' "$results"
