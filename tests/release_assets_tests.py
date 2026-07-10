#!/usr/bin/env python3

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "release_assets", ROOT / "scripts" / "release_assets.py"
)
assert SPEC and SPEC.loader
release_assets = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release_assets
SPEC.loader.exec_module(release_assets)


def load_script_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


profile_block = load_script_module("profile_block", ROOT / "scripts" / "profile_block.py")
macos_manifest = load_script_module("macos_manifest", ROOT / "scripts" / "macos_manifest.py")


class ReleaseArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.lock = release_assets.load_lock(ROOT / "release-lock.json")
        self.mac = release_assets.target_for(self.lock, "aarch64-apple-darwin")
        self.windows = release_assets.target_for(
            self.lock, "x86_64-pc-windows-msvc"
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def valid_files(executable: str) -> dict[str, bytes]:
        metadata = json.dumps({"schemaVersion": 1}).encode()
        return {
            executable: b"binary",
            "LICENSE": b"license",
            "NOTICE.md": b"notice",
            "BUILD-METADATA.json": metadata,
        }

    def make_tar(self, name: str, members: list[tuple[tarfile.TarInfo, bytes]]) -> Path:
        path = self.root / name
        with tarfile.open(path, "w:gz") as archive:
            for info, data in members:
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        return path

    def test_tar_path_traversal_is_rejected(self) -> None:
        members = []
        for name, data in self.valid_files("codex").items():
            members.append((tarfile.TarInfo(name), data))
        members[0] = (tarfile.TarInfo("../codex"), b"binary")
        path = self.make_tar("traversal.tar.gz", members)
        with self.assertRaises(SystemExit):
            release_assets.read_archive_files(path, self.mac)

    def test_tar_symlink_is_rejected(self) -> None:
        members = []
        link = tarfile.TarInfo("codex")
        link.type = tarfile.SYMTYPE
        link.linkname = "/tmp/victim"
        members.append((link, b""))
        for name, data in self.valid_files("codex").items():
            if name != "codex":
                members.append((tarfile.TarInfo(name), data))
        path = self.make_tar("symlink.tar.gz", members)
        with self.assertRaises(SystemExit):
            release_assets.read_archive_files(path, self.mac)

    def test_duplicate_zip_member_is_rejected(self) -> None:
        path = self.root / "duplicate.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w") as archive:
                for name, data in self.valid_files("codex.exe").items():
                    archive.writestr(name, data)
                archive.writestr("codex.exe", b"second")
        with self.assertRaises(SystemExit):
            release_assets.read_archive_files(path, self.windows)

    def test_macos_metadata_requires_adhoc_codesign_record(self) -> None:
        metadata = {
            "schemaVersion": 1,
            **release_assets.expected_metadata(self.lock, self.mac),
            "customizationCommit": "a" * 40,
            "binarySha256": "b" * 64,
            "debugSymbolsStripped": True,
            "signing": {
                "kind": "none",
                "codesignVerified": False,
                "developerId": False,
                "notarized": False,
            },
        }
        with self.assertRaises(SystemExit):
            release_assets.validate_metadata(metadata, self.lock, self.mac)

    def test_macos_packager_verifies_binary_before_recording_codesign(self) -> None:
        binary = self.root / "codex"
        binary.write_bytes(b"not a Mach-O")
        arguments = argparse.Namespace(
            lock=ROOT / "release-lock.json",
            target="aarch64-apple-darwin",
            binary=binary,
            dist=self.root / "dist",
            customization_commit="a" * 40,
            debug_symbols_stripped=True,
            allow_test_macos_binary=False,
        )
        with mock.patch.object(
            release_assets,
            "verify_macos_binary",
            side_effect=SystemExit("codesign rejected"),
        ) as verifier:
            with self.assertRaisesRegex(SystemExit, "codesign rejected"):
                release_assets.package(arguments)
        verifier.assert_called_once_with(binary.resolve())

    def test_signed_bundle_full_and_selected_verification(self) -> None:
        fixture = self.root / "fixture"
        (fixture / "keys").mkdir(parents=True)
        shutil.copy(ROOT / "LICENSE", fixture / "LICENSE")
        shutil.copy(ROOT / "NOTICE.md", fixture / "NOTICE.md")
        private_key = fixture / "private.pem"
        public_key = fixture / "keys" / "release-signing-public.pem"
        openssl = release_assets.openssl_command()
        subprocess.run(
            [openssl, "genrsa", "-out", str(private_key), "2048"],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [openssl, "pkey", "-in", str(private_key), "-pubout", "-out", str(public_key)],
            check=True,
            capture_output=True,
        )
        lock = json.loads((ROOT / "release-lock.json").read_text(encoding="utf-8"))
        lock["releaseSigning"]["publicKeySha256"] = hashlib.sha256(
            public_key.read_bytes()
        ).hexdigest()
        lock["releaseSigning"]["signatureSize"] = 256
        lock_path = fixture / "release-lock.json"
        lock_path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")

        commit = "a" * 40
        dist = self.root / "dist"
        windows_binary = self.root / "codex.exe"
        mac_binary = self.root / "codex"
        windows_binary.write_bytes(b"windows binary")
        mac_binary.write_bytes(b"mac binary")
        release_assets.package(
            argparse.Namespace(
                lock=lock_path,
                target="x86_64-pc-windows-msvc",
                binary=windows_binary,
                dist=dist,
                customization_commit=commit,
                debug_symbols_stripped=False,
                allow_test_macos_binary=False,
            )
        )
        with mock.patch.dict(os.environ, {"CODEX_USAGE_STATUSLINE_TEST_MODE": "1"}):
            release_assets.package(
                argparse.Namespace(
                    lock=lock_path,
                    target="aarch64-apple-darwin",
                    binary=mac_binary,
                    dist=dist,
                    customization_commit=commit,
                    debug_symbols_stripped=True,
                    allow_test_macos_binary=True,
                )
            )
        release_assets.assemble(
            argparse.Namespace(
                lock=lock_path,
                dist=dist,
                signing_key=private_key,
                customization_commit=commit,
            )
        )
        release_assets.verify(
            argparse.Namespace(
                lock=lock_path,
                release_dir=dist,
                target=None,
                extract_dir=None,
                selected_only=False,
                expected_customization_commit=commit,
            )
        )
        extracted = self.root / "extracted"
        selected_dist = self.root / "selected-dist"
        selected_dist.mkdir()
        base = "codex-usage-statusline-0.3.0-codex-0.144.1-aarch64-apple-darwin"
        for name in (
            f"{base}.tar.gz",
            f"{base}.tar.gz.sha256",
            f"{base}.metadata.json",
            "release-manifest.json",
            "SHA256SUMS",
            "SHA256SUMS.sig",
        ):
            shutil.copy(dist / name, selected_dist / name)
        release_assets.verify(
            argparse.Namespace(
                lock=lock_path,
                release_dir=selected_dist,
                target="aarch64-apple-darwin",
                extract_dir=extracted,
                selected_only=True,
                expected_customization_commit=commit,
            )
        )
        self.assertEqual((extracted / "codex").read_bytes(), b"mac binary")
        with self.assertRaises(SystemExit):
            release_assets.verify(
                argparse.Namespace(
                    lock=lock_path,
                    release_dir=dist,
                    target=None,
                    extract_dir=None,
                    selected_only=False,
                    expected_customization_commit="b" * 40,
                )
            )


class MacHelperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_profile_removal_preserves_edit_immediately_before_block(self) -> None:
        profile = self.root / ".zprofile"
        profile.write_bytes(b"export BASE=1")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            profile_block.install(
                argparse.Namespace(path=profile, bin_dir=str(self.root / "state" / "bin"))
            )
        record = json.loads(output.getvalue())
        marker = profile_block.BEGIN
        profile.write_bytes(
            profile.read_bytes().replace(marker, b"export BEFORE=1\n" + marker, 1)
        )
        with contextlib.redirect_stdout(io.StringIO()):
            profile_block.remove(
                argparse.Namespace(
                    path=profile,
                    bin_dir=str(self.root / "state" / "bin"),
                    expected_block_sha=record["blockSha256"],
                    previous_sha=record["previousSha256"],
                    separator=record["separator"],
                    existed_before=True,
                )
            )
        self.assertEqual(profile.read_bytes(), b"export BASE=1\nexport BEFORE=1\n")

    def test_manifest_records_custom_zdotdir_by_shell(self) -> None:
        home = self.root / "home"
        state = self.root / "state"
        zdotdir = home / "zsh"
        zdotdir.mkdir(parents=True)
        home.mkdir(exist_ok=True)
        records = []
        for profile in (zdotdir / ".zprofile", home / ".bash_profile"):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                profile_block.install(
                    argparse.Namespace(path=profile, bin_dir=str(state / "bin"))
                )
            record_path = self.root / f"record-{len(records)}.json"
            record_path.write_text(output.getvalue(), encoding="utf-8")
            records.append(record_path)
        official = self.root / "official.json"
        official.write_text(
            json.dumps(
                {
                    "installationKind": "npm",
                    "target": "aarch64-apple-darwin",
                    "version": "0.144.1",
                    "commandPath": "/official/codex",
                    "binaryPath": "/official/bundle/bin/codex",
                    "bundleRoot": "/official/bundle",
                    "binaryRelativePath": "bin/codex",
                }
            ),
            encoding="utf-8",
        )
        manifest_path = state / "active-install.json"
        custom_bundle = state / "versions" / "0.3.0-codex-0.144.1"
        custom_binary = custom_bundle / "bin" / "codex"
        custom_binary.parent.mkdir(parents=True)
        custom_binary.write_bytes(b"custom")
        launcher_directory = state / "bin"
        launcher_directory.mkdir(parents=True)
        (launcher_directory / "codex").write_bytes(b"launcher")
        with contextlib.redirect_stdout(io.StringIO()):
            macos_manifest.create(
                argparse.Namespace(
                    output=manifest_path,
                    official_info=official,
                    codex_version="0.144.1",
                    customization_commit="a" * 40,
                    project_version="0.3.0",
                    release_tag="v0.3.0",
                    installed_at="2026-07-10T00:00:00Z",
                    language="ko",
                    asset_name="asset.tar.gz",
                    archive_sha256="a" * 64,
                    custom_bundle=custom_bundle,
                    custom_binary=custom_binary,
                    custom_binary_sha256="b" * 64,
                    launcher_directory=launcher_directory,
                    launcher_path=launcher_directory / "codex",
                    launcher_sha256="c" * 64,
                    status_line_override="tui.status_line=[]",
                    config_toml_before="absent",
                    profile_record=records,
                )
            )
        manifest = macos_manifest.load(manifest_path)
        macos_manifest.validate_manifest(manifest, state, "0.3.0", "0.144.1", home)
        by_shell = {record["shell"]: record["path"] for record in manifest["profiles"]}
        self.assertEqual(by_shell["zsh"], str(zdotdir / ".zprofile"))
        self.assertEqual(by_shell["bash"], str(home / ".bash_profile"))
        with contextlib.redirect_stdout(io.StringIO()):
            macos_manifest.verify_inventory(
                argparse.Namespace(manifest=manifest_path, kind="bundle")
            )
        (custom_bundle / "added.txt").write_text("user data", encoding="utf-8")
        with self.assertRaises(SystemExit):
            macos_manifest.verify_inventory(
                argparse.Namespace(manifest=manifest_path, kind="bundle")
            )
        manifest["profiles"][1]["shell"] = "zsh"
        with self.assertRaises(SystemExit):
            macos_manifest.validate_manifest(manifest, state, "0.3.0", "0.144.1", home)


if __name__ == "__main__":
    unittest.main()
