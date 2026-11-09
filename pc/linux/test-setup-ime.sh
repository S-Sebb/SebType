#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub bodies are single-quoted; they expand when the stub runs
# Checks pc/linux/setup-ime.sh: ShellCheck, a read-only --dry-run on this PC, and a full run on a
# fake fresh account (stubbed packages, systemd, Fcitx5 and KWin calls) that must be idempotent.
# Changes nothing in the real session. One line per check in /tmp/sebtype/test-setup-ime-results.txt.
# Typing in real apps is the manual checklist in pc/linux/README.md.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

out=/tmp/sebtype; mkdir -p "$out"
results=$out/test-setup-ime-results.txt; : > "$results"
result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
check() { # name, command... (each run of setup-ime.sh has its own timeout)
  local name=$1; shift
  if "$@" > "$out/test-setup-ime-$name.log" 2>&1; then result PASS "$name"
  else result FAIL "$name" "see $out/test-setup-ime-$name.log"; fi
}

# Preflight
command -v uvx >/dev/null || { echo "preflight: uvx missing (used to run ShellCheck)"; exit 1; }
command -v kreadconfig6 >/dev/null || { echo "preflight: kreadconfig6 missing (KDE Plasma 6 needed)"; exit 1; }

check shellcheck uvx --from shellcheck-py shellcheck setup-ime.sh test-setup-ime.sh

# Live dry run: must not touch the account, and on a set-up PC only the agreed cleanups remain.
live_dry() {
  local before after
  before=$(find ~/.config/kwinrc ~/.config/environment.d ~/.config/fcitx5/config ~/.config/mozc/config1.db ~/.local/share/applications ~/.local/share/flatpak/overrides \
    ~/.local/share/sebtype -type f -exec md5sum {} + 2>/dev/null | sort)
  timeout 60 ./setup-ime.sh --dry-run | tee /dev/stderr | grep '^would:' | grep -v 'unused Flatpak override' && return 1
  after=$(find ~/.config/kwinrc ~/.config/environment.d ~/.config/fcitx5/config ~/.config/mozc/config1.db ~/.local/share/applications ~/.local/share/flatpak/overrides \
    ~/.local/share/sebtype -type f -exec md5sum {} + 2>/dev/null | sort)
  [[ $before == "$after" ]]
}
check live-dry-run live_dry

# Fake fresh account.
fake=$(mktemp -d /tmp/sebtype/setup-ime-fake.XXXX)
trap 'rm -rf "$fake"' EXIT
mkdir -p "$fake"/{bin,home/.config,home/.local/share/applications,home/.local/share/flatpak/overrides}
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$fake/bin/$1"; chmod +x "$fake/bin/$1"; }
stub rpm '[[ $2 != fcitx5-mozc ]]'
stub sudo 'echo "sudo $*" >> "$FAKE/sudo.log"'
stub systemctl 'cat "$FAKE/session-env" 2>/dev/null; true'
stub flatpak 'exit 1'
stub pgrep 'exit 1'  # never finds (and stops) the real mozc_server
stub qdbus6 'echo "qdbus $*" >> "$FAKE/qdbus.log"'
stub busctl 'case "$*" in
  *status*) ;;
  *setForeignShortcutKeys*) echo "$*" > "$FAKE/kga.log" ;;
  *shortcutKeys*) if [[ -e $FAKE/kga.log ]]; then echo "a(ai) 1 4 268435552 0 0 0"
    else echo "a(ai) 2 4 268435552 0 0 0 4 134217824 0 0 0"; fi ;;
  *ReloadConfig*) echo reload >> "$FAKE/reload.log" ;;
  *SetInputMethodGroupInfo*) echo "$*" > "$FAKE/set.log"
    echo "sa(ss) \"us\" 3 \"keyboard-us\" \"\" \"rime\" \"\" \"mozc\" \"\"" > "$FAKE/group" ;;
  *InputMethodGroups*) echo "as 1 \"Default\"" ;;
  *InputMethodGroupInfo*) cat "$FAKE/group" 2>/dev/null || echo "sa(ss) \"us\" 1 \"keyboard-us\" \"\"" ;;
esac'
h=$fake/home
printf '[Desktop Entry]\nName=wechat\nExec=/usr/bin/wechat %%U\n' > "$h/.local/share/applications/wechat.desktop"
printf '[Environment]\nGDK_BACKEND=x11\n' > "$h/.local/share/flatpak/overrides/com.qq.QQ"
echo 'export QT_IM_MODULE=fcitx' > "$h/.profile"
# Fcitx5's own switchers as an older setup left them, and a Mozc config with settings to keep:
# general_config (1), session_keymap (41) = MSIME, custom_roman_table (43).
mkdir -p "$h/.config/fcitx5" "$h/.config/mozc"
printf '[Hotkey]\nEnumerateWithTriggerKeys=True\n\n[Hotkey/TriggerKeys]\n0=Super+space\n\n[Hotkey/AltTriggerKeys]\n0=Shift_L\n\n[Hotkey/EnumerateForwardKeys]\n0=Control+Shift+Shift_L\n\n[Behavior]\nActiveByDefault=False\n' > "$h/.config/fcitx5/config"
printf '\x0a\x02\x08\x01\xc8\x02\x02\xda\x02\x01x' > "$h/.config/mozc/config1.db"
fake_run() { env -i PATH="$fake/bin:$PATH" HOME="$h" FAKE="$fake" XDG_CONFIG_HOME="$h/.config" \
  XDG_DATA_HOME="$h/.local/share" timeout 60 ./setup-ime.sh "$@"; }

fresh_dry() {
  local o; o=$(fake_run --dry-run < /dev/null) || return 1; echo "$o"
  [[ $(grep -c '^would:' <<<"$o") == 9 ]] && grep -q 'QT_IM_MODULE=fcitx$' <<<"$(grep warning <<<"$o")" &&
    [[ ! -e $h/.config/kwinrc && ! -e $fake/kga.log && $(wc -c < "$h/.config/mozc/config1.db") == 11 && ! -e $h/.config/environment.d && -f $h/.local/share/flatpak/overrides/com.qq.QQ ]]
}
check fresh-dry-run-changes-nothing fresh_dry

fresh_apply() {
  local o; o=$(echo n | fake_run) || return 1; echo "$o"
  [[ $(kreadconfig6 --file "$h/.config/kwinrc" --group Wayland --key InputMethod) == \
    /usr/share/applications/org.fcitx.Fcitx5.desktop ]] &&
    grep -qx 'XMODIFIERS=@im=fcitx' "$h/.config/environment.d/90-sebtype-im.conf" &&
    grep -q '^Exec=env QT_IM_MODULE=fcitx /usr/bin/wechat' "$h/.local/share/applications/wechat.desktop" &&
    [[ ! -e $h/.local/share/flatpak/overrides/com.qq.QQ ]] &&
    ls "$h"/.local/share/sebtype/backup/*/com.qq.QQ "$h"/.local/share/sebtype/backup/*/wechat.desktop &&
    grep -q 'Default us 3 keyboard-us  rime  mozc' "$fake/set.log" && [[ ! -e $fake/sudo.log ]] &&
    fcitx_hotkeys && mozc_keymap && grep -q 'setForeignShortcutKeys asa(ai) 4 kwin .* 1 4 268435552 0 0 0$' "$fake/kga.log"
}
# Super+Space is the only switch, the other settings stay, and Fcitx5 reloaded it.
fcitx_hotkeys() {
  local c=$h/.config/fcitx5/config
  [[ $(sed -n '/^\[Hotkey\/EnumerateForwardKeys\]/,/^$/p' "$c") == $'[Hotkey/EnumerateForwardKeys]\n0=Super+space' ]] &&
    ! grep -qE 'Shift_L|^\[Hotkey/(Trigger|AltTrigger)Keys' "$c" && grep -qx 'AltTriggerKeys=' "$c" &&
    grep -qx 'EnumerateGroupForwardKeys=' "$c" && grep -qx 'ActiveByDefault=False' "$c" &&
    ls "$h"/.local/share/sebtype/backup/*/config && [[ -e $fake/reload.log ]]
}
# The keymap replaces fields 41 and 42 in place; fields 1 and 43 are kept.
mozc_keymap() {
  local db=$h/.config/mozc/config1.db
  cmp <(head -c 9 "$db") <(printf '\x0a\x02\x08\x01\xc8\x02\x00\xd2\x02') &&
    cmp <(tail -c 4 "$db") <(printf '\xda\x02\x01x') && grep -qF $'DirectInput\tAlt `\tIMEOn' "$db" &&
    ls "$h"/.local/share/sebtype/backup/*/config1.db
}
check fresh-apply fresh_apply

rerun() {
  echo 'XMODIFIERS=@im=fcitx' > "$fake/session-env"
  local o; o=$(fake_run < /dev/null) || return 1; echo "$o"
  grep -q '^done: 1 change(s)' <<<"$o" && grep -q 'install packages fcitx5-mozc' <<<"$o"
}
check rerun-only-asks-for-missing-package rerun

! grep -q '^FAIL' "$results"
