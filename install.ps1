[CmdletBinding()]
param(
    [string]$CodexVersion,
    [ValidateSet('ko', 'en', 'ja')]
    [string]$Language = 'ko',
    [string]$BuildRoot = (Join-Path $env:LOCALAPPDATA 'codex-usage-statusline'),
    [switch]$SkipTests,
    [switch]$KeepSource,
    [switch]$ForceRebuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Require-Command([string]$Name, [string]$Hint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command '$Name'. $Hint"
    }
}

function ConvertFrom-CodePoints([int[]]$CodePoints) {
    -join ($CodePoints | ForEach-Object { [char]$_ })
}

Require-Command git 'Install Git for Windows: https://git-scm.com/download/win'
Require-Command cargo 'Install Rust with rustup: https://rustup.rs/'
Require-Command npm 'Install Node.js: https://nodejs.org/'
Require-Command codex 'Install Codex first: npm install -g @openai/codex'

$versionOutput = (& codex --version 2>&1 | Out-String).Trim()
if (-not $CodexVersion) {
    if ($versionOutput -notmatch '(\d+\.\d+\.\d+)') {
        throw "Could not detect Codex version from: $versionOutput"
    }
    $CodexVersion = $Matches[1]
}

$repoRoot = $PSScriptRoot
$patchPath = Join-Path $repoRoot "patches\codex-$CodexVersion.patch"
if (-not (Test-Path -LiteralPath $patchPath)) {
    $supported = Get-ChildItem (Join-Path $repoRoot 'patches') -Filter 'codex-*.patch' |
        ForEach-Object { $_.BaseName -replace '^codex-', '' }
    throw "Codex $CodexVersion is not supported. Supported versions: $($supported -join ', ')"
}

$npmRoot = (& npm root -g 2>&1 | Out-String).Trim()
$nativeRoot = Join-Path $npmRoot '@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc'
$installedBinary = Join-Path $nativeRoot 'bin\codex.exe'
if (-not (Test-Path -LiteralPath $installedBinary)) {
    throw "Could not find the npm Codex Windows binary at $installedBinary"
}

$sourceRoot = Join-Path $BuildRoot "source-$CodexVersion"
$backupRoot = Join-Path $BuildRoot 'backups'
New-Item -ItemType Directory -Force -Path $BuildRoot, $backupRoot | Out-Null

if (Test-Path -LiteralPath $sourceRoot) {
    if (-not $ForceRebuild) {
        throw "Build source already exists at $sourceRoot. Re-run with -ForceRebuild or remove it."
    }
    $resolvedBuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
    $resolvedSourceRoot = (Resolve-Path -LiteralPath $sourceRoot).Path
    if (-not $resolvedSourceRoot.StartsWith($resolvedBuildRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove source outside build root: $resolvedSourceRoot"
    }
    Remove-Item -LiteralPath $resolvedSourceRoot -Recurse -Force
}

Write-Host "Cloning Codex $CodexVersion..." -ForegroundColor Cyan
& git clone --depth 1 --branch "rust-v$CodexVersion" https://github.com/openai/codex.git $sourceRoot
if ($LASTEXITCODE -ne 0) { throw 'Failed to clone Codex source.' }

Write-Host 'Applying usage statusline patch...' -ForegroundColor Cyan
& git -C $sourceRoot apply --check $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Patch compatibility check failed.' }
& git -C $sourceRoot apply $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply patch.' }

if ($Language -ne 'ko') {
    $koContext = ConvertFrom-CodePoints @(0xCEE8, 0xD14D, 0xC2A4, 0xD2B8)
    $koUsage = ConvertFrom-CodePoints @(0xC0AC, 0xC6A9, 0xB7C9)
    $koWeekly = ConvertFrom-CodePoints @(0xC8FC, 0xAC04)
    $koReset = ConvertFrom-CodePoints @(0xCD08, 0xAE30, 0xD654)
    $labels = @{
        en = @{ Context = 'Context'; Usage = 'Usage'; Weekly = 'Weekly'; Reset = 'resets' }
        ja = @{
            Context = (ConvertFrom-CodePoints @(0x30B3, 0x30F3, 0x30C6, 0x30AD, 0x30B9, 0x30C8))
            Usage = (ConvertFrom-CodePoints @(0x4F7F, 0x7528, 0x91CF))
            Weekly = (ConvertFrom-CodePoints @(0x9031, 0x9593))
            Reset = (ConvertFrom-CodePoints @(0x30EA, 0x30BB, 0x30C3, 0x30C8))
        }
    }[$Language]
    $surfacePath = Join-Path $sourceRoot 'codex-rs\tui\src\chatwidget\status_surfaces.rs'
    $controlsPath = Join-Path $sourceRoot 'codex-rs\tui\src\chatwidget\status_controls.rs'
    $surface = Get-Content -Raw -LiteralPath $surfacePath
    $surface = $surface.Replace($koContext, $labels.Context).Replace($koUsage, $labels.Usage).Replace($koWeekly, $labels.Weekly)
    Set-Content -LiteralPath $surfacePath -Value $surface -Encoding utf8
    $controls = (Get-Content -Raw -LiteralPath $controlsPath).Replace($koReset, $labels.Reset)
    Set-Content -LiteralPath $controlsPath -Value $controls -Encoding utf8
}

if (-not $SkipTests) {
    Write-Host 'Running focused TUI tests...' -ForegroundColor Cyan
    & cargo test --manifest-path (Join-Path $sourceRoot 'codex-rs\Cargo.toml') -p codex-tui status_line_
    if ($LASTEXITCODE -ne 0) { throw 'Codex TUI tests failed.' }
}

Write-Host 'Building the customized Codex binary...' -ForegroundColor Cyan
& cargo build --manifest-path (Join-Path $sourceRoot 'codex-rs\Cargo.toml') --release -p codex-cli --bin codex
if ($LASTEXITCODE -ne 0) { throw 'Codex release build failed.' }

$builtBinary = Join-Path $sourceRoot 'codex-rs\target\release\codex.exe'
if (-not (Test-Path -LiteralPath $builtBinary)) { throw "Build succeeded but $builtBinary is missing." }

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupPath = Join-Path $backupRoot "codex-$CodexVersion-$timestamp.exe"
Copy-Item -LiteralPath $installedBinary -Destination $backupPath

try {
    Copy-Item -LiteralPath $builtBinary -Destination $installedBinary -Force
    $installedVersion = (& $installedBinary --version 2>&1 | Out-String).Trim()
    if ($installedVersion -notmatch [regex]::Escape($CodexVersion)) {
        throw "Installed binary reported an unexpected version: $installedVersion"
    }
} catch {
    Copy-Item -LiteralPath $backupPath -Destination $installedBinary -Force
    throw "Install failed and the original binary was restored. $($_.Exception.Message)"
}

$configPath = Join-Path $HOME '.codex\config.toml'
if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -Raw -LiteralPath $configPath
    $statusLine = 'status_line = ["model-with-reasoning", "context-remaining", "five-hour-limit", "weekly-limit"]'
    if ($config -match '(?m)^status_line\s*=.*$') {
        $config = [regex]::Replace($config, '(?m)^status_line\s*=.*$', $statusLine, 1)
    } elseif ($config -match '(?m)^\[tui\]\s*$') {
        $config = [regex]::Replace($config, '(?m)^\[tui\]\s*$', "[tui]`r`n$statusLine", 1)
    } else {
        $config = $config.TrimEnd() + "`r`n`r`n[tui]`r`n$statusLine`r`n"
    }
    Set-Content -LiteralPath $configPath -Value $config -Encoding utf8
}

if ($KeepSource) {
    Write-Host "Build source kept at $sourceRoot." -ForegroundColor DarkGray
} else {
    Remove-Item -LiteralPath $sourceRoot -Recurse -Force
}

Write-Host ''
Write-Host 'Installed codex-usage-statusline.' -ForegroundColor Green
Write-Host "Backup: $backupPath"
Write-Host 'Restart Codex to see the lavender usage bars.'
