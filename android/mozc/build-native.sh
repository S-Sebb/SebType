#!/usr/bin/env bash
# Builds libmozc.so, Mozc's engine for the phone, from engines/mozc with Bazel: the same Mozc the PCs run.
#
#   android/mozc/build-native.sh OUT_DIR ABI...   # ABI: arm64-v8a or x86_64 -> OUT_DIR/<ABI>/libmozc.so
#
# Gradle runs it (build.gradle) inside android/build.sh's build lock, so it takes no lock itself, and uses
# the lock's share of the cores. Bazel's
# output stays in ~/scratch/sebtype/cache/mozc-android, its disk cache shared by every worktree; its server
# exits soon after the build.
set -euo pipefail
out=$1; shift
src=$(cd "$(dirname "$0")/../../engines/mozc/src" && pwd)
export SEBTYPE_ANDROID_NDK=${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must name the app\'s NDK}
# The Bazelisk the Linux build pins; it runs the Bazel version engines/mozc/src/.bazeliskrc names.
source "$src/../../../pc/linux/mozc/versions.sh"
source "$src/../../../tools/lib.sh"
cache=$SCRATCH/cache/mozc-android
bazelisk=$cache/bazelisk-${BAZELISK_SHA256:0:12}
if [[ ! -x $bazelisk ]]; then
  mkdir -p "$cache"
  curl -sfL --retry 3 -o "$bazelisk.tmp" "$BAZELISK_URL"
  echo "$BAZELISK_SHA256  $bazelisk.tmp" | sha256sum -c --status
  chmod +x "$bazelisk.tmp" && mv "$bazelisk.tmp" "$bazelisk"
fi
export BAZELISK_HOME=$cache/bazelisk

declare -A target=([arm64-v8a]=mozc.arm64 [x86_64]=mozc.x86_64)
targets=()
for abi; do targets+=("//android/jni:${target[$abi]:?no Mozc target for $abi}"); done
bazel() {
  (cd "$src" && "$bazelisk" --output_user_root="$cache/bazel" --max_idle_secs=15 --host_jvm_args=-Xmx2g "$@")
}
opts=(--config oss_android --config release_build --jobs="$BUILD_JOBS" --disk_cache="$cache/disk"
  --symlink_prefix=/ --noshow_progress)
bazel build "${opts[@]}" "${targets[@]}"
for abi; do
  lib=$(bazel cquery "${opts[@]}" --output=files "//android/jni:${target[$abi]}" 2>/dev/null)
  mkdir -p "$out/$abi"
  cp -f "$(bazel info "${opts[@]}" execution_root 2>/dev/null)/$lib" "$out/$abi/libmozc.so"
done
