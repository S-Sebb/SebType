# Builds SebType's Windows text service and server (windows/, over core/):
#   windows/build.ps1 -Rime <dir> [-Out <dir>] [-Work <dir>]
# -Rime holds SebType's librime as pc/windows/rime/build.ps1 leaves it (include\, lib\rime.lib,
# rime.dll). Needs Visual Studio 2022 with C++, vcpkg ($env:VCPKG_INSTALLATION_ROOT), Python and curl
# (GitHub's windows-2022 runner has them; .github/workflows/windows-setup.yml runs this). Writes
# sebtype-server.exe and sebtype.dll (64-bit), x86\sebtype.dll (for 32-bit apps), 中文's model chinese.gguf
# and licenses\, the licences of what the server links in, to -Out.
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

# Protobuf for the core's Mozc protocol and OpenCC for 中文's model's 繁 (#495), with the C++ runtime linked in like
# everything else here.
$vcpkg = $env:VCPKG_INSTALLATION_ROOT
Invoke-Checked 'vcpkg install' { & "$vcpkg\vcpkg.exe" install protobuf:x64-windows-static opencc:x64-windows-static }

# llama.cpp for 中文's model, at engines/sebtype-lm/fetch-llama.sh's commit.
$llamaCommit = (Select-String -Path "$src\..\engines\sebtype-lm\fetch-llama.sh" -Pattern '^COMMIT=(\w+)').Matches[0].Groups[1].Value
$llama = "$Work\llama.cpp-$($llamaCommit.Substring(0, 12))"
if (-not (Test-Path "$llama\CMakeLists.txt")) {
  if (Test-Path $llama) { Remove-Item -Recurse -Force $llama }
  Invoke-Checked 'init llama.cpp' { git -c core.autocrlf=false init -q $llama }
  Invoke-Checked 'fetch llama.cpp' { git -C $llama fetch -q --depth 1 https://github.com/ggml-org/llama.cpp $llamaCommit }
  Invoke-Checked 'check out llama.cpp' { git -C $llama -c core.autocrlf=false checkout -q FETCH_HEAD }
}

$common = @("-DRIME_ROOT=$Rime", "-DSEBTYPE_ICONS=$Work\icons")
Invoke-Checked 'configure x64' {
  cmake -S $src -B "$Work\x64" -A x64 @common "-DCMAKE_TOOLCHAIN_FILE=$vcpkg\scripts\buildsystems\vcpkg.cmake" `
    -DVCPKG_TARGET_TRIPLET=x64-windows-static -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON "-DLLAMA_DIR=$llama"
}
Invoke-Checked 'build x64' { cmake --build "$Work\x64" --config Release --parallel }
Invoke-Checked 'candidate layout test' { & "$Work\x64\Release\candidate-layout-test.exe" }
Invoke-Checked 'pipe test' { & "$Work\x64\Release\pipe-test.exe" }
# 32-bit apps load a 32-bit text service; it reaches the 64-bit server over its pipe.
Invoke-Checked 'configure x86' { cmake -S $src -B "$Work\x86" -A Win32 @common -DSEBTYPE_TIP_ONLY=ON }
Invoke-Checked 'build x86' { cmake --build "$Work\x86" --config Release --parallel }

Copy-Item "$Work\x64\Release\sebtype-server.exe", "$Work\x64\Release\sebtype.dll", "$src\..\engines\sebtype-lm\chinese.gguf" $Out -Force
Copy-Item "$Work\x86\Release\sebtype.dll" "$Out\x86" -Force

# The licences of what the server links in (#544): llama.cpp's (ggml's too) with the notices of the code ggml
# took from llamafile and YaRN, as the phone has them, and each vcpkg package's (protobuf with Abseil and
# utf8_range, OpenCC with marisa-trie, darts-clone and RapidJSON).
$licences = New-Item -ItemType Directory -Force "$Out\licenses"
Copy-Item "$llama\LICENSE" "$licences\llama.cpp-LICENSE.txt"
Copy-Item "$src\..\android\native\src\main\assets\licenses\Llamafile-sgemm-LICENSE.txt", "$src\..\android\native\src\main\assets\licenses\YaRN-LICENSE.txt" $licences
foreach ($c in Get-ChildItem "$vcpkg\installed\x64-windows-static\share\*\copyright") {
  Copy-Item $c "$licences\$($c.Directory.Name)-LICENSE.txt"
}
