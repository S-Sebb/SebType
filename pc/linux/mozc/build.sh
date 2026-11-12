#!/usr/bin/env bash
# Builds SebType's fcitx5-mozc RPM (#66): pc/fcitx5-mozc with fcitx5-mozc.spec, as Fedora builds its
# package, in a pinned Fedora container. Prints the RPM's path.
#
#   pc/linux/mozc/build.sh    # -> ~/.cache/sebtype/mozc/rpms/fcitx5-mozc-<version>-<release>.x86_64.rpm
#
# The build tree stays in ~/.cache/sebtype/mozc/work, so a rebuild compiles only what changed. Runs under
# the shared build lock, with 4 compile jobs and the container capped at 6 GB (Decisions #2).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"
# shellcheck source-path=SCRIPTDIR source=../rpm-sources.sh
source "$here/../rpm-sources.sh"
mkdir -p "$MOZC_CACHE"/{rpms,work,sources}
fetch_lookaside fcitx5-mozc "$MOZC_CACHE/sources" "${MOZC_SOURCES[@]}"
pack_source "$here/../../fcitx5-mozc" "$MOZC_CACHE/sources/fcitx5-mozc.tar.gz"

# Builder image: the pinned Fedora with the spec's build dependencies. Built once per pin and spec.
image=localhost/sebtype-mozc-builder:$(cat "$here/fcitx5-mozc.spec" - <<<"$MOZC_BUILD_IMAGE 2" | sha256sum | head -c 12)
if ! podman image exists "$image"; then
  podman build -q -t "$image" -v "$here/fcitx5-mozc.spec:/pkg.spec:ro,Z" -f - "$MOZC_CACHE" <<EOF >/dev/null
FROM $MOZC_BUILD_IMAGE
RUN dnf -y install rpm-build rsync 'dnf5-command(builddep)' && \
  dnf -y builddep -D 'sebtype_version 0' -D 'sebtype_release 0' /pkg.spec && dnf clean all
# build_mozc.py runs ninja with one job per CPU; SebType's builds use 4 (Decisions #2).
RUN printf '#!/bin/sh\nexec /usr/bin/ninja -j4 "\$@"\n' > /usr/local/bin/ninja && chmod +x /usr/local/bin/ninja
EOF
fi

# Inside: %prep into a fresh tree, synced into the kept one by content (unchanged files keep their
# times, so ninja skips them); then %build and %install on the kept tree, and the RPM.
inner=$(cat <<'EOF'
set -euo pipefail
defs=(--define "sebtype_version $1" --define "sebtype_release $2" --define '_sourcedir /sources'
  --define 'debug_package %{nil}')
stamp=$(cat /pkg.spec /sources/* - <<<"$*" | sha256sum)
mkdir -p /work/top
if [[ $stamp != "$(cat /work/top/prep.stamp 2>/dev/null)" ]]; then
  rm -rf /work/fresh
  rpmbuild -bp --nodeps "${defs[@]}" --define '_topdir /work/fresh' /pkg.spec >/work/prep.log 2>&1 ||
    { tail -30 /work/prep.log; exit 1; }
  mkdir -p /work/top/BUILD
  rsync -rlc --delete --exclude=out_linux --exclude=mozc_version.txt \
    /work/fresh/BUILD/ /work/top/BUILD/  # keeps the build output and gyp's version file
  rm -rf /work/fresh
  echo "$stamp" > /work/top/prep.stamp
fi
# --noprep and --noclean keep the tree; ninja rebuilds only what changed.
rpmbuild -bb --noprep --noclean --nodeps "${defs[@]}" --define '_topdir /work/top' /pkg.spec >/work/build.log 2>&1 ||
  { tail -30 /work/build.log; exit 1; }
EOF
)
start=$SECONDS
devq -w 3600 -m 120 -P "${DEVQ_RANK:-2}" -n "fcitx5-mozc build" /tmp/agent-locks/sebtype/build.lock \
  podman run --rm --memory 6g --memory-swap 6g -v "$MOZC_CACHE/work:/work:Z" -v "$MOZC_CACHE/sources:/sources:ro,Z" \
  -v "$here/fcitx5-mozc.spec:/pkg.spec:ro,Z" "$image" bash -c "$inner" inner "$MOZC_VERSION" "$SEBTYPE_RELEASE"
cp "$MOZC_CACHE/work/top/RPMS/x86_64/$MOZC_RPM" "$MOZC_CACHE/rpms/"
echo "built in $((SECONDS - start)) s (logs: $MOZC_CACHE/work/*.log)" >&2
echo "$MOZC_CACHE/rpms/$MOZC_RPM"
