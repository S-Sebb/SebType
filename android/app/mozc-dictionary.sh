#!/usr/bin/env bash
# Puts Mozc's Japanese dictionary in OUTPUT_DIR as the raw resource builtin_mozc_data: the file for 日本語
# (raw-ja/) and an empty one for every other language, so the resource exists in each configuration. The file
# is Mozc's OSS dictionary data (BSD-3-Clause and its data's licences, ../../engines/mozc/LICENSE), as
# FUTO Keyboard's builds publish it; pinned by URL and sha256 and kept in the shared cache.
#
#   android/app/mozc-dictionary.sh OUTPUT_DIR
set -euo pipefail
out=${1:?usage: mozc-dictionary.sh OUTPUT_DIR}
url=https://dl.keyboard.futo.org/jisho-v25.10-non-gpl.dict
sha256=72868f27299cc91924425bab1f58ecd67a957b01bae7507c9bdb4687ae150627
dict=$HOME/scratch/SebType/cache/mozc-jisho-v25.10-non-gpl.dict
if ! echo "$sha256  $dict" | sha256sum -c --status 2>/dev/null; then
  mkdir -p "$(dirname "$dict")"
  curl -fsSL --limit-rate 35M -o "$dict.part" "$url"
  echo "$sha256  $dict.part" | sha256sum -c --status || { echo "mozc-dictionary: $url changed (sha256)" >&2; exit 1; }
  mv "$dict.part" "$dict"
fi
mkdir -p "$out/raw" "$out/raw-ja"
: > "$out/raw/builtin_mozc_data.dict"
cp "$dict" "$out/raw-ja/builtin_mozc_data.dict"
