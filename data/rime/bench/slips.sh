#!/usr/bin/env bash
# The slip check (#478) and the word and learning checks (#482): types sets/slips.tsv (make-slips.py:
# common phrases with a dropped, doubled, swapped or neighbouring letter), sets/words.tsv (make-words.py:
# common words alone) and the clean sentence and partial-pinyin sets through librime with SebType's data
# and Lua, with the PCs' keyboard setting, and checks each against the floor measured when #478 (words:
# #482) was fixed, so that slips keep landing, common words keep their usual spelling and correctly typed
# input doesn't get worse or slower; then teaches sets/learn.tsv's phrases with each keyboard's setting.
# Also sets/split.tsv (#485): inputs that split two ways (jiangeshen: jian ge shen or jiang e shen), whose
# split shown in the preedit must have its first syllable's commonest character on the first two pages.
#   data/rime/bench/slips.sh     one line per check; ranks in ~/scratch/SebType/<issue>/slips/
# Needs gcc, librime and librime-lua 1.16.1 with SebType's librime-octagram (Fedora, as on nobara-pc).
# About a minute.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../../.."
source tools/lib.sh
out=$TASK_OUT/slips
headers=$PWD/engines/librime/src
librime=/usr/lib64/librime.so.1 plugins=/usr/lib64/rime-plugins
mkdir -p "$out" "$SCRATCH/cache"

for x in gcc unzip; do command -v $x >/dev/null || { echo "preflight: $x missing"; exit 1; }; done
[[ -f $librime && -f $plugins/librime-lua.so && -f $plugins/librime-octagram.so ]] ||
  { echo "preflight: needs librime with librime-lua and librime-octagram installed"; exit 1; }
work=$(mktemp -d "$SCRATCH/cache/slips.XXXXXX")
trap 'rm -rf "$work"' EXIT
data=$(timeout 600 data/rime/build.sh "$work/assets" 2> "$out/build.log") ||
  { echo "preflight: data/rime/build.sh failed, see $out/build.log"; exit 1; }
gcc -O2 -I"$headers" -o "$work/rimebench" "$here/rimebench.c" "$librime" -ldl 2> "$out/gcc.log" ||
  { echo "preflight: rimebench doesn't build, see $out/gcc.log"; exit 1; }
unzip -q "$data" -d "$work/data"
mkdir "$work/user"
printf 'patch:\n  sebtype_typo/keyboard: pc\n' > "$work/user/rime_ice.custom.yaml"
bench() { timeout 300 "$work/rimebench" "$work/data" "$work/user" rime_ice "$1" "$plugins/librime-lua.so" "$plugins/librime-octagram.so"; }
# The first run rebuilds the schemas in the user dir (unzip's mtimes), so the timed runs measure typing.
head -1 "$here/sets/slips.tsv" > "$work/prime.tsv"
bench "$work/prime.tsv" > /dev/null 2>&1

failed=0
check() { # set top1_floor page1_floor [p95_ceiling_us]; with DEPTH=n, among the first n instead of page 1
  local set=$1 r first="page 1"
  [[ -n ${DEPTH-} ]] && first="first $DEPTH"
  if ! bench "$here/sets/$set.tsv" > "$out/$set.tsv" 2> "$out/$set.log"; then
    echo "FAIL $set: rimebench failed, see $out/$set.log"; failed=1; return
  fi
  r=$(awk -F'\t' '{n++; a += $1 == 0; b += $1 >= 0} END {printf "%.1f %.1f", 100 * a / n, 100 * b / n}' "$out/$set.tsv")
  read -r top1 page1 <<< "$r"
  p95=$(sed -n 's/.*key_p95_us=\([0-9]*\).*/\1/p' "$out/$set.log")
  local line="$set: top-1 $top1 % (floor $2), $first $page1 % (floor $3), key p95 $((p95 / 1000)).$((p95 % 1000 / 100)) ms${4:+ (ceiling $(($4 / 1000)) ms)}"
  if awk -v a="$top1" -v b="$page1" -v x="$2" -v y="$3" -v t="$p95" -v c="${4:-0}" \
    'BEGIN { exit !(a >= x && b >= y && (c == 0 || t <= c)) }'; then echo "PASS $line"; else echo "FAIL $line"; failed=1; fi
}
# Floors: #478's measurements (news-sent, words: #482's) less 0.5 points (slips: before #478, 25.9 % top-1 and 33.2 % on page 1).
check slips 50.0 60.0
check chat-sent 59.7 61.4 5000
check news-sent 65.1 66.0 5000
check chat-partial 68.7 87.9
check news-partial 53.6 82.1
# Common words typed alone (#482, make-words.py): the spelling mainland text uses comes first, and the
# reported ones each come first.
check words 89.5 97.8
reported=$(paste "$out/words.tsv" <(cut -f3 "$here/sets/words.tsv") | awk -F'\t' '$6 == "reported" && $1 != 0 {print $2 " -> " $4}')
[[ -z $reported ]] && echo "PASS words: the reported words come first" || { echo "FAIL words: not first: $reported"; failed=1; }
DEPTH=10 check split 0 100  # the first two pages of 5; before #485, 33.7 %
# A phrase taught once by picking its pieces (#482, sets/learn.tsv) comes first the next time, and Rime
# marks it learned, so SebType's model keeps it first (#369); with each keyboard's setting, in a fresh
# user dir.
for kb in pc phone; do
  mkdir "$work/learn-$kb" && cp "$work/user/rime_ice.custom.yaml" "$work/learn-$kb/"
  [[ $kb == phone ]] && printf 'patch:\n  sebtype_typo/keyboard: phone\n' > "$work/learn-$kb/rime_ice.custom.yaml"
  timeout 300 "$work/rimebench" "$work/data" "$work/learn-$kb" rime_ice "$here/sets/learn.tsv" "$plugins/librime-lua.so" \
    "$plugins/librime-octagram.so" > "$out/learn-$kb.tsv" 2> "$out/learn-$kb.log"
  bad=$(paste "$out/learn-$kb.tsv" <(cut -f3 "$here/sets/learn.tsv") | awk -F'\t' '$6 ~ /^learn / && ($1 != 0 || $5 != $3) {print $2 " -> " $4 " (learned: " $5 ")"}')
  [[ -s $out/learn-$kb.tsv && -z $bad ]] && echo "PASS learn ($kb): taught phrases come first, marked learned" ||
    { echo "FAIL learn ($kb): ${bad:-rimebench failed, see $out/learn-$kb.log}"; failed=1; }
done
# What each kind of slip got, for the PR.
paste <(cut -f3 "$here/sets/slips.tsv") "$out/slips.tsv" | awk -F'\t' '{n[$1]++; t[$1] += $2 == 0; p[$1] += $2 >= 0}
  END {for (k in n) printf "  %s: %d of %d first, %d on page 1\n", k, t[k], n[k], p[k]}' | sort
exit $failed
