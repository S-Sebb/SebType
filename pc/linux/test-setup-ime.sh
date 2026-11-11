#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub bodies are single-quoted; they expand when the stub runs
# Checks pc/linux/setup-ime.sh: ShellCheck, a read-only --dry-run on this PC, and a full run on a
# fake fresh account (stubbed packages, systemd, Fcitx5 and KWin calls) that must be idempotent.
# Changes nothing in the real session. One line per check in /tmp/sebtype/test-setup-ime-results.txt.
# Typing in real apps is the manual checklist in pc/linux/README.md.
set -uo pipefail
script=$(readlink -f "$0")
cd "$(dirname "$script")" || exit 1
# Its private Fcitx5 instances run on this PC: one test at a time, in the shared device queue.
[[ -n ${HOLDING-} ]] || exec env HOLDING=1 devq -w 1800 -m 10 -n "sebtype test-setup-ime ($(git branch --show-current))" \
  /tmp/agent-locks/devices/nobara-pc.lock bash "$script"

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
# Nor does it build SebType's Chinese data: each fake account's cache links the zip built here.
../../tools/rime-data/build.sh "$out/rime-data" > "$out/test-setup-ime-rime-data.log" 2>&1 ||
  { echo "preflight: SebType's Chinese data does not build (see $out/test-setup-ime-rime-data.log)"; exit 1; }
mapfile -t rime_zips < <(for z in ~/.cache/sebtype/rime-data-*.zip; do cmp -s "$z" "$out/rime-data/rime/rime-data.zip" && echo "$z"; done)
((${#rime_zips[@]})) || { echo "preflight: no cached zip of SebType's Chinese data in ~/.cache/sebtype"; exit 1; }
rime_data=$out/rime-data/rime/rime-data.zip
# SebType's fcitx5-rime, librime and fcitx5-mozc (#66, #117, #101), built once and cached. The private
# Fcitx5s below run them without installing them: bwrap mounts their files over Fedora's for that Fcitx5 alone.
# shellcheck source=mozc/versions.sh
source mozc/versions.sh
# shellcheck source=rime/versions.sh
source rime/versions.sh
own=$out/own-builds; rm -rf "$own"; mkdir -p "$own"
for b in "$MOZC_CACHE/rpms/$MOZC_RPM mozc/build.sh" "$RIME_CACHE/$RIME_RPM rime/build.sh" \
  "$(librime_rpm librime) rime/build.sh librime" "$(librime_rpm librime-lua) rime/build.sh librime" \
  "$(librime_rpm librime-octagram) rime/build.sh librime"; do
  read -r rpm build <<<"$b"
  # shellcheck disable=SC2086  # word-split: a script and its arguments
  [[ -f $rpm ]] || ./$build >/dev/null || { echo "preflight: pc/linux/$build failed"; exit 1; }
  rpm2cpio "$rpm" | (cd "$own" && cpio -idm --quiet) || { echo "preflight: can't unpack $rpm"; exit 1; }
done
own_fcitx=(bwrap --dev-bind / / --ro-bind "$own/usr/lib64/fcitx5/librime.so" /usr/lib64/fcitx5/librime.so
  --ro-bind "$own/usr/lib64/librime.so.$LIBRIME_VERSION" "/usr/lib64/librime.so.$LIBRIME_VERSION"
  --ro-bind "$own/usr/lib64/rime-plugins" /usr/lib64/rime-plugins
  --ro-bind "$own/usr/lib64/fcitx5/fcitx5-mozc.so" /usr/lib64/fcitx5/fcitx5-mozc.so
  --ro-bind "$own/usr/libexec/fcitx5-mozc" /usr/libexec/fcitx5-mozc)

check shellcheck uvx --from shellcheck-py shellcheck -x setup-ime.sh test-setup-ime.sh mozc/build.sh rime/build.sh

# Live dry run: must not touch the account, and on a set-up PC only the agreed cleanups remain (and
# SebType's fcitx5-mozc and fcitx5-rime, until the user says yes to their sudo install; the typo keyboard
# line, #46; #92/#93's Win+Space toggle, 日本語 and English names and Japanese's menu icon; and #102/#117's
# Chinese data and Alt+` keymap, until setup reruns).
live_dry() {
  local before after
  before=$(find ~/.config/kwinrc ~/.config/kdeglobals ~/.config/environment.d ~/.config/fcitx5/config ~/.config/mozc/config1.db ~/.local/share/applications ~/.local/share/flatpak/overrides \
    ~/.local/share/icons/SebType ~/.local/share/sebtype ~/.local/share/fcitx5/inputmethod ~/.local/share/fcitx5/rime/rime_ice.custom.yaml -type f -exec md5sum {} + 2>/dev/null | sort)
  timeout 60 ./setup-ime.sh --dry-run | tee /dev/stderr | grep '^would:' | grep -v -e 'unused Flatpak override' -e "with SebType's build" -e 'install SebType Configurator' -e 'typo correction to a PC keyboard' \
    -e "install SebType's Chinese data" -e "set Mozc's keymap" -e '^would: install packages librime-octagram ' \
    -e 'English ⇄ the last other language' -e 'install SebType.s tray icons' -e '^would: name \(mozc 日本語\|keyboard-us English\) ' && return 1
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
# fcitx5-mozc is installed only when $FAKE/fcitx5-mozc holds its version-release; fcitx5-rime is
# installed, as $FAKE/fcitx5-rime's version-release once that file exists, and not while it is empty. The fake sudo logs and applies
# dnf's install of SebType's RPMs and their distro-sync back to Fedora's.
stub rpm 'p=${*: -1}; [[ $p == fcitx5-mozc || -f $FAKE/$p ]] || exit 0; [[ -s $FAKE/$p ]] || exit 1; [[ $2 == --qf ]] && cat "$FAKE/$p"; true'
stub sudo "echo \"sudo \$*\" >> \"\$FAKE/sudo.log\"
case \"\$*\" in
  'dnf install -y '*/$MOZC_RPM) echo -n '$MOZC_VERSION-$SEBTYPE_RELEASE' > \"\$FAKE/fcitx5-mozc\" ;;
  'dnf install -y '*/$RIME_RPM) echo -n '$RIME_VERSION-$RIME_SEBTYPE_RELEASE' > \"\$FAKE/fcitx5-rime\" ;;
  'dnf distro-sync -y fcitx5-mozc') echo -n '$MOZC_VERSION-$MOZC_FEDORA_RELEASE' > \"\$FAKE/fcitx5-mozc\" ;;
  'dnf distro-sync -y fcitx5-rime') echo -n '$RIME_VERSION-$RIME_FEDORA_RELEASE' > \"\$FAKE/fcitx5-rime\" ;;
  'dnf install -y '*/librime-*) for r in \"\${@:4}\"; do p=\${r##*/}; echo -n '$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE' > \"\$FAKE/\${p%-$LIBRIME_VERSION-*}\"; done ;;
  'dnf install -y librime-octagram') echo -n '$LIBRIME_VERSION-$LIBRIME_FEDORA_RELEASE' > \"\$FAKE/librime-octagram\" ;;
  'dnf distro-sync -y librime '*) for p in \"\${@:4}\"; do echo -n '$LIBRIME_VERSION-$LIBRIME_FEDORA_RELEASE' > \"\$FAKE/\$p\"; done ;;
esac"
stub systemctl 'cat "$FAKE/session-env" 2>/dev/null; true'
stub flatpak 'exit 1'
stub pgrep 'exit 1'  # never finds (and stops) the real mozc_server
stub qdbus6 'echo "qdbus $*" >> "$FAKE/qdbus.log"'
stub busctl 'case "$*" in
  *" emit "*) echo "$*" >> "$FAKE/emit.log" ;;
  *SetConfig*) echo "$*" >> "$FAKE/deploy.log" ;;
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
# setup-ime.sh rebuilds the Configurator with cargo when its sources are newer, so cargo needs this
# account's Rust (rustup's toolchains) even though the fake account has its own HOME.
fake_run() { mkdir -p "$h/.cache/sebtype"; ln -sf "${rime_zips[@]}" "$h/.cache/sebtype/"
  env -i PATH="$fake/bin:$PATH" HOME="$h" FAKE="$fake" XDG_CONFIG_HOME="$h/.config" \
  XDG_DATA_HOME="$h/.local/share" CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" \
  timeout 60 ./setup-ime.sh "$@"; }

fresh_dry() {
  local o; o=$(fake_run --dry-run < /dev/null) || return 1; echo "$o"
  [[ $(grep -c '^would:' <<<"$o") == 16 ]] && grep -q 'QT_IM_MODULE=fcitx$' <<<"$(grep warning <<<"$o")" &&
    [[ ! -e $h/.config/kwinrc && ! -e $fake/kga.log && ! -e $fake/deploy.log && $(wc -c < "$h/.config/mozc/config1.db") == 11 && ! -e $h/.config/environment.d && -f $h/.local/share/flatpak/overrides/com.qq.QQ ]]
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
    grep -qx 'Name=日本語' "$h/.local/share/fcitx5/inputmethod/mozc.conf" &&
    grep -qx 'Name=English' "$h/.local/share/fcitx5/inputmethod/keyboard-us.conf" &&
    grep -q '^  schema/name: ".中文"' "$h/.local/share/fcitx5/rime/rime_ice.custom.yaml" &&
    grep -q '^  sebtype_typo/keyboard: pc' "$h/.local/share/fcitx5/rime/rime_ice.custom.yaml" &&
    [[ -f $h/.local/share/fcitx5/rime/lua/sebtype_typo.lua && -f $h/.local/share/fcitx5/rime/sebtype-data.txt ]] && grep -q 'setForeignShortcutKeys asa(ai) 4 kwin .* 1 4 268435552 0 0 0$' "$fake/kga.log" && configurator && rime_data
}
# The Configurator is in the app menu, starts this account's copy of the build, and has the pig icon.
configurator() {
  local d=$h/.local/share
  cmp ../configurator/target/release/sebtype-configurator "$d/sebtype/configurator/sebtype-configurator" &&
    grep -qx "Exec=$d/sebtype/configurator/sebtype-configurator" "$d/applications/sebtype-configurator.desktop" &&
    desktop-file-validate "$d/applications/sebtype-configurator.desktop" &&
    [[ -f $d/icons/hicolor/192x192/apps/sebtype-configurator.png ]]
}
# Super+Space is the only switch (the trigger key, no enumerating), all windows share one state, the
# other settings stay, and Fcitx5 reloaded it.
fcitx_hotkeys() {
  local c=$h/.config/fcitx5/config
  [[ $(sed -n '/^\[Hotkey\/TriggerKeys\]/,/^$/p' "$c") == $'[Hotkey/TriggerKeys]\n0=Super+space' ]] &&
    ! grep -qE 'Shift_L|^\[Hotkey/(EnumerateForward|AltTrigger)Keys' "$c" && grep -qx 'AltTriggerKeys=' "$c" &&
    grep -qx 'EnumerateForwardKeys=' "$c" && [[ $(grep -c '^EnumerateWithTriggerKeys=' "$c") == 1 ]] &&
    grep -qx 'EnumerateWithTriggerKeys=False' "$c" &&
    grep -qx 'EnumerateGroupForwardKeys=' "$c" && grep -qx 'ActiveByDefault=False' "$c" &&
    [[ $(grep -c '^ShareInputState=' "$c") == 1 ]] && grep -qx 'ShareInputState=All' "$c" &&
    ls "$h"/.local/share/sebtype/backup/*/config && [[ -e $fake/reload.log ]]
}
# SebType's Chinese data is in Rime's user folder with its marker, and the running Fcitx5 was asked to deploy.
rime_data() {
  local r=$h/.local/share/fcitx5/rime
  [[ $(cat "$r/sebtype-data.txt") == "$(sha256sum "$rime_data" | cut -d' ' -f1)" && -f $r/build/rime_ice.table.bin ]] &&
    ! ls "$r"/double_pinyin* "$r"/t9* 2>/dev/null &&
    [[ $(cat "$fake/deploy.log") == '--user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetConfig sv fcitx://config/addon/rime/deploy s ' ]]
}
# The keymap replaces fields 41 and 42 in place; fields 1 and 43 are kept. Alt+` switches あ ⇄ ア
# (Precomposition), and nothing else: the Shift tap is the only way to English (#117).
mozc_keymap() {
  local db=$h/.config/mozc/config1.db
  cmp <(head -c 9 "$db") <(printf '\x0a\x02\x08\x01\xc8\x02\x00\xd2\x02') &&
    cmp <(tail -c 4 "$db") <(printf '\xda\x02\x01x') && grep -qF $'Precomposition\tAlt `\tInputModeSwitchKanaType' "$db" &&
    [[ $(grep -caF 'Alt `' "$db") == 1 ]] &&
    ls "$h"/.local/share/sebtype/backup/*/config1.db
}
# SebType's icon theme inherits the theme that was active, holds every Fcitx5 status name at each size,
# is active, and the running apps were told.
tray_icons() {
  local t=$h/.local/share/icons/SebType d n
  [[ $(kreadconfig6 --file "$h/.config/kdeglobals" --group Icons --key Theme) == SebType ]] &&
    grep -qx 'Inherits=Fluent-dark' "$t/index.theme" && grep -q iconChanged "$fake/emit.log" || return 1
  for d in 16 20 22 24 32 scalable; do
    for n in input-keyboard:en fcitx-rime:zh fcitx_rime_latin:zh-a fcitx_rime_latin_upper:zh-A fcitx_mozc:hira fcitx_mozc_hiragana:hira \
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

# --undo-names removes the three renamed input method entries and the 中文 schema name, keeping the
# typo keyboard line; a second undo changes nothing, and setup names them again.
undo_names() {
  local d=$h/.local/share/fcitx5 o
  o=$(fake_run --undo-names < /dev/null) || return 1; echo "$o"
  [[ $(grep -c '^change:' <<<"$o") == 4 && ! -e $d/inputmethod/rime.conf && ! -e $d/inputmethod/mozc.conf &&
    ! -e $d/inputmethod/keyboard-us.conf ]] && ! grep -q 'schema/name' "$d/rime/rime_ice.custom.yaml" &&
    grep -q '^  sebtype_typo/keyboard: pc' "$d/rime/rime_ice.custom.yaml" &&
    o=$(fake_run --undo-names < /dev/null) && [[ -z $o ]] &&
    o=$(fake_run < /dev/null) && [[ $(grep -c '^change: \(label Chinese\|name mozc 日本語\|name keyboard-us English\)' <<<"$o") == 3 ]] &&
    grep -qx 'Name=日本語' "$d/inputmethod/mozc.conf" && grep -q '^  schema/name: ".中文"' "$d/rime/rime_ice.custom.yaml"
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
# can't see it) running SebType's Mozc on a second fake account set up by setup-ime.sh: Shift tap toggles
# あ ⇄ English in every Mozc state, Shift+K and Ctrl+Shift don't, and Alt+` toggles あ ⇄ ア and leaves
# English alone (#117); the tray (a stand-in for Plasma's kimpanel on that bus) gets the icon of each mode. Caps Lock (A) has no D-Bus way in: it is
# checked on the desktop (pc/linux/README.md). Its fcitx5 and
# mozc_server are found by the fake HOME in their environment and stopped afterwards.
mozc_keys() {
  local h=$fake/jp
  mkdir -p "$h/.config/fcitx5"
  fake_run < /dev/null > /dev/null || return 1
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=mozc\n\n[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n[Groups/0/Items/1]\nName=mozc\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  env -i PATH="$PATH" HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR-}" timeout 60 "${own_fcitx[@]}" dbus-run-session -- python3 - "$fake/fcitx5.log" <<'PY'
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
def mode():  # 'あ' or 'ア' when "a" starts a kana preedit (then cleared), 'A' when it goes to the app
    if tap('a'):
        got = preedit[0] if preedit[0] in ('あ', 'ア') else f'preedit {preedit[0]!r}'
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
chord('Alt_L', 'grave'); check('Alt+` is ア', (mode(), tray[0]), ('ア', 'fcitx_mozc_katakana_full'))
shift_tap(); check('Shift tap in ア turns English on', mode(), 'A')
chord('Alt_L', 'grave'); check('Alt+` in English stays English', mode(), 'A')
shift_tap(); check('Shift tap in English is ア again', mode(), 'ア')
chord('Alt_L', 'grave'); check('Alt+` is あ again', (mode(), tray[0]), ('あ', 'fcitx_mozc_hiragana'))
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

# Chinese label (#69) and SebType's Chinese data (#102): a private Fcitx5 (as above) running SebType's Rime on a
# third fake account set up by setup-ime.sh, which installs SebType's Chinese data there. Switching to it
# must show 中文 in the popup, both the long one and the compact one (the reference PC's setting; it shows
# the label the tray text uses), and the schema id must stay rime_ice. The same Fcitx5 checks the
# Ctrl+Shift+F key (#36): 后来 comes out as 後來 and back, and Ctrl+F reaches the app; and typo correction
# (#46) with a PC keyboard: xoaoshi (o for its neighbour i) gives 小时 first, and so does xkaoshi (k for
# the i above it), which only SebType's librime corrects (#101), and nihap (p for o) 你好 (#135); and the
# grammar plugin (#127): beirendingwei gives 被认定为, not 被人定位 as without the grammar file.
rime_label() {
  local h=$fake/zh r
  r=$h/.local/share/fcitx5/rime
  mkdir -p "$h/.config/fcitx5" "$r"
  printf 'patch:\n  schema_list: [{schema: rime_ice}]\n' > "$r/default.custom.yaml"
  printf 'patch:\n  menu/page_size: 6\n' > "$r/rime_ice.custom.yaml"
  fake_run < /dev/null > /dev/null || return 1
  grep -qx '  menu/page_size: 6' "$r/rime_ice.custom.yaml" || { echo "rime_ice.custom.yaml lost its patch"; return 1; }
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=keyboard-us\n\n[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n[Groups/0/Items/1]\nName=rime\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  env -i PATH="$PATH" HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR-}" timeout 90 "${own_fcitx[@]}" dbus-run-session -- python3 - "$fake/fcitx5-rime.log" "$r" "$h/.config/fcitx5/config" <<'PY'
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
KEYS = {'Shift_L': (0xffe1, 50), 'Control_L': (0xffe3, 37), 'space': (0x20, 65), 'Escape': (0xff1b, 9),
        'F': (0x46, 41), **{c: (ord(c), code) for row, first in (('qwertyuiop', 24), ('asdfghjkl', 38), ('zxcvbnm', 52))
                            for code, c in enumerate(row, first)}}
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
def first(keys):  # types keys, picks the first candidate, returns what was committed
    committed.clear()
    for c in keys: tap(c)
    tap('space'); wait(lambda: committed, 2)
    return ''.join(committed)
houlai = lambda: first('houlai')
preedit = ['']
def on_preedit(_c, _s, _p, _i, name, params):
    if name == 'UpdateFormattedPreedit': preedit[0] = ''.join(s for s, _ in params.unpack()[0])
bus.signal_subscribe(None, IC, None, ic, None, 0, on_preedit)
def rime_ready():  # Rime deploys on first use and takes no keys until then: n shows a preedit once it does
    tap('n'); ready = wait(lambda: preedit[0] == 'n', 0.5); tap('Escape'); return ready

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
check('Rime deployed', wait(rime_ready, 60), True)
check('long popup reads 中文', switch(), '中文')
with open(sys.argv[3], 'a') as f: f.write('\n[Behavior]\nCompactInputMethodInformation=True\n')
call(*CONTROLLER, 'ReloadConfig')
check('compact popup reads 中文', switch(), '中文')
schema = lambda: call('/rime', 'org.fcitx.Fcitx.Rime1', 'GetCurrentSchema')[0]
wait(lambda: schema(), 30)  # the reload reloads Rime, which loads rime-ice's tables again
check('schema id stays rime_ice', schema(), 'rime_ice')
check('simplified at first', houlai(), '后来')
check('Ctrl+Shift+F is taken', ctrl('F', shift=True), True)
check('traditional after Ctrl+Shift+F', houlai(), '後來')
ctrl('f', shift=True)  # Shift may send the lowercase keysym
check('simplified after the second Ctrl+Shift+F', houlai(), '后来')
check('Ctrl+F reaches the app', ctrl('f'), False)
check('typo xoaoshi gives 小时 first', first('xoaoshi'), '小时')
check('typo xkaoshi (k under i, SebType librime) gives 小时 first', first('xkaoshi'), '小时')
check('typo nihap (p beside o) gives 你好 first', first('nihap'), '你好')
check('beirendingwei gives 被认定为 first (the grammar file; without it 被人定位)', first('beirendingwei'), '被认定为')
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

# Win+Space and the tray menu (#92, #93, #117): a private Fcitx5 (as above) with English and SebType's
# Rime (SebType's Chinese data) and Mozc on a fourth fake account set up by setup-ime.sh, and a stand-in
# for Plasma's tray (a StatusNotifierWatcher on that bus) that reads and clicks Fcitx5's menu. The menu
# reads English · 中文 · 日本語 with SebType's icon names, then the active language's one switch with its
# key (中文 简 → 繁, 日本語 あ → ア, English none), which a click flips, then Fcitx5's own items; Win+Space toggles English and the last other language, also
# while Super stays held; a menu pick becomes the one Win+Space returns to; Rime's Shift tap still
# switches its English mode, and a Shift tap in English switches nothing.
win_space() {
  local h=$fake/menu
  mkdir -p "$h/.config/fcitx5"
  fake_run < /dev/null > /dev/null || return 1
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=keyboard-us\n\n[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n[Groups/0/Items/1]\nName=rime\nLayout=\n\n[Groups/0/Items/2]\nName=mozc\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  env -i PATH="$PATH" HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR-}" timeout 120 "${own_fcitx[@]}" dbus-run-session -- python3 -W ignore - "$fake/fcitx5-menu.log" <<'PY'
import subprocess, sys, time
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION)
WATCHER = Gio.DBusNodeInfo.new_for_xml("""<node><interface name="org.kde.StatusNotifierWatcher">
  <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
  <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
  <property name="ProtocolVersion" type="i" access="read"/></interface></node>""").interfaces[0]
items = []
def on_method(_c, sender, _p, _i, _name, _params, inv):
    items.append(sender); inv.return_value(None)
def on_prop(_c, _s, _p, _i, name):
    return GLib.Variant('b', True) if name == 'IsStatusNotifierHostRegistered' else GLib.Variant('i', 0)
bus.register_object('/StatusNotifierWatcher', WATCHER, on_method, on_prop, None)
Gio.bus_own_name_on_connection(bus, 'org.kde.StatusNotifierWatcher', 0, None, None)
# classicui is what turns the tray item (notificationitem) on.
fcitx = subprocess.Popen(['fcitx5', '-k', '--disable=all', '--enable=dbus,dbusfrontend,keyboard,rime,mozc,classicui,notificationitem'],
                         stdout=subprocess.DEVNULL, stderr=open(sys.argv[1], 'w'))
def wait(cond, secs):  # cond may type a key, so it runs once per try: asking again after a hit would undo it
    end = time.time() + secs
    while True:
        if cond(): return True
        if time.time() >= end: return False
        GLib.MainContext.default().iteration(False); time.sleep(0.01)
def call(dest, path, iface, method, sig=None, *args):  # never D-Bus-activates a second, default Fcitx5
    return bus.call_sync(dest, path, iface, method, GLib.Variant(sig, args) if sig else None,
                         None, Gio.DBusCallFlags.NO_AUTO_START, 10000, None).unpack()
FCITX, IC, MENU = 'org.fcitx.Fcitx5', 'org.fcitx.Fcitx.InputContext1', 'com.canonical.dbusmenu'
CONTROLLER = (FCITX, '/controller', 'org.fcitx.Fcitx.Controller1')
def up():
    try: call(*CONTROLLER, 'CurrentInputMethod'); return True
    except GLib.Error: return False
wait(up, 10)
ic, _ = call(FCITX, '/org/freedesktop/portal/inputmethod', 'org.fcitx.Fcitx.InputMethod1', 'CreateInputContext',
             '(a(ss))', [('program', 'sebtype-test')])
preedit = ['']
def on_preedit(_c, _s, _p, _i, name, params):
    if name == 'UpdateFormattedPreedit': preedit[0] = ''.join(s for s, _ in params.unpack()[0])
bus.signal_subscribe(None, IC, None, ic, None, 0, on_preedit)
call(FCITX, ic, IC, 'SetCapability', '(t)', 1 << 1 | 1 << 4 | 1 << 39)
call(FCITX, ic, IC, 'FocusIn')
SUPER, SHIFT = 0x40, 1
im = lambda: call(*CONTROLLER, 'CurrentInputMethod')[0]
def key(sym, code, state=0, release=False):
    call(FCITX, ic, IC, 'ProcessKeyEvent', '(uuubu)', sym, code, state, release, 0)
    wait(lambda: False, 0.05)
def win_space(taps=1):  # Super held, Space tapped
    key(0xffeb, 133)
    for _ in range(taps): key(0x20, 65, SUPER); key(0x20, 65, SUPER, True)
    key(0xffeb, 133, SUPER, True)
    return im()
def shift_tap():
    key(0xffe1, 50); key(0xffe1, 50, SHIFT, True)
NAMES = {'keyboard-us': 'English', 'rime': '中文', 'mozc': '日本語'}

ok = True
def check(name, got, want):
    global ok
    ok &= got == want
    print('PASS' if got == want else 'FAIL', name, '' if got == want else f'got {got!r}, want {want!r}')

check('tray item registered', bool(wait(lambda: items, 10)), True)
sni = items[0]
menu = call(sni, '/StatusNotifierItem', 'org.freedesktop.DBus.Properties', 'Get', '(ss)', 'org.kde.StatusNotifierItem', 'Menu')[0]
def menu_items():  # (id, properties) of the menu's items
    call(sni, menu, MENU, 'AboutToShow', '(i)', 0); wait(lambda: False, 0.2)
    return [(i, p) for i, p, _ in call(sni, menu, MENU, 'GetLayout', '(iias)', 0, 1, [])[1][2]]
def entries():  # (id, label, icon) of the menu's input methods: the items with a radio mark
    return [(i, p.get('label'), p.get('icon-name')) for i, p in menu_items() if 'toggle-state' in p]
LANGUAGES, FCITX_OWN = ['English', '中文', '日本語', '-'], ['Restart', 'Input Method Settings', 'Exit']
def switches():  # labels between the input methods and Fcitx5's own items, '-' for a separator
    labels = [p.get('label', '-') for _, p in menu_items()]
    if labels[:4] != LANGUAGES or labels[-3:] != FCITX_OWN: return f'menu {labels!r}'
    return labels[4:-3]
def click(label):  # clicks a menu item, returns the switches after it
    i = next(i for i, p in menu_items() if p.get('label') == label)
    call(sni, menu, MENU, 'Event', '(isvu)', i, 'clicked', GLib.Variant('i', 0), 0)
    wait(lambda: False, 0.3)
    return switches()
def pick(name):  # clicks the input method in the tray menu
    i = next(i for i, label, _ in entries() if label == NAMES[name])
    call(sni, menu, MENU, 'Event', '(isvu)', i, 'clicked', GLib.Variant('i', 0), 0)
    wait(lambda: im() == name, 2)
    return im()

check('menu reads English · 中文 · 日本語 with SebType icon names', [e[1:] for e in entries()],
      [('English', 'input-keyboard'), ('中文', 'fcitx-rime'), ('日本語', 'fcitx_mozc')])
check('starts in English', im(), 'keyboard-us')
check('English has no switch in the menu', switches(), [])
shift_tap(); check('Shift tap in English switches nothing', im(), 'keyboard-us')
check('Win+Space goes to 中文', win_space(), 'rime')
check('Win+Space is English again', win_space(), 'keyboard-us')
check('Win+Space twice with Super held toggles there and back', win_space(2), 'keyboard-us')
check('menu picks 日本語', pick('mozc'), 'mozc')
check('Win+Space from 日本語 is English', win_space(), 'keyboard-us')
check('Win+Space returns to 日本語', win_space(), 'mozc')
check('menu picks 中文', pick('rime'), 'rime')
check('Win+Space from 中文 is English', win_space(), 'keyboard-us')
check('Win+Space returns to 中文', win_space(), 'rime')
pick('mozc'); pick('keyboard-us')
check('after picking 日本語 then English, Win+Space returns to 日本語', win_space(), 'mozc')
KANA, HIRA = 'あ → ア\tAlt+`', 'ア → あ\tAlt+`'
check('日本語 has one switch, あ → ア', switches(), [KANA, '-'])
check('clicking it switches to ア', click(KANA), [HIRA, '-'])
check('clicking again is あ', click(HIRA), [KANA, '-'])
pick('rime')
def rime_ready():  # Rime deploys on first use and takes no keys until then: n shows a preedit once it does
    key(0x6e, 57); key(0x6e, 57, 0, True)
    return wait(lambda: preedit[0] == 'n', 0.5)
check('Rime deployed', wait(rime_ready, 60), True)
key(0xff1b, 9); key(0xff1b, 9, 0, True)
HANT, HANS = '简 → 繁\tCtrl+Shift+F', '繁 → 简\tCtrl+Shift+F'
check('中文 has one switch, 简 → 繁', switches(), [HANT, '-'])
check('clicking it switches to 繁', click(HANT), [HANS, '-'])
check('clicking again is 简', click(HANS), [HANT, '-'])
ascii_mode = lambda: call(FCITX, '/rime', 'org.fcitx.Fcitx.Rime1', 'IsAsciiMode')[0]
shift_tap(); check('Shift tap in 中文 turns its English mode on', (ascii_mode(), im()), (True, 'rime'))
shift_tap(); check('Shift tap again turns it off', (ascii_mode(), im()), (False, 'rime'))
fcitx.terminate(); fcitx.wait(10)
sys.exit(0 if ok else 1)
PY
  local rc=$? p
  for p in $(pgrep -x fcitx5) $(pgrep -x mozc_server); do
    grep -qzx "HOME=$h" "/proc/$p/environ" 2>/dev/null && kill "$p"
  done
  return $rc
}
if command -v fcitx5 dbus-run-session >/dev/null && [[ -f /usr/share/fcitx5/addon/rime.conf && -f /usr/share/fcitx5/addon/mozc.conf ]] &&
  python3 -c 'from gi.repository import Gio' 2>/dev/null; then
  check win-space-and-tray-menu win_space
else result SKIP win-space-and-tray-menu "needs fcitx5, fcitx5-rime, fcitx5-mozc, dbus-run-session and python3-gobject"
fi

rerun() {
  echo 'XMODIFIERS=@im=fcitx' > "$fake/session-env"
  local o; o=$(fake_run < /dev/null) || return 1; echo "$o"
  grep -q '^done: 1 change(s)' <<<"$o" && grep -q 'install packages fcitx5-mozc' <<<"$o"
}
check rerun-only-asks-for-missing-package rerun

# SebType's fcitx5-mozc (#66), fcitx5-rime (#117) and librime (#101) replace Fedora's after a yes, a
# rerun leaves them, --undo-mozc, --undo-rime and --undo-librime bring back Fedora's once, and a package
# of another version is left alone with a warning. The RPMs are placeholders, so nothing is built.
own_swap() { # version Fedora's-release package rpm [package rpm...]: setup checks the first package
  local v=$1 fedora=$2 pkgs=() rpms=() p o
  shift 2
  while (($#)); do pkgs+=("$1"); rpms+=("$2"); shift 2; done
  for o in "${rpms[@]}"; do mkdir -p "${o%/*}"; : > "$o"; done; rm -f "$fake/sudo.log"
  for p in "${pkgs[@]}"; do echo -n "$v-$fedora" > "$fake/$p"; done
  p=${pkgs[0]}
  o=$(echo y | fake_run) || return 1; echo "$o"
  grep -q "^change: replace $p .* with SebType's build" <<<"$o" &&
    [[ $(cat "$fake/sudo.log") == "sudo dnf install -y ${rpms[*]}" && $(cat "$fake/$p") == *.sebtype* ]] || return 1
  o=$(fake_run < /dev/null) || return 1; echo "$o"
  ! grep -q " $p " <<<"$o" || return 1
  o=$(fake_run "--undo-${p#fcitx5-}" < /dev/null) || return 1; echo "$o"
  [[ $(tail -1 "$fake/sudo.log") == "sudo dnf distro-sync -y ${pkgs[*]}" && $(cat "$fake/$p") == "$v-$fedora" ]] &&
    o=$(fake_run "--undo-${p#fcitx5-}" < /dev/null) && [[ -z $o ]] || return 1
  echo -n 9.9.9-1.fc45 > "$fake/$p"
  o=$(fake_run < /dev/null) || return 1; echo "$o"
  grep -q "^warning: $p 9.9.9-1.fc45 isn't the version" <<<"$o" && [[ $(wc -l < "$fake/sudo.log") == 2 ]]
}
check mozc-install-and-undo own_swap "$MOZC_VERSION" "$MOZC_FEDORA_RELEASE" fcitx5-mozc "$h/.cache/sebtype/mozc/rpms/$MOZC_RPM"
check rime-install-and-undo own_swap "$RIME_VERSION" "$RIME_FEDORA_RELEASE" fcitx5-rime "$h/.cache/sebtype/fcitx5-rime/$RIME_RPM"
# librime with its Lua plugin, which must be the same build
check librime-install-and-undo own_swap "$LIBRIME_VERSION" "$LIBRIME_FEDORA_RELEASE" \
  librime "$h/.cache/sebtype/librime/librime-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm" \
  librime-lua "$h/.cache/sebtype/librime/librime-lua-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm" \
  librime-octagram "$h/.cache/sebtype/librime/librime-octagram-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm"
# The grammar plugin (#127): a missing librime-octagram is installed, Fedora's beside Fedora's librime and
# SebType's build beside SebType's (Fedora's requires Fedora's librime).
octagram() {
  local ours=$h/.cache/sebtype/librime/librime-octagram-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm release o
  for release in "$LIBRIME_FEDORA_RELEASE" "$LIBRIME_SEBTYPE_RELEASE"; do
    echo -n "$LIBRIME_VERSION-$release" > "$fake/librime"; : > "$fake/librime-octagram"; rm -f "$fake/sudo.log"
    o=$(echo y | fake_run) || return 1; echo "$o"
    grep -q '^change: install packages librime-octagram ' <<<"$o" || return 1
    if [[ $release == "$LIBRIME_FEDORA_RELEASE" ]]; then [[ $(head -1 "$fake/sudo.log") == 'sudo dnf install -y librime-octagram' ]]
    else [[ $(head -1 "$fake/sudo.log") == "sudo dnf install -y $ours" ]]; fi || return 1
    [[ $(cat "$fake/librime-octagram") == "$LIBRIME_VERSION-$release" ]] || return 1
  done
}
check grammar-plugin-install octagram
check undo-icons-and-reinstall undo_icons
check undo-configurator-and-reinstall undo_configurator
check undo-names-and-rename undo_names

# SebType's Chinese data over an account's own rime-ice (#102): it replaces the files of the same name,
# removes the dictionary source it has a prebuilt table for, and keeps learned words, settings and the
# user's custom_phrase.txt; a rerun changes nothing. --undo-chinese-data leaves Rime's folder exactly as
# it was (the files setup's other steps patch aside), a second undo changes nothing, and setup installs it again.
chinese_data() {
  local h=$fake/data r o before
  r=$h/.local/share/fcitx5/rime
  mkdir -p "$h/.config" "$r/build" "$r/lua" "$r/sync/pc"
  echo 'schema: { schema_id: rime_ice, name: own }' > "$r/rime_ice.schema.yaml"
  echo 'name: rime_ice' > "$r/rime_ice.dict.yaml"
  echo own > "$r/build/rime_ice.table.bin"; echo own > "$r/lua/own.lua"; echo '我的	wd' > "$r/custom_phrase.txt"
  echo learned > "$r/rime_ice.userdb"; echo 'patch: {}' > "$r/rime_ice.custom.yaml"
  snap() { (cd "$r" && find . \( -name '*.custom.yaml' -prune \) -o \( -type d -printf '%p/\n' \) -o -type f -exec md5sum {} + | sort); }
  before=$(snap)
  o=$(fake_run < /dev/null) || return 1; echo "$o"
  grep -q "^change: install SebType's Chinese data" <<<"$o" && grep -q 'corr:' "$r/rime_ice.schema.yaml" &&
    [[ ! -e $r/rime_ice.dict.yaml && -f $r/lua/sebtype_typo.lua && -f $r/lua/own.lua && $(cat "$r/build/rime_ice.table.bin") != own &&
      $(cat "$r/custom_phrase.txt") == '我的	wd' && $(cat "$r/rime_ice.userdb") == learned ]] || return 1
  o=$(fake_run < /dev/null) || return 1; echo "$o"
  ! grep -q 'Chinese data' <<<"$o" || return 1
  o=$(fake_run --undo-chinese-data < /dev/null) || return 1; echo "$o"
  [[ $(grep -c '^change:' <<<"$o") == 1 && $(snap) == "$before" && ! -e $h/.local/share/sebtype/rime-before ]] || { diff <(echo "$before") <(snap); return 1; }
  o=$(fake_run --undo-chinese-data < /dev/null) && [[ -z $o ]] &&
    o=$(fake_run < /dev/null) && grep -q "^change: install SebType's Chinese data" <<<"$o" && [[ -f $r/lua/sebtype_typo.lua ]]
}
check chinese-data-and-undo chinese_data

! grep -q '^FAIL' "$results"
