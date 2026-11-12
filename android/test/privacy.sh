#!/usr/bin/env bash
# Privacy checks for #29 on the release APK: no typed-text logs compiled in, no backup or device transfer,
# no cleartext traffic and only system certificate authorities (#12),
# the "try typing here" popup not exported, and (on a free emulator, android/emulator.sh) the installed app's backup flags.
# One line per check in /tmp/sebtype/test-privacy-results.txt; logs next to it. Exit 0 only if all pass.
# Typing in all three languages while watching logcat is checked by hand through T3's device tools.
set -uo pipefail
cd "$(dirname "$0")/../.."

out=/tmp/sebtype; mkdir -p "$out"
results=$out/test-privacy-results.txt; : > "$results"
sdk=${ANDROID_HOME:-$HOME/Android/Sdk}
adb=$sdk/platform-tools/adb
bt=$(ls -d "$sdk"/build-tools/* | tail -1)

result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
check() { # name, command...; timeout T seconds (default 180)
  local name=$1; shift
  if timeout "${T:-180}" "$@" > "$out/test-privacy-$name.log" 2>&1; then result PASS "$name"
  else result FAIL "$name" "see $out/test-privacy-$name.log"; fi
}

# Preflight
[[ -x $adb ]] || { echo "preflight: adb missing in $sdk"; exit 1; }
apk=$(android/build.sh release 2> "$out/test-privacy-build.log" | tail -1)
[[ -f $apk ]] || { echo "preflight: release build failed, see $out/test-privacy-build.log"; exit 1; }
echo "testing $apk"

manifest=$("$bt/aapt2" dump xmltree --file AndroidManifest.xml "$apk")
echo "$manifest" > "$out/test-privacy-manifest.txt"
check no-backup grep -Eq 'allowBackup.*=false' "$out/test-privacy-manifest.txt"
check transfer-rules grep -q 'dataExtractionRules' "$out/test-privacy-manifest.txt"
# Every <exclude> domain for cloud backup and device transfer, nothing included.
# Resource shrinking renames the file, so resolve its path in the APK by name.
rules=$("$bt/aapt2" dump resources "$apk" | awk '/xml\/data_extraction_rules$/ {getline; print $3}')
check rules-exclude-all bash -c "x=\$('$bt/aapt2' dump xmltree --file '$rules' '$apk'); \
  ! grep -q 'E: include' <<<\"\$x\" && [[ \$(grep -c 'E: exclude' <<<\"\$x\") -eq 18 ]]"
check popup-not-exported bash -c "grep -A3 'TextEditPopupActivity' '$out/test-privacy-manifest.txt' | grep -Eq 'exported.*=false'"
# Sync (#12, H10 in #26): the network only through the app's config, which allows no cleartext and no
# user-installed certificate authorities.
netcfg=$("$bt/aapt2" dump resources "$apk" | awk '/xml\/sebtype_network_security$/ {getline; print $3}')
check network-config bash -c "grep -q 'networkSecurityConfig' '$out/test-privacy-manifest.txt' &&
  x=\$('$bt/aapt2' dump xmltree --file '$netcfg' '$apk') && grep -q 'cleartextTrafficPermitted.*=false' <<<\"\$x\" &&
  [[ \$(grep -c 'E: certificates' <<<\"\$x\") -eq 1 ]] && grep -q 'src.*=\"system\"' <<<\"\$x\""

# Release dex: the typed-text log strings are gone (R8 strips Log.d/v/i, incl. RimeJni's per-key log).
dexdir=$out/test-privacy-dex; rm -rf "$dexdir"; mkdir -p "$dexdir"
unzip -q -o "$apk" 'classes*.dex' -d "$dexdir"
strings_in_dex() { cat "$dexdir"/*.dex | strings -n 6; }
export -f strings_in_dex; export dexdir
# Log message text, not method names: the keystroke log was Log.d("Rime", "processX11Code: (...)").
check_dex_absent() { check "$1" bash -c "! strings_in_dex | grep -qF '$2'"; }
check_dex_absent dex-no-keystroke-log 'processX11Code: ('
check_dex_absent dex-no-unigram-word 'Cannot add unigram entry. word'
check_dex_absent dex-no-reweighted 'reweighted, from'

# Installed app: Android must not report it as backup-enabled.
device_check() {
  [[ $("$adb" shell getprop ro.product.cpu.abilist) == *arm64-v8a* ]] || { echo "$ANDROID_SERIAL can't run arm64 apps"; return 1; }
  "$adb" uninstall dev.sebb.sebtype >/dev/null
  "$adb" install "$apk" >/dev/null || return 1
  flags=$("$adb" shell dumpsys package dev.sebb.sebtype | grep -m1 ' flags=\[')
  echo "$flags"; [[ -n $flags && $flags != *ALLOW_BACKUP* ]]
}
export -f device_check; export adb apk
T=2000 check installed-no-backup android/emulator.sh -P 4 -w 1800 -m 5 -n "sebtype #29 test-privacy" -- bash -c device_check

! grep -qv '^PASS' "$results"
