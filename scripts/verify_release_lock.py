#!/usr/bin/env python3
"""Validate version, upstream, patch, installers, and release target metadata."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_text(path: Path, pattern: str, expected: str) -> None:
    text = path.read_text(encoding="utf-8")
    match = re.search(pattern, text, re.MULTILINE)
    if not match or match.group(1) != expected:
        actual = match.group(1) if match else "<missing>"
        raise SystemExit(f"{path.name}: expected {expected!r}, found {actual!r}")


def read_der_item(data: bytes, offset: int, expected_tag: int) -> tuple[bytes, int]:
    if offset >= len(data) or data[offset] != expected_tag:
        raise SystemExit("The release-signing public key has an unexpected DER structure")
    offset += 1
    if offset >= len(data):
        raise SystemExit("The release-signing public key has a truncated DER length")
    first = data[offset]
    offset += 1
    if first < 0x80:
        length = first
    else:
        count = first & 0x7F
        if count == 0 or count > 4 or offset + count > len(data):
            raise SystemExit("The release-signing public key has an invalid DER length")
        length = int.from_bytes(data[offset : offset + count], "big")
        offset += count
    end = offset + length
    if end > len(data):
        raise SystemExit("The release-signing public key is truncated")
    return data[offset:end], end


def rsa_public_parameters(path: Path) -> tuple[str, str]:
    lines = path.read_text(encoding="ascii").splitlines()
    if lines[:1] != ["-----BEGIN PUBLIC KEY-----"] or lines[-1:] != ["-----END PUBLIC KEY-----"]:
        raise SystemExit("The release-signing public key is not canonical PEM")
    try:
        der = base64.b64decode("".join(lines[1:-1]), validate=True)
    except ValueError as exc:
        raise SystemExit("The release-signing public key contains invalid base64") from exc
    spki, end = read_der_item(der, 0, 0x30)
    if end != len(der):
        raise SystemExit("The release-signing public key has trailing DER data")
    _, offset = read_der_item(spki, 0, 0x30)
    bit_string, offset = read_der_item(spki, offset, 0x03)
    if offset != len(spki) or not bit_string or bit_string[0] != 0:
        raise SystemExit("The release-signing public key has an invalid bit string")
    rsa_sequence, end = read_der_item(bit_string[1:], 0, 0x30)
    if end != len(bit_string) - 1:
        raise SystemExit("The release-signing RSA key has trailing data")
    modulus, offset = read_der_item(rsa_sequence, 0, 0x02)
    exponent, offset = read_der_item(rsa_sequence, offset, 0x02)
    if offset != len(rsa_sequence) or not modulus or not exponent:
        raise SystemExit("The release-signing RSA parameters are invalid")
    if modulus[0] == 0:
        modulus = modulus[1:]
    return (
        base64.b64encode(modulus).decode("ascii"),
        base64.b64encode(exponent).decode("ascii"),
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", help="Validate the release tag that triggered CI")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()

    lock = json.loads((ROOT / "release-lock.json").read_text(encoding="utf-8"))
    if lock["schemaVersion"] != 1:
        raise SystemExit("Unsupported release-lock.json schema")
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if version != lock["projectVersion"]:
        raise SystemExit(f"VERSION is {version}, release lock is {lock['projectVersion']}")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit(f"Project version is not stable SemVer: {version!r}")
    if lock["releaseTag"] != f"v{version}":
        raise SystemExit("releaseTag must be v followed by projectVersion")
    if args.tag and args.tag != lock["releaseTag"]:
        raise SystemExit(f"Tag {args.tag!r} does not match {lock['releaseTag']!r}")

    patch_path = ROOT / lock["patch"]["path"]
    actual_patch_hash = sha256(patch_path)
    if actual_patch_hash != lock["patch"]["sha256"]:
        raise SystemExit(
            f"Patch hash mismatch: expected {lock['patch']['sha256']}, got {actual_patch_hash}"
        )
    if b"\r\n" in patch_path.read_bytes():
        raise SystemExit("Patch must use LF line endings")

    expected_signing = {
        "algorithm": "rsa-pkcs1v15-sha256",
        "publicKeyPath": "keys/release-signing-public.pem",
        "publicKeySha256": "c004c4a7baf1f3dedfcfca3346db7d93b37a148d0455b01a56fb5859f31488d0",
        "signatureSize": 384,
    }
    if lock.get("releaseSigning") != expected_signing:
        raise SystemExit("Unexpected release-signing configuration")
    signing_key = ROOT / expected_signing["publicKeyPath"]
    if signing_key.is_symlink() or not signing_key.is_file():
        raise SystemExit("The release-signing public key is missing or unsafe")
    if b"\r\n" in signing_key.read_bytes():
        raise SystemExit("The release-signing public key must use LF line endings")
    if sha256(signing_key) != expected_signing["publicKeySha256"]:
        raise SystemExit("The release-signing public-key checksum does not match the lock")
    signing_modulus, signing_exponent = rsa_public_parameters(signing_key)

    require_text(ROOT / "install.ps1", r"\$ProjectVersion = '([^']+)'", version)
    require_text(
        ROOT / "install.ps1",
        r"\$SupportedCodexVersion = '([^']+)'",
        lock["codexVersion"],
    )
    require_text(
        ROOT / "install.ps1",
        r"\$ReleaseSigningPublicKeySha256 = '([^']+)'",
        expected_signing["publicKeySha256"],
    )
    require_text(
        ROOT / "install.ps1",
        r"\$ReleaseSigningSignatureSize = (\d+)",
        str(expected_signing["signatureSize"]),
    )
    powershell_text = (ROOT / "install.ps1").read_text(encoding="utf-8")
    modulus_block = re.search(
        r"\$ReleaseSigningModulusBase64 = @\((.*?)\) -join ''",
        powershell_text,
        re.DOTALL,
    )
    powershell_modulus = "".join(re.findall(r"'([^']*)'", modulus_block.group(1))) if modulus_block else ""
    if powershell_modulus != signing_modulus:
        raise SystemExit("install.ps1 release-signing RSA modulus does not match the public key")
    require_text(
        ROOT / "install.ps1",
        r"\$ReleaseSigningExponentBase64 = '([^']+)'",
        signing_exponent,
    )
    require_text(ROOT / "install.ps1", r"\$ReleaseTag = '([^']+)'", lock["releaseTag"])
    require_text(
        ROOT / "install.ps1",
        r"\$ExpectedUpstreamCommit = '([^']+)'",
        lock["upstreamCommit"],
    )
    require_text(
        ROOT / "install.ps1",
        r"\$ExpectedPatchSha256 = '([^']+)'",
        lock["patch"]["sha256"],
    )
    require_text(ROOT / "uninstall.ps1", r"\$ProjectVersion = '([^']+)'", version)
    require_text(ROOT / "install.sh", r"^ProjectVersion='([^']+)'", version)
    require_text(ROOT / "install.sh", r"^SupportedCodexVersion='([^']+)'", lock["codexVersion"])
    require_text(ROOT / "install.sh", r"^ReleaseTag='([^']+)'", lock["releaseTag"])
    require_text(ROOT / "install.sh", r"^TargetTriple='([^']+)'", "aarch64-apple-darwin")
    require_text(ROOT / "uninstall.sh", r"^ProjectVersion='([^']+)'", version)
    require_text(
        ROOT / "uninstall.sh",
        r"^SupportedCodexVersion='([^']+)'",
        lock["codexVersion"],
    )
    triples = [target["triple"] for target in lock["targets"]]
    if len(triples) != len(set(triples)):
        raise SystemExit("release-lock.json contains duplicate target triples")
    expected_targets = [
        {
            "os": "windows",
            "arch": "x86_64",
            "triple": "x86_64-pc-windows-msvc",
            "archive": "zip",
            "runner": "windows-2022",
            "executable": "codex.exe",
        },
        {
            "os": "macos",
            "arch": "aarch64",
            "triple": "aarch64-apple-darwin",
            "archive": "tar.gz",
            "runner": "macos-15",
            "executable": "codex",
        },
    ]
    if lock["targets"] != expected_targets:
        raise SystemExit(f"Unexpected release targets: {lock['targets']!r}")

    build_matrix = {
        "include": [
            {
                "os": target["os"],
                "runner": target["runner"],
                "target": target["triple"],
                "executable": target["executable"],
                "archive": target["archive"],
            }
            for target in lock["targets"]
        ]
    }

    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as output:
            output.write(f"project_version={version}\n")
            output.write(f"release_tag={lock['releaseTag']}\n")
            output.write(f"codex_version={lock['codexVersion']}\n")
            output.write(f"upstream_tag={lock['upstreamTag']}\n")
            output.write(f"upstream_tag_object={lock['upstreamTagObject']}\n")
            output.write(f"upstream_commit={lock['upstreamCommit']}\n")
            output.write(f"upstream_tree={lock['upstreamTree']}\n")
            output.write(f"rust_toolchain={lock['rustToolchain']}\n")
            output.write(f"patch_sha256={lock['patch']['sha256']}\n")
            output.write(f"patch_path={lock['patch']['path']}\n")
            output.write(f"build_matrix={json.dumps(build_matrix, separators=(',', ':'))}\n")

    print(
        f"release lock OK: project {version}, Codex {lock['codexVersion']}, "
        f"{len(triples)} targets, patch {actual_patch_hash}"
    )


if __name__ == "__main__":
    main()
