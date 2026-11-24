#!/usr/bin/env bash
# The data steps after fetch.sh, in order: corpus, tokenizer and typo bank, dev sets, packed tokens. Once the
# tokenizer is there, test.py checks the steps' own code.
#
#   tools/english-lm/prepare.sh RUN_DIR [TRAIN_SEEDS...]     (default seeds: 0 1 2, what config.json trains on)
#
# A step's output is kept only while its inputs are the same: each output has a .stamp next to it, the hash
# of the code and data it was made from, and of the earlier outputs it read. The tokenizer is the exception:
# a run copies r2's into data/ first (README.md), so one that is there is kept; without one, prepare.sh stops
# unless NEW_TOKENIZER=1 asks for a new one.
set -euo pipefail
run=$1; shift
seeds=${*:-0 1 2}
py="$HOME/scratch/SebType/cache/english-lm-venv/bin/python"
cd "$(dirname "$0")"
d=$run/data harness=../../android/test/english dict=../../data/en-dict/en_US.dict

# A missed copy of r2's tokenizer would train a new one, and the run would no longer match the pilots.
if [[ ! -s $d/tokenizer.model && ${NEW_TOKENIZER:-} != 1 ]]; then
  echo "prepare.sh: no $d/tokenizer.model: copy r2's (README.md), or set NEW_TOKENIZER=1 to train one" >&2
  exit 1
fi

# step OUT INPUT... -- COMMAND...: runs COMMAND unless OUT is there with the stamp of these INPUTs.
step() {
  local out=$1 inputs=() hash; shift
  while [[ $1 != -- ]]; do inputs+=("$1"); shift; done; shift
  hash=$(for f in "${inputs[@]}"; do
    if [[ -d $f ]]; then find -L "$f" -type f -printf '%P %s %T@\n' | sort; else cat "$f"; fi
  done | sha256sum | cut -c1-16)
  [[ -s $out && $(cat "$out.stamp" 2>/dev/null) == "$hash" ]] && return
  rm -f "$out.stamp"  # a rebuild that fails leaves no stamp on what it wrote
  "$@"
  echo "$hash" > "$out.stamp"
}

step "$d/corpus/wikipedia.txt" corpus.py $harness/sets $dict "$d/src" -- $py -I corpus.py "$run"
[[ -s $d/tokenizer.model ]] || $py -I tokenizer.py "$run"
$py -I test.py "$run"
step "$d/typos.tsv" noise.py $harness/make_sets.py $harness/layout.tsv "$d/corpus/wikipedia.txt.stamp" -- \
  $py -I noise.py "$run"
$py -I dev_sets.py "$run"
packed=(pack.py noise.py $harness/make_sets.py $dict "$d/tokenizer.model" "$d/typos.tsv.stamp" "$d/corpus/wikipedia.txt.stamp")
step "$d/dev.0.bin" "${packed[@]}" -- $py -I pack.py "$run" dev 0
for s in $seeds; do step "$d/train.$s.bin" "${packed[@]}" -- $py -I pack.py "$run" train "$s"; done
