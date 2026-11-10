#!/usr/bin/env bash
# Tests SebType's installer (#73) on TCSBackEnd (Windows Server 2022) from nobara-pc, in the background,
# and puts TCSBackEnd back as found. One command, no arguments:
#   pc/windows/setup/test-tcsbackend.sh
# It takes SebType-setup-*.exe from the "Windows setup" CI run of this commit (gh), or else from build/,
# runs test.ps1 elevated in the Administrator session (disconnected; the game backend there is never
# touched) and opens the test user's Remote Desktop session in FreeRDP inside headless gamescope (no
# window here, no sound) through an SSH tunnel, typing the typing checks' keys into FreeRDP
# (../mozc/rdp-keys.py) so they arrive as a keyboard's. Needs gh, gamescope, xfreerdp, python3-xlib,
# ImageMagick and `ssh TCSBackEnd`. Output: one line per check; logs in $out, the installer's pages in
# /tmp/sebtype/73-*.png. Takes the device lock; exit 0 only if every check passes and TCSBackEnd ends
# as found.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
out=/tmp/sebtype/73-setup-tcsbackend
lock=/tmp/agent-locks/devices/tcsbackend.lock
branch=$(git -C "$repo" branch --show-current)
if [ -z "${HOLDING:-}" ]; then
  exec env HOLDING=1 devq -w 3600 -m 75 -n "sebtype installer test on TCSBackEnd ($branch)" "$lock" bash "$0"
fi
mkdir -p "$out"; rm -rf "${out:?}"/*

missing=
command -v gamescope >/dev/null && command -v xfreerdp >/dev/null && command -v magick >/dev/null && python3 -c 'import Xlib' 2>/dev/null ||
  missing='needs gamescope, xfreerdp, ImageMagick and python3-xlib'
# The setup CI built from this commit, else one built here into build/ (ISCC under Wine, from CI's other
# artifacts) while CI's Mozc build still runs.
head=$(git -C "$repo" rev-parse HEAD)
run=$(gh run list -R S-Sebb/SebType --workflow windows-setup.yml --branch "$branch" --status success --json databaseId,headSha \
  -q "map(select(.headSha == \"$head\"))[0].databaseId // empty" 2>/dev/null)
if [ -n "$run" ]; then
  gh run download -R S-Sebb/SebType "$run" -n sebtype-setup -D "$out/in" >/dev/null 2>&1 || missing=${missing:-"downloading sebtype-setup from run $run failed"}
  exe=$(ls "$out"/in/SebType-setup-*.exe 2>/dev/null | head -1)
else
  exe=$(ls -t "$repo"/build/SebType-setup-*.exe 2>/dev/null | head -1)
fi
[ -n "$exe" ] || missing=${missing:-"no SebType-setup-*.exe: no successful Windows setup run for $head yet, none in build/"}
echo "setup: ${exe:-none}${run:+ (CI run $run)}" > "$out/input.txt"
timeout 30 ssh -o BatchMode=yes TCSBackEnd 'echo ok' >/dev/null 2>&1 || missing=${missing:-'ssh TCSBackEnd fails: connect the SoftEther VPN'}
[ -n "$missing" ] && { echo "BLOCKED preflight: $missing"; exit 1; }

tps() {  # Windows PowerShell 5.1 on TCSBackEnd, script on stdin; output as text (not CLIXML), UTF-8
  local enc
  enc=$( (echo '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference="SilentlyContinue"'; cat) | iconv -t UTF-16LE | base64 -w0)
  timeout "${T:-120}" ssh TCSBackEnd "powershell -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand $enc" 2>&1 | grep -av '^#< CLIXML\|^<Objs'
}
state() {
  tps <<'EOF'
$u = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
"sessions: $((query user 2>&1 | Select-Object -Skip 1 | ForEach-Object { $_.Trim() -replace '^(\S+)\s+(?:\S+\s+)?(\d+)\s+(\S+).*', '$1 $2 $3' }) -join ' | ')"
"languages: $(((Get-WinUserLanguageList) | ForEach-Object { "$($_.LanguageTag)=$($_.InputMethodTips -join ',')" }) -join '; ')"
"installed: $((Get-ChildItem $u | Where-Object { $_.GetValue('DisplayName') -match '^(SebType|Mozc|小狼毫|Weasel)' } | ForEach-Object { $_.GetValue('DisplayName') }) -join ', ')"
"hkcu tip sha: $((reg.exe query 'HKCU\Software\Microsoft\CTF\TIP' /s | Out-String).GetHashCode())"
"hklm tip: $((Get-ChildItem HKLM:\SOFTWARE\Microsoft\CTF\TIP).PSChildName -join ',')"
"hotkeys sha: $((reg.exe query 'HKCU\Control Panel\Input Method\Hot Keys' /s | Out-String).GetHashCode())"
"folders: $(("$env:ProgramFiles\SebType", 'C:\sebtype-setup-test', "$env:LOCALAPPDATA\SebType-setup-test", "$env:LOCALAPPDATA\SebType", 'HKLM:\SOFTWARE\SebType', 'HKLM:\SOFTWARE\WOW6432Node\Rime' | ForEach-Object { Test-Path $_ }) -join ' ')"
"backend: $((Get-Process TaikoLocalServer -ErrorAction SilentlyContinue | ForEach-Object { "pid $($_.Id) session $($_.SessionId)" }) -join ', ')"
"users: $((Get-LocalUser).Name -join ',')  profiles: $((Get-CimInstance Win32_UserProfile).LocalPath -join ',')"
"administrators: $((Get-LocalGroupMember -SID S-1-5-32-544).Name -join ',')  remote desktop users: $((Get-LocalGroupMember -SID S-1-5-32-555).Name -join ',')"
"tasks: $((Get-ScheduledTask -TaskName SebType* -ErrorAction SilentlyContinue).TaskName -join ',')"
EOF
}
cleanup() {  # what a run that died may leave: its session, user, profile, SebType, Weasel, Mozc, tasks and files
  T=900 tps <<'EOF'
Get-ScheduledTask -TaskName SebType-setup* -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'sebtype-setup-test' -or $_.ExecutablePath -match '\\(is-[^\\]+\.tmp|_iu[^\\]+)\\' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# the session first: an account deleted while its session runs leaves its profile loaded until a reboot
query.exe session 2>$null | ForEach-Object { if ("$_" -match '\ssebtype-test\s+(\d+)\s') { logoff.exe $Matches[1] } }
$app = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{5C1E7A52-3D8B-4F7E-9E0B-7B3B5A1C7354}_is1'
if (Test-Path $app) { Start-Process -Wait "$env:ProgramFiles\SebType\unins000.exe" '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'; Start-Sleep 20 }
$w = Get-ItemProperty HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Weasel -ErrorAction SilentlyContinue
if ($w -and $w.PSObject.Properties['SebType']) { Get-Process Weasel* -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Process -Wait ($w.UninstallString -replace '"') '/S'; Start-Sleep 10 }
$m = Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall | Where-Object { $_.GetValue('DisplayName') -eq 'Mozc' }
if ($m) { Get-Process mozc_* -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Process -Wait msiexec.exe '/x', $m.PSChildName, '/qn', '/norestart' }
if ($u = Get-LocalUser sebtype-test -ErrorAction SilentlyContinue) {
    for ($i = 0; $i -lt 60 -and (Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $u.SID.Value -and $_.Loaded }); $i++) { Start-Sleep 2 }
    Get-CimInstance Win32_UserProfile | Where-Object SID -EQ $u.SID.Value | Remove-CimInstance
    Remove-LocalUser sebtype-test
}
Remove-Item -Recurse -Force C:\sebtype-setup-test, "$env:LOCALAPPDATA\SebType-setup-test" -ErrorAction SilentlyContinue
EOF
}

state > "$out/before.txt"
grep -q '^installed: .' "$out/before.txt" && { echo "BLOCKED preflight: SebType, Weasel or Mozc is installed on TCSBackEnd already ($(grep '^installed:' "$out/before.txt"))"; exit 1; }
grep -q '^folders: .*True' "$out/before.txt" && { echo "BLOCKED preflight: a SebType or test folder exists on TCSBackEnd already ($(grep '^folders:' "$out/before.txt"))"; exit 1; }
grep -q 'sebtype-test' "$out/before.txt" && { echo "BLOCKED preflight: a sebtype-test user exists on TCSBackEnd already"; exit 1; }

cat > "$out/run.ps1" <<'EOF'
$d = 'C:\sebtype-setup-test'
Start-Transcript "$d\run.log" | Out-Null
try {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$d\test.ps1"
    "test exit $LASTEXITCODE"
} catch { "wrapper error: $_" } finally {
    Stop-Transcript | Out-Null
    New-Item "$d\done" | Out-Null
}
EOF
echo 'New-Item -ItemType Directory C:\sebtype-setup-test | Out-Null' | tps
if ! scp -q "$here/test.ps1" "$here/../mozc/TsfHost.cs" "$exe" "$out/run.ps1" TCSBackEnd:C:/sebtype-setup-test/; then
  echo "FAIL prepare: copying the inputs to TCSBackEnd failed"; cleanup; exit 1
fi

# test.ps1 in the Administrator session, elevated, through a one-off task (ssh runs outside it).
tps <<'EOF'
$a = New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\sebtype-setup-test\run.ps1'
$p = New-ScheduledTaskPrincipal -UserId Administrator -LogonType Interactive -RunLevel Highest
Register-ScheduledTask SebType-setup-test -Action $a -Principal $p -Force | Out-Null
Start-ScheduledTask SebType-setup-test
EOF

# The test user's session, once test.ps1 has made the user and written its logon.
tunnel= rdp=
for i in $(seq 1 60); do
  logon=$(echo 'Get-Content "$env:LOCALAPPDATA\SebType-setup-test\rdp-logon.txt" -ErrorAction SilentlyContinue' | tps | tr -d '\r')
  [ -n "$logon" ] && break
  [ "$(echo 'Test-Path C:\sebtype-setup-test\done' | tps | tr -d '\r')" = True ] && break
  sleep 5
done
if [ -n "${logon:-}" ]; then
  # Remote Desktop one way; the other way, the typing checks reach rdp-keys.py, which types into FreeRDP
  # on gamescope's display, so the keys reach Windows as a keyboard's scancodes.
  ssh -N -o ExitOnForwardFailure=yes -L 13389:127.0.0.1:3389 -R 127.0.0.1:47812:127.0.0.1:47812 TCSBackEnd & tunnel=$!
  sleep 3
  # The password is this run's own, for a user test.ps1 removes when it ends.
  gamescope --backend headless -W 1280 -H 800 -- bash -c 'python3 "$1" 47812 >"$2" 2>&1 & shift 2; exec xfreerdp "$@"' \
    _ "$here/../mozc/rdp-keys.py" "$out/rdp-keys.log" /v:127.0.0.1:13389 /u:"$(sed -n 1p <<<"$logon")" \
    /p:"$(sed -n 2p <<<"$logon")" /cert:ignore /size:1280x800 /audio-mode:none -clipboard \
    >"$out/freerdp.log" 2>&1 & rdp=$!
fi
finished=
for i in $(seq 1 360); do
  [ "$(echo 'Test-Path C:\sebtype-setup-test\done' | tps | tr -d '\r')" = True ] && { finished=1; break; }
  sleep 10
done
[ -n "$rdp" ] && { pkill -f "$here/../mozc/rdp-keys.py"; pkill -P "$rdp" 2>/dev/null; kill "$rdp" 2>/dev/null; }
[ -n "$tunnel" ] && kill "$tunnel" 2>/dev/null

mkdir -p "$out/logs"
scp -q -r 'TCSBackEnd:C:/sebtype-setup-test/out/*' 'TCSBackEnd:C:/sebtype-setup-test/run.log' "$out/logs/" 2>/dev/null
[ -z "$finished" ] && echo "FAIL test-run: test.ps1 didn't finish in 60 minutes (logs: $out/logs)"
for png in "$out"/logs/73-*.png; do
  [ -e "$png" ] && magick "$png" -resize '1000x1000>' "/tmp/sebtype/$(basename "$png")"
done
iconv -f UTF-8 "$out/logs/setup-results.txt" 2>/dev/null | sed 's/^\xef\xbb\xbf//' | grep -aE '^(PASS|FAIL|SKIP|BLOCKED|INFO) ' | tee "$out/results.txt"
[ -s "$out/results.txt" ] || echo "FAIL results: test.ps1 wrote no results (logs: $out/logs)"
cleanup > "$out/cleanup.txt"
state > "$out/after.txt"
if diff <(grep -v '^tasks' "$out/before.txt") <(grep -v '^tasks' "$out/after.txt") > "$out/state.diff"; then
  echo "PASS tcsbackend-as-found"
else
  echo "FAIL tcsbackend-as-found: see $out/state.diff"
fi
[ -n "$finished" ] && [ -s "$out/results.txt" ] && ! grep -aqE '^(FAIL|SKIP|BLOCKED) ' "$out/results.txt" && [ ! -s "$out/state.diff" ]
