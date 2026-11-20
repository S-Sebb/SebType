# An update's own side on Windows (#422), as the person who clicked Update…, not elevated: the
# Configurator builds it in and passes it as -EncodedCommand, after lines that set $App (SebType's folder),
# $State (SebType's folder of the person's) and $Elevated (start-setup.ps1 with its values, encoded; for
# the tests only, empty: no Setup).
# Setup's steps for the person who runs it (sebtype.iss) run here, for this person, and Setup with
# /NOUSERSTEPS does only the machine's: an administrator who approves UAC for them gets none of them.
# Prints "approved" once UAC is approved: the Configurator then closes, so Setup can replace it; 2 and
# "cancelled": UAC wasn't. After Setup, the person's steps; then the About page opens again, with what
# failed if anything did (update-error.txt).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
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
if ($Elevated) {
  try { $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $Elevated }
  catch { [Console]::Out.WriteLine('cancelled'); exit 2 }
}
$approved = $true
[Console]::Out.WriteLine('approved'); [Console]::Out.Flush()
if ($Elevated) {
  $p.WaitForExit()
  if ($p.ExitCode -eq 90) { Fail "the setup isn't the release's" }
  if ($p.ExitCode) { Fail "Setup exited with $($p.ExitCode) ($App\setup.log)" }
}
# The languages Setup set up, which it keeps for the next one.
$key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{5C1E7A52-3D8B-4F7E-9E0B-7B3B5A1C7354}_is1'
$languages = ((Get-ItemProperty $key).'Inno Setup: Selected Tasks' -split ',' | Where-Object { $_ -in 'en', 'zh', 'ja' }) -join ','
Step '-User', '-Languages', $languages
Start-Process "$App\sebtype-configurator.exe" '--update'
exit 0
