#!/usr/bin/env bash
# Chooses a run's checkpoint on the dev sets: exports each of train.py's (every save_every steps, and the
# last), runs dev.sh on it and prints tune.py's gain per checkpoint, the best last. On yanglab16.
#
#   tools/english-lm/select.sh RUN_DIR NAME
set -euo pipefail
run=$1 name=$2
here=$(dirname "$0")
best= top=-1
for ckpt in "$run"/ckpt/"$name"/step-* "$run/ckpt/$name"; do
  [[ -s $ckpt/model.safetensors ]] || continue
  gguf=$run/select/$(basename "$ckpt").gguf
  mkdir -p "$run/select"
  "$here/export.sh" "$ckpt" "$gguf" > /dev/null
  gain=$("$here/dev.sh" "$run" "$gguf" "$ckpt" | tee "$gguf.dev.txt" | sed -n 's/^GAIN //p')
  echo "$(basename "$ckpt") gain $gain"
  if awk -v a="$gain" -v b="$top" 'BEGIN { exit !(a > b) }'; then best=$ckpt top=$gain; fi
done
echo "best: $best (gain $top)"
