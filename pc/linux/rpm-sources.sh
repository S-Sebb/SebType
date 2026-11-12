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
