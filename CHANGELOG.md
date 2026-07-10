# Changelog

## 0.3.0 - 2026-07-10

### Added

- Build and package the shared Codex 0.144.1 status-line patch for Apple Silicon macOS.
- Add transactional macOS installation and removal with npm, Homebrew, and OpenAI standalone detection.
- Add idempotent zsh and bash PATH blocks without creating or editing `~/.codex/config.toml`.
- Verify target metadata, release manifests, aggregate checksums, embedded binary hashes, arm64 architecture, and ad-hoc code signatures before activation.
- Test checksum and network failures, path spaces, interrupted and repeated installation, profile preservation, and install/uninstall rollback on Apple Silicon.
- Build deterministic Windows ZIP and macOS tar.gz assets through one shared release packager.
- Sign aggregate release checksums with a repository-pinned RSA-3072 public key and reject missing, altered, or oversized signatures.

### Changed

- Extend `release-lock.json` and GitHub Actions from one Windows target to synchronized Windows x64 and Apple Silicon targets.
- Respect custom zsh `ZDOTDIR` locations across repeated installation, interruption recovery, and removal.
- Replace PID-directory locking with the macOS kernel `lockf` primitive and cover manifest commit-boundary interruption rollback.
- Bind every signed release asset to the exact triggering repository commit and verify the RSA checksum signature on Windows and macOS.
- Resolve the remote release tag in both installers and preserve any macOS payload whose full installed inventory changed.
- Rewrite installation documentation around installer behavior and concise platform-specific commands.
- Document that the macOS artifact has no Developer ID signature or notarization and may be rejected when Gatekeeper quarantine applies.

## 0.2.0 - 2026-07-10

### Added

- Download immutable prebuilt release binaries instead of compiling Codex on user machines.
- Install side by side without replacing or locking the official Codex executable.
- Add an Apple Silicon implementation handoff without claiming or shipping macOS support in this release.
- Select Korean, English, or Japanese labels at runtime from one shared Windows binary.
- Pin the upstream tag, commit, tree, Rust toolchain, patch checksum, and Windows x64 release target in `release-lock.json`.
- Publish archive checksums, binary metadata, a release manifest, and aggregate checksums from GitHub Actions.
- Add agent-facing installation instructions so a Codex user can provide only the repository URL.

### Changed

- Move all full Rust tests and release builds to tag-triggered GitHub Actions.
- Replace in-place npm binary modification with a reversible per-user PATH launcher that supplies the status-line `-c` override on every invocation without changing `~/.codex/config.toml`.
- Rewrite Korean, English, and Japanese documentation around the verified agent-driven installation flow.

### Fixed

- Show reset timing as compact relative durations such as `3h 42m` and `2d 23h`.
- Preserve concurrent user PATH changes and validate installer state before removal mutates PATH or files.
- Recover incomplete draft releases safely and verify an existing published release without requiring byte-for-byte reproducible ZIP timestamps.
- Preserve the upstream OpenAI Codex and Ratatui attribution in distributed release notices.
- Refresh the upstream workspace package versions in `Cargo.lock` so the pinned Codex tag builds reproducibly with `--locked`.

## 0.1.0 - 2026-07-10

### Added

- Display Context, five-hour Usage, and Weekly usage as ten-segment bars with exact used percentages.
- Show rate-limit reset timing directly in the Codex footer.
- Use a lavender accent for normal usage and yellow/red thresholds for elevated usage.
- Use Korean labels by default, with English and Japanese installation options.
- Install, verify, back up, recover, and uninstall the customized Codex binary with PowerShell scripts.
- Support Codex CLI 0.144.1 on Windows x64 npm installations.
