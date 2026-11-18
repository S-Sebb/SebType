#!/usr/bin/env bash
# The files of a Hugging Face dataset at a pinned revision whose paths match a glob, into DIR/<path>, by curl
# capped at 35 MB/s (#365): hf download has no rate cap, and the lab's servers share one 1 Gbit/s port. A
# file already there at its listed size is kept, so a rerun fetches only what is missing.
#
#   tools/hf-fetch.sh PYTHON DIR REPO REVISION GLOB...     (PYTHON: one with huggingface_hub, for the list)
set -euo pipefail
py=$1 dir=$2 repo=$3 rev=$4
shift 4
"$py" -I - "$repo" "$rev" "$@" <<'EOF' |
import fnmatch, sys
from huggingface_hub import HfApi
repo, rev, globs = sys.argv[1], sys.argv[2], sys.argv[3:]
for f in HfApi().list_repo_tree(repo, revision=rev, repo_type="dataset", recursive=True):
    if hasattr(f, "size") and any(fnmatch.fnmatch(f.path, g) for g in globs):
        print(f.size, f.path)
EOF
while read -r size path; do
  f=$dir/$path
  [[ $(stat -c %s "$f" 2>/dev/null) == "$size" ]] && continue
  mkdir -p "$(dirname "$f")"
  curl --limit-rate 35M -fsSL --retry 3 -o "$f.part" "https://huggingface.co/datasets/$repo/resolve/$rev/$path"
  mv "$f.part" "$f"
done
