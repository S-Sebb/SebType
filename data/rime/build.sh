#!/usr/bin/env bash
# Builds SebType's Chinese data and puts it into the APK's assets: rime-ice's schemas, Lua and settings
# with 白霜 (rime-frost) core's dictionary and its zh-moqi grammar, compiled here so the phone never
# compiles anything (Decisions #2: no Rime deploy on the phone). Gradle runs this before every build;
# the result is cached by its inputs, so only the first build after a change compiles (about 10 s).
#   data/rime/build.sh [ASSETS_DIR]   # default build/sebtype-assets; writes ASSETS_DIR/rime/
#
# The zip is the Rime shared dir: rime-ice's files (minus the schemas other than full pinyin), 白霜's
# zh-moqi.gram, SebType's sebtype.dict.yaml (the pack that reads the user's own word list, #11) and
# build/ with the compiled tables. The dictionary sources aren't shipped: librime
# uses the prebuilt tables as they are when a table's source is missing, so it neither checksums nor
# rebuilds them. Both projects are GPL-3.0; the zip carries the licence and SOURCE.txt (pinned
# sources and what was changed). The same zip suits the PCs (Linux and Windows run librime 1.16.1 too).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../.."

RIME_ICE_VERSION=2026.06.30
RIME_ICE_COMMIT=6810e8916d160498620a16fef2135956fecbd485
RIME_ICE_URL=https://github.com/iDvel/rime-ice/releases/download/$RIME_ICE_VERSION/full.zip
RIME_ICE_SHA256=675d23b070be00e1b800f9a6db033ef98f4493cd5b568ed8aa3b3541769c46ac
RIME_FROST_VERSION=1.0.4
RIME_FROST_COMMIT=89ad92e450f9a5f4dcc2de67ba28004f9af0cc1e
RIME_FROST_URL=https://github.com/gaboolic/rime-frost/releases/download/$RIME_FROST_VERSION/rime-frost-schemas.zip
RIME_FROST_SHA256=4f4998ae83f63d757c0a4ace192f69d48265bddfabe231642b73e3739ed0f2f5
# 白霜 core: its rime_frost.dict.yaml without the cn_dicts_cell domain dictionaries (undocumented
# origin) or tencent (which 白霜 leaves out too).
FROST_CORE=(8105 41448 base ext others corrections)
# Full pinyin is SebType's only Chinese scheme (Decisions #2, Chinese menu, #117): rime-ice's 9-key and
# double-pinyin schemes are left out. melt_eng and radical_pinyin stay: rime_ice uses them.
# OpenCC's simplified → traditional conversion, which rime-ice's 简/繁 switch (traditionalization, #36)
# runs: its s2t config and the two dictionaries that config reads, compiled to OpenCC's binary format
# with the host's libopencc (the format is the same in every OpenCC since 1.0).
OPENCC_VERSION=1.1.9
OPENCC_URL=https://raw.githubusercontent.com/BYVoid/OpenCC/ver.$OPENCC_VERSION/data
OPENCC_S2T_SHA256=710bb970e406d9c0a3dd33c609248686cf1c5578d064b7b7fc89e70fbb9ea75d
OPENCC_PHRASES_SHA256=17fece21a28f3db2dc32397abd73d21ae73261c3f295fa6a3fe64b5e8d8b554b
OPENCC_CHARACTERS_SHA256=ed1d268e0ad028511dcf5b0089faed0a980ad332449ec11d481ceefde6879f41
# The tables are compiled with the host's librime, which must be engines/librime's version (the one the
# phone builds, android/rime), so the phone takes the compiled files as they are.
LIBRIME_VERSION=$(sed -n 's/^set(rime_version \(.*\))$/\1/p' engines/librime/CMakeLists.txt)
headers=$PWD/engines/librime/src
# Bump to make every install reinstall the bundle, e.g. after changing how the app sets it up.
BUNDLE_REVISION=6

out=${1:-build/sebtype-assets}/rime
cache=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype
librime=/usr/lib64/librime.so.1
libopencc=/usr/lib64/libopencc.so.1.1
mkdir -p "$cache" "$out"

key=$(cat "$here/build.sh" "$here/deploy.c" "$here/sebtype_typo.lua" engines/librime/CMakeLists.txt "$headers"/rime_api{,_deprecated,_stdbool}.h | sha256sum | cut -c1-16)
zip=$cache/rime-data-$key.zip
version="rime-ice $RIME_ICE_VERSION + rime-frost $RIME_FROST_VERSION, sebtype $BUNDLE_REVISION"

fetch() { # url sha256 -> prints cached path
  local f=$cache/$2-$(basename "$1")
  if ! echo "$2  $f" | sha256sum -c --status 2>/dev/null; then
    curl -fsSL -o "$f.part" "$1"
    echo "$2  $f.part" | sha256sum -c --status || { echo "rime-data: checksum mismatch for $1" >&2; exit 1; }
    mv "$f.part" "$f"
  fi
  echo "$f"
}

if [[ ! -f $zip ]]; then
  [[ -f $librime && -f $libopencc ]] && command -v gcc g++ >/dev/null ||
    { echo "rime-data: needs gcc, g++, librime $LIBRIME_VERSION ($librime) and OpenCC ($libopencc) to compile the tables" >&2; exit 1; }
  work=$(mktemp -d "$cache/rime-data.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  gcc -O2 -I"$headers" -o "$work/deploy" "$here/deploy.c" "$librime"
  s=$work/shared
  mkdir -p "$s" "$work/frost"
  unzip -q "$(fetch "$RIME_ICE_URL" "$RIME_ICE_SHA256")" -d "$s"
  unzip -q "$(fetch "$RIME_FROST_URL" "$RIME_FROST_SHA256")" rime_frost.dict.yaml zh-moqi.gram 'cn_dicts/*' -d "$work/frost"

  # rime-ice's own dictionary gives way to 白霜 core's, under rime-ice's name: the schemas, Lua and the
  # learned words (rime_ice.userdb) all refer to it by that name.
  rm -rf "$s"/cn_dicts "$s"/{weasel,squirrel}.yaml "$s"/t9.schema.yaml "$s"/double_pinyin*.schema.yaml
  mkdir "$s/cn_dicts"
  for d in "${FROST_CORE[@]}"; do mv "$work/frost/cn_dicts/$d.dict.yaml" "$s/cn_dicts/"; done
  mv "$work/frost/zh-moqi.gram" "$s/"
  cp "$here/sebtype_typo.lua" "$s/lua/"
  # rime-ice ships only its emoji table in opencc/; the 简/繁 switch needs OpenCC's s2t.
  printf '%s\n' '#include <string>' \
    'namespace opencc { void ConvertDictionary(const std::string &, const std::string &, const std::string &, const std::string &); }' \
    'int main(int, char **argv) { opencc::ConvertDictionary(argv[1], argv[2], "text", "ocd2"); }' > "$work/opencc-dict.cc"
  g++ -O2 -o "$work/opencc-dict" "$work/opencc-dict.cc" "$libopencc"
  cp "$(fetch "$OPENCC_URL/config/s2t.json" "$OPENCC_S2T_SHA256")" "$s/opencc/s2t.json"
  "$work/opencc-dict" "$(fetch "$OPENCC_URL/dictionary/STPhrases.txt" "$OPENCC_PHRASES_SHA256")" "$s/opencc/STPhrases.ocd2"
  "$work/opencc-dict" "$(fetch "$OPENCC_URL/dictionary/STCharacters.txt" "$OPENCC_CHARACTERS_SHA256")" "$s/opencc/STCharacters.ocd2"
  python3 -I - "$work/frost/rime_frost.dict.yaml" "$s" "${FROST_CORE[*]}" <<'EOF'
import re, sys
frost, shared, core = sys.argv[1], sys.argv[2], sys.argv[3].split()

head, sep, body = open(frost, encoding="utf-8").read().partition("\n...\n")
head, n = re.subn(r"^name: rime_frost$", "name: rime_ice", head, flags=re.M)
assert n == 1, "name not found in rime_frost.dict.yaml"
imports = re.findall(r"^  - cn_dicts/(\w+)", head, re.M)
assert imports == core, f"白霜's core list changed: {imports}"
head = "\n".join(l for l in head.split("\n") if not l.startswith("  - cn_dicts_cell/"))
open(f"{shared}/rime_ice.dict.yaml", "w", encoding="utf-8").write(head + sep + body)

p = f"{shared}/rime_ice.schema.yaml"
s = open(p, encoding="utf-8").read()
# 白霜's grammar with the penalty the #40 study measured; contextual suggestions stay off, as in 白霜.
# Plain keys, not a root __patch: that would turn off librime's automatic <schema>.custom.yaml patch.
assert "\ngrammar:" not in s and "contextual_suggestions" not in s, p
s, n = re.subn(r"^translator:\n", "translator:\n  contextual_suggestions: false  # SebType: as in 白霜\n"
               "  packs: [sebtype]  # SebType: the user's own word list (sebtype.dict.yaml, #11)\n",
               s, count=1, flags=re.M)
assert n == 1, f"no translator in {p}"
s += ("\n# SebType: 白霜 (rime-frost)'s zh-moqi grammar\ngrammar:\n  language: zh-moqi\n"
      "  non_collocation_penalty: -4\n")

# One switch in the menus, 简 → 繁 (Decisions #2, Chinese menu, #117): the other switches lose their
# states, which is what hides a switch in every Rime menu (Fcitx5's and Weasel's),
# and keep their place (the Configurator patches them by index) and their reset: Chinese punctuation,
# emoji on, half-width, normal words. ascii_mode stays a switch: the Shift tap is its key.
switches = re.search(r"^switches:\n((?:  .*\n)+)", s, re.M)
names = re.findall(r"^  - name: (\w+)", switches.group(1), re.M)
assert names == ["ascii_mode", "ascii_punct", "traditionalization", "emoji", "full_shape", "search_single_char"], names
fixed = re.sub(r"^(  - name: (?:ascii_mode|ascii_punct|emoji|full_shape|search_single_char)\b.*\n)(?:    (?:states|abbrev):.*\n)+",
               r"\1", switches.group(1), flags=re.M)
s = s[:switches.start(1)] + fixed + s[switches.end(1):]

# Typo correction (#46): librime's correction in a second translator over the same dictionary, asked
# and ranked by sebtype_typo.lua. The main translator stays exact; without its own user dictionary the
# second one neither learns twice nor shows learned words corrected. Its comments carry the corrected
# spelling for the filter.
s, n = re.subn(r"^  filters:\n", lambda m: m.group(0) + "    - lua_filter@*sebtype_typo  # SebType: typo corrections (#46)\n",
               s, count=1, flags=re.M)
assert n == 1, f"filters not found in {p}"
preedit = re.search(r"^  preedit_format:.*\n((?:    .*\n)+)", s, re.M)
assert preedit and "\ncorr:" not in s, p
s += f"""
# SebType: typo corrections (#46). Not among the translators: lua/sebtype_typo.lua asks it only when
# the best exact candidate looks like a typo.
corr:
  dictionary: rime_ice
  enable_correction: true
  enable_sentence: false
  enable_user_dict: false
  enable_word_completion: false
  contextual_suggestions: false
  spelling_hints: 100
  always_show_comments: true
  comment_format:
    - xform/^/［/
    - xform/$/］/
  preedit_format:
{preedit.group(1)}sebtype_typo:
  keyboard: phone  # pc on Linux and Windows (their setup scripts)
"""
open(p, "w", encoding="utf-8").write(s)

p = f"{shared}/default.yaml"
s = open(p, encoding="utf-8").read()
s, n = re.subn(r"^schema_list:\n(?:[ #].*\n|\n)*", "schema_list:\n  - schema: rime_ice\n\n", s, count=1, flags=re.M)
assert n == 1, "schema_list not found in default.yaml"
# The menu remembers only 简/繁, so a value saved before #117 can't keep a switch the menu no longer has.
s, n = re.subn(r"^  save_options:\n(?:    .*\n)+", "  save_options:\n    - traditionalization\n", s, count=1, flags=re.M)
assert n == 1, "switcher/save_options not found in default.yaml"
# 简/繁's only key is Ctrl+Shift+F (#36, the PCs' setup); rime-ice's Ctrl+Shift+3 (punctuation) and
# Ctrl+Shift+4 (简/繁) go with the fixed switches.
s, n = re.subn(r"^    - \{ when: always, toggle: (?:ascii_punct|traditionalization), accept: Control\+Shift\+.*\n", "", s, flags=re.M)
assert n == 4, f"{n} of rime-ice's 4 Ctrl+Shift switch keys found in default.yaml"
# No key opens Rime's switcher (Decisions #2, #182): F4, Ctrl+` and Ctrl+Shift+` reach the app. The
# menus (Fcitx5's and Weasel's) still offer the schema and 简/繁.
s, n = re.subn(r"^  hotkeys:\n(?:    .*\n)+", "  hotkeys: []\n", s, count=1, flags=re.M)
assert n == 1 and "F4" not in s, "switcher/hotkeys not found in default.yaml"
open(p, "w", encoding="utf-8").write(s)
EOF

  # The user's own word list (#11), the same file on the phone and both PCs: rime_ice's translator
  # reads it as a pack, a small extra table compiled against the prebuilt dictionary's syllables, so
  # adding one compiles only that table. Without the list Rime logs that it is missing and goes on.
  cat > "$s/sebtype.dict.yaml" <<'EOF'
# SebType's dictionary pack (#11): imports the user's word list, sebtype_words.dict.yaml in Rime's
# user folder (any Rime word list, renamed). An entry without a weight comes after the dictionary's
# words for the same code; a large weight (third column) puts it first.
---
name: sebtype
version: "1"
sort: by_weight
import_tables:
  - sebtype_words
...
EOF

  # Compile, as the keyboard's own first deploy would; then the tables go into the shared dir's build/.
  "$work/deploy" "$s" "$work/user" rime_ice ranh > "$work/deploy.out" 2> "$work/deploy.log" ||
    { tail -5 "$work/deploy.log" >&2; exit 1; }
  grep -qx "librime=$LIBRIME_VERSION" "$work/deploy.out" ||
    { echo "rime-data: $librime is $(head -1 "$work/deploy.out"), not librime $LIBRIME_VERSION" >&2; exit 1; }
  grep -qx "first=然后" "$work/deploy.out" ||
    { grep '^E' "$work/deploy.log" | head -5 >&2; echo "rime-data: self-test ranh -> $(tail -1 "$work/deploy.out")" >&2; exit 1; }
  mv "$work/user/build" "$s/build"
  rm -f "$s"/build/*.txt # dumps, not read by Rime
  # Dictionary sources: compiled into build/, so not shipped (their source is linked in SOURCE.txt).
  rm -rf "$s"/cn_dicts "$s"/rime_ice.dict.yaml "$s"/radical_pinyin.dict.yaml "$s"/melt_eng.dict.yaml "$s"/en_dicts/*.dict.yaml

  # What the phone does: a deploy on a fresh user dir must find everything compiled already.
  "$work/deploy" "$s" "$work/phone" rime_ice ranh > "$work/phone.out" 2> "$work/phone.log"
  grep -qx 'first=然后' "$work/phone.out" || { echo "rime-data: shipped data fails ranh: $(cat "$work/phone.out")" >&2; exit 1; }
  rebuilt=$(cd "$work/phone/build" && ls | grep -v '\.yaml$' || true) # compiled tables, prisms or reverse dbs
  [[ -z $rebuilt ]] || { echo "rime-data: a deploy on the shipped data rebuilt: $rebuilt" >&2; exit 1; }
  # A user's word list (made up) in the user folder: its word comes first, and only its pack is compiled.
  mkdir "$work/words"
  printf '%s\n' '# made-up test word' '---' 'name: any_name' 'version: "1"' '...' '翀嬿琰	chong yan yan	1000' \
    > "$work/words/sebtype_words.dict.yaml"
  "$work/deploy" "$s" "$work/words" rime_ice chongyanyan > "$work/words.out" 2> "$work/words.log"
  grep -qx 'first=翀嬿琰' "$work/words.out" || { echo "rime-data: the user's word list isn't offered: chongyanyan -> $(cat "$work/words.out")" >&2; exit 1; }
  rebuilt=$(cd "$work/words/build" && ls | grep -v '\.yaml$' || true)
  [[ $rebuilt == sebtype.table.bin ]] || { echo "rime-data: a word list compiled more than its pack: $rebuilt" >&2; exit 1; }
  # The 简/繁 switch on: traditional output from the shipped OpenCC data.
  "$work/deploy" "$s" "$work/hant" rime_ice houlai traditionalization > "$work/hant.out" 2> "$work/hant.log"
  grep -qx 'first=後來' "$work/hant.out" || { echo "rime-data: 繁 doesn't convert: houlai -> $(cat "$work/hant.out")" >&2; exit 1; }
  # F4 and Ctrl+` don't open Rime's switcher (#182): Rime leaves both keys to the app.
  for k in F4 '^`'; do
    "$work/deploy" "$s" "$work/phone" rime_ice "$k" > "$work/switcher.out" 2> "$work/switcher.log"
    grep -qx 'handled=0' "$work/switcher.out" || { echo "rime-data: $k opens Rime's switcher: $(cat "$work/switcher.out")" >&2; exit 1; }
  done
  # The app's settings patch (here fuzzy z = zh, as RimeIceSetup writes it) still applies without the sources.
  mkdir "$work/fuzzy"
  printf 'patch:\n    speller/algebra/+:\n        - derive/^z/zh/\n        - derive/^zh/z/\n' > "$work/fuzzy/rime_ice.custom.yaml"
  "$work/deploy" "$s" "$work/fuzzy" rime_ice zongguo > "$work/fuzzy.out" 2> "$work/fuzzy.log"
  grep -qx 'first=中国' "$work/fuzzy.out" || { echo "rime-data: the settings patch doesn't apply: zongguo -> $(cat "$work/fuzzy.out")" >&2; exit 1; }

  cat > "$s/SOURCE.txt" <<EOF
SebType's Chinese data: rime-ice (雾凇拼音) $RIME_ICE_VERSION with the core dictionary and the zh-moqi
grammar of rime-frost (白霜拼音) $RIME_FROST_VERSION. Both are licensed under the GNU GPL version 3, the
LICENSE file next to this one. Built by data/rime/build.sh in https://github.com/S-Sebb/SebType
(sebtype $BUNDLE_REVISION) from these release assets:
  $RIME_ICE_URL (sha256 $RIME_ICE_SHA256)
    source: https://github.com/iDvel/rime-ice/tree/$RIME_ICE_COMMIT
  $RIME_FROST_URL (sha256 $RIME_FROST_SHA256)
    source: https://github.com/gaboolic/rime-frost/tree/$RIME_FROST_COMMIT

Changes to rime-ice: its dictionary (cn_dicts/) is replaced by rime-frost's cn_dicts/ ${FROST_CORE[*]}
under the name rime_ice (rime_ice.dict.yaml is rime-frost's rime_frost.dict.yaml without its
cn_dicts_cell imports); the schema rime_ice gets rime-frost's zh-moqi grammar
(non_collocation_penalty -4, contextual_suggestions off); default.yaml lists only rime_ice, remembers
only the traditionalization switch, drops the Control+Shift+3 and 4 switch keys and has no switcher
hotkeys (F4, Control+grave, Control+Shift+grave); in rime_ice the
switches but traditionalization have no states, so menus don't show them;
weasel.yaml, squirrel.yaml, t9 and the double-pinyin schemas are left out. rime_ice.schema.yaml gets SebType's
typo correction: a second translator, corr, with librime's correction on, ranked by
lua/sebtype_typo.lua (SebType's, GPL-3.0). rime_ice's translator also reads the pack sebtype
(sebtype.dict.yaml, SebType's), which imports the user's own word list, sebtype_words.dict.yaml in
Rime's user folder, when there is one. The dictionary sources are compiled
into build/ with librime $LIBRIME_VERSION and not included here: they are at the source links above.

opencc/s2t.json, STPhrases.ocd2 and STCharacters.ocd2 are OpenCC $OPENCC_VERSION's (Apache License 2.0,
https://github.com/BYVoid/OpenCC/tree/ver.$OPENCC_VERSION/data): s2t.json as it is, the two dictionaries
compiled from their .txt sources to OpenCC's binary format.
EOF
  rm -f "$zip.part"
  (cd "$s" && zip -qr -X -9 "$zip.part" .)
  mv "$zip.part" "$zip"
  echo "rime-data: built $zip ($(du -h "$zip" | cut -f1); compiled build/ $(du -sh "$s/build" | cut -f1))" >&2
fi

cmp -s "$zip" "$out/rime-data.zip" || cp "$zip" "$out/rime-data.zip"
rm -f "$out"/rime-ice.zip "$out"/rime-ice-SOURCE.txt # from before #40
echo "$version" > "$out/bundle-version"
