#!/usr/bin/env bash
# SebType Linux setup: Fcitx5 input (Chinese with Rime, Japanese with Mozc, plain English) in every app
# on a KDE Plasma Wayland session, XWayland apps included. Fedora-family systems (dnf/rpm).
# Per-user config only; sudo is used only to install missing packages, after asking.
# Safe to rerun. --dry-run prints what it would change and changes nothing.
# Why each step exists, and the app checklist: pc/linux/README.md.
set -euo pipefail

dry=0
case ${1-} in
  --dry-run) dry=1 ;;
  '') ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

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

command -v rpm >/dev/null || { echo "This setup supports Fedora-family systems (rpm/dnf) only." >&2; exit 1; }

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
fi

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

# Self-check of the live session.
parent=$(ps -o ppid= -C fcitx5 | head -1 | tr -d ' ')
[[ -n $parent && $(ps -o comm= -p "$parent") == kwin_wayland ]] ||
  warn "Fcitx5 isn't running under KWin yet; log out and in again"
[[ $(systemctl --user show-environment | sed -n 's/^XMODIFIERS=//p') == @im=fcitx ]] ||
  warn "XMODIFIERS=@im=fcitx isn't in this session yet; log out and in again"

if ((dry)); then echo "dry run: $changes change(s) to make, $todo warning(s)"
else echo "done: $changes change(s), $todo warning(s)"; fi
