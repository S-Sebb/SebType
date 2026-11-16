#!/usr/bin/env bash
# Converts a checkpoint (train.py) to GGUF, quantised to Q6_K, as the English model's export does.
#
#   tools/chinese-lm/export.sh CKPT_DIR OUT.gguf
LM_VENV=$HOME/scratch/SebType/cache/chinese-lm-venv LM_NAME="SebType Chinese" exec "$(dirname "$0")/../english-lm/export.sh" "$@"
