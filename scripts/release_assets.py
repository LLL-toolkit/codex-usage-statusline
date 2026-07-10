#!/usr/bin/env python3
"""Build and verify immutable release assets from release-lock.json."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path
from typing import BinaryIO


MAX_BINARY_SIZE = 600 * 1024 * 1024
MAX_TEXT_SIZE = 2 * 1024 * 1024
MAX_METADATA_SIZE = 64 * 1024
MAX_SIGNATURE_SIZE = 16 * 1024
HASH_RE = re.compile(r"[0-9a-f]{64}")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SystemExit(f"Invalid JSON file {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit(f"Expected a JSON object in {path}")
    return value


def load_lock(path: Path) -> dict:
    lock = load_json(path)
    if lock.get("schemaVersion") != 1:
        raise SystemExit("Unsupported release lock schema")
    return lock


def release_public_key(lock_path: Path, lock: dict) -> Path:
    signing = lock.get("releaseSigning")
    if not isinstance(signing, dict) or signing.get("algorithm") != "rsa-pkcs1v15-sha256":
        raise SystemExit("Unsupported or missing release-signing configuration")
    relative = signing.get("publicKeyPath")
    expected_hash = signing.get("publicKeySha256")
    signature_size = signing.get("signatureSize")
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise SystemExit("Invalid release-signing public-key path")
    if not HASH_RE.fullmatch(str(expected_hash)):
        raise SystemExit("Invalid release-signing public-key checksum")
    if not isinstance(signature_size, int) or not 256 <= signature_size <= 1024:
        raise SystemExit("Invalid release-signing signature size")
    root = lock_path.resolve().parent
    candidate = root / relative
    if candidate.is_symlink():
        raise SystemExit(f"Release-signing public key is unsafe: {candidate}")
    key = candidate.resolve(strict=False)
    try:
        key.relative_to(root)
    except ValueError as exc:
        raise SystemExit("The release-signing public key escapes the repository") from exc
    if not key.is_file():
        raise SystemExit(f"Release-signing public key is missing or unsafe: {key}")
    if sha256_file(key) != expected_hash:
        raise SystemExit("Release-signing public-key checksum mismatch")
    return key


def openssl_command() -> str:
    command = "/usr/bin/openssl" if Path("/usr/bin/openssl").is_file() else shutil.which("openssl")
    if not command:
        raise SystemExit("OpenSSL is required to verify release signatures")
    return command


def sign_sha256sums(checksums: Path, signature: Path, private_key: Path) -> None:
    if not private_key.is_file() or private_key.is_symlink():
        raise SystemExit("The release-signing private key is missing or unsafe")
    result = subprocess.run(
        [
            openssl_command(),
            "dgst",
            "-sha256",
            "-sign",
            str(private_key),
            "-out",
            str(signature),
            str(checksums),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"Could not sign SHA256SUMS: {result.stderr.strip()}")
    signature.chmod(0o644)


def verify_sha256sums_signature(lock_path: Path, lock: dict, release_dir: Path) -> None:
    checksums = release_dir / "SHA256SUMS"
    signature = release_dir / "SHA256SUMS.sig"
    if not signature.is_file() or signature.is_symlink():
        raise SystemExit("The SHA256SUMS signature is missing or unsafe")
    size = signature.stat().st_size
    expected_size = lock["releaseSigning"].get("signatureSize")
    if size != expected_size or size > MAX_SIGNATURE_SIZE:
        raise SystemExit("The SHA256SUMS signature has an unsafe size")
    public_key = release_public_key(lock_path, lock)
    result = subprocess.run(
        [
            openssl_command(),
            "dgst",
            "-sha256",
            "-verify",
            str(public_key),
            "-signature",
            str(signature),
            str(checksums),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit("SHA256SUMS release-signature verification failed")


def verify_macos_binary(binary: Path) -> None:
    if sys.platform != "darwin":
        raise SystemExit("macOS release binaries must be packaged on macOS")
    architecture = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(binary)],
        capture_output=True,
        text=True,
        check=False,
    )
    if architecture.returncode != 0 or architecture.stdout.strip() != "arm64":
        raise SystemExit("The macOS release binary must be arm64-only")
    verification = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(binary)],
        capture_output=True,
        text=True,
        check=False,
    )
    if verification.returncode != 0:
        raise SystemExit(f"macOS codesign verification failed: {verification.stderr.strip()}")
    details = subprocess.run(
        ["/usr/bin/codesign", "-dvv", str(binary)],
        capture_output=True,
        text=True,
        check=False,
    )
    description = details.stdout + details.stderr
    if details.returncode != 0 or "Signature=adhoc" not in description:
        raise SystemExit("The macOS release binary is not ad-hoc signed")


def target_for(lock: dict, triple: str) -> dict:
    matches = [target for target in lock.get("targets", []) if target.get("triple") == triple]
    if len(matches) != 1:
        raise SystemExit(f"Expected one release target for {triple}, found {len(matches)}")
    return matches[0]


def archive_suffix(target: dict) -> str:
    kind = target.get("archive")
    if kind == "zip":
        return ".zip"
    if kind == "tar.gz":
        return ".tar.gz"
    raise SystemExit(f"Unsupported archive format: {kind!r}")


def asset_base(lock: dict, target: dict) -> str:
    return (
        f"codex-usage-statusline-{lock['projectVersion']}-"
        f"codex-{lock['codexVersion']}-{target['triple']}"
    )


def expected_metadata(lock: dict, target: dict) -> dict:
    return {
        "projectVersion": lock["projectVersion"],
        "codexVersion": lock["codexVersion"],
        "upstreamTag": lock["upstreamTag"],
        "upstreamCommit": lock["upstreamCommit"],
        "upstreamTree": lock["upstreamTree"],
        "rustToolchain": lock["rustToolchain"],
        "patchSha256": lock["patch"]["sha256"],
        "target": target["triple"],
        "archiveFormat": target["archive"],
        "binaryName": target["executable"],
    }


def validate_metadata(metadata: dict, lock: dict, target: dict) -> None:
    if metadata.get("schemaVersion") != 1:
        raise SystemExit(f"Invalid metadata schema for {target['triple']}")
    for key, expected in expected_metadata(lock, target).items():
        if metadata.get(key) != expected:
            raise SystemExit(
                f"Metadata mismatch for {target['triple']} {key}: "
                f"expected {expected!r}, got {metadata.get(key)!r}"
            )
    if not HASH_RE.fullmatch(str(metadata.get("binarySha256", ""))):
        raise SystemExit(f"Invalid binary SHA-256 for {target['triple']}")
    if not COMMIT_RE.fullmatch(str(metadata.get("customizationCommit", ""))):
        raise SystemExit(f"Invalid customization commit for {target['triple']}")
    if not isinstance(metadata.get("debugSymbolsStripped"), bool):
        raise SystemExit(f"Missing debug-symbol status for {target['triple']}")

    signing = metadata.get("signing")
    if not isinstance(signing, dict):
        raise SystemExit(f"Missing signing metadata for {target['triple']}")
    if target["os"] == "macos":
        expected_signing = {
            "kind": "adhoc",
            "codesignVerified": True,
            "developerId": False,
            "notarized": False,
        }
        if signing != expected_signing:
            raise SystemExit(f"Unexpected macOS signing metadata: {signing!r}")
        if metadata["debugSymbolsStripped"] is not True:
            raise SystemExit("The macOS release binary must have debug symbols stripped")
    elif signing.get("kind") != "none":
        raise SystemExit(f"Unexpected signing kind for {target['triple']}: {signing!r}")


def add_zip_member(archive: zipfile.ZipFile, name: str, data: bytes, executable: bool) -> None:
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    mode = 0o755 if executable else 0o644
    info.external_attr = (stat.S_IFREG | mode) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    archive.writestr(info, data)


def build_zip(path: Path, files: list[tuple[str, bytes, bool]]) -> None:
    with zipfile.ZipFile(path, "w", allowZip64=True) as archive:
        for name, data, executable in files:
            add_zip_member(archive, name, data, executable)


def build_tar_gz(path: Path, files: list[tuple[str, bytes, bool]]) -> None:
    with path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for name, data, executable in files:
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    info.mode = 0o755 if executable else 0o644
                    info.mtime = 0
                    info.uid = 0
                    info.gid = 0
                    info.uname = ""
                    info.gname = ""
                    archive.addfile(info, io.BytesIO(data))


def package(args: argparse.Namespace) -> None:
    lock_path = args.lock.resolve()
    lock = load_lock(lock_path)
    target = target_for(lock, args.target)
    binary_path = args.binary.resolve()
    if not binary_path.is_file():
        raise SystemExit(f"Release binary does not exist: {binary_path}")
    binary_size = binary_path.stat().st_size
    if binary_size <= 0 or binary_size > MAX_BINARY_SIZE:
        raise SystemExit(f"Release binary size is unsafe: {binary_size}")

    root = lock_path.parent
    license_bytes = (root / "LICENSE").read_bytes()
    notice_bytes = (root / "NOTICE.md").read_bytes()
    binary_bytes = binary_path.read_bytes()
    if len(license_bytes) > MAX_TEXT_SIZE or len(notice_bytes) > MAX_TEXT_SIZE:
        raise SystemExit("Release notice file exceeds its safety limit")

    if target["os"] == "macos":
        if args.allow_test_macos_binary:
            if os.environ.get("CODEX_USAGE_STATUSLINE_TEST_MODE") != "1":
                raise SystemExit("--allow-test-macos-binary is reserved for automated tests")
        else:
            verify_macos_binary(binary_path)
        signing = {
            "kind": "adhoc",
            "codesignVerified": True,
            "developerId": False,
            "notarized": False,
        }
    else:
        signing = {
            "kind": "none",
            "codesignVerified": False,
            "developerId": False,
            "notarized": False,
        }

    metadata = {
        "schemaVersion": 1,
        **expected_metadata(lock, target),
        "customizationCommit": args.customization_commit,
        "binarySha256": sha256_bytes(binary_bytes),
        "debugSymbolsStripped": args.debug_symbols_stripped,
        "signing": signing,
    }
    validate_metadata(metadata, lock, target)
    metadata_bytes = json_bytes(metadata)
    if len(metadata_bytes) > MAX_METADATA_SIZE:
        raise SystemExit("BUILD-METADATA.json exceeds its safety limit")

    files = [
        (target["executable"], binary_bytes, True),
        ("LICENSE", license_bytes, False),
        ("NOTICE.md", notice_bytes, False),
        ("BUILD-METADATA.json", metadata_bytes, False),
    ]
    args.dist.mkdir(parents=True, exist_ok=True)
    base = asset_base(lock, target)
    archive_path = args.dist / f"{base}{archive_suffix(target)}"
    if target["archive"] == "zip":
        build_zip(archive_path, files)
    else:
        build_tar_gz(archive_path, files)

    archive_hash = sha256_file(archive_path)
    (args.dist / f"{archive_path.name}.sha256").write_text(
        f"{archive_hash}  {archive_path.name}\n", encoding="ascii"
    )
    (args.dist / f"{base}.metadata.json").write_bytes(metadata_bytes)
    print(f"packaged {archive_path.name}: {archive_hash}")


def parse_sidecar(path: Path, expected_name: str) -> str:
    try:
        text = path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise SystemExit(f"Invalid checksum sidecar {path}: {exc}") from exc
    match = re.fullmatch(r"([0-9a-f]{64})  ([^\s]+)", text)
    if not match or match.group(2) != expected_name:
        raise SystemExit(f"Malformed checksum sidecar: {path}")
    return match.group(1)


def expected_release_names(lock: dict) -> set[str]:
    names = {"release-manifest.json", "SHA256SUMS", "SHA256SUMS.sig"}
    for target in lock["targets"]:
        base = asset_base(lock, target)
        archive = f"{base}{archive_suffix(target)}"
        names.update({archive, f"{archive}.sha256", f"{base}.metadata.json"})
    return names


def validate_candidate(dist: Path, lock: dict, target: dict) -> tuple[dict, Path, str]:
    base = asset_base(lock, target)
    archive = dist / f"{base}{archive_suffix(target)}"
    sidecar = dist / f"{archive.name}.sha256"
    metadata_path = dist / f"{base}.metadata.json"
    for path in (archive, sidecar, metadata_path):
        if not path.is_file():
            raise SystemExit(f"Missing release candidate file: {path}")
    expected_hash = parse_sidecar(sidecar, archive.name)
    actual_hash = sha256_file(archive)
    if actual_hash != expected_hash:
        raise SystemExit(f"Archive checksum mismatch for {archive.name}")
    metadata = load_json(metadata_path)
    validate_metadata(metadata, lock, target)
    return metadata, archive, actual_hash


def assemble(args: argparse.Namespace) -> None:
    lock_path = args.lock.resolve()
    lock = load_lock(lock_path)
    release_public_key(lock_path, lock)
    if not COMMIT_RE.fullmatch(args.customization_commit):
        raise SystemExit("Invalid expected customization commit")
    dist = args.dist.resolve()
    assets = []
    expected_candidates: set[str] = set()
    for target in lock["targets"]:
        metadata, archive, archive_hash = validate_candidate(dist, lock, target)
        if metadata["customizationCommit"] != args.customization_commit:
            raise SystemExit(
                f"Customization commit mismatch for {target['triple']}: "
                f"expected {args.customization_commit}, got {metadata['customizationCommit']}"
            )
        entry = dict(metadata)
        entry["asset"] = archive.name
        entry["archiveSha256"] = archive_hash
        assets.append(entry)
        base = asset_base(lock, target)
        expected_candidates.update(
            {archive.name, f"{archive.name}.sha256", f"{base}.metadata.json"}
        )

    actual_candidates = {path.name for path in dist.iterdir() if path.is_file()}
    unexpected = actual_candidates - expected_candidates
    missing = expected_candidates - actual_candidates
    if unexpected or missing:
        raise SystemExit(
            f"Release candidate set mismatch; missing={sorted(missing)}, "
            f"unexpected={sorted(unexpected)}"
        )

    manifest = {
        "schemaVersion": 1,
        "projectVersion": lock["projectVersion"],
        "codexVersion": lock["codexVersion"],
        "upstreamTag": lock["upstreamTag"],
        "upstreamCommit": lock["upstreamCommit"],
        "patchSha256": lock["patch"]["sha256"],
        "customizationCommit": args.customization_commit,
        "assets": assets,
    }
    (dist / "release-manifest.json").write_bytes(json_bytes(manifest))
    checksum_paths = sorted(path for path in dist.iterdir() if path.is_file())
    checksums = dist / "SHA256SUMS"
    with checksums.open("w", encoding="ascii", newline="\n") as output:
        for path in checksum_paths:
            output.write(f"{sha256_file(path)}  {path.name}\n")
    signature = dist / "SHA256SUMS.sig"
    sign_sha256sums(checksums, signature, args.signing_key)
    verify_sha256sums_signature(lock_path, lock, dist)
    print(f"assembled {len(assets)} release targets")


def read_archive_files(path: Path, target: dict) -> dict[str, bytes]:
    expected_names = {
        target["executable"],
        "LICENSE",
        "NOTICE.md",
        "BUILD-METADATA.json",
    }
    limits = {
        target["executable"]: MAX_BINARY_SIZE,
        "LICENSE": MAX_TEXT_SIZE,
        "NOTICE.md": MAX_TEXT_SIZE,
        "BUILD-METADATA.json": MAX_METADATA_SIZE,
    }
    result: dict[str, bytes] = {}

    def accept(name: str, size: int, stream: BinaryIO) -> None:
        if name not in expected_names or "/" in name or "\\" in name:
            raise SystemExit(f"Unsafe or unexpected archive member: {name!r}")
        if name in result:
            raise SystemExit(f"Duplicate archive member: {name}")
        if size < 0 or size > limits[name]:
            raise SystemExit(f"Archive member exceeds its safety limit: {name}")
        data = stream.read(limits[name] + 1)
        if len(data) != size or len(data) > limits[name]:
            raise SystemExit(f"Archive member size mismatch: {name}")
        result[name] = data

    if target["archive"] == "zip":
        try:
            with zipfile.ZipFile(path) as archive:
                for info in archive.infolist():
                    mode = (info.external_attr >> 16) & 0o170000
                    if info.is_dir() or mode not in (0, stat.S_IFREG):
                        raise SystemExit(f"Archive member is not a regular file: {info.filename}")
                    with archive.open(info, "r") as stream:
                        accept(info.filename, info.file_size, stream)
        except (OSError, zipfile.BadZipFile) as exc:
            raise SystemExit(f"Invalid ZIP archive {path}: {exc}") from exc
    else:
        try:
            with tarfile.open(path, "r:gz") as archive:
                for member in archive.getmembers():
                    if not member.isfile():
                        raise SystemExit(f"Archive member is not a regular file: {member.name}")
                    stream = archive.extractfile(member)
                    if stream is None:
                        raise SystemExit(f"Could not read archive member: {member.name}")
                    with stream:
                        accept(member.name, member.size, stream)
        except (OSError, tarfile.TarError) as exc:
            raise SystemExit(f"Invalid tar archive {path}: {exc}") from exc

    if set(result) != expected_names:
        raise SystemExit(
            f"Archive member set mismatch for {path.name}: "
            f"expected {sorted(expected_names)}, got {sorted(result)}"
        )
    return result


def parse_sha256sums(path: Path) -> dict[str, str]:
    records: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise SystemExit(f"Invalid SHA256SUMS: {exc}") from exc
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\s]+)", line)
        if not match or match.group(2) in records:
            raise SystemExit("SHA256SUMS contains a malformed or duplicate record")
        records[match.group(2)] = match.group(1)
    return records


def verify_manifest(
    manifest: dict, lock: dict, expected_customization_commit: str | None = None
) -> dict[str, dict]:
    expected_top = {
        "schemaVersion": 1,
        "projectVersion": lock["projectVersion"],
        "codexVersion": lock["codexVersion"],
        "upstreamTag": lock["upstreamTag"],
        "upstreamCommit": lock["upstreamCommit"],
        "patchSha256": lock["patch"]["sha256"],
    }
    for key, expected in expected_top.items():
        if manifest.get(key) != expected:
            raise SystemExit(f"Release manifest mismatch for {key}")
    customization_commit = manifest.get("customizationCommit")
    if not COMMIT_RE.fullmatch(str(customization_commit)):
        raise SystemExit("Release manifest contains an invalid customization commit")
    if expected_customization_commit and customization_commit != expected_customization_commit:
        raise SystemExit(
            "Release manifest customization commit does not match the triggering commit"
        )
    assets = manifest.get("assets")
    if not isinstance(assets, list):
        raise SystemExit("Release manifest assets must be a list")
    by_target: dict[str, dict] = {}
    for entry in assets:
        if not isinstance(entry, dict) or not isinstance(entry.get("target"), str):
            raise SystemExit("Release manifest contains an invalid asset entry")
        if entry["target"] in by_target:
            raise SystemExit("Release manifest contains a duplicate target")
        by_target[entry["target"]] = entry
        if entry.get("customizationCommit") != customization_commit:
            raise SystemExit("Release asset customization commits are inconsistent")
    expected_targets = {target["triple"] for target in lock["targets"]}
    if set(by_target) != expected_targets:
        raise SystemExit("Release manifest target set does not match release-lock.json")
    return by_target


def safely_write_extracted(destination: Path, files: dict[str, bytes], target: dict) -> None:
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"Extraction destination is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        path = destination / name
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags, 0o755 if name == target["executable"] else 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())


def verify(args: argparse.Namespace) -> None:
    lock_path = args.lock.resolve()
    lock = load_lock(lock_path)
    release_dir = args.release_dir.resolve()
    actual_names = {path.name for path in release_dir.iterdir() if path.is_file()}
    full_expected_names = expected_release_names(lock)
    if args.selected_only:
        if not args.target:
            raise SystemExit("--selected-only requires --target")
        selected = target_for(lock, args.target)
        base = asset_base(lock, selected)
        archive_name = f"{base}{archive_suffix(selected)}"
        expected_names = {
            archive_name,
            f"{archive_name}.sha256",
            f"{base}.metadata.json",
            "release-manifest.json",
            "SHA256SUMS",
            "SHA256SUMS.sig",
        }
    else:
        expected_names = full_expected_names
    if actual_names != expected_names:
        raise SystemExit(
            f"Release asset set mismatch; expected={sorted(expected_names)}, "
            f"actual={sorted(actual_names)}"
        )

    verify_sha256sums_signature(lock_path, lock, release_dir)
    sums = parse_sha256sums(release_dir / "SHA256SUMS")
    expected_sum_names = full_expected_names - {"SHA256SUMS", "SHA256SUMS.sig"}
    if set(sums) != expected_sum_names:
        raise SystemExit("SHA256SUMS file set does not match the release")
    for name in actual_names - {"SHA256SUMS", "SHA256SUMS.sig"}:
        expected_hash = sums.get(name)
        if expected_hash is None:
            raise SystemExit(f"SHA256SUMS is missing {name}")
        if sha256_file(release_dir / name) != expected_hash:
            raise SystemExit(f"SHA256SUMS verification failed for {name}")

    manifest = load_json(release_dir / "release-manifest.json")
    manifest_assets = verify_manifest(manifest, lock, args.expected_customization_commit)
    selected_files: dict[str, bytes] | None = None
    selected_target: dict | None = None
    targets = [target_for(lock, args.target)] if args.selected_only else lock["targets"]
    for target in targets:
        metadata, archive, archive_hash = validate_candidate(release_dir, lock, target)
        entry = manifest_assets[target["triple"]]
        if entry.get("asset") != archive.name or entry.get("archiveSha256") != archive_hash:
            raise SystemExit(f"Release manifest archive mismatch for {target['triple']}")
        for key, value in metadata.items():
            if entry.get(key) != value:
                raise SystemExit(f"Release manifest metadata mismatch for {target['triple']} {key}")
        files = read_archive_files(archive, target)
        try:
            embedded = json.loads(files["BUILD-METADATA.json"].decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise SystemExit(f"Invalid embedded build metadata: {exc}") from exc
        if embedded != metadata:
            raise SystemExit(f"Embedded metadata mismatch for {target['triple']}")
        if sha256_bytes(files[target["executable"]]) != metadata["binarySha256"]:
            raise SystemExit(f"Binary SHA-256 mismatch for {target['triple']}")
        if args.target == target["triple"]:
            selected_files = files
            selected_target = target

    if args.target and selected_files is None:
        raise SystemExit(f"Requested extraction target is not locked: {args.target}")
    if args.extract_dir:
        if selected_files is None or selected_target is None:
            raise SystemExit("--extract-dir requires --target")
        safely_write_extracted(args.extract_dir.resolve(), selected_files, selected_target)
    print(f"release assets OK: {len(lock['targets'])} targets")


def boolean(value: str) -> bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise argparse.ArgumentTypeError("expected true or false")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subparsers = result.add_subparsers(dest="command", required=True)

    package_parser = subparsers.add_parser("package")
    package_parser.add_argument("--lock", type=Path, required=True)
    package_parser.add_argument("--target", required=True)
    package_parser.add_argument("--binary", type=Path, required=True)
    package_parser.add_argument("--dist", type=Path, required=True)
    package_parser.add_argument("--customization-commit", required=True)
    package_parser.add_argument("--debug-symbols-stripped", type=boolean, required=True)
    package_parser.add_argument("--allow-test-macos-binary", action="store_true")
    package_parser.set_defaults(handler=package)

    assemble_parser = subparsers.add_parser("assemble")
    assemble_parser.add_argument("--lock", type=Path, required=True)
    assemble_parser.add_argument("--dist", type=Path, required=True)
    assemble_parser.add_argument("--signing-key", type=Path, required=True)
    assemble_parser.add_argument("--customization-commit", required=True)
    assemble_parser.set_defaults(handler=assemble)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--lock", type=Path, required=True)
    verify_parser.add_argument("--release-dir", type=Path, required=True)
    verify_parser.add_argument("--target")
    verify_parser.add_argument("--extract-dir", type=Path)
    verify_parser.add_argument("--selected-only", action="store_true")
    verify_parser.add_argument("--expected-customization-commit")
    verify_parser.set_defaults(handler=verify)
    return result


def main() -> None:
    args = parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
