#!/usr/bin/env bash
# SebType's input method on Linux next to Fedora's fcitx5-rime and fcitx5-mozc, measured the same way (#54, #190):
#   pc/linux/compare.sh            # RUNS (default 5) repeats each typing set; SOAK_MIN (default 12) mixed typing
# Each setup runs in a private Fcitx5 with a throwaway profile, in its own D-Bus session and runtime dir
# (#176), never the live one; compare-keys.py types into it over D-Bus. SebType's input method and librime
# come from their RPMs (linux/build.sh, build-librime.sh), unpacked and mounted for that Fcitx5 alone with
# bwrap (linux/versions.sh's sebtype_run), as test-setup-ime.sh does. Data: stock
# Rime gets rime-ice's release (what users of fcitx5-rime install), SebType its own Chinese data
# (data/rime/build.sh) with setup-ime.sh's patches. Mozc starts with an empty profile in both. Nothing is
# learned in the timed sets. The stock setups are skipped when Fedora's fcitx5-rime or fcitx5-mozc isn't installed.
# Results: ~/scratch/SebType/<issue>/linux-compare/<setup>.out (key=value) and .log; exit 0 when no run failed.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/../../tools/lib.sh"
# shellcheck source-path=SCRIPTDIR source=../../linux/versions.sh
source "$here/../../linux/versions.sh"
out=${COMPARE_OUT:-$TASK_OUT/linux-compare}; rm -rf "$out"; mkdir -p "$out"
runs=${RUNS:-5} soak=${SOAK_MIN:-12} failed=0
work=$(mktemp -d "$TASK_OUT/linux-compare.XXXXXX"); trap 'rm -rf "$work"' EXIT

for x in fcitx5 bwrap dbus-run-session rpm2cpio unzip; do command -v $x >/dev/null || { echo "preflight: $x missing"; exit 1; }; done
ices=("$SCRATCH"/cache/*-full.zip); ice=${ices[0]} # rime-ice's release, fetched by data/rime/build.sh
[[ -f $ice ]] || { echo "preflight: no rime-ice full.zip in ~/scratch/SebType/cache (run data/rime/build.sh)"; exit 1; }
data=$("$here/../../tools/build.sh" 10 "rime data for compare" data/rime/build.sh 2> "$out/data-build.log") ||
  { echo "preflight: data/rime/build.sh failed"; exit 1; }
own=$work/own
sebtype_unpack "$own" || { echo "preflight: linux/build.sh failed"; exit 1; }
librime_unpack "$own" || { echo "preflight: linux/build-librime.sh failed"; exit 1; }
read -ra sebtype <<<"$(sebtype_run "$own")"

printf '%s\n' nihao ranhou ranh lh zhongguo women xiexie zaijian shurufa dianhua kaihui wozhidaole \
  meiguanxi jintiantianqizenmeyang > "$work/pinyin.txt"
printf '%s\n' nihongo konnichiha arigatou toukyou shinkansen watashihagakuseidesu kyouhaiitenkidesune \
  > "$work/romaji.txt"
{ cat "$work/pinyin.txt"; sed 's/^/ja:/' "$work/romaji.txt"; } > "$work/mixed.txt"

profile() { # setup -> a throwaway HOME with that setup's Fcitx5 profile and Rime data
  local h=$work/$1 r ims=(keyboard-us rime mozc) i
  r=$h/.local/share/fcitx5/rime
  mkdir -p "$h/.config/fcitx5" "$r"
  [[ $1 == stock* ]] || ims=(sebtype)  # setup-ime.sh's group: SebType's one input method
  { printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=%s\n' "${ims[0]}"
    for i in "${!ims[@]}"; do printf '\n[Groups/0/Items/%s]\nName=%s\nLayout=\n' "$i" "${ims[i]}"; done
    printf '\n[GroupOrder]\n0=Default\n'; } > "$h/.config/fcitx5/profile"
  if [[ $1 == stock* ]]; then unzip -q "$ice" -d "$r"
  else
    unzip -q "$data" -d "$r"
    printf 'patch:\n  sebtype_typo/keyboard: pc\n' > "$r/rime_ice.custom.yaml"
    printf 'patch:\n  menu/page_size: 6\n' > "$r/default.custom.yaml"
  fi
  echo "$h"
}
private() { # home timeout command...: a private D-Bus session (tools/lib.sh)
  private_dbus "$work" -i PATH="$PATH" HOME="$1" XDG_CONFIG_HOME="$1/.config" XDG_DATA_HOME="$1/.local/share" -- \
    timeout "$2" "${@:3}"
}
run() { # name timeout [env and bwrap...] -- args for compare-keys.py, words file last
  local name=$1 t=$2 words=${*: -1}; shift 2
  local pre=(); while [[ $1 != -- ]]; do pre+=("$1"); shift; done; shift
  local h; h=$(profile "$name")
  # shellcheck disable=SC2094  # the log is only written: by compare-keys.py through its path, and by its stderr
  if private "$h" "$t" "${pre[@]}" python3 -I "$here/compare-keys.py" "${@:1:$#-1}" "$out/$name.log" \
      < "$words" > "$out/$name.out" 2>> "$out/$name.log"; then echo "PASS $name"
  else echo "FAIL $name: see $out/$name.log"; failed=1; fi
}
stock() { # name, Fedora's package, its add-on, then run's arguments
  if [[ -f /usr/lib64/fcitx5/$3.so ]]; then run "$1" "${@:4}"
  else echo "SKIP $1: $2 isn't installed"; echo "skipped=$2 isn't installed" > "$out/$1.out"; fi
}

stock stock-rime fcitx5-rime librime 900 -- keys rime "$runs" "$work/pinyin.txt"
run sebtype-rime 900 "${sebtype[@]}" -- keys sebtype:zh "$runs" "$work/pinyin.txt"
stock stock-mozc fcitx5-mozc fcitx5-mozc 300 -- keys mozc "$runs" "$work/romaji.txt"
run sebtype-mozc 300 "${sebtype[@]}" -- keys sebtype:ja "$runs" "$work/romaji.txt"
run sebtype-soak $(( soak * 60 + 600 )) "${sebtype[@]}" -- soak "$soak" sebtype:zh sebtype:ja "$work/mixed.txt"
exit $failed
