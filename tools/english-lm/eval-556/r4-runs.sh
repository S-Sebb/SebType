#!/usr/bin/env bash
# r4 (step-15000) against r2's runs: probe on main and #568, core tests and harness with the r4 GGUF in place
# (main-r4, pr568-r4: copies of main and pr568), then #568's sweep.
E=$HOME/scratch/SebType/556/eval
G=$HOME/scratch/SebType/556/r4run-b/select/step-15000.gguf
for t in main pr568; do "$E/probe.sh" "$E/$t" "$G" "$E/out/r4-$t"; echo "EXIT probe-r4-$t $?"; done
for t in main pr568; do
  (cd $E/$t-r4 && ISSUE=556/core-r4-$t core/test/english.sh; echo "EXIT core-r4-$t $?")
done
for t in main pr568; do
  (cd $E/$t-r4 && ISSUE=556/h-r4-$t android/test/english/run.sh; echo "EXIT h-r4-$t $?")
done
"$E/sweep.sh" "$G" r4 > "$E/sweep-r4.md" 2> "$E/sweep-r4.err"; echo "EXIT sweep-r4 $?"
