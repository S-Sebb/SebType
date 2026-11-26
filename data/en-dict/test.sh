#!/usr/bin/env bash
# Checks SebType's English dictionary (#47, #244): the dictionary codec, that the committed en_US.dict is what
# build.sh makes from the pinned sources, the #40 benchmark against AOSP's dictionary, and that the release
# APK ships it. One line per check in ~/scratch/SebType/<issue>/test-en-dict-results.txt; logs next to it.
# Exit 0 only if all pass. Typing on the emulator ("gi" -> GitHub, autocorrect) is checked by hand.
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/lib.sh
test_key || exit 1

out=$TASK_OUT; mkdir -p "$out"
results=$out/test-en-dict-results.txt; : > "$results"
cache=$SCRATCH/cache
dict=data/en-dict/en_US.dict
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
fetch() { # url sha256 name [decode command] -> cached path
  local f=$cache/$3
  echo "$2  $f" | sha256sum -c --status 2>/dev/null ||
    { curl -fsSL --limit-rate 35M -A "SebType-test/1.0" "$1" | ${4:-cat} > "$f.part" &&
      echo "$2  $f.part" | sha256sum -c --status && mv "$f.part" "$f"; } ||
    return 1
  echo "$f"
}

# Preflight
for c in python3 hunspell curl; do command -v $c >/dev/null || { echo "preflight: $c missing"; exit 1; }; done
[[ -f $dict ]] || { echo "preflight: $dict missing"; exit 1; }
mkdir -p "$cache"
# AOSP LatinIME's own English dictionary (Apache-2.0), at the commit build.sh's word list comes from
aosp=$(fetch 'https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/127336e9f29d69607eab55982324b210279ae8c5/java/res/raw/main_en.dict?format=TEXT' \
  581e0a428fff00d4ac574866596d6de9408bb76d1ce9626e34c887113713253f aosp-127336e9f29d-main_en.dict "base64 -d") ||
  { echo "preflight: can't download AOSP's dictionary"; exit 1; }
chat=$(fetch "$CHAT_URL" "$CHAT_SHA256" oasst1-prompts.jsonl.gz) || { echo "preflight: can't download $CHAT_URL"; exit 1; }
typos=$(fetch "$TYPOS_URL" "$TYPOS_SHA256" misspellings-1199637275.txt) || { echo "preflight: can't download misspellings"; exit 1; }

check codec-roundtrip python3 -I -B -c "
import sys; sys.path.insert(0, 'data/en-dict'); import v202
d = open('$aosp', 'rb').read(); a, w = v202.decode(d)
assert v202.encode(a, w) == d, 'AOSP main_en.dict does not re-encode to the same bytes'"

rebuilt=$out/test-en-dict-rebuilt.dict
check reproducible bash -c "data/en-dict/build.sh '$rebuilt' && cmp '$rebuilt' '$dict'"

# The study's numbers: the base dictionary 26.3 % top-1 after 2 letters (AOSP's scores the same); SebType's 32.2 %, accepting 0.4 % of misspellings.
python3 -I -B data/en-dict/bench.py "$chat" "$typos" "$aosp" "$dict" > "$out/test-en-dict-bench.txt" 2>&1
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
  path=assets/english/en_US.dict
  echo "apk $apk, $(stat -c %s "$apk") bytes"
  unzip -Zl "$apk" "$path" | grep -q ' stor ' || { echo "dictionary is compressed"; return 1; }
  cmp <(unzip -p "$apk" "$path") "$dict"
}
export -f apk_check; export out dict
T=2400 check apk-ships-it bash -c apk_check

! grep -q '^FAIL' "$results"
