<#
Checks that an uninstall or a language left out keeps the learned words its sync couldn't send (#271),
without SebType installed: setup.ps1's account steps (-User -Save, then -User -Undo or -Languages) with the
Configurator's sync before removal, as a throwaway local user, so nobody's own words, login or input
settings are touched. Made-up words; a throwaway login on sebtype_sync.py serving on this PC's localhost,
or no server at all ("offline"). One command, elevated, with Windows PowerShell (on TCSBackEnd, over ssh):

    powershell -NoProfile -ExecutionPolicy Bypass -File test-unsynced.ps1

Its folder holds this script, sebtype_sync.py (sync-server/), test-sync.py, python\ (Python's embeddable
package, python.ps1), fix\ (setup.ps1 and sebtype-configurator.exe to check) and optionally main\ (the
same from main: shows the words lost before the fix, as INFO). Results: one line per check in
out\unsynced-results.txt, logs next to it; exit 0 only if all pass. The user and its tasks are removed at
the end; Windows keeps its profile loaded until a restart, so a cleanup line names the profile to delete
after one. Not on a PC someone can't restart (YukaROG).
-Part user is the throwaway user's own part, run by the task.
#>
param([string]$Part, [string]$Dir, [string]$Scenario, [string]$Server, [string]$SyncPassword)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSCommandPath
$out = "$root\out"
$python = "$root\python\python.exe"
$syncUser = 'sebtype-sync-test'
$pcWord, $jaWord = '莫福姬', 'モフ試験語'

if ($Part -eq 'user') {
  # As the throwaway user: a SebType account with Chinese and Japanese and made-up learned words, sync's
  # login when there is a server address, then setup.ps1's step. Prints what happened, as key=value lines.
  # Continue: Windows PowerShell turns a program's stderr into errors, which Stop would end the run on.
  $ErrorActionPreference = 'Continue'
  $rime = "$env:APPDATA\Rime"; $mozc = "$env:USERPROFILE\AppData\LocalLow\Mozc"; $state = "$env:LOCALAPPDATA\SebType"
  function Setup([string[]]$a) {
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Dir\setup.ps1" @a 2>&1 | Out-String
    "exit=$LASTEXITCODE"; $o
  }
  function Py { & $python -I -X utf8 "$root\test-sync.py" @args; if ($LASTEXITCODE) { throw "test-sync.py $($args[0]) failed" } }
  if ($Scenario -ne 'restore') {
    Remove-Item $rime, $mozc, $state, "$env:APPDATA\SebType" -Recurse -Force -ErrorAction SilentlyContinue
    Setup '-User', '-Save'
    $j = Get-Content "$state\setup.json" -Raw | ConvertFrom-Json; $j.Chosen = @('zh', 'ja')
    $j | ConvertTo-Json -Depth 5 | Set-Content "$state\setup.json" -Encoding utf8
    New-Item -ItemType Directory -Force $rime, $mozc | Out-Null
    Set-Content "$rime\installation.yaml" 'installation_id: "sebtype-unsynced-test-pc"'
    $null = Py seed-rime $rime
    Py add-mozc "$mozc\user_dictionary.db" 'もふてすと' $jaWord
    if ($Server) {
      "$Server`n$syncUser`n$SyncPassword`n" | & "$Dir\sebtype-configurator.exe" --save-login 2>&1 | Out-String
      "save-login=$LASTEXITCODE"
    }
    Setup '-User', '-Undo'
  } else {
    Setup '-User', '-Languages', 'ja'  # dummy Mozc files: the language list fails after the words are back
  }
  $has = { param($file, $word) (Test-Path $file) -and [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($file)).Contains($word) }
  "rime-words=$(& $has "$rime\sync\sebtype-unsynced-test-pc\rime_ice.userdb.txt" $pcWord)"
  "mozc-words=$(& $has "$mozc\user_dictionary.db" $jaWord)"
  "kept-rime=$(& $has "$state\unsynced\Rime\sync\sebtype-unsynced-test-pc\rime_ice.userdb.txt" $pcWord)"
  "kept-mozc=$(& $has "$state\unsynced\Mozc\user_dictionary.db" $jaWord)"
  exit 0
}

New-Item -ItemType Directory -Force $out | Out-Null
$results = "$out\unsynced-results.txt"
Set-Content -Encoding utf8 $results ''
function Result($name, $status, $why = '') {
  $line = "$status $name$(if ($why) { ": $why" })"
  Add-Content -Encoding utf8 $results $line; Write-Host $line
}
# Preflight
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
$missing = @("$python", "$root\sebtype_sync.py", "$root\test-sync.py", "$root\fix\setup.ps1", "$root\fix\sebtype-configurator.exe" | Where-Object { -not (Test-Path $_) })
$why = if (-not $admin) { 'not elevated' } elseif ($missing) { "missing $($missing -join ', ')" }
  elseif (Get-ScheduledTask -TaskName 'SebType sync' -ErrorAction SilentlyContinue) { "this PC has a SebType sync task: SebType is installed" }
if ($why) { Write-Host "preflight: $why"; exit 1 }

$name = 'sebtype-unsynced'
$random = { -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ }) }
$password = (& $random) + 'aA1!'
$syncPassword = & $random  # throwaway, as the user's
# The user's profiles, this run's and any an earlier run left. Windows keeps a task user's profile loaded
# until a restart (also seen with test.ps1's sebtype-test), and a loaded one can't be deleted: those stay,
# for after a restart. A new user of the same name gets a profile folder of its own.
function Remove-Profiles {
  foreach ($p in @(Get-CimInstance Win32_UserProfile | Where-Object LocalPath -Like "*\$name*")) {
    try { $p | Remove-CimInstance } catch { }
  }
  @(Get-CimInstance Win32_UserProfile | Where-Object LocalPath -Like "*\$name*").LocalPath
}
$null = Remove-Profiles
$free = { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p }
$offline = "http://127.0.0.1:$(& $free)"  # nothing listens there
$port = & $free
$syncServer = $null  # not $server: that is -Server, a string
# Every variant's Configurator runs the sync client with the Python next to it, as installed.
$variants = @('main', 'fix' | Where-Object { Test-Path "$root\$_\setup.ps1" })
foreach ($v in $variants) { if (-not (Test-Path "$root\$v\python")) { Copy-Item "$root\python" "$root\$v\python" -Recurse } }
# -Languages ja wants Mozc's files next to setup.ps1; made-up ones do, as nothing loads them.
Set-Content "$root\fix\sebtype-mozc.dll" ''
Set-Content "$root\fix\mozc-keymap.tsv" "status`tkey`tcommand"

function As-User([string]$variant, [string]$scenario, [string]$url = '') {
  $log = "$out\unsynced-$variant-$scenario.log"
  Remove-Item $log -ErrorAction SilentlyContinue
  $a = "-NoProfile -ExecutionPolicy Bypass -Command & '$PSCommandPath' -Part user -Dir '$root\$variant' -Scenario $scenario -Server '$url' -SyncPassword '$syncPassword' *> '$log'"
  Register-ScheduledTask SebType-unsynced-test -Force -User $name -Password $password -RunLevel Limited `
    -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument $a) | Out-Null
  try {
    Start-ScheduledTask SebType-unsynced-test
    $deadline = (Get-Date).AddMinutes(4)
    do { Start-Sleep 2; $task = Get-ScheduledTask SebType-unsynced-test } while ($task.State -ne 'Ready' -and (Get-Date) -lt $deadline)
    if ($task.State -ne 'Ready') { Stop-ScheduledTask SebType-unsynced-test; throw "$variant $scenario ran over 4 minutes, see $log" }
    $info = Get-ScheduledTaskInfo SebType-unsynced-test
    if ($info.LastTaskResult -ne 0) { throw "$variant $scenario`: the task ended with $('0x{0:X}' -f $info.LastTaskResult), see $log" }
  } finally { Unregister-ScheduledTask SebType-unsynced-test -Confirm:$false }
  $text = Get-Content $log -Raw  # *> writes UTF-16
  $r = @{ log = $log; text = $text }
  foreach ($m in [regex]::Matches($text, '(?m)^([a-z-]+)=(\S*)')) { $r[$m.Groups[1].Value] = $m.Groups[2].Value }  # the last: exit= is setup.ps1's last step
  $r.sync = if ($text -match 'before learned words are deleted \(exit (-?\d+)\)') { $Matches[1] } else { 'none' }
  $r
}
function Check($check, [scriptblock]$body) {  # not $name: the body would see it as the user's
  try { Result $check PASS (& $body) } catch { Result $check FAIL $_.Exception.Message }
}
function Expect($r, [hashtable]$want) {
  $bad = @($want.Keys | Sort-Object | Where-Object { "$($r[$_])" -ne "$($want[$_])" } | ForEach-Object { "$_ $($r[$_]), not $($want[$_])" })
  if ($bad) { throw "$($bad -join '; '), see $($r.log)" }
  ($want.Keys | Sort-Object | ForEach-Object { "$_ $($r[$_])" }) -join ', '
}

try {
  $null = New-LocalUser $name -Password (ConvertTo-SecureString $password -AsPlainText -Force) -AccountNeverExpires -Description 'SebType test (#271), removed after it'
  # Log on as a batch job, for its task: Performance Log Users have it on Windows' client editions.
  Add-LocalGroupMember -SID 'S-1-5-32-559' -Member $name
  & icacls.exe $root /grant "${name}:(OI)(CI)RX" /T /Q | Out-Null
  & icacls.exe $out /grant "${name}:(OI)(CI)M" /T /Q | Out-Null

  if ('main' -in $variants) {
    try {
      $r = As-User main offline $offline
      Result 'main-offline-uninstall' INFO "before the fix: Configurator exit $($r.sync), setup exit $($r.exit), words left: Rime $($r['rime-words']) Mozc $($r['mozc-words']), kept: Rime $($r['kept-rime']) Mozc $($r['kept-mozc'])"
    } catch { Result 'main-offline-uninstall' INFO $_.Exception.Message }
  }
  Check 'offline-uninstall-keeps-words' {
    Expect (As-User fix offline $offline) @{ 'save-login' = 0; sync = 1; exit = 2; 'rime-words' = $false; 'mozc-words' = $false; 'kept-rime' = $true; 'kept-mozc' = $true }
  }
  Check 'kept-words-come-back-with-their-language' {
    Expect (As-User fix restore) @{ 'mozc-words' = $true; 'kept-mozc' = $false; 'kept-rime' = $true }
  }
  Check 'never-on-uninstall-deletes-words' {
    Expect (As-User fix never) @{ sync = 'none'; exit = 0; 'rime-words' = $false; 'mozc-words' = $false; 'kept-rime' = $false; 'kept-mozc' = $false }
  }
  Check 'synced-uninstall-deletes-words' {
    $null = $syncPassword | & $python -I "$root\sebtype_sync.py" adduser --data "$out\sync-server" --password-stdin $syncUser
    $script:syncServer = Start-Process $python -PassThru -NoNewWindow -RedirectStandardError "$out\unsynced-server.log" `
      -ArgumentList '-I', "`"$root\sebtype_sync.py`"", 'serve', '--data', "`"$out\sync-server`"", '--port', $port
    Start-Sleep 2
    $r = As-User fix synced "http://127.0.0.1:$port"
    $sent = @(Get-ChildItem "$out\sync-server" -Recurse -File | Where-Object Name -in 'rime_ice.userdb.txt', 'mozc_dictionary.txt').Count
    if ($sent -ne 2) { throw "the server got $sent of the 2 files, see $($r.log)" }
    Expect $r @{ 'save-login' = 0; sync = 0; exit = 0; 'rime-words' = $false; 'mozc-words' = $false; 'kept-rime' = $false; 'kept-mozc' = $false }
  }
} finally {
  if ($syncServer) { Stop-Process -Id $syncServer.Id -Force -ErrorAction SilentlyContinue }
  $user = Get-LocalUser $name -ErrorAction SilentlyContinue
  if ($user) {
    Get-ScheduledTask -TaskName 'SebType sync' -ErrorAction SilentlyContinue | Where-Object { $_.Principal.UserId -like "*$name" } | Unregister-ScheduledTask -Confirm:$false
    Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object UserName -like "*\$name" | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-LocalUser $name
  }
  $left = Remove-Profiles
  if ($left) { Result 'cleanup' INFO "restart Windows, then delete the profiles still loaded: $($left -join ', ')" }
  Remove-Item "$out\sync-server", "$root\fix\sebtype-mozc.dll", "$root\fix\mozc-keymap.tsv" -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item "$root\main\python", "$root\fix\python" -Recurse -Force -ErrorAction SilentlyContinue
}
exit [int](Select-String -Path $results -Pattern '^FAIL' -Quiet)
