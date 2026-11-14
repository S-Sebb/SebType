#!/usr/bin/env bash
# Builds a Chinese dictionary zip for stock FUTO Keyboard from a pinned rime-ice release.
#
#   tools/pack-rime-ice.sh [PERSONAL_DIR] [OUTPUT_ZIP]
#
# PERSONAL_DIR (optional) is a Rime user dir or a copy of one. Used from it, when present:
#   fcitx_import.dict.yaml                          imported into rime_ice.dict.yaml
#   rime_ice.userdb.txt or sync/*/rime_ice.userdb.txt
#                                                   learned words (Rime's text snapshot of
#                                                   rime_ice.userdb), packed as a static dict
# OUTPUT_ZIP defaults to out/rime-ice-futo.dict. Import it in FUTO under Languages > Chinese > Dictionary.
#
# Stock FUTO hard-codes the schema id luna_pinyin_simp, so rime-ice's schema ships under that id.
# Results of trying this zip: docs/experiments/rime-ice-zip.md.
set -euo pipefail

RIME_ICE_VERSION=2026.06.30
RIME_ICE_URL=https://github.com/iDvel/rime-ice/releases/download/$RIME_ICE_VERSION/full.zip
RIME_ICE_SHA256=675d23b070be00e1b800f9a6db033ef98f4493cd5b568ed8aa3b3541769c46ac
# FUTO's own Chinese zip, used only for the OpenCC tables (s2t etc.) that rime-ice expects librime to have.
ZIDIAN_URL=https://dl.keyboard.futo.org/zidian-v26.02.dict
ZIDIAN_SHA256=cd5f684b8c78991ff211f6f0169ce5186bca3d78346f479a2c406970206038e5
ZIP_FORMAT_VERSION=1

personal=${1:-}
out=$(realpath -m "${2:-$(dirname "$0")/../out/rime-ice-futo.dict}")
cache=$HOME/scratch/sebtype/cache
mkdir -p "$cache" "$(dirname "$out")"

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
unzip -q "$(fetch "$RIME_ICE_URL" "$RIME_ICE_SHA256")" -d "$stage"
unzip -q -n "$(fetch "$ZIDIAN_URL" "$ZIDIAN_SHA256")" 'opencc/*' -d "$stage"
rm -f "$stage"/{weasel,squirrel}.yaml "$stage/t9.schema.yaml"

sed 's/^\(  schema_id: \)rime_ice$/\1luna_pinyin_simp/' "$stage/rime_ice.schema.yaml" >"$stage/luna_pinyin_simp.schema.yaml"
grep -q 'schema_id: luna_pinyin_simp' "$stage/luna_pinyin_simp.schema.yaml"

# Only the schemas FUTO can select: full pinyin and the double pinyin ids both projects share.
python3 -I - "$stage/default.yaml" <<'EOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
new = "schema_list:\n" + "".join(f"  - schema: {x}\n" for x in
    ["luna_pinyin_simp", "double_pinyin", "double_pinyin_abc", "double_pinyin_mspy", "double_pinyin_flypy"])
s, n = re.subn(r"^schema_list:\n(?:[ #].*\n|\n)*", new + "\n", s, count=1, flags=re.M)
assert n == 1, "schema_list not found in default.yaml"
open(p, "w", encoding="utf-8").write(s)
EOF

imports=()
name="rime-ice $RIME_ICE_VERSION"
if [[ -n $personal ]]; then
  if [[ -f $personal/fcitx_import.dict.yaml ]]; then
    cp "$personal/fcitx_import.dict.yaml" "$stage/"
    imports+=(fcitx_import)
  fi
  userdb_txt=$(ls -t "$personal"/rime_ice.userdb.txt "$personal"/sync/*/rime_ice.userdb.txt 2>/dev/null | head -1 || true)
  if [[ -n $userdb_txt ]]; then
    # Snapshot lines: "<code> \t<word>\tc=<commits> d=... t=...". Words picked at least once, weight = commits.
    { printf -- '---\nname: pc_userdb\nversion: "%s"\nsort: by_weight\n...\n' "$(date -r "$userdb_txt" +%F)"
      awk -F'\t' '!/^#/ && NF >= 3 { sub(/ +$/, "", $1); c = $3; sub(/^c=/, "", c); sub(/ .*/, "", c)
                                     if (c + 0 >= 1) print $2 "\t" $1 "\t" c }' "$userdb_txt"
    } >"$stage/pc_userdb.dict.yaml"
    imports+=(pc_userdb)
  fi
  ((${#imports[@]})) || { echo "no personal files found in $personal" >&2; exit 1; }
  # The name decides whether FUTO re-extracts the zip, so it changes with the personal files.
  name+=" + personal $(cat "$stage"/{fcitx_import,pc_userdb}.dict.yaml 2>/dev/null | sha256sum | cut -c1-8)"
fi
for i in "${imports[@]}"; do
  sed -i "/^  - cn_dicts\/others /a\\  - $i" "$stage/rime_ice.dict.yaml"
  grep -q "^  - $i\$" "$stage/rime_ice.dict.yaml"
done

echo "$name" >"$stage/FUTOKeyboard_ChineseDictionary_Name"
echo "$ZIP_FORMAT_VERSION" >"$stage/FUTOKeyboard_ChineseDictionary_Version"
rm -f "$out"
(cd "$stage" && zip -qr -X "$out" .)
echo "$out ($name, $(du -h "$out" | cut -f1))"
