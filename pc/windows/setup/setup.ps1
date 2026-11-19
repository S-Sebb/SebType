<#
SebType's Windows setup steps (#73), run by SebType's installer (sebtype.iss), which installs this file
in SebType's folder. Why each step exists: pc/windows/README.md.

  setup.ps1 -Machine -Languages en,zh,ja        # elevated: replaces the Weasel and Mozc SebType had before
  setup.ps1 -User -Save                         # as the user, first
  setup.ps1 -User -Languages en,zh,ja           # as the user: settings
  setup.ps1 -Machine -Undo / -User -Undo        # uninstall

-Languages lists SebType's languages to set up: en (the US layout first), zh (SebType's 中文: Rime with the
Chinese data) and ja (SebType's 日本語: Mozc). Both are profiles of SebType's text service (windows/, #190),
which Setup installs and registers next to this file with its server. A language set up before and left out now is removed as at
uninstall, its learned words deleted. Safe to rerun: an upgrade reruns both with the new files and keeps
learned words. -User saves how the account was before its first run (%LOCALAPPDATA%\SebType\setup.json
and backup\), and -User -Undo puts that back. -User logs to %LOCALAPPDATA%\SebType\setup.log; -Machine
to -Log.
Saved as UTF-8 with a BOM: Windows PowerShell 5.1 reads a file without one in the ANSI code page.
#>
param(
  [switch]$Machine,
  [switch]$User,
  [string]$Languages = '',
  [switch]$Undo,
  [switch]$Save,
  [string]$RimeData = '',
  [string]$Log
)
# Windows PowerShell 5.1, which every Windows has: PowerShell 7's language list cmdlets fail on some
# Windows versions (PowerShell issue #14102, seen on Server 2022).
$ErrorActionPreference = 'Stop'
# Started from PowerShell 7, Windows PowerShell inherits its PSModulePath, and finds PowerShell 7's
# modules (Microsoft.PowerShell.Utility's Get-FileHash) before its own, which it can't load (#299).
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
Set-StrictMode -Version Latest
$want = @(if (-not $Undo) { $Languages -split '[, ]+' | Where-Object { $_ } })
if ($want | Where-Object { $_ -notin 'en', 'zh', 'ja' }) { throw "-Languages takes en, zh and ja, not '$Languages'" }

# SebType's text service and its 中文 and 日本語 profiles (windows/src/tip/tip.h).
$Clsid = '{D4E5C593-4F73-475F-936C-0E29A6FE7A02}'
$ZhProfile = '{8AA7DDAC-A4B8-4437-9C0B-8698879EC987}'
$JaProfile = '{B148FB02-C235-45D6-996C-672C783ECD48}'
$ZhTip = "0804:$Clsid$ZhProfile"
$JaTip = "0411:$Clsid$JaProfile"
# What SebType installed before #190: Weasel's TSF ids (WeaselTSF/Globals.cpp) for Simplified Chinese, and
# Mozc's OSS text service and profile.
$WeaselClsid = '{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}'
$WeaselTip = "0804:${WeaselClsid}{3D02CAB6-2B8E-4781-BA20-1C9267529467}"
$MozcClsid = '{10A67BC8-22FA-4A59-90DC-2546652C56BF}'
$MozcProfile = '{186F700C-71CF-43FE-A00E-AACB1D9E6D3D}'
$MozcTip = "0411:$MozcClsid$MozcProfile"
$UsTip = '0409:00000409'
$Tags = @{ en = 'en-US'; zh = 'zh-Hans-CN'; ja = 'ja' }
$WeaselUninstall = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Weasel'  # Weasel's installer is 32-bit
$MachineKey = 'HKLM:\SOFTWARE\SebType'

function Get-RegValue([string]$key, [string]$name) {
  $item = Get-Item $key -ErrorAction SilentlyContinue
  if ($item) { $item.GetValue($name) }
}
# The installed Weasel: its folder, version and SebType build mark (null when not installed).
function Get-Weasel {
  $root = Get-RegValue 'HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel' WeaselRoot
  $uninst = Get-ItemProperty $WeaselUninstall -ErrorAction SilentlyContinue
  if (-not $root -or -not $uninst) { return $null }
  [pscustomobject]@{
    Root = $root
    Version = $uninst.DisplayVersion
    SebType = Get-RegValue $WeaselUninstall SebType
    Uninstaller = ($uninst.UninstallString -replace '"', '')
  }
}
function Get-MozcProduct {  # the OSS Mozc MSI's product code, if installed
  $key = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' |
    Where-Object { $_.GetValue('DisplayName') -eq 'Mozc' } | Select-Object -First 1
  if ($key) { $key.PSChildName }
}
$Server = Join-Path $PSScriptRoot 'sebtype-server.exe'
# This session's SebType server: /quit saves the learned words, and it lets go of the Rime folder.
function Get-Server { Get-Process sebtype-server -ErrorAction SilentlyContinue | Where-Object SessionId -EQ (Get-Process -Id $PID).SessionId }
function Stop-Server {
  if (Get-Server) {
    (Start-Process -PassThru -FilePath $Server -ArgumentList '/quit').WaitForExit()
    Get-Server | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    Get-Server | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Server | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue  # until it lets go of its mapped files
  }
}
# Mozc's server holds its files (SebType's from before #233, next to this file, or the Mozc SebType had
# before); without admin, only this user's own stop.
function Stop-Mozc {
  Get-Process mozc_* -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*\Mozc\*' -or $_.Path -like "$PSScriptRoot\*" } |
    Stop-Process -Force -ErrorAction SilentlyContinue
}
# Mozc in this session's SebType server reads its settings when it starts: /mozc has it save and close, and
# the next 日本語 key starts it again (no server: nothing to do).
function Restart-Mozc {
  if (Test-Path $Server) { (Start-Process -PassThru -FilePath $Server -ArgumentList '/mozc').WaitForExit() }
  Stop-Mozc
}


# ===================================================================================== the machine
if ($Machine) {
  if ($Log) { Start-Transcript -Append $Log | Out-Null }
  if (-not (Test-Path $MachineKey)) { New-Item $MachineKey | Out-Null }  # -Force would wipe an existing key's values
  # SebType's text service (registered by Setup) replaces the Weasel and Mozc SebType installed before
  # #190. Their learned words stay in the folders the text service uses.
  $w = Get-Weasel
  if ($w -and $w.SebType) {
    Write-Output "removing SebType's Weasel $($w.SebType)"
    Stop-Process -Name WeaselServer -Force -ErrorAction SilentlyContinue
    # -Wait here: the uninstaller reruns itself from %TEMP%, and -Wait waits for that copy too.
    Start-Process -Wait -FilePath $w.Uninstaller -ArgumentList '/S'
    for ($t = 0; (Test-Path $WeaselUninstall) -and $t -lt 60; $t++) { Start-Sleep 1 }
    if (Test-Path $WeaselUninstall) { throw "Weasel's uninstaller didn't remove Weasel" }
    # It leaves its text service's COM class, TSF categories and the empty Rime folder.
    Remove-Item "HKLM:\SOFTWARE\Classes\CLSID\$WeaselClsid", "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$WeaselClsid", 'HKLM:\SOFTWARE\WOW6432Node\Rime' -Recurse -ErrorAction SilentlyContinue
    Get-Item (Split-Path $w.Root) -ErrorAction SilentlyContinue | Where-Object { -not (Get-ChildItem $_.FullName -Force) } | Remove-Item
  }
  $product = Get-MozcProduct
  $installed = Get-RegValue $MachineKey Mozc
  if ($product -and $installed) {
    Write-Output "removing Mozc $installed"
    Stop-Mozc
    msiexec /x $product /qn /norestart | Out-Null
    if (Get-MozcProduct) { throw 'Mozc is still installed' }
    Remove-ItemProperty $MachineKey Mozc
  }
  if ($Undo) { Remove-Item $MachineKey -Recurse }
  Write-Output "machine: done ($(if ($Undo) { 'removed' } else { $want -join ',' }))"
  exit 0
}
if (-not $User) { throw 'say -Machine or -User' }


# ======================================================================================== the user
$RimeUser = Join-Path $env:APPDATA 'Rime'
$MozcUser = Join-Path $env:USERPROFILE 'AppData\LocalLow\Mozc'
$StateDir = Join-Path $env:LOCALAPPDATA 'SebType'
$StateFile = Join-Path $StateDir 'setup.json'
$ToggleKey = 'HKCU:\Keyboard Layout\Toggle'
$ToggleNames = 'Hotkey', 'Language Hotkey', 'Layout Hotkey'
if (-not $RimeData) { $RimeData = Join-Path $PSScriptRoot 'rime-data.zip' }  # not in param(): 5.1 leaves $PSScriptRoot empty there
New-Item -ItemType Directory -Force $StateDir | Out-Null
$UserLog = Join-Path $StateDir 'setup.log'
Start-Transcript -Append $UserLog | Out-Null
$warned = $false
# After an undo nothing of SebType's stays: its log and folders go too, unless something else is in them,
# or the log holds a warning about what may be left.
function Remove-UserFolder {
  Stop-Transcript | Out-Null
  if (-not $warned) { Remove-Item $UserLog }
  foreach ($dir in (Join-Path $StateDir 'backup'), $StateDir) {
    Get-Item $dir -ErrorAction SilentlyContinue | Where-Object { -not (Get-ChildItem $_.FullName -Force) } | Remove-Item
  }
}

# Get-WinUserLanguageList writes its list as one object, which the pipeline doesn't always unroll.
function Get-Languages {
  $list = Get-WinUserLanguageList
  @(for ($i = 0; $i -lt $list.Count; $i++) { [pscustomobject]@{ Tag = $list[$i].LanguageTag; Tips = @($list[$i].InputMethodTips) } })
}
function Set-Languages($languages) {
  $list = New-WinUserLanguageList $languages[0].Tag
  $list.Clear()
  foreach ($l in $languages) {
    $lang = New-Object Microsoft.InternationalSettings.Commands.WinUserLanguage $l.Tag
    $lang.InputMethodTips.Clear()
    foreach ($tip in $l.Tips) { $lang.InputMethodTips.Add($tip) }
    $list.Add($lang)
  }
  Set-WinUserLanguageList $list -Force -WarningAction SilentlyContinue
}
function Format-Languages($languages) { ($languages | ForEach-Object { "$($_.Tag)[$($_.Tips -join ',')]" }) -join ' ' }
# A missing key is no error (a new user has no hotkeys). reg.exe prints its result on stderr, which 5.1
# turns into a terminating error under Stop (2>$null doesn't stop that), so it runs in a Continue scope.
function Export-Key($key, $file) {
  & { $ErrorActionPreference = 'Continue'; reg.exe export $key $file /y 2>&1 | Out-Null }
  if ($LASTEXITCODE) { $null } else { $file }
}
function Import-Key($file) { & { $ErrorActionPreference = 'Continue'; reg.exe import $file 2>&1 | Out-Null } }
Add-Type -Namespace SebType -Name User32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, System.IntPtr c, uint d);
[DllImport("advapi32.dll", CharSet = CharSet.Unicode)] public static extern bool CredDeleteW(string target, uint type, uint flags);
'@
function Update-ToggleKeys { [void][SebType.User32]::SystemParametersInfo(0x5B, 0, [IntPtr]::Zero, 0) } # SPI_SETLANGTOGGLE

# Mozc's config is a mozc.config.Config protobuf. Sets session_keymap (41) = CUSTOM (0) and
# custom_keymap_table (42) = the TSV, keeping every other field, as pc/linux/setup-ime.sh does.
function Set-Keymap([byte[]]$data, [byte[]]$table) {
  function VarInt([uint64]$n) {
    $out = [Collections.Generic.List[byte]]::new()
    do { $b = [byte]($n -band 0x7F); $n = $n -shr 7; if ($n) { $b = $b -bor 0x80 }; $out.Add($b) } while ($n)
    $out.ToArray()
  }
  function ReadVarInt([ref]$i) {
    [uint64]$n = 0; $shift = 0
    do { $c = $data[$i.Value++]; $n = $n -bor ([uint64]($c -band 0x7F) -shl $shift); $shift += 7 } while ($c -band 0x80)
    $n
  }
  $before = [Collections.Generic.List[byte]]::new(); $after = [Collections.Generic.List[byte]]::new()
  $i = 0
  while ($i -lt $data.Length) {
    $start = $i; $key = ReadVarInt ([ref]$i)
    switch ($key -band 7) {
      0 { $null = ReadVarInt ([ref]$i) }
      1 { $i += 8 }
      2 { $n = ReadVarInt ([ref]$i); $i += $n }
      5 { $i += 4 }
      default { throw "config1.db: unexpected protobuf wire type $($key -band 7)" }
    }
    $field = $key -shr 3
    if ($field -lt 41) { $before.AddRange([byte[]]$data[$start..($i - 1)]) }
    elseif ($field -gt 42) { $after.AddRange([byte[]]$data[$start..($i - 1)]) }
  }
  [byte[]]($before + (VarInt (41 -shl 3)) + (VarInt 0) + (VarInt (42 -shl 3 -bor 2)) + (VarInt $table.Length) + $table + $after)
}

# Writes a *.custom.yaml patch, keeping the file's other patches: drops lines matching $drop, then puts
# $lines right under "patch:". Returns whether it changed the file.
function Set-RimePatch([string]$file, [string]$drop, [string[]]$lines) {
  $path = Join-Path $RimeUser $file
  $old = if (Test-Path $path) { @(Get-Content $path -Encoding utf8) } else { @() }
  $new = [Collections.Generic.List[string]]::new()
  $done = $false
  foreach ($l in @($old | Where-Object { $_ -notmatch $drop })) { $new.Add($l); if (-not $done -and $l -match '^patch:') { $new.AddRange($lines); $done = $true } }
  if (-not $done) { $new.Add('patch:'); $new.AddRange($lines) }
  if (($old -join "`n") -eq ($new -join "`n")) { return $false }
  [IO.File]::WriteAllLines($path, $new)  # UTF-8 without BOM, as Rime expects
  $true
}

# How the account was before SebType's first run, so -Undo can put it back. Written before anything changes.
if (Test-Path $StateFile) {
  $state = Get-Content $StateFile -Raw -Encoding utf8 | ConvertFrom-Json
} elseif ($Undo) {
  Write-Output 'user: nothing to undo'; Remove-UserFolder; exit 0
} else {
  $backup = Join-Path $StateDir "backup\$(Get-Date -Format yyyyMMdd-HHmmss)"
  New-Item -ItemType Directory -Force $backup | Out-Null
  $default = Get-WinDefaultInputMethodOverride
  $state = [pscustomobject][ordered]@{
    Backup = $backup
    Chosen = @()  # the languages SebType set up last time
    # Without SebType's own input methods: Windows adds a newly registered text service to every
    # logged-on user's list, so the machine step has put them there already.
    Languages = @(Get-Languages | ForEach-Object { $_.Tips = @($_.Tips | Where-Object { $_ -notin $ZhTip, $JaTip, $WeaselTip, $MozcTip }); $_ } | Where-Object { $_.Tips })
    DefaultInputMethod = if ($default) { $default.InputMethodTip } else { $null }
    LegacySwitchingMode = (Get-WinLanguageBarOption).IsLegacySwitchingMode
    Toggle = [pscustomobject]@{}
    # Windows prunes this user's text service settings (HKCU ...\CTF\TIP) when the language list changes.
    RegBackups = @(@((Export-Key 'HKCU\Control Panel\Input Method\Hot Keys' "$backup\hotkeys.reg"),
        (Export-Key 'HKCU\Software\Microsoft\CTF\TIP' "$backup\tip.reg")) | Where-Object { $_ })
    # The text services the account had settings for, without SebType's (see Languages).
    # A new account may have none yet (seen in #271's test user).
    TipKeys = @(Get-ChildItem 'HKCU:\Software\Microsoft\CTF\TIP' -ErrorAction SilentlyContinue | ForEach-Object PSChildName | Where-Object { $_ -notin $Clsid, $WeaselClsid, $MozcClsid })
    RimeSettingsExisted = Test-Path 'HKCU:\Software\Rime'
    # Another Rime or Mozc's folders from before SebType: the user's own, put back when SebType goes.
    RimeBackup = if (Test-Path $RimeUser) { "$backup\Rime" } else { $null }
    MozcBackup = if (Test-Path $MozcUser) { "$backup\Mozc" } else { $null }
  }
  foreach ($name in $ToggleNames) { $state.Toggle | Add-Member $name (Get-RegValue $ToggleKey $name) }
  if ($state.RimeBackup) { Copy-Item $RimeUser $state.RimeBackup -Recurse }
  if ($state.MozcBackup) { Copy-Item $MozcUser $state.MozcBackup -Recurse }
}
function Save-State { $state | ConvertTo-Json -Depth 5 | Set-Content $StateFile -Encoding utf8 }
Save-State
# -Save, before the machine step: removing the Weasel and Mozc SebType had before changes the account's
# settings, which would otherwise look like the account's own from before SebType.
if ($Save) { Write-Output 'user: saved how the account is before SebType'; Stop-Transcript | Out-Null; exit 0 }
$removed = @($state.Chosen | Where-Object { $_ -notin $want })

# Sync (#180): if sync was ever on, this account's learned words and dictionary go to the server first,
# before the steps below delete them (Decisions #2, #73). The Configurator's sync does it, with the
# login from Credential Manager. The server's copy is never deleted here; the Configurator's own button
# does that. When that sync fails (offline, say), the words it couldn't send aren't deleted but moved to
# $Unsynced (#271), and come back when their language is set up again; Setup's message says where (exit 2).
$SyncFile = Join-Path $StateDir 'sync.json'
$Unsynced = Join-Path $StateDir 'unsynced'
$unsent = $kept = $false
if ($removed -and (Test-Path $SyncFile)) {
  $p = Start-Process -Wait -PassThru (Join-Path $PSScriptRoot 'sebtype-configurator.exe') '--sync-before-removal'
  $unsent = $p.ExitCode -ne 0
  Write-Output "user: $(if ($unsent) { 'sync failed' } else { 'synced' }) before learned words are deleted (exit $($p.ExitCode))"
}
# Removes a language's learned words, or keeps them in $Unsynced when the sync couldn't send them.
function Remove-Words([string]$dir, [string]$name) {
  if (-not $unsent) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue; return 'deleted' }
  if (-not (Test-Path $dir)) { return 'deleted' }
  New-Item -ItemType Directory -Force $Unsynced | Out-Null
  Move-Item $dir (Join-Path $Unsynced $name)
  $script:kept = $true
  "kept in $Unsynced\$name, not synced"
}
# Words kept that way come back when their language is set up again. They replace what is there: at most
# the Rime or Mozc folder from before SebType, which SebType's folder started from, so it holds those too.
foreach ($l in @(@('zh', $RimeUser, 'Rime'), @('ja', $MozcUser, 'Mozc'))) {
  $from = Join-Path $Unsynced $l[2]
  if ($l[0] -in $want -and (Test-Path $from)) {
    if ($l[0] -eq 'zh') { Stop-Server } else { Restart-Mozc }
    New-Item -ItemType Directory -Force $l[1] | Out-Null
    Get-ChildItem $from -Force | ForEach-Object {
      Remove-Item (Join-Path $l[1] $_.Name) -Recurse -Force -ErrorAction SilentlyContinue
      Move-Item $_.FullName $l[1]
    }
    Remove-Item $from
    Write-Output "user: learned words back from $from"
  }
}
Get-Item $Unsynced -ErrorAction SilentlyContinue | Where-Object { -not (Get-ChildItem $_.FullName -Force) } | Remove-Item

# Chinese: the data the phone bundles (data/rime/build.sh), rime-ice's schemas and Lua with 白霜's
# dictionary, its tables prebuilt. librime uses them as they are because their sources aren't there.
# Learned words (*.userdb), *.custom.yaml and the user's custom_phrase.txt stay. The marker names the data
# and the librime it was deployed with, so a new librime redeploys it too.
$redeploy = $false
if ('zh' -in $want) {
  if (-not (Test-Path $Server)) { throw "SebType's text service isn't installed next to setup.ps1" }
  $marker = Join-Path $RimeUser 'sebtype-data.txt'
  $dataId = "$((Get-FileHash $RimeData -Algorithm SHA256).Hash) $((Get-FileHash (Join-Path $PSScriptRoot 'rime.dll') -Algorithm SHA256).Hash)"
  if ((Get-Content $marker -ErrorAction SilentlyContinue) -ne $dataId) {
    Write-Output "user: Chinese data into $RimeUser"
    Stop-Server
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "sebtype-rime-$PID"
    Expand-Archive $RimeData $tmp -Force
    if (Test-Path (Join-Path $RimeUser 'custom_phrase.txt')) { Remove-Item (Join-Path $tmp 'custom_phrase.txt') -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force $RimeUser | Out-Null
    # An app's text service may start a server again meanwhile, which maps the tables (#190): once more.
    try { Copy-Item (Join-Path $tmp '*') $RimeUser -Recurse -Force }
    catch { Write-Output "user: copy again after: $_"; Stop-Server; Copy-Item (Join-Path $tmp '*') $RimeUser -Recurse -Force }
    # An older dictionary source (the user's own rime-ice) would be compiled instead of the prebuilt table.
    Get-ChildItem (Join-Path $tmp 'build\*.table.bin') | ForEach-Object {
      Remove-Item (Join-Path $RimeUser "$($_.BaseName -replace '\.table$').dict.yaml") -ErrorAction SilentlyContinue }
    Remove-Item $tmp -Recurse -Force
    Set-Content $marker $dataId
    $redeploy = $true
  }
  # Chinese reads 中文, not 雾凇拼音, in Rime's schema menu (#69). The schema id stays
  # rime_ice, so learned words stay. Typo correction (#46) weighs a PC keyboard's neighbour keys.
  $redeploy = (Set-RimePatch 'rime_ice.custom.yaml' '^  (schema/name|sebtype_typo/keyboard):' @(
      '  schema/name: 中文  # SebType: Chinese reads 中文, not 雾凇拼音 (#69)'
      '  sebtype_typo/keyboard: pc  # SebType: typo correction for a PC keyboard (#46)')) -or $redeploy
  # 6 candidates per page (Decisions #2, #163; rime-ice has 5). Only when the user has no page size of their
  # own: the Configurator writes theirs here too. The Configurator shows 6 when there is none.
  if (-not (@(Get-Content (Join-Path $RimeUser 'default.custom.yaml') -Encoding utf8 -ErrorAction SilentlyContinue) -match '^  menu/page_size:')) {
    $redeploy = (Set-RimePatch 'default.custom.yaml' '^  menu/page_size:' @('  menu/page_size: 6  # SebType: 6 candidates per page (#163)')) -or $redeploy
  }
  # Ctrl+Shift+F switches 简/繁 at any time (Decisions #2, #36). Both keysyms, as Shift may send either.
  $redeploy = (Set-RimePatch 'default.custom.yaml' '^  (# SebType: Ctrl\+Shift\+F|key_binder/bindings/\+:$|  - \{ when: always, toggle: traditionalization, accept: Control\+Shift\+[fF] \})' @(
      '  # SebType: Ctrl+Shift+F switches 简/繁 (#36)'
      '  key_binder/bindings/+:'
      '    - { when: always, toggle: traditionalization, accept: Control+Shift+f }'
      '    - { when: always, toggle: traditionalization, accept: Control+Shift+F }')) -or $redeploy
}

# Japanese: Mozc's keymap gets a Shift tap for あ ⇄ English and Alt+` for あ ⇄ ア (pc/linux/mozc-keymap.tsv,
# Decisions #2, #117); every other setting stays. Mozc reads it only when it starts, and the account's
# server may run it already. So a changed keymap restarts this account's Mozc; the next key starts it again
# with the new keymap.
if ('ja' -in $want) {
  if (-not (Test-Path (Join-Path $PSScriptRoot 'sebtype-mozc.dll'))) { throw "Mozc isn't installed next to setup.ps1" }
  $db = Join-Path $MozcUser 'config1.db'
  # A new account has no config1.db yet. (An empty array from an if would arrive as $null.)
  $data = [byte[]]::new(0)
  if (Test-Path $db) { $data = [IO.File]::ReadAllBytes($db) }
  $new = Set-Keymap $data ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'mozc-keymap.tsv')))
  if ([Convert]::ToBase64String($data) -ne [Convert]::ToBase64String($new)) {
    New-Item -ItemType Directory -Force $MozcUser | Out-Null
    [IO.File]::WriteAllBytes($db, $new)
    Restart-Mozc
    Write-Output 'user: Mozc keymap'
  }
}

# The language list: SebType's languages first, EN (US layout first) → 中 (SebType's 中文 only) → 日
# (SebType's 日本語 only), which Win+Space cycles in this order; then the list from before SebType without them, then any
# language added since. -Undo puts the list from before back.
$now = Get-Languages
$sebtype = @($want | ForEach-Object { $Tags[$_] })
$en = $now | Where-Object Tag -EQ 'en-US'
$entry = @{
  en = [pscustomobject]@{ Tag = 'en-US'; Tips = @($UsTip) + @(if ($en) { $en.Tips | Where-Object { $_ -ne $UsTip } }) }
  zh = [pscustomobject]@{ Tag = 'zh-Hans-CN'; Tips = @($ZhTip) }
  ja = [pscustomobject]@{ Tag = 'ja'; Tips = @($JaTip) }
}
$list = @(foreach ($l in 'en', 'zh', 'ja') { if ($l -in $want) { $entry[$l] } }) +
  @($state.Languages | Where-Object { $_.Tag -notin $sebtype }) +
  @($now | Where-Object { $_.Tag -notin $sebtype -and $_.Tag -notin @($state.Languages.Tag) -and $_.Tag -notin $Tags.Values })
if ((Format-Languages $now) -ne (Format-Languages $list)) {
  Write-Output "user: input methods $(Format-Languages $list) (were $(Format-Languages $now))"
  Set-Languages $list
}
# Windows adds a new text service's profile for this user disabled, and a disabled one gets no keys and
# no tray icon (seen with Mozc on Server 2022).
foreach ($p in @(if ('zh' -in $want) { "0x00000804\$ZhProfile" }) + @(if ('ja' -in $want) { "0x00000411\$JaProfile" })) {
  $profileKey = "HKCU:\Software\Microsoft\CTF\TIP\$Clsid\LanguageProfile\$p"
  New-Item -Force $profileKey | Out-Null
  Set-ItemProperty $profileKey Enable 1 -Type DWord
}
# The settings Windows kept for the Weasel and Mozc SebType had before, which the machine step removed.
Remove-Item "HKCU:\Software\Microsoft\CTF\TIP\$WeaselClsid", "HKCU:\Software\Microsoft\CTF\TIP\$MozcClsid" -Recurse -ErrorAction SilentlyContinue
# Windows can take a while to apply a language list right after another change (over 10 s for a new
# account's first one, on TCSBackEnd).
for ($i = 0; $i -lt 120 -and (Format-Languages (Get-Languages)) -ne (Format-Languages $list); $i++) { Start-Sleep -Milliseconds 500 }
if ($i -eq 120) { throw "Windows didn't take the input methods $(Format-Languages $list)" }

# Chinese gone: its learned words with it; a Rime folder from before SebType comes back. After the list
# above: until then apps' text service would start the server again, which writes the Rime folder anew.
if ('zh' -in $removed) {
  Stop-Server
  $words = Remove-Words $RimeUser 'Rime'
  if ($state.RimeBackup) { Copy-Item $state.RimeBackup $RimeUser -Recurse }
  Remove-Item "HKCU:\Software\Microsoft\CTF\TIP\$Clsid\LanguageProfile\0x00000804", "HKCU:\Software\Microsoft\CTF\TIP\$WeaselClsid" -Recurse -ErrorAction SilentlyContinue
  if (-not $state.RimeSettingsExisted) { Remove-Item 'HKCU:\Software\Rime' -Recurse -ErrorAction SilentlyContinue }
  Write-Output "user: Chinese removed, its learned words $words"
}
if ('ja' -in $removed) {
  Restart-Mozc
  $words = Remove-Words $MozcUser 'Mozc'
  if ($state.MozcBackup) { Copy-Item $state.MozcBackup $MozcUser -Recurse }
  Remove-Item "HKCU:\Software\Microsoft\CTF\TIP\$Clsid\LanguageProfile\0x00000411", "HKCU:\Software\Microsoft\CTF\TIP\$MozcClsid" -Recurse -ErrorAction SilentlyContinue
  Write-Output "user: Japanese removed, its learned words $words"
}

if (-not $Undo) {
  # Win+Space is the only language switch: no Alt+Shift / Ctrl+Shift switch keys (3 = none), and one
  # language for every window, not one per window.
  if ($ToggleNames | Where-Object { "$(Get-RegValue $ToggleKey $_)" -ne '3' }) {
    Write-Output 'user: Alt+Shift and Ctrl+Shift switch keys off'
    New-Item $ToggleKey -Force | Out-Null
    foreach ($name in $ToggleNames) { Set-ItemProperty $ToggleKey $name '3' }
    Update-ToggleKeys
  }
  $bar = Get-WinLanguageBarOption
  if ($bar.IsLegacySwitchingMode) { Set-WinLanguageBarOption -UseLegacySwitchMode:$false -UseLegacyLanguageBar:$bar.IsLegacyLanguageBar }

  # Learning off from before #374 hid what was learned (rime-ice's enable_user_dict, Mozc's NO_HISTORY): the
  # Configurator moves it to sebtype.conf, which keeps using it, before the engines next start.
  $p = Start-Process -Wait -PassThru (Join-Path $PSScriptRoot 'sebtype-configurator.exe') '--migrate'
  Write-Output "user: learning settings $(if ($p.ExitCode) { "not migrated (exit $($p.ExitCode)), the Configurator tries again when it starts" } else { 'current' })"
  # The daily update check (#422): the Configurator's --check-updates as this user while they are logged
  # on, which its toast needs; a day missed runs at the next chance. A newer release shows a toast; the
  # Configurator's "Check for updates automatically" turns it off.
  Register-ScheduledTask 'SebType update check' -Force `
    -Action (New-ScheduledTaskAction -Execute (Join-Path $PSScriptRoot 'sebtype-configurator.exe') -Argument '--check-updates') `
    -Trigger (New-ScheduledTaskTrigger -Daily -At 12:00 -RandomDelay (New-TimeSpan -Hours 1)) `
    -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)) `
    -Principal (New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited) | Out-Null
  Write-Output 'user: daily update check scheduled'
  # Rime builds the data and patches when it redeploys: in this user's SebType server, or in /deploy
  # itself when none runs. It returns when Rime is done. Setup starts no server (from an elevated Setup it
  # would be out of the apps' reach): the text service starts it at the first key, the Run key at logon.
  if ($redeploy) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -PassThru -FilePath $Server -ArgumentList '/deploy'
    if (-not $p.WaitForExit(330000)) { Stop-Process -Id $p.Id -Force; throw "Rime's redeploy took over 5 minutes" }
    if ($p.ExitCode) { throw "Rime's redeploy failed ($($p.ExitCode))" }
    Write-Output "user: Rime redeployed in $([int]$t.Elapsed.TotalSeconds) s"
  }
  $state.Chosen = $want
  Save-State
  Write-Output "user: done ($($want -join ','))"
  if ($kept) { exit 2 }
  exit 0
}

# Undo: the rest of how the account was before SebType.
if ($state.DefaultInputMethod) { Set-WinDefaultInputMethodOverride -InputTip $state.DefaultInputMethod }
foreach ($f in $state.RegBackups) { Import-Key $f }
# Windows makes text service settings for the account as engines come and go (SebType's, and Microsoft's
# Japanese IME when Mozc goes): only the ones from before stay.
Get-ChildItem 'HKCU:\Software\Microsoft\CTF\TIP' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -notin @($state.TipKeys) } |
  Remove-Item -Recurse -ErrorAction SilentlyContinue
New-Item $ToggleKey -Force | Out-Null
foreach ($name in $ToggleNames) {
  $v = $state.Toggle.$name
  if ($null -eq $v) { Remove-ItemProperty $ToggleKey $name -ErrorAction SilentlyContinue } else { Set-ItemProperty $ToggleKey $name $v }
}
Update-ToggleKeys
$bar = Get-WinLanguageBarOption
if ($bar.IsLegacySwitchingMode -ne $state.LegacySwitchingMode) {
  Set-WinLanguageBarOption -UseLegacySwitchMode:$state.LegacySwitchingMode -UseLegacyLanguageBar:$bar.IsLegacyLanguageBar
}
# Sync's schedule, its login in Credential Manager (a generic credential, named as the keyring crate
# names it) and its files. The server's copy stays (Decisions #2). With the Configurator's schedule lock
# (sync.rs, schedule_locked), so a Configurator's startup refresh can't make the task again: it waits,
# then finds sync.json gone (#401). Released before the lock file goes, so none locks a new one meanwhile.
# A Configurator holds it for seconds; one stuck holding it (suspended, or waiting on schtasks) mustn't
# stop the uninstall: after 30 s, or on any error but the lock being held, this goes on without it.
$ScheduleLock = Join-Path $StateDir 'schedule.lock'
$lock = $unlocked = $null
try {
  $lock = if (Test-Path $StateDir) { [IO.File]::Open($ScheduleLock, 'OpenOrCreate', 'ReadWrite', 'ReadWrite, Delete') }
  $deadline = (Get-Date).AddSeconds(30)
  # Overlaps the Configurator's lock, all of the file; FileStream.Lock doesn't wait.
  while ($lock) {
    try { $lock.Lock(0, 1); break } catch {
      $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
      if (($e.HResult -band 0xFFFF) -ne 33) { throw }  # ERROR_LOCK_VIOLATION: someone holds it
      if ((Get-Date) -gt $deadline) { throw 'held for 30 s' }
      Start-Sleep -Milliseconds 100
    }
  }
} catch {
  $unlocked = "$($_.Exception.Message)"
  if ($lock) { $lock.Close(); $lock = $null }
}
& { $ErrorActionPreference = 'Continue'; schtasks.exe /delete /tn 'SebType sync' /f 2>&1 | Out-Null }
[void][SebType.User32]::CredDeleteW('login.SebType sync', 1, 0)  # CRED_TYPE_GENERIC
# The daily update check (#422), its state and downloads.
& { $ErrorActionPreference = 'Continue'; schtasks.exe /delete /tn 'SebType update check' /f 2>&1 | Out-Null }
Remove-Item (Join-Path $StateDir 'update.json'), (Join-Path $StateDir 'updates') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $SyncFile, (Join-Path $StateDir 'sync.lock'), (Join-Path $StateDir 'sebtype_sync.py') -Force -ErrorAction SilentlyContinue
if ($lock) { $lock.Close() }
Remove-Item $ScheduleLock -Force -ErrorAction SilentlyContinue
if ($unlocked) {
  $warned = $true
  $left = @(if (Get-ScheduledTask -TaskName 'SebType sync' -ErrorAction SilentlyContinue) { "the 'SebType sync' task" }) +
    @('sync.json', 'schedule.lock' | Where-Object { Test-Path (Join-Path $StateDir $_) })
  Write-Output ("user: warning: sync removed without its schedule lock ($unlocked); a SebType Configurator still running " +
    "may make the 'SebType sync' task again. Left: $(if ($left) { $left -join ', ' } else { 'nothing' })")
}
# SebType's own settings (the candidate window's).
$conf = Join-Path $env:APPDATA 'SebType\sebtype.conf'
Remove-Item $conf -ErrorAction SilentlyContinue
Get-Item (Split-Path $conf) -ErrorAction SilentlyContinue | Where-Object { -not (Get-ChildItem $_.FullName -Force) } | Remove-Item
Remove-Item $StateFile, $state.Backup -Recurse -Force
Write-Output 'user: undone; input methods, switch keys and per-window setting as before SebType'
Remove-UserFolder
if ($kept) { exit 2 }
exit 0
