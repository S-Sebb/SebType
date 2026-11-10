#!/usr/bin/env bash
# Puts together what pc/windows/setup-ime.ps1 needs on the Windows PC, in one folder (and a .tar of it
# for xfer): the setup and its test, SebType's Weasel installer and perf-rime.exe (the newest successful
# run of .github/workflows/weasel.yml on this branch, else on main), and the Chinese data from the shared
# fetch script the phone build uses.
#   pc/windows/stage.sh [OUT_DIR]   # default build/sebtype-windows
# Needs gh (signed in) and curl.
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

# The Chinese data, the same rime-ice release the phone bundles.
data=$(mktemp -d); trap 'rm -rf "$data"' EXIT
"$repo/sebtype/fetch-rime-ice.sh" "$data" >/dev/null
cp "$data/rime/rime-ice.zip" "$data/rime/rime-ice-SOURCE.txt" "$out/"

cp "$here/setup-ime.ps1" "$here/test-setup-ime.ps1" "$here/perf-rime.ps1" "$here/TypingTest.cs" "$out/"
tar -C "$(dirname "$out")" -cf "$out.tar" "$(basename "$out")"
echo "$out.tar (Weasel from run $run)"
