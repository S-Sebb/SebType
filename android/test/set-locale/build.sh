#!/usr/bin/env bash
# Builds test-emulator.sh's set-locale helper, a dex for app_process (no APK, no Gradle):  build.sh OUT.dex
set -euo pipefail
src=$(cd "$(dirname "$0")" && pwd) out=$(realpath -m "$1")
sdk=${ANDROID_HOME:-$HOME/Android/Sdk}
bt=$(ls -d "$sdk"/build-tools/* | tail -1) jar=$(ls "$sdk"/platforms/android-*/android.jar | tail -1)
jdk=${JAVA_HOME_21:-$(ls -d "$HOME"/.local/share/jdks/jdk-21* | tail -1)}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$jdk/bin/javac" --release 11 -cp "$jar" -d "$work/classes" "$src"/dev/sebb/sebtype/setlocale/SetLocale.java
JAVA_HOME=$jdk "$bt/d8" --min-api 30 --lib "$jar" --output "$work" $(find "$work/classes" -name '*.class')
mv "$work/classes.dex" "$out"
