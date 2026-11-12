# SebType's Rime and Fcitx5: pc/fcitx5-rime (#117), pc/librime (#101) and pc/fcitx5 (#182), packaged by
# fcitx5-rime.spec, librime.spec and fcitx5.spec. Sourced by build.sh, ../setup-ime.sh and
# ../test-setup-ime.sh. Bump a *_SEBTYPE_RELEASE when its source or the build changes.
RIME_VERSION=5.1.15
RIME_FEDORA_RELEASE=1.fc44
# The same pinned fedora:44 as mozc/versions.sh.
RIME_BUILD_IMAGE=registry.fedoraproject.org/fedora@sha256:a90c26f38ee1fb33444bbec8b598d8cc9aec7cc6455f8163df7d050e5d073a4f
RIME_SEBTYPE_RELEASE=1.sebtype1.fc44  # sorts above Fedora's 1.fc44 and below its next update
RIME_RPM=fcitx5-rime-$RIME_VERSION-$RIME_SEBTYPE_RELEASE.x86_64.rpm
RIME_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/fcitx5-rime

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
LIBRIME_SEBTYPE_RELEASE=2.sebtype2.fc44
LIBRIME_PACKAGES=(librime librime-lua librime-octagram librime-predict librime-tools librime-devel)
LIBRIME_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/librime
librime_rpm() { echo "$LIBRIME_CACHE/$1-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm"; } # package

# fcitx5.spec builds Fcitx5 and its subpackages, which must match each other: setup replaces every one
# installed.
FCITX5_VERSION=5.1.23
FCITX5_FEDORA_RELEASE=1.fc44
FCITX5_SEBTYPE_RELEASE=1.sebtype1.fc44
FCITX5_PACKAGES=(fcitx5 fcitx5-libs fcitx5-data fcitx5-devel fcitx5-autostart)
FCITX5_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/fcitx5
fcitx5_rpm() { # package
  local arch=x86_64; [[ $1 == fcitx5-data || $1 == fcitx5-autostart ]] && arch=noarch
  echo "$FCITX5_CACHE/$1-$FCITX5_VERSION-$FCITX5_SEBTYPE_RELEASE.$arch.rpm"
}
