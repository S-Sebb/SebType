#!/usr/bin/env bash
# #556 eval, on yanglab16: probe.sh TREE MODEL OUT [SETS...]. Builds TREE's English harness, runs the model-only
# (sebtype) and core stacks on eval/sets/*.tsv with MODEL, writes STACK.SET.tsv into OUT. Extra env
# (SEBTYPE_CAP, SEBTYPE_BARE_HINT) passes through to the binaries.
set -euo pipefail
tree=$1 model=$2 out=$3; shift 3
sets=${*:-contractions homographs owner lone-i next-contr}
p=$HOME/scratch/SebType/556/eval/sets
cd "$tree"
source tools/lib.sh
here=android/test/english
aosp=$SCRATCH/cache/aosp-latinime-127336e9f29d
export JAVA_HOME=${JAVA_HOME:-$JDK21}
b=$here/build-556
if [[ ! -x $b/english-core || ${REBUILD:-} ]]; then
  cmake -S $here -B $b -G Ninja -DCMAKE_BUILD_TYPE=Release -DAOSP_JNI="$aosp/native/jni" \
    -DLLAMA_DIR="$(engines/sebtype-lm/fetch-llama.sh)" > /dev/null
  build_lock 60 probe-556 ninja -C $b -j "$BUILD_JOBS" english-core english-sebtype > /dev/null
fi
mkdir -p "$out"
jobs=()
for s in $sets; do
  [[ ${CORE_ONLY:-} ]] || jobs+=("$b/english-sebtype $p/$s.tsv $out/sebtype.$s.tsv $here/layout.tsv $aosp/java/res/raw/main_en.dict $model")
  jobs+=("$b/english-core $p/$s.tsv $out/core.$s.tsv $here/layout.tsv data/en-dict/en_US.dict $model")
done
printf '%s\n' "${jobs[@]}" | xargs -P 12 -I{} sh -c '{} > /dev/null 2>&1'
echo "$out"
