#!/usr/bin/env bash
# Runs a model on the dev sets (dev_sets.py) through the English harness's SebType stack, on the keyboard's
# own dictionary (data/en-dict/en_US.dict, as core/src/english.cpp), prints the dev numbers and the ranking
# weights tune.py finds for it. With the checkpoint the model was exported from, it also checks the export
# against it (parity.py). On yanglab16, for one model at a time.
#
#   tools/english-lm/dev.sh RUN_DIR MODEL.gguf [CKPT_DIR]
set -euo pipefail
run=$1 model=$2 ckpt=${3:-}
py=$HOME/scratch/SebType/cache/english-lm-venv/bin/python
cd "$(dirname "$0")/../.."
source tools/lib.sh
export JAVA_HOME=$JDK21  # for jni.h
here=android/test/english
aosp=$HOME/scratch/SebType/cache/aosp-latinime-127336e9f29d
build=$run/harness-build
cmake -S $here -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DAOSP_JNI="$aosp/native/jni" \
  -DLLAMA_DIR="$(engines/sebtype-lm/fetch-llama.sh)" > "$run/dev/build.log"
build_lock 30 english-lm-dev ninja -C "$build" -j "$BUILD_JOBS" english-sebtype >> "$run/dev/build.log"
out=$run/dev/out
mkdir -p "$out" && rm -f "$out"/* "$run"/dev/*.dump
for set in "$run"/dev/*.tsv; do
  name=$(basename "$set" .tsv)
  SEBTYPE_LM_DUMP=$run/dev/$name.dump "$build/english-sebtype" "$set" "$out/sebtype.$name.tsv" \
    $here/layout.tsv data/en-dict/en_US.dict "$model" &
done
wait
python3 -I $here/score.py "$out" > "$out/summary.json"
python3 -c "import json,sys; s=json.load(open(sys.argv[1]))['sebtype']; [print(k, {m: v for m, v in s[k].items() if 'ms' not in m}) for k in sorted(s)]" "$out/summary.json"
[[ -z $ckpt ]] || $py -I tools/english-lm/parity.py "$ckpt" "$run/dev/clean.tsv" "$run/dev/clean.dump"
$py -I tools/english-lm/tune.py "$run/dev"
