#!/usr/bin/env bash
# The data steps after fetch.sh, in order: corpus, tokenizer and typo bank, dev sets, packed tokens.
#
#   tools/english-lm/prepare.sh RUN_DIR [TRAIN_SEEDS...]     (default seeds: 0 1 2, what config.json trains on)
set -euo pipefail
run=$1; shift
seeds=${*:-0 1 2}
py="$HOME/scratch/SebType/cache/english-lm-venv/bin/python"
cd "$(dirname "$0")"
[[ -s $run/data/corpus/wikipedia.txt ]] || $py -I corpus.py "$run"
[[ -s $run/data/tokenizer.model ]] || $py -I tokenizer.py "$run"
[[ -s $run/data/typos.tsv ]] || $py -I noise.py "$run"
$py -I dev_sets.py "$run"
$py -I pack.py "$run" dev 0
for s in $seeds; do [[ -s $run/data/train.$s.bin ]] || $py -I pack.py "$run" train "$s"; done
