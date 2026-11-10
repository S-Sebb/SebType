#Requires -Version 7
<#
Tests setup-ime.ps1 on the Windows PC itself, from the folder pc/windows/stage.sh made. One command,
run three times, with the admin step it prints in between (installing and removing Weasel need admin):

  1. no setup yet: saves how the PC is, runs setup-ime.ps1 -NoAdmin, prints the admin install command;
  2. SebType's Weasel installed: runs setup-ime.ps1 (twice: the rerun must change nothing), checks the
     settings, types in a test window of its own (pinyin → candidates → commit, Shift tap, Ctrl+Shift+F
     简/繁, the a / A icon with Caps Lock, the Win+Space cycle), measures Rime (p95 ≤ 10 ms), then runs
     setup-ime.ps1 -Undo -NoAdmin and prints the admin uninstall command;
  3. Weasel removed: finishes the undo and checks the PC is as step 1 found it.

Keys go only to the test's own window, checked before every key; if it loses the focus, the typing
checks fail and nothing more is typed. Caps Lock and the input method are put back as found.
Results: results.txt (one line per check) next to this script; exit 0 only if every check passes.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot
$results = Join-Path $here 'results.txt'
$before = Join-Path $here 'before.json'
$setup = Join-Path $here 'setup-ime.ps1'
$state = Join-Path $env:LOCALAPPDATA 'SebType\windows-setup.json'
$rimeUser = Join-Path $env:APPDATA 'Rime'
$tipKey = 'HKLM:\SOFTWARE\Microsoft\CTF\TIP\{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}'
$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Weasel'
Set-Content $results $null
$script:failed = 0

function Result([string]$status, [string]$name, [string]$detail) {
  $line = "$status $name$(if ($detail) { ": $detail" })"
  Add-Content $results $line
  Write-Output $line
  if ($status -eq 'FAIL') { $script:failed++ }
}
function Check([string]$name, [bool]$ok, [string]$detail) { Result $(if ($ok) { 'PASS' } else { 'FAIL' }) $name $detail }
# Runs setup-ime.ps1 with a timeout; returns its output lines.
function Invoke-Setup([string[]]$arguments, [int]$seconds = 600) {
  $log = Join-Path $here "setup$($arguments -join '')-$(Get-Date -Format HHmmss).log"
  $p = Start-Process (Get-Process -Id $PID).Path -PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
    -ArgumentList (@('-NoProfile', '-File', "`"$setup`"") + $arguments)
  if (-not $p.WaitForExit($seconds * 1000)) { $p.Kill(); return @("timeout after $seconds s") }
  @(Get-Content $log) + @(Get-Content "$log.err" | ForEach-Object { "stderr: $_" })
}
function Get-Snapshot {
  $toggle = Get-ItemProperty 'HKCU:\Keyboard Layout\Toggle' -ErrorAction SilentlyContinue
  [ordered]@{
    Languages = (Get-WinUserLanguageList | ForEach-Object { "$($_.LanguageTag)[$($_.InputMethodTips -join ',')]" }) -join ' '
    Toggle = ('Hotkey', 'Language Hotkey', 'Layout Hotkey' | ForEach-Object { "$_=$(if ($toggle) { $toggle.PSObject.Properties[$_] | ForEach-Object Value })" }) -join ' '
    LegacySwitch = (Get-WinLanguageBarOption).IsLegacySwitchingMode
    RimeExists = Test-Path $rimeUser
    DefaultInputMethod = "$((Get-WinDefaultInputMethodOverride).InputMethodTip)"
    InstalledIMEs = (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\CTF\TIP' | ForEach-Object PSChildName | Sort-Object) -join ' '
    ImeHotKeys = (Get-ChildItem 'HKCU:\Control Panel\Input Method\Hot Keys' -ErrorAction SilentlyContinue | ForEach-Object {
        $k = Get-ItemProperty $_.PSPath; "$($_.PSChildName)=$($k.'Key Modifiers' -join ',')/$($k.'Virtual Key' -join ',')" }) -join ' '
  }
}
function Get-AdminCommand($out) {  # the line after setup-ime.ps1's "run this as administrator"
  for ($i = 0; $i -lt $out.Count - 1; $i++) { if ($out[$i] -match 'run this as administrator') { return $out[$i + 1] } }
}
function Check-AsBefore([string]$prefix, $snap) {
  $now = Get-Snapshot
  foreach ($k in $now.Keys) {
    Check "$prefix-$k" ("$($now[$k])" -eq "$($snap.$k)") "now $($now[$k]); before $($snap.$k)"
  }
}

# Preflight
if (-not $IsWindows) { Write-Output 'preflight: run this on Windows'; exit 1 }
foreach ($f in 'setup-ime.ps1', 'TypingTest.cs', 'perf-rime.exe', 'perf-rime.ps1', 'rime-ice.zip') {
  if (-not (Test-Path (Join-Path $here $f))) { Write-Output "preflight: $f missing next to this script (pc/windows/stage.sh)"; exit 1 }
}
$weasel = Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------ 1. before setup
if (-not (Test-Path $before)) {
  if (Test-Path $state) { Write-Output "preflight: a SebType setup is already recorded ($state); run setup-ime.ps1 -Undo first"; exit 1 }
  if ($weasel) { Write-Output "preflight: Weasel $($weasel.DisplayVersion) is already installed; this test starts without it"; exit 1 }
  Get-Snapshot | ConvertTo-Json | Set-Content $before
  $out = Invoke-Setup @('-NoAdmin')
  $out | Set-Content (Join-Path $here 'step1.log')
  $admin = Get-AdminCommand $out
  Check setup-records-state (Test-Path $state) $state
  Check setup-asks-admin-for-weasel ([bool]("$admin" -match 'sebtype-weasel-.*-installer\.exe')) "$admin"
  Write-Output "NEXT: run as admin, then run this script again:`n$admin"
  exit [int]($script:failed -gt 0)
}

# ------------------------------------------------------------------------- 3. after the uninstall
$snap = Get-Content $before -Raw | ConvertFrom-Json
if (-not $weasel) {
  $out = Invoke-Setup @('-Undo', '-NoAdmin')
  $out | Set-Content (Join-Path $here 'step3.log')
  Check undo-weasel-removed (-not (Test-Path $tipKey)) 'no Weasel uninstall entry or TSF registration'
  Check undo-state-removed (-not (Test-Path $state)) ''
  Check-AsBefore undo $snap
  if (-not $script:failed) { Remove-Item $before }
  exit [int]($script:failed -gt 0)
}
if (-not $weasel.PSObject.Properties['SebType']) { Write-Output "preflight: Weasel $($weasel.DisplayVersion) is installed but isn't SebType's build"; exit 1 }

# --------------------------------------------------------------------------- 2. installed: test
$root = (Get-ItemProperty 'HKLM:\SOFTWARE\Rime\Weasel').WeaselRoot
$out = Invoke-Setup @('-NoAdmin')
$out | Set-Content (Join-Path $here 'step2-setup.log')
Check setup-completes ([bool]($out -match '^done: .*, 0 warning\(s\)$')) "$($out | Select-Object -Last 1)"
$deploy = $out | Where-Object { $_ -match 'redeployed in (\d+) s' } | ForEach-Object { $Matches[1] }
if ($deploy) { Result INFO weasel-deploy "$deploy s" }
$out = Invoke-Setup @('-NoAdmin')
Check setup-rerun-changes-nothing ([bool]($out -match '^done: 0 change\(s\), 0 warning\(s\)$')) "$($out | Select-Object -Last 1)"

$snapNow = Get-Snapshot
Check input-methods-en-zh-ja ($snapNow.Languages -match '^en-US\[0409:00000409[^\]]*\] zh-Hans-CN\[0804:\{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A\}\{3D02CAB6-2B8E-4781-BA20-1C9267529467\}\]( ja\[|$)') $snapNow.Languages
Check switch-keys-off ($snapNow.Toggle -eq 'Hotkey=3 Language Hotkey=3 Layout Hotkey=3') $snapNow.Toggle
$desc = (Get-ItemProperty "$tipKey\LanguageProfile\0x00000804\{3D02CAB6-2B8E-4781-BA20-1C9267529467}" -ErrorAction SilentlyContinue).Description
Check label-zhongwen ($desc -eq '中文') "Win+Space shows '$desc'"
Check schema-name-zhongwen ([bool](Select-String -Quiet -Path "$rimeUser\rime_ice.custom.yaml" -Pattern '^  schema/name: 中文')) ''
Check rime-deployed (Test-Path "$rimeUser\build\rime_ice.schema.yaml") "$rimeUser\build"
Check weasel-server-running ([bool](Get-Process WeaselServer -ErrorAction SilentlyContinue)) ''

# Typing in the test's own window.
Add-Type -Path (Join-Path $here 'TypingTest.cs')
$capsBefore = [SebType.TypingWindow]::CapsLock
$win = [SebType.TypingWindow]::new('SebType typing test (#13)')
$win.IconDll = Join-Path $root 'weaselx64.dll'
$langBefore = $win.LanguageId
$typing = 'pinyin-commit', 'shift-tap-english', 'ctrl-shift-f-traditional', 'caps-lock-icon', 'win-space-cycle'
function Wait-Ms($ms) { Start-Sleep -Milliseconds $ms }
function Assert-Focus { if (-not $win.IsForeground -and -not $win.Activate()) { throw 'the test window lost the focus' } }
function Switch-To([int]$lang) {  # Win+Space until the window's input method is $lang
  for ($i = 0; $i -lt 4 -and $win.LanguageId -ne $lang; $i++) { $win.Chord(0x5B, 0, 0x20); Wait-Ms 700; Assert-Focus }
  if ($win.LanguageId -ne $lang) { throw ('input method is 0x{0:x4}, not 0x{1:x4}' -f $win.LanguageId, $lang) }
}
try {
  if (-not $win.Activate()) { throw 'the test window could not get the focus' }
  Switch-To 0x0804
  if ($win.LangBarIcon() -eq 'a') { $win.Tap(0xA0); Wait-Ms 300 }  # Chinese, not its English mode

  $win.Text = ''; $win.Type('ranhou'); Wait-Ms 400
  $cands = [SebType.TypingWindow]::CandidatesVisible()
  $win.Tap(0x20); Wait-Ms 400
  Check pinyin-commit ($cands -and $win.Text -eq '然后') "candidates shown: $cands, text '$($win.Text)'"

  $win.Text = ''; $win.Type('ni'); $win.Tap(0xA0); $win.Type('ok'); $win.Tap(0xA0); $win.Type('ranhou '); Wait-Ms 400
  Check shift-tap-english ($win.Text -eq 'niok然后') "text '$($win.Text)'"

  $win.Text = ''
  $win.Chord(0xA2, 0xA0, 0x46); Wait-Ms 300; $win.Type('houlai '); Wait-Ms 300
  $win.Chord(0xA2, 0xA0, 0x46); Wait-Ms 300; $win.Type('houlai '); Wait-Ms 400
  Check ctrl-shift-f-traditional ($win.Text -eq '後來后来') "text '$($win.Text)'"

  $win.Text = ''
  $icons = @($win.LangBarIcon())
  $win.Tap(0xA0); Wait-Ms 400; $icons += $win.LangBarIcon()
  $win.Tap(0x14); Wait-Ms 400; $icons += $win.LangBarIcon(); $caps = [SebType.TypingWindow]::CapsLock
  $win.Type('ab'); Wait-Ms 200; $typed = $win.Text
  $win.Tap(0x14); Wait-Ms 400; $icons += $win.LangBarIcon()
  Check caps-lock-icon ("$($icons[0..2] -join ' ')" -eq '中 a A' -and $caps -and $typed -eq 'AB') "icons $($icons -join ' → '), Caps Lock $caps, typed '$typed'"
  if ($win.LangBarIcon() -eq 'a') { $win.Tap(0xA0); Wait-Ms 300 }

  Switch-To 0x0409
  $seen = @()
  foreach ($i in 1..3) { $win.Chord(0x5B, 0, 0x20); Wait-Ms 700; $seen += '{0:x4}' -f $win.LanguageId; Assert-Focus }
  Check win-space-cycle (($seen -join ' ') -eq '0804 0411 0409') "EN → $($seen -join ' → ') (0804 中, 0411 日, 0409 EN)"
} catch {
  $message = $_.Exception.Message
  $done = @(Get-Content $results | ForEach-Object { ($_ -split '[ :]')[1] })
  foreach ($t in $typing | Where-Object { $_ -notin $done }) { Result FAIL $t "not run: $message" }
} finally {
  # Caps Lock and the input method back as found, while the window still has the focus.
  try {
    if ($win.IsForeground) {
      if ([SebType.TypingWindow]::CapsLock -ne $capsBefore) { $win.Tap(0x14) }
      Switch-To $langBefore
    }
  } catch { Result FAIL restore-input-method $_.Exception.Message }
  Check caps-lock-as-found ([SebType.TypingWindow]::CapsLock -eq $capsBefore) ''
  $win.Text = ''
  $win.Close()
}

# Rime speed: key → candidates on a copy of the user folder, with the installed rime.dll.
$perf = & (Join-Path $here 'perf-rime.ps1') -Root $root -Rime $rimeUser
$perf | Set-Content (Join-Path $here 'perf-rime.log')
$line = @($perf)[-1]
Result ($line -split ' ')[0] rime-p95-under-10ms ($line -replace '^\S+ rime-p95-under-10ms: ', '')

# Undo, as far as it goes without admin.
$out = Invoke-Setup @('-Undo', '-NoAdmin')
$out | Set-Content (Join-Path $here 'step2-undo.log')
Check-AsBefore undo-user $snap
$admin = Get-AdminCommand $out
Check undo-asks-admin-for-uninstall ([bool]("$admin" -match 'uninstall')) "$admin"
Write-Output "NEXT: run as admin, then run this script again:`n$admin"
exit [int]($script:failed -gt 0)
