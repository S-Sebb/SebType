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
SCRATCH=$HOME/scratch/SebType

# build_lock MINUTES NAME CMD...: runs CMD in the shared build lock (one heavy build at a time), waiting up
# to an hour for it, under the memory cap. The queue rank is DEVQ_RANK (default 2), so a script run by a
# ranked caller builds at the caller's rank. Don't nest it: builds started inside CMD are already in it.
build_lock() {
  local minutes=$1 name=$2
  shift 2
  devq -w 3600 -m "$minutes" -P "${DEVQ_RANK:-2}" -n "$name" /tmp/agent-locks/sebtype/build.lock \
    systemd-run --user --scope --quiet -p MemoryMax="${BUILD_MEMORY_GB}G" -p MemorySwapMax=0 "$@"
}

# private_dbus DIR [ENV...] -- CMD...: CMD in a private D-Bus session that can't reach the user's desktop.
# Every test that starts its own D-Bus (a private Fcitx5, a nested KWin) goes through it. ENV goes to env
# (-i, -u NAME, NAME=VALUE). DIR is a throwaway directory the caller removes; the session's files go in it.
# - Its own XDG_RUNTIME_DIR (#176): in the user's, anything that touches the Documents portal starts a
#   second xdg-document-portal on the user's $XDG_RUNTIME_DIR/doc, and the user's mount goes when it
#   ends, so Flatpak apps no longer start.
# - No desktop portal (#203): a nested KWin starts plasma-keyboard, which asks for it, and the portal,
#   started by this bus without a display, aborts and is started again, dozens of times a minute. Its
#   services are masked by ones that fail at once; the Documents portal stays.
# - RLIMIT_CORE=1, so the kernel hands no crash in the session to systemd-coredump, and none raises a
#   DrKonqi notice on the user's desktop.
private_dbus() {
  local rt s env=()
  rt=$(mktemp -d "$1/run.XXXX"); shift  # 0700
  while [[ $1 != -- ]]; do env+=("$1"); shift; done; shift
  mkdir "$rt/masked"
  for s in /usr/share/dbus-1/services/org.freedesktop.portal.Desktop.service \
      /usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.*.service; do
    printf '[D-BUS Service]\nName=%s\nExec=/bin/false\n' "$(basename "$s" .service)" > "$rt/masked/${s##*/}"
  done
  # The first service dir that has a name wins, so the masks go before the standard ones.
  printf '<busconfig>\n  <servicedir>%s</servicedir>\n  <include>/usr/share/dbus-1/session.conf</include>\n</busconfig>\n' \
    "$rt/masked" > "$rt/bus.conf"
  env "${env[@]}" XDG_RUNTIME_DIR="$rt" prlimit --core=1 -- dbus-run-session --config-file="$rt/bus.conf" -- "$@"
}
