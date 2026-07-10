#!/bin/sh

# Shared safety and transaction helpers for install.sh and uninstall.sh.

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found."
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

config_toml_fingerprint() {
    config_path=$HOME/.codex/config.toml
    if [ -e "$config_path" ] || [ -L "$config_path" ]; then
        [ -f "$config_path" ] && [ ! -L "$config_path" ] || die "Refusing an unsafe config.toml path: $config_path"
        printf 'present:%s\n' "$(sha256_file "$config_path")"
    else
        printf 'absent\n'
    fi
}

assert_config_unchanged() {
    current_config_fingerprint=$(config_toml_fingerprint)
    [ "$current_config_fingerprint" = "$CONFIG_FINGERPRINT_BEFORE" ] || \
        die "$HOME/.codex/config.toml changed while the operation was running."
}

normalize_profile_path() {
    profile_path=$1
    profile_shell=$2
    python3 - "$profile_path" "$profile_shell" "$HOME" <<'PY'
import os
import sys
from pathlib import Path

raw, shell, home_raw = sys.argv[1:]
if any(character in raw for character in "\r\n\0"):
    raise SystemExit("A shell profile path contains a control character")
path = Path(raw)
if not path.is_absolute():
    raise SystemExit(f"A shell profile path must be absolute: {path}")
path = path.resolve(strict=False)
home = Path(home_raw).resolve(strict=False)
if shell == "zsh":
    if path.name != ".zprofile":
        raise SystemExit(f"Unexpected zsh profile path: {path}")
elif shell == "bash":
    if path != home / ".bash_profile":
        raise SystemExit(f"Unexpected bash profile path: {path}")
else:
    raise SystemExit(f"Unsupported profile shell: {shell}")
print(path)
PY
}

default_zsh_profile() {
    zdotdir=${ZDOTDIR:-$HOME}
    case "$zdotdir" in
        /*) ;;
        *) die "ZDOTDIR must be absolute so new terminals resolve one stable .zprofile: $zdotdir" ;;
    esac
    normalize_profile_path "$zdotdir/.zprofile" zsh
}

staged_profile_path() {
    path_file=$1
    profile_shell=$2
    fallback=$3
    if [ -e "$path_file" ] || [ -L "$path_file" ]; then
        [ -f "$path_file" ] && [ ! -L "$path_file" ] || die "Unsafe staged $profile_shell profile path: $path_file"
        profile_path=$(sed -n '1p' "$path_file")
        [ -n "$profile_path" ] || die "Empty staged $profile_shell profile path: $path_file"
        normalize_profile_path "$profile_path" "$profile_shell"
    else
        printf '%s\n' "$fallback"
    fi
}

assert_safe_state_root() {
    python3 - "$STATE_ROOT" "$HOME" <<'PY'
import os
import sys
from pathlib import Path

root = Path(sys.argv[1]).expanduser()
home = Path(sys.argv[2]).expanduser().resolve()
if not root.is_absolute():
    raise SystemExit("The installer state root must be absolute")
if any(character in str(root) for character in "\r\n\0"):
    raise SystemExit("The installer state root contains a control character")
resolved = root.resolve(strict=False)
for unsafe in (Path("/"), home, home / ".codex"):
    if resolved == unsafe.resolve(strict=False):
        raise SystemExit(f"Unsafe installer state root: {resolved}")
if root.is_symlink():
    raise SystemExit(f"The installer state root must not be a symlink: {root}")
PY
}

assert_owned_path() {
    python3 - "$1" "$STATE_ROOT" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1]).resolve(strict=False)
root = Path(sys.argv[2]).resolve(strict=False)
try:
    path.relative_to(root)
except ValueError as exc:
    raise SystemExit(f"Refusing to modify a path outside the installer state root: {path}") from exc
if path == root:
    raise SystemExit(f"Refusing to remove the installer state root itself: {path}")
PY
}

remove_owned_path() {
    owned_path=$1
    if [ ! -e "$owned_path" ] && [ ! -L "$owned_path" ]; then
        return
    fi
    assert_owned_path "$owned_path" || return 1
    if [ -L "$owned_path" ]; then
        rm -f "$owned_path"
    else
        rm -rf "$owned_path"
    fi
}

recover_stale_operations() {
    active_manifest=$STATE_ROOT/active-install.json
    expected_launcher=$STATE_ROOT/bin
    # Set by both entry-point scripts before this shared file is sourced.
    # shellcheck disable=SC2154
    expected_version=$STATE_ROOT/versions/$ProjectVersion-codex-$SupportedCodexVersion

    for stale_path in "$STATE_ROOT"/.staging.install.*; do
        if [ ! -e "$stale_path" ] && [ ! -L "$stale_path" ]; then
            continue
        fi
        [ -d "$stale_path" ] && [ ! -L "$stale_path" ] || die "Unsafe stale install state: $stale_path"
        if [ ! -f "$active_manifest" ]; then
            stale_zsh_profile=$(staged_profile_path "$stale_path/zprofile.path" zsh "$ZSH_PROFILE")
            stale_bash_profile=$(staged_profile_path "$stale_path/bash-profile.path" bash "$BASH_PROFILE")
            restore_profile_backup "$stale_zsh_profile" "$stale_path/backups/zprofile" "$stale_path/backups/zprofile.state"
            restore_profile_backup "$stale_bash_profile" "$stale_path/backups/bash_profile" "$stale_path/backups/bash_profile.state"
            remove_owned_path "$expected_launcher"
            remove_owned_path "$expected_version"
        fi
        remove_owned_path "$stale_path"
    done

    for stale_path in "$STATE_ROOT"/.staging.uninstall.*; do
        if [ ! -e "$stale_path" ] && [ ! -L "$stale_path" ]; then
            continue
        fi
        [ -d "$stale_path" ] && [ ! -L "$stale_path" ] || die "Unsafe stale uninstall state: $stale_path"
        if [ -f "$active_manifest" ]; then
            if [ -e "$stale_path/payload/launcher" ]; then
                [ ! -e "$expected_launcher" ] && [ ! -L "$expected_launcher" ] || \
                    die "Cannot restore a stale launcher over an existing path: $expected_launcher"
                mv "$stale_path/payload/launcher" "$expected_launcher"
            fi
            if [ -e "$stale_path/payload/version" ]; then
                [ ! -e "$expected_version" ] && [ ! -L "$expected_version" ] || \
                    die "Cannot restore a stale version over an existing path: $expected_version"
                mkdir -p "$(dirname "$expected_version")"
                mv "$stale_path/payload/version" "$expected_version"
            fi
            restore_profile_backup "$ZSH_PROFILE" "$stale_path/backups/zprofile" "$stale_path/backups/zprofile.state"
            restore_profile_backup "$BASH_PROFILE" "$stale_path/backups/bash_profile" "$stale_path/backups/bash_profile.state"
        fi
        remove_owned_path "$stale_path"
    done
}

acquire_state_lock() {
    mkdir -p "$STATE_ROOT"
    chmod 700 "$STATE_ROOT"
    LOCK_FILE=$STATE_ROOT/.operation.lock
    if [ -e "$LOCK_FILE" ] || [ -L "$LOCK_FILE" ]; then
        [ -f "$LOCK_FILE" ] && [ ! -L "$LOCK_FILE" ] || die "Unsafe installer lock path: $LOCK_FILE"
    else
        : >>"$LOCK_FILE"
    fi
    chmod 600 "$LOCK_FILE"
    exec 9>>"$LOCK_FILE"
    if ! lockf -s -t 5 9; then
        exec 9>&-
        die 'Another codex-usage-statusline install or uninstall is already running.'
    fi
    LOCK_HELD=1
}

release_state_lock() {
    if [ "${LOCK_HELD:-0}" = 1 ]; then
        exec 9>&-
        LOCK_HELD=0
    fi
}

copy_profile_backup() {
    profile_path=$1
    backup_path=$2
    marker_path=$3
    if [ -e "$profile_path" ] || [ -L "$profile_path" ]; then
        [ -f "$profile_path" ] && [ ! -L "$profile_path" ] || die "Unsafe shell profile path: $profile_path"
        cp -p "$profile_path" "$backup_path"
        printf 'present\n' >"$marker_path"
    else
        printf 'absent\n' >"$marker_path"
    fi
}

restore_profile_backup() {
    profile_path=$1
    backup_path=$2
    marker_path=$3
    [ -f "$marker_path" ] && [ ! -L "$marker_path" ] || return
    marker=$(sed -n '1p' "$marker_path")
    if [ "$marker" = present ]; then
        [ -f "$backup_path" ] && [ ! -L "$backup_path" ] || die "Unsafe or missing profile backup: $backup_path"
        cp -p "$backup_path" "$profile_path"
    elif [ "$marker" = absent ]; then
        rm -f "$profile_path"
    else
        die "Invalid profile backup marker: $marker_path"
    fi
}

validate_release_base_url() {
    python3 - "$RELEASE_BASE_URL" <<'PY'
import sys
from urllib.parse import urlsplit

value = sys.argv[1]
parsed = urlsplit(value)
if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
    raise SystemExit("ReleaseBaseUrl must be an absolute HTTPS URL without credentials")
if parsed.query or parsed.fragment:
    raise SystemExit("ReleaseBaseUrl must not contain a query or fragment")
PY
}

resolve_release_tag_commit() {
    require_command git
    # Repository and ReleaseTag are set by install.sh.
    # shellcheck disable=SC2154
    refs=$(git ls-remote --tags "https://github.com/$Repository.git" \
        "refs/tags/$ReleaseTag" "refs/tags/$ReleaseTag^{}") || \
        die "Could not resolve the immutable release tag $ReleaseTag."
    python3 - "$ReleaseTag" "$refs" <<'PY'
import re
import sys

tag = sys.argv[1]
direct = []
peeled = []
for line in sys.argv[2].splitlines():
    fields = line.rstrip("\n").split("\t")
    if len(fields) != 2 or not re.fullmatch(r"[0-9a-f]{40}", fields[0]):
        continue
    if fields[1] == f"refs/tags/{tag}":
        direct.append(fields[0])
    elif fields[1] == f"refs/tags/{tag}^{{}}":
        peeled.append(fields[0])
matches = peeled or direct
if len(matches) != 1:
    raise SystemExit(f"Expected one commit for release tag {tag}")
print(matches[0])
PY
}

download_release_file() {
    name=$1
    output=$2
    if [ -n "${RELEASE_DIRECTORY:-}" ]; then
        [ "${CODEX_USAGE_STATUSLINE_TEST_MODE:-0}" = 1 ] || \
            [ "${CODEX_USAGE_STATUSLINE_RELEASE_CANDIDATE:-0}" = 1 ] || \
            die "--release-directory is available only in installer tests or release-candidate validation."
        cp "$RELEASE_DIRECTORY/$name" "$output"
        return
    fi
    curl --proto '=https' --tlsv1.2 --location --fail --show-error --silent \
        --retry 2 --retry-all-errors --connect-timeout 10 \
        --max-filesize 681574400 \
        "$RELEASE_BASE_URL/$name" --output "$output"
}

assert_file_size_at_most() {
    checked_path=$1
    maximum_size=$2
    actual_size=$(wc -c <"$checked_path" | tr -d '[:space:]')
    case "$actual_size" in
        '' | *[!0-9]*) die "Could not determine file size: $checked_path" ;;
    esac
    [ "$actual_size" -le "$maximum_size" ] || \
        die "Downloaded file exceeds its safety limit: $checked_path"
}

codex_version_from_output() {
    python3 -c '
import re, sys
text = sys.stdin.read().strip()
match = re.search(r"(?:^|\s)(\d+\.\d+\.\d+)(?:\s|$)", text)
if not match:
    raise SystemExit(1)
print(match.group(1))
'
}

maybe_test_failpoint() {
    point=$1
    [ "${CODEX_USAGE_STATUSLINE_TEST_MODE:-0}" = 1 ] || return 0
    if [ "${CODEX_USAGE_STATUSLINE_FAILPOINT:-}" = "$point" ]; then
        die "Injected test failure at $point"
    fi
    if [ "${CODEX_USAGE_STATUSLINE_PAUSE_AT:-}" = "$point" ]; then
        signal_dir=${CODEX_USAGE_STATUSLINE_SIGNAL_DIR:-$STATE_ROOT}
        mkdir -p "$signal_dir"
        : >"$signal_dir/$point"
        while [ -e "$signal_dir/$point" ]; do
            sleep 1
        done
    fi
}

json_field() {
    json_path=$1
    field=$2
    python3 - "$json_path" "$field" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
field = sys.argv[2]
result = value.get(field)
if not isinstance(result, str) or any(character in result for character in "\r\n\0"):
    raise SystemExit(f"Invalid JSON string field: {field}")
print(result)
PY
}
