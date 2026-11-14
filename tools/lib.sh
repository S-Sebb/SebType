# Shared by SebType's build and test scripts (source it): the Android toolchain, and the one way every
# heavy local build runs, in the shared build lock with the same cores and memory cap.
# docs/development.md explains the lock, the rank and the caps.

export ANDROID_HOME=${ANDROID_HOME:-$HOME/Android/Sdk}
JDK21=${JAVA_HOME_21:-$(ls -d "$HOME"/.local/share/jdks/jdk-21* 2>/dev/null | tail -1)}

# nobara-pc has 16 threads and 15 GB, shared with the emulator and the person using it: a build gets half
# the threads and 8 GB.
BUILD_JOBS=$(( $(nproc) / 2 ))
BUILD_MEMORY_GB=8

# Test, perf and release outputs, and in cache/ the development-only caches, shared by every worktree.
SCRATCH=$HOME/scratch/sebtype

# build_lock MINUTES NAME CMD...: runs CMD in the shared build lock (one heavy build at a time), waiting up
# to an hour for it, under the memory cap. The queue rank is DEVQ_RANK (default 2), so a script run by a
# ranked caller builds at the caller's rank. Don't nest it: builds started inside CMD are already in it.
build_lock() {
  local minutes=$1 name=$2
  shift 2
  devq -w 3600 -m "$minutes" -P "${DEVQ_RANK:-2}" -n "$name" /tmp/agent-locks/sebtype/build.lock \
    systemd-run --user --scope --quiet -p MemoryMax="${BUILD_MEMORY_GB}G" -p MemorySwapMax=0 "$@"
}
