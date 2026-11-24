# shellcheck shell=bash
# The sources of SebType's RPMs. Sourced by build.sh and build-librime.sh.

# fetch_lookaside <Fedora package> <dir> <file> <sha512> [<file> <sha512>]...
# The third-party sources SebType doesn't change, as Fedora's package has them: Fedora's lookaside cache
# keeps every source it ever built with, addressed by checksum.
fetch_lookaside() {
  local pkg=$1 dir=$2 f sum
  shift 2
  while (($#)); do
    f=$1 sum=$2
    shift 2
    sha512sum -c --status <<<"$sum  $dir/$f" &>/dev/null && continue # a missing file says so on stdout
    # Its own .part: two builds that start on a cold cache don't write into one file.
    curl --limit-rate 35M -sSfL --retry 3 -o "$dir/$f.part.$$" "https://src.fedoraproject.org/repo/pkgs/rpms/$pkg/$f/sha512/$sum/$f" ||
      { rm -f "$dir/$f.part.$$"; return 1; }
    sha512sum -c --status <<<"$sum  $dir/$f.part.$$" || { rm -f "$dir/$f.part.$$"; echo "checksum mismatch: $pkg/$f" >&2; return 1; }
    mv "$dir/$f.part.$$" "$dir/$f"
  done
}

# fetch_pinned <name> <url> <sha256> <dir>: a source pinned by checksum, cached in LIBRIME_CACHE, into <dir>
# as <name>.tar.gz.
fetch_pinned() {
  local f=$LIBRIME_CACHE/sources/$1-${3:0:12}.tar.gz
  mkdir -p "$LIBRIME_CACHE/sources"
  if ! sha256sum -c --status <<<"$3  $f" &>/dev/null; then # a missing file says so on stdout
    curl --limit-rate 35M -sSfL --retry 3 -o "$f.part.$$" "$2" || { rm -f "$f.part.$$"; return 1; }
    sha256sum -c --status <<<"$3  $f.part.$$" &>/dev/null || { rm -f "$f.part.$$"; echo "checksum mismatch: $1" >&2; return 1; }
    mv "$f.part.$$" "$f"
  fi
  cp "$f" "$4/$1.tar.gz"
}

# fetch_octagram <dir>: librime-octagram at versions.sh's OCTAGRAM_COMMIT.
fetch_octagram() {
  fetch_pinned librime-octagram "https://github.com/lotem/librime-octagram/archive/$OCTAGRAM_COMMIT.tar.gz" "$OCTAGRAM_SHA256" "$1"
}

# rpm_stage: prints a new folder for one build, in its task folder (TASK_OUT, tools/lib.sh): sources/ for
# the sources it packs, rpms/ for the RPMs it copies out of the shared work folder while it holds the build
# lock. A build from another checkout that starts meanwhile can't swap them for its own (#305), as it could
# in the shared cache. The caller removes it.
rpm_stage() {
  local stage
  mkdir -p "$TASK_OUT"
  stage=$(mktemp -d "$TASK_OUT/rpm-build.XXXXXX")
  mkdir "$stage"/{sources,rpms}
  echo "$stage"
}

# pack_source <dir> <tarball>: SebType's source tree <dir> (engines/<name>) as <name>/ in a .tar.gz, the
# same bytes for the same files, so a build that compares sources sees no change.
pack_source() {
  tar -C "$(dirname "$1")" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -c "$(basename "$1")" |
    gzip -n >"$2.part"
  mv "$2.part" "$2"
}

# builder_image <image> <base> <spec> <context> [<command>]: makes sure the builder image <image> exists:
# <base> with rpm-build, <spec>'s build dependencies and anything <command> adds. dnf builddep once left
# an image without them and it stayed tagged (#193), so the build checks them before tagging and a
# reused image is checked again. The check compares names only: rpm -q --whatprovides ignores versions.
# --no-cache, as podman's layer cache doesn't see the mounted spec and would reuse another spec's layer.
builder_image() {
  local image=$1 base=$2 spec=$3 context=$4 extra=${5:+" && $5"}
  local check="rpmspec -q --buildrequires -D 'sebtype_version 0' -D 'sebtype_release 0' /pkg.spec | \
    sed 's/ .*//' | xargs -d '\n' rpm -q --whatprovides | { ! grep '^no package provides'; } >&2"
  if podman image exists "$image"; then
    podman run --rm -v "$spec:/pkg.spec:ro,Z" "$image" bash -c "$check" && return
    echo "rebuilding $image: build dependencies missing" >&2
  fi
  podman build -q --no-cache -t "$image" -v "$spec:/pkg.spec:ro,Z" -f - "$context" <<EOF >/dev/null
FROM $base
RUN dnf -y --setopt=throttle=35M install rpm-build 'dnf5-command(builddep)' && \\
  dnf -y --setopt=throttle=35M builddep -D 'sebtype_version 0' -D 'sebtype_release 0' /pkg.spec && dnf clean all && \\
  $check$extra
EOF
}
