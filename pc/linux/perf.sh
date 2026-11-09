#!/usr/bin/env bash
# Measures SebType's PC engines (#45) without touching the live Fcitx5 session:
#   - Rime with rime-ice: per-key time (key, then read the menu) on a copy of the Fcitx5 Rime folder,
#     and a full deploy of that copy with its build/ removed (what an update or a new PC costs);
#   - Mozc: per-key and conversion time through a private mozc_server with its own empty profile;
#   - memory of the running Fcitx5 and mozc_server, read-only from ps and /proc.
# One line per check in /tmp/sebtype/pc-perf-results.txt, the table in /tmp/sebtype/pc-perf.md.
# Exit 0 only if every check passes. RUNS (default 5) repeats each typing set.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

out=/tmp/sebtype; mkdir -p "$out"
results=$out/pc-perf-results.txt; : > "$results"
table=$out/pc-perf.md
runs=${RUNS:-5}
rime_dir=${RIME_DIR:-$HOME/.local/share/fcitx5/rime}
mozc_server=/usr/libexec/fcitx5-mozc/mozc_server
librime=/usr/lib64/librime.so.1
cache=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/librime-1.16.1-headers
# The copy holds the user's learned words: it stays in a private temp dir, removed on exit.
work=$(mktemp -d "$out/pc-perf.XXXXXX")
trap 'rm -rf "$work"' EXIT

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
for x in gcc python3 curl sha256sum; do command -v $x >/dev/null || { echo "preflight: $x missing"; exit 1; }; done
[[ -f $librime ]] || { echo "preflight: $librime missing (install librime)"; exit 1; }
[[ -f $rime_dir/rime_ice.schema.yaml ]] || { echo "preflight: no rime-ice in $rime_dir (set RIME_DIR)"; exit 1; }
[[ -x $mozc_server ]] || { echo "preflight: $mozc_server missing (install fcitx5-mozc)"; exit 1; }
# librime's public headers, pinned; Fedora ships them only in librime-devel.
mkdir -p "$cache"
while read -r sum f; do
  echo "$sum  $cache/$f" | sha256sum -c --status 2>/dev/null && continue
  curl -fsSL -o "$cache/$f" "https://raw.githubusercontent.com/rime/librime/1.16.1/src/$f" &&
    echo "$sum  $cache/$f" | sha256sum -c --status || { echo "preflight: can't fetch librime header $f"; exit 1; }
done <<'EOF'
6eb5629162c44761e7b878f1b122f464de5c8685bd3cd5ac1e8519badc6d6424 rime_api.h
21625c4e16480a4540939299a002f21b11150bb10b69f5331e1580875ac63341 rime_api_deprecated.h
f5a64254e98c1c12ce6628f5d540bcd4e4b542ec287b4873c0b0ce4ed1bece99 rime_api_stdbool.h
EOF
gcc -O2 -I"$cache" -o "$work/perf-rime" "$here/perf-rime.c" "$librime" -ldl 2> "$out/pc-perf-build.log" ||
  { echo "preflight: perf-rime.c doesn't build, see $out/pc-perf-build.log"; exit 1; }

# Generic phrases only: abbreviations (ranh, lh), words and a long sentence.
printf '%s\n' nihao ranhou ranh lh zhongguo women xiexie zaijian shurufa dianhua kaihui wozhidaole \
  meiguanxi jintiantianqizenmeyang > "$work/pinyin.txt"
printf '%s\n' nihongo konnichiha arigatou toukyou shinkansen watashihagakuseidesu kyouhaiitenkidesune \
  > "$work/romaji.txt"

cp -a "$rime_dir" "$work/rime"
check rime-keys 300 "$work/perf-rime" /usr/share/rime-data "$work/rime" rime_ice "$runs" < "$work/pinyin.txt"
rm -rf "$work/rime/build"
# A full deploy peaks near 1 GB; the cap keeps it from pushing the desktop into swap.
check rime-deploy 600 systemd-run --user --scope -q -p MemoryMax=3G \
  "$work/perf-rime" /usr/share/rime-data "$work/rime" rime_ice 1 < "$work/pinyin.txt"
mkdir -p "$work/mozc-home"
check mozc-keys 120 python3 -I "$here/perf-mozc.py" "$mozc_server" "$work/mozc-home" "$runs" < "$work/romaji.txt"

# Live processes, read-only. Fcitx5's Rime runs inside the fcitx5 process; Mozc in its own server.
live() { # name -> "rss_kb=.. pss_kb=.." for the user's process of that name
  local pid; pid=$(pgrep -u "$USER" -x "$1" | head -1)
  [[ -n $pid ]] || return 1
  echo "rss_kb=$(ps -o rss= -p "$pid" | tr -d ' ')"
  echo "pss_kb=$(awk '/^Pss:/ {print $2}' "/proc/$pid/smaps_rollup")"
  echo "swap_kb=$(awk '/^VmSwap:/ {print $2}' "/proc/$pid/status")" # resident counts miss swapped-out pages
}
export -f live
check fcitx5-memory 10 bash -c 'live fcitx5'
check mozc-server-memory 10 bash -c 'live mozc_server'

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
  echo "| Mozc server start (empty profile) / RSS | $(val mozc-keys start_ms) ms / $(mb "$(val mozc-keys rss_kb)") |"
  echo "| Live Fcitx5 (incl. Rime) RSS / PSS / swapped out | $(mb "$(val fcitx5-memory rss_kb)") / $(mb "$(val fcitx5-memory pss_kb)") / $(mb "$(val fcitx5-memory swap_kb)") |"
  echo "| Live mozc_server RSS / PSS / swapped out | $(mb "$(val mozc-server-memory rss_kb)") / $(mb "$(val mozc-server-memory pss_kb)") / $(mb "$(val mozc-server-memory swap_kb)") |"
} > "$table"
cat "$table"

! grep -qv '^PASS' "$results"
