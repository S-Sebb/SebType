#Requires -Version 7
<#
Times Rime per key (key, then read the candidates) on Windows with perf-rime.exe (pc/linux/perf-rime.c,
built by weasel/build.ps1, in the CI artifact sebtype-weasel), against Weasel's rime.dll and on a private copy of the Chinese data, so nothing is
learned. Budget: p95 ≤ 10 ms (Decisions #2).

  perf-rime.ps1 -Root <Weasel folder: rime.dll, data\> -Rime <a Rime user folder, or rime-data.zip>

Prints the measurements and one line "PASS|FAIL rime-p95-under-10ms: …"; exit 0 on PASS.
Without Weasel installed, -Root can be its installer unpacked with 7-Zip (`7z x <installer> -o<dir>`).
#>
param(
  [Parameter(Mandatory = $true)][string]$Root,
  [Parameter(Mandatory = $true)][string]$Rime,
  [int]$Runs = 5
)
$ErrorActionPreference = 'Stop'
$work = Join-Path ([IO.Path]::GetTempPath()) "sebtype-perf-$PID"
try {
  if ($Rime -like '*.zip') { Expand-Archive $Rime $work } else { Copy-Item $Rime $work -Recurse }
  $inputs = Join-Path $work 'perf-inputs.txt'
  # The same generic phrases as pc/linux/perf.sh: abbreviations, words and a long sentence.
  'nihao ranhou ranh lh zhongguo women xiexie zaijian shurufa dianhua kaihui wozhidaole meiguanxi jintiantianqizenmeyang' -split ' ' |
    Set-Content $inputs
  $env:PATH = "$Root;$env:PATH"  # rime.dll
  $out = Join-Path $work 'out.txt'
  $p = Start-Process (Join-Path $PSScriptRoot 'perf-rime.exe') -PassThru -NoNewWindow -RedirectStandardInput $inputs `
    -RedirectStandardOutput $out -RedirectStandardError "$out.err" -ArgumentList "`"$Root\data`"", "`"$work`"", 'rime_ice', $Runs
  if (-not $p.WaitForExit(600000)) { $p.Kill(); throw 'perf-rime.exe: timeout after 600 s' }
  $v = @{}; Get-Content $out | ForEach-Object { $k, $x = $_ -split '=', 2; $v[$k] = $x }
  if ($p.ExitCode -or -not $v.ContainsKey('key_p95_us')) { throw "perf-rime.exe failed: $(Get-Content "$out.err" -Raw)" }
  $ms = { param($k) [double]$v[$k] / 1000 }
  $p95 = & $ms key_p95_us
  $line = 'key p50 {0:n1} ms, p95 {1:n1} ms, max {2:n1} ms, first key {3:n1} ms, {4} keys; start (deploy check) {5} ms, session {6} ms; peak working set {7} MB' -f `
  (& $ms key_p50_us), $p95, (& $ms key_max_us), (& $ms first_key_us), $v['keys'], $v['deploy_ms'], $v['session_ms'], [int]([double]$v['peak_rss_kb'] / 1024)
  Write-Output "$(if ($p95 -le 10) { 'PASS' } else { 'FAIL' }) rime-p95-under-10ms: $line"
  exit [int]($p95 -gt 10)
} catch {
  Write-Output "FAIL rime-p95-under-10ms: $($_.Exception.Message)"
  exit 1
} finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
