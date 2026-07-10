#!/bin/sh

set -eu
umask 077

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
ProjectVersion='0.3.0'
SupportedCodexVersion='0.144.1'
STATE_ROOT=${CODEX_USAGE_STATUSLINE_STATE_ROOT:-"$HOME/Library/Application Support/codex-usage-statusline"}

usage() {
    cat <<'EOF'
Usage: ./uninstall.sh [--state-root PATH]

Removes only the managed launcher, shell profile blocks, and customized bundle.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --state-root)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            STATE_ROOT=$2
            shift
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

. "$SCRIPT_DIR/scripts/macos_common.sh"

require_command python3
require_command shasum
require_command awk
require_command sed
require_command cp
require_command mv
require_command lockf

[ "$(uname -s)" = Darwin ] || die 'uninstall.sh supports macOS only.'
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
LOCK_HELD=0
LOCK_FILE=
OPERATION_ROOT=
TRANSACTION_COMMITTED=0
MANIFEST_MOVING=0
COMPLETED_MANIFEST=
ZSH_BACKED_UP=0
BASH_BACKED_UP=0
LAUNCHER_MOVED=0
VERSION_MOVED=0

rollback_uninstall() {
    if [ "$VERSION_MOVED" = 1 ] && [ -e "$OPERATION_ROOT/payload/version" ]; then
        mv "$OPERATION_ROOT/payload/version" "$VERSION_ROOT" || true
    fi
    if [ "$LAUNCHER_MOVED" = 1 ] && [ -e "$OPERATION_ROOT/payload/launcher" ]; then
        mv "$OPERATION_ROOT/payload/launcher" "$LAUNCHER_DIRECTORY" || true
    fi
    if [ "$ZSH_BACKED_UP" = 1 ]; then
        restore_profile_backup "$ZSH_PROFILE" "$OPERATION_ROOT/backups/zprofile" "$OPERATION_ROOT/backups/zprofile.state" || true
    fi
    if [ "$BASH_BACKED_UP" = 1 ]; then
        restore_profile_backup "$BASH_PROFILE" "$OPERATION_ROOT/backups/bash_profile" "$OPERATION_ROOT/backups/bash_profile.state" || true
    fi
    if [ "$MANIFEST_MOVING" = 1 ] && [ ! -e "$ACTIVE_MANIFEST" ] && [ -f "$COMPLETED_MANIFEST" ] && [ ! -L "$COMPLETED_MANIFEST" ]; then
        mv "$COMPLETED_MANIFEST" "$ACTIVE_MANIFEST" || true
    fi
}

finish_uninstall() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ "$result" -ne 0 ] && [ "$TRANSACTION_COMMITTED" != 1 ]; then
        rollback_uninstall
        printf 'Uninstallation failed; installer-owned changes were rolled back.\n' >&2
    fi
    if [ -n "$OPERATION_ROOT" ] && { [ -e "$OPERATION_ROOT" ] || [ -L "$OPERATION_ROOT" ]; }; then
        remove_owned_path "$OPERATION_ROOT" || true
    fi
    release_state_lock
    exit "$result"
}

acquire_state_lock
trap finish_uninstall EXIT
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

[ -f "$ACTIVE_MANIFEST" ] && [ ! -L "$ACTIVE_MANIFEST" ] || \
    die "No active codex-usage-statusline installation was found at $ACTIVE_MANIFEST"

python3 "$SCRIPT_DIR/scripts/macos_manifest.py" validate \
    --manifest "$ACTIVE_MANIFEST" \
    --state-root "$STATE_ROOT" \
    --project-version "$ProjectVersion" \
    --codex-version "$SupportedCodexVersion" \
    --home "$HOME" >/dev/null

LAUNCHER_DIRECTORY=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" get --manifest "$ACTIVE_MANIFEST" --field launcherDirectory)
LAUNCHER_PATH=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" get --manifest "$ACTIVE_MANIFEST" --field launcherPath)
VERSION_ROOT=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" get --manifest "$ACTIVE_MANIFEST" --field customBundlePath)
CUSTOM_BINARY=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" get --manifest "$ACTIVE_MANIFEST" --field customBinaryPath)
EXPECTED_LAUNCHER_HASH=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" get --manifest "$ACTIVE_MANIFEST" --field launcherSha256)
EXPECTED_BINARY_HASH=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" get --manifest "$ACTIVE_MANIFEST" --field customBinarySha256)
assert_owned_path "$LAUNCHER_DIRECTORY"
assert_owned_path "$LAUNCHER_PATH"
assert_owned_path "$VERSION_ROOT"
assert_owned_path "$CUSTOM_BINARY"

FILES_PRESERVED=0
if ! python3 "$SCRIPT_DIR/scripts/macos_manifest.py" verify-inventory \
    --manifest "$ACTIVE_MANIFEST" --kind bundle >/dev/null; then
    FILES_PRESERVED=1
    printf 'Warning: The customized bundle inventory changed; installer-owned files will be preserved.\n' >&2
fi
if ! python3 "$SCRIPT_DIR/scripts/macos_manifest.py" verify-inventory \
    --manifest "$ACTIVE_MANIFEST" --kind launcher >/dev/null; then
    FILES_PRESERVED=1
    printf 'Warning: The launcher inventory changed; installer-owned files will be preserved.\n' >&2
fi
if [ ! -f "$CUSTOM_BINARY" ] || [ -L "$CUSTOM_BINARY" ] || \
    [ "$(sha256_file "$CUSTOM_BINARY" 2>/dev/null || true)" != "$EXPECTED_BINARY_HASH" ]; then
    FILES_PRESERVED=1
    printf 'Warning: The customized binary is missing or changed; its bundle will be preserved.\n' >&2
fi
if [ ! -f "$LAUNCHER_PATH" ] || [ -L "$LAUNCHER_PATH" ] || \
    [ "$(sha256_file "$LAUNCHER_PATH" 2>/dev/null || true)" != "$EXPECTED_LAUNCHER_HASH" ]; then
    FILES_PRESERVED=1
    printf 'Warning: The launcher is missing or changed; installer-owned files will be preserved.\n' >&2
fi

for profile in "$ZSH_PROFILE" "$BASH_PROFILE"; do
    block_hash=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" profile --manifest "$ACTIVE_MANIFEST" --path "$profile" --field blockSha256)
    python3 "$SCRIPT_DIR/scripts/profile_block.py" verify \
        --path "$profile" --bin-dir "$LAUNCHER_DIRECTORY" --expected-block-sha "$block_hash" >/dev/null
done

OPERATION_ROOT=$STATE_ROOT/.staging.uninstall.$$
mkdir -p "$OPERATION_ROOT/backups" "$OPERATION_ROOT/payload"
printf '%s\n' "$ZSH_PROFILE" >"$OPERATION_ROOT/zprofile.path"
printf '%s\n' "$BASH_PROFILE" >"$OPERATION_ROOT/bash-profile.path"
copy_profile_backup "$ZSH_PROFILE" "$OPERATION_ROOT/backups/zprofile" "$OPERATION_ROOT/backups/zprofile.state"
ZSH_BACKED_UP=1
copy_profile_backup "$BASH_PROFILE" "$OPERATION_ROOT/backups/bash_profile" "$OPERATION_ROOT/backups/bash_profile.state"
BASH_BACKED_UP=1

for profile in "$ZSH_PROFILE" "$BASH_PROFILE"; do
    block_hash=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" profile --manifest "$ACTIVE_MANIFEST" --path "$profile" --field blockSha256)
    separator=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" profile --manifest "$ACTIVE_MANIFEST" --path "$profile" --field separator)
    previous_hash=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" profile --manifest "$ACTIVE_MANIFEST" --path "$profile" --field previousSha256)
    existed=$(python3 "$SCRIPT_DIR/scripts/macos_manifest.py" profile --manifest "$ACTIVE_MANIFEST" --path "$profile" --field existed)
    existed_arg=
    [ "$existed" = true ] && existed_arg=--existed-before
    python3 "$SCRIPT_DIR/scripts/profile_block.py" remove \
        --path "$profile" \
        --bin-dir "$LAUNCHER_DIRECTORY" \
        --expected-block-sha "$block_hash" \
        --previous-sha "$previous_hash" \
        --separator "$separator" \
        $existed_arg >/dev/null
done

maybe_test_failpoint after-profile-remove
if [ "$FILES_PRESERVED" = 0 ]; then
    mv "$LAUNCHER_DIRECTORY" "$OPERATION_ROOT/payload/launcher"
    LAUNCHER_MOVED=1
    mv "$VERSION_ROOT" "$OPERATION_ROOT/payload/version"
    VERSION_MOVED=1
fi
maybe_test_failpoint after-payload-move
assert_config_unchanged

COMPLETED_MANIFEST=$STATE_ROOT/uninstalled-$(date -u '+%Y%m%d-%H%M%S')-$$.json
MANIFEST_MOVING=1
mv "$ACTIVE_MANIFEST" "$COMPLETED_MANIFEST"
maybe_test_failpoint after-manifest-retire
TRANSACTION_COMMITTED=1

printf 'codex-usage-statusline was disabled; the official Codex installation was not modified.\n'
if [ "$FILES_PRESERVED" = 1 ]; then
    printf 'Warning: Modified installer-owned files remain under %s, but their PATH blocks were removed.\n' "$STATE_ROOT" >&2
fi
printf 'Open a new terminal so the PATH change takes effect.\n'
