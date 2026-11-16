#!/usr/bin/env bash
# Runs a build a test script needs (#248) on the build host, yanglab16, in the pinned Fedora container there
# (fedora_container in tools/lib.sh: yanglab16's Ubuntu has neither Rust nor librime), and copies back the
# files the build prints, printing their paths here. With SEBTYPE_BUILD_HOST=local, or when yanglab16 can't
# be reached, the build runs here. Either way in the build lock, under its caps; its log goes to stderr.
#
#   tools/build.sh MINUTES NAME SCRIPT [ARG...]   # SCRIPT: a path in the checkout, printing the files it made
#
# In the container the checkout is at the path it has on nobara-pc, so the paths compiled into a build
# (Rust's CARGO_MANIFEST_DIR, which the Configurator's tests read) hold on nobara-pc.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source tools/lib.sh
if build_host_ready; then build_remotely SEBTYPE_CHECKOUT="$root" tools/build.sh "$@"; exit; fi
minutes=$1 name=$2
shift 2
at=${SEBTYPE_CHECKOUT:-$root}
# PWD too: bash takes the inherited one when it names the same folder, and it would be yanglab16's path.
fedora_container -v "$(pwd -P):$at" -w "$at" -e PWD="$at"
# shellcheck disable=SC2154  # container: set by fedora_container
out=$(build_lock "$minutes" "$name" "${container[@]}" env CARGO_BUILD_JOBS="$BUILD_JOBS" "$@")
echo "${out//"$at/"/"$root/"}"
