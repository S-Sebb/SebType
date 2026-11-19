#!/usr/bin/env bash
# Tests android/release.sh without publishing (#420), and the release APK's version.
#   ISSUE=<n> android/test/release.sh   one line per check; logs in ~/scratch/SebType/<ISSUE>/test-release-*.log
# release.sh --dry-run runs in a clone whose origin/main is main's latest commit with a successful Windows
# setup run (origin is a local repo, gh talks to GitHub through GH_REPO), with this checkout's release.sh and
# VERSION laid over it. Nothing is tagged, pushed or published. Exit 0 only if all pass.
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
repo=$PWD out=$TASK_OUT; mkdir -p "$out"
fails=0
result() { echo "$1 $2${3:+: $3}"; [[ $1 != FAIL ]] || fails=$((fails + 1)); }

command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { echo "preflight: gh is not logged in"; exit 1; }
git fetch -q origin main
setup_sha=$(gh run list --workflow windows-setup.yml --branch main --status success --event push --limit 1 \
  --json headSha -q '.[0].headSha // empty')
[[ -n $setup_sha ]] || { echo "preflight: no successful Windows setup run on main"; exit 1; }
# A main commit (#416's) that never ran windows-setup.yml: it changed only the Android app.
no_setup_sha=8eba6a8f90

tmp=$(mktemp -d "$out/release-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
git init -q --bare "$tmp/origin.git"
echo "$(git rev-parse --path-format=absolute --git-common-dir)/objects" > "$tmp/origin.git/objects/info/alternates"
printf '/VERSION\n' > "$tmp/excludes"
# dry_run <commit> <version> <log>: release.sh --dry-run where main is <commit> and VERSION is <version>
dry_run() {
  git -C "$tmp/origin.git" update-ref refs/heads/main "$1"
  rm -rf "$tmp/clone" && git clone -q -b main --shared "$tmp/origin.git" "$tmp/clone" || return 1
  cp android/release.sh "$tmp/clone/android/release.sh"
  git -C "$tmp/clone" update-index --assume-unchanged android/release.sh
  echo "$2" > "$tmp/clone/VERSION"
  GH_REPO=S-Sebb/SebType GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0="$tmp/excludes" \
    timeout 300 "$tmp/clone/android/release.sh" --dry-run > "$out/test-release-$3.log" 2>&1
}

version=$(cat VERSION)
if dry_run "$setup_sha" "$version" dry-run && [[ -s $out/SebType-setup-$version.exe ]]; then
  result PASS dry-run "SebType-setup-$version.exe from ${setup_sha:0:10}'s run"
else result FAIL dry-run "see $out/test-release-dry-run.log"; fi
rm -f "$out/SebType-setup-$version.exe"

published=$(gh release list --limit 1 --exclude-drafts --json tagName -q '.[0].tagName')
if ! dry_run "$setup_sha" "${published#v}" tag-exists && grep -q "release: $published exists" "$out/test-release-tag-exists.log"; then
  result PASS tag-exists "refuses $published"
else result FAIL tag-exists "see $out/test-release-tag-exists.log"; fi

if ! dry_run "$no_setup_sha" "$version" no-setup && grep -q "no successful Windows setup run" "$out/test-release-no-setup.log"; then
  result PASS no-setup "refuses a commit without a setup run"
else result FAIL no-setup "see $out/test-release-no-setup.log"; fi

# The release APK of this checkout: VERSION's name, the first-parent commit count as its code.
apk=$(timeout 1800 android/build.sh release 2> "$out/test-release-build.log" | tail -1)
if [[ -f $apk ]]; then
  badging=$("$(ls -d "$ANDROID_HOME"/build-tools/* | tail -1)/aapt2" dump badging "$apk" | head -1)
  code=$(git -C "$repo" rev-list --first-parent --count HEAD)
  if [[ $badging == *"versionCode='$code'"*"versionName='$version'"* ]]; then
    result PASS apk-version "$version, code $code"
  else result FAIL apk-version "$badging (want $version, code $code)"; fi
else result FAIL apk-version "release build failed, see $out/test-release-build.log"; fi

exit $((fails > 0))
