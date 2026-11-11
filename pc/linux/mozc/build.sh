#!/usr/bin/env bash
# Builds SebType's fcitx5-mozc RPM (#66): Fedora's own source package (sources, spec, flags) at the
# version in versions.sh, plus caps-lock-icon.patch and menu.patch, in a pinned Fedora container. Prints
# the RPM's path.
#
#   pc/linux/mozc/build.sh    # -> ~/.cache/sebtype/mozc/rpms/fcitx5-mozc-<version>-<release>.x86_64.rpm
#
# The build tree stays in ~/.cache/sebtype/mozc/work, so a rebuild compiles only what changed. Runs under
# the shared build lock, with 4 compile jobs and the container capped at 6 GB (Decisions #2).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"
mkdir -p "$MOZC_CACHE"/{rpms,work}

srpm=$MOZC_CACHE/${MOZC_SRPM_URL##*/}
srpm=${srpm//%5E/^}
if ! sha256sum -c --status <<<"$MOZC_SRPM_SHA256  $srpm" 2>/dev/null; then
  curl -sfL --retry 3 -o "$srpm.part" "$MOZC_SRPM_URL"
  sha256sum -c --status <<<"$MOZC_SRPM_SHA256  $srpm.part" || { echo "checksum mismatch: $MOZC_SRPM_URL" >&2; exit 1; }
  mv "$srpm.part" "$srpm"
fi

# Builder image: the pinned Fedora with the package's build dependencies. Built once per pin.
image=localhost/sebtype-mozc-builder:$(sha256sum <<<"$MOZC_BUILD_IMAGE $MOZC_SRPM_SHA256 1" | head -c 12)
if ! podman image exists "$image"; then
  podman build -q -t "$image" -v "$srpm:/fcitx5-mozc.src.rpm:ro,Z" -f - "$MOZC_CACHE" <<EOF >/dev/null
FROM $MOZC_BUILD_IMAGE
RUN dnf -y install rpm-build rsync 'dnf5-command(builddep)' && dnf -y builddep /fcitx5-mozc.src.rpm && dnf clean all
# build_mozc.py runs ninja with one job per CPU; SebType's builds use 4 (Decisions #2).
RUN printf '#!/bin/sh\nexec /usr/bin/ninja -j4 "\$@"\n' > /usr/local/bin/ninja && chmod +x /usr/local/bin/ninja
EOF
fi

# Inside: Fedora's %prep into a fresh tree, synced into the kept one by content (unchanged files keep
# their times, so ninja skips them); then Fedora's %build and %install on the kept tree, and the RPM.
inner=$(cat <<'EOF'
set -euo pipefail
rel=$1
spec() { # Fedora's spec with our release and patches
  sed -e "s/^Release:.*/Release: $rel/" -e '/^%autochangelog/d' \
    -e 's/^Patch1:/Patch100: caps-lock-icon.patch\nPatch101: menu.patch\n&/' \
    -e 's/^%patch 0 -p1/&\n%patch 100 -p1\n%patch 101 -p1/' "$1"
}
rm -rf /work/fresh && mkdir -p /work/fresh /work/top
rpm -i --define '_topdir /work/fresh' /srpm.rpm
cp /patches/caps-lock-icon.patch /patches/menu.patch /work/fresh/SOURCES/
spec /work/fresh/SPECS/fcitx5-mozc.spec > /work/fresh/fcitx5-mozc.spec
stamp=$(cat /work/fresh/fcitx5-mozc.spec /patches/*.patch /srpm.rpm | sha256sum)
defs=(--define '_topdir /work/top' --define 'debug_package %{nil}')
if [[ $stamp != "$(cat /work/top/prep.stamp 2>/dev/null)" ]]; then
  rpmbuild -bp --nodeps --define '_topdir /work/fresh' /work/fresh/fcitx5-mozc.spec >/work/prep.log 2>&1 ||
    { tail -30 /work/prep.log; exit 1; }
  mkdir -p /work/top/BUILD
  rsync -rlc --delete --exclude=out_linux --exclude=mozc_version.txt \
    /work/fresh/BUILD/ /work/top/BUILD/  # keeps the build output and gyp's version file
  rsync -a --delete /work/fresh/SOURCES/ /work/top/SOURCES/
  cp /work/fresh/fcitx5-mozc.spec /work/top/fcitx5-mozc.spec
  echo "$stamp" > /work/top/prep.stamp
fi
rm -rf /work/fresh
# --noprep and --noclean keep the tree; ninja rebuilds only what changed.
rpmbuild -bb --noprep --noclean --nodeps "${defs[@]}" /work/top/fcitx5-mozc.spec >/work/build.log 2>&1 ||
  { tail -30 /work/build.log; exit 1; }
EOF
)
start=$SECONDS
devq -w 3600 -m 120 -P "${DEVQ_RANK:-2}" -n "fcitx5-mozc build" /tmp/agent-locks/sebtype/build.lock \
  podman run --rm --memory 6g --memory-swap 6g -v "$MOZC_CACHE/work:/work:Z" -v "$srpm:/srpm.rpm:ro,Z" \
  -v "$here:/patches:ro,Z" "$image" bash -c "$inner" inner "$SEBTYPE_RELEASE"
cp "$MOZC_CACHE/work/top/RPMS/x86_64/$MOZC_RPM" "$MOZC_CACHE/rpms/"
echo "built in $((SECONDS - start)) s (logs: $MOZC_CACHE/work/*.log)" >&2
echo "$MOZC_CACHE/rpms/$MOZC_RPM"
