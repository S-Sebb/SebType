#!/usr/bin/env bash
# Chooses a run's checkpoint on the dev sets: exports each of train.py's (every save_every steps, and the
# last), runs dev.sh on it and prints tune.py's gain and the next-word top 3 per checkpoint, then the best:
# the highest gain among the checkpoints whose next-chat, next-news and next-texts top 3 are each within
# NEXT_MARGIN points of the best checkpoint's on that set (the gain counts typos only). On yanglab16.
#
#   tools/english-lm/select.sh RUN_DIR NAME
set -euo pipefail
run=$1 name=$2
here=$(dirname "$0")
NEXT_MARGIN=1
mkdir -p "$run/select"
results=$run/select/results.txt
: > "$results"
for ckpt in "$run"/ckpt/"$name"/step-* "$run/ckpt/$name"; do
  [[ -s $ckpt/model.safetensors ]] || continue
  gguf=$run/select/$(basename "$ckpt").gguf
  "$here/export.sh" "$ckpt" "$gguf" > /dev/null
  if ! "$here/dev.sh" "$run" "$gguf" "$ckpt" > "$gguf.dev.txt" 2>&1; then
    echo "select.sh: dev.sh failed on $ckpt; the end of $gguf.dev.txt:" >&2
    tail -n 20 "$gguf.dev.txt" >&2
    exit 1
  fi
  line="$(basename "$ckpt") $(sed -n 's/^GAIN //p' "$gguf.dev.txt") $(sed -n 's/^NEXT //p' "$gguf.dev.txt")"
  echo "$line" | tee -a "$results"
done
# Each line: checkpoint, gain, next-chat, next-news, next-texts top 3.
awk -v m=$NEXT_MARGIN '
  { name[NR] = $1; for (k = 2; k <= 5; k++) v[NR, k] = $k
    for (k = 3; k <= 5; k++) if (NR == 1 || $k > top[k]) top[k] = $k }
  END { best = 0
    for (i = 1; i <= NR; i++) {
      ok = 1
      for (k = 3; k <= 5; k++) if (v[i, k] < top[k] - m) ok = 0
      if (!ok) print name[i] ": next-word top 3 more than " m " point(s) below the best, left out"
      else if (!best || v[i, 2] > v[best, 2]) best = i
    }
    print "best: " name[best] " (gain " v[best, 2] ")" }' "$results"
