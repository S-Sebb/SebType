#!/usr/bin/env bash
# Publishes SebType <VERSION> as a GitHub release of this repo, tagged v<VERSION>: one installer per
# platform (Decisions #2, #427): the signed arm64 release APK, where Obtainium picks it up, and what CI built
# from the same commit (docs/install.md): the Windows setup and the Linux installer.
# Run from a clean checkout of origin/main, after the PR that bumps VERSION has merged and its Windows
# setup and Linux RPM runs have passed.
#   android/release.sh            build, check and publish
#   android/release.sh --dry-run  check the tag and download the PC installers, then stop: no build, no release
set -euo pipefail
source "$(dirname "$0")/../tools/lib.sh"
source "$(dirname "$0")/../linux/versions.sh"
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

# What CI built from this commit, before anything is built or published.
mkdir -p "$TASK_OUT"
ci=$(mktemp -d "$TASK_OUT/release-ci.XXXXXX")
trap 'rm -rf "$ci"' EXIT
# ci_artifact <workflow> <what> <artifact>: downloads <artifact> of this commit's successful <workflow> run into
# $ci/<artifact> and prints the run's id. Only main's own runs: a pull_request run reports its head's SHA but
# builds the merge with its base branch.
ci_artifact() {
  local run
  # Picks success in -q, not with --status success: GitHub's status filter can leave out a successful run for hours (#511).
  run=$(gh run list --workflow "$1" --branch main --commit "$head" --json databaseId,event,conclusion \
    -q '[.[] | select(.conclusion == "success" and (.event == "push" or .event == "workflow_dispatch"))][0].databaseId // empty')
  [[ -n $run ]] || { echo "release: no successful $2 run for $head (gh workflow run $1 --ref main)" >&2; return 1; }
  gh run download "$run" -n "$3" -D "$ci/$3" >/dev/null ||
    { echo "release: run $run has no $3 artifact (expired?); run $1 on main again" >&2; return 1; }
  echo "$run"
}
setup_run=$(ci_artifact windows-setup.yml "Windows setup" sebtype-setup)
setup=$TASK_OUT/SebType-setup-$version.exe
[[ -f $ci/sebtype-setup/SebType-setup-$version.exe ]] ||
  { echo "release: run $setup_run built $(ls "$ci/sebtype-setup"), not SebType-setup-$version.exe" >&2; exit 1; }
mv "$ci/sebtype-setup/SebType-setup-$version.exe" "$setup"
# The Linux installer: one self-extracting script packing sebtype and SebType's librime (#427).
linux_run=$(ci_artifact linux-rpm.yml "Linux installer" sebtype-linux-setup)
linux_setup=$TASK_OUT/$SEBTYPE_LINUX_SETUP
[[ -f $ci/sebtype-linux-setup/$SEBTYPE_LINUX_SETUP ]] ||
  { echo "release: run $linux_run built $(ls "$ci/sebtype-linux-setup"), not $SEBTYPE_LINUX_SETUP" >&2; exit 1; }
mv "$ci/sebtype-linux-setup/$SEBTYPE_LINUX_SETUP" "$linux_setup"
echo "release: $tag, version code $(git rev-list --first-parent --count HEAD), Windows setup from run $setup_run, Linux installer from run $linux_run" >&2
[[ -z $dry ]] || { echo "release: dry run, $setup and $linux_setup ready in $TASK_OUT; nothing built or published"; exit; }

apk=$(android/build.sh release)
asset=$TASK_OUT/SebType-$version-arm64-v8a.apk
cp "$apk" "$asset"

# Refuse an APK that isn't signed with the SebType key: Android would refuse it as an update anyway.
apksigner=$(ls -d "$ANDROID_HOME"/build-tools/*/apksigner | tail -1)
"$apksigner" verify --print-certs "$asset" | grep -q 'CN=SebType' || { echo "release: APK not signed with the SebType key" >&2; exit 1; }

gh release create "$tag" "$asset" "$setup" "$linux_setup" --target "$head" --title "SebType $version" \
  --notes "SebType $version: the Android app (arm64-v8a, $(du -h "$asset" | cut -f1)), the Windows setup ($(du -h "$setup" | cut -f1)), and the Linux installer for Fedora and Nobara ($SEBTYPE_LINUX_SETUP, $(du -h "$linux_setup" | cut -f1); run \`sh $SEBTYPE_LINUX_SETUP\`, see pc/linux/README.md). It installs as an update over the earlier releases, 0.1.30-sebtype.<n>, from when the Android app was based on FUTO Keyboard 0.1.30 (until #262); it now contains none of FUTO's code. SebType's own code (MIT) with the components README.md lists under their licences."
echo "release: published $tag"
