#!/usr/bin/env bash
# Builds SebType's Linux input method RPM (#190): the Fcitx5 add-on over core/ and Mozc's library, with
# sebtype.spec in the pinned Fedora container (versions.sh). Prints the RPM's path, named by a hash of the
# sources it packs (versions.sh's sebtype_key, #326), so each tree's tests find their own code's RPM.
#
#   linux/build.sh    # -> ~/scratch/SebType/cache/sebtype/sebtype-<version>-<release>.<key>.x86_64.rpm
#
# Mozc's Bazel caches stay in ~/scratch/SebType/cache/mozc/work, so a rebuild compiles only what changed. Runs in the shared build lock (tools/lib.sh), the container on the lock's cores and memory.
# The Configurator's crates and the Chinese data's sources (data/rime/build.sh) are cached there too.
# Bazel downloads nothing (#361), as in the phone's Mozc builds (tools/mozc-bazel.sh): mozc_fetch fetches Bazel,
# the registry's files and the archives tools/mozc-downloads.tsv lists, capped, into the phone's builds' cache,
# and the spec runs that Bazel from there with downloads disabled.
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
# shellcheck source-path=SCRIPTDIR source=../tools/mozc-bazel.sh
source "$root/tools/mozc-bazel.sh"
# The build host's copy has no git, so the key goes with it.
key=${SEBTYPE_SOURCES_KEY:-$(sebtype_key)}
# The keyed RPMs no tree used for two weeks (sebtype_unpack touches them); those named by version alone stay.
mkdir -p "$SEBTYPE_CACHE"
find "$SEBTYPE_CACHE" -maxdepth 1 -regextype posix-extended -regex '.*\.[0-9a-f]{12}\.x86_64\.rpm' -mtime +14 -delete
if build_host_ready; then build_remotely "SEBTYPE_SOURCES_KEY=$key" linux/build.sh; exit; fi
# Bazel's caches for Mozc, so a rebuild compiles only what changed.
MOZC_CACHE=$BAZEL_CACHE/mozc
mkdir -p "$MOZC_CACHE/work"
downloads=$BAZEL_CACHE/mozc-android
bazel=$(mozc_fetch "$downloads")
stage=$(rpm_stage)
trap 'rm -rf "$stage"' EXIT
pack_source "$root/$SEBTYPE_MOZC" "$stage/sources/mozc.tar.gz"
# The Rime plugins the add-on's librime builds in (#527, versions.sh)
mkdir -p "$LIBRIME_CACHE/sources"
fetch_lookaside librime "$LIBRIME_CACHE/sources" "${LIBRIME_PLUGIN_SOURCES[@]}"
for ((i = 0; i < ${#LIBRIME_PLUGIN_SOURCES[@]}; i += 2)); do cp "$LIBRIME_CACHE/sources/${LIBRIME_PLUGIN_SOURCES[i]}" "$stage/sources/"; done
octagram=$LIBRIME_CACHE/sources/librime-octagram-$OCTAGRAM_COMMIT.tar.gz
if ! sha256sum -c --status <<<"$OCTAGRAM_SHA256  $octagram" 2>/dev/null; then
  curl --limit-rate 35M -sfL --retry 3 -o "$octagram.part" \
    "https://github.com/lotem/librime-octagram/archive/$OCTAGRAM_COMMIT.tar.gz"
  sha256sum -c --status <<<"$OCTAGRAM_SHA256  $octagram.part" || { echo "checksum mismatch: librime-octagram" >&2; exit 1; }
  mv "$octagram.part" "$octagram"
fi
cp "$octagram" "$stage/sources/librime-octagram.tar.gz"
llama=$("$root/engines/sebtype-lm/fetch-llama.sh")
tar -C "$llama" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --exclude=.git --transform 's,^\.,llama,' -c . |
  gzip -n > "$stage/sources/llama.tar.gz"
tar -C "$root" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --exclude=pc/configurator/target \
  -c "${SEBTYPE_SOURCES[@]}" |
  gzip -n > "$stage/sources/sebtype.tar.gz"

# Builder image: the pinned Fedora with the spec's build dependencies. Built once per pin and spec; dnf's
# downloads capped at 35 MB/s like the others.
image=localhost/sebtype-builder:$(cat "$here/sebtype.spec" - <<<"$BUILD_IMAGE" | sha256sum | head -c 12)
if ! podman image exists "$image"; then
  # --no-cache: the spec is mounted, not copied, so a cached layer of another spec would match.
  podman build -q --no-cache -t "$image" -v "$here/sebtype.spec:/pkg.spec:ro,Z" -f - "$SEBTYPE_CACHE" <<EOF2 >/dev/null
FROM $BUILD_IMAGE
RUN dnf -y --setopt=throttle=35M install rpm-build 'dnf5-command(builddep)' && \
  dnf -y --setopt=throttle=35M builddep -D 'sebtype_version 0' -D 'sebtype_release 0' /pkg.spec && dnf clean all
EOF2
fi

inner=$(cat <<'EOF2'
set -euo pipefail
rm -rf /work/sebtype-top
rpmbuild -bb --define '_topdir /work/sebtype-top' --define '_sourcedir /sources' --define "sebtype_version $1" \
  --define "sebtype_release $2" --define 'debug_package %{nil}' --define "_smp_build_ncpus $3" \
  --define 'bazel_root /work/bazel' --define "bazel $4" --define "mozc_downloads $5" --define 'cache_root /work' /pkg.spec > /work/sebtype-build.log 2>&1 || { tail -30 /work/sebtype-build.log; exit 1; }
cp /work/sebtype-top/RPMS/x86_64/*.rpm /out/
EOF2
)
start=$SECONDS
build_lock 120 "sebtype build" \
  podman run --rm --cpus "$BUILD_JOBS" --memory "${BUILD_MEMORY_GB}g" --memory-swap "${BUILD_MEMORY_GB}g" -v "$MOZC_CACHE/work:/work:Z" \
  -v "$downloads:$downloads:z" \
  -v "$stage/sources:/sources:ro,Z" -v "$stage/rpms:/out:Z" -v "$here/sebtype.spec:/pkg.spec:ro,Z" "$image" \
  bash -c "$inner" inner "$SEBTYPE_VERSION" "$SEBTYPE_RPM_RELEASE" "$BUILD_JOBS" "$bazel" "$downloads"
rpm=$(sebtype_rpm "$key")
cp "$stage/rpms/$SEBTYPE_RPM" "$rpm.$$.part" && mv -f "$rpm.$$.part" "$rpm"  # per build: two trees with the same sources may publish at once
echo "built in $((SECONDS - start)) s (logs: $MOZC_CACHE/work/sebtype-build.log)" >&2
echo "$rpm"
