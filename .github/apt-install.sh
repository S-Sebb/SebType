#!/usr/bin/env bash
# Installs Ubuntu packages on a GitHub runner: .github/apt-install.sh PACKAGE...
# The runner's Azure apt mirror sometimes doesn't resolve (#142), and apt-get update only warns then, so
# the install fails: retry with that mirror dropped from the runner's mirror list (archive.ubuntu.com next).
for try in 1 2 3; do
  sudo apt-get update -q && sudo apt-get install -y "$@" && exit 0
  sudo sed -i '/azure\.archive\.ubuntu\.com/d' /etc/apt/apt-mirrors.txt; sleep 10
done
exit 1
