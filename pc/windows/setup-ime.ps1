#Requires -Version 5.1
<#
SebType Windows setup: Chinese with SebType's Weasel (小狼毫) and rime-ice, English as the plain US
layout, and Win+Space as the only language switch (EN → 中 → 日). Why each step exists: README.md here.

  setup-ime.ps1 [-DryRun] [-NoAdmin] [-Weasel <installer.exe>] [-RimeData <rime-ice.zip>]
  setup-ime.ps1 -Undo [-NoAdmin]

Safe to rerun. Changes this account's settings only, except installing or removing Weasel, which asks for
admin (UAC). -NoAdmin prints that admin command instead of running it. -DryRun changes nothing.
The first run saves what it changes to %LOCALAPPDATA%\SebType\windows-setup.json and backs up the Rime
folder; -Undo puts all of it back and removes SebType's Weasel if it wasn't there before.
-Weasel defaults to the newest sebtype-weasel-*-installer.exe next to this script and -RimeData to
rime-ice.zip next to it (pc/windows/stage.sh puts them there).
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Undo,
  [switch]$NoAdmin,
  [string]$Weasel,
  [string]$RimeData = (Join-Path $PSScriptRoot 'rime-ice.zip')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Weasel's TSF ids (WeaselTSF/Globals.cpp) for Simplified Chinese.
$WeaselTip = '0804:{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}{3D02CAB6-2B8E-4781-BA20-1C9267529467}'
$UsTip = '0409:00000409'
$UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Weasel'
$RimeUser = Join-Path $env:APPDATA 'Rime'
$StateDir = Join-Path $env:LOCALAPPDATA 'SebType'
$StateFile = Join-Path $StateDir 'windows-setup.json'
$ToggleKey = 'HKCU:\Keyboard Layout\Toggle'
$ToggleNames = 'Hotkey', 'Language Hotkey', 'Layout Hotkey'

$script:changes = 0
$script:todo = 0
function Change([string]$what) {
  $script:changes++
  if ($DryRun) { Write-Host "would: $what"; return $false }
  Write-Host "change: $what"
  return $true
}
# Messages go to the host, so functions that print return only their value.
function Warn([string]$what) { Write-Host "warning: $what"; $script:todo++ }

# Runs PowerShell code as administrator (UAC), or with -NoAdmin prints it for someone to run.
function Invoke-Admin([string]$code) {
  if ($NoAdmin) { Warn "needs admin; run this as administrator, then rerun:`n$code"; return $false }
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
  $p = Start-Process (Get-Process -Id $PID).Path -Verb RunAs -Wait -PassThru `
    -ArgumentList '-NoProfile', '-EncodedCommand', $encoded
  return $p.ExitCode -eq 0
}

# The installed Weasel: its folder, version and SebType build mark (null when not installed).
function Get-Weasel {
  $root = (Get-ItemProperty 'HKLM:\SOFTWARE\Rime\Weasel' -ErrorAction SilentlyContinue).WeaselRoot
  $uninst = Get-ItemProperty $UninstallKey -ErrorAction SilentlyContinue
  if (-not $root -or -not $uninst) { return $null }
  [pscustomobject]@{
    Root = $root
    Version = $uninst.DisplayVersion
    SebType = $uninst.PSObject.Properties['SebType'] | ForEach-Object Value
    Uninstaller = ($uninst.UninstallString -replace '"', '')
  }
}

function Get-Languages {
  @(Get-WinUserLanguageList | ForEach-Object {
      [pscustomobject]@{ Tag = $_.LanguageTag; Tips = @($_.InputMethodTips) } })
}
function Set-Languages($languages) {
  $list = New-WinUserLanguageList $languages[0].Tag
  for ($i = 1; $i -lt $languages.Count; $i++) { $list.Add($languages[$i].Tag) }
  for ($i = 0; $i -lt $languages.Count; $i++) {
    $list[$i].InputMethodTips.Clear()
    foreach ($tip in $languages[$i].Tips) { $list[$i].InputMethodTips.Add($tip) }
  }
  Set-WinUserLanguageList $list -Force -WarningAction SilentlyContinue
}
function Format-Languages($languages) { ($languages | ForEach-Object { "$($_.Tag)[$($_.Tips -join ',')]" }) -join ' ' }

# Windows reads the Alt+Shift / Ctrl+Shift switch keys from the registry when told to.
Add-Type -Namespace SebType -Name User32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, System.IntPtr c, uint d);
'@
function Update-ToggleKeys { [void][SebType.User32]::SystemParametersInfo(0x5B, 0, [IntPtr]::Zero, 0) } # SPI_SETLANGTOGGLE

function Stop-WeaselServer($w) {
  if (Get-Process WeaselServer -ErrorAction SilentlyContinue) {
    & (Join-Path $w.Root 'WeaselServer.exe') /quit
    Start-Sleep -Seconds 1
  }
}

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { throw 'setup-ime.ps1 runs on Windows only.' }

# ------------------------------------------------------------------------------------------- undo
if ($Undo) {
  if (-not (Test-Path $StateFile)) { Write-Output 'nothing to undo: no SebType setup recorded'; exit 0 }
  $state = Get-Content $StateFile -Raw | ConvertFrom-Json
  $w = Get-Weasel
  if ((Format-Languages (Get-Languages)) -ne (Format-Languages $state.Languages) -and
    (Change "input methods back to $(Format-Languages $state.Languages)")) { Set-Languages @($state.Languages) }
  if ((Get-WinLanguageBarOption).IsLegacySwitchingMode -ne $state.LegacySwitchingMode -and
    (Change "'a different input method for each app window' back to $($state.LegacySwitchingMode)")) {
    $bar = Get-WinLanguageBarOption
    Set-WinLanguageBarOption -UseLegacySwitchMode:$state.LegacySwitchingMode -UseLegacyLanguageBar:$bar.IsLegacyLanguageBar
  }
  $now = Get-ItemProperty $ToggleKey -ErrorAction SilentlyContinue
  $differs = $ToggleNames | Where-Object {
    "$(if ($now) { $now.PSObject.Properties[$_] | ForEach-Object Value })" -ne "$($state.Toggle.$_)" }
  if ($differs -and (Change 'language switch keys (Alt+Shift, Ctrl+Shift) back as they were')) {
    New-Item $ToggleKey -Force | Out-Null
    foreach ($name in $ToggleNames) {
      if ($null -eq $state.Toggle.$name) { Remove-ItemProperty $ToggleKey $name -ErrorAction SilentlyContinue }
      else { Set-ItemProperty $ToggleKey $name $state.Toggle.$name }
    }
    Update-ToggleKeys
  }
  # sebtype-data.txt marks a Rime folder that setup filled; the one restored from the backup has none.
  if (Test-Path (Join-Path $RimeUser 'sebtype-data.txt')) {
    $aside = Join-Path $state.Backup "rime-at-undo-$(Get-Date -Format yyyyMMdd-HHmmss)"
    if (Change "Rime folder back as it was before setup; the current one moves to $aside") {
      if ($w) { Stop-WeaselServer $w }
      if (Test-Path $RimeUser) { Move-Item $RimeUser $aside }
      if ($state.RimeExisted) { Copy-Item (Join-Path $state.Backup 'rime') $RimeUser -Recurse }
    }
  }
  if ($w -and -not $state.WeaselBefore -and (Change "uninstall SebType's Weasel $($w.SebType) (admin)")) {
    $code = "Start-Process -Wait -FilePath '$($w.Uninstaller)' -ArgumentList '/S'; " +
    "`$t = 0; while ((Test-Path '$UninstallKey') -and `$t++ -lt 60) { Start-Sleep 1 }; exit [int](Test-Path '$UninstallKey')"
    if (Invoke-Admin $code) { Write-Output "removed SebType's Weasel" }
  } elseif ($w -and $state.WeaselBefore) {
    Warn "Weasel $($state.WeaselBefore) was installed before; SebType's build stays until you reinstall that one"
  }
  # The record stays until Weasel is gone too, so a rerun after the admin step finishes the undo.
  if (-not $DryRun -and ($state.WeaselBefore -or -not (Get-Weasel))) {
    Remove-Item $StateFile
    Write-Output "undone; backups stay in $($state.Backup)"
  }
  if ($DryRun) { Write-Output "dry run: $script:changes change(s) to make, $script:todo warning(s)" }
  else { Write-Output "done: $script:changes change(s), $script:todo warning(s)" }
  exit 0
}

# ------------------------------------------------------------------------------------------ setup
if (-not $Weasel) {
  $Weasel = Get-ChildItem $PSScriptRoot -Filter 'sebtype-weasel-*-installer.exe' |
    Sort-Object LastWriteTime | Select-Object -Last 1 | ForEach-Object FullName
}
if (-not $Weasel -or -not (Test-Path $Weasel)) { throw "SebType's Weasel installer not found (-Weasel)" }
if (-not (Test-Path $RimeData)) { throw "Chinese data not found: $RimeData (-RimeData)" }
$Weasel = (Resolve-Path $Weasel).Path
$RimeData = (Resolve-Path $RimeData).Path
if ((Split-Path -Leaf $Weasel) -notmatch '^sebtype-weasel-(.+)-installer\.exe$') { throw "unexpected installer name: $Weasel" }
$wantWeasel = $Matches[1]

# What the first run changes, so -Undo can put it back. Written before anything changes.
if (-not (Test-Path $StateFile) -and -not $DryRun) {
  $backup = Join-Path $StateDir "backup\$(Get-Date -Format yyyyMMdd-HHmmss)"
  New-Item -ItemType Directory -Force $backup | Out-Null
  $toggle = Get-ItemProperty $ToggleKey -ErrorAction SilentlyContinue
  $before = Get-Weasel
  $state = [ordered]@{
    Backup = $backup
    Languages = Get-Languages
    LegacySwitchingMode = (Get-WinLanguageBarOption).IsLegacySwitchingMode
    Toggle = [ordered]@{}
    RimeExisted = Test-Path $RimeUser
    WeaselBefore = if ($before) { $before.Version } else { $null }
  }
  foreach ($name in $ToggleNames) { $state.Toggle[$name] = if ($toggle) { $toggle.PSObject.Properties[$name] | ForEach-Object Value } }
  if ($state.RimeExisted) { Copy-Item $RimeUser (Join-Path $backup 'rime') -Recurse }
  $state | ConvertTo-Json -Depth 5 | Set-Content $StateFile -Encoding utf8
  Write-Output "saved the current settings to $StateFile (undo: $PSCommandPath -Undo)"
}
$redeploy = $false

# 1. SebType's Weasel: upstream Weasel plus the 中文 name and the Caps Lock icon (weasel/sebtype.patch).
$w = Get-Weasel
if (-not $w -or $w.SebType -ne $wantWeasel) {
  $what = if ($w) { "replace Weasel $($w.Version) with SebType's $wantWeasel" } else { "install SebType's Weasel $wantWeasel" }
  if (Change "$what (admin)") {
    if (-not (Invoke-Admin "Start-Process -Wait -FilePath '$Weasel' -ArgumentList '/S'")) {
      if (-not $NoAdmin) { throw "Weasel's installer failed" }
    }
    $w = Get-Weasel
  }
}
if (-not $w -or $w.SebType -ne $wantWeasel) {
  if (-not $DryRun) { Warn "SebType's Weasel isn't installed yet; the rest still applies once it is" }
}

# 2. Chinese data: rime-ice, the same files Linux and the phone use (pc/windows/stage.sh). It goes
# into Weasel's user folder; learned words, *.custom.yaml and the user's custom_phrase.txt stay.
# The marker names the data and the Weasel it was deployed with, so a new Weasel redeploys it too and
# restarts WeaselServer as this user (the installer starts it as administrator).
$marker = Join-Path $RimeUser 'sebtype-data.txt'
$dataId = "$((Get-FileHash $RimeData -Algorithm SHA256).Hash) $(if ($w) { $w.SebType })"
if ((Get-Content $marker -ErrorAction SilentlyContinue) -ne $dataId -and
  (Change "install the Chinese data from $(Split-Path -Leaf $RimeData) into $RimeUser")) {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) "sebtype-rime-$PID"
  Expand-Archive $RimeData $tmp -Force
  if (Test-Path (Join-Path $RimeUser 'custom_phrase.txt')) { Remove-Item (Join-Path $tmp 'custom_phrase.txt') -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force $RimeUser | Out-Null
  Copy-Item (Join-Path $tmp '*') $RimeUser -Recurse -Force
  Remove-Item $tmp -Recurse -Force
  Set-Content $marker $dataId
  $redeploy = $true
}

# Writes a *.custom.yaml patch, keeping the file's other patches: drops lines matching $drop, then
# puts $lines right under "patch:".
function Set-RimePatch([string]$file, [string]$drop, [string[]]$lines, [string]$what) {
  $path = Join-Path $RimeUser $file
  $old = if (Test-Path $path) { @(Get-Content $path -Encoding utf8) } else { @() }
  $kept = @($old | Where-Object { $_ -notmatch $drop })
  $new = [Collections.Generic.List[string]]::new()
  $done = $false
  foreach ($l in $kept) { $new.Add($l); if (-not $done -and $l -match '^patch:') { $new.AddRange($lines); $done = $true } }
  if (-not $done) { $new.Add('patch:'); $new.AddRange($lines) }
  if (($old -join "`n") -ne ($new -join "`n") -and (Change "$what in $path")) {
    New-Item -ItemType Directory -Force $RimeUser | Out-Null
    [IO.File]::WriteAllLines($path, $new)  # UTF-8 without BOM, as Rime expects
    $script:redeploy = $true
  }
}

# 3. Chinese reads 中文, not 雾凇拼音, in Rime's schema menu and Weasel's status (#69). Weasel shows the
# whole name, so no "." prefix as on Linux. The schema id stays rime_ice, so learned words stay.
Set-RimePatch 'rime_ice.custom.yaml' '^  schema/name:' `
  @('  schema/name: 中文  # SebType: Chinese reads 中文, not 雾凇拼音 (#69)') 'name the Chinese schema 中文'

# 4. Ctrl+Shift+F switches 简/繁 at any time (Decisions #2, #36). Both keysyms, as Shift may send either.
Set-RimePatch 'default.custom.yaml' '^  (# SebType: Ctrl\+Shift\+F|key_binder/bindings/\+:$|  - \{ when: always, toggle: traditionalization, accept: Control\+Shift\+[fF] \})' @(
  '  # SebType: Ctrl+Shift+F switches 简/繁 (#36)'
  '  key_binder/bindings/+:'
  '    - { when: always, toggle: traditionalization, accept: Control+Shift+f }'
  '    - { when: always, toggle: traditionalization, accept: Control+Shift+F }') 'Ctrl+Shift+F for 简/繁'

# 5. Input methods: EN (US layout) → 中 (Weasel only) → 日 (as it was), then any other languages.
# Win+Space cycles them in this order.
$now = Get-Languages
$rest = @($now | Where-Object { $_.Tag -notin 'en-US', 'zh-Hans-CN' })
$en = $now | Where-Object Tag -EQ 'en-US'
$enTips = @($UsTip) + @(if ($en) { $en.Tips | Where-Object { $_ -ne $UsTip } })
$want = @([pscustomobject]@{ Tag = 'en-US'; Tips = $enTips }, [pscustomobject]@{ Tag = 'zh-Hans-CN'; Tips = @($WeaselTip) }) +
  @($rest | Where-Object Tag -EQ 'ja') + @($rest | Where-Object Tag -NE 'ja')
if ($w -and (Format-Languages $now) -ne (Format-Languages $want) -and
  (Change "input methods to $(Format-Languages $want) (was $(Format-Languages $now))")) {
  Set-Languages $want
}

# 6. Win+Space is the only language switch: no Alt+Shift / Ctrl+Shift switch keys (3 = none), and
# one language for every window, not one per window.
$toggle = Get-ItemProperty $ToggleKey -ErrorAction SilentlyContinue
if (($ToggleNames | Where-Object { -not $toggle -or "$($toggle.PSObject.Properties[$_] | ForEach-Object Value)" -ne '3' }) -and
  (Change 'turn off the Alt+Shift and Ctrl+Shift language switch keys')) {
  New-Item $ToggleKey -Force | Out-Null
  foreach ($name in $ToggleNames) { Set-ItemProperty $ToggleKey $name '3' }
  Update-ToggleKeys
}
$bar = Get-WinLanguageBarOption
if ($bar.IsLegacySwitchingMode -and (Change "turn off 'a different input method for each app window'")) {
  Set-WinLanguageBarOption -UseLegacySwitchMode:$false -UseLegacyLanguageBar:$bar.IsLegacyLanguageBar
}

# 7. Weasel applies the data and patches when it redeploys. WeaselServer runs as this user.
if ($w -and $w.SebType -eq $wantWeasel -and -not $DryRun) {
  if ($redeploy) { Stop-WeaselServer $w }
  if (-not (Get-Process WeaselServer -ErrorAction SilentlyContinue)) {
    Start-Process (Join-Path $w.Root 'WeaselServer.exe')
    Start-Sleep -Seconds 1
  }
  if ($redeploy) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    Start-Process (Join-Path $w.Root 'WeaselDeployer.exe') -ArgumentList '/deploy' -Wait
    Write-Output "change: Weasel redeployed in $([int]$t.Elapsed.TotalSeconds) s"
  }
}

if ($DryRun) { Write-Output "dry run: $script:changes change(s) to make, $script:todo warning(s)" }
else { Write-Output "done: $script:changes change(s), $script:todo warning(s)" }
