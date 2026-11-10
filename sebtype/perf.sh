#!/usr/bin/env bash
# Measures SebType's size, memory and speed on an Android device (#45); docs/perf.md says how to read it.
#   sebtype/perf.sh          builds the release APK, then measures on the running emulator
# APK=<path> skips the build; ANDROID_SERIAL=<serial> measures on that device instead (the only way to
# pick a phone); RUNS (default 3) repeats each typing set.
# It reinstalls SebType (all its data is lost) and types into its own test field with monkey taps.
# One line per check in results.txt, the table in perf.md, traces and logs in run/, all in
# /tmp/sebtype/perf-<checkout>/ (PERF_OUT=<dir> to put them elsewhere: a run writes ~350 MB of traces),
# so runs from parallel worktrees don't overwrite each other. Exit 0 unless a check fails. Timing comes
# from Perfetto traces of framework slices and frame timelines: nothing typed is recorded.
set -uo pipefail
cd "$(dirname "$0")/.."
self=$PWD/sebtype/perf.sh

export out=${PERF_OUT:-/tmp/sebtype/perf-$(basename "$PWD")}; export work=$out/run
export sdk=${ANDROID_HOME:-$HOME/Android/Sdk}
export adb=$sdk/platform-tools/adb
export runs=${RUNS:-3}
export pkg=dev.sebb.sebtype field=dev.sebb.sebtype.perffield
export ime_id=dev.sebb.sebtype/org.futo.inputmethod.latin.LatinIME
export field_act=dev.sebb.sebtype.perffield/.PerfField
export tp=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/trace_processor_shell-v59.1
export keys_sql=$PWD/sebtype/perf/keys.sql opens_sql=$PWD/sebtype/perf/opens.sql
results=$out/results.txt

result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
# A check runs one phase of this script with a timeout. The phase prints key=value lines; a phase
# that can't run prints "skip=<reason>" and exits 0.
check() { # name timeout
  local name=$1
  if timeout "$2" "$self" --phase "$name" > "$work/$name.out" 2> "$work/$name.log"; then
    if grep -q '^skip=' "$work/$name.out"; then result SKIP "$name" "$(sed -n 's/^skip=//p' "$work/$name.out")"
    else result PASS "$name" "$(grep -v '^#' "$work/$name.out" | tr '\n' ' ')"; fi
  else result FAIL "$name" "$(tail -1 "$work/$name.log") (see $work/$name.log)"; fi
}
val() { sed -n "s/^$2=//p" "$work/$1.out" 2>/dev/null | tail -1; } # phase key -> value

# ---- Device helpers (run inside phases) ----
sh() { "$adb" shell "$@" | tr -d '\r'; }
pss_kb() { # [label]: total PSS; the full breakdown stays in run/meminfo-<label>.txt
  local f=$work/meminfo-${1:-last}.txt
  sh dumpsys meminfo "$pkg" > "$f"; awk '/TOTAL PSS:/ {print $3; exit}' "$f"
}
open_field() {
  local o; o=$(sh am start -W -S -n "$field_act" "$@") || { echo "test field didn't open: $(tail -2 <<<"$o" | tr '\n' ' ')" >&2; return 1; }
  sleep 3
}
geometry() { # keyboard grid from the screen width and the keyboard window's top, in px
  W=$(sh wm size | awk -F'[ x]' '/Physical/ {print $3}' | tail -1)
  dpi=$(sh wm density | awk '/Physical/ {print $3}' | tail -1)
  top=$(sh dumpsys window InputMethod | sed -n 's/.*touchable region=SkRegion((\([0-9]*\),\([0-9]*\),.*/\2/p' | head -1)
  [[ -n $W && -n $dpi && -n $top ]] || { echo "keyboard window not found" >&2; return 1; }
}
key_xy() { # key -> "x y". SebType's uniform layout has 10 key columns in every language; the row
  # centres are 69, 130, 190 and 249 dp below the keyboard's top (the action bar comes first) at
  # FUTO's default keyboard height. Positions are in tenths of a key column.
  local k=$1 rows=(qwertyuiop asdfghjkl zxcvbnm) first=(5 10 20) r pre col y
  case $k in
    ' ') col=55 ;; G) col=30 ;; E) col=92 ;; # space, globe, enter
  esac
  if [[ -n ${col:-} ]]; then y=249
  else
    for r in 0 1 2; do
      pre=${rows[r]%%"$k"*}
      [[ $pre != "${rows[r]}" ]] && { col=$(( first[r] + 10 * ${#pre} )); y=$(( 69 + 61 * r - (r > 1) )); break; }
    done
  fi
  [[ -n ${col:-} ]] || { echo "unknown key $k" >&2; return 1; }
  echo "$(( W * col / 100 )) $(( top + y * dpi / 160 ))"
}
taps() { # gap_ms text: types the text with monkey (G = globe, E = enter), one tap per gap
  local gap=$1 text=$2 i
  { printf 'type= raw events\ncount= 1\nspeed= 1.0\nstart data >>\n'
    for (( i = 0; i < ${#text}; i++ )); do echo "Tap($(key_xy "${text:i:1}" | tr ' ' ','))"; echo "UserWait($gap)"; done
  } > "$work/taps.txt"
  "$adb" push "$work/taps.txt" /data/local/tmp/sebtype-perf-taps.txt > /dev/null
  sh monkey -f /data/local/tmp/sebtype-perf-taps.txt 1 > /dev/null 2>&1
  on_field
}
on_field() { # the taps went to the test field; another app on top means something else drives the device (#76)
  local focus # awk reads it all: dumpsys fails when its pipe closes early
  focus=$(sh dumpsys window | awk '/mCurrentFocus/ && !f++ {sub(/.* u0 /, ""); sub(/}.*/, ""); print}')
  [[ $focus == "$field"/* ]] || { echo "${focus:-another window} took the screen while typing: is something else using this device without its lock?" >&2; return 1; }
}
trace_start() { # name: Perfetto with frame timelines, input/view slices and scheduling
  sh rm -f "/data/misc/perfetto-traces/sebtype-$1.pftrace"
  "$adb" shell 'cat > /data/misc/perfetto-configs/sebtype-perf.pbtxt' <<EOF
buffers { size_kb: 65536 fill_policy: RING_BUFFER }
write_into_file: true
file_write_period_ms: 1000
flush_period_ms: 2000
duration_ms: 600000
data_sources { config { name: "linux.ftrace" ftrace_config {
  atrace_categories: "input" atrace_categories: "view" atrace_categories: "gfx" atrace_categories: "am"
  atrace_categories: "wm" atrace_categories: "dalvik"
  atrace_apps: "$pkg" atrace_apps: "$field"
  ftrace_events: "sched/sched_switch" } } }
data_sources { config { name: "linux.process_stats" } }
data_sources { config { name: "android.surfaceflinger.frametimeline" } }
EOF
  tracer=$(sh perfetto --txt -c /data/misc/perfetto-configs/sebtype-perf.pbtxt \
    -o "/data/misc/perfetto-traces/sebtype-$1.pftrace" --background)
  sleep 2
}
trace_stop() { # name -> $work/name.pftrace
  sh kill -TERM "$tracer"
  local i; for i in {1..20}; do sh kill -0 "$tracer" 2>/dev/null || break; sleep 0.5; done
  "$adb" pull "/data/misc/perfetto-traces/sebtype-$1.pftrace" "$work/$1.pftrace" > /dev/null
}
query() { "$tp" -q "$2" "$work/$1.pftrace" 2> /dev/null | grep -v '^Query executed' ; } # trace sql-file
opens() { # trace kind: keyboard open times (opens.sql), summarised by opens.py
  query "$1" "$opens_sql" > "$work/$1.opens.csv"
  python3 -I "$PWD/sebtype/perf/opens.py" "$2" "$work/$1.opens.csv"
}
typed() { # trace -> characters each test field gained (last length - starting length), one per line
  echo "select (select cast(value as int) from counter where track_id = t.id order by ts desc limit 1)
      - (select cast(value as int) from counter where track_id = t.id order by ts limit 1)
    from process_counter_track t where t.name = 'sebperf_len'
    order by (select min(ts) from counter where track_id = t.id);" > "$work/len.sql"
  query "$1" "$work/len.sql" | grep -E '^-?[0-9]+$'
}
per_key() { # trace: the per-key CSV, and the characters typed into each field
  query "$1" "$keys_sql" > "$work/$1.csv"
  echo "keys=$(( $(wc -l < "$work/$1.csv") - 1 ))"
  echo "typed=$(typed "$1" | paste -sd, -)"
  # Nothing in a typing trace restarts the keyboard, so each keyboard process started in it means one died.
  echo "crashes=$(query "$1" "$opens_sql" | grep -c '^"cold"' || true)"
}
typing() { # trace gap text: under one trace, types the text RUNS times, each into a fresh test field
  local r
  trace_start "$1"
  for (( r = 0; r < runs; r++ )); do open_field; taps "$2" "$3"; sleep 5; done
  trace_stop "$1"
  per_key "$1"
}
landed() { # phase taps min% max%: each field's length shows that the taps hit the keys and in which
  # language (pinyin and romaji turn into fewer characters than were typed)
  local n=0 len
  for len in $(sed -n 's/^typed=//p' "$work/$1.part" | tr ',' ' '); do
    (( len * 100 >= $2 * $3 && len * 100 <= $2 * $4 )) ||
      { echo "$1: a field got $len characters from $2 taps: wrong language or taps missed the keys" >&2; return 1; }
    (( ++n ))
  done
  (( n == runs )) || { echo "$1: $n of $runs fields got text" >&2; return 1; }
}
restart_keyboard() { # stop SebType while another keyboard is active, then switch back to it
  sh ime set "$(cat "$work/other-ime")" > /dev/null; sleep 2
  sh am force-stop "$pkg"; sleep 1
  sh ime set "$ime_id" > /dev/null; sleep 5 # the emulator's cold open takes up to 2 s
}
probe_len() { # length of what "ka " types into a fresh test field: 3 in EN, 1 or 2 in 中 and 日
  open_field; taps 300 "ka "; sleep 2
  sh uiautomator dump /data/local/tmp/sebtype-ui.xml > /dev/null
  local text; text=$(sh cat /data/local/tmp/sebtype-ui.xml |
    grep -o '<node [^>]*class="android.widget.EditText"' | sed -n 's/.* text="\([^"]*\)".*/\1/p')
  sh rm -f /data/local/tmp/sebtype-ui.xml
  echo "${#text}"
}
rime_user=/data/user/0/$pkg/files/rime/user # private (#32): readable only from a root shell (emulator)

# ---- Phases ----
phase_install() {
  sh settings get secure default_input_method > "$work/prev-ime"
  sh input keyevent KEYCODE_WAKEUP; sh wm dismiss-keyguard
  "$adb" uninstall "$pkg" > /dev/null || true # fresh: the first-run costs are part of the baseline
  "$adb" install "$APK" > /dev/null || { echo "install failed" >&2; return 1; }
  "$adb" install -r "$work/perf-field.apk" > /dev/null || { echo "field install failed" >&2; return 1; }
  sh ime enable "$ime_id" > /dev/null && sh ime set "$ime_id" > /dev/null
  echo "version=$(sh dumpsys package "$pkg" | sed -n 's/.*versionName=//p' | head -1)"
}
phase_first-open() { # the first keyboard open after install
  trace_start first-open
  open_field
  sleep 5
  trace_stop first-open
  geometry && declare -p W dpi top > "$work/geometry"
  opens first-open first
  echo "pss_idle_kb=$(pss_kb idle)"
}
phase_en() {
  . "$work/geometry"
  # In the first process after install the transformer can stay off (no LanguageModel thread in the
  # trace), so EN types into a second process, as a user would after the first day.
  [[ -s $work/other-ime ]] && restart_keyboard
  local text='the quick brown fox jumps over the lazy dog '
  typing en 700 "$text" | tee "$work/en.part"
  landed en "${#text}" 80 101
  echo "pss_kb=$(pss_kb en)"
}
phase_zh-deploy() { # switch to 中: the first-run Chinese setup (install and check), with peak memory
  . "$work/geometry"
  local peak=0 p log
  "$adb" logcat -c
  taps 0 G
  # Done when the app logs its setup; it times the install and Rime's check itself.
  local deadline=$(( SECONDS + 600 ))
  while (( SECONDS < deadline )); do
    p=$(pss_kb); (( ${p:-0} > peak )) && peak=$p
    log=$("$adb" logcat -d | grep -F 'ChineseIME (rime)' | tr -d '\r' || true) # nothing until setup logs
    [[ $log == *"Set up rime_ice in"* ]] && break
    sleep 1
  done
  [[ $log == *"self-test passed"* ]] || { echo "Chinese setup didn't pass in 10 min: ${log:-no log}" >&2; return 1; }
  echo "setup_ms=$(sed -n 's/.*Set up rime_ice in \([0-9]*\) ms.*/\1/p' <<<"$log" | tail -1)"
  echo "install_ms=$(sed -n 's/.*Installed the bundled [^0-9]* in \([0-9]*\) ms.*/\1/p' <<<"$log" | tail -1)"
  echo "pss_peak_kb=$peak"
  if [[ $(sh su 0 id -u 2>/dev/null) == 0 ]]; then # tables or prisms compiled here
    echo "built_on_device=$(sh su 0 ls "$rime_user/build" | grep -c '\.bin$')"
  fi
}
phase_zh() {
  . "$work/geometry"
  local text='nihao women jintiantianqihenhao ranhou zhongguo '
  typing zh 700 "$text" | tee "$work/zh.part"
  landed zh "${#text}" 10 60
  echo "pss_kb=$(pss_kb zh)"
}
phase_ja() {
  . "$work/geometry"
  taps 0 G; sleep 5 # 中 → 日; Mozc starts
  local text='nihongo konnichiha arigatou toukyou E'
  typing ja 700 "$text" | tee "$work/ja.part"
  landed ja "${#text}" 10 80
  echo "pss_kb=$(pss_kb ja)"
  # Back to EN for the next phases. A single globe tap after 日 didn't always switch on the phone,
  # so check with a probe and tap again (the globe cycles EN → 中 → 日).
  local n
  for n in 1 2 3; do
    taps 0 G; sleep 3
    [[ $(probe_len) == 3 ]] && { echo "globe_taps_to_en=$n"; return; }
  done
  echo "keyboard didn't switch back to EN after 3 globe taps" >&2; return 1
}
gfx() { # package -> janky frames and frame-time percentiles since the last reset
  sh dumpsys gfxinfo "$1" | awk -v p="$2" '
    /Total frames rendered/ {print p "_frames=" $4}
    /Janky frames:/ && !j++ {gsub(/[()%]/, "", $4); print p "_janky_pct=" $4}
    /^95th percentile/ && !q++ {sub(/ms/, "", $3); print p "_p95_ms=" $3}'
}
fast() { # name field-extra...: fast typing (100 ms per key) with gfxinfo jank for both apps
  local name=$1 text="the quick brown fox jumps over the lazy dog the quick brown fox jumps over the lazy dog "
  shift
  . "$work/geometry"
  trace_start "$name"
  open_field "$@" # inside the trace, so the field's starting length is in it
  sh dumpsys gfxinfo "$pkg" reset > /dev/null; sh dumpsys gfxinfo "$field" reset > /dev/null
  taps 100 "$text"
  sleep 5 # the keyboard may still be catching up
  trace_stop "$name"
  per_key "$name"
  echo "taps=${#text}"
  gfx "$pkg" ime; gfx "$field" field
}
phase_fast() { # right after 中 and 日: all three engines are loaded
  fast fast
  echo "pss_kb=$(pss_kb all)"
}
phase_long() { fast long --ei chars 20000; }
phase_unload() { # idle in EN: the engines unload after IDLE_UNLOAD_S (the app's ENGINE_IDLE_MS)
  sleep "${IDLE_UNLOAD_S:-200}"
  echo "pss_kb=$(pss_kb unloaded)"
}
phase_warm-open() { # hide the keyboard and tap the field again, 5 times
  . "$work/geometry"
  open_field
  trace_start warm-open
  for i in {1..5}; do
    sh input keyevent KEYCODE_BACK; sleep 1.5
    sh input tap $(( W / 2 )) $(( top / 2 )); sleep 2.5
  done
  trace_stop warm-open
  opens warm-open warm
}
phase_cold-open() { # switch to another keyboard and back with SebType's process stopped, 3 times
  [[ -s $work/other-ime ]] || { echo "skip=no other keyboard enabled to switch from"; return; }
  open_field
  trace_start cold-open
  for i in 1 2 3; do
    sh ime set "$(cat "$work/other-ime")" > /dev/null; sleep 3
    sh am force-stop "$pkg"; sleep 1
    sh ime set "$ime_id" > /dev/null; sleep 8
  done
  trace_stop cold-open
  opens cold-open cold
  sleep 5; echo "pss_idle_kb=$(pss_kb fresh)" # a fresh process, EN, idle
}
phase_sizes() { # needs a root shell (emulator): app code, internal data, external data
  [[ $(sh id -u) == 0 ]] || { echo "skip=needs a root adb shell to read app data (emulator: adb root)"; return; }
  echo "code_mb=$(sh du -sm "$(dirname "$(sh pm path "$pkg" | head -1 | cut -d: -f2)")" | cut -f1)"
  echo "data_mb=$(sh du -sm "/data/data/$pkg" | cut -f1)"
  local ext; ext=$(sh du -sm "/sdcard/Android/data/$pkg" 2>/dev/null | cut -f1)
  echo "external_mb=${ext:-0}" # none since #32
}

device_steps() { # under the device lock
  trap 'sh ime set "$(cat "$work/prev-ime")" > /dev/null; sh rm -f /data/misc/perfetto-traces/sebtype-*.pftrace \
    /data/misc/perfetto-configs/sebtype-perf.pbtxt /data/local/tmp/sebtype-perf-taps.txt \
    /data/local/tmp/sebtype-ui.xml' EXIT
  check install 600 || return 1
  grep -q '^PASS install' "$results" || return 1
  check first-open 120
  check en 600
  check zh-deploy 1200
  check zh 600
  check ja 600
  check fast 300
  check long 300
  check unload 400
  check warm-open 300
  check cold-open 300
  check sizes 120
}

if [[ ${1:-} == --phase ]]; then
  # Names the innermost failing command in the FAIL line; failing functions have said why already.
  set -eE; trap 'declare -F "${BASH_COMMAND%% *}" > /dev/null || [[ $BASH_COMMAND == return* || $BASH_COMMAND == *phase_* ]] ||
    echo "line ${BASH_LINENO[0]} in ${FUNCNAME[1]:-main}: ${FUNCNAME[0]:-} $BASH_COMMAND failed" >&2' ERR
  "phase_$2"; exit
fi
if [[ ${1:-} == --device ]]; then device_steps; exit; fi

# ---- Preflight ----
mkdir -p "$out"; rm -rf "$work"; mkdir -p "$work"; : > "$results"
[[ -x $adb ]] || { echo "preflight: adb missing in $sdk"; exit 1; }
# A phone only when named: the run reinstalls SebType, which wipes what it learned there.
export ANDROID_SERIAL=${ANDROID_SERIAL:-$("$adb" devices | awk '$1 ~ /^emulator-/ && $2 == "device" {print $1; exit}')}
[[ -n $ANDROID_SERIAL ]] || { echo "preflight: no emulator running (start AVD guide35; for a phone set ANDROID_SERIAL)"; exit 1; }
[[ $("$adb" -s "$ANDROID_SERIAL" get-state 2>/dev/null) == device ]] || { echo "preflight: $ANDROID_SERIAL not connected"; exit 1; }
[[ $(sh getprop ro.product.cpu.abilist) == *arm64-v8a* ]] || { echo "preflight: $ANDROID_SERIAL can't run arm64 apps"; exit 1; }
(( $(sh getprop ro.build.version.sdk) >= 34 )) || { echo "preflight: needs Android 14+ (older trace formats are untested)"; exit 1; }
for x in python3 curl unzip; do command -v $x >/dev/null || { echo "preflight: $x missing"; exit 1; }; done
if [[ ! -x $tp ]]; then # Perfetto's trace processor, pinned
  mkdir -p "$(dirname "$tp")"
  curl -fsSL -o "$tp.part" https://commondatastorage.googleapis.com/perfetto-luci-artifacts/v59.1/linux-amd64/trace_processor_shell &&
    echo "2434129a3af4dc9e2034a476f7b76447b490975213e301769310d3bd0d5d6458  $tp.part" | sha256sum -c --status &&
    chmod +x "$tp.part" && mv "$tp.part" "$tp" || { echo "preflight: can't fetch Perfetto's trace processor"; exit 1; }
fi
sebtype/perf/build-field.sh "$work/perf-field.apk" > "$work/field-build.log" 2>&1 ||
  { echo "preflight: test field doesn't build, see $work/field-build.log"; exit 1; }
if [[ -z ${APK:-} ]]; then
  APK=$(sebtype/build.sh release 2> "$work/build.log" | tail -1)
  [[ -f $APK ]] || { echo "preflight: release build failed, see $work/build.log"; exit 1; }
fi
export APK=$(realpath "$APK")
[[ -f $APK ]] || { echo "preflight: no APK at $APK"; exit 1; }
# Another keyboard to switch from for the cold open (the phone keeps Gboard for banking apps).
# Gboard first: stock FUTO crashes in Mozc on the emulator.
{ sh ime list -s | grep -m1 '^com.google.android.inputmethod.latin/' ||
  sh ime list -s | grep -m1 '^org.futo.inputmethod.latin/'; } > "$work/other-ime"
# Device locks are shared by all projects. An emulator's is named after its AVD; a phone shares the
# lock of the PC it's plugged into, which other projects (SebChat) take for the phone. A lock of its
# own let two agents tap the phone at once (#76).
case $ANDROID_SERIAL in
  emulator-*) lock=/tmp/agent-locks/devices/emulator-$("$adb" emu avd name | head -1 | tr -d '\r').lock ;;
  *) lock=/tmp/agent-locks/devices/$(hostname -s).lock ;;
esac
echo "measuring $APK on $ANDROID_SERIAL ($(sh getprop ro.product.model), Android $(sh getprop ro.build.version.release))"

# ---- Static: the APK ----
bt=$(ls -d "$sdk"/build-tools/* | tail -1)
"$bt/aapt2" dump resources "$APK" > "$work/resources.txt"
unzip -Zl "$APK" | awk 'NF >= 10 && $10 ~ /\// {print $6, $10}' | sort -rn | head -12 | while read -r size path; do
  # Resource shrinking renames res/ files; show the resource name instead.
  name=$(grep -B3 -F "$path" "$work/resources.txt" | grep -oE '(raw|drawable|font)/[A-Za-z0-9_]+' | tail -1)
  echo "$(( size / 1048576 )) MB ${name:-$path}"
done > "$work/apk-top.txt"
echo "size_mb=$(( $(stat -c %s "$APK") / 1048576 ))" > "$work/apk.out"
result PASS apk "$(cat "$work/apk.out")"

T=${PERF_LOCK_MINUTES:-30}
devq -P "${PERF_PRIORITY:-5}" -w 1800 -m "$T" -n "sebtype perf.sh" "$lock" "$self" --device ||
  echo "device steps stopped early (lock timeout or install failure)" >&2

python3 -I sebtype/perf/table.py "$work" "$results" > "$out/perf.md"
cat "$out/perf.md"
! grep -q '^FAIL' "$results" # a SKIP (e.g. sizes without root on a phone) doesn't fail the run
