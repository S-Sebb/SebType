#!/usr/bin/env bash
# Sets up the training environment and downloads the corpus sources (SOURCES.md) into the run's folder, on
# yanglab16. Safe to rerun: finished downloads are kept.
#
#   tools/english-lm/fetch.sh [RUN_DIR]     (default ~/scratch/SebType/236)
set -euo pipefail
run=${1:-$HOME/scratch/SebType/236}
cache=$HOME/scratch/SebType/cache
venv=$cache/english-lm-venv
export HF_HOME=$cache/hf UV_CACHE_DIR=$cache/uv

# Python packages: PyTorch and Hugging Face Transformers (training), sentencepiece (the tokenizer), pyarrow
# (the parquet sources), mwparserfromhell (Wikinews's wikitext), and below, gguf from llama.cpp (the export).
if [[ ! -x $venv/bin/python ]]; then
  uv venv -q --python 3.12 "$venv"
fi
uv pip install -q --python "$venv/bin/python" --index-strategy unsafe-best-match \
  --extra-index-url https://download.pytorch.org/whl/cu128 \
  -r "$(dirname "$0")/requirements.txt"

# llama.cpp (MIT) at a pinned commit: the GGUF converter, the quantizer and the library the loader links.
llama=$("$(dirname "$0")/../../engines/sebtype-lm/fetch-llama.sh")
uv pip install -q --python "$venv/bin/python" "$llama/gguf-py"

mkdir -p "$run/data/src"
cd "$run/data/src"
hf() { "$venv/bin/hf" download "$2" --repo-type dataset --revision "$3" --local-dir "$1" "${@:4}" >/dev/null; }
# Revisions pinned to the commits whose licence tags were checked (SOURCES.md).
hf wikipedia wikimedia/wikipedia b04c8d1ceb2f5cd4588862100d08de323dccfbaa --include '20231101.en/*' --include '20231101.simple/*' &
hf oasst2 OpenAssistant/oasst2 179dd21fc55192153d94adb0e0ce8f69e222bf75 --include '2023-11-05_oasst2_all.messages.jsonl.gz' &
hf oasst1 OpenAssistant/oasst1 fdf72ae0827c1cda404aff25b6603abec9e3399b --include '2023-04-12_oasst_prompts.messages.jsonl.gz' &
hf soda allenai/soda fdc848ab0183208ea7808206c91c724414d0a071 --include '*.parquet' &
hf dolly databricks/databricks-dolly-15k bdd27f4d94b9c1f951818a7da7fd7aeea5dbff1a --include '*.jsonl' &
# The NUS SMS Corpus from its authors' repository (its licence is on NUS's ScholarBank record, SOURCES.md).
[[ -s nus-sms/smsCorpus_en_2015.03.09_all.xml ]] ||
  { mkdir -p nus-sms && curl -sfo nus-sms/en.zip \
      https://raw.githubusercontent.com/kite1988/nus-sms-corpus/bf0a365170d324e61e4025edf363d400f1edd1a6/smsCorpus_en_xml_2015.03.09_all.zip &&
    unzip -oq nus-sms/en.zip -d nus-sms && rm nus-sms/en.zip; } &
[[ -s enwikinews-20261101.xml.bz2 ]] ||
  { curl -sfo wikinews.part https://dumps.wikimedia.org/enwikinews/20261101/enwikinews-20261101-pages-articles.xml.bz2 &&
    mv wikinews.part enwikinews-20261101.xml.bz2; } &
for job in $(jobs -p); do wait "$job"; done
du -sh "$run/data/src"/*
