<#
The tray key while 中文 or 日本語 isn't ready (#275), on a Windows PC with SebType installed, in the logged-on
person's own desktop session (not elevated). One command:

    powershell -ExecutionPolicy Bypass -File test-not-ready.ps1 [-Out <folder>]

Like test-focus-out.ps1 it makes no input of its own (keys go to TSF's keystroke manager in TsfHost.cs's
field), so a screen that is off stays off, and it stops sending keys once Windows reports the display on.
Checks, each saving the input indicator's icon (<state>.png, at the size the text service gave the
taskbar) and, for the popup, the window by the caret (<state>-popup.png) and the taskbar's right end
(<state>-taskbar.png), these two in the screen's own pixels at any scaling:
  ready: あ and 中 as usual;
  sharp: at any scaling the icon comes at the taskbar's size and the popup in the screen's own pixels;
  chinese-preparing: while Rime deploys (sebtype-server.exe /deploy, its prisms removed), 中 turns grey with "…", a key goes
    in as typed and the popup says why; chinese-back: once Rime is done the key is 中 again, unasked;
  chinese-switched: a switch to 中文 during a second such deploy, no key typed: grey 中, then 中 again unasked;
  chinese-unavailable: a server that hangs (its process suspended): grey 中 with "!" after one key's wait,
    the key goes in as typed, the popup says why; japanese-unavailable: the same in 日本語 with its own popup;
  japanese-back: the server answers again (resumed): あ again within two seconds, unasked;
  typed-after-recovery: ni + Space in 中文 then gives 你 (the key the app typed itself while the server hung
    doesn't reach Rime as well).
-AnyDisplay is for a PC no one sits at, or a Remote Desktop session (test-tcsbackend.sh's ONLY=not-ready): the
display state, if Windows reports one, is only reported (INFO). The deploy runs at below-normal priority.
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
  [StructLayout(LayoutKind.Sequential)] struct LastInput { public uint Size, Time; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInput li);
  // A person's last keyboard or mouse input; the test's own keys go through TSF and don't change it.
  public static uint InputTime() { var li = new LastInput { Size = 8 }; GetLastInputInfo(ref li); return li.Time; }
}
'@
$display = [SebType.Display]
$tsf = [SebType.TsfHost]
$tsf::NoInput = $true
function States { $display::States -join ', ' }
$display::Watch()
for ($i = 0; $i -lt 20 -and $display::Last -lt 0; $i++) { Start-Sleep -Milliseconds 100 }
if ($display::Last -lt 0 -and -not $AnyDisplay) { Write-Host 'BLOCKED preflight: Windows reported no display state'; exit 1 }
if ($display::Last -ne 0 -and -not $AnyDisplay) { Write-Host "BLOCKED preflight: the display is on (state $($display::Last)): someone may be using the PC"; exit 1 }

$inputAt = [SebTypeSuspend]::InputTime()
function Ready {
  # A person's keys reach the test's field while it is in front (a Shift tap turns 中 or あ to English letters).
  if ([SebTypeSuspend]::InputTime() -ne $inputAt) { throw 'someone used the keyboard or mouse during the test: no more keys' }
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

# This session's server (a terminal server may run one per session).
function Server { Get-Process sebtype-server | Where-Object SessionId -EQ (Get-Process -Id $PID).SessionId | Select-Object -First 1 }
# Changes Rime's files with no server holding them, then starts one below normal priority and waits for its pipe.
function Restart-Server([scriptblock]$change) {
  if ($old = Server) { Start-Process -Wait $server '/quit'; if (-not $old.WaitForExit(10000)) { throw 'the server did not quit in 10 s' } }
  & $change
  (Start-Process $server -PassThru).PriorityClass = 'BelowNormal'
  $pipe = "\\.\pipe\SebType.$((Get-Process -Id $PID).SessionId).$env:USERNAME"  # windows/src/pipe.h
  $end = (Get-Date).AddSeconds(20)
  while (-not (Test-Path $pipe)) { if ((Get-Date) -gt $end) { throw "no $pipe 20 s after the server started" }; Start-Sleep -Milliseconds 200 }
}
# Mozc loads again in a new server, which took seconds at its first load: before any check times 日本語.
function Warm-Mozc {
  Lang ja
  $end = (Get-Date).AddSeconds(30)
  do { Keys n i Escape; $now = try { Shot 'hira-again' } catch { $null } } while ($now -ne $hira -and (Get-Date) -lt $end)
  Lang zh
}
$suspended = $hira = $zh = $deploy = $backup = $null
$rimeBuild = "$env:APPDATA\Rime\build"
$tsf::Start()
Result scale INFO "$($tsf::Dpi()) dpi, $([int]($tsf::Dpi() * 100 / 96)) %; pictures in the screen's own pixels"
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
  # Every later check compares against these two icons.
  if (-not ($hira -and $zh) -or $hira -eq $zh) { throw 'not ready: no further checks' }

  # A deploy with nothing changed is over at once: without its prisms (built from the prebuilt tables), Rime
  # takes seconds. The server keeps them mapped, so it quits first (saving), and a new one starts below
  # normal priority, so its deploy never slows what else the PC serves. The build folder is put back at the end,
  # from this run's own copy, and only once the copy is known complete.
  $copy = "$Out\rime-build-$((New-Guid).ToString('N'))"
  Copy-Item -Recurse $rimeBuild $copy
  $bytes = { param($dir) (Get-ChildItem -Recurse -File $dir | Measure-Object Length -Sum | ForEach-Object { "$($_.Count) $($_.Sum)" }) }
  if ((& $bytes $copy) -ne (& $bytes $rimeBuild)) { throw "the copy of $rimeBuild is incomplete: nothing changed" }
  $backup = $copy
  Restart-Server { Remove-Item "$rimeBuild\*.prism.bin" }
  Warm-Mozc
  # The text service learns of the deploy at the next key, so the key goes once Rime's maintenance began:
  # the first prism back (rime_ice's, small) shows it, with seconds of the others to go (TCSBackEnd: a key
  # 300 ms after /deploy came before the deploy, which then took 12 s more after the first prism).
  $deploy = Start-Process $server '/deploy' -PassThru
  Check 'chinese-preparing' {
    $ms = { [int]((Get-Date) - $deploy.StartTime).TotalMilliseconds }
    $end = (Get-Date).AddSeconds(30)
    while (-not (Test-Path "$rimeBuild\*.prism.bin") -and -not $deploy.HasExited -and (Get-Date) -lt $end) { $tsf::Settle(10) }
    $began = if (Test-Path "$rimeBuild\*.prism.bin") { "began +$(& $ms) ms" } else { 'not seen to begin' }
    $tsf::Clear(); $keyAt = & $ms
    try { $size = KeyWithPopup 'n' 'zh-wait'; $why = $null } catch { $why = $_.Exception.Message }
    $icon = Shot 'zh-wait'; $t = $tsf::Text()
    $timeline = "maintenance $began, key +$keyAt ms, /deploy $(if ($deploy.HasExited) { "over +$([int]($deploy.ExitTime - $deploy.StartTime).TotalMilliseconds) ms" } else { "still running +$(& $ms) ms" })"
    if ($why) { throw "$why ($timeline)" }
    if ($icon -eq $zh) { throw "the icon is still 中 ($timeline)" }
    if ($t -ne 'n') { throw "the key gave '$t', not n as typed ($timeline)" }
    "grey 中, 'n' as typed, popup $size ($timeline)"
  }
  # Drawn for the screen's pixels in this DPI-unaware app, as in the many apps that are: the icon at the
  # taskbar's size, the popup per-monitor DPI aware (before, at 150 % both were stretched and blurry).
  Check 'sharp' {
    $img = [System.Drawing.Image]::FromFile("$Out\zh-wait.png"); $px = $img.Width; $img.Dispose()
    $want = $tsf::IconSize(); $aware = $tsf::PopupAwareness
    if ($px -ne $want -or $aware -ne 2) { throw "icon $px px (the taskbar draws $want), popup DPI awareness $aware (2 is per monitor; Windows stretches the others)" }
    "icon $px px as the taskbar draws it, popup per-monitor DPI aware"
  }
  Check 'chinese-back' {
    if (-not $deploy.WaitForExit(300000)) { throw 'Rime still deploying after 5 minutes' }
    Get-ChildItem $rimeBuild | Format-Table -AutoSize Name, Length, LastWriteTime | Out-File -Encoding utf8 "$Out\rime-build-after-deploy.txt"
    $icon = WaitIcon $zh 3; Shot 'zh-back' | Out-Null
    if ($icon -ne $zh) { throw 'the icon did not turn back to 中 within 3 s' }
    Keys Escape; $tsf::Clear(); Keys n i space; $t = $tsf::Text()  # Escape: a key the deploy missed may still compose
    if ($t -ne '你') { throw "ni + Space gave '$t'" }
    "中 again unasked, ni + Space gives $t"
  }
  # The same deploy, met by a switch to 中文 with no key typed.
  Lang ja
  Restart-Server { Remove-Item "$rimeBuild\*.prism.bin" }
  $deploy = Start-Process $server '/deploy' -PassThru
  Check 'chinese-switched' {
    $end = (Get-Date).AddSeconds(30)
    while (-not (Test-Path "$rimeBuild\*.prism.bin") -and -not $deploy.HasExited -and (Get-Date) -lt $end) { $tsf::Settle(10) }
    Lang zh; $icon = Shot 'zh-switched'
    if ($icon -eq $zh) { throw "the icon is 中 while Rime deploys$(if ($deploy.HasExited) { ' (the deploy was over first)' })" }
    if (-not $deploy.WaitForExit(300000)) { throw 'Rime still deploying after 5 minutes' }
    $icon = WaitIcon $zh 3; Shot 'zh-switched-back' | Out-Null
    if ($icon -ne $zh) { throw 'the icon did not turn back to 中 within 3 s of the deploy' }
    'grey 中 at the switch, 中 again unasked'
  }
  Warm-Mozc

  $suspended = Server
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
  Check 'typed-after-recovery' {
    Lang zh; Keys n i space; $t = $tsf::Text()
    if ($t -ne '你') { throw "ni + Space gave '$t': the 'n' typed as is while the server hung went to Rime too" }
    "ni + Space gives $t"
  }
} catch {
  Result 'script' FAIL $_.Exception.Message  # a check that can't go on: the rest is skipped
} finally {
  if ($suspended) { [SebTypeSuspend]::NtResumeProcess($suspended.Handle) | Out-Null }
  if ($backup) {
    if ($deploy -and -not $deploy.HasExited) { $deploy.WaitForExit(300000) | Out-Null }
    try { Restart-Server { Remove-Item -Recurse $rimeBuild; Move-Item $backup $rimeBuild } }
    catch { Result 'rime-build-restored' FAIL $_.Exception.Message }
  }
  if (-not $display::Lit -or $AnyDisplay) { try { Keys Escape Escape } catch { } }
  $tsf::Stop()
  Copy-Item -Recurse "$env:TEMP\rime.sebtype" "$Out\rime.sebtype" -ErrorAction SilentlyContinue  # the server's and Rime's logs
}
Start-Sleep 6  # a wake from the last steps shows by now
if ($AnyDisplay) { Result display-stayed-off INFO "not checked (-AnyDisplay); states: $(States)" }
else {
  Check 'display-stayed-off' {
    if ($display::Lit) { throw "the display turned on: $(States)" }
    "off throughout: $(States)"
  }
}
$failed = @(Get-Content $results | Where-Object { $_ -like 'FAIL *' }).Count
exit [int]($failed -gt 0)
