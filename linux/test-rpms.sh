#!/usr/bin/env bash
# shellcheck disable=SC2329  # the checks run through check()
# Tests a release's Linux installer (#421, #427) as the Configurator's update installs it (#422), in a fresh
# pinned Fedora (versions.sh) with Fedora's Rime (fcitx5-rime, librime and its plugins), or with an older
# release installed over it first: --install-rpms-only installs sebtype and leaves Fedora's librime as it is,
# or puts it back where an older release had replaced it (#527); SebType's version is VERSION's, every
# installed file is the package's, the files setup's user part copies are this checkout's, every library finds
# what it links, the add-on has its own librime, the package needs only sonames Fedora keeps across releases,
# Fcitx5 loads the add-on, sebtype-setup runs cleanly as a normal user, a Rime profile from before the update
# keeps its learned words, My words and settings, a system update and a later
# librime-predict install work, removing sebtype leaves Fedora's Rime working, and with sebtype installed
# again the upgrade to the next Fedora release goes through and Fcitx5 still loads it (#540).
#
#   linux/test-rpms.sh INSTALLER [OLD_INSTALLER]   # SebType-setup-<version>-linux-x86_64.sh (CI's artifact
#                                                  # sebtype-linux-setup); OLD_INSTALLER: a release's, e.g. 0.2.0's
#
# One line per check; logs in ~/scratch/SebType/<task>/test-rpms/. Exits 0 only when all pass.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"

if [[ ${1-} != --inside ]]; then
  # shellcheck source-path=SCRIPTDIR source=../tools/lib.sh
  source "$here/../tools/lib.sh"
  installer=$(readlink -f "${1:?usage: linux/test-rpms.sh INSTALLER [OLD_INSTALLER]}")
  old=${2:+$(readlink -f "$2")}
  command -v podman >/dev/null || { echo "preflight: podman missing"; exit 1; }
  for f in "$installer" ${old:+"$old"}; do [[ -f $f ]] || { echo "preflight: $f missing"; exit 1; }; done
  log=$TASK_OUT/test-rpms; rm -rf "$log"; mkdir -p "$log"
  exec podman run --rm -v "$installer:/installer.sh:ro,z" ${old:+-v "$old:/old.sh:ro,z"} -v "$here/..:/src:ro,z" \
    -v "$log:/log:z" "$BUILD_IMAGE" bash /src/linux/test-rpms.sh --inside
fi

failed=0
check() { # name function...: each within 15 minutes (timeout can't run a function); exit 77 skips it
  local name=$1 pid watch rc; shift
  "$@" > "/log/$name.log" 2>&1 & pid=$!
  { sleep 900; kill "$pid"; } 2>/dev/null & watch=$!
  wait "$pid"; rc=$?
  kill "$watch" 2>/dev/null
  if ((rc == 0)); then echo "PASS $name"
  elif ((rc == 77)); then echo "SKIP $name: $(tail -n 1 "/log/$name.log")"
  else echo "FAIL $name: see test-rpms/$name.log"; tail -n 30 "/log/$name.log" || true; failed=1; fi
}
rime=(librime librime-lua librime-octagram librime-tools fcitx5-rime)

echo 'throttle=35M' >> /etc/dnf/dnf.conf
dnf -y -q install fcitx5 "${rime[@]}" binutils dbus-daemon > /log/before.log 2>&1 ||
  { echo "preflight: Fedora's fcitx5 and Rime don't install (see test-rpms/before.log)"; exit 1; }
if [[ -f /old.sh ]]; then
  sh /old.sh --install-rpms-only > /log/old.log 2>&1 || { echo "preflight: the old installer fails (see test-rpms/old.log)"; exit 1; }
fi
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' 'sebtype*' 'librime*' 'fcitx5-rime*' | sort > /log/packages-before.txt

# A user's Rime profile from before the update, which it must keep (#540): 3000 learned words in a user
# dictionary written by Fedora's LevelDB, as SebType 0.2.0 and older wrote them, with Snappy-compressed
# tables (Fedora's rime_dict_manager restores them and, opening it again for one more, moves them into a
# table), a word under My words and a setting (Traditional Chinese on).
home=/tmp/sebtype-tester user_rime=/tmp/sebtype-tester/.local/share/fcitx5/rime
as_tester() { chroot --userspec=1000:1000 / env HOME="$home" USER=tester "$@"; }
seed_profile() {
  local header i
  echo "tester:x:1000:1000::$home:/bin/bash" >> /etc/passwd  # for D-Bus
  mkdir -p "$user_rime" && chown -R 1000:1000 "$home" || return 1
  header=$'# Rime user dictionary\n#@/db_name\trime_ice\n#@/db_type\tuserdb\n#@/rime_version\t1.16.1'
  { echo "$header"; for ((i = 1; i <= 3000; i++)); do printf 'ce shi %d \t测试词条%d\tc=3 d=3 t=1\n' "$i" "$i"; done; } > /tmp/learned.txt
  printf '%s\nling \t另一条\tc=1 d=1 t=1\n' "$header" > /tmp/one-more.txt
  as_tester sh -c "cd $user_rime && rime_dict_manager --restore /tmp/learned.txt && rime_dict_manager --restore /tmp/one-more.txt &&
    printf '# SebType: My words\n测词\tceci\n' > custom_phrase.txt && printf 'patch:\n  switches/@2/reset: 1\n' > rime_ice.custom.yaml" &&
    ls "$user_rime"/rime_ice.userdb/*.ldb
}
seed_profile > /log/seed-profile.log 2>&1 || { echo "preflight: the Rime profile doesn't seed (see test-rpms/seed-profile.log)"; exit 1; }

# Fedora's Rime packages are Fedora's and as Fedora packed them, and those not installed before still aren't.
fedora_rime() {
  local p
  for p in "${rime[@]}"; do
    [[ $(rpm -q --qf '%{RELEASE}' "$p") == *.fc44 && $(rpm -q --qf '%{RELEASE}' "$p") != *sebtype* ]] || { echo "$p: $(rpm -q "$p")"; return 1; }
  done
  rpm -V "${rime[@]}" || return 1
  for p in librime-predict librime-devel; do
    ! rpm -q "$p" || { echo "$p was installed"; return 1; }
  done
}

# The update's admin step (#427): extracts and verifies the embedded RPM and installs sebtype; Fedora's librime
# stays, or comes back where an older release had put SebType's in its place.
update() {
  sh /installer.sh --help &&
    sh /installer.sh --install-rpms-only
}
check update-installs update

# sebtype is VERSION's; Fedora's Rime is Fedora's; setup's versions.sh knows VERSION.
versions() {
  local want
  want=$(< /src/VERSION)
  [[ $(rpm -q --qf '%{VERSION}-%{RELEASE}' sebtype) == "$want-$SEBTYPE_RPM_RELEASE" ]] || { echo "sebtype: $(rpm -q sebtype), not $want"; return 1; }
  fedora_rime &&
    [[ $(bash -c 'source /usr/libexec/sebtype/versions.sh; echo "$SEBTYPE_VERSION"') == "$want" ]]
}
check versions versions

# Every file of the package is as packed (size, digest, mode, links).
verify() { rpm -V sebtype && rpm -ql sebtype; }
check files-as-packed verify

# The add-on has SebType's librime with its plugins inside (#527): it needs no librime library and exports
# none of Rime's symbols, which would meet Fedora's librime in Fcitx5's process (fcitx5-rime's).
own_librime() {
  local so=/usr/lib64/fcitx5/sebtype.so
  ! ldd "$so" | grep -i rime && ! nm -D --defined-only "$so" | grep -E 'rime_get_api|Rime[A-Z]|4rime' &&
    nm -D --defined-only "$so" | grep -q fcitx_addon_factory_instance
}
check own-librime own_librime

# The package needs no library a Fedora release may drop or rename (#540): the add-on has librime's
# libraries and protobuf inside, and needs only glibc's, GCC's, Fcitx5's, libpng's and fontconfig's.
stable_sonames() {
  local requires
  requires=$(rpm -q --requires sebtype) || return 1
  ! grep '\.so' <<<"$requires" |
    grep -vE '^(libc|libm|libstdc\+\+|libgcc_s)\.so\.[0-9]+\(|^libFcitx5(Core|Config|Utils)\.so|^libpng16\.so\.16\(|^libfontconfig\.so\.1\('
}
check stable-sonames stable_sonames

# Fcitx5 loads the add-on and its input method, without a display, in its own D-Bus session.
fcitx5_loads() {
  local log
  log=$(HOME=$(mktemp -d) timeout 20 dbus-run-session -- fcitx5 --verbose='*=5' --disable=all --enable=dbus,keyboard,sebtype 2>&1)
  { grep -q 'Loaded addon sebtype' <<<"$log" && grep -q 'input method(s) in addon sebtype' <<<"$log"; } || { echo "$log"; return 1; }
}
check fcitx5-loads fcitx5_loads

expected() {
  local f
  for f in /usr/lib64/fcitx5/sebtype.so /usr/share/fcitx5/addon/sebtype.conf /usr/lib64/sebtype/libsebtype-mozc.so \
    /usr/share/sebtype/fcitx5/addon/notificationitem.conf /usr/libexec/sebtype/{sebtype-configurator,rime-data.zip}; do
    [[ -s $f ]] || { echo "missing: $f"; return 1; }
  done
  [[ $(readlink -f /usr/bin/sebtype-setup) == /usr/libexec/sebtype/setup-ime.sh ]] || { echo "sebtype-setup isn't setup"; return 1; }
  # The licences of the libraries the add-on carries; its librime is all BSD-3-Clause (#527).
  for f in librime librime-lua librime-octagram; do
    grep -q 'Redistribution and use in source and binary forms' "/usr/share/licenses/sebtype/$f-LICENSE" ||
      { echo "not BSD: $f"; return 1; }
  done
  for f in llama.cpp glog yaml-cpp snappy leveldb marisa-trie opencc protobuf abseil utf8-range lua rapidjson; do
    [[ -s /usr/share/licenses/sebtype/$f-LICENSE ]] || { echo "missing: $f's licence"; return 1; }
  done
  # The Configurator's crates (#548; the spec's %check checks that each has its text): Slint's Royalty-free
  # licence, and dbus's (in keyring's libdbus-sys).
  f=/usr/share/licenses/sebtype/configurator-crates-LICENSE
  grep -q 'Slint Royalty-free Desktop, Mobile, and Web Applications License' "$f" && grep -q 'Academic Free License' "$f" &&
    grep -qx '  libdbus-sys [0-9.]*' "$f" || { echo "not the Configurator's crates' licences: $f"; return 1; }
  # What setup's user part copies is this checkout's.
  # rpmbuild makes setup's #!/usr/bin/env bash /usr/bin/bash.
  cmp <(tail -n +2 /src/pc/linux/setup-ime.sh) <(tail -n +2 /usr/libexec/sebtype/setup-ime.sh) &&
    cmp /src/pc/linux/mozc-keymap.tsv /usr/libexec/sebtype/mozc-keymap.tsv &&
    cmp /src/linux/data/notificationitem.conf /usr/share/sebtype/fcitx5/addon/notificationitem.conf &&
    cmp /src/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_round.png /usr/libexec/sebtype/sebtype-configurator.png
}
check files-expected expected

links() { local out; { out=$(ldd "$1") && ! grep 'not found' <<<"$out"; } || { echo "$1: $out"; return 1; }; }
libraries() {
  local f bad=0
  while read -r f; do
    [[ -f $f && $(head -c 4 "$f") == $'\x7fELF' ]] || continue
    echo "$f"
    links "$f" || bad=1
  done < <(rpm -ql sebtype)
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
# on the profile seeded before the update, and writes ~/.config/fcitx5/profile with sebtype even when Fcitx5
# isn't running (#442).
user_setup() {
  local profile=$home/.config/fcitx5/profile
  as_tester /usr/bin/sebtype-setup </dev/null &&
    [[ -x "$home/.local/share/sebtype/configurator/sebtype-configurator" ]] &&
    [[ -f "$home/.local/share/fcitx5/rime/sebtype-data.txt" ]] &&
    [[ -f "$profile" ]] &&
    grep -qx 'Name=sebtype' "$profile" &&
    ! grep -qxE 'Name=(keyboard-us|rime|mozc)' "$profile"
}
check user-setup user_setup

# The profile seeded before the update keeps (#540): with SebType's Chinese data in place, the add-on reads
# every learned word back (its sync, when Fcitx5 exits, writes them all to its snapshot), and My words and the
# setting stay.
learned_words() {
  local n
  as_tester dbus-run-session -- sh -c 'fcitx5 --disable=all --enable=dbus,keyboard,sebtype & sleep 5
    busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetConfig sv fcitx://config/addon/sebtype/deploy s ""
    sleep 20; busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 Exit; wait'
  n=$(grep -c '测试词条' "$user_rime"/sync/*/rime_ice.userdb.txt) || true
  echo "$n of 3000 entries in the add-on's snapshot"
  ((n == 3000)) || return 1
  grep -qx $'测词\tceci' "$user_rime/custom_phrase.txt" || { echo "My words were lost"; return 1; }
  grep -qx '  switches/@2/reset: 1' "$user_rime/rime_ice.custom.yaml" || { echo "the setting was lost"; return 1; }
}
check learned-words-kept learned_words

# A system update (Nobara's updater runs distro-sync, which moves every package to the repositories' version,
# #527) and an upgrade change neither sebtype nor Fedora's Rime.
system_update() {
  dnf -y --best distro-sync && dnf -y upgrade &&
    [[ $(rpm -q --qf '%{VERSION}-%{RELEASE}' sebtype) == "$(< /src/VERSION)-$SEBTYPE_RPM_RELEASE" ]] && fedora_rime
}
check system-update system_update

# Fedora's librime-predict installs later, beside Fedora's librime.
predict() { dnf -y install librime-predict && rpm -V librime-predict; }
check librime-predict-later predict

# Removing sebtype leaves Fedora's Rime installed, as packed and finding what it links.
remove() {
  local f
  dnf -y remove sebtype && ! rpm -q sebtype && rpm -V "${rime[@]}" librime-predict || return 1
  for f in /usr/lib64/fcitx5/librime.so /usr/lib64/librime.so.1 /usr/lib64/rime-plugins/*.so; do
    links "$f" || return 1
  done
}
check remove-leaves-fedora-rime remove

# The next Fedora release's upgrade (dnf --releasever distro-sync, #540) goes through with sebtype installed,
# keeps it, and every library still finds what it links and the add-on loads. Skipped only while Fedora's
# mirrors say that release has no repository yet.
release_upgrade() {
  local next meta
  next=$(($(rpm -E %fedora) + 1))
  meta=$(curl --limit-rate 35M -sSf --retry 3 "https://mirrors.fedoraproject.org/metalink?repo=fedora-$next&arch=$(uname -m)") || return 1
  if grep -q 'invalid repo' <<<"$meta"; then echo "Fedora $next has no repository yet"; return 77; fi
  sh /installer.sh --install-rpms-only && dnf -y --releasever="$next" distro-sync &&
    [[ $(rpm -E %fedora) == "$next" ]] && rpm -V sebtype && libraries && fcitx5_loads
}
check release-upgrade release_upgrade

exit $failed
