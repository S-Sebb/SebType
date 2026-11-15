#!/usr/bin/env bash
# Builds core_test with the English engine (no 中文 or 日本語: those need librime and Mozc) and runs it, on
# the build host (yanglab16) unless SEBTYPE_BUILD_HOST=local. GoogleTest and llama.cpp are fetched at pinned
# commits into the scratch cache.
#
#   core/test/english.sh
#
# Prints the test's log path last (~/scratch/SebType/<issue>/core-english.log); exit 0 only if all pass.
set -euo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh

if [[ $BUILD_HOST != local ]] && build_host_ready; then
  build_remotely core/test/english.sh
  exit
fi
if [[ ! ${CORE_IN_LOCK:-} ]]; then
  log=$TASK_OUT/core-english.log
  mkdir -p "$TASK_OUT"
  build_lock 30 core-english env CORE_IN_LOCK=1 core/test/english.sh > "$log" 2>&1 ||
    { status=$?; tail -40 "$log" >&2; }
  echo "$log"
  exit "${status:-0}"
fi

GTEST_COMMIT=52eb8108c5bdec04579160ae17225d66034bd723  # v1.17.0
gtest=$SCRATCH/cache/googletest-${GTEST_COMMIT:0:12}
if [[ ! -f $gtest/install/lib/cmake/GTest/GTestConfig.cmake ]]; then
  rm -rf "$gtest" && git init -q "$gtest/src"
  git -C "$gtest/src" fetch -q --depth 1 https://github.com/google/googletest "$GTEST_COMMIT"
  git -C "$gtest/src" checkout -q FETCH_HEAD
  cmake -S "$gtest/src" -B "$gtest/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_GMOCK=OFF \
    -DCMAKE_INSTALL_PREFIX="$gtest/install"
  ninja -C "$gtest/build" install
fi

export JAVA_HOME=${JAVA_HOME:-$JDK21}  # for jni.h
build=core/build/english
cmake -S core -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release -DSEBTYPE_CJK=OFF -DSEBTYPE_ENGLISH=ON \
  -DLLAMA_DIR="$(engines/sebtype-lm/fetch-llama.sh)" -DCMAKE_PREFIX_PATH="$gtest/install"
ninja -C $build -j "$BUILD_JOBS" core-test
$build/core-test
