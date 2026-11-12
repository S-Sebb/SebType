#!/usr/bin/env bash
# Builds SebType's fcitx5-mozc RPM (#66): engines/mozc with fcitx5-mozc.spec, as Fedora builds its package,
# in a pinned Fedora container. Prints the RPM's path.
#
#   pc/linux/mozc/build.sh    # -> ~/.cache/sebtype/mozc/rpms/fcitx5-mozc-<version>-<release>.x86_64.rpm
#
# Bazel's caches stay in ~/.cache/sebtype/mozc/work, so a rebuild compiles only what changed. Runs in the
# shared build lock (tools/lib.sh), the container on the lock's cores and memory.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"
# shellcheck source-path=SCRIPTDIR source=../rpm-sources.sh
source "$here/../rpm-sources.sh"
# shellcheck source=../../../tools/lib.sh
source "$here/../../../tools/lib.sh"
mkdir -p "$MOZC_CACHE"/{rpms,work,sources}
pack_source "$here/../../../engines/mozc" "$MOZC_CACHE/sources/mozc.tar.gz"

# Builder image: the pinned Fedora with the spec's build dependencies and Bazelisk. Built once per pin and spec.
image=localhost/sebtype-mozc-builder:$(cat "$here/fcitx5-mozc.spec" - <<<"$MOZC_BUILD_IMAGE $BAZELISK_SHA256" | sha256sum | head -c 12)
if ! podman image exists "$image"; then
  podman build -q -t "$image" -v "$here/fcitx5-mozc.spec:/pkg.spec:ro,Z" -f - "$MOZC_CACHE" <<EOF2 >/dev/null
FROM $MOZC_BUILD_IMAGE
RUN dnf -y install rpm-build 'dnf5-command(builddep)' && \
  dnf -y builddep -D 'sebtype_version 0' -D 'sebtype_release 0' /pkg.spec && dnf clean all && \
  curl -sfL --retry 3 -o /usr/local/bin/bazel $BAZELISK_URL && \
  echo '$BAZELISK_SHA256  /usr/local/bin/bazel' | sha256sum -c --status && chmod +x /usr/local/bin/bazel
EOF2
fi

inner=$(cat <<'EOF2'
set -euo pipefail
rm -rf /work/top
rpmbuild -bb --define '_topdir /work/top' --define '_sourcedir /sources' --define "sebtype_version $1" \
  --define "sebtype_release $2" --define 'debug_package %{nil}' --define "_smp_build_ncpus $3" \
  --define 'bazel_root /work/bazel' /pkg.spec > /work/build.log 2>&1 || { tail -30 /work/build.log; exit 1; }
EOF2
)
start=$SECONDS
build_lock 120 "fcitx5-mozc build" \
  podman run --rm --memory "${BUILD_MEMORY_GB}g" --memory-swap "${BUILD_MEMORY_GB}g" -e BAZELISK_HOME=/work/bazelisk -v "$MOZC_CACHE/work:/work:Z" \
  -v "$MOZC_CACHE/sources:/sources:ro,Z" -v "$here/fcitx5-mozc.spec:/pkg.spec:ro,Z" "$image" \
  bash -c "$inner" inner "$MOZC_VERSION" "$SEBTYPE_RELEASE" "$BUILD_JOBS"
cp "$MOZC_CACHE/work/top/RPMS/x86_64/$MOZC_RPM" "$MOZC_CACHE/rpms/"
echo "built in $((SECONDS - start)) s (logs: $MOZC_CACHE/work/build.log)" >&2
echo "$MOZC_CACHE/rpms/$MOZC_RPM"
