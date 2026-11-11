#!/usr/bin/env bash
# Runs CMD on a device under that device's lock, held for all of CMD:
#   sebtype/emulator.sh [devq options] -- CMD [ARGS...]
# Without ANDROID_SERIAL it takes one of SebType's two emulators (Decisions #2): it queues for the
# best one (free, a running one before one it has to start, else the shorter queue), and if that turn
# doesn't come within seconds, for the other too; the first turn wins (#140). One it starts
# runs headless; guide35b is stopped again when CMD ends, guide35 stays up for the other projects
# (SebChat) and scripts that expect it running. ANDROID_SERIAL picks the device instead: an
# emulator by its AVD's lock, a phone by its maker and model (nothing-a001.lock), the lock every
# project's agents take for that phone (#76). CMD gets ANDROID_SERIAL; the exit status is CMD's, or
# devq's 1 if the lock's turn didn't come.
# Locks are shared by all projects: /tmp/agent-locks/devices/emulator-<AVD>.lock.
set -uo pipefail
sdk=${ANDROID_HOME:-$HOME/Android/Sdk}
adb=$sdk/platform-tools/adb
locks=${EMULATOR_LOCKS:-/tmp/agent-locks/devices} # another directory only for sebtype/test-emulator-pick.sh
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
  started=
  won=${pick:-}; unset pick # not passed on to CMD, which may run emulator.sh itself
  if [[ -n $won ]]; then # queued for both emulators: run only on the first turn, leave the other queue
    mkdir "$won/won" 2> /dev/null || exit 0
    for f in "$won"/*.pid; do [[ $f == "$won/$avd.pid" ]] || kill "$(< "$f")" 2> /dev/null; done
  fi
  if [[ -z ${ANDROID_SERIAL:-} ]]; then
    unit=emulator-$avd
    if ! ANDROID_SERIAL=$(serial_of "$avd"); then
      ANDROID_SERIAL=emulator-$port
      if ! systemctl --user is-active --quiet "$unit"; then # else it's booting
        started=1
        mkdir -p /tmp/sebtype
        # A unit of the user's systemd, not a child of this shell: an emulator in an agent's process
        # tree stops when that agent's session ends, under whoever holds its lock then. No snapshot
        # saved either: it would write the RAM to disk at every stop.
        systemd-run --user --collect --quiet --unit="$unit" sh -c "exec '$sdk/emulator/emulator' -avd $avd -port $port \
          -no-window -no-audio -no-snapshot-load -no-snapshot-save -no-boot-anim > /tmp/sebtype/emulator-$avd.log 2>&1"
      fi
    fi
    export ANDROID_SERIAL
    timeout 600 bash -c 'until [[ $("$0" shell getprop sys.boot_completed 2>/dev/null | tr -d "\r") == 1 ]]; do
      [[ $1 == "" ]] || systemctl --user is-active --quiet "$1" || exit 1; sleep 3; done' "$adb" "${started:+$unit}" ||
      { echo "emulator $avd ($ANDROID_SERIAL) didn't boot, see /tmp/sebtype/emulator-$avd.log" >&2; exit 1; }
    # A cold boot keeps the guest busy for about a minute after it says it's booted (load up to 13),
    # too slow for the UI checks: wait until its 1-minute load is below 3, about 2 minutes.
    [[ -n $started ]] && timeout 300 bash -c 'until (( $("$0" shell cat /proc/loadavg | cut -d. -f1) < 3 )); do
      sleep 5; done' "$adb"
  fi
  # An app too slow to answer under load (a cold boot, both emulators busy) gets an "isn't responding"
  # dialog that covers the screen and fails every UI check after it; hidden, Android closes the app.
  [[ $ANDROID_SERIAL == emulator-* ]] && "$adb" shell settings put global hide_error_dialogs 1
  "$@"; rc=$?
  if [[ -n $started && $avd == "$on_demand" ]]; then
    "$adb" emu kill > /dev/null
    timeout 60 bash -c 'while systemctl --user is-active --quiet "$0"; do sleep 1; done' "$unit"
  fi
  [[ -n $won ]] && echo $rc > "$won/rc"
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
    *) lock=$locks/$("$adb" -s "$ANDROID_SERIAL" shell getprop ro.product.manufacturer | tr -d '\r')-$("$adb" -s "$ANDROID_SERIAL" shell getprop ro.product.model | tr -d '\r').lock
       lock=${lock,,} ;;
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
# The picked lock can be taken before devq gets it, or both be held (#140): unless its turn comes within
# 5 seconds, queue for the other one too and run on whichever turn comes first.
pick=$(mktemp -d /tmp/sebtype-emulator-pick.XXXXXX)
trap 'rm -rf "$pick"' EXIT
trap 'kill $(cat "$pick"/*.pid) 2> /dev/null; exit 143' TERM INT
queue() {
  avd=${1%:*} port=${1#*:} pick=$pick devq "${opts[@]}" "$locks/emulator-${1%:*}.lock" "$0" --run "${@:2}" <&0 &
  echo $! > "$pick/${1%:*}.pid"
}
queue "$best" "$@"
for _ in {1..25}; do [[ -d $pick/won ]] && break; sleep 0.2; done
[[ -d $pick/won ]] || for e in "${emulators[@]}"; do [[ $e == "$best" ]] || queue "$e" "$@"; done
wait
[[ -e $pick/rc ]] || exit 1 # no turn came: devq said why
exit "$(< "$pick/rc")"
