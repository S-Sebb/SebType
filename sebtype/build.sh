#!/usr/bin/env bash
# Builds a SebType APK under the shared build lock (one heavy Gradle/NDK build at a time). Memory stays
# capped and no Gradle daemon is left running: the PC has 15 GB shared with the emulator and other builds.
#   sebtype/build.sh release       signed arm64-v8a release APK (keystore in ~/.config/sebtype)
#   sebtype/build.sh debug-x86_64  debug APK for an x86_64 emulator
#   sebtype/build.sh test-x86_64   debug APK, then its instrumented-test APK, for an x86_64 emulator
#   sebtype/build.sh debug         debug arm64-v8a APK; the x86_64 ones have no Rime (its aar is arm64
#                                  only), an x86_64 emulator runs this one through its ARM translation
# BUILD_PRIORITY (default 1) is the devq rank for the build lock.
# Prints the APK path last. Version: <FUTO release>-sebtype.<first-parent commit count>.
set -euo pipefail
cd "$(dirname "$0")/.."

kind=${1:?usage: sebtype/build.sh release|debug|debug-x86_64|test-x86_64}
keydir=${SEBTYPE_KEY_DIR:-$HOME/.config/sebtype}
export JAVA_HOME=${JAVA_HOME_21:-$(ls -d "$HOME"/.local/share/jdks/jdk-21* 2>/dev/null | tail -1)}
export ANDROID_HOME=${ANDROID_HOME:-$HOME/Android/Sdk}
[[ -x $JAVA_HOME/bin/javac ]] || { echo "build: JDK 21 not found (set JAVA_HOME_21)" >&2; exit 1; }
[[ -d $ANDROID_HOME/ndk/28.2.13676358 ]] || { echo "build: NDK 28.2.13676358 missing in $ANDROID_HOME" >&2; exit 1; }

git submodule update --init --depth 1 >&2
# Mozc's Japanese dictionary (pinned URL and sha256 in FUTO's script), bundled like FUTO's Play Store build.
python3 java/res-bundle/download-bundles.py "$PWD/java/res-bundle" >&2

export VERSION_CODE=$(git rev-list --first-parent --count HEAD)
export VERSION_NAME="$(cat sebtype/upstream-version)-sebtype.$VERSION_CODE"
export BRANCH_NAME=$(git branch --show-current)

case $kind in
  release)
    [[ -f $keydir/sebtype-release.jks && -f $keydir/keystore.password ]] ||
      { echo "build: keystore missing in $keydir" >&2; exit 1; }
    task=assembleStableRelease abis=arm64-v8a out=build/outputs/apk/stable/release
    # Gradle reads signing from keystore.properties (gitignored); it exists only during the build.
    trap 'rm -f keystore.properties' EXIT
    pw=$(cat "$keydir/keystore.password")
    printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=sebtype\nkeyPassword=%s\n' \
      "$keydir/sebtype-release.jks" "$pw" "$pw" > keystore.properties ;;
  debug-x86_64)
    task=assembleStableDebug abis=x86_64 out=build/outputs/apk/stable/debug ;;
  test-x86_64)
    task="assembleStableDebug assembleStableDebugAndroidTest" abis=x86_64 out=build/outputs/apk/stable/debug
    rm -rf build/outputs/apk/androidTest ;;
  debug)
    task=assembleStableDebug abis=arm64-v8a out=build/outputs/apk/stable/debug ;;
  *) echo "build: unknown kind $kind" >&2; exit 2 ;;
esac

rm -rf "$out"
start=$(date +%s)
devq -P "${BUILD_PRIORITY:-1}" -m 30 -n "sebtype build ($kind)" /tmp/agent-locks/sebtype/build.lock \
  ./gradlew --no-daemon --max-workers=4 -Dorg.gradle.jvmargs=-Xmx3g \
    -Pkotlin.compiler.execution.strategy=in-process --console=plain -q $task -PsebtypeAbis="$abis" >&2
# The APK is named after the checkout's folder (no rootProject.name), so take the only one there.
apk=$(ls "$out"/*.apk)
echo "build: $kind $VERSION_NAME in $(( $(date +%s) - start ))s, $(du -h "$apk" | cut -f1)" >&2
echo "$apk"
[[ $kind != test-x86_64 ]] || ls build/outputs/apk/androidTest/stable/debug/*.apk
