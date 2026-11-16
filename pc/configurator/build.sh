#!/usr/bin/env bash
# Builds the Configurator and its unit tests (release) and prints their paths: the app, then the tests'
# executable. The tests run that executable, so nobara-pc doesn't compile them (#248):
#
#   tools/build.sh 30 NAME pc/configurator/build.sh   # on yanglab16, copied back
set -euo pipefail
cd "$(dirname "$0")"
cargo build --release >&2
tests=$(cargo test --release --no-run --message-format=json | sed -n 's/.*"executable":"\([^"]*\)".*/\1/p')
cp -f "$tests" target/release/sebtype-configurator-test
# setup-ime.sh rebuilds a Configurator older than its sources, and a copy brought back has nothing to
# rebuild from: this one is current.
touch target/release/sebtype-configurator
echo "$PWD/target/release/sebtype-configurator"
echo "$PWD/target/release/sebtype-configurator-test"
