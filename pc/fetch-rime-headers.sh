#!/usr/bin/env bash
# Fetches librime 1.16.1's public headers (pinned, checksummed) for the PC perf tools and prints their
# folder. Fedora ships them only in librime-devel; perf-rime.c needs nothing else to build.
set -euo pipefail
cache=${XDG_CACHE_HOME:-$HOME/.cache}/sebtype/librime-1.16.1-headers
mkdir -p "$cache"
while read -r sum f; do
  echo "$sum  $cache/$f" | sha256sum -c --status 2>/dev/null && continue
  curl -fsSL -o "$cache/$f" "https://raw.githubusercontent.com/rime/librime/1.16.1/src/$f" &&
    echo "$sum  $cache/$f" | sha256sum -c --status || { echo "can't fetch librime header $f" >&2; exit 1; }
done <<'LIST'
6eb5629162c44761e7b878f1b122f464de5c8685bd3cd5ac1e8519badc6d6424 rime_api.h
21625c4e16480a4540939299a002f21b11150bb10b69f5331e1580875ac63341 rime_api_deprecated.h
f5a64254e98c1c12ce6628f5d540bcd4e4b542ec287b4873c0b0ce4ed1bece99 rime_api_stdbool.h
LIST
echo "$cache"
