<#
Python's embeddable package for the Configurator's sync (#180), which runs sync-server/sebtype_sync.py
with it: Windows has no Python of its own. sebtype.iss runs this while it compiles and packs -Dir into
{app}\python. Kept from the last run while it is there; checked against python.org's SHA-256.

  python.ps1 -Dir <folder>
#>
param([Parameter(Mandatory)][string]$Dir)
$ErrorActionPreference = 'Stop'
$Version = '3.14.10'
$Sha256 = '90905e64a840557d8c1bc4f5b74db3d7ee85e3ffb217611cac1c7813acea4159'
if (Test-Path (Join-Path $Dir 'python.exe')) { exit 0 }
$zip = Join-Path $env:TEMP "python-$Version-embed-amd64.zip"
curl.exe -sSfL --retry 3 -o $zip "https://www.python.org/ftp/python/$Version/python-$Version-embed-amd64.zip"
if ($LASTEXITCODE) { throw "Python ${Version}: download failed ($LASTEXITCODE)" }
if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $Sha256) { throw "Python ${Version}: checksum mismatch" }
Expand-Archive $zip $Dir -Force
Remove-Item $zip
