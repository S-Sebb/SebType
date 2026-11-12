#!/usr/bin/env bash
# SebType's Linux input next to stock fcitx5-rime and fcitx5-mozc, measured the same way (#54):
#   pc/linux/compare.sh            # RUNS (default 5) repeats each typing set; SOAK_MIN (default 12) mixed typing
# Each setup runs in a private Fcitx5 with a throwaway profile, in its own D-Bus session and runtime dir
# (#176), never the live one; compare-keys.py types into it over D-Bus. SebType's fcitx5-rime,
# librime and fcitx5-mozc come from their RPMs (pc/linux/rime/build.sh, mozc/build.sh), mounted over
# Fedora's for that Fcitx5 alone with bwrap, as test-setup-ime.sh does. Data: stock Rime gets rime-ice's
# release (what users of fcitx5-rime install), SebType its own Chinese data (data/rime/build.sh) with
# setup-ime.sh's patches. Mozc starts with an empty profile in both. Nothing is learned in the timed sets.
# Results: /tmp/sebtype/linux-compare/<setup>.out (key=value) and .log; exit 0 when every run finished.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/rime/versions.sh"; source "$here/mozc/versions.sh"
out=${COMPARE_OUT:-/tmp/sebtype/linux-compare}; rm -rf "$out"; mkdir -p "$out"
runs=${RUNS:-5} soak=${SOAK_MIN:-12}
work=$(mktemp -d /tmp/sebtype/linux-compare.XXXXXX); trap 'rm -rf "$work"' EXIT

for x in fcitx5 bwrap dbus-run-session rpm2cpio unzip; do command -v $x >/dev/null || { echo "preflight: $x missing"; exit 1; }; done
ice=$(ls ~/.cache/sebtype/*-full.zip 2>/dev/null | head -1) # rime-ice's release, fetched by data/rime/build.sh
[[ -f $ice ]] || { echo "preflight: no rime-ice full.zip in ~/.cache/sebtype (run data/rime/build.sh)"; exit 1; }
"$here/../../data/rime/build.sh" "$work/data" > "$out/data-build.log" 2>&1 || { echo "preflight: data/rime/build.sh failed"; exit 1; }
own=$work/own; mkdir -p "$own"
for rpm in "$MOZC_CACHE/rpms/$MOZC_RPM" "$RIME_CACHE/$RIME_RPM" "$(librime_rpm librime)" "$(librime_rpm librime-lua)" \
  "$(librime_rpm librime-octagram)"; do
  [[ -f $rpm ]] || { echo "preflight: $rpm missing (pc/linux/rime/build.sh or mozc/build.sh)"; exit 1; }
  rpm2cpio "$rpm" | (cd "$own" && cpio -idm --quiet)
done
sebtype=(bwrap --dev-bind / / --ro-bind "$own/usr/lib64/fcitx5/librime.so" /usr/lib64/fcitx5/librime.so
  --ro-bind "$own/usr/lib64/librime.so.$LIBRIME_VERSION" "/usr/lib64/librime.so.$LIBRIME_VERSION"
  --ro-bind "$own/usr/lib64/rime-plugins" /usr/lib64/rime-plugins
  --ro-bind "$own/usr/lib64/fcitx5/fcitx5-mozc.so" /usr/lib64/fcitx5/fcitx5-mozc.so
  --ro-bind "$own/usr/libexec/fcitx5-mozc" /usr/libexec/fcitx5-mozc)

printf '%s\n' nihao ranhou ranh lh zhongguo women xiexie zaijian shurufa dianhua kaihui wozhidaole \
  meiguanxi jintiantianqizenmeyang > "$work/pinyin.txt"
printf '%s\n' nihongo konnichiha arigatou toukyou shinkansen watashihagakuseidesu kyouhaiitenkidesune \
  > "$work/romaji.txt"
{ cat "$work/pinyin.txt"; sed 's/^/ja:/' "$work/romaji.txt"; } > "$work/mixed.txt"

profile() { # setup -> a throwaway HOME with Fcitx5's profile (EN, rime, mozc) and that setup's Rime data
  local h=$work/$1 r; r=$h/.local/share/fcitx5/rime
  mkdir -p "$h/.config/fcitx5" "$r"
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=keyboard-us\n\n[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n[Groups/0/Items/1]\nName=rime\nLayout=\n\n[Groups/0/Items/2]\nName=mozc\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  if [[ $1 == stock* ]]; then unzip -q "$ice" -d "$r"
  else
    unzip -q "$work/data/rime/rime-data.zip" -d "$r"
    printf 'patch:\n  sebtype_typo/keyboard: pc\n' > "$r/rime_ice.custom.yaml"
    printf 'patch:\n  menu/page_size: 6\n' > "$r/default.custom.yaml"
  fi
  echo "$h"
}
private() { # home timeout command...: a private D-Bus session with its own runtime dir
  local rt rc; rt=$(mktemp -d "$work/run.XXXX")
  env -i PATH="$PATH" HOME="$1" XDG_CONFIG_HOME="$1/.config" XDG_DATA_HOME="$1/.local/share" XDG_RUNTIME_DIR="$rt" \
    timeout "$2" dbus-run-session -- "${@:3}"
  rc=$?; rm -rf "$rt"; return $rc
}
run() { # name timeout [bwrap...] -- args for compare-keys.py, words file last
  local name=$1 t=$2 words=${*: -1}; shift 2
  local pre=(); while [[ $1 != -- ]]; do pre+=("$1"); shift; done; shift
  local h; h=$(profile "$name")
  if private "$h" "$t" "${pre[@]}" python3 -I "$here/compare-keys.py" "${@:1:$#-1}" "$out/$name.log" \
      < "$words" > "$out/$name.out" 2>> "$out/$name.log"; then echo "PASS $name"
  else echo "FAIL $name: see $out/$name.log"; fi
}

run stock-rime 900 -- keys rime "$runs" "$work/pinyin.txt"
run sebtype-rime 900 "${sebtype[@]}" -- keys rime "$runs" "$work/pinyin.txt"
run stock-mozc 300 -- keys mozc "$runs" "$work/romaji.txt"
run sebtype-mozc 300 "${sebtype[@]}" -- keys mozc "$runs" "$work/romaji.txt"
run sebtype-soak $(( soak * 60 + 600 )) "${sebtype[@]}" -- soak "$soak" "$work/mixed.txt"
! grep -L . "$out"/*.out | grep -q .
