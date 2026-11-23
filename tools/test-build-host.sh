#!/usr/bin/env bash
# tools/lib.sh's build_host_ready, offline (#520): stub ssh, pgrep and gtk-launch on PATH stand in for the
# build host, Zscaler's tray and its launcher, and sleep is skipped. Each case gives the ssh answers in
# order and whether the tray runs, and checks where the build runs and how often Zscaler started.
#
#   tools/test-build-host.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HOME/scratch/SebType"
work=$(mktemp -d "$HOME/scratch/SebType/test-build-host.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
# ssh answers with the next line of $work/answers (0: the host answers); each call is logged.
cat > "$work/bin/ssh" <<STUB
#!/usr/bin/env bash
echo "ssh \$*" >> "$work/calls"
code=\$(head -1 "$work/answers"); sed -i 1d "$work/answers"; exit \${code:-255}
STUB
printf '#!/usr/bin/env bash\n[[ -e %q/tray ]]\n' "$work" > "$work/bin/pgrep"
printf '#!/usr/bin/env bash\necho "gtk-launch $*" >> %q/calls\n' "$work" > "$work/bin/gtk-launch"
chmod +x "$work/bin"/*

fails=0
# case NAME TRAY(running|stopped) ANSWERS EXPECTED_HOST EXPECTED_LAUNCHES
case_() {
  local name=$1 tray=$2 answers=$3 want_host=$4 want_launches=$5 host launches
  rm -f "$work/calls" "$work/tray"; : > "$work/calls"
  [[ $tray == running ]] && touch "$work/tray"
  tr ' ' '\n' <<< "$answers" > "$work/answers"
  host=$(PATH="$work/bin:$PATH" SEBTYPE_BUILD_HOST=yanglab16 SEBTYPE_HOST=nobara-pc GITHUB_ACTIONS= bash -c '
    source "$1"; sleep() { :; }; build_host_ready 2>/dev/null; echo "$BUILD_HOST"' _ "$here/lib.sh")
  launches=$(grep -c '^gtk-launch ZSTray$' "$work/calls")
  if [[ $host == "$want_host" && $launches == "$want_launches" ]]; then
    echo "PASS $name"
  else
    echo "FAIL $name: built on $host (want $want_host), Zscaler started $launches times (want $want_launches)"
    sed 's/^/  /' "$work/calls"; fails=$((fails + 1))
  fi
}
case_ host-answers                running "0"           yanglab16 0
case_ retry-answers               running "255 0"       yanglab16 0
case_ both-fail-tray-running      running "255 255 0"   local     0
case_ both-fail-tray-stopped      stopped "255 255 0"   yanglab16 1
case_ all-fail-tray-stopped       stopped "255 255 255" local     1
exit $((fails > 0))
