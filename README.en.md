# codex-usage-statusline

[한국어](README.md) · **English** · [日本語](README.ja.md)

Adds Context, five-hour Usage, and Weekly usage bars with exact percentages to the Codex CLI footer. Normal usage is lavender, 60% and above is yellow, and 85% and above is red.

```text
gpt-5.6-sol low · Context ██░░░░░░░░ 18% · Usage █░░░░░░░░░ 7% (resets in 3h 42m) · Weekly █████░░░░░ 49% (resets in 2d 23h)
```

## Install

> Apple Silicon macOS support is a v0.3.0 release candidate and is not yet a general installation target. Until real-device install and removal validation is complete, use the macOS commands below only for release-candidate development validation.

Ask your current Codex CLI:

```text
Install and verify https://github.com/LLL-toolkit/codex-usage-statusline on this computer.
Use the installer included for this operating system and set the display language to English.
```

The installer checks the operating system, CPU, and Codex version, then downloads a prebuilt asset from the pinned GitHub Release. It verifies the release checksums, manifest, build metadata, and embedded binary hash before installing into a separate user-state directory.

Close the current Codex session and terminal after installation, then open a new terminal. The official Codex installation is not replaced.

To run the repository installer directly:

Apple Silicon macOS v0.3.0 release-candidate development validation:

```sh
git clone https://github.com/LLL-toolkit/codex-usage-statusline.git
cd codex-usage-statusline
./install.sh --language en
```

Windows x64:

```powershell
git clone https://github.com/LLL-toolkit/codex-usage-statusline.git
cd codex-usage-statusline
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Language en
```

Korean `ko` is the default. English `en` and Japanese `ja` are also available.

## Compatibility

- Codex CLI **0.144.1**
- Windows x64 supported; Apple Silicon macOS v0.3.0 release candidate in validation
- Intel Macs are not supported

| Platform | Release build | Real-device validation |
|---|---:|---:|
| Windows x64 | Automated | Supported |
| Apple Silicon macOS | Automated | v0.3.0 release candidate in validation |

Codex's internal TUI is not a stable plugin API, so the version must match exactly. The installer activates nothing if the version, asset, hash, or target architecture differs.

On macOS, the installer detects the active user's official Codex from:

- the OpenAI standalone installer
- Homebrew
- a global npm installation

## Verify

From a new terminal, run:

```text
command -v codex
codex --version
codex
```

After the first request, confirm that the footer contains `Context`, `Usage`, and `Weekly` bars. Five-hour and weekly items can remain hidden until the first usage response arrives.

The installer and uninstaller never create or edit `~/.codex/config.toml`. The launcher supplies `CODEX_USAGE_STATUSLINE_LANGUAGE` and this per-invocation override:

```text
-c tui.status_line=['model-with-reasoning','context-used','five-hour-limit','weekly-limit']
```

## Uninstall

Apple Silicon macOS v0.3.0 release-candidate development validation:

```sh
./uninstall.sh
```

Windows x64:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

The uninstaller removes only its managed PATH block, launcher, and customized bundle. If any file was added to or changed in the bundle after installation, it preserves the whole bundle and only disables PATH activation. Other profile content, the official Codex installation, and `~/.codex/config.toml` are preserved.

## How it works

```text
repository installer
  └─ verify OS, CPU, Codex version, and official installation layout
      └─ verify the pinned release manifest, checksums, and metadata
          └─ copy the official Codex resource bundle into user state
              └─ put the verified binary and per-invocation launcher first on PATH
```

One shared Rust patch implements the status line. Korean, English, and Japanese are selected at runtime in the same binary.

- Windows state: `%LOCALAPPDATA%\codex-usage-statusline`
- macOS state: `~/Library/Application Support/codex-usage-statusline`
- macOS PATH blocks: absolute `$ZDOTDIR/.zprofile` when set, otherwise `~/.zprofile`, plus `~/.bash_profile`

Installation and removal use an operation lock, staging directories, atomic profile edits, and a recovery manifest. Interrupted operations roll back, and repeated installation does not duplicate managed blocks.

## macOS signing and Gatekeeper

The Apple Silicon binary is stripped, ad-hoc signed, and checked with `codesign --verify --deep --strict`. This release has no Apple Developer ID signature or notarization. A copy quarantined by Finder or a browser can therefore be rejected by Gatekeeper's `spctl` assessment.

The repository installer uses an HTTPS release and SHA-256 verification and does not remove quarantine attributes. This limitation remains until Developer ID signing and notarization are available.

## Security

- `release-lock.json` pins the official Codex tag, commit, tree, Rust version, patch SHA-256, and target architectures.
- The installers first verify `SHA256SUMS.sig` with the RSA public key pinned in the repository, then cross-check the archive, embedded binary, target metadata, `release-manifest.json`, and `SHA256SUMS`.
- The installers require the remote release tag's peeled commit to exactly match the signed `customizationCommit`.
- macOS additionally requires an arm64-only Mach-O and a valid ad-hoc `codesign` structure.
- A structured parser extracts only four allowlisted regular files from the archive.
- The original executable and persistent Codex configuration are never modified.
- This is an independent project, not an official OpenAI distribution.

See the [release process](docs/release-process.md) and [macOS validation record](docs/macos-validation.md).
