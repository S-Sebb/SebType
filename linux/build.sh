#!/usr/bin/env bash
# Builds SebType's Linux input method RPM (#190): the Fcitx5 add-on over core/ and Mozc's library, with
# sebtype.spec in the pinned Fedora container (versions.sh). Prints the RPM's path, named by a hash of the
# sources it packs (versions.sh's sebtype_key, #326), so each tree's tests find their own code's RPM.
#
#   linux/build.sh    # -> ~/scratch/SebType/cache/sebtype/sebtype-<version>-<release>.<key>.x86_64.rpm
#
# Mozc's Bazel caches stay in ~/scratch/SebType/cache/mozc/work, so a rebuild compiles only what changed. Runs in the shared build lock (tools/lib.sh), the container on the lock's cores and memory.
# Runs on yanglab16 when it answers (tools/lib.sh, #225; SEBTYPE_BUILD_HOST=local builds here) and copies
# the RPM back to the same path here.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$here/..
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"
# shellcheck source-path=SCRIPTDIR source=rpm-sources.sh
source "$here/rpm-sources.sh"
# shellcheck source-path=SCRIPTDIR source=../tools/lib.sh
source "$root/tools/lib.sh"
# The build host's copy has no git, so the key goes with it.
key=${SEBTYPE_SOURCES_KEY:-$(sebtype_key)}
# The keyed RPMs no tree used for two weeks (sebtype_unpack touches them); those named by version alone stay.
mkdir -p "$SEBTYPE_CACHE"
find "$SEBTYPE_CACHE" -maxdepth 1 -regextype posix-extended -regex '.*\.[0-9a-f]{12}\.x86_64\.rpm' -mtime +14 -delete
if build_host_ready; then build_remotely "SEBTYPE_SOURCES_KEY=$key" linux/build.sh; exit; fi
# Bazel's caches for Mozc, so a rebuild compiles only what changed.
MOZC_CACHE=$BAZEL_CACHE/mozc
mkdir -p "$MOZC_CACHE/work"
stage=$(rpm_stage)
trap 'rm -rf "$stage"' EXIT
pack_source "$root/$SEBTYPE_MOZC" "$stage/sources/mozc.tar.gz"
tar -C "$root" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -c "${SEBTYPE_SOURCES[@]}" |
  gzip -n > "$stage/sources/sebtype.tar.gz"

# Builder image: the pinned Fedora with the spec's build dependencies and Bazelisk. Built once per pin and spec.
image=localhost/sebtype-builder:$(cat "$here/sebtype.spec" - <<<"$BUILD_IMAGE $BAZELISK_SHA256" | sha256sum | head -c 12)
if ! podman image exists "$image"; then
  # --no-cache: the spec is mounted, not copied, so a cached layer of another spec would match.
  podman build -q --no-cache -t "$image" -v "$here/sebtype.spec:/pkg.spec:ro,Z" -f - "$SEBTYPE_CACHE" <<EOF2 >/dev/null
FROM $BUILD_IMAGE
RUN dnf -y install rpm-build 'dnf5-command(builddep)' && \
  dnf -y builddep -D 'sebtype_version 0' -D 'sebtype_release 0' /pkg.spec && dnf clean all && \
  curl -sfL --retry 3 -o /usr/local/bin/bazel $BAZELISK_URL && \
  echo '$BAZELISK_SHA256  /usr/local/bin/bazel' | sha256sum -c --status && chmod +x /usr/local/bin/bazel
EOF2
fi

inner=$(cat <<'EOF2'
set -euo pipefail
rm -rf /work/sebtype-top
rpmbuild -bb --define '_topdir /work/sebtype-top' --define '_sourcedir /sources' --define "sebtype_version $1" \
  --define "sebtype_release $2" --define 'debug_package %{nil}' --define "_smp_build_ncpus $3" \
  --define 'bazel_root /work/bazel' /pkg.spec > /work/sebtype-build.log 2>&1 || { tail -30 /work/sebtype-build.log; exit 1; }
cp /work/sebtype-top/RPMS/x86_64/*.rpm /out/
EOF2
)
start=$SECONDS
build_lock 120 "sebtype build" \
  podman run --rm --cpus "$BUILD_JOBS" --memory "${BUILD_MEMORY_GB}g" --memory-swap "${BUILD_MEMORY_GB}g" -e BAZELISK_HOME=/work/bazelisk -v "$MOZC_CACHE/work:/work:Z" \
  -v "$stage/sources:/sources:ro,Z" -v "$stage/rpms:/out:Z" -v "$here/sebtype.spec:/pkg.spec:ro,Z" "$image" \
  bash -c "$inner" inner "$SEBTYPE_VERSION" "$SEBTYPE_RPM_RELEASE" "$BUILD_JOBS"
rpm=$(sebtype_rpm "$key")
cp "$stage/rpms/$SEBTYPE_RPM" "$rpm.$$.part" && mv -f "$rpm.$$.part" "$rpm"  # per build: two trees with the same sources may publish at once
echo "built in $((SECONDS - start)) s (logs: $MOZC_CACHE/work/sebtype-build.log)" >&2
echo "$rpm"
