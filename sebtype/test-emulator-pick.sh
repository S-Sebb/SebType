#!/usr/bin/env bash
# Checks sebtype/emulator.sh's choice of emulator (#140): a run starts at once on the emulator whose lock
# is free, and with both held, on whichever comes free first. Uses its own lock directory and a stub adb
# that reports both emulators booted, so it touches no real emulator or lock and takes about a minute.
# One line per check in /tmp/sebtype/test-emulator-pick-results.txt; exit 0 only if all pass.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
command -v devq > /dev/null || { echo "preflight: devq missing"; exit 1; }

out=/tmp/sebtype; mkdir -p "$out"
results=$out/test-emulator-pick-results.txt; : > "$results"
tmp=$(mktemp -d); holders=()
trap 'kill "${holders[@]}" 2> /dev/null; rm -rf "$tmp"' EXIT
export EMULATOR_LOCKS=$tmp/locks ANDROID_HOME=$tmp/sdk
mkdir -p "$EMULATOR_LOCKS" "$ANDROID_HOME/platform-tools"
cat > "$ANDROID_HOME/platform-tools/adb" << 'EOF'
#!/usr/bin/env bash
[[ $1 == -s ]] && { s=$2; shift 2; }
case $* in
  devices) printf 'List of devices attached\nemulator-5554\tdevice\nemulator-5580\tdevice\n' ;;
  "emu avd name") [[ $s == emulator-5554 ]] && echo guide35 || echo guide35b; echo OK ;;
  "shell getprop sys.boot_completed") echo 1 ;;
esac
EOF
chmod +x "$ANDROID_HOME/platform-tools/adb"

result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
hold() { # AVD, seconds: hold its lock in the background until held
  devq -n "test hold" "$EMULATOR_LOCKS/emulator-$1.lock" sleep "$2" & holders+=($!)
  until ! flock -n "$EMULATOR_LOCKS/emulator-$1.lock" true; do sleep 0.2; done
}
release() { kill "${holders[@]}" 2> /dev/null; wait 2> /dev/null; holders=(); }
# name, expected serial, seconds allowed: one run, which must print that serial within that time
run() {
  local start=$SECONDS got
  got=$(timeout 60 sebtype/emulator.sh -w 60 -- sh -c 'echo $ANDROID_SERIAL' 2> "$out/test-emulator-pick-$1.log")
  if [[ $got == "$2" ]] && ((SECONDS - start <= $3)); then result PASS "$1" "$got in $((SECONDS - start))s"
  else result FAIL "$1" "got '$got' in $((SECONDS - start))s, want $2 within $3s, see $out/test-emulator-pick-$1.log"; fi
}

run both-free emulator-5554 3
hold guide35 120; run guide35-held emulator-5580 3; release
hold guide35b 120; run guide35b-held emulator-5554 3; release
# The picked one (guide35, shorter queue) stays held; guide35b comes free after 10 s.
hold guide35 120; hold guide35b 10; run both-held-b-frees-first emulator-5580 20; release

rc=$(timeout 30 sebtype/emulator.sh -- sh -c 'exit 3' 2> /dev/null; echo $?)
[[ $rc == 3 ]] && result PASS exit-status "3 from CMD" || result FAIL exit-status "got $rc, want CMD's 3"

! grep -qv '^PASS' "$results"
