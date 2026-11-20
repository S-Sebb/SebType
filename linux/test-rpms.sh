#!/usr/bin/env bash
# shellcheck disable=SC2329  # the checks run through check()
# Tests a release's Linux RPMs (#421) as the Configurator's update installs them (#422), in a fresh pinned
# Fedora (versions.sh) whose librime is Fedora's, with librime-tools: the update command replaces every
# librime package, SebType's version is VERSION's, every installed file is the package's, the files setup's
# user part copies are this checkout's, and every library finds what it links.
#
#   linux/test-rpms.sh DIR   # DIR: sebtype-*.rpm and SebType's librime*.rpm (CI's artifact sebtype-rpm)
#
# One line per check; logs in ~/scratch/SebType/<task>/test-rpms/. Exits 0 only when all pass.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"

if [[ ${1-} != --inside ]]; then
  # shellcheck source-path=SCRIPTDIR source=../tools/lib.sh
  source "$here/../tools/lib.sh"
  dir=$(readlink -f "${1:?usage: linux/test-rpms.sh DIR}")
  command -v podman >/dev/null || { echo "preflight: podman missing"; exit 1; }
  for f in "$SEBTYPE_RPM" "${LIBRIME_PACKAGES[@]/%/-$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE.x86_64.rpm}"; do
    [[ -f $dir/$f ]] || { echo "preflight: $dir/$f missing"; exit 1; }
  done
  log=$TASK_OUT/test-rpms; rm -rf "$log"; mkdir -p "$log"
  exec podman run --rm -v "$dir:/rpms:ro,z" -v "$here/..:/src:ro,z" -v "$log:/log:z" "$BUILD_IMAGE" \
    bash /src/linux/test-rpms.sh --inside
fi

failed=0
check() { # name function...: each within 15 minutes (timeout can't run a function)
  local name=$1 pid watch rc; shift
  "$@" > "/log/$name.log" 2>&1 & pid=$!
  { sleep 900; kill "$pid"; } 2>/dev/null & watch=$!
  wait "$pid"; rc=$?
  kill "$watch" 2>/dev/null
  if ((rc == 0)); then echo "PASS $name"
  else echo "FAIL $name: see test-rpms/$name.log"; failed=1; fi
}
ours=$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE
rpms=/rpms

dnf -y -q --setopt=throttle=35M install fcitx5 librime librime-lua librime-octagram librime-tools > /log/before.log 2>&1 ||
  { echo "preflight: Fedora's fcitx5 and librime don't install (see test-rpms/before.log)"; exit 1; }

# The update's command, as #423 gives it to the updater: sebtype, librime and the two plugins sebtype needs, and
# every other librime package the PC has.
update() {
  local set=("$rpms/$SEBTYPE_RPM") p
  for p in librime librime-lua librime-octagram; do set+=("$rpms/$p-$ours.x86_64.rpm"); done
  for p in librime-predict librime-tools librime-devel; do
    rpm -q "$p" >/dev/null && set+=("$rpms/$p-$ours.x86_64.rpm")
  done
  echo "dnf install -y ${set[*]}"
  dnf -y --setopt=throttle=35M install "${set[@]}"
}
check update-installs update

# sebtype is VERSION's; every librime package is SebType's; setup's versions.sh knows VERSION.
versions() {
  local want p now
  want=$(< /src/VERSION)
  [[ $(rpm -q --qf '%{VERSION}-%{RELEASE}' sebtype) == "$want-$SEBTYPE_RPM_RELEASE" ]] || { echo "sebtype: $(rpm -q sebtype), not $want"; return 1; }
  for p in librime librime-lua librime-octagram librime-tools; do
    now=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$p"); [[ $now == "$ours" ]] || { echo "$p: $now, not $ours"; return 1; }
  done
  [[ $(bash -c 'source /usr/libexec/sebtype/versions.sh; echo "$SEBTYPE_VERSION"') == "$want" ]]
}
check versions versions

ours_installed() { rpm -qa --qf '%{NAME}\n' | grep -xE 'sebtype|librime(-.*)?'; }
# Every file of the installed packages is as packed (size, digest, mode, links).
# shellcheck disable=SC2046  # one package name per word
verify() { rpm -V $(ours_installed) && rpm -ql $(ours_installed); }
check files-as-packed verify

expected() {
  local f
  for f in /usr/lib64/fcitx5/sebtype.so /usr/share/fcitx5/addon/sebtype.conf /usr/lib64/sebtype/libsebtype-mozc.so \
    /usr/share/sebtype/fcitx5/addon/notificationitem.conf /usr/libexec/sebtype/{sebtype-configurator,rime-data.zip} \
    "/usr/lib64/librime.so.$LIBRIME_VERSION" /usr/lib64/rime-plugins/librime-{lua,octagram}.so; do
    [[ -s $f ]] || { echo "missing: $f"; return 1; }
  done
  [[ $(readlink -f /usr/bin/sebtype-setup) == /usr/libexec/sebtype/setup-ime.sh ]] || { echo "sebtype-setup isn't setup"; return 1; }
  # What setup's user part copies is this checkout's.
  # rpmbuild makes setup's #!/usr/bin/env bash /usr/bin/bash.
  cmp <(tail -n +2 /src/pc/linux/setup-ime.sh) <(tail -n +2 /usr/libexec/sebtype/setup-ime.sh) &&
    cmp /src/pc/linux/mozc-keymap.tsv /usr/libexec/sebtype/mozc-keymap.tsv &&
    cmp /src/linux/data/notificationitem.conf /usr/share/sebtype/fcitx5/addon/notificationitem.conf &&
    cmp /src/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_round.png /usr/libexec/sebtype/sebtype-configurator.png
}
check files-expected expected

# shellcheck disable=SC2046  # one package name per word
libraries() {
  local f bad=0
  while read -r f; do
    [[ -f $f && $(head -c 4 "$f") == $'\x7fELF' ]] || continue
    echo "$f"
    ldd "$f" | grep 'not found' && bad=1
  done < <(rpm -ql $(ours_installed))
  return "$bad"
}
check libraries-found libraries

chinese_data() {
  # grep reads it all: -q would end unzip early, and pipefail fail it.
  unzip -tq /usr/libexec/sebtype/rime-data.zip && unzip -Z1 /usr/libexec/sebtype/rime-data.zip | grep -x build/rime_ice.table.bin
}
check chinese-data chinese_data

# Runs without a window: setup's --migrate on an account with nothing to move.
# and was built from this checkout's sources, not kept from an earlier build (#423).
configurator() {
  HOME=$(mktemp -d) /usr/libexec/sebtype/sebtype-configurator --migrate &&
    [[ $(/usr/libexec/sebtype/sebtype-configurator --sources) == "$(configurator_sources /src)" ]]
}
check configurator-runs configurator

exit $failed
