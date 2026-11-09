# SebType's fcitx5-mozc (#66): Fedora's package, rebuilt with caps-lock-icon.patch. Sourced by build.sh
# and ../setup-ime.sh. Bump SEBTYPE_RELEASE when the patch or the build changes.
MOZC_VERSION='2.30.5618.102^20250124gitc0ed34e'  # fcitx/mozc c0ed34e, as Fedora 44 ships it
MOZC_FEDORA_RELEASE=6.fc44
MOZC_SRPM_URL='https://kojipkgs.fedoraproject.org/packages/fcitx5-mozc/2.30.5618.102%5E20250124gitc0ed34e/6.fc44/src/fcitx5-mozc-2.30.5618.102%5E20250124gitc0ed34e-6.fc44.src.rpm'
MOZC_SRPM_SHA256=4e602c212eb422bc810cf77a1c5532b95c7004859d382b3e9c9019758f5dd3c1
# fedora:44 as of 2026-11-09; its packages are what the build links against.
MOZC_BUILD_IMAGE=registry.fedoraproject.org/fedora@sha256:a90c26f38ee1fb33444bbec8b598d8cc9aec7cc6455f8163df7d050e5d073a4f
SEBTYPE_RELEASE=6.sebtype1.fc44  # sorts above Fedora's 6.fc44 and below its next update
MOZC_RPM=fcitx5-mozc-$MOZC_VERSION-$SEBTYPE_RELEASE.x86_64.rpm
MOZC_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/mozc
