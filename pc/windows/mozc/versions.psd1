# SebType's Windows Mozc (#65): engines/mozc and the Set E icons, and the tools that build them.
# Read by build.ps1. Bump SebTypeRelease when engines/mozc or the build changes.
@{
    MozcVersion     = '3.35.6354'                                 # engines/mozc's Mozc release
    BazeliskUrl     = 'https://github.com/bazelbuild/bazelisk/releases/download/v1.30.0/bazelisk-windows-amd64.exe'
    BazeliskSha256  = '5d14a31e9d8a363c48ba1900dbd56764d730835232eb0d113cce255856ffe3ef'
    ResvgUrl        = 'https://github.com/linebender/resvg/releases/download/v0.49.0/resvg-win-x86_64.zip'
    ResvgSha256     = '38af9631b37e61118a32a5ef31e6be6af083eda63b4c17ffc4fdc63e449277df'
    CMakeUrl        = 'https://github.com/Kitware/CMake/releases/download/v3.31.8/cmake-3.31.8-windows-x86_64.zip'
    CMakeSha256     = '81aa9964dbabd71fe02e7ec50472fd3ad56138c49944515ece9001efbff8d719'
    SebTypeRelease  = 4
}
