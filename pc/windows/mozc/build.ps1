<#
Builds SebType's Mozc server for Windows (#65, #190): mozc_server.exe from engines/mozc (Mozc 3.35.6354 with
SebType's changes), and the C++ runtime DLLs it was built with, into WorkDir\out\mozc-server. SebType's text
service (windows/) talks to it; nothing else of Mozc's Windows client is built. Prints the folder's path.

    pwsh pc/windows/mozc/build.ps1 [-WorkDir D:\sebtype-mozc] [-BazelCache <dir>]

Needs Visual Studio 2022 or its Build Tools (C++ x64 tools, a Windows 11 SDK) and Python 3.12+; it says how
to install what is missing. It fetches the rest itself: Bazelisk pinned by checksum (versions.psd1), LLVM and
MSYS2 by Mozc's own update_deps.py. It builds a copy of engines/mozc that stays in WorkDir, so a rebuild
compiles only what changed; WorkDir should be a short path (Bazel and MAX_PATH). -BazelCache keeps Bazel's
disk and repository caches in that folder: CI, whose WorkDir starts empty, restores it from main's last build.
#>
param([string]$WorkDir = "$env:SystemDrive\sebtype-mozc", [string]$BazelCache)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$v = Import-PowerShellDataFile "$PSScriptRoot\versions.psd1"
$source = Resolve-Path "$PSScriptRoot\..\..\..\engines\mozc"

# Preflight: the tools Mozc needs and doesn't fetch.
$missing = @()
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = if (Test-Path $vswhere) {
    & $vswhere -latest -products * -version '[17.0,19.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $vs) { $missing += 'Visual Studio 2022 Build Tools with C++ x64 tools' }
if (-not (Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Include\10.0.2*" -ErrorAction SilentlyContinue)) {
    $missing += 'a Windows 11 SDK'
}
$python = Get-Command python -ErrorAction SilentlyContinue | Where-Object Source -NotLike '*WindowsApps*'
if (-not $python -or [version](& python -c 'import platform; print(platform.python_version())') -lt [version]'3.12') {
    $missing += 'Python 3.12+'
}
if ($missing) {
    Write-Error ("missing: $($missing -join ', '). Install (as admin):`n" +
        "  winget install Microsoft.VisualStudio.2022.BuildTools --override `"--quiet --wait --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.26100`"`n" +
        "  winget install Python.Python.3.13")
}

New-Item -ItemType Directory -Force "$WorkDir\dl", "$WorkDir\out" | Out-Null
$bazelisk = "$WorkDir\dl\$($v.BazeliskUrl -replace '.*/', '')"
if (-not (Test-Path $bazelisk) -or (Get-FileHash $bazelisk).Hash -ne $v.BazeliskSha256) {
    curl.exe -sfL --retry 3 -o "$bazelisk.part" $v.BazeliskUrl
    if ((Get-FileHash "$bazelisk.part").Hash -ne $v.BazeliskSha256) { throw "checksum mismatch: $($v.BazeliskUrl)" }
    Move-Item -Force "$bazelisk.part" $bazelisk
}
# Source: engines/mozc copied over the kept tree, which keeps the build's own files (Bazel's links) and
# leaves unchanged files as they are (Bazel rebuilds by content). robocopy's exit codes below 8 mean success.
& { $PSNativeCommandUseErrorActionPreference = $false; robocopy $source "$WorkDir\mozc" /E /NFL /NDL /NJH /NJS /NP | Out-Null }
if ($LASTEXITCODE -ge 8) { throw "copying $source failed: robocopy exit code $LASTEXITCODE" }
$src = "$WorkDir\mozc\src"

$start = Get-Date
# Mozc's own VS lookup (vs_util.py) also requires the VC.Redist.14.Latest component, which the Build
# Tools install above lacks though the CRT it needs is there; hand it the VS found above instead.
$env:BAZEL_VC = "$vs\VC"
Push-Location $src
try {
    # Mozc's pinned LLVM and MSYS2; the server needs none of its Qt, Ninja (Qt's build) or WiX (the MSI).
    python build_tools/update_deps.py --nondk --noqt --noninja --nowix
    $cache = if ($BazelCache) { "--disk_cache=$BazelCache\disk", "--repository_cache=$BazelCache\repo" }
    # Mozc's .bazelrc turns on --windows_enable_symlinks, which needs Developer Mode or admin rights.
    & $bazelisk "--output_user_root=$WorkDir\bazel" --nowindows_enable_symlinks build //server:mozc_server_win --config release_build `
        --jobs=8 --platforms=//:windows-x86_64 @cache *> "$WorkDir\out\build.log"
} catch {
    # To the host: the caller keeps only the folder's path from the output.
    Get-Content "$WorkDir\out\build.log" -Tail 40 -ErrorAction SilentlyContinue | Write-Host
    throw
} finally { Pop-Location }

# mozc_server.exe links the C++ runtime dynamically and loads it from its own folder (build_defs.bzl), so
# the DLLs of the toolset that built it go next to it, as Mozc's MSI put them: Windows' own may be older.
$out = "$WorkDir\out\mozc-server"
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item "$src\bazel-bin\server\mozc_server_win.exe" "$out\mozc_server.exe"
$crt = Get-ChildItem "$vs\VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT" -Directory | Sort-Object FullName | Select-Object -Last 1
if (-not $crt) { throw "no C++ runtime in $vs\VC\Redist\MSVC" }
Copy-Item "$($crt.FullName)\msvcp140*.dll", "$($crt.FullName)\vcruntime140*.dll" $out
Write-Host "built in $([int]((Get-Date) - $start).TotalMinutes) min (log: $WorkDir\out\build.log; C++ runtime from $($crt.FullName))"
$out
