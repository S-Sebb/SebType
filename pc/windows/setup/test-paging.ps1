<#
The candidate window's page arrows, wheel paging, kept width and wrapping (#276), on a Windows PC with
SebType installed, in the logged-on person's own desktop session (not elevated; it sends real keys and
mouse input there, so nobody should use the PC meanwhile). One command:

    powershell -ExecutionPolicy Bypass -File test-paging.ps1 [-Out <folder>]

TsfHost.cs (beside this script) is the text field. For Picnic and the system look, across and down, it
types pinyin and takes pictures of the first, a middle and the last page, a wrapped page and the window
at the screen's right and bottom edges; then pages with clicks on the arrows and the mouse wheel and
checks each lands on the page the keyboard shows. sebtype.conf goes back as it was. Results: one line
per check in <Out>\paging-results.txt, pictures <Out>\*.png; exit 0 only if all pass.

-Colours instead takes pictures of the system look in Windows' light mode, dark mode and the high-contrast
theme Night sky, across and down, and of Picnic for comparison (#279): the first page (faint ‹), the second
and Japanese with Mozc's comments. Light/dark mode and high contrast go back as they were. It makes no input
of its own, as test-focus-out.ps1 (#277): keys go to TSF's keystroke manager, so a screen that is off stays
off. -Watch <file> is test-focus-out.ps1 -WatchTo's log of the display's state: the run stops once it shows
the display on. -Trial needs no SebType: each mode switch, one key and a picture of the field, then the
settings restored, to see that none of it lights the display and that pictures work with it off.
#>
param([string]$Out = "$env:USERPROFILE\scratch\SebType\276\screens", [switch]$Colours, [switch]$Trial, [string]$Watch)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSCommandPath
New-Item -ItemType Directory -Force $Out | Out-Null
$results = "$Out\paging-results.txt"
Set-Content -Encoding utf8 $results ''
function Result($name, $status, $why = '') {
  $line = "$status $name$(if ($why) { ": $why" })"
  Add-Content -Encoding utf8 $results $line; Write-Host $line
}
function Check($name, [scriptblock]$body) {
  try { $why = & $body; Result $name PASS $why } catch { Result $name FAIL $_.Exception.Message }
}

$missing = if (-not $Trial -and -not (Test-Path "$env:ProgramFiles\SebType\sebtype.dll")) { 'SebType is not installed' }
elseif ((Get-Process -Id $PID).SessionId -eq 0) { 'runs in session 0: start it in the desktop session' }
elseif (-not (Test-Path "$root\TsfHost.cs")) { "no TsfHost.cs beside $PSCommandPath" }
if ($missing) { Write-Host "BLOCKED preflight: $missing"; exit 1 }

$Clsid = '{D4E5C593-4F73-475F-936C-0E29A6FE7A02}'
$ZhProfile = '{8AA7DDAC-A4B8-4437-9C0B-8698879EC987}'
$JaProfile = '{B148FB02-C235-45D6-996C-672C783ECD48}'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path "$root\TsfHost.cs" -ReferencedAssemblies System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
namespace SebTypePaging {
  public static class Input {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, int data, UIntPtr extra);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
    // The scheme's name as a pointer: Windows owns the string SPI_GETHIGHCONTRAST points it at.
    [StructLayout(LayoutKind.Sequential)] struct HIGHCONTRAST { public int size; public uint flags; public IntPtr scheme; }
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action, uint param, ref HIGHCONTRAST hc, uint winIni);
    [DllImport("user32.dll")] public static extern uint GetSysColor(int index);
    static HIGHCONTRAST GetHighContrast() { var hc = new HIGHCONTRAST(); hc.size = Marshal.SizeOf(hc); SystemParametersInfoW(0x42, (uint)hc.size, ref hc, 0); return hc; }
    public static uint HighContrastFlags() { return GetHighContrast().flags; }
    public static string HighContrastScheme() { var p = GetHighContrast().scheme; return p == IntPtr.Zero ? null : Marshal.PtrToStringUni(p); }
    // SPI_SETHIGHCONTRAST, saved and broadcast as Settings does.
    public static void SetHighContrast(uint flags, string scheme) {
      var hc = new HIGHCONTRAST(); hc.size = Marshal.SizeOf(hc); hc.flags = flags;
      hc.scheme = string.IsNullOrEmpty(scheme) ? IntPtr.Zero : Marshal.StringToHGlobalUni(scheme);
      try { SystemParametersInfoW(0x43, (uint)hc.size, ref hc, 3); } finally { if (hc.scheme != IntPtr.Zero) Marshal.FreeHGlobal(hc.scheme); }
    }
    // The visible candidate window (other apps with the text service have hidden ones).
    public static IntPtr Window() {
      IntPtr found = IntPtr.Zero;
      EnumWindows((h, l) => {
        var s = new System.Text.StringBuilder(64); GetClassNameW(h, s, 64);
        if (IsWindowVisible(h) && s.ToString() == "SebType.Candidates") { found = h; return false; }
        return true;
      }, IntPtr.Zero);
      return found;
    }
    // Whether a picture of the screen there shows anything (the display off may leave it blank).
    public static bool Blank(int x, int y, int w, int h) {
      using (var bmp = new Bitmap(w, h)) {
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(x, y, 0, 0, bmp.Size);
        var first = bmp.GetPixel(0, 0);
        for (int i = 0; i < w; i += 4) for (int j = 0; j < h; j += 4) if (bmp.GetPixel(i, j) != first) return false;
        return true;
      }
    }
    public static float Scale(IntPtr h) { return GetDpiForWindow(h) / 96f; }
    public static void Key(byte vk) { keybd_event(vk, 0, 0, UIntPtr.Zero); keybd_event(vk, 0, 2, UIntPtr.Zero); }
    public static void Click(int x, int y) { SetCursorPos(x, y); mouse_event(2, 0, 0, 0, UIntPtr.Zero); mouse_event(4, 0, 0, 0, UIntPtr.Zero); }
    public static void Wheel(int x, int y, int delta) { SetCursorPos(x, y); mouse_event(0x800, 0, 0, delta, UIntPtr.Zero); }
    // A picture of the window, and a hash of its pixels to tell pages apart.
    public static string Shot(IntPtr h, string path) {
      RECT r; GetWindowRect(h, out r);
      using (var bmp = new Bitmap(r.R - r.L, r.B - r.T)) {
        using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(r.L, r.T, 0, 0, bmp.Size);
        if (!string.IsNullOrEmpty(path)) bmp.Save(path, ImageFormat.Png);
        var data = bmp.LockBits(new Rectangle(Point.Empty, bmp.Size), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var bytes = new byte[data.Stride * data.Height];
        Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
        bmp.UnlockBits(data);
        using (var sha = System.Security.Cryptography.SHA1.Create()) return BitConverter.ToString(sha.ComputeHash(bytes));
      }
    }
  }
}
'@
$tsf = [SebType.TsfHost]
$in = [SebTypePaging.Input]
# Per-monitor aware, as apps like Notepad are, before any window: else Windows stretches the window's
# picture on a scaled screen and moves the mouse in scaled coordinates.
$null = $in::SetProcessDpiAwarenessContext([IntPtr]-4)
$conf = "$env:APPDATA\SebType\sebtype.conf"
$confBefore = if (Test-Path $conf) { Get-Content -Raw $conf }

function Keys { foreach ($k in $args) { Dark; $null = $(if ($Colours) { $tsf } else { $in })::Key($(switch ($k) { 'space' { 0x20 } 'PageDown' { 0x22 } 'PageUp' { 0x21 } 'Escape' { 0x1B } default { [byte][char]$k.ToUpper() } })); Start-Sleep -Milliseconds 120 }; $tsf::Settle(400) }
function TypeText($s) { $chars = @($s.ToCharArray() | ForEach-Object { "$_" }); Keys @chars }
# With -Watch: stop once the display has been on.
function Dark { if ($Watch -and (Get-Content $Watch -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch ' 0$' })) { throw "the display came on: $((Get-Content $Watch) -join ', ')" } }
function Win { $h = $in::Window(); if ($h -eq [IntPtr]::Zero) { throw "no candidate window (the field holds '$($tsf::Text())', active $($tsf::Active()))" }; $h }
function Rect($h) { $r = New-Object SebTypePaging.Input+RECT; $null = $in::GetWindowRect($h, [ref]$r); $r }
function Size($h) { $r = Rect $h; "$($r.R - $r.L)x$($r.B - $r.T)" }
function Shot($name) { $h = Win; $in::Shot($h, $(if ($name) { "$Out\$name.png" })) }
function Hash { $in::Shot((Win), $null) }
# The arrows' centres, as candidate_layout.cpp places them: at the top right, inside the 12 px margin, each
# 0.8 of a text row wide (Microsoft YaHei's row is about 1.32 of its size, 14 pt here) with 4 px between.
function Arrow($next) {
  $h = Win; $r = Rect $h; $s = $in::Scale($h)
  $row = [math]::Round(14 * 96 / 72 * $s * 1.32); $w = [math]::Round($row * 0.8)
  $x = $r.R - [math]::Round(12 * $s) - $w / 2
  if (-not $next) { $x -= $w + [math]::Round(4 * $s) }
  @([int]$x, [int]($r.T + [math]::Round(12 * $s) + $row / 2))
}
function Field($lang) {
  if (-not $tsf::Focus()) { throw 'the text field did not get the keyboard focus' }
  if ($lang -eq 'zh') { $tsf::Activate(0x804, [Guid]$Clsid, [Guid]$ZhProfile) } else { $tsf::Activate(0x411, [Guid]$Clsid, [Guid]$JaProfile) }
  $tsf::Settle(500); $tsf::Clear()
}
function Word($w) { Keys Escape Escape; $tsf::Clear(); TypeText $w; Start-Sleep -Milliseconds 600; $tsf::Settle(200) }
function Caret($x, $y) { [SebType.TextStore]::CaretX = $x; [SebType.TextStore]::CaretY = $y }

function Conf($look, $o) {
  New-Item -ItemType Directory -Force (Split-Path $conf) | Out-Null
  Set-Content -Encoding ascii $conf '[Candidates]', "Vertical=$([int]($o -eq 'down'))", 'FontSize=14', "Picnic=$([int]($look -eq 'picnic'))"
}

if ($Colours) {
  $personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
  $lightBefore = (Get-ItemProperty $personalize -ErrorAction SilentlyContinue).AppsUseLightTheme
  $hcBefore = $in::HighContrastFlags(); $schemeBefore = $in::HighContrastScheme()
  # Turning high contrast on saves its scheme's name here, and off leaves it.
  $hcKey = 'HKCU:\Control Panel\Accessibility\HighContrast'
  $schemeSaved = (Get-ItemProperty $hcKey -ErrorAction SilentlyContinue).'High Contrast Scheme'
  $themeBefore = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes').CurrentTheme
  function Mode($mode) {
    $flags = $in::HighContrastFlags()
    $on = $mode -eq 'high-contrast'
    if ((($flags -band 1) -ne 0) -ne $on) {
      if ($on) { $in::SetHighContrast(($flags -bor 1), 'High Contrast Black') } else { $in::SetHighContrast(($flags -band -bnot 1), $schemeBefore) }
      Start-Sleep 8
    }
    if (-not $on) { Set-ItemProperty $personalize AppsUseLightTheme ([int]($mode -eq 'light')) -Type DWord }
    if ((($in::HighContrastFlags() -band 1) -ne 0) -ne $on) { throw "high contrast did not turn $(if ($on) { 'on' } else { 'off' })" }
  }
  $tsf::NoInput = $true
  $tsf::Start()
  try {
    if ($Trial) {
      Check 'trial' {
        foreach ($m in 'dark', 'light', 'high-contrast', 'light') { Write-Host "trial: $m"; Mode $m; Dark }
        Write-Host 'trial: one key'
        if (-not $tsf::Focus()) { throw "the field did not come to the front: $($tsf::FocusState())" }
        Keys a; $tsf::Settle(500)
        if ($in::Blank(0, 0, 640, 200)) { throw 'the picture of the field is blank' }
        "modes switched, one key, the field's picture not blank"
      }
    }
    foreach ($m in $(if ($Trial) { @() } else { @('light', 'dark', 'high-contrast' | ForEach-Object { , @('system', $_) }) + , @('picnic', 'light') })) {
      $look, $mode = $m
      foreach ($o in 'across', 'down') {
        $tag = "$look-$(if ($look -eq 'system') { "$mode-" })$o"
        Check $tag {
          Mode $mode; Conf $look $o; Caret 20 20; Field zh
          Word 'nihao'; $null = Shot "$tag-1-first"
          Keys PageDown; $null = Shot "$tag-2-second"; Keys Escape Escape
          Field ja; Keys Escape; $tsf::Clear(); TypeText 'kawaii'; Keys space space; Start-Sleep -Milliseconds 600
          $null = Shot "$tag-3-ja"; Keys Escape Escape Escape
          "window $('{0:x6}' -f $in::GetSysColor(5)), text $('{0:x6}' -f $in::GetSysColor(8)) (0xBBGGRR)"
        }
      }
    }
  } finally {
    $tsf::Stop()
    if ($null -ne $confBefore) { Set-Content -NoNewline -Encoding utf8 $conf $confBefore } else { Remove-Item -ErrorAction SilentlyContinue $conf }
    if ($in::HighContrastFlags() -ne $hcBefore) { $in::SetHighContrast($hcBefore, $schemeBefore); Start-Sleep 8 }
    if ($null -ne $schemeSaved) { Set-ItemProperty $hcKey 'High Contrast Scheme' $schemeSaved } else { Remove-ItemProperty $hcKey 'High Contrast Scheme' -ErrorAction SilentlyContinue }
    if ($null -ne $lightBefore) { Set-ItemProperty $personalize AppsUseLightTheme $lightBefore -Type DWord } else { Remove-ItemProperty $personalize AppsUseLightTheme -ErrorAction SilentlyContinue }
    $themeAfter = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes').CurrentTheme
    Check 'settings-restored' {
      if ($in::HighContrastFlags() -ne $hcBefore) { throw "high-contrast flags $($in::HighContrastFlags()), were $hcBefore" }
      if ((Get-ItemProperty $personalize -ErrorAction SilentlyContinue).AppsUseLightTheme -ne $lightBefore) { throw 'AppsUseLightTheme differs' }
      if ((Get-ItemProperty $hcKey -ErrorAction SilentlyContinue).'High Contrast Scheme' -ne $schemeSaved) { throw "High Contrast Scheme differs from '$schemeSaved'" }
      if ($themeAfter -ne $themeBefore) { throw "theme $themeAfter, was $themeBefore" }
      "AppsUseLightTheme $lightBefore, high contrast flags $hcBefore, theme $themeBefore"
    }
  }
  $failed = @(Get-Content $results | Where-Object { $_ -like 'FAIL *' }).Count
  exit [int]($failed -gt 0)
}

$tsf::Start()
try {
  foreach ($look in 'picnic', 'system') {
    foreach ($o in 'across', 'down') {
      Conf $look $o
      $tag = "$look-$o"
      Caret 20 20
      Field zh
      # The first, a middle and the last page: the same width (down: never narrower), the arrows in the shot.
      Check "$tag-pages" {
        Word 'nihao'
        $null = Shot "$tag-1-first"; $first = Size (Win)
        Keys PageDown; $null = Shot "$tag-2-middle"; $middle = Size (Win)
        $last = Hash; $n = 2
        while ($n -lt 40) { Keys PageDown; $h = Hash; if ($h -eq $last) { break }; $last = $h; $n++ }
        $null = Shot "$tag-3-last"; $end = Size (Win)
        $widths = @($first, $middle, $end | ForEach-Object { [int]($_ -split 'x')[0] })
        if ($o -eq 'across' -and ($widths | Select-Object -Unique).Count -ne 1) { throw "widths differ: first $first, middle $middle, last $end" }
        if ($o -eq 'down' -and ($widths[1] -lt $widths[0] -or $widths[2] -lt $widths[0])) { throw "narrower than the first page: $first, $middle, $end" }
        "first $first, middle $middle, last $end (page $n)"
      }
      # Clicks on the arrows and the wheel land where PageDown and PageUp do; the faint ‹ does nothing.
      Check "$tag-mouse" {
        Word 'nihao'; $p1 = Hash
        Keys PageDown; $p2 = Hash; Keys PageUp
        if ($p1 -eq $p2) { throw 'PageDown did not change the page' }
        $x, $y = Arrow $false; $in::Click($x, $y); $tsf::Settle(400)
        if ((Hash) -ne $p1) { throw 'a click on the faint ‹ of the first page changed it' }
        $x, $y = Arrow $true; $in::Click($x, $y); $tsf::Settle(400)
        if ((Hash) -ne $p2) { throw "a click on › at $x,$y did not show page 2" }
        $x, $y = Arrow $false; $in::Click($x, $y); $tsf::Settle(400)
        if ((Hash) -ne $p1) { throw "a click on ‹ at $x,$y did not go back to page 1" }
        $r = Rect (Win); $cx = [int](($r.L + $r.R) / 2); $cy = [int](($r.T + $r.B) / 2)
        $in::Wheel($cx, $cy, -120); $tsf::Settle(400)
        if ((Hash) -ne $p2) { throw 'the wheel down did not show page 2' }
        $in::Wheel($cx, $cy, 120); $tsf::Settle(400)
        if ((Hash) -ne $p1) { throw 'the wheel up did not go back to page 1' }
        if ($tsf::Text()) { throw "the clicks committed '$($tsf::Text())'" }
        'arrows and wheel page as the keys do'
      }
      # A page that needs more room than the first one's width wraps: taller, same width.
      if ($o -eq 'across') {
        Check "$tag-wrap" {
          # Chinese words, then Japanese ones (converted with two spaces), whose comments vary more by page.
          $words = @('women', 'zhongguo', 'shijie', 'xiexie', 'hello', 'a', 'yi' | ForEach-Object { , @('zh', $_) }) +
                   @('kawaii', 'hai', 'kami', 'nihongo' | ForEach-Object { , @('ja', $_) })
          $cur = 'zh'
          try {
            foreach ($lw in $words) {
              $lang, $w = $lw
              if ($lang -ne $cur) { Field $lang; $cur = $lang }
              if ($lang -eq 'zh') { Word $w } else { Keys Escape Escape Escape; $tsf::Clear(); TypeText $w; Keys space space; Start-Sleep -Milliseconds 600 }
              $first = Rect (Win); $last = Hash
              for ($n = 2; $n -le 30; $n++) {
                Keys PageDown; $r = Rect (Win); $h = Hash
                if ($h -eq $last) { break }; $last = $h
                if ($r.B - $r.T -gt $first.B - $first.T + 10) {  # a row more, not a taller glyph
                  $null = Shot "$tag-4-wrapped"
                  if ($r.R - $r.L -ne $first.R - $first.L) { throw "'$w' page $n wrapped but its width changed" }
                  return "'$w' page ${n}: $($first.B - $first.T) -> $($r.B - $r.T) px tall, $($r.R - $r.L) px wide"
                }
              }
            }
            throw 'no page of the words tried wrapped'
          } finally { Keys Escape Escape Escape; Field zh }
        }
      }
      # At the screen's right edge the window moves left; at its bottom it goes above the text; always on
      # the monitor's work area.
      Check "$tag-edges" {
        $work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        Caret ($work.Right - 30) 200; Word 'zhongguo'; $r = Rect (Win); $null = Shot "$tag-5-right-edge"
        if ($r.R -gt $work.Right -or $r.L -lt $work.Left) { throw "at the right edge the window spans $($r.L)..$($r.R), the screen $($work.Left)..$($work.Right)" }
        Caret 200 ($work.Bottom - 30); Word 'zhongguo'; $b = Rect (Win)
        if ($b.B -gt $work.Bottom -or $b.T -lt $work.Top) { throw "at the bottom the window spans $($b.T)..$($b.B), the screen $($work.Top)..$($work.Bottom)" }
        Caret 20 20
        "right edge: $($r.L)..$($r.R) of ..$($work.Right); bottom: $($b.T)..$($b.B) of ..$($work.Bottom)"
      }
      # Japanese: the arrows on Mozc's row.
      Check "$tag-ja" {
        Field ja; Keys Escape; $tsf::Clear(); TypeText 'kawaii'; Keys space space; Start-Sleep -Milliseconds 600
        $null = Shot "$tag-6-ja"; $first = Size (Win)
        Keys PageDown; $null = Shot "$tag-7-ja-page2"; $second = Size (Win); Keys Escape Escape Escape
        "page 1 $first, page 2 $second"
      }
      Keys Escape Escape
    }
  }
} finally {
  $tsf::Stop()
  if ($null -ne $confBefore) { Set-Content -NoNewline -Encoding utf8 $conf $confBefore } else { Remove-Item -ErrorAction SilentlyContinue $conf }
}
$failed = @(Get-Content $results | Where-Object { $_ -like 'FAIL *' }).Count
exit [int]($failed -gt 0)
