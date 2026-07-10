# Agent instructions

## Installation requests

Use the verified prebuilt release and the installer committed in this repository.

1. Confirm `codex --version` and the operating system/architecture.
2. Run the matching installer:
   - Apple Silicon macOS: `./install.sh --language ko` only after `docs/macos-validation.md` records completed release-candidate and production-URL gates; v0.3.0 remains a release candidate until then.
   - Windows x64: `powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Language ko`
3. Use `en` or `ja` only when that display language is requested. Korean is the default.
4. Let the installer detect the official Codex layout, download the immutable release files, and validate checksums and metadata. Do not substitute another binary or mutable URL.
5. Report the result. The official Codex installation remains untouched; a new terminal is required for the side-by-side launcher to become first on PATH.
6. From a new terminal, verify `command -v codex` where available, `codex --version`, and the footer after the first request.

The Apple Silicon installer supports official standalone, Homebrew, and npm installations for the current user. Intel Macs are not supported. If the installed Codex version is not exactly 0.144.1, stop and report the mismatch because the Rust patch is version-locked.

Prebuilt installation has no Rust build step. For release maintenance, an agent may bootstrap the pinned Rust and platform toolchains and complete the build automatically.

## Uninstall requests

- Apple Silicon macOS: `./uninstall.sh`
- Windows x64: `powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1`

The uninstallers remove only installer-owned PATH activation and files. Installation and removal never create or edit `~/.codex/config.toml`.

## Development constraints

- Keep `release-lock.json`, `VERSION`, both installers, both uninstallers, the patch SHA-256, workflow targets, and release names synchronized.
- Reuse the single Rust patch for Windows x64 and `aarch64-apple-darwin`. Do not add Intel macOS.
- Official release binaries are built in GitHub Actions from the pinned upstream commit and Rust toolchain.
- Keep status-line activation in the per-invocation launcher override. Never persist it in `~/.codex/config.toml`.
- Korean, English, and Japanese are the complete supported localization set.
- macOS release assets are stripped, ad-hoc signed, and checked with `codesign --verify --deep --strict`. No Developer ID or notarization credentials are currently available; keep the Gatekeeper limitation in every language README and release note.
- Release `SHA256SUMS` files are signed with the GitHub Actions `RELEASE_SIGNING_PRIVATE_KEY`; both installers verify that signature, and the signed manifest binds every target to the triggering repository commit. The RSA public key, its checksum, and exact signature size are pinned in `release-lock.json`. Never commit or expose the private key.
- Production installers independently resolve the remote release tag's peeled commit and require it to match the signed `customizationCommit`. macOS removal verifies the complete installed bundle inventory and preserves any payload containing additions or modifications.
- Run `python3 scripts/verify_release_lock.py`, `python3 tests/release_assets_tests.py`, the platform installer tests, and `git diff --check` before release.
- Do not mark Apple Silicon as supported until the release-candidate and production-URL flows in `docs/macos-validation.md` have passed on Apple Silicon hardware.
