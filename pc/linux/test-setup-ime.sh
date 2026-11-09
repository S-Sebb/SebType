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
  before=$(find ~/.config/kwinrc ~/.config/kdeglobals ~/.config/environment.d ~/.config/fcitx5/config ~/.config/mozc/config1.db ~/.local/share/applications ~/.local/share/flatpak/overrides \
    ~/.local/share/icons/SebType ~/.local/share/sebtype ~/.local/share/fcitx5/inputmethod ~/.local/share/fcitx5/rime/rime_ice.custom.yaml -type f -exec md5sum {} + 2>/dev/null | sort)
  timeout 60 ./setup-ime.sh --dry-run | tee /dev/stderr | grep '^would:' | grep -v 'unused Flatpak override' && return 1
  after=$(find ~/.config/kwinrc ~/.config/kdeglobals ~/.config/environment.d ~/.config/fcitx5/config ~/.config/mozc/config1.db ~/.local/share/applications ~/.local/share/flatpak/overrides \
    ~/.local/share/icons/SebType ~/.local/share/sebtype ~/.local/share/fcitx5/inputmethod ~/.local/share/fcitx5/rime/rime_ice.custom.yaml -type f -exec md5sum {} + 2>/dev/null | sort)
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
  *" emit "*) echo "$*" >> "$FAKE/emit.log" ;;
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
printf '[Hotkey]\nEnumerateWithTriggerKeys=True\n\n[Hotkey/TriggerKeys]\n0=Super+space\n\n[Hotkey/AltTriggerKeys]\n0=Shift_L\n\n[Hotkey/EnumerateForwardKeys]\n0=Control+Shift+Shift_L\n\n[Behavior]\nActiveByDefault=False\nShareInputState=No\n' > "$h/.config/fcitx5/config"
printf '\x0a\x02\x08\x01\xc8\x02\x02\xda\x02\x01x' > "$h/.config/mozc/config1.db"
printf '[Icons]\nTheme=Fluent-dark\n' > "$h/.config/kdeglobals"
fake_run() { env -i PATH="$fake/bin:$PATH" HOME="$h" FAKE="$fake" XDG_CONFIG_HOME="$h/.config" \
  XDG_DATA_HOME="$h/.local/share" timeout 60 ./setup-ime.sh "$@"; }

fresh_dry() {
  local o; o=$(fake_run --dry-run < /dev/null) || return 1; echo "$o"
  [[ $(grep -c '^would:' <<<"$o") == 11 ]] && grep -q 'QT_IM_MODULE=fcitx$' <<<"$(grep warning <<<"$o")" &&
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
    fcitx_hotkeys && mozc_keymap && tray_icons && grep -qx 'Label=中文' "$h/.local/share/fcitx5/inputmethod/rime.conf" &&
    grep -q '^  schema/name: ".中文"' "$h/.local/share/fcitx5/rime/rime_ice.custom.yaml" && grep -q 'setForeignShortcutKeys asa(ai) 4 kwin .* 1 4 268435552 0 0 0$' "$fake/kga.log"
}
# Super+Space is the only switch, all windows share one state, the other settings stay, and Fcitx5 reloaded it.
fcitx_hotkeys() {
  local c=$h/.config/fcitx5/config
  [[ $(sed -n '/^\[Hotkey\/EnumerateForwardKeys\]/,/^$/p' "$c") == $'[Hotkey/EnumerateForwardKeys]\n0=Super+space' ]] &&
    ! grep -qE 'Shift_L|^\[Hotkey/(Trigger|AltTrigger)Keys' "$c" && grep -qx 'AltTriggerKeys=' "$c" &&
    grep -qx 'EnumerateGroupForwardKeys=' "$c" && grep -qx 'ActiveByDefault=False' "$c" &&
    [[ $(grep -c '^ShareInputState=' "$c") == 1 ]] && grep -qx 'ShareInputState=All' "$c" &&
    ls "$h"/.local/share/sebtype/backup/*/config && [[ -e $fake/reload.log ]]
}
# The keymap replaces fields 41 and 42 in place; fields 1 and 43 are kept.
mozc_keymap() {
  local db=$h/.config/mozc/config1.db
  cmp <(head -c 9 "$db") <(printf '\x0a\x02\x08\x01\xc8\x02\x00\xd2\x02') &&
    cmp <(tail -c 4 "$db") <(printf '\xda\x02\x01x') && grep -qF $'DirectInput\tAlt `\tIMEOn' "$db" &&
    ls "$h"/.local/share/sebtype/backup/*/config1.db
}
# SebType's icon theme inherits the theme that was active, holds every Fcitx5 status name at each size,
# is active, and the running apps were told.
tray_icons() {
  local t=$h/.local/share/icons/SebType d n
  [[ $(kreadconfig6 --file "$h/.config/kdeglobals" --group Icons --key Theme) == SebType ]] &&
    grep -qx 'Inherits=Fluent-dark' "$t/index.theme" && grep -q iconChanged "$fake/emit.log" || return 1
  for d in 16 20 22 24 32 scalable; do
    for n in input-keyboard:en fcitx-rime:zh fcitx_rime_latin:zh-a fcitx_rime_latin_upper:zh-A fcitx_mozc_hiragana:hira \
      fcitx_mozc_katakana_full:kata fcitx_mozc_direct:ja-a; do
      cmp "../icons/$d/${n#*:}.svg" "$t/$d/status/${n%%:*}.svg" || return 1
    done
  done
}
check fresh-apply fresh_apply

# --undo-icons brings back the inherited theme and removes SebType's; a second undo changes nothing.
undo_icons() {
  local o; o=$(fake_run --undo-icons < /dev/null) || return 1; echo "$o"
  [[ $(kreadconfig6 --file "$h/.config/kdeglobals" --group Icons --key Theme) == Fluent-dark &&
    ! -e $h/.local/share/icons/SebType && $(grep -c '^change:' <<<"$o") == 2 ]] &&
    o=$(fake_run --undo-icons < /dev/null) && [[ -z $o ]] &&
    o=$(fake_run < /dev/null) && grep -q '^change: install SebType.s tray icons .* over Fluent-dark' <<<"$o" && tray_icons
}

# Japanese keys, typed into a private Fcitx5 (its own D-Bus session, no display, so the live session
# can't see it) running Mozc on a second fake account set up by setup-ime.sh: Shift tap toggles
# あ ⇄ English in every Mozc state, Shift+K and Ctrl+Shift don't, and Alt+` still does. Its fcitx5 and
# mozc_server are found by the fake HOME in their environment and stopped afterwards.
mozc_keys() {
  local h=$fake/jp
  mkdir -p "$h/.config/fcitx5"
  fake_run < /dev/null > /dev/null || return 1
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=mozc\n\n[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n[Groups/0/Items/1]\nName=mozc\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  env -i PATH="$PATH" HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR-}" timeout 60 dbus-run-session -- python3 - "$fake/fcitx5.log" <<'PY'
import subprocess, sys, time
from gi.repository import Gio, GLib

SHIFT, CTRL, ALT = 1, 4, 8
KEYS = {'Shift_L': (0xffe1, 50), 'Control_L': (0xffe3, 37), 'Alt_L': (0xffe9, 64), 'Escape': (0xff1b, 9),
        'Return': (0xff0d, 36), 'Tab': (0xff09, 23), 'space': (0x20, 65), 'a': (0x61, 38), 'k': (0x6b, 45),
        'K': (0x4b, 45), 'grave': (0x60, 49)}
MODS = {'Shift_L': SHIFT, 'Control_L': CTRL, 'Alt_L': ALT}

fcitx = subprocess.Popen(['fcitx5', '-k', '--disable=all', '--enable=dbus,dbusfrontend,keyboard,mozc'],
                         stdout=subprocess.DEVNULL, stderr=open(sys.argv[1], 'w'))
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
def call(path, iface, method, sig=None, *args):  # never D-Bus-activates a second, default Fcitx5
    return bus.call_sync('org.fcitx.Fcitx5', path, iface, method, GLib.Variant(sig, args) if sig else None,
                         None, Gio.DBusCallFlags.NO_AUTO_START, 10000, None).unpack()
CONTROLLER, IC = ('/controller', 'org.fcitx.Fcitx.Controller1'), 'org.fcitx.Fcitx.InputContext1'
for _ in range(100):
    try: call(*CONTROLLER, 'CurrentInputMethod'); break
    except GLib.Error: time.sleep(0.1)
ic, _ = call('/org/freedesktop/portal/inputmethod', 'org.fcitx.Fcitx.InputMethod1', 'CreateInputContext',
             '(a(ss))', [('program', 'sebtype-test')])
committed, preedit = [], ['']
def on_signal(_c, _s, _p, _i, name, params):
    if name == 'CommitString': committed.append(params.unpack()[0])
    elif name == 'UpdateFormattedPreedit': preedit[0] = ''.join(s for s, _ in params.unpack()[0])
bus.signal_subscribe(None, IC, None, ic, None, 0, on_signal)
call(ic, IC, 'SetCapability', '(t)', 1 << 1 | 1 << 4 | 1 << 39)  # preedit, formatted, client-side panel
call(ic, IC, 'FocusIn')
call(*CONTROLLER, 'SetCurrentIM', '(s)', 'mozc')

def key(name, state=0, release=False):  # True when Fcitx5 took the key, False when it goes to the app
    sym, code = KEYS[name]
    taken = call(ic, IC, 'ProcessKeyEvent', '(uuubu)', sym, code, state, release, 0)[0]
    end = time.time() + 0.05
    while time.time() < end: GLib.MainContext.default().iteration(False)
    return taken
def tap(name, state=0):
    taken = key(name, state); key(name, state | MODS.get(name, 0), True); return taken
def chord(mod, name):
    key(mod); tap(name, MODS[mod]); key(mod, MODS[mod], True)
def shift_tap(): tap('Shift_L')
def mode():  # 'あ' when "a" starts a kana preedit (then cleared), 'A' when it goes to the app
    if tap('a'):
        got = 'あ' if preedit[0] == 'あ' else f'preedit {preedit[0]!r}'
        tap('Escape')
    else: got = 'A'
    im = call(*CONTROLLER, 'CurrentInputMethod')[0]
    return got if im == 'mozc' else f'Fcitx5 switched to {im}'

ok = True
def check(name, got, want):
    global ok
    ok &= got == want
    print('PASS' if got == want else 'FAIL', name, '' if got == want else f'got {got!r}, want {want!r}')

check('starts in あ', mode(), 'あ')
for state, keys in [('composing', 'ka'), ('converting', ['k', 'a', 'space']), ('predicting', ['k', 'a', 'Tab']),
                    ('after a commit', ['k', 'a', 'Return'])]:
    for k in keys: tap(k)
    pending, before = preedit[0], len(committed)
    shift_tap()
    check(f'Shift tap {state} commits the preedit', bool(committed[before:]), bool(pending))
    check(f'Shift tap {state} turns English on', mode(), 'A')
    shift_tap(); check(f'Shift tap in English {state} is あ again', mode(), 'あ')
key('Shift_L'); tap('K', SHIFT); key('Shift_L', SHIFT, True)
check('Shift+K starts an English run', preedit[0], 'K')
tap('Escape'); check('Shift+K stays in あ', mode(), 'あ')
key('Control_L'); key('Shift_L', CTRL); key('Shift_L', CTRL | SHIFT, True); key('Control_L', CTRL, True)
check('Ctrl+Shift stays in あ', mode(), 'あ')
chord('Alt_L', 'grave'); check('Alt+` turns English on', mode(), 'A')
chord('Alt_L', 'grave'); check('Alt+` is あ again', mode(), 'あ')
fcitx.terminate(); fcitx.wait(10)
sys.exit(0 if ok else 1)
PY
  local rc=$? p
  for p in $(pgrep -x fcitx5) $(pgrep -x mozc_server); do
    grep -qzx "HOME=$h" "/proc/$p/environ" 2>/dev/null && kill "$p"
  done
  return $rc
}
if command -v fcitx5 dbus-run-session >/dev/null && [[ -f /usr/share/fcitx5/addon/mozc.conf ]] &&
  python3 -c 'from gi.repository import Gio' 2>/dev/null; then
  check mozc-shift-tap-and-alt-grave mozc_keys
else result SKIP mozc-shift-tap-and-alt-grave "needs fcitx5, fcitx5-mozc, dbus-run-session and python3-gobject"
fi

# Chinese label (#69): a private Fcitx5 (as above) running Rime with a tiny schema that has rime-ice's id
# and name, on a third fake account set up by setup-ime.sh. Switching to it must show 中文 in the popup,
# both the long one and the compact one (the reference PC's setting; it shows the label the tray text
# uses), and the schema id must stay rime_ice.
rime_label() {
  local h=$fake/zh r
  r=$h/.local/share/fcitx5/rime
  mkdir -p "$h/.config/fcitx5" "$r"
  printf 'schema:\n  schema_id: rime_ice\n  name: 雾凇拼音\nengine:\n  processors: [ascii_composer, speller, express_editor]\n  segmentors: [abc_segmentor]\n  translators: [echo_translator]\n' \
    > "$r/rime_ice.schema.yaml"
  printf 'patch:\n  schema_list: [{schema: rime_ice}]\n' > "$r/default.custom.yaml"
  printf 'patch:\n  menu/page_size: 6\n' > "$r/rime_ice.custom.yaml"
  fake_run < /dev/null > /dev/null || return 1
  grep -qx '  menu/page_size: 6' "$r/rime_ice.custom.yaml" || { echo "rime_ice.custom.yaml lost its patch"; return 1; }
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=keyboard-us\n\n[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n[Groups/0/Items/1]\nName=rime\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  env -i PATH="$PATH" HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR-}" timeout 90 dbus-run-session -- python3 - "$fake/fcitx5-rime.log" "$r" "$h/.config/fcitx5/config" <<'PY'
import os, subprocess, sys, time
from gi.repository import Gio, GLib

fcitx = subprocess.Popen(['fcitx5', '-k', '--disable=all', '--enable=dbus,dbusfrontend,keyboard,rime'],
                         stdout=subprocess.DEVNULL, stderr=open(sys.argv[1], 'w'))
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
def call(path, iface, method, sig=None, *args):
    return bus.call_sync('org.fcitx.Fcitx5', path, iface, method, GLib.Variant(sig, args) if sig else None,
                         None, Gio.DBusCallFlags.NO_AUTO_START, 10000, None).unpack()
CONTROLLER, IC = ('/controller', 'org.fcitx.Fcitx.Controller1'), 'org.fcitx.Fcitx.InputContext1'
def wait(cond, secs):
    end = time.time() + secs
    while time.time() < end and not cond():
        GLib.MainContext.default().iteration(False); time.sleep(0.02)
    return cond()
def up():
    try: call(*CONTROLLER, 'CurrentInputMethod'); return True
    except GLib.Error: return False
wait(up, 10)
ic, _ = call('/org/freedesktop/portal/inputmethod', 'org.fcitx.Fcitx.InputMethod1', 'CreateInputContext',
             '(a(ss))', [('program', 'sebtype-test')])
popups = []
def on_signal(_c, _s, _p, _i, name, params):
    if name == 'UpdateClientSideUI':
        text = ''.join(s for s, _ in params.unpack()[2])
        if text: popups.append(text)
bus.signal_subscribe(None, IC, None, ic, None, 0, on_signal)
call(ic, IC, 'SetCapability', '(t)', 1 << 1 | 1 << 4 | 1 << 39)
call(ic, IC, 'FocusIn')

def switch():  # the popup text shown when switching from English to Chinese
    call(*CONTROLLER, 'SetCurrentIM', '(s)', 'keyboard-us'); wait(lambda: False, 0.2)
    popups.clear(); call(*CONTROLLER, 'SetCurrentIM', '(s)', 'rime')
    wait(lambda: popups, 2); wait(lambda: False, 0.2)
    return popups[-1] if popups else None

ok = True
def check(name, got, want):
    global ok
    ok &= got == want
    print('PASS' if got == want else 'FAIL', name, '' if got == want else f'got {got!r}, want {want!r}')

switch()  # loads Rime, which deploys the schema
check('Rime deployed', wait(lambda: os.path.exists(f'{sys.argv[2]}/build/rime_ice.schema.yaml'), 30), True)
wait(lambda: False, 1)
check('long popup reads 中文', switch(), '中文')
with open(sys.argv[3], 'a') as f: f.write('\n[Behavior]\nCompactInputMethodInformation=True\n')
call(*CONTROLLER, 'ReloadConfig')
check('compact popup reads 中文', switch(), '中文')
check('schema id stays rime_ice', call('/rime', 'org.fcitx.Fcitx.Rime1', 'GetCurrentSchema')[0], 'rime_ice')
fcitx.terminate(); fcitx.wait(10)
sys.exit(0 if ok else 1)
PY
  local rc=$? p
  for p in $(pgrep -x fcitx5); do grep -qzx "HOME=$h" "/proc/$p/environ" 2>/dev/null && kill "$p"; done
  return $rc
}
if command -v fcitx5 dbus-run-session >/dev/null && [[ -f /usr/share/fcitx5/addon/rime.conf ]] &&
  python3 -c 'from gi.repository import Gio' 2>/dev/null; then
  check rime-label-reads-zhongwen rime_label
else result SKIP rime-label-reads-zhongwen "needs fcitx5, fcitx5-rime, dbus-run-session and python3-gobject"
fi

rerun() {
  echo 'XMODIFIERS=@im=fcitx' > "$fake/session-env"
  local o; o=$(fake_run < /dev/null) || return 1; echo "$o"
  grep -q '^done: 1 change(s)' <<<"$o" && grep -q 'install packages fcitx5-mozc' <<<"$o"
}
check rerun-only-asks-for-missing-package rerun
check undo-icons-and-reinstall undo_icons

! grep -q '^FAIL' "$results"
