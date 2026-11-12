#!/usr/bin/env bash
# Builds the perf test field (PerfField.java) with the SDK's own tools, no Gradle.
#   android/perf/build-field.sh OUTPUT.apk
set -euo pipefail
source "$(dirname "$0")/../../tools/lib.sh"
here=$(cd "$(dirname "$0")" && pwd)
apk=$(realpath -m "$1")
sdk=$ANDROID_HOME
bt=$(ls -d "$sdk"/build-tools/* | tail -1)
jar=$(ls -d "$sdk"/platforms/android-* | sort -V | tail -1)/android.jar
jdk=$JDK21
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT

"$jdk/bin/javac" -nowarn --release 11 -classpath "$jar" -d "$w/classes" "$here/PerfField.java"
"$jdk/bin/java" -cp "$bt/lib/d8.jar" com.android.tools.r8.D8 --lib "$jar" --min-api 29 --output "$w" \
  $(find "$w/classes" -name '*.class')
"$bt/aapt2" link -I "$jar" --manifest "$here/AndroidManifest.xml" -o "$w/unsigned.apk"
(cd "$w" && zip -q unsigned.apk classes.dex)
"$bt/zipalign" -f 4 "$w/unsigned.apk" "$w/aligned.apk"
# A throwaway test app: Android's debug key is enough.
PATH=$jdk/bin:$PATH "$bt/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-pass pass:android \
  --out "$apk" "$w/aligned.apk"
