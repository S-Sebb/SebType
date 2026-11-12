#!/usr/bin/env bash
# Builds test-settings.py's set-text helper APK (debug-signed, no Gradle):  build.sh OUT.apk
set -euo pipefail
src=$(cd "$(dirname "$0")" && pwd) out=$1
sdk=${ANDROID_HOME:-$HOME/Android/Sdk}
bt=$(ls -d "$sdk"/build-tools/* | tail -1) jar=$(ls "$sdk"/platforms/android-*/android.jar | tail -1)
jdk=${JAVA_HOME_21:-$(ls -d "$HOME"/.local/share/jdks/jdk-21* | tail -1)}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"$jdk/bin/javac" --release 11 -cp "$jar" -d "$work/classes" "$src"/dev/sebb/sebtype/settext/SetText.java
JAVA_HOME=$jdk "$bt/d8" --min-api 26 --lib "$jar" --output "$work" $(find "$work/classes" -name '*.class')
"$bt/aapt2" link -I "$jar" --manifest "$src/AndroidManifest.xml" -o "$work/base.apk"
(cd "$work" && zip -q base.apk classes.dex)
"$bt/zipalign" -f 4 "$work/base.apk" "$work/aligned.apk"
JAVA_HOME=$jdk "$bt/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-pass pass:android --out "$out" "$work/aligned.apk"
