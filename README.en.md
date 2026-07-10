# codex-usage-statusline

[한국어](README.md) · **English** · [日本語](README.ja.md)

A friendlier Codex CLI status line for Windows. It replaces the plain remaining-limit text with compact usage bars, exact percentages, reset timing, and a lavender-first color scale.

```text
gpt-5.6-sol low · 컨텍스트 ██░░░░░░░░ 18% · 사용량 █░░░░░░░░░ 7% (초기화 in 3h 42m) · 주간 █████░░░░░ 49% (초기화 in 2d 23h)
```

Normal usage is lavender. At 60% it changes to yellow; at 85% it changes to red. The percentages consistently mean **used**, so Context, Usage, and Weekly can be compared at a glance.

## Install

### Prerequisites

- Windows x64
- Codex CLI installed with `npm install -g @openai/codex`
- Git, Node.js/npm, and the Rust toolchain (`cargo`)
- Approximately 10 GB of temporary free disk space for the Codex release build

Close running Codex sessions before installation. Then clone this repository and run the installer:

```powershell
git clone https://github.com/LLL-toolkit/codex-usage-statusline.git
cd codex-usage-statusline
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer detects your Codex version, selects the matching patch, builds Codex from the official tagged source, runs focused tests, backs up the installed binary, and replaces it only after a successful build. Restart Codex when it finishes.

Korean is the default display language. English and Japanese are also available; Chinese is intentionally not included.

```powershell
.\install.ps1 -Language en
.\install.ps1 -Language ja
```

## Verify

Start a new Codex session:

```powershell
codex
```

The footer should contain `Context`, `Usage`, and `Weekly` bars. If rate-limit data has not arrived yet, Usage or Weekly may appear after the first request.

## Installer options

```powershell
# Rebuild when a prior source directory exists
.\install.ps1 -ForceRebuild

# Keep the cloned Codex source after installation
.\install.ps1 -KeepSource

# Skip tests when diagnosing test-runner problems (not recommended)
.\install.ps1 -SkipTests

# Build a specific supported version
.\install.ps1 -CodexVersion 0.144.1

# Select Korean (default), English, or Japanese labels
.\install.ps1 -Language ko
.\install.ps1 -Language en
.\install.ps1 -Language ja
```

`-SkipTests` does not skip the release build or post-install version check. The original binary is still backed up and restored automatically if installation fails.

## Uninstall

Close Codex, then restore the newest backup:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

You can also reinstall the official npm package:

```powershell
npm install -g @openai/codex@latest
```

## Compatibility

Patches are version-specific because Codex's internal TUI is not a stable public extension API.

| Codex CLI | Platform | Status |
|---|---|---|
| 0.144.1 | Windows x64, npm install | Supported |

When Codex updates, this customization may be replaced. Re-run the installer after this repository adds support for the new version. The installer refuses unknown versions instead of applying an unsafe patch.

## How it works

```text
installed Codex version
        │
        ▼
matching version patch ──► official Codex tagged source
                                  │
                                  ▼
                         test + release build
                                  │
                                  ▼
                  backup original ──► atomic replacement
```

The patch changes only the Codex TUI status-line formatter and its tests. It does not read credentials, send telemetry, or change API requests. Build artifacts live under `%LOCALAPPDATA%\codex-usage-statusline`; cloned source is removed after a successful install unless `-KeepSource` is supplied.

## Troubleshooting

### The Codex version is unsupported

Wait for a matching patch in `patches/`, or install a supported Codex release. Do not rename an older patch: internal source lines may have changed.

### The installed binary is in use

Close every Codex process and run the installer again with `-ForceRebuild`.

### The build fails

Confirm that `rustc --version`, `cargo --version`, `git --version`, and `npm --version` all work. Re-run with `-KeepSource` to preserve the source tree for diagnosis.

### Disable colors

Set Codex's existing status-line color option in `%USERPROFILE%\.codex\config.toml`:

```toml
[tui]
status_line_use_colors = false
```

## Security and recovery

- Source is cloned only from `https://github.com/openai/codex.git` at the exact installed version tag.
- `git apply --check` must succeed before the source is modified.
- The existing executable is copied to `%LOCALAPPDATA%\codex-usage-statusline\backups` before replacement.
- A failed post-install version check restores the backup immediately.
