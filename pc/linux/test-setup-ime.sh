#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub bodies are single-quoted; they expand when the stub runs
# Checks pc/linux/setup-ime.sh: ShellCheck, a read-only --dry-run on this PC, and a full run on a
# fake fresh account (stubbed packages, systemd, Fcitx5 and KWin calls) that must be idempotent.
# Changes nothing in the real session. One line per check in ~/scratch/SebType/<issue>/test-setup-ime-results.txt.
# Check names as arguments run only those (fresh-apply, which the later checks build on, always runs).
# Typing in real apps is the manual checklist in pc/linux/README.md.
set -uo pipefail
script=$(readlink -f "$0")
cd "$(dirname "$script")" || exit 1
# shellcheck source=../../tools/lib.sh
source ../../tools/lib.sh
# Its private Fcitx5 instances run on this PC: one test at a time, in the shared device queue.
[[ -n ${HOLDING-} ]] || exec env HOLDING=1 devq -w 1800 -m 10 -n "sebtype test-setup-ime ($(git branch --show-current))" \
  /tmp/agent-locks/devices/nobara-pc.lock bash "$script" "$@"

out=$TASK_OUT; mkdir -p "$out"
selected=("$@")
results=$out/test-setup-ime-results.txt; : > "$results"
result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
check() { # name, command... (each run of setup-ime.sh has its own timeout)
  local name=$1; shift
  if ((${#selected[@]})) && [[ $name != fresh-apply && " ${selected[*]} " != *" $name "* ]]; then
    result SKIP "$name" "not selected"; return; fi
  if "$@" > "$out/test-setup-ime-$name.log" 2>&1; then result PASS "$name"
  else result FAIL "$name" "see $out/test-setup-ime-$name.log"; fi
}

# Preflight
command -v uvx >/dev/null || { echo "preflight: uvx missing (used to run ShellCheck)"; exit 1; }
command -v kreadconfig6 >/dev/null || { echo "preflight: kreadconfig6 missing (KDE Plasma 6 needed)"; exit 1; }
# The fake account has no Rust: setup-ime.sh copies the Configurator built for it. Nor does it build
# SebType's Chinese data: each fake account's cache links the zip built for it. Both build on yanglab16
# (tools/build.sh), in the shared build lock.
../../tools/build.sh 30 "configurator build for test-setup-ime" pc/configurator/build.sh > /dev/null 2> "$out/test-setup-ime-configurator-build.log" ||
  { echo "preflight: the SebType Configurator does not build (see $out/test-setup-ime-configurator-build.log)"; exit 1; }
rime_data=$(../../tools/build.sh 10 "rime data for test-setup-ime" data/rime/build.sh 2> "$out/test-setup-ime-rime-data.log") &&
  [[ -f $rime_data ]] ||
  { echo "preflight: SebType's Chinese data does not build (see $out/test-setup-ime-rime-data.log)"; exit 1; }
# SebType's input method (#190) and librime (#101), built once and cached. The private Fcitx5s below run them
# without installing them: bwrap mounts them from $own for that Fcitx5 alone (sebtype_run).
# shellcheck source=../../linux/versions.sh
source ../../linux/versions.sh
own=$out/own-builds
sebtype_unpack "$own" || { echo "preflight: linux/build.sh failed"; exit 1; }
sebtype_rpm=$(sebtype_rpm "$(sebtype_key)")  # the RPM setup-ime.sh installs from this tree
librime_unpack "$own" || { echo "preflight: linux/build-librime.sh failed"; exit 1; }
read -ra own_fcitx <<<"$(sebtype_run "$own")"

check shellcheck uvx --from shellcheck-py shellcheck -x setup-ime.sh test-setup-ime.sh perf.sh compare.sh \
  ../../linux/build.sh ../../linux/build-librime.sh ../../linux/build-installer.sh ../../linux/test-rpms.sh

# No two icon files differ only by case: a Windows checkout would keep one of them (#77).
icon_case() { ! git ls-files ../icons | tr '[:upper:]' '[:lower:]' | sort | uniq -d | grep .; }
check icon-names-differ-beyond-case icon_case

# Live dry run: must not touch the account, and on a set-up PC only the agreed cleanups remain (the typo
# keyboard line, #46; #92/#93's Win+Space toggle, 日本語 and English names and Japanese's menu icon; #102/#117's
# Chinese data and Alt+` keymap; #182's add-on hotkeys and the removal of Fcitx5's own settings; and #190's
# input method, its Super+Space and its tray, until setup reruns).
live_dry() {
  local before after
  before=$(find ~/.config/kwinrc ~/.config/kdeglobals ~/.config/environment.d ~/.config/fcitx5/config ~/.config/mozc/config1.db ~/.local/share/applications ~/.local/share/flatpak/overrides \
    ~/.local/share/icons/SebType ~/.local/share/sebtype ~/.local/share/fcitx5/inputmethod ~/.local/share/fcitx5/addon ~/.local/share/fcitx5/rime/rime_ice.custom.yaml -type f -exec md5sum {} + 2>/dev/null | sort)
  timeout 60 ./setup-ime.sh --dry-run | tee /dev/stderr | grep '^would:' | grep -v -e 'unused Flatpak override' -e "with SebType's build" -e 'install SebType Configurator' -e 'typo correction to a PC keyboard' \
    -e "install SebType's Chinese data" -e "set Mozc's keymap" -e '^would: install packages librime-octagram ' \
    -e 'English ⇄ the last other language' -e 'remove the old SebType icon theme' -e '^would: name \(mozc 日本語\|keyboard-us English\) ' \
    -e "turn off Fcitx5's .* hotkeys" -e "^would: remove .*, Fcitx5's own settings" -e "^would: install SebType's input method" \
    -e "^would: show SebType's tray menu" -e '^would: install packages librime-lua' \
    -e "^would: schedule SebType's daily update check" && return 1
  after=$(find ~/.config/kwinrc ~/.config/kdeglobals ~/.config/environment.d ~/.config/fcitx5/config ~/.config/mozc/config1.db ~/.local/share/applications ~/.local/share/flatpak/overrides \
    ~/.local/share/icons/SebType ~/.local/share/sebtype ~/.local/share/fcitx5/inputmethod ~/.local/share/fcitx5/addon ~/.local/share/fcitx5/rime/rime_ice.custom.yaml -type f -exec md5sum {} + 2>/dev/null | sort)
  [[ $before == "$after" ]]
}
check live-dry-run live_dry

# Fake fresh account.
fake=$(mktemp -d "$out/setup-ime-fake.XXXX")
trap 'rm -rf "$fake"' EXIT
mkdir -p "$fake"/{bin,home/.config,home/.local/share/applications,home/.local/share/flatpak/overrides}
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$fake/bin/$1"; chmod +x "$fake/bin/$1"; }
# sebtype (and kcm-fcitx5 and fcitx5-configtool) is installed only when $FAKE/<package> holds its version-release;
# any other package is installed, as $FAKE/<package>'s version-release once that file exists, and not while
# it is empty. The fake sudo logs and applies dnf's install of SebType's RPMs and their distro-sync back to
# Fedora's, and the removal and install of Fcitx5's own settings.
stub rpm 'p=${*: -1}; [[ $p == sebtype || $p == kcm-fcitx5 || $p == fcitx5-configtool || -f $FAKE/$p ]] || exit 0; [[ -s $FAKE/$p ]] || exit 1; [[ $2 == --qf ]] && cat "$FAKE/$p"; true'
stub sudo "echo \"sudo \$*\" >> \"\$FAKE/sudo.log\"
case \"\$*\" in
  'dnf install -y '*/sebtype-$SEBTYPE_VERSION-*) echo -n '$SEBTYPE_VERSION-$SEBTYPE_RPM_RELEASE' > \"\$FAKE/sebtype\" ;;
  'dnf install -y '*/librime-*) for r in \"\${@:4}\"; do p=\${r##*/}; echo -n '$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE' > \"\$FAKE/\${p%-$LIBRIME_VERSION-*}\"; done ;;
  'dnf remove -y '*) for p in \"\${@:4}\"; do : > \"\$FAKE/\$p\"; done ;;
  'dnf install -y kcm-fcitx5'*|'dnf install -y fcitx5-configtool'*) for p in \"\${@:4}\"; do echo -n 5.1.16-1.fc44 > \"\$FAKE/\$p\"; done ;;
  'dnf install -y librime-octagram') echo -n '$LIBRIME_VERSION-$LIBRIME_FEDORA_RELEASE' > \"\$FAKE/librime-octagram\" ;;
  'dnf distro-sync -y librime '*) for p in \"\${@:4}\"; do echo -n '$LIBRIME_VERSION-$LIBRIME_FEDORA_RELEASE' > \"\$FAKE/\$p\"; done ;;
esac"
stub systemctl 'echo "systemctl $*" >> "$FAKE/systemctl.log"; cat "$FAKE/session-env" 2>/dev/null; true'
stub flatpak 'exit 1'
stub qdbus6 'echo "qdbus $*" >> "$FAKE/qdbus.log"'
stub busctl 'case "$*" in
  *" emit "*) echo "$*" >> "$FAKE/emit.log" ;;
  *SetConfig*) echo "$*" >> "$FAKE/deploy.log" ;;
  *status*) [[ ! -e $FAKE/no-fcitx ]] ;;
  *setForeignShortcutKeys*) echo "$*" > "$FAKE/kga.log" ;;
  *shortcutKeys*) if [[ -e $FAKE/kga.log ]]; then echo "a(ai) 1 4 268435552 0 0 0"
    else echo "a(ai) 2 4 268435552 0 0 0 4 134217824 0 0 0"; fi ;;
  *ReloadConfig*) echo reload >> "$FAKE/reload.log" ;;
  *AvailableInputMethods*) echo "a(ssssssb) 2 \"keyboard-us\" \"English\" \"\" \"\" \"\" \"en\" false \"sebtype\" \"SebType\" \"\" \"\" \"\" \"\" false" ;;
  *SetInputMethodGroupInfo*) echo "$*" > "$FAKE/set.log"
    echo "sa(ss) \"us\" 1 \"sebtype\" \"\"" > "$FAKE/group" ;;
  *SetCurrentIM*) echo "$*" >> "$FAKE/current-im.log" ;;
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
# The fake account has no Rust either: the Configurator built above is newer than its sources, so
# setup-ime.sh doesn't rebuild it.
fake_run() { mkdir -p "$h/scratch/SebType/cache/sebtype"; ln -sf "$rime_data" "$h/scratch/SebType/cache/"
  touch "$h/scratch/SebType/cache/sebtype/${sebtype_rpm##*/}"  # a placeholder: the fake sudo installs nothing
  env -i PATH="$fake/bin:$PATH" HOME="$h" FAKE="$fake" XDG_CONFIG_HOME="$h/.config" \
  XDG_DATA_HOME="$h/.local/share" timeout 60 ./setup-ime.sh "$@"; }

fresh_dry() {
  local o; o=$(fake_run --dry-run < /dev/null) || return 1; echo "$o"
  [[ $(grep -c '^would:' <<<"$o") == 21 ]] && grep -q 'QT_IM_MODULE=fcitx$' <<<"$(grep warning <<<"$o")" &&
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
    grep -q 'Default us 1 sebtype $' "$fake/set.log" && grep -q 'SetCurrentIM s sebtype$' "$fake/current-im.log" &&
    grep -qx 'systemctl --user set-environment XMODIFIERS=@im=fcitx' "$fake/systemctl.log" && [[ ! -e $fake/sudo.log ]] &&
    cmp ../../linux/data/notificationitem.conf "$h/.local/share/fcitx5/addon/notificationitem.conf" &&
    fcitx_hotkeys && mozc_keymap && tray_icons && grep -qx 'Label=中文' "$h/.local/share/fcitx5/inputmethod/rime.conf" &&
    grep -qx 'Name=日本語' "$h/.local/share/fcitx5/inputmethod/mozc.conf" &&
    grep -qx 'Name=English' "$h/.local/share/fcitx5/inputmethod/keyboard-us.conf" &&
    grep -q '^  schema/name: ".中文"' "$h/.local/share/fcitx5/rime/rime_ice.custom.yaml" &&
    grep -q '^  sebtype_typo/keyboard: pc' "$h/.local/share/fcitx5/rime/rime_ice.custom.yaml" &&
    grep -q '^  menu/page_size: 6 ' "$h/.local/share/fcitx5/rime/default.custom.yaml" &&
    [[ -f $h/.local/share/fcitx5/rime/lua/sebtype_typo.lua && -f $h/.local/share/fcitx5/rime/sebtype-data.txt ]] && grep -q 'setForeignShortcutKeys asa(ai) 4 kwin .* 1 4 268435552 0 0 0$' "$fake/kga.log" && configurator && rime_data
}
# The Configurator is in the app menu, starts this account's copy of the build, and has the pig icon.
configurator() {
  local d=$h/.local/share
  cmp ../configurator/target/release/sebtype-configurator "$d/sebtype/configurator/sebtype-configurator" &&
    grep -qx "Exec=$d/sebtype/configurator/sebtype-configurator" "$d/applications/sebtype-configurator.desktop" &&
    desktop-file-validate "$d/applications/sebtype-configurator.desktop" &&
    [[ -f $d/icons/hicolor/192x192/apps/sebtype-configurator.png ]] &&
    # the daily update check (#422)
    grep -qx "ExecStart=\"$d/sebtype/configurator/sebtype-configurator\" --check-updates" "$h/.config/systemd/user/sebtype-update.service" &&
    grep -qx 'OnCalendar=daily' "$h/.config/systemd/user/sebtype-update.timer"
}
# Fcitx5's own switchers are empty, so Super+Space reaches SebType's input method (#190), all windows share
# one state, the other settings stay, Fcitx5's clipboard, Unicode and quick phrase hotkeys are empty, and Fcitx5 reloaded it.
fcitx_hotkeys() {
  local c=$h/.config/fcitx5/config
  grep -qx 'TriggerKeys=' "$c" && ! grep -q 'Super+space' "$c" &&
    ! grep -qE 'Shift_L|^\[Hotkey/(EnumerateForward|AltTrigger|Trigger)Keys' "$c" && grep -qx 'AltTriggerKeys=' "$c" &&
    grep -qx 'EnumerateForwardKeys=' "$c" && [[ $(grep -c '^EnumerateWithTriggerKeys=' "$c") == 1 ]] &&
    grep -qx 'EnumerateWithTriggerKeys=False' "$c" &&
    grep -qx 'EnumerateGroupForwardKeys=' "$c" && grep -qx 'ActiveByDefault=False' "$c" &&
    [[ $(grep -c '^ShareInputState=' "$c") == 1 ]] && grep -qx 'ShareInputState=All' "$c" &&
    grep -qx 'TriggerKey=' "${c%/*}/conf/clipboard.conf" && grep -qx 'TriggerKey=' "${c%/*}/conf/quickphrase.conf" &&
    [[ $(grep -cxE 'TriggerKey=|DirectUnicodeMode=' "${c%/*}/conf/unicode.conf") == 2 ]] &&
    ls "$h"/.local/share/sebtype/backup/*/config && [[ -e $fake/reload.log ]]
}
# SebType's Chinese data is in Rime's user folder with its marker, and the running Fcitx5 was asked to restart
# Mozc (for its new keymap) and to deploy.
rime_data() {
  local r=$h/.local/share/fcitx5/rime
  [[ $(cat "$r/sebtype-data.txt") == "$(sha256sum "$rime_data" | cut -d' ' -f1)" && -f $r/build/rime_ice.table.bin ]] &&
    ! ls "$r"/double_pinyin* "$r"/t9* 2>/dev/null &&
    [[ $(cat "$fake/deploy.log") == "$(printf '%s\n' \
      '--user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetConfig sv fcitx://config/addon/sebtype/mozc s ' \
      '--user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetConfig sv fcitx://config/addon/sebtype/deploy s ')" ]]
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
# Setup leaves the icon theme alone (#278): the tray icons come with SebType's RPM, in hicolor.
tray_icons() {
  [[ $(kreadconfig6 --file "$h/.config/kdeglobals" --group Icons --key Theme) == Fluent-dark &&
    ! -e $h/.local/share/icons/SebType && ! -e $fake/emit.log ]]
}
# The RPM has every icon the add-on asks for (sebtype-<state>, the states of pc/icons) at each hicolor size.
rpm_icons() {
  local p n
  for p in 16:16x16 22:22x22 24:24x24 32:32x32 48:48x48 64:64x64 32:16x16@2 44:22x22@2 48:24x24@2 64:32x32@2 \
    scalable:scalable; do
    for n in en zh zh-a zh-caps hira kata ja-a ja-caps zh-wait zh-off hira-wait hira-off; do
      [[ ${p%%:*} == scalable ]] && n=$n.svg || n=$n.png
      cmp "../icons/${p%%:*}/$n" "$own/usr/share/icons/hicolor/${p#*:}/status/sebtype-$n" || return 1
    done
  done
}
check rpm-has-tray-icons rpm_icons
check fresh-apply fresh_apply

# A page size of the user's own (as the Configurator writes it) stays when setup runs again (#163).
page_size_kept() {
  local f=$h/.local/share/fcitx5/rime/default.custom.yaml o
  sed -i 's|^  menu/page_size: .*|  menu/page_size: 8|' "$f"
  o=$(fake_run < /dev/null) || return 1; echo "$o"
  ! grep -q 'candidates per page' <<<"$o" && [[ $(grep -c '^  menu/page_size:' "$f") == 1 ]] && grep -qx '  menu/page_size: 8' "$f"
}
check page-size-kept page_size_kept

# Upgrade from the icon theme of an older setup (#278): the theme goes, and the theme it inherits is active
# again; without an Inherits line the Theme key goes; a theme the user picked since stays. A rerun changes nothing.
old_icon_theme() {
  local t=$h/.local/share/icons/SebType g=$h/.config/kdeglobals o inherits want
  for inherits in Fluent-dark '' picked; do
    rm -f "$fake/emit.log"; mkdir -p "$t/16/status"; : > "$t/16/status/sebtype-en.svg"
    { printf '[Icon Theme]\nName=SebType\n'; [[ -n $inherits ]] && printf 'Inherits=%s\n' "$inherits"; } > "$t/index.theme"
    printf '[General]\nColorScheme=BreezeDark\n\n[Icons]\nTheme=SebType\n' > "$g"
    want=$inherits
    if [[ $inherits == picked ]]; then sed -i 's/^Theme=SebType/Theme=Papirus/' "$g"; want=Papirus; fi
    o=$(fake_run < /dev/null) || return 1; echo "$o"
    grep -q '^change: remove the old SebType icon theme' <<<"$o" && [[ ! -e $t ]] &&
      [[ $(kreadconfig6 --file "$g" --group Icons --key Theme) == "$want" ]] && grep -qx 'ColorScheme=BreezeDark' "$g" &&
      if [[ $inherits == picked ]]; then [[ ! -e $fake/emit.log ]]; else grep -q iconChanged "$fake/emit.log"; fi || return 1
    [[ -n $inherits ]] || ! grep -q '^Theme=' "$g" || return 1
    o=$(fake_run < /dev/null) && ! grep -q 'icon theme' <<<"$o" || return 1
  done
  printf '[Icons]\nTheme=Fluent-dark\n' > "$g"; rm -f "$fake/emit.log"
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

# --undo-configurator removes the app and its daily update check (#422), stopping a check that waits on its
# notification, and puts back the candidate window theme Picnic replaced; a second
# undo changes nothing, and setup installs it again.
undo_configurator() {
  local d=$h/.local/share c=$h/.config/fcitx5/conf/classicui.conf o
  mkdir -p "$d/fcitx5/themes/sebtype-picnic" "${c%/*}"
  printf 'Theme=Nord\nDarkTheme=default-dark\n' > "$d/fcitx5/themes/sebtype-picnic/previous"
  printf 'Vertical Candidate List=False\nTheme=sebtype-picnic\nDarkTheme=sebtype-picnic\n' > "$c"
  : > "$fake/systemctl.log"
  o=$(fake_run --undo-configurator < /dev/null) || return 1; echo "$o"
  grep -qx 'systemctl --user stop sebtype-update.service' "$fake/systemctl.log" || { echo "the update check wasn't stopped"; return 1; }
  [[ $(grep -c '^change:' <<<"$o") == 6 && ! -e $d/sebtype/configurator && ! -e $h/.config/systemd/user/sebtype-update.timer && ! -e $d/applications/sebtype-configurator.desktop &&
    ! -e $d/icons/hicolor/192x192/apps/sebtype-configurator.png && ! -e $d/fcitx5/themes/sebtype-picnic ]] &&
    [[ $(cat "$c") == $'Vertical Candidate List=False\nTheme=Nord\nDarkTheme=default-dark' ]] &&
    o=$(fake_run --undo-configurator < /dev/null) && [[ -z $o ]] &&
    o=$(fake_run < /dev/null) && grep -q '^change: install SebType Configurator' <<<"$o" && configurator
}

# A private D-Bus session for one fake account (private_dbus, tools/lib.sh).
private_bus() { # home, timeout seconds, command...
  private_dbus "$fake" -i PATH="$PATH" HOME="$1" XDG_CONFIG_HOME="$1/.config" XDG_DATA_HOME="$1/.local/share" -- \
    timeout "$2" "${@:3}"
}
# The issue's repro: a private session asks for the Documents portal, and the user's mount stays. Not
# under bwrap (own_fcitx), where the private portal can't mount at all.
portal_mount() {
  local h=$fake/portal; mkdir -p "$h"
  private_bus "$h" 20 gdbus call --session --dest org.freedesktop.portal.Documents --object-path /org/freedesktop/portal/documents \
    --method org.freedesktop.portal.Documents.GetMountPoint || return 1
  mount | grep " on $XDG_RUNTIME_DIR/doc type fuse.portal "
}
if [[ -n ${XDG_RUNTIME_DIR-} ]] && mount | grep -q " on $XDG_RUNTIME_DIR/doc type fuse.portal "; then
  check private-bus-keeps-document-portal portal_mount
else result SKIP private-bus-keeps-document-portal "the user's xdg-document-portal isn't mounted"
fi

# Japanese keys, typed into a private Fcitx5 (its own D-Bus session, no display, so the live session
# can't see it) running SebType's input method (#190) on a second fake account set up by setup-ime.sh: Shift tap toggles
# あ ⇄ English in every Mozc state, Shift+K and Ctrl+Shift don't, and Alt+` toggles あ ⇄ ア and leaves
# English alone (#117), Ctrl+Backspace right after a commit undoes it only there (#376); the tray (a stand-in for Plasma's kimpanel on that bus) gets the icon of each mode. Caps Lock (A) has no D-Bus way in: it is
# checked on the desktop (pc/linux/README.md). Its fcitx5 is found by the fake HOME in its environment and
# stopped afterwards.
mozc_keys() {
  local h=$fake/jp
  mkdir -p "$h/.config/fcitx5"
  fake_run < /dev/null > /dev/null || return 1
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=sebtype\n\n[Groups/0/Items/0]\nName=sebtype\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  private_bus "$h" 60 "${own_fcitx[@]}" python3 - "$fake/fcitx5.log" <<'PY'
import re, subprocess, sys, time
from gi.repository import Gio, GLib

SHIFT, CTRL, ALT = 1, 4, 8
KEYS = {'Shift_L': (0xffe1, 50), 'Control_L': (0xffe3, 37), 'Alt_L': (0xffe9, 64), 'Escape': (0xff1b, 9),
        'Return': (0xff0d, 36), 'Tab': (0xff09, 23), 'space': (0x20, 65), 'a': (0x61, 38), 'k': (0x6b, 45),
        'K': (0x4b, 45), 'grave': (0x60, 49), 'Katakana': (0xff26, 101), 'Hiragana': (0xff25, 102),
        'BackSpace': (0xff08, 22), 'i': (0x69, 31), 's': (0x73, 39), 'h': (0x68, 43)}
MODS = {'Shift_L': SHIFT, 'Control_L': CTRL, 'Alt_L': ALT}

fcitx = subprocess.Popen(['fcitx5', '-k', '--disable=all', '--enable=dbus,dbusfrontend,keyboard,sebtype,kimpanel'],
                         stdout=subprocess.DEVNULL, stderr=open(sys.argv[1], 'w'))
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
Gio.bus_own_name_on_connection(bus, 'org.kde.impanel', 0, None, None)
tray = ['']
def on_tray(_c, _s, _p, _i, name, params):
    if name == 'UpdateProperty': tray[0] = (re.findall(r'sebtype-[\w-]+', str(params.unpack())) or tray)[0]
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
    elif name == 'UpdateClientSideUI': ui.append(params.unpack())
ui = []
bus.signal_subscribe(None, IC, None, ic, None, 0, on_signal)
call(ic, IC, 'SetCapability', '(t)', 1 << 1 | 1 << 4 | 1 << 39)  # preedit, formatted, client-side panel
call(ic, IC, 'FocusIn')
SEBTYPE = ('/sebtype', 'org.sebtype.Core1')
call(*SEBTYPE, 'SetLanguage', '(s)', 'ja')

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
    lang = call(*SEBTYPE, 'State')[0]
    return got if lang == 'ja' else f'SebType switched to {lang}'

ok = True
def check(name, got, want):
    global ok
    ok &= got == want
    print('PASS' if got == want else 'FAIL', name, '' if got == want else f'got {got!r}, want {want!r}')

check('starts in あ', mode(), 'あ')
check('tray icon in あ', tray[0], 'sebtype-hira')
tap('Shift_L'); check('tray icon in English', tray[0], 'sebtype-ja-a'); tap('Shift_L')
tap('Katakana'); check('tray icon in ア', tray[0], 'sebtype-kata'); tap('Hiragana')
check('tray icon back in あ', tray[0], 'sebtype-hira')
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
chord('Alt_L', 'grave'); check('Alt+` is ア', (mode(), tray[0]), ('ア', 'sebtype-kata'))
shift_tap(); check('Shift tap in ア turns English on', mode(), 'A')
chord('Alt_L', 'grave'); check('Alt+` in English stays English', mode(), 'A')
shift_tap(); check('Shift tap in English is ア again', mode(), 'ア')
chord('Alt_L', 'grave'); check('Alt+` is あ again', (mode(), tray[0]), ('あ', 'sebtype-hira'))
# #443: the mouse wheel over the candidate window pages it. classicui's wheel calls the list's prev() or next()
# when it says it has that page, as the client-side panel's PrevPage and NextPage do here. A notch past the
# first or last page changes nothing, and nothing ends what is being typed.
def shown():  # the page's words, whether it has a page before and after it, and whether a word is typed
    u = ui[-1]
    return tuple(t for _, t in u[4]), u[7], u[8], bool(preedit[0])
def wheel(down):
    n = len(ui)
    call(ic, IC, 'NextPage' if down else 'PrevPage')
    end = time.time() + 0.5
    while time.time() < end and len(ui) == n: GLib.MainContext.default().iteration(False)
    end = time.time() + 0.05  # and the preedit after it
    while time.time() < end: GLib.MainContext.default().iteration(False)
    return shown()
def wheel_pages(name):
    first = shown()
    check(f'{name}: the first page has a next one', first[1:3], (False, True))
    check(f'{name}: wheel up on the first page changes nothing', wheel(False), first)
    second = wheel(True)
    check(f'{name}: wheel down shows the next page', (second[0] != first[0], second[1], second[3]), (True, True, True))
    check(f'{name}: wheel up shows the first page again', wheel(False), first)
    last, pages = first, 1
    while last[2] and pages < 100: last, pages = wheel(True), pages + 1
    check(f'{name}: wheel down reaches the last page', (last[2], last[3]), (False, True))
    check(f'{name}: wheel down on the last page changes nothing', wheel(True), last)
for k in 'kisha': tap(k)
one = shown()  # Mozc's suggestions: one page
check('the wheel over one page changes nothing', (one[1:3], wheel(True), wheel(False)), ((False, False), one, one))
tap('space'); tap('space'); wheel_pages('converting kisha')  # the second space shows the candidates
tap('Escape'); tap('Escape')
# Ctrl+Backspace right after a commit (#376), in fields that keep their text as an app does (the caret at its
# end) and say it to Fcitx5 (surrounding text) or not: the commit goes and converts again as before Enter, and
# Escape gives its reading back; but never in another field, or where the app can't delete it.
def field(surrounding, text=''):
    global ic
    if ic: call(ic, IC, 'FocusOut')
    ic = call('/org/freedesktop/portal/inputmethod', 'org.fcitx.Fcitx.InputMethod1', 'CreateInputContext',
              '(a(ss))', [('program', 'sebtype-test')])[0]
    doc = {'text': text, 'deleted': []}
    def on_doc(_c, _s, _p, _i, name, params):
        if name == 'CommitString': doc['text'] += params.unpack()[0]
        elif name == 'DeleteSurroundingText':
            offset, n = params.unpack(); doc['deleted'].append((offset, n))
            end = len(doc['text']) + offset
            doc['text'] = doc['text'][:end] + doc['text'][end + n:]
        elif name == 'UpdateFormattedPreedit': preedit[0] = ''.join(s for s, _ in params.unpack()[0])
        else: return
        doc['sync'] = True
    bus.signal_subscribe(None, IC, None, ic, None, 0, on_doc)
    call(ic, IC, 'SetCapability', '(t)', 1 << 1 | 1 << 4 | 1 << 39 | (1 << 6 if surrounding else 0))
    call(ic, IC, 'FocusIn')
    doc['sync'] = surrounding
    def say():  # the app's text and caret, after each change, as apps tell it
        if surrounding and doc.pop('sync', False):
            n = len(doc['text']); call(ic, IC, 'SetSurroundingText', '(suu)', doc['text'], n, n)
    doc['say'] = say; say()
    return doc
def typed(doc, keys):
    for k in keys:
        if k == 'ctrl-bs': chord('Control_L', 'BackSpace')
        else: tap(k)
        doc['say']()
    return doc['text'], preedit[0]
convert = [*'kisha', 'space', 'Return']
doc = field(True)
check('Ctrl+Backspace after a commit deletes it and converts it again',
      (typed(doc, convert), typed(doc, ['ctrl-bs']), typed(doc, ['Escape']), typed(doc, ['Return']), doc['deleted']),
      (('記者', ''), ('', '記者'), ('', 'きしゃ'), ('きしゃ', ''), [(-2, 2)]))
typed(doc, convert)
other = field(True, 'abcd')
check('Ctrl+Backspace in another field after a commit leaves its text', (typed(other, ['ctrl-bs']), other['deleted']),
      (('abcd', ''), []))
plain = field(False)
check('Ctrl+Backspace after a commit leaves it where the app has no surrounding text',
      (typed(plain, convert), typed(plain, ['ctrl-bs', 'Escape', 'Return'])), (('記者', ''), ('記者', '')))
fcitx.terminate(); fcitx.wait(10)
sys.exit(0 if ok else 1)
PY
  local rc=$? p
  for p in $(pgrep -x fcitx5); do
    grep -qzx "HOME=$h" "/proc/$p/environ" 2>/dev/null && kill "$p"
  done
  return $rc
}
if command -v fcitx5 dbus-run-session >/dev/null && python3 -c 'from gi.repository import Gio' 2>/dev/null; then
  check mozc-shift-tap-and-alt-grave mozc_keys
else result SKIP mozc-shift-tap-and-alt-grave "needs fcitx5, dbus-run-session and python3-gobject"
fi

# The popup's mode words follow the system language (#205): a private Fcitx5 (as above) on its own fake
# account, started once with each LANGUAGE, shows 日本語 (Hiragana), 日本語（平假名） and 日本語（ひらがな）
# on a switch to 日本語. What it showed goes to popup-words.txt next to the results.
popup_words() {
  local h=$fake/popup p
  mkdir -p "$h/.config/fcitx5"
  fake_run < /dev/null > /dev/null || return 1
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=sebtype\n\n[Groups/0/Items/0]\nName=sebtype\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  # Fedora's Fcitx5 shows the compact popup (あ) by default; the words checked below are the long popup's.
  kwriteconfig6 --file "$h/.config/fcitx5/config" --group Behavior --key CompactInputMethodInformation False
  private_bus "$h" 90 "${own_fcitx[@]}" python3 - "$fake/fcitx5-popup.log" "$out/popup-words.txt" <<'PY2'
import os, subprocess, sys, time
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION)
def call(path, iface, method, sig=None, *args):
    return bus.call_sync('org.fcitx.Fcitx5', path, iface, method, GLib.Variant(sig, args) if sig else None,
                         None, Gio.DBusCallFlags.NO_AUTO_START, 10000, None).unpack()
def wait(cond, secs):
    end = time.time() + secs
    while time.time() < end and not cond():
        GLib.MainContext.default().iteration(False); time.sleep(0.02)
    return cond()
def up():
    try: call('/controller', 'org.fcitx.Fcitx.Controller1', 'CurrentInputMethod'); return True
    except GLib.Error: return False
IC, SEBTYPE = 'org.fcitx.Fcitx.InputContext1', ('/sebtype', 'org.sebtype.Core1')

def popup(language):  # the popup a Fcitx5 started with LANGUAGE=language shows on a switch to 日本語
    fcitx = subprocess.Popen(['fcitx5', '-k', '--disable=all', '--enable=dbus,dbusfrontend,keyboard,sebtype'],
                             env={**os.environ, 'LANGUAGE': language}, stdout=subprocess.DEVNULL,
                             stderr=open(sys.argv[1], 'a'))
    started = time.monotonic()
    try:
        wait(up, 10)
        ic, _ = call('/org/freedesktop/portal/inputmethod', 'org.fcitx.Fcitx.InputMethod1', 'CreateInputContext',
                     '(a(ss))', [('program', 'sebtype-test')])
        popups = []
        def on_signal(_c, _s, _p, _i, name, params):
            if name == 'UpdateClientSideUI':
                text = ''.join(s for s, _ in params.unpack()[2])
                if text: popups.append(text)
        sub = bus.signal_subscribe(None, IC, None, ic, None, 0, on_signal)
        call(ic, IC, 'SetCapability', '(t)', 1 << 1 | 1 << 4 | 1 << 39)
        call(ic, IC, 'FocusIn')
        call(ic, IC, 'SetCursorRect', '(iiii)', 120, 640, 1, 20)  # a text field's caret: the popup shows by it (#446)
        # Fcitx5 shows its own popup (SebType (English)) once after it starts, to a focused input context: its
        # group-changed timer fires 30 ms later plus up to sd-event's default 250 ms accuracy. Switching before
        # that let it land just after SebType's 日本語 popup and replace it (#221), so the switch waits for it,
        # or for 1 s after the start when it came before the focus.
        call(*SEBTYPE, 'SetLanguage', '(s)', 'en')
        wait(lambda: popups or time.monotonic() - started > 1, 5)
        popups.clear(); call(*SEBTYPE, 'SetLanguage', '(s)', 'ja')
        wait(lambda: popups, 5); wait(lambda: False, 0.3)  # and any popup that replaces it
        bus.signal_unsubscribe(sub)
        if len(popups) > 1: print(f'LANGUAGE={language}: popups {popups!r}')
        return popups[-1] if popups else None
    finally:
        fcitx.terminate(); fcitx.wait(10)

ok = True
with open(sys.argv[2], 'w') as f:
    for language, want in (('en', '日本語 (Hiragana)'), ('zh_CN', '日本語（平假名）'), ('ja', '日本語（ひらがな）')):
        got = popup(language)
        f.write(f'{language}\t{got}\n')
        ok &= got == want
        print('PASS' if got == want else 'FAIL', f'LANGUAGE={language} popup', '' if got == want else f'got {got!r}, want {want!r}')
sys.exit(0 if ok else 1)
PY2
  local rc=$?
  for p in $(pgrep -x fcitx5); do
    grep -qzx "HOME=$h" "/proc/$p/environ" 2>/dev/null && kill "$p"
  done
  return $rc
}
if command -v fcitx5 dbus-run-session >/dev/null && python3 -c 'from gi.repository import Gio' 2>/dev/null; then
  check popup-words popup_words
else result SKIP popup-words "needs fcitx5, dbus-run-session and python3-gobject"
fi

# Upgrade from mozc_server (#233): a profile that SebType's last release with Mozc's own server learned in
# (a conversion's second candidate, picked once) and a word in SebType's user dictionary still convert the
# same in Mozc in Fcitx5's process. Both runs: a private Fcitx5 (as above) on a fourth fake account. The old
# release's mozc_server is overlaid at the path it was built for (its watchdog checks it) and stopped after.
old_rpm=$SEBTYPE_CACHE/sebtype-0.1.0-5.fc44.x86_64.rpm  # the last release before #233
mozc_upgrade() {
  local h=$fake/upgrade old=$fake/old-build p rc
  mkdir -p "$h/.config/fcitx5" "$h/.config/mozc" "$old"
  fake_run < /dev/null > /dev/null || return 1
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=sebtype\n\n[Groups/0/Items/0]\nName=sebtype\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  # SebType's user dictionary as the Configurator writes it (pc/configurator/src/mozc.rs): もふてすと → モフ試験語, a noun.
  python3 - "$h/.config/mozc/user_dictionary.db" <<'PY'
import sys
def f(n, v): return bytes([n << 3 | 2, len(v)]) + v if isinstance(v, bytes) else bytes([n << 3, v])
entry = f(1, 'もふてすと'.encode()) + f(2, 'モフ試験語'.encode()) + f(5, 1)
open(sys.argv[1], 'wb').write(f(2, f(1, 7) + f(3, b'SebType') + f(4, entry)))
PY
  rpm2cpio "$old_rpm" | (cd "$old" && cpio -idm --quiet) || return 1
  local mounts; read -ra mounts <<<"$(librime_mounts "$own")"
  local old_fcitx=(env "FCITX_ADDON_DIRS=$old/usr/lib64/fcitx5:/usr/lib64/fcitx5" "XDG_DATA_DIRS=$old/usr/share:/usr/share"
    bwrap --dev-bind / / "${mounts[@]}" --overlay-src /usr/libexec --overlay-src "$old/usr/libexec" --ro-overlay /usr/libexec)
  type_ja() { # mode (learn: kikai, Space, Space, Return; check: kikai and mofutesuto, Space, Return), command...
    private_bus "$h" 60 "${@:2}" python3 - "$1" "$fake/fcitx5-upgrade-$1.log" <<'PY'
import subprocess, sys, time
from gi.repository import Gio, GLib
KEYS = {'space': (0x20, 65), 'Return': (0xff0d, 36)} | {c: (ord(c), 0) for c in 'abcdefghijklmnopqrstuvwxyz'}
fcitx = subprocess.Popen(['fcitx5', '-k', '--disable=all', '--enable=dbus,dbusfrontend,keyboard,sebtype'],
                         stdout=subprocess.DEVNULL, stderr=open(sys.argv[2], 'w'))
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
def call(path, iface, method, sig=None, *args):
    return bus.call_sync('org.fcitx.Fcitx5', path, iface, method, GLib.Variant(sig, args) if sig else None,
                         None, Gio.DBusCallFlags.NO_AUTO_START, 20000, None).unpack()
CONTROLLER, IC = ('/controller', 'org.fcitx.Fcitx.Controller1'), 'org.fcitx.Fcitx.InputContext1'
for _ in range(100):
    try: call(*CONTROLLER, 'CurrentInputMethod'); break
    except GLib.Error: time.sleep(0.1)
ic, _ = call('/org/freedesktop/portal/inputmethod', 'org.fcitx.Fcitx.InputMethod1', 'CreateInputContext',
             '(a(ss))', [('program', 'sebtype-test')])
committed = []
bus.signal_subscribe(None, IC, 'CommitString', ic, None, 0, lambda *a: committed.append(a[5].unpack()[0]))
call(ic, IC, 'SetCapability', '(t)', 1 << 1 | 1 << 4 | 1 << 39)
call(ic, IC, 'FocusIn')
call('/sebtype', 'org.sebtype.Core1', 'SetLanguage', '(s)', 'ja')
def tap(name):
    sym, code = KEYS[name]
    for release in (False, True): call(ic, IC, 'ProcessKeyEvent', '(uuubu)', sym, code, 0, release, 0)
    end = time.time() + 0.05
    while time.time() < end: GLib.MainContext.default().iteration(False)
def word(romaji, spaces):
    committed.clear()
    for k in list(romaji) + ['space'] * spaces + ['Return']: tap(k)
    print(''.join(committed))
if sys.argv[1] == 'learn': word('kikai', 2)
else: word('kikai', 1); word('mofutesuto', 1)
call(*CONTROLLER, 'Exit')  # Fcitx5 saves on the way out: SYNC_DATA
fcitx.wait(20)
PY
  }
  local learned now
  learned=$(type_ja learn "${old_fcitx[@]}"); rc=$?
  for p in $(pgrep -x mozc_server); do grep -qzx "HOME=$h" "/proc/$p/environ" 2>/dev/null && kill "$p"; done
  if ((rc != 0)) || [[ -z $learned ]] || ! ls "$h/.config/mozc/segment.db"; then
    echo "the old release learned nothing: '$learned'"; return 1
  fi
  now=$(type_ja check "${own_fcitx[@]}") || return 1
  echo "picked with mozc_server: $learned; in-process now: ${now//$'\n'/, }"
  [[ $now == "$learned"$'\n'モフ試験語 ]]
}
if [[ ! -f $old_rpm ]]; then result SKIP mozc-profile-from-mozc-server "no $old_rpm (the release before #233) cached"
elif command -v fcitx5 dbus-run-session >/dev/null && python3 -c 'from gi.repository import Gio' 2>/dev/null; then
  check mozc-profile-from-mozc-server mozc_upgrade
else result SKIP mozc-profile-from-mozc-server "needs fcitx5, dbus-run-session and python3-gobject"
fi

# Chinese label (#69) and SebType's Chinese data (#102): a private Fcitx5 (as above) running SebType's input method (#190) on a
# third fake account set up by setup-ime.sh, which installs SebType's Chinese data there. Switching to it
# must show 中文 in the popup, both the long one and the compact one (the reference PC's setting; it shows
# the label the tray text uses), as fcitx5-rime's did. The same Fcitx5 checks the
# Ctrl+Shift+F key (#36): 后来 comes out as 後來 and back, and Ctrl+F reaches the app; and typo correction
# (#46) with a PC keyboard: xoaoshi (o for its neighbour i) gives 小时 first, and so does xkaoshi (k for
# the i above it), which only SebType's librime corrects (#101), and nihap (p for o) 你好 (#135); and the
# grammar plugin (#127): beirendingwei gives 被认定为, not 被人定位 as without the grammar file. The account's
# default.custom.yaml has no page size, so setup's 6 is added to it and a page shows 6 candidates (#163).
# Focus moving away mid-word types the pinyin in (#277), and so does switching to 日本語 (#301). A sync's save and
# a deploy wait until typing is idle (#373).
rime_label() {
  local h=$fake/zh r
  r=$h/.local/share/fcitx5/rime
  mkdir -p "$h/.config/fcitx5" "$r"
  printf 'patch:\n  schema_list: [{schema: rime_ice}]\n' > "$r/default.custom.yaml"
  printf 'patch:\n  translator/spelling_hints: 9\n' > "$r/rime_ice.custom.yaml"
  fake_run < /dev/null > /dev/null || return 1
  grep -qx '  translator/spelling_hints: 9' "$r/rime_ice.custom.yaml" || { echo "rime_ice.custom.yaml lost its patch"; return 1; }
  grep -q '^  schema_list:' "$r/default.custom.yaml" || { echo "default.custom.yaml lost its patch"; return 1; }
  grep -q '^  menu/page_size: 6 ' "$r/default.custom.yaml" || { echo "default.custom.yaml has no page size 6"; return 1; }
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=sebtype\n\n[Groups/0/Items/0]\nName=sebtype\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  private_bus "$h" 120 "${own_fcitx[@]}" python3 - "$fake/fcitx5-rime.log" "$r" "$h/.config/fcitx5/config" <<'PY'
import os, subprocess, sys, time
from gi.repository import Gio, GLib

fcitx = subprocess.Popen(['fcitx5', '-k', '--disable=all', '--enable=dbus,dbusfrontend,keyboard,sebtype'],
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
popups, candidates, shown, ui = [], [[]], [''], []
def on_signal(_c, _s, _p, _i, name, params):
    if name == 'UpdateClientSideUI':
        text = shown[0] = ''.join(s for s, _ in params.unpack()[2])
        if text: popups.append(text)
        candidates[0] = params.unpack()[4]
        ui.append(params.unpack())
committed = []
def on_commit(_c, _s, _p, _i, name, params):
    if name == 'CommitString': committed.append(params.unpack()[0])
bus.signal_subscribe(None, IC, None, ic, None, 0, on_signal)
bus.signal_subscribe(None, IC, None, ic, None, 0, on_commit)
call(ic, IC, 'SetCapability', '(t)', 1 << 1 | 1 << 4 | 1 << 39)
call(ic, IC, 'FocusIn')
CARET = (120, 640, 1, 20)
call(ic, IC, 'SetCursorRect', '(iiii)', *CARET)  # a text field's caret: the popup shows by it (#446)

SHIFT, CTRL, SUPER = 1, 4, 0x40
KEYS = {'Shift_L': (0xffe1, 50), 'Control_L': (0xffe3, 37), 'Super_L': (0xffeb, 133), 'space': (0x20, 65),
        'Escape': (0xff1b, 9), 'F': (0x46, 41), '1': (0x31, 10), **{c: (ord(c), code) for row, first in (('qwertyuiop', 24), ('asdfghjkl', 38), ('zxcvbnm', 52))
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

SEBTYPE = ('/sebtype', 'org.sebtype.Core1')
def switch():  # the popup text shown when switching from English to Chinese
    call(*SEBTYPE, 'SetLanguage', '(s)', 'en'); wait(lambda: False, 0.2)
    popups.clear(); call(*SEBTYPE, 'SetLanguage', '(s)', 'zh')
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
# #449: the popup stays its second while nothing is typed, the Win+Space keys that switched included, and the
# first typed key ends it, also one that goes to the app (1 with no pinyin) or commits.
def win_space():
    key('Super_L'); key('space', SUPER); key('space', SUPER, True); key('Super_L', SUPER, True)
def after(typing):  # what the popup shows after a switch to 中文 by Win+Space, then typing, then 0.3 s
    call(*SEBTYPE, 'SetLanguage', '(s)', 'en'); wait(lambda: False, 1.2)
    win_space(); typing(); wait(lambda: False, 0.3)
    return shown[0]
check('the popup stays after the Win+Space keys', after(lambda: None), '中文')
check('it hides by itself after its second', wait(lambda: not shown[0], 1.5), True)
check('a key that goes to the app ends it at once', after(lambda: tap('1')), '')
check('a word committed ends it at once', after(lambda: first('ni')), '')
# #446: Win+Space where the app gives no caret (no text field) shows no popup at the screen's corner.
call(ic, IC, 'SetCursorRect', '(iiii)', 0, 0, 0, 0)
check('no popup without a caret', after(lambda: None), '')
call(ic, IC, 'SetCursorRect', '(iiii)', *CARET)
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
# #277: focus moving away mid-word types the pinyin in as its letters, without Rime's spaces between
# syllables, and the next word starts fresh: through Fcitx5 for an app that shows the preedit itself, and
# from SebType for one whose preedit is in Fcitx5's panel.
def away(caps):
    call(ic, IC, 'SetCapability', '(t)', caps)
    committed.clear()
    for c in 'nihao': tap(c)
    call(ic, IC, 'FocusOut'); wait(lambda: committed, 2)
    typed = ''.join(committed)
    call(ic, IC, 'FocusIn')
    return typed, first('ni')
check('focus out types in nihao (the app shows the preedit)', away(1 << 1 | 1 << 4 | 1 << 39), ('nihao', '你'))
check('focus out types in nihao (preedit in the panel)', away(1 << 39), ('nihao', '你'))
call(ic, IC, 'SetCapability', '(t)', 1 << 1 | 1 << 4 | 1 << 39)
# #301: switching to 日本語 mid-word types the pinyin in the same way, and 中文 starts fresh after it.
def switch_away():
    committed.clear()
    for c in 'nihao': tap(c)
    call(*SEBTYPE, 'SetLanguage', '(s)', 'ja'); wait(lambda: committed, 2)
    typed = ''.join(committed)
    call(*SEBTYPE, 'SetLanguage', '(s)', 'zh')
    return typed, first('ni')
check('switching to 日本語 types in nihao', switch_away(), ('nihao', '你'))
def page(keys):  # how many candidates the first page of keys shows
    for c in keys: tap(c)
    wait(lambda: candidates[0], 2); n = len(candidates[0]); tap('Escape'); return n
check('a page shows 6 candidates (shi)', page('shi'), 6)
# #443: the mouse wheel over the candidate window pages it. classicui's wheel calls the list's prev() or next()
# when it says it has that page, as the client-side panel's PrevPage and NextPage do here. A notch past the
# first or last page changes nothing, and nothing ends what is being typed.
def page_shown():  # the page's words, whether it has a page before and after it, and whether a word is typed
    u = ui[-1]
    return tuple(t for _, t in u[4]), u[7], u[8], bool(preedit[0])
def wheel(down):
    n = len(ui)
    call(ic, IC, 'NextPage' if down else 'PrevPage')
    wait(lambda: len(ui) > n, 0.5); wait(lambda: False, 0.03)
    return page_shown()
def wheel_pages(name):
    first = page_shown()
    check(f'{name}: the first page has a next one', first[1:3], (False, True))
    check(f'{name}: wheel up on the first page changes nothing', wheel(False), first)
    second = wheel(True)
    check(f'{name}: wheel down shows the next page', (second[0] != first[0], second[1], second[3]), (True, True, True))
    check(f'{name}: wheel up shows the first page again', wheel(False), first)
    last, pages = first, 1
    while last[2] and pages < 100: last, pages = wheel(True), pages + 1
    check(f'{name}: wheel down reaches the last page', (last[2], last[3]), (False, True))
    check(f'{name}: wheel down on the last page changes nothing', wheel(True), last)
for c in 'shi': tap(c)
wait(lambda: candidates[0], 2)
wheel_pages('shi')
tap('Escape')
# #373: the sync's Save and its deploy asked for mid-word wait until typing is idle: the word typed on keeps what
# was typed before them, and Rime's save runs once typing stops (it writes this PC's snapshot).
def sync_mid_word():
    for c in 'ni': tap(c)
    call(*CONTROLLER, 'Save')
    call(*CONTROLLER, 'SetConfig', '(sv)', 'fcitx://config/addon/sebtype/deploy-when-idle', GLib.Variant('s', ''))
    wait(lambda: False, 1)
    return first('hao')
check('a sync and a deploy mid-word keep it: nihao gives 你好', sync_mid_word(), '你好')
def saved():
    return any(f.endswith('.userdb.txt') for _, _, files in os.walk(os.path.join(sys.argv[2], 'sync')) for f in files)
check("Rime's save runs once typing is idle", wait(saved, 30), True)
fcitx.terminate(); fcitx.wait(10)
sys.exit(0 if ok else 1)
PY
  local rc=$? p
  for p in $(pgrep -x fcitx5); do grep -qzx "HOME=$h" "/proc/$p/environ" 2>/dev/null && kill "$p"; done
  return $rc
}
if command -v fcitx5 dbus-run-session >/dev/null && python3 -c 'from gi.repository import Gio' 2>/dev/null; then
  check rime-label-and-zh-hant-key rime_label
else result SKIP rime-label-and-zh-hant-key "needs fcitx5, dbus-run-session and python3-gobject"
fi

# Private fields (#270): a private Fcitx5 (as above) with SebType's input method on its own fake account. In a field
# the app marks sensitive (Chromium's incognito windows, Qt's ImhSensitiveData), a word picked in 中文 and in
# 日本語 is not learned, and what was learned before is still first; in a field that may learn the same pick is.
# Mozc's settings file (here general_config and the MS-IME keymap) is never written for it. Forgetting 日本語 then
# leaves no history behind (#373). The Configurator's learning off (#374) is the same everywhere, and turned on
# again learns.
private_field() {
  local h=$fake/private
  mkdir -p "$h/.config/fcitx5"
  fake_run < /dev/null > /dev/null || return 1
  mkdir -p "$h/.config/mozc"
  printf '\x0a\x02\x08\x01\xc8\x02\x02' > "$h/.config/mozc/config1.db"
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=sebtype\n\n[Groups/0/Items/0]\nName=sebtype\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  private_bus "$h" 240 "${own_fcitx[@]}" python3 - "$fake/fcitx5-private.log" "$h/.config/mozc" "$PWD/../configurator/target/release/sebtype-configurator" <<'PY'
import hashlib, os, re, subprocess, sys, time
from gi.repository import Gio, GLib

CONFIG1 = os.path.join(sys.argv[2], 'config1.db')
def config1(): return os.stat(CONFIG1).st_mtime_ns, hashlib.sha256(open(CONFIG1, 'rb').read()).hexdigest()
before = config1()

fcitx = subprocess.Popen(['fcitx5', '-k', '--disable=all', '--enable=dbus,dbusfrontend,keyboard,sebtype'],
                         stdout=subprocess.DEVNULL, stderr=open(sys.argv[1], 'w'))
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
def call(path, iface, method, sig=None, *args):  # never D-Bus-activates a second, default Fcitx5
    return bus.call_sync('org.fcitx.Fcitx5', path, iface, method, GLib.Variant(sig, args) if sig else None,
                         None, Gio.DBusCallFlags.NO_AUTO_START, 10000, None).unpack()
CONTROLLER, IC, SEBTYPE = ('/controller', 'org.fcitx.Fcitx.Controller1'), 'org.fcitx.Fcitx.InputContext1', ('/sebtype', 'org.sebtype.Core1')
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
committed, preedit = [], ['']
def on_signal(_c, _s, _p, _i, name, params):
    if name == 'CommitString': committed.append(params.unpack()[0])
    elif name == 'UpdateFormattedPreedit': preedit[0] = ''.join(s for s, _ in params.unpack()[0])
bus.signal_subscribe(None, IC, None, ic, None, 0, on_signal)
SENSITIVE = 1 << 36
def field(sensitive):  # preedit, formatted, client-side panel; the core reads the flags at the next key
    call(ic, IC, 'SetCapability', '(t)', 1 << 1 | 1 << 4 | 1 << 39 | (SENSITIVE if sensitive else 0))
call(ic, IC, 'FocusIn')
KEYS = {'space': (0x20, 65), 'Return': (0xff0d, 36), 'Escape': (0xff1b, 9), '2': (0x32, 11), '3': (0x33, 12), '4': (0x34, 13),
        **{c: (ord(c), code) for row, first in (('qwertyuiop', 24), ('asdfghjkl', 38), ('zxcvbnm', 52))
           for code, c in enumerate(row, first)}}
def tap(name):
    for release in (False, True):
        call(ic, IC, 'ProcessKeyEvent', '(uuubu)', *KEYS[name], 0, release, 0)
        wait(lambda: False, 0.03)
def commit(keys):
    committed.clear()
    for k in keys: tap(k)
    wait(lambda: committed, 3)
    return ''.join(committed)
def rime_ready():  # Rime deploys on first use and takes no keys until then
    tap('n'); ready = wait(lambda: preedit[0] == 'n', 0.5); tap('Escape'); return ready
SETTINGS = os.path.expanduser('~/.config/sebtype/sebtype.conf')
RIME_PATCH = os.path.expanduser('~/.local/share/fcitx5/rime/rime_ice.custom.yaml')
PENDING = os.path.expanduser('~/.local/share/sebtype/learning-migration-pending')
learned = {}
LANGS = {  # the first candidate, and the nth picked
    'zh': (lambda: commit([*'shishi', 'space']), lambda n: commit([*'shishi', str(n)])),
    'ja': (lambda: commit([*'kisha', 'space', 'Return']), lambda n: commit([*'kisha', *['space'] * n, 'Return'])),
}
def learning(on):  # the Configurator's switch (#374), as its window sets it
    r = subprocess.run([sys.argv[3], '--learning', 'on' if on else 'off'], capture_output=True, text=True, timeout=60)
    if r.returncode: print(r.stdout[-2000:], r.stderr[-2000:])
    return r.returncode == 0

ok = True
def check(name, got, want):
    global ok
    ok &= got == want
    print('PASS' if got == want else 'FAIL', name, '' if got == want else f'got {got!r}, want {want!r}')

for lang, (first, nth) in LANGS.items():
    call(*SEBTYPE, 'SetLanguage', '(s)', lang)
    field(False)
    if lang == 'zh': check('Rime deployed', wait(rime_ready, 60), True)
    top = first()
    field(True)
    picked = nth(4)
    check(f'{lang}: a pick in a sensitive field', bool(picked) and picked != top, True)
    check(f'{lang}: a sensitive field learns nothing', first(), top)
    field(False)
    check(f'{lang}: the same pick in a field that may learn', nth(4), picked)
    check(f'{lang}: a field that may learn learns it', first(), picked)
    field(True)
    check(f'{lang}: a sensitive field keeps what was learned', first(), picked)
    # Learning off in the Configurator is the same (#374): what was learned stays in use, a pick isn't learned.
    # The file may already say off, from a try whose notice didn't reach Fcitx5: told again all the same.
    field(False)
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    with open(SETTINGS, 'a') as f: f.write('[Learning]\nOn=false\n')
    check(f'{lang}: the Configurator turns learning off', learning(False), True)
    if lang == 'zh': wait(rime_ready, 60)
    check(f'{lang}: learning off keeps what was learned', first(), picked)
    other = nth(3)
    check(f'{lang}: a pick with learning off', bool(other) and other != picked, True)
    check(f'{lang}: learning off learns nothing', first(), picked)
    check(f'{lang}: the Configurator turns learning on', learning(True), True)
    if lang == 'zh': wait(rime_ready, 60)
    check(f'{lang}: learning on again keeps what was learned', first(), picked)
    check(f'{lang}: the same pick with learning on', nth(3), other)
    # Learned, it moves up from 3rd (Rime may keep the word committed more often ahead of it).
    check(f'{lang}: learning on again learns it', other in (first(), nth(2)), True)
    learned[lang] = first()
check("Mozc's config1.db untouched by learning off and on", config1(), before)
# Restrictions SebType didn't write (no SebType comment; NO_HISTORY with Chinese's learning on) are the
# person's own: a migration leaves them, and learning on (#374).
with open(RIME_PATCH) as f: patch = f.read()
with open(CONFIG1, 'rb') as f: cfg = f.read()
def old_settings(rime_line):
    with open(RIME_PATCH, 'w') as f: f.write(re.sub(r'^patch:\n', f'patch:\n  {rime_line}\n', patch, count=1, flags=re.M))
    with open(CONFIG1, 'wb') as f: f.write(cfg + b'\x90\x03\x02')  # history_learning_level (50): NO_HISTORY
def migrate():
    r = subprocess.run([sys.argv[3], '--migrate'], capture_output=True, text=True, timeout=120)
    return r.returncode, r.stderr
def idle_refresh():  # the migration's deploy and Mozc restart wait until typing is idle (5 s, #373)
    wait(lambda: False, 8); wait(rime_ready, 60); wait(lambda: False, 8)
old_settings('translator/enable_user_dict: false')
check('own restrictions: the migration runs', migrate(), (0, ''))
check('own restrictions: learning stays on', os.path.exists(SETTINGS) and 'On=false' in open(SETTINGS).read(), False)
check("own restrictions: rime-ice's patch keeps them", 'enable_user_dict: false\n' in open(RIME_PATCH).read(), True)
check("own restrictions: Mozc's NO_HISTORY stays", open(CONFIG1, 'rb').read(), cfg + b'\x90\x03\x02')
# An upgrade from a Configurator before #374, whose learning off hid what was learned (rime-ice's
# enable_user_dict, Mozc's NO_HISTORY, as it wrote them): setup's --migrate moves it to sebtype.conf, which
# keeps using it. It comes while 中文 is being typed, which the engines' refresh keeps (#373).
old_settings("translator/enable_user_dict: false  # SebType: don't learn")
call(*CONTROLLER, 'SetConfig', '(sv)', 'fcitx://config/addon/sebtype/deploy', GLib.Variant('s', ''))
call(*CONTROLLER, 'SetConfig', '(sv)', 'fcitx://config/addon/sebtype/mozc', GLib.Variant('s', ''))
hidden = {}
for lang, (first, nth) in LANGS.items():
    call(*SEBTYPE, 'SetLanguage', '(s)', lang)
    if lang == 'zh': wait(rime_ready, 60)
    hidden[lang] = first()
    check(f'{lang}: learning off before #374 hides what was learned', hidden[lang] != learned[lang], True)
call(*SEBTYPE, 'SetLanguage', '(s)', 'zh')
for k in 'shi': tap(k)
check('setup migrates learning off', migrate(), (0, ''))
check('migrating keeps what is being typed', commit([*'shi', 'space']), hidden['zh'])
check('migrated, sebtype.conf has learning off', open(SETTINGS).read().count('[Learning]\nOn=false'), 1)
check("migrated, rime-ice's patch is as before", open(RIME_PATCH).read(), patch)
check("migrated, Mozc's config1.db is as before", open(CONFIG1, 'rb').read(), cfg)
idle_refresh()
for lang, (first, nth) in LANGS.items():
    call(*SEBTYPE, 'SetLanguage', '(s)', lang)
    if lang == 'zh': wait(rime_ready, 60)
    check(f'{lang}: migrated, what was learned is back', first(), learned[lang])
    picked = nth(4)
    check(f'{lang}: migrated, a pick', bool(picked) and picked != learned[lang], True)
    check(f'{lang}: migrated, learning off learns nothing', first(), learned[lang])
check('migrated, nothing left to do', os.path.exists(PENDING), False)
# A migration cut off after it removed Rime's old setting, before Rime read its settings again: the next
# one still has Rime do it.
call(*SEBTYPE, 'SetLanguage', '(s)', 'zh')
old_settings("translator/enable_user_dict: false  # SebType: don't learn")
with open(CONFIG1, 'wb') as f: f.write(cfg)
call(*CONTROLLER, 'SetConfig', '(sv)', 'fcitx://config/addon/sebtype/deploy', GLib.Variant('s', ''))
wait(rime_ready, 60)
check('zh: learning off before #374 hides it again', LANGS['zh'][0](), hidden['zh'])
with open(RIME_PATCH, 'w') as f: f.write(patch)
os.makedirs(os.path.dirname(PENDING), exist_ok=True)
with open(PENDING, 'w') as f: f.write('rime\n')
check('the next migration runs', migrate(), (0, ''))
idle_refresh()
check('zh: after a cut-off migration, what was learned is back', LANGS['zh'][0](), learned['zh'])
check('after a cut-off migration, nothing left to do', os.path.exists(PENDING), False)
check('learning on after the migration', learning(True), True)
# Forgetting 日本語 as the Configurator does (forget_mozc): Mozc restarts at once, saving and closing, then its
# history files go; Mozc closing later (here as Fcitx5 exits) writes nothing back (#373).
HISTORY = [os.path.join(sys.argv[2], f) for f in ('segment.db', 'boundary.db', 'cform.db', '.history.db')]
call(*CONTROLLER, 'SetConfig', '(sv)', 'fcitx://config/addon/sebtype/mozc', GLib.Variant('s', ''))
removed = [f for f in HISTORY if os.path.exists(f)]
for f in removed: os.remove(f)
check('ja: forgetting finds the history Mozc saved as it closed', bool(removed), True)
fcitx.terminate(); fcitx.wait(10)
check('ja: forgotten history stays gone after Mozc closes', [f for f in HISTORY if os.path.exists(f)], [])
sys.exit(0 if ok else 1)
PY
  local rc=$? p
  for p in $(pgrep -x fcitx5); do grep -qzx "HOME=$h" "/proc/$p/environ" 2>/dev/null && kill "$p"; done
  return $rc
}
if command -v fcitx5 dbus-run-session >/dev/null && python3 -c 'from gi.repository import Gio' 2>/dev/null; then
  check private-field private_field
else result SKIP private-field "needs fcitx5, dbus-run-session and python3-gobject"
fi

# Win+Space and the tray menu (#92, #93, #117): a private Fcitx5 (as above) with SebType's input method
# (#190; SebType's Chinese data) on a fourth fake account set up by setup-ime.sh, which also puts SebType's
# tray in place of Fcitx5's, and a stand-in for Plasma's tray (a StatusNotifierWatcher on that bus) that
# reads and clicks the menu. The menu
# reads English · 中文 · 日本語 with SebType's icon names, then the active language's one switch with its
# key (中文 简 → 繁, 日本語 あ → ア, English none), which a click flips, then Fcitx5's Restart and Exit; Fcitx5's clipboard,
# Unicode and quick phrase hotkeys reach the app (#182); Win+Space toggles English and the last other language, also
# while Super stays held; a menu pick becomes the one Win+Space returns to; Rime's Shift tap still
# switches its English mode, and a Shift tap in English switches nothing.
win_space() {
  local h=$fake/menu
  mkdir -p "$h/.config/fcitx5"
  fake_run < /dev/null > /dev/null || return 1
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=sebtype\n\n[Groups/0/Items/0]\nName=sebtype\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$h/.config/fcitx5/profile"
  private_bus "$h" 120 "${own_fcitx[@]}" python3 -W ignore - "$fake/fcitx5-menu.log" <<'PY'
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
# classicui is what turns the tray item (notificationitem, SebType's by the fake account's add-on entry) on.
fcitx = subprocess.Popen(['fcitx5', '-k', '--disable=all', '--enable=dbus,dbusfrontend,keyboard,sebtype,classicui,notificationitem,clipboard,unicode,quickphrase'],
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
SEBTYPE = (FCITX, '/sebtype', 'org.sebtype.Core1')
IMS = {'en': 'keyboard-us', 'zh': 'rime', 'ja': 'mozc'}  # the language, by the input method it was before
im = lambda: IMS[call(*SEBTYPE, 'State')[0]]
def key(sym, code, state=0, release=False):  # True when Fcitx5 took the key
    taken = call(FCITX, ic, IC, 'ProcessKeyEvent', '(uuubu)', sym, code, state, release, 0)[0]
    wait(lambda: False, 0.05)
    return taken
def taken(sym, code, state):  # a chord: True when Fcitx5 took it, False when it reaches the app
    t = key(sym, code, state); key(sym, code, state, True)
    key(0xff1b, 9); key(0xff1b, 9, 0, True)  # Escape closes whatever it opened
    return t
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
# SebType's tray has no Input Method Settings item (#182, #190)
LANGUAGES, FCITX_OWN = ['English', '中文', '日本語', '-'], ['Restart', 'Exit']
def switches():  # labels between the input methods and Fcitx5's own items, '-' for a separator
    labels = [p.get('label', '-') for _, p in menu_items()]
    if labels[:4] != LANGUAGES or labels[-2:] != FCITX_OWN or 'Input Method Settings' in labels: return f'menu {labels!r}'
    return labels[4:-2]
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
      [('English', 'sebtype-en'), ('中文', 'sebtype-zh'), ('日本語', 'sebtype-hira')])
check('starts in English', im(), 'keyboard-us')
CTRL, ALT = 4, 8
check("Fcitx5's own hotkeys reach the app: Ctrl+; Ctrl+Alt+Shift+U Ctrl+Shift+U Super+` Super+;",
      [taken(0x3b, 47, CTRL), taken(0x55, 30, CTRL | ALT | SHIFT), taken(0x55, 30, CTRL | SHIFT),
       taken(0x60, 49, SUPER), taken(0x3b, 47, SUPER)], [False] * 5)
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
# The input method's language is the current one, as rime's (zh) and mozc's (ja) were: classicui draws the
# Chinese or Japanese forms of a glyph by it
lang_code = lambda: next(m[5] for m in call(*CONTROLLER, 'AvailableInputMethods')[0] if m[0] == 'sebtype')
check('its language is zh in 中文', lang_code(), 'zh')
pick('mozc'); pick('keyboard-us')
check('after picking 日本語 then English, Win+Space returns to 日本語', win_space(), 'mozc')
check('its language is ja in 日本語', lang_code(), 'ja')
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
ascii_mode = lambda: call(*SEBTYPE, 'State')[1]
shift_tap(); check('Shift tap in 中文 turns its English mode on', (ascii_mode(), im()), (True, 'rime'))
shift_tap(); check('Shift tap again turns it off', (ascii_mode(), im()), (False, 'rime'))
fcitx.terminate(); fcitx.wait(10)
sys.exit(0 if ok else 1)
PY
  local rc=$? p
  for p in $(pgrep -x fcitx5); do
    grep -qzx "HOME=$h" "/proc/$p/environ" 2>/dev/null && kill "$p"
  done
  return $rc
}
if command -v fcitx5 dbus-run-session >/dev/null && python3 -c 'from gi.repository import Gio' 2>/dev/null; then
  check win-space-and-tray-menu win_space
else result SKIP win-space-and-tray-menu "needs fcitx5, dbus-run-session and python3-gobject"
fi

rerun() {
  echo 'XMODIFIERS=@im=fcitx' > "$fake/session-env"
  local o; o=$(fake_run < /dev/null) || return 1; echo "$o"
  grep -q '^done: 1 change(s)' <<<"$o" && grep -q "install SebType's input method" <<<"$o"
}
check rerun-only-asks-for-missing-package rerun

# SebType's input method (#190) is installed after a yes, and a rerun leaves it. The RPM is a placeholder.
sebtype_install() {
  local o; rm -f "$fake/sudo.log"; : > "$fake/sebtype"
  o=$(echo y | fake_run) || return 1; echo "$o"
  grep -q "^change: install SebType's input method" <<<"$o" &&
    [[ $(cat "$fake/sudo.log") == "sudo dnf install -y $h/scratch/SebType/cache/sebtype/${sebtype_rpm##*/}" &&
      $(cat "$fake/sebtype") == "$SEBTYPE_VERSION-$SEBTYPE_RPM_RELEASE" ]] || return 1
  o=$(fake_run < /dev/null) || return 1; echo "$o"
  ! grep -q "SebType's input method" <<<"$o"
}
check sebtype-install sebtype_install

# SebType's librime (#101) replaces Fedora's after a yes, a rerun leaves it, --undo-librime brings back
# Fedora's once, and a package of another version is left alone with a warning. The RPMs are placeholders,
# so nothing is built.
own_swap() { # Fedora's-version-release package rpm [package rpm...]: setup checks the first package
  local fedora=$1 pkgs=() rpms=() p o
  shift
  while (($#)); do pkgs+=("$1"); rpms+=("$2"); shift 2; done
  for o in "${rpms[@]}"; do mkdir -p "${o%/*}"; : > "$o"; done; rm -f "$fake/sudo.log"
  for p in "${pkgs[@]}"; do echo -n "$fedora" > "$fake/$p"; done
  # The checks before this one install it when the full set runs, but a selected run leaves it
  # missing: setup would then ask for it too and take the one `y` that answers this package's question.
  [[ -s $fake/sebtype ]] || echo -n "$SEBTYPE_VERSION-$SEBTYPE_RPM_RELEASE" > "$fake/sebtype"
  p=${pkgs[0]}
  o=$(echo y | fake_run) || return 1; echo "$o"
  grep -q "^change: replace $p .* with SebType's build" <<<"$o" &&
    [[ $(cat "$fake/sudo.log") == "sudo dnf install -y ${rpms[*]}" && $(cat "$fake/$p") == *.sebtype* ]] || return 1
  o=$(fake_run < /dev/null) || return 1; echo "$o"
  ! grep -q " $p " <<<"$o" || return 1
  o=$(fake_run "--undo-$p" < /dev/null) || return 1; echo "$o"
  [[ $(tail -1 "$fake/sudo.log") == "sudo dnf distro-sync -y ${pkgs[*]}" && $(cat "$fake/$p") == "$fedora" ]] &&
    o=$(fake_run "--undo-$p" < /dev/null) && [[ -z $o ]] || return 1
  echo -n 9.9.9-1.fc45 > "$fake/$p"
  o=$(fake_run < /dev/null) || return 1; echo "$o"
  grep -q "^warning: $p 9.9.9-1.fc45 isn't the version" <<<"$o" && [[ $(wc -l < "$fake/sudo.log") == 2 ]]
}
# librime with its Lua plugin, which must be the same build
check librime-install-and-undo own_swap "$LIBRIME_VERSION-$LIBRIME_FEDORA_RELEASE" \
  librime "$h/scratch/SebType/cache/librime/librime-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm" \
  librime-lua "$h/scratch/SebType/cache/librime/librime-lua-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm" \
  librime-octagram "$h/scratch/SebType/cache/librime/librime-octagram-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm"
# Fcitx5's own settings (#182): setup removes kcm-fcitx5 and fcitx5-configtool after a yes, a rerun
# leaves it, and --undo-fcitx5 puts both back.
fcitx5_settings() {
  local o p
  for p in kcm-fcitx5 fcitx5-configtool; do echo -n 5.1.16-1.fc44 > "$fake/$p"; done; rm -f "$fake/sudo.log"
  # Installed, so the one `y` answers this question (as in own_swap)
  [[ -s $fake/sebtype ]] || echo -n "$SEBTYPE_VERSION-$SEBTYPE_RPM_RELEASE" > "$fake/sebtype"
  o=$(echo y | fake_run) || return 1; echo "$o"
  grep -q "^change: remove kcm-fcitx5 fcitx5-configtool, Fcitx5's own settings" <<<"$o" &&
    [[ $(head -1 "$fake/sudo.log") == 'sudo dnf remove -y kcm-fcitx5 fcitx5-configtool' && ! -s $fake/kcm-fcitx5 && ! -s $fake/fcitx5-configtool ]] || return 1
  o=$(fake_run < /dev/null) || return 1; echo "$o"
  ! grep -q "remove kcm-fcitx5" <<<"$o" || return 1
  o=$(fake_run --undo-fcitx5 < /dev/null) || return 1; echo "$o"
  grep -q 'sudo dnf install -y kcm-fcitx5 fcitx5-configtool' "$fake/sudo.log" && [[ -s $fake/kcm-fcitx5 && -s $fake/fcitx5-configtool ]] || return 1
  : > "$fake/kcm-fcitx5"; : > "$fake/fcitx5-configtool"  # removed again, so the later checks' `y` isn't taken
}
check fcitx5-settings-removed-and-restored fcitx5_settings
# The grammar plugin (#127): a missing librime-octagram is installed, Fedora's beside Fedora's librime and
# SebType's build beside SebType's (Fedora's requires Fedora's librime).
octagram() {
  local ours=$h/scratch/SebType/cache/librime/librime-octagram-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm release o
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
check upgrade-from-old-icon-theme old_icon_theme
check undo-configurator-and-reinstall undo_configurator
# A Configurator stuck holding sync's schedule lock (#401): the uninstall waits 30 s for it, then removes
# sync anyway and warns.
undo_lock_held() {
  local s=$h/.local/share/sebtype o t0
  mkdir -p "$s"; : > "$s/schedule.lock"; echo '{}' > "$s/sync.json"
  flock "$s/schedule.lock" sleep 50 & local holder=$!
  sleep 0.5; t0=$SECONDS
  o=$(fake_run --undo-configurator < /dev/null); local rc=$?
  pkill -P "$holder" sleep; wait "$holder"; echo "$o"
  ((rc == 0 && SECONDS - t0 >= 29)) && grep -q "^warning: .*held sync's schedule lock for 30 s" <<<"$o" &&
    [[ ! -e $s/sync.json && ! -e $s/schedule.lock ]] && fake_run < /dev/null > /dev/null
}
check undo-configurator-with-schedule-lock-held undo_lock_held
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

# Setup's user part as the sebtype RPM installs it (sebtype-setup, #421), the release's packages installed, on
# a fresh account with no checkout: it builds and installs nothing, takes the RPM's Configurator, Chinese data
# and tray entry, and a rerun changes nothing.
from_rpm() {
  local f=$fake/from-rpm o; local h=$f/home d=$f/home/.local/share
  mkdir -p "$h/.config" "$d"
  echo -n "$SEBTYPE_VERSION-$SEBTYPE_RPM_RELEASE" > "$f/sebtype"
  echo -n "$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE" > "$f/librime"
  echo 'XMODIFIERS=@im=fcitx' > "$f/session-env"
  run() { env -i PATH="$fake/bin:$PATH" HOME="$h" FAKE="$f" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$d" \
    timeout 60 "$own/usr/libexec/sebtype/setup-ime.sh" < /dev/null; }
  o=$(run) || return 1; echo "$o"
  [[ ! -e $f/sudo.log ]] && ! grep -qE '^warning: librime|Build SebType|Rust' <<<"$o" && grep -q 'Default us 1 sebtype $' "$f/set.log" &&
    cmp "$own/usr/libexec/sebtype/sebtype-configurator" "$d/sebtype/configurator/sebtype-configurator" &&
    cmp "$own/usr/libexec/sebtype/sebtype-configurator.png" "$d/icons/hicolor/192x192/apps/sebtype-configurator.png" &&
    cmp ../../linux/data/notificationitem.conf "$d/fcitx5/addon/notificationitem.conf" &&
    [[ $(cat "$d/fcitx5/rime/sebtype-data.txt") == "$(sha256sum < "$own/usr/libexec/sebtype/rime-data.zip" | cut -d' ' -f1)" ]] &&
    [[ -f $d/fcitx5/rime/build/rime_ice.table.bin ]] || return 1
  o=$(run) || return 1; echo "$o"
  grep -q '^done: 0 change(s)' <<<"$o"
}
check setup-from-rpm from_rpm

# Offline Fcitx5 profile update (#442): when Fcitx5 isn't running, setup writes ~/.config/fcitx5/profile
# directly — fresh profile, existing keyboard-us/rime/mozc profile, and an existing profile with an extra IM
# (hangul) and custom layout/group preserved — and a rerun makes no profile change.
offline_profile() {
  local f=$fake/offline o p
  local h=$f/home
  p=$h/.config/fcitx5/profile
  mkdir -p "$h/.config/fcitx5" "$h/.local/share" "$h/scratch/SebType/cache"
  ln -sf "$rime_data" "$h/scratch/SebType/cache/"
  : > "$f/no-fcitx"
  echo -n "$SEBTYPE_VERSION-$SEBTYPE_RPM_RELEASE" > "$f/sebtype"
  echo -n "$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE" > "$f/librime"
  echo 'XMODIFIERS=@im=fcitx' > "$f/session-env"
  run() { env -i PATH="$fake/bin:$PATH" HOME="$h" FAKE="$f" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" \
    timeout 60 ./setup-ime.sh < /dev/null; }
  # 1. Fresh profile (no file yet)
  o=$(run) || return 1; echo "$o"
  grep -qx 'Default Layout=us' "$p" && grep -qx 'DefaultIM=sebtype' "$p" && grep -qx 'Name=sebtype' "$p" &&
    ! grep -qxE 'Name=(keyboard-us|rime|mozc)' "$p" || return 1
  # Idempotent rerun
  o=$(run) || return 1
  ! grep -q 'fcitx5/profile' <<<"$o" || return 1
  # 2. Existing profile with keyboard-us, rime, mozc
  cat > "$p" <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=keyboard-us

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=rime
Layout=

[Groups/0/Items/2]
Name=mozc
Layout=

[GroupOrder]
0=Default
EOF
  o=$(run) || return 1; echo "$o"
  grep -qx 'DefaultIM=sebtype' "$p" && grep -qx 'Name=sebtype' "$p" &&
    [[ $(grep -c '^\[Groups/0/Items/' "$p") == 1 ]] &&
    ! grep -qxE 'Name=(keyboard-us|rime|mozc)' "$p" &&
    ls "$h"/.local/share/sebtype/backup/*/profile >/dev/null || return 1
  # 3. Existing profile with an extra IM (hangul), custom Default Layout, and a second group
  cat > "$p" <<'EOF'
[Groups/0]
Name=Default
Default Layout=gb
DefaultIM=keyboard-us

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=hangul
Layout=kr

[Groups/0/Items/2]
Name=rime
Layout=

[Groups/1]
Name=Other
Default Layout=de
DefaultIM=keyboard-de

[Groups/1/Items/0]
Name=keyboard-de
Layout=

[GroupOrder]
0=Default
1=Other
EOF
  o=$(run) || return 1; echo "$o"
  grep -qx 'Default Layout=gb' "$p" && grep -qx 'DefaultIM=sebtype' "$p" &&
    grep -qx 'Name=sebtype' "$p" && grep -qx 'Name=hangul' "$p" && grep -qx 'Layout=kr' "$p" &&
    grep -qx '\[Groups/1\]' "$p" && grep -qx 'Name=keyboard-de' "$p" && grep -qx '1=Other' "$p" &&
    ! grep -qxE 'Name=(keyboard-us|rime|mozc)' "$p" || return 1
}
check offline-profile-update offline_profile

! grep -q '^FAIL' "$results"
