#!/usr/bin/env bash
# Puts together what pc/windows/setup-ime.ps1 needs on the Windows PC, in one folder (and a .tar of it
# for xfer): the setup and its test, SebType's Weasel installer and perf-rime.exe (the newest successful
# run of .github/workflows/weasel.yml on this branch, else on main), and the Chinese data from the shared
# build the phone uses (tools/rime-data/build.sh).
#   pc/windows/stage.sh [OUT_DIR]   # default build/sebtype-windows
# Needs gh (signed in), curl, and gcc and librime 1.16.1 for tools/rime-data/build.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=$(realpath -m "${1:-$repo/build/sebtype-windows}")
rm -rf "$out"; mkdir -p "$out"

branch=$(git -C "$repo" branch --show-current)
run=
for b in "$branch" main; do
  run=$(gh run list -R S-Sebb/SebType --workflow weasel.yml --branch "$b" --status success --limit 1 \
    --json databaseId --jq '.[0].databaseId // empty')
  [[ -n $run ]] && break
done
[[ -n $run ]] || { echo "stage: no successful Weasel build; run the Weasel workflow first" >&2; exit 1; }
gh run download -R S-Sebb/SebType "$run" -n sebtype-weasel -D "$out"

# The Chinese data, the same zip the phone bundles.
data=$(mktemp -d); trap 'rm -rf "$data"' EXIT
"$repo/tools/rime-data/build.sh" "$data"
cp "$data/rime/rime-data.zip" "$out/"

cp "$here/setup-ime.ps1" "$here/test-setup-ime.ps1" "$here/perf-rime.ps1" "$here/TypingTest.cs" "$out/"
tar -C "$(dirname "$out")" -cf "$out.tar" "$(basename "$out")"
echo "$out.tar (Weasel from run $run)"
