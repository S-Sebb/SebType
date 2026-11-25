#!/usr/bin/env bash
# Chooses a run's checkpoint on the dev sets (#557): exports each of train.py's (every save_every steps, and
# the last), runs the keyboard's own code with it on the dev sets (bench.sh --dev, core stack) and prints, per
# checkpoint, the mean top-1 over the typed sets and the next-word top 3 of chat and news; then the best: the
# highest mean top-1 among the checkpoints whose next-word top 3 (chat's and news's mean) is within NEXT_MARGIN
# points of the best checkpoint's. Then checks the best export against its checkpoint (parity.py). On yanglab16.
#
#   tools/chinese-lm/select.sh RUN_DIR NAME
#
# In a git checkout, or in a copy without git with LIBRIME_KEY set (linux/versions.sh's librime_key, as
# build_remotely brings it).
set -euo pipefail
run=$(realpath "$1") name=$2
here=$(realpath "$(dirname "$0")")
bench=$here/../../android/test/chinese-lm/bench.sh
py="$HOME/scratch/SebType/cache/chinese-lm-venv/bin/python -I -W ignore"
NEXT_MARGIN=1
sel=$run/select/$name  # a folder per run: its exports, their results and results.txt
mkdir -p "$sel"
results=$sel/results.txt
: > "$results"
for ckpt in "$run"/ckpt/"$name"/step-* "$run/ckpt/$name"; do
  [[ -s $ckpt/model.safetensors ]] || continue
  c=$(basename "$ckpt")
  gguf=$sel/$c.gguf
  # A rerun (after a failed bench) keeps the results it already has for this checkpoint.
  if [[ ! $sel/$c/summary.json -nt $ckpt/model.safetensors ]]; then
    "$here/export.sh" "$ckpt" "$gguf" > /dev/null
    # dump=1: the model stack's scores, for parity.py.
    CHINESE_CORE=1 "$bench" --dev "$run/dev" "$sel/$c" "$gguf" dump=1 > "$sel/$c.log" 2>&1 ||
      { echo "select.sh: bench.sh failed on $ckpt; the end of $sel/$c.log:" >&2; tail -n 20 "$sel/$c.log" >&2; exit 1; }
  fi
  python3 -I -c '
import json, sys
core = json.load(open(sys.argv[1]))["core"]
typed = [m["top1"] for n, m in core.items() if isinstance(m, dict) and not n.startswith("dev-next")]
print(sys.argv[2], round(sum(typed) / len(typed), 2), core["dev-next-chat"]["top3"], core["dev-next-news"]["top3"])
' "$sel/$c/summary.json" "$c" | tee -a "$results"
done
# Each line: checkpoint, mean top-1, next-chat and next-news top 3.
# (Chat's and news's best can be different checkpoints', so the margin applies to their mean.)
best=$(awk -v m=$NEXT_MARGIN '
  { name[NR] = $1; typed[NR] = $2; next3[NR] = ($3 + $4) / 2; if (NR == 1 || next3[NR] > top) top = next3[NR] }
  END { best = 0
    for (i = 1; i <= NR; i++)
      if (next3[i] < top - m) print name[i] ": next-word top 3 more than " m " point(s) below the best, left out" > "/dev/stderr"
      else if (!best || typed[i] > typed[best]) best = i
    print name[best] }' "$results")
echo "best: $best"
ckpt=$run/ckpt/$name/$best
[[ $best == "$name" ]] && ckpt=$run/ckpt/$name
$py "$here/parity.py" "$ckpt" "$run/dev/dev-sent-chat.tsv" "$sel/$best/model.dev-sent-chat.tsv.dump"
