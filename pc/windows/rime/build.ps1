# Builds SebType's librime for Windows: engines/librime (librime $RimeVersion, the version SebType's Android
# and Linux builds use too; #101, #133), 64-bit, with librime-lua and -octagram merged into rime.dll
# as librime's own Windows release does (without -predict, which no schema SebType ships uses, #219), and Rime's shared data.
#   pc/windows/rime/build.ps1 [-Out <dir>] [-Work <dir>]
# Needs Visual Studio 2022 with C++, git, 7z and Git's bash (GitHub's windows-2022 runner has them all;
# .github/workflows/windows-setup.yml runs this). The third-party code SebType doesn't change is fetched at
# pinned commits: librime's dependencies and plugins, and plum with its preset packages. Boost's headers are
# downloaded into $env:BOOST_ROOT when they aren't there yet. Writes to -Out rime\ (rime.dll, lib\rime.lib,
# include\, data\, Rime's shared data with OpenCC's, and licenses\, the licences of what rime.dll carries and
# of the shared data) for windows/build.ps1 and SebType's setup, and perf-rime.exe (pc/linux/perf-rime.c) for
# pc/windows/perf-rime.ps1.
param(
  [string]$Out = (Join-Path $PSScriptRoot '..\..\..\build\rime'),
  [string]$Work = (Join-Path $PSScriptRoot '..\..\..\build\rime-src')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RimeVersion = '1.16.1'
# What librime $RimeVersion's submodules pin, and the plugins its own Windows release merges into
# rime.dll, at the commits its version-info.txt names (rime-ice's Lua needs librime-lua); octagram at the
# phone's commit, BSD-3-Clause since its relicence (#544).
$RimeDeps = @(
  @{ Dir = 'deps\glog'; Repo = 'google/glog'; Commit = '7b134a5c82c0c0b5698bb6bf7a835b230c5638e4' }
  @{ Dir = 'deps\leveldb'; Repo = 'google/leveldb'; Commit = '99b3c03b3284f5886f9ef9a4ef703d57373e61be' }
  @{ Dir = 'deps\marisa-trie'; Repo = 's-yata/marisa-trie'; Commit = '3e87d53b78e15f2f43783d5e376561a8c9722051' }
  @{ Dir = 'deps\opencc'; Repo = 'BYVoid/OpenCC'; Commit = '556ed22496d650bd0b13b6c163be9814637970ae' }
  @{ Dir = 'deps\yaml-cpp'; Repo = 'jbeder/yaml-cpp'; Commit = '2f86d13775d119edbb69af52e5f566fd65c6953b' }
  @{ Dir = 'plugins\lua'; Repo = 'hchunhui/librime-lua'; Commit = '68f9c364a2d25a04c7d4794981d7c796b05ab627' }
  @{ Dir = 'plugins\octagram'; Repo = 'lotem/librime-octagram'; Commit = '57d18b9f58e5284bd891d559f6bdd16cf60341e9' }
)
# rime/plum at the commit Weasel 0.17.4 pinned, which fetches Rime's preset data, as SebType shipped it before #190.
$PlumCommit = 'cab9ed35289f2022b6888503750d2dfb1851dbe0'
# Its preset packages (preset-packages.conf), which plum itself takes at their heads: at the heads of 2026-11-24 (#553).
$PlumPackages = [ordered]@{
  'bopomofo' = '6085c9a38a4a728047862b33d67eee18aa86f3b9'
  'cangjie' = 'fcb3d7dd94ac1304663d575727d24d8107f6b082'
  'essay' = 'd95eeae056df429ecf993038c325a216f0b28c5b'
  'luna-pinyin' = '84685a7e7793e43278ca29368977b79d74d37a03'
  'prelude' = '082425ea0684bca36474415d4a0e8db9b016487e'
  'stroke' = '1e8fff9b9494ddec23b0cbc526bcfd8171a6fd48'
  'terra-pinyin' = '723e51bc266cf9464530c1ddedb856aa18e3da34'
}
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
  Invoke-Checked 'download boost' { curl.exe --limit-rate 35M -sSfL --retry 3 -o $archive "https://archives.boost.io/release/$BoostVersion/source/$(Split-Path -Leaf $archive)" }
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

  # The licences of what rime.dll carries (#544), from the sources it was built from; the phone's copies
  # (android/native/src/main/assets/licenses) where the sources have none: OpenCC's bundled RapidJSON, and
  # Boost's, whose headers are kept without it.
  $assets = Join-Path $PSScriptRoot '..\..\..\android\native\src\main\assets\licenses'
  $licences = @{
    'librime' = 'LICENSE'; 'librime-lua' = 'plugins\lua\LICENSE'; 'librime-octagram' = 'plugins\octagram\LICENSE'
    'glog' = 'deps\glog\COPYING'; 'LevelDB' = 'deps\leveldb\LICENSE'; 'marisa-trie' = 'deps\marisa-trie\COPYING.md'
    'OpenCC' = 'deps\opencc\LICENSE'; 'yaml-cpp' = 'deps\yaml-cpp\LICENSE'
    'darts-clone' = 'include\COPYING.darts-clone'  # librime's and OpenCC's
    'RapidJSON' = "$assets\RapidJSON-LICENSE.txt"; 'Boost' = "$assets\Boost-LICENSE.txt"
  }
  New-Item -ItemType Directory "$rime\licenses" | Out-Null
  foreach ($name in $licences.Keys) { Copy-Item $licences[$name] "$rime\licenses\$name-LICENSE.txt" }
  # Lua's notice ends lua.h; the X11 keysym names' is lines 2-46 of keysymdef.h, as the phone takes it.
  $lua = Get-Content plugins\lua\thirdparty\lua5.4\lua.h
  $from = ($lua | Select-String -SimpleMatch '* Copyright (C)' | Select-Object -Last 1).LineNumber - 1
  $lua[$from..($lua.Count - 1)] | Where-Object { $_ -match '^\* ?' -and $_ -notmatch '^\*{5}' } |
    ForEach-Object { $_ -replace '^\* ?', '' } | Set-Content "$rime\licenses\Lua-LICENSE.txt"
  (Get-Content include\X11\keysymdef.h)[1..45] | Set-Content "$rime\licenses\X11-keysym-LICENSE.txt"
} finally {
  Pop-Location
}

# Rime's shared data: plum's preset recipes (prelude, essay and the stock schemas), as Weasel's build
# fetched them, with Git's bash and relative paths as Weasel's build.bat ran it.
Get-Commit rime/plum $PlumCommit "$Work\plum"
# Each package at its pin where plum looks for it; no_update below has plum install it as found.
foreach ($name in $PlumPackages.Keys) { Get-Commit "rime/rime-$name" $PlumPackages[$name] "$Work\plum\package\rime\$name" }
Push-Location $Work
try {
  $env:plum_dir = 'plum'
  $env:rime_dir = 'data'
  $env:no_update = '1'
  # Git's own bash (git.exe is in Git\cmd), not WSL's, which System32 may put first.
  $bash = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) 'bin\bash.exe'
  Invoke-Checked 'fetch Rime data' { & $bash plum/rime-install }
  if (-not (Test-Path data\essay.txt)) { throw "plum didn't fetch Rime's data" }
  Copy-Item -Recurse -Force data\* "$Out\rime\data"
  # Each preset package's licence (LGPL-3.0), next to rime.dll's; a package plum added would have none.
  $packages = Get-ChildItem plum\package\rime -Directory
  if (Compare-Object $packages.Name @($PlumPackages.Keys)) { throw "plum's packages aren't the pinned ones: $($packages.Name)" }
  foreach ($p in $packages) { Copy-Item "$($p.FullName)\LICENSE" "$Out\rime\licenses\rime-$($p.Name)-LICENSE.txt" }
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
