#!/usr/bin/env bash
# Checks the build speed-ups of #58 (docs/development.md, "Build and test times") on this checkout's commit:
# a debug build in a new worktree comes from the shared caches, a Kotlin change compiles incrementally,
# and the release APK is the same from two checkouts, with or without the caches.
# Uses a scratch worktree in ~/scratch/sebtype/cache/test-build-wt, deleted at the end; builds take the build lock.
# One line per check in ~/scratch/sebtype/test-build-results.txt; logs next to it. Exit 0 only if all pass.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

out=$HOME/scratch/sebtype; mkdir -p "$out"
results=$out/test-build-results.txt; : > "$results"
wt=$HOME/scratch/sebtype/cache/test-build-wt
# Checks run under `timeout` in a subshell: the functions and what they read must be exported.
export out wt

result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
check() { # name, function...; run it under timeout T seconds (default 3600: builds may wait for the build lock)
  local name=$1; shift
  if timeout "${T:-3600}" bash -c "$*" > "$out/test-build-$name.log" 2>&1; then result PASS "$name"
  else result FAIL "$name" "see $out/test-build-$name.log"; fi
}
cleanup() { rm -rf "$wt"; git worktree prune; }
trap cleanup EXIT

# Preflight
command -v sccache >/dev/null || { echo "preflight: sccache missing (native objects aren't cached without it)"; exit 1; }
[[ -z $(git status --porcelain --untracked-files=no) ]] ||
  { echo "preflight: uncommitted changes; this checks the committed state, commit first"; exit 1; }
android/build.sh debug > /dev/null 2> "$out/test-build-warm.log" ||
  { echo "preflight: debug build failed, see $out/test-build-warm.log"; exit 1; }
cleanup
if ! { git worktree add -q --detach "$wt" HEAD &&
  cp -a android/app/res-bundle/. "$wt/android/app/res-bundle/"; }; then
  echo "preflight: can't set up $wt"; exit 1
fi

built_in() { grep -o 'in [0-9]*s after' "$1" | tr -dc 0-9; } # the build's own time, without the lock queue
# The checkout just built the same sources, so only native code compiles (from sccache): about 15 s.
debug_from_cache() {
  (cd "$wt" && android/build.sh debug) || return 1
  local s; s=$(built_in "$out/test-build-new-worktree-debug.log"); echo "built in ${s}s, budget 60s"; (( s <= 60 ))
}
export -f built_in debug_from_cache
check new-worktree-debug debug_from_cache

# One changed Kotlin file: Kotlin's build report says whether it compiled incrementally.
kotlin_incremental() {
  local kt=android/app/src/main/java/org/futo/inputmethod/latin/uix/ActionBar.kt
  echo "private val sebtypeTestBuildProbe = 1" >> "$wt/$kt"
  rm -rf "$wt/android/build/reports/kotlin-build"
  (cd "$wt" && env 'ORG_GRADLE_PROJECT_kotlin.build.report.output=file' android/build.sh debug); local rc=$?
  git -C "$wt" checkout -q -- "$kt"
  ((rc == 0)) || return 1
  grep -h 'compilation:\|REBUILD_REASON' "$wt"/android/build/reports/kotlin-build/*
  ! grep -q 'Non incremental\|REBUILD_REASON' "$wt"/android/build/reports/kotlin-build/*
}
export -f kotlin_incremental
check kotlin-incremental kotlin_incremental

entries() { # name and CRC of every APK entry outside the signature
  python3 -I -c 'import sys, zipfile
for i in sorted(zipfile.ZipFile(sys.argv[1]).infolist(), key=lambda i: i.filename):
    i.filename.startswith("META-INF/") or print(i.filename, i.CRC)' "$1"
}
# The checkout's release comes from the caches; the worktree's is built without them (no build cache,
# no sccache on PATH), so the caches change nothing in it.
same_release() {
  local a b nosc
  a=$(android/build.sh release) || return 1
  sed -i 's/^org.gradle.caching=true/org.gradle.caching=false/' "$wt/android/gradle.properties"
  nosc=$(mktemp -d) && ln -s "$(command -v devq)" "$nosc/devq"
  b=$(cd "$wt" && rm -rf android/app/.cxx android/rime/.cxx && PATH=$nosc:$(tr : '\n' <<<"$PATH" | grep -vx "$(dirname "$(command -v sccache)")" | paste -sd:) \
    android/build.sh release); local rc=$?
  rm -rf "$nosc"; git -C "$wt" checkout -q -- android/gradle.properties
  ((rc == 0)) && diff <(entries "$a") <(entries "$b") && echo "same entries: $a and $b"
}
export -f entries same_release
check release-same-in-two-checkouts same_release

! grep -qv '^PASS' "$results"
