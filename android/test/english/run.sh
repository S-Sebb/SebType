#!/usr/bin/env bash
# The English quality harness (#231, stage 0 of docs/plans/android-own-keyboard.md): runs today's English
# (FUTO's decoder and transformer), pristine AOSP's decoder, SebType's model on it, and the new keyboard's
# English (core/src/english.cpp, #244) on the test sets in sets/, twice, on the build host (yanglab16), checks
# that the two runs agree and that the new keyboard's English passes the plan's quality bar (§2).
#
#   android/test/english/run.sh
#
# One line per check in ~/scratch/SebType/<issue>/test-english-results.txt, and the baseline table (the
# docs/perf/ format) in english/table.md next to it; logs in english/run1/ and run2/. Exit 0 only if all pass.
# A run takes about 15 minutes on yanglab16. It never runs on nobara-pc unless SEBTYPE_BUILD_HOST=local.
# SEBTYPE_MODEL=PATH (a GGUF file on the build host, tools/english-lm) tries another model in place of the
# committed engines/sebtype-lm/english.gguf.
set -uo pipefail
cd "$(dirname "$0")/../../.."
source tools/lib.sh

here=android/test/english
out=$TASK_OUT
results=$out/test-english-results.txt
mkdir -p "$out/english"; : > "$results"
result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }

# Preflight
for f in $here/sets/{clean,phone-typos,misspellings,next-chat,next-news,next-texts,text-typos}.tsv; do
  [[ -s $f ]] || { echo "preflight: $f missing (make_sets.py makes it)"; exit 1; }
done
[[ -f android/app/src/main/res/raw/ml4_q6_k.gguf ]] || { echo "preflight: FUTO's model ml4_q6_k.gguf missing"; exit 1; }
if [[ $BUILD_HOST != local ]] && ! build_host_ready; then
  echo "preflight: $BUILD_HOST unreachable; the harness doesn't run on $(hostname -s) unless SEBTYPE_BUILD_HOST=local"
  exit 1
fi

bench() { # run name: builds and runs on the build host (or here), copying its summary back
  if [[ $BUILD_HOST == local ]]; then
    timeout 5400 $here/bench.sh "$1"
  else
    timeout 5400 bash -c "source tools/lib.sh; build_remotely ${SEBTYPE_MODEL:+SEBTYPE_MODEL=$SEBTYPE_MODEL} $here/bench.sh $1"
  fi
}
for run in run1 run2; do
  if bench $run > "$out/english/$run.log" 2>&1 && [[ -s $out/english/$run/summary.json ]]; then
    result PASS "$run" "$out/english/$run/summary.json"
  else
    result FAIL "$run" "see $out/english/$run.log"
  fi
done

s1=$out/english/run1/summary.json s2=$out/english/run2/summary.json
if [[ -s $s1 && -s $s2 ]]; then
  if python3 -I $here/score.py --compare "$s1" "$s2" > "$out/english/compare.txt"; then
    result PASS reproducible "quality numbers equal, per-key p50 within 25 %"
  else
    result FAIL reproducible "$(head -1 "$out/english/compare.txt")"
  fi
  python3 -I $here/score.py --table "$s1" "$s2" > "$out/english/table.md" &&
    result PASS table "$out/english/table.md" || result FAIL table
  python3 -I $here/score.py --bar "$s1" > "$out/english/bar.txt" &&
    result PASS bar "$out/english/bar.txt" || result FAIL bar "$(grep -c ^FAIL "$out/english/bar.txt") rows miss, $out/english/bar.txt"
else
  result FAIL reproducible "a run has no summary"
fi

! grep -q '^FAIL' "$results"
