#!/usr/bin/env bash
# Smoke test for the Rime aar with Lua. One command, no arguments:
#   - builds the arm64-v8a aar and checks its exported symbols, Kotlin API and size;
#   - builds an x86_64 variant with an instrumented test that deploys rime-ice and
#     types ranh / rq / hm on a running emulator (AVD guide35 or lossbench).
# Results: one line per check in $RESULTS; logs next to it. Exit 0 only if all pass.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/versions.sh"
LOGS=/tmp/sebtype/7-smoke
RESULTS="$LOGS/results.txt"
RIME_ICE_COMMIT=da1fbe602e38f26db846fa10120ee64c2b0324c0  # rime-ice release the PC setup uses
RIME_ICE_LOCAL="$HOME/.local/share/fcitx5/rime"           # read only: a rime-ice clone
FUTO_AAR="$HOME/src/sebtype-upstream/futo-keyboard/libs/rime-release.aar"
SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
ADB="$SDK/platform-tools/adb"
NDK_BIN="$SDK/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin"
LOCK=/tmp/agent-locks/sebtype/emulator.lock

rm -rf "$LOGS" && mkdir -p "$LOGS"
: > "$RESULTS"
result() { echo "$1 $2${3:+ - $3}" | tee -a "$RESULTS"; }
finish() { grep -qv '^PASS\|^INFO' "$RESULTS" && exit 1; exit 0; }

# --- preflight ---------------------------------------------------------------
for tool in devq gh git javap unzip rsync "$ADB" "$NDK_BIN/llvm-nm"; do
  command -v "$tool" >/dev/null || { echo "preflight: missing $tool"; exit 2; }
done
SERIAL=""
for s in $("$ADB" devices | awk '$1 ~ /^emulator-/ && $2 == "device" {print $1}'); do
  avd="$("$ADB" -s "$s" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
  [[ "$avd" == guide35 || "$avd" == lossbench ]] && SERIAL="$s" && break
done
[[ -n "$SERIAL" ]] || { echo "preflight: no running emulator guide35 or lossbench (open one with device_open)"; exit 2; }

# --- arm64 aar: build, symbols, API, size --------------------------------------
if (cd "$HERE" && ./build.sh) > "$LOGS/build-arm64.log" 2>&1; then
  ARM_AAR="$HERE/out/rime-android-$RIME_ANDROID_VERSION-arm64-v8a.aar"
  result PASS build-arm64
  unzip -o -q "$ARM_AAR" -d "$LOGS/aar-arm64"
  SO="$LOGS/aar-arm64/jni/arm64-v8a/librime-jni.so"
  # The plugins are linked into librime-jni.so (stripped, but its dynamic symbols stay);
  # their module entry points, Lua's C API and the Lua gear classes must be exported.
  "$NDK_BIN/llvm-nm" -C -D --defined-only "$SO" > "$LOGS/nm-arm64.txt"
  missing=""
  for sym in rime_require_module_lua rime_require_module_octagram rime_require_module_predict \
             lua_newstate luaL_openlibs LuaTranslator LuaFilter LuaProcessor; do
    grep -q "$sym" "$LOGS/nm-arm64.txt" || missing+=" $sym"
  done
  [[ -z "$missing" ]] && result PASS symbols "lua, octagram, predict modules and Lua C API present" \
                      || result FAIL symbols "missing:$missing"

  if [[ -f "$FUTO_AAR" ]]; then
    api() { # public Kotlin/JVM API of an aar's classes.jar
      local d="$LOGS/api-$1"; mkdir -p "$d"; unzip -o -q "$2" classes.jar -d "$d"
      unzip -Z1 "$d/classes.jar" | grep '\.class$' | sed 's/\.class$//; s#/#.#g' | sort \
        | xargs javap -cp "$d/classes.jar" -public | grep -v '^Compiled from' > "$d/api.txt"
    }
    api ours "$ARM_AAR"; api futo "$FUTO_AAR"
    if diff "$LOGS/api-futo/api.txt" "$LOGS/api-ours/api.txt" > "$LOGS/api.diff"; then
      result PASS kotlin-api "same public API as FUTO's aar"
    else
      result FAIL kotlin-api "differs from FUTO's aar, see $LOGS/api.diff"
    fi
    futo_so=$(unzip -l "$FUTO_AAR" jni/arm64-v8a/librime-jni.so | awk 'NR==4{print $1}')
    result INFO size "aar $(stat -c %s "$ARM_AAR") B (arm64 only), librime-jni.so $(stat -c %s "$SO") B; FUTO aar $(stat -c %s "$FUTO_AAR") B (4 ABIs), arm64 librime-jni.so $futo_so B"
  else
    result SKIP kotlin-api "FUTO aar not found at $FUTO_AAR"
  fi
else
  result FAIL build-arm64 "see $LOGS/build-arm64.log"
fi

# --- x86_64 variant with the instrumented test ---------------------------------
TESTSRC="$HERE/work/androidTest"
rm -rf "$TESTSRC" "$HERE/work/rime-ice"
mkdir -p "$TESTSRC/assets" "$HERE/work/rime-ice"
cp -r "$HERE/smoke-test/java" "$TESTSRC/"
(
  cd "$HERE/work/rime-ice" && git init -q &&
  { git fetch -q --depth 1 "file://$RIME_ICE_LOCAL" "$RIME_ICE_COMMIT" 2>/dev/null ||
    git fetch -q --depth 1 https://github.com/iDvel/rime-ice.git "$RIME_ICE_COMMIT"; } &&
  git checkout -q FETCH_HEAD
) > "$LOGS/rime-ice.log" 2>&1 || { result FAIL rime-ice "could not fetch $RIME_ICE_COMMIT"; finish; }
# Only what Rime reads; no prebuilt build/, so the phone-side deploy is tested too.
rsync -a --exclude .git --exclude .github --exclude others --exclude build \
  "$HERE/work/rime-ice/" "$TESTSRC/assets/rime-ice/"

if (cd "$HERE" && RIME_ABIS=x86_64 RIME_ANDROID_TEST_DIR="$TESTSRC" \
    RIME_ANDROID_GRADLE_TASKS=":rime:assembleRelease :rime:assembleReleaseAndroidTest" ./build.sh) \
    > "$LOGS/build-x86_64.log" 2>&1; then
  result PASS build-x86_64
else
  result FAIL build-x86_64 "see $LOGS/build-x86_64.log"; finish
fi
TEST_APK="$HERE/work/RimeJni/rime/build/outputs/apk/androidTest/release/rime-release-androidTest.apk"

# --- emulator, under the emulator lock -----------------------------------------
devq -w 1800 -m 15 -P "${DEVQ_RANK:-2}" -n "rime-android smoke test" "$LOCK" bash -c '
  adb=$1 s=$2 apk=$3 logs=$4
  $adb -s $s logcat -c
  $adb -s $s install -r -t "$apk" > "$logs/install.log" 2>&1 || exit 3
  timeout 1500 $adb -s $s shell am instrument -w -r \
    -e class icu.astronot233.rime.RimeIceSmokeTest \
    icu.astronot233.rime.test/androidx.test.runner.AndroidJUnitRunner > "$logs/instrument.log" 2>&1
  $adb -s $s logcat -d -s RimeIceSmokeTest RimeJNI librime > "$logs/logcat.txt"
  $adb -s $s uninstall icu.astronot233.rime.test > /dev/null 2>&1
  exit 0
' _ "$ADB" "$SERIAL" "$TEST_APK" "$LOGS"
case $? in
  0) ;;
  3) result FAIL install "see $LOGS/install.log"; finish ;;
  *) result FAIL emulator-lock "$(devq status "$LOCK" | head -1)"; finish ;;
esac

# am instrument -r: status code 1 = started, 0 = passed, -2 = failed, -1 = error.
for t in ranhGivesRanhou rqGivesTodaysDate hmIsPinnedToHoumian; do
  code=$(awk -v t="$t" '/INSTRUMENTATION_STATUS: test=/{cur=substr($0, index($0,"=")+1)}
                        /INSTRUMENTATION_STATUS_CODE:/ && cur==t {c=$2} END{print c}' "$LOGS/instrument.log")
  got=$(grep -o "$(case $t in ranh*) echo ranh;; rq*) echo rq;; hm*) echo hm;; esac) -> .*" "$LOGS/logcat.txt" | head -1)
  case "$code" in
    0) result PASS "$t" "$got" ;;
    "") result FAIL "$t" "did not run, see $LOGS/instrument.log" ;;
    *) result FAIL "$t" "${got:-no candidates logged}, see $LOGS/instrument.log" ;;
  esac
done
deploy=$(grep -o 'deployed in [0-9]* ms' "$LOGS/logcat.txt" | head -1)
[[ -n "$deploy" ]] && result INFO deploy "rime-ice $deploy on the emulator"
finish
