#!/bin/sh

set -eu
umask 077

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
PROJECT_VERSION=0.3.0
CODEX_VERSION=0.144.1
TARGET=aarch64-apple-darwin
SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/codex-statusline-tests.XXXXXX")
TEMP_ROOT=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TEMP_ROOT")

cleanup() {
    if [ "${KEEP_TEST_TEMP:-0}" = 1 ]; then
        printf 'Preserved test directory: %s\n' "$TEMP_ROOT" >&2
    else
        rm -rf "$TEMP_ROOT"
    fi
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    actual=$1
    expected=$2
    message=$3
    [ "$actual" = "$expected" ] || fail "$message (expected '$expected', got '$actual')"
}

assert_file_hash() {
    path=$1
    expected=$2
    actual=$(shasum -a 256 "$path" | awk '{print $1}')
    assert_equal "$actual" "$expected" "Unexpected file hash for $path"
}

expect_failure() {
    if "$@"; then
        fail "Command unexpectedly succeeded: $*"
    fi
}

write_fake_binary() {
    path=$1
    label=$2
    mkdir -p "$(dirname "$path")"
    cat >"$path" <<EOF
#!/bin/sh
for argument in "\$@"; do
    if [ "\$argument" = "--version" ]; then
        printf 'codex-cli $CODEX_VERSION\\n'
        exit 0
    fi
done
printf '$label LANG=%s\\n' "\${CODEX_USAGE_STATUSLINE_LANGUAGE:-unset}"
for argument in "\$@"; do
    printf '$label ARG=%s\\n' "\$argument"
done
EOF
    chmod 755 "$path"
}

make_npm_install() {
    base=$1
    package_root=$base/lib/node_modules/@openai/codex
    native=$package_root/node_modules/@openai/codex-darwin-arm64/vendor/$TARGET/bin/codex
    write_fake_binary "$native" OFFICIAL
    mkdir -p "$package_root/bin" "$base/bin"
    cat >"$package_root/bin/codex.js" <<EOF
#!/bin/sh
exec '$native' "\$@"
EOF
    chmod 755 "$package_root/bin/codex.js"
    ln -s "$package_root/bin/codex.js" "$base/bin/codex"
}

make_standalone_install() {
    home=$1
    release=$home/.codex/packages/standalone/releases/$CODEX_VERSION-$TARGET
    write_fake_binary "$release/bin/codex" OFFICIAL
    printf '{"version":"%s","target":"%s"}\n' "$CODEX_VERSION" "$TARGET" >"$release/codex-package.json"
    mkdir -p "$home/.codex/packages/standalone" "$home/.local/bin"
    ln -s "$release" "$home/.codex/packages/standalone/current"
    ln -s "$release/bin/codex" "$home/.local/bin/codex"
}

make_homebrew_install() {
    base=$1
    binary=$base/opt/homebrew/Caskroom/codex/$CODEX_VERSION/codex-aarch64-apple-darwin
    write_fake_binary "$binary" OFFICIAL
    mkdir -p "$base/opt/homebrew/bin"
    ln -s "$binary" "$base/opt/homebrew/bin/codex"
}

detected_kind() {
    home=$1
    command_path=$2
    CODEX_HOME=${3:-$home/.codex} HOME="$home" PATH="$command_path:$SYSTEM_PATH" \
        python3 "$ROOT/scripts/detect_macos_codex.py" \
        --expected-version "$CODEX_VERSION" \
        --state-root "$home/state" \
        --home "$home" \
        --allow-test-binaries |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["installationKind"])'
}

[ "$(uname -s)" = Darwin ] || fail 'macOS installer tests require macOS.'

NPM_ROOT=$TEMP_ROOT/npm
make_npm_install "$NPM_ROOT"
assert_equal "$(detected_kind "$TEMP_ROOT/npm-home" "$NPM_ROOT/bin")" npm 'npm detection failed'

STANDALONE_HOME=$TEMP_ROOT/standalone-home
make_standalone_install "$STANDALONE_HOME"
assert_equal "$(detected_kind "$STANDALONE_HOME" "$STANDALONE_HOME/.local/bin")" standalone 'standalone detection failed'

BREW_ROOT=$TEMP_ROOT/brew
make_homebrew_install "$BREW_ROOT"
assert_equal "$(detected_kind "$TEMP_ROOT/brew-home" "$BREW_ROOT/opt/homebrew/bin")" homebrew 'Homebrew detection failed'

make_test_home() {
    home=$1
    mkdir -p "$home/.codex"
    printf 'model = "test"\n' >"$home/.codex/config.toml"
    printf 'export USER_Z=1' >"$home/.zprofile"
    printf 'export USER_BASH=1\n' >"$home/.bash_profile"
}

DIST=$TEMP_ROOT/release
RELEASE_FIXTURE_ROOT=$TEMP_ROOT/release-fixture
TEST_RELEASE_LOCK=$RELEASE_FIXTURE_ROOT/release-lock.json
TEST_SIGNING_KEY=$RELEASE_FIXTURE_ROOT/release-signing-private.pem
mkdir -p "$RELEASE_FIXTURE_ROOT/keys"
cp "$ROOT/release-lock.json" "$ROOT/LICENSE" "$ROOT/NOTICE.md" "$RELEASE_FIXTURE_ROOT/"
/usr/bin/openssl genrsa -out "$TEST_SIGNING_KEY" 2048 >/dev/null 2>&1
/usr/bin/openssl pkey -in "$TEST_SIGNING_KEY" -pubout \
    -out "$RELEASE_FIXTURE_ROOT/keys/release-signing-public.pem" >/dev/null 2>&1
python3 - "$TEST_RELEASE_LOCK" "$RELEASE_FIXTURE_ROOT/keys/release-signing-public.pem" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

lock_path = Path(sys.argv[1])
public_key = Path(sys.argv[2])
lock = json.loads(lock_path.read_text(encoding="utf-8"))
lock["releaseSigning"]["publicKeySha256"] = hashlib.sha256(public_key.read_bytes()).hexdigest()
lock["releaseSigning"]["signatureSize"] = 256
lock_path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
PY
CUSTOM_MAC=$TEMP_ROOT/custom-codex
CUSTOM_WINDOWS=$TEMP_ROOT/codex.exe
write_fake_binary "$CUSTOM_MAC" CUSTOM
write_fake_binary "$CUSTOM_WINDOWS" WINDOWS
COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
python3 "$ROOT/scripts/release_assets.py" package \
    --lock "$TEST_RELEASE_LOCK" \
    --target x86_64-pc-windows-msvc \
    --binary "$CUSTOM_WINDOWS" \
    --dist "$DIST" \
    --customization-commit "$COMMIT" \
    --debug-symbols-stripped false
CODEX_USAGE_STATUSLINE_TEST_MODE=1 python3 "$ROOT/scripts/release_assets.py" package \
    --lock "$TEST_RELEASE_LOCK" \
    --target "$TARGET" \
    --binary "$CUSTOM_MAC" \
    --dist "$DIST" \
    --customization-commit "$COMMIT" \
    --debug-symbols-stripped true \
    --allow-test-macos-binary
python3 "$ROOT/scripts/release_assets.py" assemble \
    --lock "$TEST_RELEASE_LOCK" --dist "$DIST" --signing-key "$TEST_SIGNING_KEY" \
    --customization-commit "$COMMIT"
python3 "$ROOT/scripts/release_assets.py" verify --lock "$TEST_RELEASE_LOCK" --release-dir "$DIST" \
    --expected-customization-commit "$COMMIT"
cp "$DIST/SHA256SUMS.sig" "$TEMP_ROOT/SHA256SUMS.sig"
printf 'tampered' >>"$DIST/SHA256SUMS.sig"
expect_failure python3 "$ROOT/scripts/release_assets.py" verify \
    --lock "$TEST_RELEASE_LOCK" --release-dir "$DIST" \
    --expected-customization-commit "$COMMIT"
mv "$TEMP_ROOT/SHA256SUMS.sig" "$DIST/SHA256SUMS.sig"

# A validly signed bundle from a different customization commit must be rejected.
WRONG_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
WRONG_COMMIT_DIST=$TEMP_ROOT/wrong-commit-release
python3 "$ROOT/scripts/release_assets.py" package \
    --lock "$TEST_RELEASE_LOCK" --target x86_64-pc-windows-msvc \
    --binary "$CUSTOM_WINDOWS" --dist "$WRONG_COMMIT_DIST" \
    --customization-commit "$WRONG_COMMIT" --debug-symbols-stripped false
CODEX_USAGE_STATUSLINE_TEST_MODE=1 python3 "$ROOT/scripts/release_assets.py" package \
    --lock "$TEST_RELEASE_LOCK" --target "$TARGET" \
    --binary "$CUSTOM_MAC" --dist "$WRONG_COMMIT_DIST" \
    --customization-commit "$WRONG_COMMIT" --debug-symbols-stripped true \
    --allow-test-macos-binary
python3 "$ROOT/scripts/release_assets.py" assemble \
    --lock "$TEST_RELEASE_LOCK" --dist "$WRONG_COMMIT_DIST" \
    --signing-key "$TEST_SIGNING_KEY" --customization-commit "$WRONG_COMMIT"
WRONG_COMMIT_HOME=$TEMP_ROOT/'wrong commit home'
WRONG_COMMIT_STATE=$TEMP_ROOT/'wrong commit state'
make_test_home "$WRONG_COMMIT_HOME"
wrong_commit_z_hash=$(shasum -a 256 "$WRONG_COMMIT_HOME/.zprofile" | awk '{print $1}')
expect_failure env \
    HOME="$WRONG_COMMIT_HOME" ZDOTDIR="$WRONG_COMMIT_HOME" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" \
    CODEX_USAGE_STATUSLINE_TEST_MODE=1 \
    "$ROOT/install.sh" --state-root "$WRONG_COMMIT_STATE" \
    --release-directory "$WRONG_COMMIT_DIST" --release-lock "$TEST_RELEASE_LOCK" \
    --expected-customization-commit "$COMMIT"
[ ! -e "$WRONG_COMMIT_STATE/active-install.json" ] || fail 'Wrong-commit release left an active manifest.'
[ ! -e "$WRONG_COMMIT_STATE/bin" ] || fail 'Wrong-commit release left a launcher.'
assert_file_hash "$WRONG_COMMIT_HOME/.zprofile" "$wrong_commit_z_hash"

run_installer() {
    home=$1
    state=$2
    shift 2
    official_path=${TEST_OFFICIAL_PATH:-$NPM_ROOT/bin}
    HOME="$home" ZDOTDIR="${TEST_ZDOTDIR:-$home}" PATH="$official_path:$SYSTEM_PATH" \
        CODEX_USAGE_STATUSLINE_TEST_MODE=1 \
        "$ROOT/install.sh" \
        --state-root "$state" \
        --release-directory "$DIST" \
        --release-lock "$TEST_RELEASE_LOCK" \
        --expected-customization-commit "$COMMIT" \
        "$@"
}

run_uninstaller() {
    home=$1
    state=$2
    shift 2
    official_path=${TEST_OFFICIAL_PATH:-$NPM_ROOT/bin}
    HOME="$home" ZDOTDIR="${TEST_ZDOTDIR:-$home}" PATH="$official_path:$SYSTEM_PATH" \
        CODEX_USAGE_STATUSLINE_TEST_MODE=1 \
        "$ROOT/uninstall.sh" --state-root "$state" "$@"
}

# Standalone and Homebrew layouts must complete the same full install/reinstall/remove flow.
standalone_config_hash=$(shasum -a 256 "$STANDALONE_HOME/.codex/config.toml" 2>/dev/null | awk '{print $1}')
if [ -z "$standalone_config_hash" ]; then
    printf 'model = "standalone-test"\n' >"$STANDALONE_HOME/.codex/config.toml"
    standalone_config_hash=$(shasum -a 256 "$STANDALONE_HOME/.codex/config.toml" | awk '{print $1}')
fi
printf 'export STANDALONE_Z=1\n' >"$STANDALONE_HOME/.zprofile"
printf 'export STANDALONE_BASH=1\n' >"$STANDALONE_HOME/.bash_profile"
STANDALONE_STATE=$TEMP_ROOT/'standalone state'
TEST_OFFICIAL_PATH="$STANDALONE_HOME/.local/bin" run_installer "$STANDALONE_HOME" "$STANDALONE_STATE"
assert_equal "$(python3 "$ROOT/scripts/macos_manifest.py" get --manifest "$STANDALONE_STATE/active-install.json" --field officialInstallationKind)" standalone 'Standalone full install recorded the wrong layout.'
TEST_OFFICIAL_PATH="$STANDALONE_HOME/.local/bin" run_installer "$STANDALONE_HOME" "$STANDALONE_STATE"
TEST_OFFICIAL_PATH="$STANDALONE_HOME/.local/bin" run_uninstaller "$STANDALONE_HOME" "$STANDALONE_STATE"
assert_file_hash "$STANDALONE_HOME/.codex/config.toml" "$standalone_config_hash"

BREW_FLOW_HOME=$TEMP_ROOT/'homebrew flow home'
make_test_home "$BREW_FLOW_HOME"
brew_config_hash=$(shasum -a 256 "$BREW_FLOW_HOME/.codex/config.toml" | awk '{print $1}')
BREW_FLOW_STATE=$TEMP_ROOT/'homebrew flow state'
TEST_OFFICIAL_PATH="$BREW_ROOT/opt/homebrew/bin" run_installer "$BREW_FLOW_HOME" "$BREW_FLOW_STATE"
assert_equal "$(python3 "$ROOT/scripts/macos_manifest.py" get --manifest "$BREW_FLOW_STATE/active-install.json" --field officialInstallationKind)" homebrew 'Homebrew full install recorded the wrong layout.'
TEST_OFFICIAL_PATH="$BREW_ROOT/opt/homebrew/bin" run_installer "$BREW_FLOW_HOME" "$BREW_FLOW_STATE"
TEST_OFFICIAL_PATH="$BREW_ROOT/opt/homebrew/bin" run_uninstaller "$BREW_FLOW_HOME" "$BREW_FLOW_STATE"
assert_file_hash "$BREW_FLOW_HOME/.codex/config.toml" "$brew_config_hash"

# A checksum mismatch must fail before profiles or payload are committed.
BAD_DIST=$TEMP_ROOT/bad-release
cp -R "$DIST" "$BAD_DIST"
printf 'tampered' >>"$BAD_DIST/codex-usage-statusline-$PROJECT_VERSION-codex-$CODEX_VERSION-$TARGET.tar.gz"
BAD_HOME=$TEMP_ROOT/'bad home'
BAD_STATE=$TEMP_ROOT/'bad state'
make_test_home "$BAD_HOME"
bad_z_hash=$(shasum -a 256 "$BAD_HOME/.zprofile" | awk '{print $1}')
expect_failure env \
    HOME="$BAD_HOME" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" \
    CODEX_USAGE_STATUSLINE_TEST_MODE=1 \
    "$ROOT/install.sh" --state-root "$BAD_STATE" --release-directory "$BAD_DIST" \
    --release-lock "$TEST_RELEASE_LOCK" --expected-customization-commit "$COMMIT"
[ ! -e "$BAD_STATE/active-install.json" ] || fail 'Checksum failure left an active manifest.'
[ ! -e "$BAD_STATE/bin" ] || fail 'Checksum failure left a launcher.'
assert_file_hash "$BAD_HOME/.zprofile" "$bad_z_hash"

# Network failure must leave profiles and config untouched.
NETWORK_HOME=$TEMP_ROOT/'network home'
NETWORK_STATE=$TEMP_ROOT/'network state'
make_test_home "$NETWORK_HOME"
network_config_hash=$(shasum -a 256 "$NETWORK_HOME/.codex/config.toml" | awk '{print $1}')
network_z_hash=$(shasum -a 256 "$NETWORK_HOME/.zprofile" | awk '{print $1}')
expect_failure env \
    HOME="$NETWORK_HOME" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" \
    CODEX_USAGE_STATUSLINE_TEST_MODE=1 \
    "$ROOT/install.sh" --state-root "$NETWORK_STATE" \
    --release-base-url https://127.0.0.1:1/unreachable \
    --expected-customization-commit "$COMMIT"
assert_file_hash "$NETWORK_HOME/.codex/config.toml" "$network_config_hash"
assert_file_hash "$NETWORK_HOME/.zprofile" "$network_z_hash"
[ ! -e "$NETWORK_STATE/active-install.json" ] || fail 'Network failure left an active manifest.'

# A failure after both profile writes must restore exact pre-install bytes.
ROLLBACK_HOME=$TEMP_ROOT/'rollback home'
ROLLBACK_STATE=$TEMP_ROOT/'rollback state'
make_test_home "$ROLLBACK_HOME"
rollback_z_hash=$(shasum -a 256 "$ROLLBACK_HOME/.zprofile" | awk '{print $1}')
rollback_bash_hash=$(shasum -a 256 "$ROLLBACK_HOME/.bash_profile" | awk '{print $1}')
expect_failure env \
    HOME="$ROLLBACK_HOME" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" \
    CODEX_USAGE_STATUSLINE_TEST_MODE=1 \
    CODEX_USAGE_STATUSLINE_FAILPOINT=after-profile-write \
    "$ROOT/install.sh" --state-root "$ROLLBACK_STATE" --release-directory "$DIST" \
    --release-lock "$TEST_RELEASE_LOCK" --expected-customization-commit "$COMMIT"
assert_file_hash "$ROLLBACK_HOME/.zprofile" "$rollback_z_hash"
assert_file_hash "$ROLLBACK_HOME/.bash_profile" "$rollback_bash_hash"
[ ! -e "$ROLLBACK_STATE/active-install.json" ] || fail 'Install rollback left an active manifest.'
[ ! -e "$ROLLBACK_STATE/bin" ] || fail 'Install rollback left a launcher.'

# Stale lock-file contents must not matter after the kernel releases its advisory lock.
REUSED_PID_HOME=$TEMP_ROOT/'reused pid home'
REUSED_PID_STATE=$TEMP_ROOT/'reused pid state'
make_test_home "$REUSED_PID_HOME"
mkdir -p "$REUSED_PID_STATE"
printf 'stale PID %s\n' "$$" >"$REUSED_PID_STATE/.operation.lock"
run_installer "$REUSED_PID_HOME" "$REUSED_PID_STATE"
[ -f "$REUSED_PID_STATE/active-install.json" ] || fail 'PID-reuse lock recovery did not install.'
run_uninstaller "$REUSED_PID_HOME" "$REUSED_PID_STATE"

# SIGKILL after profile activation leaves stale files and lock state; the next run rolls it back.
INTERRUPT_HOME=$TEMP_ROOT/'interrupt home'
INTERRUPT_STATE=$TEMP_ROOT/'interrupt state'
SIGNAL_DIR=$TEMP_ROOT/signals
make_test_home "$INTERRUPT_HOME"
mkdir -p "$SIGNAL_DIR"
interrupt_config_hash=$(shasum -a 256 "$INTERRUPT_HOME/.codex/config.toml" | awk '{print $1}')
interrupt_z_hash=$(shasum -a 256 "$INTERRUPT_HOME/.zprofile" | awk '{print $1}')
interrupt_bash_hash=$(shasum -a 256 "$INTERRUPT_HOME/.bash_profile" | awk '{print $1}')
env \
    HOME="$INTERRUPT_HOME" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" \
    CODEX_USAGE_STATUSLINE_TEST_MODE=1 \
    CODEX_USAGE_STATUSLINE_PAUSE_AT=after-profile-write \
    CODEX_USAGE_STATUSLINE_SIGNAL_DIR="$SIGNAL_DIR" \
    "$ROOT/install.sh" --state-root "$INTERRUPT_STATE" --release-directory "$DIST" \
    --release-lock "$TEST_RELEASE_LOCK" --expected-customization-commit "$COMMIT" \
    >"$TEMP_ROOT/interrupted.log" 2>&1 &
interrupted_pid=$!
counter=0
while [ ! -e "$SIGNAL_DIR/after-profile-write" ] && [ "$counter" -lt 30 ]; do
    sleep 1
    counter=$((counter + 1))
done
[ -e "$SIGNAL_DIR/after-profile-write" ] || fail 'Interrupted-install pause point was not reached.'
expect_failure run_installer "$INTERRUPT_HOME" "$INTERRUPT_STATE"
kill -9 "$interrupted_pid"
wait "$interrupted_pid" 2>/dev/null || true
rm -f "$SIGNAL_DIR/after-profile-write"
run_installer "$INTERRUPT_HOME" "$INTERRUPT_STATE"
[ -f "$INTERRUPT_STATE/active-install.json" ] || fail 'Interrupted install did not recover.'
assert_equal "$(grep -c '^# >>> codex-usage-statusline >>>$' "$INTERRUPT_HOME/.zprofile")" 1 'Interrupted-install recovery duplicated the zsh block.'
assert_equal "$(grep -c '^# >>> codex-usage-statusline >>>$' "$INTERRUPT_HOME/.bash_profile")" 1 'Interrupted-install recovery duplicated the bash block.'
assert_file_hash "$INTERRUPT_HOME/.codex/config.toml" "$interrupt_config_hash"

# SIGKILL after payload removal must restore payload and profiles before retrying removal.
env \
    HOME="$INTERRUPT_HOME" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" \
    CODEX_USAGE_STATUSLINE_TEST_MODE=1 \
    CODEX_USAGE_STATUSLINE_PAUSE_AT=after-payload-move \
    CODEX_USAGE_STATUSLINE_SIGNAL_DIR="$SIGNAL_DIR" \
    "$ROOT/uninstall.sh" --state-root "$INTERRUPT_STATE" \
    >"$TEMP_ROOT/interrupted-uninstall.log" 2>&1 &
interrupted_uninstall_pid=$!
counter=0
while [ ! -e "$SIGNAL_DIR/after-payload-move" ] && [ "$counter" -lt 30 ]; do
    sleep 1
    counter=$((counter + 1))
done
[ -e "$SIGNAL_DIR/after-payload-move" ] || fail 'Interrupted-uninstall pause point was not reached.'
kill -9 "$interrupted_uninstall_pid"
wait "$interrupted_uninstall_pid" 2>/dev/null || true
rm -f "$SIGNAL_DIR/after-payload-move"
run_uninstaller "$INTERRUPT_HOME" "$INTERRUPT_STATE"
[ ! -e "$INTERRUPT_STATE/active-install.json" ] || fail 'Interrupted-uninstall recovery left an active manifest.'
[ ! -e "$INTERRUPT_STATE/bin" ] || fail 'Interrupted-uninstall recovery left a launcher.'
[ ! -e "$INTERRUPT_STATE/versions/$PROJECT_VERSION-codex-$CODEX_VERSION" ] || fail 'Interrupted-uninstall recovery left a version bundle.'
assert_file_hash "$INTERRUPT_HOME/.zprofile" "$interrupt_z_hash"
assert_file_hash "$INTERRUPT_HOME/.bash_profile" "$interrupt_bash_hash"
assert_file_hash "$INTERRUPT_HOME/.codex/config.toml" "$interrupt_config_hash"
assert_equal "$(HOME="$INTERRUPT_HOME" ZDOTDIR="$INTERRUPT_HOME" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" /bin/zsh -lic 'command -v codex')" "$NPM_ROOT/bin/codex" 'Interrupted-uninstall recovery did not restore official Codex resolution.'

# Graceful signals in the manifest commit windows must roll back both manifest and payload state.
COMMIT_HOME=$TEMP_ROOT/'commit window home'
COMMIT_STATE=$TEMP_ROOT/'commit window state'
make_test_home "$COMMIT_HOME"
commit_config_hash=$(shasum -a 256 "$COMMIT_HOME/.codex/config.toml" | awk '{print $1}')
commit_z_hash=$(shasum -a 256 "$COMMIT_HOME/.zprofile" | awk '{print $1}')
commit_bash_hash=$(shasum -a 256 "$COMMIT_HOME/.bash_profile" | awk '{print $1}')
env \
    HOME="$COMMIT_HOME" ZDOTDIR="$COMMIT_HOME" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" \
    CODEX_USAGE_STATUSLINE_TEST_MODE=1 \
    CODEX_USAGE_STATUSLINE_PAUSE_AT=after-manifest-publish \
    CODEX_USAGE_STATUSLINE_SIGNAL_DIR="$SIGNAL_DIR" \
    "$ROOT/install.sh" --state-root "$COMMIT_STATE" --release-directory "$DIST" \
    --release-lock "$TEST_RELEASE_LOCK" --expected-customization-commit "$COMMIT" \
    >"$TEMP_ROOT/commit-install.log" 2>&1 &
commit_install_pid=$!
counter=0
while [ ! -e "$SIGNAL_DIR/after-manifest-publish" ] && [ "$counter" -lt 30 ]; do
    sleep 1
    counter=$((counter + 1))
done
[ -e "$SIGNAL_DIR/after-manifest-publish" ] || fail 'Install commit-window pause point was not reached.'
kill -TERM "$commit_install_pid"
wait "$commit_install_pid" 2>/dev/null || true
rm -f "$SIGNAL_DIR/after-manifest-publish"
[ ! -e "$COMMIT_STATE/active-install.json" ] || fail 'Install commit-window rollback left an active manifest.'
[ ! -e "$COMMIT_STATE/bin" ] || fail 'Install commit-window rollback left a launcher.'
[ ! -e "$COMMIT_STATE/versions/$PROJECT_VERSION-codex-$CODEX_VERSION" ] || fail 'Install commit-window rollback left a version bundle.'
assert_file_hash "$COMMIT_HOME/.zprofile" "$commit_z_hash"
assert_file_hash "$COMMIT_HOME/.bash_profile" "$commit_bash_hash"
assert_file_hash "$COMMIT_HOME/.codex/config.toml" "$commit_config_hash"

run_installer "$COMMIT_HOME" "$COMMIT_STATE"
env \
    HOME="$COMMIT_HOME" ZDOTDIR="$COMMIT_HOME" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" \
    CODEX_USAGE_STATUSLINE_TEST_MODE=1 \
    CODEX_USAGE_STATUSLINE_PAUSE_AT=after-manifest-retire \
    CODEX_USAGE_STATUSLINE_SIGNAL_DIR="$SIGNAL_DIR" \
    "$ROOT/uninstall.sh" --state-root "$COMMIT_STATE" \
    >"$TEMP_ROOT/commit-uninstall.log" 2>&1 &
commit_uninstall_pid=$!
counter=0
while [ ! -e "$SIGNAL_DIR/after-manifest-retire" ] && [ "$counter" -lt 30 ]; do
    sleep 1
    counter=$((counter + 1))
done
[ -e "$SIGNAL_DIR/after-manifest-retire" ] || fail 'Uninstall commit-window pause point was not reached.'
kill -TERM "$commit_uninstall_pid"
wait "$commit_uninstall_pid" 2>/dev/null || true
rm -f "$SIGNAL_DIR/after-manifest-retire"
[ -f "$COMMIT_STATE/active-install.json" ] || fail 'Uninstall commit-window rollback did not restore the active manifest.'
[ -x "$COMMIT_STATE/bin/codex" ] || fail 'Uninstall commit-window rollback did not restore the launcher.'
[ -d "$COMMIT_STATE/versions/$PROJECT_VERSION-codex-$CODEX_VERSION" ] || fail 'Uninstall commit-window rollback did not restore the version bundle.'
assert_equal "$(grep -c '^# >>> codex-usage-statusline >>>$' "$COMMIT_HOME/.zprofile")" 1 'Uninstall commit-window rollback did not restore the zsh block.'
assert_equal "$(grep -c '^# >>> codex-usage-statusline >>>$' "$COMMIT_HOME/.bash_profile")" 1 'Uninstall commit-window rollback did not restore the bash block.'
assert_file_hash "$COMMIT_HOME/.codex/config.toml" "$commit_config_hash"
run_uninstaller "$COMMIT_HOME" "$COMMIT_STATE"
assert_file_hash "$COMMIT_HOME/.zprofile" "$commit_z_hash"
assert_file_hash "$COMMIT_HOME/.bash_profile" "$commit_bash_hash"

# Modified installer-owned payload is disabled but preserved for inspection.
PRESERVE_HOME=$TEMP_ROOT/'preserve home'
PRESERVE_STATE=$TEMP_ROOT/'preserve state'
make_test_home "$PRESERVE_HOME"
preserve_config_hash=$(shasum -a 256 "$PRESERVE_HOME/.codex/config.toml" | awk '{print $1}')
run_installer "$PRESERVE_HOME" "$PRESERVE_STATE"
printf 'added after install\n' >"$PRESERVE_STATE/versions/$PROJECT_VERSION-codex-$CODEX_VERSION/added-by-user.txt"
run_uninstaller "$PRESERVE_HOME" "$PRESERVE_STATE"
[ -f "$PRESERVE_STATE/bin/codex" ] || fail 'The launcher paired with a changed bundle inventory was not preserved.'
[ -f "$PRESERVE_STATE/versions/$PROJECT_VERSION-codex-$CODEX_VERSION/added-by-user.txt" ] || fail 'An added bundle file was not preserved.'
if grep -F 'codex-usage-statusline' "$PRESERVE_HOME/.zprofile" >/dev/null; then
    fail 'Modified-payload removal left its PATH block active.'
fi
assert_file_hash "$PRESERVE_HOME/.codex/config.toml" "$preserve_config_hash"

# Successful install, launcher behavior, new-shell resolution, and idempotent reinstall.
HOME_ROOT=$TEMP_ROOT/'main home with spaces'
STATE_ROOT=$TEMP_ROOT/'main state with spaces'
make_test_home "$HOME_ROOT"
MAIN_ZDOTDIR=$HOME_ROOT/'custom zsh startup files'
mkdir -p "$MAIN_ZDOTDIR"
mv "$HOME_ROOT/.zprofile" "$MAIN_ZDOTDIR/.zprofile"
CONFIG_HASH=$(shasum -a 256 "$HOME_ROOT/.codex/config.toml" | awk '{print $1}')
ORIGINAL_BASH_HASH=$(shasum -a 256 "$HOME_ROOT/.bash_profile" | awk '{print $1}')
TEST_ZDOTDIR="$MAIN_ZDOTDIR" run_installer "$HOME_ROOT" "$STATE_ROOT" --language ko
assert_file_hash "$HOME_ROOT/.codex/config.toml" "$CONFIG_HASH"
assert_equal "$(grep -c '^# >>> codex-usage-statusline >>>$' "$MAIN_ZDOTDIR/.zprofile")" 1 'zsh profile block count is wrong'
assert_equal "$(grep -c '^# >>> codex-usage-statusline >>>$' "$HOME_ROOT/.bash_profile")" 1 'bash profile block count is wrong'

launcher_output=$("$STATE_ROOT/bin/codex" --probe 'argument with spaces')
printf '%s\n' "$launcher_output" | grep -F 'CUSTOM LANG=ko' >/dev/null || fail 'Launcher language was not propagated.'
printf '%s\n' "$launcher_output" | grep -F "CUSTOM ARG=tui.status_line=['model-with-reasoning','context-used','five-hour-limit','weekly-limit']" >/dev/null || fail 'Status-line override was not propagated.'
printf '%s\n' "$launcher_output" | grep -F 'CUSTOM ARG=argument with spaces' >/dev/null || fail 'Launcher argument quoting failed.'

zsh_command=$(HOME="$HOME_ROOT" ZDOTDIR="$MAIN_ZDOTDIR" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" /bin/zsh -lic 'command -v codex')
assert_equal "$zsh_command" "$STATE_ROOT/bin/codex" 'A new zsh did not resolve the managed launcher.'
bash_command=$(HOME="$HOME_ROOT" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" /bin/bash -lc 'command -v codex')
assert_equal "$bash_command" "$STATE_ROOT/bin/codex" 'A new bash did not resolve the managed launcher.'

TEST_ZDOTDIR=relative run_installer "$HOME_ROOT" "$STATE_ROOT" --language ko
assert_equal "$(grep -c '^# >>> codex-usage-statusline >>>$' "$MAIN_ZDOTDIR/.zprofile")" 1 'Repeated install duplicated the zsh block.'
assert_equal "$(grep -c '^# >>> codex-usage-statusline >>>$' "$HOME_ROOT/.bash_profile")" 1 'Repeated install duplicated the bash block.'

# A modified managed block must fail closed before any payload or profile mutation.
cp -p "$MAIN_ZDOTDIR/.zprofile" "$TEMP_ROOT/zprofile-before-managed-edit"
sed 's/# Managed by codex-usage-statusline\./# User changed this managed line./' \
    "$TEMP_ROOT/zprofile-before-managed-edit" >"$MAIN_ZDOTDIR/.zprofile"
managed_edit_hash=$(shasum -a 256 "$MAIN_ZDOTDIR/.zprofile" | awk '{print $1}')
expect_failure run_uninstaller "$HOME_ROOT" "$STATE_ROOT"
[ -f "$STATE_ROOT/active-install.json" ] || fail 'Modified-block rejection lost the active manifest.'
[ -x "$STATE_ROOT/bin/codex" ] || fail 'Modified-block rejection lost the launcher.'
assert_file_hash "$MAIN_ZDOTDIR/.zprofile" "$managed_edit_hash"
cp -p "$TEMP_ROOT/zprofile-before-managed-edit" "$MAIN_ZDOTDIR/.zprofile"

# Preserve user edits immediately before and after the block, and prove rollback restores them.
python3 - "$MAIN_ZDOTDIR/.zprofile" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
marker = b"# >>> codex-usage-statusline >>>"
data = path.read_bytes()
if data.count(marker) != 1:
    raise SystemExit("expected one managed marker")
path.write_bytes(data.replace(marker, b"export BEFORE_BLOCK=1\n" + marker, 1))
PY
printf 'export AFTER_INSTALL=1\n' >>"$MAIN_ZDOTDIR/.zprofile"
MODIFIED_Z_HASH=$(shasum -a 256 "$MAIN_ZDOTDIR/.zprofile" | awk '{print $1}')
expect_failure env \
    HOME="$HOME_ROOT" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" \
    CODEX_USAGE_STATUSLINE_TEST_MODE=1 \
    CODEX_USAGE_STATUSLINE_FAILPOINT=after-payload-move \
    "$ROOT/uninstall.sh" --state-root "$STATE_ROOT"
[ -f "$STATE_ROOT/active-install.json" ] || fail 'Uninstall rollback lost the active manifest.'
[ -x "$STATE_ROOT/bin/codex" ] || fail 'Uninstall rollback lost the launcher.'
assert_file_hash "$MAIN_ZDOTDIR/.zprofile" "$MODIFIED_Z_HASH"

TEST_ZDOTDIR=relative run_uninstaller "$HOME_ROOT" "$STATE_ROOT"
assert_file_hash "$HOME_ROOT/.codex/config.toml" "$CONFIG_HASH"
assert_file_hash "$HOME_ROOT/.bash_profile" "$ORIGINAL_BASH_HASH"
grep -F 'export USER_Z=1' "$MAIN_ZDOTDIR/.zprofile" >/dev/null || fail 'Uninstall removed pre-existing zsh content.'
grep -F 'export BEFORE_BLOCK=1' "$MAIN_ZDOTDIR/.zprofile" >/dev/null || fail 'Uninstall changed an edit immediately before the managed block.'
grep -F 'export AFTER_INSTALL=1' "$MAIN_ZDOTDIR/.zprofile" >/dev/null || fail 'Uninstall removed a post-install user edit.'
printf 'export USER_Z=1\nexport BEFORE_BLOCK=1\nexport AFTER_INSTALL=1\n' >"$TEMP_ROOT/expected-zprofile"
cmp "$MAIN_ZDOTDIR/.zprofile" "$TEMP_ROOT/expected-zprofile" || fail 'Uninstall did not preserve exact user zsh profile bytes.'
if grep -F 'codex-usage-statusline' "$MAIN_ZDOTDIR/.zprofile" >/dev/null; then
    fail 'Uninstall left the managed zsh block.'
fi
assert_equal "$(HOME="$HOME_ROOT" ZDOTDIR="$MAIN_ZDOTDIR" PATH="$NPM_ROOT/bin:$SYSTEM_PATH" /bin/zsh -lic 'command -v codex')" "$NPM_ROOT/bin/codex" 'Official Codex was not restored in zsh.'

printf 'macOS installer tests passed\n'
