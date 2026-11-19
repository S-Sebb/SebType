#!/usr/bin/env bash
# Builds a SebType APK under the shared build lock (one heavy Gradle/NDK build at a time). Memory stays
# capped and no Gradle daemon is left running: the PC has 15 GB shared with the emulator and other builds.
#   android/build.sh release       signed arm64-v8a release APK (keystore in ~/.config/sebtype), the one the
#                                  emulator tests run (through the emulator's ARM translation), as the phone does
#   android/build.sh debug         debug arm64-v8a APK
#   android/build.sh debug-x86_64  debug APK for an x86_64 emulator
#   android/build.sh unit-tests    the app's unit tests (JVM, no device); no APK
# Runs on yanglab16 when it answers (tools/lib.sh, #225; SEBTYPE_BUILD_HOST=local builds here), and copies
# the APKs back. A release comes back unsigned and is signed here: the key never leaves this PC.
# Runs in the shared build lock (tools/lib.sh's build_lock: the caller's DEVQ_RANK, half the cores, 8 GB).
# Each run copies its APKs, inside the lock, to a folder of its own in app/build/runs/, so builds run at the
# same time in one checkout can't swap each other's APK (#182). Prints the APK path last.
# Version: a release is named ../VERSION (SebType's one version, the Windows setup's too, #420), its code the
# first-parent commit count, which goes on from the FUTO-based releases (0.1.30-sebtype.<count>); debug builds
# are always <VERSION>-dev, code 1, so BuildConfig doesn't change with every commit or branch and Gradle's
# build cache serves every worktree (#58).
set -euo pipefail
cd "$(dirname "$0")"
source ../tools/lib.sh

kind=${1:?usage: android/build.sh release|debug|debug-x86_64|unit-tests}
keydir=${SEBTYPE_KEY_DIR:-$HOME/.config/sebtype}
apksigner() { "$(ls -d "$ANDROID_HOME"/build-tools/* | tail -1)"/apksigner "$@"; }
# A release is built unsigned, here or on the build host, and signed the same way in both cases, as Gradle
# would: APK Signature Scheme v2 alone (minSdk 24), with an RSA key, so the same bytes from either (#229).
sign_release() {
  local apk=${1%-unsigned.apk}.apk
  apksigner sign --ks "$keydir/sebtype-release.jks" --ks-key-alias sebtype --ks-pass "file:$keydir/keystore.password" \
    --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled false --v4-signing-enabled false \
    --out "$apk" "$1" 2>/dev/null
  rm "$1"
  apksigner verify --print-certs "$apk" 2>/dev/null | grep -q 'CN=SebType' ||
    { echo "build: $apk is not signed with SebType's key" >&2; exit 1; }
  echo "$apk"
}
# SEBTYPE_UNSIGNED=1: a release left unsigned (on the build host, for the PC to sign).
unsigned=${SEBTYPE_UNSIGNED:-}
signed=; [[ $kind == release ]] && signed=1
if [[ -n $signed ]]; then
  VERSION_CODE=${VERSION_CODE:-$(git rev-list --first-parent --count HEAD)} VERSION_NAME=$(cat ../VERSION)
  [[ -n $unsigned || ( -f $keydir/sebtype-release.jks && -f $keydir/keystore.password ) ]] ||
    { echo "build: keystore missing in $keydir" >&2; exit 1; }
else VERSION_CODE=1 VERSION_NAME=$(cat ../VERSION)-dev; fi

# Runs older than a day are gone: a caller uses its APK within minutes.
mkdir -p app/build/runs
find app/build/runs -mindepth 1 -maxdepth 1 -mmin +1440 -exec rm -rf {} +

if build_host_ready; then
  apks=$(build_remotely VERSION_CODE="$VERSION_CODE" SEBTYPE_UNSIGNED=1 android/build.sh "$kind")
  [[ -z $signed || -n $unsigned ]] || apks=$(sign_release "$apks")
  echo "$apks"
  exit
fi

# On yanglab16 the tools come pinned into the scratch cache, and the build runs in Fedora, as here
# (fedora_container), with Bazel's cache mounted where it is.
[[ $(hostname -s) != yanglab16 ]] || ../tools/android-tools.sh
fedora_container -v "$BAZEL_CACHE:$BAZEL_CACHE" -w "$PWD"
export JAVA_HOME=$JDK21
[[ -x $JAVA_HOME/bin/javac ]] || { echo "build: JDK 21 not found (set JAVA_HOME_21)" >&2; exit 1; }
[[ -d $ANDROID_HOME/ndk/28.2.13676358 ]] || { echo "build: NDK 28.2.13676358 missing in $ANDROID_HOME" >&2; exit 1; }

export VERSION_CODE VERSION_NAME
case $kind in
  release)
    # Kotlin compiles a release from scratch: an incremental compile infers Compose's stability of some
    # lambdas differently, so the dex (and baseline.prof) depended on what was built before (#223, #229).
    task="assembleRelease -Pkotlin.incremental=false" abis=arm64-v8a out=app/build/outputs/apk/release ;;
  debug-x86_64)
    task=assembleDebug abis=x86_64 out=app/build/outputs/apk/debug ;;
  debug)
    task=assembleDebug abis=arm64-v8a out=app/build/outputs/apk/debug ;;
  unit-tests)
    task=":app:testDebugUnitTest --continue" abis=arm64-v8a out= ;;
  *) echo "build: unknown kind $kind" >&2; exit 2 ;;
esac
# This run's APKs, hard links to Gradle's (which the next build replaces, not overwrites).
run=$(mktemp -d "$PWD/app/build/runs/$kind.XXXXXX")
locked=$run/locked # when the build lock was taken

# Native objects come from sccache when it is installed (CMake takes the launcher from the environment
# when it first configures a checkout). A private server per build, started in the lock (and the container),
# hashes paths relative to the checkout's real root (tools/lib.sh's sccache_env), and build.gradle keeps them
# out of the objects, so every worktree shares the cache.
command -v sccache >/dev/null && sccache_env "$(cd .. && pwd -P)"

start=$(date +%s)
# The Kotlin compiler runs in its own daemon: in-process it recompiles every file on each build. That
# daemon ends with the build, like Gradle's.
export KIND=$kind OUT=$out RUN=$run BUILD_JOBS GRADLE_WORKERS ROOT=$(cd .. && pwd) ROOT_REAL=$(cd .. && pwd -P)
# shellcheck disable=SC2154  # container: set by fedora_container
build_lock 30 "sebtype build ($kind, $(basename "$(cd .. && pwd)"))" "${container[@]}" bash -c '
  set -e
  date +%s > "$RUN/locked"
  # Until #318 sccache could hand a checkout another one'"'"'s objects and depfiles, after which ninja watched
  # that checkout'"'"'s headers instead of this one'"'"'s and never rebuilt them here. A CMake folder like that
  # is configured and built again (its objects from sccache).
  for deps in native/.cxx/*/*/*/.ninja_deps; do
    [[ -f $deps ]] || continue
    if grep -aoE "/[^[:space:][:cntrl:]]*/(core/include/sebtype|engines/[a-z-]+)/" "$deps" |
      grep -qvF -e "$ROOT/" -e "$ROOT_REAL/"; then
      echo "build: $(dirname "$deps") watched another checkout'"'"'s files (#318); building it again" >&2
      rm -rf "$(dirname "$deps")"
    fi
  done
  if [[ -n ${SCCACHE_SERVER_UDS:-} ]]; then
    sccache --start-server >/dev/null
    trap "sccache --stop-server >/dev/null; rm -f $SCCACHE_SERVER_UDS" EXIT
  fi
  [[ -z $OUT ]] || rm -rf "$OUT"
  ./gradlew --no-daemon --max-workers="$GRADLE_WORKERS" -PsebtypeJobs="$BUILD_JOBS" -Dorg.gradle.jvmargs=-Xmx3g \
    -Pkotlin.compiler.execution.strategy=daemon -Pkotlin.daemon.jvmargs=-Xmx2g --console=plain -q "$@" >&2
  [[ -z $OUT ]] || cp -l "$OUT"/*.apk "$RUN/"
' build $task -PsebtypeAbis="$abis"
if [[ $kind == unit-tests ]]; then
  echo "build: unit tests passed in $(( $(date +%s) - $(cat "$locked") ))s after $(( $(cat "$locked") - start ))s in the lock queue" >&2
  exit
fi
apk=$(echo "$run"/*.apk)
[[ -z $signed || -n $unsigned ]] || apk=$(sign_release "$apk")
echo "build: $kind $VERSION_NAME in $(( $(date +%s) - $(cat "$locked") ))s after $(( $(cat "$locked") - start ))s in the lock queue, $(du -h "$apk" | cut -f1)" >&2
echo "$apk"
