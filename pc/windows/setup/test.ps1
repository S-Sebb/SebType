<#
Tests SebType's installer (#73) in the background on a Windows Server: install, typing, upgrade and
uninstall, twice, and a picture of every installer page. One command, run elevated in a logged-on
session (test-tcsbackend.sh does that on TCSBackEnd and opens the Remote Desktop session it needs):

    powershell -File C:\sebtype-setup-test\test.ps1

The folder holds this script, TsfHost.cs, perf-rime.ps1 (../) and perf-rime.exe (from the librime
build) and SebType-setup-*.exe; for -Only upgrade also old\SebType-setup-*.exe, the SebType before
#190 (Weasel and Mozc's own text services). The test creates a local
admin user, sebtype-test, and runs everything as that user in a Remote Desktop session of its own, so
nobody's own input settings change, then removes the user and its profile:

1. The installer's pictures: the language dialog (which must preselect Windows' own display language),
   the welcome page in English, 中文 and 日本語, then a whole install in English with the uninstaller.
2. Round 1 (that install, all languages): what it installed and set, typing in Notepad with real keys
   (rdp-keys.py: Win+Space EN → 中 → 日, pinyin, the Shift tap, Ctrl+Shift+F, typo correction, Japanese and its Ctrl+Backspace undo),
   Rime's time per key (p95 ≤ 16 ms, only with -PerfRun: the final performance run, #54) and Chinese's
   tray menu in a TSF text field of the test's own (TsfHost.cs, with a picture of the menu) and its
   Picnic candidate window with the pig (pictures, horizontal and vertical), a silent
   upgrade that keeps learned words, Japanese still working after the language list changes, then the
   uninstall: everything back as before, learned words gone.
3. Round 2, all silent: install with Chinese and Japanese only (no English), upgrade to English and
   Chinese (Japanese and its learned words go), uninstall.

-Only picnic: only a silent install, the Picnic window's pictures and a silent uninstall (#162).
-Only quick-english: only a silent install, a switch into 中文 and 日本語 ending the Shift tap's English (#489),
   and a silent uninstall.
-Only upgrade: only the update from the SebType before #190 (#190, #192): that one installed silently with
   all languages and learned words, then this one over it: Weasel and Mozc gone with their Start menu
   entries, SebType's text service in their place, the learned words kept; then typing and a silent
   uninstall.
-Only sync: only sync with your own server (#180): a silent install; sebtype_sync.py serving on this PC's
   localhost, run by a copy of the Python Setup packs, with a throwaway login; the login saved as the
   Configurator's Save does (sebtype-configurator --save-login: Credential Manager, the task); made-up
   words of this PC's (Rime, Mozc) and of another device (test-sync.py); the "SebType sync" task run
   once, then again from a network-connect event (#377); then a silent uninstall, which must sync first,
   wait for the schedule lock a Configurator holds (#401), go on after 30 s if it stays held, and remove
   the task, the login and sync's files.
   The folder also holds sebtype_sync.py (sync-server/) and test-sync.py.
-Only sync-page: only the setup wizard's sync page (#435, #465, #468, #471): an install in English as a person
   does it, Inno closing after the copy and the installed Configurator's wizard showing the rest, driven
   through UI Automation; once its sync page shows, sebtype_sync.py (in the folder) serving on localhost with
   Setup's Python and a throwaway login; the page given a wrong password (Wrong username or password and Save
   anyway & continue in the page, cleared by a field change), a closed port (Can't reach the server), then the
   right one (the tick, the ready page, sync on in sync.json; the save, which needs Credential Manager, is INFO
   where the driver's elevated token lacks it), with pictures (73-4-common-en, 73-5-*, 73-6-*); a silent uninstall.
-Only common-page: only the setup wizard's Common settings page (#444, #471): an install in 中文 as a person
   does it, with English and 日本語 ticked only; the page showing a new account's settings (简体, Picnic, Vertical, 6; 73-4-common-zh), then 繁體,
   System style (the wizard turning plain at once), Horizontal and 8 chosen and Next, each read back with
   sebtype-configurator --common-settings get; Skip to the ready page and 完成, then Windows' input methods and
   the Configurator's language switches (English and 日本語 on, 中文 off); each page (2-4) in both themes
   and both languages (73-wizard-<lang>-<step>-<theme>); the ready page's step with SebType's 日本語 taken off
   the language list, in both themes and languages (73-wizard-<lang>-4-<theme>-step), its 添加 putting it back
   (#445); a silent uninstall; then a silent
   install with /TASKS="en,ja" and the same language checks, and its silent uninstall.
-Only compare: the final performance run's comparison (#54): a silent install, what it put in the Start
   menu, then SebType's Chinese and Japanese, Microsoft Pinyin and Microsoft Japanese IME each typed in
   the TSF text field and timed per key, with their memory; 10+ minutes of mixed SebType typing
   (-SoakMinutes, default 12; 0 for none); a silent uninstall. -CompareImes picks the input methods. Numbers in out\compare-*.txt.
-Only not-ready: the tray key while 中文 or 日本語 isn't ready (#275): a silent install, test-not-ready.ps1
   (in the folder too) as the test user, not elevated, with -AnyDisplay (its pictures in out\275), a silent
   uninstall.
-Only forget: forgetting learned words while the server runs (#375): a silent install, test-forget.ps1 (in the
   folder too) as the test user, not elevated, a silent uninstall.
-Only learned: Mozc's learned conversions sync (#409): a silent install, test-learned-sync.ps1 (in the folder
   too, with sebtype_sync.py) as the test user, not elevated, a silent uninstall.
-Only update: the daily update check (#422): a silent install, its task, test-update.ps1 (in the folder too) as
   the test user, not elevated, the update's admin side (the installed start-setup.ps1) refusing a changed
   setup and upgrading from its checked copy in Program Files, a silent uninstall and the task and copies gone.
-Only private: private fields and the Configurator's learning off (#270, #374): a silent install,
   test-private.ps1 (in the folder too) as the test user, not elevated, with -AnyDisplay, a silent uninstall.

Results: one line per check in out\setup-results.txt, pictures in out\*.png; exit 0 only if all pass.
-Driver and -Typing are the test user's own parts (elevated, and not elevated as apps run).
#>
param([string]$Driver, [string]$Typing, [switch]$PerfRun, [string]$Only, [int]$SoakMinutes = 12, [string]$CompareImes = 'sebtype-zh,mspinyin,sebtype-ja,msime')
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
# Where a run's time goes: out\times-<part>.txt, a line per check and step.
$timesStart = Get-Date
function Mark($what, $seconds = $null) {
  Add-Content -Encoding utf8 ($results -replace '-results\.txt$', '-times.txt') "$(Get-Date -f HH:mm:ss) +$([int]((Get-Date) - $timesStart).TotalSeconds)s $what$(if ($null -ne $seconds) { " ($seconds s)" })"
}
function Check($name, [scriptblock]$body) {
  if ($Typing) { Add-Content "$out\keys-$Typing.txt" "$(Get-Date -f HH:mm:ss.fff) CHECK $name" }  # with ime-*.txt (#129)
  $t = Get-Date
  try { $why = & $body; Result $name PASS $why } catch { Result $name FAIL $_.Exception.Message }
  Mark $name ([int]((Get-Date) - $t).TotalSeconds)
}
function Wait-Until([int]$seconds, [scriptblock]$cond) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while (-not ($r = & $cond)) { if ((Get-Date) -gt $deadline) { return $null }; Start-Sleep -Milliseconds 300 }
  $r
}
$user = 'sebtype-test'
$AppKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{5C1E7A52-3D8B-4F7E-9E0B-7B3B5A1C7354}_is1'
$App = "$env:ProgramFiles\SebType"
# SebType's text service (windows/src/tip/tip.h), and the Weasel and Mozc SebType installed before #190.
$Clsid = '{D4E5C593-4F73-475F-936C-0E29A6FE7A02}'
$ZhProfile = '{8AA7DDAC-A4B8-4437-9C0B-8698879EC987}'
$JaProfile = '{B148FB02-C235-45D6-996C-672C783ECD48}'
$ZhTip = "0804:$Clsid$ZhProfile"
$JaTip = "0411:$Clsid$JaProfile"
$WeaselClsid = '{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}'
$MozcClsid = '{10A67BC8-22FA-4A59-90DC-2546652C56BF}'
$WeaselKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Weasel'
function Mozc-Installed { [bool](Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall | Where-Object { $_.GetValue('DisplayName') -eq 'Mozc' }) }
function Languages { ((Get-WinUserLanguageList) | ForEach-Object { "$($_.LanguageTag)[$($_.InputMethodTips -join ',')]" }) -join ' ' }


# ============================================================ typing, as the test user, not elevated
if ($Typing) {
  try {
    # Scripts of their own, which make no keys through Remote Desktop (#275, #270): no key server.
    $own = @{ 'not-ready' = 'test-not-ready.ps1', '275', 'not-ready-results.txt'; 'private' = 'test-private.ps1', '374', 'private-results.txt'; 'update' = 'test-update.ps1', '422', 'update-results.txt'; 'update-user' = 'test-update-user.ps1', '422', 'update-user-results.txt' }
    if ($own.ContainsKey($Typing)) {
      $script, $dir, $file = $own[$Typing]
      $log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root\$script" -AnyDisplay -Out "$out\$dir" 2>&1 | Out-String
      Set-Content -Encoding utf8 "$out\$Typing.log" $log
      $lines = @(Get-Content -Encoding utf8 "$out\$dir\$file" -ErrorAction SilentlyContinue | Where-Object { $_ })
      if ($lines) { $lines | ForEach-Object { Add-Content -Encoding utf8 $results $_ } } else { Result $Typing FAIL "no results: $($log.Trim())" }
      return
    }
    # Scripts whose keys go to TSF's keystroke manager: no key server.
    $tsfOwn = @{ 'forget' = 'test-forget.ps1', '375', 'forget-results.txt'; 'learned' = 'test-learned-sync.ps1', '409', 'learned-sync-results.txt' }
    if ($tsfOwn.ContainsKey($Typing)) {
      $script, $dir, $file = $tsfOwn[$Typing]
      $log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root\$script" -Out "$out\$dir" 2>&1 | Out-String
      Set-Content -Encoding utf8 "$out\$Typing.log" $log
      $lines = @(Get-Content -Encoding utf8 "$out\$dir\$file" -ErrorAction SilentlyContinue | Where-Object { $_ })
      if ($lines) { $lines | ForEach-Object { Add-Content -Encoding utf8 $results $_ } } else { Result $Typing FAIL "no results: $($log.Trim())" }
      return
    }
    Add-Type -Path "$root\TsfHost.cs" -ReferencedAssemblies System.Drawing
    $tsf = [SebType.TsfHost]
    # Keys come from the Remote Desktop client (rdp-keys.py through test-tcsbackend.sh's tunnel), as a person's.
    $keys = Wait-Until 30 { try { New-Object Net.Sockets.TcpClient '127.0.0.1', 47812 } catch { $null } }
    if (-not $keys) { throw 'no key server at 127.0.0.1:47812 (rdp-keys.py, through the SSH tunnel)' }
    $kw = New-Object IO.StreamWriter $keys.GetStream(); $kw.AutoFlush = $true
    $kr = New-Object IO.StreamReader $keys.GetStream()
    function Keys {  # X keysym names or chords (Alt_L+grave), pressed in order
      $line = ($args | ForEach-Object { $_ }) -join ' '
      Add-Content "$out\keys-$Typing.txt" "$(Get-Date -f HH:mm:ss.fff) $line"
      $kw.WriteLine($line); $r = $kr.ReadLine()
      if ($r -ne 'ok') { throw "keys $line`: $r" }
      Start-Sleep -Milliseconds 500
    }
    function TypeText($s) { Keys ($s.ToCharArray() | ForEach-Object { if ($_ -eq ' ') { 'space' } else { "$_" } }) }
    # #562: a window that didn't come to the front says what held it (TsfHost's LastFront) and leaves a picture
    # of the screen; each time only a fallback won, that goes in 562-front.txt too.
    function Front-Note($what) {
      $line = "$what`: $($tsf::LastFront)"
      if ($tsf::LastFront -notmatch '; won') {
        $shot = "$out\562-front-$(Get-Date -f HHmmss-fff).png"
        try { $tsf::Screen($shot); $line += "; picture $shot" } catch { $line += "; no picture: $($_.Exception.Message)" }
      }
      Add-Content -Encoding utf8 "$out\562-front.txt" "$(Get-Date -f HH:mm:ss) $line"
      $line
    }
    function To-Front($h, $what) {
      $ok = $tsf::Foreground($h)
      if ($tsf::LastFront) { $why = Front-Note $what }
      if (-not $ok) { throw "$what did not come to the front ($why)" }
    }
    # -Only compare (#54): SebType's Chinese and Japanese next to Microsoft's, typed the same way into
    # the test's own TSF text field, one fresh process per input method so each one's in-process share of
    # memory is its own. Per key: from the key entering the session (a low-level hook) to the input
    # method's first change of the field's text (its composition). Words end with Escape (Mozc and
    # Microsoft Japanese: Space converts first), so nothing is learned. compare-<ime>.txt: key=value lines.
    if ($Typing -like 'compare-*') {
      $ime = $Typing -replace '^compare-'
      $IMES = @{
        'sebtype-zh' = 0x804, $Clsid, $ZhProfile
        mspinyin = 0x804, '{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}', '{FA550B04-5AD7-411F-A5AC-CA038EC515D7}'
        'sebtype-ja' = 0x411, $Clsid, $JaProfile
        msime = 0x411, '{03B5835F-F03C-411B-9CE2-AA23E1171E36}', '{A76C93D9-5523-4E90-AAFA-4DB112F9AC76}'
      }
      $pinyin = -split 'nihao ranhou ranh lh zhongguo women xiexie zaijian shurufa dianhua kaihui wozhidaole meiguanxi jintiantianqizenmeyang'
      $romaji = -split 'nihongo konnichiha arigatou toukyou shinkansen watashihagakuseidesu kyouhaiitenkidesune'
      $f = "$out\compare-$ime.txt"; Set-Content -Encoding utf8 $f ''
      function Out($k, $v) { Add-Content -Encoding utf8 $f "$k=$v" }
      $session = (Get-Process -Id $PID).SessionId
      function Mem($tag) {  # this process (the IME's in-process part) and the input methods' own processes
        $me = Get-Process -Id $PID
        Out "${tag}_host_private_kb" ([int]($me.PrivateMemorySize64 / 1KB)); Out "${tag}_host_ws_kb" ([int]($me.WorkingSet64 / 1KB))
        Get-Process | Where-Object { $_.SessionId -eq $session -and $_.Name -match '^(sebtype-server|mozc_server|mozc_renderer|mozc_broker|ChsIME|IMEJP.*|TextInputHost|InputApp|ctfmon)$' } |
          ForEach-Object { Out "${tag}_proc" "$($_.Name) pid $($_.Id) ws_kb $([int]($_.WorkingSet64 / 1KB)) private_kb $([int]($_.PrivateMemorySize64 / 1KB))" }
      }
      function Use($name) {
        $l, $c, $p = $IMES[$name]
        $tsf::Activate($l, [Guid]$c, [Guid]$p); $tsf::Open(); $tsf::Settle(500)
        $want = '{0:x4} {1}' -f $l, $c.ToUpperInvariant()
        if ($tsf::Active() -ne $want) { throw "$name isn't active: $($tsf::Active())" }
      }
      function Ms([string]$s) { if ($s) { @($s -split ',' | ForEach-Object { [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) }) } else { @() } }
      # One word: its keys and the ones that end it; returns each key's ms until the field first changed
      # after it, -1 when it didn't before the next key.
      function Word($w, $tail) {
        $tsf::Clear(); $null = $tsf::TakeTimes()
        $sent = @($w.ToCharArray() | ForEach-Object { "$_" }) + $tail
        Keys $sent; $tsf::Settle(200)
        $k, $e = $tsf::TakeTimes() -split '\|'
        $k = Ms $k; $e = Ms $e
        if ($k.Count -ne $sent.Count) { throw "the hook saw $($k.Count) keys for $($sent.Count) sent ($w)" }
        for ($i = 0; $i -lt $k.Count; $i++) {
          $next = if ($i + 1 -lt $k.Count) { $k[$i + 1] } else { $k[$i] + 1000 }
          $first = @($e | Where-Object { $_ -ge $k[$i] -and $_ -lt $next } | Select-Object -First 1)
          [pscustomobject]@{ key = $sent[$i]; ms = $(if ($first) { $first[0] - $k[$i] } else { -1 }) }
        }
      }
      function Pct($v, $q) { $s = @($v | Sort-Object); if ($s) { '{0:F1}' -f $s[[math]::Min($s.Count - 1, [math]::Round($q * ($s.Count - 1)))] } }
      # SebType's Chinese shows the pinyin in its own window, not in the field, so its keys change the
      # field less than Microsoft Pinyin's.
      $zh = $ime -in 'sebtype-zh', 'mspinyin'
      $words = if ($zh) { $pinyin } else { $romaji }
      $tail = if ($zh) { @('Escape') } else { @('space', 'Escape', 'Escape') }
      $tsf::Start(); $tsf::StartTiming()
      try {
        if (-not $tsf::Focus()) { throw "the text field did not get the keyboard focus ($(Front-Note 'the text field'))" }
        if ($ime -eq 'soak') {
          # 10+ minutes of mixed SebType typing, words committed, with memory every 30 s and any server restart.
          $minutes = [double](Get-Content "$out\soak-minutes.txt"); $end = (Get-Date).AddMinutes($minutes); $start = Get-Date
          $pids = @{}; $restarts = @(); $n = 0; $next = Get-Date
          while ((Get-Date) -lt $end) {
            $isZh = $n % 2 -eq 0
            Use $(if ($isZh) { 'sebtype-zh' } else { 'sebtype-ja' })
            if ($n % 20 -eq 0) { $tsf::Clear() }
            $w = if ($isZh) { $pinyin[$n % $pinyin.Count] } else { $romaji[$n % $romaji.Count] }
            Keys (@($w.ToCharArray() | ForEach-Object { "$_" }) + $(if ($isZh) { 'space' } else { 'space', 'Return' }))
            $n++
            foreach ($p in Get-Process sebtype-server -ErrorAction SilentlyContinue | Where-Object SessionId -EQ $session) {
              if ($pids[$p.Name] -and $pids[$p.Name] -ne $p.Id) { $restarts += "$($p.Name) $($pids[$p.Name]) -> $($p.Id) at $([int]((Get-Date) - $start).TotalSeconds) s" }
              $pids[$p.Name] = $p.Id
            }
            if ((Get-Date) -ge $next) { Mem "t$([int]((Get-Date) - $start).TotalSeconds)s"; $next = (Get-Date).AddSeconds(30) }
          }
          Out words $n; Out restarts $restarts.Count; $restarts | ForEach-Object { Out restart $_ }
          Out text_chars $tsf::Text().Length; Out text_sample ($tsf::Text().Substring(0, [math]::Min(40, $tsf::Text().Length)))
          Result $Typing PASS "$n words in $minutes min, $($restarts.Count) server restarts"
          return
        }
        Mem base
        Use $ime
        # Microsoft Pinyin on TCSBackEnd starts in English and ignores Open and a write of TSF's conversion
        # mode; Shift, its own 中/英 key, switches it.
        Out conversion_mode $tsf::Mode()  # TSF's: its low bit is 中 or かな
        if ($ime -eq 'mspinyin' -and -not ($tsf::Mode() -band 1)) { Keys Shift_L; $tsf::Settle(300); Out conversion_mode_after_shift $tsf::Mode() }
        $first = @(Word $words[0] $tail)
        Out first_key_ms ('{0:F1}' -f $first[0].ms)
        $all = @()
        foreach ($r in 1..3) { foreach ($w in $words) { $all += Word $w $tail } }
        $letters = @($all | Where-Object { $_.key -match '^[a-z]$' })
        $shown = @($letters | Where-Object { $_.ms -ge 0 } | ForEach-Object { $_.ms })
        Out keys $letters.Count; Out keys_changed_text $shown.Count
        Out key_p50_ms (Pct $shown 0.5); Out key_p95_ms (Pct $shown 0.95); Out key_max_ms (Pct $shown 1)
        if (-not $zh) {
          $conv = @($all | Where-Object { $_.key -eq 'space' -and $_.ms -ge 0 } | ForEach-Object { $_.ms })
          Out convert_p50_ms (Pct $conv 0.5); Out convert_p95_ms (Pct $conv 0.95); Out convert_max_ms (Pct $conv 1)
        }
        Mem typed
        # It was really this input method: one word committed gives Chinese or Japanese.
        $tsf::Clear(); Keys (@($words[0].ToCharArray() | ForEach-Object { "$_" }) + $(if ($zh) { 'space' } else { 'space', 'Return' })); $tsf::Settle(500)
        $text = $tsf::Text().Trim(); Out committed $text
        if ($text -notmatch '[぀-ヿ一-鿿]') { throw "$ime committed '$text', not Chinese or Japanese" }
        Result $Typing PASS "$($letters.Count) keys, p95 $(Pct $shown 0.95) ms; '$($words[0])' gave $text"
      } finally { $tsf::Stop() }
      return
    }
    # A language of SebType's in the test's own TSF text field (TsfHost.cs, started).
    function Field($lang) {
      if (-not $tsf::Focus()) {
        $why = Front-Note 'the text field'
        # A new field window, so one lost race doesn't fail every check after it (#562).
        $tsf::Stop(); $tsf::Start()
        if (-not $tsf::Focus()) { throw "the text field did not get the keyboard focus ($why), nor a new one ($(Front-Note 'a new text field'))" }
      } elseif ($tsf::LastFront) { $null = Front-Note 'the text field' }
      if ($lang -eq 'zh') { $tsf::Activate(0x804, [Guid]$Clsid, [Guid]$ZhProfile) } else { $tsf::Activate(0x411, [Guid]$Clsid, [Guid]$JaProfile) }
      $tsf::Settle(500); $tsf::Clear()
    }
    # The Picnic window with SebType's pig (#94, #162), as the Configurator writes it (sebtype.conf), at
    # 14 pt: pictures 162-sebtype-horizontal.png and -vertical.png, and the same for Japanese. 中文 also with the
    # Configurator's pinyin row off (#447): the pinyin is in the field's text, not in the window.
    $picnic = {
      $conf = "$env:APPDATA\SebType\sebtype.conf"
      New-Item -ItemType Directory -Force (Split-Path $conf) | Out-Null
      $sizes = foreach ($lang in 'zh', 'ja') {
        Field $lang
        if ($lang -eq 'ja') {  # Mozc starts with 日本語's first key: until it is ready, keys reach the field (#275)
          $null = Wait-Until 30 { $tsf::Clear(); Keys a; Start-Sleep 1; $kana = $tsf::Text() -match 'あ'; Keys Escape Escape; $kana }
        }
        if ($lang -eq 'zh') {  # the popup a Shift tap shows, a picture only (#205): 205-popup-zh.png
          Keys Shift_L; $null = $tsf::CandidateWindow("$out\205-popup-zh.png"); Keys Shift_L; Start-Sleep 2
        }
        foreach ($o in @('horizontal', 'vertical') + $(if ($lang -eq 'zh') { 'no-pinyin-row' })) {
          Set-Content -Encoding ascii $conf '[Candidates]', "Vertical=$([int]($o -eq 'vertical'))", 'FontSize=14', 'Picnic=1',
            "PinyinRow=$([int]($o -ne 'no-pinyin-row'))"
          $tsf::Clear(); if ($lang -eq 'zh') { TypeText 'nihao' } else { TypeText 'nihongo'; Keys space space }
          Start-Sleep 2
          $size = $tsf::CandidateWindow("$out\162-sebtype-$lang-$o.png"); $text = $tsf::Text(); Keys Escape Escape
          if (-not $size) { throw "no candidate window ($lang, $o), the field holds '$text', active $($tsf::Active())" }
          if ($lang -eq 'zh' -and ($text -match 'ni ?hao') -ne ($o -eq 'no-pinyin-row')) {
            throw "中文 $o`: the field holds '$text'"
          }
          "$lang $o $size"
        }
      }
      Remove-Item $conf
      $sizes -join ', '
    }
    if ($Typing -eq 'picnic') {
      $tsf::Start()
      try { Check 'picnic-window' $picnic } finally { $tsf::Stop() }
      return
    }
    # #489: a switch into 中文 or 日本語 types the language at once, whatever its Shift tap was left in, and the
    # button (the taskbar's input indicator) shows the language's normal icon: back from English's keyboard and
    # from SebType's other language, as Win+Space and the indicator switch profiles. 日本語's ア stays.
    function First($lang) {  # what a first word gives: 你 or ni in 中文, あ, ア or a in 日本語
      $tsf::Clear()
      if ($lang -eq 'zh') { TypeText 'ni '; Start-Sleep 1; $t = $tsf::Text().Trim() }
      else { Keys a; Start-Sleep 1; $t = $tsf::Text().Trim(); Keys Escape Escape }
      $tsf::Clear(); $t
    }
    function ButtonIcon { $p = "$out\489-icon.png"; $tsf::ButtonIcon($p); [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) }
    $quickEnglish = {
      # Rime deploys and Mozc starts with the first use: until then keys reach the field (#275).
      Field zh; if (-not (Wait-Until 90 { (First zh) -eq '你' })) { throw "中文 never typed 你 for ni" }
      Field ja; if (-not (Wait-Until 30 { (First ja) -match '[あア]' })) { throw "日本語 never typed kana for a" }
      if ((First ja) -eq 'あ') { Keys 'Alt_L+grave' }
      $want = @{ zh = '你'; ja = 'ア' }
      $seen = foreach ($pair in ('zh', 'en'), ('zh', 'ja'), ('ja', 'en'), ('ja', 'zh')) {
        $lang, $via = $pair
        Field $lang
        $normal = ButtonIcon
        Keys Shift_L; $quick = First $lang
        if ($quick -eq $want[$lang]) { throw "$lang`: the Shift tap didn't turn English on ('$quick')" }
        if ($via -eq 'en') { $tsf::ActivateLayout(0x409, '00000409'); $tsf::Settle(500) } else { Field $via }
        Field $lang
        $t = First $lang
        if ($t -ne $want[$lang]) { throw "$lang after $via and back gave '$t' (want $($want[$lang])), the Shift tap '$quick'" }
        if ((ButtonIcon) -ne $normal) { throw "$lang after $via and back: the button's icon isn't the one before the Shift tap" }
        "$lang via $via`: $t"
      }
      Keys 'Alt_L+grave'  # 日本語 back to あ
      $seen -join ', '
    }
    if ($Typing -eq 'quick-english') {
      $tsf::Start()
      try { Check 'quick-english-ends-on-switch' $quickEnglish } finally { $tsf::Stop() }
      return
    }
    $np = Start-Process notepad -PassThru
    try {
      $null = $np.WaitForInputIdle(10000)
      $h = $np.MainWindowHandle
      To-Front $h Notepad
      # Notepad's IME open status, conversion mode (its low bit: 中 1, English 0) and language at each change, in
      # ime-*.txt next to the keys sent, keys-*.txt: says when a flaky Chinese check found English (#129).
      $null = Start-Job -ArgumentList $h.ToInt64(), "$out\ime-$Typing.txt" {
        param($h, $file)
        Add-Type -Namespace P -Name W -MemberDefinition @'
[DllImport("imm32.dll")] public static extern System.IntPtr ImmGetDefaultIMEWnd(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessageW(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, System.IntPtr p);
[DllImport("user32.dll")] public static extern System.IntPtr GetKeyboardLayout(uint t);
'@
        $last = ''
        while ($true) {
          $ime = [P.W]::ImmGetDefaultIMEWnd([IntPtr]$h)
          $open = [P.W]::SendMessageW($ime, 0x283, [IntPtr]5, [IntPtr]0)  # WM_IME_CONTROL: IMC_GETOPENSTATUS
          $conv = [P.W]::SendMessageW($ime, 0x283, [IntPtr]1, [IntPtr]0)  # IMC_GETCONVERSIONMODE
          $lang = '{0:x4}' -f ([int64][P.W]::GetKeyboardLayout([P.W]::GetWindowThreadProcessId([IntPtr]$h, [IntPtr]::Zero)) -band 0xFFFF)
          $st = "open=$open conv=$conv lang=$lang"
          if ($st -ne $last) { Add-Content $file "$(Get-Date -f HH:mm:ss.fff) $st"; $last = $st }
          Start-Sleep -Milliseconds 20
        }
      }
      function Typed($s) { Keys 'Control_L+a' BackSpace; TypeText $s; Start-Sleep 1; $tsf::EditText($h).Trim() }
      function Lang { '{0:x4}' -f $tsf::Language($h) }
      function To-Language($id) {
        for ($i = 0; $i -lt 4 -and (Lang) -ne $id; $i++) { Keys 'Super_L+space'; Start-Sleep 1 }
        if ((Lang) -ne $id) { throw "Win+Space didn't reach $id (at $(Lang))" }
      }
      if ($Typing -eq 'all') {
        Check 'win-space-cycle' {
          To-Language '0409'
          # Each switch is done before the next press, as a person sees it done: the first to 中文 and 日本語
          # starts the server and the engine (1 to 2 s after an install), and Windows' switcher counts from
          # the language the app has finished switching to.
          $seen = foreach ($i in 1..3) {
            $was = Lang; Keys 'Super_L+space'; $null = Wait-Until 5 { (Lang) -ne $was }; $null = $np.WaitForInputIdle(5000); Lang
          }
          if (($seen -join ' ') -ne '0804 0411 0409') { throw "from EN, Win+Space gave $($seen -join ' → ') (0804 中, 0411 日, 0409 EN)" }
          'EN → 中 → 日 → EN'
        }
        Check 'chinese-pinyin' {
          To-Language '0804'
          Keys n i; Start-Sleep 3; Keys Escape  # the first key starts sebtype-server when none runs
          $t = Typed 'ranhou '
          if ($t -ne '然后') { throw "ranhou + Space gave '$t'" }
          $t
        }
        # #495: 中文's model puts 是的 first for shide, where Rime alone puts 使得. Its list comes after the keys, and the
        # text service shows it in the box before Space picks it; server.log says whether the model runs.
        Check 'chinese-model' {
          Keys 'Control_L+a' BackSpace; TypeText 'shide'; Start-Sleep 1; Keys space; Start-Sleep 1
          $t = $tsf::EditText($h).Trim()
          $log = Get-Content "$env:TEMP\rime.sebtype\server.log" -Encoding utf8 -ErrorAction SilentlyContinue | Select-String '中文: ' | Select-Object -Last 1
          if ($t -ne '是的') { throw "shide, a second, then Space gave '$t' (Rime alone: 使得); server.log: '$log'" }
          "$t, $($log -replace '^.*中文: ')"
        }
        # #478 with the model: a slip that reads as pinyin, its correction on page 1 once weighed (0.3 s after the keys).
        # The window can't be read here: each of the page's six is picked in turn, and one must be 又快又好.
        Check 'chinese-correction' {
          foreach ($k in 1..6) {
            Keys Escape 'Control_L+a' BackSpace; TypeText 'youkuaiyoouhao'; Start-Sleep 1; Keys "$k"
            $t = $tsf::EditText($h).Trim()
            if ($t -eq '又快又好') { return "又快又好 at $k" }
          }
          throw "youkuaiyoouhao: 又快又好 isn't one of page 1's six (picking 6 gave '$t')"
        }
        # #503: the model's guesses that read the letters otherwise (当, dang) come after Rime's first two pages when
        # its first is a dictionary word, as for dan; the readings that tell them come with the Chinese data. Each of
        # the two pages' twelve is picked in turn, and none may be 当.
        Check 'chinese-dan-before-dang' {
          if (-not (Test-Path "$env:APPDATA\Rime\sebtype_readings.txt")) { throw 'no sebtype_readings.txt in %APPDATA%\Rime' }
          $got = foreach ($i in 0..11) {
            Keys Escape 'Control_L+a' BackSpace; TypeText 'dan'  # the model's list comes within a key's 0.5 s
            Keys (@('equal') * [math]::Floor($i / 6) + "$($i % 6 + 1)")
            $tsf::EditText($h).Trim()
          }
          if ($got -contains '当') { throw "dan's first two pages hold 当: $($got -join ' ')" }
          $got -join ' '
        }
        Check 'chinese-shift-tap' {
          Keys 'Control_L+a' BackSpace; TypeText 'ni'; Keys Shift_L; TypeText 'ok'; Keys Shift_L; TypeText 'ranhou '
          Start-Sleep 1; $t = $tsf::EditText($h).Trim()
          if ($t -ne 'niok然后') { throw "ni Shift ok Shift ranhou gave '$t' (see ime-all.txt)" }
          $t
        }
        Check 'chinese-ctrl-shift-f' {
          Keys 'Control_L+a' BackSpace 'Control_L+Shift_L+f'; TypeText 'houlai '; Keys 'Control_L+Shift_L+f'; TypeText 'houlai '
          Start-Sleep 1; $t = $tsf::EditText($h).Trim()
          if ($t -ne '後來后来') { throw "houlai with 繁 then 简 gave '$t'" }
          $t
        }
        # SebType's librime (#133): a slip onto the key under i is corrected; the word typed right stays.
        Check 'chinese-typo-xkaoshi' {
          $typo = Typed 'xkaoshi '; $clean = Typed 'kaoshi '
          if ("$typo $clean" -ne '小时 考试') { throw "xkaoshi + Space gave '$typo', kaoshi + Space '$clean' (want 小时, 考试)" }
          "xkaoshi → $typo, kaoshi → $clean"
        }
        # #277: focus moving away mid-word (another window to the front, and back) types in the pinyin as its
        # letters, and the next word starts fresh.
        Check 'chinese-focus-out' {
          $other = Start-Process notepad -PassThru
          try {
            $null = $other.WaitForInputIdle(10000)
            Keys 'Control_L+a' BackSpace; TypeText 'nihao'; Start-Sleep 1
            To-Front $other.MainWindowHandle 'the second Notepad'
            Start-Sleep 1
            To-Front $h 'Notepad, back,'
            Start-Sleep 1; TypeText 'ni '; Start-Sleep 1; $t = $tsf::EditText($h).Trim()
            if ($t -ne 'nihao你') { throw "nihao, focus away and back, ni + Space gave '$t' (want nihao你)" }
            $t
          } finally { $other | Stop-Process -Force -ErrorAction SilentlyContinue }
        }
      }
      # Notepad gets Japanese only once it is committed (Enter). Japanese starts in English or あ.
      function Committed($s) { Keys 'Control_L+a' BackSpace; TypeText $s; Keys Return; Start-Sleep 1; $tsf::EditText($h).Trim() }
      Check "japanese-$Typing" {
        To-Language '0411'
        $t = Committed 'nihongo '
        if ($t -ne '日本語') { throw "nihongo + Space + Enter gave '$t'" }
        $t
      }
      if ($Typing -eq 'all') {
        # Alt+` is あ ⇄ ア, and the Shift tap the only way to English letters, where Alt+` switches nothing (#117).
        Check 'japanese-alt-grave' {
          Keys 'Alt_L+grave'; $kata = Committed 'a'
          Keys 'Alt_L+grave'; $hira = Committed 'a'
          Keys Shift_L; Keys 'Alt_L+grave'; $en = Committed 'a'
          Keys Shift_L; $back = Committed 'a'
          if ("$kata $hira $en $back" -ne 'ア あ a あ') { throw "Alt+`` gave '$kata', again '$hira'; Shift tap and Alt+`` '$en', Shift tap '$back'" }
          'あ → ア → あ; in English Alt+` stays English'
        }
        # Ctrl+Backspace right after a commit (#376): undone where Notepad gives the text before the caret (記者
        # goes and converts again, Escape gives きしゃ, which Enter commits), else nothing; never typed twice.
        Check 'japanese-undo-commit-notepad' {
          $first = Committed 'kisha '
          Keys 'Control_L+BackSpace' Escape Return; Start-Sleep 1; $t = $tsf::EditText($h).Trim()
          if ($first -ne '記者' -or $t -notin 'きしゃ', '記者') { throw "kisha + Space + Enter gave '$first', then Ctrl+Backspace, Escape and Enter '$t' (want きしゃ, or 記者 untouched)" }
          "$first → $(if ($t -eq '記者') { 'untouched: Notepad gave no text before the caret' } else { $t })"
        }
      }
    } finally { $np | Stop-Process -Force -ErrorAction SilentlyContinue; Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue }
    # The tray menu (#117) of the test's own TSF text field, where the input mode button can be
    # right-clicked: each language's one switch with its key, 简 → 繁 and あ → ア. A picture of each,
    # 117-menu-*.png.
    if ($Typing -eq 'all') {
      $tsf::Start()
      try {
        Check 'chinese-tray-menu' {
          Field zh
          function Typed($s) { $tsf::Clear(); TypeText $s; Start-Sleep 1; $tsf::Text().Trim() }
          $m = $tsf::TrayPopup($true, "$out\117-menu-zh-hans.png"); $hant = Typed 'houlai '
          $m2 = $tsf::TrayPopup($true, "$out\117-menu-zh-hant.png"); $hans = Typed 'houlai '
          if ($m -ne "简 → 繁`tCtrl+Shift+F" -or $hant -ne '後來' -or $m2 -ne "繁 → 简`tCtrl+Shift+F" -or $hans -ne '后来') {
            throw "menu '$m', then houlai gave '$hant'; menu '$m2', then '$hans'"
          }
          'menu 简 → 繁 (後來), then 繁 → 简 (后来)'
        }
        Check 'japanese-tray-menu' {
          Field ja
          function Typed($s) { $tsf::Clear(); TypeText $s; Keys Return; Start-Sleep 1; $tsf::Text().Trim() }
          $m = $tsf::TrayPopup($true, "$out\117-menu-ja-hira.png"); $first = Typed 'a'
          $m2 = $tsf::TrayPopup($true, "$out\117-menu-ja-kata.png"); $second = Typed 'a'
          # From the mode the earlier checks left in the apps' one core (ア after a failed japanese-alt-grave,
          # #222): each pick switches to what its menu said.
          $toKata = "あ → ア`tAlt+``"; $toHira = "ア → あ`tAlt+``"
          if (-not (($m -eq $toKata -and $first -eq 'ア' -and $m2 -eq $toHira -and $second -eq 'あ') -or
                    ($m -eq $toHira -and $first -eq 'あ' -and $m2 -eq $toKata -and $second -eq 'ア'))) {
            throw "menu '$m', then a gave '$first'; menu '$m2', then '$second'"
          }
          "menu $($m -replace '\t.*') ($first), then $($m2 -replace '\t.*') ($second)"
        }
        # In a field whose text TSF can read and change, Ctrl+Backspace right after a commit undoes it (#376).
        Check 'japanese-undo-commit' {
          Field ja
          TypeText 'kisha '; Keys Return; Start-Sleep 1; $first = $tsf::Text().Trim()
          Keys 'Control_L+BackSpace' Escape Return; Start-Sleep 1; $t = $tsf::Text().Trim()
          if ($first -ne '記者' -or $t -notin 'きしゃ', 'キシャ') { throw "kisha + Space + Enter gave '$first', then Ctrl+Backspace, Escape and Enter '$t' (want きしゃ)" }
          "$first → $t"
        }
        # A field that refuses the undo's edit, or grants it only later (the key's release meanwhile), keeps its
        # commit and the text around it, and Enter doesn't type it again.
        # The same where the app refuses the conversion's composition (the commit must not go before it can come
        # back).
        foreach ($case in 'refused', 'deferred', 'deferred-dropped', 'deferred-caret-moved', 'composition-refused') {
          Check "japanese-undo-$case" {
            Field ja
            $moved = $case -eq 'deferred-caret-moved'
            if ($moved) { $tsf::SetText('ab') }
            TypeText 'kisha '; Keys Return; Start-Sleep 1; $first = $tsf::Text().Trim()
            switch ($case) {
              'refused' { $tsf::ReadOnly = $true }
              'composition-refused' { $tsf::RefuseComposition = $true }
              default { $tsf::WriteLater = $true }
            }
            try {
              Keys 'Control_L+BackSpace'; Start-Sleep 1; $mid = $tsf::Text().Trim()
              if ($case -eq 'composition-refused' -and $tsf::Refused -eq 0) { throw 'the undo started no composition for the app to refuse' }
              if ($case -eq 'deferred-dropped') { $tsf::DropPending() }
              if ($moved) { $tsf::Caret(3) }
            } finally { $tsf::ReadOnly = $false; $tsf::WriteLater = $false; $tsf::RefuseComposition = $false }
            Start-Sleep 1
            if ($moved) { Keys Escape } else { Keys Return }
            Start-Sleep 1; $t = $tsf::Text().Trim(); $want = if ($moved) { 'ab記者' } else { '記者' }
            if ($first -ne $want -or $mid -ne $want -or $t -ne $want) { throw "kisha + Space + Enter gave '$first', then a $case Ctrl+Backspace '$mid', and Enter or Escape '$t' (want $want throughout)" }
            "$first, kept"
          }
        }
        # A commit over 32 UTF-16 units is undone too: 35 kana go and compose again, which Escape drops.
        Check 'japanese-undo-long-commit' {
          Field ja
          TypeText ('aiueo' * 7); Keys Return; Start-Sleep 1; $first = $tsf::Text().Trim()
          Keys 'Control_L+BackSpace' Escape Escape; Start-Sleep 1; $t = $tsf::Text().Trim()
          if ($first -ne ('あいうえお' * 7) -or $t -ne '') { throw "35 kana + Enter gave '$first', then Ctrl+Backspace and Escape '$t' (want nothing)" }
          "35 kana, undone"
        }
        Check 'picnic-window' $picnic
        Check 'quick-english-ends-on-switch' $quickEnglish
      } finally { $tsf::Stop() }
    }
  } catch { Result "typing-$Typing" FAIL $_.Exception.Message } finally {
    New-Item -ItemType File -Force "$out\typing-$Typing-done" | Out-Null
  }
  exit
}


# ==================================================== the driver, as the test user, elevated as Setup
if ($Driver) {
  Mark 'driver started: the test user is logged on'
  # Windows' toasts off for this new account (#562): its first logon brings one ("SoftEther VPN is now set
  # to run when you sign in") that keeps the front from the test's windows until someone clicks it.
  $toasts = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
  if (-not (Test-Path $toasts)) { New-Item -Force $toasts | Out-Null }
  Set-ItemProperty $toasts ToastEnabled 0 -Type DWord
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
      // No (IDNO 7) takes its N accelerator instead.
      int id = caption == "OK" ? 1 : caption == "Yes" ? 6 : caption == "No" ? 7 : 0;
      if (id == 0) return false;
      byte key = (byte)(id == 7 ? 0x4E : 0x0D);
      if (Cls(p) == "#32770") PostMessage(p, 0x0466, (IntPtr)id, IntPtr.Zero);
      else { Front(p); keybd_event(key, 0, 0, UIntPtr.Zero); keybd_event(key, 0, 2, UIntPtr.Zero); }
      return true;
    }
    // Fills the page's visible edit boxes, top to bottom (an input query page's fields), with WM_SETTEXT.
    public static void Fill(IntPtr p, string[] values) {
      var edits = Children(p).FindAll(h => Cls(h).IndexOf("Edit", StringComparison.OrdinalIgnoreCase) >= 0);
      edits.Sort((a, b) => { RECT ra, rb; GetWindowRect(a, out ra); GetWindowRect(b, out rb); return ra.T.CompareTo(rb.T); });
      if (edits.Count != values.Length) throw new ArgumentException(edits.Count + " edit boxes, want " + values.Length + ": " + Texts(p));
      for (int i = 0; i < values.Length; i++) { IntPtr r; SendMessageTimeout(edits[i], 0x000C, IntPtr.Zero, new StringBuilder(values[i]), 2, 2000, out r); }
    }
    // Picks item i of the page's n-th visible combo box, top to bottom, with CB_SETCURSEL: Inno reads a
    // combo box's ItemIndex back from it.
    public static void Select(IntPtr p, int n, int i) {
      var boxes = Children(p).FindAll(h => Cls(h).IndexOf("ComboBox", StringComparison.OrdinalIgnoreCase) >= 0);
      boxes.Sort((a, b) => { RECT ra, rb; GetWindowRect(a, out ra); GetWindowRect(b, out rb); return ra.T.CompareTo(rb.T); });
      if (n >= boxes.Count) throw new ArgumentException(boxes.Count + " combo boxes, want " + (n + 1) + ": " + Texts(p));
      IntPtr r; SendMessageTimeout(boxes[n], 0x014E, (IntPtr)i, null, 2, 2000, out r);
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
  # not the Weasel installer the SebType before #190 runs from its folder there.
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
  # Each run's logs: the machine's and this user's setup steps, and the server's Rime log.
  function Save-MachineLog($what) {
    Copy-Item "$App\setup.log" "$out\machine-$what.log" -ErrorAction SilentlyContinue
    Copy-Item "$env:LOCALAPPDATA\SebType\setup.log" "$out\user-$what.log" -ErrorAction SilentlyContinue
    # Rime's and the server's logs from every temporary folder: a Remote Desktop session's is Temp\<session>.
    New-Item -Force -ItemType Directory "$out\rime-log-$what" | Out-Null
    Get-ChildItem "$env:LOCALAPPDATA\Temp" -Depth 1 -Directory -Filter rime.sebtype -ErrorAction SilentlyContinue | ForEach-Object {
      Copy-Item $_.FullName "$out\rime-log-$what\$($_.Parent.Name)" -Recurse -ErrorAction SilentlyContinue
    }
  }
  # A Setup or uninstaller started here and left showing is stopped, with the temporary copy it runs.
  function Stop-Setup { Get-Process | Where-Object { $_.Path -like "$env:TEMP\*.tmp" -or $_.Name -like 'SebType-setup*' -or $_.Name -like 'unins000' } | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep 1 }
  # After Install, Inno closes and the installed Configurator shows the rest of setup (#471): its window,
  # read and driven through UI Automation (Slint's AccessKit tree), its pictures with $win::Shot.
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
  $uia = [Windows.Automation.AutomationElement]
  # The wizard's window, by its title (Finish opens the Configurator's own), once it has its size.
  function Wizard-Process {
    Get-Process sebtype-configurator -ErrorAction SilentlyContinue | Where-Object {
      $_.MainWindowTitle -in 'SebType Setup', 'SebType 安装向导' -and $uia::FromHandle($_.MainWindowHandle).Current.BoundingRectangle.Width -gt 200
    } | Select-Object -First 1
  }
  function Wizard-Handle($seconds = 60) {
    $h = Wait-Until $seconds { $p = Wizard-Process; if ($p) { $p.MainWindowHandle } }
    if (-not $h) { throw "no setup wizard window in $seconds s; windows: $($win::Visible())" }
    $h
  }
  # Finish closes the wizard and, with Open SebType Configurator on (the default), opens the Configurator.
  function Wizard-Finish($finish) {
    $p = Wizard-Process
    Ui-Click $finish
    if (-not $p.WaitForExit(30000)) { throw "$finish left the wizard open" }
    $opened = Configurator-Process
    if (-not $opened) { Stop-Wizard; throw "$finish closed the wizard but opened no Configurator" }
    $opened
  }
  function Configurator-Process { Wait-Until 30 { Get-Process sebtype-configurator -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -in 'SebType Configurator', 'SebType 设置' } | Select-Object -First 1 } }
  # The Configurator's language switches once it has read Windows' list (they show off, disabled, until then;
  # a switch tells UI Automation when it is disabled).
  function Configurator-Langs($p) {
    $r = Wait-Until 60 {
      $all = $uia::FromHandle($p.MainWindowHandle).FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
      $sw = @($all | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.CheckBox' -and $_.Current.Name -in 'English', '中文', '日本語' })
      if ($sw.Count -eq 3 -and ($sw | Where-Object { $_.Current.IsEnabled })) {
        ($sw | ForEach-Object {
          $t = $null
          if ($_.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$t)) { "$($_.Current.Name)=$(if ($t.Current.ToggleState -eq 'On') { 'on' } else { 'off' })" }
          else { "$($_.Current.Name)=? (patterns: $(($_.GetSupportedPatterns() | ForEach-Object ProgrammaticName) -join ','))" }
        }) -join ' '
      }
    }
    if (-not $r) { throw 'the Configurator showed no language switches ready in 60 s' }
    $r
  }
  # SebType's English and 日本語 only: an account's own other input methods (Windows' 中文 with Microsoft
  # Pinyin on a Chinese Windows) stay, and the Configurator shows a language on wherever Windows lists it.
  function Check-EnJa($p, $what) {
    $l = Languages
    $shown = Configurator-Langs $p
    $win::Shot($p.MainWindowHandle, "$out\73-configurator-langs-$what.png")
    if ($l -notlike "en-US[[]0409:00000409[]]*" -or $l -notlike "* ja[[]$JaTip[]]*" -or $l -like "*$ZhTip*") { throw "input methods $l after English and 日本語 only" }
    $zh = if ($l -like '*zh-Hans-CN*') { 'on' } else { 'off' }
    # In Win+Space order, as Windows lists them.
    $sorted = [string[]]($shown -split ' '); [Array]::Sort($sorted, [StringComparer]::Ordinal)
    if (($sorted -join ' ') -ne "English=on 中文=$zh 日本語=on") { throw "the Configurator shows $shown for $l" }
    "$l; the Configurator: $shown"
  }
  function Wizard-Shot($name) { $h = Wizard-Handle; Start-Sleep 1; $win::Shot($h, "$out\73-$name.png"); $h }
  function Stop-Wizard { Get-Process sebtype-configurator -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1 }
  function Ui-All { $uia::FromHandle((Wizard-Handle)).FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition) }
  function Ui-Texts { (@(Ui-All) | ForEach-Object { $_.Current.Name } | Where-Object { $_ }) -join ' | ' }
  # By name, and by kind where a label shares it (a field's caption above it): Button, Edit.
  function Ui-Find-Now($name, $type) {
    @(Ui-All) | Where-Object { $_.Current.Name -like $name -and (-not $type -or $_.Current.ControlType.ProgrammaticName -eq "ControlType.$type") } | Select-Object -First 1
  }
  function Ui-Find($name, $seconds = 30, $type) {
    $e = Wait-Until $seconds { Ui-Find-Now $name $type }
    if (-not $e) { throw "no '$name' $type in the wizard in $seconds s; it shows: $(Ui-Texts)" }
    $e
  }
  function Ui-Click($name) { (Ui-Find $name 30 Button).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); Start-Sleep -Milliseconds 300 }
  function Ui-Fill($name, $value) { (Ui-Find $name 30 Edit).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($value) }
  # Setup as a person runs it in $lang (its default languages), until the wizard's Common settings page.
  # $tasks: the languages page's ticks before Install (Inno's /TASKS, as clicking them would leave them).
  function Install-Then-Wizard($lang, $what, $tasks = 'en,zh,ja') {
    $next, $langs, $install, $common = @{ en = 'Next', 'Your languages', 'Install', 'Common settings'; zh = '下一步', '你的语言', '安装', '常用设置' }[$lang]
    Start-Process $setup "/LANG=$lang", "/TASKS=`"$tasks`"", "/LOG=`"$out\setup-$what.log`""
    $h = Window TWizardForm
    Page $h $next; Click $h $next; Page $h $langs  # the form shows before its buttons
    Click $h $install
    if (-not (Wait-Until 900 { -not (Get-Process | Where-Object { $_.Path -like "$env:TEMP\is-*" }) })) { throw 'Setup did not close after Install' }
    Save-MachineLog $what
    $null = Ui-Find $common 60
  }
  function Silent($what, [string[]]$arguments, $exe = $setup) {
    $p = Start-Process $exe -PassThru -ArgumentList (@('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$out\setup-$what.log`"") + $arguments)
    if (-not $p.WaitForExit(900000)) { throw "Setup ($what) ran over 15 minutes" }
    Save-MachineLog $what
    if ($p.ExitCode) { throw "Setup ($what) exited with $($p.ExitCode) (logs: out\setup-$what.log, out\machine-$what.log, out\user-$what.log)" }
  }
  # The uninstaller finishes in its copy, %TEMP%\is-*-uninstall.tmp\_unins.tmp.
  function Uninstalled { -not (Test-Path $AppKey) -and -not (Get-Process | Where-Object { $_.Path -like "$env:TEMP\*-uninstall.tmp\*" }) }
  function Silent-Uninstall($what) {
    Check "$what-uninstall" {
      Start-Process "$App\unins000.exe" '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
      if (-not (Wait-Until 600 { Uninstalled })) { throw 'the silent uninstall did not finish in 10 minutes' }
      'silent'
    }
  }
  # 'all' takes about 5 minutes (#503's dan check added 40 s); past the limit the driver goes on under it.
  function Typing($phase, [int]$seconds = 420) {
    Set-Content "$out\typing-phase.txt" $phase
    Start-ScheduledTask SebType-setup-typing
    if (-not (Wait-Until $seconds { Test-Path "$out\typing-$phase-done" })) { Result "typing-$phase" FAIL "the typing checks took over $seconds s" }
    Get-Content -Encoding utf8 "$out\typing-$phase-results.txt" | Where-Object { $_ } | ForEach-Object { Add-Content -Encoding utf8 $results $_; Write-Host $_ }
  }

  # Windows Server opens Server Manager at an admin's logon, in front of whatever the test shows, unless
  # the machine's setting or policy says not to (TCSBackEnd's does: no 45 s wait for nothing there).
  $quiet = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\ServerManager -ErrorAction SilentlyContinue).DoNotOpenServerManagerAtLogon -eq 1 -or
    (Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager -ErrorAction SilentlyContinue).DoNotOpenAtLogon -eq 1
  if (-not $quiet -and (Wait-Until 45 { Get-Process ServerManager -ErrorAction SilentlyContinue })) {
    Mark 'Server Manager opened'
    Start-Sleep 5; Get-Process ServerManager | Stop-Process -Force
  }
  Mark "Server Manager closed (or 45 s without it, or set not to open: $quiet)"

  # How this account is before SebType: English and Chinese (Microsoft Pinyin), as on a Chinese PC.
  $ll = New-WinUserLanguageList en-US
  $ll.Add((New-Object Microsoft.InternationalSettings.Commands.WinUserLanguage zh-Hans-CN))
  Set-WinUserLanguageList $ll -Force
  # SebType's and Weasel's entries in the Start menu (Weasel's own folder must never be there, #192).
  $startMenu = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
  function Start-Menu { (Get-ChildItem $startMenu -ErrorAction SilentlyContinue | Where-Object Name -match '^(SebType|小狼毫|Weasel)').Name -join ', ' }
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
      startMenu = Start-Menu
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
  function Check-Installed($round, [string[]]$langs, [string]$order, [int]$pageSize = 6) {
    Check "$round-installed" {
      $missing = @("$App\sebtype-configurator.exe", "$App\setup.ps1", "$App\unins000.exe", "$App\sebtype.ico" | Where-Object { -not (Test-Path $_) })
      $entry = Get-ItemProperty $AppKey
      if ($missing) { throw "missing: $($missing -join ', ')" }
      if ($entry.DisplayName -ne 'SebType' -or $entry.DisplayIcon -notlike '*sebtype.ico') { throw "Apps lists '$($entry.DisplayName)' with icon $($entry.DisplayIcon)" }
      if ((Test-Path $WeaselKey) -or (Mozc-Installed)) { throw "Weasel ($(Test-Path $WeaselKey)) or Mozc ($(Mozc-Installed)) is installed" }
      $missing = @("$App\sebtype-server.exe", "$App\sebtype.dll", "$App\x86\sebtype.dll", "$App\rime.dll", "$App\sebtype-mozc.dll" | Where-Object { -not (Test-Path $_) })
      if ($missing) { throw "missing: $($missing -join ', ')" }
      $dll = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\CLSID\$Clsid\InprocServer32" -ErrorAction SilentlyContinue).'(default)'
      if ($dll -ne "$App\sebtype.dll") { throw "the text service is registered as '$dll'" }
      $menu = Start-Menu
      if ($menu -notmatch '^SebType[^,]*\.lnk$') { throw "the Start menu has '$menu', want only SebType's settings shortcut" }
      "$(Split-Path -Leaf $setup) in $App; SebType's text service registered, no Weasel or Mozc; Start menu: $menu"
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
        $name = (Get-Item "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$Clsid\LanguageProfile\0x00000804\$ZhProfile").GetValue('Description')
        $patch = Get-Content "$env:APPDATA\Rime\rime_ice.custom.yaml" -Encoding utf8 -ErrorAction SilentlyContinue
        $pages = @(Get-Content "$env:APPDATA\Rime\default.custom.yaml" -Encoding utf8 -ErrorAction SilentlyContinue) -match '^  menu/page_size:'
        if ($name -ne '中文') { throw "the Chinese input method reads '$name'" }
        if (-not (Test-Path "$env:APPDATA\Rime\build\rime_ice.schema.yaml") -or -not ($patch -match 'schema/name: 中文') -or -not ($patch -match 'sebtype_typo/keyboard: pc')) { throw 'the Chinese data is not deployed with SebType''s patches' }
        if ($pages.Count -ne 1 -or $pages[0] -notmatch "^  menu/page_size: $pageSize\b") { throw "default.custom.yaml's page size: '$($pages -join ' | ')', want $pageSize (#163)" }
        "named 中文; rime-ice and 白霜 deployed with the 中文 name, PC typo correction and $pageSize candidates per page"
      }
    }
    if ('ja' -in $langs) {
      Check "$round-japanese" {
        $name = (Get-Item "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$Clsid\LanguageProfile\0x00000411\$JaProfile").GetValue('Description')
        $db = "$env:USERPROFILE\AppData\LocalLow\Mozc\config1.db"
        if ($name -ne '日本語') { throw "the Japanese input method reads '$name'" }
        if (-not (Test-Path $db) -or -not ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($db)) -match '(?s)IMEOn.*InputModeSwitchKanaType')) { throw 'no SebType keymap in config1.db' }
        'named 日本語, with SebType''s keymap (Shift tap for English, Alt+` for ア)'
      }
    }
  }
  $learned = "$env:APPDATA\Rime\rime_ice.userdb\SEBTYPE-TEST", "$env:USERPROFILE\AppData\LocalLow\Mozc\SEBTYPE-TEST"

  try {
    if ($Only -eq 'compare') {
      # SebType next to Microsoft Pinyin and Microsoft Japanese IME (#54): a silent install of all three
      # languages, what it left in the Start menu (#53 D10), each input method typed in a process of its
      # own, 10+ minutes of mixed SebType typing, a silent uninstall.
      Check 'compare-install' { Silent compare-install @(); 'silent, all languages' }
      Check 'compare-start-menu' {
        $menus = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
        $items = @(Get-ChildItem $menus -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName -replace '^.*\\Programs\\' } | Where-Object { $_ -match 'SebType|Weasel|小狼毫|Rime|Mozc' })
        Set-Content -Encoding utf8 "$out\compare-start-menu.txt" $items
        if ($items -match '小狼毫|Weasel|Rime') { throw "Weasel's own Start menu entries are installed: $($items -join ', ')" }
        "$($items -join ', ')"
      }
      # Microsoft's input methods back next to SebType's, in each language's list.
      $ll = New-WinUserLanguageList en-US
      $ll.Add((New-Object Microsoft.InternationalSettings.Commands.WinUserLanguage zh-Hans-CN)); $ll[1].InputMethodTips.Clear(); $ll[1].InputMethodTips.Add($ZhTip); $ll[1].InputMethodTips.Add('0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}')
      $ll.Add((New-Object Microsoft.InternationalSettings.Commands.WinUserLanguage ja)); $ll[2].InputMethodTips.Clear(); $ll[2].InputMethodTips.Add($JaTip); $ll[2].InputMethodTips.Add('0411:{03B5835F-F03C-411B-9CE2-AA23E1171E36}{A76C93D9-5523-4E90-AAFA-4DB112F9AC76}')
      Set-WinUserLanguageList $ll -Force -WarningAction SilentlyContinue
      Result compare-languages INFO (Languages)
      foreach ($ime in $CompareImes -split ',') { Typing "compare-$ime" }
      if ($SoakMinutes) {
        Set-Content "$out\soak-minutes.txt" $SoakMinutes
        Typing compare-soak ($SoakMinutes * 60 + 300)
      }
      Silent-Uninstall compare
      return
    }
    if ($Only -in 'not-ready', 'private') {
      Check "$Only-install" { Silent "$Only-install" @(); 'silent, all languages' }
      Typing $Only 900
      Silent-Uninstall $Only
      return
    }
    if ($Only -eq 'update') {
      # The daily update check (#422): Setup schedules it for the person, test-update.ps1 runs it against a
      # release served here, and the uninstall removes it with its link.
      Check 'update-install' { Silent update-install @(); 'silent, all languages' }
      Check 'update-task-scheduled' {
        $t = Get-ScheduledTask 'SebType update check' -ErrorAction SilentlyContinue
        if (-not $t) { throw "no 'SebType update check' task" }
        $a = $t.Actions[0]
        if ($a.Execute -ne "$App\sebtype-configurator.exe" -or $a.Arguments -ne '--check-updates' -or $t.Principal.UserId -notmatch "\b$user$" -or
          -not $t.Settings.StartWhenAvailable -or $t.Triggers[0].DaysInterval -ne 1) {
          throw "the task runs '$($a.Execute) $($a.Arguments)' as $($t.Principal.UserId), daily: $($t.Triggers[0].DaysInterval), when available: $($t.Settings.StartWhenAvailable)"
        }
        "daily as $($t.Principal.UserId), and at the next chance after a missed day"
      }
      Typing update 300
      # The update's admin side as update-user.ps1 runs it elevated (the installed start-setup.ps1, here
      # without UAC: this runs elevated already): Setup only from its checked copy where only admins can write, and
      # none of the person's steps; then its own side as the test user, not elevated (update-user.ps1).
      function Start-Copy($sha) {
        $said = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$App\start-setup.ps1" -Setup $setup -Sha $sha -Log "$out\setup-update-copy.log" 2>&1
        $LASTEXITCODE, (($said | Out-String).Trim())
      }
      Check 'update-setup-refused-when-changed' {
        $code, $said = Start-Copy ('0' * 64)
        if ($code -ne 90) { throw "a SHA-256 that isn't the setup's: exit $code, $said" }
        if (Get-ChildItem "$App\updates" -Directory -ErrorAction SilentlyContinue) { throw "a copy left in $App\updates" }
        "exit 90: $said"
      }
      Check 'update-setup-from-protected-copy' {
        $userLog = "$env:LOCALAPPDATA\SebType\setup.log"
        $before = (Get-Item $userLog).Length
        $code, $said = Start-Copy (Get-FileHash -Algorithm SHA256 $setup).Hash
        if ($code -ne 0 -or $said -notmatch '^started (\d+) (.+)$') { throw "exit $code, $said" }
        $id, $copy = [int]$Matches[1], $Matches[2]
        if (-not $copy.StartsWith("$App\updates\update-")) { throw "Setup ran from $copy" }
        $acl = (Get-Acl (Split-Path $copy)).Access | Where-Object { $_.FileSystemRights -match 'Write|Modify|FullControl' -and $_.AccessControlType -eq 'Allow' } |
          ForEach-Object { $_.IdentityReference.Value } | Where-Object { $_ -notmatch 'Administrators|SYSTEM|TrustedInstaller|CREATOR OWNER' }
        if ($acl) { throw "$copy's folder is writable by $($acl -join ', ')" }
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($p -and -not $p.WaitForExit(900000)) { throw 'Setup ran over 15 minutes' }
        if (-not (Select-String -Quiet -Path "$out\setup-update-copy.log" -Pattern 'Installation process succeeded')) { throw "Setup didn't finish: out\setup-update-copy.log" }
        if ((Get-Item $userLog).Length -ne $before) { throw "Setup ran the person's steps: $userLog changed" }
        "Setup ran from $copy (only admins can write there) and upgraded SebType, without the person's steps"
      }
      # Remove the task update-install made while elevated, so update-user must recreate it as the unelevated test user.
      Unregister-ScheduledTask 'SebType update check' -Confirm:$false -ErrorAction SilentlyContinue
      Typing update-user 600
      Silent-Uninstall update
      Check 'update-task-removed' {
        $left = @(if (Get-ScheduledTask 'SebType update check' -ErrorAction SilentlyContinue) { 'the task' }) +
          @(if (Test-Path 'HKLM:\SOFTWARE\Classes\sebtype-configurator') { 'the sebtype-configurator: link' }) +
          @(if (Test-Path "$App\updates") { "$App\updates" })
        if ($left) { throw "left: $($left -join ', ')" }
        'the task, the link and the copies gone'
      }
      return
    }
    if ($Only -in 'forget', 'learned') {
      Check "$Only-install" { Silent "$Only-install" @(); 'silent, all languages' }
      Typing $Only 900
      Silent-Uninstall $Only
      return
    }
    if ($Only -eq 'quick-english') {
      # Only the Shift tap's English ending on a switch (#489): a silent install, the check, a silent uninstall.
      Check 'quick-english-install' { Silent quick-english-install @(); 'silent, all languages' }
      Typing quick-english
      Silent-Uninstall quick-english
      return
    }
    if ($Only -eq 'picnic') {
      # Only the Picnic window (#162): a silent install, its pictures, a silent uninstall.
      Check 'picnic-install' { Silent picnic-install @(); 'silent' }
      Typing picnic
      Silent-Uninstall picnic
      return
    }
    if ($Only -eq 'upgrade') {
      # The update from the SebType before #190 (Weasel and Mozc): that one silently with all languages and
      # learned words, then this one over it.
      $old = (Get-ChildItem "$root\old\SebType-setup-*.exe" | Select-Object -First 1).FullName
      Check 'upgrade-old-install' {
        Silent upgrade-old-install @() $old
        if (-not (Test-Path $WeaselKey) -or -not (Mozc-Installed)) { throw "$(Split-Path -Leaf $old) installed no Weasel or Mozc" }
        "$(Split-Path -Leaf $old): Weasel and Mozc"
      }
      $learned | ForEach-Object { New-Item -Force $_ | Out-Null }
      Check 'upgrade-install' { Silent upgrade-install @(); 'silent, over the SebType with Weasel and Mozc' }
      Check-Installed upgrade en, zh, ja "en-US[0409:00000409] zh-Hans-CN[$ZhTip] ja[$JaTip]"
      Check 'upgrade-keeps-learned-words' {
        $gone = @($learned | Where-Object { -not (Test-Path $_) })
        if ($gone) { throw "gone: $($gone -join ', ')" }
        $old = @("HKLM:\SOFTWARE\Microsoft\CTF\TIP\$WeaselClsid", "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$MozcClsid", "HKCU:\Software\Microsoft\CTF\TIP\$WeaselClsid", "HKCU:\Software\Microsoft\CTF\TIP\$MozcClsid" | Where-Object { Test-Path $_ })
        if ($old) { throw "left: $($old -join ', ')" }
        'Rime and Mozc learned words kept; Weasel''s and Mozc''s registrations gone'
      }
      Typing all
      Silent-Uninstall upgrade
      Check-AsBefore upgrade
      return
    }
    if ($Only -eq 'common-page') {
      # This account's Common settings as the Configurator reads them (what the wizard's page shows and saves)
      function Common-Settings {
        $f = "$out\common-settings.txt"
        $p = Start-Process -PassThru -Wait "$App\sebtype-configurator.exe" '--common-settings', 'get', "`"$f`""
        if ($p.ExitCode) { throw "sebtype-configurator --common-settings get exited with $($p.ExitCode)" }
        ((Get-Content $f) | Where-Object { $_ }) -join ' '
      }
      Check 'common-page-defaults' {
        # English and 日本語 only: the wizard must not lose the languages page's choice (#471).
        Install-Then-Wizard zh common-page 'en,ja'
        $null = Wizard-Shot '4-common-zh'
        # A new account: 简体, Picnic, Vertical and 6 (#471: Picnic unless the account chose before).
        $want = 'traditional=0 page-size=6 picnic=1 vertical=1'
        $now = Common-Settings
        if ($now -ne $want) { throw "a new account's settings: $now, want $want" }
        "$now; Inno closed after Install and the Configurator's wizard showed 常用设置"
      }
      Check 'common-page-next-saves' {
        foreach ($t in '繁體', '系统样式', '横排', '8') { Ui-Click $t }
        # The theme previews at once (#471): the plain wizard, before Next saves anything.
        $null = Wizard-Shot '4-common-zh-changed'
        Ui-Click '下一步'; $null = Ui-Find '账号同步'
        $want = 'traditional=1 page-size=8 picnic=0 vertical=0'
        $now = Common-Settings
        if ($now -ne $want) { throw "after 繁體, 系统样式, 横排 and 8: $now, want $want" }
        $now
      }
      Check 'common-page-finish' {
        # The title waits for the page's own check of SebType's text service in the language list (#445).
        Ui-Click '跳过'; $null = Ui-Find 'SebType 装好啦！'
        $null = Wizard-Shot '6-ready-zh'
        $script:c = Wizard-Finish '完成'
        'Skip leads to the ready page; 完成 closes the wizard and opens the Configurator'
      }
      Check 'common-page-languages' {
        try { Check-EnJa $c wizard } finally { Stop-Wizard }
      }
      # Each page in both themes and both languages, for comparing with Linux's (#471).
      Check 'common-page-pictures' {
        foreach ($lang in 'en', 'zh') { foreach ($step in 2, 3, 4) { foreach ($theme in 'picnic', 'system') {
          Start-Process "$App\sebtype-configurator.exe" '--setup-after-install', '--lang', $lang, '--step', $step, '--theme', $theme
          $null = Wizard-Shot "wizard-$lang-$step-$theme"
          Stop-Wizard
        } } }
        '12 pictures: steps 2-4, Picnic and System style, English and 中文'
      }
      # The last page's guided step (#445): with SebType's 日本語 taken off the language list (as a person could
      # in Settings), the page says what is left, in both themes and languages; its Add button puts it back
      # and the page turns ready by itself.
      Check 'common-page-ready-step' {
        $l = Get-WinUserLanguageList
        foreach ($x in $l) { if ($x.LanguageTag -eq 'ja') { [void]$x.InputMethodTips.Remove($JaTip) } }
        Set-WinUserLanguageList $l -Force -WarningAction SilentlyContinue
        if ((Languages) -like "*$JaTip*") { throw "SebType's 日本語 stayed in $(Languages)" }
        foreach ($lang in 'en', 'zh') { foreach ($theme in 'picnic', 'system') {
          Start-Process "$App\sebtype-configurator.exe" '--setup-after-install', '--lang', $lang, '--step', 4, '--theme', $theme
          $null = Ui-Find @{ en = 'Almost ready'; zh = '快好啦' }[$lang] 30
          $null = Wizard-Shot "wizard-$lang-4-$theme-step"
          if ($lang -eq 'en' -or $theme -eq 'picnic') { Stop-Wizard }
        } }
        try {
          Ui-Click '添加'
          $null = Ui-Find 'SebType 装好啦！' 60
          $null = Wizard-Shot 'wizard-zh-4-system-step-done'
        } finally { Stop-Wizard }
        if ((Languages) -notlike "* ja[[]$JaTip*") { throw "添加 left $(Languages)" }
        "Almost ready without SebType's 日本語; 添加 gave back $(Languages)"
      }
      Silent-Uninstall 'common-page'
      Check 'common-page-silent-languages' {
        Silent common-page-silent @('/TASKS="en,ja"')
        Start-Process "$App\sebtype-configurator.exe"
        $c = Configurator-Process; if (-not $c) { throw 'the Configurator opened no window' }
        try { "silent /TASKS=en,ja: $(Check-EnJa $c silent)" } finally { Stop-Wizard }
      }
      Silent-Uninstall 'common-page-silent'
      return
    }
    if ($Only -eq 'sync-page') {
      $syncUser = 'sebtype-sync-test'
      $syncPassword = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
      $server = $null
      try {
        Check 'sync-page-shown' {
          Install-Then-Wizard en sync-page
          $null = Wizard-Shot '4-common-en'
          Ui-Click 'Next'; $null = Ui-Find 'Account sync'
          # The server runs from a copy of Setup's Python, there by now: the uninstall removes {app}\python.
          Copy-Item -Recurse "$App\python" "$out\python"
          $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $listener.Start()
          $script:port = $listener.LocalEndpoint.Port; $listener.Stop()
          $null = $syncPassword | & "$out\python\python.exe" -I "$root\sebtype_sync.py" adduser --data "$out\sync-server" --password-stdin $syncUser
          $script:server = Start-Process "$out\python\python.exe" -PassThru -NoNewWindow -RedirectStandardError "$out\sync-server.log" `
            -ArgumentList '-I', "`"$root\sebtype_sync.py`"", 'serve', '--data', "`"$out\sync-server`"", '--port', $port
          if (-not (Wait-Until 30 { try { (New-Object Net.Sockets.TcpClient '127.0.0.1', $port).Close(); $true } catch { $false } })) { throw "no server on port $port" }
          'after the install, with sebtype_sync.py on localhost and a throwaway login'
        }
        $url = "http://127.0.0.1:$port"
        function Fill-Login($u, $p) { Ui-Fill 'Server address' $url; Ui-Fill 'Username' $u; Ui-Fill 'Password' $p }
        Check 'sync-page-wrong-password' {
          Fill-Login $syncUser 'not-the-password'
          Ui-Click 'Sign in & continue'
          $null = Ui-Find 'Wrong username or password' 60
          $null = Ui-Find 'Save anyway & continue' 10 Button
          $null = Wizard-Shot '5-sync-wrong-password'
          # Changing a field takes the failed check (and Save anyway) back.
          Ui-Fill 'Password' 'not-the-password-2'
          $null = Ui-Find 'Sign in & continue' 10 Button
          'Wrong username or password and Save anyway & continue in the page; a field change clears both'
        }
        Check 'sync-page-unreachable' {
          # A closed port: one the system just handed out and took back.
          $closed = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $closed.Start(); $cp = $closed.LocalEndpoint.Port; $closed.Stop()
          Ui-Fill 'Server address' "http://127.0.0.1:$cp"
          Ui-Click 'Sign in & continue'
          $null = Ui-Find "Can't reach the server. Check the address and your network" 60
          $null = Wizard-Shot '5-sync-unreachable'
          "Can't reach the server for a closed port"
        }
        Check 'sync-page-connected' {
          Fill-Login $syncUser $syncPassword
          Ui-Click 'Sign in & continue'
          $null = Ui-Find 'Connected. The server and login work' 60
          $null = Wizard-Shot '6-sync-connected'
          # Saving then needs Credential Manager, which this driver's elevated token from Task Scheduler
          # doesn't have (as in -Only sync): the page says why and stays.
          $r = Wait-Until 30 { if (Ui-Find-Now 'SebType is ready!') { 'ready' } elseif (Ui-Find-Now '*ERROR_NO_SUCH_LOGON_SESSION*') { 'unsaved' } }
          if ($r -eq 'unsaved') {
            $null = Wizard-Shot '6-sync-connected-not-saved'
            Result 'sync-page-saves-login' INFO 'not checkable here: the check passed (the tick showed) but saving needs Credential Manager, which the elevated driver''s token lacks (ERROR_NO_SUCH_LOGON_SESSION)'
            Ui-Click 'Skip'; $null = Ui-Find 'SebType is ready!'
          } elseif ($r -eq 'ready') {
            $j = Get-Content "$env:LOCALAPPDATA\SebType\sync.json" -Raw -Encoding utf8 | ConvertFrom-Json
            if (-not $j.enabled -or $j.server -ne $url) { throw "sync.json after the page: $($j | ConvertTo-Json -Compress)" }
          } else { throw "after Connected, neither the ready page nor a save error: $(Ui-Texts)" }
          $null = Wizard-Shot '6-sync-connected-finish'
          $null = Wizard-Finish 'Finish'; Stop-Wizard
          if ($r -eq 'ready') { 'the tick, the ready page, sync on for the local server in sync.json' }
          else { 'the tick: the check passed; the save is INFO above; Skip, the ready page' }
        }
        Silent-Uninstall 'sync-page'
      } finally {
        Stop-Wizard
        if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -Recurse -Force "$out\python", "$out\sync-server" -ErrorAction SilentlyContinue
      }
      return
    }
    if ($Only -eq 'sync') {
      Check 'sync-install' { Silent sync-install @(); 'silent, all languages' }
      # The server runs from a copy of Setup's Python: the uninstaller removes {app}\python, which it holds.
      Copy-Item -Recurse "$App\python" "$out\python"
      $python = "$out\python\python.exe"
      function Run-Exe($exe, [string[]]$arguments, [string]$stdin) {  # its output; throws on a failure
        $psi = New-Object Diagnostics.ProcessStartInfo $exe, (($arguments | ForEach-Object { "`"$_`"" }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $psi.RedirectStandardOutput = $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.WriteLine($stdin); $p.StandardInput.Close()
        $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit(300000)) { Stop-Process -Id $p.Id -Force; throw "$(Split-Path -Leaf $exe) $($arguments[0..1] -join ' ') ran over 5 minutes" }
        if ($p.ExitCode) { throw "$(Split-Path -Leaf $exe) $($arguments[0..1] -join ' '): exit $($p.ExitCode) $e$o".Trim() }
        $o.Trim()
      }
      function Py([string[]]$arguments, [string]$stdin) { Run-Exe $python (@('-I', '-X', 'utf8') + $arguments) $stdin }
      function Helper { Py (@("$root\test-sync.py") + $args) $syncPassword }
      $syncUser = 'sebtype-sync-test'
      $syncPassword = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
      $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $listener.Start()
      $port = $listener.LocalEndpoint.Port; $listener.Stop()
      $url = "http://127.0.0.1:$port"
      $syncJson = "$env:LOCALAPPDATA\SebType\sync.json"
      $rime = "$env:APPDATA\Rime"
      $mozcDb = "$env:USERPROFILE\AppData\LocalLow\Mozc\user_dictionary.db"
      function Rime-Sync {  # Rime's 用户资料同步 in SebType's server, as the Configurator runs it
        $p = Start-Process -PassThru "$App\sebtype-server.exe" '/sync'
        if (-not $p.WaitForExit(120000)) { Stop-Process -Id $p.Id -Force; throw "Rime's sync took over 2 minutes" }
      }
      # A script as this admin, not elevated, in a one-off task as the Configurator's tray runs: the elevated
      # driver's token from Task Scheduler has an empty Credential Manager (its cmdkey /list lists none).
      # $ScriptText is the script's text, $Answer a file it writes before it ends.
      function Plain([string]$ScriptText, [string]$Answer, [int]$Seconds = 120) {
        $f = "$out\plain-$(Get-Random)"
        [IO.File]::WriteAllText("$f.ps1", $ScriptText)
        Register-ScheduledTask SebType-setup-plain -Force `
          -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$f.ps1`"") `
          -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited) | Out-Null
        try {
          Start-ScheduledTask SebType-setup-plain
          if (-not (Wait-Until $Seconds { (Test-Path $Answer) -and (Get-ScheduledTask SebType-setup-plain).State -eq 'Ready' })) {
            throw "not elevated: nothing in $Answer after $Seconds s"
          }
        } finally { Unregister-ScheduledTask SebType-setup-plain -Confirm:$false }
      }
      $server = $loginLeft = $null
      try {
        Check 'sync-server' {
          $null = Py @("$root\sebtype_sync.py", 'adduser', '--data', "$out\sync-server", '--password-stdin', $syncUser) $syncPassword
          $script:server = Start-Process $python -PassThru -NoNewWindow -RedirectStandardError "$out\sync-server.log" `
            -ArgumentList '-I', "`"$root\sebtype_sync.py`"", 'serve', '--data', "`"$out\sync-server`"", '--port', $port
          if (-not (Wait-Until 30 { try { (New-Object Net.Sockets.TcpClient '127.0.0.1', $port).Close(); $true } catch { $false } })) { throw "no server on $url" }
          "sebtype_sync.py on $url with Setup's Python, a throwaway login"
        }
        Check 'sync-login-in-credential-manager' {
          # The login is made and Credential Manager listed in the one plain task: the elevated driver sees none.
          $login = "$out\save-login"
          [IO.File]::WriteAllText("$login-in.txt", "$url`n$syncUser`n$syncPassword`n")
          $save = @"
Get-Content -Raw '$login-in.txt' | & '$App\sebtype-configurator.exe' --save-login 2>&1 | Out-File -Encoding utf8 '$login-out.txt'
`$exit = `$LASTEXITCODE
cmdkey /list 2>&1 | Out-File -Encoding utf8 '$login-cred.txt'
Set-Content '$login-code.txt' `$exit
"@
          try { Plain $save "$login-code.txt" } finally { Remove-Item "$login-in.txt" -ErrorAction SilentlyContinue }  # a throwaway password
          $code = (Get-Content "$login-code.txt" -Raw -ErrorAction SilentlyContinue)
          if ("$code".Trim() -ne '0') { throw "--save-login, not elevated: exit '$code' $(Get-Content "$login-out.txt" -Raw -ErrorAction SilentlyContinue)" }
          # Not cmdkey /list:'login.SebType sync': its space reaches cmdkey as two arguments, and its labels are localized.
          $cred = Get-Content "$login-cred.txt" -Raw -ErrorAction SilentlyContinue
          if ($cred -notmatch 'target=.*login\.SebType sync') { throw "no 'login.SebType sync' in Credential Manager: $cred" }
          $saved = Get-Content $syncJson -Raw -Encoding utf8
          if ($saved.Contains($syncPassword)) { throw 'the password is in sync.json' }
          if (-not ($saved | ConvertFrom-Json).enabled) { throw "sync is off after the first login: $saved" }
          if (-not (Get-ScheduledTask -TaskName 'SebType sync' -ErrorAction SilentlyContinue)) { throw 'no SebType sync task' }
          'the password only in Credential Manager (login.SebType sync), sync on, the SebType sync task made'
        }
        $device = Helper device $rime
        Check 'sync-made-up-words' {
          # A word Rime learned on this PC: Rime takes in its own snapshot, which then goes, so only its
          # learned words hold the word until the task's sync writes the snapshot again.
          $snap = (Helper seed-rime $rime) + '\rime_ice.userdb.txt'
          Rime-Sync; Remove-Item $snap; Rime-Sync
          if (-not ((Get-Content $snap -Raw -Encoding utf8) -match '莫福姬')) { throw 'Rime did not take in the PC''s word 莫福姬' }
          Remove-Item $snap
          $null = Helper add-mozc $mozcDb 'もふてすと' 'モフ試験語'
          $null = Helper put-phone $url $syncUser
          "this PC ($device): 莫福姬 in Rime's learned words, モフ試験語 in Mozc; another device's 普噜莫 and プルモ試験語 on the server"
        }
        Check 'sync-scheduled-task' {
          Start-ScheduledTask -TaskName 'SebType sync'
          $j = Wait-Until 300 { $x = Get-Content $syncJson -Raw -Encoding utf8 | ConvertFrom-Json; if ($x.status -ne 'not-yet') { $x } }
          if (-not $j) { throw 'the task did not sync in 5 minutes' }
          if ($j.status -ne 'synced') { throw "the task's sync: $($j.status)" }
          'the SebType sync task ran sebtype-configurator --sync: synced'
        }
        # #377: the task also syncs when Windows connects to a network. The network is never touched: a
        # NetworkProfile event 10000 ("connected") written into its log stands in, and only when no other
        # task that is on listens for it, so nothing else reacts.
        Check 'sync-network-trigger' {
          $t = (Get-ScheduledTask -TaskName 'SebType sync').Triggers
          $connect = $t | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskEventTrigger' -and
            $_.Subscription -match 'Microsoft-Windows-NetworkProfile/Operational' -and $_.Subscription -match 'EventID=10000' }
          if (-not $connect) { throw "no network-connect trigger: $($t | ForEach-Object { $_.CimClass.CimClassName })" }
          if (-not ($t | Where-Object { $_.Repetition.Interval -eq 'PT30M' })) { throw 'no half-hourly trigger' }
          $others = Get-ScheduledTask | Where-Object { $_.TaskName -ne 'SebType sync' -and $_.State -ne 'Disabled' -and
            ($_.Triggers | Where-Object { $_.Subscription -match 'NetworkProfile' }) } | ForEach-Object { $_.TaskName }
          if ($others) { throw "not fired: other tasks listen for NetworkProfile events: $($others -join ', ')" }
          $before = (Get-Content $syncJson -Raw -Encoding utf8 | ConvertFrom-Json).at
          Start-Sleep 1  # sync.json keeps whole seconds
          New-WinEvent -ProviderName Microsoft-Windows-NetworkProfile -Id 10000 `
            -Payload @('SebType test', 'SebType test', [guid]::NewGuid(), 0, 1, 0) -WarningAction SilentlyContinue
          $j = Wait-Until 120 { $x = Get-Content $syncJson -Raw -Encoding utf8 | ConvertFrom-Json; if ($x.at -gt $before) { $x } }
          if (-not $j) { throw 'no sync within 2 minutes of the network-connect event' }
          if ($j.status -ne 'synced') { throw "the network trigger's sync: $($j.status)" }
          "network-connect trigger (NetworkProfile 10000, $($connect.Delay) delay) and the half-hourly one; the event ran the sync: synced"
        }
        Check 'sync-pc-words-reach-server' {
          (Helper server-has $url $syncUser $device rime_ice.userdb.txt '莫福姬'), (Helper server-has $url $syncUser $device mozc_dictionary.txt 'モフ試験語') -join '; '
        }
        Check 'sync-other-device-reaches-pc' { Helper pc-has $rime $mozcDb }
        Check 'sync-uninstall-syncs-first-and-cleans-up' {
          $null = Helper add-mozc $mozcDb 'さいごて' 'サイゴ試験語'  # only the uninstall's sync can take this one up
          $before = (Get-Content $syncJson -Raw -Encoding utf8 | ConvertFrom-Json).at
          Start-Sleep 1  # sync.json keeps whole seconds
          Start-Process "$App\unins000.exe" '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$out\uninstall-sync.log`""
          # Once the uninstall's sync is done, this holds the schedule lock as a Configurator's startup
          # refresh would while it remakes the task: the uninstall waits for it (#401). Then as one stuck
          # holding it: the uninstall goes on after 30 s, removes sync anyway and says so in its log.
          $deadline = (Get-Date).AddSeconds(300)
          while (-not (Test-Path $syncJson) -or (Get-Content $syncJson -Raw -Encoding utf8 | ConvertFrom-Json).at -le $before) {
            if ((Get-Date) -gt $deadline) { throw 'the uninstall did not sync in 5 minutes' }
            Start-Sleep -Milliseconds 50
          }
          $lock = [IO.File]::Open("$env:LOCALAPPDATA\SebType\schedule.lock", 'OpenOrCreate', 'ReadWrite', 'ReadWrite, Delete')
          try {
            while ($true) { try { $lock.Lock(0, 1); break } catch { Start-Sleep -Milliseconds 20 } }
            if (-not (Test-Path $syncJson)) { throw 'the uninstall took the schedule lock first: nothing checked' }
            Start-Sleep 10
            if (-not (Get-ScheduledTask -TaskName 'SebType sync' -ErrorAction SilentlyContinue)) { throw 'the uninstall removed the task while a Configurator held the schedule lock' }
            if (-not (Wait-Until 600 { Uninstalled })) { throw 'the silent uninstall did not finish in 10 minutes with the schedule lock held' }
          } finally { $lock.Close() }
          $log = Get-Content "$env:LOCALAPPDATA\SebType\setup.log" -Raw -Encoding utf8 -ErrorAction SilentlyContinue
          if ($log -notmatch 'user: warning: sync removed without its schedule lock \(held for 30 s\).*Left: nothing') {
            throw "no warning about the schedule lock in the uninstall's log: $("$log".Substring([Math]::Max(0, "$log".Length - 600)))"
          }
          $synced = Helper server-has $url $syncUser $device mozc_dictionary.txt 'サイゴ試験語'
          $files = [int](Helper server-files $url $syncUser)
          if ($files -lt 4) { throw "the server keeps $files files, not this PC's and the other device's 4" }
          $left = @()
          if (Get-ScheduledTask -TaskName 'SebType sync' -ErrorAction SilentlyContinue) { $left += 'the SebType sync task' }
          Plain "cmdkey /list 2>&1 | Out-File -Encoding utf8 '$out\after-uninstall.txt'" "$out\after-uninstall.txt"
          if (-not (Test-Path "$out\after-uninstall.txt")) { throw 'no Credential Manager listing after the uninstall' }
          $script:loginLeft = (Get-Content "$out\after-uninstall.txt" -Raw) -match 'target=.*login\.SebType sync'
          $left += @('sync.json', 'sync.lock', 'schedule.lock', 'sebtype_sync.py' | Where-Object { Test-Path "$env:LOCALAPPDATA\SebType\$_" })
          if ($left) { throw "left after uninstall: $($left -join ', ')" }
          "synced first ($synced), the server's $files files kept; waited for the schedule lock, went on after 30 s and said so; task and sync's files gone"
        }
        # The uninstall runs elevated from this driver, whose token from Task Scheduler (a logon without a
        # password) can read Credential Manager but not change it, so setup.ps1's CredDeleteW can't remove
        # the login here; UAC's elevated token, a real uninstall's, comes from the password logon and can.
        # A test-made password logon instead leaves the test user's profile loaded until a reboot. So
        # here: setup.ps1's own call, from this account's logon token.
        if ($loginLeft -eq $false) { Result 'sync-uninstall-removes-login' PASS 'the login is gone from Credential Manager' } elseif ($loginLeft) {
          try {
            Plain @"
Add-Type -Namespace T -Name C -MemberDefinition '[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CredDeleteW(string target, uint type, uint flags);'
`$ok = [T.C]::CredDeleteW('login.SebType sync', 1, 0); `$e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
Set-Content '$out\cred-delete.txt' "`$ok `$e"
"@ "$out\cred-delete.txt"
            $r = (Get-Content "$out\cred-delete.txt" -Raw).Trim()
            if ($r -notmatch '^True') { throw "the login stayed, and setup.ps1's CredDeleteW from the logon token failed too: $r" }
            Result 'sync-uninstall-removes-login' INFO ("not checkable here: the driver's elevated token can't change Credential Manager, " +
              "so the uninstall left the login; setup.ps1's CredDeleteW('login.SebType sync', CRED_TYPE_GENERIC) removed it from this account's logon token")
          } catch { Result 'sync-uninstall-removes-login' FAIL $_.Exception.Message }
        }
      } finally {
        if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -Recurse -Force "$out\python", "$out\sync-server" -ErrorAction SilentlyContinue
      }
      return
    }
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
      # Inno closes after the copy; the Configurator's wizard takes over (#471).
      if (-not (Wait-Until 900 { -not (Get-Process | Where-Object { $_.Path -like "$env:TEMP\is-*" }) })) { throw 'Setup did not close after Install' }
      $null = Ui-Find 'Common settings' 60; $null = Wizard-Shot '4-common'; Ui-Click 'Next'
      $null = Ui-Find 'Account sync'; $null = Wizard-Shot '4-sync'; Ui-Click 'Skip'
      $null = Ui-Find 'SebType is ready!'; $null = Wizard-Shot '4-finish'
      $null = Wizard-Finish 'Finish'; Stop-Wizard
      'welcome, languages, installing, then the wizard: common settings, sync (skipped), ready'
    }
    Save-MachineLog round1-install; Stop-Setup
    Check-Installed round1 en, zh, ja "en-US[0409:00000409] zh-Hans-CN[$ZhTip] ja[$JaTip]"
    Typing all
    # Rime per key on the installed librime and data (perf-rime.exe from the librime build; #133). A timing
    # check: only in the final performance run (Decisions #2, 2026-11-11).
    if ($PerfRun) {
    Check 'round1-rime-p95' {
      if (-not (Test-Path "$root\perf-rime.exe")) { throw 'no perf-rime.exe next to test.ps1' }
      # The child's stderr says why when it says nothing else; 'Stop' here would drop it.
      $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      $said = powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root\perf-rime.ps1" -Root $App -Rime "$App\rime-data.zip" 2>&1
      $code = $LASTEXITCODE
      $ErrorActionPreference = $eap
      $line = "$(@($said) | Where-Object { "$_" -like '*rime-p95-under-16ms*' } | Select-Object -Last 1)"
      # Fails on a nonzero exit, and on no such line: an empty result's -notlike 'PASS *' isn't true.
      if ($code -or $line -notlike 'PASS *') { throw "perf-rime.ps1 (librime in '$App') exit $code said: $($said -join ' | ')" }
      $line -replace '^PASS rime-p95-under-16ms: '
    }
    }
    # What it learned stays through an upgrade: a mark in each learned-words folder.
    $learned | ForEach-Object { New-Item -Force $_ | Out-Null }
    Check 'round1-upgrade' { Silent round1-upgrade @(); 'silent, same languages' }
    Check-Installed round1-upgraded en, zh, ja "en-US[0409:00000409] zh-Hans-CN[$ZhTip] ja[$JaTip]"
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
    Check-Installed round2 zh, ja "zh-Hans-CN[$ZhTip] ja[$JaTip] en-US[0409:00000409]"
    New-Item -Force $learned[1] | Out-Null
    # A page size of the user's own (the Configurator's line) stays through the upgrade (#163).
    $defaults = "$env:APPDATA\Rime\default.custom.yaml"
    [IO.File]::WriteAllLines($defaults, @(@(Get-Content $defaults -Encoding utf8) -replace '^  menu/page_size: .*', '  menu/page_size: 8'))
    Check 'round2-upgrade-drops-japanese' { Silent round2-upgrade @('/TASKS="en,zh"'); 'silent, English and 中文' }
    Check-Installed round2-upgraded en, zh "en-US[0409:00000409] zh-Hans-CN[$ZhTip]" 8
    Check 'round2-japanese-words-deleted' { if (Test-Path $learned[1]) { throw "kept: $($learned[1])" }; 'Japanese left out: its learned words gone' }
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
elseif (-not (Test-Path "$root\TsfHost.cs")) { "no TsfHost.cs in $root (pc/windows/setup)" }
elseif ((Get-Process -Id $PID).SessionId -eq 0) { 'in session 0 (services): start it from a logged-on session' }
elseif ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) { 'not Windows Server: the test needs a second Remote Desktop session' }
elseif (Get-LocalUser $user -ErrorAction SilentlyContinue) { "a local user $user exists already" }
elseif ((Test-Path $AppKey) -or (Test-Path $WeaselKey) -or (Mozc-Installed)) { 'SebType, Weasel or Mozc is installed already: the test starts without them' }
elseif ($Only -eq 'upgrade' -and -not (Get-ChildItem "$root\old\SebType-setup-*.exe" -ErrorAction SilentlyContinue)) { "no old\SebType-setup-*.exe in $root (the SebType before #190)" }
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
      -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\test.ps1`" -$mode $mode$(if ($PerfRun) { ' -PerfRun' })$(if ($Only) { " -Only $Only -SoakMinutes $SoakMinutes -CompareImes $CompareImes" })" }
  Register-ScheduledTask SebType-setup-driver -Action (& $run Driver) -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) `
    -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest) -Force | Out-Null
  # The typing runs as apps do, not elevated; the driver starts it, its phase in out\typing-phase.txt.
  $typingAction = New-ScheduledTaskAction -Execute powershell.exe -WorkingDirectory $root `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"& '$root\test.ps1' -Typing (Get-Content '$out\typing-phase.txt')`""
  Register-ScheduledTask SebType-setup-typing -Action $typingAction `
    -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited) -Force | Out-Null
  New-Item -ItemType Directory -Force (Split-Path $rdp) | Out-Null
  Set-Content $rdp $user, $password
  Mark 'test user made, its logon written'
  if (-not (Wait-Until 3000 { Test-Path "$out\driver-done" })) {
    Result driver FAIL $(if (Test-Path "$out\driver-results.txt") { 'the run took over 50 minutes' } else { "no Remote Desktop logon of $user in 50 minutes" })
  }
} catch { Result admin FAIL $_.Exception.Message } finally {
  Mark 'driver done'
  Remove-Item -Recurse (Split-Path $rdp) -ErrorAction SilentlyContinue
  'SebType-setup-driver', 'SebType-setup-typing', 'SebType sync' | ForEach-Object { Unregister-ScheduledTask $_ -Confirm:$false -ErrorAction SilentlyContinue }
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
Mark 'test user removed'
Get-Content -Encoding utf8 "$out\driver-results.txt" -ErrorAction SilentlyContinue | Where-Object { $_ } | ForEach-Object { Add-Content -Encoding utf8 $results $_; Write-Host $_ }

Check 'machine-as-before' {
  $left = @($App, $AppKey, $WeaselKey, 'HKLM:\SOFTWARE\SebType', "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$Clsid", "Registry::HKEY_CLASSES_ROOT\CLSID\$Clsid", "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$WeaselClsid", "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$MozcClsid", 'HKLM:\SOFTWARE\WOW6432Node\Rime' | Where-Object { Test-Path $_ })
  if (Mozc-Installed) { $left += 'Mozc' }
  if ($left) { throw "left: $($left -join ', ')" }
  'SebType, its text service, and any Weasel or Mozc gone'
}
# Windows' entries for this admin of the text services the run registered: not SebType's own, removed.
$extra = @((Get-ChildItem HKCU:\Software\Microsoft\CTF\TIP -ErrorAction SilentlyContinue).PSChildName | Where-Object { $_ -notin ($adminBefore.tipKeys -split ',') })
$extra | ForEach-Object { Remove-Item -Recurse -Force "HKCU:\Software\Microsoft\CTF\TIP\$_" }
if ($extra) { Result admin-text-service-entries INFO "Windows had added $($extra -join ', ') for this admin; removed" }
Check 'admin-input-as-before' {
  if ((Languages) -ne $adminBefore.languages) { throw "this admin's input methods are $(Languages), were $($adminBefore.languages)" }
  'this admin''s input methods untouched'
}
foreach ($c in 'language-follows-windows', 'welcome-zh', 'welcome-ja', 'round1-install-pages', 'win-space-cycle', 'chinese-pinyin', 'chinese-focus-out', 'japanese-all', 'japanese-alt-grave', 'chinese-tray-menu', 'japanese-tray-menu', 'picnic-window', 'quick-english-ends-on-switch',
  'round1-upgrade', 'japanese-after-language-change', 'round1-uninstall-pages', 'round1-everything-as-before', 'round2-upgrade-drops-japanese', 'round2-everything-as-before') {
  if (-not $Only -and -not (Select-String -Quiet -SimpleMatch " $c" $results)) { Result $c SKIP 'did not run' }
}
exit [int][bool](Select-String -Quiet '^(FAIL|SKIP) ' $results)
