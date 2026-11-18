<#
The tray key while 中文 or 日本語 isn't ready (#275), on a Windows PC with SebType installed, in the logged-on
person's own desktop session (not elevated). One command:

    powershell -ExecutionPolicy Bypass -File test-not-ready.ps1 [-Out <folder>]

Like test-focus-out.ps1 it makes no input of its own (keys go to TSF's keystroke manager in TsfHost.cs's
field), so a screen that is off stays off, and it stops sending keys once Windows reports the display on.
Checks, each saving the input indicator's icon (<state>.png, at the size the text service gave the
taskbar) and, for the popup, the window by the caret (<state>-popup.png) and the taskbar's right end
(<state>-taskbar.png), these two in the screen's own pixels at any scaling:
  first-japanese: the first 日本語 after the install (#312), its Mozc's load held 8 s (a batch oplock on
    sebtype-mozc.dll, as an antivirus scan holds a new file): the button is there at once as grey あ, and a key
    goes in as typed without waiting; reload-while-loading: the Configurator's /mozc meanwhile, and 中文 still
    switches and types at once; first-japanese-back: あ unasked once Mozc and the reload are done, then the first ka gives か;
  ready: あ and 中 as usual; dpi-change: the candidates rescale when the scale changes while they show (#327),
    and back as a fresh show; windows-ime (INFO): Microsoft Pinyin's icon in the same taskbar, to compare;
  sharp: at any scaling the icon comes at the taskbar's size and the popup in the screen's own pixels;
  chinese-preparing: while Rime deploys (sebtype-server.exe /deploy, its prisms removed), 中 turns grey with "…", a key goes
    in as typed and the popup says why; chinese-back: once Rime is done the key is 中 again, unasked;
  chinese-switched: a switch to 中文 during a second such deploy, no key typed: grey 中, then 中 again unasked;
  chinese-unavailable: a server that hangs (its process suspended): grey 中 with "!" after one key's wait,
    the key goes in as typed, the popup says why; japanese-unavailable: the same in 日本語 with its own popup;
  japanese-back: the server answers again (resumed): あ again within two seconds, unasked;
  typed-after-recovery: ni + Space in 中文 then gives 你 (the key the app typed itself while the server hung
    doesn't reach Rime as well); dpi-change-popup: dpi-change for the popup, at a key once the server hangs;
  popup-own-content: that popup, after typed-after-recovery's candidates with page arrows, shows only its own
    text: the same as japanese-unavailable's popup, with no arrows left from the candidates (#348);
  hang-mid-composition: the server hangs while か is being typed: か stays, the key goes in after it with the
    popup, and i once the server answers again gives かnい; hang-mid-deferred-lock: the same, with n and then
    keypad 1, in an app that grants the text service's edit only after it handled the key.
-AnyDisplay is for a PC no one sits at, or a Remote Desktop session (test-tcsbackend.sh's ONLY=not-ready): the
display state, if Windows reports one, is only reported (INFO). The deploy runs at below-normal priority.
The server is resumed and Rime's build folder put back in any case. It refuses to run as the built-in
Administrator or in its session, whose desktop may serve other things (TCSBackEnd's). Results: one line per check in <Out>\not-ready-results.txt; exit 0 only
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
  try { $why = & $body; if ($why -match '^(SKIP|INFO): ') { Result $name $Matches[1] $why.Substring(6) } else { Result $name PASS $why } }
  catch { Result $name FAIL $_.Exception.Message }
}

$missing = if (-not (Test-Path $server)) { 'SebType is not installed' }
elseif ((Get-Process -Id $PID).SessionId -eq 0) { 'runs in session 0: start it in the desktop session' }
elseif (-not (Test-Path "$root\TsfHost.cs")) { "no TsfHost.cs beside $PSCommandPath" }
elseif ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -like 'S-1-5-21-*-500') { 'runs as the built-in Administrator: use a test user' }
elseif (Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe' AND SessionId = $((Get-Process -Id $PID).SessionId)" |
    Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid).Sid -like 'S-1-5-21-*-500' }) {
  "runs in the built-in Administrator's session: use a test user's own"
}
if ($missing) { Write-Host "BLOCKED preflight: $missing"; exit 1 }

Add-Type -Path "$root\TsfHost.cs" -ReferencedAssemblies System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Threading;
// A slow first open of a file, as an antivirus scan of a newly installed DLL makes it (#312): a batch oplock,
// so the next open by anyone else waits until the oplock is let go, ms after that open asked.
public static class SlowOpen {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool DeviceIoControl(IntPtr h, uint code, IntPtr inBuf, uint inSize, IntPtr outBuf, uint outSize, out uint ret, IntPtr overlapped);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  public static int AskedAt;  // Environment.TickCount when the other open came; 0 before
  // False when the oplock wasn't granted (the file is open elsewhere): nothing is slowed.
  public static bool Hold(string path, int ms) {
    AskedAt = 0;
    IntPtr h = CreateFileW(path, 0x80000000 /* GENERIC_READ */, 7, IntPtr.Zero, 3 /* OPEN_EXISTING */, 0x40000000 /* OVERLAPPED */, IntPtr.Zero);
    if (h == new IntPtr(-1)) return false;
    var broken = new ManualResetEvent(false);
    IntPtr ov = Marshal.AllocHGlobal(IntPtr.Size * 2 + 8 + IntPtr.Size);
    for (int i = 0; i < IntPtr.Size * 3 + 8; i++) Marshal.WriteByte(ov, i, 0);
    Marshal.WriteIntPtr(ov, IntPtr.Size * 2 + 8, broken.SafeWaitHandle.DangerousGetHandle());
    uint ret;
    if (DeviceIoControl(h, 0x00090008 /* FSCTL_REQUEST_BATCH_OPLOCK */, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret, ov) ||
        Marshal.GetLastWin32Error() != 997 /* ERROR_IO_PENDING */) {
      CloseHandle(h); Marshal.FreeHGlobal(ov); return false;
    }
    new Thread(() => {
      if (broken.WaitOne(120000)) { AskedAt = Environment.TickCount; Thread.Sleep(ms); }
      CloseHandle(h); Marshal.FreeHGlobal(ov);
    }) { IsBackground = true }.Start();
    return true;
  }
}
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
# A key's virtual-key code: space, Escape, kp0-kp9 (the keypad's digits, Num Lock on), or a letter.
function Vk($k) {
  switch -regex ($k) { '^space$' { 0x20 } '^Escape$' { 0x1B } '^kp(\d)$' { 0x60 + [int]$Matches[1] } default { [byte][char]$k.ToUpper() } }
}
function Keys {
  Ready
  foreach ($k in $args) { $null = $tsf::Key((Vk $k)); $tsf::Settle(150) }
  $tsf::Settle(600)
}
# One key, and the popup by the caret saved while it shows (1.2 s).
function KeyWithPopup($k, $name) {
  Ready
  $null = $tsf::Key((Vk $k)); $tsf::Settle(200)
  $size = $tsf::CandidateWindow("$Out\$name-popup.png")
  if (-not $size) { throw "no popup by the caret after '$k'" }
  $tsf::Settle(600)
  $null = $tsf::CandidateWindow("$Out\$name-popup-later.png")  # the same popup once it settled
  $tsf::Settle(900)
  $size
}
# A scale change while the window shows (#327), sent as Windows sends it: the window's sizes at this DPI, after
# a change to the other (96 or 144) and after the change back, which has to match the first. A SCALE=150 run of
# test-tcsbackend.sh gives the fresh show at 144 dpi that a SCALE=100 run's change has to match, and back.
function DpiRoundTrip($name) {
  $d = $tsf::Dpi(); $o = if ($d -eq 96) { 144 } else { 96 }
  $size = { param($png) $s = $tsf::CandidateWindow("$Out\$png"); if ($s) { ($s -split ' ')[0] } }
  $fresh = & $size "$name-fresh-$d.png"
  if (-not $fresh) { throw "no window to rescale" }
  if (-not $tsf::DpiChanged($o)) { throw "the window went before the change to $o dpi" }
  $other = & $size "$name-changed-$o.png"
  $null = $tsf::DpiChanged($d); $back = & $size "$name-back-$d.png"
  $sizes = "$fresh fresh at $d dpi, $other changed to $o dpi, $back back"
  if (-not $other -or $other -eq $fresh) { throw "the window didn't rescale: $sizes" }
  if ($back -ne $fresh) { throw "back at $d dpi it isn't as fresh: $sizes" }
  $sizes
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
function Server { Get-Process sebtype-server -ErrorAction SilentlyContinue | Where-Object SessionId -EQ (Get-Process -Id $PID).SessionId | Select-Object -First 1 }
# Every server on the PC, for a failure's message.
function Servers { (@(Get-CimInstance Win32_Process -Filter "Name='sebtype-server.exe'") | ForEach-Object { $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner; "$($_.ProcessId) $($o.User) session $($_.SessionId) from $($_.CreationDate.ToString('HH:mm:ss.fff'))" }) -join '; ' }
# Changes Rime's files with no server holding them, then starts one below normal priority, even when the change
# failed, and waits for its pipe. The server's mutex (windows/src/server.cpp) is held meanwhile: an app's text
# service that finds no server starts one (ChsIME's does, after Microsoft Pinyin was on), which would load
# Rime's files mid-change at normal priority and keep this one from starting (#332). Held, it leaves at once.
function Restart-Server([scriptblock]$change) {
  $hold = [Threading.Mutex]::new($false, 'Local\SebType.Server')
  try {
    if ($old = Server) { Start-Process -Wait $server '/quit'; if (-not $old.WaitForExit(10000)) { throw 'the server did not quit in 10 s' } }
    & $change
  } finally {
    $hold.Dispose()
    # Started again when it left with no pipe there: an app's server, rejected, may still have held the mutex.
    # The pipe is looked for in the list, not opened (Test-Path does): opened, it is busy, and seems gone.
    $name = "SebType.$((Get-Process -Id $PID).SessionId).$env:USERNAME"  # windows/src/pipe.h
    $up = { [IO.Directory]::GetFiles('\\.\pipe\') -like "*\$name" }
    for ($try = 1; -not (& $up); $try++) {
      if ($try -gt 3) { throw "no pipe $name after 3 starts" }
      $started = Start-Process $server -PassThru
      $end = (Get-Date).AddSeconds(20)
      while (-not (& $up) -and -not $started.HasExited) {
        if ((Get-Date) -gt $end) { throw "no pipe $name 20 s after the server started" }
        Start-Sleep -Milliseconds 200
      }
      if (-not (& $up)) { Start-Sleep 1 }  # the server that kept it out may still be making its pipe
    }
  }
  # An app may still start one as the mutex is let go, which then serves instead: whichever serves runs below
  # normal priority, and it is the only one.
  $end = (Get-Date).AddSeconds(3)
  while (($n = @(Get-Process sebtype-server | Where-Object SessionId -EQ (Get-Process -Id $PID).SessionId).Count) -gt 1 -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 100 }
  if ($n -ne 1) { throw "$n servers after the restart: $(Servers)" }
  (Server).PriorityClass = 'BelowNormal'
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
# Rime's build folder back from the copy beside it, by renames on the one volume: the deployed one is set
# aside, the copy takes its name, and only then is the deployed one deleted; a failed rename is undone.
function Restore-Build {
  $removed = "$backup.removed"
  Rename-Item $rimeBuild (Split-Path -Leaf $removed)
  try { Rename-Item $backup 'build' } catch { Rename-Item $removed 'build' -ErrorAction Continue; throw }
  Remove-Item -Recurse $removed
}
$tsf::Start()
Result scale INFO "$($tsf::Dpi()) dpi, $([int]($tsf::Dpi() * 100 / 96)) %; pictures in the screen's own pixels"
try {
  # The first 日本語 after the install (#312): Mozc's first load took seconds, the activation waited for it
  # past the text service's 3 s reply wait, and there was no button and no key taken for over 4 s (YukaROG).
  # Now the button is there at once (grey あ while Mozc loads), a key goes in as typed without waiting, and
  # あ shows once Mozc is up, unasked.
  Check 'first-japanese' {
    $was = if (Server) { 'a server ran already' } else { 'no server yet' }
    # YukaROG's first load took over 4 s; TCSBackEnd's is fast by itself, so its open is held 8 s: long
    # enough for reload-while-loading too.
    $script:slowed = [SlowOpen]::Hold("$env:ProgramFiles\SebType\sebtype-mozc.dll", 8000)
    $t = Get-Date; Lang ja; $activation = [int]((Get-Date) - $t).TotalMilliseconds - 500  # Lang settles 500 ms
    $script:first = Shot 'hira-first'
    $tsf::Clear(); $t = Get-Date; Ready; $null = $tsf::Key((Vk 'n')); $key = [int]((Get-Date) - $t).TotalMilliseconds
    $tsf::Settle(300); $typed = $tsf::Text(); Keys Escape; $tsf::Clear()
    $script:held = $slowed -and [SlowOpen]::AskedAt
    $load = if (-not $slowed) { "Mozc's load not slowed (no oplock)" } elseif ($held) { 'Mozc held 8 s at its load' } else { 'Mozc not loaded yet' }
    $timeline = "$was, $load, activation $activation ms, key $key ms gave '$typed'"
    if ($activation -gt 1500) { throw "the activation took $activation ms ($timeline)" }
    if ($key -gt 3500) { throw "the key waited $key ms ($timeline)" }
    if ($held -and $typed -ne 'n') { throw "the key while Mozc loads gave '$typed', not n as typed ($timeline)" }
    if ($held -and (Shot 'hira-first-key') -ne $first) { throw "the icon changed while Mozc loads ($timeline)" }
    if ($held) { "grey あ at once, n as typed ($timeline)" } else { "INFO: Mozc's load wasn't held: $timeline" }
  }
  # The Configurator's reload (/mozc) while Mozc still loads: 中文 still switches and types at once (#312).
  Check 'reload-while-loading' {
    if (-not $held) { return "SKIP: Mozc's load wasn't held" }
    $reload = Start-Process $server '/mozc' -PassThru; $tsf::Settle(300)
    $t = Get-Date; Lang zh; $switch = [int]((Get-Date) - $t).TotalMilliseconds - 500
    $end = (Get-Date).AddSeconds(10); $slowest = 0
    do {
      $tsf::Clear(); $t = Get-Date; Keys n i space
      $slowest = [Math]::Max($slowest, [int]((Get-Date) - $t).TotalMilliseconds - 3 * 150 - 600)
    } while ($tsf::Text() -ne '你' -and (Get-Date) -lt $end)
    $t = $tsf::Text(); $tsf::Clear()
    $timeline = "switch $switch ms, keys waited up to $slowest ms, Mozc's load $(if ([SlowOpen]::AskedAt + 8000 - [Environment]::TickCount -gt 0) { 'still held' } else { 'over' })"
    if (-not $reload.WaitForExit(10000)) { throw "/mozc didn't return in 10 s ($timeline)" }
    if ($switch -gt 1500) { throw "the switch to 中文 took $switch ms ($timeline)" }
    if ($slowest -gt 1000) { throw "a key waited $slowest ms ($timeline)" }
    if ($t -ne '你') { throw "ni + Space gave '$t' ($timeline)" }
    "ni + Space gives 你 ($timeline)"
  }
  # あ comes unasked once Mozc is up, the reload asked for during its load done too (the text service's
  # readiness timer, no key), and then the first ka gives か: no key goes to a Mozc that isn't ready.
  Check 'first-japanese-back' {
    if (-not $held) { return "SKIP: Mozc's load wasn't held" }
    Lang ja
    $end = (Get-Date).AddSeconds(30)
    do { $tsf::Settle(250); $now = Shot 'hira-first-up' } while ($now -eq $first -and (Get-Date) -lt $end)
    if ($now -eq $first) { throw 'still grey 30 s after the activation, no key typed' }
    $tsf::Clear(); Keys k a; $t = $tsf::Text(); Keys Escape; $tsf::Clear()
    $after = Shot 'hira-first-typed'
    if ($t -ne 'か') { throw "the first ka once あ showed gave '$t', not か" }
    if ($after -ne $now) { throw 'the icon that came unasked is not the one after typing か' }
    'あ unasked after the load and the reload, then ka gives か at once'
  }
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
  Check 'dpi-change' {
    Lang zh; $tsf::Clear(); Keys n i
    try { DpiRoundTrip 'dpi-candidates' } finally { Keys Escape; $tsf::Clear() }
  }
  # Every later check compares against these two icons.
  if (-not ($hira -and $zh) -or $hira -eq $zh) { throw 'not ready: no further checks' }
  # Windows' own Microsoft Pinyin in the same taskbar, to set ours beside (ms-pinyin.png, ms-pinyin-taskbar.png).
  Check 'windows-ime' {
    $clsid = [Guid]'{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}'; $profile = [Guid]'{FA550B04-5AD7-411F-A5AC-CA038EC515D7}'
    $was = try { $tsf::Enabled(0x804, $clsid, $profile) } catch { return "SKIP: no Microsoft Pinyin ($($_.Exception.InnerException.Message))" }
    try {
      if (-not $was) { $tsf::Enable(0x804, $clsid, $profile, $true) }  # for this capture only
      $tsf::Activate(0x804, $clsid, $profile); $tsf::Settle(1500)
      try { Shot 'ms-pinyin' | Out-Null; $what = 'its button icon and the taskbar saved' }
      catch { $tsf::Taskbar("$Out\ms-pinyin-taskbar.png", 360); $what = "the taskbar saved; no button icon ($($_.Exception.Message))" }
    } catch { $what = "can't be switched to ($($_.Exception.InnerException.Message))" }
    finally { Lang zh; if (-not $was) { $tsf::Enable(0x804, $clsid, $profile, $false) } }
    "INFO: Microsoft Pinyin$(if (-not $was) { ', on for this capture only,' }) for comparison: $what"
  }

  # A deploy with nothing changed is over at once: without its prisms (built from the prebuilt tables), Rime
  # takes seconds. The server keeps them mapped, so it quits first (saving), and a new one starts below
  # normal priority, so its deploy never slows what else the PC serves. The build folder is put back at the end,
  # from this run's own copy beside it, and only once the copy is known complete.
  $copy = "$rimeBuild.sebtype-test-$((New-Guid).ToString('N'))"
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
  # The popup (1.2 s) rescales too: the first key once the server hangs shows it.
  Check 'dpi-change-popup' {
    Lang ja
    $script:suspended = Server
    [SebTypeSuspend]::NtSuspendProcess($suspended.Handle) | Out-Null
    try { Ready; $null = $tsf::Key((Vk 'k')); $tsf::Settle(200); DpiRoundTrip 'dpi-popup' }
    finally {
      [SebTypeSuspend]::NtResumeProcess($suspended.Handle) | Out-Null; $script:suspended = $null
      $null = WaitIcon $hira 4; $tsf::Clear()
    }
  }
  Check 'popup-own-content' {
    $d = $tsf::Dpi(); $popup = "$Out\dpi-popup-fresh-$d.png"
    if (-not (Test-Path $popup) -or -not (Test-Path "$Out\hira-off-popup.png")) { throw 'no popup from dpi-change-popup or japanese-unavailable to compare' }
    $diff = $tsf::Differ($popup, "$Out\hira-off-popup.png", [math]::Ceiling(8 * $d / 96))
    if ($diff) { throw "it differs from japanese-unavailable's popup: $diff (dpi-popup-fresh-$d.png, hira-off-popup.png)" }
    "the same as japanese-unavailable's popup: no page arrows left from the candidates"
  }
  # The server hangs while か is being typed: か stays as it showed, the key goes in after it with the popup,
  # and once the server answers again nothing of the old typing comes back or deletes it. The second time the
  # app grants the text service's edit only after it handled the key, as an app may: a letter, then a keypad digit.
  $hang = {
    param($key, $defer, $shot)
    Lang ja; $tsf::Clear(); Keys k a
    $script:suspended = Server
    [SebTypeSuspend]::NtSuspendProcess($suspended.Handle) | Out-Null
    $tsf::DeferLocks = $defer
    try { $size = KeyWithPopup $key $shot; $why = $null } catch { $why = $_.Exception.Message }
    finally { $tsf::DeferLocks = $false }
    $t = $tsf::Text()
    [SebTypeSuspend]::NtResumeProcess($suspended.Handle) | Out-Null; $script:suspended = $null
    $icon = WaitIcon $hira 4; Keys i; $after = $tsf::Text(); Keys Escape
    $c = if ($key -match '^kp(\d)$') { $Matches[1] } else { $key }
    if ($why) { throw "${key}: $why (text '$t')" }
    if ($t -ne "か$c") { throw "か then $key while the server hangs gave '$t', not か$c" }
    if ($icon -ne $hira) { throw "${key}: the icon did not turn back to あ within 4 s" }
    if ($after -ne "か${c}い") { throw "${key}: i after the server answered again gave '$after', not か${c}い" }
    "か$c with the popup $size, then i gives $after"
  }
  Check 'hang-mid-composition' { & $hang 'n' $false 'hang-mid' }
  Check 'hang-mid-deferred-lock' { (& $hang 'n' $true 'hang-mid-deferred'), (& $hang 'kp1' $true 'hang-mid-deferred-kp') -join '; ' }
} catch {
  Result 'script' FAIL $_.Exception.Message  # a check that can't go on: the rest is skipped
} finally {
  if ($suspended) { [SebTypeSuspend]::NtResumeProcess($suspended.Handle) | Out-Null }
  if ($backup) {
    if ($deploy -and -not $deploy.HasExited) { $deploy.WaitForExit(300000) | Out-Null }
    try { Restart-Server { Restore-Build } }
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
