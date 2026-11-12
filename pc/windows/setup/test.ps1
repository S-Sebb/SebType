<#
Tests SebType's installer (#73) in the background on a Windows Server: install, typing, upgrade and
uninstall, twice, and a picture of every installer page. One command, run elevated in a logged-on
session (test-tcsbackend.sh does that on TCSBackEnd and opens the Remote Desktop session it needs):

    powershell -File C:\sebtype-setup-test\test.ps1

The folder holds this script, TsfHost.cs (../mozc), windows.rs (the Configurator's Picnic scheme), perf-rime.ps1 and perf-rime.exe (../, from the
Weasel build) and SebType-setup-*.exe. The test creates a local
admin user, sebtype-test, and runs everything as that user in a Remote Desktop session of its own, so
nobody's own input settings change, then removes the user and its profile:

1. The installer's pictures: the language dialog (which must preselect Windows' own display language),
   the welcome page in English, 中文 and 日本語, then a whole install in English with the uninstaller.
2. Round 1 (that install, all languages): what it installed and set, typing in Notepad with real keys
   (rdp-keys.py: Win+Space EN → 中 → 日, pinyin, the Shift tap, Ctrl+Shift+F, typo correction, Japanese),
   Rime's time per key (p95 ≤ 10 ms, only with -PerfRun: the final performance run, #54) and Chinese's
   tray menu in a TSF text field of the test's own (TsfHost.cs, with a picture of the menu) and its
   Picnic candidate window with the pig (pictures, horizontal and vertical), a silent
   upgrade that keeps learned words, Japanese still working after the language list changes, then the
   uninstall: everything back as before, learned words gone.
3. Round 2, all silent: install with Chinese and Japanese only (no English), upgrade to English and
   Chinese (Japanese and its learned words go), uninstall.

-Only picnic: only a silent install, the Picnic window's pictures and a silent uninstall (#162).
-Only sync: only sync with your own server (#180): a silent install; sebtype_sync.py serving on this PC's
   localhost, run by a copy of the Python Setup packs, with a throwaway login; the login saved as the
   Configurator's Save does (sebtype-configurator --save-login: Credential Manager, the task); made-up
   words of this PC's (Rime, Mozc) and of another device (test-sync.py); the "SebType sync" task run
   once; then a silent uninstall, which must sync first and remove the task, the login and sync's files.
   The folder also holds sebtype_sync.py (sync-server/) and test-sync.py.
-Only compare: the final performance run's comparison (#54): a silent install, what it put in the Start
   menu, then SebType's Chinese and Japanese, Microsoft Pinyin and Microsoft Japanese IME each typed in
   the TSF text field and timed per key, with their memory; 10+ minutes of mixed SebType typing
   (-SoakMinutes, default 12; 0 for none); a silent uninstall. -CompareImes picks the input methods. Numbers in out\compare-*.txt.

Results: one line per check in out\setup-results.txt, pictures in out\*.png; exit 0 only if all pass.
-Driver and -Typing are the test user's own parts (elevated, and not elevated as apps run).
#>
param([string]$Driver, [string]$Typing, [switch]$PerfRun, [string]$Only, [int]$SoakMinutes = 12, [string]$CompareImes = 'weasel,weasel-inline,mspinyin,mozc,msime')
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
  if ($Typing) { Add-Content "$out\keys-$Typing.txt" "$(Get-Date -f HH:mm:ss.fff) CHECK $name" }  # with ime-*.txt (#129)
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
    # -Only compare (#54): SebType's Chinese and Japanese next to Microsoft's, typed the same way into
    # the test's own TSF text field, one fresh process per input method so each one's in-process share of
    # memory is its own. Per key: from the key entering the session (a low-level hook) to the input
    # method's first change of the field's text (its composition). Words end with Escape (Mozc and
    # Microsoft Japanese: Space converts first), so nothing is learned. compare-<ime>.txt: key=value lines.
    if ($Typing -like 'compare-*') {
      $ime = $Typing -replace '^compare-'
      $IMES = @{
        weasel = 0x804, $WeaselClsid, '{3D02CAB6-2B8E-4781-BA20-1C9267529467}'
        'weasel-inline' = 0x804, $WeaselClsid, '{3D02CAB6-2B8E-4781-BA20-1C9267529467}'
        mspinyin = 0x804, '{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}', '{FA550B04-5AD7-411F-A5AC-CA038EC515D7}'
        mozc = 0x411, $MozcClsid, '{186F700C-71CF-43FE-A00E-AACB1D9E6D3D}'
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
        Get-Process | Where-Object { $_.SessionId -eq $session -and $_.Name -match '^(WeaselServer|mozc_server|mozc_renderer|mozc_broker|ChsIME|IMEJP.*|TextInputHost|InputApp|ctfmon)$' } |
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
      $zh = $ime -in 'weasel', 'weasel-inline', 'mspinyin'
      # Weasel shows what is typed in its own window, not in the field, so only the first key of a word
      # changes the field. weasel-inline puts it in the field (inline preedit, for this test's host
      # alone), as Microsoft Pinyin does, so its keys time like Microsoft's.
      if ($ime -eq 'weasel-inline') {
        [IO.File]::WriteAllLines("$env:APPDATA\Rime\weasel.custom.yaml", [string[]]@('patch:', '  app_options/powershell.exe: {inline_preedit: true}'))
        $p = [Diagnostics.Process]::Start((Join-Path (Get-ItemProperty HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel).WeaselRoot WeaselDeployer.exe), '/deploy')
        if (-not $p.WaitForExit(120000)) { throw "Weasel's redeploy took over 2 minutes" }
      }
      $words = if ($zh) { $pinyin } else { $romaji }
      $tail = if ($zh) { @('Escape') } else { @('space', 'Escape', 'Escape') }
      $tsf::Start(); $tsf::StartTiming()
      try {
        if (-not $tsf::Focus()) { throw 'the text field did not get the keyboard focus' }
        if ($ime -eq 'soak') {
          # 10+ minutes of mixed SebType typing, words committed, with memory every 30 s and any server restart.
          $minutes = [double](Get-Content "$out\soak-minutes.txt"); $end = (Get-Date).AddMinutes($minutes); $start = Get-Date
          $pids = @{}; $restarts = @(); $n = 0; $next = Get-Date
          while ((Get-Date) -lt $end) {
            $isZh = $n % 2 -eq 0
            Use $(if ($isZh) { 'weasel' } else { 'mozc' })
            if ($n % 20 -eq 0) { $tsf::Clear() }
            $w = if ($isZh) { $pinyin[$n % $pinyin.Count] } else { $romaji[$n % $romaji.Count] }
            Keys (@($w.ToCharArray() | ForEach-Object { "$_" }) + $(if ($isZh) { 'space' } else { 'space', 'Return' }))
            $n++
            foreach ($p in Get-Process WeaselServer, mozc_server -ErrorAction SilentlyContinue | Where-Object SessionId -EQ $session) {
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
    # Chinese in the test's own TSF text field (TsfHost.cs, started), after Weasel's first key there.
    function Weasel-Field {
      if (-not $tsf::Focus()) { throw 'the text field did not get the keyboard focus' }
      $tsf::Activate(0x804, [Guid]$WeaselClsid, [Guid]'{3D02CAB6-2B8E-4781-BA20-1C9267529467}')
      $tsf::Clear(); TypeText 'ni'; Start-Sleep 1; Keys Escape
    }
    # The Picnic window with SebType's pig (#94, #162), as the Configurator writes it (its scheme from
    # windows.rs), at 14 pt, in Weasel-Field: pictures 162-weasel-horizontal.png and -vertical.png.
    $picnic = {
      $rs = (((Get-Content "$root\windows.rs" -Encoding utf8 -Raw) -split 'const PICNIC_SCHEME')[1] -split '\];')[0]
      $scheme = [regex]::Matches($rs, '"(    [^"]+)"') | ForEach-Object { $_.Groups[1].Value }
      $deployer = Join-Path (Get-ItemProperty HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel).WeaselRoot WeaselDeployer.exe
      $sizes = foreach ($o in 'horizontal', 'vertical') {
        [IO.File]::WriteAllLines("$env:APPDATA\Rime\weasel.custom.yaml", [string[]](@('patch:',
          "  style/horizontal: $($o -eq 'horizontal')".ToLower(), '  style/font_point: 14', '  style/color_scheme: sebtype_picnic',
          '  style/sebtype_logo: true', '  preset_color_schemes/sebtype_picnic:') + $scheme))
        # Not Start-Process: its trailing space makes the deployer open its settings window (setup.ps1)
        $p = [Diagnostics.Process]::Start($deployer, '/deploy')
        if (-not $p.WaitForExit(60000)) { Stop-Process -Id $p.Id -Force; throw "Weasel's redeploy ($o) took over a minute" }
        $tsf::Clear(); TypeText 'nihao'; Start-Sleep 2
        $size = $tsf::CandidateWindow("$out\162-weasel-$o.png"); Keys Escape
        if (-not $size) { throw "no candidate window ($o)" }
        "$o $size"
      }
      $sizes -join ', '
    }
    if ($Typing -eq 'picnic') {
      $tsf::Start()
      try { Check 'chinese-picnic-window' { Weasel-Field; & $picnic } } finally { $tsf::Stop() }
      return
    }
    $np = Start-Process notepad -PassThru
    try {
      $null = $np.WaitForInputIdle(10000)
      $h = $np.MainWindowHandle
      if (-not $tsf::Foreground($h)) { throw 'Notepad did not come to the front' }
      # Notepad's IME open status, conversion mode (its low bit: Weasel's 中 1, English 0) and language at each change, in
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
      }
      # Notepad gets Japanese only once it is committed (Enter). Japanese starts in English or あ.
      function Committed($s) { Keys 'Control_L+a' BackSpace; TypeText $s; Keys Return; Start-Sleep 1; $tsf::EditText($h).Trim() }
      Check "japanese-$Typing" {
        To-Language '0411'
        if ((Committed 'a') -eq 'a') { Keys Shift_L }
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
      }
    } finally { $np | Stop-Process -Force -ErrorAction SilentlyContinue; Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue }
    # The tray menu (#117) of the test's own TSF text field, where the input mode button can be
    # right-clicked: Chinese's one switch, 简 → 繁, with its key. Japanese's is in mozc/test.ps1. A picture
    # of each, 117-menu-*.png.
    if ($Typing -eq 'all') {
      $tsf::Start()
      try {
        Check 'chinese-tray-menu' {
          Weasel-Field
          function Field($s) { $tsf::Clear(); TypeText $s; Start-Sleep 1; $tsf::Text().Trim() }
          $m = $tsf::TrayPopup($true, "$out\117-menu-zh-hans.png"); $hant = Field 'houlai '
          $m2 = $tsf::TrayPopup($true, "$out\117-menu-zh-hant.png"); $hans = Field 'houlai '
          if ($m -ne "简 → 繁`tCtrl+Shift+F" -or $hant -ne '後來' -or $m2 -ne "繁 → 简`tCtrl+Shift+F" -or $hans -ne '后来') {
            throw "menu '$m', then houlai gave '$hant'; menu '$m2', then '$hans'"
          }
          'menu 简 → 繁 (後來), then 繁 → 简 (后来)'
        }
        Check 'chinese-picnic-window' $picnic
      } finally { $tsf::Stop() }
    }
  } catch { Result "typing-$Typing" FAIL $_.Exception.Message } finally {
    Copy-Item "$env:TEMP\rime.weasel" "$out\weasel-log-$Typing" -Recurse -ErrorAction SilentlyContinue  # Weasel's own log (#129)
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
  function Stop-Setup { Get-Process | Where-Object { $_.Path -like "$env:TEMP\*.tmp" -or $_.Name -like 'SebType-setup*' -or $_.Name -like 'unins000' } | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep 1 }
  function Silent($what, [string[]]$arguments) {
    $p = Start-Process $setup -PassThru -ArgumentList (@('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$out\setup-$what.log`"") + $arguments)
    if (-not $p.WaitForExit(900000)) { throw "Setup ($what) ran over 15 minutes" }
    Save-MachineLog $what
    if ($p.ExitCode) { throw "Setup ($what) exited with $($p.ExitCode) (logs: out\setup-$what.log, out\machine-$what.log, out\user-setup.log)" }
  }
  # The uninstaller finishes in its copy, %TEMP%\is-*-uninstall.tmp\_unins.tmp.
  function Uninstalled { -not (Test-Path $AppKey) -and -not (Get-Process | Where-Object { $_.Path -like "$env:TEMP\*-uninstall.tmp\*" }) }
  function Typing($phase, [int]$seconds = 300) {
    Set-Content "$out\typing-phase.txt" $phase
    Start-ScheduledTask SebType-setup-typing
    if (-not (Wait-Until $seconds { Test-Path "$out\typing-$phase-done" })) { Result "typing-$phase" FAIL "the typing checks took over $seconds s" }
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
  function Check-Installed($round, [string[]]$langs, [string]$order, [int]$pageSize = 6) {
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
        $pages = @(Get-Content "$env:APPDATA\Rime\default.custom.yaml" -Encoding utf8 -ErrorAction SilentlyContinue) -match '^  menu/page_size:'
        if ($name -ne '中文') { throw "Weasel's input method reads '$name'" }
        if (-not (Test-Path "$env:APPDATA\Rime\build\rime_ice.schema.yaml") -or -not ($patch -match 'schema/name: 中文') -or -not ($patch -match 'sebtype_typo/keyboard: pc')) { throw 'the Chinese data is not deployed with SebType''s patches' }
        if ($pages.Count -ne 1 -or $pages[0] -notmatch "^  menu/page_size: $pageSize\b") { throw "default.custom.yaml's page size: '$($pages -join ' | ')', want $pageSize (#163)" }
        "named 中文; rime-ice and 白霜 deployed with the 中文 name, PC typo correction and $pageSize candidates per page"
      }
    }
    if ('ja' -in $langs) {
      Check "$round-japanese" {
        $name = (Get-Item "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$MozcClsid\LanguageProfile\0x00000411\{186F700C-71CF-43FE-A00E-AACB1D9E6D3D}").GetValue('Description')
        $db = "$env:USERPROFILE\AppData\LocalLow\Mozc\config1.db"
        if ($name -ne '日本語') { throw "Mozc's input method reads '$name'" }
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
      $ll.Add((New-Object Microsoft.InternationalSettings.Commands.WinUserLanguage zh-Hans-CN)); $ll[1].InputMethodTips.Clear(); $ll[1].InputMethodTips.Add($WeaselTip); $ll[1].InputMethodTips.Add('0804:{81D4E9C9-1D3B-41BC-9E6C-4B40BF79E35E}{FA550B04-5AD7-411F-A5AC-CA038EC515D7}')
      $ll.Add((New-Object Microsoft.InternationalSettings.Commands.WinUserLanguage ja)); $ll[2].InputMethodTips.Clear(); $ll[2].InputMethodTips.Add($MozcTip); $ll[2].InputMethodTips.Add('0411:{03B5835F-F03C-411B-9CE2-AA23E1171E36}{A76C93D9-5523-4E90-AAFA-4DB112F9AC76}')
      Set-WinUserLanguageList $ll -Force -WarningAction SilentlyContinue
      Result compare-languages INFO (Languages)
      foreach ($ime in $CompareImes -split ',') { Typing "compare-$ime" }
      if ($SoakMinutes) {
        Set-Content "$out\soak-minutes.txt" $SoakMinutes
        Typing compare-soak ($SoakMinutes * 60 + 300)
      }
      Check 'compare-uninstall' {
        Start-Process "$App\unins000.exe" '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
        if (-not (Wait-Until 600 { Uninstalled })) { throw 'the silent uninstall did not finish in 10 minutes' }
        'silent'
      }
      return
    }
    if ($Only -eq 'picnic') {
      # Only the Picnic window (#162): a silent install, its pictures, a silent uninstall.
      Check 'picnic-install' { Silent picnic-install @(); 'silent' }
      Typing picnic
      Check 'picnic-uninstall' {
        Start-Process "$App\unins000.exe" '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
        if (-not (Wait-Until 600 { Uninstalled })) { throw 'the silent uninstall did not finish in 10 minutes' }
        'silent'
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
      $deployer = Join-Path (Get-ItemProperty HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel).WeaselRoot WeaselDeployer.exe
      function Rime-Sync {  # Weasel's 用户资料同步; not Start-Process (its trailing space, see $picnic)
        $p = [Diagnostics.Process]::Start($deployer, '/sync')
        if (-not $p.WaitForExit(120000)) { Stop-Process -Id $p.Id -Force; throw "Weasel's sync took over 2 minutes" }
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
        Check 'sync-pc-words-reach-server' {
          (Helper server-has $url $syncUser $device rime_ice.userdb.txt '莫福姬'), (Helper server-has $url $syncUser $device mozc_dictionary.txt 'モフ試験語') -join '; '
        }
        Check 'sync-other-device-reaches-pc' { Helper pc-has $rime $mozcDb }
        Check 'sync-uninstall-syncs-first-and-cleans-up' {
          $null = Helper add-mozc $mozcDb 'さいごて' 'サイゴ試験語'  # only the uninstall's sync can take this one up
          Start-Process "$App\unins000.exe" '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$out\uninstall-sync.log`""
          if (-not (Wait-Until 600 { Uninstalled })) { throw 'the silent uninstall did not finish in 10 minutes' }
          $synced = Helper server-has $url $syncUser $device mozc_dictionary.txt 'サイゴ試験語'
          $files = [int](Helper server-files $url $syncUser)
          if ($files -lt 4) { throw "the server keeps $files files, not this PC's and the other device's 4" }
          $left = @()
          if (Get-ScheduledTask -TaskName 'SebType sync' -ErrorAction SilentlyContinue) { $left += 'the SebType sync task' }
          Plain "cmdkey /list 2>&1 | Out-File -Encoding utf8 '$out\after-uninstall.txt'" "$out\after-uninstall.txt"
          if (-not (Test-Path "$out\after-uninstall.txt")) { throw 'no Credential Manager listing after the uninstall' }
          $script:loginLeft = (Get-Content "$out\after-uninstall.txt" -Raw) -match 'target=.*login\.SebType sync'
          $left += @('sync.json', 'sync.lock', 'sebtype_sync.py' | Where-Object { Test-Path "$env:LOCALAPPDATA\SebType\$_" })
          if ($left) { throw "left after uninstall: $($left -join ', ')" }
          "synced first ($synced), the server's $files files kept; task and sync's files gone"
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
      Page $h 'SebType is ready' 900; $null = Shot TWizardForm '4-finish'
      Click $h 'Finish'
      if (-not (Wait-Until 60 { -not (Get-Process | Where-Object { $_.Path -like "$env:TEMP\is-*" }) })) { throw 'Setup did not close' }
      Start-Sleep 3; Get-Process sebtype-configurator -ErrorAction SilentlyContinue | Stop-Process -Force
      'welcome, languages, installing, finish'
    }
    Save-MachineLog round1-install; Stop-Setup
    Check-Installed round1 en, zh, ja "en-US[0409:00000409] zh-Hans-CN[$WeaselTip] ja[$MozcTip]"
    Typing all
    # Rime per key on the installed librime and data (perf-rime.exe from the Weasel build; #133). A timing
    # check: only in the final performance run (Decisions #2, 2026-11-11).
    if ($PerfRun) {
    Check 'round1-rime-p95' {
      if (-not (Test-Path "$root\perf-rime.exe")) { throw 'no perf-rime.exe next to test.ps1' }
      $weasel = (Get-ItemProperty HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel).WeaselRoot
      # The child's stderr says why when it says nothing else; 'Stop' here would drop it.
      $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      $said = powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root\perf-rime.ps1" -Root $weasel -Rime "$App\rime-data.zip" 2>&1
      $ErrorActionPreference = $eap
      $line = @($said) | Where-Object { "$_" -like '*rime-p95-under-10ms*' } | Select-Object -Last 1
      if ($line -notlike 'PASS *') { throw "perf-rime.ps1 (Weasel at '$weasel') exit $LASTEXITCODE said: $($said -join ' | ')" }
      $line -replace '^PASS rime-p95-under-10ms: '
    }
    }
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
    # A page size of the user's own (the Configurator's line) stays through the upgrade (#163).
    $defaults = "$env:APPDATA\Rime\default.custom.yaml"
    [IO.File]::WriteAllLines($defaults, @(@(Get-Content $defaults -Encoding utf8) -replace '^  menu/page_size: .*', '  menu/page_size: 8'))
    Check 'round2-upgrade-drops-japanese' { Silent round2-upgrade @('/TASKS="en,zh"'); 'silent, English and 中文' }
    Check-Installed round2-upgraded en, zh "en-US[0409:00000409] zh-Hans-CN[$WeaselTip]" 8
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
      -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\test.ps1`" -$mode $mode$(if ($Only) { " -Only $Only -SoakMinutes $SoakMinutes -CompareImes $CompareImes" })" }
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
foreach ($c in 'language-follows-windows', 'welcome-zh', 'welcome-ja', 'round1-install-pages', 'win-space-cycle', 'chinese-pinyin', 'japanese-all', 'japanese-alt-grave',
  'round1-upgrade', 'japanese-after-language-change', 'round1-uninstall-pages', 'round1-everything-as-before', 'round2-upgrade-drops-japanese', 'round2-everything-as-before') {
  if (-not $Only -and -not (Select-String -Quiet -SimpleMatch " $c" $results)) { Result $c SKIP 'did not run' }
}
exit [int][bool](Select-String -Quiet '^(FAIL|SKIP) ' $results)
