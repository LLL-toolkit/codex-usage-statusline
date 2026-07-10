[CmdletBinding()]
param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'codex-usage-statusline'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectVersion = '0.3.0'
$SupportedCodexVersion = '0.144.1'

function Get-Sha256([string]$Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Normalize-PathEntry([string]$Path) {
    if ($null -eq $Path) { return '' }
    $Path.Trim().Trim('"').TrimEnd('\', '/').ToLowerInvariant()
}

function Remove-PathEntry([string]$CurrentPath, [string]$Entry) {
    $wanted = Normalize-PathEntry $Entry
    (@($CurrentPath -split ';' | Where-Object {
        $_ -and (Normalize-PathEntry $_) -ne $wanted
    })) -join ';'
}

function Add-PathEntry([string]$CurrentPath, [string]$Entry) {
    $wanted = Normalize-PathEntry $Entry
    $kept = @($CurrentPath -split ';' | Where-Object {
        $_ -and (Normalize-PathEntry $_) -ne $wanted
    })
    (@($Entry) + $kept) -join ';'
}

function Publish-EnvironmentChange {
    if (-not ('CodexStatuslineEnvironment' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexStatuslineEnvironment {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint message, UIntPtr wParam, string lParam,
        uint flags, uint timeout, out UIntPtr result);
}
'@
    }
    $result = [UIntPtr]::Zero
    [void][CodexStatuslineEnvironment]::SendMessageTimeout(
        [IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result)
}

function Enter-StateLock([string]$Root) {
    $normalized = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)) } finally { $sha.Dispose() }
    $suffix = -join ($digest | ForEach-Object { $_.ToString('x2') })
    $mutex = New-Object Threading.Mutex($false, "Global\CodexUsageStatusline-$suffix")
    try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        $mutex.Dispose()
        throw 'Another codex-usage-statusline install or uninstall is already running.'
    }
    $mutex
}

function Assert-OwnedPath([string]$Path, [string]$Root) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the installer state root: $pathFull"
    }
}

function Assert-SamePath([string]$Actual, [string]$Expected, [string]$Label) {
    $actualFull = [IO.Path]::GetFullPath($Actual).TrimEnd('\', '/')
    $expectedFull = [IO.Path]::GetFullPath($Expected).TrimEnd('\', '/')
    if (-not $actualFull.Equals($expectedFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The installation manifest contains an unexpected $Label path: $actualFull"
    }
}

function Assert-SafeStateRoot([string]$Root) {
    if (-not $Root) { throw 'The installer state root must not be empty.' }
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $volumeRoot = [IO.Path]::GetPathRoot($full).TrimEnd('\', '/')
    $homeFull = [IO.Path]::GetFullPath($HOME).TrimEnd('\', '/')
    if (-not $full -or $full -eq $volumeRoot -or $full -eq $homeFull) {
        throw "Unsafe installer state root: $full"
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The installer state root must not be a reparse point: $full"
        }
    }
}

function Remove-OwnedPath([string]$Path, [string]$Root) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-OwnedPath $Path $Root
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to recursively remove a reparse point: $Path"
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

if ($env:CODEX_USAGE_STATUSLINE_TEST_MODE -eq '1') { return }

$stateMutex = Enter-StateLock $StateRoot
try {
Assert-SafeStateRoot $StateRoot
$manifestPath = Join-Path $StateRoot 'active-install.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "No active codex-usage-statusline installation was found at $manifestPath"
}
$manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
if ($manifest.schemaVersion -ne 3 -or $manifest.installMode -ne 'side-by-side-path-launcher') {
    throw 'The installation manifest uses an unsupported schema. Preserve it and reinstall the matching project version.'
}
if ($manifest.projectVersion -ne $ProjectVersion -or $manifest.codexVersion -ne $SupportedCodexVersion) {
    throw 'The installation manifest belongs to a different project or Codex version. Use its matching uninstaller.'
}

$expectedLauncherDirectory = Join-Path $StateRoot 'bin'
$expectedLauncherPath = Join-Path $expectedLauncherDirectory 'codex.cmd'
$expectedBundlePath = Join-Path (Join-Path $StateRoot 'versions') "$ProjectVersion-codex-$SupportedCodexVersion"
Assert-SamePath $manifest.launcherDirectory $expectedLauncherDirectory 'launcher directory'
Assert-SamePath $manifest.launcherPath $expectedLauncherPath 'launcher'
Assert-SamePath $manifest.customBundlePath $expectedBundlePath 'custom bundle'
Assert-OwnedPath $manifest.launcherDirectory $StateRoot
Assert-OwnedPath $manifest.launcherPath $manifest.launcherDirectory
Assert-OwnedPath $manifest.customBundlePath $StateRoot
Assert-OwnedPath $manifest.customBinaryPath $manifest.customBundlePath
$previousUserPath = [string]$manifest.previousUserPath
$expectedInstalledUserPath = Add-PathEntry $previousUserPath $expectedLauncherDirectory
if ([string]$manifest.installedUserPath -ne $expectedInstalledUserPath) {
    throw 'The installation manifest contains an invalid PATH transition.'
}
foreach ($hashRecord in @(
    [pscustomobject]@{ Name = 'launcherSha256'; Value = [string]$manifest.launcherSha256 }
    [pscustomobject]@{ Name = 'customBinarySha256'; Value = [string]$manifest.customBinarySha256 }
)) {
    if ($hashRecord.Value -notmatch '^[0-9a-f]{64}$') {
        throw "The installation manifest contains an invalid $($hashRecord.Name)."
    }
}

$filesPreserved = $false
if (Test-Path -LiteralPath $manifest.customBinaryPath) {
    $customHash = Get-Sha256 $manifest.customBinaryPath
    if ($customHash -ne $manifest.customBinarySha256) {
        $filesPreserved = $true
        Write-Warning "The customized binary changed after installation, so its bundle was preserved at $($manifest.customBundlePath)."
    }
}
if (Test-Path -LiteralPath $manifest.launcherPath) {
    $launcherHash = Get-Sha256 $manifest.launcherPath
    if ($launcherHash -ne $manifest.launcherSha256) {
        $filesPreserved = $true
        Write-Warning "The launcher changed after installation, so it was preserved at $($manifest.launcherPath)."
    }
}

$currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($null -eq $currentUserPath) { $currentUserPath = '' }
if ($currentUserPath -eq [string]$manifest.installedUserPath) {
    $cleanUserPath = $previousUserPath
} else {
    $cleanUserPath = Remove-PathEntry $currentUserPath $manifest.launcherDirectory
    $previousEntry = @($previousUserPath -split ';' | Where-Object {
        $_ -and (Normalize-PathEntry $_) -eq (Normalize-PathEntry $manifest.launcherDirectory)
    } | Select-Object -First 1)
    if ($previousEntry.Count -eq 1) { $cleanUserPath = "$($previousEntry[0]);$cleanUserPath".TrimEnd(';') }
}
[Environment]::SetEnvironmentVariable('Path', $cleanUserPath, 'User')
try { Publish-EnvironmentChange } catch { Write-Warning "PATH was updated, but the environment-change broadcast failed: $($_.Exception.Message)" }

if (-not $filesPreserved) {
    Remove-OwnedPath $manifest.launcherDirectory $StateRoot
    Remove-OwnedPath $manifest.customBundlePath $StateRoot
}

$completedManifest = Join-Path $StateRoot ("uninstalled-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Move-Item -LiteralPath $manifestPath -Destination $completedManifest
Write-Host 'codex-usage-statusline was disabled. The official Codex installation was never modified.' -ForegroundColor Green
if ($filesPreserved) {
    Write-Warning 'Modified installer-owned files were left in place, but their PATH entry was removed.'
}
Write-Host 'Open a new terminal so the PATH change takes effect.'
} finally {
    if ($stateMutex) {
        try { $stateMutex.ReleaseMutex() } catch { }
        $stateMutex.Dispose()
    }
}
