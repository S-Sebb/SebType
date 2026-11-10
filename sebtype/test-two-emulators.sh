#!/usr/bin/env bash
# Checks that two emulator suites run at once (#103): sebtype/test-emulator.sh once alone, then twice at
# the same time, from this checkout and from a scratch worktree of the same commit
# (~/.cache/sebtype/test-two-emulators-wt, deleted at the end). Both parallel runs must take different
# emulators, overlap, and get the single run's results. visible-password-plain is a known failure (#100)
# and isn't compared. Memory is sampled while both run.
# One line per check in /tmp/sebtype/test-two-emulators/results.txt; logs next to it. Exit 0 only if all pass.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

out=/tmp/sebtype/test-two-emulators; rm -rf "$out"; mkdir -p "$out"
results=$out/results.txt; : > "$results"
wt=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/test-two-emulators-wt

result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
cleanup() {
  [[ -n ${sampler:-} ]] && kill "$sampler" 2> /dev/null
  rm -rf "$wt" "/tmp/sebtype/test-emulator-$(basename "$wt")"; git worktree prune
}
trap cleanup EXIT

# Preflight
command -v devq > /dev/null || { echo "preflight: devq missing"; exit 1; }
[[ -z $(git status --porcelain --untracked-files=no) ]] ||
  { echo "preflight: uncommitted changes; this checks the committed state, commit first"; exit 1; }
for avd in guide35 guide35b; do
  [[ -f ~/.android/avd/$avd.avd/config.ini ]] || { echo "preflight: no AVD $avd (docs/testing.md)"; exit 1; }
done
cleanup
if ! { git worktree add -q --detach "$wt" HEAD && (cd "$wt" && git submodule update --init --depth 1 -q) &&
  cp -a java/res-bundle/. "$wt/java/res-bundle/" && mkdir -p "$wt/rime-android/out" &&
  cp rime-android/out/rime-release.aar "$wt/rime-android/out/"; } > "$out/worktree.log" 2>&1; then
  echo "preflight: can't set up $wt, see $out/worktree.log"; exit 1
fi

suite() { # checkout name: runs its test-emulator.sh, each output line stamped with the epoch second
  timeout 5400 "$1/sebtype/test-emulator.sh" 2>&1 | while IFS= read -r l; do echo "$(date +%s) $l"; done > "$out/$2.log"
  echo "$(date +%s) end" >> "$out/$2.log"
  cp "/tmp/sebtype/test-emulator-$(basename "$1")/results.txt" "$out/$2-results.txt" 2> /dev/null
}
outcomes() { grep -v ' visible-password-plain' "$1" | cut -d: -f1 | sort; } # "PASS name" lines
started() { awk '$2 == "testing" {print $1; exit}' "$out/$1.log"; }
serial() { awk '$2 == "testing" {print $5; exit}' "$out/$1.log"; }

suite "$PWD" single
if [[ -z $(started single) ]]; then
  result FAIL single-run "never reached the emulator, see $out/single.log"; exit 1
fi
result PASS single-run "$(serial single), $(grep -c '^PASS' "$out/single-results.txt") checks passed, $(grep -vc '^PASS' "$out/single-results.txt") not"

# Memory every 10 s: available, and each emulator's resident size (MB).
while :; do
  echo "$(date +%s) avail=$(free -m | awk '/^Mem:/ {print $7}')$(ps -eo rss=,args= | awk '/qemu-system.*-avd / {
    for (i = 1; i < NF; i++) if ($i == "-avd") printf " %s=%d", $(i + 1), $1 / 1024 }')"
  sleep 10
done > "$out/memory.log" &
sampler=$!
suite "$PWD" a & pa=$!
suite "$wt" b & pb=$!
wait "$pa" "$pb"
kill "$sampler"; sampler=

sa=$(serial a) sb=$(serial b)
if [[ -n $sa && -n $sb && $sa != "$sb" ]]; then result PASS different-emulators "$sa and $sb"
else result FAIL different-emulators "a on ${sa:-none}, b on ${sb:-none}"; fi
ea=$(tail -1 "$out/a.log" | cut -d' ' -f1) eb=$(tail -1 "$out/b.log" | cut -d' ' -f1)
if [[ -n $sa && -n $sb ]] && (( $(started a) < eb && $(started b) < ea )); then
  result PASS at-once "device parts overlapped $(( (ea < eb ? ea : eb) - ($(started a) > $(started b) ? $(started a) : $(started b)) )) s"
else result FAIL at-once "they didn't run at the same time (see $out/a.log, $out/b.log)"; fi
for r in a b; do
  if [[ -s $out/$r-results.txt ]] && diff <(outcomes "$out/single-results.txt") <(outcomes "$out/$r-results.txt") > "$out/$r-diff.txt"; then
    result PASS "same-results-$r" "$(wc -l < "$out/$r-results.txt") lines"
  else result FAIL "same-results-$r" "see $out/$r-diff.txt"; fi
done
result INFO memory "$(awk '{ split($2, a, "="); if (min == "" || a[2] < min) min = a[2]
  for (i = 3; i <= NF; i++) { split($i, e, "="); if (e[2] > max[e[1]]) max[e[1]] = e[2] } }
  END { printf "lowest available %d MB;", min; for (k in max) printf " %s peak %d MB", k, max[k] }' "$out/memory.log")"

! grep -qv '^PASS\|^INFO' "$results"
