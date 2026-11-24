#Requires -Version 5.1
<#
Times Rime per key (key, then read the candidates) on Windows with perf-rime.exe (pc/linux/perf-rime.c,
built by rime/build.ps1, in the CI artifact perf-rime), against SebType's rime.dll and on a private copy of the
Chinese data, so nothing is learned. Budget (Decisions #2, 2026-11-24): p95 ≤ 16 ms over every key of the -Runs passes, the
first (cold) pass included. The warm p95 (the passes after the first) and the cold p95 (the first) are reported
beside it, not gated (#523).

  perf-rime.ps1 -Root <SebType's folder: rime.dll, data\> -Rime <a Rime user folder, or rime-data.zip>

Prints the measurements and one line "PASS|FAIL rime-p95-under-16ms: …"; exit 0 on PASS.
Without SebType installed, -Root can be CI's sebtype-rime artifact.
#>
param(
  [Parameter(Mandatory = $true)][string]$Root,
  [Parameter(Mandatory = $true)][string]$Rime,
  [ValidateRange(2, 100)][int]$Runs = 5  # 2 or more: the warm p95 needs a pass after the first
)
$ErrorActionPreference = 'Stop'
# Not in %TEMP%: the zip's files keep their fixed 2025 times, and Windows' Storage Service deletes such
# old-looking files there, prebuilt tables included, which Rime would then rebuild (#537).
$work = Join-Path $env:LOCALAPPDATA "SebType\perf-$PID"
try {
  New-Item -ItemType Directory -Force (Split-Path $work) | Out-Null  # Copy-Item makes no parent folders
  if ($Rime -like '*.zip') { Expand-Archive $Rime $work } else { Copy-Item $Rime $work -Recurse }
  $inputs = Join-Path $work 'perf-inputs.txt'
  # The same generic phrases as pc/linux/perf.sh: abbreviations, words and a long sentence.
  'nihao ranhou ranh lh zhongguo women xiexie zaijian shurufa dianhua kaihui wozhidaole meiguanxi jintiantianqizenmeyang' -split ' ' |
    Set-Content $inputs
  $env:PATH = "$Root;$env:PATH"  # rime.dll
  $out = Join-Path $work 'out.txt'
  $p = Start-Process (Join-Path $PSScriptRoot 'perf-rime.exe') -PassThru -NoNewWindow -RedirectStandardInput $inputs `
    -RedirectStandardOutput $out -RedirectStandardError "$out.err" -ArgumentList "`"$Root\data`"", "`"$work`"", 'rime_ice', $Runs
  $null = $p.Handle  # Windows PowerShell keeps the exit code only once the handle is read
  if (-not $p.WaitForExit(600000)) { $p.Kill(); throw 'perf-rime.exe: timeout after 600 s' }
  $v = @{}; Get-Content $out | ForEach-Object { $k, $x = $_ -split '=', 2; $v[$k] = $x }
  if ($p.ExitCode) { throw "perf-rime.exe failed: $(Get-Content "$out.err" -Raw)" }
  # A perf-rime.exe older than this script lacks the newer keys: say so, not 0.0 ms. An empty value counts as missing.
  $missing = 'key_p50_us', 'key_p95_us', 'key_max_us', 'keys', 'first_key_us', 'cold_p95_us', 'warm_p95_us', 'slow_keys_per_pass',
    'deploy_ms', 'session_ms', 'peak_rss_kb' | Where-Object { -not $v[$_] }
  if ($missing) { throw "perf-rime.exe printed no $($missing -join ', '): an older build?" }
  $ms = { param($k) [double]$v[$k] / 1000 }
  $gated = 'key_p95_us'  # all keys (Decisions #2); 'warm_p95_us' would leave the cold first pass out (#523)
  $p95 = & $ms $gated
  $line = 'key p50 {0:n1} ms, p95 {1:n1} ms, max {2:n1} ms over {4} keys; p95 warm (passes 2-{9}) {8:n1} ms, cold (pass 1) {10:n1} ms; keys over 10 ms per pass {11}; first key {3:n1} ms; start (deploy check) {5} ms, session {6} ms; peak working set {7} MB' -f `
  (& $ms key_p50_us), (& $ms key_p95_us), (& $ms key_max_us), (& $ms first_key_us), $v['keys'], $v['deploy_ms'], $v['session_ms'],
  [int]([double]$v['peak_rss_kb'] / 1024), (& $ms warm_p95_us), $Runs, (& $ms cold_p95_us), $v['slow_keys_per_pass']
  Write-Output "$(if ($p95 -le 16) { 'PASS' } else { 'FAIL' }) rime-p95-under-16ms: $line"
  exit [int]($p95 -gt 16)
} catch {
  Write-Output "FAIL rime-p95-under-16ms: $($_.Exception.Message)"
  exit 1
} finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
