#!/usr/bin/env bash
# Checks SebType's English dictionary (#47): the dictionary codec, that the committed main_en.dict is what
# build.sh makes from the pinned sources, the #40 benchmark against FUTO's dictionary, and that the release
# APK ships it. One line per check in ~/scratch/sebtype/test-en-dict-results.txt; logs next to it.
# Exit 0 only if all pass. Typing on the emulator ("gi" -> GitHub, autocorrect) is checked by hand.
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh

out=$SCRATCH; mkdir -p "$out"
results=$out/test-en-dict-results.txt; : > "$results"
cache=$SCRATCH/cache
dict=android/app/src/main/res/raw/main_en.dict
sdk=$ANDROID_HOME
bt=$(ls -d "$sdk"/build-tools/* 2>/dev/null | tail -1)
# Benchmark text, as in the #40 study: OpenAssistant oasst1 prompts (Apache-2.0) and Wikipedia's
# machine-readable common misspellings (CC BY-SA 4.0) at a fixed revision.
CHAT_URL=https://huggingface.co/datasets/OpenAssistant/oasst1/resolve/main/2023-04-12_oasst_prompts.messages.jsonl.gz
CHAT_SHA256=621ccd86a6ef320ca4e24c137121bd4b39bcc7a0df839f0897fcc965ef2076ed
TYPOS_URL='https://en.wikipedia.org/w/index.php?title=Wikipedia:Lists_of_common_misspellings/For_machines&action=raw&oldid=1199637275'
TYPOS_SHA256=3b6a9290e5aaad968da7ec769a5174adb45247688ef7ae097fd2dd80237a3050

result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
check() { # name, command...; timeout T seconds (default 300)
  local name=$1; shift
  if timeout "${T:-300}" "$@" > "$out/test-en-dict-$name.log" 2>&1; then result PASS "$name"
  else result FAIL "$name" "see $out/test-en-dict-$name.log"; fi
}
fetch() { # url sha256 name -> cached path
  local f=$cache/$3
  echo "$2  $f" | sha256sum -c --status 2>/dev/null ||
    { curl -fsSL -A "SebType-test/1.0" -o "$f.part" "$1" && echo "$2  $f.part" | sha256sum -c --status && mv "$f.part" "$f"; } ||
    return 1
  echo "$f"
}

# Preflight
for c in python3 hunspell curl; do command -v $c >/dev/null || { echo "preflight: $c missing"; exit 1; }; done
[[ -f $dict ]] || { echo "preflight: $dict missing"; exit 1; }
mkdir -p "$cache"
# FUTO's dictionary, the one data/en-dict/build.sh starts from
futo=$(fetch https://gitlab.futo.org/keyboard/keyboard-large-resources/-/raw/d87d9dbdf3966bbe18413be375dab2f6c7bbdfdd/raw/main_en.dict c3e21185c056e82769a2bb1381ae6b0e799437bdab101379715c6baa0a3544d1 futo-main_en.dict) ||
  { echo "preflight: can't download FUTO's dictionary"; exit 1; }
chat=$(fetch "$CHAT_URL" "$CHAT_SHA256" oasst1-prompts.jsonl.gz) || { echo "preflight: can't download $CHAT_URL"; exit 1; }
typos=$(fetch "$TYPOS_URL" "$TYPOS_SHA256" misspellings-1199637275.txt) || { echo "preflight: can't download misspellings"; exit 1; }

check codec-roundtrip python3 -I -B -c "
import sys; sys.path.insert(0, 'data/en-dict'); import v202
d = open('$futo', 'rb').read(); a, w = v202.decode(d)
assert v202.encode(a, w) == d, 'FUTO main_en.dict does not re-encode to the same bytes'"

rebuilt=$out/test-en-dict-rebuilt.dict
check reproducible bash -c "data/en-dict/build.sh '$rebuilt' && cmp '$rebuilt' '$dict'"

# The study's numbers: FUTO 26.3 % top-1 after 2 letters; the new list 32.2 %, accepting 0.4 % of misspellings.
python3 -I -B data/en-dict/bench.py "$chat" "$typos" "$futo" "$dict" > "$out/test-en-dict-bench.txt" 2>&1
check benchmark python3 -I -B -c "
rows = [l.split() for l in open('$out/test-en-dict-bench.txt')][1:]
new = dict(zip(['cover', 'p2top1', 'p2top3', 'p3top1', 'p3top3', 'typos_ok'], map(float, rows[1][2:])))
print(open('$out/test-en-dict-bench.txt').read())
assert new['p2top1'] >= 31.5, new
assert new['typos_ok'] <= 0.6, new"
sed 's/^/  /' "$out/test-en-dict-bench.txt" >> "$results"

apk_check() {
  local apk path
  apk=$(android/build.sh release 2> "$out/test-en-dict-build.log" | tail -1)
  [[ -f $apk ]] || { echo "release build failed, see $out/test-en-dict-build.log"; return 1; }
  path=$("$bt/aapt2" dump resources "$apk" | grep -A2 'raw/main_en$' | awk '$1 == "()" {print $3}')
  echo "apk $apk, dictionary at $path, $(stat -c %s "$apk") bytes"
  unzip -Zl "$apk" "$path" | grep -q ' stor ' || { echo "dictionary is compressed"; return 1; }
  cmp <(unzip -p "$apk" "$path") "$dict"
}
export -f apk_check; export out bt dict
T=2400 check apk-ships-it bash -c apk_check

! grep -q '^FAIL' "$results"
