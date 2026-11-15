#!/usr/bin/env bash
# Converts a checkpoint (train.py) to the GGUF model the loader reads, quantised to Q6_K as FUTO's is.
#
#   tools/english-lm/export.sh CKPT_DIR OUT.gguf
set -euo pipefail
ckpt=$1 out=$2
venv=$HOME/scratch/SebType/cache/english-lm-venv
llama=$("$(dirname "$0")/../../engines/sebtype-lm/fetch-llama.sh")
if [[ ! -x $llama/build/bin/llama-quantize ]]; then
  cmake -S "$llama" -B "$llama/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=OFF -DGGML_CUDA=OFF > /dev/null
  ninja -C "$llama/build" -j 8 llama-quantize > /dev/null
fi
"$venv/bin/python" "$llama/convert_hf_to_gguf.py" "$ckpt" --outtype f32 --outfile "$out.f32" \
  --model-name "SebType English" > "$out.log" 2>&1
"$llama/build/bin/llama-quantize" "$out.f32" "$out" Q6_K 1 >> "$out.log" 2>&1
rm "$out.f32"
ls -l "$out"
