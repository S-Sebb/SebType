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

# One download at a time, each capped (tools/hf-fetch.sh): together they would fill the lab's shared port.
hf_fetch=$(realpath "$(dirname "$0")/../hf-fetch.sh")
hf() { "$hf_fetch" "$venv/bin/python" "$@"; }
mkdir -p "$run/data/src"
cd "$run/data/src"
# Revisions pinned to the commits whose licence tags were checked (SOURCES.md).
hf wikipedia wikimedia/wikipedia b04c8d1ceb2f5cd4588862100d08de323dccfbaa '20231101.en/*' '20231101.simple/*'
hf oasst2 OpenAssistant/oasst2 179dd21fc55192153d94adb0e0ce8f69e222bf75 '2023-11-05_oasst2_all.messages.jsonl.gz'
hf oasst1 OpenAssistant/oasst1 fdf72ae0827c1cda404aff25b6603abec9e3399b '2023-04-12_oasst_prompts.messages.jsonl.gz'
hf soda allenai/soda fdc848ab0183208ea7808206c91c724414d0a071 '*.parquet'
hf dolly databricks/databricks-dolly-15k bdd27f4d94b9c1f951818a7da7fd7aeea5dbff1a '*.jsonl'
# The NUS SMS Corpus from its authors' repository (its licence is on NUS's ScholarBank record, SOURCES.md).
[[ -s nus-sms/smsCorpus_en_2015.03.09_all.xml ]] ||
  { mkdir -p nus-sms && curl --limit-rate 35M -sfo nus-sms/en.zip \
      https://raw.githubusercontent.com/kite1988/nus-sms-corpus/bf0a365170d324e61e4025edf363d400f1edd1a6/smsCorpus_en_xml_2015.03.09_all.zip &&
    unzip -oq nus-sms/en.zip -d nus-sms && rm nus-sms/en.zip; }
# Blended Skill Talk as Hugging Face's parquet copy of ParlAI's release (its licence is in ParlAI, SOURCES.md).
hf bst ParlAI/blended_skill_talk d7b0093243439fa5f0cd9663125cc47575ced2ea 'data/*.parquet'
[[ -s topical-chat/train.json ]] ||
  { mkdir -p topical-chat && for f in train valid_freq valid_rare test_freq test_rare; do
      curl --limit-rate 35M -sfo topical-chat/$f.json \
        https://raw.githubusercontent.com/alexa/Topical-Chat/7c939229cbcf6f55f6977b341a5a2f2fe982d53f/conversations/$f.json || exit 1
    done; }
# Tatoeba replaces its export every week and keeps no old ones: the checked export is kept in the cache.
tatoeba=$cache/english-lm/tatoeba-eng_sentences-20261114.tsv.bz2
[[ -s $tatoeba ]] ||
  { curl --limit-rate 35M -sfo "$tatoeba.part" https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2 &&
    echo "3b5b3ecfcac5037b09f81ef048fa16fedc4d24838db5b6fbeedca1dfab374cbf  $tatoeba.part" | sha256sum -c --status && mv "$tatoeba.part" "$tatoeba" ||
    { echo "fetch: Tatoeba's export changed since 2026-11-14; check its licence and pin the new one" >&2; exit 1; }; }
ln -sf "$tatoeba" tatoeba-eng_sentences.tsv.bz2
[[ -s enwikinews-20261101.xml.bz2 ]] ||
  { curl --limit-rate 35M -sfo wikinews.part https://dumps.wikimedia.org/enwikinews/20261101/enwikinews-20261101-pages-articles.xml.bz2 &&
    mv wikinews.part enwikinews-20261101.xml.bz2; }
du -sh "$run/data/src"/*
