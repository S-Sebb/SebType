#!/usr/bin/env bash
# Builds the Chinese harness and runs today's 中文 (and, given a model, today's 中文 with the model) on every
# set, here (run.sh starts it on yanglab16). On yanglab16 it runs in the pinned Fedora container
# (tools/lib.sh, fedora_container) with Fedora's librime and its Lua and octagram plugins, as SebType's Linux
# build does, in the build lock and under its caps.
#
#   [CHINESE_CORE=1] android/test/chinese-lm/bench.sh RUN_NAME [MODEL.gguf [NAME=VALUE...] [-- NAME=VALUE...]]
#                                    NAME=VALUE: zhbench's options; after --, those a third stack ("gen", the
#                                    model with its own candidates) adds to them. CHINESE_CORE=1 adds the
#                                    keyboard's own code ("core", zhbench's core=1), with the model.
#   [CHINESE_CORE=1] android/test/chinese-lm/bench.sh --dev DEV_DIR OUT_DIR MODEL.gguf [NAME=VALUE...]  only
#                                    the model (and the keyboard's own code), on the dev sets in DEV_DIR (tune.py)
#
# Writes each stack's results per set and score.py's summary to ~/scratch/SebType/<issue>/chinese/RUN_NAME/
# and prints the results' paths, the summary's last.
set -euo pipefail
cd "$(dirname "$0")/../../.."
source tools/lib.sh
here=android/test/chinese-lm

if [[ ! ${CHINESE_IN_CONTAINER:-} ]]; then
  # The base build image plus librime's headers, its octagram plugin and the harness's build tools.
  fedora_container
  if [[ ${#container[@]} -gt 0 ]]; then
    extra="librime-devel librime-octagram opencc-devel cmake ninja-build"
    base=${container[-1]}
    image=localhost/sebtype-fedora-zh:$(sha256sum <<<"$base $extra" | head -c 12)
    podman image exists "$image" ||
      podman build -q -t "$image" -f - "$SCRATCH/cache" <<<"FROM $base
RUN dnf -y --setopt=throttle=35M install $extra && dnf clean all" >/dev/null
    container=("${container[@]:0:${#container[@]}-1}" -w "$(pwd -P)" "$image")
  fi
  # llama.cpp (MIT) is fetched at its pinned commit out here: the container has no git.
  llama=$(engines/sebtype-lm/fetch-llama.sh)
  # Only the results' paths go to stdout (build_remotely copies what it names back): each set's, which
  # score.py --compare reads, and the summary's last.
  build_lock 120 chinese-harness "${container[@]}" env CHINESE_IN_CONTAINER=1 ISSUE="${ISSUE:-}" LLAMA_DIR="$llama" CHINESE_CORE="${CHINESE_CORE:-}" \
    $here/bench.sh "$@" >&2
  [[ $1 == --dev ]] && exit
  printf '%s\n' "$TASK_OUT/chinese/$1"/*.tsv "$TASK_OUT/chinese/$1/summary.json"
  exit
fi

dev=
if [[ $1 == --dev ]]; then dev=$2; out=$3; shift 3; else out=$TASK_OUT/chinese/$1; shift; fi
model=${1:-}; shift || true
options=() gen=()
while (($#)) && [[ $1 != -- ]]; do options+=("$1"); shift; done
(($#)) && { shift; gen=("$@"); }
mkdir -p "$out"
rm -f "$out"/*.tsv "$out"/*.keys
work=$(mktemp -d "$SCRATCH/cache/chinese-bench.XXXXXX")
trap 'rm -rf "$work"' EXIT
# The build stays between runs (tune.py runs the dev sets many times), one per checkout: CMake ties a build
# folder to its source folder.
build=$TASK_OUT/chinese/build-$(pwd -P | sha256sum | head -c 8)

# The data the apps ship (data/rime/build.sh), unpacked as the Linux setup does.
zip=$(data/rime/build.sh "$work/assets" | tail -1)
mkdir -p "$work/shared" && unzip -q "$zip" -d "$work/shared"
cmake -S $here -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DLLAMA_DIR="$LLAMA_DIR" > "$out/build.log"
ninja -C "$build" -j "$BUILD_JOBS" zhbench zh_lm_test >> "$out/build.log"
[[ $model ]] && "$build/zh_lm_test" "$model" | tee -a "$out/test.log" >&2

# Rime deploys into the user folder on its first start (unzip keeps mtimes only to 2 s, so it rebuilds the
# schema); every job then starts from a copy of that folder, so none of them measures the deploy.
head -1 $here/sets/sent-chat.tsv > "$work/prime.tsv"
"$build/zhbench" "$work/shared" "$work/user" "$work/prime.tsv" "$work/prime.out" 2>> "$out/run.log"

if [[ $dev ]]; then sets=("$dev"/dev-*.tsv); else sets=($here/sets/*.tsv); fi
stacks=(rime)
[[ $model ]] && stacks+=(model)
((${#gen[@]})) && stacks+=(gen)
[[ $model && ${CHINESE_CORE:-} ]] && stacks+=(core)
[[ $dev ]] && stacks=(model ${CHINESE_CORE:+core})
jobs=()
for stack in "${stacks[@]}"; do
  for set in "${sets[@]}"; do
    [[ $set == *wikinews-articles.tsv ]] && continue
    name=$(basename "$set" .tsv)
    args=("$work/shared" "$work/user-$stack-$name" "$set" "$out/$stack.$name.tsv")
    [[ $stack == model ]] && args+=("$model" "${options[@]}")
    [[ $stack == gen ]] && args+=("$model" "${options[@]}" "${gen[@]}")
    [[ $stack == core ]] && args+=("$model" core=1 "${options[@]}")
    jobs+=("cp -r $work/user $work/user-$stack-$name && $build/zhbench ${args[*]}")
  done
done
# Each job runs on one thread (threads=N: N); 16 at a time (CHINESE_JOBS) leave most of the machine to others
# and the latencies steady.
printf '%s\n' "${jobs[@]}" | xargs -P "${CHINESE_JOBS:-16}" -I{} sh -c '{} 2>>"$0/run.log"' "$out"
[[ $dev ]] || python3 -I $here/score.py "$out" > "$out/summary.json"
