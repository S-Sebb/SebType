# Builds SebType's Windows text service and server (windows/, over core/):
#   windows/build.ps1 -Rime <dir> [-Out <dir>] [-Work <dir>]
# -Rime holds SebType's librime as pc/windows/rime/build.ps1 leaves it (include\, lib\rime.lib,
# rime.dll). Needs Visual Studio 2022 with C++, vcpkg ($env:VCPKG_INSTALLATION_ROOT), Python and curl
# (GitHub's windows-2022 runner has them; .github/workflows/windows-setup.yml runs this). Writes
# sebtype-server.exe and sebtype.dll (64-bit) and x86\sebtype.dll (for 32-bit apps) to -Out.
param(
  [Parameter(Mandatory = $true)][string]$Rime,
  [string]$Out = (Join-Path $PSScriptRoot '..\build\windows'),
  [string]$Work = (Join-Path $PSScriptRoot '..\build\windows-work')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Checked([string]$what, [scriptblock]$cmd) {
  & $cmd
  if ($LASTEXITCODE) { throw "$what failed with exit code $LASTEXITCODE" }
}

$Rime = (Resolve-Path $Rime).Path
New-Item -ItemType Directory -Force $Out, "$Out\x86", $Work | Out-Null
$Out = (Resolve-Path $Out).Path
$Work = (Resolve-Path $Work).Path
$src = $PSScriptRoot

Invoke-Checked 'make icons' { python -I "$src\make_icons.py" "$src\..\pc\icons" "$Work\icons" }

# Protobuf for the core's Mozc protocol, with the C++ runtime linked in like everything else here.
$vcpkg = $env:VCPKG_INSTALLATION_ROOT
Invoke-Checked 'vcpkg install protobuf' { & "$vcpkg\vcpkg.exe" install protobuf:x64-windows-static }

$common = @("-DRIME_ROOT=$Rime", "-DSEBTYPE_ICONS=$Work\icons")
Invoke-Checked 'configure x64' {
  cmake -S $src -B "$Work\x64" -A x64 @common "-DCMAKE_TOOLCHAIN_FILE=$vcpkg\scripts\buildsystems\vcpkg.cmake" `
    -DVCPKG_TARGET_TRIPLET=x64-windows-static -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON
}
Invoke-Checked 'build x64' { cmake --build "$Work\x64" --config Release --parallel }
Invoke-Checked 'candidate layout test' { & "$Work\x64\Release\candidate-layout-test.exe" }
Invoke-Checked 'pipe test' { & "$Work\x64\Release\pipe-test.exe" }
# 32-bit apps load a 32-bit text service; it reaches the 64-bit server over its pipe.
Invoke-Checked 'configure x86' { cmake -S $src -B "$Work\x86" -A Win32 @common -DSEBTYPE_TIP_ONLY=ON }
Invoke-Checked 'build x86' { cmake --build "$Work\x86" --config Release --parallel }

Copy-Item "$Work\x64\Release\sebtype-server.exe", "$Work\x64\Release\sebtype.dll" $Out -Force
Copy-Item "$Work\x86\Release\sebtype.dll" "$Out\x86" -Force
