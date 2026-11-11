<#
Builds SebType's Mozc for Windows (#65): upstream Mozc at the tag in versions.psd1, plus
caps-lock-icon.patch (the Caps Lock icon), japanese-name.patch (the name 日本語), menu.patch (the
language bar's one switch, あ → ア, and Alt+` as a two-way あ ⇄ ア), shift-tap.patch (Shift tap from
English back to あ) and the Set E tray icons from pc/icons. Prints the
installer's path.

    pwsh pc/windows/mozc/build.ps1 [-WorkDir D:\sebtype-mozc]

Needs Visual Studio 2022 or its Build Tools (C++ x64 tools, ATL, a Windows 11 SDK), Python 3.12+ and a
.NET 8+ SDK; it says how to install what is missing. It fetches the rest itself, each pinned by checksum
(Mozc's source, Bazelisk, resvg, CMake) or by Mozc's own update_deps.py (LLVM, MSYS2, Ninja, Qt, WiX). The
tree stays in WorkDir, so a rebuild compiles only what changed. The first build takes about 40 minutes and
10 GB; WorkDir should be a short path (Bazel and MAX_PATH). -BazelCache keeps Bazel's disk and repository
caches in that folder: CI, whose WorkDir starts empty, restores it from main's last build.
#>
param([string]$WorkDir = "$env:SystemDrive\sebtype-mozc", [string]$BazelCache)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$v = Import-PowerShellDataFile "$PSScriptRoot\versions.psd1"
$icons = Resolve-Path "$PSScriptRoot\..\..\icons"

# Preflight: the tools Mozc needs and doesn't fetch.
$missing = @()
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = if (Test-Path $vswhere) {
    & $vswhere -latest -products * -version '[17.0,19.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.ATL -property installationPath
}
if (-not $vs) { $missing += 'Visual Studio 2022 Build Tools with C++ x64 tools and ATL' }
if (-not (Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Include\10.0.2*" -ErrorAction SilentlyContinue)) {
    $missing += 'a Windows 11 SDK'
}
$python = Get-Command python -ErrorAction SilentlyContinue | Where-Object Source -NotLike '*WindowsApps*'
if (-not $python -or [version](& python -c 'import platform; print(platform.python_version())') -lt [version]'3.12') {
    $missing += 'Python 3.12+'
}
if (-not ((& dotnet --list-sdks 2>$null) -match '^([89]|\d\d)\.')) { $missing += '.NET 8+ SDK' }
if ($missing) {
    Write-Error ("missing: $($missing -join ', '). Install (as admin):`n" +
        "  winget install Microsoft.VisualStudio.2022.BuildTools --override `"--quiet --wait --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.ATL --add Microsoft.VisualStudio.Component.Windows11SDK.26100`"`n" +
        "  winget install Python.Python.3.13 Microsoft.DotNet.SDK.8")
}

New-Item -ItemType Directory -Force "$WorkDir\dl", "$WorkDir\out" | Out-Null
function Get-Pinned($url, $sha256) {
    $file = "$WorkDir\dl\$($url -replace '.*/', '')"
    if (-not (Test-Path $file) -or (Get-FileHash $file).Hash -ne $sha256) {
        curl.exe -sfL --retry 3 -o "$file.part" $url
        if ((Get-FileHash "$file.part").Hash -ne $sha256) { throw "checksum mismatch: $url" }
        Move-Item -Force "$file.part" $file
    }
    $file
}

# Source: the pinned tarball unpacked over the kept tree, which puts back upstream's files (Bazel
# rebuilds by content, so unchanged files cost nothing), then SebType's patch and icons.
$tarball = Get-Pinned "https://codeload.github.com/google/mozc/tar.gz/$($v.MozcCommit)" $v.MozcSha256
$bazelisk = Get-Pinned $v.BazeliskUrl $v.BazeliskSha256
$resvg = "$WorkDir\dl\resvg.exe"
tar -xf (Get-Pinned $v.ResvgUrl $v.ResvgSha256) -C "$WorkDir\dl" resvg.exe
# Qt's configure needs CMake, which the Build Tools lack without their CMake component.
$cmakeZip = Get-Pinned $v.CMakeUrl $v.CMakeSha256
if (-not (Test-Path ($cmake = $cmakeZip -replace '\.zip$'))) { tar -xf $cmakeZip -C "$WorkDir\dl" }
$env:Path = "$cmake\bin;$env:Path"
New-Item -ItemType Directory -Force "$WorkDir\mozc" | Out-Null
tar -xzf $tarball -C "$WorkDir\mozc" --strip-components=1
$src = "$WorkDir\mozc\src"
Get-ChildItem "$PSScriptRoot\*.patch" | ForEach-Object { python -I "$PSScriptRoot\apply_patch.py" $_.FullName $src }
python -I "$PSScriptRoot\make_icons.py" $resvg $icons $src

$start = Get-Date
# Mozc's own VS lookup (vs_util.py) also requires the VC.Redist.14.Latest component, which the Build
# Tools install above lacks though the CRT it needs is there; hand it the VS found above instead.
$env:BAZEL_VC = "$vs\VC"
Push-Location $src
try {
    # Mozc's own pinned dependencies, and Qt for its settings tools; each step skips what is done.
    python build_tools/update_deps.py --nondk
    if (-not (Test-Path third_party\qt\bin)) {
        python build_tools/build_qt.py --release --confirm_license --vcvarsall_path "$vs\VC\Auxiliary\Build\vcvarsall.bat"
        Remove-Item -Recurse -Force third_party\qt_src -ErrorAction SilentlyContinue
    }
    $cache = if ($BazelCache) { "--disk_cache=$BazelCache\disk", "--repository_cache=$BazelCache\repo" }
    # Mozc's .bazelrc turns on --windows_enable_symlinks, which needs Developer Mode or admin rights.
    & $bazelisk "--output_user_root=$WorkDir\bazel" --nowindows_enable_symlinks build package --config release_build --jobs=8 `
        --platforms=//:windows-x86_64 @cache *> "$WorkDir\out\build.log"
} catch {
    Get-Content "$WorkDir\out\build.log" -Tail 40 -ErrorAction SilentlyContinue
    throw
} finally { Pop-Location }

$msi = "$WorkDir\out\SebType-Mozc-$($v.MozcVersion)-sebtype$($v.SebTypeRelease).msi"
Copy-Item -Force "$src\bazel-bin\win32\installer\Mozc64.msi" $msi
Write-Host "built in $([int]((Get-Date) - $start).TotalMinutes) min (log: $WorkDir\out\build.log)"
$msi
