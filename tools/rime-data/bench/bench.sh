#!/usr/bin/env bash
# Chinese accuracy benchmark (#40): types the six held-out sets in sets/ through librime with what the
# phone runs (Lua and octagram loaded) and gives top-1 / top-3 for each, for rime-ice as #8 bundled it
# and for SebType's data from tools/rime-data/build.sh. The two typo sets (#46, make-typos.py) are
# typed with the phone's and the PCs' keyboard model. Run it before changing the Chinese data and put
# the table in the PR. Takes about 7 minutes.
#   tools/rime-data/bench/bench.sh      table in /tmp/sebtype/rime-bench.md, ranks in /tmp/sebtype/rime-bench/
# Needs gcc, librime and librime-lua 1.16.1 (Fedora) and dnf (for librime-octagram, unpacked, not installed).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../../.."
. rime-android/versions.sh

out=/tmp/sebtype/rime-bench; mkdir -p "$out"
cache=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype
headers=$cache/librime-$LIBRIME_VERSION-headers
librime=/usr/lib64/librime.so.1 lua=/usr/lib64/rime-plugins/librime-lua.so
OLD_URL=https://github.com/iDvel/rime-ice/releases/download/2026.06.30/full_compiled.zip
OLD_SHA256=ae810e0023f28d3eb45ff98a7c58830dd0b505c2272638a321fa6d5a6f5d5418
OCTAGRAM_RPM=librime-octagram-$LIBRIME_VERSION-2.fc44.x86_64.rpm
OCTAGRAM_SHA256=cf11634cf4ecb1b3bfa41e22fecac644c6493ab1c14291893345ecd12ff09f13
SETS=(chat-sent chat-abbr chat-partial news-sent news-abbr news-partial typo-phone typo-pc)

for x in gcc dnf rpm2cpio cpio curl; do command -v $x >/dev/null || { echo "preflight: $x missing"; exit 1; }; done
[[ -f $librime && -f $lua ]] || { echo "preflight: needs librime and librime-lua $LIBRIME_VERSION installed"; exit 1; }
work=$(mktemp -d "$cache/rime-bench.XXXXXX")
trap 'rm -rf "$work"' EXIT

# SebType's data (also fetches librime's headers), rime-ice as bundled before, and the octagram plugin.
tools/rime-data/build.sh "$work/assets" > "$work/build.log" 2>&1 || { echo "preflight: tools/rime-data/build.sh failed, see below"; tail -3 "$work/build.log"; exit 1; }
old=$cache/rime-ice-2026.06.30-full_compiled.zip
if ! echo "$OLD_SHA256  $old" | sha256sum -c --status 2>/dev/null; then
  curl -fsSL -o "$old.part" "$OLD_URL" && echo "$OLD_SHA256  $old.part" | sha256sum -c --status && mv "$old.part" "$old" ||
    { echo "preflight: can't fetch rime-ice's full_compiled.zip"; exit 1; }
fi
rpm=$cache/$OCTAGRAM_RPM
if ! echo "$OCTAGRAM_SHA256  $rpm" | sha256sum -c --status 2>/dev/null; then
  (cd "$work" && dnf download -q "${OCTAGRAM_RPM%.rpm}" > /dev/null) && mv "$work/$OCTAGRAM_RPM" "$rpm" &&
    echo "$OCTAGRAM_SHA256  $rpm" | sha256sum -c --status || { echo "preflight: can't fetch $OCTAGRAM_RPM"; exit 1; }
fi
# Through a file: cpio stops reading at the archive trailer, which would SIGPIPE rpm2cpio under pipefail.
rpm2cpio "$rpm" > "$work/octagram.cpio" && (cd "$work" && cpio -id --quiet < octagram.cpio)
octagram=$(find "$work/usr" -name librime-octagram.so)
gcc -O2 -I"$headers" -o "$work/rimebench" "$here/rimebench.c" "$librime" -ldl

mkdir -p "$work/rime-ice" "$work/sebtype"
unzip -q "$old" -d "$work/rime-ice"
unzip -q "$work/assets/rime/rime-data.zip" -d "$work/sebtype"
# unzip restores mtimes only to 2 s, so Rime sees changed sources and rebuilds the schemas and prisms in
# the user dir (the app restores exact times: nothing is rebuilt there). One item first does that
# rebuild, so the speed row measures typing, not compiling.
# typo-pc has its own user dir with the PCs' setting (pc/linux/setup-ime.sh, pc/windows/setup-ime.ps1).
head -1 "$here/sets/${SETS[0]}.tsv" > "$work/prime.tsv"
for data in rime-ice sebtype; do
  mkdir -p "$work/user-$data-pc"
  printf 'patch:\n  sebtype_typo/keyboard: pc\n' > "$work/user-$data-pc/rime_ice.custom.yaml"
  for user in "$work/user-$data" "$work/user-$data-pc"; do
    "$work/rimebench" "$work/$data" "$user" rime_ice "$work/prime.tsv" "$lua" "$octagram" > /dev/null 2>&1
  done
done

echo "| Set | rime-ice (as bundled by #8) top-1 / top-3 | SebType (白霜 core + zh-moqi) top-1 / top-3 |" > "$out.md"
echo "|---|---|---|" >> "$out.md"
for set in "${SETS[@]}" mean speed; do
  row="| $set |"; [[ $set == mean ]] && row="| mean of the 6 clean sets |"
  for data in rime-ice sebtype; do
    if [[ $set == mean ]]; then
      row+=$(awk 'NR <= 6 {a += $1; b += $2} END {printf " **%.1f / %.1f** |", a / 6, b / 6}' "$out/$data.scores")
    elif [[ $set == speed ]]; then # per key on this PC (a phone is several times slower), and peak RSS
      row+=$(sed -n 's/.*key_p50_us=\([0-9]*\) key_p95_us=\([0-9]*\) rss_kb=\([0-9]*\)/\1 \2 \3/p' "$out/$data-chat-sent.log" |
        awk '{printf " key p50 %.1f ms, p95 %.1f ms, RSS %d MB |", $1 / 1000, $2 / 1000, $3 / 1024}')
    else
      [[ $set == "${SETS[0]}" ]] && : > "$out/$data.scores"
      # Its own fresh user dir: nothing is ever committed, so nothing is learned.
      user=$work/user-$data; [[ $set == typo-pc ]] && user+=-pc
      timeout 900 "$work/rimebench" "$work/$data" "$user" rime_ice "$here/sets/$set.tsv" "$lua" "$octagram" \
        > "$out/$data-$set.tsv" 2> "$out/$data-$set.log" || { echo "FAIL $data $set: see $out/$data-$set.log"; exit 1; }
      row+=$(awk -F'\t' '{n++; a += $1 == 0; b += $1 >= 0 && $1 < 3} END {printf "%.1f %.1f\n", 100 * a / n, 100 * b / n}' \
        "$out/$data-$set.tsv" | tee -a "$out/$data.scores" | awk '{printf " %.1f / %.1f |", $1, $2}')
    fi
  done
  echo "$row" >> "$out.md"
done
cat "$out.md"
