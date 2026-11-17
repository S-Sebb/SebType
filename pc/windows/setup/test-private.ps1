<#
Private fields learn nothing new (#270), on a Windows PC with SebType installed, in the logged-on person's own
desktop session (not elevated). One command:

    powershell -ExecutionPolicy Bypass -File test-private.ps1 -Watch <file> [-Out <folder>] [-Browsers]

It makes no input of its own, as test-focus-out.ps1 (#277), so a screen that is off stays off: -Watch <file> is
test-focus-out.ps1 -WatchTo's log of the display's state, started before SebType's install; the run stops once
it shows the display on. TsfHost.cs (beside this script) is the field, with the input scope IS_PRIVATE as a
browser's private window gives it, or none. In 中文 (shishi) and 日本語 (kisha) a 4th candidate picked in the
private field is not learned and the first stays first; picked in a field that may learn it is learned; and
the private field then still suggests it first.
-Browsers then opens a local page with a focused text field in Edge (and Chrome when installed), InPrivate or
incognito and then normal, each with a profile in <Out>, brings the window to the front without a key, and
checks server.log: SebType's server notes "field: private, learns nothing" for the private window, "field:
learns" for the normal one. The browsers it started are closed. Results: one line per check in
<Out>\private-results.txt; exit 0 only if all pass.
#>
param([string]$Out = "$env:USERPROFILE\scratch\SebType\270", [string]$Watch, [switch]$Browsers)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSCommandPath
New-Item -ItemType Directory -Force $Out | Out-Null
$results = "$Out\private-results.txt"
Set-Content -Encoding utf8 $results ''
function Result($name, $status, $why = '') {
  $line = "$status $name$(if ($why) { ": $why" })"
  Add-Content -Encoding utf8 $results $line; Write-Host $line
}
function Check($name, [scriptblock]$body) {
  try { $why = & $body; Result $name PASS $why } catch { Result $name FAIL $_.Exception.Message }
}
function Lit { Get-Content $Watch -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch ' 0$' } }

$missing = if (-not (Test-Path "$env:ProgramFiles\SebType\sebtype.dll")) { 'SebType is not installed' }
elseif ((Get-Process -Id $PID).SessionId -eq 0) { 'runs in session 0: start it in the desktop session' }
elseif (-not $Watch -or -not (Test-Path $Watch)) { 'no -Watch file: start test-focus-out.ps1 -WatchTo <file> first' }
elseif (-not (Get-Content $Watch)) { 'the -Watch file has no display state yet' }
elseif (Lit) { "the display is on or was: $((Get-Content $Watch) -join ', ')" }
if ($missing) { Write-Host "BLOCKED preflight: $missing"; exit 1 }

Add-Type -Path "$root\TsfHost.cs" -ReferencedAssemblies System.Drawing
$tsf = [SebType.TsfHost]
$tsf::NoInput = $true
$log = "$env:TEMP\rime.sebtype\server.log"
function Dark { if (Lit) { throw "the display came on: $((Get-Content $Watch) -join ', ')" } }
function Keys {
  Dark
  if (-not $tsf::Focus()) { throw "the test field is not in front with the keyboard focus ($($tsf::FocusState())): no key sent" }
  foreach ($k in $args) {
    $null = $tsf::Key($(switch ($k) { 'space' { 0x20 } 'Return' { 0x0D } 'Escape' { 0x1B } default { [byte][char]"$k".ToUpper() } }))
    $tsf::Settle(150)
  }
  $tsf::Settle(600)
}
function Lang($lang) {
  $clsid = [Guid]'{D4E5C593-4F73-475F-936C-0E29A6FE7A02}'
  if ($lang -eq 'zh') { $tsf::Activate(0x804, $clsid, [Guid]'{8AA7DDAC-A4B8-4437-9C0B-8698879EC987}') }
  else { $tsf::Activate(0x411, $clsid, [Guid]'{B148FB02-C235-45D6-996C-672C783ECD48}') }
  $tsf::Settle(500); $tsf::Clear()
}
# The text service reads the input scope once per focus: away and back, as a click into another field.
function Field($private) {
  [SebType.TextStore]::Scopes = if ($private) { [int[]]@(61) } else { $null }  # IS_PRIVATE
  $tsf::Away($true); $tsf::Settle(500); $tsf::Away($false); $tsf::Settle(500)
}
function Typed { Keys @args; $t = $tsf::Text(); $tsf::Clear(); $t }
$words = @{  # the first candidate, and the fourth picked
  zh = { Typed s h i s h i space }, { Typed s h i s h i 4 }
  ja = { Typed k i s h a space Return }, { Typed k i s h a space space space space Return }
}

$tsf::Start()
try {
  foreach ($lang in 'zh', 'ja') {
    Lang $lang
    $first, $fourth = $words[$lang]
    if ($lang -eq 'zh') { Keys n i; Start-Sleep 3; Keys Escape; $tsf::Clear() }  # the first key starts the server
    Field $false; $top = & $first
    Field $true; $picked = & $fourth
    Check "$lang-private-pick" { if (-not $picked -or $picked -eq $top) { throw "the 4th candidate gave '$picked' (first '$top')" }; $picked }
    Check "$lang-private-learns-nothing" { $t = & $first; if ($t -ne $top) { throw "first is '$t', want '$top'" }; $t }
    Field $false
    Check "$lang-normal-learns" { $null = & $fourth; $t = & $first; if ($t -ne $picked) { throw "first is '$t', want '$picked'" }; $t }
    Field $true
    Check "$lang-private-keeps-learned" { $t = & $first; if ($t -ne $picked) { throw "first is '$t', want '$picked'" }; $t }
    Field $false
  }

  if ($Browsers) {
    $page = "$Out\field.html"
    Set-Content -Encoding utf8 $page '<title>sebtype-270</title><textarea autofocus></textarea>'
    $found = @(
      @{ Name = 'edge'; Exe = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"; Private = '--inprivate' }
      @{ Name = 'chrome'; Exe = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"; Private = '--incognito' }
    ) | Where-Object { Test-Path $_.Exe }
    foreach ($b in $found) {
      foreach ($private in $true, $false) {
        $name = "$($b.Name)-$(if ($private) { 'private' } else { 'normal' })"
        $prof = "$Out\$($b.Name)-profile"
        Check $name {
          # The server notes only a change: the test's own field first, in front with the other privacy.
          Field (-not $private)
          if (-not $tsf::Focus()) { throw "the test field is not in front ($($tsf::FocusState()))" }
          $tsf::Settle(500); Dark
          $before = @(Get-Content $log -ErrorAction SilentlyContinue).Count
          $flags = @("--user-data-dir=`"$prof`"", '--no-first-run', '--no-default-browser-check') + @($(if ($private) { $b.Private })) + "file:///$($page -replace '\\', '/')"
          $null = Start-Process $b.Exe -ArgumentList $flags -PassThru
          try {
            $h = [IntPtr]::Zero
            for ($i = 0; $i -lt 60 -and $h -eq [IntPtr]::Zero; $i++) {
              Start-Sleep -Milliseconds 500
              $w = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like 'sebtype-270*' } | Select-Object -First 1
              if ($w) { $h = $w.MainWindowHandle }
            }
            if ($h -eq [IntPtr]::Zero) { throw 'no browser window with the page' }
            $front = $tsf::Foreground($h)
            $want = if ($private) { 'field: private, learns nothing' } else { 'field: learns' }
            # A new profile's page can take seconds to focus its field.
            for ($i = 0; $i -lt 15; $i++) {
              Start-Sleep 1; Dark
              $new = @(Get-Content $log -ErrorAction SilentlyContinue | Select-Object -Skip $before) -match 'field: '
              if ($new | Where-Object { $_ -like "*$want" }) { break }
            }
            $why = "in front: $front; server.log: $($new -join ' / ')"
            if (-not ($new | Where-Object { $_ -like "*$want" })) { throw $why }
            $why
          } finally {
            Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$prof*" } |
              ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep 2
          }
        }
      }
      Remove-Item -Recurse -Force $prof -ErrorAction SilentlyContinue
    }
    Remove-Item -Force $page
  }
} finally {
  if (-not (Lit)) { try { Keys Escape Escape } catch { } }
  $tsf::Stop()
}

Start-Sleep 6  # a wake from the last steps shows by now
Check 'display-stayed-off' { if (Lit) { throw "the display turned on: $((Get-Content $Watch) -join ', ')" }; 'off throughout' }
$failed = @(Get-Content $results | Where-Object { $_ -like 'FAIL *' }).Count
exit [int]($failed -gt 0)
