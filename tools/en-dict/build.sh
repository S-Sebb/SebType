#!/usr/bin/env bash
# Regenerates SebType's English dictionary, sebtype/res-stable/raw/main_en.dict, from pinned sources (#47):
# FUTO's words, wordfreq's frequencies and the frequent modern words SCOWL accepts (make_dict.py says how).
#
#   tools/en-dict/build.sh [OUTPUT_DICT]
#
# Also writes the word list as text, out/en_wordlist.combined.gz, to read or diff. Needs python3 and hunspell.
# Bumping a source: change its URL and sha256 here, rebuild, and run tools/en-dict/test.sh for the
# before/after benchmark. The stable APK ships this file instead of FUTO's (a res-stable override).
set -euo pipefail
cd "$(dirname "$0")/../.."

# FUTO's dictionary from the java/res-large submodule (at d87d9db, 2026-04-23: FUTO's 2014 list, acronyms removed).
FUTO_DICT=java/res-large/raw/main_en.dict
FUTO_DICT_SHA256=c3e21185c056e82769a2bb1381ae6b0e799437bdab101379715c6baa0a3544d1
# wordfreq 3.x "large" English list (frozen since 2021; data CC BY-SA 4.0), at tag v3.2.
WORDFREQ_URL=https://raw.githubusercontent.com/rspeer/wordfreq/42233e6c36ce792031bcccfa17cdd0cec9af5fa7/wordfreq/data/large_en.msgpack.gz
WORDFREQ_SHA256=dffae8066b78dce0a6667cf5f58e567054f902674667090a7ac8a8a44628b05c
# SCOWL's en_US-large hunspell dictionary, release 2026.02.25.
SCOWL_URL=https://github.com/en-wl/wordlist/releases/download/rel-2026.02.25/hunspell-en_US-large-2026.02.25.zip
SCOWL_SHA256=06ab5a2a12c29033f100988d3b0a5e53dcad40bf2473ccb78270619d1da99321

out=${1:-sebtype/res-stable/raw/main_en.dict}
cache=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype
mkdir -p "$cache" out "$(dirname "$out")"
command -v hunspell >/dev/null || { echo "build: hunspell missing" >&2; exit 1; }
echo "$FUTO_DICT_SHA256  $FUTO_DICT" | sha256sum -c --status ||
  { echo "build: $FUTO_DICT changed (submodule bump?): check it, then update FUTO_DICT_SHA256" >&2; exit 1; }

fetch() { # url sha256 -> prints cached path
  local f=$cache/$(basename "$1")
  if ! echo "$2  $f" | sha256sum -c --status 2>/dev/null; then
    curl -fsSL -o "$f.part" "$1"
    echo "$2  $f.part" | sha256sum -c --status || { echo "checksum mismatch: $1" >&2; exit 1; }
    mv "$f.part" "$f"
  fi
  echo "$f"
}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
wordfreq=$(fetch "$WORDFREQ_URL" "$WORDFREQ_SHA256")
unzip -q "$(fetch "$SCOWL_URL" "$SCOWL_SHA256")" -d "$stage"
python3 -I -B tools/en-dict/make_dict.py "$FUTO_DICT" "$wordfreq" "$stage" "$out" out/en_wordlist.combined.gz
echo "$out"
