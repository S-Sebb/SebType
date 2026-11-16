#!/usr/bin/env bash
# Sets up the training environment and downloads the corpus sources (SOURCES.md) into the run's folder, on
# yanglab16. Safe to rerun: finished downloads are kept.
#
#   tools/chinese-lm/fetch.sh [RUN_DIR]     (default ~/scratch/SebType/259)
set -euo pipefail
run=${1:-$HOME/scratch/SebType/259}
cache=$HOME/scratch/SebType/cache
venv=$cache/chinese-lm-venv
export HF_HOME=$cache/hf UV_CACHE_DIR=$cache/uv

# PyTorch and Transformers (training), sentencepiece (the tokenizer), pyarrow (Wikipedia's parquet),
# mwparserfromhell (Wikinews's wikitext), pypinyin (the pinyin typed for the text), OpenCC's tables in pure
# Python (繁 → 简), and gguf from llama.cpp (the export).
[[ -x $venv/bin/python ]] || uv venv -q --python 3.12 "$venv"
uv pip install -q --python "$venv/bin/python" --index-strategy unsafe-best-match \
  --extra-index-url https://download.pytorch.org/whl/cu128 -r "$(dirname "$0")/requirements.txt"
llama=$("$(dirname "$0")/../../engines/sebtype-lm/fetch-llama.sh")
uv pip install -q --python "$venv/bin/python" "$llama/gguf-py"

mkdir -p "$run/data/src"
cd "$run/data/src"
hf() { "$venv/bin/hf" download "$2" --repo-type dataset --revision "$3" --local-dir "$1" "${@:4}" >/dev/null; }
# Revisions pinned to the commits whose licence tags were checked (SOURCES.md).
hf wikipedia wikimedia/wikipedia b04c8d1ceb2f5cd4588862100d08de323dccfbaa --include '20231101.zh/*' &
hf lccc silver/lccc 5bd582fa28cd7143f2f9c852e08e23089d677c44 \
  --include lccc_base_train.jsonl.gz --include lccc_base_valid.jsonl.gz --include lccc_base_test.jsonl.gz &
hf oasst2 OpenAssistant/oasst2 179dd21fc55192153d94adb0e0ce8f69e222bf75 --include '2023-11-05_oasst2_all.messages.jsonl.gz' &
[[ -s zhwikinews-20261101.xml.bz2 ]] ||
  { curl -sfo zhwikinews.part https://dumps.wikimedia.org/zhwikinews/20261101/zhwikinews-20261101-pages-articles.xml.bz2 &&
    mv zhwikinews.part zhwikinews-20261101.xml.bz2; } &
for job in $(jobs -p); do wait "$job"; done
du -sh "$run/data/src"/*
