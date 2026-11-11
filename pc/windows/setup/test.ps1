<#
Tests SebType's installer (#73) in the background on a Windows Server: install, typing, upgrade and
uninstall, twice, and a picture of every installer page. One command, run elevated in a logged-on
session (test-tcsbackend.sh does that on TCSBackEnd and opens the Remote Desktop session it needs):

    powershell -File C:\sebtype-setup-test\test.ps1

The folder holds this script, TsfHost.cs (../mozc) and SebType-setup-*.exe. The test creates a local
admin user, sebtype-test, and runs everything as that user in a Remote Desktop session of its own, so
nobody's own input settings change, then removes the user and its profile:

1. The installer's pictures: the language dialog (which must preselect Windows' own display language),
   the welcome page in English, 中文 and 日本語, then a whole install in English with the uninstaller.
2. Round 1 (that install, all languages): what it installed and set, typing in Notepad with real keys
   (rdp-keys.py: Win+Space EN → 中 → 日, pinyin, the Shift tap, Ctrl+Shift+F, Japanese), a silent
   upgrade that keeps learned words, Japanese still working after the language list changes, then the
   uninstall: everything back as before, learned words gone.
3. Round 2, all silent: install with Chinese and Japanese only (no English), upgrade to English and
   Chinese (Japanese and its learned words go), uninstall.

Results: one line per check in out\setup-results.txt, pictures in out\*.png; exit 0 only if all pass.
-Driver and -Typing are the test user's own parts (elevated, and not elevated as apps run).
#>
param([string]$Driver, [string]$Typing)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSCommandPath
$out = "$root\out"
New-Item -ItemType Directory -Force $out | Out-Null
$results = "$out\$(if ($Driver) { 'driver' } elseif ($Typing) { "typing-$Typing" } else { 'setup' })-results.txt"
Set-Content -Encoding utf8 $results ''
function Result($name, $status, $why = '') {
  $line = "$status $name$(if ($why) { ": $why" })"
  Add-Content -Encoding utf8 $results $line; Write-Host $line
}
function Check($name, [scriptblock]$body) {
  try { $why = & $body; Result $name PASS $why } catch { Result $name FAIL $_.Exception.Message }
}
function Wait-Until([int]$seconds, [scriptblock]$cond) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while (-not ($r = & $cond)) { if ((Get-Date) -gt $deadline) { return $null }; Start-Sleep -Milliseconds 300 }
  $r
}
$user = 'sebtype-test'
$AppKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{5C1E7A52-3D8B-4F7E-9E0B-7B3B5A1C7354}_is1'
$App = "$env:ProgramFiles\SebType"
$WeaselClsid = '{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}'
$WeaselTip = "0804:${WeaselClsid}{3D02CAB6-2B8E-4781-BA20-1C9267529467}"
$MozcClsid = '{10A67BC8-22FA-4A59-90DC-2546652C56BF}'
$MozcTip = "0411:$MozcClsid{186F700C-71CF-43FE-A00E-AACB1D9E6D3D}"
$WeaselKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Weasel'
function Mozc-Installed { [bool](Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall | Where-Object { $_.GetValue('DisplayName') -eq 'Mozc' }) }
function Languages { ((Get-WinUserLanguageList) | ForEach-Object { "$($_.LanguageTag)[$($_.InputMethodTips -join ',')]" }) -join ' ' }


# ============================================================ typing, as the test user, not elevated
if ($Typing) {
  try {
    Add-Type -Path "$root\TsfHost.cs"
    $tsf = [SebType.TsfHost]
    # Keys come from the Remote Desktop client (rdp-keys.py through test-tcsbackend.sh's tunnel), as a person's.
    $keys = Wait-Until 30 { try { New-Object Net.Sockets.TcpClient '127.0.0.1', 47812 } catch { $null } }
    if (-not $keys) { throw 'no key server at 127.0.0.1:47812 (rdp-keys.py, through the SSH tunnel)' }
    $kw = New-Object IO.StreamWriter $keys.GetStream(); $kw.AutoFlush = $true
    $kr = New-Object IO.StreamReader $keys.GetStream()
    function Keys {  # X keysym names or chords (Alt_L+grave), pressed in order
      $line = ($args | ForEach-Object { $_ }) -join ' '
      $kw.WriteLine($line); $r = $kr.ReadLine()
      if ($r -ne 'ok') { throw "keys $line`: $r" }
      Start-Sleep -Milliseconds 500
    }
    function TypeText($s) { Keys ($s.ToCharArray() | ForEach-Object { if ($_ -eq ' ') { 'space' } else { "$_" } }) }
    $np = Start-Process notepad -PassThru
    try {
      $null = $np.WaitForInputIdle(10000)
      $h = $np.MainWindowHandle
      if (-not $tsf::Foreground($h)) { throw 'Notepad did not come to the front' }
      function Typed($s) { Keys 'Control_L+a' BackSpace; TypeText $s; Start-Sleep 1; $tsf::EditText($h).Trim() }
      function Lang { '{0:x4}' -f $tsf::Language($h) }
      function To-Language($id) {
        for ($i = 0; $i -lt 4 -and (Lang) -ne $id; $i++) { Keys 'Super_L+space'; Start-Sleep 1 }
        if ((Lang) -ne $id) { throw "Win+Space didn't reach $id (at $(Lang))" }
      }
      if ($Typing -eq 'all') {
        Check 'win-space-cycle' {
          To-Language '0409'
          $seen = foreach ($i in 1..3) { Keys 'Super_L+space'; Start-Sleep 1; Lang }
          if (($seen -join ' ') -ne '0804 0411 0409') { throw "from EN, Win+Space gave $($seen -join ' → ') (0804 中, 0411 日, 0409 EN)" }
          'EN → 中 → 日 → EN'
        }
        Check 'chinese-pinyin' {
          To-Language '0804'
          Keys n i; Start-Sleep 3; Keys Escape  # the first key starts WeaselServer
          $t = Typed 'ranhou '
          if ($t -ne '然后') { throw "ranhou + Space gave '$t'" }
          $t
        }
        Check 'chinese-shift-tap' {
          Keys 'Control_L+a' BackSpace; TypeText 'ni'; Keys Shift_L; TypeText 'ok'; Keys Shift_L; TypeText 'ranhou '
          Start-Sleep 1; $t = $tsf::EditText($h).Trim()
          if ($t -ne 'niok然后') { throw "ni Shift ok Shift ranhou gave '$t'" }
          $t
        }
        Check 'chinese-ctrl-shift-f' {
          Keys 'Control_L+a' BackSpace 'Control_L+Shift_L+f'; TypeText 'houlai '; Keys 'Control_L+Shift_L+f'; TypeText 'houlai '
          Start-Sleep 1; $t = $tsf::EditText($h).Trim()
          if ($t -ne '後來后来') { throw "houlai with 繁 then 简 gave '$t'" }
          $t
        }
      }
      Check "japanese-$Typing" {
        To-Language '0411'
        # Notepad gets Japanese only once it is committed (Enter). Japanese starts in English or あ.
        function Committed($s) { Keys 'Control_L+a' BackSpace; TypeText $s; Keys Return; Start-Sleep 1; $tsf::EditText($h).Trim() }
        if ((Committed 'a') -eq 'a') { Keys 'Alt_L+grave' }
        $t = Committed 'nihongo '
        if ($t -ne '日本語') { throw "nihongo + Space + Enter gave '$t'" }
        $t
      }
    } finally { $np | Stop-Process -Force -ErrorAction SilentlyContinue }
  } catch { Result "typing-$Typing" FAIL $_.Exception.Message } finally {
    New-Item -ItemType File -Force "$out\typing-$Typing-done" | Out-Null
  }
  exit
}


# ==================================================== the driver, as the test user, elevated as Setup
if ($Driver) {
  Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Text; using System.Collections.Generic; using System.Drawing; using System.Drawing.Imaging;
using System.Runtime.InteropServices;
namespace SebTypeSetupTest {
  public static class Win {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, StringBuilder l, uint f, uint ms, out IntPtr r);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    struct RECT { public int L, T, R, B; }
    static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
    // WM_GETTEXT, not GetWindowText, which doesn't ask another process's controls (a combo box's choice).
    public static string Text(IntPtr h) { var s = new StringBuilder(1024); IntPtr r; SendMessageTimeout(h, 0x000D, (IntPtr)1024, s, 2, 2000, out r); return s.ToString(); }
    // The first visible top-level window of a class: TSelectLanguageForm, TWizardForm, TUninstallProgressForm.
    public static IntPtr Find(string cls) {
      IntPtr found = IntPtr.Zero;
      EnumWindows((h, l) => { if (IsWindowVisible(h) && Cls(h) == cls) { found = h; return false; } return true; }, IntPtr.Zero);
      return found;
    }
    // A message box: a visible top-level window of these processes that isn't one of their forms. Inno 6.7's
    // message boxes aren't all Windows' own #32770 dialog.
    public static IntPtr Owned(int[] pids, string[] forms) {
      IntPtr found = IntPtr.Zero;
      EnumWindows((h, l) => {
        uint pid; GetWindowThreadProcessId(h, out pid);
        RECT r; GetWindowRect(h, out r);
        if (IsWindowVisible(h) && r.R - r.L >= 80 && r.B - r.T >= 60 && Array.IndexOf(pids, (int)pid) >= 0 && Array.IndexOf(forms, Cls(h)) < 0) { found = h; return false; }
        return true;
      }, IntPtr.Zero);
      return found;
    }
    // Every visible top-level window, for a failure's message.
    public static string Visible() {
      var t = new List<string>();
      EnumWindows((h, l) => { if (IsWindowVisible(h)) { uint pid; GetWindowThreadProcessId(h, out pid); t.Add(Cls(h) + " '" + Text(h) + "' pid " + pid); } return true; }, IntPtr.Zero);
      return string.Join("; ", t);
    }
    static List<IntPtr> Children(IntPtr p) {
      var list = new List<IntPtr>();
      EnumChildWindows(p, (h, l) => { if (IsWindowVisible(h)) list.Add(h); return true; }, IntPtr.Zero);
      return list;
    }
    public static string Texts(IntPtr p) {
      var t = new List<string>();
      foreach (var h in Children(p)) { var s = Text(h); if (s.Length > 0) t.Add(Cls(h) + ":" + s); }
      return string.Join(" | ", t);
    }
    // Clicks the visible button whose caption, without its & accelerator, starts with the text.
    public static bool Click(IntPtr p, string caption) {
      foreach (var h in Children(p)) {
        if (Cls(h).IndexOf("Button", StringComparison.OrdinalIgnoreCase) >= 0 && Text(h).Replace("&", "").StartsWith(caption)) {
          // The click a button tells its parent (WM_COMMAND, BN_CLICKED): Inno's VCL and message boxes take it
          // in the background, where BM_CLICK's mouse messages need the window in front.
          PostMessage(GetParent(h), 0x0111, (IntPtr)(GetDlgCtrlID(h) & 0xFFFF), h);
          return true;
        }
      }
      // Buttons that aren't windows: a task dialog's take TDM_CLICK_BUTTON with the id (IDOK 1, IDYES 6);
      // any other message box takes Enter, for its default button (Yes in the confirm, OK in the last one).
      int id = caption == "OK" ? 1 : caption == "Yes" ? 6 : 0;
      if (id == 0) return false;
      if (Cls(p) == "#32770") PostMessage(p, 0x0466, (IntPtr)id, IntPtr.Zero);
      else { Front(p); keybd_event(0x0D, 0, 0, UIntPtr.Zero); keybd_event(0x0D, 0, 2, UIntPtr.Zero); }
      return true;
    }
    // Windows lets a process take the foreground right after it sent input: an Alt tap first.
    static void Front(IntPtr h) {
      for (int i = 0; i < 5 && GetForegroundWindow() != h; i++) {
        keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero);
        SetForegroundWindow(h);
        System.Threading.Thread.Sleep(300);
      }
    }
    public static void Shot(IntPtr h, string path) {
      Front(h);
      System.Threading.Thread.Sleep(700);
      RECT r; GetWindowRect(h, out r);
      if (r.R - r.L < 1 || r.B - r.T < 1) throw new ArgumentException(Cls(h) + " '" + Text(h) + "' has no size to picture");
      using (var bmp = new Bitmap(r.R - r.L, r.B - r.T)) {
        using (var g = Graphics.FromImage(bmp)) { var dc = g.GetHdc(); PrintWindow(h, dc, 2); g.ReleaseHdc(dc); }  // PW_RENDERFULLCONTENT
        bmp.Save(path, ImageFormat.Png);
      }
    }
  }
}
'@
  $win = [SebTypeSetupTest.Win]
  $setup = (Get-ChildItem "$root\SebType-setup-*.exe" | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
  function Window($cls, $seconds = 60) {
    $h = Wait-Until $seconds { $x = $win::Find($cls); if ($x -ne [IntPtr]::Zero) { $x } }
    if (-not $h) { throw "no $cls window in $seconds s; windows: $($win::Visible())" }
    $h
  }
  # Setup's processes (the stub, its .tmp copy in %TEMP%) and the uninstaller's (unins000, its .tmp copy),
  # not the Weasel installer Setup runs from its folder there.
  $forms = [string[]]('TWizardForm', 'TSelectLanguageForm', 'TUninstallProgressForm', 'TApplication')
  function Find-Message {
    $pids = @(Get-Process | Where-Object { $_.Path -like "$env:TEMP\*.tmp" -or $_.Name -like 'SebType-setup*' -or $_.Name -like 'unins*' } | ForEach-Object Id)
    if ($pids) { $m = $win::Owned([int[]]$pids, $forms); if ($m -ne [IntPtr]::Zero) { $m } }
  }
  function Message($seconds = 60) {
    $h = Wait-Until $seconds { Find-Message }
    if (-not $h) { throw "no message box from Setup or its uninstaller in $seconds s; windows: $($win::Visible())" }
    $h
  }
  function Shot($cls, $name, $seconds = 60) { $h = Window $cls $seconds; $win::Shot($h, "$out\73-$name.png"); $h }
  function Click($h, $caption) { if (-not $win::Click($h, $caption)) { throw "no '$caption' button in: $($win::Texts($h))" } }
  # Waits for a page by a text on it (Inno's labels are windows of their own); a message box Setup shows
  # instead (a failed step) ends the wait.
  function Page($h, $text, $seconds = 60) {
    $r = Wait-Until $seconds { if ($win::Texts($h) -like "*$text*") { 'page' } else { Find-Message } }
    if ($r -is [IntPtr]) { $win::Shot($r, "$out\failed-$(Get-Date -Format HHmmss).png"); throw "Setup says: $($win::Texts($r))" }
    if (-not $r) { throw "no '$text' in $seconds s; window shows: $($win::Texts($h))" }
  }
  function Save-MachineLog($what) { Copy-Item "$App\setup.log" "$out\machine-$what.log" -ErrorAction SilentlyContinue }
  # A Setup or uninstaller started here and left showing is stopped, with the temporary copy it runs.
  function Stop-Setup { Get-Process | Where-Object { $_.Path -like "$env:TEMP\is-*" -or $_.Path -like "$env:TEMP\_iu*" -or $_.Name -like 'SebType-setup*' -or $_.Name -like 'unins000' } | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep 1 }
  function Silent($what, [string[]]$arguments) {
    $p = Start-Process $setup -PassThru -ArgumentList (@('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$out\setup-$what.log`"") + $arguments)
    if (-not $p.WaitForExit(900000)) { throw "Setup ($what) ran over 15 minutes" }
    Save-MachineLog $what
    if ($p.ExitCode) { throw "Setup ($what) exited with $($p.ExitCode) (logs: out\setup-$what.log, out\machine-$what.log, out\user-setup.log)" }
  }
  function Uninstalled { -not (Test-Path $AppKey) -and -not (Get-Process | Where-Object { $_.Path -like "$env:TEMP\_iu*" }) }
  function Typing($phase) {
    Set-Content "$out\typing-phase.txt" $phase
    Start-ScheduledTask SebType-setup-typing
    if (-not (Wait-Until 300 { Test-Path "$out\typing-$phase-done" })) { Result "typing-$phase" FAIL 'the typing checks took over 5 minutes' }
    Get-Content -Encoding utf8 "$out\typing-$phase-results.txt" | Where-Object { $_ } | ForEach-Object { Add-Content -Encoding utf8 $results $_; Write-Host $_ }
  }

  # Windows Server opens Server Manager at an admin's logon, in front of whatever the test shows.
  if (Wait-Until 45 { Get-Process ServerManager -ErrorAction SilentlyContinue }) { Start-Sleep 5; Get-Process ServerManager | Stop-Process -Force }

  # How this account is before SebType: English and Chinese (Microsoft Pinyin), as on a Chinese PC.
  $ll = New-WinUserLanguageList en-US
  $ll.Add((New-Object Microsoft.InternationalSettings.Commands.WinUserLanguage zh-Hans-CN))
  Set-WinUserLanguageList $ll -Force
  function Snapshot {
    $toggle = Get-Item 'HKCU:\Keyboard Layout\Toggle' -ErrorAction SilentlyContinue
    [ordered]@{
      languages = Languages
      default = "$(Get-WinDefaultInputMethodOverride | ForEach-Object InputMethodTip)"
      toggle = ('Hotkey', 'Language Hotkey', 'Layout Hotkey' | ForEach-Object { "$_=$(if ($toggle) { $toggle.GetValue($_) })" }) -join ' '
      perWindow = (Get-WinLanguageBarOption).IsLegacySwitchingMode
      hotkeys = (reg.exe query 'HKCU\Control Panel\Input Method\Hot Keys' /s 2>$null) -join "`n"
      tipKeys = (Get-ChildItem HKCU:\Software\Microsoft\CTF\TIP -ErrorAction SilentlyContinue).PSChildName -join ','
      rime = Test-Path "$env:APPDATA\Rime"
      mozc = Test-Path "$env:USERPROFILE\AppData\LocalLow\Mozc"
      rimeSettings = Test-Path HKCU:\Software\Rime
      sebtypeFolder = Test-Path "$env:LOCALAPPDATA\SebType"
      app = Test-Path $App
      appEntry = Test-Path $AppKey
      weasel = Test-Path $WeaselKey
      mozcInstalled = Mozc-Installed
      machineKey = Test-Path HKLM:\SOFTWARE\SebType
      startMenu = [bool](Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Filter 'SebType*' -ErrorAction SilentlyContinue)
    }
  }
  $before = Snapshot
  $before | ConvertTo-Json | Set-Content "$out\account-before.json"
  function Check-AsBefore($round) {
    Check "$round-everything-as-before" {
      $now = Snapshot
      $now | ConvertTo-Json | Set-Content "$out\account-after-$round.json"
      $diff = @($before.Keys | Where-Object { "$($before[$_])" -ne "$($now[$_])" } | ForEach-Object { "$_ now '$($now[$_])', was '$($before[$_])'" })
      if ($diff) { throw ($diff -join '; ') }
      'input methods, switch keys, per-window setting, hotkeys; SebType, Weasel, Mozc, learned words and the Start menu entry gone'
    }
  }
  function Check-Installed($round, [string[]]$langs, [string]$order) {
    Check "$round-installed" {
      $missing = @("$App\sebtype-configurator.exe", "$App\setup.ps1", "$App\unins000.exe", "$App\sebtype.ico" | Where-Object { -not (Test-Path $_) })
      $entry = Get-ItemProperty $AppKey
      if ($missing) { throw "missing: $($missing -join ', ')" }
      if ($entry.DisplayName -ne 'SebType' -or $entry.DisplayIcon -notlike '*sebtype.ico') { throw "Apps lists '$($entry.DisplayName)' with icon $($entry.DisplayIcon)" }
      $w = Get-ItemProperty $WeaselKey -ErrorAction SilentlyContinue
      if (('zh' -in $langs) -ne [bool]($w -and $w.PSObject.Properties['SebType'])) { throw "SebType's Weasel installed: $([bool]$w), wanted: $('zh' -in $langs)" }
      if (('ja' -in $langs) -ne (Mozc-Installed)) { throw "Mozc installed: $(Mozc-Installed), wanted: $('ja' -in $langs)" }
      "$(Split-Path -Leaf $setup) in $App; Weasel $('zh' -in $langs), Mozc $('ja' -in $langs)"
    }
    Check "$round-input-methods" {
      $l = Languages
      if ($l -ne $order) { throw "input methods $l, want $order" }
      'Win+Space order ' + (($l -split ' ' | ForEach-Object { ($_ -split '\[')[0] }) -join ' → ')
    }
    Check "$round-only-win-space" {
      $t = (Snapshot).toggle
      if ($t -ne 'Hotkey=3 Language Hotkey=3 Layout Hotkey=3' -or (Get-WinLanguageBarOption).IsLegacySwitchingMode) { throw "switch keys $t, per-window $((Get-WinLanguageBarOption).IsLegacySwitchingMode)" }
      'Alt+Shift and Ctrl+Shift off, one input method for every window'
    }
    if ('zh' -in $langs) {
      Check "$round-chinese" {
        $name = (Get-Item "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$WeaselClsid\LanguageProfile\0x00000804\{3D02CAB6-2B8E-4781-BA20-1C9267529467}").GetValue('Description')
        $patch = Get-Content "$env:APPDATA\Rime\rime_ice.custom.yaml" -Encoding utf8 -ErrorAction SilentlyContinue
        if ($name -ne '中文') { throw "Weasel's input method reads '$name'" }
        if (-not (Test-Path "$env:APPDATA\Rime\build\rime_ice.schema.yaml") -or -not ($patch -match 'schema/name: 中文') -or -not ($patch -match 'sebtype_typo/keyboard: pc')) { throw 'the Chinese data is not deployed with SebType''s patches' }
        'named 中文; rime-ice and 白霜 deployed with the 中文 name and PC typo correction'
      }
    }
    if ('ja' -in $langs) {
      Check "$round-japanese" {
        $name = (Get-Item "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$MozcClsid\LanguageProfile\0x00000411\{186F700C-71CF-43FE-A00E-AACB1D9E6D3D}").GetValue('Description')
        $db = "$env:USERPROFILE\AppData\LocalLow\Mozc\config1.db"
        if ($name -ne '日本語') { throw "Mozc's input method reads '$name'" }
        if (-not (Test-Path $db) -or -not ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($db)) -match 'IMEOn')) { throw 'no SebType keymap in config1.db' }
        'named 日本語, with SebType''s keymap (Shift tap, Alt+`)'
      }
    }
  }
  $learned = "$env:APPDATA\Rime\rime_ice.userdb\SEBTYPE-TEST", "$env:USERPROFILE\AppData\LocalLow\Mozc\SEBTYPE-TEST"

  try {
    # ---------------------------------------------------------------------------------- pictures
    Check 'language-follows-windows' {
      Start-Process $setup
      $h = Shot TSelectLanguageForm '0-language'
      $chosen = ($win::Texts($h) -split ' \| ' | Where-Object { $_ -like '*ComboBox:*' }) -replace '^[^:]*:'
      $ui = [Globalization.CultureInfo]::InstalledUICulture.Name
      $want = @{ 'zh-CN' = '简体中文'; 'ja-JP' = '日本語' }[$ui]; if (-not $want) { $want = 'English' }
      Stop-Setup
      if ($chosen -ne $want) { throw "Windows shows $ui; the dialog offers '$chosen', not '$want'" }
      "Windows shows $ui; the dialog offers $chosen"
    }
    foreach ($lang in 'zh', 'ja') {
      Check "welcome-$lang" { Start-Process $setup "/LANG=$lang"; $null = Shot TWizardForm "1-welcome-$lang"; Stop-Setup; "73-1-welcome-$lang.png" }
    }

    # ------------------------------------------------- round 1: install in English, as a person does
    Check 'round1-install-pages' {
      Start-Process $setup '/LANG=en', "/LOG=`"$out\setup-round1-install.log`""
      $h = Shot TWizardForm '1-welcome-en'
      Click $h 'Next'; Page $h 'Your languages'; $null = Shot TWizardForm '2-languages'
      Click $h 'Install'; Page $h 'Installing the input methods' 120; $null = Shot TWizardForm '3-installing'
      Page $h 'SebType is ready' 900; $null = Shot TWizardForm '4-finish'
      Click $h 'Finish'
      if (-not (Wait-Until 60 { -not (Get-Process | Where-Object { $_.Path -like "$env:TEMP\is-*" }) })) { throw 'Setup did not close' }
      Start-Sleep 3; Get-Process sebtype-configurator -ErrorAction SilentlyContinue | Stop-Process -Force
      'welcome, languages, installing, finish'
    }
    Save-MachineLog round1-install; Stop-Setup
    Check-Installed round1 en, zh, ja "en-US[0409:00000409] zh-Hans-CN[$WeaselTip] ja[$MozcTip]"
    Typing all
    # What it learned stays through an upgrade: a mark in each learned-words folder.
    $learned | ForEach-Object { New-Item -Force $_ | Out-Null }
    Check 'round1-upgrade' { Silent round1-upgrade @(); 'silent, same languages' }
    Check-Installed round1-upgraded en, zh, ja "en-US[0409:00000409] zh-Hans-CN[$WeaselTip] ja[$MozcTip]"
    Check 'round1-upgrade-keeps-learned-words' {
      $gone = @($learned | Where-Object { -not (Test-Path $_) })
      if ($gone) { throw "gone: $($gone -join ', ')" }
      'the Rime and Mozc learned-word folders stay'
    }
    # Windows turns a text service's profile off for the user when the language list changes, unless
    # it is enabled by default (#65; setup.ps1 -Machine). Then Japanese must still type.
    $ll = Get-WinUserLanguageList; $ll.Add('fr-FR'); Set-WinUserLanguageList $ll -Force
    $ll = Get-WinUserLanguageList; $ll.RemoveAll({ param($l) $l.LanguageTag -eq 'fr-FR' }) | Out-Null; Set-WinUserLanguageList $ll -Force
    Typing after-language-change

    Check 'round1-uninstall-pages' {
      Start-Process "$App\unins000.exe" "/LOG=`"$out\uninstall-round1.log`""
      $h = Message; $win::Shot($h, "$out\73-5-uninstall-confirm.png")
      Click $h 'Yes'
      $h = Window TUninstallProgressForm
      Page $h 'Putting your old keyboards back'; $null = Shot TUninstallProgressForm '6-uninstalling'
      $h = Message 600
      $win::Shot($h, "$out\73-7-uninstalled.png")
      $said = $win::Texts($h)  # empty where the box draws its text itself: the picture shows it
      if ($said -and $said -notlike '*was removed*') { throw "the uninstaller says: $said" }
      Click $h 'OK'
      if (-not (Wait-Until 120 { Uninstalled })) { throw 'the uninstaller did not finish' }
      'confirm, removing, removed'
    }
    Stop-Setup
    Check 'round1-uninstall-deletes-learned-words' {
      $kept = @($learned | Where-Object { Test-Path $_ })
      if ($kept) { throw "kept: $($kept -join ', ')" }
      'the Rime and Mozc folders are gone'
    }
    Check-AsBefore round1

    # ------------------------------------------------------- round 2: silent, languages optional
    Check 'round2-install-without-english' { Silent round2-install @('/TASKS="zh,ja"'); 'silent, 中文 and 日本語' }
    Check-Installed round2 zh, ja "zh-Hans-CN[$WeaselTip] ja[$MozcTip] en-US[0409:00000409]"
    New-Item -Force $learned[1] | Out-Null
    Check 'round2-upgrade-drops-japanese' { Silent round2-upgrade @('/TASKS="en,zh"'); 'silent, English and 中文' }
    Check-Installed round2-upgraded en, zh "en-US[0409:00000409] zh-Hans-CN[$WeaselTip]"
    Check 'round2-japanese-words-deleted' { if (Test-Path $learned[1]) { throw "kept: $($learned[1])" }; 'Japanese left out: Mozc and its learned words gone' }
    Check 'round2-uninstall' {
      Start-Process "$App\unins000.exe" '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$out\uninstall-round2.log`""
      if (-not (Wait-Until 600 { Uninstalled })) { throw 'the silent uninstall did not finish in 10 minutes' }
      'silent'
    }
    Check-AsBefore round2
  } catch { Result driver FAIL $_.Exception.Message } finally {
    Stop-Setup
    Copy-Item "$env:LOCALAPPDATA\SebType\setup.log" "$out\user-setup.log" -ErrorAction SilentlyContinue
    New-Item -ItemType File -Force "$out\driver-done" | Out-Null
  }
  exit
}


# ========================================================================= the admin part
$preflight = if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'not elevated (admin)' }
elseif (-not (Get-ChildItem "$root\SebType-setup-*.exe" -ErrorAction SilentlyContinue)) { "no SebType-setup-*.exe in $root" }
elseif (-not (Test-Path "$root\TsfHost.cs")) { "no TsfHost.cs in $root (pc/windows/mozc)" }
elseif ((Get-Process -Id $PID).SessionId -eq 0) { 'in session 0 (services): start it from a logged-on session' }
elseif ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) { 'not Windows Server: the test needs a second Remote Desktop session' }
elseif (Get-LocalUser $user -ErrorAction SilentlyContinue) { "a local user $user exists already" }
elseif ((Test-Path $AppKey) -or (Test-Path $WeaselKey) -or (Mozc-Installed)) { 'SebType, Weasel or Mozc is installed already: the test starts without them' }
if ($preflight) { Result preflight BLOCKED $preflight; exit 1 }

# The admin's own input settings, which must end as they began (Windows gives every logged-on user an
# entry for a newly registered text service).
$adminBefore = [ordered]@{ languages = Languages; tipKeys = (Get-ChildItem HKCU:\Software\Microsoft\CTF\TIP -ErrorAction SilentlyContinue).PSChildName -join ',' }
$password = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ }) + '-a1A'
$rdp = "$env:LOCALAPPDATA\SebType-setup-test\rdp-logon.txt"  # in this admin's profile, which the test user can't read
$account = $null
try {
  $account = New-LocalUser $user -Password (ConvertTo-SecureString $password -AsPlainText -Force) -AccountNeverExpires -PasswordNeverExpires `
    -Description 'SebType installer test (#73); deleted on exit'
  # An administrator, as the person installing SebType is; Setup runs elevated as they would after UAC.
  Add-LocalGroupMember -SID S-1-5-32-544 -Member $user
  Add-LocalGroupMember -SID S-1-5-32-555 -Member $user  # Remote Desktop Users
  & icacls.exe $root /grant "${user}:(OI)(CI)M" | Out-Null
  $run = { param($mode, $level) New-ScheduledTaskAction -Execute powershell.exe -WorkingDirectory $root `
      -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\test.ps1`" -$mode $mode" }
  Register-ScheduledTask SebType-setup-driver -Action (& $run Driver) -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) `
    -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest) -Force | Out-Null
  # The typing runs as apps do, not elevated; the driver starts it, its phase in out\typing-phase.txt.
  $typingAction = New-ScheduledTaskAction -Execute powershell.exe -WorkingDirectory $root `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"& '$root\test.ps1' -Typing (Get-Content '$out\typing-phase.txt')`""
  Register-ScheduledTask SebType-setup-typing -Action $typingAction `
    -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
  New-Item -ItemType Directory -Force (Split-Path $rdp) | Out-Null
  Set-Content $rdp $user, $password
  if (-not (Wait-Until 3000 { Test-Path "$out\driver-done" })) {
    Result driver FAIL $(if (Test-Path "$out\driver-results.txt") { 'the run took over 50 minutes' } else { "no Remote Desktop logon of $user in 50 minutes" })
  }
} catch { Result admin FAIL $_.Exception.Message } finally {
  Remove-Item -Recurse (Split-Path $rdp) -ErrorAction SilentlyContinue
  'SebType-setup-driver', 'SebType-setup-typing' | ForEach-Object { Unregister-ScheduledTask $_ -Confirm:$false -ErrorAction SilentlyContinue }
  # A run that died may leave SebType installed: its own uninstaller, then the session, profile and user.
  if (Test-Path $AppKey) { Start-Process -Wait "$App\unins000.exe" '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'; Start-Sleep 20 }
  query.exe session 2>$null | ForEach-Object { if ("$_" -match "\s$user\s+(\d+)\s") { logoff.exe $Matches[1] } }
  if ($account) {
    $prof = $null
    for ($i = 0; $i -lt 60; $i++) {
      $prof = Get-CimInstance Win32_UserProfile | Where-Object SID -EQ $account.SID.Value
      if (-not $prof -or -not $prof.Loaded) { break }
      Start-Sleep 2
    }
    if ($prof -and $prof.Loaded) { Result test-user-removed FAIL "its profile stayed loaded after logoff: $user and $($prof.LocalPath) kept" }
    else { if ($prof) { $prof | Remove-CimInstance }; Remove-LocalUser $user }
  }
}
Get-Content -Encoding utf8 "$out\driver-results.txt" -ErrorAction SilentlyContinue | Where-Object { $_ } | ForEach-Object { Add-Content -Encoding utf8 $results $_; Write-Host $_ }

Check 'machine-as-before' {
  $left = @($App, $AppKey, $WeaselKey, 'HKLM:\SOFTWARE\SebType', "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$WeaselClsid", "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$MozcClsid", 'HKLM:\SOFTWARE\WOW6432Node\Rime' | Where-Object { Test-Path $_ })
  if (Mozc-Installed) { $left += 'Mozc' }
  if ($left) { throw "left: $($left -join ', ')" }
  'SebType, Weasel, Mozc and their registrations gone'
}
# Windows' entries for this admin of the text services the run registered: not SebType's own, removed.
$extra = @((Get-ChildItem HKCU:\Software\Microsoft\CTF\TIP -ErrorAction SilentlyContinue).PSChildName | Where-Object { $_ -notin ($adminBefore.tipKeys -split ',') })
$extra | ForEach-Object { Remove-Item -Recurse -Force "HKCU:\Software\Microsoft\CTF\TIP\$_" }
if ($extra) { Result admin-text-service-entries INFO "Windows had added $($extra -join ', ') for this admin; removed" }
Check 'admin-input-as-before' {
  if ((Languages) -ne $adminBefore.languages) { throw "this admin's input methods are $(Languages), were $($adminBefore.languages)" }
  'this admin''s input methods untouched'
}
foreach ($c in 'language-follows-windows', 'welcome-zh', 'welcome-ja', 'round1-install-pages', 'win-space-cycle', 'chinese-pinyin', 'japanese-all',
  'round1-upgrade', 'japanese-after-language-change', 'round1-uninstall-pages', 'round1-everything-as-before', 'round2-upgrade-drops-japanese', 'round2-everything-as-before') {
  if (-not (Select-String -Quiet -SimpleMatch " $c" $results)) { Result $c SKIP 'did not run' }
}
exit [int][bool](Select-String -Quiet '^(FAIL|SKIP) ' $results)
