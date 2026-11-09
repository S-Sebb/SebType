#!/usr/bin/env bash
# Measures SebType's size, memory and speed on an Android device (#45); docs/perf.md says how to read it.
#   sebtype/perf.sh          builds the release APK, then measures on the first adb device
# APK=<path> skips the build; ANDROID_SERIAL picks the device; RUNS (default 3) repeats each typing set.
# It reinstalls SebType (all its data is lost) and types into its own test field with monkey taps.
# One line per check in /tmp/sebtype/perf-results.txt, the table in /tmp/sebtype/perf.md, traces and
# logs in /tmp/sebtype/perf/. Exit 0 only if every check passes. Timing comes from Perfetto traces of
# framework slices, frame timelines and ImeTracker logs: nothing typed is recorded.
set -uo pipefail
cd "$(dirname "$0")/.."
self=$PWD/sebtype/perf.sh

export out=/tmp/sebtype work=/tmp/sebtype/perf
export sdk=${ANDROID_HOME:-$HOME/Android/Sdk}
export adb=$sdk/platform-tools/adb
export runs=${RUNS:-3}
export pkg=dev.sebb.sebtype field=dev.sebb.sebtype.perffield
export ime_id=dev.sebb.sebtype/org.futo.inputmethod.latin.LatinIME
export field_act=dev.sebb.sebtype.perffield/.PerfField
export tp=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/trace_processor_shell-v59.1
export keys_sql=$PWD/sebtype/perf/keys.sql
results=$out/perf-results.txt

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
pss_kb() { sh dumpsys meminfo "$pkg" | awk '/TOTAL PSS:/ {print $3; exit}'; }
open_field() { sh am start -W -S -n "$field_act" "$@" > /dev/null; sleep 3; }
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
}
trace_start() { # name: Perfetto with frame timelines, input/view slices, scheduling and logcat
  sh rm -f "/data/misc/perfetto-traces/sebtype-$1.pftrace"
  "$adb" shell 'cat > /data/misc/perfetto-configs/sebtype-perf.pbtxt' <<EOF
buffers { size_kb: 32768 fill_policy: DISCARD }
write_into_file: true
file_write_period_ms: 1000
duration_ms: 600000
data_sources { config { name: "linux.ftrace" ftrace_config {
  atrace_categories: "input" atrace_categories: "view" atrace_categories: "gfx" atrace_categories: "am"
  atrace_categories: "wm" atrace_categories: "dalvik"
  atrace_apps: "$pkg" atrace_apps: "$field"
  ftrace_events: "sched/sched_switch" } } }
data_sources { config { name: "linux.process_stats" } }
data_sources { config { name: "android.surfaceflinger.frametimeline" } }
data_sources { config { name: "android.log" android_log_config { log_ids: LID_DEFAULT log_ids: LID_SYSTEM } } }
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
ime_logs() { # trace -> CSV of ImeTracker events and keyboard process starts
  echo "select ts, msg from android_logs where tag = 'ImeTracker' and msg like '$field:%'
    or (tag = 'ActivityManager' and msg like 'Start proc %:$pkg/%') order by ts;" > "$work/logs.sql"
  query "$1" "$work/logs.sql"
}
text_len() { # trace -> last length of the test field's text
  echo "select cast(value as int) from counter c join process_counter_track t on c.track_id = t.id
    where t.name = 'sebperf_len' order by c.ts desc limit 1;" > "$work/len.sql"
  query "$1" "$work/len.sql" | tail -1
}
typing() { # trace gap text: types under a trace, then writes the per-key CSV
  trace_start "$1"
  taps "$2" "$3"
  sleep 2
  trace_stop "$1"
  query "$1" "$keys_sql" > "$work/$1.csv"
  echo "keys=$(( $(wc -l < "$work/$1.csv") - 1 ))"
  echo "text_len=$(text_len "$1")"
}
landed() { # phase taps min% max%: the field's final length shows that the taps hit the keys and in
  # which language (pinyin and romaji turn into fewer characters than were typed)
  local len; len=$(sed -n 's/^text_len=//p' "$work/$1.part")
  (( ${len:-0} * 100 >= $2 * $3 && ${len:-0} * 100 <= $2 * $4 )) ||
    { echo "$1: field has ${len:-no} characters after $2 taps: wrong language or taps missed the keys" >&2; return 1; }
}
rime_dir=/sdcard/Android/data/$pkg/files/rime

# ---- Phases ----
phase_install() {
  sh settings get secure default_input_method > "$work/prev-ime"
  sh input keyevent KEYCODE_WAKEUP; sh wm dismiss-keyguard
  "$adb" uninstall "$pkg" > /dev/null # fresh: the first-run costs are part of the baseline
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
  ime_logs first-open > "$work/first-open.logs"
  python3 -I "$PWD/sebtype/perf/opens.py" first "$work/first-open.logs"
  geometry && declare -p W dpi top > "$work/geometry"
  echo "pss_idle_kb=$(pss_kb)"
}
phase_en() {
  . "$work/geometry"
  local text=$(for (( i = 0; i < runs; i++ )); do printf 'the quick brown fox jumps over the lazy dog '; done)
  typing en 700 "$text" | tee "$work/en.part"
  landed en "${#text}" 80 101
  echo "pss_kb=$(pss_kb)"
}
phase_zh-deploy() { # switch to 中: the first-run Rime deploy (rime-ice), with peak memory
  . "$work/geometry"
  local start peak=0 p prev="" same=0 t
  if [[ ! -f $work/rime-bundled ]]; then
    # main doesn't bundle rime-ice yet (#8): FUTO clears rime/shared on the first 中 start, so let
    # that happen, push rime-ice, then restart the keyboard so its next 中 start deploys it.
    taps 0 G; sleep 5
    "$adb" push "$work/shared" "$rime_dir/" > /dev/null || { echo "push failed" >&2; return 1; }
    sh ime set "$(cat "$work/other-ime")" > /dev/null; sleep 2
    sh am force-stop "$pkg"; sleep 1
    start=$(date +%s.%N)
    sh ime set "$ime_id" > /dev/null
  else
    start=$(date +%s.%N)
    taps 0 G
  fi
  # Done when the compiled tables exist and the Rime folder hasn't changed for 5 s.
  for (( t = 0; t < 900; t++ )); do
    p=$(pss_kb); (( ${p:-0} > peak )) && peak=$p
    cur=$(sh "du -s $rime_dir; ls $rime_dir/user/build 2>/dev/null" | tr '\n' ' ')
    if [[ $cur == "$prev" && $cur == *.table.bin* && $cur == *.prism.bin* ]]; then
      (( ++same >= 5 )) && break
    else same=0; last=$(date +%s.%N); fi
    prev=$cur; sleep 1
  done
  (( same >= 5 )) || { echo "deploy didn't finish in 15 min" >&2; return 1; }
  echo "deploy_s=$(awk -v a="$start" -v b="$last" 'BEGIN {printf "%.0f", b - a}')"
  echo "pss_peak_kb=$peak"
  echo "build_mb=$(sh du -sm "$rime_dir/user/build" | cut -f1)"
}
phase_zh() {
  . "$work/geometry"
  local text=$(for (( i = 0; i < runs; i++ )); do printf 'nihao women jintiantianqihenhao ranhou zhongguo '; done)
  typing zh 700 "$text" | tee "$work/zh.part"
  landed zh "${#text}" 10 60
  echo "pss_kb=$(pss_kb)"
}
phase_ja() {
  . "$work/geometry"
  taps 0 G; sleep 5 # 中 → 日; Mozc starts
  local text=$(for (( i = 0; i < runs; i++ )); do printf 'nihongo konnichiha arigatou toukyou E'; done)
  typing ja 700 "$text" | tee "$work/ja.part"
  landed ja "${#text}" 10 80
  echo "pss_kb=$(pss_kb)"
  taps 0 G; sleep 2 # back to EN for the next phases
}
gfx() { # package -> janky frames and frame-time percentiles since the last reset
  sh dumpsys gfxinfo "$1" | awk -v p="$2" '
    /Total frames rendered/ {print p "_frames=" $4}
    /Janky frames:/ && !j++ {gsub(/[()%]/, "", $4); print p "_janky_pct=" $4}
    /^95th percentile/ && !q++ {sub(/ms/, "", $3); print p "_p95_ms=" $3}'
}
fast() { # name field-extra...: fast typing (100 ms per key) with gfxinfo jank for both apps
  local name=$1; shift
  . "$work/geometry"
  open_field "$@"
  sh dumpsys gfxinfo "$pkg" reset > /dev/null; sh dumpsys gfxinfo "$field" reset > /dev/null
  typing "$name" 100 "the quick brown fox jumps over the lazy dog the quick brown fox jumps over the lazy dog "
  gfx "$pkg" ime; gfx "$field" field
}
phase_fast() { fast fast; }
phase_long() { fast long --ei chars 20000; }
phase_warm-open() { # hide the keyboard and tap the field again, 5 times
  . "$work/geometry"
  open_field
  trace_start warm-open
  for i in {1..5}; do
    sh input keyevent KEYCODE_BACK; sleep 1.5
    sh input tap $(( W / 2 )) $(( top / 2 )); sleep 2.5
  done
  trace_stop warm-open
  ime_logs warm-open > "$work/warm-open.logs"
  python3 -I "$PWD/sebtype/perf/opens.py" warm "$work/warm-open.logs"
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
  ime_logs cold-open > "$work/cold-open.logs"
  python3 -I "$PWD/sebtype/perf/opens.py" cold "$work/cold-open.logs"
  sleep 5; echo "pss_idle_kb=$(pss_kb)" # a fresh process, EN, idle
}
phase_sizes() { # needs a root shell (emulator): app code, internal data, external data
  [[ $(sh id -u) == 0 ]] || { echo "skip=needs a root adb shell to read app data (emulator: adb root)"; return; }
  echo "code_mb=$(sh du -sm "$(dirname "$(sh pm path "$pkg" | head -1 | cut -d: -f2)")" | cut -f1)"
  echo "data_mb=$(sh du -sm "/data/data/$pkg" | cut -f1)"
  echo "external_mb=$(sh du -sm "/sdcard/Android/data/$pkg" | cut -f1)"
}

device_steps() { # under the device lock
  check install 600 || return 1
  grep -q '^PASS install' "$results" || return 1
  check first-open 120
  check en 600
  check zh-deploy 1200
  check zh 600
  check ja 600
  check fast 300
  check long 300
  check warm-open 300
  check cold-open 300
  check sizes 120
  sh ime set "$(cat "$work/prev-ime")" > /dev/null # give the device back with its keyboard
}

if [[ ${1:-} == --phase ]]; then set -e; "phase_$2"; exit; fi
if [[ ${1:-} == --device ]]; then device_steps; exit; fi

# ---- Preflight ----
mkdir -p "$out"; rm -rf "$work"; mkdir -p "$work"; : > "$results"
[[ -x $adb ]] || { echo "preflight: adb missing in $sdk"; exit 1; }
export ANDROID_SERIAL=${ANDROID_SERIAL:-$("$adb" devices | awk 'NR > 1 && $2 == "device" {print $1; exit}')}
[[ -n $ANDROID_SERIAL ]] || { echo "preflight: no adb device (start AVD guide35 or connect the phone)"; exit 1; }
[[ $(sh getprop ro.product.cpu.abilist) == *arm64-v8a* ]] || { echo "preflight: $ANDROID_SERIAL can't run arm64 apps"; exit 1; }
(( $(sh getprop ro.build.version.sdk) >= 34 )) || { echo "preflight: needs Android 14+ (ImeTracker logs)"; exit 1; }
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
if unzip -Z1 "$APK" | grep -q 'rime_ice.schema.yaml'; then touch "$work/rime-bundled"
else # rime-ice packed as for #4, without personal words
  tools/pack-rime-ice.sh "" "$work/rime-ice.dict" > "$work/rime-ice.log" 2>&1 &&
    unzip -q "$work/rime-ice.dict" -d "$work/shared" || { echo "preflight: can't pack rime-ice, see $work/rime-ice.log"; exit 1; }
fi
# Another keyboard to switch from for the cold open (the phone keeps Gboard for banking apps).
sh ime list -s | grep -E '^(com.google.android.inputmethod.latin|org.futo.inputmethod.latin)/' | head -1 > "$work/other-ime"
case $ANDROID_SERIAL in emulator-*) lock=/tmp/agent-locks/sebtype/emulator.lock ;; *) lock=/tmp/agent-locks/sebtype/phone.lock ;; esac
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
! grep -qv '^PASS' "$results"
