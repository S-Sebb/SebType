<#
An update's admin side on Windows (#422), elevated by UAC: update-user.ps1 starts it from SebType's folder
in Program Files, where only admins can write, so it can't have been changed:

    powershell -File start-setup.ps1 -Setup <the download> -Sha <its SHA-256 from the release> [-Log <file>]

Copies the download into a new folder in updates\ next to it (also only admins can write there), checks the
copy's SHA-256 there and runs Setup from it, as an update does: silent but for its progress, the languages
chosen before, and with /NOUSERSTEPS only the machine's part (update-user.ps1 does the person's as them). So a
download changed after the Configurator's check never runs. Older copies go first; -Log: Setup's, for the tests.
Prints "started <pid> <copy>" once Setup runs, waits for it and exits with its exit code; 90: the copy isn't
the release's; 91 and the error's message: anything else.
#>
param([Parameter(Mandatory)][string]$Setup, [Parameter(Mandatory)][string]$Sha, [string]$Log)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
trap { [Console]::Out.WriteLine("error: $($_.Exception.Message)"); exit 91 }
$Root = Join-Path $PSScriptRoot 'updates'
$Arguments = @('/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOUSERSTEPS') + @(if ($Log) { "/LOG=`"$Log`"" })
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
