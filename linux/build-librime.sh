#!/usr/bin/env bash
# Builds SebType's librime RPMs (#101): engines/librime with librime.spec (Fedora's spec), which also builds
# the plugins from Fedora's own copies, in the pinned Fedora container. Prints the RPMs' paths.
#
#   linux/build-librime.sh    # -> ~/scratch/SebType/cache/librime/librime{,-lua,...}-<version>-<release>.x86_64.rpm
#
# One to five minutes, in the shared build lock (tools/lib.sh), the container on the lock's cores and memory.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"
# shellcheck source-path=SCRIPTDIR source=rpm-sources.sh
source "$here/rpm-sources.sh"
# shellcheck source-path=SCRIPTDIR source=../tools/lib.sh
source "$here/../tools/lib.sh"
spec=$here/librime.spec cache=$LIBRIME_CACHE
mkdir -p "$cache"/{work,sources}
fetch_lookaside librime "$cache/sources" "${LIBRIME_SOURCES[@]}"
pack_source "$here/../engines/librime" "$cache/sources/librime.tar.gz"

# Builder image: the pinned Fedora with the spec's build dependencies. Built once per pin and spec.
image=localhost/sebtype-rime-builder:$(cat "$spec" - <<<"$BUILD_IMAGE 2" | sha256sum | head -c 12)
builder_image "$image" "$BUILD_IMAGE" "$spec" "$cache"

inner=$(cat <<'EOF'
set -euo pipefail
rm -rf /work/top
rpmbuild -bb --define '_topdir /work/top' --define '_sourcedir /sources' --define "sebtype_version $1" \
  --define "sebtype_release $2" --define 'debug_package %{nil}' --define "_smp_build_ncpus $3" \
  /pkg.spec > /work/build.log 2>&1 || { tail -30 /work/build.log; exit 1; }
EOF
)
build_lock 5 "librime build" \
  podman run --rm --memory "${BUILD_MEMORY_GB}g" --memory-swap "${BUILD_MEMORY_GB}g" -v "$cache/work:/work:Z" -v "$cache/sources:/sources:ro,Z" \
  -v "$spec:/pkg.spec:ro,Z" "$image" bash -c "$inner" inner "$LIBRIME_VERSION" "$LIBRIME_SEBTYPE_RELEASE" "$BUILD_JOBS"
for rpm in "$cache"/work/top/RPMS/*/*-"$LIBRIME_SEBTYPE_RELEASE".*.rpm; do
  cp "$rpm" "$cache/"
  echo "$cache/${rpm##*/}"
done
