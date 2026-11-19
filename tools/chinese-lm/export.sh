#!/usr/bin/env bash
# Converts a checkpoint (train.py) to GGUF, quantised to Q6_K, with the English model's export.
#
#   tools/chinese-lm/export.sh CKPT_DIR OUT.gguf
LM_VENV=$HOME/scratch/SebType/cache/chinese-lm-venv LM_NAME="SebType Chinese" LM_QUANT=Q6_K exec "$(dirname "$0")/../english-lm/export.sh" "$@"
