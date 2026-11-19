#!/usr/bin/env bash
# Checks the SebType Configurator (#72) on Linux without touching the live desktop: unit tests, every
# string translated into 中文 and 日本語 (#118), the release build, every screen opened in English, 中文
# and 日本語 as the system language in a nested virtual KWin (screenshots kept), a private Fcitx5 and
# Rime taking what the app writes, the Picnic candidate window it writes drawn with SebType's pig (#94),
# its sync with a local sebtype_sync.py server both ways (#180), its forgetting of learned words while the engines run (#375), and its install by setup-ime.sh. Engine files are copies in a
# sandbox; learned words are never copied or forgotten. One line per check in
# ~/scratch/SebType/<issue>/configurator-test-results.txt; logs and screenshots next to it.
# SEBTYPE_CHECKS=a,b runs only the checks whose names start with a or b (picnic-candidate-window draws
# what private-fcitx5-and-rime wrote, so it needs that one named too).
set -uo pipefail
self=$(readlink -f "$0")  # the devq re-exec below needs a path that still resolves after this cd
cd "$(dirname "$self")" || exit 1
# shellcheck source=../../tools/lib.sh
source ../../tools/lib.sh

out=$TASK_OUT; mkdir -p "$out"
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
for c in dbus-run-session kwin_wayland spectacle fcitx5 desktop-file-validate; do
  command -v "$c" >/dev/null || { echo "preflight: $c missing"; exit 1; }
done
python3 -c 'import dbus, Xlib, PIL, numpy' 2>/dev/null || { echo "preflight: python3-dbus, python3-xlib, python3-pillow and python3-numpy needed"; exit 1; }
command -v xrdb >/dev/null || { echo "preflight: xrdb missing"; exit 1; }
[[ -f ~/.local/share/fcitx5/rime/rime_ice.schema.yaml ]] ||
  { echo "preflight: rime-ice (pc/linux/setup-ime.sh) needed"; exit 1; }
# SebType's input method (#190), built once and cached, runs uninstalled in the private Fcitx5s below.
# shellcheck source=../../linux/versions.sh
source ../../linux/versions.sh
own=$out/configurator-own

command -v devq >/dev/null || { echo "preflight: devq missing"; exit 1; }

# The nested sessions and setup-ime's test run under this PC's lock (devq), after the app and its unit
# tests are built on yanglab16 (tools/build.sh, #248) and copied back: this PC compiles nothing.
if [[ -z ${HOLDING-} ]]; then
  sebtype_unpack "$own" || { echo "preflight: linux/build.sh failed"; exit 1; }
  ../../tools/build.sh 30 "sebtype configurator test build ($(git branch --show-current))" pc/configurator/build.sh \
    > /dev/null 2> "$out/configurator-test-build.log" ||
    { echo "preflight: the build failed, see $out/configurator-test-build.log"; exit 1; }
  # SebType's Chinese data (data/rime/build.sh, cached), the Rime folder the sandbox starts from.
  rime_data=$(../../tools/build.sh 10 "rime data for the configurator test" data/rime/build.sh 2>> "$out/configurator-test-build.log" | tail -1)
  [[ -f $rime_data ]] || { echo "preflight: data/rime/build.sh failed, see $out/configurator-test-build.log"; exit 1; }
  exec env HOLDING=1 RIME_DATA="$rime_data" devq -w 1800 -m 20 -n "sebtype configurator test ($(git branch --show-current))" \
    /tmp/agent-locks/devices/nobara-pc.lock bash "$self"
fi

own_env=$(sebtype_env "$own")  # word-split where it is used: Fcitx5 finds SebType's add-on there
export own_env

bin=$PWD/target/release/sebtype-configurator tests=$PWD/target/release/sebtype-configurator-test
check unit-tests 900 "$tests"
check every-string-translated 300 "$tests" every_string_is_translated
# The release build, made in yanglab16's Fedora, finds every library it links here.
release_build() { ldd "$bin" && ! ldd "$bin" | grep -q 'not found'; }
export -f release_build; export bin
check release-build 60 release_build

# A sandbox account: SebType's Chinese data, settings files written here and made-up My words (#410).
# Nothing of this account's comes in: no dictionary, learned words, snapshot, backup or settings file,
# which could hold its own text (Mozc's romaji table, Fcitx5's phrases) or its sync folder.
sb=$(mktemp -d "$out/configurator-sandbox.XXXX")
# What the nested sessions start (ksecretd, the Documents portal) outlives their D-Bus: stop whatever
# still runs in the sandbox.
cleanup() {
  local p
  for p in $(pgrep -u "$USER"); do grep -qzF "XDG_DATA_HOME=$sb/" "/proc/$p/environ" 2>/dev/null && kill "$p"; done
  sleep 1; rm -rf "$sb"
}
trap cleanup EXIT
# Each private D-Bus session runs through private_dbus (tools/lib.sh), its files removed with the sandbox.
export -f private_dbus
export RIME_DATA
sandbox() { # [dir], $sb by default
  local sb=${1:-$sb} rime=${1:-$sb}/data/fcitx5/rime
  mkdir -p "$sb/config/fcitx5" "$sb/config/mozc" "$rime"
  unzip -q "$RIME_DATA" -d "$rime"
  # setup-ime.sh's patches as compare.sh writes them; a made-up installation without a sync folder.
  printf 'patch:\n  sebtype_typo/keyboard: pc\n' > "$rime/rime_ice.custom.yaml"
  printf 'patch:\n  menu/page_size: 6\n' > "$rime/default.custom.yaml"
  printf 'installation_id: "sebtype-test-pc"\n' > "$rime/installation.yaml"
  printf '# SebType: My words\n小明\txiaoming\n张伟\tzhangwei\n' > "$sb/data/fcitx5/rime/custom_phrase.txt"
  python3 - "$sb/config/mozc/user_dictionary.db" <<'PY'
import sys  # a UserDictionaryStorage (mozc.rs) with SebType's dictionary: せぶ → SebType, もふ → モフ
def varint(n):
    out = b""
    while n > 0x7f: out += bytes([n & 0x7f | 0x80]); n >>= 7
    return out + bytes([n])
def field(number, data): return varint(number << 3 | 2) + varint(len(data)) + data
def number(n, value): return varint(n << 3) + varint(value)
d = number(1, 7) + field(3, b"SebType")
for reading, word in (("せぶ", "SebType"), ("もふ", "モフ")):
    d += field(4, field(1, reading.encode()) + field(2, word.encode()) + number(5, 1))
open(sys.argv[1], "wb").write(field(2, d))
PY
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=sebtype\n\n[Groups/0/Items/0]\nName=sebtype\nLayout=\n\n[GroupOrder]\n0=Default\n' \
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
  private_dbus "$sb" -u WAYLAND_DISPLAY -u DISPLAY HOME="$sb" XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" -- \
    kwin_wayland --virtual --no-lockscreen --socket "wl-sebtype-test-$$" --width 1000 --height 700 --exit-with-session \
    "$sb/shots.sh $bin $d 'langs:--page 0' 'keyboard:--page 1' 'theme:--page 2' 'privacy:--page 3' 'sync:--page 4' 'synclogin:--page 4 --sub 1' 'about:--page 5' 'fuzzy:--page 0 --sub 1' 'zhwords:--page 0 --sub 2' 'jawords:--page 0 --sub 3'" > "$sb/kwin.log" 2>&1
  cat "$d/status"; grep -qx all-screens-ok "$d/status"
}
export -f shots; export out sb
check every-screen-in-every-language 400 shots

# Fcitx5 and Rime take the languages and Chinese settings the app writes (the ignored Rust test).
# shellcheck disable=SC2016,SC2086  # the inner script gets its paths as arguments; own_env is split
private_fcitx5() {
  private_dbus "$sb" -i PATH="$PATH" $own_env HOME="$sb" XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" \
    -- bash -c '
      fcitx5 -k --disable=all --enable=dbus,keyboard,sebtype > "$1/fcitx5.log" 2>&1 & f=$!
      for _ in $(seq 50); do busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && break; sleep 0.2; done
      "$2" --ignored --exact linux::tests::private_fcitx5_takes_languages_and_chinese_settings
      rc=$?; kill $f; wait $f; exit $rc' _ "$sb" "$tests"
}
export -f private_fcitx5; export tests
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
  fcitx5 -k --disable=all --enable=dbus,dbusfrontend,xcb,classicui,keyboard,sebtype > "$out/configurator-picnic-fcitx5-$o.log" 2>&1 & f=$!
  for _ in $(seq 100); do busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && break; sleep 0.1; done
  sleep 3  # Rime loads its schema
  read -r size pink tab < <(python3 "$here/candidate-window.py" "$out/configurator-picnic-$o.png")
  kill $f; wait $f
  if [[ ${pink:-0} -gt 100 && ${tab:-0} == 1 ]]; then echo "$o ok: $size, $pink logo pixels, on its tab"
  else echo "$o: no logo on a tab (${size:-no window}, ${pink:-0} logo pixels, tab ${tab:-0})"; fi
done
SH
  chmod +x "$sb/picnic.sh"; rm -f "$out/configurator-picnic.status"
  # shellcheck disable=SC2086  # own_env is split
  private_dbus "$sb" -u WAYLAND_DISPLAY -u DISPLAY $own_env HOME="$sb" XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" -- \
    kwin_wayland --virtual --xwayland --no-lockscreen --socket "wl-sebtype-picnic-$$" --width 1000 --height 700 --exit-with-session \
    "$sb/picnic.sh $PWD $sb $out" > "$sb/kwin-picnic.log" 2>&1
  cat "$out/configurator-picnic.status"; [[ $(grep -c ' ok: ' "$out/configurator-picnic.status") == 2 ]]
}
export -f picnic_window
check picnic-candidate-window 120 picnic_window

# Sync (#180) with a sebtype_sync.py server on this PC, both ways, then delete on the server: a sandbox
# of its own (the checks above change its settings), with a made-up device id and no sync_dir, so Rime
# writes only there, a throwaway login in a private keyring (gnome-keyring), and made-up words.
# shellcheck disable=SC2016,SC2086  # the inner script gets its paths as arguments; own_env is split
private_sync() {
  local d=$sb/sync-account rime port
  sandbox "$d"; mkdir -p "$d/server"
  rime=$d/data/fcitx5/rime
  sed -i 's|translator/enable_user_dict: false|translator/enable_user_dict: true|' "$rime/rime_ice.custom.yaml" 2>/dev/null
  rm -f "$d/config/mozc/user_dictionary.db"  # only made-up Japanese words
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  private_dbus "$sb" -i PATH="$PATH" $own_env HOME="$d" XDG_CONFIG_HOME="$d/config" XDG_DATA_HOME="$d/data" \
    -- bash -c '
      d=$1 here=$2 port=$3 server=$2/../../sync-server/sebtype_sync.py
      SEBTYPE_TEST_SYNC_PASSWORD=$(head -c 18 /dev/urandom | base64)
      printf "%s\n" "$SEBTYPE_TEST_SYNC_PASSWORD" | python3 -I "$server" adduser --data "$d/server" --password-stdin sebtype-test || exit 1
      python3 -I "$server" serve --data "$d/server" --port "$port" > "$d/server.log" 2>&1 & s=$!
      head -c 18 /dev/urandom | base64 | gnome-keyring-daemon --unlock --components=secrets --daemonize > /dev/null
      fcitx5 -k --disable=all --enable=dbus,dbusfrontend,keyboard,sebtype > "$d/fcitx5.log" 2>&1 & f=$!
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
for _ in range(100):  # the sebtype add-on loads a moment after Fcitx5 is on the bus
    try:
        call("/sebtype", "org.sebtype.Core1", "SetLanguage", "(s)", "zh")
        break
    except GLib.Error:
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
      "$here/target/release/sebtype-configurator-test" --ignored --exact sync::tests::private_server_syncs_both_ways_and_delete_clears_it
      rc=$?; kill $f $s; wait $f $s
      cp "$d/fcitx5.log" "$4/configurator-test-private-sync-fcitx5.log"
      ls -lR --time-style=+%T "$XDG_DATA_HOME/fcitx5/rime/sync" "$XDG_DATA_HOME/fcitx5/rime" > "$4/configurator-test-private-sync-rime.txt" 2>&1
      exit $rc' _ "$d" "$PWD" "$port" "$out"
}
export -f private_sync sandbox
check private-sync 300 private_sync

# Forget learned words while Rime and Mozc are open, then type, then restart (#375): a sandbox of its own
# with learning on and a new Mozc profile (default settings, no words of this account), made-up typing only.
# shellcheck disable=SC2086  # own_env is split
private_forget() {
  local d=$sb/forget-account
  sandbox "$d"
  rm -rf "$d/config/mozc"
  sed -i 's|translator/enable_user_dict: false|translator/enable_user_dict: true|' "$d/data/fcitx5/rime/rime_ice.custom.yaml" 2>/dev/null
  rm -f "$out/forget-results.txt"
  private_dbus "$sb" -i PATH="$PATH" $own_env HOME="$d" XDG_CONFIG_HOME="$d/config" XDG_DATA_HOME="$d/data" \
    -- python3 ../linux/test-forget.py "$out" "$tests" "$bin"
}
export -f private_forget
check private-forget 600 private_forget

# Sync when the network comes back (#377): the units the Configurator's login makes, in a private systemd
# user manager that starts nothing else, with the network trigger watching a file of the sandbox instead of
# resolv.conf (a drop-in), so the PC's network is never touched. Each sync's start and end go in runs.txt;
# its server isn't there, so it ends offline. Checked:
# - a new resolv.conf runs the real sync after it settles;
# - changes while a sync runs (held inside the sync, by holding its words.lock past the moment the sync
#   planned for them comes) come to exactly one more sync once it ends;
# - a change just after a sync waits until 2 minutes after it;
# - setup-ime.sh's uninstall, with a --network-changed and a sync waiting for the schedule lock it holds,
#   leaves no trigger, planned sync or file behind, nor does a sync that was running and ends after it (#401).
# shellcheck disable=SC2016  # the inner script gets its paths as arguments
reconnect_sync() {
  local d=$sb/reconnect-account u
  u=$d/config/systemd/user
  mkdir -p "$u/sebtype-sync.service.d" "$u/sebtype-sync-network.service.d" "$u/sebtype-sync.path.d" "$u/sebtype-sync.timer.d" "$d/data/sebtype"
  cat > "$u/sebtype-sync.service.d/runs.conf" <<EOF
[Service]
ExecStartPre=/bin/sh -c 'echo start \$(date +%%s) >> $d/runs.txt'
ExecStopPost=/bin/sh -c 'echo end \$(date +%%s) >> $d/runs.txt'
EOF
  printf '[Path]\nPathChanged=\nPathChanged=%s\n' "$d/resolv.conf" > "$u/sebtype-sync.path.d/sandbox.conf"
  # Only the network starts syncs here: no sync 2 minutes after the manager starts.
  printf '[Timer]\nOnStartupSec=\nOnUnitActiveSec=30min\n' > "$u/sebtype-sync.timer.d/sandbox.conf"
  printf '[Unit]\nDescription=Nothing\n' > "$u/sebtype-test.target"
  private_dbus "$sb" -i PATH="$PATH" HOME="$d" XDG_CONFIG_HOME="$d/config" XDG_DATA_HOME="$d/data" -- bash -c '
    d=$1 bin=$2 here=$3 units=$1/config/systemd/user own=$1/data/sebtype
    fail() { echo "FAIL: $1"; cat "$d/runs.txt" 2>/dev/null; tail -20 "$d/manager.log"; exit 1; }
    status() { sed -n "s/.*\"status\": *\"\([^\"]*\)\".*/\1/p" "$own/sync.json" 2>/dev/null; }
    until_() { local i; for ((i = 0; i < $1 * 5; i++)); do eval "$2" && return 0; sleep 0.2; done; return 1; }
    runs() { cat "$d/runs.txt" 2>/dev/null | grep -c "^$1"; }
    at() { grep "^$1" "$d/runs.txt" | sed -n "$2s/^$1 //p"; }  # start|end, the nth one
    change() { echo "nameserver 192.0.2.$1" > "$d/r.tmp"; mv "$d/r.tmp" "$d/resolv.conf"; }
    active() { systemctl --user is-active -q "$1"; }
    hold() { flock "$own/$1" sh -c "until [ -e \"$d/release-$1\" ]; do sleep 0.2; done" & }  # until release <lock>
    release() { touch "$d/release-$1"; }
    # The syncs and the network trigger see only this sandbox, never the owner'"'"'s sync.json or keyring.
    for s in sebtype-sync sebtype-sync-network; do
      printf "[Service]\nEnvironment=\"HOME=%s\" \"XDG_CONFIG_HOME=%s\" \"XDG_DATA_HOME=%s\" \"DBUS_SESSION_BUS_ADDRESS=%s\"\n" \
        "$d" "$d/config" "$d/data" "$DBUS_SESSION_BUS_ADDRESS" > "$units/$s.service.d/sandbox.conf"
    done
    SYSTEMD_LOG_TARGET=console SYSTEMD_LOG_COLOR=0 /usr/lib/systemd/systemd --user --unit=sebtype-test.target > "$d/manager.log" 2>&1 & m=$!
    # systemd leaves its inaccessible/ files without permissions: the sandbox couldn'"'"'t be removed.
    trap "release words.lock; release undo; kill $m; wait $m; cp \"$d/manager.log\" \"$4/configurator-test-reconnect-manager.log\"; chmod -R u+rwx \"\$XDG_RUNTIME_DIR\"" EXIT
    until_ 10 "[[ -S \$XDG_RUNTIME_DIR/systemd/private ]]" || fail "the private systemd didn'"'"'t start"
    head -c 18 /dev/urandom | base64 | gnome-keyring-daemon --unlock --components=secrets --daemonize > /dev/null
    printf "http://127.0.0.1:9\nsebtype-test\n%s\n" "$(head -c 18 /dev/urandom | base64)" | "$bin" --save-login ||
      fail "--save-login"
    active sebtype-sync.path && systemctl --user is-enabled -q sebtype-sync.path || fail "the network trigger isn'"'"'t on"
    echo "sync on: timer $(systemctl --user is-active sebtype-sync.timer), network trigger active, status $(status)"
    sleep 3; [[ $(runs start) == 0 ]] || fail "a sync ran before the network came back"

    hold words.lock
    t0=$(date +%s); change 1
    until_ 60 "[[ \$(runs start) == 1 ]]" || fail "no sync within a minute of the network coming back"
    echo "the network came back: a sync started $(( $(at start 1) - t0 )) s later"
    sleep 2; for i in $(seq 2 11); do change "$i"; sleep 0.1; done
    until_ 10 "active sebtype-sync-soon.timer" || fail "the changes during the sync planned nothing"
    until_ 150 "! active sebtype-sync-soon.timer" || fail "the sync planned for them never came"
    [[ $(runs end) == 0 ]] || fail "the sync ended before the one planned for the changes came"
    echo "10 changes during the sync: the sync planned for them came $(( $(date +%s) - $(at start 1) )) s into it"
    release words.lock
    until_ 60 "[[ \$(runs end) == 2 ]]" || fail "the changes during the sync were lost: $(runs start) syncs"
    sleep 20
    [[ $(runs start) == 2 ]] || fail "10 changes during a sync ran $(( $(runs start) - 1 )) syncs, not 1"
    [[ $(cut -d" " -f1 "$d/runs.txt" | uniq | wc -l) == 4 ]] || fail "two syncs at once"
    [[ $(status) == offline ]] || fail "status $(status), not offline"
    echo "once it ended: one more sync $(( $(at start 2) - $(at end 1) )) s later, never two at once, status $(status)"

    change 12
    until_ 180 "[[ \$(runs start) == 3 ]]" || fail "no sync after the change that came just after one"
    apart=$(( $(at start 3) - $(at start 2) ))
    ((apart >= 118 && apart <= 140)) || fail "syncs $apart s apart, not 2 minutes"
    echo "a change just after a sync: the next one $apart s after it"
    until_ 60 "[[ \$(runs end) == 3 ]]"
    active sebtype-sync.path || fail "the changes stopped the network trigger"

    leftovers() {  # true, naming them, if any is left
      local f
      for f in "$units"/sebtype-sync.{path,timer,service} "$units"/sebtype-sync-network.service "$own"/{sync.json,network-state,schedule.lock}; do
        [[ -e $f ]] && echo "$f"
      done | grep .
    }
    # The uninstall, held while it holds the schedule lock (its first systemctl waits for release undo).
    real=$(command -v systemctl); mkdir -p "$d/held"
    printf "#!/bin/sh\n[ \"\$2\" = disable ] && until [ -e %s/release-undo ]; do sleep 0.2; done\nexec %s \"\$@\"\n" "$d" "$real" > "$d/held/systemctl"
    chmod +x "$d/held/systemctl"
    HOME=$d PATH=$d/held:$PATH bash "$here/../linux/setup-ime.sh" --undo-configurator > "$d/undo.log" 2>&1 & undo=$!
    until_ 10 "! flock -n \"\$own/schedule.lock\" true" || fail "the uninstall doesn'"'"'t take the schedule lock"
    change 13
    until_ 10 "[[ \$(systemctl --user is-active sebtype-sync-network.service) == activating ]]" ||
      fail "--network-changed isn'"'"'t waiting for the schedule lock"
    systemctl --user start --no-block sebtype-sync.service
    sleep 2; [[ $(systemctl --user is-active sebtype-sync.service) == activating ]] ||
      fail "the sync isn'"'"'t waiting for the schedule lock"
    release undo
    wait $undo || fail "the uninstall failed: $(tail -5 "$d/undo.log")"
    until_ 30 "[[ \$(systemctl --user is-active sebtype-sync.service) != activating ]]" || fail "the waiting sync never ended"
    sleep 5
    for x in sebtype-sync.path sebtype-sync-network.service sebtype-sync-soon.timer; do
      active "$x" && fail "$x still runs after the uninstall"
    done
    left=$(leftovers) && fail "files left after the uninstall: $left"
    echo "the uninstall, with --network-changed and a sync waiting: no trigger, planned sync or file left"

    # A sync running through the uninstall (held in its pull by words.lock), ending after it.
    printf "http://127.0.0.1:9\nsebtype-test\n%s\n" "$(head -c 18 /dev/urandom | base64)" | "$bin" --save-login ||
      fail "--save-login again"
    rm "$d/release-words.lock"; hold words.lock
    systemctl --user start --no-block sebtype-sync.service
    until_ 10 "[[ \$(runs start) == 5 ]]" || fail "the second sync didn'"'"'t start"
    sleep 2
    HOME=$d bash "$here/../linux/setup-ime.sh" --undo-configurator > "$d/undo2.log" 2>&1 || fail "the second uninstall failed: $(tail -5 "$d/undo2.log")"
    release words.lock
    until_ 30 "[[ \$(systemctl --user is-active sebtype-sync.service) != activating ]]" || fail "the running sync never ended"
    left=$(leftovers) && fail "files left by the sync that ended after the uninstall: $left"
    echo "a sync running through the uninstall: no file left once it ended"
' _ "$d" "$bin" "$PWD" "$out"
}
export -f reconnect_sync
check sync-on-network-reconnect 700 reconnect_sync

check setup-ime 900 ../linux/test-setup-ime.sh

! grep -q '^FAIL' "$results"
