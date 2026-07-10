[CmdletBinding()]
param(
    [string]$BuildRoot = (Join-Path $env:LOCALAPPDATA 'codex-usage-statusline')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$npmRoot = (& npm root -g 2>&1 | Out-String).Trim()
$installedBinary = Join-Path $npmRoot '@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
$backup = Get-ChildItem (Join-Path $BuildRoot 'backups') -Filter 'codex-*.exe' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $backup) { throw "No backup found under $BuildRoot\backups." }
if (-not (Test-Path -LiteralPath $installedBinary)) { throw "Codex binary not found at $installedBinary." }

Copy-Item -LiteralPath $backup.FullName -Destination $installedBinary -Force
Write-Host "Restored original Codex from $($backup.FullName)." -ForegroundColor Green
Write-Host 'Restart Codex to finish uninstalling the custom statusline.'

