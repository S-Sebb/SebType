#!/usr/bin/env bash
# shellcheck disable=SC2016  # the checks are single-quoted; they expand in the session
# Removing SebType end to end (#582), on yanglab16, in a fresh kde-emu session of its own (a real Plasma, KWin
# and Fcitx5 with fcitx5-rime; stopped at the end): the account has Fcitx5 groups of its own, this tree's RPM
# is installed and sebtype-setup run, a group and an input method are added after setup, then sebtype-setup
# --undo-all and dnf remove sebtype. Fcitx5's groups and keys must be the ones from before SebType with those
# added since (#611), in the running Fcitx5 and on disk, and Fcitx5's settings apps back. The RPM is built on the host first (the session builds nothing).
# One line per check in ~/t3-apps/SebType/scratch/<issue>/test-removal/results.txt, logs beside it.
set -uo pipefail
script=$(readlink -f "$0")
cd "$(dirname "$script")" || exit 1
# shellcheck source=../../tools/lib.sh
source ../../tools/lib.sh
out=$TASK_OUT/test-removal; mkdir -p "$out"
results=$out/results.txt; : > "$results"

command -v kde-emu >/dev/null || { echo "preflight: kde-emu missing (yanglab16 only)"; exit 1; }
rpm=$(sebtype_rpm "$(sebtype_key)")
[[ -f $rpm ]] || ../../linux/build.sh > /dev/null 2> "$out/rpm-build.log" ||
  { echo "preflight: linux/build.sh failed (see $out/rpm-build.log)"; exit 1; }
session=$(kde-emu start) || { echo "preflight: kde-emu start failed"; exit 1; }
trap 'kde-emu "$session" stop >/dev/null 2>&1' EXIT
trap 'exit 143' TERM

in_session() { timeout 600 kde-emu "$session" run bash -c "$1"; }
failed=
check() { # name, shell commands run in the session: after a failure the later checks, which build on it, skip
  if [[ -n $failed ]]; then echo "SKIP $1: after $failed" | tee -a "$results"; return; fi
  if in_session "$helpers
$2" > "$out/$1.log" 2>&1; then echo "PASS $1" | tee -a "$results"
  else failed=$1; echo "FAIL $1: see $out/$1.log" | tee -a "$results"; fi
}
# KWin starts and stops Fcitx5 as kwinrc's input method changes. groups prints the running Fcitx5's groups,
# one a line: name, then its input methods.
helpers='set -euo pipefail
im() { kwriteconfig6 --notify --file kwinrc --group Wayland --key InputMethod "$1"; }
up() { for _ in $(seq 50); do busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && return; sleep 0.2; done; return 1; }
down() { for _ in $(seq 50); do pgrep -x fcitx5 >/dev/null || return 0; sleep 0.2; done; return 1; }
call() { busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 "$@"; }
groups() { call --json=short InputMethodGroups | python3 -c "import json, sys; print(*json.load(sys.stdin)[\"data\"][0], sep=\"\n\")" |
  while IFS= read -r g; do echo "$g: $(call --json=short InputMethodGroupInfo s "$g" | python3 -c "import json, sys; print(*(i for i, _ in json.load(sys.stdin)[\"data\"][1]))")"; done; }
own=$'"'"'Default: keyboard-us rime\nDeutsch: keyboard-de'"'"'
want=$'"'"'Default: keyboard-us rime keyboard-fr\nDeutsch: keyboard-de\nLater: keyboard-us'"'"'
f=~/.config/fcitx5'

# Setup's sudo asks no password here.
if ! kde-emu "$session" root bash -c "echo '$USER ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/test-removal" > "$out/session.log" 2>&1; then
  echo "preflight: the session's setup failed (see $out/session.log)"; exit 1
fi

# The account before SebType: two groups of its own and a trigger key of its own, which Fcitx5 loads.
check own-groups 'im /usr/share/applications/org.fcitx.Fcitx5.desktop; up; im ""; down
mkdir -p "$f"
printf "[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=rime\n\n[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n[Groups/0/Items/1]\nName=rime\nLayout=\n\n[Groups/1]\nName=Deutsch\nDefault Layout=de\nDefaultIM=keyboard-de\n\n[Groups/1/Items/0]\nName=keyboard-de\nLayout=\n\n[GroupOrder]\n0=Default\n1=Deutsch\n" > "$f/profile"
printf "[Hotkey/TriggerKeys]\n0=Control+space\n" > "$f/config"
im /usr/share/applications/org.fcitx.Fcitx5.desktop; up
[[ $(groups) == "$own" ]]'
check install-and-setup "sudo dnf install -y $rpm
"'sebtype-setup < <(yes)
up; groups; [[ $(groups | head -1) == "Default: sebtype" ]] && ls ~/.local/share/fcitx5/addon/notificationitem.conf && ! rpm -q kcm-fcitx5'
check added-after-setup 'call AddInputMethodGroup s Later; call SetInputMethodGroupInfo "ssa(ss)" Later us 1 keyboard-us ""
call SetInputMethodGroupInfo "ssa(ss)" Default us 2 sebtype "" keyboard-fr ""; call Save
groups; groups | grep -qx "Later: keyboard-us" && groups | grep -qx "Default: sebtype keyboard-fr"'
check undo-all 'o=$(sebtype-setup --undo-all < /dev/null) || { echo "$o"; exit 1; }; echo "$o"; up; groups
grep -q "^change: stop Fcitx5 under KWin" <<<"$o" && [[ $(groups) == "$want" ]] && rpm -q kcm-fcitx5 fcitx5-configtool &&
  [[ ! -e ~/.local/share/fcitx5/addon/notificationitem.conf && ! -e ~/.local/share/sebtype/configurator ]] &&
  grep -qx "0=Control+space" "$f/config"'
# A Fcitx5 that loaded SebType keeps it until it restarts: as at the next login, after dnf remove.
check dnf-remove 'sudo dnf remove -y sebtype; im ""; down; im /usr/share/applications/org.fcitx.Fcitx5.desktop; up; sleep 2
groups; [[ $(groups) == "$want" ]] && call AvailableInputMethods | grep -q "\"rime\"" && ! call AvailableInputMethods | grep -q "\"sebtype\""'
check groups-on-disk 'im ""; down; cat "$f/profile"
[[ $(grep -c "^\[Groups/[0-9]*\]$" "$f/profile") == 3 ]] && grep -qx "Name=Deutsch" "$f/profile" && grep -qx "Name=rime" "$f/profile" &&
  grep -qx "Name=Later" "$f/profile" && grep -qx "Name=keyboard-fr" "$f/profile" && ! grep -q sebtype "$f/profile"'

! grep -q '^FAIL' "$results"
