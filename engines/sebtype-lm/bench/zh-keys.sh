#!/usr/bin/env bash
# The Chinese model's jobs on a phone (#264), without the keyboard: sebtype-zh-keys (zh_keys.cpp) built for
# arm64 with the app's llama.cpp (its CPU code in variants, the best loaded at run time), then run on the
# phone ANDROID_SERIAL names, under its lock, on its big cores (f0), its little ones (0f) and all of them (ff).
#
#   ANDROID_SERIAL=<serial> engines/sebtype-lm/bench/zh-keys.sh [THREADS...]   default: 2 4
#
# Prints a line per cores and threads: ranking and next words, p50 / p95. Full output in
# ~/scratch/SebType/<issue>/zh-keys/.
set -euo pipefail
cd "$(dirname "$0")/../../.."
source tools/lib.sh

out=$TASK_OUT/zh-keys
if [[ ${1:-} == --build ]]; then  # in the build lock: the binary and its libraries, into $out/bin
  ndk=$(ls -d "$ANDROID_HOME"/ndk/* | tail -1)
  build=engines/sebtype-lm/bench/build-android
  cmake -S engines/sebtype-lm/bench -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=24 \
    -DLLAMA_DIR="$(engines/sebtype-lm/fetch-llama.sh)" > /dev/null
  ninja -C $build -j "$BUILD_JOBS" sebtype-zh-keys ggml-cpu-android_armv8.0_1 ggml-cpu-android_armv8.2_2 \
    ggml-cpu-android_armv8.6_1 > /dev/null
  rm -rf "$out/bin" && mkdir -p "$out/bin"
  cp $build/sebtype-zh-keys $build/bin/*.so "$out/bin/"
  "$ndk"/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip "$out"/bin/*
  ls -d "$out"/bin/*
  exit
fi
if [[ ${1:-} == --run ]]; then  # under the phone's lock
  shift
  adb=$ANDROID_HOME/platform-tools/adb d=/data/local/tmp/sebtype-zh-keys
  trap '"$adb" shell rm -rf $d' EXIT
  "$adb" shell mkdir -p $d
  "$adb" push -q "$out"/bin/* engines/sebtype-lm/chinese.gguf $d/ > /dev/null
  "$adb" shell chmod 755 $d/sebtype-zh-keys
  for cores in f0 0f ff; do
    for t in "$@"; do
      "$adb" shell "cd $d && LD_LIBRARY_PATH=. taskset $cores ./sebtype-zh-keys chinese.gguf $t 3 700" > "$out/$cores-t$t.txt" 2>&1
      echo "cores $cores: $(tail -1 "$out/$cores-t$t.txt" | sed 's/^# //')"
    done
  done
  exit
fi

[[ -n ${ANDROID_SERIAL:-} ]] || { echo "zh-keys: ANDROID_SERIAL names the phone"; exit 1; }
mkdir -p "$out"
build_lock 20 sebtype-zh-keys engines/sebtype-lm/bench/zh-keys.sh --build > /dev/null
(( $# )) || set -- 2 4
android/emulator.sh -w 1800 -m 15 -n "sebtype zh-keys.sh" -- "$PWD/engines/sebtype-lm/bench/zh-keys.sh" --run "$@"
