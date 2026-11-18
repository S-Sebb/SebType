#!/usr/bin/env bash
# Checks Mozc's capped prefetch (tools/mozc-bazel.sh's mozc_prefetch) and the list's module resolver
# (tools/mozc-repo-urls.py) offline (#335), with a stub curl that serves files from a folder:
# - a cached file whose pinned sha256 changed, or a corrupt cached Bazel, is fetched again;
# - a cached file that was replaced after its stamp was written, or deleted with its stamp kept, is
#   fetched again;
# - two prefetches at once into one empty cache both succeed;
# - with two versions of a module in the registry's copy, the one Bazel selected is taken.
#   tools/test-mozc-downloads.sh
# One line per check; exit 0 only if all pass.
set -uo pipefail
cd "$(dirname "$0")/.."
source tools/lib.sh
source tools/mozc-bazel.sh
mkdir -p "$TASK_OUT"; dir=$(mktemp -d "$TASK_OUT/test-mozc-downloads.XXXXXX")
trap 'rm -rf "$dir"' EXIT
status=0
result() { echo "$1 $2${3:+: $3}"; [[ $1 == PASS ]] || status=1; }

# curl ... -o FILE URL: URL's file from the fake server, slowly, so prefetches at once overlap
curl() {
  local out=${*: -2:1} url=${*: -1}
  sleep 0.3
  cp "$dir/server/${url#https://}" "$out"
}
# serve PATH CONTENT: puts CONTENT on the fake server at https://PATH, prints its list line's sha256
serve() {
  mkdir -p "$(dirname "$dir/server/$1")"
  printf %s "$2" > "$dir/server/$1"
  sha256sum < "$dir/server/$1" | cut -d' ' -f1
}
export dir MOZC_DOWNLOADS=$dir/list.tsv
list() { printf '%s\n' "$@" > "$MOZC_DOWNLOADS"; }

# prefetch CACHE: mozc_prefetch as the builds run it, under set -e, in a bash of its own: in a check, after
# && or as a job, set -e would be off
prefetch() { bash -ec 'mozc_prefetch "$1"' _ "$1"; }
export -f curl mozc_prefetch mozc_identity mozc_file mozc_place

# A pinned digest changes: the registry file's path stays, its cached bytes must not
cache=$dir/stale
old=$(serve bcr.bazel.build/modules/m/1.0/MODULE.bazel old)
bazel=$(serve releases.bazel.build/bazel good-bazel)
list "$old	https://bcr.bazel.build/modules/m/1.0/MODULE.bazel	registry" \
  "$bazel	https://releases.bazel.build/bazel	bazel"
prefetch "$cache"
new=$(serve bcr.bazel.build/modules/m/1.0/MODULE.bazel new)
list "$new	https://bcr.bazel.build/modules/m/1.0/MODULE.bazel	registry" \
  "$bazel	https://releases.bazel.build/bazel	bazel"
prefetch "$cache" && got=$(cat "$cache/registry/modules/m/1.0/MODULE.bazel")
[[ ${got:-} == new ]] && result PASS changed-digest || result FAIL changed-digest "cache kept '${got:-}'"

# A corrupt Bazel without a stamp (a cache from before them) is checked, not trusted
rm -rf "$cache/stamps"
printf corrupt > "$cache/bazel-${bazel:0:12}"
prefetch "$cache" && got=$(cat "$cache/bazel-${bazel:0:12}")
[[ ${got:-} == good-bazel ]] && result PASS corrupt-bazel || result FAIL corrupt-bazel "cache kept '${got:-}'"

# A deleted Bazel whose stamp stayed is fetched again
rm "$cache/bazel-${bazel:0:12}"
prefetch "$cache" && got=$(cat "$cache/bazel-${bazel:0:12}" 2>/dev/null)
[[ ${got:-} == good-bazel ]] && result PASS deleted-file || result FAIL deleted-file "no Bazel after the prefetch"

# Two worktrees pin different bytes for one registry path, and publish interleaved: A moves its file in, B
# moves its own in and stamps it, then A stamps. A's next prefetch must not trust B's bytes.
cache=$dir/interleaved path=bcr.bazel.build/modules/m/2.0/MODULE.bazel file=$cache/registry/modules/m/2.0/MODULE.bazel
mkdir -p "$(dirname "$file")"
printf A > "$dir/a.part"; printf B > "$dir/b.part"
sha_a=$(sha256sum < "$dir/a.part" | cut -d' ' -f1) sha_b=$(sha256sum < "$dir/b.part" | cut -d' ' -f1)
id_a=$(mozc_identity "$dir/a.part" 2>/dev/null)
mv "$dir/a.part" "$file"
mozc_place "$cache" "$dir/b.part" "$file" "https://$path" registry "$sha_b" "$(mozc_identity "$dir/b.part" 2>/dev/null)"
mozc_place "$cache" "" "$file" "https://$path" registry "$sha_a" "$id_a"
serve "$path" A >/dev/null
list "$sha_a	https://$path	registry"
prefetch "$cache" && got=$(cat "$file")
[[ ${got:-} == A ]] && result PASS interleaved || result FAIL interleaved "A's prefetch kept '${got:-}'"

# Two prefetches into one empty cache at once
cache=$dir/both
list "$(serve bcr.bazel.build/modules/a/1.0/MODULE.bazel a)	https://bcr.bazel.build/modules/a/1.0/MODULE.bazel	registry" \
  "$(serve github.com/x/a.tar.gz archive)	https://github.com/x/a.tar.gz	repos"
prefetch "$cache" 2> "$dir/one.err" & one=$!
prefetch "$cache" 2> "$dir/two.err" & two=$!
wait $one; a=$?; wait $two; b=$?
if [[ $a == 0 && $b == 0 && $(cat "$cache/registry/modules/a/1.0/MODULE.bazel") == a ]] &&
    ! compgen -G "$cache/registry/modules/a/1.0/*.part" >/dev/null; then result PASS concurrent
else result FAIL concurrent "exits $a $b: $(cat "$dir/one.err" "$dir/two.err" | head -1)"; fi

# Two versions of protobuf in the registry's copy, after an upgrade: the selected one's files
reg=$dir/registry
for v in 33.0 34.1; do
  mkdir -p "$reg/modules/protobuf/$v"
  echo "module(name = \"protobuf\", version = \"$v\")" > "$reg/modules/protobuf/$v/MODULE.bazel"
  echo "{\"url\": \"https://example.com/protobuf-$v.tar.gz\", \"integrity\": \"sha256-AAAA\"}" \
    > "$reg/modules/protobuf/$v/source.json"
done
graph='{"name": "mozc", "dependencies": [{"name": "protobuf", "version": "34.1"},
  {"name": "x", "version": "1", "dependencies": [{"name": "protobuf", "version": "34.1", "unexpanded": true}]}]}'
got=$(python3 -I tools/mozc-repo-urls.py "$reg" protobuf+ <<<"$graph" | head -1)
[[ $got == "https://example.com/protobuf-34.1.tar.gz repos 000000" ]] && result PASS selected-version ||
  result FAIL selected-version "$got"
exit $status
