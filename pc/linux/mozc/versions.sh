# SebType's fcitx5-mozc (#66): engines/mozc, packaged by fcitx5-mozc.spec. Sourced by build.sh,
# ../setup-ime.sh and ../test-setup-ime.sh. Bump SEBTYPE_RELEASE when the source or the build changes.
MOZC_VERSION=3.35.6354  # engines/mozc/src/version.bzl
# The Fedora 44 package SebType's build replaces, and the one --undo-mozc brings back.
MOZC_FEDORA='2.30.5618.102^20250124gitc0ed34e-6.fc44'
# fedora:44 as of 2026-11-09; its packages are what the build links against.
MOZC_BUILD_IMAGE=registry.fedoraproject.org/fedora@sha256:a90c26f38ee1fb33444bbec8b598d8cc9aec7cc6455f8163df7d050e5d073a4f
# Bazelisk, which runs the Bazel version engines/mozc/src/.bazeliskrc names.
BAZELISK_URL=https://github.com/bazelbuild/bazelisk/releases/download/v1.30.0/bazelisk-linux-amd64
BAZELISK_SHA256=a248ae2b2b62b5baebb748f6fba7203bff1a27e5d01b55399a8406744cb539e8
SEBTYPE_RELEASE=1.sebtype.fc44
MOZC_RPM=fcitx5-mozc-$MOZC_VERSION-$SEBTYPE_RELEASE.x86_64.rpm
MOZC_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/mozc
