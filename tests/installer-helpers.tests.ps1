$ErrorActionPreference = 'Stop'
$env:CODEX_USAGE_STATUSLINE_TEST_MODE = '1'
. (Join-Path $PSScriptRoot '..\install.ps1')

function Assert-Contains([string]$Value, [string]$Expected) {
    if (-not $Value.Contains($Expected)) { throw "Expected text not found: $Expected`n$Value" }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "$Message`nExpected: $Expected`nActual: $Actual" }
}

function ConvertFrom-CodePoints([int[]]$CodePoints) {
    -join ($CodePoints | ForEach-Object { [char]$_ })
}

Assert-Equal $StatusLineOverride "tui.status_line=['model-with-reasoning','context-used','five-hour-limit','weekly-limit']" 'The launcher config override changed unexpectedly.'

$path = Add-PathEntry 'C:\official;C:\tools;C:\custom' 'C:\custom\'
Assert-Equal $path 'C:\custom\;C:\official;C:\tools' 'PATH insertion did not prepend and deduplicate the launcher.'
Assert-Equal (Remove-PathEntry $path 'c:\CUSTOM') 'C:\official;C:\tools' 'PATH removal was not case-insensitive.'
$unsafeRootRejected = $false
try { Assert-SafeStateRoot ([IO.Path]::GetPathRoot($env:TEMP)) } catch { $unsafeRootRejected = $true }
if (-not $unsafeRootRejected) { throw 'A filesystem root was accepted as installer state.' }

$lockRoot = Join-Path ([IO.Path]::GetTempPath()) 'codex-statusline-lock-test'
$firstLock = Enter-StateLock $lockRoot
try {
    $installScript = (Resolve-Path (Join-Path $PSScriptRoot '..\install.ps1')).Path
    $probe = "`$env:CODEX_USAGE_STATUSLINE_TEST_MODE='1'; . '$($installScript.Replace("'", "''"))'; try { `$m = Enter-StateLock '$($lockRoot.Replace("'", "''"))'; `$m.ReleaseMutex(); `$m.Dispose(); exit 0 } catch { exit 23 }"
    $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
    $probeProcess = Start-Process powershell.exe -ArgumentList '-NoProfile', '-EncodedCommand', $encodedProbe -Wait -PassThru -WindowStyle Hidden
    if ($probeProcess.ExitCode -ne 23) { throw 'A second process acquired the state lock concurrently.' }
} finally {
    $firstLock.ReleaseMutex()
    $firstLock.Dispose()
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("codex-statusline-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp | Out-Null
try {
    $utf8Path = Join-Path $temp 'utf8.txt'
    $korean = ConvertFrom-CodePoints @(0xD55C, 0xAD6D, 0xC5B4)
    $japanese = ConvertFrom-CodePoints @(0x65E5, 0x672C, 0x8A9E)
    Write-Utf8NoBom $utf8Path "$korean English $japanese"
    $bytes = [IO.File]::ReadAllBytes($utf8Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'UTF-8 writer added a BOM.'
    }

    $bundleRoot = Join-Path $temp 'vendor\x86_64-pc-windows-msvc'
    $binaryPath = Join-Path $bundleRoot 'bin\codex.exe'
    New-Item -ItemType Directory -Force (Split-Path -Parent $binaryPath) | Out-Null
    [IO.File]::WriteAllBytes($binaryPath, [byte[]](1, 2, 3))
    $bundle = Get-BundleInfo $binaryPath
    Assert-Equal $bundle.Root ([IO.Path]::GetFullPath($bundleRoot)) 'Bundle root detection failed.'
    Assert-Equal $bundle.BinaryRelativePath 'bin\codex.exe' 'Bundle-relative executable path detection failed.'

    $directRoot = Join-Path $temp 'tools\bin'
    $directBinary = Join-Path $directRoot 'codex.exe'
    New-Item -ItemType Directory -Force $directRoot | Out-Null
    [IO.File]::WriteAllBytes($directBinary, [byte[]](1, 2, 3))
    $directBundle = Get-BundleInfo $directBinary
    Assert-Equal $directBundle.Root ([IO.Path]::GetFullPath($directRoot)) 'A plain bin directory was incorrectly widened to its parent.'
    Assert-Equal $directBundle.BinaryRelativePath 'codex.exe' 'Direct standalone executable relative path is incorrect.'

    $mockState = Join-Path $temp 'launcher-state'
    $mockBin = Join-Path $mockState 'bin'
    $mockVersion = Join-Path $mockState 'versions\mock'
    New-Item -ItemType Directory -Force $mockBin, $mockVersion | Out-Null
    $mockBinary = Join-Path $mockVersion 'codex.cmd'
    Write-Utf8NoBom $mockBinary "@echo off`r`necho LANG=%CODEX_USAGE_STATUSLINE_LANGUAGE%`r`necho ARGS=%*`r`n"
    $mockLauncher = Join-Path $mockBin 'codex.cmd'
    Write-Utf8NoBom $mockLauncher (Get-CodexLauncherContent '..\versions\mock\codex.cmd' 'ko')
    $launcherOutput = (& $mockLauncher --version | Out-String)
    Assert-Contains $launcherOutput 'LANG=ko'
    Assert-Contains $launcherOutput $StatusLineOverride
    Assert-Contains $launcherOutput '--version'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archiveSource = Join-Path $temp 'archive-source'
    New-Item -ItemType Directory $archiveSource | Out-Null
    foreach ($name in @('codex.exe', 'LICENSE', 'NOTICE.md', 'BUILD-METADATA.json')) {
        [IO.File]::WriteAllText((Join-Path $archiveSource $name), $name)
    }
    $validArchive = Join-Path $temp 'valid.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($archiveSource, $validArchive)
    $validExtract = Join-Path $temp 'valid-extract'
    New-Item -ItemType Directory $validExtract | Out-Null
    Expand-StatuslineArchive $validArchive $validExtract
    if (-not (Test-Path -LiteralPath (Join-Path $validExtract 'BUILD-METADATA.json'))) {
        throw 'A valid release archive was not extracted.'
    }

    [IO.File]::WriteAllText((Join-Path $archiveSource 'unexpected.txt'), 'unexpected')
    $invalidArchive = Join-Path $temp 'invalid.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($archiveSource, $invalidArchive)
    $invalidArchiveRejected = $false
    try {
        $invalidExtract = Join-Path $temp 'invalid-extract'
        New-Item -ItemType Directory $invalidExtract | Out-Null
        Expand-StatuslineArchive $invalidArchive $invalidExtract
    } catch { $invalidArchiveRejected = $true }
    if (-not $invalidArchiveRejected) { throw 'An archive containing an unexpected entry was accepted.' }

    Remove-Item -LiteralPath (Join-Path $archiveSource 'unexpected.txt')
    [IO.File]::WriteAllBytes((Join-Path $archiveSource 'BUILD-METADATA.json'), (New-Object byte[] (65KB)))
    $oversizedArchive = Join-Path $temp 'oversized-metadata.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($archiveSource, $oversizedArchive)
    $oversizedMetadataRejected = $false
    try {
        $oversizedExtract = Join-Path $temp 'oversized-extract'
        New-Item -ItemType Directory $oversizedExtract | Out-Null
        Expand-StatuslineArchive $oversizedArchive $oversizedExtract
    } catch { $oversizedMetadataRejected = $true }
    if (-not $oversizedMetadataRejected) { throw 'An oversized BUILD-METADATA.json entry was accepted.' }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$lock = [IO.File]::ReadAllText((Join-Path $repoRoot 'release-lock.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
Assert-Equal $lock.projectVersion $ProjectVersion 'release-lock.json and install.ps1 project versions differ.'
Assert-Equal $lock.codexVersion $SupportedCodexVersion 'release-lock.json and install.ps1 Codex versions differ.'
Assert-Equal $lock.releaseTag $ReleaseTag 'release-lock.json and install.ps1 release tags differ.'
$patchPath = Join-Path $repoRoot ($lock.patch.path -replace '/', '\')
Assert-Equal (Get-Sha256 $patchPath) $lock.patch.sha256 'The locked patch SHA-256 is stale.'
$patchText = [IO.File]::ReadAllText($patchPath, [Text.Encoding]::UTF8)
Assert-Contains $patchText 'CODEX_USAGE_STATUSLINE_LANGUAGE'
Assert-Contains $patchText (ConvertFrom-CodePoints @(0x30B3, 0x30F3, 0x30C6, 0x30AD, 0x30B9, 0x30C8))
Assert-Contains $patchText (ConvertFrom-CodePoints @(0xCEE8, 0xD14D, 0xC2A4, 0xD2B8))

. (Join-Path $PSScriptRoot '..\uninstall.ps1')
$manifestTraversalRejected = $false
try { Assert-SamePath 'C:\safe\state\bin\..\victim' 'C:\safe\state\bin' 'test' } catch { $manifestTraversalRejected = $true }
if (-not $manifestTraversalRejected) { throw 'A manifest path containing traversal was accepted as an exact owned path.' }

Write-Host 'Windows installer helper tests passed'
