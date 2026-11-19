#!/usr/bin/env bash
# Tests SebType's installer (#73) on TCSBackEnd (Windows Server 2022) from nobara-pc, in the background,
# and puts TCSBackEnd back as found. One command, no arguments:
#   pc/windows/setup/test-tcsbackend.sh
# PERF_RUN=1 adds the timing check (round1-rime-p95), for the final performance run only (#54).
# ONLY=picnic runs only the Picnic candidate window's pictures (#162), with TCSBackEnd's own checks.
# ONLY=upgrade runs only the update from the SebType before #190 (Weasel and Mozc; its setup from the
# newest successful "Windows setup" run on main without windows/build.ps1), typing and uninstall, with
# TCSBackEnd's own checks.
# ONLY=sync runs only sync with your own server (#180): a local sebtype_sync.py with a throwaway login,
# made-up words both ways through the Configurator's task, and the uninstall's sync first (test.ps1).
# ONLY=compare runs the final performance run's comparison with Microsoft's input methods (#54);
# SOAK_MIN and COMPARE_IMES (comma-separated) narrow it.
# ONLY=not-ready runs only the tray key while 中文 or 日本語 isn't ready (#275): test-not-ready.ps1 in the
# test user's Remote Desktop session, its pictures in ~/scratch/SebType/<issue>/screens/windows-<SCALE>-<time>.
# ONLY=forget runs only forgetting learned words while the server runs (#375): test-forget.ps1 as the test user.
# ONLY=learned runs only Mozc's learned conversions sync (#409): test-learned-sync.ps1 as the test user.
# ONLY=private runs only private fields and the Configurator's learning off (#270, #374): test-private.ps1 in
# the test user's Remote Desktop session.
# SCALE=150 (100 to 500) sets the session's display scaling (Remote Desktop's desktop scale factor).
# It takes SebType-setup-*.exe (and for PERF_RUN perf-rime.exe) from the "Windows setup" CI run of this
# commit (gh), or else from build/, and pushes them (TCSBackEnd's downloads are fast, its uploads capped),
# runs test.ps1 elevated in the Administrator session (disconnected; the game backend there is never
# touched) and opens the test user's Remote Desktop session in FreeRDP inside headless gamescope (no
# window here, no sound) through an SSH tunnel, typing the typing checks' keys into FreeRDP
# (rdp-keys.py) so they arrive as a keyboard's. Needs gh, gamescope, xfreerdp, python3-xlib,
# ImageMagick and `ssh TCSBackEnd`. Output: one line per check; logs in $out, the installer's pages in
# ~/scratch/SebType/<issue>/73-*.png (117-*, 162-*, 205-*: the tray menus, the candidate window, the popup).
# Where the time went: $out/times.txt and logs/*-times.txt. Takes the device lock; exit 0 only if every check
# passes and TCSBackEnd ends as found.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
source "$repo/tools/lib.sh"
stamp=$(date +%Y%m%d-%H%M%S)
out=$TASK_OUT/73-setup-tcsbackend-$stamp  # each run its own: none deletes another's
lock=/tmp/agent-locks/devices/tcsbackend.lock
branch=$(git -C "$repo" branch --show-current)
if [ -z "${HOLDING:-}" ]; then
  exec env HOLDING=1 devq -w 3600 -m 75 -n "sebtype installer test on TCSBackEnd ($branch)" "$lock" bash "$0"
fi
mkdir -p "$out"
# Where a run's time goes: $out/times.txt here, logs/*-times.txt from test.ps1.
t0=$(date +%s)
mark() { echo "$(date +%T) +$(( $(date +%s) - t0 ))s $*" >> "$out/times.txt"; }
mark start

missing=
command -v gamescope >/dev/null && command -v xfreerdp >/dev/null && command -v magick >/dev/null && python3 -c 'import Xlib' 2>/dev/null ||
  missing='needs gamescope, xfreerdp, ImageMagick and python3-xlib'
# The setup CI built from this commit, else one built here into build/ (ISCC under Wine, from CI's other
# artifacts) while CI's Mozc build still runs.
head=$(git -C "$repo" rev-parse HEAD)
run=$(gh run list -R S-Sebb/SebType --workflow windows-setup.yml --commit "$head" --status success --json databaseId \
  -q '.[0].databaseId // empty' 2>/dev/null)
perf=
if [ -n "$run" ]; then
  gh run download -R S-Sebb/SebType "$run" -n sebtype-setup -D "$out/in" >/dev/null 2>&1 || missing=${missing:-"downloading sebtype-setup from run $run failed"}
  exe=$(ls "$out"/in/SebType-setup-*.exe 2>/dev/null | head -1)
  # perf-rime.exe (from the librime build), for the Rime per-key check against the librime the setup installed (#133)
  [ -n "${PERF_RUN:-}" ] && gh run download -R S-Sebb/SebType "$run" -n perf-rime -D "$out/in" >/dev/null 2>&1
else
  exe=$(ls -t "$repo"/build/SebType-setup-*.exe 2>/dev/null | head -1)
fi
[ -n "${PERF_RUN:-}" ] && perf=$(ls "$out"/in/perf-rime.exe "$repo"/build/rime/perf-rime.exe 2>/dev/null | head -1)
[ -n "$exe" ] || missing=${missing:-"no SebType-setup-*.exe: no successful Windows setup run for $head yet, none in build/"}
old=
if [ "${ONLY:-}" = upgrade ]; then
  git -C "$repo" fetch -q origin main
  for r in $(gh run list -R S-Sebb/SebType --workflow windows-setup.yml --branch main --status success --limit 50 \
      --json databaseId,headSha -q '.[] | "\(.databaseId):\(.headSha)"' 2>/dev/null); do
    git -C "$repo" cat-file -e "${r#*:}:windows/build.ps1" 2>/dev/null && continue
    gh run download -R S-Sebb/SebType "${r%%:*}" -n sebtype-setup -D "$out/old" >/dev/null 2>&1 && old=$(ls "$out"/old/SebType-setup-*.exe 2>/dev/null | head -1)
    break
  done
  [ -n "$old" ] || missing=${missing:-'no setup of the SebType before #190 from a main run'}
fi
echo "setup: ${exe:-none}${run:+ (CI run $run)}" > "$out/input.txt"
mark 'CI artifacts downloaded'
timeout 30 ssh -o BatchMode=yes TCSBackEnd 'echo ok' >/dev/null 2>&1 || missing=${missing:-'ssh TCSBackEnd fails: connect the SoftEther VPN'}
[ -n "$missing" ] && { echo "BLOCKED preflight: $missing"; exit 1; }

tps() {  # Windows PowerShell 5.1 on TCSBackEnd, script on stdin; output as text (not CLIXML), UTF-8
  local enc
  enc=$( (echo '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference="SilentlyContinue"'; cat) | iconv -t UTF-16LE | base64 -w0)
  timeout "${T:-120}" ssh TCSBackEnd "powershell -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand $enc" 2>&1 | grep -av '^#< CLIXML\|^<Objs' | tr -d '\r'
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
# A rename left pending in SebType's folder makes the next Setup ask for a restart, which TCSBackEnd never gets.
"pending renames in SebType's folder: $(@((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').PendingFileRenameOperations | Where-Object { $_ -like '*\Program Files\SebType*' }).Count)"
EOF
}
cleanup() {  # what a run that died may leave: its session, user, profile, SebType, Weasel, Mozc, tasks and files
  # Uninstalling a text service late can change the Administrator's language list: it goes back as found.
  { echo "\$adminLanguages = '$(sed -n 's/^languages: //p' "$out/before.txt")'"; cat; } <<'EOF' | T=900 tps
Get-ScheduledTask -TaskName SebType-setup*, 'SebType sync' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
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
if (-not (Test-Path $app)) { Remove-Item -Recurse -Force "$env:ProgramFiles\SebType" -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force C:\sebtype-setup-test, "$env:LOCALAPPDATA\SebType-setup-test" -ErrorAction SilentlyContinue
if ((((Get-WinUserLanguageList) | ForEach-Object { "$($_.LanguageTag)=$($_.InputMethodTips -join ',')" }) -join '; ') -ne $adminLanguages) {
    $list = $null
    foreach ($e in $adminLanguages -split '; ') {
        $tag, $tips = $e -split '=', 2
        if ($list) { $list.Add($tag) } else { $list = New-WinUserLanguageList $tag }
        $l = $list[$list.Count - 1]; $l.InputMethodTips.Clear(); $tips -split ',' | Where-Object { $_ } | ForEach-Object { $l.InputMethodTips.Add($_) }
    }
    Set-WinUserLanguageList $list -Force -WarningAction SilentlyContinue
    "Administrator's languages put back: $adminLanguages"
}
EOF
}

state > "$out/before.txt"
mark 'state before read'
grep -q '^installed: .' "$out/before.txt" && { echo "BLOCKED preflight: SebType, Weasel or Mozc is installed on TCSBackEnd already ($(grep '^installed:' "$out/before.txt"))"; exit 1; }
grep -q '^folders: .*True' "$out/before.txt" && { echo "BLOCKED preflight: a SebType or test folder exists on TCSBackEnd already ($(grep '^folders:' "$out/before.txt"))"; exit 1; }
grep -qE '^users: \S*\bsebtype-test\b' "$out/before.txt" && { echo "BLOCKED preflight: a sebtype-test user exists on TCSBackEnd already"; exit 1; }
grep -qE "^pending renames in SebType's folder: [1-9]" "$out/before.txt" && { echo "BLOCKED preflight: renames pending in C:\\Program Files\\SebType until a restart (Setup would ask for one)"; exit 1; }

# shellcheck disable=SC2016
sed "s/ PERFRUN/${PERF_RUN:+ -PerfRun}${ONLY:+ -Only $ONLY}${SOAK_MIN:+ -SoakMinutes $SOAK_MIN}${COMPARE_IMES:+ -CompareImes $COMPARE_IMES}/" > "$out/run.ps1" <<'EOF'
$d = 'C:\sebtype-setup-test'
Start-Transcript "$d\run.log" | Out-Null
try {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$d\test.ps1" PERFRUN
    "test exit $LASTEXITCODE"
} catch { "wrapper error: $_" } finally {
    Stop-Transcript | Out-Null
    New-Item "$d\done" | Out-Null
}
EOF
echo 'New-Item -ItemType Directory C:\sebtype-setup-test, C:\sebtype-setup-test\old | Out-Null' | tps
if [ -n "$old" ] && ! scp -q "$old" TCSBackEnd:C:/sebtype-setup-test/old/; then
  echo "FAIL prepare: copying the old setup to TCSBackEnd failed"; cleanup; exit 1
fi
if ! scp -q "$here/test.ps1" "$here/test-not-ready.ps1" "$here/test-forget.ps1" "$here/test-learned-sync.ps1" "$here/test-private.ps1" "$here/TsfHost.cs" "$here/../perf-rime.ps1" ${perf:+"$perf"} "$exe" "$out/run.ps1" \
  "$repo/sync-server/sebtype_sync.py" "$here/test-sync.py" TCSBackEnd:C:/sebtype-setup-test/; then
  echo "FAIL prepare: copying the inputs to TCSBackEnd failed"; cleanup; exit 1
fi
mark 'inputs uploaded'
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
mark 'test user logon read'
if [ -n "${logon:-}" ]; then
  # Remote Desktop one way; the other way, the typing checks reach rdp-keys.py, which types into FreeRDP
  # on gamescope's display, so the keys reach Windows as a keyboard's scancodes.
  # Retried: a forward can fail for a few seconds, e.g. while the last run's sshd still holds the port.
  for try in 1 2 3 4 5; do
    ssh -N -o ExitOnForwardFailure=yes -L 13389:127.0.0.1:3389 -R 127.0.0.1:47812:127.0.0.1:47812 TCSBackEnd 2>>"$out/tunnel.log" & tunnel=$!
    for i in $(seq 1 20); do ss -ltn | grep -q '127.0.0.1:13389 ' && break; kill -0 "$tunnel" 2>/dev/null || break; sleep 0.5; done
    sleep 2  # the remote forward is set up after the local one
    kill -0 "$tunnel" 2>/dev/null && ss -ltn | grep -q '127.0.0.1:13389 ' && break
    kill "$tunnel" 2>/dev/null; tunnel=; sleep 5
  done
  # The password is this run's own, for a user test.ps1 removes when it ends.
  gamescope --backend headless -W 1280 -H 800 -- bash -c 'python3 "$1" 47812 >"$2" 2>&1 & shift 2; exec xfreerdp "$@"' \
    _ "$here/rdp-keys.py" "$out/rdp-keys.log" /v:127.0.0.1:13389 /u:"$(sed -n 1p <<<"$logon")" \
    /p:"$(sed -n 2p <<<"$logon")" /cert:ignore /size:1280x800 /scale-desktop:"${SCALE:-100}" /audio-mode:none -clipboard \
    >"$out/freerdp.log" 2>&1 & rdp=$!
fi
mark 'Remote Desktop started'
finished=
for i in $(seq 1 720); do
  [ "$(echo 'Test-Path C:\sebtype-setup-test\done' | tps | tr -d '\r')" = True ] && { finished=1; break; }
  sleep 5
done
[ -n "$rdp" ] && { pkill -f "$here/rdp-keys.py"; pkill -P "$rdp" 2>/dev/null; kill "$rdp" 2>/dev/null; }
[ -n "$tunnel" ] && kill "$tunnel" 2>/dev/null

mark 'test.ps1 done'
mkdir -p "$out/logs"
# One file: scp pays a round trip per file, which made 60 files take a minute.
echo 'tar -cf C:\sebtype-setup-test\logs.tar -C C:\sebtype-setup-test\out . -C C:\sebtype-setup-test run.log' | tps >/dev/null
scp -q TCSBackEnd:C:/sebtype-setup-test/logs.tar "$out/" 2>/dev/null && tar -xf "$out/logs.tar" -C "$out/logs" && rm "$out/logs.tar"
[ -z "$finished" ] && echo "FAIL test-run: test.ps1 didn't finish in 60 minutes (logs: $out/logs)"
for png in "$out"/logs/73-*.png "$out"/logs/117-*.png "$out"/logs/162-*.png "$out"/logs/205-*.png; do
  [ -e "$png" ] && magick "$png" -resize '1000x1000>' "$TASK_OUT/$(basename "$png")"
done
if [ -d "$out/logs/275" ]; then
  screens=$TASK_OUT/screens/windows-${SCALE:-100}-$stamp
  mkdir -p "$screens"
  cp "$out"/logs/275/*.png "$out/logs/275/not-ready-results.txt" "$screens/" 2>/dev/null
fi
iconv -f UTF-8 "$out/logs/setup-results.txt" 2>/dev/null | sed 's/^\xef\xbb\xbf//' | grep -aE '^(PASS|FAIL|SKIP|BLOCKED|INFO) ' | tee "$out/results.txt"
[ -s "$out/results.txt" ] || echo "FAIL results: test.ps1 wrote no results (logs: $out/logs)"
mark 'logs fetched'
cleanup > "$out/cleanup.txt"
mark 'cleaned up'
state > "$out/after.txt"
mark 'state after read'
if diff <(grep -v '^tasks' "$out/before.txt") <(grep -v '^tasks' "$out/after.txt") > "$out/state.diff"; then
  echo "PASS tcsbackend-as-found"
else
  echo "FAIL tcsbackend-as-found: see $out/state.diff"
fi
[ -n "$finished" ] && [ -s "$out/results.txt" ] && ! grep -aqE '^(FAIL|SKIP|BLOCKED) ' "$out/results.txt" && [ ! -s "$out/state.diff" ]
