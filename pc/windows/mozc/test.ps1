<#
Tests SebType's Mozc for Windows (#65) on a real desktop: speed, dictionary, install, typing in a test
window of its own, tray icons, and undo. One command, no arguments, run elevated (install.ps1 needs admin):

    powershell -File pc/windows/mozc/test.ps1

Needs build.ps1's MSI (newest SebType-Mozc-*.msi in C:\ or D:\sebtype-mozc\out) and Python. It sends
keys only while its own test window is in front (the typing runs in a copy of the script that isn't
elevated, as apps run), and puts back what it found: the language list,
default input method, hotkeys, this user's text service settings, Caps Lock, the input language in
use, Mozc's profile, and whether Mozc is installed. On a shared
PC the caller holds the device lock (on YukaROG: devices/yukarog-power.lock, taken from nobara-pc).
One line per check in %LOCALAPPDATA%\SebType\test\mozc-results.txt, logs next to it; exit 0 only if
every check passes.
#>
param([switch]$Typing)  # internal: the typing checks only, started by the elevated run
$ErrorActionPreference = 'Stop'
$out = "$env:LOCALAPPDATA\SebType\test"
New-Item -ItemType Directory -Force $out | Out-Null
$results = "$out\mozc-results.txt"
if (-not $Typing) { Set-Content -Encoding utf8 $results '' }
$failed = 0
function Result($name, $status, $why = '') {
    $line = "$status $name$(if ($why) { ": $why" })"
    Add-Content -Encoding utf8 $results $line; Write-Host $line
    if ($status -eq 'FAIL') { $script:failed++ }
}
function Check($name, [scriptblock]$body) {
    try { $why = & $body; Result $name PASS $why } catch { Result $name FAIL $_.Exception.Message }
}

# Preflight: one line saying what is missing.
$msi = Get-ChildItem 'C:\sebtype-mozc\out\SebType-Mozc-*.msi', 'D:\sebtype-mozc\out\SebType-Mozc-*.msi' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
$python = Get-Command python -ErrorAction SilentlyContinue | Where-Object Source -NotLike '*WindowsApps*'
$preflight = if ($Typing) { $null } elseif ($env:OS -ne 'Windows_NT') { 'not Windows' }
elseif (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'not elevated (admin)' }
elseif (-not $msi) { 'no SebType-Mozc-*.msi: run build.ps1 first' } elseif (-not $python) { 'no Python on PATH' }
elseif (Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -NE (Get-Process -Id $PID).SessionId) { 'not in the desktop session' }
if ($preflight) { Write-Host "preflight: $preflight"; Add-Content -Encoding utf8 $results "BLOCKED preflight: $preflight"; exit 1 }
$install = "$PSScriptRoot\install.ps1"
if (-not $Typing -and (Test-Path "$env:LOCALAPPDATA\SebType\mozc-install.json")) { & $install -Undo | Out-Null }  # a run that died midway

Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

[ComImport, Guid("BA468C55-9956-4FB1-A59D-52A7DD7F3E6E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITfLangBarItemMgr {
    void EnumItems(out IntPtr e);
    [PreserveSig] int GetItem(ref Guid guid, [MarshalAs(UnmanagedType.IUnknown)] out object item);
}
[ComImport, Guid("28C7F1D0-DE25-11D2-AFDD-00105A2799B5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITfLangBarItemButton {  // ITfLangBarItem's four methods, then the button's
    void GetInfo(IntPtr info); void GetStatus(out uint status); void Show(int show); void GetTooltipString(IntPtr s);
    void OnClick(int click, long pt, IntPtr area); void InitMenu(IntPtr menu); void OnMenuSelect(uint id);
    [PreserveSig] int GetIcon(out IntPtr icon);
}

// A plain Win32 edit window on its own thread, which loads the input method like any app.
public static class TestWindow {
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit, Size = 40)] struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct ICONINFO { public bool fIcon; public int x, y; public IntPtr mask, color; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern bool GetMessageW(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern bool PostThreadMessageW(uint thread, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool SetWindowTextW(IntPtr h, string s);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll")] static extern short GetKeyState(int vk);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern IntPtr LoadImageW(IntPtr inst, IntPtr name, uint type, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr icon, out ICONINFO info);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    [DllImport("gdi32.dll")] static extern int GetBitmapBits(IntPtr bmp, int n, byte[] bits);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string name);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("msctf.dll")] static extern int TF_CreateLangBarItemMgr(out ITfLangBarItemMgr mgr);
    const uint WM_APP = 0x8000, WM_CLOSE = 0x10;

    public static IntPtr Hwnd;
    static uint threadId;
    static readonly BlockingCollection<Action> queue = new BlockingCollection<Action>();

    public static void Start() {
        var ready = new ManualResetEvent(false);
        var t = new Thread(() => {
            threadId = GetCurrentThreadId();
            // EDIT as a top-level window: WS_OVERLAPPEDWINDOW | WS_VISIBLE, ES_MULTILINE | ES_AUTOVSCROLL
            Hwnd = CreateWindowExW(0x8 /* WS_EX_TOPMOST */, "EDIT", "", 0x10CF0000 | 0x44, 200, 200, 640, 200, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            SetWindowTextW(Hwnd, "");
            ready.Set();
            MSG m;
            while (GetMessageW(out m, IntPtr.Zero, 0, 0)) {
                if (m.hwnd == IntPtr.Zero && m.message == WM_APP) { Action a; while (queue.TryTake(out a)) a(); continue; }
                TranslateMessage(ref m); DispatchMessageW(ref m);
                if (m.hwnd == Hwnd && m.message == WM_CLOSE) break;
            }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.IsBackground = true;
        t.Start();
        ready.WaitOne(10000);
    }
    public static void Stop() { PostMessageW(Hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); }

    static T OnUi<T>(Func<T> f) {
        T r = default(T); Exception err = null; var done = new ManualResetEvent(false);
        queue.Add(() => { try { r = f(); } catch (Exception e) { err = e; } done.Set(); });
        PostThreadMessageW(threadId, WM_APP, IntPtr.Zero, IntPtr.Zero);
        if (!done.WaitOne(5000)) throw new TimeoutException("test window didn't answer");
        if (err != null) throw err;
        return r;
    }

    public static bool Focus() {
        if (GetForegroundWindow() != Hwnd) {
            uint fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero), me = GetCurrentThreadId();
            AttachThreadInput(me, fg, true);
            Key(0x12, false); Key(0x12, true);  // an Alt tap lets this process take the foreground
            SetForegroundWindow(Hwnd);
            AttachThreadInput(me, fg, false);
            Thread.Sleep(200);
        }
        OnUi(() => SetFocus(Hwnd));
        return GetForegroundWindow() == Hwnd;
    }
    public static string Text() { var s = new StringBuilder(4096); GetWindowTextW(Hwnd, s, s.Capacity); return s.ToString(); }
    public static void Clear() { SetWindowTextW(Hwnd, ""); }
    public static int Lang() { return (int)((long)GetKeyboardLayout(threadId) & 0xFFFF); }
    public static bool CapsLock() { return (GetKeyState(0x14) & 1) != 0; }

    static void Key(ushort vk, bool up) {
        var i = new INPUT { type = 1 };
        i.ki.vk = vk; i.ki.flags = up ? 2u : 0u;
        // Win and the arrow-type keys are extended keys
        if (vk == 0x5B) i.ki.flags |= 1;
        SendInput(1, new[] { i }, Marshal.SizeOf(typeof(INPUT)));
    }
    // Presses keys in order and releases them in reverse, e.g. Press(0x5B, 0x20) for Win+Space.
    public static void Press(params ushort[] vks) {
        if (GetForegroundWindow() != Hwnd) throw new InvalidOperationException("the test window lost the focus");
        foreach (var vk in vks) Key(vk, false);
        for (int i = vks.Length - 1; i >= 0; i--) Key(vks[i], true);
        Thread.Sleep(60);
    }
    public static void Type(string s) {  // a-z, '-' and space
        foreach (var c in s) Press(c == '-' ? (ushort)0xBD : c == ' ' ? (ushort)0x20 : (ushort)char.ToUpperInvariant(c));
    }

    // Which of Mozc's icon resources the input mode button (the tray's あ/a) shows now, or -1.
    public static int TrayIcon(int[] ids) {
        return OnUi(() => {
            ITfLangBarItemMgr mgr;
            Marshal.ThrowExceptionForHR(TF_CreateLangBarItemMgr(out mgr));
            var guid = new Guid("2C77A81E-41CC-4178-A3A7-5F8A987568E6");  // GUID_LBI_INPUTMODE
            object item;
            Marshal.ThrowExceptionForHR(mgr.GetItem(ref guid, out item));
            IntPtr icon;
            Marshal.ThrowExceptionForHR(((ITfLangBarItemButton)item).GetIcon(out icon));
            var shown = Pixels(icon);
            DestroyIcon(icon);
            IntPtr dll = GetModuleHandleW("mozc_tip64.dll");
            int size = GetSystemMetrics(50);  // SM_CYSMICON, as Mozc loads it
            foreach (var id in ids) {
                IntPtr res = LoadImageW(dll, (IntPtr)id, 1, size, size, 0x2000);  // IMAGE_ICON, LR_CREATEDIBSECTION
                if (res == IntPtr.Zero) continue;
                var px = Pixels(res);
                DestroyIcon(res);
                if (px == shown) return id;
            }
            return -1;
        });
    }
    static string Pixels(IntPtr icon) {
        ICONINFO info;
        if (!GetIconInfo(icon, out info)) return "";
        var bits = new byte[1 << 16];
        int n = GetBitmapBits(info.color, bits.Length, bits);
        DeleteObject(info.color); DeleteObject(info.mask);
        return Convert.ToBase64String(bits, 0, n);
    }
}
'@

if ($Typing) {  # the typing checks, in a process that isn't elevated
    $level = (whoami.exe /groups | Select-String 'S-1-16-\d+').Matches.Value  # the integrity label
    Result 'typing-not-elevated' $(if ($level -eq 'S-1-16-8192') { 'PASS' } else { 'FAIL' }) "integrity level $level (medium is S-1-16-8192)"
$mozcOk = @((Get-WinUserLanguageList) | ForEach-Object { $_.InputMethodTips }) -contains '0411:{10A67BC8-22FA-4A59-90DC-2546652C56BF}{186F700C-71CF-43FE-A00E-AACB1D9E6D3D}'
$langNames = @{ 0x0409 = 'EN'; 0x0804 = '中'; 0x0411 = '日' }
$startLang = $null
if ($mozcOk) {
    [TestWindow]::Start()
    $focused = [TestWindow]::Focus()
    Result 'test-window-focused' $(if ($focused) { 'PASS' } else { 'FAIL' }) $(if (-not $focused) { 'another window kept the foreground; no keys sent' })
}
if ($mozcOk -and $focused) {
    $startLang = [TestWindow]::Lang()
    $VK = @{ Win = 0x5B; Space = 0x20; Enter = 0x0D; Esc = 0x1B; Shift = 0x10; Alt = 0x12; Grave = 0xC0; Caps = 0x14; Katakana = 0xF1; Hiragana = 0xF2 }
    $ICON = @{ a = 112; hira = 104; kata = 114; caps = 124 }  # caps: A, Caps Lock on (keys and -eq ignore case)
    function Lang-Name { $l = [TestWindow]::Lang(); if ($langNames[$l]) { $langNames[$l] } else { '{0:x4}' -f $l } }
    function Win-Space { [TestWindow]::Press($VK.Win, $VK.Space); Start-Sleep -Milliseconds 600; Lang-Name }
    function Tray {
        $id = [TestWindow]::TrayIcon(@($ICON.Values))
        $name = ($ICON.GetEnumerator() | Where-Object Value -EQ $id).Key
        if ($name) { $name } else { "icon $id" }
    }
    function Typed($keys) { [TestWindow]::Clear(); [TestWindow]::Type($keys); [TestWindow]::Press($VK.Enter); Start-Sleep -Milliseconds 300; [TestWindow]::Text().Trim() }
    # Japanese starts in English or あ; a typed "a" says which.
    function To-Hiragana { if ((Typed 'a') -eq 'a') { [TestWindow]::Press($VK.Alt, $VK.Grave); Start-Sleep -Milliseconds 300 } }

    Check 'win-space-cycles-en-zh-ja' {
        $seen = @(Lang-Name) + (1..3 | ForEach-Object { Win-Space })
        $cycle = $seen -join ' → '
        if (($seen + $seen) -join ',' -notmatch 'EN,中,日,EN') { throw "Win+Space went $cycle" }
        $cycle
    }
    for ($i = 0; $i -lt 4 -and (Lang-Name) -ne '日'; $i++) { Win-Space | Out-Null }
    Check 'kana-input' {
        if ((Lang-Name) -ne '日') { throw "can't reach Japanese: $(Lang-Name)" }
        To-Hiragana
        $t = Typed 'nihongo '
        if ($t -ne '日本語') { throw "nihongo + Space + Enter gave '$t'" }
        $t
    }
    Check 'tray-hiragana' { $t = Tray; if ($t -ne 'hira') { throw "tray shows $t" }; 'あ' }
    Check 'katakana-and-back' {
        [TestWindow]::Press($VK.Katakana); Start-Sleep -Milliseconds 300
        $t = Tray; $k = Typed 'a'
        [TestWindow]::Press($VK.Hiragana); Start-Sleep -Milliseconds 300
        $back = Tray
        if ($t -ne 'kata' -or $k -ne 'ア' -or $back -ne 'hira') { throw "ア mode: tray $t, typed '$k'; back: tray $back" }
        'あ → ア (typed ア) → あ'
    }
    Check 'shift-tap-toggles-english' {
        [TestWindow]::Press($VK.Shift); Start-Sleep -Milliseconds 300
        $t = Tray; $e = Typed 'a'
        [TestWindow]::Press($VK.Shift); Start-Sleep -Milliseconds 300
        $back = Tray
        if ($t -ne 'a' -or $e -ne 'a' -or $back -ne 'hira') { throw "after Shift: tray $t, typed '$e'; after a second Shift: tray $back" }
        'あ → a → あ'
    }
    Check 'shift-letter-stays-japanese' {
        [TestWindow]::Clear(); [TestWindow]::Press($VK.Shift, 0x4B); Start-Sleep -Milliseconds 200; [TestWindow]::Press($VK.Esc)
        [TestWindow]::Press($VK.Esc); $t = Tray
        if ($t -ne 'hira') { throw "Shift+K left the tray at $t" }
        'Shift+K is no Shift tap'
    }
    Check 'alt-grave-toggles-english' {
        [TestWindow]::Press($VK.Alt, $VK.Grave); Start-Sleep -Milliseconds 300
        $t = Tray; $e = Typed 'a'
        [TestWindow]::Press($VK.Alt, $VK.Grave); Start-Sleep -Milliseconds 300
        $back = Tray
        if ($t -ne 'a' -or $e -ne 'a' -or $back -ne 'hira') { throw "after Alt+``: tray $t, typed '$e'; after a second Alt+``: tray $back" }
        'あ → a → あ'
    }
    Check 'caps-lock-icon' {
        $caps = [TestWindow]::CapsLock()
        try {
            if ($caps) { [TestWindow]::Press($VK.Caps); Start-Sleep -Milliseconds 300 }  # start with Caps Lock off
            [TestWindow]::Press($VK.Alt, $VK.Grave); Start-Sleep -Milliseconds 300
            $off = Tray
            [TestWindow]::Press($VK.Caps); Start-Sleep -Milliseconds 300
            $on = Tray
            [TestWindow]::Press($VK.Alt, $VK.Grave); Start-Sleep -Milliseconds 300
            $hiraCaps = Tray
            [TestWindow]::Press($VK.Caps); Start-Sleep -Milliseconds 300
            [TestWindow]::Press($VK.Alt, $VK.Grave); Start-Sleep -Milliseconds 300
            $offAgain = Tray
            [TestWindow]::Press($VK.Alt, $VK.Grave); Start-Sleep -Milliseconds 300
            if ($off -ne 'a' -or $on -ne 'caps' -or $hiraCaps -ne 'hira' -or $offAgain -ne 'a') {
                throw "English: $off, with Caps Lock: $on, あ with Caps Lock: $hiraCaps, English after: $offAgain"
            }
            'a → A with Caps Lock → a; あ stays あ'
        } finally {
            # a check that throws midway still leaves Caps Lock as it found it
            if ($caps -ne [TestWindow]::CapsLock()) { [TestWindow]::Press($VK.Caps) }
        }
    }
    # Back to the input language the run started in.
    for ($i = 0; $i -lt 4 -and [TestWindow]::Lang() -ne $startLang; $i++) { Win-Space | Out-Null }
}
$endLang = if ($mozcOk) { [TestWindow]::Lang() }
if ($mozcOk) { [TestWindow]::Stop() }
    "$startLang $endLang" | Set-Content "$out\typing-langs.txt"
    exit
}

# What the input method setup looks like now; the run must end with the same.
function Snapshot {
    $hot = reg.exe query 'HKCU\Control Panel\Input Method\Hot Keys' /s 2>$null
    $toggle = reg.exe query 'HKCU\Keyboard Layout\Toggle' 2>$null
    [ordered]@{
        languages = ((Get-WinUserLanguageList) | ForEach-Object { "$($_.LanguageTag)=$($_.InputMethodTips -join ',')" }) -join '; '
        default = "$(Get-WinDefaultInputMethodOverride | ForEach-Object InputMethodTip)"
        hotkeys = ($hot + $toggle) -join "`n"
        tips = (reg.exe query 'HKCU\Software\Microsoft\CTF\TIP' /s 2>$null) -join "`n"
        mozcRegistered = Test-Path 'HKLM:\SOFTWARE\Microsoft\CTF\TIP\{10A67BC8-22FA-4A59-90DC-2546652C56BF}'
        mozcProfile = Test-Path "$env:USERPROFILE\AppData\LocalLow\Mozc"
        hkcuSoftware = (Get-ChildItem HKCU:\Software).PSChildName -join ','
        capsLock = [Console]::CapsLock
    }
}
$before = Snapshot
$before | ConvertTo-Json | Set-Content "$out\mozc-before.json"

# Speed and dictionary: Mozc's own server from the MSI, timed through its IPC (Decisions #2: p95 ≤ 5 ms).
Check 'mozc-speed-and-dictionary' {
    $image = "$env:TEMP\sebtype-mozc-perf"
    Remove-Item -Recurse -Force $image -ErrorAction SilentlyContinue
    msiexec /a $msi.FullName /qn TARGETDIR=$image | Out-Null
    $server = (Get-ChildItem $image -Recurse -Filter mozc_server.exe | Select-Object -First 1).FullName
    if (-not $server) { throw 'no mozc_server.exe in the MSI image' }
    # cmd writes perf-mozc.py's UTF-8 bytes straight to the file: 5.1 decodes a native command's output
    # with this machine's console code page, which turns the Japanese words into '?' (top1 0/104 here).
    $raw = "$env:TEMP\sebtype-mozc-perf.txt"
    Remove-Item $raw -ErrorAction SilentlyContinue
    $job = Start-Job {
        param($py, $perf, $server, $words, $raw)
        $env:PYTHONIOENCODING = 'utf-8'
        cmd /c "`"$py`" -I `"$perf`" `"$server`" - 3 < `"$words`" > `"$raw`""
    } -ArgumentList $python.Source, "$PSScriptRoot\..\..\linux\perf-mozc.py", $server, "$PSScriptRoot\dict-words.tsv", $raw
    $job | Wait-Job -Timeout 300 | Out-Null
    $res = Get-Content -Encoding utf8 $raw -ErrorAction SilentlyContinue
    $job | Remove-Job -Force
    Remove-Item $raw -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $image -ErrorAction SilentlyContinue
    $res | Set-Content -Encoding utf8 "$out\mozc-perf.txt"
    $v = @{}; $res | Where-Object { $_ -match '^(\w+)=(.*)$' } | ForEach-Object { $v[$Matches[1]] = $Matches[2] }
    if (-not $v.key_p95_ms) { throw "no timings (see $out\mozc-perf.txt)" }
    if ([double]$v.key_p95_ms -gt 5) { throw "key p95 $($v.key_p95_ms) ms > 5 ms" }
    "key p50/p95 $($v.key_p50_ms)/$($v.key_p95_ms) ms, Space p95 $($v.convert_p95_ms) ms, RSS $([int]$v.rss_kb / 1024) MB, dictionary top-1 $($v.top1)"
}

Check 'install' { & $install $msi.FullName | Out-String | ForEach-Object Trim }

# Typing runs as apps do, not elevated: a scheduled task with RunLevel Limited starts this script
# again with the desktop user's normal (medium integrity) token. Built-in Administrator accounts have
# no such token; the child then fails 'typing-not-elevated'.
Remove-Item "$out\typing-langs.txt" -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Typing"
$user = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName sebtype-mozc-typing -Action $action -Principal $user -Force | Out-Null
Start-ScheduledTask sebtype-mozc-typing
for ($i = 0; $i -lt 300 -and -not (Test-Path "$out\typing-langs.txt"); $i++) { Start-Sleep 2 }
Unregister-ScheduledTask sebtype-mozc-typing -Confirm:$false
$startLang, $endLang = if (Test-Path "$out\typing-langs.txt") { (Get-Content "$out\typing-langs.txt") -split ' ' | ForEach-Object { if ($_) { [int]$_ } } }
foreach ($c in 'typing-not-elevated', 'test-window-focused', 'win-space-cycles-en-zh-ja', 'kana-input', 'tray-hiragana', 'katakana-and-back', 'shift-tap-toggles-english',
    'shift-letter-stays-japanese', 'alt-grave-toggles-english', 'caps-lock-icon') {
    if (-not (Select-String -Quiet -SimpleMatch " $c" $results)) { Result $c SKIP 'Mozc not installed or no focus' }
}

Check 'undo' { & $install -Undo | Out-String | ForEach-Object Trim }
Check 'everything-as-found' {
    if ($startLang -and $endLang -ne $startLang) { throw "input language is $('{0:x4}' -f $endLang), was $('{0:x4}' -f $startLang)" }
    $after = Snapshot
    $after | ConvertTo-Json | Set-Content "$out\mozc-after.json"
    $diff = $before.Keys | Where-Object { "$($before[$_])" -ne "$($after[$_])" }
    if ($diff) { throw "changed: $($diff -join ', ') (see $out\mozc-before.json, mozc-after.json)" }
    'language list, default input method, hotkeys, text service settings, Mozc installed or not, Mozc profile, Caps Lock'
}
exit [int][bool](Select-String -Quiet '^FAIL ' $results)
