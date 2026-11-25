#!/usr/bin/env bash
# Builds the Configurator, its unit tests (release) and its test build (sebtype-configurator-update-test,
# next to it) and prints their paths: the app, the tests' executable, the test build. The tests run that
# executable, built in the build lock (#248):
#
#   tools/build.sh 30 NAME pc/configurator/build.sh
set -euo pipefail
cd "$(dirname "$0")"
# The tests' build first (#422: it takes a release served on 127.0.0.1), then the one setup-ime.sh installs.
cargo build --release --features update-test >&2
cp -f target/release/sebtype-configurator target/release/sebtype-configurator-update-test
cargo build --release >&2
tests=$(cargo test --release --no-run --message-format=json | sed -n 's/.*"executable":"\([^"]*\)".*/\1/p')
cp -f "$tests" target/release/sebtype-configurator-test
# setup-ime.sh rebuilds a Configurator older than its sources, and a fake account (test-setup-ime.sh) has
# nothing to rebuild with: this one is current.
touch target/release/sebtype-configurator
echo "$PWD/target/release/sebtype-configurator"
echo "$PWD/target/release/sebtype-configurator-test"
echo "$PWD/target/release/sebtype-configurator-update-test"
