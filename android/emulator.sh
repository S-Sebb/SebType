#!/usr/bin/env bash
# Runs CMD on a device under that device's lock, held for all of CMD:
#   android/emulator.sh [devq options] -- CMD [ARGS...]
# Without ANDROID_SERIAL it queues for SebType's one emulator, guide35: one emulator at a time, two ran
# the PC out of memory (Decisions #2, #170). If it isn't running it is started headless, and stopped when
# CMD ends unless another run waits in the lock's queue, which then stops it in turn (#194). An emulator
# this script didn't start is left running. ANDROID_SERIAL picks the device instead: an
# emulator by its AVD's lock, a phone by the lock of the PC it's plugged into, which other projects
# (SebChat) take for the phone (#76). CMD gets ANDROID_SERIAL; the exit status is CMD's, or devq's 1
# if the lock's turn didn't come.
# Locks are shared by all projects: /tmp/agent-locks/devices/emulator-<AVD>.lock.
set -uo pipefail
source "$(dirname "$0")/../tools/lib.sh"
sdk=$ANDROID_HOME
adb=$sdk/platform-tools/adb
locks=${EMULATOR_LOCKS:-/tmp/agent-locks/devices} # another directory only for android/test/emulator-pick.sh
# AVD and console port: a fixed port gives the emulator a stable serial, emulator-<port>.
avd=guide35 port=5554
# The InvocationID of the emulator's unit when this script started it: whichever run ends with nobody
# waiting stops it. A unit started any other way has another ID.
started_by_us=$locks/emulator-$avd.lock.started

serial_of() { # AVD -> serial of its running emulator, booted or not
  local s
  for s in $("$adb" devices | awk '$1 ~ /^emulator-/ {print $1}'); do
    [[ $("$adb" -s "$s" emu avd name 2>/dev/null | head -1 | tr -d '\r') == "$1" ]] && { echo "$s"; return; }
  done
  return 1
}

# Stops the emulator if this script started it and no other run waits for it (a ticket of a live devq).
stop_if_unused() {
  local t pid
  [[ -s $started_by_us && $(< "$started_by_us") == $(systemctl --user show -p InvocationID --value "$unit") ]] || return 0
  for t in "$locks/emulator-$avd.lock.queue"/*; do
    [[ -e $t ]] && read -r pid _ < "$t" && kill -0 "$pid" 2> /dev/null && return 0
  done
  rm -f "$started_by_us"
  "$adb" -s "emulator-$port" emu kill > /dev/null 2>&1
  timeout 30 bash -c 'while systemctl --user is-active --quiet "$0"; do sleep 1; done' "$unit" ||
    systemctl --user stop "$unit"
}

if [[ ${1:-} == --run ]]; then # under the lock
  shift
  started=
  if [[ -z ${ANDROID_SERIAL:-} ]]; then
    unit=emulator-$avd
    if ! ANDROID_SERIAL=$(serial_of "$avd"); then
      ANDROID_SERIAL=emulator-$port
      if ! systemctl --user is-active --quiet "$unit"; then # else it's booting
        started=1
        mkdir -p "$SCRATCH"
        # A unit of the user's systemd, not a child of this shell: an emulator in an agent's process
        # tree stops when that agent's session ends, under whoever holds its lock then. No snapshot
        # saved either: it would write the RAM to disk at every stop.
        systemd-run --user --collect --quiet --unit="$unit" sh -c "exec '$sdk/emulator/emulator' -avd $avd -port $port \
          -no-window -no-audio -no-snapshot-load -no-snapshot-save -no-boot-anim > $SCRATCH/emulator-$avd.log 2>&1"
        systemctl --user show -p InvocationID --value "$unit" > "$started_by_us"
      fi
    fi
    # Also when the boot fails or the run is interrupted. TERM and INT would skip the EXIT trap.
    trap stop_if_unused EXIT; trap 'exit 143' TERM; trap 'exit 130' INT
    export ANDROID_SERIAL
    timeout 600 bash -c 'until [[ $("$0" shell getprop sys.boot_completed 2>/dev/null | tr -d "\r") == 1 ]]; do
      [[ $1 == "" ]] || systemctl --user is-active --quiet "$1" || exit 1; sleep 3; done' "$adb" "${started:+$unit}" ||
      { echo "emulator $avd ($ANDROID_SERIAL) didn't boot, see $SCRATCH/emulator-$avd.log" >&2; exit 1; }
    # A cold boot keeps the guest busy for about a minute after it says it's booted (load up to 13),
    # too slow for the UI checks: wait until its 1-minute load is below 3, about 2 minutes.
    [[ -n $started ]] && timeout 300 bash -c 'until (( $("$0" shell cat /proc/loadavg | cut -d. -f1) < 3 )); do
      sleep 5; done' "$adb"
  fi
  # An app too slow to answer under load (a cold boot) gets an "isn't responding"
  # dialog that covers the screen and fails every UI check after it; hidden, Android closes the app.
  [[ $ANDROID_SERIAL == emulator-* ]] && "$adb" shell settings put global hide_error_dialogs 1
  "$@"
  exit
fi

opts=()
while [[ $# -gt 0 && $1 != -- ]]; do opts+=("$1"); shift; done
shift
[[ $# -gt 0 ]] || { echo "usage: android/emulator.sh [devq options] -- CMD [ARGS...]" >&2; exit 2; }

if [[ -n ${ANDROID_SERIAL:-} ]]; then
  [[ $("$adb" -s "$ANDROID_SERIAL" get-state 2>/dev/null) == device ]] || { echo "$ANDROID_SERIAL not connected" >&2; exit 1; }
  case $ANDROID_SERIAL in
    emulator-*) lock=$locks/emulator-$("$adb" -s "$ANDROID_SERIAL" emu avd name | head -1 | tr -d '\r').lock ;;
    *) lock=$locks/$(hostname -s).lock ;;
  esac
  export ANDROID_SERIAL
  exec devq "${opts[@]}" "$lock" "$0" --run "$@"
fi

exec devq "${opts[@]}" "$locks/emulator-$avd.lock" "$0" --run "$@"
