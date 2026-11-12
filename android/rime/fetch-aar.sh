#!/usr/bin/env bash
# Downloads the released Rime aar (librime with Lua) and checks its checksum.
#
#   ./fetch-aar.sh [DEST]   # default: out/rime-release.aar next to this script
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/versions.sh"

DEST="${1:-$HERE/out/rime-release.aar}"
read -r SHA256 ASSET < "$HERE/rime-android.sha256"

if [[ -f "$DEST" ]] && echo "$SHA256  $DEST" | sha256sum --check --status; then
  echo "$DEST is up to date"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$ASSET" \
  "https://github.com/S-Sebb/SebType/releases/download/rime-android-$RIME_ANDROID_VERSION/$ASSET"
if ! echo "$SHA256  $TMP/$ASSET" | sha256sum --check --status; then
  echo "checksum mismatch for $ASSET (expected $SHA256)" >&2
  exit 1
fi
mkdir -p "$(dirname "$DEST")"
mv "$TMP/$ASSET" "$DEST"
echo "$DEST"
