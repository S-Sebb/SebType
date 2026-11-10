<#
Tests SebType's Mozc for Windows (#65) in the background: speed, dictionary, install, typing, the name
and tray icons, and undo. One command, no arguments, run elevated (the MSI installs for the machine):

    powershell -File pc/windows/mozc/test.ps1

Needs build.ps1's MSI (newest SebType-Mozc-*.msi in C:\ or D:\sebtype-mozc\out) and Python. Nothing
shows on the screen and nothing reads or sends real keys: the typing runs as a local user the test
creates and removes (sebtype-test, a standard account), on a desktop of its own that no screen
shows, and types through TSF (TsfHost.cs) instead of the keyboard. So the person at the PC keeps their
input method, Caps Lock and focus, and their own input settings are never changed: the run checks they
end as they began (language list, default input method, hotkeys, text service settings, Caps Lock),
and that Mozc, the test user and its profile are gone again. On a shared PC the caller holds the device
lock (on YukaROG: devices/yukarog-power.lock, taken from nobara-pc). One line per check in
%LOCALAPPDATA%\SebType\test\mozc-results.txt, logs next to it; exit 0 only if every check passes.
#>
param([string]$Typing)  # internal: the folder for the typing checks' results, set by the elevated run
$ErrorActionPreference = 'Stop'
$out = if ($Typing) { $Typing } else { "$env:LOCALAPPDATA\SebType\test" }
New-Item -ItemType Directory -Force $out | Out-Null
$results = if ($Typing) { "$out\typing-results.txt" } else { "$out\mozc-results.txt" }
Set-Content -Encoding utf8 $results ''
function Result($name, $status, $why = '') {
    $line = "$status $name$(if ($why) { ": $why" })"
    Add-Content -Encoding utf8 $results $line; Write-Host $line
}
function Check($name, [scriptblock]$body) {
    try { $why = & $body; Result $name PASS $why } catch { Result $name FAIL $_.Exception.Message }
}
$clsid = [Guid]'{10A67BC8-22FA-4A59-90DC-2546652C56BF}'  # Mozc's OSS text service and its profile
$profileId = [Guid]'{186F700C-71CF-43FE-A00E-AACB1D9E6D3D}'
$mozcTip = '0411:{10A67BC8-22FA-4A59-90DC-2546652C56BF}{186F700C-71CF-43FE-A00E-AACB1D9E6D3D}'
$typingChecks = 'test-user', 'install-for-user', 'languages-en-zh-ja', 'tsf-started', 'name-nihongo', 'mozc-active', 'kana-input',
    'tray-hiragana', 'katakana-and-back', 'shift-tap-toggles-english', 'shift-letter-stays-japanese', 'alt-grave-toggles-english',
    'caps-lock-icon', 'undo-for-user'

# The typing runs as another user, on a desktop that no screen shows (SwitchDesktop is never called),
# so the input method's windows (candidates, mode indicator) open there too. Not in session 0, which
# Mozc refuses. What each step needs, all seen on Server 2022:
# - the user logs on through LogonUser, not CreateProcessWithLogonW: Mozc's server takes the latter's
#   token (source "seclogo") for RunAs and runs restricted, and its text service then shows an error
#   and passes every key through (base/run_level.cc, IsDifferentUser);
# - the desktop is in WinSta0, as TSF refuses other window stations (E_ACCESSDENIED); the user gets
#   access to WinSta0 only while it runs;
# - the desktop has medium integrity: one made by this elevated process is high by default, and a
#   process of the user then hangs as it starts, whatever the access list says.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class HiddenDesktop {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct STARTUPINFO {
        public int cb; public string reserved, desktop, title; public int x, y, w, h, xChars, yChars, fill, flags;
        public short show, reserved2; public IntPtr reserved3, stdIn, stdOut, stdErr;
    }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr process, thread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES { public int length; public IntPtr sd; public bool inherit; }
    [StructLayout(LayoutKind.Sequential)] struct EXPLICIT_ACCESS {
        public int permissions, mode, inheritance; public IntPtr multipleTrustee; public int multipleOp, form, type; public IntPtr sid;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool LogonUserW(string user, string domain, string password, int type, int provider, out IntPtr token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcessWithTokenW(IntPtr token, int logonFlags, string app, string cmd, int creationFlags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, int rev, out IntPtr sd, IntPtr size);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ConvertStringSidToSidW(string s, out IntPtr sid);
    [DllImport("advapi32.dll")] static extern int GetSecurityInfo(IntPtr h, int type, int info, IntPtr owner, IntPtr group, out IntPtr dacl, IntPtr sacl, out IntPtr sd);
    [DllImport("advapi32.dll")] static extern int SetSecurityInfo(IntPtr h, int type, int info, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int SetEntriesInAclW(int n, ref EXPLICIT_ACCESS ea, IntPtr old, out IntPtr acl);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode, int flags, int access, ref SECURITY_ATTRIBUTES sa);
    [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr d);
    [DllImport("kernel32.dll")] static extern int WaitForSingleObject(IntPtr h, int ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out int code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    const int SE_WINDOW_OBJECT = 7, DACL_SECURITY_INFORMATION = 4;

    // Runs cmd as a local user with its profile, on a hidden desktop in this session; its exit code,
    // or -1 after ms.
    public static int Run(string user, string password, string sid, string cmd, string cwd, int ms) {
        IntPtr token, binarySid, oldDacl, oldSd, newDacl, sd, desk = IntPtr.Zero;
        if (!LogonUserW(user, ".", password, 2 /* LOGON32_LOGON_INTERACTIVE */, 0, out token)) throw new Win32Exception();
        if (!ConvertStringSidToSidW(sid, out binarySid)) throw new Win32Exception();
        IntPtr ws = GetProcessWindowStation();
        int e = GetSecurityInfo(ws, SE_WINDOW_OBJECT, DACL_SECURITY_INFORMATION, IntPtr.Zero, IntPtr.Zero, out oldDacl, IntPtr.Zero, out oldSd);
        if (e != 0) throw new Win32Exception(e);
        var ea = new EXPLICIT_ACCESS { permissions = 0x37F /* WINSTA_ALL_ACCESS */, mode = 1 /* GRANT_ACCESS */, type = 1 /* user */, sid = binarySid };
        e = SetEntriesInAclW(1, ref ea, oldDacl, out newDacl);
        if (e != 0) throw new Win32Exception(e);
        e = SetSecurityInfo(ws, SE_WINDOW_OBJECT, DACL_SECURITY_INFORMATION, IntPtr.Zero, IntPtr.Zero, newDacl, IntPtr.Zero);
        if (e != 0) throw new Win32Exception(e);
        try {
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW("D:(A;;GA;;;" + sid + ")(A;;GA;;;SY)(A;;GA;;;BA)S:(ML;;NW;;;ME)", 1, out sd, IntPtr.Zero)) throw new Win32Exception();
            var sa = new SECURITY_ATTRIBUTES { length = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), sd = sd };
            desk = CreateDesktopW("SebTypeTest", IntPtr.Zero, IntPtr.Zero, 0, 0x10000000 /* GENERIC_ALL */, ref sa);
            LocalFree(sd);
            if (desk == IntPtr.Zero) throw new Win32Exception();
            var si = new STARTUPINFO { cb = Marshal.SizeOf(typeof(STARTUPINFO)), desktop = @"WinSta0\SebTypeTest" };
            PROCESS_INFORMATION pi;
            // LOGON_WITH_PROFILE; CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT
            if (!CreateProcessWithTokenW(token, 1, null, cmd, 0x08000400, IntPtr.Zero, cwd, ref si, out pi)) throw new Win32Exception();
            try {
                if (WaitForSingleObject(pi.process, ms) != 0) return -1;
                int code; GetExitCodeProcess(pi.process, out code); return code;
            } finally { CloseHandle(pi.process); CloseHandle(pi.thread); }
        } finally {
            SetSecurityInfo(ws, SE_WINDOW_OBJECT, DACL_SECURITY_INFORMATION, IntPtr.Zero, IntPtr.Zero, oldDacl, IntPtr.Zero);  // WinSta0 as it was
            if (desk != IntPtr.Zero) CloseDesktop(desk);
            LocalFree(newDacl); LocalFree(oldSd); LocalFree(binarySid); CloseHandle(token);
        }
    }
}
'@

if ($Typing) {  # the typing checks, as the test user: not elevated, with a profile of its own
    Check 'test-user' {
        $level = (whoami.exe /groups | Select-String 'S-1-16-\d+').Matches.Value
        if ($level -ne 'S-1-16-8192') { throw "integrity level $level, not medium (S-1-16-8192)" }
        "$env:USERNAME, not elevated, session $((Get-Process -Id $PID).SessionId)"
    }
    # A new user's languages follow the machine's; start from English and Chinese, as on YukaROG.
    $ll = New-WinUserLanguageList en-US
    $ll.Add((New-Object Microsoft.InternationalSettings.Commands.WinUserLanguage zh-Hans-CN))
    Set-WinUserLanguageList $ll -Force
    $langsBefore = ((Get-WinUserLanguageList) | ForEach-Object { "$($_.LanguageTag)=$($_.InputMethodTips -join ',')" }) -join '; '
    Check 'install-for-user' { & "$PSScriptRoot\install.ps1" | Out-String | ForEach-Object Trim }
    Check 'languages-en-zh-ja' {
        $langs = @((Get-WinUserLanguageList) | ForEach-Object { $_ })
        $order = ($langs | ForEach-Object { $_.LanguageTag.Substring(0, 2) }) -join ','
        $ja = ($langs | Where-Object LanguageTag -Like 'ja*').InputMethodTips -join ','
        if ($order -ne 'en,zh,ja' -or $ja -ne $mozcTip) { throw "languages $order, Japanese: $ja" }
        'Win+Space goes EN → 中 → 日; Japanese is Mozc only'
    }
    $started = $false
    Check 'tsf-started' { Add-Type -Path "$PSScriptRoot\TsfHost.cs"; [SebType.TsfHost]::Start(); $script:started = $true; 'a text field of its own, focused in TSF' }
    if ($started) {
        $tsf = [SebType.TsfHost]
        Check 'name-nihongo' { $d = $tsf::Description(0x411, $clsid, $profileId); if ($d -ne '日本語') { throw "Windows shows '$d'" }; "Win+Space shows $d" }
        Check 'mozc-active' {
            $tsf::Activate(0x411, $clsid, $profileId); Start-Sleep -Milliseconds 500
            $a = $tsf::Active(); if ($a -ne "0411 $($clsid.ToString('B').ToUpper())") { throw "active: $a" }; 'Mozc'
        }
        $VK = @{ Enter = 0x0D; Esc = 0x1B; Shift = 0x10; Alt = 0x12; Grave = 0xC0; Caps = 0x14; Katakana = 0xF1; Hiragana = 0xF2 }
        $ICON = @{ a = 112; hira = 104; kata = 114; caps = 124 }  # caps: A, Caps Lock on (keys and -eq ignore case)
        function Tray {
            $id = $tsf::TrayIcon(@($ICON.Values))
            $name = ($ICON.GetEnumerator() | Where-Object Value -EQ $id).Key
            if ($name) { $name } else { "icon $id" }
        }
        function Press { $tsf::Press([uint16[]]$args); Start-Sleep -Milliseconds 300 }
        function Typed($keys) { $tsf::Clear(); $tsf::Type($keys); Press $VK.Enter; $tsf::Text().Trim() }
        # Japanese starts in English or あ; a typed "a" says which.
        function To-Hiragana { if ((Typed 'a') -eq 'a') { Press $VK.Alt $VK.Grave } }

        Check 'kana-input' {
            To-Hiragana
            $t = Typed 'nihongo '
            if ($t -ne '日本語') { throw "nihongo + Space + Enter gave '$t'" }
            $t
        }
        Check 'tray-hiragana' { $t = Tray; if ($t -ne 'hira') { throw "tray shows $t" }; 'あ' }
        Check 'katakana-and-back' {
            Press $VK.Katakana
            $t = Tray; $k = Typed 'a'
            Press $VK.Hiragana
            $back = Tray
            if ($t -ne 'kata' -or $k -ne 'ア' -or $back -ne 'hira') { throw "ア mode: tray $t, typed '$k'; back: tray $back" }
            'あ → ア (typed ア) → あ'
        }
        Check 'shift-tap-toggles-english' {
            Press $VK.Shift
            $t = Tray; $e = Typed 'a'
            Press $VK.Shift
            $back = Tray
            if ($t -ne 'a' -or $e -ne 'a' -or $back -ne 'hira') { throw "after Shift: tray $t, typed '$e'; after a second Shift: tray $back" }
            'あ → a → あ'
        }
        Check 'shift-letter-stays-japanese' {
            $tsf::Clear(); Press $VK.Shift 0x4B; Press $VK.Esc; Press $VK.Esc
            $t = Tray
            if ($t -ne 'hira') { throw "Shift+K left the tray at $t" }
            'Shift+K is no Shift tap'
        }
        Check 'alt-grave-toggles-english' {
            Press $VK.Alt $VK.Grave
            $t = Tray; $e = Typed 'a'
            Press $VK.Alt $VK.Grave
            $back = Tray
            if ($t -ne 'a' -or $e -ne 'a' -or $back -ne 'hira') { throw "after Alt+``: tray $t, typed '$e'; after a second Alt+``: tray $back" }
            'あ → a → あ'
        }
        # Caps Lock here is this thread's own key state, not the keyboard's.
        Check 'caps-lock-icon' {
            if ($tsf::CapsLock()) { Press $VK.Caps }
            Press $VK.Alt $VK.Grave; $off = Tray
            Press $VK.Caps; $on = Tray
            Press $VK.Alt $VK.Grave; $hiraCaps = Tray
            Press $VK.Caps; Press $VK.Alt $VK.Grave; $offAgain = Tray
            Press $VK.Alt $VK.Grave
            if ($off -ne 'a' -or $on -ne 'caps' -or $hiraCaps -ne 'hira' -or $offAgain -ne 'a') {
                throw "English: $off, with Caps Lock: $on, あ with Caps Lock: $hiraCaps, English after: $offAgain"
            }
            'a → A with Caps Lock → a; あ stays あ'
        }
        # DIAG (#65, remove): what ran and what Mozc wrote
        @("processes: $((Get-Process | Where-Object Name -Like 'mozc*' | ForEach-Object { "$($_.Name) $($_.Id) s$($_.SessionId)" }) -join ', ')"
          "LocalLow\Mozc: $((Get-ChildItem "$env:USERPROFILE\AppData\LocalLow\Mozc" -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ')"
          "keydown a: $($tsf::Diag(0x41))") | Set-Content -Encoding utf8 "$out\typing-diag.txt"
        Get-ChildItem "$env:USERPROFILE\AppData\LocalLow\Mozc" -Filter *.log -ErrorAction SilentlyContinue | Copy-Item -Destination $out
        $tsf::Stop()
    }
    Check 'undo-for-user' {
        & "$PSScriptRoot\install.ps1" -Undo | Out-Null
        $after = ((Get-WinUserLanguageList) | ForEach-Object { "$($_.LanguageTag)=$($_.InputMethodTips -join ',')" }) -join '; '
        if ($after -ne $langsBefore) { throw "languages $after, were $langsBefore" }
        'languages back to English and Chinese'
    }
    exit
}

# Preflight: one line saying what is missing.
$msi = Get-ChildItem 'C:\sebtype-mozc\out\SebType-Mozc-*.msi', 'D:\sebtype-mozc\out\SebType-Mozc-*.msi' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
$python = Get-Command python -ErrorAction SilentlyContinue | Where-Object Source -NotLike '*WindowsApps*'
$user = 'sebtype-test'
$preflight = if ($env:OS -ne 'Windows_NT') { 'not Windows' }
elseif (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'not elevated (admin)' }
elseif (-not $msi) { 'no SebType-Mozc-*.msi: run build.ps1 first' } elseif (-not $python) { 'no Python on PATH' }
elseif ((Get-Process -Id $PID).SessionId -eq 0) { 'in session 0 (services), where Mozc refuses to run: start it from a logged-on session' }
elseif (Get-LocalUser $user -ErrorAction SilentlyContinue) { "a local user $user exists already" }
if ($preflight) { Write-Host "preflight: $preflight"; Add-Content -Encoding utf8 $results "BLOCKED preflight: $preflight"; exit 1 }
$mozcBefore = Test-Path "HKLM:\SOFTWARE\Microsoft\CTF\TIP\{$clsid}"


# What the input method setup looks like now; the run must end with the same.
function Snapshot {
    $hot = reg.exe query 'HKCU\Control Panel\Input Method\Hot Keys' /s 2>$null
    $toggle = reg.exe query 'HKCU\Keyboard Layout\Toggle' 2>$null
    [ordered]@{
        languages = ((Get-WinUserLanguageList) | ForEach-Object { "$($_.LanguageTag)=$($_.InputMethodTips -join ',')" }) -join '; '
        default = "$(Get-WinDefaultInputMethodOverride | ForEach-Object InputMethodTip)"
        hotkeys = ($hot + $toggle) -join "`n"
        tips = (reg.exe query 'HKCU\Software\Microsoft\CTF\TIP' /s 2>$null) -join "`n"
        mozcRegistered = Test-Path "HKLM:\SOFTWARE\Microsoft\CTF\TIP\{$clsid}"
        mozcProfile = Test-Path "$env:USERPROFILE\AppData\LocalLow\Mozc"
        hkcuSoftware = (Get-ChildItem HKCU:\Software).PSChildName -join ','
        capsLock = [Console]::CapsLock
        localUsers = (Get-LocalUser).Name -join ','
        profiles = (Get-CimInstance Win32_UserProfile).LocalPath -join ','
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

Check 'install' {
    $log = "$out\mozc-msi.log"
    msiexec /i $msi.FullName /qn /norestart /l*v $log | Out-Null
    if (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\CTF\TIP\{$clsid}")) { throw "Mozc isn't registered after the MSI (log: $log)" }
    "$($msi.Name) for the machine"
}

# The typing checks, as a standard user of the test's own (see the top): a copy of this folder it can
# read, a password only this run knows, and the account and its profile removed afterwards.
$share = "$env:ProgramData\SebType-mozc-test"
Remove-Item -Recurse -Force $share -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$share\windows\mozc", "$share\linux" | Out-Null
Copy-Item "$PSScriptRoot\*" "$share\windows\mozc"
Copy-Item "$PSScriptRoot\..\..\linux\mozc-keymap.tsv" "$share\linux"
$password = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ }) + '-a1A'
try {
    $account = New-LocalUser $user -Password (ConvertTo-SecureString $password -AsPlainText -Force) -AccountNeverExpires -PasswordNeverExpires `
        -Description 'SebType Mozc test (#65); test.ps1 removes it'
    Add-LocalGroupMember -SID S-1-5-32-545 -Member $user -ErrorAction SilentlyContinue  # Users, if Windows didn't add it
    & icacls.exe $share /grant "${user}:(OI)(CI)M" | Out-Null
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$share\windows\mozc\test.ps1`" -Typing `"$share\out`""
    if ([HiddenDesktop]::Run($user, $password, $account.SID.Value, $cmd, $share, 600000) -eq -1) { Result typing-run FAIL 'the typing checks took over 10 minutes' }
} catch {
    Result typing-run FAIL $_.Exception.Message
} finally {
    # Mozc's server and renderer keep running as the test user; they go first, then its profile.
    Get-Process -IncludeUserName | Where-Object UserName -Like "*\$user" | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($account) {
        for ($i = 0; $i -lt 30; $i++) {
            $p = Get-CimInstance Win32_UserProfile | Where-Object SID -EQ $account.SID.Value
            if (-not $p) { break }
            try { $p | Remove-CimInstance; break } catch { Start-Sleep 2 }  # its registry hive unloads a moment after logoff
        }
        Remove-LocalUser $user
    }
}
Get-Content -Encoding utf8 "$share\out\typing-results.txt" -ErrorAction SilentlyContinue | Where-Object { $_ } | ForEach-Object { Add-Content -Encoding utf8 $results $_; Write-Host $_ }
Copy-Item "$share\out\*" $out -Exclude typing-results.txt -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $share
foreach ($c in $typingChecks) {
    if (-not (Select-String -Quiet -SimpleMatch " $c" $results)) { Result $c SKIP 'did not run' }
}

Check 'undo' {
    if ($mozcBefore) { return 'Mozc was installed before: kept' }
    Get-Process mozc_* -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*\Mozc\*' } | Stop-Process -Force
    msiexec /x $msi.FullName /qn /norestart | Out-Null
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\CTF\TIP\{$clsid}") { throw 'Mozc is still registered' }
    # Windows gives every logged-on user a (disabled) profile entry for a new text service, and Mozc an
    # empty LocalLow\Mozc folder; neither was there before.
    Remove-Item -Recurse -Force "HKCU:\Software\Microsoft\CTF\TIP\{$clsid}" -ErrorAction SilentlyContinue
    if (-not $before.mozcProfile) { Remove-Item -Recurse -Force "$env:USERPROFILE\AppData\LocalLow\Mozc" -ErrorAction SilentlyContinue }
    'Mozc uninstalled'
}
Check 'everything-as-found' {
    $after = Snapshot
    $after | ConvertTo-Json | Set-Content "$out\mozc-after.json"
    $diff = $before.Keys | Where-Object { "$($before[$_])" -ne "$($after[$_])" }
    if ($diff) { throw "changed: $($diff -join ', ') (see $out\mozc-before.json, mozc-after.json)" }
    'your language list, default input method, hotkeys, text service settings, Caps Lock; Mozc, the test user and its profile gone'
}
exit [int][bool](Select-String -Quiet '^FAIL ' $results)
