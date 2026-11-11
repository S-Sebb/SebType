#!/usr/bin/env bash
# Runs CMD on a device under that device's lock, held for all of CMD:
#   sebtype/emulator.sh [devq options] -- CMD [ARGS...]
# Without ANDROID_SERIAL it takes one of SebType's two emulators (Decisions #2): the one whose lock is
# free, a running one before one it has to start, else the one with the shorter queue. One it starts
# runs headless; guide35b is stopped again when CMD ends, guide35 stays up for the other projects
# (SebChat) and scripts that expect it running. ANDROID_SERIAL picks the device instead: an
# emulator by its AVD's lock, a phone by the lock of the PC it's plugged into, which other projects
# (SebChat) take for the phone (#76). CMD gets ANDROID_SERIAL; the exit status is CMD's, or devq's 1
# if the lock's turn didn't come.
# Locks are shared by all projects: /tmp/agent-locks/devices/emulator-<AVD>.lock.
set -uo pipefail
sdk=${ANDROID_HOME:-$HOME/Android/Sdk}
adb=$sdk/platform-tools/adb
locks=/tmp/agent-locks/devices
# AVD and console port: a fixed port gives each emulator a stable serial, emulator-<port>.
emulators=(guide35:5554 guide35b:5580)
on_demand=guide35b # stopped when the run that started it ends: two emulators leave little memory

serial_of() { # AVD -> serial of its running emulator, booted or not
  local s
  for s in $("$adb" devices | awk '$1 ~ /^emulator-/ {print $1}'); do
    [[ $("$adb" -s "$s" emu avd name 2>/dev/null | head -1 | tr -d '\r') == "$1" ]] && { echo "$s"; return; }
  done
  return 1
}

if [[ ${1:-} == --run ]]; then # under the lock: $avd and $port from the caller
  shift
  started= pid=$$
  if [[ -z ${ANDROID_SERIAL:-} ]]; then
    if ! ANDROID_SERIAL=$(serial_of "$avd"); then
      ANDROID_SERIAL=emulator-$port started=1
      mkdir -p /tmp/sebtype
      # No snapshot saved either: it would write the RAM to disk at every stop.
      setsid "$sdk/emulator/emulator" -avd "$avd" -port "$port" -no-window -no-audio -no-snapshot-load \
        -no-snapshot-save -no-boot-anim < /dev/null > "/tmp/sebtype/emulator-$avd.log" 2>&1 &
      pid=$!
    fi
    export ANDROID_SERIAL
    timeout 600 bash -c 'until [[ $("$0" shell getprop sys.boot_completed 2>/dev/null | tr -d "\r") == 1 ]]; do
      kill -0 "$1" 2> /dev/null || exit 1; sleep 3; done' "$adb" "$pid" ||
      { echo "emulator $avd ($ANDROID_SERIAL) didn't boot, see /tmp/sebtype/emulator-$avd.log" >&2; exit 1; }
    # A cold boot keeps the guest busy for about a minute after it says it's booted (load up to 13),
    # too slow for the UI checks: wait until its 1-minute load is below 3, about 2 minutes.
    [[ -n $started ]] && timeout 300 bash -c 'until (( $("$0" shell cat /proc/loadavg | cut -d. -f1) < 3 )); do
      sleep 5; done' "$adb"
  fi
  "$@"; rc=$?
  if [[ -n $started && $avd == "$on_demand" ]]; then
    "$adb" emu kill > /dev/null
    timeout 60 bash -c 'while "$0" -s "$1" get-state > /dev/null 2>&1; do sleep 1; done' "$adb" "$ANDROID_SERIAL"
  fi
  exit $rc
fi

opts=()
while [[ $# -gt 0 && $1 != -- ]]; do opts+=("$1"); shift; done
shift
[[ $# -gt 0 ]] || { echo "usage: sebtype/emulator.sh [devq options] -- CMD [ARGS...]" >&2; exit 2; }

if [[ -n ${ANDROID_SERIAL:-} ]]; then
  [[ $("$adb" -s "$ANDROID_SERIAL" get-state 2>/dev/null) == device ]] || { echo "$ANDROID_SERIAL not connected" >&2; exit 1; }
  case $ANDROID_SERIAL in
    emulator-*) lock=$locks/emulator-$("$adb" -s "$ANDROID_SERIAL" emu avd name | head -1 | tr -d '\r').lock ;;
    *) lock=$locks/$(hostname -s).lock ;;
  esac
  export ANDROID_SERIAL
  exec devq "${opts[@]}" "$lock" "$0" --run "$@"
fi

# Lowest score first: 0 free and running, 1 free, then 2 + the number waiting.
best= best_score=
for e in "${emulators[@]}"; do
  avd=${e%:*} lock=$locks/emulator-$avd.lock
  waiting=0
  for f in "$lock.queue"/*; do [[ -e $f ]] && kill -0 "$(cut -d' ' -f1 "$f")" 2> /dev/null && ((waiting++)); done
  if ((waiting == 0)) && flock -n "$lock" true; then score=$(serial_of "$avd" > /dev/null && echo 0 || echo 1)
  else score=$((2 + waiting)); fi
  [[ -z $best_score ]] || ((score < best_score)) && { best=$e best_score=$score; }
done
export avd=${best%:*} port=${best#*:}
exec devq "${opts[@]}" "$locks/emulator-$avd.lock" "$0" --run "$@"
