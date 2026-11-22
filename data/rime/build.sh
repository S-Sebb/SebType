#!/usr/bin/env bash
# Builds SebType's Chinese data and puts it into the APK's assets: rime-ice's schemas, Lua and settings
# with 白霜 (rime-frost) core's dictionary and its zh-moqi grammar, compiled here so the phone never
# compiles anything (Decisions #2: no Rime deploy on the phone). Gradle runs this before every build;
# the result is cached by its inputs, so only the first build after a change compiles (about 10 s).
#   data/rime/build.sh [ASSETS_DIR]   # default build/sebtype-assets; writes ASSETS_DIR/rime/
# Prints the zip's path in the cache (~/scratch/SebType/cache/rime-data-<key>.zip). Tests build it on
# yanglab16 with tools/build.sh.
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
# jieba's word frequencies (MIT), to order core's words by use and check which spellings mainland text uses
# (#482, usage_words.py).
JIEBA_COMMIT=67fa2e36e72f69d9134b8a1037b83fbb070b9775
JIEBA_URL=https://raw.githubusercontent.com/fxsjy/jieba/$JIEBA_COMMIT/jieba/dict.txt
JIEBA_SHA256=7197c3211ddd98962b036cdf40324d1ea2bfaa12bd028e68faa70111a88e12a8
# Full pinyin is SebType's only Chinese scheme (Decisions #2, Chinese menu, #117): rime-ice's 9-key and
# double-pinyin schemes are left out. melt_eng and radical_pinyin stay: rime_ice uses them.
# OpenCC's simplified → traditional conversion, which rime-ice's 简/繁 switch (traditionalization, #36)
# runs: its s2t config and the two dictionaries that config reads, compiled to OpenCC's binary format
# with the host's libopencc (the format is the same in every OpenCC since 1.0). And t2s, its way back, for
# SebType's Chinese model (core/src/chinese.cpp, #264): it reads simplified text, so with 繁 on it reads
# Rime's candidates and the field's text through t2s.
OPENCC_VERSION=1.1.9
OPENCC_URL=https://raw.githubusercontent.com/BYVoid/OpenCC/ver.$OPENCC_VERSION/data
OPENCC_S2T_SHA256=710bb970e406d9c0a3dd33c609248686cf1c5578d064b7b7fc89e70fbb9ea75d
OPENCC_PHRASES_SHA256=17fece21a28f3db2dc32397abd73d21ae73261c3f295fa6a3fe64b5e8d8b554b
OPENCC_CHARACTERS_SHA256=ed1d268e0ad028511dcf5b0089faed0a980ad332449ec11d481ceefde6879f41
OPENCC_T2S_SHA256=b818534194f27c2d95f01001edb0a5ec49b9050119892cb30a0504bb202cc07c
OPENCC_TS_PHRASES_SHA256=504169029c43f7f234b8e2ae470720af3657675c5574ff8aa0feb257e1dc5ce2
OPENCC_TS_CHARACTERS_SHA256=6b5a0a799bea2bb22c001f635eaa3fc2904310f0c08addbff275477a80ecf09a
# The tables are compiled with the host's librime, which must be engines/librime's version (the one the
# phone builds, android/native), so the phone takes the compiled files as they are.
LIBRIME_VERSION=$(sed -n 's/^set(rime_version \(.*\))$/\1/p' engines/librime/CMakeLists.txt)
headers=$PWD/engines/librime/src
# Bump to make every install reinstall the bundle, e.g. after changing how the app sets it up.
BUNDLE_REVISION=11

out=${1:-build/sebtype-assets}/rime
cache=$HOME/scratch/SebType/cache
librime=/usr/lib64/librime.so.1
libopencc=/usr/lib64/libopencc.so.1.1
mkdir -p "$cache" "$out"

key=$(cat "$here/build.sh" "$here/deploy.c" "$here/sebtype_typo.lua" "$here/sebtype_learned.lua" "$here/sebtype_split.lua" "$here/sebtype_ge.lua" "$here/usage_words.py" engines/librime/CMakeLists.txt "$headers"/rime_api{,_deprecated,_stdbool}.h | sha256sum | cut -c1-16)
zip=$cache/rime-data-$key.zip
version="rime-ice $RIME_ICE_VERSION + rime-frost $RIME_FROST_VERSION, sebtype $BUNDLE_REVISION"

fetch() { # url sha256 -> prints cached path
  local f=$cache/$2-$(basename "$1")
  if ! echo "$2  $f" | sha256sum -c --status 2>/dev/null; then
    curl --limit-rate 35M -fsSL -o "$f.part" "$1"
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
  unzip -q "$(fetch "$RIME_FROST_URL" "$RIME_FROST_SHA256")" rime_frost.dict.yaml zh-moqi.gram essay.txt 'cn_dicts/*' -d "$work/frost"

  # rime-ice's own dictionary gives way to 白霜 core's, under rime-ice's name: the schemas, Lua and the
  # learned words (rime_ice.userdb) all refer to it by that name.
  rm -rf "$s"/cn_dicts "$s"/{weasel,squirrel}.yaml "$s"/t9.schema.yaml "$s"/double_pinyin*.schema.yaml
  mkdir "$s/cn_dicts"
  for d in "${FROST_CORE[@]}"; do mv "$work/frost/cn_dicts/$d.dict.yaml" "$s/cn_dicts/"; done
  mv "$work/frost/zh-moqi.gram" "$s/"
  python3 -I "$here/usage_words.py" "$s" "$work/frost/essay.txt" "$(fetch "$OPENCC_URL/dictionary/TSPhrases.txt" "$OPENCC_TS_PHRASES_SHA256")" \
    "$(fetch "$OPENCC_URL/dictionary/TSCharacters.txt" "$OPENCC_TS_CHARACTERS_SHA256")" "$(fetch "$JIEBA_URL" "$JIEBA_SHA256")"
  cp "$here/sebtype_typo.lua" "$here/sebtype_learned.lua" "$here/sebtype_split.lua" "$here/sebtype_ge.lua" "$s/lua/"
  # rime-ice ships only its emoji table in opencc/; the 简/繁 switch needs OpenCC's s2t.
  printf '%s\n' '#include <string>' \
    'namespace opencc { void ConvertDictionary(const std::string &, const std::string &, const std::string &, const std::string &); }' \
    'int main(int, char **argv) { opencc::ConvertDictionary(argv[1], argv[2], "text", "ocd2"); }' > "$work/opencc-dict.cc"
  g++ -O2 -o "$work/opencc-dict" "$work/opencc-dict.cc" "$libopencc"
  cp "$(fetch "$OPENCC_URL/config/s2t.json" "$OPENCC_S2T_SHA256")" "$s/opencc/s2t.json"
  "$work/opencc-dict" "$(fetch "$OPENCC_URL/dictionary/STPhrases.txt" "$OPENCC_PHRASES_SHA256")" "$s/opencc/STPhrases.ocd2"
  "$work/opencc-dict" "$(fetch "$OPENCC_URL/dictionary/STCharacters.txt" "$OPENCC_CHARACTERS_SHA256")" "$s/opencc/STCharacters.ocd2"
  cp "$(fetch "$OPENCC_URL/config/t2s.json" "$OPENCC_T2S_SHA256")" "$s/opencc/t2s.json"
  "$work/opencc-dict" "$(fetch "$OPENCC_URL/dictionary/TSPhrases.txt" "$OPENCC_TS_PHRASES_SHA256")" "$s/opencc/TSPhrases.ocd2"
  "$work/opencc-dict" "$(fetch "$OPENCC_URL/dictionary/TSCharacters.txt" "$OPENCC_TS_CHARACTERS_SHA256")" "$s/opencc/TSCharacters.ocd2"
  python3 -I - "$work/frost/rime_frost.dict.yaml" "$s" "${FROST_CORE[*]}" <<'EOF'
import re, sys
frost, shared, core = sys.argv[1], sys.argv[2], sys.argv[3].split()

head, sep, body = open(frost, encoding="utf-8").read().partition("\n...\n")
head, n = re.subn(r"^name: rime_frost$", "name: rime_ice", head, flags=re.M)
assert n == 1, "name not found in rime_frost.dict.yaml"
imports = re.findall(r"^  - cn_dicts/(\w+)", head, re.M)
assert imports == core, f"白霜's core list changed: {imports}"
head = "\n".join(l for l in head.split("\n") if not l.startswith("  - cn_dicts_cell/"))
# The spellings 白霜 core leaves out (#482, usage_words.py).
head, n = re.subn(r"^(  - cn_dicts/corrections\b.*\n)", r"\1  - cn_dicts/sebtype_usage\n", head, flags=re.M)
assert n == 1, "corrections import not found in rime_frost.dict.yaml"
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
s, n = re.subn(r"^  filters:\n", lambda m: m.group(0) + "    - lua_filter@*sebtype_ge  # SebType: a word split by 个 (#484)\n"
               "    - lua_filter@*sebtype_typo  # SebType: typo corrections (#46)\n"
               "    - lua_filter@*sebtype_split  # SebType: the preedit's split first (#485)\n",
               s, count=1, flags=re.M)
assert n == 1, f"filters not found in {p}"
# SebType's Chinese model (#369): the last filter names a learned first candidate, after 繁 and the uniquifier.
s, n = re.subn(r"^(  filters:\n(?:    - .*\n)+)", lambda m: m.group(1) + "    - lua_filter@*sebtype_learned  # SebType: is the first a learned word (#369)\n",
               s, count=1, flags=re.M)
assert n == 1 and "    - uniquifier" in s, f"filters not found in {p}"
preedit = re.search(r"^  preedit_format:.*\n((?:    .*\n)+)", s, re.M)
assert preedit and "\ncorr:" not in s, p
s += f"""
# SebType: typo corrections (#46). Not among the translators: lua/sebtype_typo.lua asks it only when
# the best exact candidate looks like a typo.
corr:
  dictionary: rime_ice
  prism: sebtype_corr
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
  keyboard: phone
# SebType: whole dictionary words for lua/sebtype_ge.lua (#484), with rime_ice's prism
sebtype_word:
  dictionary: rime_ice
  enable_sentence: false
  enable_user_dict: false
  enable_completion: false
  enable_word_completion: false
  enable_correction: false
  contextual_suggestions: false  # pc on Linux and Windows (their setup scripts)
"""
# corr's prism (#478): rime_ice's spellings, and each syllable with one letter dropped (not its first: that
# slows every key for few slips), doubled or swapped, as fuzz spellings. librime corrects only slips onto a
# neighbouring key. A schema of its own, so the main translator's prism stays exact.
s, n = re.subn(r"^    - radical_pinyin .*\n", lambda m: m.group(0) + "    - sebtype_corr  # SebType: typo corrections (#478)\n",
               s, count=1, flags=re.M)
assert n == 1, f"dependencies not found in {p}"
open(p, "w", encoding="utf-8").write(s)
algebra = re.search(r"^  algebra:\n((?:    .*\n|\n)+)", s, re.M).group(1)
syllables = sorted({y for l in open(f"{shared}/cn_dicts/8105.dict.yaml", encoding="utf-8").read().partition("\n...\n")[2].split("\n")
                    if l.count("\t") >= 1 and not l.startswith("#") for y in l.split("\t")[1].split()})
assert 400 < len(syllables) < 450 and "yue" in syllables, f"{len(syllables)} syllables in 8105.dict.yaml"
def slips(y):
    out = {y[:i] + y[i + 1:] for i in range(1, len(y)) if len(y) > 2}
    out |= {y[:i] + y[i] + y[i:] for i in range(len(y))}
    out |= {y[:i] + y[i + 1] + y[i] + y[i + 2:] for i in range(len(y) - 1) if y[i] != y[i + 1]}
    return sorted(out - {y})
# The schema is also one SebType's Chinese model types into, in a session of its own, for corrections of
# input that reads as valid pinyin (core/src/chinese.cpp, #478): sentences over the slips, with 白霜's grammar.
with open(f"{shared}/sebtype_corr.schema.yaml", "w", encoding="utf-8") as f:
    f.write("# SebType: rime_ice's typo corrections (#478), built from rime_ice's speller\n"
            "schema:\n  schema_id: sebtype_corr\n  name: sebtype_corr\n  version: \"1\"\n"
            "engine:\n  processors:\n    - speller\n  segmentors:\n    - abc_segmentor\n  translators:\n    - script_translator\n"
            "  filters:\n    - uniquifier\n"
            "speller:\n  alphabet: zyxwvutsrqponmlkjihgfedcba\n  delimiter: \" '\"\n  algebra:\n" + algebra
            + "".join(f"    - fuzz/^{y}$/{t}/\n" for y in syllables for t in slips(y))
            + "translator:\n  dictionary: rime_ice\n  prism: sebtype_corr\n  enable_correction: true\n"
            "  enable_user_dict: false\n  enable_word_completion: false\n  contextual_suggestions: false\n"
            "grammar:\n  language: zh-moqi\n  non_collocation_penalty: -4\n")

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

  # Rime records its sources' modification times in the compiled files (the phone puts them back, see
  # RimeIceBundle), and unzip sets them in the local time zone: one fixed time makes the zip the same on
  # every machine (#229).
  stamp() { find "$s" -exec touch -h -d @1735689600 {} +; }
  stamp
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
  # sebtype_corr's sentences correct a slip that reads as valid pinyin (#478): yu for yue.
  "$work/deploy" "$s" "$work/phone" sebtype_corr yuelaiyuxiao > "$work/corr.out" 2> "$work/corr.log"
  grep -qx 'first=越来越小' "$work/corr.out" || { echo "rime-data: sebtype_corr doesn't correct: yuelaiyuxiao -> $(cat "$work/corr.out")" >&2; exit 1; }
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

Changes to rime-ice: its dictionary (cn_dicts/) is replaced by rime-frost's cn_dicts/ ${FROST_CORE[*]},
whose words sharing a pinyin are re-ordered by their counts in rime-frost's essay.txt and jieba's dict.txt
and their rime-frost weight (SebType's data/rime/usage_words.py), under the name rime_ice (rime_ice.dict.yaml is rime-frost's rime_frost.dict.yaml without its
cn_dicts_cell imports), plus cn_dicts/sebtype_usage: the words of rime-frost's essay.txt that its core
leaves out where mainland text uses them over the core's word for the same pinyin (SebType's
data/rime/usage_words.py, checked against jieba's dict.txt, MIT, https://github.com/fxsjy/jieba/tree/$JIEBA_COMMIT); the schema rime_ice gets rime-frost's zh-moqi grammar
(non_collocation_penalty -4, contextual_suggestions off); default.yaml lists only rime_ice, remembers
only the traditionalization switch, drops the Control+Shift+3 and 4 switch keys and has no switcher
hotkeys (F4, Control+grave, Control+Shift+grave); in rime_ice the
switches but traditionalization have no states, so menus don't show them;
weasel.yaml, squirrel.yaml, t9 and the double-pinyin schemas are left out. rime_ice.schema.yaml gets SebType's
typo correction: a second translator, corr, with librime's correction on and its own prism from
sebtype_corr.schema.yaml (SebType's: rime_ice's spellings and slips of them), ranked by
lua/sebtype_typo.lua (SebType's, GPL-3.0); its last filter, lua/sebtype_learned.lua (SebType's,
GPL-3.0), tells SebType's Chinese model when the first candidate is a learned word. lua/sebtype_ge.lua (SebType's,
GPL-3.0) puts first a dictionary word split by 个 (健个身 for jiangeshen) when the first candidate is a sentence,
looking words up through a third translator, sebtype_word. lua/sebtype_split.lua (SebType's, GPL-3.0)
moves candidates that split the input otherwise than the first one behind those that split it the same way. rime_ice's translator also reads the pack sebtype
(sebtype.dict.yaml, SebType's), which imports the user's own word list, sebtype_words.dict.yaml in
Rime's user folder, when there is one. The dictionary sources are compiled
into build/ with librime $LIBRIME_VERSION and not included here: they are at the source links above.

opencc/s2t.json, STPhrases.ocd2 and STCharacters.ocd2 are OpenCC $OPENCC_VERSION's (Apache License 2.0,
https://github.com/BYVoid/OpenCC/tree/ver.$OPENCC_VERSION/data): s2t.json as it is, the two dictionaries
compiled from their .txt sources to OpenCC's binary format.
EOF
  rm -f "$zip.part"
  stamp # and in a fixed order, with times stored as UTC (zip stores local time)
  (cd "$s" && find . -mindepth 1 | LC_ALL=C sort | TZ=UTC zip -q -X -9 "$zip.part" -@)
  mv "$zip.part" "$zip"
  echo "rime-data: built $zip ($(du -h "$zip" | cut -f1); compiled build/ $(du -sh "$s/build" | cut -f1))" >&2
fi

cmp -s "$zip" "$out/rime-data.zip" || cp "$zip" "$out/rime-data.zip"
rm -f "$out"/rime-ice.zip "$out"/rime-ice-SOURCE.txt # from before #40
echo "$version" > "$out/bundle-version"
echo "$zip"
