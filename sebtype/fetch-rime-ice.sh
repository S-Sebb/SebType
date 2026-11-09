#!/usr/bin/env bash
# Puts the bundled rime-ice into the APK's assets: rime-ice's own release zip, unmodified and
# checksum-checked (it has a prebuilt build/, so the phone needn't compile the tables), and the bundle
# version the app reinstalls and redeploys on. Gradle runs this before every build.
#   sebtype/fetch-rime-ice.sh [ASSETS_DIR]   # default build/sebtype-assets
#
# rime-ice is GPL-3.0; its LICENSE is inside the zip. Source of the exact version bundled:
# https://github.com/iDvel/rime-ice/tree/6810e8916d160498620a16fef2135956fecbd485 (tag 2026.06.30)
set -euo pipefail
cd "$(dirname "$0")/.."

RIME_ICE_VERSION=2026.06.30
RIME_ICE_COMMIT=6810e8916d160498620a16fef2135956fecbd485
RIME_ICE_ASSET=full_compiled.zip
RIME_ICE_SHA256=ae810e0023f28d3eb45ff98a7c58830dd0b505c2272638a321fa6d5a6f5d5418
# Bump to make every install reinstall and redeploy the bundle, e.g. after changing how the app sets it up.
BUNDLE_REVISION=1

out=${1:-build/sebtype-assets}/rime
cache=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype
zip=$cache/rime-ice-$RIME_ICE_VERSION-$RIME_ICE_ASSET
mkdir -p "$cache" "$out"

if ! echo "$RIME_ICE_SHA256  $zip" | sha256sum -c --status 2>/dev/null; then
  curl -fsSL -o "$zip.part" "https://github.com/iDvel/rime-ice/releases/download/$RIME_ICE_VERSION/$RIME_ICE_ASSET"
  echo "$RIME_ICE_SHA256  $zip.part" | sha256sum -c --status ||
    { echo "fetch-rime-ice: checksum mismatch for $RIME_ICE_ASSET $RIME_ICE_VERSION" >&2; exit 1; }
  mv "$zip.part" "$zip"
fi
cmp -s "$zip" "$out/rime-ice.zip" || cp "$zip" "$out/rime-ice.zip"
echo "rime-ice $RIME_ICE_VERSION sebtype $BUNDLE_REVISION" > "$out/bundle-version"
cat > "$out/rime-ice-SOURCE.txt" <<EOF
rime-ice.zip is rime-ice (雾凇拼音) $RIME_ICE_VERSION, unmodified: the release asset
https://github.com/iDvel/rime-ice/releases/download/$RIME_ICE_VERSION/$RIME_ICE_ASSET
(sha256 $RIME_ICE_SHA256). rime-ice is licensed under the GNU GPL version 3; the licence
is the LICENSE file inside rime-ice.zip. Its source, at the exact commit bundled:
https://github.com/iDvel/rime-ice/tree/$RIME_ICE_COMMIT
EOF
