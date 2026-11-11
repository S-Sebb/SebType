#!/usr/bin/env bash
# Builds SebType's fcitx5-rime RPM (#117) or librime RPMs (#101): Fedora's own source package (sources,
# spec, flags) at the version in versions.sh, plus menu.patch or layout-model.patch, in a pinned Fedora
# container. Prints the RPMs' paths.
#
#   pc/linux/rime/build.sh            # -> ~/.cache/sebtype/fcitx5-rime/fcitx5-rime-<version>-<release>.x86_64.rpm
#   pc/linux/rime/build.sh librime    # -> ~/.cache/sebtype/librime/librime{,-lua,...}-<version>-<release>.x86_64.rpm
#
# One to five minutes, under the shared build lock, with 4 compile jobs and the container capped at
# 6 GB (Decisions #2).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"
pkg=${1:-fcitx5-rime}
case $pkg in
  fcitx5-rime) url=$RIME_SRPM_URL sum=$RIME_SRPM_SHA256 release=$RIME_SEBTYPE_RELEASE patch=menu.patch cache=$RIME_CACHE ;;
  librime) url=$LIBRIME_SRPM_URL sum=$LIBRIME_SRPM_SHA256 release=$LIBRIME_SEBTYPE_RELEASE patch=layout-model.patch cache=$LIBRIME_CACHE ;;
  *) echo "usage: $0 [fcitx5-rime | librime]" >&2; exit 2 ;;
esac
mkdir -p "$cache/work"

srpm=$cache/${url##*/}
if ! sha256sum -c --status <<<"$sum  $srpm" 2>/dev/null; then
  curl -sfL --retry 3 -o "$srpm.part" "$url"
  sha256sum -c --status <<<"$sum  $srpm.part" || { echo "checksum mismatch: $url" >&2; exit 1; }
  mv "$srpm.part" "$srpm"
fi

# Builder image: the pinned Fedora with the package's build dependencies. Built once per pin.
image=localhost/sebtype-rime-builder:$(sha256sum <<<"$RIME_BUILD_IMAGE $sum 1" | head -c 12)
if ! podman image exists "$image"; then
  podman build -q -t "$image" -v "$srpm:/pkg.src.rpm:ro,Z" -f - "$cache" <<EOF >/dev/null
FROM $RIME_BUILD_IMAGE
RUN dnf -y install rpm-build 'dnf5-command(builddep)' && dnf -y builddep /pkg.src.rpm && dnf clean all
EOF
fi

# Inside: Fedora's spec with SebType's release and patch (%autosetup -p1 applies it), built as Fedora does.
inner=$(cat <<'EOF'
set -euo pipefail
pkg=$1 release=$2 patch=$3
rm -rf /work/top && mkdir -p /work/top
rpm -i --define '_topdir /work/top' /srpm.rpm
cp /patch "/work/top/SOURCES/$patch"
sed -e "s/^Release:.*/Release: $release/" -e "s/^Source0\\?:.*/&\nPatch100: $patch/" -e 's/^%autosetup$/%autosetup -p1/' \
  "/work/top/SPECS/$pkg.spec" > "/work/top/$pkg.spec"
rpmbuild -bb --define '_topdir /work/top' --define 'debug_package %{nil}' --define '_smp_build_ncpus 4' \
  "/work/top/$pkg.spec" > /work/build.log 2>&1 || { tail -30 /work/build.log; exit 1; }
EOF
)
devq -w 3600 -m 5 -P "${DEVQ_RANK:-2}" -n "$pkg build" /tmp/agent-locks/sebtype/build.lock \
  podman run --rm --memory 6g --memory-swap 6g -v "$cache/work:/work:Z" -v "$srpm:/srpm.rpm:ro,Z" \
  -v "$here/$patch:/patch:ro,Z" "$image" bash -c "$inner" inner "$pkg" "$release" "$patch"
for rpm in "$cache"/work/top/RPMS/x86_64/*-"$release".x86_64.rpm; do
  cp "$rpm" "$cache/"
  echo "$cache/${rpm##*/}"
done
