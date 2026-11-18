#!/usr/bin/env bash
# Checks that two checkouts on different code each test their own RPM: builds started at once each package
# their own code (#305), and the cache keeps one RPM per sources, not per version (#326). Copies this checkout
# twice, gives each copy a marker comment in linux/data/sebtype.conf, has sebtype_unpack build both together
# and looks for each marker in what it unpacked. Then a copy whose sources haven't changed reuses its RPM, and
# one whose sources changed by a line, uncommitted, gets another.
#
#   ISSUE=326 linux/test-parallel-build.sh   # two RPM builds, one after the other in the build lock
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
      $(printf 'scratch/SebType/cache/sebtype/%q ' "${rpms[@]##*/}")" || true
  fi
}
trap cleanup EXIT

pids=()
for c in a b; do
  git -C "$root" ls-files -co --exclude-standard | rsync -a --files-from=- "$root/" "$work/$c/"
  echo "# parallel-build-$c" >>"$work/$c/linux/data/sebtype.conf"
  # build_remotely takes the files to copy from git.
  git -C "$work/$c" init -q && git -C "$work/$c" add -A
  rpms+=("$(cd "$work/$c" && source linux/versions.sh && sebtype_rpm "$(sebtype_key)")")
  # shellcheck disable=SC2016  # expands in the copy's shell
  (cd "$work/$c" && timeout 7200 bash -c 'source linux/versions.sh && sebtype_unpack "$1"' _ "$work/$c-own") \
    >/dev/null 2>"$TASK_OUT/parallel-build-$c.log" &
  pids+=($!)
done

status=0
for i in 0 1; do
  c=$([[ $i == 0 ]] && echo a || echo b)
  if ! wait "${pids[i]}"; then
    echo "FAIL $c: build failed (log: $TASK_OUT/parallel-build-$c.log)"; status=1; continue
  fi
  conf=$work/$c-own/usr/share/fcitx5/addon/sebtype.conf
  if grep -q "^# parallel-build-$c$" "$conf"; then
    echo "PASS $c: it unpacked its own RPM, ${rpms[i]##*/}"
  else
    echo "FAIL $c: its RPM has $(grep '^# parallel-build' "$conf" || echo 'no marker')"; status=1
  fi
done
[[ ${rpms[0]} != "${rpms[1]}" ]] || { echo "FAIL: both copies' RPMs have one name, ${rpms[0]##*/}"; status=1; }

# Unchanged sources: the cached RPM is unpacked again, not rebuilt (a rebuild has another build time inside).
# shellcheck disable=SC2016
unpack_a() { (cd "$work/a" && timeout 7200 bash -c 'source linux/versions.sh && sebtype_unpack "$1"' _ "$work/a-own"); }
before=$(sha256sum <"${rpms[0]}")
if unpack_a >/dev/null 2>>"$TASK_OUT/parallel-build-a.log" && [[ $(sha256sum <"${rpms[0]}") == "$before" ]]; then
  echo "PASS unchanged: a reused its RPM"
else
  echo "FAIL unchanged: a's RPM was rebuilt or failed to unpack"; status=1
fi
# A one-line change, not committed: another key, so sebtype_unpack would build a new RPM.
echo "# changed" >>"$work/a/core/README.md"
changed=$(cd "$work/a" && source linux/versions.sh && sebtype_rpm "$(sebtype_key)")
if [[ $changed != "${rpms[0]}" && ! -f $changed ]]; then
  echo "PASS changed: a's next RPM is ${changed##*/}, not built yet"
else
  echo "FAIL changed: a still names ${changed##*/}"; status=1
fi
# Logs stay when something failed.
[[ $status != 0 ]] || rm -f "$TASK_OUT"/parallel-build-{a,b}.log
exit $status
