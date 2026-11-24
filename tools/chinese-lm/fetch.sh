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

# One download at a time, each capped (tools/hf-fetch.sh): together they would fill the lab's shared port.
here=$(realpath "$(dirname "$0")")
hf_fetch=$here/../hf-fetch.sh
hf() { "$hf_fetch" "$venv/bin/python" "$@"; }
mkdir -p "$run/data/src"
cd "$run/data/src"
# Revisions pinned to the commits whose licence tags were checked (SOURCES.md).
hf wikipedia wikimedia/wikipedia b04c8d1ceb2f5cd4588862100d08de323dccfbaa '20231101.zh/*'
hf oasst2 OpenAssistant/oasst2 179dd21fc55192153d94adb0e0ce8f69e222bf75 '2023-11-05_oasst2_all.messages.jsonl.gz'
hf hundredcv-chat Jax-dan/HundredCV-Chat cece0fa1b87a8c3fdb08a7c45852863fea7ddfab synthesized_.jsonl
[[ -s zhwikinews-20261101.xml.bz2 ]] ||
  { curl --limit-rate 35M -sfo zhwikinews.part https://dumps.wikimedia.org/zhwikinews/20261101/zhwikinews-20261101-pages-articles.xml.bz2 &&
    mv zhwikinews.part zhwikinews-20261101.xml.bz2; }
kdconv=https://raw.githubusercontent.com/thu-coai/KdConv/653db76432de09a004ba708a68f8bbd5500e6bec/data
for d in film music travel; do
  for s in train dev test; do
    [[ -s kdconv/$d/$s.json ]] && continue
    mkdir -p kdconv/$d
    curl --limit-rate 35M -sfo kdconv/$d/$s.part "$kdconv/$d/$s.json" && mv kdconv/$d/$s.part kdconv/$d/$s.json
  done
done
# Tatoeba replaces its export every week and keeps no old ones: the checked export is kept in the cache.
tatoeba=$cache/chinese-lm/tatoeba-cmn_sentences_detailed-20261124.tsv.bz2
[[ -s $tatoeba ]] ||
  { mkdir -p "$(dirname "$tatoeba")" &&
    curl --limit-rate 35M -sfo "$tatoeba.part" https://downloads.tatoeba.org/exports/per_language/cmn/cmn_sentences_detailed.tsv.bz2 &&
    mv "$tatoeba.part" "$tatoeba"; }
mkdir -p tatoeba && ln -sf "$tatoeba" tatoeba/cmn_sentences_detailed.tsv.bz2
# 白霜's dictionary, the one the apps ship (data/rime/build.sh's pin): its readings correct pypinyin's.
eval "$(grep -E '^RIME_FROST_(VERSION|URL|SHA256)=' "$here/../../data/rime/build.sh")"
frost=$cache/$RIME_FROST_SHA256-rime-frost-schemas.zip
if ! echo "$RIME_FROST_SHA256  $frost" | sha256sum -c --status 2>/dev/null; then
  curl --limit-rate 35M -fsSL -o "$frost.part" "$RIME_FROST_URL"
  echo "$RIME_FROST_SHA256  $frost.part" | sha256sum -c --status && mv "$frost.part" "$frost"
fi
ln -sf "$frost" rime-frost-schemas.zip

# The meetings' transcripts (TextGrids) come only inside their audio archives (23-25 GB each): each is read
# as it downloads and only its TextGrids are kept, in the cache, so a later run downloads none of them again.
textgrids() { # NAME URL
  local d=$cache/chinese-lm/textgrid/$1
  if [[ ! -e $d/.done ]]; then
    rm -rf "$d" && mkdir -p "$d"
    curl --limit-rate 35M -fsSL --retry 3 "$2" | tar -xz -C "$d" --wildcards --no-anchored '*.TextGrid'
    touch "$d/.done"
  fi
  mkdir -p meetings && ln -sfn "$d" "meetings/$1"
}
ali=https://speech-lab-share-data.oss-cn-shanghai.aliyuncs.com/AliMeeting/openlr
textgrids alimeeting-train "$ali/Train_Ali_near.tar.gz"
textgrids alimeeting-eval "$ali/Eval_Ali.tar.gz"
for s in L M S; do textgrids aishell4-train-$s https://www.openslr.org/resources/111/train_$s.tar.gz; done
textgrids aishell4-test https://www.openslr.org/resources/111/test.tar.gz
du -shL "$run/data/src"/*
