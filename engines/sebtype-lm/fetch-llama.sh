#!/usr/bin/env bash
# Fetches llama.cpp (MIT) at the pinned commit into SebType's scratch cache and prints its path. The loader
# (sebtype_lm.cpp), the harness and tools/english-lm's export build on it.
set -euo pipefail
URL=https://github.com/ggml-org/llama.cpp
COMMIT=b1b770d90d94cad9e9ea5b993bdbc383a522fb28  # tag v1.0.0
dir=$HOME/scratch/SebType/cache/llama.cpp-${COMMIT:0:12}
# The build container's user doesn't own the NAS cache, which git otherwise refuses to read.
if [[ $(git -c safe.directory="$dir" -C "$dir" rev-parse HEAD 2>/dev/null) != "$COMMIT" ]]; then
  rm -rf "$dir.part" && git init -q "$dir.part"
  git -C "$dir.part" fetch -q --depth 1 "$URL" "$COMMIT"
  git -C "$dir.part" checkout -q FETCH_HEAD
  rm -rf "$dir" && mv "$dir.part" "$dir"
fi
echo "$dir"
