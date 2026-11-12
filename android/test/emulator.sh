#!/usr/bin/env bash
# Checks the SebType release APK, installs it on SebType's emulator (android/emulator.sh, or
# the device ANDROID_SERIAL names) next to stock FUTO Keyboard, opens its settings as the new keyboard
# starts for the first time (no hang, default languages saved, #75), then
# types Chinese with it (android/test/chinese.py): the bundled Chinese data set up in the background from
# the setup screen after a fresh install (with its notice when 中 comes up first), learning, an update
# over itself and recovery from a broken install, the 简/繁 menu switch (#36); then Japanese's あ ⇄ ア
# mode chip (#38); with MAIN_APK (main's release APK), last an update from main that keeps a word
# learned there; then every settings screen and SebType's own options (android/test/settings.py, #41),
# incognito (#31), sync with a local sync-server (#12, #14), importing personal data (#11), and clipboard
# history in a settings backup only when ticked (#34).
# It uninstalls SebType first, so its data is lost.
# SEBTYPE_CHECKS=a,b runs only the checks whose names start with a or b, plus what they need: the build, the
# install and the locale always, and chinese.py's earlier checks they depend on. A PR runs the checks
# for what it changed; a release runs them all. PERF_RUN=1 adds the timing checks (settings-smooth-scrolling),
# which only the final performance run uses (#54, Decisions #2 2026-11-11).
# One line per check in ~/scratch/sebtype/test-emulator-<checkout>/results.txt; logs next to it (one directory
# per checkout, so runs from parallel worktrees don't overwrite each other). Exit 0 only if all pass.
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh

out=$SCRATCH/test-emulator-$(basename "$PWD"); mkdir -p "$out"
results=$out/results.txt; : > "$results"
sdk=$ANDROID_HOME
adb=$sdk/platform-tools/adb
bt=$(ls -d "$sdk"/build-tools/* | tail -1)
futo_apk=$SCRATCH/cache/futo-keyboard-0.1.30.apk; mkdir -p "$SCRATCH/cache"

export SEBTYPE_CHECKS=${SEBTYPE_CHECKS:-} PERF_RUN=${PERF_RUN:-}
result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
check() { # name, command...; timeout T seconds (default 180); only if SEBTYPE_CHECKS names it or it's a step all need
  local name=$1 c; shift
  if [[ -n $SEBTYPE_CHECKS && " bumped-apk locale install-beside-futo chinese-run settings-run " != *" $name "* ]]; then
    for c in ${SEBTYPE_CHECKS//,/ }; do [[ $name == "$c"* ]] && break; done
    [[ $name == "$c"* ]] || return 0
  fi
  if timeout "${T:-180}" "$@" > "$out/$name.log" 2>&1; then result PASS "$name"
  else result FAIL "$name" "see $out/$name.log"; fi
}

# Preflight
[[ -x $adb ]] || { echo "preflight: adb missing in $sdk"; exit 1; }
apk=$(android/build.sh release 2> "$out/build.log" | tail -1)
[[ -f $apk ]] || { echo "preflight: release build failed, see $out/build.log"; exit 1; }
# The text field the Chinese checks type into: the app's own "try typing" popup isn't exported.
field_apk=$out/field.apk
android/perf/build-field.sh "$field_apk" > "$out/field.log" 2>&1 && [[ -f $field_apk ]] ||
  { echo "preflight: test field build failed, see $out/field.log"; exit 1; }
locale_dex=$out/set-locale.dex
android/test/set-locale/build.sh "$locale_dex" > "$out/set-locale.log" 2>&1 ||
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
# The Chinese data comes compiled (tables and 白霜's grammar), without the dictionary sources; its one
# .dict.yaml is SebType's pack for the user's own word list (#11).
rime_data=$out/rime-data.zip
unzip -p "$apk" assets/rime/rime-data.zip > "$rime_data"
check rime-data-bundled bash -c 'l=$(unzip -Z1 "$1") && grep -qx build/rime_ice.table.bin <<<"$l" &&
  grep -qx zh-moqi.gram <<<"$l" && [[ $(grep "\.dict\.yaml$" <<<"$l") == sebtype.dict.yaml ]]' _ "$rime_data"
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
# translations (#6, #178: the other languages' files aren't in the repo).
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
# #75: on a fresh install that hasn't run yet, opening the settings app while SebType is being selected
# starts the activity and the keyboard service in one new process; the keyboard's first-start write
# blocked the main thread for good ("SebType isn't responding"). The keyboard must still save its
# default languages (EN, 中, 日).
first_start_settings() {
  local ime=dev.sebb.sebtype/org.futo.inputmethod.latin.LatinIME prev prefs pid i saved=
  local act=dev.sebb.sebtype/org.futo.inputmethod.latin.uix.settings.SettingsActivity
  prev=$("$adb" -s "$serial" shell settings get secure default_input_method | tr -d '\r')
  # install-beside-futo just installed SebType, and nothing has started it since.
  "$adb" -s "$serial" shell ime enable "$ime" >/dev/null || return 1
  "$adb" -s "$serial" logcat -c
  "$adb" -s "$serial" shell "am start -n $act & ime set $ime; wait"
  for i in {1..25}; do
    prefs=$("$adb" -s "$serial" shell su 0 cat /data/data/dev.sebb.sebtype/files/datastore/settings.preferences_pb 2>/dev/null |
      tr -c '[:print:]' ' ')
    [[ $prefs == *en_US:KeyboardLayoutSet=qwerty* && $prefs == *zh:KeyboardLayoutSet=sebtype_zh* &&
       $prefs == *ja:KeyboardLayoutSet=sebtype_ja* ]] && { saved=1; break; }
    sleep 1
  done
  pid=$("$adb" -s "$serial" shell pidof dev.sebb.sebtype | tr -d '\r')
  [[ -n $pid ]] && "$adb" -s "$serial" shell su 0 debuggerd -j "$pid" > "$out/first-start-settings-stacks.txt" 2>&1
  "$adb" -s "$serial" shell ime set "$prev" >/dev/null
  if grep -A30 '^"main"' "$out/first-start-settings-stacks.txt" 2>/dev/null | grep -m1 runBlocking; then
    echo "main thread stuck in runBlocking: see first-start-settings-stacks.txt"; return 1
  fi
  "$adb" -s "$serial" logcat -d | grep -E "ANR in dev\.sebb\.sebtype|executing service dev\.sebb\.sebtype" && return 1
  [[ $saved ]] || { echo "default languages not saved in 25 s: $prefs"; return 1; }
  echo "no hang; default languages saved"
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
  T=60 check locale bash -c set_locale && echo "locale en-US, $(grep -m1 '^locale was' "$out/locale.log")"
  T=300 check install-beside-futo bash -c device_checks
  grep -q '^PASS install-beside-futo' "$results" && T=90 check first-start-settings bash -c first_start_settings
  if grep -q '^PASS install-beside-futo' "$results" && grep -q '^PASS bumped-apk' "$results"; then
    # first-install enables SebType and chinese.py installs the field app: a run of named checks
    # may run neither, so it does both here.
    if [[ -n $SEBTYPE_CHECKS ]]; then
      "$adb" -s "$serial" shell ime enable "dev.sebb.sebtype/org.futo.inputmethod.latin.LatinIME" >/dev/null
      "$adb" -s "$serial" install -r "$field_apk" >/dev/null
    fi
    # chinese.py appends its own result lines; this line only records whether it ran to the end.
    PATH=$(dirname "$adb"):$PATH T=3600 check chinese-run \
      python3 -I android/test/chinese.py "$serial" "$apk" "$bumped" "$field_apk" "$results" "$out" ${MAIN_APK:+"$MAIN_APK"}
    # Every settings screen opens and SebType's own options take effect (#41); appends its own lines.
    PATH=$(dirname "$adb"):$PATH T=3600 check settings-run python3 -I android/test/settings.py "$serial" "$results" "$out"
  else
    result SKIP chinese "needs install-beside-futo and bumped-apk"
  fi
}
export -f result check set_locale device_checks first_start_settings device_suite; export adb apk futo_apk field_apk locale_dex results
android/emulator.sh -P 1 -w 1800 -m 50 -n "sebtype test-emulator ($(basename "$PWD"))" -- bash -c device_suite \
  2> "$out/emulator.log" || grep -q '^[A-Z]* emulator\|install-beside-futo' "$results" ||
  result FAIL emulator "$(head -1 "$out/emulator.log")"

! grep -qv '^PASS' "$results"
