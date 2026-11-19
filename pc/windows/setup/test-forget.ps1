<#
Forget learned words while SebType's server runs (#375), on a Windows PC with SebType installed, in the
logged-on person's own session (not elevated; test-tcsbackend.sh's ONLY=forget runs it as its test user). One
command:

    powershell -ExecutionPolicy Bypass -File test-forget.ps1 [-Out <folder>]

Keys go to TSF's keystroke manager in TsfHost.cs's field, as test-private.ps1's. In 中文 (shishi) and 日本語
(kisha) the 4th candidate is picked, and is then first: learned. The Configurator's Forget for both
(sebtype-configurator.exe --forget zh, ja: its own code without its window) then comes while both engines are
open, Mozc with its history in memory only (it saves every few minutes), and Mozc's DLL held 8 s at its next read (as an antivirus scan
holds it). The first candidate must be the original one again at once, and after the server restarts (/quit
saves, and the next key starts a new one); the same for 日本語's prediction (Tab after きし no longer suggests
the word picked: Mozc's history.db) and a character form it learned (a digit's width, kept for the whole
process). Results: one line per check in <Out>\forget-results.txt; exit 0 only
if all pass.
#>
param([string]$Out = "$env:USERPROFILE\scratch\SebType\375")
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSCommandPath
$server = "$env:ProgramFiles\SebType\sebtype-server.exe"
New-Item -ItemType Directory -Force $Out | Out-Null
$results = "$Out\forget-results.txt"
Set-Content -Encoding utf8 $results ''
function Result($name, $status, $why = '') {
  $line = "$status $name$(if ($why) { ": $why" })"
  Add-Content -Encoding utf8 $results $line; Write-Host $line
}
function Check($name, [scriptblock]$body) {
  try { $why = & $body; Result $name PASS $why } catch { Result $name FAIL $_.Exception.Message }
}
if (-not (Test-Path $server)) { Write-Host 'BLOCKED preflight: SebType is not installed'; exit 1 }

Add-Type -Path "$root\TsfHost.cs" -ReferencedAssemblies System.Drawing
$tsf = [SebType.TsfHost]
$tsf::NoInput = $true
function Keys {
  foreach ($k in $args) {
    $null = $tsf::Key($(switch ($k) { 'space' { 0x20 } 'Return' { 0x0D } 'Escape' { 0x1B } 'Tab' { 0x09 } default { [byte][char]"$k".ToUpper() } }))
    $tsf::Settle(150)
  }
  $tsf::Settle(600)
}
function Lang($lang) {
  $clsid = [Guid]'{D4E5C593-4F73-475F-936C-0E29A6FE7A02}'
  if ($lang -eq 'zh') { $tsf::Activate(0x804, $clsid, [Guid]'{8AA7DDAC-A4B8-4437-9C0B-8698879EC987}') }
  else { $tsf::Activate(0x411, $clsid, [Guid]'{B148FB02-C235-45D6-996C-672C783ECD48}') }
  $tsf::Settle(500); $tsf::Clear()
  # Until its engine takes keys: the first key starts the server, and Mozc loads in the background.
  for ($i = 0; $i -lt 120; $i++) {
    $taken = $tsf::Key([byte][char]'N'); $tsf::Settle(200); $null = $tsf::Key(0x1B); $tsf::Settle(200); $tsf::Clear()
    if ($taken) { return }
    Start-Sleep -Milliseconds 500
  }
  throw "$lang never took a key"
}
function Typed { Keys @args; $t = $tsf::Text(); $tsf::Clear(); $t }
$words = @{  # the first candidate, and the fourth picked
  zh = { Typed s h i s h i space }, { Typed s h i s h i 4 }
  ja = { Typed k i s h a space Return }, { Typed k i s h a space space space space Return }
}
function Predicted { Typed k i s i Tab Return }  # Mozc's first prediction for きし
function DigitForm($d) {  # Mozc's first candidate for a digit: its learned width for all digits
  $t = Typed $d space Return
  if ($t -eq "$d") { 'half' } elseif ($t -eq [string][char](0xFF10 + [int]"$d")) { 'full' } else { "'$t'" }
}
function Forget($lang) {  # Privacy's Forget, without its window
  $p = Start-Process -PassThru -WindowStyle Hidden "$env:ProgramFiles\SebType\sebtype-configurator.exe" '--forget', $lang
  if (-not $p.WaitForExit(120000)) { Stop-Process -Id $p.Id -Force; throw "--forget $lang took over 2 minutes" }
  if ($p.ExitCode) { throw "--forget $lang exited with $($p.ExitCode)" }
}

$first = @{}
$tsf::Start()
try {
  foreach ($lang in 'zh', 'ja') {
    Check "$lang-learns" {
      Lang $lang
      if ($lang -eq 'ja') { $script:predicted = Predicted }
      $f, $fourth = $words[$lang]
      $first[$lang] = & $f
      $picked = & $fourth
      $again = & $f
      if (-not $picked -or $picked -eq $first[$lang] -or $again -ne $picked) { throw "first '$($first[$lang])', 4th '$picked', then first '$again'" }
      $script:picked = $picked
      "first '$($first[$lang])', 4th '$picked' first after it"
    }
  }
  Check 'ja-learns-prediction' {
    $now = Predicted
    if ($predicted -eq $picked -or $now -ne $picked) { throw "きし predicted '$predicted', after '$picked' '$now'" }
    "きし predicted '$predicted', then '$now'"
  }
  # Digits each in a width of their own, none typed twice (or the history would choose).
  $base = DigitForm 3
  $other = @{ half = 'full'; full = 'half' }[$base]
  Check 'ja-learns-character-form' {
    for ($i = 1; $i -le 8 -and $learned -ne $other; $i++) {
      $keys = @('2') + @('space') * $i + @('Return')
      $t = Typed @keys
      $learned = if ($t -eq '2') { 'half' } elseif ($t -eq [string][char]0xFF12) { 'full' } else { '?' }
    }
    $now = DigitForm 5
    if ($now -ne $other) { throw "3 is $base, then 5 is $now after 2 in $other width" }
    "3 is $base, 5 $now after 2 in $other width"
  }
  function JaForgotten($phase, $digit) {
    Check "ja-prediction-forgotten-$phase" {
      $now = Predicted
      if (-not $now -or $now -eq $picked) { throw "きし predicted '$now', want not '$picked'" }
      $now
    }
    Check "ja-character-form-forgotten-$phase" {
      $now = DigitForm $digit
      if ($now -ne $base) { throw "$digit is $now, want $base" }
      $now
    }
  }
  Check 'configurator-forgets-zh' { Forget zh; 'sebtype-configurator --forget zh returned 0' }
  Check 'configurator-forgets-ja' {
    # Mozc's next read of its DLL held 8 s, as an antivirus scan holds it (TsfHost.cs's SlowOpen): a reload
    # of Mozc, in the background, can't be over before anything that doesn't wait for it.
    $held = [SlowOpen]::Hold("$env:ProgramFiles\SebType\sebtype-mozc.dll", 8000)
    Forget ja
    "sebtype-configurator --forget ja returned 0; Mozc's DLL $(if (-not $held) { 'not held (no oplock)' } elseif ([SlowOpen]::AskedAt) { 'held 8 s at its next read' } else { 'not read yet' })"
  }
  foreach ($lang in 'zh', 'ja') {
    Check "$lang-forgotten-while-typing" {
      Lang $lang
      $t = & $words[$lang][0]
      if ($t -ne $first[$lang]) { throw "first is '$t', want '$($first[$lang])'" }
      $t
    }
  }
  JaForgotten while-typing 6
  $p = Start-Process -PassThru -WindowStyle Hidden $server '/quit'
  $null = $p.WaitForExit(30000)
  Start-Sleep 3  # the old server saves and exits
  foreach ($lang in 'zh', 'ja') {
    Check "$lang-forgotten-after-restart" {
      Lang $lang
      $t = & $words[$lang][0]
      if ($t -ne $first[$lang]) { throw "first is '$t', want '$($first[$lang])'" }
      $t
    }
  }
  JaForgotten after-restart 7
} finally {
  $tsf::Stop()
  Copy-Item "$env:TEMP\rime.sebtype\server.log" $Out -ErrorAction SilentlyContinue
}
$failed = @(Get-Content $results | Where-Object { $_ -like 'FAIL *' }).Count
exit [int]($failed -gt 0)
