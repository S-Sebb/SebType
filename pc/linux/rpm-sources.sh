# shellcheck shell=bash
# The sources of SebType's RPMs. Sourced by mozc/build.sh and rime/build.sh.

# fetch_lookaside <Fedora package> <dir> <file> <sha512> [<file> <sha512>]...
# The third-party sources SebType doesn't change, as Fedora's package has them: Fedora's lookaside cache
# keeps every source it ever built with, addressed by checksum.
fetch_lookaside() {
  local pkg=$1 dir=$2 f sum
  shift 2
  while (($#)); do
    f=$1 sum=$2
    shift 2
    sha512sum -c --status <<<"$sum  $dir/$f" 2>/dev/null && continue
    curl -sfL --retry 3 -o "$dir/$f.part" "https://src.fedoraproject.org/repo/pkgs/rpms/$pkg/$f/sha512/$sum/$f"
    sha512sum -c --status <<<"$sum  $dir/$f.part" || { echo "checksum mismatch: $pkg/$f" >&2; return 1; }
    mv "$dir/$f.part" "$dir/$f"
  done
}

# pack_source <dir> <tarball>: SebType's source tree <dir> (pc/<name>) as <name>/ in a .tar.gz, the
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
RUN dnf -y install rpm-build 'dnf5-command(builddep)' && \\
  dnf -y builddep -D 'sebtype_version 0' -D 'sebtype_release 0' /pkg.spec && dnf clean all && \\
  $check$extra
EOF
}
