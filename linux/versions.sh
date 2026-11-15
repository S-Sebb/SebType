# shellcheck shell=bash
# SebType's Linux packages: the input method (#190), the Fcitx5 add-on over SebType's core with Mozc's
# server, packaged by sebtype.spec (build.sh), and SebType's librime (#101), packaged by librime.spec
# (build-librime.sh). Sourced by the build scripts, pc/linux/setup-ime.sh and the tests. Bump
# SEBTYPE_RPM_RELEASE when core/, linux/ or engines/mozc changes, LIBRIME_SEBTYPE_RELEASE when engines/librime does.
SEBTYPE_VERSION=0.1.0
SEBTYPE_RPM_RELEASE=5.fc44
SEBTYPE_RPM=sebtype-$SEBTYPE_VERSION-$SEBTYPE_RPM_RELEASE.x86_64.rpm
SEBTYPE_CACHE=$HOME/scratch/SebType/cache/sebtype

# fedora:44 as of 2026-11-09; its packages are what the builds link against.
BUILD_IMAGE=registry.fedoraproject.org/fedora@sha256:a90c26f38ee1fb33444bbec8b598d8cc9aec7cc6455f8163df7d050e5d073a4f
# Bazelisk, which runs the Bazel version engines/mozc/src/.bazeliskrc names (android/mozc uses it too).
BAZELISK_URL=https://github.com/bazelbuild/bazelisk/releases/download/v1.30.0/bazelisk-linux-amd64
BAZELISK_SHA256=a248ae2b2b62b5baebb748f6fba7203bff1a27e5d01b55399a8406744cb539e8

# librime.spec also builds librime-lua and the other plugins, which must match the librime they run on:
# setup replaces every librime package installed.
LIBRIME_VERSION=1.16.1
LIBRIME_FEDORA_RELEASE=2.fc44
# Fedora's copies of the plugins (file, sha512).
LIBRIME_SOURCES=(
  librime-lua.tar.gz 855c2633b938b49d32e70c0b0a81be2072b7f1c087485b4b3304e0f72eb237a03b21435c85e26abeb760da0b3711b176f5810704af4362856419fb34558992c0
  librime-octagram.tar.gz cf0ebfa6af1d80607e0ef477145b8fcdaabbd6fdc3877a2fe7834509d6a327728dcf5397b19897b31b8e4a19defeeb0daabaa0790db8a5d8c13e3c2129eba537
  librime-predict.tar.gz 18886685d38efe8384d1c3d3c7c178f79b9cb9e32d5063586c332f1b1c7b559e869fd2623ede2d088e855ebd82a0368fe83bbffa78a793d660d233a5c82c71c8
)
LIBRIME_SEBTYPE_RELEASE=2.sebtype4.fc44
LIBRIME_PACKAGES=(librime librime-lua librime-octagram librime-predict librime-tools librime-devel)
LIBRIME_CACHE=$HOME/scratch/SebType/cache/librime
librime_rpm() { echo "$LIBRIME_CACHE/$1-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm"; } # package

# sebtype_unpack <dir>: SebType's RPM (built first if it isn't cached) unpacked into <dir>, for a private
# Fcitx5 that runs it uninstalled with sebtype_run's prefix, or sebtype_env's variables where nothing
# runs longer than Mozc's 3-minute watchdog (see sebtype_run).
sebtype_unpack() {
  [[ -f $SEBTYPE_CACHE/$SEBTYPE_RPM ]] || "$(dirname "${BASH_SOURCE[0]}")/build.sh" >/dev/null || return 1
  rm -rf "$1"; mkdir -p "$1"
  rpm2cpio "$SEBTYPE_CACHE/$SEBTYPE_RPM" | (cd "$1" && cpio -idm --quiet)
}
sebtype_env() { # <dir>: Fcitx5 finds the add-on there before its own
  echo "FCITX_ADDON_DIRS=$1/usr/lib64/fcitx5:/usr/lib64/fcitx5" "XDG_DATA_DIRS=$1/usr/share:/usr/share" \
    "SEBTYPE_MOZC_SERVER=$1/usr/libexec/sebtype/mozc_server"
}
# librime_unpack <dir>: SebType's librime and the plugins setup installs with it (built first if they aren't
# cached), unpacked into <dir>; librime_mounts <dir> prints the bwrap arguments that put them over Fedora's
# for one process alone.
librime_unpack() {
  local p rpm
  for p in librime librime-lua librime-octagram; do
    rpm=$(librime_rpm "$p")
    [[ -f $rpm ]] || "$(dirname "${BASH_SOURCE[0]}")/build-librime.sh" >/dev/null || return 1
    rpm2cpio "$rpm" | (cd "$1" && cpio -idm --quiet) || return 1
  done
}
librime_mounts() {
  echo "--ro-bind $1/usr/lib64/librime.so.$LIBRIME_VERSION /usr/lib64/librime.so.$LIBRIME_VERSION" \
    "--ro-bind $1/usr/lib64/rime-plugins /usr/lib64/rime-plugins"
}
# sebtype_run <dir>: the command prefix that runs a private Fcitx5 as if both were installed. Mozc's server
# is overlaid at the path it was built for (config.bzl), not run from <dir>: its watchdog's client rejects a
# server whose /proc/<pid>/exe differs from that path, and every 3 minutes it aborts the server.
sebtype_run() {
  echo "env FCITX_ADDON_DIRS=$1/usr/lib64/fcitx5:/usr/lib64/fcitx5 XDG_DATA_DIRS=$1/usr/share:/usr/share" \
    "bwrap --dev-bind / / $(librime_mounts "$1")" \
    "--overlay-src /usr/libexec --overlay-src $1/usr/libexec --ro-overlay /usr/libexec"
}
