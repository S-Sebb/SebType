# Builds SebType's Weasel (小狼毫) installer: SebType's Weasel in pc/weasel (Weasel $WeaselVersion) with
# SebType's tray icons, and SebType's librime in engines/librime (librime $RimeVersion, the version SebType's
# Android build uses, android/rime/versions.sh; #101, #133).
#   pc/windows/weasel/build.ps1 -Icons <dir with zh.ico en.ico en_caps.ico> [-Out <dir>]
# Needs Visual Studio 2022 with C++ and ATL, git, 7z, NSIS and Git's bash (GitHub's windows-2022
# runner has them all; .github/workflows/weasel.yml runs this). The third-party code SebType doesn't
# change is fetched at pinned commits: librime's dependencies and plugins, and plum. Boost is downloaded
# into $env:BOOST_ROOT when it isn't there yet. Writes sebtype-weasel-<version>-installer.exe to -Out, and
# perf-rime.exe (pc/linux/perf-rime.c) for pc/windows/perf-rime.ps1.
param(
  [Parameter(Mandatory = $true)][string]$Icons,
  [string]$Out = (Join-Path $PSScriptRoot '..\..\..\build\weasel'),
  [string]$Work = (Join-Path $PSScriptRoot '..\..\..\build\weasel-src')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$WeaselVersion = '0.17.4'
$RimeVersion = '1.16.1'
# What librime $RimeVersion's submodules pin, and the plugins its own Windows release merges into
# rime.dll, at the commits its version-info.txt names (rime-ice's Lua needs librime-lua).
$RimeDeps = @(
  @{ Dir = 'deps\glog'; Repo = 'google/glog'; Commit = '7b134a5c82c0c0b5698bb6bf7a835b230c5638e4' }
  @{ Dir = 'deps\googletest'; Repo = 'google/googletest'; Commit = 'f8d7d77c06936315286eb55f8de22cd23c188571' }
  @{ Dir = 'deps\leveldb'; Repo = 'google/leveldb'; Commit = '99b3c03b3284f5886f9ef9a4ef703d57373e61be' }
  @{ Dir = 'deps\marisa-trie'; Repo = 's-yata/marisa-trie'; Commit = '3e87d53b78e15f2f43783d5e376561a8c9722051' }
  @{ Dir = 'deps\opencc'; Repo = 'BYVoid/OpenCC'; Commit = '556ed22496d650bd0b13b6c163be9814637970ae' }
  @{ Dir = 'deps\yaml-cpp'; Repo = 'jbeder/yaml-cpp'; Commit = '2f86d13775d119edbb69af52e5f566fd65c6953b' }
  @{ Dir = 'plugins\lua'; Repo = 'hchunhui/librime-lua'; Commit = '68f9c364a2d25a04c7d4794981d7c796b05ab627' }
  @{ Dir = 'plugins\octagram'; Repo = 'lotem/librime-octagram'; Commit = 'dfcc15115788c828d9dd7b4bff68067d3ce2ffb8' }
  @{ Dir = 'plugins\predict'; Repo = 'rime/librime-predict'; Commit = '920bd41ebf6f9bf6855d14fbe80212e54e749791' }
)
$PlumCommit = 'cab9ed35289f2022b6888503750d2dfb1851dbe0'  # Weasel $WeaselVersion's rime/plum, which fetches its data
$LuaSourceCommit = '9e5bb71db1544913f8005dadc3df8439c00d08b7'  # librime-lua's thirdparty branch
$BoostVersion = '1.84.0'
# Bump on every change to what this builds; setup-ime.ps1 reinstalls when the installed one differs.
$SebTypeBuild = 4

function Invoke-Checked([string]$what, [scriptblock]$cmd) {
  & $cmd
  if ($LASTEXITCODE) { throw "$what failed with exit code $LASTEXITCODE" }
}
# One commit of a repository into $dir, its files as the repository has them.
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

# The build writes into its tree, so it builds a copy: Weasel, with librime and plum where Weasel's
# build.bat takes them.
$pc = Join-Path $PSScriptRoot '..\..'
New-Item -ItemType Directory -Force (Split-Path $Work) | Out-Null
Copy-Item -Recurse (Join-Path $pc 'weasel') $Work
Copy-Item -Recurse (Join-Path $pc 'librime') (Join-Path $Work 'librime')
Push-Location $Work
try {
  foreach ($d in $RimeDeps) { Get-Commit $d.Repo $d.Commit "librime\$($d.Dir)" }
  Get-Commit hchunhui/librime-lua $LuaSourceCommit librime\plugins\lua\thirdparty  # its action-install.bat's Lua
  Get-Commit rime/plum $PlumCommit plum
  foreach ($icon in 'zh.ico', 'en.ico', 'en_caps.ico') { Copy-Item (Join-Path $Icons $icon) resource\ -Force }
  # The pig at the start of the candidate window, which WeaselServer finds next to itself (#94; made by
  # art/make-icon.py).
  Copy-Item (Join-Path $PSScriptRoot 'sebtype-logo.png') output\ -Force

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

  # Weasel's build.bat builds librime and its dependencies for x64 and Win32 and puts rime.dll, rime.lib,
  # the headers and OpenCC's data where the Weasel build takes them.
  Invoke-Checked 'build librime' { cmd /c build.bat rime }
  # build.bat's own errors don't always reach its exit code.
  foreach ($f in 'lib64\rime.lib', 'lib\rime.lib', 'output\rime.dll', 'output\Win32\rime.dll') {
    if (-not (Test-Path $f)) { throw "build.bat rime didn't build $f" }
  }

  $env:RELEASE_BUILD = '1'
  $env:WEASEL_BUILD = "$SebTypeBuild"
  Invoke-Checked 'build data' { cmd /c build.bat data }
  Invoke-Checked 'build weasel and installer' { cmd /c build.bat installer }
  $installer = "output\archives\weasel-$WeaselVersion.$SebTypeBuild-installer.exe"
  Copy-Item $installer (Join-Path $Out "sebtype-weasel-$WeaselVersion.$SebTypeBuild-installer.exe") -Force

  # 64-bit, like the rime.dll Weasel installs on a 64-bit PC (its 32-bit one is for 32-bit Windows).
  $vcvars = & $vswhere -latest -find 'VC\Auxiliary\Build\vcvarsall.bat' | Select-Object -First 1
  $perf = (Resolve-Path (Join-Path $PSScriptRoot '..\..\linux\perf-rime.c')).Path
  # A batch file, so cmd gets the quotes as written.
  Set-Content perf-rime.bat "@call `"$vcvars`" x64 >nul && cl /nologo /O2 /MT /Iinclude /Fe`"$Out\perf-rime.exe`" `"$perf`" psapi.lib"
  Invoke-Checked 'build perf-rime' { cmd /c perf-rime.bat }
} finally {
  Pop-Location
}
