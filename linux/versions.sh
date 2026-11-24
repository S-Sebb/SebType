# shellcheck shell=bash
# SebType's Linux package: the input method (#190), the Fcitx5 add-on over SebType's core with Mozc and
# SebType's librime (#101, #527) in it, packaged by sebtype.spec (build.sh). Sourced by the build scripts,
# pc/linux/setup-ime.sh and the tests. Bump SEBTYPE_RPM_RELEASE when what build.sh packs (SEBTYPE_SOURCES,
# SEBTYPE_MOZC) changes; the benches' librime RPMs rebuild by themselves (librime_unpack).
# A release carries the sebtype RPM (#421) with the add-on, Mozc, the Configurator, the Chinese data and
# setup's user part, so a PC updates without a checkout.
# SebType's version, the phone's and Windows' too (VERSION, #420).
SEBTYPE_VERSION=$(<"$(dirname "${BASH_SOURCE[0]}")/../VERSION")
SEBTYPE_RPM_RELEASE=4.fc44
SEBTYPE_RPM=sebtype-$SEBTYPE_VERSION-$SEBTYPE_RPM_RELEASE.x86_64.rpm
SEBTYPE_LINUX_SETUP=SebType-setup-$SEBTYPE_VERSION-linux-x86_64.sh
SEBTYPE_CACHE=$HOME/scratch/SebType/cache/sebtype
# What build.sh packs: SEBTYPE_SOURCES as sebtype.tar.gz, SEBTYPE_MOZC as mozc.tar.gz, and llama.cpp at
# fetch-llama.sh's pin as llama.tar.gz. The Configurator takes the sync client and the phone's pig and font; the
# add-on SebType's librime (engines/librime, with LIBRIME_PLUGIN_SOURCES and OCTAGRAM_COMMIT's octagram) and
# SEBTYPE_DEPS with the phone's copies of their licences; 中文's model (#495) its loader and chinese.gguf.
SEBTYPE_SOURCES=(VERSION core linux pc/icons pc/linux/setup-ime.sh pc/linux/mozc-keymap.tsv pc/configurator
  sync-server/sebtype_sync.py android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_round.png
  android/app/src/main/res/font/sebtype_nunito_extrabold.ttf data/rime engines/librime android/native/src/main/assets/licenses
  engines/sebtype-lm/CMakeLists.txt engines/sebtype-lm/fetch-llama.sh engines/sebtype-lm/sebtype_lm.cpp
  engines/sebtype-lm/sebtype_lm.h engines/sebtype-lm/zh_lm.cpp engines/sebtype-lm/zh_lm.h engines/sebtype-lm/chinese.gguf)
SEBTYPE_MOZC=engines/mozc

# fedora:44 as of 2026-11-09; its packages are what the builds link against.
BUILD_IMAGE=registry.fedoraproject.org/fedora@sha256:a90c26f38ee1fb33444bbec8b598d8cc9aec7cc6455f8163df7d050e5d073a4f

# SebType's librime in the add-on (linux/CMakeLists.txt) leaves Fedora's librime installed and as it is (#527).
# librime.spec builds it with its plugins as Fedora's librime packages for the benches and the private
# Fcitx5s of the dev tools (librime_unpack); releases up to 0.2.0-2 installed them in Fedora's place (release
# LIBRIME_SEBTYPE_RELEASE and older ones, all *.sebtype*), and the installer and --undo-librime put Fedora's back.
LIBRIME_VERSION=1.16.1
LIBRIME_FEDORA_RELEASE=2.fc44
# Fedora's copies of the plugins (file, sha512); octagram is OCTAGRAM_COMMIT's (below).
LIBRIME_SOURCES=(
  librime-lua.tar.gz 855c2633b938b49d32e70c0b0a81be2072b7f1c087485b4b3304e0f72eb237a03b21435c85e26abeb760da0b3711b176f5810704af4362856419fb34558992c0
  librime-predict.tar.gz 18886685d38efe8384d1c3d3c7c178f79b9cb9e32d5063586c332f1b1c7b559e869fd2623ede2d088e855ebd82a0368fe83bbffa78a793d660d233a5c82c71c8
)
LIBRIME_SEBTYPE_RELEASE=2.sebtype4.fc44
# The plugins the add-on's librime builds in: rime-ice's Lua, Fedora's copy (LIBRIME_PLUGIN_SOURCES), and the
# grammar's octagram at the phone's pin (android/native/src/main/cpp/cmake/librime-plugins.cmake), which
# librime.spec builds too. That one is BSD-3-Clause like librime since 2026-07; Fedora's copy is an older
# GPL-3.0 one. Its one code change since, a fix to the encoding of other characters than ASCII and U+4000-9FFF,
# leaves 白霜's Chinese grammar byte for byte the same.
LIBRIME_PLUGIN_SOURCES=("${LIBRIME_SOURCES[@]:0:2}")
OCTAGRAM_COMMIT=57d18b9f58e5284bd891d559f6bdd16cf60341e9
OCTAGRAM_SHA256=7b9c77bcf17566b64204791b72cdb1b4471e22efec5eef9b79ca764ab99a1576
# What librime and core/ link, built into the add-on too (#540), at the phone's pins (android/native/src/main/
# cpp/cmake/) and glog at Fedora 44's: as shared libraries they made the sebtype package need sonames a
# Fedora release drops (F45 has libopencc.so.1.2 and liblua-5.5.so), which blocked dnf --releasever's
# distro-sync. Name, URL, sha256; build.sh passes each as <name>.tar.gz.
SEBTYPE_DEPS=(
  glog https://github.com/google/glog/archive/refs/tags/v0.7.1.tar.gz 00e4a87e87b7e7612f519a41e491f16623b12423620006f59f5688bfd8d13b08
  yaml-cpp https://github.com/jbeder/yaml-cpp/archive/refs/tags/0.8.0.tar.gz fbe74bbdcee21d656715688706da3c8becfd946d92cd44705cc6098bb23b3a16
  leveldb https://github.com/google/leveldb/archive/refs/tags/1.23.tar.gz 9a37f8a6174f09bd622bc723b55881dc541cd50747cbd08831c2a82d620f6d76
  marisa https://github.com/s-yata/marisa-trie/archive/refs/tags/v0.3.1.tar.gz 986ed5e2967435e3a3932a8c95980993ae5a196111e377721f0849cad4e807f3
  opencc https://github.com/BYVoid/OpenCC/archive/refs/tags/ver.1.1.9.tar.gz ad4bcd8d87219a240a236d4a55c9decd2132a9436697d2882ead85c8939b0a99
  lua https://github.com/lua/lua/archive/refs/tags/v5.4.7.tar.gz 5c39111b3fc4c1c9e56671008955a1730f54a15b95e1f1bd0752b868b929d8e3
  protobuf https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protobuf-cpp-3.21.12.tar.gz 4eab9b524aa5913c6fffb20b2a8abf5ef7f95a80bc0701f3a6dbb4c607f73460
)
LIBRIME_PACKAGES=(librime librime-lua librime-octagram librime-predict librime-tools librime-devel)
LIBRIME_CACHE=$HOME/scratch/SebType/cache/librime
librime_rpm() { echo "$LIBRIME_CACHE/$1/$2-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm"; } # key package

# sources_key <path>...: a hash of those paths of the tree as they are now, committed or not (new and deleted
# files too), but not what git ignores. git hashes the files into a copy of the tree's index, so it reads again
# only the files changed since the index was written.
sources_key() {
  local root index rc
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  index=$(git -C "$root" rev-parse --path-format=absolute --git-path index)
  cp "$index" "$index.sebtype-key.$$" &&
    GIT_INDEX_FILE=$index.sebtype-key.$$ git -C "$root" add -- "$@" &&
    GIT_INDEX_FILE=$index.sebtype-key.$$ git -C "$root" ls-files -s -- "$@" | sha256sum | head -c 12
  rc=$?
  rm -f "$index.sebtype-key.$$"
  return $rc
}
sebtype_key() { sources_key "${SEBTYPE_SOURCES[@]}" "$SEBTYPE_MOZC"; } # what build.sh packs
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
# librime_key: a hash of what decides build-librime.sh's RPMs, which it keeps in a folder of that name, so a
# tree never takes RPMs another tree built from other code. The build host's copy has no git: there it is
# LIBRIME_KEY, which build_remotely brings along.
librime_key() {
  if [[ -e $(dirname "${BASH_SOURCE[0]}")/../.git ]]; then
    sources_key engines/librime linux/librime.spec linux/build-librime.sh linux/rpm-sources.sh linux/versions.sh
  else
    [[ ${LIBRIME_KEY:-} ]] || { echo "librime_key: no git and no LIBRIME_KEY (build_remotely sets it)" >&2; return 1; }
    echo "$LIBRIME_KEY"
  fi
}
# librime_built: prints librime_key, after building the RPMs if they aren't cached.
librime_built() {
  local p key
  key=$(librime_key) || return 1
  # Marked in use before the check, so build-librime.sh's cleanup of folders no tree used for two weeks can't
  # take it between the check and the use (unless it picked the folder in this same moment); -c never leaves
  # an empty file in its place.
  touch -c "$LIBRIME_CACHE/$key"
  for p in "${LIBRIME_PACKAGES[@]}"; do
    [[ -f $(librime_rpm "$key" "$p") ]] && continue
    LIBRIME_KEY=$key "$(dirname "${BASH_SOURCE[0]}")/build-librime.sh" >&2 || return 1 # its errors go to stdout
    break
  done
  echo "$key"
}
# librime_unpack <dir>: SebType's librime and the plugins as librime.spec packages them, from this tree's code
# (built first if they aren't cached), unpacked into <dir>, for the benches and the dev tools that run
# Fedora's Rime apps on it. librime_mounts <dir> prints the bwrap arguments that put them over Fedora's for
# one process alone.
librime_unpack() {
  local p rpm key
  key=$(librime_built) || return 1
  for p in librime librime-lua librime-octagram; do
    rpm=$(librime_rpm "$key" "$p")
    # cpio stops at the archive trailer; the rest is drained so rpm2cpio doesn't die of SIGPIPE under pipefail.
    rpm2cpio "$rpm" | (cd "$1" && cpio -idm --quiet; s=$?; cat >/dev/null; exit $s) || return 1
  done
}
librime_mounts() {
  echo "--ro-bind $1/usr/lib64/librime.so.$LIBRIME_VERSION /usr/lib64/librime.so.$LIBRIME_VERSION" \
    "--ro-bind $1/usr/lib64/rime-plugins /usr/lib64/rime-plugins"
}
# sebtype_run <dir>: the command prefix that runs a private Fcitx5 as if the RPM were installed. The add-on finds
# Mozc's library in <dir> by its RUNPATH, and has SebType's librime inside (#527).
sebtype_run() {
  echo "env $(sebtype_env "$1") bwrap --dev-bind / /"
}
