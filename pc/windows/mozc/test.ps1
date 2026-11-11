<#
Tests SebType's Mozc for Windows (#65) in the background: speed, dictionary, install, typing, the name
and tray icons, and undo. One command, no arguments, run elevated (the MSI installs for the machine):

    powershell -File pc/windows/mozc/test.ps1

Needs build.ps1's MSI (newest SebType-Mozc-*.msi in C:\ or D:\sebtype-mozc\out) and Python. Nothing
shows on the screen and no real keyboard is read or used: the typing runs as a local user the test
creates and removes (sebtype-test, a standard account), in a Remote Desktop session of its own that no
screen shows, whose RDP client types the keys (rdp-keys.py, reached on port 47812). So the person at the PC keeps
their input method, Caps Lock and focus, and their own input settings are never changed: the run checks
they end as they began (language list, default input method, hotkeys, text service settings, Caps
Lock), and that Mozc, the test user and its profile are gone again. The session needs Windows Server
(several sessions at once) and an RDP client: test-tcsbackend.sh runs all of this on TCSBackEnd from
nobara-pc and opens the session there without a window. One line per check in
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
$typingChecks = 'test-user', 'install-for-user', 'languages-en-ja-zh', 'rdp-keys', 'notepad-japanese', 'notepad-shift-tap', 'tsf-started', 'window-focused', 'name-nihongo', 'mozc-active', 'kana-input',
    'tray-hiragana', 'tray-menu-katakana-and-back', 'shift-tap-toggles-english', 'shift-letter-stays-japanese', 'alt-grave-katakana-and-back', 'shift-letter-stays-english',
    'caps-lock-icon', 'undo-for-user'

if ($Typing) {  # the typing checks, as the test user: not elevated, with a profile of its own
    try {
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
        $setup = "$PSScriptRoot\..\setup\setup.ps1"  # what SebType's installer runs for the user (#73)
        Check 'install-for-user' { & $setup -User -Languages en,ja | Out-String | ForEach-Object Trim }
        Check 'languages-en-ja-zh' {
            $langs = @((Get-WinUserLanguageList) | ForEach-Object { $_ })
            $order = ($langs | ForEach-Object { $_.LanguageTag.Substring(0, 2) }) -join ','
            $ja = ($langs | Where-Object LanguageTag -Like 'ja*').InputMethodTips -join ','
            if ($order -ne 'en,ja,zh' -or $ja -ne $mozcTip) { throw "languages $order, Japanese: $ja" }
            'SebType''s languages first (EN → 日), then Chinese as it was; Japanese is Mozc only'
        }
        # The keys come from the Remote Desktop client, as a person's would: rdp-keys.py on its side, which
        # test-tcsbackend.sh tunnels to this port. They go to the window in front of this session.
        Add-Type -Path "$PSScriptRoot\TsfHost.cs" -ReferencedAssemblies System.Drawing
        $tsf = [SebType.TsfHost]
        $keys = $null
        Check 'rdp-keys' {
            for ($i = 0; $i -lt 30 -and -not $script:keys; $i++) {
                try { $script:keys = New-Object Net.Sockets.TcpClient '127.0.0.1', 47812 } catch { Start-Sleep 1 }
            }
            if (-not $script:keys) { throw 'no key server at 127.0.0.1:47812 (rdp-keys.py, through the SSH tunnel)' }
            'the Remote Desktop client types the keys'
        }
        if ($keys) {
            $kw = New-Object IO.StreamWriter $keys.GetStream(); $kw.AutoFlush = $true
            $kr = New-Object IO.StreamReader $keys.GetStream()
            # Keys 'Shift_L' 'Alt_L+grave': X keysym names, pressed in order; then time for them to arrive.
            function Keys {
                $line = ($args | ForEach-Object { $_ }) -join ' '
                $kw.WriteLine($line); $r = $kr.ReadLine()
                if ($r -ne 'ok') { throw "keys $line`: $r" }
                Start-Sleep -Milliseconds 500
            }
            function TypeText($s) { Keys ($s.ToCharArray() | ForEach-Object { if ($_ -eq ' ') { 'space' } else { "$_" } }) }

            # Notepad first, the plainest real app: Win+Space to 日本語, then what a person types.
            $np = Start-Process notepad -PassThru
            try {
                $null = $np.WaitForInputIdle(10000)
                $h = $np.MainWindowHandle
                function NotepadTyped($s) { Keys 'Control_L+a' BackSpace; TypeText $s; Keys Return; $tsf::EditText($h).Trim() }
                Check 'notepad-japanese' {
                    if (-not $tsf::Foreground($h)) { throw 'Notepad did not come to the front' }
                    for ($i = 0; $i -lt 3 -and $tsf::Language($h) -ne 0x411; $i++) { Keys 'Super_L+space'; Start-Sleep 1 }
                    if ($tsf::Language($h) -ne 0x411) { throw "Win+Space three times left Notepad in language $('{0:x4}' -f $tsf::Language($h))" }
                    if ((NotepadTyped 'a') -eq 'a') { Keys Shift_L }  # Japanese starts in English or あ
                    $t = NotepadTyped 'nihongo '
                    if ($t -ne '日本語') { throw "nihongo + Space + Enter gave '$t'" }
                    "Win+Space to 日本語, typed $t"
                }
                Check 'notepad-shift-tap' {
                    Keys 'Control_L+a' BackSpace
                    Keys Shift_L; TypeText 'a'; $e = $tsf::EditText($h)
                    Keys Shift_L; TypeText 'a'; Keys Return; $j = $tsf::EditText($h).Trim()
                    if ($e -ne 'a' -or $j -ne 'aあ') { throw "after a Shift tap 'a' gave '$e'; after a second '$j'" }
                    'あ → a → あ'
                }
            } finally { $np | Stop-Process -Force }

            # Then the test's own text field, where Mozc's tray button can be read.
            $started = $false
            Check 'tsf-started' { $tsf::Start(); $script:started = $true; 'a text field of its own, focused in TSF' }
        }
        if ($started) {
            Check 'window-focused' { if (-not $tsf::Focus()) { throw 'another window kept the foreground of the test session' }; 'the text field has the keyboard focus in TSF' }
            Check 'name-nihongo' { $d = $tsf::Description(0x411, $clsid, $profileId); if ($d -ne '日本語') { throw "Windows shows '$d'" }; "Win+Space shows $d" }
            Check 'mozc-active' {
                $tsf::Activate(0x411, $clsid, $profileId); Start-Sleep -Milliseconds 500
                $a = $tsf::Active(); if ($a -ne "0411 $($clsid.ToString('B').ToUpper())") { throw "active: $a" }; 'Mozc'
            }
            $ICON = @{ a = 112; hira = 104; kata = 114; caps = 124 }  # caps: A, Caps Lock on (keys and -eq ignore case)
            function Tray {
                $id = $tsf::TrayIcon(@($ICON.Values))
                $name = ($ICON.GetEnumerator() | Where-Object Value -EQ $id).Key
                if ($name) { $name } else { "icon $id" }
            }
            function Typed($s) { $tsf::Clear(); TypeText $s; Keys Return; $tsf::Text().Trim() }
            # Japanese starts in English or あ; a typed "a" says which.
            function To-Hiragana { if ((Typed 'a') -eq 'a') { Keys Shift_L } }

            Check 'kana-input' {
                To-Hiragana
                $t = Typed 'nihongo '
                if ($t -ne '日本語') { throw "nihongo + Space + Enter gave '$t'" }
                $t
            }
            Check 'tray-hiragana' { $t = Tray; if ($t -ne 'hira') { throw "tray shows $t" }; 'あ' }
            # The tray menu is the one switch, あ → ア, with its key (#117), with a picture of each in $out.
            Check 'tray-menu-katakana-and-back' {
                $m = $tsf::TrayPopup($true, "$out\menu-ja-hira.png")
                $t = Tray; $k = Typed 'a'
                $m2 = $tsf::TrayPopup($true, "$out\menu-ja-kata.png")
                $back = Tray
                if ($m -ne "あ → ア`tAlt+``" -or $t -ne 'kata' -or $k -ne 'ア' -or $m2 -ne "ア → あ`tAlt+``" -or $back -ne 'hira') {
                    throw "menu '$m', then tray $t, typed '$k'; menu '$m2', then tray $back"
                }
                'menu あ → ア (typed ア), then ア → あ'
            }
            Check 'alt-grave-katakana-and-back' {
                Keys 'Alt_L+grave'
                $t = Tray; $k = Typed 'a'
                Keys 'Alt_L+grave'
                $back = Tray
                if ($t -ne 'kata' -or $k -ne 'ア' -or $back -ne 'hira') { throw "after Alt+``: tray $t, typed '$k'; after a second Alt+``: tray $back" }
                'あ → ア (typed ア) → あ'
            }
            Check 'shift-tap-toggles-english' {
                Keys Shift_L
                $t = Tray; $e = Typed 'a'
                Keys Shift_L
                $back = Tray
                if ($t -ne 'a' -or $e -ne 'a' -or $back -ne 'hira') { throw "after Shift: tray $t, typed '$e'; after a second Shift: tray $back" }
                'あ → a → あ'
            }
            Check 'shift-letter-stays-japanese' {
                $tsf::Clear(); Keys 'Shift_L+k'; Keys Escape Escape
                $t = Tray
                if ($t -ne 'hira') { throw "Shift+K left the tray at $t" }
                'Shift+K is no Shift tap'
            }
            # The Shift tap is the only way to English letters: Alt+` there switches nothing (#117).
            Check 'alt-grave-stays-english' {
                Keys Shift_L; Keys 'Alt_L+grave'
                $t = Tray; $e = Typed 'a'
                Keys Shift_L
                $back = Tray
                if ($t -ne 'a' -or $e -ne 'a' -or $back -ne 'hira') { throw "English, then Alt+``: tray $t, typed '$e'; after a Shift tap: tray $back" }
                'a → Alt+` → a → あ'
            }
            Check 'shift-letter-stays-english' {
                Keys Shift_L
                $tsf::Clear(); Keys 'Shift_L+k'; $k = $tsf::Text(); $t = Tray
                Keys Shift_L
                if ($k -ne 'K' -or $t -ne 'a') { throw "Shift+K in English typed '$k', tray $t" }
                'Shift+K types K and stays English'
            }
            # Caps Lock is this session's own: the test user's, not anyone's keyboard.
            Check 'caps-lock-icon' {
                if ($tsf::CapsLock()) { Keys Caps_Lock }
                Keys Shift_L; $off = Tray
                Keys Caps_Lock; $on = Tray
                Keys Shift_L; $hiraCaps = Tray
                Keys Caps_Lock; Keys Shift_L; $offAgain = Tray
                Keys Shift_L
                if ($off -ne 'a' -or $on -ne 'caps' -or $hiraCaps -ne 'hira' -or $offAgain -ne 'a') {
                    throw "English: $off, with Caps Lock: $on, あ with Caps Lock: $hiraCaps, English after: $offAgain"
                }
                'a → A with Caps Lock → a; あ stays あ'
            }
            $tsf::Stop()
        }
        Check 'undo-for-user' {
            & $setup -User -Undo | Out-Null
            $after = ((Get-WinUserLanguageList) | ForEach-Object { "$($_.LanguageTag)=$($_.InputMethodTips -join ',')" }) -join '; '
            if ($after -ne $langsBefore) { throw "languages $after, were $langsBefore" }
            'languages back to English and Chinese'
        }
    } catch { Result typing-run FAIL $_.Exception.Message } finally {
        New-Item -ItemType File "$out\typing-done" | Out-Null  # the elevated run waits for it
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
elseif ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) { 'not Windows Server: the typing needs a second Remote Desktop session (run test-tcsbackend.sh)' }
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

# The typing checks, as a standard user of the test's own, in a Remote Desktop session of its own. Mozc
# needs that user's own interactive logon. Seen on Server 2022 (#65): started with CreateProcessWithLogonW,
# Mozc takes the token (source "seclogo") for RunAs, runs restricted and passes every key through
# (base/run_level.cc, IsDifferentUser); started with LogonUser into this session, the process hangs or
# fails to start (0xC0000142) on any desktop here. So a logon task starts them in the user's own
# session, with the same token as its Explorer; the caller opens that session with an RDP client and the
# logon this run writes to $rdp (Windows Server ignores an RDP client's own start program).
$share = "$env:ProgramData\SebType-mozc-test"
Remove-Item -Recurse -Force $share -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$share\windows\mozc", "$share\windows\setup", "$share\out" | Out-Null
Copy-Item "$PSScriptRoot\*" "$share\windows\mozc"
Copy-Item "$PSScriptRoot\..\setup\setup.ps1", "$PSScriptRoot\..\..\linux\mozc-keymap.tsv" "$share\windows\setup"
$password = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ }) + '-a1A'
$rdp = "$out\rdp-logon.txt"  # in the elevated user's own profile, which the test user can't read
$task = 'SebType-mozc-typing'
try {
    $account = New-LocalUser $user -Password (ConvertTo-SecureString $password -AsPlainText -Force) -AccountNeverExpires -PasswordNeverExpires `
        -Description 'SebType Mozc test (#65); test.ps1 removes it'
    Add-LocalGroupMember -SID S-1-5-32-545 -Member $user -ErrorAction SilentlyContinue  # Users, if Windows didn't add it
    Add-LocalGroupMember -SID S-1-5-32-555 -Member $user  # Remote Desktop Users
    & icacls.exe $share /grant "${user}:(OI)(CI)M" | Out-Null
    $action = New-ScheduledTaskAction -Execute powershell.exe -WorkingDirectory $share `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$share\windows\mozc\test.ps1`" -Typing `"$share\out`""
    Register-ScheduledTask $task -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) `
        -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
    Set-Content $rdp $user, $password
    $deadline = (Get-Date).AddMinutes(12)
    while (-not (Test-Path "$share\out\typing-done") -and (Get-Date) -lt $deadline) { Start-Sleep 5 }
    if (-not (Test-Path "$share\out\typing-done")) {
        Result typing-run FAIL $(if (Test-Path "$share\out\typing-results.txt") { 'the typing checks took over 12 minutes' } else { "no Remote Desktop logon of $user in 12 minutes" })
    }
} catch {
    Result typing-run FAIL $_.Exception.Message
} finally {
    Remove-Item $rdp -ErrorAction SilentlyContinue
    Unregister-ScheduledTask $task -Confirm:$false -ErrorAction SilentlyContinue
    # Its session ends first and Windows unloads its profile; only then do the profile and the account go.
    # (Deleting the account while its session runs leaves the profile loaded until a reboot.)
    query.exe session 2>$null | ForEach-Object { if ("$_" -match "\s$user\s+(\d+)\s") { logoff.exe $Matches[1] } }
    if ($account) {
        $prof = $null
        for ($i = 0; $i -lt 60; $i++) {
            $prof = Get-CimInstance Win32_UserProfile | Where-Object SID -EQ $account.SID.Value
            if (-not $prof -or -not $prof.Loaded) { break }
            Start-Sleep 2
        }
        if ($prof.Loaded) {
            Result test-user-removed FAIL "its profile stayed loaded after logoff: $user and $($prof.LocalPath) kept"
        } else {
            if ($prof) { $prof | Remove-CimInstance }
            Remove-LocalUser $user
        }
    }
}
Get-Content -Encoding utf8 "$share\out\typing-results.txt" -ErrorAction SilentlyContinue | Where-Object { $_ } | ForEach-Object { Add-Content -Encoding utf8 $results $_; Write-Host $_ }
Copy-Item "$share\out\*" $out -Exclude typing-results.txt, typing-done -ErrorAction SilentlyContinue
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
exit [int][bool](Select-String -Quiet '^(FAIL|SKIP) ' $results)
