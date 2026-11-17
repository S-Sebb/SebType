#!/usr/bin/env bash
# Regenerates the new keyboard's emoji list (#191 stage 4, android/next's assets/emoji/emoji.txt) from pinned
# Unicode sources: the emoji, their order, groups and skin tones from Unicode's emoji-test.txt, and their names
# and keywords in English, 中文 and 日本語 from Unicode CLDR's annotations (make.py says how). Both under the
# Unicode licence (see ../../NOTICE). Then the ASCII faces in ascii.txt (FUTO's, see
# ../../NOTICE). Bumping a source:
# change its URL and sha256 here and rebuild.
#
#   data/emoji/build.sh [OUTPUT]
set -euo pipefail
cd "$(dirname "$0")/../.."

EMOJI_TEST_URL=https://unicode.org/Public/emoji/16.0/emoji-test.txt
EMOJI_TEST_SHA256=24f0c534e86cf142e2496953e8f0e46a3e702392911eddcd29c6cced85139697
CLDR=https://raw.githubusercontent.com/unicode-org/cldr-json/46.0.0/cldr-json
declare -A SHA256=(
  [annotations-en]=2405d3f2e4c5812a4faf93d965630246269e0177ce907d863c7d6bb197e957c1
  [annotations-zh]=21ac6db8c956a7ffcf1953de8d927aba37c02c49962e432761f734b4a20bf6c9
  [annotations-ja]=74419d311241783d9324b1e34cee5f8c7e0bf36f72caf42b016e6345dccc17f1
  [derived-en]=603b94176ee294ba2454a0c85a2835082ff4812cbeb5bb4e3ea78664f28ba16d
  [derived-zh]=042622b79c070312e3927da78caee887a2be112144cb25a1e4e4c9804736c96b
  [derived-ja]=1da738fd3577f747f312e37230ca6a0c9a578b97fa12fbab6d3b061856361213
)

out=${1:-android/next/src/main/assets/emoji/emoji.txt}
cache=$HOME/scratch/SebType/cache/emoji-16.0
mkdir -p "$cache" "$(dirname "$out")"

fetch() { # url sha256 name -> prints cached path
  local f=$cache/$3
  if ! echo "$2  $f" | sha256sum -c --status 2>/dev/null; then
    curl -fsSL "$1" > "$f.part"
    echo "$2  $f.part" | sha256sum -c --status || { echo "build: $1 changed (sha256)" >&2; exit 1; }
    mv "$f.part" "$f"
  fi
  echo "$f"
}

args=("$(fetch "$EMOJI_TEST_URL" "$EMOJI_TEST_SHA256" emoji-test.txt)")
for lang in en zh ja; do
  args+=("$(fetch "$CLDR/cldr-annotations-full/annotations/$lang/annotations.json" "${SHA256[annotations-$lang]}" "annotations-$lang.json")")
  args+=("$(fetch "$CLDR/cldr-annotations-derived-full/annotationsDerived/$lang/annotations.json" "${SHA256[derived-$lang]}" "derived-$lang.json")")
done
python3 -I data/emoji/make.py "$out" "${args[@]}" data/emoji/ascii.txt
echo "$out"
