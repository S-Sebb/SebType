<#
The tray key while 中文 or 日本語 isn't ready (#275), on a Windows PC with SebType installed, in the logged-on
person's own desktop session (not elevated). One command:

    powershell -ExecutionPolicy Bypass -File test-not-ready.ps1 [-Out <folder>]

Like test-focus-out.ps1 it makes no input of its own (keys go to TSF's keystroke manager in TsfHost.cs's
field), so a screen that is off stays off, and it stops sending keys once Windows reports the display on.
Checks, each saving the input indicator's icon (<state>.png) and, for the popup, the window by the caret
(<state>-popup.png) and the taskbar's right end (<state>-taskbar.png):
  ready: あ and 中 as usual;
  chinese-preparing: while Rime deploys (sebtype-server.exe /deploy, its prisms removed), 中 turns grey with "…", a key goes
    in as typed and the popup says why; chinese-back: once Rime is done the key is 中 again, unasked;
  chinese-unavailable: a server that hangs (its process suspended): grey 中 with "!" after one key's wait,
    the key goes in as typed, the popup says why; japanese-unavailable: the same in 日本語 with its own popup;
  japanese-back: the server answers again (resumed): あ again within two seconds, unasked.
-AnyDisplay is for a PC no one sits at with its display on: the display state is only reported.
The server is resumed and Rime's build folder put back in any case. Results: one line per check in <Out>\not-ready-results.txt; exit 0 only
if all pass.
#>
param([string]$Out = "$env:USERPROFILE\scratch\SebType\275\screens", [switch]$AnyDisplay)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSCommandPath
$server = "$env:ProgramFiles\SebType\sebtype-server.exe"
New-Item -ItemType Directory -Force $Out | Out-Null
$results = "$Out\not-ready-results.txt"
Set-Content -Encoding utf8 $results ''
function Result($name, $status, $why = '') {
  $line = "$status $name$(if ($why) { ": $why" })"
  Add-Content -Encoding utf8 $results $line; Write-Host $line
}
function Check($name, [scriptblock]$body) {
  try { $why = & $body; if ($why -like 'SKIP: *') { Result $name SKIP $why.Substring(6) } else { Result $name PASS $why } }
  catch { Result $name FAIL $_.Exception.Message }
}

$missing = if (-not (Test-Path $server)) { 'SebType is not installed' }
elseif ((Get-Process -Id $PID).SessionId -eq 0) { 'runs in session 0: start it in the desktop session' }
elseif (-not (Test-Path "$root\TsfHost.cs")) { "no TsfHost.cs beside $PSCommandPath" }
if ($missing) { Write-Host "BLOCKED preflight: $missing"; exit 1 }

Add-Type -Path "$root\TsfHost.cs" -ReferencedAssemblies System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class SebTypeSuspend {
  [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
  [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
}
'@
$display = [SebType.Display]
$tsf = [SebType.TsfHost]
$tsf::NoInput = $true
function States { $display::States -join ', ' }
$display::Watch()
for ($i = 0; $i -lt 20 -and $display::Last -lt 0; $i++) { Start-Sleep -Milliseconds 100 }
if ($display::Last -lt 0) { Write-Host 'BLOCKED preflight: Windows reported no display state'; exit 1 }
if ($display::Last -ne 0 -and -not $AnyDisplay) { Write-Host "BLOCKED preflight: the display is on (state $($display::Last)): someone may be using the PC"; exit 1 }

function Ready {
  if ($display::Lit -and -not $AnyDisplay) { throw "the display turned on ($(States)): no more keys" }
  if (-not $tsf::Focus()) { throw "the test field is not in front with the keyboard focus ($($tsf::FocusState())): no key sent" }
}
function Keys {
  Ready
  foreach ($k in $args) { $null = $tsf::Key($(switch ($k) { 'space' { 0x20 } 'Escape' { 0x1B } default { [byte][char]$k.ToUpper() } })); $tsf::Settle(150) }
  $tsf::Settle(600)
}
# One key, and the popup by the caret saved while it shows (1.2 s).
function KeyWithPopup($k, $name) {
  Ready
  $null = $tsf::Key([byte][char]$k.ToUpper()); $tsf::Settle(200)
  $size = $tsf::CandidateWindow("$Out\$name-popup.png")
  if (-not $size) { throw "no popup by the caret after '$k'" }
  $tsf::Settle(600)
  $null = $tsf::CandidateWindow("$Out\$name-popup-later.png")  # the same popup once it settled
  $tsf::Settle(900)
  $size
}
function Lang($lang) {
  $clsid = [Guid]'{D4E5C593-4F73-475F-936C-0E29A6FE7A02}'
  if ($lang -eq 'zh') { $tsf::Activate(0x804, $clsid, [Guid]'{8AA7DDAC-A4B8-4437-9C0B-8698879EC987}') }
  else { $tsf::Activate(0x411, $clsid, [Guid]'{B148FB02-C235-45D6-996C-672C783ECD48}') }
  $tsf::Settle(500); $tsf::Clear()
}
# The input mode button's icon; a check fails, not the script, while there is none.
function Icon($path) {
  try { $tsf::ButtonIcon($path) } catch { throw "no input mode button ($($_.Exception.InnerException.Message))" }
}
function Shot($name) {
  Icon "$Out\$name.png"
  try { $tsf::Taskbar("$Out\$name-taskbar.png", 360) } catch { }
  [Convert]::ToBase64String([IO.File]::ReadAllBytes("$Out\$name.png"))
}
# The icon once it is the one wanted, within secs; the last one seen otherwise.
function WaitIcon($want, $secs) {
  $end = (Get-Date).AddSeconds($secs)
  do { $tsf::Settle(250); Icon "$Out\poll.png"; $now = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$Out\poll.png")) }
  while ($now -ne $want -and (Get-Date) -lt $end)
  Remove-Item "$Out\poll.png"
  $now
}

$suspended = $hira = $zh = $deploy = $null
$rimeBuild = "$env:APPDATA\Rime\build"
$tsf::Start()
try {
  # The first key starts sebtype-server when none runs; the first 日本語 after an install took over 4 s
  # before its button showed and it took keys (YukaROG, Mozc's first load).
  Check 'ready' {
    Lang ja
    $end = (Get-Date).AddSeconds(30)
    do { Keys n i Escape; $script:hira = try { Shot 'hira' } catch { $null } } while (-not $hira -and (Get-Date) -lt $end)
    if (-not $hira) { throw '日本語 showed no input mode button within 30 s' }
    Lang zh
    Keys n i Escape
    $script:zh = Shot 'zh'
    if ($hira -eq $zh) { throw 'あ and 中 show the same icon' }
    'あ and 中 differ'
  }
  if (-not ($hira -and $zh)) { throw 'not ready: no further checks' }

  # A deploy with nothing changed is over at once: without its prisms (built from the prebuilt tables), Rime
  # takes seconds. The build folder is put back as it was at the end.
  Copy-Item -Recurse $rimeBuild "$Out\rime-build"
  Remove-Item "$rimeBuild\*.prism.bin"
  # The text service learns of the deploy at the next key, so the key goes as soon as /deploy has asked.
  $deploy = Start-Process $server '/deploy' -PassThru
  Check 'chinese-preparing' {
    $tsf::Settle(300); $tsf::Clear()
    try { $size = KeyWithPopup 'n' 'zh-wait' }
    catch { throw "$($_.Exception.Message) (/deploy $(if ($deploy.HasExited) { "over after $([int](($deploy.ExitTime - $deploy.StartTime).TotalMilliseconds)) ms" } else { 'still running' }))" }
    $icon = Shot 'zh-wait'; $t = $tsf::Text()
    if ($icon -eq $zh) { throw 'the icon is still 中' }
    if ($t -ne 'n') { throw "the key gave '$t', not n as typed" }
    "grey 中, 'n' as typed, popup $size"
  }
  Check 'chinese-back' {
    if (-not $deploy.WaitForExit(300000)) { throw 'Rime still deploying after 5 minutes' }
    $icon = WaitIcon $zh 3; Shot 'zh-back' | Out-Null
    if ($icon -ne $zh) { throw 'the icon did not turn back to 中 within 3 s' }
    $tsf::Clear(); Keys n i space; $t = $tsf::Text()
    if ($t -ne '你') { throw "ni + Space gave '$t'" }
    "中 again unasked, ni + Space gives $t"
  }

  $suspended = (Get-Process sebtype-server | Select-Object -First 1)
  [SebTypeSuspend]::NtSuspendProcess($suspended.Handle) | Out-Null
  Check 'chinese-unavailable' {
    $tsf::Clear(); $start = Get-Date; $size = KeyWithPopup 'n' 'zh-off'; $icon = Shot 'zh-off'; $t = $tsf::Text()
    if ($icon -eq $zh) { throw 'the icon is still 中' }
    if ($t -ne 'n') { throw "the key gave '$t', not n as typed" }
    $tsf::Clear(); $k = Get-Date; Keys a b c; $more = ((Get-Date) - $k).TotalMilliseconds - 3 * 150 - 600
    if ($tsf::Text() -ne 'abc' -or $more -gt 500) { throw "3 more keys gave '$($tsf::Text())' with $([int]$more) ms of waiting" }
    "grey 中 with !, 'n' as typed, popup $size; 3 more keys as typed, $([int]$more) ms of waiting"
  }
  Check 'japanese-unavailable' {
    Lang ja; $size = KeyWithPopup 'k' 'hira-off'; $icon = Shot 'hira-off'; $t = $tsf::Text()
    if ($icon -eq $hira) { throw 'the icon is still あ' }
    if ($t -ne 'k') { throw "the key gave '$t', not k as typed" }
    "grey あ with !, 'k' as typed, popup $size"
  }
  [SebTypeSuspend]::NtResumeProcess($suspended.Handle) | Out-Null; $suspended = $null
  Check 'japanese-back' {
    $icon = WaitIcon $hira 4; Shot 'hira-back' | Out-Null
    if ($icon -ne $hira) { throw 'the icon did not turn back to あ within 4 s' }
    'あ again unasked'
  }
} catch {
  Result 'script' FAIL $_.Exception.Message  # a check that can't go on: the rest is skipped
} finally {
  if ($suspended) { [SebTypeSuspend]::NtResumeProcess($suspended.Handle) | Out-Null }
  if (Test-Path "$Out\rime-build") {
    if ($deploy -and -not $deploy.HasExited) { $deploy.WaitForExit(300000) | Out-Null }
    Remove-Item -Recurse $rimeBuild; Move-Item "$Out\rime-build" $rimeBuild
  }
  if (-not $display::Lit -or $AnyDisplay) { try { Keys Escape Escape } catch { } }
  $tsf::Stop()
}
Start-Sleep 6  # a wake from the last steps shows by now
Check 'display-stayed-off' {
  if ($AnyDisplay) { return "SKIP: -AnyDisplay (states: $(States))" }
  if ($display::Lit) { throw "the display turned on: $(States)" }
  "off throughout: $(States)"
}
$failed = @(Get-Content $results | Where-Object { $_ -like 'FAIL *' }).Count
exit [int]($failed -gt 0)
