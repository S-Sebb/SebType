#!/usr/bin/env bash
# The data steps after fetch.sh, in order: pypinyin's corrected readings (common.py readings), the dev sets
# (android/test/chinese-lm/make_sets.py --dev, in RUN_DIR/dev), the corpus, which leaves them and the test sets
# out (overlap.py checks it), the tokenizer and the packed tokens.
#
#   tools/chinese-lm/prepare.sh RUN_DIR [TRAIN_SEEDS...]     (default seeds: 0 1 2, what config.json trains on)
#
# A step's output is kept only while its inputs are the same (#557): each output has a .stamp next to it, the
# hash of the code and data it was made from, and of the earlier outputs it read.
set -euo pipefail
run=$1; shift
seeds=${*:-0 1 2}
py="$HOME/scratch/SebType/cache/chinese-lm-venv/bin/python -I -W ignore"
cd "$(dirname "$0")"
d=$run/data harness=../../android/test/chinese-lm

# step OUT INPUT... -- COMMAND...: runs COMMAND unless OUT is there with the stamp of these INPUTs. The stamp
# goes first: a step stopped halfway leaves its output without one, so it runs again.
step() {
  local out=$1 inputs=() hash; shift
  while [[ $1 != -- ]]; do inputs+=("$1"); shift; done; shift
  hash=$(for f in "${inputs[@]}"; do
    if [[ -d $f ]]; then find -L "$f" -type f -printf '%P %s %T@\n' | sort; else cat "$f"; fi
  done | sha256sum | cut -c1-16)
  [[ -s $out && $(cat "$out.stamp" 2>/dev/null) == "$hash" ]] && return
  rm -f "$out.stamp"
  "$@"
  echo "$hash" > "$out.stamp"
}

step "$d/readings.tsv" common.py "$d/src/rime-frost-schemas.zip" -- \
  $py common.py readings "$d/src/rime-frost-schemas.zip" "$d/readings.tsv"
step "$run/dev/dev-typo.tsv" $harness/make_sets.py common.py "$d/readings.tsv.stamp" "$d/src" -- \
  $py $harness/make_sets.py "$d/src" "$d/readings.tsv" "$run/dev" --dev
corpus() { $py corpus.py "$run" && $py overlap.py "$run"; }
step "$d/corpus/wikipedia.txt" corpus.py overlap.py common.py $harness/sets "$run/dev/dev-typo.tsv.stamp" "$d/src" -- corpus
step "$d/tokenizer.model" tokenizer.py "$d/corpus/wikipedia.txt.stamp" -- $py tokenizer.py "$run"
packed=(pack.py common.py "$d/tokenizer.model.stamp" "$d/corpus/wikipedia.txt.stamp")
step "$d/dev.0.bin" "${packed[@]}" -- $py pack.py "$run" dev 0
for s in $seeds; do step "$d/train.$s.bin" "${packed[@]}" -- $py pack.py "$run" train "$s"; done
