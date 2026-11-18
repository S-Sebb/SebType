#!/usr/bin/env bash
# Fails on a download in the repository that isn't capped at 300 Mbit/s (#365): the lab's servers share one
# 1 Gbit/s port, and an uncapped download stalls SSH and the NAS for everyone. It finds a curl or wget call
# without --limit-rate on the same line (put it right after the command name: curl --limit-rate 35M,
# wget --limit-rate=35m), and PowerShell's Invoke-WebRequest, which can't be capped (use curl.exe).
#
#   tools/check-downloads.sh
set -uo pipefail
cd "$(dirname "$0")/.."
# A call: the name, then an option, a quoted or variable argument, or a URL.
found=$(git grep -nIE "(^|[^[:alnum:]_./-])(curl(\.exe)?|wget|Invoke-WebRequest|iwr)[[:space:]]+[-\"'\$h]" \
  | grep -v -- '--limit-rate')
if [[ -n $found ]]; then
  echo "FAIL downloads-capped: these downloads have no --limit-rate:"
  echo "$found"
  exit 1
fi
echo "PASS downloads-capped"
