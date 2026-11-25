#!/usr/bin/env bash
# Chooses a run's checkpoint on the dev sets: exports each of train.py's (every save_every steps, and the
# last), runs dev.sh on it and prints tune.py's gain and the next-word top 3 per checkpoint, then the best:
# the highest gain among the checkpoints whose next-chat, next-news and next-texts top 3 are each within
# NEXT_MARGIN points of the best checkpoint's on that set (the gain counts typos only). On yanglab16.
#
#   tools/english-lm/select.sh RUN_DIR NAME
set -euo pipefail
run=$1 name=$2
NEXT_MARGIN=1
mkdir -p "$run/select"
results=$run/select/results.txt
: > "$results"
# #556: select.sh, but each checkpoint is evaluated as soon as train.py has written it (config.train.json is
# its last file), so selection overlaps training. here= points at main's tools in r4code.
here=$HOME/scratch/SebType/556/r4code/tools/english-lm
ckpts() { for n in $(seq 1000 1000 15000); do echo "$run/ckpt/$name/step-$n"; done; echo "$run/ckpt/$name"; }
for ckpt in $(ckpts); do
  until [[ -s $ckpt/config.train.json ]]; do sleep 30; done
  [[ -s $ckpt/model.safetensors ]] || continue
  gguf=$run/select/$(basename "$ckpt").gguf
  rm -f "$gguf.log"
  # A checkpoint that fails (a save cut short, an export off its checkpoint) is skipped; the others still run.
  if ! "$here/export.sh" "$ckpt" "$gguf" > "$gguf.export.txt" 2>&1; then
    echo "select.sh: export failed on $ckpt, skipped; the end of its output and of $gguf.log:" >&2
    tail -n 5 "$gguf.export.txt" "$gguf.log" >&2 2> /dev/null || true
    continue
  fi
  if ! "$here/dev-nolock.sh" "$run" "$gguf" "$ckpt" > "$gguf.dev.txt" 2>&1; then
    echo "select.sh: dev.sh failed on $ckpt, skipped; the end of $gguf.dev.txt:" >&2
    tail -n 20 "$gguf.dev.txt" >&2 || true
    continue
  fi
  line="$(basename "$ckpt") $(sed -n 's/^GAIN //p' "$gguf.dev.txt") $(sed -n 's/^NEXT //p' "$gguf.dev.txt")"
  echo "$line" | tee -a "$results"
done
# Each line: checkpoint, gain, next-chat, next-news, next-texts top 3. The bests of the three sets may be
# different checkpoints', so none may be within the margin of all three: then there is no choice to make here.
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
    if (!NR) { print "select.sh: no checkpoint was evaluated" > "/dev/stderr"; exit 1 }
    if (!best) {
      print "select.sh: no checkpoint is within " m " point(s) of the best next-word top 3 on every set" > "/dev/stderr"
      exit 1
    }
    print "best: " name[best] " (gain " v[best, 2] ")" }' "$results"
