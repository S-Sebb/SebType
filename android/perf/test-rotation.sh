#!/usr/bin/env bash
# Offline checks of perf.sh's screen-rotation guards (#402) and its test field closed at the end (#587),
# against a fake adb: no device needed.
#   android/perf/test-rotation.sh    one PASS/FAIL line per check, exit 0 when all pass
set -uo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/sdk/platform-tools" "$tmp/out/run"
# The fake device: its screen size and rotation from FAKE_SIZE and FAKE_ROT, its system settings in
# files, every shell command logged.
cat > "$tmp/sdk/platform-tools/adb" <<'ADB'
#!/usr/bin/env bash
[[ $1 == shell ]] || exit 0
shift; echo "$*" >> "$FAKE/log"
case "$*" in
  'wm size') echo "Physical size: $FAKE_SIZE" ;;
  'wm density') echo 'Physical density: 420' ;;
  'dumpsys window InputMethod') echo '  touchable region=SkRegion((0,1535,1080,2400))' ;;
  'dumpsys window displays') echo "  mRotation=$FAKE_ROT}"; seq 200000 ;; # long, as a real dump: a reader must take it all
  'settings get system '*) cat "$FAKE/settings/$4" 2>/dev/null || echo null ;;
  'settings put system '*) echo "$5" > "$FAKE/settings/$4" ;;
  'settings delete system '*) rm -f "$FAKE/settings/$4"; echo 'Deleted 1 rows' ;;
esac
ADB
chmod +x "$tmp/sdk/platform-tools/adb"
# SEBTYPE_HOST: on yanglab16, tools/lib.sh would point ANDROID_HOME at its own SDK, past the fake adb
export ANDROID_HOME=$tmp/sdk PERF_OUT=$tmp/out FAKE=$tmp SETTLE_S=0 ANDROID_SERIAL=fake SEBTYPE_HOST=fake
fails=0
ok() { echo "PASS $1"; }
no() { echo "FAIL $1: $2"; fails=$(( fails + 1 )); }
idle() { # size rotation: perf.sh's idle phase (open, measure the grid) on that screen, an old run's grid in place
  echo 'declare -- top="9"' > "$tmp/out/run/geometry"
  FAKE_SIZE=$1 FAKE_ROT=$2 timeout 60 android/perf/perf.sh --phase idle > "$tmp/idle.out" 2> "$tmp/idle.log"
}

idle 1080x2400 ROTATION_0 && grep -q 'top="1535"' "$tmp/out/run/geometry" &&
  ok "upright phone: the grid is measured" || no "upright phone" "$(tail -1 "$tmp/idle.log")"
# The field opens locked upright: only perf.sh asks for that (#524)
grep '^am start' "$FAKE/log" | grep -vq -- '--ez upright true' &&
  no "field upright" "$(grep '^am start' "$FAKE/log" | grep -v -- '--ez upright true' | head -1)" ||
  { grep -q '^am start.*--ez upright true' "$FAKE/log" && ok "field opened upright" || no "field upright" "no am start logged"; }
if idle 1080x2400 ROTATION_1; then no "turned phone" "the phase passed"
elif [[ -e $tmp/out/run/geometry ]]; then no "turned phone" "an old grid is left to type from"
else ok "turned phone: stops, no grid left"; fi
if idle 2560x1600 ROTATION_0; then no "landscape tablet" "the phase passed at rotation 0"
elif ! grep -q "natural orientation isn't portrait" "$tmp/idle.log"; then no "landscape tablet" "$(tail -1 "$tmp/idle.log")"
else ok "landscape tablet: stops, natural orientation named"; fi

# The run puts the owner's settings back exactly: one that wasn't there is deleted. The soak run stops at
# its idle phase here (turned screen), as a failed grid stops every run before its taps.
mkdir -p "$tmp/settings"; echo 0 > "$tmp/settings/accelerometer_rotation"; : > "$tmp/out/results.txt"
cat > "$tmp/monkey-ish" <<'SET'
echo 1 > "$FAKE/settings/accelerometer_rotation"; echo 0 > "$FAKE/settings/user_rotation"
SET
: > "$tmp/log"
FAKE_SIZE=1080x2400 FAKE_ROT=ROTATION_1 timeout 60 bash -c '
  # monkey changes both settings while the run holds the device
  ( sleep 2; . "$FAKE/monkey-ish" ) & android/perf/perf.sh --soak-device' > "$tmp/soak.out" 2>&1
if grep -q '^check soak\|PASS soak\|FAIL soak' "$tmp/out/results.txt"; then no "failed grid stops the soak" "soak ran"
else ok "failed grid: the soak doesn't run"; fi
[[ $(cat "$tmp/settings/accelerometer_rotation") == 0 && ! -e $tmp/settings/user_rotation ]] &&
  ok "rotation settings back as found (absent one deleted)" ||
  no "rotation settings" "accelerometer_rotation=$(cat "$tmp/settings/accelerometer_rotation") user_rotation=$(cat "$tmp/settings/user_rotation" 2>/dev/null || echo absent)"
# However the device steps end, the test field is closed and the phone is back on its home screen (#587).
grep -qx 'am force-stop dev.sebb.sebtype.perffield' "$tmp/log" && ok "test field closed at the end" ||
  no "test field" "still open after the run"
exit $(( fails > 0 ))
