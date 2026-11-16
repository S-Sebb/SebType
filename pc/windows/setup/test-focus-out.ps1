<#
Focus moving away mid-word types in what was being typed (#277), on a Windows PC with SebType installed,
in the logged-on person's own desktop session (not elevated; it sends real keys there, so nobody should
use the PC meanwhile). One command:

    powershell -ExecutionPolicy Bypass -File test-focus-out.ps1 [-Out <folder>]

The fields are two ordinary edit controls in a window of the script's own, the way classic apps (Notepad
on Windows Server) take input; TsfHost.cs (beside this script) is the other window. Checks: 中文 ranhou
Space gives 然后; nihao, then the other field or the other window and back, leaves nihao in the field, and
ni Space after it gives 你 (nothing left over); 日本語 nihongo Space, then the other field, leaves 日本語.
Results: one line per check in <Out>\focus-out-results.txt; exit 0 only if all pass.
#>
param([string]$Out = "$env:USERPROFILE\scratch\SebType\277")
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSCommandPath
New-Item -ItemType Directory -Force $Out | Out-Null
$results = "$Out\focus-out-results.txt"
Set-Content -Encoding utf8 $results ''
function Result($name, $status, $why = '') {
  $line = "$status $name$(if ($why) { ": $why" })"
  Add-Content -Encoding utf8 $results $line; Write-Host $line
}
function Check($name, [scriptblock]$body) {
  try { $why = & $body; Result $name PASS $why } catch { Result $name FAIL $_.Exception.Message }
}

$missing = if (-not (Test-Path "$env:ProgramFiles\SebType\sebtype.dll")) { 'SebType is not installed' }
elseif ((Get-Process -Id $PID).SessionId -eq 0) { 'runs in session 0: start it in the desktop session' }
elseif (-not (Test-Path "$root\TsfHost.cs")) { "no TsfHost.cs beside $PSCommandPath" }
if ($missing) { Write-Host "BLOCKED preflight: $missing"; exit 1 }

$Clsid = '{D4E5C593-4F73-475F-936C-0E29A6FE7A02}'
$ZhProfile = '{8AA7DDAC-A4B8-4437-9C0B-8698879EC987}'
$JaProfile = '{B148FB02-C235-45D6-996C-672C783ECD48}'
Add-Type -Path "$root\TsfHost.cs" -ReferencedAssemblies System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms @'
using System; using System.Threading; using System.Windows.Forms; using System.Runtime.InteropServices;
namespace SebTypeFocus {
  // A window with two edit controls on its own thread.
  public static class Fields {
    static Form form; static TextBox[] boxes;
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code, uint type);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    // The window in front is this process's (the test window or TsfHost's): keys go nowhere else.
    public static bool Ours() {
      uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
      return pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
    }
    public static IntPtr Start() {
      var ready = new ManualResetEvent(false);
      var t = new Thread(() => {
        form = new Form { Text = "SebType focus test", Width = 500, Height = 160 };
        boxes = new[] { new TextBox { Left = 10, Top = 10, Width = 460 }, new TextBox { Left = 10, Top = 50, Width = 460 } };
        form.Controls.AddRange(boxes);
        form.Shown += (s, e) => ready.Set();
        Application.Run(form);
      });
      t.SetApartmentState(ApartmentState.STA); t.IsBackground = true; t.Start();
      if (!ready.WaitOne(20000)) throw new TimeoutException("the test window didn't show");
      return OnUi(() => form.Handle);
    }
    public static void Stop() { try { OnUi(() => { form.Close(); return 0; }); } catch { } }
    static T OnUi<T>(Func<T> f) { return (T)form.Invoke(f); }
    public static void Focus(int i) { OnUi(() => { boxes[i].Focus(); boxes[i].SelectionStart = boxes[i].TextLength; return 0; }); }
    public static string Text(int i) { return OnUi(() => boxes[i].Text); }
    public static void Clear() { OnUi(() => { foreach (var b in boxes) b.Clear(); return 0; }); }
    public static void Key(byte vk) {
      byte scan = (byte)MapVirtualKeyW(vk, 0);
      keybd_event(vk, scan, 0, UIntPtr.Zero); keybd_event(vk, scan, 2, UIntPtr.Zero);
    }
  }
}
'@
$tsf = [SebType.TsfHost]
$f = [SebTypeFocus.Fields]
function Keys {
  if (-not $f::Ours()) { throw 'another program''s window is in front: no keys sent' }
  foreach ($k in $args) { $f::Key($(switch ($k) { 'space' { 0x20 } 'Escape' { 0x1B } default { [byte][char]$k.ToUpper() } })); Start-Sleep -Milliseconds 150 }; Start-Sleep -Milliseconds 600 }
function TypeText($s) { $chars = @($s.ToCharArray() | ForEach-Object { if ($_ -eq ' ') { 'space' } else { "$_" } }); Keys @chars }
function Front { if (-not $tsf::Foreground($h)) { throw 'the test window did not come to the front' }; $f::Focus(0); Start-Sleep -Milliseconds 300 }
function Lang($lang) {  # this process's input method (TF_IPPMF_FORPROCESS), then the first field
  if ($lang -eq 'zh') { $tsf::Activate(0x804, [Guid]$Clsid, [Guid]$ZhProfile) } else { $tsf::Activate(0x411, [Guid]$Clsid, [Guid]$JaProfile) }
  Front; $f::Clear(); $f::Focus(0)
}
function Away($how) {  # the other field, or the other window and back
  if ($how -eq 'field') { $f::Focus(1) }
  else { if (-not $tsf::Focus()) { throw 'the other window did not come to the front' }; Start-Sleep 1; Front }
  Start-Sleep 1
}

$tsf::Start()
$h = $f::Start()
try {
  Lang zh
  Keys n i; Start-Sleep 3; Keys Escape  # the first key starts sebtype-server when none runs
  Check 'chinese-pinyin' {
    $f::Clear(); $f::Focus(0); TypeText 'ranhou '; $t = $f::Text(0)
    if ($t -ne '然后') { throw "ranhou + Space gave '$t'" }
    $t
  }
  foreach ($how in 'field', 'window') {
    Check "chinese-focus-out-$how" {
      $f::Clear(); $f::Focus(0); TypeText 'nihao'; Away $how; $away = $f::Text(0)
      $f::Focus(0); TypeText 'ni '; $t = $f::Text(0)
      if ("$away $t" -ne 'nihao nihao你') { throw "nihao, then the other $how, left '$away'; ni + Space after it gave '$t' (want nihao, nihao你)" }
      "nihao stays; then $t"
    }
  }
  Lang ja
  Check 'japanese-focus-out-field' {
    $f::Clear(); $f::Focus(0); TypeText 'nihongo '; Away field; $t = $f::Text(0)
    if ($t -ne '日本語') { throw "nihongo + Space, then the other field, left '$t'" }
    $t
  }
} finally {
  if ($f::Ours()) { Keys Escape Escape }
  $f::Stop(); $tsf::Stop()
}
$failed = @(Get-Content $results | Where-Object { $_ -like 'FAIL *' }).Count
exit [int]($failed -gt 0)
