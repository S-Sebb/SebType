#!/usr/bin/env bash
# The tray key while 中文 or 日本語 isn't ready (#275), on Linux, in screenshots:
#   pc/linux/test-not-ready.sh        # results and PNGs in ~/scratch/SebType/<issue>/screens/linux-<scale>-<time>
#   SCALE=2 pc/linux/test-not-ready.sh  # the screen at 200 % (nobara-pc's own), X apps scaled by themselves
# A private Fcitx5 with a throwaway profile and SebType's RPM (linux/build.sh of this tree, unpacked as
# test-setup-ime.sh does) runs in a nested KWin (virtual, 1000 x 700 at scale 1) with a Plasma system tray,
# in its own D-Bus session (tools/lib.sh's private_dbus), never the live one; it takes the device lock, as it
# fills the CPU while Rime deploys. test-not-ready.py types into it over D-Bus and saves the screen and the popup by the caret.
# Exit 0 when all checks pass.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/../../tools/lib.sh"
# shellcheck source-path=SCRIPTDIR source=../../linux/versions.sh
source "$here/../../linux/versions.sh"
scale=${SCALE:-1}
out=$TASK_OUT/screens/linux-$scale-$(date +%Y%m%d-%H%M%S); mkdir -p "$out"  # each run its own: none deletes another's
work=$(mktemp -d "$TASK_OUT/not-ready.XXXXXX"); trap 'rm -rf "$work"' EXIT
for x in kwin_wayland plasmawindowed kded6 spectacle fcitx5 bwrap devq; do
  command -v $x >/dev/null || { echo "preflight: $x missing"; exit 1; }
done
python3 -c 'import dbus, Xlib, numpy, PIL' 2>/dev/null || { echo "preflight: python3-dbus, xlib, numpy or pillow missing"; exit 1; }
sebtype_unpack "$work/own" || { echo "preflight: linux/build.sh failed"; exit 1; }

h=$work/home
mkdir -p "$h/.config/fcitx5"
printf '%s\n' '[Xwayland]' "Scale=$scale" > "$h/.config/kwinrc"  # X apps (Fcitx5's popup) draw at the scale
printf '%s\n' '[Groups/0]' Name=Default 'Default Layout=us' DefaultIM=sebtype '[Groups/0/Items/0]' Name=sebtype \
  '[GroupOrder]' 0=Default > "$h/.config/fcitx5/profile"
cat > "$work/inner.sh" <<EOF
#!/usr/bin/env bash
echo "Xft.dpi: $((96 * scale))" | xrdb -merge
kded6 >/dev/null 2>&1 &
plasmawindowed org.kde.plasma.systemtray >/dev/null 2>&1 &
sleep 3
WAYLAND_DISPLAY= fcitx5 -k --disable=all --enable=dbus,dbusfrontend,xcb,classicui,keyboard,sebtype,notificationitem \
  > "$out/fcitx5.log" 2>&1 & f=\$!
timeout 300 python3 "$here/test-not-ready.py" "$out"; echo \$? > "$work/rc"
kill \$f
EOF
chmod +x "$work/inner.sh"
# devq runs a program, so private_dbus goes in with its definition.
read -ra env <<<"$(sebtype_env "$work/own")"
session="$(declare -f private_dbus); private_dbus ${work@Q} -u WAYLAND_DISPLAY -u DISPLAY ${env[*]@Q} \
  HOME=${h@Q} XDG_CONFIG_HOME=${h@Q}/.config XDG_DATA_HOME=${h@Q}/.local/share -- kwin_wayland --virtual --xwayland \
  --no-lockscreen --socket wl-sebtype-$$ --width 1000 --height 700 --scale $scale --exit-with-session '$work/inner.sh'"
devq -w 2000 -m 8 -n "sebtype not-ready shots" /tmp/agent-locks/devices/nobara-pc.lock bash -c "$session" \
  > "$out/kwin.log" 2>&1
rc=$(cat "$work/rc" 2>/dev/null || echo 1)
cat "$out/results.txt" 2>/dev/null
exit "$rc"
