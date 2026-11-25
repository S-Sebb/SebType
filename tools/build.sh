#!/usr/bin/env bash
# Runs a build a test script needs (#248) in the build lock, under its caps, and prints the files the build
# prints; its log goes to stderr. On yanglab16 it runs in the pinned Fedora container (fedora_container in
# tools/lib.sh: yanglab16's Ubuntu has neither Rust nor librime).
#
#   tools/build.sh MINUTES NAME SCRIPT [ARG...]   # SCRIPT: a path in the checkout, printing the files it made
set -euo pipefail
cd -P "$(dirname "$0")/.."  # the physical path: the container sees no links
source tools/lib.sh
minutes=$1 name=$2
shift 2
fedora_container -w "$PWD"
# shellcheck disable=SC2154  # container: set by fedora_container
build_lock "$minutes" "$name" "${container[@]}" env CARGO_BUILD_JOBS="$BUILD_JOBS" "$@"
