# An update's admin side on Windows (#422), elevated by UAC: the Configurator builds it in and passes it
# as -EncodedCommand, after lines that set $Setup (the download), $Sha (its SHA-256 from the release),
# $Arguments (Setup's) and, for the tests only, $Root: else SebType's folder in Program Files, where
# only admins can write.
# Copies the download into a new folder in $Root, checks the copy's SHA-256 there and starts Setup from
# it, so a download changed after the Configurator's check isn't run. Older copies go first.
# Exit 0 and "started <pid> <copy>" once Setup runs; 3: the copy isn't the release's.
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'SebType\updates' }
New-Item -ItemType Directory -Force $Root | Out-Null
Get-ChildItem -LiteralPath $Root -Directory -Filter 'update-*' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$d = Join-Path $Root ('update-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $d | Out-Null
$copy = Join-Path $d ([IO.Path]::GetFileName($Setup))
Copy-Item -LiteralPath $Setup -Destination $copy
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $copy).Hash -ne $Sha) {
  Remove-Item -Recurse -Force $d
  [Console]::Out.WriteLine("$([IO.Path]::GetFileName($Setup)) isn't the release's")
  exit 3
}
$p = Start-Process -PassThru -FilePath $copy -ArgumentList $Arguments
[Console]::Out.WriteLine("started $($p.Id) $copy")
exit 0
