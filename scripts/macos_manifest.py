#!/usr/bin/env python3
"""Create and validate the macOS installer recovery manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import tempfile
from pathlib import Path, PurePosixPath


HASH_RE = re.compile(r"[0-9a-f]{64}")
LANGUAGES = {"ko", "en", "ja"}
KINDS = {"npm", "homebrew", "standalone"}
TARGET = "aarch64-apple-darwin"
PROFILE_SHELLS = ("zsh", "bash")


def valid_config_fingerprint(value: object) -> bool:
    return value == "absent" or bool(
        isinstance(value, str) and re.fullmatch(r"present:[0-9a-f]{64}", value)
    )


def load(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SystemExit(f"Invalid installation manifest {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit("The installation manifest must be a JSON object")
    return value


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def relative_inventory_path(root: Path, path: Path) -> str:
    value = path.relative_to(root).as_posix()
    if (
        not value
        or value == "."
        or any(character in value for character in "\r\n\0")
        or PurePosixPath(value).is_absolute()
        or ".." in PurePosixPath(value).parts
    ):
        raise SystemExit(f"Unsafe inventory path: {value!r}")
    return value


def create_inventory(root: Path) -> dict:
    try:
        root_info = root.lstat()
    except OSError as exc:
        raise SystemExit(f"Could not inventory {root}: {exc}") from exc
    if stat.S_ISLNK(root_info.st_mode) or not stat.S_ISDIR(root_info.st_mode):
        raise SystemExit(f"Inventory root must be a real directory: {root}")
    root = root.resolve(strict=False)
    directories: list[str] = []
    files: list[dict] = []
    for current_raw, directory_names, file_names in os.walk(root, followlinks=False):
        current = Path(current_raw)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            path = current / name
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                raise SystemExit(f"Bundle inventory rejects linked or special directories: {path}")
            directories.append(relative_inventory_path(root, path))
        for name in file_names:
            path = current / name
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                raise SystemExit(f"Bundle inventory rejects linked or special files: {path}")
            files.append(
                {
                    "path": relative_inventory_path(root, path),
                    "sha256": file_sha256(path),
                    "mode": stat.S_IMODE(info.st_mode),
                }
            )
    return {
        "directories": sorted(directories),
        "files": sorted(files, key=lambda record: record["path"]),
    }


def validate_inventory(value: object, label: str) -> None:
    if not isinstance(value, dict) or set(value) != {"directories", "files"}:
        raise SystemExit(f"Installation manifest contains an invalid {label} inventory")
    directories = value.get("directories")
    files = value.get("files")
    if not isinstance(directories, list) or not isinstance(files, list):
        raise SystemExit(f"Installation manifest contains an incomplete {label} inventory")

    def valid_relative_path(path: object) -> bool:
        return bool(
            isinstance(path, str)
            and path
            and not PurePosixPath(path).is_absolute()
            and ".." not in PurePosixPath(path).parts
            and not any(character in path for character in "\r\n\0")
        )

    if (
        directories != sorted(directories)
        or len(directories) != len(set(directories))
        or not all(valid_relative_path(path) for path in directories)
    ):
        raise SystemExit(f"Installation manifest contains unsafe {label} directories")
    file_paths = []
    for record in files:
        if not isinstance(record, dict) or set(record) != {"path", "sha256", "mode"}:
            raise SystemExit(f"Installation manifest contains an invalid {label} file")
        if not valid_relative_path(record.get("path")):
            raise SystemExit(f"Installation manifest contains an unsafe {label} file path")
        if not HASH_RE.fullmatch(str(record.get("sha256", ""))):
            raise SystemExit(f"Installation manifest contains an invalid {label} file hash")
        if not isinstance(record.get("mode"), int) or not 0 <= record["mode"] <= 0o7777:
            raise SystemExit(f"Installation manifest contains an invalid {label} file mode")
        file_paths.append(record["path"])
    if file_paths != sorted(file_paths) or len(file_paths) != len(set(file_paths)):
        raise SystemExit(f"Installation manifest contains duplicate or unsorted {label} files")


def parse_profile_record(path: Path) -> dict:
    record = load(path)
    required = {
        "path": str,
        "existed": bool,
        "previousSha256": str,
        "installedSha256": str,
        "blockSha256": str,
        "separator": str,
        "changed": bool,
    }
    for key, expected_type in required.items():
        if not isinstance(record.get(key), expected_type):
            raise SystemExit(f"Invalid profile record field {key} in {path}")
    for key in ("previousSha256", "installedSha256", "blockSha256"):
        if not HASH_RE.fullmatch(record[key]):
            raise SystemExit(f"Invalid profile record checksum {key} in {path}")
    if record["separator"] not in {"none", "newline", "existing"}:
        raise SystemExit(f"Invalid profile separator in {path}")
    return record


def create(args: argparse.Namespace) -> None:
    official = load(args.official_info)
    if official.get("installationKind") not in KINDS:
        raise SystemExit("Unsupported official Codex installation kind")
    if official.get("target") != TARGET or official.get("version") != args.codex_version:
        raise SystemExit("Official Codex detection does not match the requested release")
    profiles = [parse_profile_record(path) for path in args.profile_record]
    if len(profiles) != 2:
        raise SystemExit("The macOS installation manifest requires zsh and bash profile records")
    for shell, profile in zip(PROFILE_SHELLS, profiles):
        profile["shell"] = shell
    manifest = {
        "schemaVersion": 2,
        "installMode": "side-by-side-profile-launcher",
        "installedAt": args.installed_at,
        "projectVersion": args.project_version,
        "releaseTag": args.release_tag,
        "codexVersion": args.codex_version,
        "customizationCommit": args.customization_commit,
        "language": args.language,
        "targetTriple": TARGET,
        "assetName": args.asset_name,
        "archiveSha256": args.archive_sha256,
        "officialInstallationKind": official["installationKind"],
        "officialCommandPath": official["commandPath"],
        "officialBinaryPath": official["binaryPath"],
        "officialBundleRoot": official["bundleRoot"],
        "officialBinaryRelativePath": official["binaryRelativePath"],
        "customBundlePath": str(args.custom_bundle),
        "customBinaryPath": str(args.custom_binary),
        "customBinarySha256": args.custom_binary_sha256,
        "launcherDirectory": str(args.launcher_directory),
        "launcherPath": str(args.launcher_path),
        "launcherSha256": args.launcher_sha256,
        "statusLineOverride": args.status_line_override,
        "configTomlBefore": args.config_toml_before,
        "profiles": profiles,
        "bundleInventory": create_inventory(args.custom_bundle),
        "launcherInventory": create_inventory(args.launcher_directory),
    }
    for key in ("archiveSha256", "customBinarySha256", "launcherSha256"):
        if not HASH_RE.fullmatch(str(manifest[key])):
            raise SystemExit(f"Invalid manifest checksum: {key}")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest["customizationCommit"]):
        raise SystemExit("Invalid customization commit")
    if manifest["language"] not in LANGUAGES:
        raise SystemExit("Invalid display language")
    if not valid_config_fingerprint(manifest["configTomlBefore"]):
        raise SystemExit("Invalid config.toml fingerprint")
    atomic_json(args.output, manifest)


def exact_path(actual: object, expected: Path, label: str) -> None:
    if not isinstance(actual, str):
        raise SystemExit(f"The installation manifest is missing {label}")
    try:
        actual_path = Path(actual).expanduser().resolve(strict=False)
        expected_path = expected.expanduser().resolve(strict=False)
    except OSError as exc:
        raise SystemExit(f"Could not validate {label}: {exc}") from exc
    if actual_path != expected_path:
        raise SystemExit(f"The installation manifest contains an unexpected {label}: {actual}")


def normalized_profile_path(value: object, shell: str, home: Path) -> Path:
    if not isinstance(value, str) or any(character in value for character in "\r\n\0"):
        raise SystemExit(f"Installation manifest contains an invalid {shell} profile path")
    path = Path(value)
    if not path.is_absolute():
        raise SystemExit(f"Installation manifest contains a relative {shell} profile path")
    path = path.resolve(strict=False)
    if str(path) != value:
        raise SystemExit(f"Installation manifest contains a non-canonical {shell} profile path")
    if shell == "zsh":
        if path.name != ".zprofile":
            raise SystemExit("Installation manifest contains an unexpected zsh profile path")
    elif shell == "bash":
        if path != home.resolve(strict=False) / ".bash_profile":
            raise SystemExit("Installation manifest contains an unexpected bash profile path")
    else:
        raise SystemExit(f"Installation manifest contains an unsupported profile shell: {shell}")
    return path


def validated_profiles(manifest: dict, home: Path) -> dict[str, dict]:
    records = manifest.get("profiles")
    if not isinstance(records, list) or len(records) != len(PROFILE_SHELLS):
        raise SystemExit("Installation manifest profile records are incomplete")
    by_shell: dict[str, dict] = {}
    for record in records:
        if not isinstance(record, dict) or record.get("shell") not in PROFILE_SHELLS:
            raise SystemExit("Installation manifest contains an invalid profile record")
        shell = record["shell"]
        if shell in by_shell:
            raise SystemExit("Installation manifest contains duplicate profile shells")
        normalized_profile_path(record.get("path"), shell, home)
        for key in ("previousSha256", "installedSha256", "blockSha256"):
            if not HASH_RE.fullmatch(str(record.get(key, ""))):
                raise SystemExit(f"Installation manifest contains an invalid profile {key}")
        if record.get("separator") not in {"none", "newline", "existing"}:
            raise SystemExit("Installation manifest contains an invalid profile separator")
        if not isinstance(record.get("existed"), bool) or not isinstance(record.get("changed"), bool):
            raise SystemExit("Installation manifest contains an invalid profile state flag")
        by_shell[shell] = record
    if set(by_shell) != set(PROFILE_SHELLS):
        raise SystemExit("Installation manifest must contain zsh and bash profiles")
    return by_shell


def validate_manifest(
    manifest: dict,
    state_root: Path,
    project_version: str,
    codex_version: str,
    home: Path,
) -> None:
    expected_values = {
        "schemaVersion": 2,
        "installMode": "side-by-side-profile-launcher",
        "projectVersion": project_version,
        "releaseTag": f"v{project_version}",
        "codexVersion": codex_version,
        "targetTriple": TARGET,
    }
    for key, expected in expected_values.items():
        if manifest.get(key) != expected:
            raise SystemExit(f"Installation manifest mismatch for {key}")
    if manifest.get("language") not in LANGUAGES:
        raise SystemExit("Installation manifest contains an unsupported language")
    if manifest.get("officialInstallationKind") not in KINDS:
        raise SystemExit("Installation manifest contains an unsupported official installation kind")
    if not re.fullmatch(r"[0-9a-f]{40}", str(manifest.get("customizationCommit", ""))):
        raise SystemExit("Installation manifest contains an invalid customization commit")
    if not valid_config_fingerprint(manifest.get("configTomlBefore")):
        raise SystemExit("Installation manifest contains an invalid config.toml fingerprint")
    for key in ("archiveSha256", "customBinarySha256", "launcherSha256"):
        if not HASH_RE.fullmatch(str(manifest.get(key, ""))):
            raise SystemExit(f"Installation manifest contains an invalid {key}")

    version_root = state_root / "versions" / f"{project_version}-codex-{codex_version}"
    launcher_directory = state_root / "bin"
    exact_path(manifest.get("customBundlePath"), version_root, "custom bundle path")
    exact_path(manifest.get("launcherDirectory"), launcher_directory, "launcher directory")
    exact_path(manifest.get("launcherPath"), launcher_directory / "codex", "launcher path")
    custom_binary = Path(str(manifest.get("customBinaryPath", ""))).resolve(strict=False)
    try:
        custom_binary.relative_to(version_root.resolve(strict=False))
    except ValueError as exc:
        raise SystemExit("The custom binary path escapes its installer-owned bundle") from exc

    validated_profiles(manifest, home)
    validate_inventory(manifest.get("bundleInventory"), "bundle")
    validate_inventory(manifest.get("launcherInventory"), "launcher")


def validate(args: argparse.Namespace) -> None:
    manifest = load(args.manifest)
    validate_manifest(
        manifest,
        args.state_root,
        args.project_version,
        args.codex_version,
        args.home,
    )
    print("manifest OK")


TOP_FIELDS = {
    "language",
    "customizationCommit",
    "assetName",
    "archiveSha256",
    "customBundlePath",
    "customBinaryPath",
    "customBinarySha256",
    "launcherDirectory",
    "launcherPath",
    "launcherSha256",
    "configTomlBefore",
    "officialInstallationKind",
}
PROFILE_FIELDS = {
    "existed",
    "previousSha256",
    "installedSha256",
    "blockSha256",
    "separator",
}


def get_field(args: argparse.Namespace) -> None:
    if args.field not in TOP_FIELDS:
        raise SystemExit("Unsupported manifest field")
    value = load(args.manifest).get(args.field)
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, str):
        print(value)
    else:
        raise SystemExit(f"Manifest field {args.field} is missing or invalid")


def get_profile(args: argparse.Namespace) -> None:
    if args.field not in PROFILE_FIELDS:
        raise SystemExit("Unsupported profile field")
    profiles = load(args.manifest).get("profiles")
    matches = [record for record in profiles or [] if record.get("path") == str(args.path)]
    if len(matches) != 1:
        raise SystemExit(f"Expected one profile record for {args.path}")
    value = matches[0].get(args.field)
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, str):
        print(value)
    else:
        raise SystemExit(f"Profile field {args.field} is missing or invalid")


def get_profile_path(args: argparse.Namespace) -> None:
    manifest = load(args.manifest)
    profiles = validated_profiles(manifest, args.home)
    print(normalized_profile_path(profiles[args.shell]["path"], args.shell, args.home))


def verify_inventory(args: argparse.Namespace) -> None:
    manifest = load(args.manifest)
    if args.kind == "bundle":
        root = manifest.get("customBundlePath")
        expected = manifest.get("bundleInventory")
    else:
        root = manifest.get("launcherDirectory")
        expected = manifest.get("launcherInventory")
    if not isinstance(root, str):
        raise SystemExit(f"Installation manifest is missing the {args.kind} inventory root")
    validate_inventory(expected, args.kind)
    actual = create_inventory(Path(root))
    if actual != expected:
        raise SystemExit(f"The installed {args.kind} inventory was modified")
    print(f"{args.kind} inventory OK")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)

    create_parser = commands.add_parser("create")
    create_parser.add_argument("--output", type=Path, required=True)
    create_parser.add_argument("--project-version", required=True)
    create_parser.add_argument("--release-tag", required=True)
    create_parser.add_argument("--codex-version", required=True)
    create_parser.add_argument("--customization-commit", required=True)
    create_parser.add_argument("--installed-at", required=True)
    create_parser.add_argument("--language", required=True)
    create_parser.add_argument("--asset-name", required=True)
    create_parser.add_argument("--archive-sha256", required=True)
    create_parser.add_argument("--official-info", type=Path, required=True)
    create_parser.add_argument("--custom-bundle", type=Path, required=True)
    create_parser.add_argument("--custom-binary", type=Path, required=True)
    create_parser.add_argument("--custom-binary-sha256", required=True)
    create_parser.add_argument("--launcher-directory", type=Path, required=True)
    create_parser.add_argument("--launcher-path", type=Path, required=True)
    create_parser.add_argument("--launcher-sha256", required=True)
    create_parser.add_argument("--status-line-override", required=True)
    create_parser.add_argument("--config-toml-before", required=True)
    create_parser.add_argument("--profile-record", type=Path, action="append", required=True)
    create_parser.set_defaults(handler=create)

    validate_parser = commands.add_parser("validate")
    validate_parser.add_argument("--manifest", type=Path, required=True)
    validate_parser.add_argument("--state-root", type=Path, required=True)
    validate_parser.add_argument("--project-version", required=True)
    validate_parser.add_argument("--codex-version", required=True)
    validate_parser.add_argument("--home", type=Path, required=True)
    validate_parser.set_defaults(handler=validate)

    get_parser = commands.add_parser("get")
    get_parser.add_argument("--manifest", type=Path, required=True)
    get_parser.add_argument("--field", required=True)
    get_parser.set_defaults(handler=get_field)

    profile_parser = commands.add_parser("profile")
    profile_parser.add_argument("--manifest", type=Path, required=True)
    profile_parser.add_argument("--path", type=Path, required=True)
    profile_parser.add_argument("--field", required=True)
    profile_parser.set_defaults(handler=get_profile)

    profile_path_parser = commands.add_parser("profile-path")
    profile_path_parser.add_argument("--manifest", type=Path, required=True)
    profile_path_parser.add_argument("--home", type=Path, required=True)
    profile_path_parser.add_argument("--shell", choices=PROFILE_SHELLS, required=True)
    profile_path_parser.set_defaults(handler=get_profile_path)

    inventory_parser = commands.add_parser("verify-inventory")
    inventory_parser.add_argument("--manifest", type=Path, required=True)
    inventory_parser.add_argument("--kind", choices=("bundle", "launcher"), required=True)
    inventory_parser.set_defaults(handler=verify_inventory)
    return result


def main() -> None:
    args = parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
