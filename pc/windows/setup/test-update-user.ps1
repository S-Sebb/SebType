<#
An update's own side (#422, pc/configurator/src/update-user.ps1, next to this script), as the logged-on person,
not elevated: test.ps1's -Only update runs it as its test user once Setup has upgraded SebType with
/NOUSERSTEPS. Run without its Setup ($Elevated empty: UAC can't be clicked here), it must run Setup's steps for
the person as this person: setup.ps1 -User -Save and -User with the languages Setup keeps, whose update task
then runs as this person. Results: one line per check in <Out>\update-user-results.txt; exit 0 only if all pass.

    powershell -ExecutionPolicy Bypass -File test-update-user.ps1 [-Out <folder>]
#>
param([string]$Out = "$env:USERPROFILE\scratch\SebType\422", [switch]$AnyDisplay)
$ErrorActionPreference = 'Stop'
$app = "$env:ProgramFiles\SebType"
New-Item -ItemType Directory -Force $Out | Out-Null
$results = "$Out\update-user-results.txt"
Set-Content -Encoding utf8 $results ''
function Result($name, $status, $why = '') {
  $line = "$status $name$(if ($why) { ": $why" })"
  Add-Content -Encoding utf8 $results $line; Write-Host $line
}
function Check($name, [scriptblock]$body) {
  try { $why = & $body; Result $name PASS $why } catch { Result $name FAIL $_.Exception.Message }
}

Check 'update-user-steps-as-the-person' {
  # The update task Setup's -User made comes again only from this run's -User, as whoever runs it.
  Unregister-ScheduledTask 'SebType update check' -Confirm:$false -ErrorAction SilentlyContinue
  $userLog = "$env:LOCALAPPDATA\SebType\setup.log"
  $before = @(Get-Content -Encoding utf8 $userLog -ErrorAction SilentlyContinue).Count
  $v = { param($s) "([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)))')))" }
  $script = "`$App = $(& $v $app)`n`$State = $(& $v "$env:LOCALAPPDATA\SebType")`n`$Elevated = ''`n" + (Get-Content -Raw "$PSScriptRoot\update-user.ps1")
  $said = & powershell.exe -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))) 2>&1
  $code = $LASTEXITCODE
  # the About page it opens afterwards (no window here: no OpenGL over Remote Desktop)
  Start-Sleep 2; Get-Process sebtype-configurator -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  $said = ($said | Out-String).Trim()
  if ($code -ne 0 -or $said -ne 'approved') { throw "exit $code, said '$said'" }
  if (Test-Path "$env:LOCALAPPDATA\SebType\update-error.txt") { throw "update-error.txt: $(Get-Content -Raw "$env:LOCALAPPDATA\SebType\update-error.txt")" }
  $new = (Get-Content -Encoding utf8 $userLog | Select-Object -Skip $before) -join "`n"
  if ($new -notmatch 'user: input methods') { throw "no -User step in setup.log since: $new" }
  $t = Get-ScheduledTask 'SebType update check' -ErrorAction SilentlyContinue
  if (-not $t -or $t.Principal.UserId -notmatch "\b$([regex]::Escape($env:USERNAME))$") { throw "the update task runs as '$($t.Principal.UserId)'" }
  "as $env:USERNAME: -User -Save and -User ran ($(([regex]::Match($new, 'user: input methods[^\r\n]*')).Value)); the update task runs as $($t.Principal.UserId)"
}
if (Select-String -Path $results -Pattern '^FAIL' -Quiet) { exit 1 }
exit 0
