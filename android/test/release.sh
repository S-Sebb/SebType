#!/usr/bin/env bash
# Tests android/release.sh without publishing (#420), and the release APK's version.
#   ISSUE=<n> android/test/release.sh   one line per check; logs in ~/scratch/SebType/<ISSUE>/test-release-*.log
# release.sh --dry-run runs in a clone whose origin/main is main's latest commit with successful Windows setup
# and Linux RPM runs (origin is a local repo, gh talks to GitHub through GH_REPO), with this checkout's release.sh laid
# over it. Nothing is tagged, pushed to GitHub or published. Exit 0 only if all pass.
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
test_key || exit 1
repo=$PWD out=$TASK_OUT; mkdir -p "$out"
fails=0
result() { echo "$1 $2${3:+: $3}"; [[ $1 != FAIL ]] || fails=$((fails + 1)); }

command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { echo "preflight: gh is not logged in"; exit 1; }
git fetch -q origin main
# Success is picked in -q, not with --status success, which can leave out a successful run for hours (#511).
setup_sha=$(gh run list --workflow windows-setup.yml --branch main --event push --limit 20 \
  --json headSha,conclusion -q '[.[] | select(.conclusion == "success")][0].headSha // empty')
[[ -n $setup_sha ]] || { echo "preflight: no successful Windows setup run on main"; exit 1; }
# A main commit (#416's) that never ran windows-setup.yml: it changed only the Android app.
no_setup_sha=8eba6a8f90
# A main commit (#419's) with a Windows setup run, from before linux-rpm.yml (#421).
no_rpm_sha=45ae6594c8
# Main's latest commit with both runs and the single Linux installer (#427).
rpm_shas=$(gh run list --workflow linux-rpm.yml --branch main --event push --limit 20 \
  --json headSha,conclusion -q '.[] | select(.conclusion == "success") | .headSha')
both_sha=
while read -r sha; do
  [[ -n $sha ]] && git cat-file -e "$sha:linux/build-installer.sh" 2>/dev/null && { both_sha=$sha; break; }
done < <(gh run list --workflow windows-setup.yml --branch main --event push --limit 20 \
  --json headSha,conclusion -q '.[] | select(.conclusion == "success") | .headSha' | grep -xF -f <(echo "${rpm_shas:-none}"))
# A PR's head with a successful pull_request run, which built the PR merged into its base, not this commit.
pr_sha=$(gh run list --workflow windows-setup.yml --event pull_request --limit 20 \
  --json headSha,conclusion -q '[.[] | select(.conclusion == "success")][0].headSha // empty')
[[ -n $pr_sha ]] && git fetch -q origin "$pr_sha" || { echo "preflight: no successful pull_request Windows setup run to fetch"; exit 1; }

tmp=$(mktemp -d "$out/release-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
git init -q --bare "$tmp/origin.git"
echo "$(git rev-parse --path-format=absolute --git-common-dir)/objects" > "$tmp/origin.git/objects/info/alternates"
printf '/VERSION\n' > "$tmp/excludes"
# dry_run <commit> <version> <log>: release.sh --dry-run where main is <commit> and VERSION is <version>.
# A VERSION that <commit> tracks with another value is committed over it, and the local origin's main moved
# there. Commits from before VERSION existed get it untracked, kept out of git status by core.excludesFile.
dry_run() {
  git -C "$tmp/origin.git" update-ref refs/heads/main "$1"
  rm -rf "$tmp/clone" && git clone -q -b main --shared "$tmp/origin.git" "$tmp/clone" || return 1
  cp android/release.sh "$tmp/clone/android/release.sh"
  git -C "$tmp/clone" update-index --assume-unchanged android/release.sh
  echo "$2" > "$tmp/clone/VERSION"
  if git -C "$tmp/clone" ls-files --error-unmatch VERSION >/dev/null 2>&1 && ! git -C "$tmp/clone" diff --quiet VERSION; then
    git -C "$tmp/clone" -c user.name=test -c user.email=test@invalid commit -q -m "VERSION $2" VERSION &&
      git -C "$tmp/origin.git" fetch -q "$tmp/clone" HEAD &&
      git -C "$tmp/origin.git" update-ref refs/heads/main FETCH_HEAD || return 1
  fi
  GH_REPO=S-Sebb/SebType GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0="$tmp/excludes" \
    timeout 300 "$tmp/clone/android/release.sh" --dry-run > "$out/test-release-$3.log" 2>&1
}

# The Windows setup and the single Linux installer (#427).
both_dry() {
  local v
  v=$(git show "$both_sha:VERSION") || return 1
  dry_run "$both_sha" "$v" dry-run &&
    [[ -s $out/SebType-setup-$v.exe && -s $out/SebType-setup-$v-linux-x86_64.sh ]] || return 1
  rm -f "$out/SebType-setup-$v-linux-x86_64.sh"
}
if [[ -z $both_sha ]]; then
  result SKIP dry-run "no main commit has both a Windows setup and a Linux installer run yet (once #427 is on main)"
elif both_dry; then result PASS dry-run "the Windows setup and Linux installer from ${both_sha:0:10}'s runs"
else result FAIL dry-run "see $out/test-release-dry-run.log"; fi
rm -f "$out"/SebType-setup-*.exe "$out"/SebType-setup-*-linux-x86_64.sh

# A setup run without the Linux installer: refused after the setup is found.
# The version that commit's setup run built (it predates VERSION: sebtype.iss's default), not this checkout's.
no_rpm_version=$(git show "$no_rpm_sha:pc/windows/setup/sebtype.iss" | sed -n 's/^ *#define Version "\(.*\)"$/\1/p')
if gh release view "v$no_rpm_version" >/dev/null 2>&1; then
  result SKIP no-rpm "v$no_rpm_version is already published, so ${no_rpm_sha:0:10} stops at the tag check"
elif ! dry_run "$no_rpm_sha" "$no_rpm_version" no-rpm && grep -q "no successful Linux installer run" "$out/test-release-no-rpm.log"; then
  result PASS no-rpm "refuses ${no_rpm_sha:0:10}, which has a setup run but no Linux installer run"
else result FAIL no-rpm "see $out/test-release-no-rpm.log"; fi
rm -f "$out"/SebType-setup-*.exe

published=$(gh release list --limit 1 --exclude-drafts --json tagName -q '.[0].tagName')
# On this checkout's HEAD, which tracks VERSION, as main will.
if ! dry_run "$(git rev-parse HEAD)" "${published#v}" tag-exists && grep -q "release: $published exists" "$out/test-release-tag-exists.log"; then
  result PASS tag-exists "refuses $published"
else result FAIL tag-exists "see $out/test-release-tag-exists.log"; fi

# An unpublished version so release.sh passes the tag check and reaches the CI run checks.
unpublished=99.99.99
if ! dry_run "$no_setup_sha" "$unpublished" no-setup && grep -q "no successful Windows setup run" "$out/test-release-no-setup.log"; then
  result PASS no-setup "refuses a commit without a setup run"
else result FAIL no-setup "see $out/test-release-no-setup.log"; fi

if ! dry_run "$pr_sha" "$unpublished" pr-run && grep -q "no successful Windows setup run" "$out/test-release-pr-run.log"; then
  result PASS pr-run "refuses ${pr_sha:0:10}, whose only run is a PR's"
else result FAIL pr-run "see $out/test-release-pr-run.log"; fi

# The release APK of this checkout: VERSION's name, the first-parent commit count as its code.
apk=$(timeout 1800 android/build.sh release 2> "$out/test-release-build.log" | tail -1)
if [[ -f $apk ]]; then
  badging=$("$(ls -d "$ANDROID_HOME"/build-tools/* | tail -1)/aapt2" dump badging "$apk" | head -1)
  code=$(git -C "$repo" rev-list --first-parent --count HEAD) name=$(cat VERSION)
  if [[ $badging == *"versionCode='$code'"*"versionName='$name'"* ]]; then
    result PASS apk-version "$name, code $code"
  else result FAIL apk-version "$badging (want $name, code $code)"; fi
else result FAIL apk-version "release build failed, see $out/test-release-build.log"; fi

exit $((fails > 0))
