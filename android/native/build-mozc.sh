#!/usr/bin/env bash
# Builds libmozc.so, Mozc's engine for the phone, from engines/mozc with Bazel: the same Mozc the PCs run.
#
#   android/native/build-mozc.sh OUT_DIR ABI...   # ABI: arm64-v8a or x86_64 -> OUT_DIR/<ABI>/libmozc.so
#
# Gradle runs it (build.gradle) inside android/build.sh's build lock, with the lock's share of the cores.
# Bazel's output stays in ~/scratch/SebType/cache/mozc-android (tools/mozc-bazel.sh's mozc_bazel), its disk
# cache shared by every worktree.
set -euo pipefail
out=$1; shift
source "$(dirname "$0")/../../tools/lib.sh"
source "$(dirname "$0")/../../tools/mozc-bazel.sh"

declare -A target=([arm64-v8a]=mozc.arm64 [x86_64]=mozc.x86_64)
targets=()
for abi; do targets+=("//android/jni:${target[$abi]:?no Mozc target for $abi}"); done
mozc_bazel oss_android build "${targets[@]}"
for abi; do
  mkdir -p "$out/$abi"
  cp -f "$(mozc_files oss_android "//android/jni:${target[$abi]}")" "$out/$abi/libmozc.so"
done
