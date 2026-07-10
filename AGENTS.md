# Agent instructions

## When the user asks to install this repository

Prefer the verified prebuilt release because it is the shortest installation path. The actual requirement is zero manual prerequisite work by the user: if a requested maintenance or platform task needs Rust, compiler tools, or the locked Codex source, the agent may bootstrap them and complete the work itself.

1. Confirm `codex --version` and the operating system/architecture.
2. Use only the installer committed in this repository:
   - Windows x64: `powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Language ko`
3. Use `en` or `ja` instead of `ko` only when the user requests that display language.
4. Let the installer download the immutable GitHub Release asset and verify its SHA-256 checksum. Do not substitute another binary or mutable download URL.
5. Report the installer result. The official Codex installation remains untouched; a new terminal session is required for the side-by-side launcher to become first on PATH. The launcher sets `CODEX_USAGE_STATUSLINE_LANGUAGE` and passes the `-c tui.status_line=[...]` override on each invocation.
6. Verify from a new terminal with `codex --version`, then start Codex and confirm the footer after the first request.

If the installed Codex version is unsupported, stop and report the exact mismatch because the patch is version-locked. If an exact-version release asset is missing, an agent may build the locked source with the pinned patch and toolchain when the machine has adequate resources; it must verify the same tests and hashes and must not ask the user to install prerequisites manually. On Windows, stop if `codex` resolves only from the machine PATH unless the agent implements and verifies a safe activation method rather than bypassing the installer check.

macOS is not shipped in this release. If a user asks to install it on a Mac, do not improvise an installer or use a Windows release asset. Report that Apple Silicon support is future work and point maintainers to `docs/macos-validation.md`.

## When the user asks to uninstall

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1`

The uninstaller removes only installer-owned PATH activation and files. Installation and removal never create or edit `~/.codex/config.toml`.

## Development constraints

- Keep `release-lock.json`, `VERSION`, the Windows installer, patch SHA-256, workflow target, and release names synchronized.
- Official release binaries are built in GitHub Actions. Local or Mac-based development builds are allowed when an agent bootstraps the pinned toolchain, respects the machine's resource constraints, and performs the same verification.
- Keep status-line activation in the per-invocation launcher override. Never persist it by editing the user's `~/.codex/config.toml`.
- Korean is the default. English and Japanese are the supported localization set.
- Do not claim macOS support until the Apple Silicon implementation and real-device gates in `docs/macos-validation.md` are complete.
