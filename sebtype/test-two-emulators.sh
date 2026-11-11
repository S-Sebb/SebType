#!/usr/bin/env bash
# Checks that two emulator suites run at once (#103): sebtype/test-emulator.sh once alone, then twice at
# the same time, from this checkout and from a scratch worktree of the same commit
# (~/.cache/sebtype/test-two-emulators-wt, deleted at the end). Both parallel runs must take different
# emulators, overlap, and get the single run's results. visible-password-plain is a known failure (#100)
# and isn't compared, nor is the timing check settings-smooth-scrolling. guide35 is left in zh-Hans-CN
# first, to check that the suite puts the locale back. Memory is sampled while both run.
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
# "PASS name" lines; frame timing depends on what else the PC runs, so the smoothness check isn't compared.
outcomes() { grep -v ' visible-password-plain\| settings-smooth-scrolling' "$1" | cut -d: -f1 | sort; }
started() { awk '$2 == "testing" {print $1; exit}' "$out/$1.log"; }
serial() { awk '$2 == "testing" {print $5; exit}' "$out/$1.log"; }

suite "$PWD" single
# Compared outcomes mean something only if the suite ran to its last phase.
if ! grep -q '^PASS install-beside-futo' "$out/single-results.txt" 2> /dev/null ||
  ! grep -q '^[A-Z]* settings-run' "$out/single-results.txt"; then
  result FAIL single-run "didn't run to the settings checks, see $out/single.log"; exit 1
fi
result PASS single-run "$(serial single), $(grep -c '^PASS' "$out/single-results.txt") checks passed, $(grep -vc '^PASS' "$out/single-results.txt") not"

# Another task can leave an emulator in Chinese; one of the parallel runs gets guide35, so leaving it
# there checks that test-emulator.sh puts it back to en-US. Only when it runs: other projects start it.
zh_guide35() {
  local s
  for s in $(adb devices | awk '$1 ~ /^emulator-/ {print $1}'); do
    [[ $(adb -s "$s" emu avd name | head -1 | tr -d '\r') == guide35 ]] || continue
    adb -s "$s" push "$out/set-locale.dex" /data/local/tmp/sebtype-set-locale.dex > /dev/null &&
      adb -s "$s" shell app_process -cp /data/local/tmp/sebtype-set-locale.dex / dev.sebb.sebtype.setlocale.SetLocale zh-Hans-CN
    adb -s "$s" shell rm -f /data/local/tmp/sebtype-set-locale.dex
    return
  done
  return 1
}
export -f zh_guide35; export out PATH=${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools:$PATH
sebtype/set-locale/build.sh "$out/set-locale.dex" > "$out/set-locale.log" 2>&1 &&
  devq -P 1 -w 1800 -m 1 -n "sebtype #103 test-two-emulators: guide35 to zh-Hans-CN" \
    /tmp/agent-locks/devices/emulator-guide35.lock bash -c zh_guide35 > "$out/zh-guide35.log" 2>&1
zh=$?

# Memory every 10 s: available, and each emulator's resident size (MB).
while :; do
  echo "$(date +%s) avail=$(free -m | awk '/^Mem:/ {print $7}')$(ps -eo rss=,args= | awk '/qemu-system.*-avd / {
    for (i = 1; i < NF; i++) if ($i == "-avd") printf " %s=%d", $(i + 1), $1 / 1024 }')"
  sleep 10
done > "$out/memory.log" &
sampler=$!
# Both start once both emulators are free, so another worktree's run doesn't put them in one queue.
timeout 3600 bash -c 'until (for l in /tmp/agent-locks/devices/emulator-guide35{,b}.lock; do
  flock -n "$l" true && [[ -z $(ls "$l.queue" 2> /dev/null) ]] || exit 1; done); do sleep 5; done' ||
  result FAIL both-free "both emulators weren't free within an hour"
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
if ((zh != 0)); then result SKIP locale-reset "couldn't leave guide35 in zh-Hans-CN (not running?), see $out/zh-guide35.log"
elif grep -q 'locale en-US, locale was zh-Hans-CN' "$out/a.log" "$out/b.log"; then result PASS locale-reset "guide35 from zh-Hans-CN"
else result FAIL locale-reset "no run reset guide35's zh-Hans-CN"; fi
result INFO memory "$(awk '{ split($2, a, "="); if (min == "" || a[2] < min) min = a[2]
  for (i = 3; i <= NF; i++) { split($i, e, "="); if (e[2] > max[e[1]]) max[e[1]] = e[2] } }
  END { printf "lowest available %d MB;", min; for (k in max) printf " %s peak %d MB", k, max[k] }' "$out/memory.log")"

! grep -qv '^PASS\|^INFO' "$results"
