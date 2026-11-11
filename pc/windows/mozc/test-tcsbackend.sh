#!/usr/bin/env bash
# Runs test.ps1 on TCSBackEnd (Windows Server 2022) from nobara-pc, in the background, and puts
# TCSBackEnd back as found (#65). One command, no arguments:
#   pc/windows/mozc/test-tcsbackend.sh
# test.ps1 runs elevated in the Administrator session (disconnected; the live game backend there is
# never touched). Its typing checks need a Remote Desktop session for its test user: this opens it with
# FreeRDP inside headless gamescope (no window here, no sound) through an SSH tunnel, and types the
# typing checks' keys into FreeRDP (rdp-keys.py), so they arrive as a keyboard's; test.ps1 logs it off. Needs the newest SebType-Mozc-*.msi from build.ps1 in build/ or ~/Downloads/xfer,
# gamescope, xfreerdp, python3-xlib and `ssh TCSBackEnd`. Output: one line per check; logs in $out. Takes the
# device lock; exit 0 only if every check passes and TCSBackEnd ends as found.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
out=/tmp/sebtype/mozc-tcsbackend
lock=/tmp/agent-locks/devices/tcsbackend.lock
if [ -z "${HOLDING:-}" ]; then
  exec env HOLDING=1 devq -w 1800 -m 20 -n "sebtype mozc test on TCSBackEnd ($(git -C "$repo" branch --show-current))" "$lock" bash "$0"
fi
mkdir -p "$out"; rm -f "$out"/*

msi=$(ls -t "$repo"/build/SebType-Mozc-*.msi ~/Downloads/xfer/*SebType-Mozc-*.msi 2>/dev/null | head -1)
python_url=https://www.python.org/ftp/python/3.13.17/python-3.13.17-embed-amd64.zip
python_sha=9e35319bffedab8b36ad44d8f377cb4f1733bcec257a0b6d04d94f01486ddb38
python_zip=~/.cache/sebtype/python-3.13.17-embed-amd64.zip
missing=
[ -n "$msi" ] || missing='no SebType-Mozc-*.msi in build/ or ~/Downloads/xfer: run build.ps1 and xfer it here'
command -v gamescope >/dev/null && command -v xfreerdp >/dev/null && python3 -c 'import Xlib' 2>/dev/null ||
  missing=${missing:-'needs gamescope, xfreerdp and python3-xlib'}
timeout 30 ssh -o BatchMode=yes TCSBackEnd 'echo ok' >/dev/null 2>&1 || missing=${missing:-'ssh TCSBackEnd fails: connect the SoftEther VPN'}
if [ -z "$missing" ] && ! echo "$python_sha  $python_zip" | sha256sum -c --status 2>/dev/null; then
  mkdir -p ~/.cache/sebtype
  curl -fsSL -o "$python_zip" "$python_url" && echo "$python_sha  $python_zip" | sha256sum -c --status ||
    missing="Python download failed or its sha256 differs ($python_url)"
fi
[ -n "$missing" ] && { echo "BLOCKED preflight: $missing"; exit 1; }

tps() {  # Windows PowerShell 5.1 on TCSBackEnd, script on stdin; output as text (not CLIXML), UTF-8
  local enc
  enc=$( (echo '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference="SilentlyContinue"'; cat) | iconv -t UTF-16LE | base64 -w0)
  timeout "${T:-120}" ssh TCSBackEnd "powershell -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand $enc" 2>&1 | grep -av '^#< CLIXML\|^<Objs'
}
state() {
  tps <<'EOF'
"sessions: $((query user 2>&1 | Select-Object -Skip 1 | ForEach-Object { $_.Trim() -replace '^(\S+)\s+(?:\S+\s+)?(\d+)\s+(\S+).*', '$1 $2 $3' }) -join ' | ')"
"languages: $(((Get-WinUserLanguageList) | ForEach-Object { "$($_.LanguageTag)=$($_.InputMethodTips -join ',')" }) -join '; ')"
"mozc installed: $([bool](Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall | Where-Object { $_.GetValue('DisplayName') -eq 'Mozc' }))"
"hkcu tip sha: $((reg.exe query 'HKCU\Software\Microsoft\CTF\TIP' /s | Out-String).GetHashCode())"
"hotkeys sha: $((reg.exe query 'HKCU\Control Panel\Input Method\Hot Keys' /s | Out-String).GetHashCode())"
"folders: $((Test-Path "$env:USERPROFILE\AppData\LocalLow\Mozc"), (Test-Path "$env:LOCALAPPDATA\SebType"), (Test-Path C:\sebtype-mozc), (Test-Path C:\sebtype-test), (Test-Path "$env:ProgramData\SebType-mozc-test"))"
"backend: $((Get-Process TaikoLocalServer -ErrorAction SilentlyContinue | ForEach-Object { "pid $($_.Id) session $($_.SessionId)" }) -join ', ')"
"users: $((Get-LocalUser).Name -join ',')  profiles: $((Get-CimInstance Win32_UserProfile).LocalPath -join ',')"
"remote desktop users: $((Get-LocalGroupMember -SID S-1-5-32-555).Name -join ',')"
"tasks: $((Get-ScheduledTask -TaskName SebType* -ErrorAction SilentlyContinue).TaskName -join ',')"
EOF
}
cleanup() {  # what a run that died may leave: its session, user, profile, Mozc, tasks and files
  T=600 tps <<'EOF'
Get-ScheduledTask -TaskName SebType* -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -match 'sebtype-test\\|SebType-mozc-test' |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# the session first: an account deleted while its session runs leaves its profile loaded until a reboot
query.exe session 2>$null | ForEach-Object { if ("$_" -match '\ssebtype-test\s+(\d+)\s') { logoff.exe $Matches[1] } }
if ($u = Get-LocalUser sebtype-test -ErrorAction SilentlyContinue) {
    for ($i = 0; $i -lt 60 -and (Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $u.SID.Value -and $_.Loaded }); $i++) { Start-Sleep 2 }
    Get-CimInstance Win32_UserProfile | Where-Object SID -EQ $u.SID.Value | Remove-CimInstance
    Remove-LocalUser sebtype-test
}
$p = Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall | Where-Object { $_.GetValue('DisplayName') -eq 'Mozc' }
if ($p) { Get-Process mozc_* -ErrorAction SilentlyContinue | Stop-Process -Force; msiexec /x $p.PSChildName /qn /norestart | Out-Null }
Remove-Item -Recurse -Force "$env:ProgramData\SebType-mozc-test", C:\sebtype-test, C:\sebtype-mozc, "$env:LOCALAPPDATA\SebType" -ErrorAction SilentlyContinue
EOF
}

state > "$out/before.txt"
grep -q 'mozc installed: True' "$out/before.txt" && { echo "BLOCKED preflight: Mozc is installed on TCSBackEnd already"; exit 1; }
grep -q 'folders: .*True' "$out/before.txt" && { echo "BLOCKED preflight: a test folder exists on TCSBackEnd already ($(grep folders: "$out/before.txt"))"; exit 1; }

# Inputs over scp (an -EncodedCommand this long passes cmd.exe's 8191-character limit).
tar -cf "$out/pc.tar" -C "$repo" pc/windows/mozc pc/windows/setup/setup.ps1 pc/linux
cat > "$out/run.ps1" <<'EOF'
$d = 'C:\sebtype-test'
Start-Transcript "$d\run.log" | Out-Null
try {
    $env:Path = "$d\python;$env:Path"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$d\pc\windows\mozc\test.ps1"
    "test exit $LASTEXITCODE"
} catch { "wrapper error: $_" } finally {
    Stop-Transcript | Out-Null
    New-Item "$d\done" | Out-Null
}
EOF
echo 'New-Item -ItemType Directory C:\sebtype-test, C:\sebtype-mozc\out | Out-Null' | tps
if ! { scp -q "$out/pc.tar" "$python_zip" "$out/run.ps1" TCSBackEnd:C:/sebtype-test/ && scp -q "$msi" "TCSBackEnd:C:/sebtype-mozc/out/SebType-Mozc-${msi##*SebType-Mozc-}"; } ||
   ! T=300 tps <<'EOF' | tee "$out/prepare.txt" | grep -q '^ready'
$d = 'C:\sebtype-test'
tar -xf "$d\pc.tar" -C $d; Expand-Archive "$d\python-3.13.17-embed-amd64.zip" "$d\python"
Remove-Item "$d\pc.tar", "$d\python-3.13.17-embed-amd64.zip"
if (Test-Path "$d\python\python.exe") { 'ready' }
EOF
then echo "FAIL prepare: copying the inputs to TCSBackEnd failed"; cleanup; exit 1; fi

# test.ps1 in the Administrator session, elevated, through a one-off task (ssh runs outside it).
tps <<'EOF'
$a = New-ScheduledTaskAction -Execute powershell.exe -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\sebtype-test\run.ps1'
$p = New-ScheduledTaskPrincipal -UserId Administrator -LogonType Interactive -RunLevel Highest
Register-ScheduledTask SebType-mozc-test -Action $a -Principal $p -Force | Out-Null
Start-ScheduledTask SebType-mozc-test
EOF

# The test user's session: once test.ps1 has written its logon (after speed, dictionary and install).
tunnel= rdp=
for i in $(seq 1 120); do
  logon=$(echo 'Get-Content "$env:LOCALAPPDATA\SebType\test\rdp-logon.txt" -ErrorAction SilentlyContinue' | tps | tr -d '\r')
  [ -n "$logon" ] && break
  [ "$(echo 'Test-Path C:\sebtype-test\done' | tps | tr -d '\r')" = True ] && break
  sleep 5
done
if [ -n "${logon:-}" ]; then
  # Remote Desktop one way; the other way, test.ps1's typing checks reach rdp-keys.py, which types into
  # FreeRDP on gamescope's display, so the keys reach Windows as a keyboard's scancodes.
  ssh -N -o ExitOnForwardFailure=yes -L 13389:127.0.0.1:3389 -R 127.0.0.1:47812:127.0.0.1:47812 TCSBackEnd & tunnel=$!
  sleep 3
  # The password is this run's own, for a user test.ps1 removes when it ends.
  gamescope --backend headless -W 1280 -H 800 -- bash -c 'python3 "$1" 47812 >"$2" 2>&1 & shift 2; exec xfreerdp "$@"' \
    _ "$here/rdp-keys.py" "$out/rdp-keys.log" /v:127.0.0.1:13389 /u:"$(sed -n 1p <<<"$logon")" \
    /p:"$(sed -n 2p <<<"$logon")" /cert:ignore /size:1280x800 /audio-mode:none -clipboard \
    >"$out/freerdp.log" 2>&1 & rdp=$!
fi
finished=
for i in $(seq 1 180); do
  [ "$(echo 'Test-Path C:\sebtype-test\done' | tps | tr -d '\r')" = True ] && { finished=1; break; }
  sleep 10
done
[ -n "$rdp" ] && { pkill -f "$here/rdp-keys.py"; pkill -P "$rdp" 2>/dev/null; kill "$rdp" 2>/dev/null; }
[ -n "$tunnel" ] && kill "$tunnel" 2>/dev/null

tps > "$out/results.txt" <<'EOF'
"--- run.log"; Get-Content C:\sebtype-test\run.log -Encoding utf8 -ErrorAction SilentlyContinue
"--- mozc-results.txt"; Get-Content "$env:LOCALAPPDATA\SebType\test\mozc-results.txt" -Encoding utf8 -ErrorAction SilentlyContinue
Get-ChildItem "$env:LOCALAPPDATA\SebType\test" -Exclude mozc-results.txt, *.png -ErrorAction SilentlyContinue | ForEach-Object { "--- $($_.Name)"; Get-Content $_.FullName -Encoding utf8 -Tail 60 }
EOF
# The pictures of the tray menu (#117).
scp -q 'TCSBackEnd:C:/Users/Administrator/AppData/Local/SebType/test/*.png' "$out/" 2>/dev/null
[ -z "$finished" ] && echo "FAIL test-run: test.ps1 didn't finish in 30 minutes (log: $out/results.txt)"
sed -n '/^--- mozc-results.txt/,/^--- /p' "$out/results.txt" | grep -aE '^(PASS|FAIL|SKIP|BLOCKED) '
cleanup >/dev/null
state > "$out/after.txt"
if diff <(grep -v '^tasks' "$out/before.txt") <(grep -v '^tasks' "$out/after.txt") > "$out/state.diff"; then
  echo "PASS tcsbackend-as-found"
else
  echo "FAIL tcsbackend-as-found: see $out/state.diff"
fi
[ -n "$finished" ] && ! grep -aqE '^(FAIL|SKIP|BLOCKED) ' "$out/results.txt" && [ ! -s "$out/state.diff" ]
