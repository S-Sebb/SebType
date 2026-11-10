<#
Installs SebType's Mozc (#65) on Windows, or undoes it. Installing the MSI needs admin: Windows only
loads text services registered for the whole machine; it deletes a per-user registration.

    powershell -File pc/windows/mozc/install.ps1 <SebType-Mozc-...msi>   # elevated: install or update, safe to rerun
    powershell -File pc/windows/mozc/install.ps1                       # no admin: set up this user, Mozc installed
    powershell -File pc/windows/mozc/install.ps1 -Undo                 # remove it, put back what was there

Installing: build.ps1's MSI installs Mozc for the machine, then, for the user running this, Mozc's
keymap gets Alt+` and a Shift tap for あ ⇄ English (pc/linux/mozc-keymap.tsv, Decisions #2), and
Japanese in the language list gets only Mozc, after Chinese, so Win+Space cycles EN → 中 → 日.
Before the first install it saves the language list, the default input method, the input hotkeys,
this user's text service settings and Mozc's config1.db; -Undo puts them back and uninstalls Mozc
(elevated), unless it was installed before. Apps opened before an install see the new keymap once restarted.
#>
param([string]$Msi, [switch]$Undo)
# Runs in Windows PowerShell 5.1, which every Windows has; PowerShell 7's language list cmdlets
# fail on some Windows versions (PowerShell issue #14102, seen on Server 2022).
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Msi -and -not $admin) { throw 'run install.ps1 <msi> elevated (admin): Mozc installs for the whole machine' }

$clsid = '{10A67BC8-22FA-4A59-90DC-2546652C56BF}'    # Mozc's OSS text service
$profileId = '{186F700C-71CF-43FE-A00E-AACB1D9E6D3D}'
$mozcTip = "0411:$clsid$profileId"
$configDir = "$env:USERPROFILE\AppData\LocalLow\Mozc"
$state = "$env:LOCALAPPDATA\SebType\mozc-install.json"
$uninstall = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
function Get-MozcProduct {  # the OSS Mozc MSI's product code, if installed
    $key = Get-ChildItem $uninstall | Where-Object { $_.GetValue('DisplayName') -eq 'Mozc' } | Select-Object -First 1
    if ($key) { $key.PSChildName }
}

# Get-WinUserLanguageList outputs its list as one object; the parentheses unroll it.
function Get-Languages { @((Get-WinUserLanguageList) | ForEach-Object { @{ Tag = $_.LanguageTag; Tips = @($_.InputMethodTips) } }) }
function Set-Languages($list) {
    $ll = New-WinUserLanguageList $list[0].Tag
    $ll.Clear()
    foreach ($l in $list) {
        $lang = New-Object Microsoft.InternationalSettings.Commands.WinUserLanguage $l.Tag
        $lang.InputMethodTips.Clear()
        $l.Tips | ForEach-Object { $lang.InputMethodTips.Add($_) }
        $ll.Add($lang)
    }
    Set-WinUserLanguageList $ll -Force
}
# A missing key is no error (a new user has no hotkeys); reg.exe's stderr needs a Continue scope (see -Undo).
function Export-Key($key, $file) {
    & { $ErrorActionPreference = 'Continue'; reg.exe export $key $file /y 2>&1 | Out-Null }
    if ($LASTEXITCODE) { $null } else { $file }
}

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

if ($Undo) {
    if (-not (Test-Path $state)) { throw "nothing to undo: $state is missing" }
    $s = Get-Content $state -Raw | ConvertFrom-Json
    if (-not $s.MozcBefore -and -not $admin) { throw 'run install.ps1 -Undo elevated (admin): it uninstalls Mozc' }
    # Mozc's running server and renderer hold its text service: the language list change below
    # waits on them, and the uninstall can't remove their files. Without admin, only this user's own.
    Get-Process mozc_* -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*\Mozc\*' } | Stop-Process -Force -ErrorAction SilentlyContinue
    Set-Languages $s.Languages
    if ($s.DefaultInputMethod) { Set-WinDefaultInputMethodOverride -InputTip $s.DefaultInputMethod }
    # reg.exe import prints its result on stderr, which 5.1 turns into a terminating error under
    # ErrorActionPreference Stop (2>$null and 2>&1 do not stop that), so run it in a Continue scope.
    foreach ($f in $s.RegBackups) { & { $ErrorActionPreference = 'Continue'; reg.exe import $f 2>&1 | Out-Null } }
    if (-not $s.MozcBefore) {
        if ($product = Get-MozcProduct) { msiexec /x $product /qn /norestart | Out-Null }
        Remove-Item -Recurse -Force "HKCU:\Software\Microsoft\CTF\TIP\$clsid" -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $configDir -ErrorAction SilentlyContinue
    if ($s.ConfigBackup) { New-Item -ItemType Directory -Force $configDir | Out-Null; Copy-Item -Recurse "$($s.ConfigBackup)\*" $configDir }
    Remove-Item $state
    if ($s.Backup) { Remove-Item -Recurse -Force $s.Backup }
    Write-Host "undone: $(if ($s.MozcBefore) { 'Mozc kept (installed before)' } else { 'Mozc uninstalled' }); language list, default input method, hotkeys, text service settings and Mozc config put back"
    exit
}

if ($Msi) { $Msi = (Resolve-Path $Msi).Path }
elseif (-not (Get-MozcProduct)) { throw 'Mozc is not installed: run install.ps1 <msi> elevated first' }

# Save the state from before SebType's Mozc, once, so reruns keep it.
if (-not (Test-Path $state)) {
    $backup = "$env:LOCALAPPDATA\SebType\backup\$(Get-Date -Format yyyyMMdd-HHmmss)"
    New-Item -ItemType Directory -Force $backup | Out-Null
    $savedConfig = $null
    if (Test-Path $configDir) { $savedConfig = "$backup\Mozc"; Copy-Item -Recurse $configDir $savedConfig }
    # Windows prunes this user's text service settings (HKCU ...\CTF\TIP) when the language list changes.
    $regs = @(Export-Key 'HKCU\Control Panel\Input Method\Hot Keys' "$backup\hotkeys.reg"
        Export-Key 'HKCU\Keyboard Layout\Toggle' "$backup\toggle.reg"
        Export-Key 'HKCU\Software\Microsoft\CTF\TIP' "$backup\tip.reg") | Where-Object { $_ }
    $default = Get-WinDefaultInputMethodOverride
    if ($default) { $default = $default.InputMethodTip }
    New-Item -ItemType Directory -Force (Split-Path $state) | Out-Null
    @{ Languages = Get-Languages; DefaultInputMethod = $default; RegBackups = $regs; ConfigBackup = $savedConfig; Backup = $backup
        MozcBefore = [bool](Get-MozcProduct) } |
        ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $state
}

# Mozc itself, for the machine; its installer registers the text service and starts nothing.
if ($Msi) {
    $log = "$env:TEMP\sebtype-mozc-msi.log"
    msiexec /i $Msi /qn /norestart /l*v $log | Out-Null
    if (-not (Get-MozcProduct)) { throw "the MSI didn't install Mozc (log: $log)" }
}

# Keymap: Mozc's text service reads it once per app, when the app first loads it.
$table = [IO.File]::ReadAllBytes("$PSScriptRoot\..\..\linux\mozc-keymap.tsv")
$db = "$configDir\config1.db"
$data = if (Test-Path $db) { [IO.File]::ReadAllBytes($db) } else { [byte[]]@() }
New-Item -ItemType Directory -Force $configDir | Out-Null
[IO.File]::WriteAllBytes($db, (Set-Keymap $data $table))

# Japanese: Mozc only, after Chinese, so Win+Space goes EN → 中 → 日.
$langs = Get-Languages
$ja = @($langs | Where-Object { $_.Tag -like 'ja*' })[0]
if (-not $ja) { $ja = @{ Tag = 'ja' } }
$ja.Tips = @($mozcTip)
$rest = @($langs | Where-Object { $_.Tag -notlike 'ja*' })
$zh = [array]::FindLastIndex([object[]]$rest, [Predicate[object]] { param($l) $l.Tag -like 'zh*' })
$order = if ($zh -ge 0) { @($rest[0..$zh]) + $ja + @($rest | Select-Object -Skip ($zh + 1)) } else { $rest + $ja }
Set-Languages $order
# Windows adds a new text service's profile for this user disabled, and a disabled one gets no keys
# and no tray icon (seen on Server 2022).
$userProfile = "HKCU:\Software\Microsoft\CTF\TIP\$clsid\LanguageProfile\0x00000411\$profileId"
New-Item -Force $userProfile | Out-Null
Set-ItemProperty $userProfile Enable 1 -Type DWord
# Windows can take a few seconds to apply a language list right after another change.
for ($i = 0; $i -lt 20 -and -not (@((Get-WinUserLanguageList) | ForEach-Object { $_.InputMethodTips }) -contains $mozcTip); $i++) {
    Start-Sleep -Milliseconds 500
}
if ($i -eq 20) { throw "Windows didn't take Mozc into the language list" }
Write-Host "installed: $(if ($Msi) { Split-Path -Leaf $Msi } else { 'for this user' }); Japanese is Mozc for $env:USERNAME (undo: $PSCommandPath -Undo)"
