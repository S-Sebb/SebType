#!/usr/bin/env bash
# The data steps after fetch.sh and the harness's sets, in order: corpus, tokenizer, packed tokens.
#
#   tools/chinese-lm/prepare.sh RUN_DIR [TRAIN_SEEDS...]     (default seeds: 0 1 2, what config.json trains on)
#
# RUN_DIR/dev holds the dev sets (android/test/chinese-lm/make_sets.py --dev), which the corpus leaves out too.
set -euo pipefail
run=$1; shift
seeds=${*:-0 1 2}
py="$HOME/scratch/SebType/cache/chinese-lm-venv/bin/python -W ignore"
cd "$(dirname "$0")"
[[ -s $run/dev/dev-typo.tsv ]] || { echo "prepare: $run/dev has no dev sets (make_sets.py --dev)"; exit 1; }
[[ -s $run/data/corpus/wikipedia.txt ]] || $py corpus.py "$run"
[[ -s $run/data/tokenizer.model ]] || $py tokenizer.py "$run"
$py pack.py "$run" dev 0
for s in $seeds; do [[ -s $run/data/train.$s.bin ]] || $py pack.py "$run" train "$s"; done
