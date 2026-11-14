# shellcheck shell=bash
# SebType's Linux input method (#190): the Fcitx5 add-on over SebType's core, with Mozc's server, packaged
# by sebtype.spec. Sourced by build.sh, pc/linux/setup-ime.sh and the tests. Bump SEBTYPE_RPM_RELEASE when
# core/, linux/ or engines/mozc changes.
SEBTYPE_VERSION=0.1.0
SEBTYPE_RPM_RELEASE=2.fc44
SEBTYPE_RPM=sebtype-$SEBTYPE_VERSION-$SEBTYPE_RPM_RELEASE.x86_64.rpm
SEBTYPE_CACHE=$HOME/scratch/SebType/cache/sebtype

# sebtype_unpack <dir>: SebType's RPM (built first if it isn't cached) unpacked into <dir>, for a private
# Fcitx5 that runs it uninstalled with sebtype_env's variables.
sebtype_unpack() {
  [[ -f $SEBTYPE_CACHE/$SEBTYPE_RPM ]] || "$(dirname "${BASH_SOURCE[0]}")/build.sh" >/dev/null || return 1
  rm -rf "$1"; mkdir -p "$1"
  rpm2cpio "$SEBTYPE_CACHE/$SEBTYPE_RPM" | (cd "$1" && cpio -idm --quiet)
}
sebtype_env() { # <dir>: Fcitx5 finds the add-on there before its own
  echo "FCITX_ADDON_DIRS=$1/usr/lib64/fcitx5:/usr/lib64/fcitx5" "XDG_DATA_DIRS=$1/usr/share:/usr/share" \
    "SEBTYPE_MOZC_SERVER=$1/usr/libexec/sebtype/mozc_server"
}
