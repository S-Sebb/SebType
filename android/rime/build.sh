#!/usr/bin/env bash
# Builds the Rime Android library (RimeJni aar, Kotlin API icu.astronot233.rime.*)
# with librime-lua and librime-octagram, from pinned sources.
#
#   ./build.sh                    # arm64-v8a aar -> out/rime-android-<version>-arm64-v8a.aar
#   RIME_ABIS=x86_64 ./build.sh   # emulator variant for the smoke test
#
# Native builds run under the shared build lock (one heavy build at a time).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/versions.sh"

ABIS="${RIME_ABIS:-arm64-v8a}"
WORK="$HERE/work/RimeJni"
OUT="$HERE/out"
AAR="$OUT/rime-android-$RIME_ANDROID_VERSION-${ABIS//,/-}.aar"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
# JDK 21 (looked for in ~/.local/share/jdks first).
if [[ -z "${JAVA_HOME:-}" ]]; then
  JAVA_HOME="$(ls -d "$HOME"/.local/share/jdks/jdk-21* /usr/lib/jvm/java-21-openjdk 2>/dev/null | head -1)"
fi
export JAVA_HOME

# Fresh checkout at the pinned commit, then our patch. Downloads are cached
# across runs (their checksums are checked by RimeJni's CMake).
if [[ ! -d "$WORK/.git" ]]; then
  git clone --quiet "$RIMEJNI_URL" "$WORK"
fi
git -C "$WORK" fetch --quiet origin "$RIMEJNI_COMMIT" 2>/dev/null || true
git -C "$WORK" checkout --quiet --force "$RIMEJNI_COMMIT"
git -C "$WORK" clean --quiet -fdx -e rime/src/main/jni/Downloads
git -C "$WORK" apply "$HERE"/patches/*.patch
echo "sdk.dir=$ANDROID_HOME" > "$WORK/local.properties"

# Optional extra test sources (the smoke test copies them in before calling us).
if [[ -n "${RIME_ANDROID_TEST_DIR:-}" ]]; then
  mkdir -p "$WORK/rime/src/androidTest"
  cp -r "$RIME_ANDROID_TEST_DIR"/. "$WORK/rime/src/androidTest/"
fi

TASKS=(":rime:assembleRelease")
[[ -n "${RIME_ANDROID_GRADLE_TASKS:-}" ]] && read -ra TASKS <<<"$RIME_ANDROID_GRADLE_TASKS"

# Native objects come from sccache when it is installed (CMake reads the launcher from the environment):
# a rebuild takes 31 s instead of 130 s and gives the same aar (#58). The objects hold their source paths,
# so they are shared only within this checkout (no SCCACHE_BASEDIRS, unlike android/build.sh).
if command -v sccache >/dev/null; then
  SCCACHE_SERVER_UDS=$(mktemp -u /tmp/rime-android-sccache.XXXXXX)
  export CMAKE_C_COMPILER_LAUNCHER=sccache CMAKE_CXX_COMPILER_LAUNCHER=sccache SCCACHE_SERVER_UDS
  sccache --start-server >/dev/null
  trap 'sccache --stop-server >/dev/null; rm -f "$SCCACHE_SERVER_UDS"' EXIT
fi

devq -w 3600 -m 30 -P "${DEVQ_RANK:-2}" -n "rime-android build" /tmp/agent-locks/sebtype/build.lock \
  bash -c 'cd "$1" && shift && ./gradlew --no-daemon --console=plain -PrimeAbis="$0" "$@"' \
  "$ABIS" "$WORK" "${TASKS[@]}"

mkdir -p "$OUT"
cp "$WORK/rime/build/outputs/aar/rime-release.aar" "$AAR"
echo "$AAR"
sha256sum "$AAR"
