#!/usr/bin/env bash
# Measures the engines of SebType's input method (#45, #190) without touching the live Fcitx5 session:
#   - Rime with rime-ice, on SebType's librime: per-key time (key, then read the menu) on a copy of the
#     Fcitx5 Rime folder, and a full deploy of that copy with its build/ removed (what an update or a new PC costs);
#   - Mozc: per-key and conversion time through SebType's Mozc library, in this process as in Fcitx5, with its
#     own empty profile;
#   - memory of the running Fcitx5 (with Rime and Mozc), read-only from ps and /proc, when it runs SebType's.
# SebType's builds (linux/build.sh, build-librime.sh) are unpacked here, librime mounted over Fedora's with
# bwrap for perf-rime alone, as compare.sh does.
# One line per check in ~/scratch/SebType/<issue>/pc-perf-results.txt, the table in pc-perf.md next to it.
# Exit 0 unless a check fails (the live ones skip without SebType). RUNS (default 5) repeats each typing set.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

source "$here/../../tools/lib.sh"
# shellcheck source-path=SCRIPTDIR source=../../linux/versions.sh
source "$here/../../linux/versions.sh"
out=$TASK_OUT; mkdir -p "$out"
results=$out/pc-perf-results.txt; : > "$results"
table=$out/pc-perf.md
runs=${RUNS:-5}
rime_dir=${RIME_DIR:-$HOME/.local/share/fcitx5/rime}
librime=/usr/lib64/librime.so.1
# The copy holds the user's learned words: it stays in a private temp dir, removed on exit.
work=$(mktemp -d "$out/pc-perf.XXXXXX")
trap 'rm -rf "$work"' EXIT
own=$work/own mozc_lib=$work/own/usr/lib64/sebtype/libsebtype-mozc.so

result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
check() { # name timeout command...: PASS with the command's key=value output, or FAIL with its log
  local name=$1 t=$2; shift 2
  if timeout "$t" "$@" > "$work/$name.out" 2> "$out/pc-perf-$name.log"; then
    result PASS "$name" "$(tr '\n' ' ' < "$work/$name.out")"
  else result FAIL "$name" "see $out/pc-perf-$name.log"; fi
}
val() { sed -n "s/^$2=//p" "$work/$1.out" 2>/dev/null; } # check key -> value
ms() { [[ -n $1 ]] && awk -v u="$1" 'BEGIN { printf "%.1f ms", u / 1000 }'; }
mb() { [[ -n $1 ]] && echo "$(( $1 / 1024 )) MB"; }

# Preflight
for x in gcc python3 bwrap rpm2cpio; do command -v $x >/dev/null || { echo "preflight: $x missing"; exit 1; }; done
[[ -f $librime ]] || { echo "preflight: $librime missing (install librime)"; exit 1; }
[[ -f $rime_dir/rime_ice.schema.yaml ]] || { echo "preflight: no rime-ice in $rime_dir (set RIME_DIR)"; exit 1; }
sebtype_unpack "$own" || { echo "preflight: linux/build.sh failed"; exit 1; }
librime_unpack "$own" || { echo "preflight: linux/build-librime.sh failed"; exit 1; }
read -ra mounts <<<"$(librime_mounts "$own")"
own_rime=(bwrap --dev-bind / / "${mounts[@]}")
gcc -O2 -I"$here/../../engines/librime/src" -o "$work/perf-rime" "$here/perf-rime.c" "$librime" -ldl 2> "$out/pc-perf-build.log" ||
  { echo "preflight: perf-rime.c doesn't build, see $out/pc-perf-build.log"; exit 1; }

# Generic phrases only: abbreviations (ranh, lh), words and a long sentence.
printf '%s\n' nihao ranhou ranh lh zhongguo women xiexie zaijian shurufa dianhua kaihui wozhidaole \
  meiguanxi jintiantianqizenmeyang > "$work/pinyin.txt"
printf '%s\n' nihongo konnichiha arigatou toukyou shinkansen watashihagakuseidesu kyouhaiitenkidesune \
  > "$work/romaji.txt"

cp -a "$rime_dir" "$work/rime"
check rime-keys 300 "${own_rime[@]}" "$work/perf-rime" /usr/share/rime-data "$work/rime" rime_ice "$runs" < "$work/pinyin.txt"
rm -rf "$work/rime/build"
# A full deploy peaks near 1 GB; the cap keeps it from pushing the desktop into swap.
check rime-deploy 600 systemd-run --user --scope -q -p MemoryMax=3G \
  "${own_rime[@]}" "$work/perf-rime" /usr/share/rime-data "$work/rime" rime_ice 1 < "$work/pinyin.txt"
check mozc-keys 120 python3 -I "$here/perf-mozc.py" "$mozc_lib" "$work/mozc-profile" "$runs" < "$work/romaji.txt"

# Live processes, read-only. SebType's Rime and Mozc run inside the fcitx5 process. Skipped
# while the session runs another input method or none.
live() { # name, file only SebType's process maps -> "rss_kb=.. pss_kb=.." for the user's process of that name
  local pid; pid=$(pgrep -u "$USER" -x "$1" | head -1)
  [[ -n $pid ]] || { echo "skip: no live $1 is running"; return 2; }
  grep -q "$2" "/proc/$pid/maps" || { echo "skip: the live $1 isn't SebType's"; return 2; }
  echo "rss_kb=$(ps -o rss= -p "$pid" | tr -d ' ')"
  echo "pss_kb=$(awk '/^Pss:/ {print $2}' "/proc/$pid/smaps_rollup")"
  echo "swap_kb=$(awk '/^VmSwap:/ {print $2}' "/proc/$pid/status")" # resident counts miss swapped-out pages
}
export -f live
live_check() { # check name, process name, file only SebType's process maps
  # shellcheck disable=SC2016  # expanded by the inner bash
  timeout 10 bash -c 'live "$1" "$2"' live "$2" "$3" > "$work/$1.out" 2> "$out/pc-perf-$1.log"
  case $? in
    0) result PASS "$1" "$(tr '\n' ' ' < "$work/$1.out")" ;;
    2) result SKIP "$1" "$(cat "$work/$1.out")"; : > "$work/$1.out" ;;
    *) result FAIL "$1" "see $out/pc-perf-$1.log" ;;
  esac
}
live_check fcitx5-memory fcitx5 /fcitx5/sebtype.so

{
  echo "SebType PC baseline ($(hostname), $(date -I), $runs runs; Rime keys from $(val rime-keys keys) keystrokes)"
  echo
  echo "| Metric | Value |"
  echo "|---|---|"
  echo "| Rime (rime-ice) key → candidates, median / p95 / max | $(ms "$(val rime-keys key_p50_us)") / $(ms "$(val rime-keys key_p95_us)") / $(ms "$(val rime-keys key_max_us)") |"
  echo "| Rime first key after start | $(ms "$(val rime-keys first_key_us)") |"
  echo "| Rime start (deploy check, built) / session | $(val rime-keys deploy_ms) ms / $(val rime-keys session_ms) ms |"
  echo "| Rime full deploy of rime-ice (no build/) | $(val rime-deploy deploy_ms) ms, peak RSS $(mb "$(val rime-deploy peak_rss_kb)"), RSS after $(mb "$(val rime-deploy rss_kb)") |"
  echo "| Rime RSS after typing (built) | $(mb "$(val rime-keys rss_kb)") |"
  echo "| Mozc key → suggestions, median / p95 / max | $(val mozc-keys key_p50_ms) / $(val mozc-keys key_p95_ms) / $(val mozc-keys key_max_ms) ms |"
  echo "| Mozc Space → conversion, median / p95 / max | $(val mozc-keys convert_p50_ms) / $(val mozc-keys convert_p95_ms) / $(val mozc-keys convert_max_ms) ms |"
  echo "| Mozc start (empty profile) / RSS of Python with it | $(val mozc-keys start_ms) ms / $(mb "$(val mozc-keys rss_kb)") |"
  echo "| Live Fcitx5 (incl. SebType, Rime and Mozc) RSS / PSS / swapped out | $(mb "$(val fcitx5-memory rss_kb)") / $(mb "$(val fcitx5-memory pss_kb)") / $(mb "$(val fcitx5-memory swap_kb)") |"
} > "$table"
cat "$table"

! grep -q '^FAIL' "$results"
