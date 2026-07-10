#!/bin/sh

set -eu
umask 077

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
ProjectVersion='0.3.0'
SupportedCodexVersion='0.144.1'
ReleaseTag='v0.3.0'
TargetTriple='aarch64-apple-darwin'
Repository='LLL-toolkit/codex-usage-statusline'
StatusLineOverride="tui.status_line=['model-with-reasoning','context-used','five-hour-limit','weekly-limit']"

LANGUAGE=ko
STATE_ROOT=${CODEX_USAGE_STATUSLINE_STATE_ROOT:-"$HOME/Library/Application Support/codex-usage-statusline"}
RELEASE_BASE_URL=
RELEASE_DIRECTORY=
RELEASE_LOCK=$SCRIPT_DIR/release-lock.json
EXPECTED_CUSTOMIZATION_COMMIT=
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [--language ko|en|ja] [--state-root PATH] [--dry-run]

Installs the verified Apple Silicon release side by side with the official Codex CLI.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --language)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            LANGUAGE=$2
            shift
            ;;
        --state-root)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            STATE_ROOT=$2
            shift
            ;;
        --release-base-url)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            RELEASE_BASE_URL=$2
            shift
            ;;
        --release-directory)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            RELEASE_DIRECTORY=$2
            shift
            ;;
        --release-lock)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            RELEASE_LOCK=$2
            shift
            ;;
        --expected-customization-commit)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_CUSTOMIZATION_COMMIT=$2
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

case "$LANGUAGE" in
    ko | en | ja) ;;
    *) printf 'Unsupported language: %s\n' "$LANGUAGE" >&2; exit 2 ;;
esac

. "$SCRIPT_DIR/scripts/macos_common.sh"

require_command python3
require_command shasum
require_command awk
require_command sed
require_command curl
require_command cp
require_command mv
require_command lockf

[ "$(uname -s)" = Darwin ] || die 'install.sh supports macOS only.'
machine_arch=$(uname -m)
if [ "$machine_arch" != arm64 ]; then
    translated=$(sysctl -n sysctl.proc_translated 2>/dev/null || true)
    [ "$machine_arch" = x86_64 ] && [ "$translated" = 1 ] || \
        die 'This release supports Apple Silicon only; Intel Macs are not supported.'
fi
if [ "${CODEX_USAGE_STATUSLINE_TEST_MODE:-0}" != 1 ]; then
    require_command codesign
    require_command lipo
    require_command spctl
fi

case "$STATE_ROOT" in
    /*) ;;
    *) STATE_ROOT=$PWD/$STATE_ROOT ;;
esac
STATE_ROOT=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$STATE_ROOT")
assert_safe_state_root
ZSH_PROFILE=
BASH_PROFILE=$(normalize_profile_path "$HOME/.bash_profile" bash)
ACTIVE_MANIFEST=$STATE_ROOT/active-install.json
CONFIG_FINGERPRINT_BEFORE=$(config_toml_fingerprint)

if [ -z "$RELEASE_BASE_URL" ]; then
    RELEASE_BASE_URL=https://github.com/$Repository/releases/download/$ReleaseTag
fi
if [ -n "$RELEASE_DIRECTORY" ]; then
    [ "${CODEX_USAGE_STATUSLINE_TEST_MODE:-0}" = 1 ] || \
        [ "${CODEX_USAGE_STATUSLINE_RELEASE_CANDIDATE:-0}" = 1 ] || \
        die '--release-directory is reserved for automated tests and release-candidate validation.'
    RELEASE_DIRECTORY=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$RELEASE_DIRECTORY")
    [ -d "$RELEASE_DIRECTORY" ] || die "Release test directory does not exist: $RELEASE_DIRECTORY"
else
    validate_release_base_url
fi
if [ "$RELEASE_LOCK" != "$SCRIPT_DIR/release-lock.json" ]; then
    [ "${CODEX_USAGE_STATUSLINE_TEST_MODE:-0}" = 1 ] || \
        die '--release-lock is reserved for the automated installer tests.'
    RELEASE_LOCK=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$RELEASE_LOCK")
fi
[ -f "$RELEASE_LOCK" ] && [ ! -L "$RELEASE_LOCK" ] || die "Release lock is missing or unsafe: $RELEASE_LOCK"
if [ -n "$EXPECTED_CUSTOMIZATION_COMMIT" ]; then
    [ "${CODEX_USAGE_STATUSLINE_TEST_MODE:-0}" = 1 ] || \
        [ "${CODEX_USAGE_STATUSLINE_RELEASE_CANDIDATE:-0}" = 1 ] || \
        die '--expected-customization-commit is reserved for tests and release-candidate validation.'
else
    EXPECTED_CUSTOMIZATION_COMMIT=$(resolve_release_tag_commit)
fi
case "$EXPECTED_CUSTOMIZATION_COMMIT" in
    *[!0-9a-f]*) die "Invalid expected customization commit: $EXPECTED_CUSTOMIZATION_COMMIT" ;;
esac
[ "${#EXPECTED_CUSTOMIZATION_COMMIT}" -eq 40 ] || \
    die "Invalid expected customization commit: $EXPECTED_CUSTOMIZATION_COMMIT"

DETECTION_ARGS=
if [ "${CODEX_USAGE_STATUSLINE_TEST_MODE:-0}" = 1 ]; then
    DETECTION_ARGS=--allow-test-binaries
fi

if [ "$DRY_RUN" = 1 ]; then
    dry_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-statusline-dry.XXXXXX")
    trap 'rm -rf "$dry_root"' EXIT HUP INT TERM
    python3 "$SCRIPT_DIR/scripts/detect_macos_codex.py" \
        --expected-version "$SupportedCodexVersion" \
        --state-root "$STATE_ROOT" \
        --home "$HOME" \
        $DETECTION_ARGS >"$dry_root/official.json"
    printf 'Codex: %s\n' "$(json_field "$dry_root/official.json" versionOutput)"
    printf 'Official installation: %s\n' "$(json_field "$dry_root/official.json" installationKind)"
    printf 'Official bundle: %s\n' "$(json_field "$dry_root/official.json" bundleRoot)"
    printf 'Release asset: %s/codex-usage-statusline-%s-codex-%s-%s.tar.gz\n' \
        "$RELEASE_BASE_URL" "$ProjectVersion" "$SupportedCodexVersion" "$TargetTriple"
    printf 'Language: %s\n' "$LANGUAGE"
    printf 'Customization commit: %s\n' "$EXPECTED_CUSTOMIZATION_COMMIT"
    assert_config_unchanged
    printf 'Dry run completed. No files were changed.\n'
    exit 0
fi

STATE_ROOT_EXISTED=0
[ -d "$STATE_ROOT" ] && STATE_ROOT_EXISTED=1
LOCK_HELD=0
LOCK_FILE=
OPERATION_ROOT=
TRANSACTION_COMMITTED=0
MANIFEST_PUBLISHING=0
VERSION_COMMITTED=0
LAUNCHER_COMMITTED=0
ZSH_BACKED_UP=0
BASH_BACKED_UP=0

rollback_install() {
    if [ "$MANIFEST_PUBLISHING" = 1 ] && { [ -e "$ACTIVE_MANIFEST" ] || [ -L "$ACTIVE_MANIFEST" ]; }; then
        if [ -f "$ACTIVE_MANIFEST" ] && [ ! -L "$ACTIVE_MANIFEST" ]; then
            rm -f "$ACTIVE_MANIFEST"
        else
            printf 'Warning: unsafe published manifest could not be rolled back: %s\n' "$ACTIVE_MANIFEST" >&2
        fi
    fi
    if [ "$ZSH_BACKED_UP" = 1 ]; then
        restore_profile_backup "$ZSH_PROFILE" "$OPERATION_ROOT/backups/zprofile" "$OPERATION_ROOT/backups/zprofile.state" || true
    fi
    if [ "$BASH_BACKED_UP" = 1 ]; then
        restore_profile_backup "$BASH_PROFILE" "$OPERATION_ROOT/backups/bash_profile" "$OPERATION_ROOT/backups/bash_profile.state" || true
    fi
    if [ "$LAUNCHER_COMMITTED" = 1 ]; then
        remove_owned_path "$LAUNCHER_DIRECTORY" || true
    fi
    if [ "$VERSION_COMMITTED" = 1 ]; then
        remove_owned_path "$VERSION_ROOT" || true
    fi
    rm -f "${MANIFEST_TEMP:-}" 2>/dev/null || true
}

finish_install() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ "$result" -ne 0 ] && [ "$TRANSACTION_COMMITTED" != 1 ]; then
        rollback_install
        printf 'Installation failed; installer-owned changes were rolled back.\n' >&2
    fi
    if [ -n "$OPERATION_ROOT" ] && { [ -e "$OPERATION_ROOT" ] || [ -L "$OPERATION_ROOT" ]; }; then
        remove_owned_path "$OPERATION_ROOT" || true
    fi
    release_state_lock
    if [ "$result" -ne 0 ] && [ "$STATE_ROOT_EXISTED" = 0 ]; then
        rmdir "$STATE_ROOT/versions" 2>/dev/null || true
        rmdir "$STATE_ROOT" 2>/dev/null || true
    fi
    exit "$result"
}

acquire_state_lock
trap finish_install EXIT
trap 'exit 130' HUP INT TERM
if [ -e "$ACTIVE_MANIFEST" ] || [ -L "$ACTIVE_MANIFEST" ]; then
    [ -f "$ACTIVE_MANIFEST" ] && [ ! -L "$ACTIVE_MANIFEST" ] || die "Unsafe active manifest path: $ACTIVE_MANIFEST"
    python3 "$SCRIPT_DIR/scripts/macos_manifest.py" validate \
        --manifest "$ACTIVE_MANIFEST" \
        --state-root "$STATE_ROOT" \
        --project-version "$ProjectVersion" \
        --codex-version "$SupportedCodexVersion" \
        --home "$HOME" >/dev/null
    ZSH_PROFILE=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" profile-path \
        --manifest "$ACTIVE_MANIFEST" --home "$HOME" --shell zsh)
    BASH_PROFILE=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" profile-path \
        --manifest "$ACTIVE_MANIFEST" --home "$HOME" --shell bash)
else
    ZSH_PROFILE=$(default_zsh_profile)
fi
recover_stale_operations

LAUNCHER_DIRECTORY=$STATE_ROOT/bin
LAUNCHER_PATH=$LAUNCHER_DIRECTORY/codex
VERSION_ROOT=$STATE_ROOT/versions/$ProjectVersion-codex-$SupportedCodexVersion

if [ -f "$ACTIVE_MANIFEST" ]; then
    python3 "$SCRIPT_DIR/scripts/macos_manifest.py" validate \
        --manifest "$ACTIVE_MANIFEST" \
        --state-root "$STATE_ROOT" \
        --project-version "$ProjectVersion" \
        --codex-version "$SupportedCodexVersion" \
        --home "$HOME" >/dev/null
    installed_language=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" get --manifest "$ACTIVE_MANIFEST" --field language)
    [ "$installed_language" = "$LANGUAGE" ] || \
        die "The status line is already installed with language $installed_language. Uninstall it before changing languages."
    installed_commit=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" get --manifest "$ACTIVE_MANIFEST" --field customizationCommit)
    [ "$installed_commit" = "$EXPECTED_CUSTOMIZATION_COMMIT" ] || \
        die 'The installed customization commit does not match the release tag.'
    CUSTOM_BINARY=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" get --manifest "$ACTIVE_MANIFEST" --field customBinaryPath)
    expected_custom_hash=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" get --manifest "$ACTIVE_MANIFEST" --field customBinarySha256)
    expected_launcher_hash=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" get --manifest "$ACTIVE_MANIFEST" --field launcherSha256)
    [ -f "$CUSTOM_BINARY" ] && [ ! -L "$CUSTOM_BINARY" ] || die 'The installed custom binary is missing or unsafe.'
    [ -f "$LAUNCHER_PATH" ] && [ ! -L "$LAUNCHER_PATH" ] || die 'The installed launcher is missing or unsafe.'
    [ "$(sha256_file "$CUSTOM_BINARY")" = "$expected_custom_hash" ] || die 'The installed custom binary was modified.'
    [ "$(sha256_file "$LAUNCHER_PATH")" = "$expected_launcher_hash" ] || die 'The installed launcher was modified.'
    python3 "$SCRIPT_DIR/scripts/macos_manifest.py" verify-inventory \
        --manifest "$ACTIVE_MANIFEST" --kind bundle >/dev/null
    python3 "$SCRIPT_DIR/scripts/macos_manifest.py" verify-inventory \
        --manifest "$ACTIVE_MANIFEST" --kind launcher >/dev/null
    for profile in "$ZSH_PROFILE" "$BASH_PROFILE"; do
        block_hash=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" profile --manifest "$ACTIVE_MANIFEST" --path "$profile" --field blockSha256)
        python3 "$SCRIPT_DIR/scripts/profile_block.py" verify \
            --path "$profile" --bin-dir "$LAUNCHER_DIRECTORY" --expected-block-sha "$block_hash" >/dev/null
    done
    if [ "${CODEX_USAGE_STATUSLINE_TEST_MODE:-0}" != 1 ]; then
        [ "$(lipo -archs "$CUSTOM_BINARY")" = arm64 ] || die 'The installed custom binary is not arm64-only.'
        codesign --verify --deep --strict --verbose=2 "$CUSTOM_BINARY"
    fi
    assert_config_unchanged
    TRANSACTION_COMMITTED=1
    printf 'codex-usage-statusline %s is already installed and verified.\n' "$ProjectVersion"
    exit 0
fi
[ ! -e "$ACTIVE_MANIFEST" ] && [ ! -L "$ACTIVE_MANIFEST" ] || die "Unsafe active manifest path: $ACTIVE_MANIFEST"
[ ! -e "$VERSION_ROOT" ] && [ ! -L "$VERSION_ROOT" ] || die "A stale version directory requires inspection: $VERSION_ROOT"
[ ! -e "$LAUNCHER_DIRECTORY" ] && [ ! -L "$LAUNCHER_DIRECTORY" ] || die "A stale launcher directory requires inspection: $LAUNCHER_DIRECTORY"

OPERATION_ROOT=$STATE_ROOT/.staging.install.$$
DOWNLOAD_ROOT=$OPERATION_ROOT/download
EXTRACT_ROOT=$OPERATION_ROOT/extract
STAGED_BUNDLE=$OPERATION_ROOT/bundle
STAGED_LAUNCHER_DIRECTORY=$OPERATION_ROOT/launcher
mkdir -p "$DOWNLOAD_ROOT" "$EXTRACT_ROOT" "$STAGED_BUNDLE" "$STAGED_LAUNCHER_DIRECTORY" "$OPERATION_ROOT/backups" "$STATE_ROOT/versions"
printf '%s\n' "$ZSH_PROFILE" >"$OPERATION_ROOT/zprofile.path"
printf '%s\n' "$BASH_PROFILE" >"$OPERATION_ROOT/bash-profile.path"

python3 "$SCRIPT_DIR/scripts/detect_macos_codex.py" \
    --expected-version "$SupportedCodexVersion" \
    --state-root "$STATE_ROOT" \
    --home "$HOME" \
    $DETECTION_ARGS >"$OPERATION_ROOT/official.json"

ASSET_BASE=codex-usage-statusline-$ProjectVersion-codex-$SupportedCodexVersion-$TargetTriple
ASSET_NAME=$ASSET_BASE.tar.gz
for release_name in \
    "$ASSET_NAME" \
    "$ASSET_NAME.sha256" \
    "$ASSET_BASE.metadata.json" \
    release-manifest.json \
    SHA256SUMS \
    SHA256SUMS.sig
do
    printf 'Downloading %s\n' "$release_name"
    download_release_file "$release_name" "$DOWNLOAD_ROOT/$release_name"
done
assert_file_size_at_most "$DOWNLOAD_ROOT/$ASSET_NAME" 629145600
assert_file_size_at_most "$DOWNLOAD_ROOT/$ASSET_NAME.sha256" 4096
assert_file_size_at_most "$DOWNLOAD_ROOT/$ASSET_BASE.metadata.json" 65536
assert_file_size_at_most "$DOWNLOAD_ROOT/release-manifest.json" 1048576
assert_file_size_at_most "$DOWNLOAD_ROOT/SHA256SUMS" 65536
assert_file_size_at_most "$DOWNLOAD_ROOT/SHA256SUMS.sig" 16384

maybe_test_failpoint after-download
python3 "$SCRIPT_DIR/scripts/release_assets.py" verify \
    --lock "$RELEASE_LOCK" \
    --release-dir "$DOWNLOAD_ROOT" \
    --target "$TargetTriple" \
    --selected-only \
    --expected-customization-commit "$EXPECTED_CUSTOMIZATION_COMMIT" \
    --extract-dir "$EXTRACT_ROOT"

DOWNLOADED_BINARY=$EXTRACT_ROOT/codex
if ! DOWNLOADED_VERSION=$("$DOWNLOADED_BINARY" --version 2>&1); then
    die "The downloaded release binary did not run: $DOWNLOADED_VERSION"
fi
DETECTED_DOWNLOADED_VERSION=$(printf '%s\n' "$DOWNLOADED_VERSION" | codex_version_from_output) || \
    die "Could not parse the release binary version: $DOWNLOADED_VERSION"
[ "$DETECTED_DOWNLOADED_VERSION" = "$SupportedCodexVersion" ] || \
    die "Release binary version mismatch: $DOWNLOADED_VERSION"
if [ "${CODEX_USAGE_STATUSLINE_TEST_MODE:-0}" != 1 ]; then
    [ "$(lipo -archs "$DOWNLOADED_BINARY")" = arm64 ] || die 'The release binary is not arm64-only.'
    codesign --verify --deep --strict --verbose=2 "$DOWNLOADED_BINARY"
    if ! spctl --assess --type execute --verbose=2 "$DOWNLOADED_BINARY" 2>"$OPERATION_ROOT/spctl.txt"; then
        printf 'Warning: Gatekeeper does not trust this ad-hoc-signed build; archive hashes and codesign structure were verified.\n' >&2
    fi
fi
CUSTOM_HASH=$(sha256_file "$DOWNLOADED_BINARY")
ARCHIVE_HASH=$(sha256_file "$DOWNLOAD_ROOT/$ASSET_NAME")

OFFICIAL_BUNDLE=$(json_field "$OPERATION_ROOT/official.json" bundleRoot)
BINARY_RELATIVE=$(json_field "$OPERATION_ROOT/official.json" binaryRelativePath)
case "$BINARY_RELATIVE" in
    /* | *'..'*) die "Unsafe official bundle-relative binary path: $BINARY_RELATIVE" ;;
esac
cp -a "$OFFICIAL_BUNDLE/." "$STAGED_BUNDLE/"
STAGED_BINARY=$STAGED_BUNDLE/$BINARY_RELATIVE
[ -f "$STAGED_BINARY" ] && [ ! -L "$STAGED_BINARY" ] || die 'The copied official bundle has an unsafe binary path.'
cp "$DOWNLOADED_BINARY" "$STAGED_BINARY"
chmod 755 "$STAGED_BINARY"
[ "$(sha256_file "$STAGED_BINARY")" = "$CUSTOM_HASH" ] || die 'Staged binary SHA-256 verification failed.'

mv "$STAGED_BUNDLE" "$VERSION_ROOT"
VERSION_COMMITTED=1
CUSTOM_BINARY=$VERSION_ROOT/$BINARY_RELATIVE

python3 - "$STAGED_LAUNCHER_DIRECTORY/codex" "$CUSTOM_BINARY" "$LAUNCHER_DIRECTORY" "$LANGUAGE" "$StatusLineOverride" <<'PY'
import os
import shlex
import sys
from pathlib import Path

launcher = Path(sys.argv[1])
binary = Path(sys.argv[2])
installed_launcher_dir = Path(sys.argv[3])
language = sys.argv[4]
override = sys.argv[5]
relative = os.path.relpath(binary, installed_launcher_dir)
content = (
    "#!/bin/sh\n"
    "set -eu\n"
    "launcher_dir=$(CDPATH='' cd -- \"$(dirname -- \"$0\")\" && pwd -P)\n"
    f"export CODEX_USAGE_STATUSLINE_LANGUAGE={shlex.quote(language)}\n"
    f"exec \"$launcher_dir\"/{shlex.quote(relative)} -c {shlex.quote(override)} \"$@\"\n"
)
launcher.write_text(content, encoding="utf-8")
launcher.chmod(0o755)
PY
mv "$STAGED_LAUNCHER_DIRECTORY" "$LAUNCHER_DIRECTORY"
LAUNCHER_COMMITTED=1
LAUNCHER_HASH=$(sha256_file "$LAUNCHER_PATH")

copy_profile_backup "$ZSH_PROFILE" "$OPERATION_ROOT/backups/zprofile" "$OPERATION_ROOT/backups/zprofile.state"
ZSH_BACKED_UP=1
python3 "$SCRIPT_DIR/scripts/profile_block.py" install \
    --path "$ZSH_PROFILE" --bin-dir "$LAUNCHER_DIRECTORY" >"$OPERATION_ROOT/zprofile.json"
copy_profile_backup "$BASH_PROFILE" "$OPERATION_ROOT/backups/bash_profile" "$OPERATION_ROOT/backups/bash_profile.state"
BASH_BACKED_UP=1
python3 "$SCRIPT_DIR/scripts/profile_block.py" install \
    --path "$BASH_PROFILE" --bin-dir "$LAUNCHER_DIRECTORY" >"$OPERATION_ROOT/bash-profile.json"

maybe_test_failpoint after-profile-write
if ! VERIFIED_VERSION=$("$LAUNCHER_PATH" --version 2>&1); then
    die "The installed launcher did not run: $VERIFIED_VERSION"
fi
DETECTED_INSTALLED_VERSION=$(printf '%s\n' "$VERIFIED_VERSION" | codex_version_from_output) || \
    die "Could not parse the installed launcher version: $VERIFIED_VERSION"
[ "$DETECTED_INSTALLED_VERSION" = "$SupportedCodexVersion" ] || \
    die "Installed launcher version mismatch: $VERIFIED_VERSION"
assert_config_unchanged

MANIFEST_TEMP=$OPERATION_ROOT/active-install.json
python3 "$SCRIPT_DIR/scripts/macos_manifest.py" create \
    --output "$MANIFEST_TEMP" \
    --project-version "$ProjectVersion" \
    --release-tag "$ReleaseTag" \
    --codex-version "$SupportedCodexVersion" \
    --customization-commit "$EXPECTED_CUSTOMIZATION_COMMIT" \
    --installed-at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --language "$LANGUAGE" \
    --asset-name "$ASSET_NAME" \
    --archive-sha256 "$ARCHIVE_HASH" \
    --official-info "$OPERATION_ROOT/official.json" \
    --custom-bundle "$VERSION_ROOT" \
    --custom-binary "$CUSTOM_BINARY" \
    --custom-binary-sha256 "$CUSTOM_HASH" \
    --launcher-directory "$LAUNCHER_DIRECTORY" \
    --launcher-path "$LAUNCHER_PATH" \
    --launcher-sha256 "$LAUNCHER_HASH" \
    --status-line-override "$StatusLineOverride" \
    --config-toml-before "$CONFIG_FINGERPRINT_BEFORE" \
    --profile-record "$OPERATION_ROOT/zprofile.json" \
    --profile-record "$OPERATION_ROOT/bash-profile.json"
MANIFEST_PUBLISHING=1
mv "$MANIFEST_TEMP" "$ACTIVE_MANIFEST"
maybe_test_failpoint after-manifest-publish
TRANSACTION_COMMITTED=1

printf 'codex-usage-statusline was installed without modifying the official Codex installation.\n'
printf 'Open a new terminal so the managed PATH block takes effect.\n'
printf 'Recovery manifest: %s\n' "$ACTIVE_MANIFEST"
