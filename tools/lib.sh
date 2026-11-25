# Shared by SebType's build and test scripts (source it): the Android toolchain, the caches, and the one way
# every heavy build runs, in the shared build lock with the same cores and memory cap. Every build runs on the
# machine the script runs on (#592). docs/development.md explains the lock, the rank and the caps.

# shellcheck source=../linux/versions.sh
source "$(dirname "${BASH_SOURCE[0]}")/../linux/versions.sh"
# Files made outside the checkout: ~/scratch/SebType, or the project's scratch/ (SEBTYPE_PROJECT,
# linux/versions.sh); in cache/ the tests' fixtures, which every worktree shares. The builds' caches are in
# CACHE.
SCRATCH=${SEBTYPE_PROJECT:+$SEBTYPE_PROJECT/scratch}
SCRATCH=${SCRATCH:-$HOME/scratch/SebType}
# The running task's test, perf and release outputs: $SCRATCH/<ISSUE>/ (ISSUE=211 <script>),
# or without ISSUE the checkout's folder name.
TASK_OUT=$SCRATCH/${ISSUE:-$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")}

# nobara-pc has 16 threads and 15 GB, shared with the emulator, the person using it and other projects'
# builds: a build gets 6 cores' worth of CPU, 6 compile jobs, 4 Gradle workers and 8 GB.
BUILD_JOBS=6 GRADLE_WORKERS=4
BUILD_MEMORY_GB=8

# yanglab16, the lab's shared machine: a build gets half its 96 threads and 32 GB, runs in the pinned Fedora
# (fedora_container: its Ubuntu has neither Rust nor librime), and the Android build's tools are pinned in
# CACHE (tools/android-tools.sh). The build container sees SEBTYPE_HOST through --env-host: its own host
# name is the container's, and it has no hostname command.
if [[ ${SEBTYPE_HOST:=$(uname -n)} == yanglab16* ]]; then
  export SEBTYPE_HOST
  BUILD_JOBS=$(( $(nproc) / 2 )) BUILD_MEMORY_GB=32
  # The build container is already capped to that half, and nproc there counts only it.
  [[ -f /run/.containerenv ]] && BUILD_JOBS=$(nproc)
  GRADLE_WORKERS=$BUILD_JOBS
  export ANDROID_HOME=$CACHE/android-sdk JAVA_HOME_21=$CACHE/jdks/jdk-21.0.13+9 \
    GRADLE_USER_HOME=$CACHE/gradle ANDROID_USER_HOME=$CACHE/android-user \
    SCCACHE_DIR=$CACHE/sccache CARGO_HOME=$CACHE/cargo PATH=$CACHE/bin:$PATH
  # Bazel refuses an output root it doesn't own, and on the NAS every file belongs to the NAS's user: its
  # caches are in a podman volume, in podman's storage (in the project's capped folder when
  # CONTAINERS_STORAGE_CONF points there). A BAZEL_CACHE set beforehand stays: inside the build container it
  # comes from the host, and a test may name a cache of its own (a cold-cache build, #361). A kde-emu
  # session has no podman, and builds nothing (#596).
  if [[ -z ${BAZEL_CACHE:-} ]] && command -v podman >/dev/null; then
    podman volume exists sebtype-bazel || podman volume create sebtype-bazel >/dev/null
    BAZEL_CACHE=$(podman volume inspect -f '{{.Mountpoint}}' sebtype-bazel)
    export BAZEL_CACHE
  fi
fi
# On a GitHub-hosted runner (.github/workflows/linux-rpm.yml) the build has the machine to itself: all its
# cores and most of its memory, and no lock (build_lock).
if [[ ${GITHUB_ACTIONS:-} == true ]]; then
  BUILD_JOBS=$(nproc) BUILD_MEMORY_GB=$(( $(awk '/^MemTotal/ { print int($2 / 1048576) }' /proc/meminfo) - 2 ))
fi
# Bazel's output roots and caches (Mozc's builds).
BAZEL_CACHE=${BAZEL_CACHE:-$CACHE}

export ANDROID_HOME=${ANDROID_HOME:-$HOME/Android/Sdk}
JDK21=${JAVA_HOME_21:-$(ls -d "$HOME"/.local/share/jdks/jdk-21* 2>/dev/null | tail -1 || true)}  # none: no Android build here

# fedora_container [PODMAN_OPTION...]: on yanglab16, sets container to the command that runs a build there
# in the pinned Fedora nobara-pc runs (linux/versions.sh), with what builds take from the system: Fedora's
# librime and OpenCC for the Chinese data, gcc for Bazel's host tools, Rust and fontconfig for the
# Configurator, python, git for llama.cpp's pinned checkout (engines/sebtype-lm/fetch-llama.sh). It runs as
# tony with an empty home (Java takes it from the user, not HOME), its CPUs and memory capped, the scratch
# folders where they are (under both their paths), CACHE, and the checkout at its own (physical) path.
# Elsewhere, to nothing: the build runs on the host.
fedora_container() {
  container=()
  [[ $SEBTYPE_HOST == yanglab16* && ! -f /run/.containerenv ]] || return 0
  local rpms='librime librime-lua opencc gcc gcc-c++ cargo rust fontconfig-devel python3 python-unversioned-command unzip zip diffutils findutils which git'
  local image nas root d mounts=()
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
  image=localhost/sebtype-fedora:$(sha256sum <<<"$BUILD_IMAGE $rpms" | head -c 12)
  mkdir -p "$CACHE" "$SCRATCH"
  podman image exists "$image" ||
    podman build -q -t "$image" -f - "$CACHE" <<<"FROM $BUILD_IMAGE
RUN dnf -y --setopt=throttle=35M install $rpms && dnf clean all" >/dev/null
  # The scratch folders under both their paths, and ~/scratch/SebType's language models too when the
  # project has its own.
  for d in "$SCRATCH" "$HOME/scratch/SebType"; do
    [[ -d $d ]] || continue
    nas=$(readlink -f "$d")
    for d in "$d" "$nas"; do [[ " ${mounts[*]} " == *":$d "* ]] || mounts+=(-v "$nas:$d"); done
  done
  container=(podman run --rm --env-host --userns=keep-id --tmpfs "$HOME:rw,U"
    --cpus "$BUILD_JOBS" --memory "${BUILD_MEMORY_GB}g" --memory-swap "${BUILD_MEMORY_GB}g"
    "${mounts[@]}" -v "$CACHE:$CACHE" -v "$root:$root" "$@" "$image")
}

# sccache_env ROOT: C and C++ compiles go through sccache, with a private server (sccache --start-server
# starts it) whose hashes take paths relative to the checkout's real root ROOT, so every checkout shares the
# cache. Without its preprocessor cache, which keys entries by those relative paths but checks the headers at
# the absolute paths of the checkout that stored them: a checkout whose headers differ got that one's
# objects and depfiles (#318). Objects are then found by the preprocessed source, as before sccache 0.7.
sccache_env() {
  mkdir -p "$CACHE"
  SCCACHE_SERVER_UDS=$(mktemp -u "$CACHE/sccache.XXXXXX")  # well under a socket path's 108 bytes
  export CMAKE_C_COMPILER_LAUNCHER=sccache CMAKE_CXX_COMPILER_LAUNCHER=sccache SCCACHE_BASEDIRS=$1 \
    SCCACHE_DIRECT=false SCCACHE_SERVER_UDS
}

# test_key: for the test scripts that build a release. Where SebType's key isn't (it stays on nobara-pc,
# Decisions #2), SEBTYPE_KEY_DIR points at this machine's test key, CN=SebType test key, in the tests'
# cache: made once, renamed into place whole so runs at the same time keep whichever got there first, and
# never deleted, since parallel runs sign with it (#603). android/release.sh doesn't call it and refuses
# that key.
test_key() {
  [[ -f ${SEBTYPE_KEY_DIR:-$HOME/.config/sebtype}/sebtype-release.jks ]] && return
  export SEBTYPE_KEY_DIR=$SCRATCH/cache/test-key
  [[ -f $SEBTYPE_KEY_DIR/sebtype-release.jks ]] && return
  [[ -x $JDK21/bin/keytool || $SEBTYPE_HOST != yanglab16* ]] || "$(dirname "${BASH_SOURCE[0]}")/android-tools.sh"
  local tmp; mkdir -p "$SCRATCH/cache" && tmp=$(mktemp -d "$SCRATCH/cache/test-key.XXXXXX") || return
  head -c 24 /dev/urandom | base64 > "$tmp/keystore.password"
  "$JDK21/bin/keytool" -genkeypair -keystore "$tmp/sebtype-release.jks" -storetype PKCS12 -alias sebtype \
    -keyalg RSA -keysize 2048 -validity 36500 -dname "CN=SebType test key" \
    -storepass:file "$tmp/keystore.password" > "$tmp/keytool.log" 2>&1 ||
    { echo "test_key: keytool failed, see $tmp/keytool.log" >&2; return 1; }
  mv -T "$tmp" "$SEBTYPE_KEY_DIR" 2>/dev/null || rm -rf "$tmp"
}

# build_lock MINUTES NAME CMD...: runs CMD in the shared build lock (one heavy SebType build at a time),
# waiting up to an hour plus MINUTES for it, under the CPU and memory caps, at the lowest CPU and I/O
# priority. The queue rank is DEVQ_RANK (default 2; it orders the queue, the lock is still one build at a
# time), so a script run by a ranked caller builds at the caller's rank. Don't nest it: builds started
# inside CMD are already in it.
build_lock() {
  local minutes=$1 name=$2
  shift 2
  [[ ${GITHUB_ACTIONS:-} != true ]] || { "$@"; return; }
  # Within a rank devq orders tickets by MINUTES less the minutes waited: a long job gets ahead of fresh
  # short ones only after waiting the difference, so its wait grows with MINUTES (#538).
  devq -w $(( 3600 + minutes * 60 )) -m "$minutes" -P "${DEVQ_RANK:-2}" -n "$name" /tmp/agent-locks/sebtype/build.lock \
    systemd-run --user --scope --quiet -p CPUQuota="${BUILD_JOBS}00%" -p MemoryMax="${BUILD_MEMORY_GB}G" \
    -p MemorySwapMax=0 nice -n 19 ionice -c 3 "$@"
}

# private_dbus DIR [ENV...] -- CMD...: CMD in a private D-Bus session that can't reach the user's desktop.
# Every test that starts its own D-Bus (a private Fcitx5, a nested KWin) goes through it. ENV goes to env
# (-i, -u NAME, NAME=VALUE). DIR is a throwaway directory the caller removes; the session's files go in it.
# - Its own XDG_RUNTIME_DIR (#176): in the user's, anything that touches the Documents portal starts a
#   second xdg-document-portal on the user's $XDG_RUNTIME_DIR/doc, and the user's mount goes when it
#   ends, so Flatpak apps no longer start. The session sees it by a short link in the user's (#525): a
#   nested KWin puts its Xwayland's input socket there (kwin-xwayland-eis-socket.<pid>), which under a
#   long DIR passes a Unix socket's 108 bytes, and then Xwayland never answers its first X client.
# - No desktop portal (#203): a nested KWin starts plasma-keyboard, which asks for it, and the portal,
#   started by this bus without a display, aborts and is started again, dozens of times a minute. Its
#   services are masked by ones that fail at once; the Documents portal stays.
# - RLIMIT_CORE=1, so the kernel hands no crash in the session to systemd-coredump, and none raises a
#   DrKonqi notice on the user's desktop.
private_dbus() {
  local rt link l s env=()
  rt=$(mktemp -d "$1/run.XXXX"); shift  # 0700
  link=$rt  # without XDG_RUNTIME_DIR (CI, cron) the long path: only --xwayland callers need the short one
  if [[ -n ${XDG_RUNTIME_DIR-} ]]; then
    # Links stay after the session: its Documents portal may still unmount <link>/doc once dbus-run-session
    # has returned. Earlier sessions' links whose sandbox is gone are swept here instead.
    find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'sebtype-bus.*' -xtype l -delete
    l=$(mktemp -u "$XDG_RUNTIME_DIR/sebtype-bus.XXXX") && ln -s "$rt" "$l" && link=$l
  fi
  while [[ $1 != -- ]]; do env+=("$1"); shift; done; shift
  mkdir "$rt/masked"
  for s in /usr/share/dbus-1/services/org.freedesktop.portal.Desktop.service \
      /usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.*.service; do
    printf '[D-BUS Service]\nName=%s\nExec=/bin/false\n' "$(basename "$s" .service)" > "$rt/masked/${s##*/}"
  done
  # The first service dir that has a name wins, so the masks go before the standard ones.
  printf '<busconfig>\n  <servicedir>%s</servicedir>\n  <include>/usr/share/dbus-1/session.conf</include>\n</busconfig>\n' \
    "$rt/masked" > "$rt/bus.conf"
  env "${env[@]}" XDG_RUNTIME_DIR="$link" prlimit --core=1 -- dbus-run-session --config-file="$rt/bus.conf" -- "$@"
}

# doc_portal NAME before|after: the user's Documents portal is still mounted (#550). A second portal on the
# user's runtime dir (#176; another project's nested session, S-Sebb/SebChat#905) unmounts it when it ends,
# and the user's Flatpak apps no longer start. Gone, it is said and put back (restarting the user's portal
# is the one change to the user's session a test makes): before the run a NOTE, as something before it
# took it, or a FAIL if it doesn't come back; after it a FAIL. Calls the script's result. Only for a
# desktop session (a Wayland or X11 one) with the portal's unit, on that session's own runtime dir: elsewhere
# none is expected, and a private runtime dir (with the user's bus) would restart the user's healthy portal.
doc_expected() {
  local s
  [[ -n ${XDG_RUNTIME_DIR-} && $(realpath -e "$XDG_RUNTIME_DIR" 2> /dev/null) == "/run/user/$UID" ]] && s=$(loginctl show-user "$USER" -p Display --value 2>/dev/null) && [[ -n $s ]] &&
    [[ $(loginctl show-session "$s" -p Type --value) == @(wayland|x11) ]] &&
    systemctl --user cat xdg-document-portal.service &> /dev/null
}
doc_portal() {
  local doc=${XDG_RUNTIME_DIR-}/doc back
  if ! doc_expected; then [[ $2 == before ]] || result SKIP "$1" "no desktop session with a Documents portal"; return 0; fi
  # by-app/ isn't there when it's unmounted, nor on a mount whose portal died ("not connected")
  if [[ -d $doc/by-app ]]; then [[ $2 == before ]] || result PASS "$1"; return 0; fi
  systemctl --user restart xdg-document-portal.service
  [[ -d $doc/by-app ]] && back="restarted xdg-document-portal.service, mounted again" ||
    back="restarted xdg-document-portal.service, STILL NOT MOUNTED"
  if [[ $2 == after ]]; then result FAIL "$1" "the user's Documents portal ($doc) was unmounted during this run; $back"
  elif [[ -d $doc/by-app ]]; then result NOTE "$1" "the user's Documents portal ($doc) was unmounted before this run; $back"
  else result FAIL "$1" "the user's Documents portal ($doc) was unmounted before this run; $back"
  fi
}

# in_sandbox PID DIR: the process's own XDG_DATA_HOME is in DIR (not another variable that holds the path).
in_sandbox() {
  local e
  while IFS= read -rd '' e; do [[ $e == "XDG_DATA_HOME=$2/"* ]] && return 0; done 2> /dev/null < "/proc/$1/environ"
  return 1
}

# stop_sandbox DIR: stops the processes that run with XDG_DATA_HOME in DIR, and waits until they have exited.
# What a private session started (ksecretd, a Documents portal) outlives its D-Bus, and a portal unmounts as
# it ends: they go before a check of the user's portal. TERM, and after 15 s KILL; fails, naming them, if any
# still runs after that.
stop_sandbox() {
  local p left=() still=()
  for p in $(pgrep -u "$USER"); do in_sandbox "$p" "$1" && kill "$p" && left+=("$p"); done
  ((${#left[@]})) || return 0
  for _ in {1..75}; do ps -p "${left[*]}" > /dev/null || return 0; sleep 0.2; done
  # Only those still in the sandbox: an exited one's PID may be another process's by now.
  for p in "${left[@]}"; do in_sandbox "$p" "$1" && still+=("$p"); done
  ((${#still[@]})) || return 0
  left=("${still[@]}")
  kill -9 "${left[@]}" 2>/dev/null
  for _ in {1..10}; do ps -p "${left[*]}" > /dev/null || return 0; sleep 0.2; done
  echo "still running after KILL: $(ps -o pid=,comm= -p "${left[*]}" | xargs)"
  return 1
}
