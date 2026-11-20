<#
The daily update check (#422), on a Windows PC with SebType installed, in the logged-on person's own session
(not elevated; test-tcsbackend.sh's ONLY=update runs it as its test user). One command:

    powershell -ExecutionPolicy Bypass -File test-update.ps1 [-Out <folder>]

A release served on this PC with Setup's Python stands in for GitHub, through the Configurator's test build
(sebtype-configurator-update-test.exe next to this script, CI's artifact of that name), the one that takes
SEBTYPE_UPDATE_URL: nothing is downloaded or installed. Checked: the Configurator's --check-updates finds the newer release, keeps
it in update.json and shows its toast under SebType Configurator's AppUserModelID; a second check doesn't show
it again; a click's sebtype-configurator: link opens the Configurator's About page. Results: one line per
check in <Out>\update-results.txt; exit 0 only if all pass.
#>
param([string]$Out = "$env:USERPROFILE\scratch\SebType\422", [switch]$AnyDisplay)
$ErrorActionPreference = 'Stop'
$app = "$env:ProgramFiles\SebType"
New-Item -ItemType Directory -Force $Out | Out-Null
$results = "$Out\update-results.txt"
Set-Content -Encoding utf8 $results ''
function Result($name, $status, $why = '') {
  $line = "$status $name$(if ($why) { ": $why" })"
  Add-Content -Encoding utf8 $results $line; Write-Host $line
}
function Check($name, [scriptblock]$body) {
  try { $why = & $body; Result $name PASS $why } catch { Result $name FAIL $_.Exception.Message }
}
if (-not (Test-Path "$app\sebtype-configurator.exe")) { Write-Host 'BLOCKED preflight: SebType is not installed'; exit 1 }
$test = "$PSScriptRoot\sebtype-configurator-update-test.exe"
if (-not (Test-Path $test)) { Write-Host "BLOCKED preflight: no $test"; exit 1 }

$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
function Toasts { @([Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory('SebType.Configurator') | ForEach-Object { $_.Content.GetXml() }) }
function Check-Updates {
  $p = Start-Process -PassThru $test '--check-updates'
  if (-not $p.WaitForExit(120000)) { Stop-Process -Id $p.Id -Force; throw '--check-updates ran over 2 minutes' }
  if ($p.ExitCode) { throw "--check-updates exited with $($p.ExitCode)" }
}

$site = "$Out\release"
New-Item -ItemType Directory -Force $site | Out-Null
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $listener.Start()
$port = $listener.LocalEndpoint.Port; $listener.Stop()
$url = "http://127.0.0.1:$port"
$assets = 'SebType-setup-99.0.0.exe', 'sebtype-99.0.0-1.fc44.x86_64.rpm' | ForEach-Object { @{ name = $_; size = 1; browser_download_url = "$url/$_" } }
[IO.File]::WriteAllText("$site\latest.json", (@{ tag_name = 'v99.0.0'; assets = $assets } | ConvertTo-Json -Depth 4))
# Setup's Python serves it from a copy: the uninstall removes {app}\python, which it would hold.
Copy-Item -Recurse "$app\python" "$Out\python"
$server = Start-Process "$Out\python\python.exe" -PassThru -WindowStyle Hidden -ArgumentList '-I', '-m', 'http.server', $port, '--bind', '127.0.0.1', '--directory', "`"$site`""
$env:SEBTYPE_UPDATE_URL = "$url/latest.json"
try {
  $deadline = (Get-Date).AddSeconds(30)
  while (-not $(try { (New-Object Net.Sockets.TcpClient '127.0.0.1', $port).Close(); $true } catch { $false })) {
    if ((Get-Date) -gt $deadline) { throw "no release server on $url" }; Start-Sleep -Milliseconds 300
  }
  $before = (Toasts).Count
  Check 'update-found-and-toast-shown' {
    Check-Updates
    $u = Get-Content -Raw "$env:LOCALAPPDATA\SebType\update.json" | ConvertFrom-Json
    if ($u.latest -ne '99.0.0' -or $u.notified -ne '99.0.0') { throw "update.json: $($u | ConvertTo-Json -Compress)" }
    $new = @(Toasts | Select-Object -Skip $before)
    if ($new.Count -ne 1 -or $new[0] -notmatch 'SebType 99\.0\.0' -or $new[0] -notmatch 'launch="sebtype-configurator:update"') { throw "toasts: $($new -join ' | ')" }
    "update.json has 99.0.0; one toast: $($new[0])"
  }
  Check 'update-toast-once' {
    Check-Updates
    if ((Toasts).Count -ne $before + 1) { throw "$((Toasts).Count - $before) toasts after two checks" }
    'no second toast for the same release'
  }
  Check 'update-toast-opens-about' {
    $command = (Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\sebtype-configurator\shell\open\command' -ErrorAction SilentlyContinue).'(default)'
    if ($command -ne "`"$app\sebtype-configurator.exe`" --update") { throw "sebtype-configurator: opens '$command'" }
    # The window may not open here (no OpenGL in TCSBackEnd's Remote Desktop session), so any Configurator
    # the link starts counts, however briefly it runs: nothing else starts one meanwhile.
    Start-Process 'sebtype-configurator:update'
    $deadline = (Get-Date).AddSeconds(30)
    while (-not ($w = Get-Process sebtype-configurator -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 20 }
    $p = Start-Process -PassThru "$app\sebtype-configurator.exe" '--update'
    $alive = -not $p.WaitForExit(10000)
    $direct = if ($alive) { Stop-Process -Id $p.Id -Force; 'stays open' } else { "exits with $($p.ExitCode) after $([int]($p.ExitTime - $p.StartTime).TotalMilliseconds) ms" }
    if (-not $w) { throw "the link started no Configurator in 30 s; started directly with --update it $direct" }
    $w | Stop-Process -Force -ErrorAction SilentlyContinue
    "opens $command; with --update the Configurator $direct"
  }
} finally {
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  [Windows.UI.Notifications.ToastNotificationManager]::History.Clear('SebType.Configurator')
}
if (Select-String -Path $results -Pattern '^FAIL' -Quiet) { exit 1 }
exit 0
