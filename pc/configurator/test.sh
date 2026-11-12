#!/usr/bin/env bash
# Checks the SebType Configurator (#72) on Linux without touching the live desktop: unit tests, every
# string translated into 中文 and 日本語 (#118), the release build, every screen opened in English, 中文
# and 日本語 as the system language in a nested virtual KWin (screenshots kept), a private Fcitx5 and
# Rime taking what the app writes, the Picnic candidate window it writes drawn with SebType's pig (#94),
# its sync with a local sebtype_sync.py server both ways (#180), and its install by setup-ime.sh. Engine files are copies in a
# sandbox; learned words are never copied or forgotten. One line per check in
# /tmp/sebtype/configurator-test-results.txt; logs and screenshots next to it.
# SEBTYPE_CHECKS=a,b runs only the checks whose names start with a or b (picnic-candidate-window draws
# what private-fcitx5-and-rime wrote, so it needs that one named too).
set -uo pipefail
self=$(readlink -f "$0")  # the devq re-exec below needs a path that still resolves after this cd
cd "$(dirname "$self")" || exit 1

out=/tmp/sebtype; mkdir -p "$out"
results=$out/configurator-test-results.txt; : > "$results"
result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
check() { # name, timeout seconds, command or exported function...
  local name=$1 secs=$2 c; shift 2
  if [[ -n ${SEBTYPE_CHECKS-} ]]; then
    for c in ${SEBTYPE_CHECKS//,/ }; do [[ $name == "$c"* ]] && break; done
    [[ $name == "$c"* ]] || return 0
  fi
  if timeout "$secs" bash -c '"$@"' _ "$@" > "$out/configurator-test-$name.log" 2>&1; then result PASS "$name"
  else result FAIL "$name" "see $out/configurator-test-$name.log"; fi
}

# Preflight
for c in cargo dbus-run-session kwin_wayland spectacle fcitx5 desktop-file-validate; do
  command -v "$c" >/dev/null || { echo "preflight: $c missing"; exit 1; }
done
python3 -c 'import dbus, Xlib, PIL, numpy' 2>/dev/null || { echo "preflight: python3-dbus, python3-xlib, python3-pillow and python3-numpy needed"; exit 1; }
command -v xrdb >/dev/null || { echo "preflight: xrdb missing"; exit 1; }
[[ -f /usr/share/fcitx5/addon/rime.conf && -f ~/.local/share/fcitx5/rime/rime_ice.schema.yaml ]] ||
  { echo "preflight: fcitx5-rime and rime-ice (pc/linux/setup-ime.sh) needed"; exit 1; }

command -v devq >/dev/null || { echo "preflight: devq missing"; exit 1; }

# The nested sessions and setup-ime's test run under this PC's lock (devq), after a build under the
# shared build lock at half the cores, so builds never run side by side.
if [[ -z ${HOLDING-} ]]; then
  devq -m 30 -n "sebtype configurator test build ($(git branch --show-current))" /tmp/agent-locks/sebtype/build.lock \
    env CARGO_BUILD_JOBS=8 bash -c 'cargo build --release && cargo test --release --no-run' > "$out/configurator-test-build.log" 2>&1 ||
    { echo "preflight: the build failed, see $out/configurator-test-build.log"; exit 1; }
  exec env HOLDING=1 devq -w 1800 -m 20 -n "sebtype configurator test ($(git branch --show-current))" \
    /tmp/agent-locks/devices/nobara-pc.lock bash "$self"
fi

check unit-tests 900 cargo test --release
check every-string-translated 300 cargo test --release every_string_is_translated
check release-build 900 cargo build --release
bin=$PWD/target/release/sebtype-configurator

# A sandbox account: copies of this account's engine settings, without Rime's and Mozc's learned words.
sb=$(mktemp -d "$out/configurator-sandbox.XXXX")
# The nested sessions' portal and ksecretd outlive their D-Bus: stop whatever still runs in the sandbox.
cleanup() {
  local p
  for p in $(pgrep -u "$USER"); do grep -qzF "XDG_DATA_HOME=$sb/" "/proc/$p/environ" 2>/dev/null && kill "$p"; done
  sleep 1; rm -rf "$sb"
}
trap cleanup EXIT
# Each private D-Bus session gets its own throwaway runtime dir, removed with the sandbox (#176): in the
# user's, anything that touches the Documents portal starts a second xdg-document-portal on the user's
# $XDG_RUNTIME_DIR/doc, and the user's mount goes when it ends, so Flatpak apps no longer start.
runtime_dir() { mktemp -d "$sb/run.XXXX"; }  # 0700
export -f runtime_dir
sandbox() { # [dir], $sb by default
  local sb=${1:-$sb}
  mkdir -p "$sb/config" "$sb/data/fcitx5"
  cp -r ~/.config/fcitx5 "$sb/config/"
  [[ -d ~/.config/mozc ]] && rsync -a --exclude='*history*' --exclude=segment.db --exclude=boundary.db --exclude=cform.db ~/.config/mozc "$sb/config/"
  rsync -a --exclude='*.userdb' --exclude='*.userdb.txt' --exclude=sync ~/.local/share/fcitx5/rime "$sb/data/fcitx5/"
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=keyboard-us\n\n[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n[Groups/0/Items/1]\nName=rime\nLayout=\n\n[Groups/0/Items/2]\nName=mozc\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$sb/config/fcitx5/profile"
}
sandbox

# Every screen opens and stays open in each language, set as the system's; the screenshots are kept for
# the eye, and a 中文 or 日本語 screen that looks the same as the English one fails.
shots() {
  local d=$out/configurator-shots
  rm -rf "$d"; mkdir -p "$d"
  cat > "$sb/shots.sh" <<'SH'
#!/usr/bin/env bash
bin=$1 d=$2; shift 2
exec >> "$d/status" 2>&1  # KWin doesn't pass its client's output on
unset LC_ALL LC_MESSAGES
for lang in en_US zh_CN ja_JP; do
  for spec in "$@"; do
    name=${lang%_*}-${spec%%:*}; read -ra a <<<"${spec#*:}"
    LANGUAGE=$lang LANG=$lang.UTF-8 "$bin" "${a[@]}" & pid=$!
    sleep 3
    kill -0 $pid 2>/dev/null || { echo "$name: the app exited"; exit 1; }
    spectacle -b -n -a -o "$d/$name.png" 2>/dev/null
    kill $pid; wait $pid 2>/dev/null
    [[ -s $d/$name.png ]] || { echo "$name: no screenshot"; exit 1; }
    if [[ $lang != en_US && $(python3 -c 'import sys, numpy as n; from PIL import Image
a, b = (n.asarray(Image.open(f).convert("RGB")) for f in sys.argv[1:])
print("differs" if a.shape != b.shape or (a != b).any() else "same")' "$d/en-${spec%%:*}.png" "$d/$name.png") != differs ]]; then
      echo "$name: looks the same as in English"; exit 1
    fi
    echo "$name ok"
  done
done
echo all-screens-ok
SH
  chmod +x "$sb/shots.sh"
  env -u WAYLAND_DISPLAY -u DISPLAY XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" XDG_RUNTIME_DIR="$(runtime_dir)" dbus-run-session -- \
    kwin_wayland --virtual --no-lockscreen --socket "wl-sebtype-test-$$" --width 1000 --height 700 --exit-with-session \
    "$sb/shots.sh $bin $d 'langs:--page 0' 'keyboard:--page 1' 'theme:--page 2' 'privacy:--page 3' 'sync:--page 4' 'synclogin:--page 4 --sub 1' 'about:--page 5' 'fuzzy:--page 0 --sub 1' 'zhwords:--page 0 --sub 2' 'jawords:--page 0 --sub 3'" > "$sb/kwin.log" 2>&1
  cat "$d/status"; grep -qx all-screens-ok "$d/status"
}
export -f shots; export out sb bin
check every-screen-in-every-language 400 shots

# Fcitx5 and Rime take the languages and Chinese settings the app writes (the ignored Rust test).
# shellcheck disable=SC2016  # the inner script gets its paths as arguments
private_fcitx5() {
  env -i PATH="$PATH" HOME="$sb" XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" XDG_RUNTIME_DIR="$(runtime_dir)" \
    CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_TARGET_DIR="$PWD/target" \
    dbus-run-session -- bash -c '
      fcitx5 -k --disable=all --enable=dbus,keyboard,rime,mozc > "$1/fcitx5.log" 2>&1 & f=$!
      for _ in $(seq 50); do busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && break; sleep 0.2; done
      cargo test --release --manifest-path "$2/Cargo.toml" -- --ignored --exact linux::tests::private_fcitx5_takes_languages_and_chinese_settings
      rc=$?; kill $f; wait $f; exit $rc' _ "$sb" "$PWD"
}
export -f private_fcitx5
check private-fcitx5-and-rime 300 private_fcitx5

# The Picnic window that test wrote draws SebType's pig at the start (#94), horizontal and vertical: a
# private Fcitx5 on X11 in a nested KWin, typed into over D-Bus. The screenshots are kept for the eye.
picnic_window() {
  cat > "$sb/picnic.sh" <<'SH'
#!/usr/bin/env bash
here=$1 sb=$2 out=$3
exec >> "$out/configurator-picnic.status" 2>&1  # KWin doesn't pass its client's output on
unset WAYLAND_DISPLAY  # Fcitx5 draws on Xwayland, where the window can be read back
echo "Xft.dpi: 96" | xrdb -merge
ui=$sb/config/fcitx5/conf/classicui.conf
for o in horizontal vertical; do
  sed -i "s/^Vertical Candidate List=.*/Vertical Candidate List=$([[ $o == vertical ]] && echo True || echo False)/" "$ui"
  fcitx5 -k --disable=all --enable=dbus,dbusfrontend,xcb,classicui,keyboard,rime > "$out/configurator-picnic-fcitx5-$o.log" 2>&1 & f=$!
  for _ in $(seq 100); do busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && break; sleep 0.1; done
  sleep 3  # Rime loads its schema
  read -r size pink tab < <(python3 "$here/candidate-window.py" "$out/configurator-picnic-$o.png")
  kill $f; wait $f
  if [[ ${pink:-0} -gt 100 && ${tab:-0} == 1 ]]; then echo "$o ok: $size, $pink logo pixels, on its tab"
  else echo "$o: no logo on a tab (${size:-no window}, ${pink:-0} logo pixels, tab ${tab:-0})"; fi
done
SH
  chmod +x "$sb/picnic.sh"; rm -f "$out/configurator-picnic.status"
  env -u WAYLAND_DISPLAY -u DISPLAY HOME="$sb" XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" XDG_RUNTIME_DIR="$(runtime_dir)" dbus-run-session -- \
    kwin_wayland --virtual --xwayland --no-lockscreen --socket "wl-sebtype-picnic-$$" --width 1000 --height 700 --exit-with-session \
    "$sb/picnic.sh $PWD $sb $out" > "$sb/kwin-picnic.log" 2>&1
  cat "$out/configurator-picnic.status"; [[ $(grep -c ' ok: ' "$out/configurator-picnic.status") == 2 ]]
}
export -f picnic_window
check picnic-candidate-window 120 picnic_window

# Sync (#180) with a sebtype_sync.py server on this PC, both ways, then delete on the server: a sandbox
# of its own (the checks above turn learning off), with a made-up device id and no sync_dir, so Rime
# writes only there, a throwaway login in a private keyring (gnome-keyring), and made-up words.
# shellcheck disable=SC2016  # the inner script gets its paths as arguments
private_sync() {
  local d=$sb/sync-account rime port
  sandbox "$d"; mkdir -p "$d/server"
  rime=$d/data/fcitx5/rime
  sed -i '/^sync_dir:/d; s/^installation_id:.*/installation_id: "sebtype-test-pc"/' "$rime/installation.yaml"
  sed -i 's|translator/enable_user_dict: false|translator/enable_user_dict: true|' "$rime/rime_ice.custom.yaml" 2>/dev/null
  rm -f "$d/config/mozc/user_dictionary.db"  # only made-up Japanese words
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  env -i PATH="$PATH" HOME="$d" XDG_CONFIG_HOME="$d/config" XDG_DATA_HOME="$d/data" XDG_RUNTIME_DIR="$(runtime_dir)" \
    CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_TARGET_DIR="$PWD/target" \
    dbus-run-session -- bash -c '
      d=$1 here=$2 port=$3 server=$2/../../sync-server/sebtype_sync.py
      SEBTYPE_TEST_SYNC_PASSWORD=$(head -c 18 /dev/urandom | base64)
      printf "%s\n" "$SEBTYPE_TEST_SYNC_PASSWORD" | python3 -I "$server" adduser --data "$d/server" --password-stdin sebtype-test || exit 1
      python3 -I "$server" serve --data "$d/server" --port "$port" > "$d/server.log" 2>&1 & s=$!
      head -c 18 /dev/urandom | base64 | gnome-keyring-daemon --unlock --components=secrets --daemonize > /dev/null
      fcitx5 -k --disable=all --enable=dbus,dbusfrontend,keyboard,rime,mozc > "$d/fcitx5.log" 2>&1 & f=$!
      for _ in $(seq 50); do busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && break; sleep 0.2; done
      # Rime opens its learned words (rime_ice.userdb) once 中文 is in use: one key in a private input context.
      python3 - <<"PY"
import os, time
from gi.repository import Gio, GLib
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
def call(path, iface, method, sig=None, *args):
    return bus.call_sync("org.fcitx.Fcitx5", path, iface, method, GLib.Variant(sig, args) if sig else None,
                         None, Gio.DBusCallFlags.NO_AUTO_START, 10000, None).unpack()
ic, _ = call("/org/freedesktop/portal/inputmethod", "org.fcitx.Fcitx.InputMethod1", "CreateInputContext", "(a(ss))", [("program", "sebtype-test")])
call(ic, "org.fcitx.Fcitx.InputContext1", "FocusIn")
for _ in range(100):  # the rime addon loads a moment after Fcitx5 is on the bus
    call("/controller", "org.fcitx.Fcitx.Controller1", "SetCurrentIM", "(s)", "rime")
    if call("/controller", "org.fcitx.Fcitx.Controller1", "CurrentInputMethod")[0] == "rime":
        break
    time.sleep(0.2)
# Rime takes no keys while it deploys after its start: "a" and Escape until its learned words are open.
userdb = os.path.join(os.environ["XDG_DATA_HOME"], "fcitx5/rime/rime_ice.userdb")
for _ in range(60):
    for sym, code in ((0x61, 38), (0xff1b, 9)):
        for release in (False, True):
            call(ic, "org.fcitx.Fcitx.InputContext1", "ProcessKeyEvent", "(uuubu)", sym, code, 0, release, 0)
    if os.path.isdir(userdb):
        break
    time.sleep(0.5)
else:
    print("Rime has no rime_ice.userdb: 中文 never came up")
PY
      export SEBTYPE_TEST_SYNC_SERVER=http://127.0.0.1:$port SEBTYPE_TEST_SYNC_USER=sebtype-test SEBTYPE_TEST_SYNC_PASSWORD
      cargo test --release --manifest-path "$here/Cargo.toml" -- --ignored --exact sync::tests::private_server_syncs_both_ways_and_delete_clears_it
      rc=$?; kill $f $s; wait $f $s
      cp "$d/fcitx5.log" "$4/configurator-test-private-sync-fcitx5.log"
      ls -lR --time-style=+%T "$XDG_DATA_HOME/fcitx5/rime/sync" "$XDG_DATA_HOME/fcitx5/rime" > "$4/configurator-test-private-sync-rime.txt" 2>&1
      exit $rc' _ "$d" "$PWD" "$port" "$out"
}
export -f private_sync sandbox
check private-sync 300 private_sync

check setup-ime 900 ../linux/test-setup-ime.sh

! grep -q '^FAIL' "$results"
