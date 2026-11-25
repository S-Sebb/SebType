#!/usr/bin/env bash
# The model's context window in long text (#359): how long the next words and rankings take after an empty
# field and after 20,000 characters, and how often the next word is predicted with each window rule, on 60
# Wikinews articles (fetched once into the cache, as android/test/english/make_sets.py fetches them). Runs in
# the build lock, on one thread as the phone.
#
#   engines/sebtype-lm/bench/bench.sh [time]     time only: no articles, a minute
#
# Prints the results and writes them to ~/scratch/SebType/<issue>/sebtype-lm-window.txt.
set -euo pipefail
cd "$(dirname "$0")/../../.."
source tools/lib.sh

out=$TASK_OUT/sebtype-lm-window.txt
mkdir -p "$TASK_OUT"
if [[ ! ${BENCH_IN_LOCK:-} ]]; then
  build_lock 60 sebtype-lm-window env BENCH_IN_LOCK=1 engines/sebtype-lm/bench/bench.sh "$@" >&2
  cat "$out"
  exit
fi

articles=$SCRATCH/cache/wikinews-60.json
if [[ ${1:-} != time && ! -s $articles ]]; then
  python3 -I -c 'import sys; sys.path.insert(0, "android/test/english"); import make_sets
make_sets.fetch_wikinews(sys.argv[1] + ".part", 60)' "$articles" && mv "$articles.part" "$articles"
fi
build=engines/sebtype-lm/bench/build
cmake -S engines/sebtype-lm/bench -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_DIR="$(engines/sebtype-lm/fetch-llama.sh)" > /dev/null
ninja -C $build -j "$BUILD_JOBS" sebtype-lm-window > /dev/null
model=engines/sebtype-lm/english.gguf
{
  echo "$(uname -n), model $(sha256sum $model | cut -c1-12)"
  $build/sebtype-lm-window $model time
  if [[ ${1:-} != time ]]; then
    python3 -I -c 'import json, sys
for a in json.load(open(sys.argv[1])):
    for p in a["text"].splitlines():
        if p.strip(): print(" ".join(p.split()))' "$articles" > "$TASK_OUT/wikinews-paragraphs.txt"
    $build/sebtype-lm-window $model quality "$TASK_OUT/wikinews-paragraphs.txt"
  fi
} > "$out"
