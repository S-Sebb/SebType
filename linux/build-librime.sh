#!/usr/bin/env bash
# Builds SebType's librime RPMs (#101): engines/librime with librime.spec (Fedora's spec), which also builds
# the plugins (Fedora's own copies, octagram at versions.sh's OCTAGRAM_COMMIT), in the pinned Fedora
# container. Prints the RPMs' paths, in a folder named by versions.sh's librime_key.
#
#   linux/build-librime.sh    # -> ~/scratch/SebType/cache/librime/<key>/librime{,-lua,...}-<version>-<release>.x86_64.rpm
#
# One to five minutes, in the shared build lock (tools/lib.sh), the container on the lock's cores and memory.
# Runs on yanglab16 when it answers (tools/lib.sh, #225) and copies the RPMs back to the same paths here.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"
# shellcheck source-path=SCRIPTDIR source=rpm-sources.sh
source "$here/rpm-sources.sh"
# shellcheck source-path=SCRIPTDIR source=../tools/lib.sh
source "$here/../tools/lib.sh"
if build_host_ready; then build_remotely linux/build-librime.sh; exit; fi
key=$(librime_key)
spec=$here/librime.spec cache=$LIBRIME_CACHE
# rpmbuild's work folder, where Bazel's are (BAZEL_CACHE): on yanglab16 the container's root can't chown
# what it unpacks on the NAS.
work=$BAZEL_CACHE/librime/work
mkdir -p "$cache/sources" "$work"
stage=$(rpm_stage)
trap 'rm -rf "$stage"' EXIT
fetch_lookaside librime "$cache/sources" "${LIBRIME_SOURCES[@]}"
for ((i = 0; i < ${#LIBRIME_SOURCES[@]}; i += 2)); do cp "$cache/sources/${LIBRIME_SOURCES[i]}" "$stage/sources/"; done
fetch_octagram "$stage/sources"
pack_source "$here/../engines/librime" "$stage/sources/librime.tar.gz"

# Builder image: the pinned Fedora with the spec's build dependencies. Built once per pin and spec.
image=localhost/sebtype-rime-builder:$(cat "$spec" - <<<"$BUILD_IMAGE 2" | sha256sum | head -c 12)
builder_image "$image" "$BUILD_IMAGE" "$spec" "$cache"

inner=$(cat <<'EOF'
set -euo pipefail
rm -rf /work/top
rpmbuild -bb --define '_topdir /work/top' --define '_sourcedir /sources' --define "sebtype_version $1" \
  --define "sebtype_release $2" --define 'debug_package %{nil}' --define "_smp_build_ncpus $3" \
  /pkg.spec > /work/build.log 2>&1 || { tail -30 /work/build.log; exit 1; }
cp /work/top/RPMS/*/*.rpm /out/
EOF
)
build_lock 5 "librime build" \
  podman run --rm --cpus "$BUILD_JOBS" --memory "${BUILD_MEMORY_GB}g" --memory-swap "${BUILD_MEMORY_GB}g" -v "$work:/work:Z" -v "$stage/sources:/sources:ro,Z" \
  -v "$stage/rpms:/out:Z" -v "$spec:/pkg.spec:ro,Z" "$image" bash -c "$inner" inner "$LIBRIME_VERSION" "$LIBRIME_SEBTYPE_RELEASE" "$BUILD_JOBS"
# The key's folder appears whole; one another build of the same key made first stays (the same code).
find "$cache" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9a-f]{12}' -mtime +14 -exec rm -rf {} +
tmp=$(mktemp -d "$cache/.$key.XXXXXX")
cp "$stage"/rpms/*-"$LIBRIME_SEBTYPE_RELEASE".*.rpm "$tmp/"
mv -T "$tmp" "$cache/$key" 2>/dev/null || rm -rf "$tmp"
for rpm in "$cache/$key"/*.rpm; do echo "$rpm"; done
