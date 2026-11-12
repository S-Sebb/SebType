# SebType's fcitx5-mozc (#66): pc/fcitx5-mozc, packaged by fcitx5-mozc.spec. Sourced by build.sh and
# ../setup-ime.sh. Bump SEBTYPE_RELEASE when the source or the build changes.
MOZC_VERSION='2.30.5618.102^20250124gitc0ed34e'  # fcitx/mozc c0ed34e, as Fedora 44 ships it
MOZC_FEDORA_RELEASE=6.fc44
# Fedora's copies of the third-party sources (file, sha512).
MOZC_SOURCES=(
  japanese-usage-dictionary-e5b3425575734c323e1d947009dd74709437b684.tar.gz b7e997a979b6d50e49b9af5dc830ea4df0532f6ab1321b9ef14983f65bb54f1b2967375c82e07957ae7693ebbf43c9b56ecea6bfea8dd1fdaee444bd549d83a7
  protobuf-3.29.1.tar.gz b8211d8baacfe21b615d78e3213ab475373193b17efd5dee45c11bf1fd1a4ccbdea5a37eaadb6338b27606eee0db639ffa2a2ce6c08722f5492ea2d3b3fe851d
  abseil-cpp-20240722.0.tar.gz bd2cca8f007f2eee66f51c95a979371622b850ceb2ce3608d00ba826f7c494a1da0fba3c1427728f2c173fe50d59b701da35c2c9fdad2752a5a49746b1c8ef31
  ken_all.zip ed7b041a0d1d95b8be7c1824c3dfd50867080b6284265192ddc5f829c9d6bb0d537db56271764da3ddb8bba65ccf410050dfea276f579c853788e29e56bddaec
  jigyosyo.zip cb47d51511d4021eb025db6575c593f399b70f027c5bf92eec2d1202029abd701b3476672b02da7f3ff3e18ba6824b277753fcc88c50d9015f14d1a8485513eb
)
# fedora:44 as of 2026-11-09; its packages are what the build links against.
MOZC_BUILD_IMAGE=registry.fedoraproject.org/fedora@sha256:a90c26f38ee1fb33444bbec8b598d8cc9aec7cc6455f8163df7d050e5d073a4f
SEBTYPE_RELEASE=6.sebtype2.fc44  # sorts above Fedora's 6.fc44 and below its next update
MOZC_RPM=fcitx5-mozc-$MOZC_VERSION-$SEBTYPE_RELEASE.x86_64.rpm
MOZC_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/mozc
