#!/usr/bin/env bash
# Checks the SebType release APK, installs it on one of SebType's two emulators (sebtype/emulator.sh, or
# the device ANDROID_SERIAL names) next to stock FUTO Keyboard, then
# types Chinese with it (sebtype/test-chinese.py): the bundled Chinese data set up in the background from
# the setup screen after a fresh install (with its notice when 中 comes up first), learning, an update
# over itself and recovery from a broken install, the 简/繁 menu switch (#36); then Japanese's あ ⇄ ア
# mode chip (#38); with MAIN_APK (main's release APK), last an update from main that keeps a word
# learned there; then every settings screen and SebType's own options (sebtype/test-settings.py, #41).
# It uninstalls SebType first, so its data is lost.
# One line per check in /tmp/sebtype/test-emulator-<checkout>/results.txt; logs next to it (one directory
# per checkout, so runs from parallel worktrees don't overwrite each other). Exit 0 only if all pass.
set -uo pipefail
cd "$(dirname "$0")/.."

out=/tmp/sebtype/test-emulator-$(basename "$PWD"); mkdir -p "$out"
results=$out/results.txt; : > "$results"
sdk=${ANDROID_HOME:-$HOME/Android/Sdk}
adb=$sdk/platform-tools/adb
bt=$(ls -d "$sdk"/build-tools/* | tail -1)
futo_apk=/tmp/sebtype/futo-keyboard-0.1.30.apk

result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
check() { # name, command...; timeout T seconds (default 180)
  local name=$1; shift
  if timeout "${T:-180}" "$@" > "$out/$name.log" 2>&1; then result PASS "$name"
  else result FAIL "$name" "see $out/$name.log"; fi
}

# Preflight
[[ -x $adb ]] || { echo "preflight: adb missing in $sdk"; exit 1; }
apk=$(sebtype/build.sh release 2> "$out/build.log" | tail -1)
[[ -f $apk ]] || { echo "preflight: release build failed, see $out/build.log"; exit 1; }
# The text field the Chinese checks type into: the app's own "try typing" popup isn't exported.
field_apk=$out/field.apk
sebtype/perf/build-field.sh "$field_apk" > "$out/field.log" 2>&1 && [[ -f $field_apk ]] ||
  { echo "preflight: test field build failed, see $out/field.log"; exit 1; }
locale_dex=$out/set-locale.dex
sebtype/set-locale/build.sh "$locale_dex" > "$out/set-locale.log" 2>&1 ||
  { echo "preflight: set-locale helper build failed, see $out/set-locale.log"; exit 1; }
[[ -f $futo_apk ]] || gh release download 0.1.30 -R futo-org/android-keyboard -p keyboard-0.1.30.apk -O "$futo_apk" ||
  { echo "preflight: can't download stock FUTO 0.1.30"; exit 1; }

badging=$("$bt/aapt2" dump badging "$apk")
check package-id grep -q "package: name='dev.sebb.sebtype'" <<<"$badging"
check app-label grep -q "application-label:'SebType'" <<<"$badging"
check arm64-only bash -c "[[ \$(unzip -Z1 '$apk' 'lib/*' | cut -d/ -f2 | sort -u) == arm64-v8a ]]"
check signed-sebtype bash -c "'$bt/apksigner' verify --print-certs '$apk' | grep -q 'CN=SebType'"
# Japanese works with nothing imported only if Mozc's dictionary is in the APK, stored uncompressed (Mozc maps it).
mozc_dict=$(grep -A3 'raw/builtin_mozc_data$' <<<"$("$bt/aapt2" dump resources "$apk")" | awk '$1 == "(ja)" {print $3}')
check mozc-dictionary bash -c "[[ -n '$mozc_dict' ]] && unzip -Zl '$apk' '$mozc_dict' | grep -q ' stor '"
# SebType's uniform zh/ja layouts ship beside FUTO's English ones.
assets=$(unzip -Z1 "$apk" 'assets/layouts/*')
check uniform-layouts bash -c 'for f in SebType/sebtype_zh SebType/sebtype_ja Default/qwerty; do
  grep -qx "assets/layouts/$f.yaml" <<<"$1" || { echo "missing $f"; exit 1; }; done' _ "$assets"
# The Chinese data comes compiled (tables and 白霜's grammar), without the dictionary sources.
rime_data=$out/rime-data.zip
unzip -p "$apk" assets/rime/rime-data.zip > "$rime_data"
check rime-data-bundled bash -c 'l=$(unzip -Z1 "$1") && grep -qx build/rime_ice.table.bin <<<"$l" &&
  grep -qx zh-moqi.gram <<<"$l" && ! grep -q "\.dict\.yaml$" <<<"$l"' _ "$rime_data"
rm -f "$rime_data"

# The same APK with another bundled data version marker, re-signed: what an update that changes the
# Chinese data looks like to the app.
bumped=$out/bumped.apk
make_bumped() {
  # A copy plus the re-zipped APK are 2 × 180 MB: scratch goes beside the build, and the last run's
  # copy, which a nearly-full /tmp can't hold next to this run's, is dropped first.
  local d; d=$(mktemp -d "$(dirname "$apk")/bumped.XXXXXX") || return 1
  rm -f "$bumped" "$bumped.idsig"
  mkdir -p "$d/assets/rime" &&
    unzip -p "$apk" assets/rime/bundle-version | sed 's/$/ test-bump/' > "$d/assets/rime/bundle-version" &&
    cp "$apk" "$d/in.apk" && (cd "$d" && zip -q -X in.apk assets/rime/bundle-version) &&
    "$bt/zipalign" -p -f 4 "$d/in.apk" "$d/bumped.apk" &&
    "$bt/apksigner" sign --ks "${SEBTYPE_KEY_DIR:-$HOME/.config/sebtype}/sebtype-release.jks" --ks-key-alias sebtype \
      --ks-pass "file:${SEBTYPE_KEY_DIR:-$HOME/.config/sebtype}/keystore.password" "$d/bumped.apk" &&
    mv "$d/bumped.apk" "$bumped"
  local rc=$?; rm -rf "$d"; return $rc
}
# timeout execs its command, so the function and what it reads go through the environment.
export -f make_bumped; export apk bt bumped out
check bumped-apk bash -c make_bumped

# The trim (#6): no voice input, glide typing or other languages; only English, Japanese and Chinese
# translations. Russian's sources stay in FUTO's submodules (build.gradle drops them from the APK).
dicts=$("$bt/aapt2" dump resources "$apk" | grep -o 'raw/main_[a-z_]*' | sort -u | tr '\n' ' ')
check trimmed bash -c 'bad=$(unzip -Z1 "$1" | grep -E "tiny_en_acft|futo-swipe|libswipe_jni|assets/layouts/(Cyrillic|LatinScript)/")
  [[ -z $bad ]] || { echo "still in the APK: $bad"; exit 1; }
  ! grep -q RECORD_AUDIO <<<"$2" || { echo "RECORD_AUDIO permission"; exit 1; }
  grep -qx "locales: .--_--. .ja. .zh-CN." <<<"$2" || { grep "^locales" <<<"$2"; exit 1; }
  [[ $3 == "raw/main_en " ]] || { echo "dictionaries: $3"; exit 1; }' _ "$apk" "$badging" "$dicts"

# The device steps hold one emulator's lock from the install to the last check, so no other run
# reinstalls SebType in between. They leave both keyboards installed for the manual typing check.
device_checks() {
  "$adb" -s "$serial" shell pm path org.futo.inputmethod.latin >/dev/null || "$adb" -s "$serial" install "$futo_apk"
  # A fresh install, so nothing imported earlier (a dictionary, settings) hides what the APK ships with.
  "$adb" -s "$serial" uninstall dev.sebb.sebtype >/dev/null
  "$adb" -s "$serial" install "$apk" || return 1
  # The system lists a newly installed keyboard a few seconds after the install returns.
  local imes i
  for i in {1..15}; do
    imes=$("$adb" -s "$serial" shell ime list -a -s)
    grep -q '^dev.sebb.sebtype/' <<<"$imes" && grep -q '^org.futo.inputmethod.latin/' <<<"$imes" && return 0
    sleep 2
  done
  echo "keyboards listed: $imes"; return 1
}
set_locale() { # language list to en-US only, the way Settings does: a framework restart can crash the emulator
  "$adb" -s "$serial" push "$locale_dex" /data/local/tmp/sebtype-set-locale.dex > /dev/null &&
    echo "locale was $("$adb" -s "$serial" shell app_process -cp /data/local/tmp/sebtype-set-locale.dex / \
      dev.sebb.sebtype.setlocale.SetLocale en-US | tr -d '\r')"
  "$adb" -s "$serial" shell rm -f /data/local/tmp/sebtype-set-locale.dex
  [[ $("$adb" -s "$serial" shell getprop persist.sys.locale | tr -d '\r') == en-US ]]
}
device_suite() {
  export serial=$ANDROID_SERIAL
  echo "testing $apk on $serial ($("$adb" -s "$serial" emu avd name | head -1 | tr -d '\r'))"
  [[ $("$adb" -s "$serial" shell getprop ro.product.cpu.abilist) == *arm64-v8a* ]] ||
    { result FAIL emulator "$serial can't run arm64 apps"; return 1; }
  # Rime's data is in the app's private storage (#32), which the checks read as root.
  [[ $("$adb" -s "$serial" shell su 0 id -u | tr -d '\r') == 0 ]] ||
    { result FAIL emulator "$serial has no root shell (su), needed to read the app's Rime data"; return 1; }
  # The system language decides which of SebType's languages a fresh install starts with, and another
  # task can leave the emulator in Chinese (#106's second run: 13 checks failed for that alone).
  T=60 check locale bash -c set_locale && echo "locale en-US, $(head -1 "$out/locale.log")"
  T=300 check install-beside-futo bash -c device_checks
  if grep -q '^PASS install-beside-futo' "$results" && grep -q '^PASS bumped-apk' "$results"; then
    # test-chinese.py appends its own result lines; this line only records whether it ran to the end.
    PATH=$(dirname "$adb"):$PATH T=3600 check chinese-run \
      python3 -I sebtype/test-chinese.py "$serial" "$apk" "$bumped" "$field_apk" "$results" "$out" ${MAIN_APK:+"$MAIN_APK"}
    # Every settings screen opens and SebType's own options take effect (#41); appends its own lines.
    PATH=$(dirname "$adb"):$PATH T=2400 check settings-run python3 -I sebtype/test-settings.py "$serial" "$results" "$out"
  else
    result SKIP chinese "needs install-beside-futo and bumped-apk"
  fi
}
export -f result check set_locale device_checks device_suite; export adb apk futo_apk field_apk locale_dex results
sebtype/emulator.sh -P 1 -w 1800 -m 35 -n "sebtype test-emulator ($(basename "$PWD"))" -- bash -c device_suite \
  2> "$out/emulator.log" || grep -q '^[A-Z]* emulator\|install-beside-futo' "$results" ||
  result FAIL emulator "$(head -1 "$out/emulator.log")"

! grep -qv '^PASS' "$results"
