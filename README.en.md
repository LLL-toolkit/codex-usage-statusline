# codex-usage-statusline

[한국어](README.md) · **English** · [日本語](README.ja.md)

Adds compact Context, five-hour Usage, and Weekly bars with exact used percentages to the Codex CLI footer on Windows x64. Normal usage is lavender, 60% and above is yellow, and 85% and above is red.

```text
gpt-5.6-sol low · Context ██░░░░░░░░ 18% · Usage █░░░░░░░░░ 7% (resets in 3h 42m) · Weekly █████░░░░░ 49% (resets in 2d 23h)
```

## Easiest installation

Ask your current Codex CLI exactly this:

```text
Install https://github.com/LLL-toolkit/codex-usage-statusline on this Windows x64 computer.
Detect the Codex installation, use the repository's official Windows installer, select English labels, and verify the result. Bootstrap any required tools yourself instead of asking me to install them manually.
```

The default installer verifies Windows x64 and the Codex version, downloads the matching asset from an immutable GitHub Release, and verifies its SHA-256 checksum. It normally needs no build toolchain. For maintenance or a future platform port, the AI may bootstrap Rust and platform tools automatically; the user should not have to perform those intermediate steps.

Close the current Codex session and the existing terminal application, then open one new terminal after installation. The official Codex installation is left untouched; a verified side-by-side build is placed first on your user PATH. On Windows, the installer supports Codex commands that resolve in the current user's scope.

## Manual installation

Git is needed only for this manual clone path.

Windows x64:

```powershell
git clone https://github.com/LLL-toolkit/codex-usage-statusline.git
cd codex-usage-statusline
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Language en
```

`ko` is the default language. `en` and `ja` are also available through `-Language`.

## Requirements and compatibility

- A working Codex CLI and an internet connection
- Codex CLI **0.144.1**
- A Windows x64 Codex command that resolves in the current user's scope

| Platform | Release build | Real-device validation |
|---|---:|---:|
| Windows x64 | Automated | Supported |

No macOS binary or installer is shipped yet. The [macOS handoff](docs/macos-validation.md) describes how to extend the same Rust patch to Apple Silicon later.

The installer makes no changes when the exact Codex version or release asset is unavailable. Codex's internal TUI is not a stable plugin API, so every Codex version requires explicit validation.

## Verify

From a new terminal, run:

```text
codex --version
codex
```

After the first request, confirm that the footer contains `Context`, `Usage`, and `Weekly` bars. Rate-limit items can remain hidden until Codex receives the first usage response.

The installer never creates or edits `~/.codex/config.toml`. If you want to disable colors yourself, use Codex's existing option:

```toml
[tui]
status_line_use_colors = false
```

## Uninstall

Ask Codex to uninstall this status line, or run:

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

The uninstaller removes only the managed PATH entry and customized bundle. The official Codex installation and `~/.codex/config.toml` are untouched throughout installation and removal.

## How it works

```text
repository installer
  └─ verify Windows x64 and the Codex version
      └─ verify an immutable GitHub Release asset and SHA-256
          └─ copy the official Codex resource bundle into user state
              └─ put a launcher that supplies language and the status-line -c override first on PATH
```

One shared Rust patch implements the status line. Korean, English, and Japanese are selected at runtime in the same binary. On every invocation, the launcher sets `CODEX_USAGE_STATUSLINE_LANGUAGE` and passes a `-c tui.status_line=[...]` override, so it does not need to persist the status-line setting in the user's config file. Official release binaries are built reproducibly by GitHub Actions when a release tag is created.

State is stored under `%LOCALAPPDATA%\codex-usage-statusline`.

## Security and limitations

- The exact official Codex tag, commit, and customization patch SHA-256 are pinned in `release-lock.json`.
- CI records archive and binary hashes; the installer verifies the archive SHA-256 before extraction.
- The original executable is not overwritten, which also avoids the active-executable lock on Windows.
- This is an independent project, not an official OpenAI distribution.

See the [release process](docs/release-process.md) and the future [Apple Silicon implementation handoff](docs/macos-validation.md).
