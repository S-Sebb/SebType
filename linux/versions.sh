# shellcheck shell=bash
# SebType's Linux packages: the input method (#190), the Fcitx5 add-on over SebType's core with Mozc in its
# process, packaged by sebtype.spec (build.sh), and SebType's librime (#101), packaged by librime.spec
# (build-librime.sh). Sourced by the build scripts, pc/linux/setup-ime.sh and the tests. Bump
# SEBTYPE_RPM_RELEASE when what build.sh packs (SEBTYPE_SOURCES, SEBTYPE_MOZC) changes, LIBRIME_SEBTYPE_RELEASE
# when engines/librime does.
# A release carries both (#421): the sebtype RPM with the add-on, Mozc, the Configurator, the Chinese data and
# setup's user part, and SebType's librime with its plugins, so a PC updates without a checkout.
# SebType's version, the phone's and Windows' too (VERSION, #420).
SEBTYPE_VERSION=$(<"$(dirname "${BASH_SOURCE[0]}")/../VERSION")
SEBTYPE_RPM_RELEASE=2.fc44
SEBTYPE_RPM=sebtype-$SEBTYPE_VERSION-$SEBTYPE_RPM_RELEASE.x86_64.rpm
SEBTYPE_LINUX_SETUP=SebType-setup-$SEBTYPE_VERSION-linux-x86_64.sh
SEBTYPE_CACHE=$HOME/scratch/SebType/cache/sebtype
# What build.sh packs: SEBTYPE_SOURCES as sebtype.tar.gz, SEBTYPE_MOZC as mozc.tar.gz, and llama.cpp at
# fetch-llama.sh's pin as llama.tar.gz. The Configurator takes the sync client and the phone's pig and font; the
# Chinese data librime's API headers; 中文's model (#495) its loader and chinese.gguf.
SEBTYPE_SOURCES=(VERSION core linux pc/icons pc/linux/setup-ime.sh pc/linux/mozc-keymap.tsv pc/configurator
  sync-server/sebtype_sync.py android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_round.png
  android/app/src/main/res/font/sebtype_nunito_extrabold.ttf data/rime engines/librime/CMakeLists.txt
  engines/librime/src/rime_api.h engines/librime/src/rime_api_deprecated.h engines/librime/src/rime_api_stdbool.h
  engines/sebtype-lm/CMakeLists.txt engines/sebtype-lm/fetch-llama.sh engines/sebtype-lm/sebtype_lm.cpp
  engines/sebtype-lm/sebtype_lm.h engines/sebtype-lm/zh_lm.cpp engines/sebtype-lm/zh_lm.h engines/sebtype-lm/chinese.gguf)
SEBTYPE_MOZC=engines/mozc

# fedora:44 as of 2026-11-09; its packages are what the builds link against.
BUILD_IMAGE=registry.fedoraproject.org/fedora@sha256:a90c26f38ee1fb33444bbec8b598d8cc9aec7cc6455f8163df7d050e5d073a4f

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
LIBRIME_SEBTYPE_RELEASE=2.sebtype5.fc44
# Fedora's names. SebType's packages are sebtype-<name> and provide <name> (librime.spec, #527).
LIBRIME_PACKAGES=(librime librime-lua librime-octagram librime-predict librime-tools librime-devel)
LIBRIME_CACHE=$HOME/scratch/SebType/cache/librime
librime_rpm() { echo "$LIBRIME_CACHE/sebtype-$1-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm"; } # Fedora's name

# sebtype_key: a hash of what build.sh packs, as it is in this tree now, committed or not (new and deleted
# files too), but not what git ignores. git hashes the files into a copy of the tree's index, so it reads again
# only the files changed since the index was written.
sebtype_key() {
  local root index rc
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  index=$(git -C "$root" rev-parse --path-format=absolute --git-path index)
  cp "$index" "$index.sebtype-key.$$" &&
    GIT_INDEX_FILE=$index.sebtype-key.$$ git -C "$root" add -- "${SEBTYPE_SOURCES[@]}" "$SEBTYPE_MOZC" &&
    GIT_INDEX_FILE=$index.sebtype-key.$$ git -C "$root" ls-files -s -- "${SEBTYPE_SOURCES[@]}" "$SEBTYPE_MOZC" |
    sha256sum | head -c 12
  rc=$?
  rm -f "$index.sebtype-key.$$"
  return $rc
}
# configurator_sources <root>: a hash of the files the Configurator is built from under <root>, a checkout or
# the spec's unpacked sources. The spec builds it in, and Cargo rebuilds when it changes: the packed sources'
# times are all 0, so Cargo's own check by time would keep an older build (#423). linux/test-rpms.sh compares
# it with the checkout's.
configurator_sources() {
  (cd "$1" && find VERSION pc/configurator sync-server/sebtype_sync.py android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_round.png \
    android/app/src/main/res/font/sebtype_nunito_extrabold.ttf -path pc/configurator/target -prune -o -type f -print0 |
    LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | head -c 16)
}
# sebtype_rpm <key>: the cached RPM built from sources with that key (#326): two trees on different code
# never share one, and a tree whose sources haven't changed reuses its own.
sebtype_rpm() { echo "$SEBTYPE_CACHE/sebtype-$SEBTYPE_VERSION-$SEBTYPE_RPM_RELEASE.$1.x86_64.rpm"; }
# sebtype_unpack <dir>: this tree's RPM (built first if it isn't cached) unpacked into <dir>, for a private
# Fcitx5 that runs it uninstalled with sebtype_run's prefix, or with sebtype_env's variables.
sebtype_unpack() {
  local key rpm
  key=$(sebtype_key) || return 1
  rpm=$(sebtype_rpm "$key")
  # Marked in use before the check, so build.sh's cleanup of RPMs no tree used for two weeks can't take it
  # between the check and the unpack; -c never leaves an empty file in its place.
  touch -c "$rpm"
  [[ -f $rpm ]] || SEBTYPE_SOURCES_KEY=$key "$(dirname "${BASH_SOURCE[0]}")/build.sh" >/dev/null || return 1
  rm -rf "$1"; mkdir -p "$1"
  rpm2cpio "$rpm" | (cd "$1" && cpio -idm --quiet)
}
sebtype_env() { # <dir>: Fcitx5 finds the add-on there before its own
  echo "FCITX_ADDON_DIRS=$1/usr/lib64/fcitx5:/usr/lib64/fcitx5" "XDG_DATA_DIRS=$1/usr/share:/usr/share"
}
# librime_unpack <dir>: SebType's librime and the plugins setup installs with it (built first if they aren't
# cached), unpacked into <dir>; librime_mounts <dir> prints the bwrap arguments that put them over Fedora's
# for one process alone.
librime_unpack() {
  local p rpm
  for p in librime librime-lua librime-octagram; do
    rpm=$(librime_rpm "$p")
    [[ -f $rpm ]] || "$(dirname "${BASH_SOURCE[0]}")/build-librime.sh" >&2 || return 1 # its errors go to stdout
    # cpio stops at the archive trailer; the rest is drained so rpm2cpio doesn't die of SIGPIPE under pipefail.
    rpm2cpio "$rpm" | (cd "$1" && cpio -idm --quiet; s=$?; cat >/dev/null; exit $s) || return 1
  done
}
librime_mounts() {
  echo "--ro-bind $1/usr/lib64/librime.so.$LIBRIME_VERSION /usr/lib64/librime.so.$LIBRIME_VERSION" \
    "--ro-bind $1/usr/lib64/rime-plugins /usr/lib64/rime-plugins"
}
# sebtype_run <dir>: the command prefix that runs a private Fcitx5 as if both were installed. The add-on finds
# Mozc's library in <dir> by its RUNPATH.
sebtype_run() {
  echo "env $(sebtype_env "$1") bwrap --dev-bind / / $(librime_mounts "$1")"
}
