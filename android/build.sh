#!/usr/bin/env bash
# Builds a SebType APK under the shared build lock (one heavy Gradle/NDK build at a time). Memory stays
# capped and no Gradle daemon is left running: the PC has 15 GB shared with the emulator and other builds.
#   android/build.sh release       signed arm64-v8a release APK (keystore in ~/.config/sebtype)
#   android/build.sh debug-x86_64  debug APK for an x86_64 emulator
#   android/build.sh test-x86_64   debug APK, then its instrumented-test APK, for an x86_64 emulator
#   android/build.sh debug         debug arm64-v8a APK, the one the emulator tests run (through the
#                                  emulator's ARM translation), as the phone does
# BUILD_PRIORITY (default 1) is the devq rank for the build lock.
# Prints the APK path last. Version: <FUTO release>-sebtype.<first-parent commit count> for release;
# debug builds are always <FUTO release>-sebtype.dev, code 1, so BuildConfig doesn't change
# with every commit or branch and Gradle's build cache serves every worktree (#58).
set -euo pipefail
cd "$(dirname "$0")"

kind=${1:?usage: android/build.sh release|debug|debug-x86_64|test-x86_64}
keydir=${SEBTYPE_KEY_DIR:-$HOME/.config/sebtype}
export JAVA_HOME=${JAVA_HOME_21:-$(ls -d "$HOME"/.local/share/jdks/jdk-21* 2>/dev/null | tail -1)}
export ANDROID_HOME=${ANDROID_HOME:-$HOME/Android/Sdk}
[[ -x $JAVA_HOME/bin/javac ]] || { echo "build: JDK 21 not found (set JAVA_HOME_21)" >&2; exit 1; }
[[ -d $ANDROID_HOME/ndk/28.2.13676358 ]] || { echo "build: NDK 28.2.13676358 missing in $ANDROID_HOME" >&2; exit 1; }

# Mozc's Japanese dictionary (pinned URL and sha256 in FUTO's script), bundled like FUTO's Play Store build.
python3 app/res-bundle/download-bundles.py "$PWD/app/res-bundle" >&2

if [[ $kind == release ]]; then
  VERSION_CODE=$(git rev-list --first-parent --count HEAD) build=$VERSION_CODE
else VERSION_CODE=1 build=dev; fi
VERSION_NAME="$(cat upstream-version)-sebtype.$build"
export VERSION_CODE VERSION_NAME
locked=$(mktemp) # when the build lock was taken
trap 'rm -f "$locked"' EXIT

case $kind in
  release)
    [[ -f $keydir/sebtype-release.jks && -f $keydir/keystore.password ]] ||
      { echo "build: keystore missing in $keydir" >&2; exit 1; }
    task=assembleRelease abis=arm64-v8a out=app/build/outputs/apk/release ;;
  debug-x86_64)
    task=assembleDebug abis=x86_64 out=app/build/outputs/apk/debug ;;
  test-x86_64)
    task="assembleDebug assembleDebugAndroidTest" abis=x86_64 out=app/build/outputs/apk/debug
    rm -rf app/build/outputs/apk/androidTest ;;
  debug)
    task=assembleDebug abis=arm64-v8a out=app/build/outputs/apk/debug ;;
  *) echo "build: unknown kind $kind" >&2; exit 2 ;;
esac

# Native objects come from sccache when it is installed (CMake takes the launcher from the environment
# when it first configures a checkout). A private server per build hashes paths relative to this checkout,
# and build.gradle keeps them out of the objects, so every worktree shares the cache.
if command -v sccache >/dev/null; then
  export CMAKE_C_COMPILER_LAUNCHER=sccache CMAKE_CXX_COMPILER_LAUNCHER=sccache SCCACHE_BASEDIRS=${PWD%/*} \
    SCCACHE_SERVER_UDS=$locked.sccache
  sccache --start-server >/dev/null
  trap 'sccache --stop-server >/dev/null; rm -f "$locked" "$SCCACHE_SERVER_UDS"' EXIT
fi

start=$(date +%s)
# A release build gets SebType's key through its own environment, so builds in parallel or in the same
# checkout can't take each other's signing away, and Gradle stops without it (#149, #178).
# The Kotlin compiler runs in its own daemon: in-process it recompiles every file on each build. That
# daemon ends with the build, like Gradle's.
export SEBTYPE_KEY_DIR=$keydir KIND=$kind OUT=$out LOCKED=$locked
devq -P "${BUILD_PRIORITY:-1}" -m 30 -n "sebtype build ($kind)" /tmp/agent-locks/sebtype/build.lock bash -c '
  date +%s > "$LOCKED"
  rm -rf "$OUT"
  if [[ $KIND == release ]]; then
    export SEBTYPE_KEYSTORE=$SEBTYPE_KEY_DIR/sebtype-release.jks
    SEBTYPE_KEYSTORE_PASSWORD=$(cat "$SEBTYPE_KEY_DIR/keystore.password"); export SEBTYPE_KEYSTORE_PASSWORD
  fi
  ./gradlew --no-daemon --max-workers=4 -Dorg.gradle.jvmargs=-Xmx3g \
    -Pkotlin.compiler.execution.strategy=daemon -Pkotlin.daemon.jvmargs=-Xmx2g --console=plain -q "$@" >&2
' build $task -PsebtypeAbis="$abis"
apk=$(realpath "$out"/*.apk)
if [[ $kind == release ]]; then
  "$(ls -d "$ANDROID_HOME"/build-tools/* | tail -1)"/apksigner verify --print-certs "$apk" 2>/dev/null | grep -q 'CN=SebType' ||
    { echo "build: $apk is not signed with SebType's key" >&2; exit 1; }
fi
echo "build: $kind $VERSION_NAME in $(( $(date +%s) - $(cat "$locked") ))s after $(( $(cat "$locked") - start ))s in the lock queue, $(du -h "$apk" | cut -f1)" >&2
echo "$apk"
[[ $kind != test-x86_64 ]] || realpath app/build/outputs/apk/androidTest/debug/*.apk
