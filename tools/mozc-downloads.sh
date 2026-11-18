#!/usr/bin/env bash
# Updates tools/mozc-downloads.tsv, the files Mozc's Bazel builds download (tools/mozc-bazel.sh's mozc_bazel), after
# engines/mozc's dependencies changed (#335). It runs those builds' loading and analysis with downloads
# disabled; each file Bazel says it lacks is fetched at the capped rate, recorded with its sha256 and put where
# Bazel looks (mozc_file), until they need nothing more.
#   tools/mozc-downloads.sh
# Run it on the build host, inside the build container (as android/build.sh's builds run), with
# ANDROID_NDK_HOME set. BAZEL_CACHE names the cache it fills; new lines go to the end of the list.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/lib.sh
source tools/mozc-bazel.sh
cache=$BAZEL_CACHE/mozc-android
# failed_repos: the repositories Bazel's output (stdin) says it couldn't download.
failed_repos() {
  { grep -oE "Failed to download repository @@[^:]+: download is disabled" || true; } | sed -E 's/.*@@([^:]+):.*/\1/' | sort -u
}
builds=("oss_android //android/jni:mozc.arm64 //android/jni:mozc.x86_64"
  "oss_linux //data_manager/oss:mozc_dataset_for_oss //sebtype:libsebtype-mozc.so")
for build in "${builds[@]}"; do
  read -ra args <<<"$build"
  while ! log=$(mozc_bazel "${args[0]}" build --nobuild --keep_going "${args[@]:1}" 2>&1); do
    missing=$(sed -nE "s|.*file://$cache/registry/([^ :]+): not found.*|https://bcr.bazel.build/\1 registry|p
      s|.*Module ([^@ ]+)@([^ ]+)'s source\.json not found in registry.*|https://bcr.bazel.build/modules/\1/\2/source.json registry|p
      s|.*Failed to download (https://[^ ]+) .*download is disabled.*|\1 repos|p" <<<"$log" | sort -u)
    # A repository's download names only the repository: a module's source.json in the registry, or else its
    # rule's attributes, name its files. mod show_repo reads those but fetches the modules they come from first:
    # those it can't fetch go the first way.
    repos=$(failed_repos <<<"$log")
    files=
    for _ in 1 2; do
      modules=$(grep -E '^[^+]+\+?$' <<<"$repos") || true
      others=$(grep -vE '^[^+]+\+?$' <<<"$repos" | sed 's/^/@@/') || true
      # shellcheck disable=SC2086
      [[ -z $modules ]] || { files+=$(mozc_bazel_plain mod graph --output=json |
        python3 -I tools/mozc-repo-urls.py "$cache/registry" $modules)$'\n'; break; }
      [[ -n $others ]] || break
      # shellcheck disable=SC2086
      if shown=$(mozc_bazel_plain mod show_repo $others --output=streamed_jsonproto 2>"$cache/show_repo.log"); then
        files+=$(python3 -I tools/mozc-repo-urls.py "$(mozc_bazel_plain info output_base)" <<<"$shown"); break
      fi
      repos=$(failed_repos < "$cache/show_repo.log")
    done
    grep '^?' <<<"$files" && { echo "mozc-downloads: can't tell what those download" >&2; exit 1; }
    missing+=$'\n'$files
    # Only what the list lacks: Bazel lacking a listed file means it doesn't find it where mozc_file puts it.
    missing=$(grep . <<<"$missing" | sort -u | while read -r url rest; do
      grep -q "	$url	${rest%% *}$" tools/mozc-downloads.tsv || echo "$url $rest"; done)
    [[ -n $missing ]] || { tail -20 <<<"$log" >&2; echo "mozc-downloads: Bazel failed, and not for a file the list lacks" >&2; exit 1; }
    while read -r url where want; do
      tmp=$(mktemp "$cache/download.XXXXXX")
      curl -fsSL --retry 3 --limit-rate 35M -o "$tmp" "$url" || { rm -f "$tmp"; echo "mozc-downloads: $url failed" >&2; exit 1; }
      sha=$(sha256sum "$tmp" | cut -d' ' -f1) file=$(mozc_file "$cache" "$sha" "$url" "$where")
      [[ -z ${want:-} || $want == "$sha" ]] || { rm "$tmp"; echo "mozc-downloads: $url isn't what its rule pins" >&2; exit 1; }
      mkdir -p "$(dirname "$file")" && mozc_place "$cache" "$tmp" "$file" "$url" "$where" "$sha"
      printf '%s\t%s\t%s\n' "$sha" "$url" "$where" >> tools/mozc-downloads.tsv
      echo "added $url"
    done <<<"$missing"
  done
done
