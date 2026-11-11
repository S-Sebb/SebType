# SebType's fcitx5-rime (#117): Fedora's package, rebuilt with menu.patch. Sourced by build.sh and
# ../setup-ime.sh. Bump RIME_SEBTYPE_RELEASE when the patch or the build changes.
RIME_VERSION=5.1.15
RIME_FEDORA_RELEASE=1.fc44
RIME_SRPM_URL='https://kojipkgs.fedoraproject.org/packages/fcitx5-rime/5.1.15/1.fc44/src/fcitx5-rime-5.1.15-1.fc44.src.rpm'
RIME_SRPM_SHA256=e0d2135a54e440008ee57d8d012190791b64fec0cfeaae8da188ad8c2ccc26fe
# The same pinned fedora:44 as mozc/versions.sh.
RIME_BUILD_IMAGE=registry.fedoraproject.org/fedora@sha256:a90c26f38ee1fb33444bbec8b598d8cc9aec7cc6455f8163df7d050e5d073a4f
RIME_SEBTYPE_RELEASE=1.sebtype1.fc44  # sorts above Fedora's 1.fc44 and below its next update
RIME_RPM=fcitx5-rime-$RIME_VERSION-$RIME_SEBTYPE_RELEASE.x86_64.rpm
RIME_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/fcitx5-rime
