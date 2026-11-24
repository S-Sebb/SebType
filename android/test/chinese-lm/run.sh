#!/usr/bin/env bash
# The Chinese harness (#259): runs today's 中文 (core/'s Rime engine, rime-ice with 白霜's dictionary and
# octagram grammar, the data the apps ship) and, with SEBTYPE_ZH_MODEL, today's 中文 with SebType's Chinese
# model (tools/chinese-lm) on the sets in sets/, twice, on the build host (yanglab16), and checks that the two
# runs agree.
#
#   SEBTYPE_ZH_MODEL=PATH [SEBTYPE_ZH_OPTIONS="rerank=4 rankWeight=1.5"] \
#     [SEBTYPE_ZH_GEN_OPTIONS="generate=2 generatedRank=2"] [SEBTYPE_ZH_CORE=1] android/test/chinese-lm/run.sh
#
# PATH is a GGUF file on the build host; the options are zhbench's, from tools/chinese-lm/tune.py. With
# SEBTYPE_ZH_GEN_OPTIONS, a third stack runs the model with both sets of options; with SEBTYPE_ZH_CORE=1,
# a fourth runs the keyboard's own code (core/src/chinese.cpp around Rime, #264). One line per
# check in ~/scratch/SebType/<issue>/test-chinese-lm-results.txt, the table (docs/experiments/2026-11-16-chinese-lm.md's)
# in chinese/table.md next to it, logs in chinese/run1/ and run2/. Exit 0 only if all pass. Both runs take about
# 15 minutes with a model. It never runs on nobara-pc unless SEBTYPE_BUILD_HOST=local.
set -uo pipefail
cd "$(dirname "$0")/../../.."
source tools/lib.sh

here=android/test/chinese-lm
out=$TASK_OUT
results=$out/test-chinese-lm-results.txt
mkdir -p "$out/chinese"; : > "$results"
result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }

for s in sent-chat sent-news abbr-chat abbr-news partial-chat partial-news typo next-chat next-news; do
  [[ -s $here/sets/$s.tsv ]] || { echo "preflight: $here/sets/$s.tsv missing (make_sets.py makes it)"; exit 1; }
done
if [[ $BUILD_HOST != local ]] && ! build_host_ready; then
  echo "preflight: $BUILD_HOST unreachable; the harness doesn't run on $(hostname -s) unless SEBTYPE_BUILD_HOST=local"
  exit 1
fi

model=${SEBTYPE_ZH_MODEL:-}
read -ra options <<< "${SEBTYPE_ZH_OPTIONS:-}"
read -ra gen <<< "${SEBTYPE_ZH_GEN_OPTIONS:-}"
((${#gen[@]})) && options+=(-- "${gen[@]}")
bench() { # timeout: the build lock's wait (3 h for its 120 minutes) and the run
  if [[ $BUILD_HOST == local ]]; then
    CHINESE_CORE=${SEBTYPE_ZH_CORE:-} timeout 18000 $here/bench.sh "$1" $model "${options[@]}"
  else
    timeout 18000 bash -c 'source tools/lib.sh; build_remotely "$@"' _ CHINESE_CORE="${SEBTYPE_ZH_CORE:-}" \
      $here/bench.sh "$1" $model "${options[@]}"
  fi
}
for run in run1 run2; do
  if bench $run > "$out/chinese/$run.log" 2>&1 && [[ -s $out/chinese/$run/summary.json ]]; then
    result PASS "$run" "$out/chinese/$run/summary.json"
  else
    result FAIL "$run" "see $out/chinese/$run.log"
  fi
done

s1=$out/chinese/run1/summary.json s2=$out/chinese/run2/summary.json
if [[ -s $s1 && -s $s2 ]]; then
  if python3 -I $here/score.py --compare "$s1" "$s2" > "$out/chinese/compare.txt"; then
    result PASS reproducible "every item's results equal, per-key p50 and p95 within 25 %"
  else
    result FAIL reproducible "$(head -1 "$out/chinese/compare.txt")"
  fi
  python3 -I $here/score.py --table "$s1" "$s2" > "$out/chinese/table.md" &&
    result PASS table "$out/chinese/table.md" || result FAIL table
else
  result FAIL reproducible "a run has no summary"
fi

! grep -q '^FAIL' "$results"
