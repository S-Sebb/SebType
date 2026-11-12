#!/usr/bin/env bash
# Builds SebType's fcitx5-rime RPM (#117), librime RPMs (#101) or Fcitx5 RPMs (#182): pc/fcitx5-rime,
# pc/librime or pc/fcitx5 with fcitx5-rime.spec, librime.spec or fcitx5.spec, as Fedora builds its
# packages, in a pinned Fedora container. Prints the RPMs' paths.
#
#   pc/linux/rime/build.sh            # -> ~/.cache/sebtype/fcitx5-rime/fcitx5-rime-<version>-<release>.x86_64.rpm
#   pc/linux/rime/build.sh librime    # -> ~/.cache/sebtype/librime/librime{,-lua,...}-<version>-<release>.x86_64.rpm
#   pc/linux/rime/build.sh fcitx5     # -> ~/.cache/sebtype/fcitx5/fcitx5{,-libs,...}-<version>-<release>.<arch>.rpm
#
# One to five minutes, under the shared build lock, with 4 compile jobs and the container capped at
# 6 GB (Decisions #2).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"
# shellcheck source-path=SCRIPTDIR source=../rpm-sources.sh
source "$here/../rpm-sources.sh"
pkg=${1:-fcitx5-rime}
case $pkg in
  fcitx5-rime) version=$RIME_VERSION release=$RIME_SEBTYPE_RELEASE cache=$RIME_CACHE sources=() ;;
  librime) version=$LIBRIME_VERSION release=$LIBRIME_SEBTYPE_RELEASE cache=$LIBRIME_CACHE sources=("${LIBRIME_SOURCES[@]}") ;;
  fcitx5) version=$FCITX5_VERSION release=$FCITX5_SEBTYPE_RELEASE cache=$FCITX5_CACHE sources=() ;;
  *) echo "usage: $0 [fcitx5-rime | librime | fcitx5]" >&2; exit 2 ;;
esac
spec=$here/$pkg.spec
mkdir -p "$cache"/{work,sources}
fetch_lookaside "$pkg" "$cache/sources" "${sources[@]}"
pack_source "$here/../../$pkg" "$cache/sources/$pkg.tar.gz"
[[ $pkg != fcitx5 ]] || cp "$here/fcitx5-xinput" "$here/fcitx5.sh" "$cache/sources/"

# Builder image: the pinned Fedora with the spec's build dependencies. Built once per pin and spec;
# --no-cache, as podman's layer cache doesn't see the mounted spec and would reuse another spec's image.
image=localhost/sebtype-rime-builder:$(cat "$spec" - <<<"$RIME_BUILD_IMAGE 2" | sha256sum | head -c 12)
if ! podman image exists "$image"; then
  podman build -q --no-cache -t "$image" -v "$spec:/pkg.spec:ro,Z" -f - "$cache" <<EOF >/dev/null
FROM $RIME_BUILD_IMAGE
RUN dnf -y install rpm-build 'dnf5-command(builddep)' && \
  dnf -y builddep -D 'sebtype_version 0' -D 'sebtype_release 0' /pkg.spec && dnf clean all
EOF
fi

inner=$(cat <<'EOF'
set -euo pipefail
rm -rf /work/top
rpmbuild -bb --define '_topdir /work/top' --define '_sourcedir /sources' --define "sebtype_version $1" \
  --define "sebtype_release $2" --define 'debug_package %{nil}' --define '_smp_build_ncpus 4' \
  /pkg.spec > /work/build.log 2>&1 || { tail -30 /work/build.log; exit 1; }
EOF
)
devq -w 3600 -m 5 -P "${DEVQ_RANK:-2}" -n "$pkg build" /tmp/agent-locks/sebtype/build.lock \
  podman run --rm --memory 6g --memory-swap 6g -v "$cache/work:/work:Z" -v "$cache/sources:/sources:ro,Z" \
  -v "$spec:/pkg.spec:ro,Z" "$image" bash -c "$inner" inner "$version" "$release"
for rpm in "$cache"/work/top/RPMS/*/*-"$release".*.rpm; do
  cp "$rpm" "$cache/"
  echo "$cache/${rpm##*/}"
done
