#!/usr/bin/env bash
# Builds core_test with SebType's Chinese model around a stand-in Rime (no librime or Mozc) and runs it, on
# yanglab16 in the pinned Fedora container, for its OpenCC. llama.cpp and GoogleTest are fetched at pinned
# commits into the cache (linux/versions.sh).
#
#   core/test/chinese.sh [GTEST_FILTER]
#
# Prints the test's log path last (~/scratch/SebType/<issue>/core-chinese.log); exit 0 only if all pass.
set -euo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh

if [[ ! ${CORE_IN_LOCK:-} ]]; then
  log=$TASK_OUT/core-chinese.log
  mkdir -p "$TASK_OUT"
  fedora_container
  extra="opencc-devel cmake ninja-build gtest-devel"
  if [[ ${#container[@]} -gt 0 ]]; then
    base=${container[-1]}
    image=localhost/sebtype-fedora-core:$(sha256sum <<<"$base $extra" | head -c 12)
    podman image exists "$image" ||
      podman build -q -t "$image" -f - "$CACHE" <<<"FROM $base
RUN dnf -y install $extra && dnf clean all" >/dev/null
    container=("${container[@]:0:${#container[@]}-1}" -w "$(pwd -P)" "$image")
  fi
  # llama.cpp is fetched out here: the container has git, but this keeps one checkout for every build.
  llama=$(engines/sebtype-lm/fetch-llama.sh)
  build_lock 30 core-chinese "${container[@]}" env CORE_IN_LOCK=1 LLAMA_DIR="$llama" core/test/chinese.sh "$@" \
    > "$log" 2>&1 || { status=$?; tail -40 "$log" >&2; }
  echo "$log"
  exit "${status:-0}"
fi

build=$TASK_OUT/core-chinese-build-$(pwd -P | sha256sum | head -c 8)
cmake -S core -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DSEBTYPE_CJK=OFF -DSEBTYPE_CHINESE_MODEL=ON \
  -DLLAMA_DIR="$LLAMA_DIR"
ninja -C "$build" -j "$BUILD_JOBS" core-test
"$build/core-test" ${1:+--gtest_filter="$1"}
