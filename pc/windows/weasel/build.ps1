# Builds SebType's Weasel (小狼毫) installer: upstream Weasel at $WeaselTag with sebtype.patch, SebType's
# tray icons and SebType's librime: $RimeTag (the version SebType's Android build uses,
# rime-android/versions.sh) built from source with Linux's layout-model.patch (#101, #133).
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
$RimeCommit = 'de4700e9f6b75b109910613df907965e3cbe0567'
$RimePlugins = @(
  @{ Dir = 'lua'; Repo = 'hchunhui/librime-lua'; Commit = '68f9c364a2d25a04c7d4794981d7c796b05ab627' }
  @{ Dir = 'octagram'; Repo = 'lotem/librime-octagram'; Commit = 'dfcc15115788c828d9dd7b4bff68067d3ce2ffb8' }
  @{ Dir = 'predict'; Repo = 'rime/librime-predict'; Commit = '920bd41ebf6f9bf6855d14fbe80212e54e749791' }
)
$LuaSourceCommit = '9e5bb71db1544913f8005dadc3df8439c00d08b7'  # librime-lua's thirdparty branch
$BoostVersion = '1.84.0'
# Bump on every change to what this builds; setup-ime.ps1 reinstalls when the installed one differs.
$SebTypeBuild = 4

function Invoke-Checked([string]$what, [scriptblock]$cmd) {
  & $cmd
  if ($LASTEXITCODE) { throw "$what failed with exit code $LASTEXITCODE" }
}
# One commit of a repository into $dir. autocrlf off, so a patch's line endings match the files.
function Get-Commit([string]$repo, [string]$sha, [string]$dir) {
  Invoke-Checked "init $dir" { git -c core.autocrlf=false init -q $dir }
  Invoke-Checked "config $dir" { git -C $dir config core.autocrlf false }
  Invoke-Checked "fetch $repo" { git -C $dir fetch -q --depth 1 "https://github.com/$repo.git" $sha }
  Invoke-Checked "check out $repo" { git -C $dir checkout -q FETCH_HEAD }
}

$Icons = (Resolve-Path $Icons).Path
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }

# autocrlf off, so the patch's line endings match the files. Not its librime submodule, which is older
# than $RimeTag: SebType's librime goes there below.
Invoke-Checked 'clone weasel' { git -c core.autocrlf=false clone -q --depth 1 --branch $WeaselTag `
    --recurse-submodules=plum --shallow-submodules https://github.com/rime/weasel.git $Work }
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

  # SebType's librime: $RimeTag with layout-model.patch, and the plugins librime's own $RimeTag Windows
  # release merges into rime.dll, at the commits its version-info.txt names (rime-ice's Lua needs
  # librime-lua). Weasel's build.bat builds it and its dependencies for x64 and Win32 and puts rime.dll,
  # rime.lib, the headers and OpenCC's data where the Weasel build takes them.
  Remove-Item -Recurse -Force librime
  Get-Commit rime/librime $RimeCommit librime
  Invoke-Checked 'librime submodules' { git -C librime submodule update -q --init --depth 1 }
  Invoke-Checked 'apply layout-model.patch' { git -C librime apply (Join-Path $PSScriptRoot '..\..\linux\rime\layout-model.patch') }
  foreach ($p in $RimePlugins) { Get-Commit $p.Repo $p.Commit "librime\plugins\$($p.Dir)" }
  Get-Commit hchunhui/librime-lua $LuaSourceCommit librime\plugins\lua\thirdparty  # its action-install.bat's Lua
  Invoke-Checked 'build librime' { cmd /c build.bat rime }
  # build.bat's own errors don't always reach its exit code.
  foreach ($f in 'lib64\rime.lib', 'lib\rime.lib', 'output\rime.dll', 'output\Win32\rime.dll') {
    if (-not (Test-Path $f)) { throw "build.bat rime didn't build $f" }
  }

  $env:RELEASE_BUILD = '1'
  $env:WEASEL_BUILD = "$SebTypeBuild"
  Invoke-Checked 'build data' { cmd /c build.bat data }
  Invoke-Checked 'build weasel and installer' { cmd /c build.bat installer }
  $installer = "output\archives\weasel-$WeaselTag.$SebTypeBuild-installer.exe"
  Copy-Item $installer (Join-Path $Out "sebtype-weasel-$WeaselTag.$SebTypeBuild-installer.exe") -Force

  # 64-bit, like the rime.dll Weasel installs on a 64-bit PC (its 32-bit one is for 32-bit Windows).
  $vcvars = & $vswhere -latest -find 'VC\Auxiliary\Build\vcvarsall.bat' | Select-Object -First 1
  $perf = (Resolve-Path (Join-Path $PSScriptRoot '..\..\linux\perf-rime.c')).Path
  # A batch file, so cmd gets the quotes as written.
  Set-Content perf-rime.bat "@call `"$vcvars`" x64 >nul && cl /nologo /O2 /MT /Iinclude /Fe`"$Out\perf-rime.exe`" `"$perf`" psapi.lib"
  Invoke-Checked 'build perf-rime' { cmd /c perf-rime.bat }
} finally {
  Pop-Location
}
