[CmdletBinding()]
param(
    [ValidateSet('ko', 'en', 'ja')]
    [string]$Language = 'ko',
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'codex-usage-statusline'),
    [string]$ReleaseTag = 'v0.2.0',
    [string]$ReleaseBaseUrl,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ProjectVersion = '0.2.0'
$SupportedCodexVersion = '0.144.1'
$TargetTriple = 'x86_64-pc-windows-msvc'
$ExpectedUpstreamCommit = '44918ea10c0f99151c6710411b4322c2f5c96bea'
$ExpectedPatchSha256 = '1fb02b2d93503d85bdc917f7d14f08b67f8ad61e86b824860c22f23444382dc3'
$Repository = 'LLL-toolkit/codex-usage-statusline'
$StatusLineOverride = "tui.status_line=['model-with-reasoning','context-used','five-hour-limit','weekly-limit']"

function Get-Sha256([string]$Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

function Get-CodexLauncherContent([string]$RelativeBinary, [string]$DisplayLanguage) {
    if ($RelativeBinary -match '[%\r\n"]') { throw 'The generated launcher path contains characters that cmd.exe cannot safely represent.' }
    if ($DisplayLanguage -notin @('ko', 'en', 'ja')) { throw 'The generated launcher language is unsupported.' }
    $content = @"
@echo off
setlocal
set "CODEX_USAGE_STATUSLINE_LANGUAGE=$DisplayLanguage"
"%~dp0$RelativeBinary" -c "$script:StatusLineOverride" %*
"@
    $content -replace "`n", "`r`n"
}

function Normalize-PathEntry([string]$Path) {
    if ($null -eq $Path) { return '' }
    $Path.Trim().Trim('"').TrimEnd('\', '/').ToLowerInvariant()
}

function Add-PathEntry([string]$CurrentPath, [string]$Entry) {
    $wanted = Normalize-PathEntry $Entry
    $kept = @($CurrentPath -split ';' | Where-Object {
        $_ -and (Normalize-PathEntry $_) -ne $wanted
    })
    (@($Entry) + $kept) -join ';'
}

function Remove-PathEntry([string]$CurrentPath, [string]$Entry) {
    $wanted = Normalize-PathEntry $Entry
    (@($CurrentPath -split ';' | Where-Object {
        $_ -and (Normalize-PathEntry $_) -ne $wanted
    })) -join ';'
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

function Get-CodexVersion([string]$CommandPath) {
    $output = (& $CommandPath --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $output -notmatch '(\d+\.\d+\.\d+)') {
        throw "Could not detect Codex version from '$CommandPath': $output"
    }
    [pscustomobject]@{ Version = $Matches[1]; Output = $output }
}

function Find-OfficialCodexBinary([string]$ExpectedVersion) {
    $commands = @(Get-Command codex -All -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0) { throw 'Codex CLI was not found in PATH.' }

    $candidatePaths = New-Object System.Collections.Generic.List[string]
    $searchRoots = New-Object System.Collections.Generic.List[string]
    foreach ($command in $commands) {
        $source = if ($command.Path) { $command.Path } else { $command.Source }
        if (-not $source) { continue }
        if ([IO.Path]::GetExtension($source) -ieq '.exe') { $candidatePaths.Add($source) }
        $directory = Split-Path -Parent $source
        if ($directory) {
            $searchRoots.Add($directory)
            $searchRoots.Add((Join-Path $directory 'node_modules'))
        }
    }

    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if ($npm) {
        $npmRoot = (& npm root -g 2>$null | Out-String).Trim()
        if ($npmRoot) { $searchRoots.Add($npmRoot) }
    }

    $seenRoots = @{}
    foreach ($root in $searchRoots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $rootFull = [IO.Path]::GetFullPath($root)
        if ($seenRoots.ContainsKey($rootFull)) { continue }
        $seenRoots[$rootFull] = $true

        $known = @(
            (Join-Path $rootFull '@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'),
            (Join-Path $rootFull '@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'),
            (Join-Path $rootFull '@openai\codex\vendor\x86_64-pc-windows-msvc\bin\codex.exe')
        )
        foreach ($path in $known) { $candidatePaths.Add($path) }

        $openAiRoot = Join-Path $rootFull '@openai'
        if (Test-Path -LiteralPath $openAiRoot) {
            Get-ChildItem -LiteralPath $openAiRoot -Filter codex.exe -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '\\vendor\\x86_64-pc-windows-msvc\\bin\\codex\.exe$' } |
                ForEach-Object { $candidatePaths.Add($_.FullName) }
        }
    }

    $seenCandidates = @{}
    foreach ($candidate in $candidatePaths) {
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $full = [IO.Path]::GetFullPath($candidate)
        if ($seenCandidates.ContainsKey($full)) { continue }
        $seenCandidates[$full] = $true
        try {
            $version = Get-CodexVersion $full
            if ($version.Version -eq $ExpectedVersion) {
                return [pscustomobject]@{
                    BinaryPath = $full
                    CommandPath = if ($commands[0].Path) { $commands[0].Path } else { $commands[0].Source }
                    VersionOutput = $version.Output
                }
            }
        } catch { continue }
    }
    throw "Could not locate the native Codex $ExpectedVersion Windows binary. Supported layouts are the official standalone and npm installations."
}

function Get-BundleInfo([string]$BinaryPath) {
    $binaryDirectory = Split-Path -Parent $BinaryPath
    $candidateBundleRoot = Split-Path -Parent $binaryDirectory
    $isKnownVendorLayout = $BinaryPath -match '\\vendor\\x86_64-pc-windows-msvc\\bin\\codex\.exe$'
    $resourceMarker = @('codex-resources', 'codex-path', 'codex-package.json') |
        Where-Object { Test-Path -LiteralPath (Join-Path $candidateBundleRoot $_) } |
        Select-Object -First 1
    $hasStandaloneResources = ((Split-Path -Leaf $binaryDirectory) -ieq 'bin') -and [bool]$resourceMarker
    if ($isKnownVendorLayout -or $hasStandaloneResources) {
        $bundleRoot = $candidateBundleRoot
    } else {
        $bundleRoot = $binaryDirectory
    }
    $bundleFull = [IO.Path]::GetFullPath($bundleRoot).TrimEnd('\')
    $binaryFull = [IO.Path]::GetFullPath($BinaryPath)
    if (-not $binaryFull.StartsWith($bundleFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Could not derive the Codex resource bundle from $BinaryPath"
    }
    [pscustomobject]@{
        Root = $bundleFull
        BinaryRelativePath = $binaryFull.Substring($bundleFull.Length).TrimStart('\')
    }
}

function Expand-StatuslineArchive([string]$ArchivePath, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $allowed = @('codex.exe', 'LICENSE', 'NOTICE.md', 'BUILD-METADATA.json')
    $entryLimits = @{
        'codex.exe' = 600MB
        'LICENSE' = 2MB
        'NOTICE.md' = 2MB
        'BUILD-METADATA.json' = 64KB
    }
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $seen = @{}
        [long]$totalLength = 0
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -notin $allowed -or $entry.FullName.Contains('/') -or $entry.FullName.Contains('\')) {
                throw "Unexpected or unsafe archive entry: $($entry.FullName)"
            }
            if ($seen.ContainsKey($entry.FullName)) { throw "Duplicate archive entry: $($entry.FullName)" }
            if ($entry.Length -gt $entryLimits[$entry.FullName]) {
                throw "Archive entry exceeds its safety limit: $($entry.FullName)"
            }
            $totalLength += $entry.Length
            if ($totalLength -gt 650MB) { throw 'The expanded release archive exceeds the 650 MB safety limit.' }
            $seen[$entry.FullName] = $true
        }
        foreach ($required in $allowed) {
            if (-not $seen.ContainsKey($required)) { throw "The release archive is missing $required." }
        }
    } finally {
        $archive.Dispose()
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $Destination)
}

if ($env:CODEX_USAGE_STATUSLINE_TEST_MODE -eq '1') { return }

$stateMutex = Enter-StateLock $StateRoot
try {

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This release supports Windows x64 only. Apple Silicon continuation work is documented in docs/macos-validation.md.'
}
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'This release supports Windows x64 only.'
}
Assert-SafeStateRoot $StateRoot

$activeManifestPath = Join-Path $StateRoot 'active-install.json'
if (Test-Path -LiteralPath $activeManifestPath) {
    throw "codex-usage-statusline is already active. Run uninstall.ps1 first: $activeManifestPath"
}

$activeVersion = Get-CodexVersion 'codex'
if ($activeVersion.Version -ne $SupportedCodexVersion) {
    throw "Codex $($activeVersion.Version) is installed, but this release requires exactly $SupportedCodexVersion. No files were changed."
}
$official = Find-OfficialCodexBinary $SupportedCodexVersion
$bundle = Get-BundleInfo $official.BinaryPath
$officialCommandDirectory = Split-Path -Parent $official.CommandPath
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$officialIsMachineScoped = @($machinePath -split ';' | Where-Object {
    $_ -and (Normalize-PathEntry ([Environment]::ExpandEnvironmentVariables($_))) -eq (Normalize-PathEntry $officialCommandDirectory)
}).Count -gt 0
if ($officialIsMachineScoped) {
    throw 'The active Codex command is on the machine PATH, which this per-user launcher cannot safely override. An agent must prepare a verified current-user activation method before retrying.'
}

$assetName = "codex-usage-statusline-$ProjectVersion-codex-$SupportedCodexVersion-$TargetTriple.zip"
if (-not $ReleaseBaseUrl) {
    $ReleaseBaseUrl = "https://github.com/$Repository/releases/download/$ReleaseTag"
}
$releaseUri = [Uri]$ReleaseBaseUrl
if (-not $releaseUri.IsAbsoluteUri -or $releaseUri.Scheme -ne 'https') {
    throw 'ReleaseBaseUrl must be an absolute HTTPS URL.'
}
$assetUrl = "$($ReleaseBaseUrl.TrimEnd('/'))/$assetName"
$checksumUrl = "$assetUrl.sha256"

if ($DryRun) {
    Write-Host "Codex: $($activeVersion.Output)"
    Write-Host "Official bundle: $($bundle.Root)"
    Write-Host "Release asset: $assetUrl"
    Write-Host "Language: $Language"
    Write-Host 'Dry run completed. No files were changed.' -ForegroundColor Green
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$operationRoot = Join-Path $StateRoot ("staging-{0}" -f [guid]::NewGuid().ToString('N'))
$downloadRoot = Join-Path $operationRoot 'download'
$extractRoot = Join-Path $operationRoot 'extract'
$stagedBundle = Join-Path $operationRoot 'bundle'
$versionsRoot = Join-Path $StateRoot 'versions'
$versionRoot = Join-Path $versionsRoot "$ProjectVersion-codex-$SupportedCodexVersion"
$launcherDirectory = Join-Path $StateRoot 'bin'
$launcherPath = Join-Path $launcherDirectory 'codex.cmd'
if (Test-Path -LiteralPath $versionRoot) {
    throw "A stale version directory already exists. Remove it after checking its contents: $versionRoot"
}
if (Test-Path -LiteralPath $launcherDirectory) {
    throw "A stale launcher directory already exists. Remove it after checking its contents: $launcherDirectory"
}
$archivePath = Join-Path $downloadRoot $assetName
$checksumPath = "$archivePath.sha256"
$customBinary = Join-Path $versionRoot $bundle.BinaryRelativePath
$oldUserPath = $null
$installedUserPath = $null
$pathCommitted = $false
$versionCommitted = $false
$manifestTemp = "$activeManifestPath.$PID.tmp"
try {
    New-Item -ItemType Directory -Force -Path $StateRoot, $downloadRoot, $extractRoot, $versionsRoot | Out-Null
    $versionsItem = Get-Item -LiteralPath $versionsRoot -Force
    if (($versionsItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Installer-owned directories must not be reparse points: $versionsRoot"
    }

    Write-Host "Downloading the verified Windows release for Codex $SupportedCodexVersion..." -ForegroundColor Cyan
    Invoke-WebRequest -UseBasicParsing -Uri $assetUrl -OutFile $archivePath
    Invoke-WebRequest -UseBasicParsing -Uri $checksumUrl -OutFile $checksumPath
    if ((Get-Item -LiteralPath $archivePath).Length -gt 600MB) {
        throw 'The downloaded release archive exceeds the 600 MB safety limit.'
    }
    if ((Get-Item -LiteralPath $checksumPath).Length -gt 4KB) {
        throw 'The release checksum file exceeds the 4 KB safety limit.'
    }
    $checksumText = [IO.File]::ReadAllText($checksumPath, [Text.Encoding]::ASCII).Trim()
    if ($checksumText -notmatch '^([0-9a-fA-F]{64})\s+([^\s]+)$') { throw 'The release checksum file is malformed.' }
    $expectedArchiveHash = $Matches[1].ToLowerInvariant()
    if ($Matches[2] -ne $assetName) { throw 'The release checksum names a different archive.' }
    $archiveHash = Get-Sha256 $archivePath
    if ($archiveHash -ne $expectedArchiveHash) { throw 'Release archive SHA-256 verification failed.' }

    Expand-StatuslineArchive $archivePath $extractRoot
    $downloadedBinary = Join-Path $extractRoot 'codex.exe'
    $buildMetadataPath = Join-Path $extractRoot 'BUILD-METADATA.json'
    $buildMetadata = [IO.File]::ReadAllText($buildMetadataPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($buildMetadata.schemaVersion -ne 1 -or
        $buildMetadata.projectVersion -ne $ProjectVersion -or
        $buildMetadata.codexVersion -ne $SupportedCodexVersion -or
        $buildMetadata.target -ne $TargetTriple -or
        $buildMetadata.upstreamCommit -ne $ExpectedUpstreamCommit -or
        $buildMetadata.patchSha256 -ne $ExpectedPatchSha256) {
        throw 'Release build metadata does not match the requested project, Codex version, and target.'
    }
    $downloadedVersion = Get-CodexVersion $downloadedBinary
    if ($downloadedVersion.Version -ne $SupportedCodexVersion) {
        throw "Release binary version mismatch: $($downloadedVersion.Output)"
    }
    $customHash = Get-Sha256 $downloadedBinary
    if ($buildMetadata.binarySha256 -ne $customHash) { throw 'Release binary SHA-256 does not match BUILD-METADATA.json.' }

    Write-Host 'Preparing a side-by-side Codex resource bundle...' -ForegroundColor Cyan
    Copy-Item -LiteralPath $bundle.Root -Destination $stagedBundle -Recurse -Force
    $stagedBinary = Join-Path $stagedBundle $bundle.BinaryRelativePath
    if (-not (Test-Path -LiteralPath $stagedBinary)) {
        throw "The copied Codex bundle is missing its executable: $stagedBinary"
    }
    Copy-Item -LiteralPath $downloadedBinary -Destination $stagedBinary -Force
    if ((Get-Sha256 $stagedBinary) -ne $customHash) { throw 'Staged binary hash verification failed.' }

    Move-Item -LiteralPath $stagedBundle -Destination $versionRoot
    $versionCommitted = $true
    New-Item -ItemType Directory -Force -Path $launcherDirectory | Out-Null
    $stateFull = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\', '/')
    $customFull = [IO.Path]::GetFullPath($customBinary)
    if (-not $customFull.StartsWith($stateFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The generated custom binary path is outside the installer state root.'
    }
    $launcherRelativeBinary = '..\' + $customFull.Substring($stateFull.Length).TrimStart('\')
    Write-Utf8NoBom $launcherPath (Get-CodexLauncherContent $launcherRelativeBinary $Language)
    $launcherHash = Get-Sha256 $launcherPath

    $oldUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $oldUserPath) { $oldUserPath = '' }
    $installedUserPath = Add-PathEntry $oldUserPath $launcherDirectory
    [Environment]::SetEnvironmentVariable('Path', $installedUserPath, 'User')
    $pathCommitted = $true
    try { Publish-EnvironmentChange } catch { Write-Warning "PATH was updated, but the environment-change broadcast failed: $($_.Exception.Message)" }

    $env:CODEX_USAGE_STATUSLINE_LANGUAGE = $Language
    $verifiedVersion = Get-CodexVersion $customBinary
    if ($verifiedVersion.Version -ne $SupportedCodexVersion) { throw 'Installed custom binary failed its version check.' }

    $manifest = [ordered]@{
        schemaVersion = 3
        installMode = 'side-by-side-path-launcher'
        installedAt = (Get-Date).ToString('o')
        projectVersion = $ProjectVersion
        releaseTag = $ReleaseTag
        codexVersion = $SupportedCodexVersion
        language = $Language
        targetTriple = $TargetTriple
        assetName = $assetName
        archiveSha256 = $archiveHash
        officialCommandPath = $official.CommandPath
        officialBinaryPath = $official.BinaryPath
        officialBundleRoot = $bundle.Root
        customBundlePath = $versionRoot
        customBinaryPath = $customBinary
        customBinarySha256 = $customHash
        launcherDirectory = $launcherDirectory
        launcherPath = $launcherPath
        launcherSha256 = $launcherHash
        previousUserPath = $oldUserPath
        installedUserPath = $installedUserPath
        statusLineOverride = $StatusLineOverride
    }
    Write-Utf8NoBom $manifestTemp ($manifest | ConvertTo-Json -Depth 5)
    Move-Item -LiteralPath $manifestTemp -Destination $activeManifestPath
} catch {
    if ($pathCommitted) {
        $currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($currentUserPath -eq $installedUserPath) {
            [Environment]::SetEnvironmentVariable('Path', $oldUserPath, 'User')
        } else {
            [Environment]::SetEnvironmentVariable('Path', (Remove-PathEntry $currentUserPath $launcherDirectory), 'User')
        }
        try { Publish-EnvironmentChange } catch { Write-Warning "PATH rollback succeeded, but its broadcast failed: $($_.Exception.Message)" }
    }
    if ($versionCommitted) {
        try { Remove-OwnedPath $versionRoot $StateRoot } catch { Write-Warning $_.Exception.Message }
    }
    try { Remove-OwnedPath $launcherDirectory $StateRoot } catch { Write-Warning $_.Exception.Message }
    if (Test-Path -LiteralPath $manifestTemp) { Remove-Item -LiteralPath $manifestTemp -Force }
    throw "Installation failed and rollback was attempted. $($_.Exception.Message)"
} finally {
    try { Remove-OwnedPath $operationRoot $StateRoot } catch { Write-Warning "Temporary cleanup failed: $($_.Exception.Message)" }
}

Write-Host 'codex-usage-statusline was installed without modifying the official Codex installation.' -ForegroundColor Green
Write-Host 'Close this Codex session and open a new terminal once so the PATH change takes effect.'
Write-Host "Recovery manifest: $activeManifestPath"
} finally {
    if ($stateMutex) {
        try { $stateMutex.ReleaseMutex() } catch { }
        $stateMutex.Dispose()
    }
}
