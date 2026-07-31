#!/usr/bin/env python3
"""Verify the self-contained Sepolia deployed-source freeze."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import struct
import sys
from typing import Any

HEX64 = re.compile(r"^[0-9a-f]{64}$")


class FreezeError(ValueError):
    pass


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise FreezeError(f"cannot read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise FreezeError("manifest root must be an object")
    return value


def contained(root: pathlib.Path, relative: str) -> pathlib.Path:
    candidate = pathlib.PurePosixPath(relative)
    if candidate.is_absolute() or ".." in candidate.parts or not relative.startswith("src/"):
        raise FreezeError(f"unsafe source path: {relative}")
    resolved = (root / candidate).resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as exc:
        raise FreezeError(f"source escapes frozen root: {relative}") from exc
    return resolved


def verify(manifest_path: pathlib.Path) -> tuple[int, str]:
    manifest_path = manifest_path.resolve()
    manifest = load_json(manifest_path)
    if manifest.get("schemaVersion") != 1:
        raise FreezeError("unsupported source-freeze schemaVersion")
    source_root = manifest.get("sourceRoot")
    if not isinstance(source_root, str):
        raise FreezeError("sourceRoot is missing")
    repository = manifest_path.parents[2]
    source_root_path = (repository / source_root).resolve()
    try:
        source_root_path.relative_to(repository)
    except ValueError as exc:
        raise FreezeError("sourceRoot escapes repository") from exc
    if not source_root_path.is_dir() or source_root_path.is_symlink():
        raise FreezeError("sourceRoot must be a real directory")

    entries = manifest.get("files")
    if not isinstance(entries, list) or not entries:
        raise FreezeError("files must be a nonempty array")
    paths: set[str] = set()
    aggregate = hashlib.sha256()
    for entry in sorted(entries, key=lambda item: item.get("path", "") if isinstance(item, dict) else ""):
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256", "bytes"}:
            raise FreezeError("each file entry must contain exactly path, sha256, and bytes")
        relative = entry["path"]
        expected_hash = entry["sha256"]
        expected_bytes = entry["bytes"]
        if not isinstance(relative, str) or relative in paths:
            raise FreezeError(f"duplicate or invalid source path: {relative!r}")
        paths.add(relative)
        if not isinstance(expected_hash, str) or not HEX64.fullmatch(expected_hash):
            raise FreezeError(f"invalid SHA-256 for {relative}")
        if not isinstance(expected_bytes, int) or expected_bytes < 0:
            raise FreezeError(f"invalid byte count for {relative}")
        path = contained(source_root_path, relative)
        if not path.is_file() or path.is_symlink():
            raise FreezeError(f"missing or symlinked frozen source: {relative}")
        data = path.read_bytes()
        if len(data) != expected_bytes:
            raise FreezeError(f"byte count mismatch for {relative}")
        if hashlib.sha256(data).hexdigest() != expected_hash:
            raise FreezeError(f"SHA-256 mismatch for {relative}")
        encoded_path = relative.encode()
        aggregate.update(struct.pack(">I", len(encoded_path)))
        aggregate.update(encoded_path)
        aggregate.update(struct.pack(">Q", len(data)))
        aggregate.update(data)

    root_digest = aggregate.hexdigest()
    if manifest.get("rootDigest") != root_digest:
        raise FreezeError("aggregate rootDigest mismatch")
    actual_sources = {
        path.relative_to(source_root_path).as_posix()
        for path in source_root_path.rglob("*.sol")
        if path.is_file()
    }
    if actual_sources != paths:
        raise FreezeError("sourceRoot contains undeclared or missing Solidity files")
    return len(paths), root_digest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "manifest",
        nargs="?",
        type=pathlib.Path,
        default=pathlib.Path("deployments/sepolia/source-freeze.json"),
    )
    args = parser.parse_args()
    try:
        count, root_digest = verify(args.manifest)
    except FreezeError as exc:
        print(f"SEPOLIA_SOURCE_FREEZE_FAILED: {exc}", file=sys.stderr)
        return 1
    print(f"SEPOLIA_SOURCE_FREEZE_PASSED: files={count} root={root_digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
