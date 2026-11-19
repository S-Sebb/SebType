#!/usr/bin/env bash
# Publishes SebType <VERSION> as a GitHub release of this repo, tagged v<VERSION>: the signed arm64 release
# APK, where Obtainium picks it up, and the Windows setup CI built from the same commit (docs/install.md).
# Run from a clean checkout of origin/main, after the PR that bumps VERSION has merged and its Windows
# setup run has passed.
#   android/release.sh            build, check and publish
#   android/release.sh --dry-run  check the tag and download the setup, then stop: no build, no release
set -euo pipefail
source "$(dirname "$0")/../tools/lib.sh"
cd "$(dirname "$0")/.."
dry=; [[ ${1:-} == --dry-run ]] && dry=1

git fetch -q --tags origin main
[[ -z $(git status --porcelain --ignore-submodules=none) ]] || { echo "release: uncommitted changes" >&2; exit 1; }
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] ||
  { echo "release: HEAD is not origin/main; the version code counts main's commits" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "release: gh is not logged in" >&2; exit 1; }

version=$(cat VERSION)
tag="v$version"
head=$(git rev-parse HEAD)
# Each release bumps VERSION in its own PR, so a tag that exists means this version is out already.
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || gh release view "$tag" >/dev/null 2>&1; then
  echo "release: $tag exists; bump VERSION in a PR first" >&2; exit 1
fi

# The Windows setup from this commit's windows-setup.yml run, before anything is built or published.
mkdir -p "$TASK_OUT"
setup_dir=$(mktemp -d "$TASK_OUT/release-setup.XXXXXX")
trap 'rm -rf "$setup_dir"' EXIT
# Only main's own runs: a pull_request run reports its head's SHA but builds the merge with its base branch.
run=$(gh run list --workflow windows-setup.yml --branch main --commit "$head" --status success --json databaseId,event \
  -q '[.[] | select(.event == "push" or .event == "workflow_dispatch")][0].databaseId // empty')
[[ -n $run ]] || { echo "release: no successful Windows setup run for $head (gh workflow run windows-setup.yml --ref main)" >&2; exit 1; }
gh run download "$run" -n sebtype-setup -D "$setup_dir" >/dev/null ||
  { echo "release: run $run has no sebtype-setup artifact (expired?); run windows-setup.yml on main again" >&2; exit 1; }
setup=$TASK_OUT/SebType-setup-$version.exe
[[ -f $setup_dir/SebType-setup-$version.exe ]] ||
  { echo "release: run $run built $(ls "$setup_dir"), not SebType-setup-$version.exe" >&2; exit 1; }
mv "$setup_dir/SebType-setup-$version.exe" "$setup"
echo "release: $tag, version code $(git rev-list --first-parent --count HEAD), setup from run $run" >&2
[[ -z $dry ]] || { echo "release: dry run, $setup ready; nothing built or published"; exit; }

apk=$(android/build.sh release)
asset=$TASK_OUT/SebType-$version-arm64-v8a.apk
cp "$apk" "$asset"

# Refuse an APK that isn't signed with the SebType key: Android would refuse it as an update anyway.
apksigner=$(ls -d "$ANDROID_HOME"/build-tools/*/apksigner | tail -1)
"$apksigner" verify --print-certs "$asset" | grep -q 'CN=SebType' || { echo "release: APK not signed with the SebType key" >&2; exit 1; }

gh release create "$tag" "$asset" "$setup" --target "$head" --title "SebType $version" \
  --notes "SebType $version: the Android app (arm64-v8a, $(du -h "$asset" | cut -f1)) and the Windows setup ($(du -h "$setup" | cut -f1)). It installs as an update over the earlier releases, 0.1.30-sebtype.<n>, from when the Android app was based on FUTO Keyboard 0.1.30 (until #262); it now contains none of FUTO's code. SebType's own code (MIT) with the components README.md lists under their licences."
echo "release: published $tag"
