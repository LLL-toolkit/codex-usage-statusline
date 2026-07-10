#!/usr/bin/env python3
"""Locate the active user's official Apple Silicon Codex resource bundle."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


TARGET = "aarch64-apple-darwin"
VERSION_RE = re.compile(r"(?:^|\s)(\d+\.\d+\.\d+)(?:\s|$)")


@dataclass(frozen=True)
class Candidate:
    kind: str
    command_path: Path
    binary_path: Path
    bundle_root: Path
    relative_binary: Path


def is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except (OSError, ValueError):
        return False


def command_version(path: Path) -> tuple[str, str] | None:
    try:
        process = subprocess.run(
            [str(path), "--version"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=15,
            env=os.environ.copy(),
        )
    except (OSError, subprocess.SubprocessError):
        return None
    output = process.stdout.strip()
    match = VERSION_RE.search(output)
    if process.returncode != 0 or not match:
        return None
    return match.group(1), output


def is_node_launcher(path: Path) -> bool:
    if path.suffix == ".js":
        return True
    try:
        return b"node" in path.read_bytes()[:256].splitlines()[0]
    except (OSError, IndexError):
        return False


def native_architecture(path: Path, allow_test_binaries: bool) -> bool:
    if allow_test_binaries:
        return path.is_file() and os.access(path, os.X_OK)
    try:
        output = subprocess.run(
            ["/usr/bin/lipo", "-archs", str(path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    return output.split() == ["arm64"]


def candidate_from_binary(
    kind: str,
    command_path: Path,
    binary_path: Path,
) -> Candidate | None:
    try:
        binary = binary_path.resolve(strict=True)
    except OSError:
        return None
    parts = binary.parts
    if TARGET in parts:
        index = parts.index(TARGET)
        bundle = Path(*parts[: index + 1])
    elif binary.parent.name == "bin" and (binary.parent.parent / "codex-package.json").is_file():
        bundle = binary.parent.parent
    else:
        bundle = binary.parent
    try:
        relative = binary.relative_to(bundle)
    except ValueError:
        return None
    if relative.is_absolute() or ".." in relative.parts:
        return None
    return Candidate(kind, command_path, binary, bundle.resolve(), relative)


def npm_candidates(command_path: Path, launcher: Path) -> list[Candidate]:
    roots: list[Path] = []
    if launcher.name == "codex.js" and launcher.parent.name == "bin":
        roots.append(launcher.parent.parent)
    patterns = (
        Path("node_modules/@openai/codex-darwin-arm64/vendor") / TARGET / "bin/codex",
        Path("node_modules/@openai/codex-darwin-arm64/vendor") / TARGET / "codex/codex",
        Path("vendor") / TARGET / "bin/codex",
    )

    def candidates_for_roots(search_roots: list[Path]) -> list[Candidate]:
        found: list[Candidate] = []
        for root in search_roots:
            for pattern in patterns:
                candidate = candidate_from_binary("npm", command_path, root / pattern)
                if candidate:
                    found.append(candidate)
        return found

    results = candidates_for_roots(roots)
    if results:
        return results

    try:
        process = subprocess.run(
            ["npm", "root", "-g"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
        )
        if process.returncode == 0 and process.stdout.strip():
            roots = [Path(process.stdout.strip()) / "@openai" / "codex"]
    except (OSError, subprocess.SubprocessError):
        roots = []

    return candidates_for_roots(roots)


def standalone_candidates(home: Path, command_path: Path) -> list[Candidate]:
    codex_home = Path(os.environ.get("CODEX_HOME", str(home / ".codex"))).expanduser()
    standalone = codex_home / "packages" / "standalone"
    roots: list[Path] = [standalone / "current"]
    releases = standalone / "releases"
    if releases.is_dir():
        roots.extend(sorted(releases.glob(f"*-{TARGET}"), reverse=True))
    results: list[Candidate] = []
    for root in roots:
        for relative in (Path("bin/codex"), Path("codex")):
            candidate = candidate_from_binary("standalone", command_path, root / relative)
            if candidate:
                results.append(candidate)
    return results


def homebrew_candidates(command_path: Path, resolved_command: Path) -> list[Candidate]:
    results: list[Candidate] = []
    resolved_text = str(resolved_command)
    if "/Caskroom/codex/" in resolved_text or "/Cellar/codex/" in resolved_text:
        candidate = candidate_from_binary("homebrew", command_path, resolved_command)
        if candidate:
            results.append(candidate)
    if results:
        return results

    prefixes = [Path("/opt/homebrew"), Path("/usr/local")]
    try:
        process = subprocess.run(
            ["brew", "--prefix"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
        )
        if process.returncode == 0 and process.stdout.strip():
            prefixes.insert(0, Path(process.stdout.strip()))
    except (OSError, subprocess.SubprocessError):
        pass
    for prefix in prefixes:
        patterns = (
            "Caskroom/codex/*/codex*",
            "Cellar/codex/*/bin/codex",
        )
        for pattern in patterns:
            for binary in sorted(prefix.glob(pattern), reverse=True):
                if binary.name.endswith((".tar.gz", ".zst", ".dmg")):
                    continue
                candidate = candidate_from_binary("homebrew", command_path, binary)
                if candidate:
                    results.append(candidate)
    return results


def path_commands(path_value: str) -> list[Path]:
    commands = []
    for entry in path_value.split(os.pathsep):
        if not entry:
            continue
        candidate = Path(entry).expanduser() / "codex"
        if candidate.exists() and os.access(candidate, os.X_OK):
            commands.append(candidate)
    return commands


def classify_command(command_path: Path, home: Path) -> list[Candidate]:
    try:
        resolved = command_path.resolve(strict=True)
    except OSError:
        return []
    if is_node_launcher(resolved):
        return npm_candidates(command_path, resolved)
    resolved_text = str(resolved)
    if "/packages/standalone/" in resolved_text:
        candidate = candidate_from_binary("standalone", command_path, resolved)
        return [candidate] if candidate else []
    if "/Caskroom/codex/" in resolved_text or "/Cellar/codex/" in resolved_text:
        candidate = candidate_from_binary("homebrew", command_path, resolved)
        return [candidate] if candidate else []
    candidate = candidate_from_binary("standalone", command_path, resolved)
    return [candidate] if candidate else []


def detect(args: argparse.Namespace) -> None:
    home = args.home.expanduser().resolve()
    state_root = args.state_root.expanduser().resolve()
    commands = path_commands(args.path)
    if not commands:
        raise SystemExit("Codex CLI was not found in PATH")

    active_version: tuple[str, str] | None = None
    for command in commands:
        if is_within(command, state_root):
            continue
        version = command_version(command)
        if version:
            active_version = version
            break
    if active_version is None:
        raise SystemExit("No official Codex command in PATH returned a version")
    if active_version[0] != args.expected_version:
        raise SystemExit(
            f"Codex {active_version[0]} is active, but this release requires exactly "
            f"{args.expected_version}"
        )

    candidates: list[Candidate] = []
    for command in commands:
        if is_within(command, state_root):
            continue
        candidates.extend(classify_command(command, home))
    candidates.extend(standalone_candidates(home, commands[0]))
    try:
        resolved_first = commands[0].resolve(strict=True)
    except OSError:
        resolved_first = commands[0]
    candidates.extend(homebrew_candidates(commands[0], resolved_first))

    seen: set[tuple[Path, Path]] = set()
    failures: list[str] = []
    for candidate in candidates:
        key = (candidate.binary_path, candidate.bundle_root)
        if key in seen or is_within(candidate.binary_path, state_root):
            continue
        seen.add(key)
        if not candidate.bundle_root.is_dir():
            continue
        if not native_architecture(candidate.binary_path, args.allow_test_binaries):
            failures.append(f"wrong architecture: {candidate.binary_path}")
            continue
        version = command_version(candidate.binary_path)
        if not version or version[0] != args.expected_version:
            failures.append(f"wrong version: {candidate.binary_path}")
            continue
        result = {
            "schemaVersion": 1,
            "installationKind": candidate.kind,
            "commandPath": str(candidate.command_path.absolute()),
            "binaryPath": str(candidate.binary_path),
            "bundleRoot": str(candidate.bundle_root),
            "binaryRelativePath": candidate.relative_binary.as_posix(),
            "version": version[0],
            "versionOutput": version[1],
            "target": TARGET,
        }
        print(json.dumps(result, ensure_ascii=False))
        return

    details = "; ".join(failures[:5])
    suffix = f" ({details})" if details else ""
    raise SystemExit(
        "Could not locate an official Codex Apple Silicon resource bundle from the "
        f"npm, Homebrew, or standalone installation{suffix}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--state-root", type=Path, required=True)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--path", default=os.environ.get("PATH", ""))
    parser.add_argument("--allow-test-binaries", action="store_true")
    detect(parser.parse_args())


if __name__ == "__main__":
    main()
