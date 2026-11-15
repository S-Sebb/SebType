# Builds SebType's librime for Windows: engines/librime (librime $RimeVersion, the version SebType's Android
# and Linux builds use too; #101, #133), 64-bit, with librime-lua, -octagram and -predict merged into rime.dll
# as librime's own Windows release does, and Rime's shared data.
#   pc/windows/rime/build.ps1 [-Out <dir>] [-Work <dir>]
# Needs Visual Studio 2022 with C++, git, 7z and Git's bash (GitHub's windows-2022 runner has them all;
# .github/workflows/windows-setup.yml runs this). The third-party code SebType doesn't change is fetched at
# pinned commits: librime's dependencies and plugins, and plum. Boost's headers are downloaded into
# $env:BOOST_ROOT when they aren't there yet. Writes to -Out rime\ (rime.dll, lib\rime.lib, include\ and
# data\, Rime's shared data with OpenCC's) for windows/build.ps1 and SebType's setup, and perf-rime.exe
# (pc/linux/perf-rime.c) for pc/windows/perf-rime.ps1.
param(
  [string]$Out = (Join-Path $PSScriptRoot '..\..\..\build\rime'),
  [string]$Work = (Join-Path $PSScriptRoot '..\..\..\build\rime-src')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
# rime/plum at the commit Weasel 0.17.4 pinned, which fetches Rime's preset data, as SebType shipped it before #190.
$PlumCommit = 'cab9ed35289f2022b6888503750d2dfb1851dbe0'
$LuaSourceCommit = '9e5bb71db1544913f8005dadc3df8439c00d08b7'  # librime-lua's thirdparty branch
$BoostVersion = '1.84.0'

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

New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path
if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }
New-Item -ItemType Directory -Force $Work | Out-Null
$Work = (Resolve-Path $Work).Path

# librime needs only Boost's headers on Windows (its CMakeLists asks for no Boost library there).
if (-not $env:BOOST_ROOT) { $env:BOOST_ROOT = Join-Path $Work "boost_$($BoostVersion -replace '\.', '_')" }
if (-not (Test-Path "$env:BOOST_ROOT\boost")) {
  $parent = Split-Path $env:BOOST_ROOT
  New-Item -ItemType Directory -Force $parent | Out-Null
  $archive = Join-Path $parent "boost_$($BoostVersion -replace '\.', '_').7z"
  Invoke-WebRequest "https://archives.boost.io/release/$BoostVersion/source/$(Split-Path -Leaf $archive)" -OutFile $archive
  Invoke-Checked 'unpack boost' { 7z x -y "-o$parent" $archive | Out-Null }
  Remove-Item $archive
  Get-ChildItem $env:BOOST_ROOT -Exclude boost | Remove-Item -Recurse -Force  # sources, docs and tools: only the headers stay
}

# The build writes into its tree, so it builds a copy.
$rimeSrc = Join-Path $Work 'librime'
Copy-Item -Recurse (Join-Path $PSScriptRoot '..\..\..\engines\librime') $rimeSrc
Push-Location $rimeSrc
try {
  foreach ($d in $RimeDeps) { Get-Commit $d.Repo $d.Commit $d.Dir }
  Get-Commit hchunhui/librime-lua $LuaSourceCommit plugins\lua\thirdparty  # its action-install.bat's Lua
  Set-Content env.bat @(
    "set BOOST_ROOT=$env:BOOST_ROOT"
    'set ARCH=x64'
    'set BJAM_TOOLSET=msvc-14.3'
    'set CMAKE_GENERATOR="Visual Studio 17 2022"'
    'set PLATFORM_TOOLSET=v143'
  )
  # librime's own build.bat: its dependencies (static), then rime.dll with the plugins merged in, into dist\.
  Invoke-Checked 'build librime deps' { cmd /c build.bat deps release }
  Invoke-Checked 'build librime' { cmd /c build.bat release }
  foreach ($f in 'dist\lib\rime.dll', 'dist\lib\rime.lib', 'share\opencc\TSCharacters.ocd2') {
    if (-not (Test-Path $f)) { throw "librime's build.bat didn't build $f" }
  }

  $rime = Join-Path $Out 'rime'
  if (Test-Path $rime) { Remove-Item -Recurse -Force $rime }
  New-Item -ItemType Directory -Force "$rime\lib", "$rime\include", "$rime\data\opencc" | Out-Null
  Copy-Item dist\lib\rime.dll $rime
  Copy-Item dist\lib\rime.lib "$rime\lib"
  Copy-Item dist\include\rime_*.h "$rime\include"
  Copy-Item share\opencc\* "$rime\data\opencc"
} finally {
  Pop-Location
}

# Rime's shared data: plum's preset recipes (prelude, essay and the stock schemas), as Weasel's build
# fetched them, with Git's bash and relative paths as Weasel's build.bat ran it.
Get-Commit rime/plum $PlumCommit "$Work\plum"
Push-Location $Work
try {
  $env:plum_dir = 'plum'
  $env:rime_dir = 'data'
  # Git's own bash (git.exe is in Git\cmd), not WSL's, which System32 may put first.
  $bash = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) 'bin\bash.exe'
  Invoke-Checked 'fetch Rime data' { & $bash plum/rime-install }
  if (-not (Test-Path data\essay.txt)) { throw "plum didn't fetch Rime's data" }
  Copy-Item -Recurse -Force data\* "$Out\rime\data"
} finally {
  Pop-Location
}

# 64-bit, like rime.dll.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vcvars = & $vswhere -latest -find 'VC\Auxiliary\Build\vcvarsall.bat' | Select-Object -First 1
$perf = (Resolve-Path (Join-Path $PSScriptRoot '..\..\linux\perf-rime.c')).Path
Push-Location $Work
try {
  # A batch file, so cmd gets the quotes as written.
  Set-Content perf-rime.bat "@call `"$vcvars`" x64 >nul && cl /nologo /O2 /MT `"/I$Out\rime\include`" `"/Fe$Out\perf-rime.exe`" `"$perf`" psapi.lib"
  Invoke-Checked 'build perf-rime' { cmd /c perf-rime.bat }
} finally {
  Pop-Location
}
