<#
Python's embeddable package for the Configurator's sync (#180), which runs sync-server/sebtype_sync.py
with it: Windows has no Python of its own. The setup CI runs this before ISCC, which packs In\python
into {app}\python. Kept while it is there (CI caches it); checked against python.org's SHA-256.
Only what sync needs is kept (#544): the interpreter, the standard library's zip, and the native modules
for sockets and HTTPS (ssl with OpenSSL, hashlib) and IDNA host names (unicodedata). Its licences go in
licenses\, which Setup installs in {app}\licenses\python: Python's own with the notices of what its
Windows build carries (LICENSE.txt), and CPython's list of the code it incorporates (Doc/license.rst)
with the notice of HACL* (its hashes, in python314.dll), from the release's tag.

  python.ps1 -Dir <folder>
#>
param([Parameter(Mandatory)][string]$Dir)
$ErrorActionPreference = 'Stop'
$Version = '3.14.10'
$Sha256 = '90905e64a840557d8c1bc4f5b74db3d7ee85e3ffb217611cac1c7813acea4159'
$Keep = 'python.exe', 'python314.dll', 'python3.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'python314.zip',
  'python314._pth', 'LICENSE.txt', '_socket.pyd', 'select.pyd', '_ssl.pyd', '_hashlib.pyd', 'libssl-3.dll',
  'libcrypto-3.dll', 'unicodedata.pyd'
$Sources = @{
  'Doc/license.rst' = '8A7329B25131F64B2BEA284155F0824876B1AF9F4A2F970E6335751D97DFA6DD'
  'Modules/_hacl/Hacl_Hash_SHA2.c' = 'F8AF382DE7E29A73C726F9C70770498DDD99E2C4702489ED6E634F0B68597C95'
}
if (Test-Path (Join-Path $Dir 'python.exe')) { exit 0 }
function Get-Checked([string]$url, [string]$file, [string]$sha256) {
  curl.exe --limit-rate 35M -sSfL --retry 3 -o $file $url
  if ($LASTEXITCODE) { throw "${url}: download failed ($LASTEXITCODE)" }
  if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $sha256) { throw "${url}: checksum mismatch" }
}
$zip = Join-Path $env:TEMP "python-$Version-embed-amd64.zip"
Get-Checked "https://www.python.org/ftp/python/$Version/python-$Version-embed-amd64.zip" $zip $Sha256
Expand-Archive $zip $Dir -Force
Remove-Item $zip
$missing = $Keep | Where-Object { -not (Test-Path (Join-Path $Dir $_)) }
if ($missing) { throw "Python ${Version}'s package has no $missing" }
Get-ChildItem $Dir | Where-Object Name -NotIn $Keep | Remove-Item -Recurse -Force

$licences = New-Item -ItemType Directory -Force (Join-Path $Dir 'licenses')
Copy-Item (Join-Path $Dir 'LICENSE.txt') "$licences\Python-LICENSE.txt"
$raw = "https://raw.githubusercontent.com/python/cpython/v$Version"
Get-Checked "$raw/Doc/license.rst" "$licences\Python-incorporated-software.txt" $Sources['Doc/license.rst']
$hacl = Join-Path $env:TEMP 'Hacl_Hash_SHA2.c'
Get-Checked "$raw/Modules/_hacl/Hacl_Hash_SHA2.c" $hacl $Sources['Modules/_hacl/Hacl_Hash_SHA2.c']
# Its notice is the comment that opens each HACL* file.
$c = Get-Content $hacl
$end = ($c | Select-String '^ \*/' | Select-Object -First 1).LineNumber - 1
$c[0..($end - 1)] -replace '^(/\*| \*) ?', '' | Set-Content "$licences\HACL-LICENSE.txt"
Remove-Item $hacl
