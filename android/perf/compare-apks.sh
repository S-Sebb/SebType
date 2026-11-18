#!/usr/bin/env bash
# English typing and opens of two SebType APKs, alternately in one emulator lock (#262): perf.sh --compare's
# rows (idle memory, typing at 700 and 100 ms a key, a long field, warm and cold opens) for each, RUNS times
# (default 2). Both are dev.sebb.sebtype with the same keyboard service, so each run installs its APK afresh.
#
#   android/perf/compare-apks.sh OLD_APK NEW_APK     e.g. the FUTO-based app's last release and this build
#
# Each run's results.txt and perf.md (table.py's table) in ~/scratch/SebType/<issue>/perf-compare/<old|new>-<n>/,
# all the tables printed last. Exit 0 only if every run installed, ran and wrote its results without a FAIL.
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh

old=$(realpath "${1:?usage: compare-apks.sh OLD_APK NEW_APK}") new=$(realpath "${2:?usage: compare-apks.sh OLD_APK NEW_APK}")
export old new runs=${RUNS:-2} top=$TASK_OUT/perf-compare
for f in "$old" "$new"; do [[ -f $f ]] || { echo "preflight: no APK at $f"; exit 1; }; done
rm -rf "$top"; mkdir -p "$top"
android/perf/build-field.sh "$top/perf-field.apk" > "$top/field-build.log" 2>&1 ||
  { echo "preflight: test field doesn't build, see $top/field-build.log"; exit 1; }

device_runs() { # under the emulator lock; exit 1 if any run failed
  local n app apk dir adb=$ANDROID_HOME/platform-tools/adb failed=0
  for n in $(seq "$runs"); do
    for app in old new; do
      apk=${!app} dir=$top/$app-$n
      mkdir -p "$dir/run" && cp "$top/perf-field.apk" "$dir/run/"
      "$adb" uninstall dev.sebb.sebtype > /dev/null
      "$adb" install "$apk" > /dev/null || { echo "FAIL $app-$n: install"; failed=1; continue; }
      sleep 5 # Android lists a new keyboard a few seconds after the install
      PERF_OUT=$dir android/perf/perf.sh --compare-device > "$dir/log.txt" 2>&1 ||
        { echo "FAIL $app-$n: perf.sh, see $dir/log.txt"; failed=1; }
      python3 -I android/perf/table.py "$dir/run" "$dir/results.txt" > "$dir/perf.md" 2>> "$dir/log.txt" ||
        { echo "FAIL $app-$n: table.py, see $dir/log.txt"; failed=1; }
    done
  done
  "$adb" uninstall dev.sebb.sebtype > /dev/null
  return $failed
}
export -f device_runs
android/emulator.sh -P "${PERF_PRIORITY:-5}" -w 1800 -m $(( runs * 2 * 20 + 10 )) -n "sebtype perf compare-apks" -- \
  bash -c device_runs
status=$?

for n in $(seq "$runs"); do
  for app in old new; do echo "## $app $n ($top/$app-$n/perf.md)"; cat "$top/$app-$n/perf.md" 2>/dev/null; echo; done
done
for n in $(seq "$runs"); do
  for app in old new; do
    [[ -f $top/$app-$n/results.txt ]] || { echo "FAIL $app-$n: no results.txt"; status=1; }
  done
done
if grep -h '^FAIL' "$top"/*/results.txt 2>/dev/null; then status=1; fi
exit "$status"
