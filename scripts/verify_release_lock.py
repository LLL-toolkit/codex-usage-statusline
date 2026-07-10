#!/usr/bin/env python3
"""Validate version, upstream, patch, and installer release metadata."""

from __future__ import annotations

import argparse
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

    require_text(ROOT / "install.ps1", r"\$ProjectVersion = '([^']+)'", version)
    require_text(
        ROOT / "install.ps1",
        r"\$SupportedCodexVersion = '([^']+)'",
        lock["codexVersion"],
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
    triples = [target["triple"] for target in lock["targets"]]
    if len(triples) != len(set(triples)):
        raise SystemExit("release-lock.json contains duplicate target triples")
    required = {"x86_64-pc-windows-msvc"}
    if set(triples) != required:
        raise SystemExit(f"Unexpected release target set: {triples}")

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

    print(
        f"release lock OK: project {version}, Codex {lock['codexVersion']}, "
        f"{len(triples)} targets, patch {actual_patch_hash}"
    )


if __name__ == "__main__":
    main()
