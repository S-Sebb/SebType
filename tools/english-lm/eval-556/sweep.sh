#!/usr/bin/env bash
# #556 eval, on yanglab16: sweep.sh MODEL LABEL. On #568's code with the experiment toggles (pr568x): decide()'s
# cap swept 1-20 and no cap, and the contraction's hint with vs without its apostrophe at cap 10, core stack.
# Prints one table row per setting: rows right per set.
set -euo pipefail
model=$1 label=$2
E=$HOME/scratch/SebType/556/eval
sets="contractions homographs owner h-contractions h-apostrophes h-homographs h-capitals h-phone-typos"
run() { # NAME ENV...
  local name=$1; shift
  env CORE_ONLY=1 "$@" "$E/probe.sh" "$E/pr568x" "$model" "$E/out/sweep-$label/$name" $sets > /dev/null
  printf '| %s |' "$name"
  for s in $sets; do
    python3 -c "import sys; r=[l.split('\t') for l in open(sys.argv[1]).read().splitlines()]; print(f' {sum(x[1]==x[2] for x in r)}/{len(r)} |', end='')" \
      "$E/out/sweep-$label/$name/core.$s.tsv"
  done
  echo
}
printf '| setting |'; for s in $sets; do printf ' %s |' "$s"; done; echo
printf '|---'; for s in $sets; do printf '|---'; done; echo '|'
run hint-apostrophe SEBTYPE_CAP=10
run hint-bare SEBTYPE_CAP=10 SEBTYPE_BARE_HINT=1
for c in 1 2 3 4 5 6 7 8 9 11 12 14 16 18 20 1e9; do run cap-$c SEBTYPE_CAP=$c; done
