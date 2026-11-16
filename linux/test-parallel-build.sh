#!/usr/bin/env bash
# Checks that two Linux RPM builds started at once from different checkouts each package their own code
# (#305): copies this checkout twice, gives each copy its own RPM release and a marker comment in
# linux/data/sebtype.conf, runs linux/build.sh in both together and looks for each marker in its own RPM.
#
#   ISSUE=305 linux/test-parallel-build.sh   # two RPM builds, one after the other in the build lock
#
# The test RPMs are removed afterwards, here and on the build host.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=../tools/lib.sh
source "$root/tools/lib.sh"
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$root/linux/versions.sh"
# The copies' builds go in this task's folder, on the build host too.
export ISSUE=${ISSUE:-$(basename "$TASK_OUT")}
work=$TASK_OUT/parallel-build
command -v rpm2cpio >/dev/null || { echo "BLOCKED: rpm2cpio missing"; exit 1; }
rm -rf "$work"
mkdir -p "$work"
rpms=()
cleanup() {
  rm -rf "$work" "${rpms[@]}"
  if build_host_ready 2>/dev/null; then
    ssh "$BUILD_HOST" "rm -rf scratch/SebType/$ISSUE/a scratch/SebType/$ISSUE/b \
      scratch/SebType/cache/sebtype/sebtype-$SEBTYPE_VERSION-$ISSUE[ab].fc44.x86_64.rpm" || true
  fi
}
trap cleanup EXIT

pids=()
for c in a b; do
  git -C "$root" ls-files -co --exclude-standard | rsync -a --files-from=- "$root/" "$work/$c/"
  sed -i "s/^SEBTYPE_RPM_RELEASE=.*/SEBTYPE_RPM_RELEASE=$ISSUE$c.fc44/" "$work/$c/linux/versions.sh"
  echo "# parallel-build-$c" >>"$work/$c/linux/data/sebtype.conf"
  # build_remotely takes the files to copy from git.
  git -C "$work/$c" init -q && git -C "$work/$c" add -A
  rpms+=("$SEBTYPE_CACHE/sebtype-$SEBTYPE_VERSION-$ISSUE$c.fc44.x86_64.rpm")
  timeout 7200 "$work/$c/linux/build.sh" >/dev/null 2>"$TASK_OUT/parallel-build-$c.log" &
  pids+=($!)
done

status=0
for i in 0 1; do
  c=$([[ $i == 0 ]] && echo a || echo b)
  if ! wait "${pids[i]}"; then
    echo "FAIL $c: build failed (log: $TASK_OUT/parallel-build-$c.log)"; status=1; continue
  fi
  conf=$(rpm2cpio "${rpms[i]}" | cpio -i --quiet --to-stdout ./usr/share/fcitx5/addon/sebtype.conf)
  if grep -q "^# parallel-build-$c$" <<<"$conf"; then
    echo "PASS $c: its RPM has its own sebtype.conf"
  else
    echo "FAIL $c: its RPM has $(grep '^# parallel-build' <<<"$conf" || echo 'no marker')"; status=1
  fi
done
# Logs stay when something failed.
[[ $status != 0 ]] || rm -f "$TASK_OUT"/parallel-build-{a,b}.log
exit $status
