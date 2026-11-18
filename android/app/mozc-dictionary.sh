#!/usr/bin/env bash
# Puts Mozc's Japanese dictionary in OUTPUT_DIR as the raw resource builtin_mozc_data: the file for 日本語
# (raw-ja/) and an empty one for every other language, so the resource exists in each configuration. The file
# is Mozc's OSS data set (//data_manager/oss:mozc_dataset_for_oss, the data the PCs' Mozc builds in), built
# with Bazel from engines/mozc, the same revision libmozc.so is built from (#335): Mozc's BSD-3-Clause and its
# data's licences (../../engines/mozc/LICENSE, data/dictionary_oss/README.txt), nothing GPL.
#
#   android/app/mozc-dictionary.sh OUTPUT_DIR
#
# Gradle runs it (build.gradle) inside android/build.sh's build lock and caches its output by engines/mozc's
# files; Bazel's own cache is libmozc.so's (tools/mozc-bazel.sh's mozc_bazel).
set -euo pipefail
out=${1:?usage: mozc-dictionary.sh OUTPUT_DIR}
source "$(dirname "$0")/../../tools/lib.sh"
source "$(dirname "$0")/../../tools/mozc-bazel.sh"
dataset=//data_manager/oss:mozc_dataset_for_oss
mozc_bazel oss_linux build "$dataset"
mkdir -p "$out/raw" "$out/raw-ja"
: > "$out/raw/builtin_mozc_data.dict"
cp -f "$(mozc_files oss_linux "$dataset" | grep '/mozc\.data$')" "$out/raw-ja/builtin_mozc_data.dict"
