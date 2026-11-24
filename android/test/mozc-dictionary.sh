#!/usr/bin/env bash
# Checks the phone's Japanese dictionary (android/app/mozc-dictionary.sh, #335) without a device: builds it
# from engines/mozc on the build host, as the APK build does, with the PCs' Mozc library (libsebtype-mozc.so,
# which opens a data file as the phone's does), then loads it into that Mozc here and types each word in
# mozc-words.tsv: its suggestions and conversion must be the candidates listed there, in that order.
#   android/test/mozc-dictionary.sh
# One line per check; logs in ~/scratch/SebType/<issue>/test-mozc-dictionary/. Exit 0 only if all pass.
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
source linux/versions.sh

# On the build host: the dictionary and the library, in the build lock and the build's Fedora container.
if [[ ${1:-} == build ]]; then
  dir=$TASK_OUT/mozc-dictionary
  [[ $(hostname -s) != yanglab16 ]] || tools/android-tools.sh >&2
  fedora_container -v "$BAZEL_CACHE:$BAZEL_CACHE" -w "$PWD"
  ANDROID_NDK_HOME=$ANDROID_HOME/ndk/28.2.13676358 build_lock 30 mozc-dictionary "${container[@]}" bash -c '
    set -e; source tools/lib.sh; source tools/mozc-bazel.sh
    bash android/app/mozc-dictionary.sh "$1"
    mozc_bazel oss_linux build //sebtype:libsebtype-mozc.so
    cp -f "$(mozc_files oss_linux //sebtype:libsebtype-mozc.so)" "$1"' - "$dir" >&2 || exit 1
  echo "$dir/raw-ja/builtin_mozc_data.dict $dir/libsebtype-mozc.so"
  exit
fi

out=$TASK_OUT/test-mozc-dictionary; mkdir -p "$out"
command -v python3 >/dev/null || { echo "preflight: python3 missing"; exit 1; }
build_host_ready || { echo "preflight: build host $BUILD_HOST unreachable"; exit 1; }
status=0
result() { echo "$1 $2${3:+: $3}"; [[ $1 == PASS ]] || status=1; }
# The build waits in the build lock (up to 90 minutes) and times out there.
if files=$(build_remotely android/test/mozc-dictionary.sh build 2> "$out/build.log"); then result PASS build
else result FAIL build "$(tail -1 "$out/build.log")"; exit 1; fi
read -rd "" dict lib <<<"$files"
if timeout 300 python3 -I android/test/mozc-candidates.py "$lib" "$dict" android/test/mozc-words.tsv \
    > "$out/candidates.log" 2>&1; then result PASS candidates "$(tail -1 "$out/candidates.log")"
else result FAIL candidates "$(tail -1 "$out/candidates.log")"; fi
exit $status
