#!/usr/bin/env bash
# Checks the build speed-ups of #58 (docs/development.md, "Build and test times") on this checkout's commit,
# on yanglab16, where the builds run (#225, #250): a debug build in a new checkout comes from the shared
# caches, a Kotlin change compiles incrementally, and the release APK is the same file from two checkouts,
# with or without the caches, and from two builds signed here. SEBTYPE_BUILD_HOST=local also builds a
# release on this PC and checks it is the same file; nothing else builds here.
# Uses a scratch worktree in ~/scratch/SebType/<issue>/test-build-wt (and its copy on yanglab16), deleted at
# the end; builds take yanglab16's build lock.
# One line per check in ~/scratch/SebType/<issue>/test-build-results.txt; logs next to it. Exit 0 only if all pass.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# The checks build on yanglab16 whatever SEBTYPE_BUILD_HOST says; =local only adds the local release.
build_here=${SEBTYPE_BUILD_HOST:-}; unset SEBTYPE_BUILD_HOST
source tools/lib.sh
out=$TASK_OUT; mkdir -p "$out"
results=$out/test-build-results.txt; : > "$results"
wt=$out/test-build-wt
# build_remotely puts a checkout at ~/scratch/SebType/<task>/<checkout> on yanglab16; the worktree's task is
# the same as this checkout's.
export ISSUE; ISSUE=$(basename "$TASK_OUT")
remote_wt=scratch/SebType/$ISSUE/test-build-wt remote_main=scratch/SebType/$ISSUE/$(basename "$PWD")
# Checks run under `timeout` in a subshell: the functions and what they read must be exported.
export out wt remote_wt remote_main build_here

result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
check() { # name, function...; run it under timeout T seconds (default 3600: builds may wait for the build lock)
  local name=$1; shift
  if timeout "${T:-3600}" bash -c "$*" > "$out/test-build-$name.log" 2>&1; then result PASS "$name"
  else result FAIL "$name" "see $out/test-build-$name.log"; fi
}
on_host() { ssh -o ConnectTimeout=10 -o BatchMode=yes yanglab16 "$@"; }
cleanup() { rm -rf "$wt"; git worktree prune; on_host rm -rf "$remote_wt"; }
trap cleanup EXIT
export -f on_host

# Preflight
on_host true || { echo "preflight: yanglab16 unreachable (start Zscaler: gtk-launch ZSTray)"; exit 1; }
[[ -z $(git status --porcelain --untracked-files=no) ]] ||
  { echo "preflight: uncommitted changes; this checks the committed state, commit first"; exit 1; }
android/build.sh debug > /dev/null 2> "$out/test-build-warm.log" ||
  { echo "preflight: debug build on yanglab16 failed, see $out/test-build-warm.log"; exit 1; }
cleanup
# The worktree's copy on yanglab16 starts empty but for FUTO's downloaded dictionary, which git ignores.
if ! { git worktree add -q --detach "$wt" HEAD &&
  on_host "mkdir -p $remote_wt/android/app && cp -a $remote_main/android/app/res-bundle $remote_wt/android/app/"; }; then
  echo "preflight: can't set up $wt and its copy on yanglab16"; exit 1
fi

built_in() { grep -o 'in [0-9]*s after' "$1" | tr -dc 0-9; } # the build's own time, without the lock queue
# The checkout just built the same sources, so only native code compiles (from sccache).
debug_from_cache() {
  (cd "$wt" && android/build.sh debug) || return 1
  local s; s=$(built_in "$out/test-build-new-worktree-debug.log"); echo "built in ${s}s, budget 60s"; (( s <= 60 ))
}
export -f built_in debug_from_cache
check new-worktree-debug debug_from_cache

# build_remotely from the worktree, for builds that need an environment android/build.sh doesn't pass on.
wt_remotely() { (cd "$wt" && source tools/lib.sh && build_remotely "$@"); }
# One changed Kotlin file: Kotlin's build report says whether it compiled incrementally.
kotlin_incremental() {
  local kt=android/app/src/main/java/org/futo/inputmethod/latin/uix/ActionBar.kt reports
  echo "private val sebtypeTestBuildProbe = 1" >> "$wt/$kt"
  reports=$remote_wt/android/build/reports/kotlin-build
  on_host rm -rf "$reports"
  wt_remotely 'ORG_GRADLE_PROJECT_kotlin.build.report.output=file' android/build.sh debug; local rc=$?
  git -C "$wt" checkout -q -- "$kt"
  ((rc == 0)) || return 1
  on_host "grep -h 'compilation:\|REBUILD_REASON' $reports/*" &&
    ! on_host "grep -q 'Non incremental\|REBUILD_REASON' $reports/*"
}
export -f wt_remotely kotlin_incremental
check kotlin-incremental kotlin_incremental

same_apk() { # the same file, or the entries (name and CRC) that differ
  cmp -s "$1" "$2" && echo "same file: $1 and $2" && return
  diff <(entries "$1") <(entries "$2"); echo "$1 and $2 differ"; return 1
}
entries() {
  python3 -I -c 'import sys, zipfile
for i in sorted(zipfile.ZipFile(sys.argv[1]).infolist(), key=lambda i: i.filename): print(i.filename, i.CRC)' "$1"
}
# Unsigned, as they come from yanglab16. The checkout's release comes from the caches; the worktree's is
# built without them (no build cache, a new CMake folder, and sccache compiles everything again), so the
# caches change nothing in it.
same_release() {
  local a b
  a=$(SEBTYPE_UNSIGNED=1 android/build.sh release) || return 1
  sed -i 's/^org.gradle.caching=true/org.gradle.caching=false/' "$wt/android/gradle.properties"
  on_host rm -rf "$remote_wt/android/app/.cxx" "$remote_wt/android/native/.cxx"
  b=$(wt_remotely VERSION_CODE="$(git rev-list --first-parent --count HEAD)" SEBTYPE_UNSIGNED=1 SCCACHE_RECACHE=1 \
    android/build.sh release); local rc=$?
  git -C "$wt" checkout -q -- android/gradle.properties
  ((rc == 0)) && same_apk "$a" "$b"
}
export -f same_apk entries same_release
check release-same-in-two-checkouts same_release

# Two releases built on yanglab16 and signed here (#229); with SEBTYPE_BUILD_HOST=local, also one built here
# (other paths, CPU count, time zone and NDK folder).
same_signed() {
  local a b c
  a=$(android/build.sh release) && b=$(cd "$wt" && android/build.sh release) && same_apk "$a" "$b" || return 1
  [[ $build_here == local ]] || { echo "no local build (SEBTYPE_BUILD_HOST=local adds one)"; return; }
  command -v sccache >/dev/null || { echo "sccache missing here (native objects aren't cached without it)"; return 1; }
  c=$(SEBTYPE_BUILD_HOST=local android/build.sh release) && same_apk "$a" "$c"
}
export -f same_signed
check release-same-on-yanglab16 same_signed

! grep -qv '^PASS' "$results"
