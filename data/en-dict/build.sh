#!/usr/bin/env bash
# Regenerates SebType's English dictionary from pinned sources (#47): a base word list, wordfreq's frequencies
# and the frequent modern words SCOWL accepts (make_dict.py says how).
#
#   data/en-dict/build.sh [OUTPUT_DICT]   today's app: FUTO's words (sebtype/res-stable/raw/main_en.dict)
#   data/en-dict/build.sh --aosp [OUTPUT_DICT]
#                                         the new keyboard (#244): AOSP's en_US words (data/en-dict/en_US.dict)
#
# Also writes the word list as text, out/en_wordlist.combined.gz, to read or diff. Needs python3 and hunspell.
# Bumping a source: change its URL and sha256 here, rebuild, and run data/en-dict/test.sh for the
# before/after benchmark. The stable APK ships FUTO's build instead of FUTO's own file (a res-stable
# override) until stage 6 of docs/plans/android-own-keyboard.md, which drops it.
set -euo pipefail
cd "$(dirname "$0")/../.."

# FUTO's dictionary from its keyboard-large-resources repo (at d87d9db, 2026-04-23: FUTO's 2014 list, acronyms removed).
FUTO_DICT_URL=https://gitlab.futo.org/keyboard/keyboard-large-resources/-/raw/d87d9dbdf3966bbe18413be375dab2f6c7bbdfdd/raw/main_en.dict
FUTO_DICT_SHA256=c3e21185c056e82769a2bb1381ae6b0e799437bdab101379715c6baa0a3544d1
# AOSP LatinIME's en_US word list (Apache-2.0), at the commit engines/latinime comes from. Gitiles serves
# it base64-encoded.
AOSP_LIST_URL='https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/127336e9f29d69607eab55982324b210279ae8c5/dictionaries/en_US_wordlist.combined.gz?format=TEXT'
AOSP_LIST_SHA256=0f78dd455b532be169a23f233227b811fabced4b5bd7fc9c40cc05839793bcbd
# wordfreq 3.x "large" English list (frozen since 2021; data CC BY-SA 4.0), at tag v3.2.
WORDFREQ_URL=https://raw.githubusercontent.com/rspeer/wordfreq/42233e6c36ce792031bcccfa17cdd0cec9af5fa7/wordfreq/data/large_en.msgpack.gz
WORDFREQ_SHA256=dffae8066b78dce0a6667cf5f58e567054f902674667090a7ac8a8a44628b05c
# SCOWL's en_US-large hunspell dictionary, release 2026.02.25.
SCOWL_URL=https://github.com/en-wl/wordlist/releases/download/rel-2026.02.25/hunspell-en_US-large-2026.02.25.zip
SCOWL_SHA256=06ab5a2a12c29033f100988d3b0a5e53dcad40bf2473ccb78270619d1da99321

aosp=
[[ ${1:-} == --aosp ]] && { aosp=1; shift; }
out=${1:-$([[ $aosp ]] && echo data/en-dict/en_US.dict || echo sebtype/res-stable/raw/main_en.dict)}
cache=$HOME/scratch/SebType/cache
mkdir -p "$cache" out "$(dirname "$out")"
command -v hunspell >/dev/null || { echo "build: hunspell missing" >&2; exit 1; }

fetch() { # url sha256 [name] [decode command] -> prints cached path
  local f=$cache/${3:-$(basename "$1")}
  if ! echo "$2  $f" | sha256sum -c --status 2>/dev/null; then
    curl -fsSL "$1" | ${4:-cat} > "$f.part"
    echo "$2  $f.part" | sha256sum -c --status || { echo "checksum mismatch: $1" >&2; exit 1; }
    mv "$f.part" "$f"
  fi
  echo "$f"
}

stage=$(mktemp -d "$cache/en-dict.XXXXXX")
trap 'rm -rf "$stage"' EXIT
if [[ $aosp ]]; then
  base=$(fetch "$AOSP_LIST_URL" "$AOSP_LIST_SHA256" aosp-127336e9f29d-en_US_wordlist.combined.gz "base64 -d")
  combined=out/en_US_wordlist.combined.gz
else
  base=$(fetch "$FUTO_DICT_URL" "$FUTO_DICT_SHA256")
  combined=out/en_wordlist.combined.gz
fi
wordfreq=$(fetch "$WORDFREQ_URL" "$WORDFREQ_SHA256")
unzip -q "$(fetch "$SCOWL_URL" "$SCOWL_SHA256")" -d "$stage"
python3 -I -B data/en-dict/make_dict.py "$base" "$wordfreq" "$stage" "$out" "$combined"
echo "$out"
