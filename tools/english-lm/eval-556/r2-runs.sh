#!/usr/bin/env bash
# r2 baselines: core tests (with #539's test rows, without its rule) and the harness, on main and #568.
E=$HOME/scratch/SebType/556/eval
for t in main pr568; do
  (cd $E/$t && ISSUE=556/core-r2-$t core/test/english.sh; echo "EXIT core-r2-$t $?")
done
for t in main pr568; do
  (cd $E/$t && ISSUE=556/h-r2-$t android/test/english/run.sh; echo "EXIT h-r2-$t $?")
done
