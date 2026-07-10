#!/usr/bin/env python3
"""Atomically add, verify, and remove the installer-owned shell profile block."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import stat
import tempfile
from pathlib import Path


BEGIN = b"# >>> codex-usage-statusline >>>"
END = b"# <<< codex-usage-statusline <<<"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def block(bin_dir: str) -> bytes:
    if any(character in bin_dir for character in "\r\n\0"):
        raise SystemExit("The launcher path contains an unsupported control character")
    path_value = shlex.quote(bin_dir)
    return (
        f"{BEGIN.decode()}\n"
        "# Managed by codex-usage-statusline.\n"
        f"export PATH={path_value}:\"$PATH\"\n"
        f"{END.decode()}\n"
    ).encode("utf-8")


def read_profile(path: Path) -> tuple[bool, bytes, int]:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False, b"", 0o600
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise SystemExit(f"Profile must be a regular file, not a link: {path}")
    return True, path.read_bytes(), stat.S_IMODE(info.st_mode)


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary.exists():
            temporary.unlink()


def marker_state(data: bytes, expected_block: bytes) -> None:
    begin_count = data.count(BEGIN)
    end_count = data.count(END)
    block_count = data.count(expected_block)
    if begin_count != block_count or end_count != block_count or block_count > 1:
        raise SystemExit("The managed profile block is duplicated or was modified")


def install(args: argparse.Namespace) -> None:
    path = args.path.expanduser()
    existed, previous, mode = read_profile(path)
    expected_block = block(args.bin_dir)
    marker_state(previous, expected_block)
    if expected_block in previous:
        result = {
            "path": str(path),
            "existed": existed,
            "previousSha256": sha256(previous),
            "installedSha256": sha256(previous),
            "blockSha256": sha256(expected_block),
            "separator": "existing",
            "changed": False,
        }
    else:
        separator = b"\n" if previous and not previous.endswith(b"\n") else b""
        managed = separator + expected_block
        installed = previous + managed
        atomic_write(path, installed, mode)
        result = {
            "path": str(path),
            "existed": existed,
            "previousSha256": sha256(previous),
            "installedSha256": sha256(installed),
            "blockSha256": sha256(expected_block),
            "separator": "newline" if separator else "none",
            "changed": True,
        }
    print(json.dumps(result, ensure_ascii=False))


def verify(args: argparse.Namespace) -> None:
    path = args.path.expanduser()
    existed, data, _ = read_profile(path)
    if not existed:
        raise SystemExit(f"Managed profile is missing: {path}")
    expected_block = block(args.bin_dir)
    marker_state(data, expected_block)
    if data.count(expected_block) != 1:
        raise SystemExit(f"Managed profile block is missing: {path}")
    if args.expected_block_sha and sha256(expected_block) != args.expected_block_sha:
        raise SystemExit("The expected profile block checksum is invalid")
    print(sha256(data))


def remove(args: argparse.Namespace) -> None:
    path = args.path.expanduser()
    existed, data, mode = read_profile(path)
    expected_block = block(args.bin_dir)
    if not re.fullmatch(r"[0-9a-f]{64}", args.previous_sha):
        raise SystemExit("The installation manifest contains an invalid previous profile checksum")
    if args.expected_block_sha and sha256(expected_block) != args.expected_block_sha:
        raise SystemExit("The installation manifest contains an invalid profile block checksum")
    if not existed:
        print(json.dumps({"path": str(path), "changed": False, "missing": True}))
        return
    marker_state(data, expected_block)
    count = data.count(expected_block)
    if count == 0:
        print(json.dumps({"path": str(path), "changed": False, "missing": True}))
        return
    if count != 1:
        raise SystemExit("The managed profile block is duplicated")

    start = data.index(expected_block)
    if args.separator == "newline":
        if start == 0 or data[start - 1 : start] != b"\n":
            raise SystemExit("The managed profile separator was modified")
        if sha256(data[: start - 1]) == args.previous_sha:
            start -= 1
    elif args.separator not in ("none", "existing"):
        raise SystemExit("The installation manifest contains an invalid profile separator")
    cleaned = data[:start] + data[data.index(expected_block) + len(expected_block) :]

    if not cleaned and not args.existed_before:
        path.unlink()
        changed_hash = sha256(b"")
    else:
        atomic_write(path, cleaned, mode)
        changed_hash = sha256(cleaned)
    print(
        json.dumps(
            {
                "path": str(path),
                "changed": True,
                "missing": False,
                "resultSha256": changed_hash,
            },
            ensure_ascii=False,
        )
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    install_parser = subparsers.add_parser("install")
    install_parser.add_argument("--path", type=Path, required=True)
    install_parser.add_argument("--bin-dir", required=True)
    install_parser.set_defaults(handler=install)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--path", type=Path, required=True)
    verify_parser.add_argument("--bin-dir", required=True)
    verify_parser.add_argument("--expected-block-sha")
    verify_parser.set_defaults(handler=verify)

    remove_parser = subparsers.add_parser("remove")
    remove_parser.add_argument("--path", type=Path, required=True)
    remove_parser.add_argument("--bin-dir", required=True)
    remove_parser.add_argument("--expected-block-sha")
    remove_parser.add_argument("--previous-sha", required=True)
    remove_parser.add_argument("--separator", required=True)
    remove_parser.add_argument("--existed-before", action="store_true")
    remove_parser.set_defaults(handler=remove)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
