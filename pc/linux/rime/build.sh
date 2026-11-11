#!/usr/bin/env bash
# Builds SebType's fcitx5-rime RPM (#117): Fedora's own source package (sources, spec, flags) at the
# version in versions.sh, plus menu.patch, in a pinned Fedora container. Prints the RPM's path.
#
#   pc/linux/rime/build.sh    # -> ~/.cache/sebtype/fcitx5-rime/fcitx5-rime-<version>-<release>.x86_64.rpm
#
# About a minute, under the shared build lock, with 4 compile jobs and the container capped at 6 GB
# (Decisions #2).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"
mkdir -p "$RIME_CACHE/work"

srpm=$RIME_CACHE/${RIME_SRPM_URL##*/}
if ! sha256sum -c --status <<<"$RIME_SRPM_SHA256  $srpm" 2>/dev/null; then
  curl -sfL --retry 3 -o "$srpm.part" "$RIME_SRPM_URL"
  sha256sum -c --status <<<"$RIME_SRPM_SHA256  $srpm.part" || { echo "checksum mismatch: $RIME_SRPM_URL" >&2; exit 1; }
  mv "$srpm.part" "$srpm"
fi

# Builder image: the pinned Fedora with the package's build dependencies. Built once per pin.
image=localhost/sebtype-rime-builder:$(sha256sum <<<"$RIME_BUILD_IMAGE $RIME_SRPM_SHA256 1" | head -c 12)
if ! podman image exists "$image"; then
  podman build -q -t "$image" -v "$srpm:/fcitx5-rime.src.rpm:ro,Z" -f - "$RIME_CACHE" <<EOF >/dev/null
FROM $RIME_BUILD_IMAGE
RUN dnf -y install rpm-build 'dnf5-command(builddep)' && dnf -y builddep /fcitx5-rime.src.rpm && dnf clean all
EOF
fi

# Inside: Fedora's spec with SebType's release and patch (%autosetup applies it), built as Fedora does.
inner=$(cat <<'EOF'
set -euo pipefail
rm -rf /work/top && mkdir -p /work/top
rpm -i --define '_topdir /work/top' /srpm.rpm
cp /patch /work/top/SOURCES/menu.patch
sed -e "s/^Release:.*/Release: $1/" -e 's/^Source2:.*/&\nPatch0: menu.patch/' -e 's/^%autosetup$/%autosetup -p1/' \
  /work/top/SPECS/fcitx5-rime.spec > /work/top/fcitx5-rime.spec
rpmbuild -bb --define '_topdir /work/top' --define 'debug_package %{nil}' --define '_smp_build_ncpus 4' \
  /work/top/fcitx5-rime.spec > /work/build.log 2>&1 || { tail -30 /work/build.log; exit 1; }
EOF
)
devq -w 3600 -m 5 -P "${DEVQ_RANK:-2}" -n "fcitx5-rime build" /tmp/agent-locks/sebtype/build.lock \
  podman run --rm --memory 6g --memory-swap 6g -v "$RIME_CACHE/work:/work:Z" -v "$srpm:/srpm.rpm:ro,Z" \
  -v "$here/menu.patch:/patch:ro,Z" "$image" bash -c "$inner" inner "$RIME_SEBTYPE_RELEASE"
cp "$RIME_CACHE/work/top/RPMS/x86_64/$RIME_RPM" "$RIME_CACHE/"
echo "$RIME_CACHE/$RIME_RPM"
