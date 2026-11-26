#!/usr/bin/env bash
# SebType Linux setup: Fcitx5 input with SebType's input method (English, Chinese with Rime, Japanese with
# Mozc, #190) in every app on a KDE Plasma Wayland session, XWayland apps included. Fedora-family systems (dnf/rpm).
# Per-user config only; sudo is used only to install missing packages, after asking.
# Safe to rerun. --dry-run prints what it would change and changes nothing. --undo-all, run before
# `dnf remove sebtype`, undoes it all, the account's Fcitx5 groups and keys included. --undo-librime puts Fedora's
# librime back where SebType 0.2.0 or older installed its own build in its place. --undo-fcitx5 puts back Fcitx5's own settings (kcm-fcitx5,
# fcitx5-configtool).
# --undo-configurator removes the SebType Configurator app
# and its Picnic candidate window theme (settings made with it stay in Rime's and Mozc's files).
# --undo-names gives the input methods back Fcitx5's own names (Keyboard - English (US), Rime, Mozc).
# --undo-chinese-data puts Rime's folder back as it was before SebType's Chinese data.
# Why each step exists, and the app checklist: pc/linux/README.md.
# Run from a checkout, it builds SebType's packages, Configurator and Chinese data from it. Run as sebtype-setup,
# from the sebtype RPM (#421), it is the user part of a release's install or update: the release's packages are
# installed, and the Configurator, the Chinese data and the keymap come from beside it.
set -euo pipefail

dry=0 undo_all=0 undo_librime=0 undo_fcitx5=0 undo_configurator=0 undo_names=0 undo_chinese_data=0
case ${1-} in
  --dry-run) dry=1 ;;
  --undo-all) undo_all=1 ;;
  --undo-librime) undo_librime=1 ;;
  --undo-fcitx5) undo_fcitx5=1 ;;
  --undo-configurator) undo_configurator=1 ;;
  --undo-names) undo_names=1 ;;
  --undo-chinese-data) undo_chinese_data=1 ;;
  '') ;;
  *) echo "usage: $0 [--dry-run | --undo-all | --undo-librime | --undo-fcitx5 | --undo-configurator | --undo-names | --undo-chinese-data]" >&2; exit 2 ;;
esac
here=$(dirname "$(readlink -f "$0")")
checkout=0; [[ -f $here/../../linux/build.sh ]] && checkout=1

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

# KWin / Fcitx5 live-session helpers. KWin starts Fcitx5 as the Wayland input method (step 2).
fcitx_desktop=/usr/share/applications/org.fcitx.Fcitx5.desktop
kwin_reconfigure() {
  local qdbus
  qdbus=$(command -v qdbus6 || command -v qdbus-qt6 || true)
  if [[ -n $qdbus ]]; then "$qdbus" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
  else busctl --user call org.kde.KWin /KWin org.kde.KWin reconfigure >/dev/null 2>&1 || true; fi
}
fcitx_on_dbus() { busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1; }
fcitx_under_kwin() {
  local ppid
  while read -r ppid; do
    [[ -n $ppid && $(ps -o comm= -p "$ppid" 2>/dev/null || true) == kwin_wayland ]] && return 0
  done < <(ps -o ppid= -C fcitx5 2>/dev/null || true)
  return 1
}
wait_fcitx_up() {
  local i
  for ((i = 0; i < 25; i++)); do fcitx_on_dbus && return 0; sleep 0.2; done
  fcitx_on_dbus
}
wait_fcitx_down() {
  local i
  for ((i = 0; i < 25; i++)); do ! fcitx_on_dbus && ! fcitx_under_kwin && return 0; sleep 0.2; done
  ! fcitx_on_dbus
}
# Only the Fcitx5 that owns the session bus name, the one setup configures and restarts: another Fcitx5 of
# this user (a test's private one, or the desktop's while setup configures a test account) isn't ours (#535).
fcitx_has_deleted_libs() {
  local pid
  pid=$(busctl --user status org.fcitx.Fcitx5 2>/dev/null | sed -n 's/^PID=//p')
  [[ -n $pid ]] && grep -qE '(sebtype\.so|librime\.so).* \(deleted\)$' "/proc/$pid/maps" 2>/dev/null
}
# KWin reads its input method when told kwinrc changed (--notify; Plasma 6.8 no longer at reconfigure).
kwin_set_im() { kwriteconfig6 --notify --file kwinrc --group Wayland --key InputMethod "$1" && kwin_reconfigure; }
# Stops Fcitx5 under KWin and starts it again. A command given runs while it is stopped, which it must be for
# that: fails, running nothing, if Fcitx5 doesn't stop.
kwin_restart_fcitx5() {
  local s=0
  (
    restored=0
    _restore_kwin_im() {
      ((restored)) && return 0
      restored=1
      kwin_set_im "$fcitx_desktop"
    }
    trap '_restore_kwin_im || true' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    kwin_set_im "" || true
    if (($#)); then
      wait_fcitx_down || { echo "error: Fcitx5 didn't stop under KWin" >&2; exit 1; }
      "$@" || exit 1
    else wait_fcitx_down || true; fi
    _restore_kwin_im
  ) || s=$?
  wait_fcitx_up || true
  return "$s"
}
kwin_runs_fcitx() {
  command -v kreadconfig6 >/dev/null 2>&1 && command -v kwriteconfig6 >/dev/null 2>&1 &&
    busctl --user status org.kde.KWin >/dev/null 2>&1 &&
    [[ $(kreadconfig6 --file kwinrc --group Wayland --key InputMethod) == "$fcitx_desktop" ]]
}

# --undo-all (#582), before `dnf remove sebtype`: the undos below, then, with Fcitx5 stopped (it writes its
# groups over profile as it quits), Fcitx5's and Mozc's files back from the oldest backup that has each (later
# ones hold files SebType had already changed) and Fcitx5's own tray. A file no backup has stays: it was new
# with setup or already as setup wanted it. The backups move aside, so a later install's oldest are its own.
# fcitx5-rime's Rime stays in the groups while SebType is installed, so Fcitx5 starts again at once.
if ((undo_all)); then
  for u in configurator names chinese-data fcitx5 librime; do "$0" "--undo-$u"; done
  mozc=$config/mozc; [[ -d $HOME/.mozc ]] && mozc=$HOME/.mozc
  backups=$data/sebtype/backup
  put_back() {
    local f b LC_COLLATE=C  # <time>/ before the Configurator's <time>_2/
    for f in "$config/fcitx5/"{profile,config} "$config/fcitx5/conf/"{clipboard,unicode,quickphrase}.conf "$mozc/config1.db"; do
      b=("$backups"/*/"${f##*/}")
      [[ -f ${b[0]} ]] || continue
      echo "change: put back $f from ${b[0]}"
      mkdir -p "${f%/*}"; cp -p "${b[0]}" "$f"
    done
    f=$data/fcitx5/addon/notificationitem.conf
    if grep -qx 'Library=sebtype' "$f" 2>/dev/null; then echo "change: remove SebType's tray $f"; rm "$f"; fi
  }
  b=("$backups"/*/profile); [[ -f ${b[0]} ]] ||
    warn "no backup has Fcitx5's groups from before SebType (setup up to 0.2.0 kept none): once SebType is removed, add Rime back in Fcitx 5 Configuration"
  if kwin_runs_fcitx; then
    echo "change: stop Fcitx5 under KWin while its files go back, then start it again"
    kwin_restart_fcitx5 put_back
  else
    if fcitx_on_dbus; then
      echo "change: quit Fcitx5 while its files go back (it starts again at your next login)"
      busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 Exit
      wait_fcitx_down || { echo "error: Fcitx5 didn't quit: nothing put back" >&2; exit 1; }
    fi
    put_back
  fi
  if [[ -d $backups ]]; then
    echo "change: move $backups to $backups-until-${backup##*/}"
    mv "$backups" "$backups-until-${backup##*/}"
  fi
  echo "SebType's changes are undone: remove it with 'sudo dnf remove sebtype'"
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
  # Sync (#180): its half-hourly timer and network trigger (#377), its login in the keyring and its files.
  # The server's copy stays.
  # With the Configurator's schedule lock (sync.rs, schedule_locked), so a sync starting or ending or the
  # network trigger plans nothing once this has begun: each finds sync.json gone.
  sync_units=$config/systemd/user
  # The Configurator makes the lock before it schedules anything: without it there is nothing to wait for.
  # It holds it for seconds; one stuck holding it (suspended) mustn't stop the uninstall.
  if [[ -f $data/sebtype/schedule.lock ]]; then
    exec {schedule_lock}>"$data/sebtype/schedule.lock"
    flock -w 30 "$schedule_lock" || {
      warn "a SebType Configurator or sync has held sync's schedule lock for 30 s: removing sync without it; close it, or it may plan a sync again"
      exec {schedule_lock}>&-; unset schedule_lock
    }
  fi
  if [[ -f $sync_units/sebtype-sync.timer ]]; then
    echo "change: stop and remove SebType's sync timer and network trigger"
    systemctl --user disable --now sebtype-sync.timer sebtype-sync.path 2>/dev/null || true
    # A sync planned after the network changed, and a --network-changed waiting for the lock.
    systemctl --user stop sebtype-sync-soon.timer sebtype-sync-network.service 2>/dev/null || true  # fails for one not there
    rm -f "$sync_units"/sebtype-sync.{timer,path,service} "$sync_units"/sebtype-sync-network.service
    systemctl --user daemon-reload 2>/dev/null
  fi
  if [[ -f $data/sebtype/sync.json ]] && command -v secret-tool >/dev/null; then
    echo "change: remove SebType's sync login from the keyring"
    secret-tool clear service 'SebType sync' username login 2>/dev/null || true  # none there, or no keyring
  fi
  # The daily update check (#422), with a check still waiting on its notification, its state and downloads.
  if [[ -f $sync_units/sebtype-update.timer ]]; then
    echo "change: stop and remove SebType's daily update check"
    systemctl --user disable --now sebtype-update.timer 2>/dev/null || true
    systemctl --user stop sebtype-update.service 2>/dev/null || true
    rm -f "$sync_units"/sebtype-update.{timer,service}
    systemctl --user daemon-reload 2>/dev/null
  fi
  for updates in "${XDG_RUNTIME_DIR:-/nonexistent}/sebtype-updates" "${XDG_CACHE_HOME:-$HOME/.cache}/sebtype-updates"; do
    [[ -d $updates ]] && { echo "change: remove $updates"; rm -r "$updates"; }
  done
  for f in "$data"/sebtype/{sync.json,sync.lock,sebtype_sync.py,network-state,schedule.lock,update.json}; do
    # Released before it goes: a sync starting meanwhile would lock a new file while this holds the old (#401).
    [[ $f == */schedule.lock && -n ${schedule_lock-} ]] && exec {schedule_lock}>&-
    [[ -f $f ]] && { echo "change: remove $f"; rm "$f"; }
  done
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
# What a running Fcitx5 loads only when it starts: restarted once at the end, under KWin, so nothing waits
# for a login (#445).
restart_for=()
restart_later() {
  [[ " ${restart_for[*]} " == *" $1 "* ]] && return 0
  busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && restart_for+=("$1")
  return 0
}
# fcitx5-rime's entry as setup up to 0.2.0 named it 中文 (step 12 removes it now, #542).
old_rime_im=$'[InputMethod]\nName=中文\nIcon=fcitx-rime\nLabel=中文\nLangCode=zh\nAddon=rime\nConfigurable=True'
if ((undo_names)); then
  for f in "$im_dir"/{mozc,keyboard-us}.conf; do [[ -f $f ]] && { echo "change: remove $f"; rm "$f"; changes=1; }; done
  # A rime.conf of the person's own stays.
  f=$im_dir/rime.conf
  [[ $(cat "$f" 2>/dev/null) == "$old_rime_im" ]] && { echo "change: remove $f (backup in $backup)"; save "$f"; rm "$f"; changes=1; }
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
  busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetConfig sv fcitx://config/addon/sebtype/deploy s '' || true
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

# SebType's input method (#190): linux/, packaged by linux/build.sh, with SebType's librime (#101) inside (#527).
versions=$here/../../linux/versions.sh; ((checkout)) || versions=$here/versions.sh
# shellcheck source-path=SCRIPTDIR source=../../linux/versions.sh
source "$versions"
# A package's version-release, empty when it isn't installed (rpm -q prints that it isn't on stdout)
installed() { if rpm -q --quiet "$1" 2>/dev/null; then rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$1" | head -1; fi; }
restart_note() { echo "Fcitx5 loads the new $1 once it restarts: turn System Settings → Keyboard → Virtual Keyboard off and back on, or log in again"; }
# The librime packages releases up to 0.2.0-2 installed in place of Fedora's (#101), all from one *.sebtype* build. The
# add-on now has SebType's librime inside (#527); distro-sync brings back the repositories' Fedora release.
old_librime() { local p; for p in "${LIBRIME_PACKAGES[@]}"; do [[ $(installed "$p") != *.sebtype* ]] || echo "$p"; done; }
# Fcitx5's own settings, a second place to change Rime and Mozc behind SebType's back (Decisions #2, #182):
# its page in System Settings and its "Fcitx 5 Configuration" app. Setup removes them; --undo-fcitx5 puts them back.
fcitx5_settings=(kcm-fcitx5 fcitx5-configtool)
fcitx5_settings_installed() { local p; for p in "${fcitx5_settings[@]}"; do rpm -q "$p" >/dev/null 2>&1 && echo "$p"; done; true; }
if ((undo_librime)); then
  mapfile -t librime_pkgs < <(old_librime)
  if ((${#librime_pkgs[@]})); then
    echo "change: replace SebType's old ${librime_pkgs[*]} with Fedora's"
    sudo dnf distro-sync -y "${librime_pkgs[@]}"
    restart_note "librime (fcitx5-rime's; SebType's input method has its own)"
  fi
  exit 0
fi
if ((undo_fcitx5)); then
  missing=(); for p in "${fcitx5_settings[@]}"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if ((${#missing[@]})); then
    echo "change: install ${missing[*]}, Fcitx5's own settings"
    sudo dnf install -y "${missing[@]}"
  fi
  exit 0
fi

# 1. Packages. The gtk2/qt5 modules serve XWayland and older apps. SebType's input method itself, with
# librime and its Lua and grammar plugins inside, is step 1b.
pkgs=(fcitx5 fcitx5-autostart fcitx5-qt fcitx5-qt5 fcitx5-qt6 fcitx5-gtk fcitx5-gtk2 fcitx5-gtk3 fcitx5-gtk4)
missing=()
for p in "${pkgs[@]}"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
if ((${#missing[@]})); then
  if change "install packages ${missing[*]} (asks before using sudo)"; then
    read -rp "Install ${missing[*]} with 'sudo dnf install'? [y/N] " answer || answer=
    if [[ $answer == [yY]* ]]; then
      sudo dnf install -y "${missing[@]}"
    else warn "packages not installed: ${missing[*]}"; fi
  fi
fi
# Fcitx5's own settings go (above); the Configurator holds SebType's settings.
mapfile -t settings < <(fcitx5_settings_installed)
if ((${#settings[@]})) && change "remove ${settings[*]}, Fcitx5's own settings (asks before using sudo)"; then
  read -rp "Remove ${settings[*]} with 'sudo dnf remove'? [y/N] " answer || answer=
  if [[ $answer == [yY]* ]]; then sudo dnf remove -y "${settings[@]}"
  else warn "${settings[*]} stay installed"; fi
fi

# 1b. SebType's input method (#190), with SebType's librime and its plugins inside (#101, #527), built from
# SebType's source by linux/build.sh (about an hour the first time, in a container). Built from this checkout,
# not taken from a release (#421): a tree under test must run its own code. Run from the RPM, setup comes
# with the release's package, which the release's install or update installed.
sebtype_now=$(installed sebtype) sebtype_want=$SEBTYPE_VERSION-$SEBTYPE_RPM_RELEASE sebtype_coming=0
if ((checkout)) && [[ $sebtype_now != "$sebtype_want" ]] && { ((!dry)) || sebtype_coming=1; } &&
  change "install SebType's input method $sebtype_want, which hosts Rime and Mozc (asks before using sudo)"; then
  read -rp "Build SebType's input method if needed and install it with 'sudo dnf install'? [y/N] " answer || answer=
  if [[ $answer == [yY]* ]]; then
    key=$(sebtype_key); rpm=$(sebtype_rpm "$key")
    [[ -f $rpm ]] || SEBTYPE_SOURCES_KEY=$key "$here/../../linux/build.sh" >/dev/null
    sudo dnf install -y "$rpm"
    restart_later "SebType input method"
  else warn "SebType's input method isn't installed, so typing stays as it was"; fi
fi
# Releases up to 0.2.0-2 replaced Fedora's librime with SebType's *.sebtype* build; the release's install puts Fedora's
# back (linux/build-installer.sh), and so does the next system update.
mapfile -t librime_pkgs < <(old_librime)
if ((${#librime_pkgs[@]})); then
  if ((!checkout)); then warn "${librime_pkgs[*]} are SebType's old build, which the add-on no longer uses: $0 --undo-librime puts Fedora's back"
  elif change "replace SebType's old ${librime_pkgs[*]} with Fedora's: the input method has its own librime now (asks before using sudo)"; then
    read -rp "Replace them with 'sudo dnf distro-sync'? [y/N] " answer || answer=
    if [[ $answer == [yY]* ]]; then sudo dnf distro-sync -y "${librime_pkgs[@]}"
    else warn "${librime_pkgs[*]} stay SebType's old build"; fi
  fi
fi

# 2. KWin starts Fcitx5 as the Wayland input method (System Settings → Keyboard → Virtual Keyboard).
# Native Wayland GTK, Qt and Electron apps get the IME through it with no environment variables.
if command -v kreadconfig6 >/dev/null 2>&1 && command -v kwriteconfig6 >/dev/null 2>&1; then
  if [[ $(kreadconfig6 --file kwinrc --group Wayland --key InputMethod) != "$fcitx_desktop" ]]; then
    if change "set KWin's virtual keyboard to Fcitx 5 in $config/kwinrc"; then
      kwin_set_im "$fcitx_desktop"
      wait_fcitx_up || true
    fi
  fi
fi

# 3. XWayland apps (Steam, WINE, Java, Xlib) reach Fcitx5 through XIM, picked by XMODIFIERS.
# Written per user only when the session doesn't already have it (e.g. from /etc/environment).
imfile=$config/environment.d/90-sebtype-im.conf
if [[ $(systemctl --user show-environment 2>/dev/null | sed -n 's/^XMODIFIERS=//p' || true) != @im=fcitx ]] &&
  ! grep -qx 'XMODIFIERS=@im=fcitx' "$imfile" 2>/dev/null; then
  if change "write XMODIFIERS=@im=fcitx to $imfile (applies at next login)"; then
    mkdir -p "${imfile%/*}"
    echo 'XMODIFIERS=@im=fcitx' > "$imfile"
    systemctl --user set-environment XMODIFIERS=@im=fcitx 2>/dev/null || true
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

canon() { awk '/^\[/ { sec = $0; next } NF && !/^#/ { print sec "\t" $0 }' | sort; }

# Prints $1 (an Fcitx5 profile file, or /dev/null) updated so the first group has sebtype first in place of
# keyboard-us, rime and mozc, keeping any other IMs, Default Layout, and other groups. The first group is
# the one [GroupOrder] names first, not always [Groups/0]: Fcitx5 doesn't write its groups in order (#579).
fcitx_profile_update() {
  python3 - "$1" <<'PY'
import re, sys

path = sys.argv[1]
try:
    text = open(path, encoding='utf-8').read()
except FileNotFoundError:
    text = ''

sections = []
cur_name = None
cur_lines = []
for raw in text.splitlines():
    s = raw.strip()
    if s.startswith('[') and s.endswith(']'):
        if cur_name is not None:
            sections.append((cur_name, cur_lines))
        cur_name = s[1:-1]
        cur_lines = []
    elif cur_name is not None and s:
        cur_lines.append(raw)
if cur_name is not None:
    sections.append((cur_name, cur_lines))

def parse_kv(lines):
    out = []
    for l in lines:
        if '=' in l:
            k, v = l.split('=', 1)
            out.append((k, v))
    return out

group_names = {name: dict(parse_kv(lines)).get('Name') for name, lines in sections
               if re.fullmatch(r'Groups/\d+', name)}
order = [v for name, lines in sections if name == 'GroupOrder'
         for k, v in sorted(parse_kv(lines), key=lambda kv: int(kv[0]))]
first = next((sec for v in order for sec, n in group_names.items() if n == v), 'Groups/0')

g0_lines = None
g0_items = {}
other_sections = []
has_group_order = False
for name, lines in sections:
    if name == first:
        g0_lines = lines
    elif m := re.fullmatch(re.escape(first) + r'/Items/(\d+)', name):
        g0_items[int(m.group(1))] = dict(parse_kv(lines))
    else:
        if name == 'GroupOrder':
            has_group_order = True
        other_sections.append((name, lines))

if g0_lines is None:
    g0_kv = [('Name', 'Default'), ('Default Layout', 'us'), ('DefaultIM', 'sebtype')]
    group0_name = 'Default'
else:
    g0_kv = []
    seen_default_im = False
    seen_name = False
    seen_layout = False
    group0_name = 'Default'
    for k, v in parse_kv(g0_lines):
        if k == 'DefaultIM':
            g0_kv.append(('DefaultIM', 'sebtype'))
            seen_default_im = True
        else:
            if k == 'Name':
                seen_name = True
                group0_name = v or 'Default'
            elif k == 'Default Layout':
                seen_layout = True
            g0_kv.append((k, v))
    if not seen_name:
        g0_kv.insert(0, ('Name', 'Default'))
    if not seen_layout:
        g0_kv.append(('Default Layout', 'us'))
    if not seen_default_im:
        g0_kv.append(('DefaultIM', 'sebtype'))

sebtype_layout = ''
kept = []
for idx in sorted(g0_items):
    item = g0_items[idx]
    im = item.get('Name', '')
    layout = item.get('Layout', '')
    if im == 'sebtype':
        sebtype_layout = layout
    elif im and im not in ('keyboard-us', 'rime', 'mozc'):
        kept.append((im, layout))
items = [('sebtype', sebtype_layout)] + kept

out = [f'[{first}]']
for k, v in g0_kv:
    out.append(f'{k}={v}')
for idx, (im, layout) in enumerate(items):
    out.append('')
    out.append(f'[{first}/Items/{idx}]')
    out.append(f'Name={im}')
    out.append(f'Layout={layout}')
for name, lines in other_sections:
    out.append('')
    out.append(f'[{name}]')
    out.extend(lines)
if not has_group_order:
    out.append('')
    out.append('[GroupOrder]')
    out.append(f'0={group0_name}')
print('\n'.join(out))
PY
}

# 6b. If KDE KWin is managing Fcitx5 and Fcitx5 isn't running yet, doesn't know sebtype yet, or still
# holds deleted sebtype/librime libraries from an upgrade, toggle KWin's Virtual Keyboard off and back on
# so Fcitx5 starts fresh and loads SebType immediately without requiring a re-login (#442).
if ((!dry)) && kwin_runs_fcitx; then
  need_restart=0
  if ! fcitx_on_dbus; then
    need_restart=1
  elif [[ -n $(installed sebtype) || -f /usr/lib64/fcitx5/sebtype.so ]] &&
    ! busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 AvailableInputMethods 2>/dev/null | grep -q '"sebtype"'; then
    need_restart=1
  elif fcitx_has_deleted_libs; then
    need_restart=1
  fi
  if ((need_restart)) && change "restart Fcitx5 under KWin so it loads SebType"; then
    kwin_restart_fcitx5
    restart_for=()
  fi
fi

# The running Fcitx5's controller.
call() { busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 "$@"; }
# The running Fcitx5's groups in order, one a line: name, layout, then its input methods, each field ended by
# \x1f (a layout may be empty). Read as JSON: busctl's plain output escapes non-ASCII (a zh Fcitx5's 默认) and
# keeps a name's spaces and quotes, which no split survives. $1: only the first $1 groups. Fails, printing no
# more, when a group can't be read (gone since the list, or a failed call), never a line of two groups.
running_groups() {
  local g info
  call --json=short InputMethodGroups |
    python3 -c 'import json, sys; print(*json.load(sys.stdin)["data"][0][:int(sys.argv[1] or 0) or None], sep="\n")' "${1-}" |
    while IFS= read -r g; do
      info=$(call --json=short InputMethodGroupInfo s "$g" | python3 -c 'import json, sys
layout, ims = json.load(sys.stdin)["data"]
print(*(f + "\x1f" for f in [layout, *(im for im, _ in ims)]), sep="")') || exit 1
      printf '%s\x1f%s\n' "$g" "$info"
    done
}
# Prints the number and name ("<n><TAB><name>") of each Fcitx5 group with fcitx5-rime's rime, 0 for the first:
# the running Fcitx5's groups when it knows SebType's input method (step 7 changes those), else the profile's,
# numbered by [GroupOrder] (#579), as fcitx_profile_update picks the first. Both assume what Fcitx5 writes:
# [GroupOrder] keys 0=, 1=, … with no gap, and a Name= in each [Groups/N].
rime_groups() {
  if fcitx_on_dbus && call AvailableInputMethods 2>/dev/null | grep -q '"sebtype"'; then
    local groups
    groups=$(running_groups) || return 1  # none rather than a part
    awk -F '\x1f' '{ for (i = 3; i < NF; i++) if ($i == "rime") { print NR - 1 "\t" $1; next } }' <<<"$groups"
  else
    awk '/^\[Groups\/[0-9]+\]$/ { g = $0; gsub(/[^0-9]/, "", g); sec = "group"; next }
      /^\[Groups\/[0-9]+\/Items\/[0-9]+\]$/ { sec = "item"; next } /^\[GroupOrder\]$/ { sec = "order"; next }
      /^\[/ { sec = ""; next }
      sec == "group" && sub(/^Name=/, "") { name[g] = $0 } sec == "item" && $0 == "Name=rime" { rime[g] = 1 }
      sec == "order" && match($0, /^[0-9]+=/) { order[substr($0, 1, RLENGTH - 1) + 0] = substr($0, RLENGTH + 1) }
      END { n = 0; for (k = 0; k in order; k++) for (g in name) if (name[g] == order[k] && !(g in at)) at[g] = n++
        if (!n) for (g in name) at[g] = g + 0  # no order: [Groups/0] first, as fcitx_profile_update takes it
        for (g in rime) print (g in at ? at[g] : 1000 + g) "\t" name[g] }' "$fcitx_profile" 2>/dev/null | sort -n
  fi
}
# 7. Input methods: SebType's one input method, which switches English, Chinese and Japanese itself (#190),
# first in the first Fcitx5 group, in place of keyboard-us, rime and mozc; any others stay. When Fcitx5 is
# running and knows sebtype, update it live over D-Bus and activate sebtype immediately; otherwise update
# ~/.config/fcitx5/profile directly so Fcitx5 loads sebtype the next time it starts (#442).
fcitx_profile=$config/fcitx5/profile
# Rime in the first group, which SebType takes the place of: said on a line of its own after the change.
# fcitx5-rime's Rime stays off while SebType's input method is installed (linux/src/sebtype.cpp, #542), and stays out of the group after.
# The way back after removing SebType: pc/linux/README.md, Removing SebType (not installed with the RPM).
removing=https://github.com/S-Sebb/SebType/blob/main/pc/linux/README.md#removing-sebtype
first_rime=; [[ $(rime_groups | cut -f1) == 0* ]] &&
  first_rime=$'\n'"  Rime (fcitx5-rime) won't type Chinese beside SebType: to use it again after removing SebType, add it back"
restore=", or run $0 --undo-all before removing SebType, which puts back profile from before it,"  # after first_rime, where a backup is made
if fcitx_on_dbus && call AvailableInputMethods 2>/dev/null | grep -q '"sebtype"'; then
  first_group=$(running_groups 1)  # a failed read stops setup, as a failed call does
  IFS=$'\x1f' read -r -a q <<<"$first_group"
  group=${q[0]} layout=${q[1]} now=("${q[@]:2}") ims=(sebtype)
  for im in "${now[@]}"; do
    [[ " sebtype keyboard-us rime mozc " == *" $im "* ]] || ims+=("$im")
  done
  if [[ "${now[*]}" != "${ims[*]}" ]]; then
    if change "make SebType's input method the one in Fcitx5 input method group $group, in place of keyboard-us, rime and mozc (backup of $fcitx_profile in $backup)$first_rime${first_rime:+$restore as $removing says}"; then
      call Save  # the running groups, on disk for the backup
      [[ -f $fcitx_profile ]] && save "$fcitx_profile"
      args=()
      for im in "${ims[@]}"; do args+=("$im" ""); done
      call SetInputMethodGroupInfo 'ssa(ss)' "$group" "$layout" $((${#args[@]} / 2)) "${args[@]}"
      call SetCurrentIM s sebtype >/dev/null 2>&1 || true
      call Save
    fi
  elif ((!dry)) && [[ $(call CurrentInputMethod 2>/dev/null | awk '{print $2}' | tr -d '"' || true) != sebtype ]]; then
    call SetCurrentIM s sebtype >/dev/null 2>&1 || true
  fi
else
  src=$fcitx_profile; [[ -f $src ]] || src=/dev/null
  want=$(fcitx_profile_update "$src")
  backed=; [[ -f $fcitx_profile ]] && backed=" (backup in $backup)" && first_rime+=${first_rime:+$restore}
  first_rime+=${first_rime:+ as $removing says}
  if [[ $(canon < "$src") != "$(canon <<<"$want")" ]] &&
    change "set SebType as the input method in $fcitx_profile$backed$first_rime"; then
    [[ -f $fcitx_profile ]] && save "$fcitx_profile"
    mkdir -p "${fcitx_profile%/*}"; printf '%s\n' "$want" > "$fcitx_profile"
  fi
  if fcitx_on_dbus; then
    warn "Fcitx5 doesn't know SebType's input method yet: $(restart_note "SebType input method")"
  fi
fi
# 7b. Rime in the user's other groups won't type Chinese beside SebType's input method (above): told, with
# how to drop such a group (Fcitx5 saves it as it quits), since setup took Fcitx5's own settings away. The
# first group is left out: step 7 takes Rime out of it, also in a dry run, which changes nothing yet.
# A dry run before step 1b's install says it as the run would.
if ((sebtype_coming)) || [[ -n $(installed sebtype) || -f /usr/lib64/fcitx5/sebtype.so ]]; then
  rime_names=() removes=()
  while IFS=$'\t' read -r n name; do
    ((n)) || continue
    rime_names+=("\"$name\"")
    removes+=("busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 RemoveInputMethodGroup s $(printf %q "$name")")
  done < <(rime_groups)
  if ((${#rime_names[@]})); then
    s=; ((${#rime_names[@]} > 1)) && s=s
    names=$(printf ', %s' "${rime_names[@]}") cmds=$(printf '; %s' "${removes[@]}")
    warn "Rime in input method group$s ${names:2} won't type Chinese while SebType is installed. Type Chinese with SebType's 中文: Use SebType on SebType Configurator's About page puts it in Rime's place and keeps the other input methods. Or remove the group$s: ${cmds:2}"
  fi
fi

# 8. Super+Space is the only language switch, and it toggles English and the last other language (#93):
# SebType's input method takes it (#190), so Fcitx5's own switchers are cleared: its trigger key (which
# an older setup made Super+Space), Shift_L (AltTriggerKeys), Control+Shift+Shift_L (EnumerateForwardKeys),
# and the group switch, which defaults to Super+Space too. EnumerateWithTriggerKeys=False is what an older
# setup wrote. The Shift tap for English is SebType's input method's too.
# ShareInputState=All: one language for every window, as on Windows (#42), not one per window.
fcitx_conf=$config/fcitx5/config
fcitx_global() { # prints the config with those settings, keeping everything else
  awk -v cleared='TriggerKeys AltTriggerKeys EnumerateForwardKeys EnumerateBackwardKeys EnumerateGroupForwardKeys EnumerateGroupBackwardKeys' '
    BEGIN { n = split(cleared " EnumerateWithTriggerKeys", keys, " ")
      for (i = 1; i <= n; i++) { own["[Hotkey/" keys[i] "]"] = 1; own[keys[i]] = 1 }
      gsub(" ", "=\n", cleared); cleared = cleared "=\nEnumerateWithTriggerKeys=False" }
    /^\[/ { sec = $0; skip = (sec in own) }
    skip || (sec == "[Hotkey]" && (substr($0, 1, index($0, "=") - 1) in own)) { next }
    sec == "[Behavior]" && /^ShareInputState=/ { next }
    { print }
    $0 == "[Hotkey]" { hotkey = 1; print cleared }
    $0 == "[Behavior]" { behavior = 1; print "ShareInputState=All" }
    END { if (!hotkey) print "[Hotkey]\n" cleared
      if (!behavior) print "\n[Behavior]\nShareInputState=All" }' "$@"
}
src=$fcitx_conf; [[ -f $src ]] || src=/dev/null
want=$(fcitx_global "$src")
if [[ $(canon < "$src") != "$(canon <<<"$want")" ]] &&
  change "leave Super+Space, the only language switch, to SebType's input method (English ⇄ the last other language), shared by all windows, in $fcitx_conf (backup in $backup)"; then
  [[ -f $fcitx_conf ]] && save "$fcitx_conf"
  mkdir -p "${fcitx_conf%/*}"; printf '%s\n' "$want" > "$fcitx_conf"
  busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 ReloadConfig 2>/dev/null || true
fi

# 8b. Fcitx5's own add-on hotkeys are off (Decisions #2, #182): clipboard history (Ctrl+;), Unicode input
# (Ctrl+Alt+Shift+U, Ctrl+Shift+U) and quick phrase (Super+`, Super+;). The add-ons stay loaded; only their
# key lists are emptied (Key= before any section).
addon_keys_off() { # file keys...: prints the add-on's config with those key lists empty, keeping the rest
  local f=$1; shift
  awk -v keys="$*" '
    BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) { own[k[i]] = 1; own["[" k[i] "]"] = 1; print k[i] "=" } }
    /^\[/ { sec = $0; skip = (sec in own) }
    skip || (sec == "" && (substr($0, 1, index($0, "=") - 1) in own)) { next }
    { print }' "$f"
}
for spec in "clipboard TriggerKey" "unicode TriggerKey DirectUnicodeMode" "quickphrase TriggerKey"; do
  read -r addon keys <<<"$spec"
  f=$config/fcitx5/conf/$addon.conf src=$f; [[ -f $src ]] || src=/dev/null
  # shellcheck disable=SC2086  # word-split: one argument per key
  want=$(addon_keys_off "$src" $keys)
  if [[ $(canon < "$src") != "$(canon <<<"$want")" ]] &&
    change "turn off Fcitx5's $addon hotkeys ($keys) in $f (backup in $backup)"; then
    [[ -f $f ]] && save "$f"
    mkdir -p "${f%/*}"; printf '%s\n' "$want" > "$f"
    busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 ReloadAddonConfig s "$addon" 2>/dev/null || true
  fi
done

# 9. Japanese: a Shift tap toggles あ and direct English, and Alt+` あ and ア (Decisions #2, menu hotkeys),
# in Mozc's own keymap, as before SebType's input method (#190), which now takes both keys itself: its
# Shift tap is a Shift released with no other key pressed since, so Shift+letter (Mozc's English run) and
# Shift in shortcuts never match it. Alt+` is Mozc's InputModeSwitchKanaType, which SebType's build
# (engines/mozc) makes a two-way switch.
# Mozc keeps a custom keymap only as a whole table, so mozc-keymap.tsv is Mozc's MS-IME keymap plus
# Shift lines for each state and Alt+` (F6–F10 and Space stay as they are). It goes into Mozc's binary config, config1.db (a mozc.config.Config
# protobuf): session_keymap (field 41) = CUSTOM (0) and custom_keymap_table (field 42), other settings
# kept. Mozc reads it at start, so a running Fcitx5 is asked to restart SebType's Mozc (it saves, closes and
# starts again at the next key).
# Mozc's profile by Mozc's own rule, as the input method and the Configurator use it (#274).
mozc_db=$config/mozc/config1.db
[[ -d $HOME/.mozc ]] && mozc_db=$HOME/.mozc/config1.db
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
  busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 &&
    { busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetConfig sv fcitx://config/addon/sebtype/mozc s '' || true; }
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

# 11. Tray icons: SebType's RPM installs its keycaps as sebtype-<state> in hicolor (#278). An older setup
# (#63) put an icon theme "SebType" with them in front of the user's, inheriting the theme that was active;
# that theme goes, and the one it inherits is active again. One the user picked since stays.
old_theme=$data/icons/SebType
if [[ -d $old_theme ]] && change "remove the old SebType icon theme $old_theme"; then
  if command -v kreadconfig6 >/dev/null 2>&1 && command -v kwriteconfig6 >/dev/null 2>&1 &&
    [[ $(kreadconfig6 --file kdeglobals --group Icons --key Theme) == SebType ]]; then
    inherited=$(sed -n 's/^Inherits=//p' "$old_theme/index.theme")
    if [[ -n $inherited ]]; then kwriteconfig6 --file kdeglobals --group Icons --key Theme "$inherited"
    else kwriteconfig6 --file kdeglobals --group Icons --key Theme --delete; fi
    # Running KDE apps, the tray too, reload their icons.
    busctl --user emit /KIconLoader org.kde.KIconLoader iconChanged i 0 2>/dev/null || true
    busctl --user emit /KGlobalSettings org.kde.KGlobalSettings notifyChange ii 4 0 2>/dev/null || true
  fi
  rm -r "$old_theme"
fi

# 11b. SebType's tray item and menu (#190, Decisions #2): SebType's input method brings it as Fcitx5's
# notificationitem add-on, by this account's add-on entry over Fedora's. Fcitx5's classic UI then leaves
# out its own tray icon, as it does for Fcitx5's item, so its menu with Input Method Settings never shows.
tray_conf=$data/fcitx5/addon/notificationitem.conf
tray_src=$here/../../linux/data/notificationitem.conf; ((checkout)) || tray_src=$here/../../share/sebtype/fcitx5/addon/notificationitem.conf
if ! cmp -s "$tray_src" "$tray_conf" &&
  change "show SebType's tray menu in place of Fcitx5's with $tray_conf"; then
  mkdir -p "${tray_conf%/*}"; cp "$tray_src" "$tray_conf"
  restart_later "SebType tray"
fi

rime_changed=0  # steps 12 to 13b set it; 13c deploys
# 12. Chinese reads 中文 in the switch popup and the tray text (#69). fcitx5-rime's label is the first
# character of the schema name (雾 from 雾凇拼音), unless the name starts with "."; then Fcitx5 shows the
# input method's own label. So the schema name becomes ".中文" (its id stays rime_ice, so learned words
# stay). The same patch sets typo correction (#46, in SebType's Chinese data) to a PC keyboard's neighbour keys.
# Older setups also named fcitx5-rime's input method entry 中文 (this account's rime.conf). fcitx5-rime stays
# off beside SebType's input method now (#542), so that copy goes, as it was written: the entry reads Rime
# again, the name setup's warnings and fcitx5-rime after uninstalling use.
rime_im=$im_dir/rime.conf
if [[ $(cat "$rime_im" 2>/dev/null) == "$old_rime_im" ]] &&
  change "give Rime (fcitx5-rime) its own name back: remove $rime_im, which named it 中文 (backup in $backup)"; then
  save "$rime_im"; rm "$rime_im"
  restart_later "input method names"
fi
lines='  schema/name: ".中文"  # SebType: Fcitx5 shows the input method entry'\''s label instead of 雾 (#69)
  sebtype_typo/keyboard: pc  # SebType: typo correction for a PC keyboard (#46)'
src=$rime_custom; [[ -f $src ]] || src=/dev/null
want_custom=$(awk -v lines="$lines" '/^  (schema\/name|sebtype_typo\/keyboard):/ { next } { print } /^patch:/ && !done { print lines; done = 1 }
  END { if (!done) print "patch:\n" lines }' "$src")
if [[ $(cat "$src") != "$want_custom" ]] &&
  change "label Chinese 中文 instead of 雾 and set typo correction to a PC keyboard in $rime_custom (backup in $backup; undo: $0 --undo-names)"; then
  [[ -f $rime_custom ]] && save "$rime_custom"
  mkdir -p "$rime_dir"; printf '%s\n' "$want_custom" > "$rime_custom"
  rime_changed=1
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
    restart_later "input method names"
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
# data/rime/build.sh. It goes into Rime's folder over the files of the same name, as on Windows;
# learned words, *.custom.yaml and an existing custom_phrase.txt stay. Dictionary sources the data has
# prebuilt tables for are removed, or Rime would compile them instead. What it replaces or removes is
# kept in $rime_before first, so --undo-chinese-data puts the folder back.
rime_tmp=$(mktemp -d) rime_zip=$here/rime-data.zip
((!checkout)) || { "$here/../../data/rime/build.sh" "$rime_tmp" > "$rime_tmp/build.log" 2>&1 && rime_zip=$rime_tmp/rime/rime-data.zip; } ||
  rime_zip=
if [[ -n $rime_zip ]]; then
  rime_id=$(sha256sum < "$rime_zip" | cut -d' ' -f1)
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
# than the build, then copied into this account with its launcher and the phone's icon. Run from the RPM, the
# release's build beside it is copied.
src_app=$here/../configurator built=$src_app/target/release/sebtype-configurator
icon=$here/../../android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_round.png
((checkout)) || built=$here/sebtype-configurator icon=$here/sebtype-configurator.png
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
# Unset where there is nothing to rebuild from: a failed $(...) in an assignment would end setup (set -e).
stale=; ((checkout)) && [[ -x $built ]] && stale=$(find "$src_app" -path "$src_app/target" -prune -o -type f -newer "$built" -print -quit)
if [[ ! -x $built || -n $stale ]] || ! cmp -s "$built" "$app_bin" || [[ $(cat "$app_desktop" 2>/dev/null) != "$want_desktop" ]] ||
  ! cmp -s "$icon" "$app_icon"; then
  if change "install SebType Configurator in $app_dir with its app-menu entry (undo: $0 --undo-configurator)"; then
    if ((checkout)) && [[ ! -x $built || -n $stale ]]; then
      if command -v cargo >/dev/null; then
        cargo build --release --quiet --manifest-path "$src_app/Cargo.toml"
      else
        warn "SebType Configurator needs Rust to build: install it from https://rustup.rs, then run this again"
      fi
    fi
    if [[ -x $built ]]; then
      mkdir -p "$app_dir" "${app_desktop%/*}" "${app_icon%/*}"
      cp "$built" "$app_bin.new" && mv "$app_bin.new" "$app_bin"
      cp "$icon" "$app_icon"
      printf '%s\n' "$want_desktop" > "$app_desktop"
    fi
  fi
fi
# Learning off from before #374 hid what was learned (rime-ice's enable_user_dict, Mozc's NO_HISTORY): the
# Configurator moves it to sebtype.conf, which keeps using it. Nothing to do once moved.
if ((!dry)) && [[ -x $app_bin ]]; then
  "$app_bin" --migrate || warn "SebType Configurator couldn't move learning off to SebType's settings; it tries again when it starts"
fi

# 14b. The daily update check (#422): the Configurator's --check-updates from a systemd user timer, once a
# day and at the next login after a missed day. A newer release shows a notification; the Configurator's
# "Check for updates automatically" turns it off. A click on the notification opens the Configurator from
# the check's service, which keeps it running (KillMode=process).
update_units=$config/systemd/user
want_update_service="[Unit]
Description=SebType's update check

[Service]
Type=oneshot
ExecStart=\"$app_bin\" --check-updates
KillMode=process"
want_update_timer="[Unit]
Description=SebType's update check once a day

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target"
if [[ $(cat "$update_units/sebtype-update.service" 2>/dev/null) != "$want_update_service" ||
  $(cat "$update_units/sebtype-update.timer" 2>/dev/null) != "$want_update_timer" ]] &&
  change "schedule SebType's daily update check (undo: $0 --undo-configurator)"; then
  mkdir -p "$update_units"
  printf '%s\n' "$want_update_service" > "$update_units/sebtype-update.service"
  printf '%s\n' "$want_update_timer" > "$update_units/sebtype-update.timer"
  if ! { systemctl --user daemon-reload && systemctl --user enable --now sebtype-update.timer; }; then
    warn "the daily update check couldn't start: systemctl --user enable --now sebtype-update.timer"
  fi
fi

# Once more for what Fcitx5 loads when it starts (the tray, the names, packages), as 6b does (#445).
if ((${#restart_for[@]})); then
  if kwin_runs_fcitx; then
    change "restart Fcitx5 under KWin so it loads the new ${restart_for[*]}" && kwin_restart_fcitx5
  else warn "$(restart_note "${restart_for[*]}")"; fi
fi

# Self-check of the live session.
fcitx_under_kwin ||
  warn "Fcitx5 isn't running under KWin yet; log out and in again"
[[ $(systemctl --user show-environment 2>/dev/null | sed -n 's/^XMODIFIERS=//p' || true) == @im=fcitx ]] ||
  warn "XMODIFIERS=@im=fcitx isn't in this session yet; log out and in again"

if ((dry)); then echo "dry run: $changes change(s) to make, $todo warning(s)"
else echo "done: $changes change(s), $todo warning(s)"; fi
