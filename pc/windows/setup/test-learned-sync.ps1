<#
Mozc's learned conversions sync (#409), on a Windows PC with SebType installed, in the logged-on person's own
session (not elevated; test-tcsbackend.sh's ONLY=learned runs it as its test user), as pc/linux/test-learned-sync.py
on Linux. One command:

    powershell -ExecutionPolicy Bypass -File test-learned-sync.ps1 [-Out <folder>]

sebtype_sync.py (in this folder) serves on this PC with Setup's Python and a throwaway login, which the
Configurator's --save-login keeps. Keys go to TSF's keystroke manager in TsfHost.cs's field, as test-forget.ps1's.
This PC picks a conversion, a made-up phone on the server picks others, and the Configurator's --sync takes each
to the other. Checked: each device gets the other's; the same reading picked on both comes first as the later
pick; learning off (--learning off) records nothing new but still learns the phone's; Forget (--forget ja)
empties this PC's record, which the next sync uploads so, and what the phone picked before doesn't come back
after a sync, only what it picks after. Results: one line per check in <Out>\learned-sync-results.txt; exit 0
only if all pass.
#>
param([string]$Out = "$env:USERPROFILE\scratch\SebType\409")
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSCommandPath
$app = "$env:ProgramFiles\SebType"
$mozc = "$env:USERPROFILE\AppData\LocalLow\Mozc"
$own = "$mozc\mozc_learned.txt"
$phoneDevice = 'sebtype-test-phone'
$header = "# SebType mozc_learned 1`n"
New-Item -ItemType Directory -Force $Out | Out-Null
$results = "$Out\learned-sync-results.txt"
Set-Content -Encoding utf8 $results ''
function Result($name, $status, $why = '') {
  $line = "$status $name$(if ($why) { ": $why" })"
  Add-Content -Encoding utf8 $results $line; Write-Host $line
}
function Check($name, [scriptblock]$body) {
  try { $why = & $body; Result $name PASS $why } catch { Result $name FAIL $_.Exception.Message }
}
if (-not (Test-Path "$app\sebtype-server.exe")) { Write-Host 'BLOCKED preflight: SebType is not installed'; exit 1 }

Add-Type -Path "$root\TsfHost.cs" -ReferencedAssemblies System.Drawing
$tsf = [SebType.TsfHost]
$tsf::NoInput = $true
function Keys {
  foreach ($k in $args) {
    $null = $tsf::Key($(switch ($k) { 'space' { 0x20 } 'Return' { 0x0D } 'Escape' { 0x1B } default { [byte][char]"$k".ToUpper() } }))
    $tsf::Settle(150)
  }
  $tsf::Settle(600)
}
function Lang($lang) {
  $clsid = [Guid]'{D4E5C593-4F73-475F-936C-0E29A6FE7A02}'
  if ($lang -eq 'zh') { $tsf::Activate(0x804, $clsid, [Guid]'{8AA7DDAC-A4B8-4437-9C0B-8698879EC987}') }
  else { $tsf::Activate(0x411, $clsid, [Guid]'{B148FB02-C235-45D6-996C-672C783ECD48}') }
  $tsf::Settle(500); $tsf::Clear()
  for ($i = 0; $i -lt 120; $i++) {  # the first key starts the server, and Mozc loads in the background
    $taken = $tsf::Key([byte][char]'N'); $tsf::Settle(200); $null = $tsf::Key(0x1B); $tsf::Settle(200); $tsf::Clear()
    if ($taken) { return }
    Start-Sleep -Milliseconds 500
  }
  throw "$lang never took a key"
}
# What converting the reading and taking the n-th candidate commits (the first learns no pick).
function Conv($word, $n = 1) {
  $keys = @($word.ToCharArray() | ForEach-Object { "$_" }) + @('space') * $n + @('Return')
  Keys @keys; $t = $tsf::Text(); $tsf::Clear(); $t
}
function Read($path) { if (Test-Path $path) { [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) } else { '' } }

# The server and its throwaway login.
$python = "$app\python\python.exe"
$password = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $listener.Start()
$port = $listener.LocalEndpoint.Port; $listener.Stop()
$url = "http://127.0.0.1:$port"
$user = 'sebtype-learned-test'
$auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:$password"))
$password | & $python -I "$root\sebtype_sync.py" adduser --data "$Out\server" --password-stdin $user | Out-Null
$server = Start-Process $python -PassThru -WindowStyle Hidden -RedirectStandardError "$Out\server.log" `
  -ArgumentList '-I', "`"$root\sebtype_sync.py`"", 'serve', '--data', "`"$Out\server`"", '--port', $port
function Http($method, $path, $body) {  # this PC's own server: nothing to cap (tools/check-downloads.py)
  $web = [Net.WebClient]::new()
  $web.Headers['Authorization'] = $auth
  if ($method -eq 'PUT') { $null = $web.UploadData("$url$path", 'PUT', [Text.Encoding]::UTF8.GetBytes($body)); return }
  [Text.Encoding]::UTF8.GetString($web.DownloadData("$url$path"))
}
$phone = @{}  # the phone's record: "reading`twritten" -> time
function PhonePicks($reading, $written, $time) {
  $phone["$reading`t$written"] = $time
  $lines = $phone.GetEnumerator() | Sort-Object Value | ForEach-Object { "$($_.Key)`t$($_.Value)`n" }
  $null = Http PUT "/v1/files/$phoneDevice/mozc_learned.txt" ($header + ($lines -join ''))
}
function PcOnServer {
  $f = (Http GET '/v1/files' | ConvertFrom-Json).files | Where-Object { $_.name -eq 'mozc_learned.txt' -and $_.device -ne $phoneDevice }
  if ($f) { Http GET "/v1/files/$($f.device)/mozc_learned.txt" } else { '' }
}
function Configurator {
  $p = Start-Process -PassThru -WindowStyle Hidden "$app\sebtype-configurator.exe" $args
  if (-not $p.WaitForExit(180000)) { Stop-Process -Id $p.Id -Force; throw "--$($args -join ' ') took over 3 minutes" }
  if ($p.ExitCode) { throw "$($args -join ' ') exited with $($p.ExitCode)" }
}
function Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
# The Configurator's sync; once it pulled the phone's record, Mozc restarts when typing is idle and learns it.
function Sync {
  Configurator --sync
  $record = "$mozc\mozc_learned\$phoneDevice"
  for ($i = 0; $i -lt 120; $i++) {
    $txt = Read "$record.txt"
    if ($txt -and (Read "$record.applied") -eq $txt) { return }
    Start-Sleep -Milliseconds 500
  }
  throw "Mozc didn't learn the phone's record within a minute"
}

$reading = @{ kisha = 'きしゃ'; kanji = 'かんじ'; touki = 'とうき'; seika = 'せいか' }
$phonePick = @{ kisha = '汽車'; kanji = '幹事'; touki = '冬季'; seika = '聖火' }
$first = @{}
$tsf::Start()
try {
  Check 'ja-ready' {
    "$url`n$user`n$password`n" | & "$app\sebtype-configurator.exe" --save-login
    if ($LASTEXITCODE) { throw "--save-login exited with $LASTEXITCODE" }
    Lang zh  # a sync also writes 中文's snapshot
    Lang ja
    foreach ($w in $reading.Keys) { $first[$w] = Conv $w }
    $same = @($reading.Keys | Where-Object { -not $first[$_] -or $first[$_] -eq $phonePick[$_] })
    if ($same) { throw "first candidates $($first | Out-String), want none of the phone's" }
    "first candidates $(($first.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ')"
  }
  Check 'pc-learns-and-records' {
    $script:picked = Conv kisha 4
    $again = Conv kisha
    if (-not $picked -or $picked -in $first.kisha, $phonePick.kisha -or $again -ne $picked) { throw "4th '$picked', then first '$again'" }
    if (-not (Read $own).Contains("きしゃ`t$picked`t")) { throw "'$picked' not in $own" }
    "4th '$picked', then first, in $own"
  }
  $now = Now
  PhonePicks $reading.kisha $phonePick.kisha ($now - 100)
  PhonePicks $reading.kanji $phonePick.kanji ($now - 50)
  Check 'pc-pick-reaches-server' {
    Sync
    $up = PcOnServer
    if (-not $up.StartsWith($header) -or -not $up.Contains("きしゃ`t$picked`t")) { throw "the PC's record on the server: '$up'" }
    "the PC's record on the server has '$picked'"
  }
  Check 'phone-pick-reaches-pc' { $t = Conv kanji; if ($t -ne $phonePick.kanji) { throw "かんじ first '$t'" }; $t }
  Check 'same-reading-later-pick-first' {
    $t = Conv kisha
    if ($t -ne $picked) { throw "きしゃ first '$t', want this PC's later pick '$picked'" }
    "きしゃ first '$t', not the phone's earlier $($phonePick.kisha)"
  }
  Check 'same-reading-phone-later-first' {
    PhonePicks $reading.kisha $phonePick.kisha ((Now) + 10)
    Sync
    $t = Conv kisha
    if ($t -ne $phonePick.kisha) { throw "きしゃ first '$t'" }
    $t
  }
  Check 'learning-off-records-nothing' {
    $before = Read $own
    Configurator --learning off
    $p = Conv seika 3
    $t = Conv seika
    if (-not $p -or $p -eq $first.seika -or $t -ne $first.seika) { throw "3rd '$p', then first '$t'" }
    if ((Read $own) -ne $before) { throw 'the record changed' }
    "3rd '$p', then first '$t', record unchanged"
  }
  Check 'learning-off-still-learns-phone' {
    PhonePicks $reading.touki $phonePick.touki ((Now) + 20)
    Sync
    $t = Conv touki
    if ($t -ne $phonePick.touki) { throw "とうき first '$t'" }
    $t
  }
  Configurator --learning on
  $words = 'kisha', 'kanji', 'touki'
  function Firsts { ($words | ForEach-Object { "$_ $(Conv $_)" }) -join ', ' }
  $want = ($words | ForEach-Object { "$_ $($first[$_])" }) -join ', '
  Check 'forget-clears-record' {
    Configurator --forget ja
    if ((Read $own) -ne $header) { throw "record '$(Read $own)'" }
    $now = Firsts
    if ($now -ne $want) { throw "first $now, want $want" }
    "record empty, first $now"
  }
  Check 'forget-stays-after-sync' {
    Sync
    $up = PcOnServer
    $now = Firsts
    if ($up -ne $header -or $now -ne $want) { throw "the PC's record on the server '$up', first $now, want $want" }
    "the PC's record on the server empty, first $now"
  }
  Check 'phone-picks-after-forget-come' {
    PhonePicks $reading.seika $phonePick.seika ((Now) + 30)
    Sync
    $s, $k = (Conv seika), (Conv kanji)
    if ($s -ne $phonePick.seika -or $k -ne $first.kanji) { throw "せいか first '$s', かんじ first '$k'" }
    "せいか first '$s', かんじ first '$k' (forgotten)"
  }
} finally {
  $tsf::Stop()
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Copy-Item "$env:TEMP\rime.sebtype\server.log" $Out -ErrorAction SilentlyContinue
}
$failed = @(Get-Content $results | Where-Object { $_ -like 'FAIL *' }).Count
exit [int]($failed -gt 0)
