#!/usr/bin/env bash
# Builds the English harness and runs every stack on every test set.
#
#   android/test/english/bench.sh RUN_NAME
#
# Writes the raw results and score.py's summary to ~/scratch/SebType/<issue>/english/RUN_NAME/ and prints
# the summary's path last. The build fetches pristine AOSP LatinIME at a pinned commit into the cache.
set -euo pipefail
cd "$(dirname "$0")/../../.."
source tools/lib.sh

run=$1
here=android/test/english
out=$TASK_OUT/english/$run
# The whole run holds this machine's build lock, under its CPU and memory caps. Only the results' paths
# go to stdout: the lock's own messages go to stderr.
if [[ ! ${ENGLISH_IN_LOCK:-} ]]; then
  build_lock 90 english-harness env ENGLISH_IN_LOCK=1 $here/bench.sh "$@" >&2
  ls "$out"/*.tsv "$out"/*.log
  echo "$out/summary.json"
  exit
fi
# Pristine AOSP LatinIME (Apache-2.0) from AOSP's own repository, never FUTO's copy (§4 of the plan).
AOSP_URL=https://android.googlesource.com/platform/packages/inputmethods/LatinIME
AOSP_COMMIT=127336e9f29d69607eab55982324b210279ae8c5
aosp=$SCRATCH/cache/aosp-latinime-${AOSP_COMMIT:0:12}

if [[ $(git -C "$aosp" rev-parse HEAD 2>/dev/null) != "$AOSP_COMMIT" ]]; then
  rm -rf "$aosp.part" && git init -q "$aosp.part"
  git -C "$aosp.part" fetch -q --depth 1 "$AOSP_URL" "$AOSP_COMMIT"
  git -C "$aosp.part" checkout -q FETCH_HEAD
  rm -rf "$aosp" && mv "$aosp.part" "$aosp"
fi

export JAVA_HOME=${JAVA_HOME:-$JDK21}  # for jni.h
mkdir -p "$out"
rm -f "$out"/*.tsv
build=$here/build
# SebType's own model: the committed one (engines/sebtype-lm/english.gguf), or SEBTYPE_MODEL, a GGUF file on
# this machine (tools/english-lm). llama.cpp (MIT) is fetched at a pinned commit too.
model=${SEBTYPE_MODEL:-engines/sebtype-lm/english.gguf}
llama=$(engines/sebtype-lm/fetch-llama.sh)
cmake -S $here -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release -DAOSP_JNI="$aosp/native/jni" -DLLAMA_DIR="$llama" \
  > "$out/build.log"
ninja -C $build -j "$BUILD_JOBS" >> "$out/build.log"

# Stacks: name, executable, its files. core is the keyboard's English (core/src/english.cpp on the rebuilt
# dictionary, #244), which the plan's bar gates against today.json: the FUTO-based app's English, measured on
# its last main before it was removed (#262).
stacks=(
  "aosp english-aosp $here/layout.tsv $aosp/java/res/raw/main_en.dict"
  "sebtype english-sebtype $here/layout.tsv $aosp/java/res/raw/main_en.dict $model"
  "core english-core $here/layout.tsv data/en-dict/en_US.dict $model"
)
# One process per stack and set; each runs on one thread (the model's own setting), BUILD_JOBS at a time.
jobs=()
for s in "${stacks[@]}"; do
  read -r name exe files <<< "$s"
  for set in $here/sets/*.tsv; do
    [[ $set == */wikinews-articles.tsv ]] && continue
    jobs+=("$build/$exe $set $out/$name.$(basename "$set") $files")
  done
done
printf '%s\n' "${jobs[@]}" | xargs -P "$BUILD_JOBS" -I{} sh -c '{} 2>>"$0/run.log"' "$out"
python3 -I $here/score.py "$out" > "$out/summary.json"
