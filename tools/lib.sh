# Shared by SebType's build and test scripts (source it): the Android toolchain, where heavy builds run,
# and the one way every heavy build runs, in the shared build lock with the same cores and memory cap.
# docs/development.md explains the lock, the rank and the caps.

# Files made outside the checkout; in cache/ the caches every worktree shares (the Linux setup's too).
SCRATCH=$HOME/scratch/SebType
# The running task's test, perf and release outputs: ~/scratch/SebType/<ISSUE>/ (ISSUE=211 <script>),
# or without ISSUE the checkout's folder name.
TASK_OUT=$SCRATCH/${ISSUE:-$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")}

# nobara-pc has 16 threads and 15 GB, shared with the emulator, the person using it and other projects'
# builds: a build gets 6 cores' worth of CPU, 6 compile jobs, 4 Gradle workers and 8 GB.
BUILD_JOBS=6 GRADLE_WORKERS=4
BUILD_MEMORY_GB=8

# Where the heavy builds run (#225): on yanglab16, the lab's machine, unless SEBTYPE_BUILD_HOST=local
# (build_host_ready, build_remotely). There, a shared machine, a build gets half its 96 threads and 32 GB,
# and the Android build's tools are in the scratch cache (tools/android-tools.sh).
BUILD_HOST=${SEBTYPE_BUILD_HOST:-yanglab16}
# The build container sees SEBTYPE_HOST through --env-host (fedora_container): its own host name is the
# container's, and it has no hostname command.
if [[ ${SEBTYPE_HOST:=$(uname -n)} == yanglab16* ]]; then
  export SEBTYPE_HOST
  BUILD_HOST=local BUILD_JOBS=$(( $(nproc) / 2 )) BUILD_MEMORY_GB=32
  # The build container is already capped to that half, and nproc there counts only it.
  [[ -f /run/.containerenv ]] && BUILD_JOBS=$(nproc)
  GRADLE_WORKERS=$BUILD_JOBS
  export ANDROID_HOME=$SCRATCH/cache/android-sdk JAVA_HOME_21=$SCRATCH/cache/jdks/jdk-21.0.13+9 \
    GRADLE_USER_HOME=$SCRATCH/cache/gradle ANDROID_USER_HOME=$SCRATCH/cache/android-user \
    SCCACHE_DIR=$SCRATCH/cache/sccache CARGO_HOME=$SCRATCH/cache/cargo PATH=$SCRATCH/cache/bin:$PATH
  # Bazel refuses an output root it doesn't own, and on the NAS every file belongs to the NAS's user. A
  # BAZEL_CACHE set beforehand stays: inside the build container it comes from the host, and a test may name
  # a cache of its own (a cold-cache build, #361).
  if [[ -z ${BAZEL_CACHE:-} ]]; then
    podman volume exists sebtype-bazel || podman volume create sebtype-bazel >/dev/null
    BAZEL_CACHE=$(podman volume inspect -f '{{.Mountpoint}}' sebtype-bazel)
    export BAZEL_CACHE
  fi
fi
# On a GitHub-hosted runner (.github/workflows/linux-rpm.yml) the build has the machine to itself: all its
# cores and most of its memory, and no lock (build_lock).
if [[ ${GITHUB_ACTIONS:-} == true ]]; then
  BUILD_HOST=local BUILD_JOBS=$(nproc) BUILD_MEMORY_GB=$(( $(awk '/^MemTotal/ { print int($2 / 1048576) }' /proc/meminfo) - 2 ))
fi
# Bazel's output roots and caches (Mozc's builds).
BAZEL_CACHE=${BAZEL_CACHE:-$SCRATCH/cache}

export ANDROID_HOME=${ANDROID_HOME:-$HOME/Android/Sdk}
JDK21=${JAVA_HOME_21:-$(ls -d "$HOME"/.local/share/jdks/jdk-21* 2>/dev/null | tail -1 || true)}  # none: no Android build here

# build_host_ready: whether this build runs on the build host. If the host doesn't answer, it tries again
# with a longer timeout (a slow moment on the lab network), then, only if Zscaler's tray isn't running,
# starts Zscaler and tries once more: each start brings Zscaler's window up on the person's desktop (#520).
# If the host still doesn't answer, it says so and the build runs here.
build_host_ready() {
  [[ $BUILD_HOST != local ]] || return 1
  local try=(ssh -o BatchMode=yes)
  "${try[@]}" -o ConnectTimeout=10 "$BUILD_HOST" true 2>/dev/null && return
  "${try[@]}" -o ConnectTimeout=30 "$BUILD_HOST" true 2>/dev/null && return
  if ! pgrep -x ZSTray >/dev/null; then
    gtk-launch ZSTray >/dev/null 2>&1 && sleep 20 && "${try[@]}" -o ConnectTimeout=30 "$BUILD_HOST" true 2>/dev/null && return
  fi
  echo "build: $BUILD_HOST unreachable; building on $(uname -n) (SEBTYPE_BUILD_HOST=local skips the try)" >&2
  BUILD_HOST=local
  return 1
}

# build_remotely [NAME=VALUE...] SCRIPT [ARG...]: runs SCRIPT (a path in the checkout) with ARGs on the
# build host, in a copy of this checkout there, ~/scratch/SebType/<task>/<checkout>: rsynced with its
# uncommitted changes but not what git ignores.
# DEVQ_RANK, ISSUE, LIBRIME_KEY (linux/versions.sh: the copy has no git) and the NAME=VALUEs go with it.
# The files SCRIPT prints, in the copy or in the host's ~/scratch/SebType, are copied back to the same place
# here, and their paths printed. If SCRIPT fails, what it
# printed goes to stderr instead (linux/build.sh prints the reason there).
build_remotely() {
  local root dir out f rel here key
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  dir=$(basename "$TASK_OUT")/$(basename "$root")
  key=$(source "$root/linux/versions.sh" && librime_key) || return 1
  local env=(SEBTYPE_BUILD_HOST=local ${DEVQ_RANK:+DEVQ_RANK=$DEVQ_RANK} ${ISSUE:+ISSUE=$ISSUE} "LIBRIME_KEY=$key")
  while [[ $1 == *=* ]]; do env+=("$1"); shift; done
  # rsync's .gitignore rules would also leave out the files git tracks despite them (librime's include/):
  # those, and their folders, are taken first. Ignored files on the host stay: its build outputs.
  git -C "$root" ls-files -ci --exclude-standard |
    awk -F/ '{ p = ""; for (i = 1; i < NF; i++) { p = p "/" $i; print "+ " p "/" } print "+ /" $0 }' | sort -u |
    rsync -a --delete --exclude=/.git --filter='. -' --filter=':- .gitignore' \
      --rsync-path="mkdir -p scratch/SebType/$dir && rsync" "$root/" "$BUILD_HOST:scratch/SebType/$dir/" || return 1
  out=$(ssh "$BUILD_HOST" "cd scratch/SebType/$dir && $(printf '%q ' env "${env[@]}" "$@")") ||
    { [[ -z $out ]] || echo "$out" >&2; echo "build: failed on $BUILD_HOST" >&2; return 1; }
  for f in $out; do
    rel=${f#*/scratch/SebType/}
    if [[ $rel == "$dir"/* ]]; then here=$root/${rel#"$dir"/}; else here=$SCRATCH/$rel; fi
    mkdir -p "$(dirname "$here")" && rsync -a "$BUILD_HOST:$f" "$here" || return 1
    echo "$here"
  done
}

# fedora_container [PODMAN_OPTION...]: on yanglab16, sets container to the command that runs a build there
# in the pinned Fedora nobara-pc runs (linux/versions.sh), with what builds take from the system: Fedora's
# librime and OpenCC for the Chinese data, gcc for Bazel's host tools, Rust and fontconfig for the
# Configurator, python, git for llama.cpp's pinned checkout (engines/sebtype-lm/fetch-llama.sh). It runs as
# tony with an empty home (Java takes it from the user, not HOME), its CPUs and memory capped, and the scratch
# folder where it is (under both its paths: Gradle takes the NAS's).
# Elsewhere, to nothing: the build runs on the host.
fedora_container() {
  container=()
  [[ $SEBTYPE_HOST == yanglab16* && ! -f /run/.containerenv ]] || return 0
  local rpms='librime librime-lua opencc gcc gcc-c++ cargo rust fontconfig-devel python3 python-unversioned-command unzip zip diffutils findutils which git'
  local image nas
  # shellcheck source=../linux/versions.sh
  source "$(dirname "${BASH_SOURCE[0]}")/../linux/versions.sh"
  image=localhost/sebtype-fedora:$(sha256sum <<<"$BUILD_IMAGE $rpms" | head -c 12)
  podman image exists "$image" ||
    podman build -q -t "$image" -f - "$SCRATCH/cache" <<<"FROM $BUILD_IMAGE
RUN dnf -y --setopt=throttle=35M install $rpms && dnf clean all" >/dev/null
  nas=$(readlink -f "$SCRATCH")
  container=(podman run --rm --env-host --userns=keep-id --tmpfs "$HOME:rw,U"
    --cpus "$BUILD_JOBS" --memory "${BUILD_MEMORY_GB}g" --memory-swap "${BUILD_MEMORY_GB}g"
    -v "$nas:$SCRATCH" -v "$nas:$nas" "$@" "$image")
}

# sccache_env ROOT: C and C++ compiles go through sccache, with a private server (sccache --start-server
# starts it) whose hashes take paths relative to the checkout's real root ROOT, so every checkout shares the
# cache. Without its preprocessor cache, which keys entries by those relative paths but checks the headers at
# the absolute paths of the checkout that stored them: a checkout whose headers differ got that one's
# objects and depfiles (#318). Objects are then found by the preprocessed source, as before sccache 0.7.
sccache_env() {
  mkdir -p "$SCRATCH/cache"
  SCCACHE_SERVER_UDS=$(mktemp -u "$SCRATCH/cache/sccache.XXXXXX")  # well under a socket path's 108 bytes
  export CMAKE_C_COMPILER_LAUNCHER=sccache CMAKE_CXX_COMPILER_LAUNCHER=sccache SCCACHE_BASEDIRS=$1 \
    SCCACHE_DIRECT=false SCCACHE_SERVER_UDS
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
