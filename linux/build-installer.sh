#!/usr/bin/env bash
# Packs SebType's Linux RPMs (versions.sh: sebtype + the 6 librime packages) into one self-extracting
# POSIX sh installer, SebType-setup-<version>-linux-x86_64.sh (#427).
#
#   linux/build-installer.sh DIR [OUT]
#
# DIR holds the 7 RPMs; OUT defaults to SebType-setup-<version>-linux-x86_64.sh in the current directory.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=versions.sh
source "$here/versions.sh"

dir=${1:?usage: linux/build-installer.sh DIR [OUT]}
out=${2:-$SEBTYPE_LINUX_SETUP}
[[ -d $dir ]] || { echo "build-installer: $dir is not a directory" >&2; exit 1; }

ours=$LIBRIME_VERSION-$LIBRIME_SEBTYPE_RELEASE
required=(
  "$SEBTYPE_RPM"
  "librime-$ours.x86_64.rpm"
  "librime-lua-$ours.x86_64.rpm"
  "librime-octagram-$ours.x86_64.rpm"
)
optional=(
  "librime-predict-$ours.x86_64.rpm"
  "librime-tools-$ours.x86_64.rpm"
  "librime-devel-$ours.x86_64.rpm"
)
all=("${required[@]}" "${optional[@]}")

for f in "${all[@]}"; do
  [[ -f $dir/$f ]] || { echo "build-installer: missing $dir/$f" >&2; exit 1; }
done

manifest=$(cd "$dir" && sha256sum -- "${all[@]}")

mkdir -p "$(dirname "$out")"
tmp=$(mktemp "${out}.XXXXXX")
trap 'rm -f "$tmp"' EXIT

cat > "$tmp" <<EOF
#!/bin/sh
# SebType $SEBTYPE_VERSION Linux installer (Fedora / Nobara, x86_64).
# Installs SebType's RPMs (required packages plus any already-installed optional librime packages)
# and runs sebtype-setup for the invoking user.
set -eu

SEBTYPE_VERSION='$SEBTYPE_VERSION'
SEBTYPE_RPM='$SEBTYPE_RPM'
LIBRIME_RPM='librime-$ours.x86_64.rpm'
LIBRIME_LUA_RPM='librime-lua-$ours.x86_64.rpm'
LIBRIME_OCTAGRAM_RPM='librime-octagram-$ours.x86_64.rpm'
LIBRIME_PREDICT_RPM='librime-predict-$ours.x86_64.rpm'
LIBRIME_TOOLS_RPM='librime-tools-$ours.x86_64.rpm'
LIBRIME_DEVEL_RPM='librime-devel-$ours.x86_64.rpm'

usage() {
  cat <<'USAGE'
SebType $SEBTYPE_VERSION Linux installer (Fedora / Nobara, x86_64)

Usage:
  sh SebType-setup-$SEBTYPE_VERSION-linux-x86_64.sh
  sh SebType-setup-$SEBTYPE_VERSION-linux-x86_64.sh --install-rpms-only
  sh SebType-setup-$SEBTYPE_VERSION-linux-x86_64.sh --help

Options:
  --install-rpms-only   Install only the RPM packages (must run as root).
  -h, --help            Show this help and exit.
USAGE
}

mode=full
case "\${1:-}" in
  '') ;;
  --install-rpms-only) mode=rpms ;;
  -h|--help) usage; exit 0 ;;
  *) echo "SebType installer: unknown option: \$1" >&2; usage >&2; exit 2 ;;
esac
[ \$# -le 1 ] || { echo "SebType installer: unexpected argument: \$2" >&2; exit 2; }

self=\$(readlink -f -- "\$0" 2>/dev/null || true)
if [ -z "\$self" ]; then
  case "\$0" in
    /*) self=\$0 ;;
    *) self=\$PWD/\$0 ;;
  esac
fi
[ -f "\$self" ] || { echo "SebType installer: cannot locate installer file (\$0)" >&2; exit 1; }

install_rpms() {
  [ "\$(id -u)" -eq 0 ] || { echo "SebType installer: --install-rpms-only must run as root" >&2; exit 1; }
  line=\$(awk '/^__SEBTYPE_PAYLOAD__\$/ { print NR + 1; exit }' "\$self")
  [ -n "\$line" ] || { echo "SebType installer: payload marker not found" >&2; exit 1; }
  tmp=\$(mktemp -d)
  chmod 700 "\$tmp"
  trap 'rm -rf "\$tmp"' EXIT
  tail -n "+\$line" "\$self" | tar -xf - -C "\$tmp"
  (
    cd "\$tmp"
    sha256sum --check --status - <<'MANIFEST'
$manifest
MANIFEST
  ) || { echo "SebType installer: payload checksum verification failed" >&2; exit 3; }

  set -- "\$tmp/\$SEBTYPE_RPM" "\$tmp/\$LIBRIME_RPM" "\$tmp/\$LIBRIME_LUA_RPM" "\$tmp/\$LIBRIME_OCTAGRAM_RPM"
  for pair in "librime-predict:\$LIBRIME_PREDICT_RPM" "librime-tools:\$LIBRIME_TOOLS_RPM" "librime-devel:\$LIBRIME_DEVEL_RPM"; do
    pkg=\${pair%%:*}
    rpm=\${pair#*:}
    if rpm -q --quiet "\$pkg" 2>/dev/null; then
      set -- "\$@" "\$tmp/\$rpm"
    fi
  done
  dnf install -y "\$@"
}

if [ "\$mode" = rpms ]; then
  install_rpms
  exit 0
fi

if [ "\$(id -u)" -eq 0 ]; then
  install_rpms
  if [ -n "\${SUDO_USER:-}" ]; then
    echo "SebType \$SEBTYPE_VERSION packages installed. Run 'sebtype-setup' (without sudo) as \$SUDO_USER to finish setting up your account, then log out and back in (or toggle Virtual Keyboard off and on in KDE System Settings)."
  else
    echo "SebType \$SEBTYPE_VERSION packages installed. Run 'sebtype-setup' as your normal user to finish setting up your account, then log out and back in (or toggle Virtual Keyboard off and on in KDE System Settings)."
  fi
  exit 0
fi

self_sha=\$(sha256sum "\$self" | awk '{print \$1}')
root_run='set -eu; d=\$(mktemp -d); trap "rm -rf \"\$d\"" EXIT; chmod 700 "\$d"; cp -- "\$1" "\$d/setup.sh"; got=\$(sha256sum "\$d/setup.sh" | cut -d" " -f1); [ "\$got" = "\$2" ] || { echo "SebType installer changed before elevation" >&2; exit 3; }; /bin/sh "\$d/setup.sh" --install-rpms-only'
if [ -t 0 ] && [ -t 1 ] && command -v sudo >/dev/null 2>&1; then
  sudo /bin/sh -c "\$root_run" sh "\$self" "\$self_sha"
elif command -v pkexec >/dev/null 2>&1; then
  pkexec /bin/sh -c "\$root_run" sh "\$self" "\$self_sha"
elif command -v sudo >/dev/null 2>&1; then
  sudo /bin/sh -c "\$root_run" sh "\$self" "\$self_sha"
else
  echo "SebType installer: neither sudo nor pkexec found; run as root with --install-rpms-only, then run sebtype-setup as your user." >&2
  exit 1
fi

if [ -t 0 ]; then
  /usr/bin/sebtype-setup
else
  /usr/bin/sebtype-setup </dev/null
fi

echo "SebType \$SEBTYPE_VERSION is installed. Log out and back in (or toggle Virtual Keyboard off and on in KDE System Settings) to start using it."
exit 0
__SEBTYPE_PAYLOAD__
EOF

tar -cf - -C "$dir" -- "${all[@]}" >> "$tmp"
chmod 755 "$tmp"
mv -f "$tmp" "$out"
echo "$out"
