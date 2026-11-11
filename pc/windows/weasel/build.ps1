# Builds SebType's Weasel (小狼毫) installer: upstream Weasel at $WeaselTag with sebtype.patch, SebType's
# tray icons and librime $RimeTag (the version SebType's Android build uses, rime-android/versions.sh).
#   pc/windows/weasel/build.ps1 -Icons <dir with zh.ico en.ico en_caps.ico> [-Out <dir>]
# Needs Visual Studio 2022 with C++ and ATL, git, 7z, NSIS and Git's bash (GitHub's windows-2022
# runner has them all; .github/workflows/weasel.yml runs this). Boost is downloaded into
# $env:BOOST_ROOT when it isn't there yet. Writes sebtype-weasel-<version>-installer.exe to -Out, and
# perf-rime.exe (pc/linux/perf-rime.c) for pc/windows/perf-rime.ps1.
param(
  [Parameter(Mandatory = $true)][string]$Icons,
  [string]$Out = (Join-Path $PSScriptRoot '..\..\..\build\weasel'),
  [string]$Work = (Join-Path $PSScriptRoot '..\..\..\build\weasel-src')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$WeaselTag = '0.17.4'
$RimeTag = '1.16.1'
$BoostVersion = '1.84.0'
# Bump on every change to what this builds; setup-ime.ps1 reinstalls when the installed one differs.
$SebTypeBuild = 3

function Invoke-Checked([string]$what, [scriptblock]$cmd) {
  & $cmd
  if ($LASTEXITCODE) { throw "$what failed with exit code $LASTEXITCODE" }
}

$Icons = (Resolve-Path $Icons).Path
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }

# autocrlf off, so the patch's line endings match the files.
Invoke-Checked 'clone weasel' { git -c core.autocrlf=false clone -q --depth 1 --branch $WeaselTag `
    --recurse-submodules --shallow-submodules https://github.com/rime/weasel.git $Work }
Push-Location $Work
try {
  Invoke-Checked 'apply sebtype.patch' { git apply (Join-Path $PSScriptRoot 'sebtype.patch') }
  foreach ($icon in 'zh.ico', 'en.ico', 'en_caps.ico') { Copy-Item (Join-Path $Icons $icon) resource\ -Force }
  # The pig at the start of the candidate window, which WeaselServer finds next to itself (#94; made by
  # sebtype/make-icon.py).
  Copy-Item (Join-Path $PSScriptRoot 'sebtype-logo.png') output\ -Force
  # The resource script is UTF-16, so it is edited here rather than in the patch.
  $rc = Join-Path $Work 'WeaselTSF\WeaselTSF.rc'  # .NET resolves relative paths against the process folder
  $text = [IO.File]::ReadAllText($rc, [Text.Encoding]::Unicode)
  $line = 'IDI_EN                  ICON                    "..\\resource\\en.ico"'
  if (-not $text.Contains($line)) { throw "$rc has no IDI_EN icon line" }
  $text = $text.Replace($line, "$line`r`n`r`nIDI_EN_CAPS             ICON                    `"..\\resource\\en_caps.ico`"")
  [IO.File]::WriteAllText($rc, $text, [Text.Encoding]::Unicode)

  Copy-Item env.vs2022.bat env.bat
  if (-not $env:BOOST_ROOT) { $env:BOOST_ROOT = Join-Path $Work "deps\boost_$($BoostVersion -replace '\.', '_')" }
  if (-not (Test-Path "$env:BOOST_ROOT\stage\lib")) {
    if (-not (Test-Path "$env:BOOST_ROOT\boost")) {
      $parent = Split-Path $env:BOOST_ROOT
      New-Item -ItemType Directory -Force $parent | Out-Null
      $archive = Join-Path $parent "boost_$($BoostVersion -replace '\.', '_').7z"
      Invoke-WebRequest "https://archives.boost.io/release/$BoostVersion/source/$(Split-Path -Leaf $archive)" -OutFile $archive
      Invoke-Checked 'unpack boost' { 7z x -y "-o$parent" $archive | Out-Null }
      Remove-Item $archive
    }
    Invoke-Checked 'build boost' { cmd /c build.bat boost }
  }

  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  $msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
  $env:PATH = "$(Split-Path $msbuild);$env:PATH"

  # get-rime.ps1 asks GitHub's API for the release; a token avoids the runner's shared rate limit.
  if ($env:GITHUB_TOKEN) { "`$global:authorization = '$env:GITHUB_TOKEN'" | Set-Content "$HOME\.get-rime.conf.ps1" }
  # Its own process: get-rime.ps1 isn't written for strict mode.
  Invoke-Checked 'get-rime' { pwsh -NoProfile -File .\get-rime.ps1 -use dev -tag $RimeTag }
  if (-not (Test-Path lib64\rime.lib)) { throw "get-rime.ps1 didn't fetch librime $RimeTag" }

  $env:RELEASE_BUILD = '1'
  $env:WEASEL_BUILD = "$SebTypeBuild"
  Invoke-Checked 'build data' { cmd /c build.bat data }
  Invoke-Checked 'build weasel and installer' { cmd /c build.bat installer }
  $installer = "output\archives\weasel-$WeaselTag.$SebTypeBuild-installer.exe"
  Copy-Item $installer (Join-Path $Out "sebtype-weasel-$WeaselTag.$SebTypeBuild-installer.exe") -Force

  # 32-bit, like the rime.dll it loads: Weasel ships only a 32-bit one.
  $vcvars = & $vswhere -latest -find 'VC\Auxiliary\Build\vcvarsall.bat' | Select-Object -First 1
  $perf = (Resolve-Path (Join-Path $PSScriptRoot '..\..\linux\perf-rime.c')).Path
  # A batch file, so cmd gets the quotes as written.
  Set-Content perf-rime.bat "@call `"$vcvars`" x86 >nul && cl /nologo /O2 /MT /Iinclude /Fe`"$Out\perf-rime.exe`" `"$perf`" psapi.lib"
  Invoke-Checked 'build perf-rime' { cmd /c perf-rime.bat }
} finally {
  Pop-Location
  Remove-Item "$HOME\.get-rime.conf.ps1" -ErrorAction SilentlyContinue
}
