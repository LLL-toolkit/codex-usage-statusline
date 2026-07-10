[CmdletBinding()]
param(
    [ValidateSet('ko', 'en', 'ja')]
    [string]$Language = 'ko',
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'codex-usage-statusline'),
    [string]$ReleaseTag = 'v0.3.0',
    [string]$ReleaseBaseUrl,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ProjectVersion = '0.3.0'
$SupportedCodexVersion = '0.144.1'
$TargetTriple = 'x86_64-pc-windows-msvc'
$ExpectedUpstreamCommit = '44918ea10c0f99151c6710411b4322c2f5c96bea'
$ExpectedPatchSha256 = '02d74d7c01f34c72e0c1e244db334ce09fde9dd01b12f56b6741f001ceed9d53'
$Repository = 'LLL-toolkit/codex-usage-statusline'
$StatusLineOverride = "tui.status_line=['model-with-reasoning','context-used','five-hour-limit','weekly-limit']"
$ReleaseSigningPublicKeySha256 = 'c004c4a7baf1f3dedfcfca3346db7d93b37a148d0455b01a56fb5859f31488d0'
$ReleaseSigningSignatureSize = 384
$ReleaseSigningModulusBase64 = @(
    '5n72MLqX+b6k3Nqgkeik3gctX0mbrywJSnuFFuw3J0wH6/9mL5zLRiyCAT+jf5xTjVoHY6n9T+DOUcDuAznH'
    'Z1FCd+4ULlKfXzF0dYdUHMly+hNT6m6dguvgNL0eyI2vmqR3bjCgmQZcI8VGf9+/MjOBKaWUYyVwZ6za/Zol'
    'oi5FPdwyyGvYQpsqeozT2ZLh8mfaHPzK8JOtjSgqV+vitxPnXJt0uFGvcQDJtt6hnIHqfhvyb7rfdLTw5aGm6'
    '1hhHJKoAQ1m2U2e6xg8XcAHzmWlYUAjHLkZLE2ir7OohARw3M/u/Mdx7LbMy+N3hV/qrFe76gMqkg78/Ya0E'
    'mgL7N1m8WBGNcqyYw+wTYjnVCAVdZxUitmEifwnLb/RNQMleX58/e8HrtXl6QcCQQjV1xvf6yjcz8laOEsuY'
    '6KwLnFdXNJ+d/aaALxCTvatPPg+G/+ircB9CG93erbjxfIWDH3nAw6qWyX3I06szxjU2xK+2KpRNliAHmv7XF'
    '60TYYf'
) -join ''
$ReleaseSigningExponentBase64 = 'AQAB'

function Get-Sha256([string]$Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

function Test-RsaSha256Signature(
    [string]$ContentPath,
    [string]$SignaturePath,
    [string]$ModulusBase64 = $script:ReleaseSigningModulusBase64,
    [string]$ExponentBase64 = $script:ReleaseSigningExponentBase64,
    [int]$ExpectedSignatureSize = $script:ReleaseSigningSignatureSize
) {
    $signature = [IO.File]::ReadAllBytes($SignaturePath)
    if ($signature.Length -ne $ExpectedSignatureSize) { return $false }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([IO.File]::ReadAllBytes($ContentPath)) } finally { $sha.Dispose() }
    $parameters = New-Object Security.Cryptography.RSAParameters
    $parameters.Modulus = [Convert]::FromBase64String($ModulusBase64)
    $parameters.Exponent = [Convert]::FromBase64String($ExponentBase64)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.ImportParameters($parameters)
        $rsa.VerifyHash($hash, [Security.Cryptography.CryptoConfig]::MapNameToOID('SHA256'), $signature)
    } finally {
        $rsa.Dispose()
    }
}

function Read-Sha256Sums([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0 -or $bytes.Length -gt 64KB) { throw 'SHA256SUMS has an unsafe size.' }
    if (@($bytes | Where-Object { $_ -gt 0x7f }).Count -gt 0) { throw 'SHA256SUMS must be ASCII.' }
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    if (-not $text.EndsWith("`n") -or $text.Contains("`r")) { throw 'SHA256SUMS must use canonical LF line endings.' }
    $records = @{}
    foreach ($line in $text.Substring(0, $text.Length - 1).Split([char]10)) {
        if ($line -cnotmatch '^([0-9a-f]{64})  ([^\s]+)$') { throw 'SHA256SUMS contains a malformed record.' }
        $name = $Matches[2]
        if ($records.ContainsKey($name)) { throw "SHA256SUMS contains a duplicate record: $name" }
        $records[$name] = $Matches[1]
    }
    $records
}

function Resolve-ReleaseTagCommit([string]$RepositoryName, [string]$Tag) {
    if ($Tag -notmatch '^v\d+\.\d+\.\d+$') { throw "Unsafe release tag: $Tag" }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is required to resolve the immutable release tag.' }
    $lines = @(& git ls-remote --tags "https://github.com/$RepositoryName.git" "refs/tags/$Tag" "refs/tags/$Tag^{}" 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "Could not resolve release tag $Tag." }
    $direct = @()
    $peeled = @()
    foreach ($line in $lines) {
        $fields = @($line -split '\s+', 2)
        if ($fields.Count -ne 2 -or $fields[0] -notmatch '^[0-9a-f]{40}$') { continue }
        if ($fields[1] -eq "refs/tags/$Tag") { $direct += $fields[0] }
        if ($fields[1] -eq "refs/tags/$Tag^{}") { $peeled += $fields[0] }
    }
    $candidates = @(if ($peeled.Count -gt 0) { $peeled } else { $direct })
    if ($candidates.Count -ne 1) { throw "Expected one commit for release tag $Tag." }
    $candidates[0]
}

function Get-ReleaseManifestAsset(
    [object]$Manifest,
    [string]$ExpectedProjectVersion,
    [string]$ExpectedCodexVersion,
    [string]$ExpectedUpstreamCommit,
    [string]$ExpectedPatchSha256,
    [string]$ExpectedCustomizationCommit,
    [string]$ExpectedTarget
) {
    if ($Manifest.schemaVersion -ne 1 -or
        $Manifest.projectVersion -ne $ExpectedProjectVersion -or
        $Manifest.codexVersion -ne $ExpectedCodexVersion -or
        $Manifest.upstreamCommit -ne $ExpectedUpstreamCommit -or
        $Manifest.patchSha256 -ne $ExpectedPatchSha256 -or
        $Manifest.customizationCommit -ne $ExpectedCustomizationCommit) {
        throw 'The signed release manifest does not match the requested release and source commit.'
    }
    $assets = @($Manifest.assets)
    if ($assets.Count -ne 2) { throw 'The signed release manifest must contain exactly two targets.' }
    $targets = @($assets | ForEach-Object { $_.target } | Sort-Object)
    if (($targets -join ',') -ne 'aarch64-apple-darwin,x86_64-pc-windows-msvc') {
        throw 'The signed release manifest contains an unexpected target set.'
    }
    foreach ($asset in $assets) {
        if ($asset.customizationCommit -ne $ExpectedCustomizationCommit) {
            throw 'Release asset customization commits are inconsistent.'
        }
    }
    $selected = @($assets | Where-Object { $_.target -eq $ExpectedTarget })
    if ($selected.Count -ne 1) { throw "The signed release manifest is missing $ExpectedTarget." }
    $selected[0]
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
$aggregateChecksumUrl = "$($ReleaseBaseUrl.TrimEnd('/'))/SHA256SUMS"
$aggregateSignatureUrl = "$aggregateChecksumUrl.sig"
$releaseManifestUrl = "$($ReleaseBaseUrl.TrimEnd('/'))/release-manifest.json"
$ExpectedCustomizationCommit = Resolve-ReleaseTagCommit $Repository $ReleaseTag

if ($DryRun) {
    Write-Host "Codex: $($activeVersion.Output)"
    Write-Host "Official bundle: $($bundle.Root)"
    Write-Host "Release asset: $assetUrl"
    Write-Host "Language: $Language"
    Write-Host "Customization commit: $ExpectedCustomizationCommit"
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
$aggregateChecksumPath = Join-Path $downloadRoot 'SHA256SUMS'
$aggregateSignaturePath = Join-Path $downloadRoot 'SHA256SUMS.sig'
$releaseManifestPath = Join-Path $downloadRoot 'release-manifest.json'
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
    $previousProgressPreference = $ProgressPreference
    try {
        # Windows PowerShell 5.1 can make large Invoke-WebRequest downloads
        # dramatically slower while calculating its legacy progress display.
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri $assetUrl -OutFile $archivePath
        Invoke-WebRequest -UseBasicParsing -Uri $checksumUrl -OutFile $checksumPath
        Invoke-WebRequest -UseBasicParsing -Uri $aggregateChecksumUrl -OutFile $aggregateChecksumPath
        Invoke-WebRequest -UseBasicParsing -Uri $aggregateSignatureUrl -OutFile $aggregateSignaturePath
        Invoke-WebRequest -UseBasicParsing -Uri $releaseManifestUrl -OutFile $releaseManifestPath
    }
    finally {
        $ProgressPreference = $previousProgressPreference
    }
    if ((Get-Item -LiteralPath $archivePath).Length -gt 600MB) {
        throw 'The downloaded release archive exceeds the 600 MB safety limit.'
    }
    if ((Get-Item -LiteralPath $checksumPath).Length -gt 4KB) {
        throw 'The release checksum file exceeds the 4 KB safety limit.'
    }
    $aggregateChecksumSize = (Get-Item -LiteralPath $aggregateChecksumPath).Length
    if ($aggregateChecksumSize -le 0 -or $aggregateChecksumSize -gt 64KB) {
        throw 'The aggregate release checksum file has an unsafe size.'
    }
    if ((Get-Item -LiteralPath $aggregateSignaturePath).Length -ne $ReleaseSigningSignatureSize) {
        throw 'The aggregate release signature has an invalid size.'
    }
    if (-not (Test-RsaSha256Signature $aggregateChecksumPath $aggregateSignaturePath)) {
        throw 'The aggregate release checksum signature is invalid.'
    }
    $aggregateChecksums = Read-Sha256Sums $aggregateChecksumPath
    $windowsBase = "codex-usage-statusline-$ProjectVersion-codex-$SupportedCodexVersion-x86_64-pc-windows-msvc"
    $macBase = "codex-usage-statusline-$ProjectVersion-codex-$SupportedCodexVersion-aarch64-apple-darwin"
    $expectedReleaseFiles = @(
        "$windowsBase.zip", "$windowsBase.zip.sha256", "$windowsBase.metadata.json",
        "$macBase.tar.gz", "$macBase.tar.gz.sha256", "$macBase.metadata.json",
        'release-manifest.json'
    )
    if ($aggregateChecksums.Count -ne $expectedReleaseFiles.Count) {
        throw 'SHA256SUMS does not contain the exact locked release file set.'
    }
    foreach ($expectedReleaseFile in $expectedReleaseFiles) {
        if (-not $aggregateChecksums.ContainsKey($expectedReleaseFile)) {
            throw "SHA256SUMS is missing $expectedReleaseFile."
        }
    }
    $releaseManifestSize = (Get-Item -LiteralPath $releaseManifestPath).Length
    if ($releaseManifestSize -le 0 -or $releaseManifestSize -gt 1MB) {
        throw 'The signed release manifest has an unsafe size.'
    }
    if ((Get-Sha256 $releaseManifestPath) -ne $aggregateChecksums['release-manifest.json']) {
        throw 'The release manifest does not match the signed aggregate checksum.'
    }
    $releaseManifest = [IO.File]::ReadAllText($releaseManifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $manifestAsset = Get-ReleaseManifestAsset `
        $releaseManifest $ProjectVersion $SupportedCodexVersion $ExpectedUpstreamCommit `
        $ExpectedPatchSha256 $ExpectedCustomizationCommit $TargetTriple
    $checksumText = [IO.File]::ReadAllText($checksumPath, [Text.Encoding]::ASCII).Trim()
    if ($checksumText -cnotmatch '^([0-9a-f]{64})  ([^\s]+)$') { throw 'The release checksum file is malformed.' }
    $expectedArchiveHash = $Matches[1]
    if ($Matches[2] -ne $assetName) { throw 'The release checksum names a different archive.' }
    if ($aggregateChecksums[$assetName] -ne $expectedArchiveHash) {
        throw 'The target sidecar and signed aggregate archive checksums differ.'
    }
    if ($manifestAsset.asset -ne $assetName -or $manifestAsset.archiveSha256 -ne $expectedArchiveHash) {
        throw 'The signed release manifest names a different Windows archive.'
    }
    if ((Get-Sha256 $checksumPath) -ne $aggregateChecksums["$assetName.sha256"]) {
        throw 'The target checksum sidecar does not match the signed aggregate checksum.'
    }
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
        $buildMetadata.patchSha256 -ne $ExpectedPatchSha256 -or
        $buildMetadata.customizationCommit -ne $ExpectedCustomizationCommit) {
        throw 'Release build metadata does not match the requested project, Codex version, and target.'
    }
    $downloadedVersion = Get-CodexVersion $downloadedBinary
    if ($downloadedVersion.Version -ne $SupportedCodexVersion) {
        throw "Release binary version mismatch: $($downloadedVersion.Output)"
    }
    $customHash = Get-Sha256 $downloadedBinary
    if ($buildMetadata.binarySha256 -ne $customHash) { throw 'Release binary SHA-256 does not match BUILD-METADATA.json.' }
    if ($manifestAsset.binarySha256 -ne $customHash -or
        $manifestAsset.customizationCommit -ne $buildMetadata.customizationCommit) {
        throw 'Embedded metadata does not match the signed release manifest.'
    }

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
        customizationCommit = $ExpectedCustomizationCommit
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
