# shellcheck shell=bash
# Mozc's Bazel builds for the phone (#335), and the downloads of the Linux RPM's (linux/build.sh, #361),
# sourced after tools/lib.sh (BAZEL_CACHE, BUILD_JOBS). Gradle takes this file and mozc-downloads.tsv as inputs
# of the tasks that use it, so it holds nothing else.
MOZC_DOWNLOADS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mozc-downloads.tsv

# mozc_bazel CONFIG COMMAND [ARG...]: Bazel in engines/mozc/src with Mozc's CONFIG (oss_android for libmozc.so,
# android/native/build-mozc.sh; oss_linux for the host tools that build the phone's dictionary,
# android/app/mozc-dictionary.sh), with one output root and disk cache in $BAZEL_CACHE/mozc-android.
# ANDROID_NDK_HOME names the app's NDK. Gradle runs them inside android/build.sh's build lock, so they take no
# lock themselves; the server exits soon after the build.
# Bazel downloads nothing itself (#335): it would at full speed, and yanglab16's port is shared. Bazel, the
# registry's files and every archive the builds use are in tools/mozc-downloads.tsv, fetched at the capped
# rate and checked by mozc_prefetch; Bazel reads the registry from that copy and the archives from its
# repository cache. tools/mozc-downloads.sh updates the list when engines/mozc's dependencies change.
mozc_bazel() {
  local config=$1 command=$2
  shift 2
  mozc_bazel_plain "$command" --config "$config" --config release_build --jobs="$BUILD_JOBS" \
    --disk_cache="$BAZEL_CACHE/mozc-android/disk" --symlink_prefix=/ --noshow_progress "$@"
}
# mozc_bazel_plain COMMAND [ARG...]: the same Bazel without the build's options, for commands that take none
# (mod).
mozc_bazel_plain() {
  local command=$1 cache=$BAZEL_CACHE/mozc-android bazel
  shift
  bazel=$(mozc_fetch "$cache") || return
  (cd "$(dirname "${BASH_SOURCE[0]}")/../engines/mozc/src" &&
    SEBTYPE_ANDROID_NDK=${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must name the app\'s NDK} \
    "$bazel" --output_user_root="$cache/bazel" --max_idle_secs=15 --host_jvm_args=-Xmx2g "$command" \
    --registry="file://$cache/registry" --repository_cache="$cache/repos" --repository_disable_download "$@")
}
# mozc_fetch CACHE: what the list names, into CACHE (mozc_prefetch), after checking that its Bazel is the
# one Mozc names; prints that Bazel's path. The Linux package's build (linux/build.sh) runs it too, and its
# spec runs that Bazel with the same registry, repository cache and downloads disabled.
mozc_fetch() {
  local version
  version=$(sed -n 's/^USE_BAZEL_VERSION=//p' "$(dirname "${BASH_SOURCE[0]}")/../engines/mozc/src/.bazeliskrc")
  grep -q "/$version/release/bazel-$version-linux-x86_64	bazel$" "$MOZC_DOWNLOADS" ||
    { echo "mozc_bazel: Mozc wants Bazel $version; put it in tools/mozc-downloads.tsv" >&2; return 1; }
  mozc_prefetch "$1" || return
  echo "$1/$(awk '$3 == "bazel" {print "bazel-" substr($1, 1, 12)}' "$MOZC_DOWNLOADS")"
}
# mozc_prefetch CACHE: what tools/mozc-downloads.tsv lists (sha256, URL, where), into CACHE (mozc_file), each
# once, capped at 35 MB/s, and checked. A file counts as there, unhashed, when its stamp (mozc_place) holds the
# sha256 the list now pins and the file is still the one hashed: a registry file's path doesn't name its digest.
# Builds may run this at the same time: each downloads to a file of its own and moves it into place in one step.
mozc_prefetch() {
  local sha url where file stamp id tmp
  while read -r sha url where; do
    file=$(mozc_file "$1" "$sha" "$url" "$where") stamp=
    [[ -f $1/stamps/${file#"$1"/} ]] && read -r stamp < "$1/stamps/${file#"$1"/}"
    id=$(mozc_identity "$file")
    [[ -n $id && $stamp == "$sha $id" ]] && continue
    # Unstamped, replaced or stale: kept only if it is what the list pins
    if [[ -n $id ]] && echo "$sha  $file" | sha256sum -c --status; then
      mozc_place "$1" "" "$file" "$url" "$where" "$sha" "$id"; continue
    fi
    mkdir -p "$(dirname "$file")"
    tmp=$(mktemp --suffix=.part "$file.XXXXXX")
    curl -fsSL --retry 3 --limit-rate 35M -o "$tmp" "$url" && echo "$sha  $tmp" | sha256sum -c --status ||
      { rm -f "$tmp"; echo "mozc_prefetch: $url failed or changed (sha256)" >&2; return 1; }
    [[ $where != bazel ]] || chmod +x "$tmp"
    mozc_place "$1" "$tmp" "$file" "$url" "$where" "$sha" "$(mozc_identity "$tmp")"
  done < <(grep -v '^#' "$MOZC_DOWNLOADS")
}
# mozc_identity FILE: which file FILE is (inode, size, mtime in ns), or nothing, with success, if there is none
# (the builds run under set -e). mv keeps it, and replacing or rewriting the file changes it.
mozc_identity() { stat -c '%i %s %.9Y' "$1" 2>/dev/null || true; }
# mozc_file CACHE SHA256 URL WHERE: where Bazel looks for that file: Bazel itself (bazel), a file of the
# registry's, under its path in the Bazel Central Registry (registry), or an archive in Bazel's repository
# cache, found by its sha256 (repos).
mozc_file() {
  case $4 in
    bazel) echo "$1/bazel-${2:0:12}" ;;
    registry) echo "$1/registry/${3#https://bcr.bazel.build/}" ;;
    repos) echo "$1/repos/content_addressable/sha256/$2/file" ;;
  esac
}

# mozc_place CACHE DOWNLOAD FILE URL WHERE SHA256 IDENTITY: moves DOWNLOAD, checked, to FILE (mozc_file), or
# with no DOWNLOAD takes FILE as it is, then stamps it in CACHE/stamps with SHA256 and IDENTITY, the checked
# file's (mozc_identity), taken before the move: if another build replaces FILE in between, the stamp doesn't
# match the file there and the next prefetch hashes it again. An archive also gets the marker Bazel's
# repository cache wants beside it: without one for the rule's canonical id, by default its URL, Bazel doesn't
# take the file from the cache.
mozc_place() {
  local stamp=$1/stamps/${3#"$1"/} tmp
  [[ -z $2 ]] || mv -f "$2" "$3"
  [[ $5 != repos ]] || touch "$(dirname "$3")/id-$(printf %s "$4" | sha256sum | cut -d' ' -f1)"
  mkdir -p "$(dirname "$stamp")"
  tmp=$(mktemp "$stamp.XXXXXX") && echo "$6 $7" > "$tmp" && mv -f "$tmp" "$stamp"
}

# mozc_files CONFIG TARGET: the paths of TARGET's output files, after mozc_bazel CONFIG built it.
mozc_files() {
  local root
  root=$(mozc_bazel "$1" info execution_root 2>/dev/null)
  mozc_bazel "$1" cquery --output=files "$2" 2>/dev/null | sed "s|^|$root/|"
}
