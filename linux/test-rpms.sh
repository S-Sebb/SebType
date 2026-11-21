#!/usr/bin/env bash
# shellcheck disable=SC2329  # the checks run through check()
# Tests a release's Linux installer (#421, #427) as the Configurator's update installs it (#422), in a fresh
# pinned Fedora (versions.sh) whose librime is Fedora's, with librime-tools: --install-rpms-only replaces
# every installed librime package without pulling in uninstalled optional ones, SebType's version is
# VERSION's, every installed file is the package's, the files setup's user part copies are this checkout's,
# every library finds what it links, and sebtype-setup runs cleanly as a normal user.
#
#   linux/test-rpms.sh INSTALLER   # SebType-setup-<version>-linux-x86_64.sh (CI's artifact sebtype-linux-setup)
#
# One line per check; logs in ~/scratch/SebType/<task>/test-rpms/. Exits 0 only when all pass.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"

if [[ ${1-} != --inside ]]; then
  # shellcheck source-path=SCRIPTDIR source=../tools/lib.sh
  source "$here/../tools/lib.sh"
  installer=$(readlink -f "${1:?usage: linux/test-rpms.sh INSTALLER}")
  command -v podman >/dev/null || { echo "preflight: podman missing"; exit 1; }
  [[ -f $installer ]] || { echo "preflight: $installer missing"; exit 1; }
  log=$TASK_OUT/test-rpms; rm -rf "$log"; mkdir -p "$log"
  exec podman run --rm -v "$installer:/installer.sh:ro,z" -v "$here/..:/src:ro,z" -v "$log:/log:z" "$BUILD_IMAGE" \
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
  else echo "FAIL $name: see test-rpms/$name.log"; tail -n 30 "/log/$name.log" || true; failed=1; fi
}
ours=$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE

echo 'throttle=35M' >> /etc/dnf/dnf.conf
dnf -y -q install fcitx5 librime librime-lua librime-octagram librime-tools > /log/before.log 2>&1 ||
  { echo "preflight: Fedora's fcitx5 and librime don't install (see test-rpms/before.log)"; exit 1; }

# The update's admin step (#427): extracts and verifies the embedded RPMs, installs sebtype, librime,
# librime-lua, librime-octagram, and only the optional librime packages already installed (librime-tools).
update() {
  sh /installer.sh --help &&
    sh /installer.sh --install-rpms-only
}
check update-installs update

# sebtype is VERSION's; every installed librime package is SebType's; uninstalled optional librime
# packages weren't pulled in; setup's versions.sh knows VERSION.
versions() {
  local want p now
  want=$(< /src/VERSION)
  [[ $(rpm -q --qf '%{VERSION}-%{RELEASE}' sebtype) == "$want-$SEBTYPE_RPM_RELEASE" ]] || { echo "sebtype: $(rpm -q sebtype), not $want"; return 1; }
  for p in librime librime-lua librime-octagram librime-tools; do
    now=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$p"); [[ $now == "$ours" ]] || { echo "$p: $now, not $ours"; return 1; }
  done
  for p in librime-predict librime-devel; do
    ! rpm -q "$p" >/dev/null 2>&1 || { echo "optional $p was unexpectedly installed"; return 1; }
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

# The user part of the installer: sebtype-setup runs cleanly as a non-root user (without needing useradd/su),
# and writes ~/.config/fcitx5/profile with sebtype even when Fcitx5 isn't running (#442).
user_setup() {
  local home=/tmp/sebtype-tester profile
  profile=$home/.config/fcitx5/profile
  rm -rf "$home"; mkdir -p "$home"; chown 1000:1000 "$home"
  chroot --userspec=1000:1000 / env HOME="$home" USER=tester /usr/bin/sebtype-setup </dev/null &&
    [[ -x "$home/.local/share/sebtype/configurator/sebtype-configurator" ]] &&
    [[ -f "$home/.local/share/fcitx5/rime/sebtype-data.txt" ]] &&
    [[ -f "$profile" ]] &&
    grep -qx 'Name=sebtype' "$profile" &&
    ! grep -qxE 'Name=(keyboard-us|rime|mozc)' "$profile"
}
check user-setup user_setup

exit $failed
