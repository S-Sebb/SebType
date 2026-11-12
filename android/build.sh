#!/usr/bin/env bash
# Builds a SebType APK under the shared build lock (one heavy Gradle/NDK build at a time). Memory stays
# capped and no Gradle daemon is left running: the PC has 15 GB shared with the emulator and other builds.
#   android/build.sh release       signed arm64-v8a release APK (keystore in ~/.config/sebtype)
#   android/build.sh debug-x86_64  debug APK for an x86_64 emulator
#   android/build.sh test-x86_64   debug APK, then its instrumented-test APK, for an x86_64 emulator
#   android/build.sh debug         debug arm64-v8a APK, the one the emulator tests run (through the
#                                  emulator's ARM translation), as the phone does
# Runs in the shared build lock (tools/lib.sh's build_lock: the caller's DEVQ_RANK, half the cores, 8 GB).
# Each run copies its APKs, inside the lock, to a folder of its own in app/build/runs/, so builds run at the
# same time in one checkout can't swap each other's APK (#182). Prints the APK path last (then, for
# test-x86_64, the test APK's). Version: <FUTO release>-sebtype.<first-parent commit count> for release;
# debug builds are always <FUTO release>-sebtype.dev, code 1, so BuildConfig doesn't change
# with every commit or branch and Gradle's build cache serves every worktree (#58).
set -euo pipefail
cd "$(dirname "$0")"
source ../tools/lib.sh

kind=${1:?usage: android/build.sh release|debug|debug-x86_64|test-x86_64}
keydir=${SEBTYPE_KEY_DIR:-$HOME/.config/sebtype}
export JAVA_HOME=$JDK21
[[ -x $JAVA_HOME/bin/javac ]] || { echo "build: JDK 21 not found (set JAVA_HOME_21)" >&2; exit 1; }
[[ -d $ANDROID_HOME/ndk/28.2.13676358 ]] || { echo "build: NDK 28.2.13676358 missing in $ANDROID_HOME" >&2; exit 1; }

# Mozc's Japanese dictionary (pinned URL and sha256 in FUTO's script), bundled like FUTO's Play Store build.
python3 app/res-bundle/download-bundles.py "$PWD/app/res-bundle" >&2

if [[ $kind == release ]]; then
  VERSION_CODE=$(git rev-list --first-parent --count HEAD) build=$VERSION_CODE
else VERSION_CODE=1 build=dev; fi
VERSION_NAME="$(cat upstream-version)-sebtype.$build"
export VERSION_CODE VERSION_NAME
case $kind in
  release)
    [[ -f $keydir/sebtype-release.jks && -f $keydir/keystore.password ]] ||
      { echo "build: keystore missing in $keydir" >&2; exit 1; }
    task=assembleRelease abis=arm64-v8a out=app/build/outputs/apk/release ;;
  debug-x86_64)
    task=assembleDebug abis=x86_64 out=app/build/outputs/apk/debug ;;
  test-x86_64)
    task="assembleDebug assembleDebugAndroidTest" abis=x86_64 out=app/build/outputs/apk/debug ;;
  debug)
    task=assembleDebug abis=arm64-v8a out=app/build/outputs/apk/debug ;;
  *) echo "build: unknown kind $kind" >&2; exit 2 ;;
esac
# This run's APKs, hard links to Gradle's (which the next build replaces, not overwrites). Runs older than
# a day are gone: a caller uses its APK within minutes.
mkdir -p app/build/runs
find app/build/runs -mindepth 1 -maxdepth 1 -mmin +1440 -exec rm -rf {} +
run=$(mktemp -d "$PWD/app/build/runs/$kind.XXXXXX")
locked=$run/locked # when the build lock was taken

# Native objects come from sccache when it is installed (CMake takes the launcher from the environment
# when it first configures a checkout). A private server per build hashes paths relative to the checkout's root,
# and build.gradle keeps them out of the objects, so every worktree shares the cache.
if command -v sccache >/dev/null; then
  SCCACHE_SERVER_UDS=$(mktemp -u /tmp/sebtype-sccache.XXXXXX)
  export CMAKE_C_COMPILER_LAUNCHER=sccache CMAKE_CXX_COMPILER_LAUNCHER=sccache SCCACHE_BASEDIRS=${PWD%/*} \
    SCCACHE_SERVER_UDS
  sccache --start-server >/dev/null
  trap 'sccache --stop-server >/dev/null; rm -f "$SCCACHE_SERVER_UDS"' EXIT
fi

start=$(date +%s)
# A release build gets SebType's key through its own environment, so builds in parallel or in the same
# checkout can't take each other's signing away, and Gradle stops without it (#149, #178).
# The Kotlin compiler runs in its own daemon: in-process it recompiles every file on each build. That
# daemon ends with the build, like Gradle's.
export SEBTYPE_KEY_DIR=$keydir KIND=$kind OUT=$out RUN=$run BUILD_JOBS
build_lock 30 "sebtype build ($kind, $(basename "$(git rev-parse --show-toplevel)"))" bash -c '
  date +%s > "$RUN/locked"
  rm -rf "$OUT" app/build/outputs/apk/androidTest
  if [[ $KIND == release ]]; then
    export SEBTYPE_KEYSTORE=$SEBTYPE_KEY_DIR/sebtype-release.jks
    SEBTYPE_KEYSTORE_PASSWORD=$(cat "$SEBTYPE_KEY_DIR/keystore.password"); export SEBTYPE_KEYSTORE_PASSWORD
  fi
  ./gradlew --no-daemon --max-workers="$BUILD_JOBS" -Dorg.gradle.jvmargs=-Xmx3g \
    -Pkotlin.compiler.execution.strategy=daemon -Pkotlin.daemon.jvmargs=-Xmx2g --console=plain -q "$@" >&2
  cp -l "$OUT"/*.apk "$RUN/"
  if [[ $KIND == test-x86_64 ]]; then mkdir "$RUN/androidTest" && cp -l app/build/outputs/apk/androidTest/debug/*.apk "$RUN/androidTest/"; fi
' build $task -PsebtypeAbis="$abis"
apk=$(echo "$run"/*.apk)
if [[ $kind == release ]]; then
  "$(ls -d "$ANDROID_HOME"/build-tools/* | tail -1)"/apksigner verify --print-certs "$apk" 2>/dev/null | grep -q 'CN=SebType' ||
    { echo "build: $apk is not signed with SebType's key" >&2; exit 1; }
fi
echo "build: $kind $VERSION_NAME in $(( $(date +%s) - $(cat "$locked") ))s after $(( $(cat "$locked") - start ))s in the lock queue, $(du -h "$apk" | cut -f1)" >&2
echo "$apk"
[[ $kind != test-x86_64 ]] || echo "$run"/androidTest/*.apk
