<#
Focus moving away mid-word types in what was being typed (#277), on a Windows PC with SebType installed,
in the logged-on person's own desktop session (not elevated). One command:

    powershell -ExecutionPolicy Bypass -File test-focus-out.ps1 [-Out <folder>] [-Trial]

It makes no input of its own, so a screen that is off stays off (YukaROG's SebChat Night: any key or mouse
input lights it): the field is TsfHost.cs's (beside this script), brought to the front without a key, and
keys go to TSF's keystroke manager instead of the session's input. Moving away is TSF's focus going to
another document and back, as a click into another field does. Checks: 中文 ranhou Space gives 然后; nihao,
then away and back, leaves nihao, and ni Space after it gives 你 (nothing left over); 日本語 nihongo Space,
then away, leaves 日本語; 日本語 nihongo Space, then 中文, leaves 日本語, and 中文 nihao, then 日本語,
leaves nihao (#301); 中文 nihao, then the list's first other input method, leaves nothing. Windows' display state (GUID_CONSOLE_DISPLAY_STATE) is watched from the start:
it must be off then and never turn on (display-stayed-off); once it is on, no more keys go.
-Trial needs no SebType: the field to the front and one key, and the display watched, then nothing else.
-WatchTo <file> only watches the display, for a whole session around this test (installing, uninstalling):
each state goes into the file as Windows reports it, until <file>.stop exists (at most 60 minutes).
-AnyDisplay is for a PC no one sits at (TCSBackEnd, whose console session the run attaches): the display
state is only reported.
Results: one line per check in <Out>\focus-out-results.txt; exit 0 only if all pass.
#>
param([string]$Out = "$env:USERPROFILE\scratch\SebType\277", [switch]$Trial, [string]$WatchTo, [switch]$AnyDisplay)
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
  try { $why = & $body; if ($why -like 'SKIP: *') { Result $name SKIP $why.Substring(6) } else { Result $name PASS $why } }
  catch { Result $name FAIL $_.Exception.Message }
}

$missing = if ($WatchTo) { $null }
elseif (-not $Trial -and -not (Test-Path "$env:ProgramFiles\SebType\sebtype.dll")) { 'SebType is not installed' }
elseif ((Get-Process -Id $PID).SessionId -eq 0) { 'runs in session 0: start it in the desktop session' }
elseif (-not (Test-Path "$root\TsfHost.cs")) { "no TsfHost.cs beside $PSCommandPath" }
if ($missing) { Write-Host "BLOCKED preflight: $missing"; exit 1 }

Add-Type -Path "$root\TsfHost.cs" -ReferencedAssemblies System.Drawing
$display = [SebType.Display]
if ($WatchTo) {
  $display::Watch(); $seen = 0; $end = (Get-Date).AddMinutes(60)
  while (-not (Test-Path "$WatchTo.stop") -and (Get-Date) -lt $end) {
    $now = @($display::States); if ($now.Count -gt $seen) { Add-Content $WatchTo $now[$seen..($now.Count - 1)]; $seen = $now.Count }
    Start-Sleep -Milliseconds 200
  }
  exit 0
}
$tsf = [SebType.TsfHost]
$tsf::NoInput = $true
function States { $display::States -join ', ' }

$display::Watch()
for ($i = 0; $i -lt 20 -and $display::Last -lt 0; $i++) { Start-Sleep -Milliseconds 100 }
if ($display::Last -lt 0) { Write-Host 'BLOCKED preflight: Windows reported no display state'; exit 1 }
if ($display::Last -ne 0 -and -not $AnyDisplay) { Write-Host "BLOCKED preflight: the display is on (state $($display::Last)): someone may be using the PC"; exit 1 }

# Before each key: the display still off, and the field in front with TSF's focus.
function Ready {
  if ($display::Lit -and -not $AnyDisplay) { throw "the display turned on ($(States)): no more keys" }
  if (-not $tsf::Focus()) { throw "the test field is not in front with the keyboard focus ($($tsf::FocusState())): no key sent" }
}
function Keys {
  Ready
  foreach ($k in $args) { $null = $tsf::Key($(switch ($k) { 'space' { 0x20 } 'Escape' { 0x1B } default { [byte][char]$k.ToUpper() } })); $tsf::Settle(150) }
  $tsf::Settle(600)
}
function TypeText($s) { $chars = @($s.ToCharArray() | ForEach-Object { if ($_ -eq ' ') { 'space' } else { "$_" } }); Keys @chars }
function Away { $tsf::Away($true); $tsf::Settle(800); $tsf::Away($false); $tsf::Settle(800) }
$clsid = [Guid]'{D4E5C593-4F73-475F-936C-0E29A6FE7A02}'
function Lang($lang, [switch]$Keep) {  # -Keep: the switch is under test, so the field keeps what it holds
  if ($lang -eq 'zh') { $tsf::Activate(0x804, $clsid, [Guid]'{8AA7DDAC-A4B8-4437-9C0B-8698879EC987}') }
  else { $tsf::Activate(0x411, $clsid, [Guid]'{B148FB02-C235-45D6-996C-672C783ECD48}') }
  $tsf::Settle(500); if (-not $Keep) { $tsf::Clear() }
}
# The first input method in the person's language list that isn't SebType, made active for this process
# only (the list stays as it is), or $null when there is none.
function OtherKeyboard {
  $tip = @((Get-WinUserLanguageList) | ForEach-Object { $_.InputMethodTips } | Where-Object { $_ -notmatch $clsid })[0]
  if (-not $tip) { return $null }
  $lang = [Convert]::ToUInt16($tip.Substring(0, 4), 16)
  if ($tip -match '^\w{4}:\{(.+)\}\{(.+)\}$') { $tsf::Activate($lang, [Guid]$Matches[1], [Guid]$Matches[2]) }
  else { $tsf::ActivateLayout($lang, $tip.Substring(5)) }
  $tsf::Settle(800)
  $tip
}

$tsf::Start()
try {
  if ($Trial) {
    Check 'trial-front-and-key' {
      # The key goes even when the field isn't in front (it is no input either way), to show where it gets.
      if ($display::Lit) { throw "the display turned on ($(States)): no key sent" }
      $front = $tsf::Focus(); $state = $tsf::FocusState()
      $eaten = $tsf::Key(0x41); $tsf::Settle(500); $t = $tsf::Text()
      $why = "$state; one key through TSF (eaten: $eaten), the field holds '$t'"
      if (-not $front -or $t -ne 'a') { throw $why }
      $why
    }
  } else {
    Lang zh
    Check 'chinese-pinyin' {
      TypeText 'ni'; Start-Sleep 3; Keys Escape  # the first key starts sebtype-server when none runs
      $tsf::Clear(); TypeText 'ranhou '; $t = $tsf::Text()
      if ($t -ne '然后') { throw "ranhou + Space gave '$t'" }
      $t
    }
    Check 'chinese-focus-out' {
      $tsf::Clear(); TypeText 'nihao'; Away; $away = $tsf::Text()
      TypeText 'ni '; $t = $tsf::Text()
      if ("$away $t" -ne 'nihao nihao你') { throw "nihao, then away and back, left '$away'; ni + Space after it gave '$t' (want nihao, nihao你)" }
      "nihao stays; then $t"
    }
    Lang ja
    Check 'japanese-focus-out' {
      TypeText 'nihongo '; Away; $t = $tsf::Text()
      if ($t -ne '日本語') { throw "nihongo + Space, then away, left '$t'" }
      $t
    }
    # Switching between SebType's 中 and 日 types in what focus moving away does (#301): pinyin as its
    # letters, Japanese as converted.
    Check 'japanese-to-chinese' {
      $tsf::Clear(); TypeText 'nihongo '; Lang zh -Keep; $t = $tsf::Text()
      if ($t -ne '日本語') { throw "nihongo + Space, then 中, left '$t'" }
      $t
    }
    Check 'chinese-to-japanese' {
      $tsf::Clear(); TypeText 'nihao'; Lang ja -Keep; $t = $tsf::Text()
      if ($t -ne 'nihao') { throw "nihao, then 日, left '$t'" }
      $t
    }
    # Switching to another input method still throws it away (the user's choice in #301).
    Check 'chinese-to-other-keyboard' {
      Lang zh; TypeText 'nihao'; $typed = $tsf::Text(); $from = $tsf::Active(); $other = OtherKeyboard
      if (-not $other) { Lang zh; return 'SKIP: the language list has no input method besides SebType' }
      $t = $tsf::Text(); $to = $tsf::Active(); Lang zh
      if ($t -ne '') { throw "nihao, then $other, left '$t' (before: '$typed' in $from; after: $to)" }
      "nothing left after $other"
    }
  }
} finally {
  if (-not $display::Lit -or $AnyDisplay) { try { Keys Escape Escape } catch { } }
  $tsf::Stop()
}
Start-Sleep 6  # a wake from the last steps shows by now
Check 'display-stayed-off' {
  if ($AnyDisplay) { return "SKIP: -AnyDisplay (states: $(States))" }
  if ($display::Lit) { throw "the display turned on: $(States)" }
  "off throughout: $(States)"
}
$failed = @(Get-Content $results | Where-Object { $_ -like 'FAIL *' }).Count
exit [int]($failed -gt 0)
