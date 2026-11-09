#!/usr/bin/env bash
# Builds the signed arm64 release APK from main and publishes it as a GitHub release of this repo,
# where Obtainium picks it up (docs/install.md). Run from a clean checkout of origin/main.
set -euo pipefail
cd "$(dirname "$0")/.."

git fetch -q origin main
[[ -z $(git status --porcelain --ignore-submodules=none) ]] || { echo "release: uncommitted changes" >&2; exit 1; }
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] ||
  { echo "release: HEAD is not origin/main; the version code counts main's commits" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "release: gh is not logged in" >&2; exit 1; }

apk=$(sebtype/build.sh release)
version="$(cat sebtype/upstream-version)-sebtype.$(git rev-list --first-parent --count HEAD)"
tag="v$version"
asset=/tmp/sebtype/SebType-$version-arm64-v8a.apk
mkdir -p /tmp/sebtype && cp "$apk" "$asset"

# Refuse an APK that isn't signed with the SebType key: Android would refuse it as an update anyway.
apksigner=$(ls -d "${ANDROID_HOME:-$HOME/Android/Sdk}"/build-tools/*/apksigner | tail -1)
"$apksigner" verify --print-certs "$asset" | grep -q 'CN=SebType' || { echo "release: APK not signed with the SebType key" >&2; exit 1; }

gh release create "$tag" "$asset" --target "$(git rev-parse HEAD)" --title "SebType $version" \
  --notes "SebType $version, based on FUTO Keyboard $(cat sebtype/upstream-version). arm64-v8a, $(du -h "$asset" | cut -f1)."
echo "release: published $tag"
