<#
An update's own side on Windows (#422), as the person who clicked Update..., not elevated: the Configurator
starts it from SebType's folder in Program Files with the download it checked.

    powershell -File update-user.ps1 -Setup <the download> -Sha <its SHA-256 from the release>
    powershell -File update-user.ps1 -NoSetup     # the tests': the person's steps only

Setup's steps for the person who runs it (sebtype.iss) run here, as this person, and Setup (start-setup.ps1,
elevated: one UAC prompt) does only the machine's, so an administrator who approves UAC for them gets none of
them. Prints "approved" once UAC is approved: the Configurator then closes, so Setup can replace it; exit 2
and "cancelled": UAC wasn't. After Setup: the person's steps, the download's folder removed, and the About
page opens again, with what failed if anything did (update-error.txt).
#>
param([string]$Setup, [string]$Sha, [switch]$NoSetup)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$App = $PSScriptRoot
$State = "$env:LOCALAPPDATA\SebType"
$approved = $false
function Fail($why) {
  if (-not $approved) { [Console]::Out.WriteLine("error: $why"); exit 1 }
  [IO.File]::WriteAllText((Join-Path $State 'update-error.txt'), $why)
  Start-Process "$App\sebtype-configurator.exe" '--update'
  exit 1
}
trap { Fail $_.Exception.Message }
function Step([string[]]$arguments) {
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$App\setup.ps1" @arguments 2>&1 | Out-Null
  # 2: done, but learned words a sync couldn't send were kept (setup.ps1, #271)
  if ($LASTEXITCODE -notin 0, 2) { Fail "setup.ps1 $arguments exited with $LASTEXITCODE (%LOCALAPPDATA%\SebType\setup.log)" }
}
# As Setup does first: this person's server saves the learned words and stops, and how the account is
# before SebType is kept (once).
if (Test-Path "$App\sebtype-server.exe") { Start-Process -Wait -WindowStyle Hidden "$App\sebtype-server.exe" '/quit' }
Step '-User', '-Save'
if (-not $NoSetup) {
  if ($Sha -notmatch '^[0-9a-fA-F]{64}$' -or $Setup.Contains('"')) { Fail "not a download and its SHA-256: $Setup $Sha" }
  # Start-Process joins the arguments with spaces: the path is quoted (no Windows path has a ").
  $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$App\start-setup.ps1`" -Setup `"$Setup`" -Sha $Sha"
  try { $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList $arguments }
  catch { [Console]::Out.WriteLine('cancelled'); exit 2 }
}
$approved = $true
[Console]::Out.WriteLine('approved'); [Console]::Out.Flush()
if (-not $NoSetup) {
  $p.WaitForExit()
  # The download stays until here: the admin side copies it once it runs.
  Remove-Item -Recurse -Force (Split-Path $Setup) -ErrorAction SilentlyContinue
  if ($p.ExitCode -eq 90) { Fail "the setup isn't the release's" }
  if ($p.ExitCode) { Fail "Setup exited with $($p.ExitCode) ($App\setup.log)" }
}
# The languages Setup set up, which it keeps for the next one.
$key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{5C1E7A52-3D8B-4F7E-9E0B-7B3B5A1C7354}_is1'
$languages = ((Get-ItemProperty $key).'Inno Setup: Selected Tasks' -split ',' | Where-Object { $_ -in 'en', 'zh', 'ja' }) -join ','
Step '-User', '-Languages', $languages
Start-Process "$App\sebtype-configurator.exe" '--update'
exit 0
