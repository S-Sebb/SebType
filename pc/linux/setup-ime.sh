#!/usr/bin/env bash
# SebType Linux setup: Fcitx5 input (Chinese with Rime, Japanese with Mozc, plain English) in every app
# on a KDE Plasma Wayland session, XWayland apps included. Fedora-family systems (dnf/rpm).
# Per-user config only; sudo is used only to install missing packages, after asking.
# Safe to rerun. --dry-run prints what it would change and changes nothing. --undo-icons switches back
# from SebType's tray icon theme to the one it inherits from, and removes it. --undo-mozc, --undo-rime and
# --undo-librime put Fedora's fcitx5-mozc, fcitx5-rime and librime back in place of SebType's builds.
# --undo-configurator removes the SebType Configurator app
# and its Picnic candidate window theme (settings made with it stay in Rime's and Mozc's files).
# --undo-names gives the input methods back Fcitx5's own names (Keyboard - English (US), Rime, Mozc).
# --undo-chinese-data puts Rime's folder back as it was before SebType's Chinese data.
# Why each step exists, and the app checklist: pc/linux/README.md.
set -euo pipefail

dry=0 undo_icons=0 undo_mozc=0 undo_rime=0 undo_librime=0 undo_configurator=0 undo_names=0 undo_chinese_data=0
case ${1-} in
  --dry-run) dry=1 ;;
  --undo-icons) undo_icons=1 ;;
  --undo-mozc) undo_mozc=1 ;;
  --undo-rime) undo_rime=1 ;;
  --undo-librime) undo_librime=1 ;;
  --undo-configurator) undo_configurator=1 ;;
  --undo-names) undo_names=1 ;;
  --undo-chinese-data) undo_chinese_data=1 ;;
  '') ;;
  *) echo "usage: $0 [--dry-run | --undo-icons | --undo-mozc | --undo-rime | --undo-librime | --undo-configurator | --undo-names | --undo-chinese-data]" >&2; exit 2 ;;
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

# Input method names (steps 12 and 12b): this account's copies of Fcitx5's input method entries, and the
# Rime schema name that makes Chinese read 中文.
im_dir=$data/fcitx5/inputmethod rime_dir=$data/fcitx5/rime rime_custom=$data/fcitx5/rime/rime_ice.custom.yaml
names_note="Fcitx5 shows the new names once it restarts: log in again, or turn System Settings → Keyboard → Virtual Keyboard off and back on"
if ((undo_names)); then
  for f in "$im_dir"/{rime,mozc,keyboard-us}.conf; do [[ -f $f ]] && { echo "change: remove $f"; rm "$f"; changes=1; }; done
  if grep -q '^  schema/name: ".中文"' "$rime_custom" 2>/dev/null; then
    echo "change: drop the 中文 schema name from $rime_custom"
    sed -i '/^  schema\/name: ".中文"/d' "$rime_custom"; changes=1
  fi
  ((changes)) && busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && echo "$names_note"
  exit 0
fi

# SebType's Chinese data (step 13b): files.txt lists, in order, each path in Rime's folder it placed or
# removed (directories end in /), and old/ holds the ones that were there before.
rime_before=$data/sebtype/rime-before rime_marker=$rime_dir/sebtype-data.txt
# Rime applies its data and patches when it deploys. SebType's tray menu has no Deploy (#117), so a running
# Fcitx5 is asked for one; without one, Rime deploys when Fcitx5 starts.
deploy_rime() {
  busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 || return 0
  echo "Rime deploys the changes in the background"
  busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetConfig sv fcitx://config/addon/rime/deploy s '' || true
}
if ((undo_chinese_data)); then
  if [[ -f $rime_before/files.txt ]]; then
    echo "change: put $rime_dir back as it was before SebType's Chinese data"
    tac "$rime_before/files.txt" | while IFS= read -r f; do
      if [[ $f == */ ]]; then rmdir --ignore-fail-on-non-empty "$rime_dir/$f"; continue; fi
      rm -f "$rime_dir/$f"
      [[ -e $rime_before/old/$f ]] && cp -p "$rime_before/old/$f" "$rime_dir/$f"
    done
    rm -f "$rime_marker"; rm -r "$rime_before"
    deploy_rime
  fi
  exit 0
fi

command -v rpm >/dev/null || { echo "This setup supports Fedora-family systems (rpm/dnf) only." >&2; exit 1; }

# SebType's fcitx5-mozc (#66), fcitx5-rime (#117) and librime (#101): SebType's source in pc/, packaged
# as Fedora's packages (mozc/ and rime/). The undo goes back to the Fedora release in the repositories.
# shellcheck source-path=SCRIPTDIR source=mozc/versions.sh
source "$here/mozc/versions.sh"
# shellcheck source-path=SCRIPTDIR source=rime/versions.sh
source "$here/rime/versions.sh"
installed() { rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null || true; }
restart_note() { echo "Fcitx5 loads the new $1 once it restarts: turn System Settings → Keyboard → Virtual Keyboard off and back on, or log in again"; }
undo_build() { # package [packages built with it...]
  local now; now=$(installed "$1")
  if [[ $now == *.sebtype* ]]; then
    echo "change: replace SebType's $* $now with Fedora's"
    sudo dnf distro-sync -y "$@"
    restart_note "$1"
  fi
  exit 0
}
# librime's packages here: librime and its plugins, which must come from the same build
librime_installed() { local p; for p in "${LIBRIME_PACKAGES[@]}"; do [[ -z $(installed "$p") ]] || echo "$p"; done; }
((undo_mozc)) && undo_build fcitx5-mozc
((undo_rime)) && undo_build fcitx5-rime
((undo_librime)) && { mapfile -t librime_pkgs < <(librime_installed); undo_build "${librime_pkgs[@]}"; }

# 1. Packages. The gtk2/qt5 modules serve XWayland and older apps; librime-octagram is the Rime plugin
# that reads the Chinese data's grammar file, as the phone and Windows do (#127); fcitx5-mozc is the
# Japanese engine.
pkgs=(fcitx5 fcitx5-autostart fcitx5-qt fcitx5-qt5 fcitx5-qt6 fcitx5-gtk fcitx5-gtk2 fcitx5-gtk3 fcitx5-gtk4
  fcitx5-rime librime-octagram fcitx5-mozc kcm-fcitx5)
missing=()
for p in "${pkgs[@]}"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
if ((${#missing[@]})); then
  if change "install packages ${missing[*]} (asks before using sudo)"; then
    read -rp "Install ${missing[*]} with 'sudo dnf install'? [y/N] " answer || answer=
    if [[ $answer == [yY]* ]]; then
      # librime's plugins come from librime's own build: SebType's, once librime is (1b)
      if [[ " ${missing[*]} " == *" librime-octagram "* && $(installed librime) == *.sebtype* ]]; then
        octagram_rpm=$(librime_rpm librime-octagram)
        [[ -f $octagram_rpm ]] || "$here/rime/build.sh" librime >/dev/null
        missing=("${missing[@]/#librime-octagram/$octagram_rpm}")
      fi
      sudo dnf install -y "${missing[@]}"
      [[ " ${missing[*]} " == *octagram* ]] && busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 &&
        warn "$(restart_note "grammar plugin")"
    else warn "packages not installed: ${missing[*]}"; fi
  fi
fi

# 1b. SebType's fcitx5-mozc, fcitx5-rime and librime in place of Fedora's, built from Fedora's source
# packages by mozc/build.sh (about an hour the first time, in a container) and rime/build.sh (a minute or
# five). A Fedora update to another version replaces them; then setup-ime.sh warns until
# <dir>/versions.sh follows it.
# own_build <package> <version> <Fedora's release> <SebType's release> <build command> <what it adds>
#   <what is missing without it> <rpm...>: the package's RPM first, then any built with it
own_build() {
  local pkg=$1 version=$2 fedora=$3 ours=$4 build=$5 adds=$6 without=$7 now answer
  shift 7
  now=$(installed "$pkg")
  case $now in
    "$version-$ours" | '') ;;
    "$version-$fedora" | "$version-"*.sebtype*)
      if change "replace $pkg $now with SebType's build $ours, Fedora's plus $adds (asks before using sudo; undo: $0 --undo-${pkg#fcitx5-})"; then
        read -rp "Build SebType's $pkg if needed and install it with 'sudo dnf install'? [y/N] " answer || answer=
        if [[ $answer == [yY]* ]]; then
          # shellcheck disable=SC2086  # word-split: a script and its arguments
          [[ -f $1 ]] || $build >/dev/null
          sudo dnf install -y "$@"
          busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && warn "$(restart_note "$pkg")"
        else warn "$pkg stays Fedora's: $without"; fi
      fi ;;
    *) warn "$pkg $now isn't the version SebType's build is for ($version): $without until pc/linux/$(basename "$(dirname "${build%% *}")")/versions.sh follows it" ;;
  esac
}
own_build fcitx5-mozc "$MOZC_VERSION" "$MOZC_FEDORA_RELEASE" "$SEBTYPE_RELEASE" "$here/mozc/build.sh" \
  "a Caps Lock icon and Japanese's one menu switch, あ → ア" "Japanese shows a, not A, with Caps Lock on, and its menu keeps Mozc's input modes and tools" \
  "$MOZC_CACHE/rpms/$MOZC_RPM"
own_build fcitx5-rime "$RIME_VERSION" "$RIME_FEDORA_RELEASE" "$RIME_SEBTYPE_RELEASE" "$here/rime/build.sh" \
  "Chinese's one menu switch, 简 → 繁" "Chinese's menu keeps Rime's schema list, Deploy and Synchronize" "$RIME_CACHE/$RIME_RPM"
# librime's typo correction knows a PC keyboard's vertical neighbours too (pc/librime), so
# a typo such as xkaoshi (k for the i above it) gives 小时; its plugins are rebuilt with it.
librime_rpms=()
while read -r p; do librime_rpms+=("$(librime_rpm "$p")"); done < <(librime_installed)
own_build librime "$LIBRIME_VERSION" "$LIBRIME_FEDORA_RELEASE" "$LIBRIME_SEBTYPE_RELEASE" "$here/rime/build.sh librime" \
  "a PC keyboard's layout in Chinese typo correction" "Chinese typos onto the key above or below aren't corrected" "${librime_rpms[@]}"

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

# 8. Super+Space is the only language switch, and it toggles English and the last other language (#93):
# it is Fcitx5's trigger key, which switches between the group's first input method (English) and the
# one used last, and a pick from the tray menu becomes that one. EnumerateWithTriggerKeys=False keeps
# it a toggle while Super stays held. Fcitx5's other switchers are cleared: Shift_L (AltTriggerKeys),
# Control+Shift+Shift_L (EnumerateForwardKeys), and the group switch, which defaults to Super+Space too.
# Rime still handles its own Shift tap for English inside Chinese.
# ShareInputState=All: one language for every window, as on Windows (#42), not one per window.
fcitx_conf=$config/fcitx5/config
fcitx_global() { # prints the config with those settings, keeping everything else
  awk -v cleared='AltTriggerKeys EnumerateForwardKeys EnumerateBackwardKeys EnumerateGroupForwardKeys EnumerateGroupBackwardKeys' '
    BEGIN { n = split(cleared " TriggerKeys EnumerateWithTriggerKeys", keys, " ")
      for (i = 1; i <= n; i++) { own["[Hotkey/" keys[i] "]"] = 1; own[keys[i]] = 1 }
      gsub(" ", "=\n", cleared); cleared = cleared "=\nEnumerateWithTriggerKeys=False" }
    /^\[/ { sec = $0; skip = (sec in own) }
    skip || (sec == "[Hotkey]" && (substr($0, 1, index($0, "=") - 1) in own)) { next }
    sec == "[Behavior]" && /^ShareInputState=/ { next }
    { print }
    $0 == "[Hotkey]" { hotkey = 1; print cleared }
    $0 == "[Behavior]" { behavior = 1; print "ShareInputState=All" }
    END { if (!hotkey) print "[Hotkey]\n" cleared
      if (!behavior) print "\n[Behavior]\nShareInputState=All"
      print "\n[Hotkey/TriggerKeys]\n0=Super+space" }' "$@"
}
canon() { awk '/^\[/ { sec = $0; next } NF && !/^#/ { print sec "\t" $0 }' | sort; }
src=$fcitx_conf; [[ -f $src ]] || src=/dev/null
want=$(fcitx_global "$src")
if [[ $(canon < "$src") != "$(canon <<<"$want")" ]] &&
  change "make Super+Space the only language switch (English ⇄ the last other language), shared by all windows, in $fcitx_conf (backup in $backup)"; then
  [[ -f $fcitx_conf ]] && save "$fcitx_conf"
  mkdir -p "${fcitx_conf%/*}"; printf '%s\n' "$want" > "$fcitx_conf"
  busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 ReloadConfig 2>/dev/null || true
fi

# 9. Japanese: a Shift tap toggles あ and direct English, and Alt+` あ and ア (Decisions #2, menu hotkeys),
# in Mozc's own keymap. fcitx5-mozc sends Mozc a bare Shift only when it is released with no other key
# pressed since, so Shift+letter (Mozc's English run) and Shift in shortcuts never match it. Alt+` is
# Mozc's InputModeSwitchKanaType, which SebType's build (pc/fcitx5-mozc) makes a two-way switch.
# Mozc keeps a custom keymap only as a whole table, so mozc-keymap.tsv is Mozc's MS-IME keymap plus
# Shift lines for each state and Alt+` (F6–F10 and Space stay as they are). It goes into Mozc's binary config, config1.db (a mozc.config.Config
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
  change "set Mozc's keymap to MS-IME plus Shift tap for あ ⇄ English and Alt+\` for あ ⇄ ア in $mozc_db (backup in $backup)"; then
  [[ -f $mozc_db ]] && save "$mozc_db"
  mkdir -p "${mozc_db%/*}"; base64 -d <<<"$mozc_want" > "$mozc_db"
  mapfile -t pids < <(pgrep -u "$(id -u)" -x mozc_server)
  ((${#pids[@]})) && kill "${pids[@]}"
  # fcitx5-mozc reads the keys that work in direct English mode once, when Fcitx5 starts.
  busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 &&
    warn "the Shift tap from English back to あ works once Fcitx5 restarts: log in again, or turn System Settings → Keyboard → Virtual Keyboard off and back on"
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
# Fcitx5 asks for these names (fcitx_mozc is Japanese's entry in the tray menu); input-keyboard (EN) and
# fcitx-rime come from the active theme, so only a
# theme of our own set as active overrides them. fcitx_rime_latin_upper is what fcitx5-rime asks for in
# English with Caps Lock on; SebType's fcitx5-mozc build (step 1b) asks for <English mode icon>_upper.
icons=$here/../icons
icon_names=(input-keyboard:en fcitx-rime:zh fcitx_rime_latin:zh-a fcitx_rime_latin_upper:zh-caps
  fcitx_mozc:hira fcitx_mozc_hiragana:hira fcitx_mozc_katakana_full:kata fcitx_mozc_katakana_half:kata
  fcitx_mozc_direct:ja-a fcitx_mozc_alpha_half:ja-a fcitx_mozc_alpha_full:ja-a
  fcitx_mozc_direct_upper:ja-caps fcitx_mozc_alpha_half_upper:ja-caps fcitx_mozc_alpha_full_upper:ja-caps)
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

rime_changed=0  # steps 12 to 13b set it; 13c deploys
# 12. Chinese reads 中文 in the switch popup and the tray text (#69). fcitx5-rime's label is the first
# character of the schema name (雾 from 雾凇拼音), unless the name starts with "."; then Fcitx5 shows the
# input method's own label. So the schema name becomes ".中文" (its id stays rime_ice, so learned words
# stay) and this account's copy of Rime's input method entry is named and labelled 中文. The same patch
# sets typo correction (#46, in SebType's Chinese data) to a PC keyboard's neighbour keys.
rime_im=$im_dir/rime.conf
want_im=$'[InputMethod]\nName=中文\nIcon=fcitx-rime\nLabel=中文\nLangCode=zh\nAddon=rime\nConfigurable=True'
lines='  schema/name: ".中文"  # SebType: Fcitx5 shows rime.conf'\''s label 中文 instead of 雾 (#69)
  sebtype_typo/keyboard: pc  # SebType: typo correction for a PC keyboard (#46)'
src=$rime_custom; [[ -f $src ]] || src=/dev/null
want_custom=$(awk -v lines="$lines" '/^  (schema\/name|sebtype_typo\/keyboard):/ { next } { print } /^patch:/ && !done { print lines; done = 1 }
  END { if (!done) print "patch:\n" lines }' "$src")
if { [[ $(cat "$rime_im" 2>/dev/null) != "$want_im" ]] || [[ $(cat "$src") != "$want_custom" ]]; } &&
  change "label Chinese 中文 instead of 雾 and set typo correction to a PC keyboard in $rime_im and $rime_custom (backup in $backup; undo: $0 --undo-names)"; then
  for f in "$rime_im" "$rime_custom"; do [[ -f $f ]] && save "$f"; done
  mkdir -p "${rime_im%/*}" "$rime_dir"
  printf '%s\n' "$want_im" > "$rime_im"; printf '%s\n' "$want_custom" > "$rime_custom"
  rime_changed=1
  # Fcitx5 reads input method entries when it starts.
  busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && warn "$names_note"
fi

# 12b. Japanese reads 日本語 and English reads English in the tray menu and the switch popup (#92), not
# Mozc and Keyboard - English (US): this account's copies of their input method entries, renamed. An
# entry here also names the keyboard addon's built-in keyboard-us; the layout still comes from its id.
for im in 'mozc 日本語 fcitx_mozc あ ja mozc' 'keyboard-us English input-keyboard en en keyboard'; do
  read -r id name icon label lang addon <<<"$im"
  f=$im_dir/$id.conf
  want_im="[InputMethod]
Name=$name
Icon=$icon
Label=$label
LangCode=$lang
Addon=$addon
Configurable=True"
  if [[ $(cat "$f" 2>/dev/null) != "$want_im" ]] && change "name $id $name in $f (undo: $0 --undo-names)"; then
    [[ -f $f ]] && save "$f"
    mkdir -p "$im_dir"; printf '%s\n' "$want_im" > "$f"
    busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && warn "$names_note"
  fi
done

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
    rime_changed=1
  fi
fi

# 13a. 6 candidates per page (Decisions #2, #163; rime-ice has 5), as on Windows. Only when the user has no
# page size of their own: the Configurator writes theirs here too, and shows 6 when there is none.
src=$default_custom; [[ -f $src ]] || src=/dev/null
if ! grep -q '^  menu/page_size:' "$src" &&
  change "6 Chinese candidates per page in $default_custom (backup in $backup)"; then
  want_custom=$(awk '{ print } /^patch:/ && !done { print line; done = 1 }
    END { if (!done) print "patch:\n" line }' line='  menu/page_size: 6  # SebType: 6 candidates per page (#163)' "$src")
  # Step 13 may have saved the file as it was already.
  [[ -f $default_custom && ! -f $backup/default.custom.yaml ]] && save "$default_custom"
  mkdir -p "$rime_dir"; printf '%s\n' "$want_custom" > "$default_custom"
  rime_changed=1
fi

# 13b. Chinese uses SebType's Chinese data (#102), the data the phone and Windows use: rime-ice's schemas and
# Lua with 白霜's dictionary and SebType's typo correction (#46), its tables prebuilt, built (cached) by
# tools/rime-data/build.sh. It goes into Rime's folder over the files of the same name, as on Windows;
# learned words, *.custom.yaml and an existing custom_phrase.txt stay. Dictionary sources the data has
# prebuilt tables for are removed, or Rime would compile them instead. What it replaces or removes is
# kept in $rime_before first, so --undo-chinese-data puts the folder back.
rime_tmp=$(mktemp -d)
if "$here/../../tools/rime-data/build.sh" "$rime_tmp" > "$rime_tmp/build.log" 2>&1; then
  rime_zip=$rime_tmp/rime/rime-data.zip rime_id=$(sha256sum < "$rime_zip" | cut -d' ' -f1)
  if [[ $(cat "$rime_marker" 2>/dev/null) != "$rime_id" ]] &&
    change "install SebType's Chinese data with typo correction in $rime_dir (the files it replaces kept in $rime_before; undo: $0 --undo-chinese-data)"; then
    new=$rime_tmp/data
    unzip -q "$rime_zip" -d "$new"
    [[ -f $rime_dir/custom_phrase.txt ]] && rm "$new/custom_phrase.txt"
    mkdir -p "$rime_before/old" "$rime_dir"; touch "$rime_before/files.txt"
    while IFS= read -r f; do # directories first, so the undo, going backwards, empties them before removing
      grep -qxF -- "$f" "$rime_before/files.txt" && continue
      if [[ $f == */ ]]; then [[ -d $rime_dir/$f ]] && continue
      elif [[ -e $rime_dir/$f ]]; then mkdir -p "$(dirname "$rime_before/old/$f")"; cp -p "$rime_dir/$f" "$rime_before/old/$f"; fi
      echo "$f" >> "$rime_before/files.txt"
    done < <(cd "$new" && find . -mindepth 1 -type d -printf '%P/\n' | sort; find . -type f -printf '%P\n' | sort
      for t in build/*.table.bin; do t=${t#build/}; echo "${t%.table.bin}.dict.yaml"; done)
    for t in "$new"/build/*.table.bin; do t=${t##*/}; rm -f "$rime_dir/${t%.table.bin}.dict.yaml"; done
    cp -r "$new/." "$rime_dir/"
    echo "$rime_id" > "$rime_marker"
    rime_changed=1
  fi
else
  warn "SebType's Chinese data doesn't build, so Chinese has no typo correction: $(tail -1 "$rime_tmp/build.log")"
fi
rm -r "$rime_tmp"

# 13c. A running Fcitx5's Rime deploys whatever steps 12 to 13b changed.
((rime_changed)) && deploy_rime

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
