# SebType's Rime: Fedora's fcitx5-rime rebuilt with menu.patch (#117), and Fedora's librime rebuilt
# with layout-model.patch (#101). Sourced by build.sh, ../setup-ime.sh and ../test-setup-ime.sh. Bump a
# *_SEBTYPE_RELEASE when its patch or the build changes.
RIME_VERSION=5.1.15
RIME_FEDORA_RELEASE=1.fc44
RIME_SRPM_URL='https://kojipkgs.fedoraproject.org/packages/fcitx5-rime/5.1.15/1.fc44/src/fcitx5-rime-5.1.15-1.fc44.src.rpm'
RIME_SRPM_SHA256=e0d2135a54e440008ee57d8d012190791b64fec0cfeaae8da188ad8c2ccc26fe
# The same pinned fedora:44 as mozc/versions.sh.
RIME_BUILD_IMAGE=registry.fedoraproject.org/fedora@sha256:a90c26f38ee1fb33444bbec8b598d8cc9aec7cc6455f8163df7d050e5d073a4f
RIME_SEBTYPE_RELEASE=1.sebtype1.fc44  # sorts above Fedora's 1.fc44 and below its next update
RIME_RPM=fcitx5-rime-$RIME_VERSION-$RIME_SEBTYPE_RELEASE.x86_64.rpm
RIME_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/fcitx5-rime

# The source package also builds librime-lua and the other plugins, which must match the librime
# they run on: setup replaces every librime package installed.
LIBRIME_VERSION=1.16.1
LIBRIME_FEDORA_RELEASE=2.fc44
LIBRIME_SRPM_URL='https://kojipkgs.fedoraproject.org/packages/librime/1.16.1/2.fc44/src/librime-1.16.1-2.fc44.src.rpm'
LIBRIME_SRPM_SHA256=65ffb514b91d883106841895083900c4ec71de30d2ba2bc7be8ddc89a7d1ba62
LIBRIME_SEBTYPE_RELEASE=2.sebtype1.fc44
LIBRIME_PACKAGES=(librime librime-lua librime-octagram librime-predict librime-tools librime-devel)
LIBRIME_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/librime
librime_rpm() { echo "$LIBRIME_CACHE/$1-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm"; } # package
