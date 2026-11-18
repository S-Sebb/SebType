#!/usr/bin/env bash
# Installs the Android build's tools, pinned, into ~/scratch/SebType/cache/ on a build host without them
# (yanglab16, #225): the JDK nobara-pc builds with, the Android SDK packages the build uses, and sccache.
# tools/lib.sh points the build at them there. Does nothing for a tool already installed.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
mkdir -p "$SCRATCH/cache" && cd "$SCRATCH/cache"

fetch() { # url sha256 file
  [[ -f $3 ]] && return
  curl --limit-rate 35M -sfL --retry 3 -o "$3.part" "$1"
  echo "$2  $3.part" | sha256sum -c --status || { echo "android-tools: checksum mismatch: $1" >&2; exit 1; }
  mv "$3.part" "$3"
}

if [[ ! -x $JDK21/bin/javac ]]; then
  fetch https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz \
    d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c jdk.tar.gz
  mkdir -p "$(dirname "$JDK21")" && tar -xzf jdk.tar.gz -C "$(dirname "$JDK21")" && rm jdk.tar.gz
fi

if ! command -v sccache >/dev/null; then
  fetch https://github.com/mozilla/sccache/releases/download/v0.19.0/sccache-v0.19.0-x86_64-unknown-linux-musl.tar.gz \
    aa73c7270c997894038c0d8f0d297865f57569e1687883322bc431713d4bb9dd sccache.tar.gz
  mkdir -p bin && tar -xzf sccache.tar.gz -O --wildcards '*/sccache' > bin/sccache && chmod +x bin/sccache && rm sccache.tar.gz
fi

# Command-line tools 19: from 20 on, sdkmanager installs the Android CLI into ~/.android.
sdkmanager=$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager
if [[ ! -x $sdkmanager ]]; then
  fetch https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip \
    7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee cmdline-tools.zip
  mkdir -p "$ANDROID_HOME/cmdline-tools" && unzip -q cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools" &&
    mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" && rm cmdline-tools.zip
fi
# What android/build.sh uses; Gradle would fetch a missing one itself, but outside the build lock.
packages=('platforms;android-35' 'build-tools;35.0.0' 'cmake;3.22.1' 'ndk;28.2.13676358')
missing=()
for p in "${packages[@]}"; do [[ -f $ANDROID_HOME/${p//;//}/source.properties ]] || missing+=("$p"); done
if ((${#missing[@]})); then
  # sdkmanager writes its analytics settings to ~/.android whatever ANDROID_USER_HOME says.
  export JAVA_HOME=$JDK21 SDKMANAGER_OPTS="-Duser.home=$ANDROID_USER_HOME"
  { yes || :; } | "$sdkmanager" --licenses >/dev/null  # yes ends on SIGPIPE
  "$sdkmanager" --install "${missing[@]}" >/dev/null
fi
