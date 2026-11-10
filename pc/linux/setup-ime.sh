#!/usr/bin/env bash
# SebType Linux setup: Fcitx5 input (Chinese with Rime, Japanese with Mozc, plain English) in every app
# on a KDE Plasma Wayland session, XWayland apps included. Fedora-family systems (dnf/rpm).
# Per-user config only; sudo is used only to install missing packages, after asking.
# Safe to rerun. --dry-run prints what it would change and changes nothing. --undo-icons switches back
# from SebType's tray icon theme to the one it inherits from, and removes it. --undo-mozc puts Fedora's
# fcitx5-mozc back in place of SebType's build. --undo-configurator removes the SebType Configurator app
# and its Picnic candidate window theme (settings made with it stay in Rime's and Mozc's files).
# Why each step exists, and the app checklist: pc/linux/README.md.
set -euo pipefail

dry=0 undo_icons=0 undo_mozc=0 undo_configurator=0
case ${1-} in
  --dry-run) dry=1 ;;
  --undo-icons) undo_icons=1 ;;
  --undo-mozc) undo_mozc=1 ;;
  --undo-configurator) undo_configurator=1 ;;
  '') ;;
  *) echo "usage: $0 [--dry-run | --undo-icons | --undo-mozc | --undo-configurator]" >&2; exit 2 ;;
esac
here=$(dirname "$0")

config=${XDG_CONFIG_HOME:-$HOME/.config}
data=${XDG_DATA_HOME:-$HOME/.local/share}
backup=$data/sebtype/backup/$(date +%Y%m%d-%H%M%S)
changes=0
todo=0

# change "what": counts one change and prints it; returns true when it should be applied.
change() {
  changes=$((changes + 1))
  if ((dry)); then echo "would: $1"; return 1; fi
  echo "change: $1"
}
warn() { echo "warning: $1"; todo=$((todo + 1)); }
save() { mkdir -p "$backup"; cp -p "$1" "$backup/"; }

# Tray icons (#63): an icon theme "SebType" that holds only the Fcitx5 status icons (pc/icons, Set E) and
# inherits everything else from the theme that was active, so other icons stay as they were.
theme=$data/icons/SebType
icon_theme() { kreadconfig6 --file kdeglobals --group Icons --key Theme; }
set_icon_theme() { # writes kdeglobals and tells running KDE apps (the tray too) to reload their icons
  kwriteconfig6 --file kdeglobals --group Icons --key Theme "$1"
  busctl --user emit /KIconLoader org.kde.KIconLoader iconChanged i 0 2>/dev/null || true
  busctl --user emit /KGlobalSettings org.kde.KGlobalSettings notifyChange ii 4 0 2>/dev/null || true
}
inherited=$(icon_theme)
[[ $inherited == SebType ]] && inherited=$(sed -n 's/^Inherits=//p' "$theme/index.theme" 2>/dev/null)
inherited=${inherited:-breeze}  # Plasma's default when kdeglobals names none

if ((undo_icons)); then
  if [[ $(icon_theme) == SebType ]]; then echo "change: icon theme back to $inherited"; set_icon_theme "$inherited"; fi
  if [[ -d $theme ]]; then echo "change: remove $theme"; rm -r "$theme"; fi
  exit 0
fi

# SebType Configurator (#72, step 14): the app, its launcher and icon, and the Picnic candidate window
# theme it installs when 主题 → 候选窗 is Picnic. The theme remembers the look it replaced.
app_dir=$data/sebtype/configurator app_bin=$data/sebtype/configurator/sebtype-configurator
app_desktop=$data/applications/sebtype-configurator.desktop
app_icon=$data/icons/hicolor/192x192/apps/sebtype-configurator.png
picnic_theme=$data/fcitx5/themes/sebtype-picnic classicui=$config/fcitx5/conf/classicui.conf
if ((undo_configurator)); then
  for f in "$app_desktop" "$app_icon"; do [[ -f $f ]] && { echo "change: remove $f"; rm "$f"; }; done
  [[ -d $app_dir ]] && { echo "change: remove $app_dir"; rm -r "$app_dir"; }
  if [[ -f $classicui ]] && grep -q '^Theme=sebtype-picnic$' "$classicui"; then
    prev=$picnic_theme/previous
    t=$(sed -n 's/^Theme=//p' "$prev" 2>/dev/null); d=$(sed -n 's/^DarkTheme=//p' "$prev" 2>/dev/null)
    echo "change: candidate window theme back to ${t:-default}"
    sed -i "s/^Theme=sebtype-picnic\$/Theme=${t:-default}/; s/^DarkTheme=sebtype-picnic\$/DarkTheme=${d:-default}/" "$classicui"
    busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 ReloadAddonConfig s classicui 2>/dev/null || true
  fi
  [[ -d $picnic_theme ]] && { echo "change: remove $picnic_theme"; rm -r "$picnic_theme"; }
  exit 0
fi

command -v rpm >/dev/null || { echo "This setup supports Fedora-family systems (rpm/dnf) only." >&2; exit 1; }

# SebType's fcitx5-mozc (#66): Fedora's package rebuilt with a patch that gives Japanese's English mode
# a Caps Lock icon. The undo goes back to the Fedora release in the repositories.
# shellcheck source-path=SCRIPTDIR source=mozc/versions.sh
source "$here/mozc/versions.sh"
mozc_installed=$(rpm -q --qf '%{VERSION}-%{RELEASE}' fcitx5-mozc 2>/dev/null) || mozc_installed=
restart_note="Fcitx5 loads the new fcitx5-mozc once it restarts: turn System Settings → Keyboard → Virtual Keyboard off and back on, or log in again"
if ((undo_mozc)); then
  if [[ $mozc_installed == *.sebtype* ]]; then
    echo "change: replace SebType's fcitx5-mozc $mozc_installed with Fedora's"
    sudo dnf distro-sync -y fcitx5-mozc
    echo "$restart_note"
  fi
  exit 0
fi

# 1. Packages. The gtk2/qt5 modules serve XWayland and older apps; fcitx5-mozc is the Japanese engine.
pkgs=(fcitx5 fcitx5-autostart fcitx5-qt fcitx5-qt5 fcitx5-qt6 fcitx5-gtk fcitx5-gtk2 fcitx5-gtk3 fcitx5-gtk4
  fcitx5-rime fcitx5-mozc kcm-fcitx5)
missing=()
for p in "${pkgs[@]}"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
if ((${#missing[@]})); then
  if change "install packages ${missing[*]} (asks before using sudo)"; then
    read -rp "Install ${missing[*]} with 'sudo dnf install'? [y/N] " answer || answer=
    if [[ $answer == [yY]* ]]; then sudo dnf install -y "${missing[@]}"
    else warn "packages not installed: ${missing[*]}"; fi
  fi
  mozc_installed=$(rpm -q --qf '%{VERSION}-%{RELEASE}' fcitx5-mozc 2>/dev/null) || mozc_installed=
fi

# 1b. SebType's fcitx5-mozc in place of Fedora's (#66), so Japanese's English mode shows A with Caps Lock
# on. Built from Fedora's source package by mozc/build.sh (about an hour the first time, in a container).
# A Fedora update to another version replaces it; then Japanese shows a with Caps Lock on until
# mozc/versions.sh follows that version.
built_rpm=$MOZC_CACHE/rpms/$MOZC_RPM
case $mozc_installed in
  "$MOZC_VERSION-$SEBTYPE_RELEASE" | '') ;;
  "$MOZC_VERSION-$MOZC_FEDORA_RELEASE" | "$MOZC_VERSION-"*.sebtype*)
    if change "replace fcitx5-mozc $mozc_installed with SebType's build $SEBTYPE_RELEASE, Fedora's plus a Caps Lock icon (asks before using sudo; undo: $0 --undo-mozc)"; then
      read -rp "Build SebType's fcitx5-mozc if needed and install it with 'sudo dnf install'? [y/N] " answer || answer=
      if [[ $answer == [yY]* ]]; then
        [[ -f $built_rpm ]] || "$here/mozc/build.sh" >/dev/null
        sudo dnf install -y "$built_rpm"
        busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && warn "$restart_note"
      else warn "fcitx5-mozc stays Fedora's: Japanese shows a, not A, with Caps Lock on"; fi
    fi ;;
  *) warn "fcitx5-mozc $mozc_installed isn't the version SebType's build is for ($MOZC_VERSION): Japanese shows a, not A, with Caps Lock on until pc/linux/mozc/versions.sh follows it" ;;
esac

# 2. KWin starts Fcitx5 as the Wayland input method (System Settings → Keyboard → Virtual Keyboard).
# Native Wayland GTK, Qt and Electron apps get the IME through it with no environment variables.
fcitx_desktop=/usr/share/applications/org.fcitx.Fcitx5.desktop
if [[ $(kreadconfig6 --file kwinrc --group Wayland --key InputMethod) != "$fcitx_desktop" ]]; then
  if change "set KWin's virtual keyboard to Fcitx 5 in $config/kwinrc"; then
    kwriteconfig6 --file kwinrc --group Wayland --key InputMethod "$fcitx_desktop"
    qdbus=$(command -v qdbus6 || command -v qdbus-qt6 || true)
    [[ -n $qdbus ]] && "$qdbus" org.kde.KWin /KWin reconfigure >/dev/null
  fi
fi

# 3. XWayland apps (Steam, WINE, Java, Xlib) reach Fcitx5 through XIM, picked by XMODIFIERS.
# Written per user only when the session doesn't already have it (e.g. from /etc/environment).
imfile=$config/environment.d/90-sebtype-im.conf
if [[ $(systemctl --user show-environment | sed -n 's/^XMODIFIERS=//p') != @im=fcitx ]] &&
  ! grep -qx 'XMODIFIERS=@im=fcitx' "$imfile" 2>/dev/null; then
  if change "write XMODIFIERS=@im=fcitx to $imfile (applies at next login)"; then
    mkdir -p "${imfile%/*}"
    echo 'XMODIFIERS=@im=fcitx' > "$imfile"
  fi
fi

# 4. A global GTK_IM_MODULE/QT_IM_MODULE/... overrides Wayland text-input and makes candidate windows
# flicker. Report it with its location; don't edit files outside this account's SebType config.
while IFS= read -r hit; do
  warn "global IM module set, remove it unless an app needs it: $hit"
done < <(grep -HnsE '^[[:space:]]*(export[[:space:]]+)?[A-Z0-9]+_IM_MODULE=' \
  /etc/environment /etc/environment.d/*.conf /usr/lib/environment.d/*.conf "$config"/environment.d/*.conf \
  "$config"/plasma-workspace/env/*.sh /etc/profile /etc/profile.d/*.sh \
  ~/.profile ~/.bash_profile ~/.bashrc ~/.zshenv ~/.zprofile || true)
while IFS= read -r var; do
  warn "global IM module in the session environment: $var"
done < <(systemctl --user show-environment | grep -E '^[A-Z0-9]+_IM_MODULE=' || true)

# 5. Dead Flatpak overrides from older attempts to fix QQ/WeChat input: the apps aren't installed as
# Flatpaks, so the overrides do nothing. Removed after a backup.
for id in com.qq.QQ com.tencent.WeChat; do
  f=$data/flatpak/overrides/$id
  [[ -f $f ]] || continue
  flatpak info "$id" >/dev/null 2>&1 && continue
  if change "remove unused Flatpak override $f (backup in $backup)"; then save "$f"; rm "$f"; fi
done

# 6. Per-app launcher fixes, in the user's copy of the launcher (created from the system one if needed).
# launcher <desktop id> <text every Exec line must contain> <sed edit> <description>
launcher() {
  local id=$1 want=$2 edit=$3 what=$4
  local dest=$data/applications/$id src
  src=$dest; [[ -f $src ]] || src=/usr/share/applications/$id
  [[ -f $src ]] || return 0
  grep '^Exec=' "$src" | grep -qvF -- "$want" || return 0
  change "$what in $dest" || return 0
  local tmp; tmp=$(mktemp)
  sed "$edit" "$src" > "$tmp"
  if [[ $src == "$dest" ]]; then save "$dest"
  else sed -i '0,/^\[Desktop Entry\]/s//&\nX-SebType-Managed=true/' "$tmp"; fi
  mkdir -p "${dest%/*}"; mv "$tmp" "$dest"; chmod 644 "$dest"
}
# WeChat bundles its own Qt and runs on X11; it needs Fcitx's Qt module by name.
launcher wechat.desktop QT_IM_MODULE=fcitx '/QT_IM_MODULE=fcitx/!s/^Exec=/Exec=env QT_IM_MODULE=fcitx /' \
  "set QT_IM_MODULE=fcitx for WeChat"
# Chromium/Electron apps on native Wayland that the live test showed get no IME without the flag.
# None so far: Discord (Chromium 152) and Chrome 157 work without it (pc/linux/README.md).
wayland_ime_apps=()  # entries: <desktop id>:<binary path>
for app in "${wayland_ime_apps[@]}"; do
  id=${app%%:*} bin=${app#*:}
  launcher "$id" --enable-wayland-ime "/--enable-wayland-ime/!s|^\(Exec=.*$bin\)\( \|$\)|\1 --enable-wayland-ime\2|" \
    "add --enable-wayland-ime to ${id%.desktop}"
done

# 7. Input methods: English, Chinese, Japanese in the first Fcitx5 group (EN → 中 → 日), keeping any others.
if busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1; then
  call() { busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 "$@"; }
  group=$(call InputMethodGroups | awk '{print $3}' | tr -d '"')
  # Quoted strings of the reply: <layout> then <im> <im layout> pairs.
  mapfile -t q < <(call InputMethodGroupInfo s "$group" | grep -o '"[^"]*"' | tr -d '"')
  layout=${q[0]} ims=()
  for ((i = 1; i < ${#q[@]}; i += 2)); do ims+=("${q[i]}"); done
  add=()
  for im in keyboard-us rime mozc; do [[ " ${ims[*]} " == *" $im "* ]] || add+=("$im"); done
  if ((${#add[@]})) && change "add ${add[*]} to Fcitx5 input method group $group"; then
    args=()
    for im in "${ims[@]}" "${add[@]}"; do args+=("$im" ""); done
    call SetInputMethodGroupInfo 'ssa(ss)' "$group" "$layout" $((${#args[@]} / 2)) "${args[@]}"
    call Save
  fi
else
  warn "Fcitx5 isn't running; log out and in again, then rerun to set up its input methods"
fi

# 8. Super+Space is the only language switch, and it cycles EN → 中 → 日. It is Fcitx5's
# enumerate-forward key: a trigger key would only toggle English and the last language. Fcitx5's other
# switchers are cleared: Shift_L (AltTriggerKeys), Control+Shift+Shift_L, and the group switch, which
# defaults to Super+Space too. Rime still handles its own Shift tap for English inside Chinese.
# ShareInputState=All: one language for every window, as on Windows (#42), not one per window.
fcitx_conf=$config/fcitx5/config
fcitx_global() { # prints the config with those settings, keeping everything else
  awk -v cleared='TriggerKeys AltTriggerKeys EnumerateBackwardKeys EnumerateGroupForwardKeys EnumerateGroupBackwardKeys' '
    BEGIN { n = split(cleared " EnumerateForwardKeys", keys, " ")
      for (i = 1; i <= n; i++) { own["[Hotkey/" keys[i] "]"] = 1; own[keys[i]] = 1 } }
    /^\[/ { sec = $0; skip = (sec in own) }
    skip || (sec == "[Hotkey]" && (substr($0, 1, index($0, "=") - 1) in own)) { next }
    sec == "[Behavior]" && /^ShareInputState=/ { next }
    { print }
    $0 == "[Hotkey]" { hotkey = 1; gsub(" ", "=\n", cleared); print cleared "=" }
    $0 == "[Behavior]" { behavior = 1; print "ShareInputState=All" }
    END { if (!hotkey) { gsub(" ", "=\n", cleared); print "[Hotkey]\n" cleared "=" }
      if (!behavior) print "\n[Behavior]\nShareInputState=All"
      print "\n[Hotkey/EnumerateForwardKeys]\n0=Super+space" }' "$@"
}
canon() { awk '/^\[/ { sec = $0; next } NF && !/^#/ { print sec "\t" $0 }' | sort; }
src=$fcitx_conf; [[ -f $src ]] || src=/dev/null
want=$(fcitx_global "$src")
if [[ $(canon < "$src") != "$(canon <<<"$want")" ]] &&
  change "make Super+Space the only language switch, shared by all windows, in $fcitx_conf (backup in $backup)"; then
  [[ -f $fcitx_conf ]] && save "$fcitx_conf"
  mkdir -p "${fcitx_conf%/*}"; printf '%s\n' "$want" > "$fcitx_conf"
  busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 ReloadConfig 2>/dev/null || true
fi

# 9. Japanese: a Shift tap and Alt+` toggle あ and direct English (Decisions #2), in Mozc's own keymap,
# so no addon or patch is needed. fcitx5-mozc sends Mozc a bare Shift only when it is released with no
# other key pressed since, so Shift+letter (Mozc's English run) and Shift in shortcuts never match it.
# Mozc keeps a custom keymap only as a whole table, so mozc-keymap.tsv is Mozc's MS-IME keymap plus
# Alt+` and Shift lines for each state (F6–F10 and Space stay as they are). It goes into Mozc's binary config, config1.db (a mozc.config.Config
# protobuf): session_keymap (field 41) = CUSTOM (0) and custom_keymap_table (field 42), other settings
# kept. Mozc reads it at start, so a running mozc_server is stopped; fcitx5-mozc restarts it on the next key.
mozc_db=$config/mozc/config1.db
mozc_want=$(python3 - "$mozc_db" "$here/mozc-keymap.tsv" <<'PY' | base64 -w0
import sys

def varint(b, i):
    n = shift = 0
    while True:
        c = b[i]; i += 1; n |= (c & 0x7F) << shift; shift += 7
        if c < 0x80: return n, i

def enc(n):
    out = bytearray()
    while True:
        out.append(n & 0x7F | (0x80 if n > 0x7F else 0)); n >>= 7
        if not n: return bytes(out)

try: data = open(sys.argv[1], 'rb').read()
except FileNotFoundError: data = b''
table = open(sys.argv[2], 'rb').read()
before, after, i = b'', b'', 0
while i < len(data):  # copy every field but 41 and 42, in place
    start = i; key, i = varint(data, i); wire = key & 7
    if wire == 0: _, i = varint(data, i)
    elif wire == 1: i += 8
    elif wire == 2: n, i = varint(data, i); i += n
    elif wire == 5: i += 4
    else: sys.exit(f'{sys.argv[1]}: unexpected protobuf wire type {wire}')
    if key >> 3 < 41: before += data[start:i]
    elif key >> 3 > 42: after += data[start:i]
sys.stdout.buffer.write(before + enc(41 << 3) + enc(0) + enc(42 << 3 | 2) + enc(len(table)) + table + after)
PY
)
if [[ $(base64 -w0 "$mozc_db" 2>/dev/null) != "$mozc_want" ]] &&
  change "set Mozc's keymap to MS-IME plus Shift tap and Alt+\` for あ ⇄ English in $mozc_db (backup in $backup)"; then
  [[ -f $mozc_db ]] && save "$mozc_db"
  mkdir -p "${mozc_db%/*}"; base64 -d <<<"$mozc_want" > "$mozc_db"
  mapfile -t pids < <(pgrep -u "$(id -u)" -x mozc_server)
  ((${#pids[@]})) && kill "${pids[@]}"
  # fcitx5-mozc reads the keys that work in direct English mode once, when Fcitx5 starts.
  busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 &&
    warn "Shift tap and Alt+\` from English back to あ work once Fcitx5 restarts: log in again, or turn System Settings → Keyboard → Virtual Keyboard off and back on"
fi

# 10. Plasma binds Alt+` (and Meta+`) to "Walk Through Windows of Current Application", so Mozc would
# never see Alt+`. The action keeps Meta+`.
kga() { busctl --user call org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel "$@"; }
walk=(kwin "Walk Through Windows of Current Application" KWin "Walk Through Windows of Current Application")
alt_grave=$((0x08000000 | 0x60)) meta_grave=$((0x10000000 | 0x60))  # Qt::AltModifier/MetaModifier | Qt::Key_QuoteLeft
if [[ " $(kga shortcutKeys as 4 "${walk[@]}" 2>/dev/null) " == *" $alt_grave "* ]] &&
  change "free Alt+\` from Plasma's \"${walk[1]}\" shortcut, which keeps Meta+\`"; then
  kga setForeignShortcutKeys 'asa(ai)' 4 "${walk[@]}" 1 4 "$meta_grave" 0 0 0
fi

# 11. Tray icons: SebType's Set E keycaps for EN, 中, あ, ア, and a / A (Caps Lock) in the English modes.
# Fcitx5 asks for these names; input-keyboard (EN) and fcitx-rime come from the active theme, so only a
# theme of our own set as active overrides them. fcitx_rime_latin_upper is what fcitx5-rime asks for in
# English with Caps Lock on; SebType's fcitx5-mozc build (step 1b) asks for <English mode icon>_upper.
icons=$here/../icons
icon_names=(input-keyboard:en fcitx-rime:zh fcitx_rime_latin:zh-a fcitx_rime_latin_upper:zh-A
  fcitx_mozc_hiragana:hira fcitx_mozc_katakana_full:kata fcitx_mozc_katakana_half:kata
  fcitx_mozc_direct:ja-a fcitx_mozc_alpha_half:ja-a fcitx_mozc_alpha_full:ja-a
  fcitx_mozc_direct_upper:ja-A fcitx_mozc_alpha_half_upper:ja-A fcitx_mozc_alpha_full_upper:ja-A)
want_theme=$(mktemp -d)
dirs=(16 20 22 24 32 scalable)
{
  printf '[Icon Theme]\nName=SebType\nComment=SebType tray icons over %s\nInherits=%s\nDirectories=%s\n' \
    "$inherited" "$inherited" "$(IFS=,; echo "${dirs[*]/%//status}")"
  for d in "${dirs[@]}"; do
    if [[ $d == scalable ]]; then printf '\n[%s/status]\nSize=48\nMinSize=33\nMaxSize=512\nType=Scalable\nContext=Status\n' "$d"
    else printf '\n[%s/status]\nSize=%s\nType=Fixed\nContext=Status\n' "$d" "$d"; fi
  done
} > "$want_theme/index.theme"
for d in "${dirs[@]}"; do
  mkdir -p "$want_theme/$d/status"
  for n in "${icon_names[@]}"; do cp "$icons/$d/${n#*:}.svg" "$want_theme/$d/status/${n%%:*}.svg"; done
done
if { ! diff -rq "$want_theme" "$theme" >/dev/null 2>&1 || [[ $(icon_theme) != SebType ]]; } &&
  change "install SebType's tray icons as icon theme $theme over $inherited, and make it active (undo: $0 --undo-icons)"; then
  rm -rf "$theme"; mkdir -p "${theme%/*}"; cp -r "$want_theme" "$theme"; chmod 755 "$theme"
  set_icon_theme SebType
fi
rm -r "$want_theme"

# 12. Chinese reads 中文 in the switch popup and the tray text (#69). fcitx5-rime's label is the first
# character of the schema name (雾 from 雾凇拼音), unless the name starts with "."; then Fcitx5 shows the
# input method's own label. So the schema name becomes ".中文" (its id stays rime_ice, so learned words
# stay) and this account's copy of Rime's input method entry is named and labelled 中文. The same patch
# sets typo correction (#46, in SebType's Chinese data) to a PC keyboard's neighbour keys.
rime_dir=$data/fcitx5/rime rime_custom=$data/fcitx5/rime/rime_ice.custom.yaml
rime_im=$data/fcitx5/inputmethod/rime.conf
want_im=$'[InputMethod]\nName=中文\nIcon=fcitx-rime\nLabel=中文\nLangCode=zh\nAddon=rime\nConfigurable=True'
lines='  schema/name: ".中文"  # SebType: Fcitx5 shows rime.conf'\''s label 中文 instead of 雾 (#69)
  sebtype_typo/keyboard: pc  # SebType: typo correction for a PC keyboard (#46)'
src=$rime_custom; [[ -f $src ]] || src=/dev/null
want_custom=$(awk -v lines="$lines" '/^  (schema\/name|sebtype_typo\/keyboard):/ { next } { print } /^patch:/ && !done { print lines; done = 1 }
  END { if (!done) print "patch:\n" lines }' "$src")
if { [[ $(cat "$rime_im" 2>/dev/null) != "$want_im" ]] || [[ $(cat "$src") != "$want_custom" ]]; } &&
  change "label Chinese 中文 instead of 雾 and set typo correction to a PC keyboard in $rime_im and $rime_custom (backup in $backup)"; then
  for f in "$rime_im" "$rime_custom"; do [[ -f $f ]] && save "$f"; done
  mkdir -p "${rime_im%/*}" "$rime_dir"
  printf '%s\n' "$want_im" > "$rime_im"; printf '%s\n' "$want_custom" > "$rime_custom"
  # Fcitx5 reads input method entries when it starts, and Rime redeploys then too.
  busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 &&
    warn "Chinese reads 中文 once Fcitx5 restarts: log in again, or turn System Settings → Keyboard → Virtual Keyboard off and back on"
fi

# 13. Ctrl+Shift+F switches Chinese between simplified and traditional output at any time (#36), as on
# Windows; Ctrl+F alone stays Find. It toggles rime-ice's traditionalization option, which converts only
# what Rime outputs, so learned words stay shared. Both keysyms, because Shift may send either. The
# bindings are appended to default.yaml's, keeping the file's other patches.
default_custom=$rime_dir/default.custom.yaml
src=$default_custom; [[ -f $src ]] || src=/dev/null
if ! grep -q 'toggle: traditionalization, accept: Control+Shift+f }' "$src" ||
  ! grep -q 'toggle: traditionalization, accept: Control+Shift+F }' "$src"; then
  want_custom=$(awk '
    function binds() { for (k = 1; k <= 2; k++) print "    - { when: always, toggle: traditionalization, accept: Control+Shift+" substr("fF", k, 1) " }" }
    /toggle: traditionalization, accept: Control\+Shift\+[fF] }/ { next }
    { print } /^  key_binder\/bindings\/\+:/ && !done { binds(); done = 1 }
    END { if (!done) { print (NR ? "" : "patch:") "\n  # SebType: Ctrl+Shift+F switches 简/繁 (#36)\n  key_binder/bindings/+:"; binds() } }' "$src")
  # A file without key_binder/bindings/+ gets it at its end, which is inside its patch: block.
  if change "Ctrl+Shift+F switches Chinese 简/繁 in $default_custom (backup in $backup)"; then
    [[ -f $default_custom ]] && save "$default_custom"
    mkdir -p "$rime_dir"; printf '%s\n' "$want_custom" > "$default_custom"
    busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 &&
      warn "Ctrl+Shift+F switches 简/繁 once Rime redeploys: right-click the tray icon → Deploy"
  fi
fi

# 14. SebType Configurator (#72): SebType's settings app, "SebType Configurator" in the app menu. Built
# from pc/configurator with Rust's cargo (a few minutes the first time) whenever its sources are newer
# than the build, then copied into this account with its launcher and the phone's icon.
src_app=$here/../configurator built=$src_app/target/release/sebtype-configurator
want_desktop="[Desktop Entry]
Type=Application
Name=SebType Configurator
Name[zh_CN]=SebType 设置
Comment=SebType's settings: languages, candidate window, privacy and backup
Comment[zh_CN]=SebType 输入法设置：语言、候选窗、隐私和备份
Exec=$app_bin
Icon=sebtype-configurator
Categories=Settings;
Keywords=SebType;IME;input method;Rime;Mozc;Fcitx;输入法;
StartupWMClass=sebtype-configurator"
stale=$( [[ -x $built ]] && find "$src_app" -path "$src_app/target" -prune -o -type f -newer "$built" -print -quit)
if [[ ! -x $built || -n $stale ]] || ! cmp -s "$built" "$app_bin" || [[ $(cat "$app_desktop" 2>/dev/null) != "$want_desktop" ]] ||
  ! cmp -s "$here/../../sebtype/res-stable/mipmap-xxxhdpi/ic_launcher_round.png" "$app_icon"; then
  if change "install SebType Configurator in $app_dir with its app-menu entry (undo: $0 --undo-configurator)"; then
    if [[ ! -x $built || -n $stale ]]; then
      if command -v cargo >/dev/null; then
        cargo build --release --quiet --manifest-path "$src_app/Cargo.toml"
      else
        warn "SebType Configurator needs Rust to build: install it from https://rustup.rs, then run this again"
      fi
    fi
    if [[ -x $built ]]; then
      mkdir -p "$app_dir" "${app_desktop%/*}" "${app_icon%/*}"
      cp "$built" "$app_bin.new" && mv "$app_bin.new" "$app_bin"
      cp "$here/../../sebtype/res-stable/mipmap-xxxhdpi/ic_launcher_round.png" "$app_icon"
      printf '%s\n' "$want_desktop" > "$app_desktop"
    fi
  fi
fi

# Self-check of the live session.
parent=$(ps -o ppid= -C fcitx5 | head -1 | tr -d ' ')
[[ -n $parent && $(ps -o comm= -p "$parent") == kwin_wayland ]] ||
  warn "Fcitx5 isn't running under KWin yet; log out and in again"
[[ $(systemctl --user show-environment | sed -n 's/^XMODIFIERS=//p') == @im=fcitx ]] ||
  warn "XMODIFIERS=@im=fcitx isn't in this session yet; log out and in again"

if ((dry)); then echo "dry run: $changes change(s) to make, $todo warning(s)"
else echo "done: $changes change(s), $todo warning(s)"; fi
