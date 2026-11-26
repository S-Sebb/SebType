#!/usr/bin/env bash
# tools/build.sh's container sees the checkout's git repository both from a main checkout and from a
# worktree, whose .git names a folder in the main checkout's .git (#608). Puts this tree's files in a git
# worktree and in a clone, each in this task's folder, and has tools/build.sh run git there: it has to find
# the commit the host sees. Elsewhere than yanglab16 the build runs on the host, and so does this check.
#
#   ISSUE=608 tools/test-build.sh   # two short jobs in the build lock
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$root/tools/lib.sh"
command -v rsync >/dev/null || { echo "preflight: rsync missing"; exit 1; }
work=$TASK_OUT/test-build
rm -rf "$work" && mkdir -p "$work" || exit 1
cleanup() { git -C "$root" worktree remove --force "$work/worktree" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
git -C "$root" worktree add -q --detach "$work/worktree" HEAD
git clone -q --no-hardlinks "$(git -C "$root" rev-parse --show-toplevel)" "$work/clone"
git -C "$work/clone" checkout -q --detach "$(git -C "$root" rev-parse HEAD)"

status=0
for c in worktree clone; do
  # This tree's uncommitted changes too: they are what's being tested.
  git -C "$root" ls-files -co --exclude-standard | rsync -a --files-from=- "$root/" "$work/$c/"
  want=$(git -C "$work/$c" rev-parse HEAD)
  got=$(timeout 3900 "$work/$c/tools/build.sh" 5 "test-build $c (#608)" git rev-parse HEAD 2>"$TASK_OUT/test-build-$c.log")
  if [[ $got == "$want" ]]; then
    echo "PASS $c: the build sees commit ${got:0:12}"
  else
    echo "FAIL $c: the build saw '${got:0:40}' (log: $TASK_OUT/test-build-$c.log)"; status=1
  fi
done
exit $status
