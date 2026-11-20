# An update's admin side on Windows (#422), elevated by UAC: the Configurator builds it in and passes it
# as -EncodedCommand, after lines that set $Setup (the download), $Sha (its SHA-256 from the release),
# $Arguments (Setup's) and, for the tests only, $Root: else SebType's folder in Program Files, where
# only admins can write.
# Copies the download into a new folder in $Root, checks the copy's SHA-256 there and starts Setup from
# it, so a download changed after the Configurator's check isn't run. Older copies go first.
# Prints "started <pid> <copy>" once Setup runs, waits for it and exits with its exit code; 90: the copy
# isn't the release's; 91 and the error's message: anything else.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
trap { [Console]::Out.WriteLine("error: $($_.Exception.Message)"); exit 91 }
if (-not $Root) { $Root = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'SebType\updates' }
New-Item -ItemType Directory -Force $Root | Out-Null
Get-ChildItem -LiteralPath $Root -Directory -Filter 'update-*' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$d = Join-Path $Root ('update-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $d | Out-Null
$copy = Join-Path $d ([IO.Path]::GetFileName($Setup))
Copy-Item -LiteralPath $Setup -Destination $copy
# .NET's SHA-256, not Get-FileHash: its module needn't load (a PSModulePath of PowerShell 7's hides it).
$f = [IO.File]::OpenRead($copy)
try { $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($f)).Replace('-', '') } finally { $f.Dispose() }
if ($hash -ne $Sha) {
  Remove-Item -Recurse -Force $d
  [Console]::Out.WriteLine("$([IO.Path]::GetFileName($Setup)) isn't the release's")
  exit 90
}
$p = Start-Process -PassThru -FilePath $copy -ArgumentList $Arguments
[Console]::Out.WriteLine("started $($p.Id) $copy"); [Console]::Out.Flush()
$p.WaitForExit()
exit $p.ExitCode
