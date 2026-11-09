#!/usr/bin/env bash
# Checks the SebType release APK and installs it on the local emulator next to stock FUTO Keyboard.
# One line per check in /tmp/sebtype/test-emulator-results.txt; logs next to it. Exit 0 only if all pass.
# Typing with SebType is checked by hand through T3's device tools (see the #5 PR).
set -uo pipefail
cd "$(dirname "$0")/.."

out=/tmp/sebtype; mkdir -p "$out"
results=$out/test-emulator-results.txt; : > "$results"
sdk=${ANDROID_HOME:-$HOME/Android/Sdk}
adb=$sdk/platform-tools/adb
bt=$(ls -d "$sdk"/build-tools/* | tail -1)
futo_apk=$out/futo-keyboard-0.1.30.apk
lock=/tmp/agent-locks/sebtype/emulator.lock

result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
check() { # name, command...; timeout T seconds (default 180)
  local name=$1; shift
  if timeout "${T:-180}" "$@" > "$out/test-emulator-$name.log" 2>&1; then result PASS "$name"
  else result FAIL "$name" "see $out/test-emulator-$name.log"; fi
}

# Preflight
[[ -x $adb ]] || { echo "preflight: adb missing in $sdk"; exit 1; }
serial=$("$adb" devices | awk '/^emulator-[0-9]+\tdevice/ {print $1; exit}')
[[ -n $serial ]] || { echo "preflight: no running emulator (start AVD guide35 or lossbench)"; exit 1; }
[[ $("$adb" -s "$serial" shell getprop ro.product.cpu.abilist) == *arm64-v8a* ]] ||
  { echo "preflight: emulator $serial can't run arm64 apps"; exit 1; }
apk=$(sebtype/build.sh release 2> "$out/test-emulator-build.log" | tail -1)
[[ -f $apk ]] || { echo "preflight: release build failed, see $out/test-emulator-build.log"; exit 1; }
[[ -f $futo_apk ]] || gh release download 0.1.30 -R futo-org/android-keyboard -p keyboard-0.1.30.apk -O "$futo_apk" ||
  { echo "preflight: can't download stock FUTO 0.1.30"; exit 1; }
echo "testing $apk on $serial"

badging=$("$bt/aapt2" dump badging "$apk")
check package-id grep -q "package: name='dev.sebb.sebtype'" <<<"$badging"
check app-label grep -q "application-label:'SebType'" <<<"$badging"
check arm64-only bash -c "[[ \$(unzip -Z1 '$apk' 'lib/*' | cut -d/ -f2 | sort -u) == arm64-v8a ]]"
check signed-sebtype bash -c "'$bt/apksigner' verify --print-certs '$apk' | grep -q 'CN=SebType'"

# Device checks hold the emulator lock; they leave both keyboards installed for the manual typing check.
device_checks() {
  "$adb" -s "$serial" shell pm path org.futo.inputmethod.latin >/dev/null || "$adb" -s "$serial" install "$futo_apk"
  "$adb" -s "$serial" install -r "$apk" || return 1
  # The system lists a newly installed keyboard a few seconds after the install returns.
  local imes i
  for i in {1..15}; do
    imes=$("$adb" -s "$serial" shell ime list -a -s)
    grep -q '^dev.sebb.sebtype/' <<<"$imes" && grep -q '^org.futo.inputmethod.latin/' <<<"$imes" && return 0
    sleep 2
  done
  echo "keyboards listed: $imes"; return 1
}
export -f device_checks; export adb serial apk futo_apk
T=2000 check install-beside-futo devq -P 1 -w 1800 -m 5 -n "sebtype #5 test-emulator" "$lock" bash -c device_checks

! grep -qv '^PASS' "$results"
