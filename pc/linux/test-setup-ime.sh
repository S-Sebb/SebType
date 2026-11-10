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
# The fake account has no Rust: setup-ime.sh copies the Configurator built here.
cargo build --release --quiet --manifest-path ../configurator/Cargo.toml ||
  { echo "preflight: the SebType Configurator does not build (pc/configurator)"; exit 1; }

check shellcheck uvx --from shellcheck-py shellcheck -x setup-ime.sh test-setup-ime.sh mozc/build.sh

# Live dry run: must not touch the account, and on a set-up PC only the agreed cleanups remain (and
# SebType's fcitx5-mozc, until the user says yes to its sudo install).
live_dry() {
  local before after
  before=$(find ~/.config/kwinrc ~/.config/kdeglobals ~/.config/environment.d ~/.config/fcitx5/config ~/.config/mozc/config1.db ~/.local/share/applications ~/.local/share/flatpak/overrides \
    ~/.local/share/icons/SebType ~/.local/share/sebtype ~/.local/share/fcitx5/inputmethod ~/.local/share/fcitx5/rime/rime_ice.custom.yaml -type f -exec md5sum {} + 2>/dev/null | sort)
  timeout 60 ./setup-ime.sh --dry-run | tee /dev/stderr | grep '^would:' | grep -v -e 'unused Flatpak override' -e "with SebType's build" -e 'install SebType Configurator' && return 1
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
# shellcheck source=mozc/versions.sh
source mozc/versions.sh
# fcitx5-mozc is installed only when $FAKE/mozc holds its version-release; the fake sudo logs and
# applies dnf's install of SebType's RPM and its distro-sync back to Fedora's.
stub rpm '[[ ${*: -1} != fcitx5-mozc ]] && exit; [[ -f $FAKE/mozc ]] || exit 1; [[ $2 == --qf ]] && cat "$FAKE/mozc"; true'
stub sudo "echo \"sudo \$*\" >> \"\$FAKE/sudo.log\"
case \"\$*\" in
  'dnf install -y '*/$MOZC_RPM) echo -n '$MOZC_VERSION-$SEBTYPE_RELEASE' > \"\$FAKE/mozc\" ;;
  'dnf distro-sync -y fcitx5-mozc') echo -n '$MOZC_VERSION-$MOZC_FEDORA_RELEASE' > \"\$FAKE/mozc\" ;;
esac"
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
  [[ $(grep -c '^would:' <<<"$o") == 13 ]] && grep -q 'QT_IM_MODULE=fcitx$' <<<"$(grep warning <<<"$o")" &&
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
    grep -q '^  schema/name: ".中文"' "$h/.local/share/fcitx5/rime/rime_ice.custom.yaml" &&
    grep -q '^  sebtype_typo/keyboard: pc' "$h/.local/share/fcitx5/rime/rime_ice.custom.yaml" && grep -q 'setForeignShortcutKeys asa(ai) 4 kwin .* 1 4 268435552 0 0 0$' "$fake/kga.log" && configurator
}
# The Configurator is in the app menu, starts this account's copy of the build, and has the pig icon.
configurator() {
  local d=$h/.local/share
  cmp ../configurator/target/release/sebtype-configurator "$d/sebtype/configurator/sebtype-configurator" &&
    grep -qx "Exec=$d/sebtype/configurator/sebtype-configurator" "$d/applications/sebtype-configurator.desktop" &&
    desktop-file-validate "$d/applications/sebtype-configurator.desktop" &&
    [[ -f $d/icons/hicolor/192x192/apps/sebtype-configurator.png ]]
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
      fcitx_mozc_katakana_full:kata fcitx_mozc_direct:ja-a fcitx_mozc_direct_upper:ja-A; do
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

# --undo-configurator removes the app and puts back the candidate window theme Picnic replaced; a second
# undo changes nothing, and setup installs it again.
undo_configurator() {
  local d=$h/.local/share c=$h/.config/fcitx5/conf/classicui.conf o
  mkdir -p "$d/fcitx5/themes/sebtype-picnic" "${c%/*}"
  printf 'Theme=Nord\nDarkTheme=default-dark\n' > "$d/fcitx5/themes/sebtype-picnic/previous"
  printf 'Vertical Candidate List=False\nTheme=sebtype-picnic\nDarkTheme=sebtype-picnic\n' > "$c"
  o=$(fake_run --undo-configurator < /dev/null) || return 1; echo "$o"
  [[ $(grep -c '^change:' <<<"$o") == 5 && ! -e $d/sebtype/configurator && ! -e $d/applications/sebtype-configurator.desktop &&
    ! -e $d/icons/hicolor/192x192/apps/sebtype-configurator.png && ! -e $d/fcitx5/themes/sebtype-picnic ]] &&
    [[ $(cat "$c") == $'Vertical Candidate List=False\nTheme=Nord\nDarkTheme=default-dark' ]] &&
    o=$(fake_run --undo-configurator < /dev/null) && [[ -z $o ]] &&
    o=$(fake_run < /dev/null) && grep -q '^change: install SebType Configurator' <<<"$o" && configurator
}

# Japanese keys, typed into a private Fcitx5 (its own D-Bus session, no display, so the live session
# can't see it) running Mozc on a second fake account set up by setup-ime.sh: Shift tap toggles
# あ ⇄ English in every Mozc state, Shift+K and Ctrl+Shift don't, and Alt+` still does; the tray (a stand-in
# for Plasma's kimpanel on that bus) gets the icon of each mode. Caps Lock (A) has no D-Bus way in: it is
# checked on the desktop (pc/linux/README.md). Its fcitx5 and
# mozc_server are found by the fake HOME in their environment and stopped afterwards.
mozc_keys() {
  local h=$fake/jp
  mkdir -p "$h/.config/fcitx5"
  fake_run < /dev/null > /dev/null || return 1
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=mozc\n\n[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n[Groups/0/Items/1]\nName=mozc\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  env -i PATH="$PATH" HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR-}" timeout 60 dbus-run-session -- python3 - "$fake/fcitx5.log" <<'PY'
import re, subprocess, sys, time
from gi.repository import Gio, GLib

SHIFT, CTRL, ALT = 1, 4, 8
KEYS = {'Shift_L': (0xffe1, 50), 'Control_L': (0xffe3, 37), 'Alt_L': (0xffe9, 64), 'Escape': (0xff1b, 9),
        'Return': (0xff0d, 36), 'Tab': (0xff09, 23), 'space': (0x20, 65), 'a': (0x61, 38), 'k': (0x6b, 45),
        'K': (0x4b, 45), 'grave': (0x60, 49), 'Katakana': (0xff26, 101), 'Hiragana': (0xff25, 102)}
MODS = {'Shift_L': SHIFT, 'Control_L': CTRL, 'Alt_L': ALT}

fcitx = subprocess.Popen(['fcitx5', '-k', '--disable=all', '--enable=dbus,dbusfrontend,keyboard,mozc,kimpanel'],
                         stdout=subprocess.DEVNULL, stderr=open(sys.argv[1], 'w'))
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
Gio.bus_own_name_on_connection(bus, 'org.kde.impanel', 0, None, None)
tray = ['']
def on_tray(_c, _s, _p, _i, name, params):
    if name == 'UpdateProperty': tray[0] = (re.findall(r'fcitx_mozc_\w+', str(params.unpack())) or tray)[0]
bus.signal_subscribe(None, None, 'UpdateProperty', None, None, 0, on_tray)
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
check('tray icon in あ', tray[0], 'fcitx_mozc_hiragana')
tap('Shift_L'); check('tray icon in English', tray[0], 'fcitx_mozc_direct'); tap('Shift_L')
tap('Katakana'); check('tray icon in ア', tray[0], 'fcitx_mozc_katakana_full'); tap('Hiragana')
check('tray icon back in あ', tray[0], 'fcitx_mozc_hiragana')
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
# uses), and the schema id must stay rime_ice. The schema also has rime-ice's 简/繁 switch, so the same
# Fcitx5 checks the Ctrl+Shift+F key (#36): 后来 comes out as 後來 and back, and Ctrl+F reaches the app.
rime_label() {
  local h=$fake/zh r
  r=$h/.local/share/fcitx5/rime
  mkdir -p "$h/.config/fcitx5" "$r"
  cat > "$r/rime_ice.schema.yaml" <<'YAML'
schema: { schema_id: rime_ice, name: 雾凇拼音 }
switches: [{ name: traditionalization, states: [简, 繁] }]
engine:
  processors: [ascii_composer, key_binder, speller, selector, express_editor]
  segmentors: [abc_segmentor]
  translators: [table_translator]
  filters: [simplifier@traditionalize]
speller: { alphabet: abcdefghijklmnopqrstuvwxyz, delimiter: " '" }
translator: { dictionary: sebtest }
traditionalize: { option_name: traditionalization, opencc_config: s2t.json }
key_binder: { import_preset: default }
YAML
  printf -- '---\nname: sebtest\nversion: "1"\nsort: by_weight\n...\n后来\thou lai\t100\n后\thou\t10\n来\tlai\t10\n' > "$r/sebtest.dict.yaml"
  mkdir -p "$r/opencc"; cp /usr/share/opencc/{s2t.json,STPhrases.ocd2,STCharacters.ocd2} "$r/opencc/"
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
committed = []
def on_commit(_c, _s, _p, _i, name, params):
    if name == 'CommitString': committed.append(params.unpack()[0])
bus.signal_subscribe(None, IC, None, ic, None, 0, on_signal)
bus.signal_subscribe(None, IC, None, ic, None, 0, on_commit)
call(ic, IC, 'SetCapability', '(t)', 1 << 1 | 1 << 4 | 1 << 39)
call(ic, IC, 'FocusIn')

SHIFT, CTRL = 1, 4
KEYS = {'Shift_L': (0xffe1, 50), 'Control_L': (0xffe3, 37), 'space': (0x20, 65), 'f': (0x66, 41), 'F': (0x46, 41),
        **{c: (ord(c), code) for c, code in zip('houlai', (43, 32, 30, 46, 38, 31))}}
def key(name, state=0, release=False):  # True when Fcitx5 took the key, False when it goes to the app
    taken = call(ic, IC, 'ProcessKeyEvent', '(uuubu)', *KEYS[name], state, release, 0)[0]
    wait(lambda: False, 0.03)
    return taken
def tap(name, state=0):
    taken = key(name, state); key(name, state, True); return taken
def ctrl(name, shift=False):  # Ctrl(+Shift)+name, pressed in order and released in reverse
    key('Control_L'); shift and key('Shift_L', CTRL)
    mods = CTRL | (SHIFT if shift else 0)
    taken = tap(name, mods)
    shift and key('Shift_L', mods, True); key('Control_L', CTRL, True)
    return taken
def houlai():  # types houlai, picks the first candidate, returns what was committed
    committed.clear()
    for c in 'houlai': tap(c)
    tap('space'); wait(lambda: committed, 2)
    return ''.join(committed)

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
check('simplified at first', houlai(), '后来')
check('Ctrl+Shift+F is taken', ctrl('F', shift=True), True)
check('traditional after Ctrl+Shift+F', houlai(), '後來')
ctrl('f', shift=True)  # Shift may send the lowercase keysym
check('simplified after the second Ctrl+Shift+F', houlai(), '后来')
check('Ctrl+F reaches the app', ctrl('f'), False)
fcitx.terminate(); fcitx.wait(10)
sys.exit(0 if ok else 1)
PY
  local rc=$? p
  for p in $(pgrep -x fcitx5); do grep -qzx "HOME=$h" "/proc/$p/environ" 2>/dev/null && kill "$p"; done
  return $rc
}
if command -v fcitx5 dbus-run-session >/dev/null && [[ -f /usr/share/fcitx5/addon/rime.conf ]] &&
  python3 -c 'from gi.repository import Gio' 2>/dev/null; then
  check rime-label-and-zh-hant-key rime_label
else result SKIP rime-label-and-zh-hant-key "needs fcitx5, fcitx5-rime, dbus-run-session and python3-gobject"
fi

rerun() {
  echo 'XMODIFIERS=@im=fcitx' > "$fake/session-env"
  local o; o=$(fake_run < /dev/null) || return 1; echo "$o"
  grep -q '^done: 1 change(s)' <<<"$o" && grep -q 'install packages fcitx5-mozc' <<<"$o"
}
check rerun-only-asks-for-missing-package rerun

# SebType's fcitx5-mozc (#66) replaces Fedora's after a yes, a rerun leaves it, --undo-mozc brings back
# Fedora's once, and an fcitx5-mozc of another version is left alone with a warning. The RPM is a
# placeholder, so nothing is built.
mozc_swap() {
  local o rpm=$h/.cache/sebtype/mozc/rpms/$MOZC_RPM
  mkdir -p "${rpm%/*}"; : > "$rpm"; rm -f "$fake/sudo.log"
  echo -n "$MOZC_VERSION-$MOZC_FEDORA_RELEASE" > "$fake/mozc"
  o=$(echo y | fake_run) || return 1; echo "$o"
  grep -q "^change: replace fcitx5-mozc .* with SebType's build" <<<"$o" &&
    [[ $(cat "$fake/sudo.log") == "sudo dnf install -y $rpm" && $(cat "$fake/mozc") == *.sebtype* ]] || return 1
  o=$(fake_run < /dev/null) || return 1; echo "$o"
  ! grep -q 'fcitx5-mozc' <<<"$o" || return 1
  o=$(fake_run --undo-mozc < /dev/null) || return 1; echo "$o"
  [[ $(tail -1 "$fake/sudo.log") == 'sudo dnf distro-sync -y fcitx5-mozc' && $(cat "$fake/mozc") == "$MOZC_VERSION-$MOZC_FEDORA_RELEASE" ]] &&
    o=$(fake_run --undo-mozc < /dev/null) && [[ -z $o ]] || return 1
  echo -n 2.31.0-1.fc45 > "$fake/mozc"
  o=$(fake_run < /dev/null) || return 1; echo "$o"
  grep -q "^warning: fcitx5-mozc 2.31.0-1.fc45 isn't the version" <<<"$o" && [[ $(wc -l < "$fake/sudo.log") == 2 ]]
}
check mozc-install-and-undo mozc_swap
check undo-icons-and-reinstall undo_icons
check undo-configurator-and-reinstall undo_configurator

! grep -q '^FAIL' "$results"
