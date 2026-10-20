"""Bounded, streaming personal content transport. Never downloads game data.

PNCONT1 is an eight-byte magic, little-endian uint64 JSON length, a UTF-8
manifest, then file bodies in manifest order. No compression, links or offsets.
Hashes detect damage; they are not publisher signatures or proof of ownership.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import tempfile
from typing import BinaryIO

from protector_native.executable_truth import RBNEG9_DOL_SHA256

MAGIC = b"PNCONT1\n"
SCHEMA = "protector-native.personal-content/v1"
MAX_MANIFEST = 32 * 1024 * 1024
MAX_PAYLOAD = 64 * 1024**3
BLOCK = 1024 * 1024
ROOTS = ("Game", "RestoredArt", "EnhancedModels", "RestoredCinematics")
REQUIRED = ("Game/sys/main.dol", "Game/sys/fst.bin", "RestoredArt/pack.json",
            "EnhancedModels/geometry.json", "RestoredCinematics/cinematics.json")
ENHANCEMENTS = {
    "RestoredArt": ("pack.json", "protector-native.texture-pack/v6", 2221),
    "EnhancedModels": ("geometry.json", "protector-native.geometry-pack/v1", 194),
    "RestoredCinematics": ("cinematics.json", "protector-native.cinematic-pack/v2", 76),
}


class ContentError(ValueError):
    pass


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def digest_file(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def checked_path(value: object) -> str:
    if not isinstance(value, str) or not value or len(value) > 1024:
        raise ContentError("Invalid content path")
    parts = value.split("/")
    if (len(parts) < 2 or parts[0] not in ROOTS or
            any(p in ("", ".", "..") or len(p) > 255 for p in parts) or
            any(ord(c) < 32 or ord(c) > 126 or c in "\\:" for c in value)):
        raise ContentError(f"Unsafe content path: {value!r}")
    return value


def validate_manifest(manifest: object) -> dict:
    if not isinstance(manifest, dict):
        raise ContentError("Content manifest is not an object")
    if (manifest.get("schema") != SCHEMA or manifest.get("source_dol_sha256") != RBNEG9_DOL_SHA256
            or type(manifest.get("runtime_version")) is not int or manifest["runtime_version"] != 1):
        raise ContentError("Content is not compatible with this RBNEG9 runtime")
    files = manifest.get("files")
    if not isinstance(files, list) or not 1 <= len(files) <= 100000:
        raise ContentError("Invalid file count")
    seen: set[str] = set()
    total = 0
    for item in files:
        if not isinstance(item, dict) or set(item) != {"path", "bytes", "sha256"}:
            raise ContentError("Invalid file record")
        name = checked_path(item["path"])
        folded = name.casefold()
        if folded in seen:
            raise ContentError("Duplicate or case-colliding content path")
        seen.add(folded)
        size = item["bytes"]
        if type(size) is not int or not 0 <= size <= MAX_PAYLOAD:
            raise ContentError("Invalid file size")
        if not isinstance(item["sha256"], str) or not re.fullmatch("[0-9a-f]{64}", item["sha256"]):
            raise ContentError("Invalid file hash")
        total += size
    for name in seen:
        if any(str(parent) in seen for parent in PurePosixPath(name).parents):
            raise ContentError("File/directory collision")
    if any(name not in {item["path"] for item in files} for name in REQUIRED):
        raise ContentError("All enhanced content classes are required")
    dol = next(item for item in files if item["path"] == REQUIRED[0])
    if dol["sha256"] != RBNEG9_DOL_SHA256:
        raise ContentError("Unsupported original executable")
    if total > MAX_PAYLOAD or type(manifest.get("payload_bytes")) is not int or manifest["payload_bytes"] != total:
        raise ContentError("Invalid payload total")
    expected = hashlib.sha256(canonical(files)).hexdigest()
    if manifest.get("content_id") != expected:
        raise ContentError("Content identity does not match the file manifest")
    return manifest


def inventory(roots: dict[str, Path]) -> dict:
    if set(roots) != set(ROOTS):
        raise ContentError("Provide Game, RestoredArt, EnhancedModels and RestoredCinematics roots")
    files = []
    for label in ROOTS:
        root = roots[label]
        if root.is_symlink() or not root.is_dir():
            raise ContentError(f"Not a real content directory: {label}")
        for path in sorted(root.rglob("*")):
            if path.is_symlink():
                raise ContentError(f"Links are not content files: {path}")
            if path.is_dir():
                continue
            if not path.is_file():
                raise ContentError(f"Not a regular file: {path}")
            name = checked_path(f"{label}/{path.relative_to(root).as_posix()}")
            files.append({"path": name, "bytes": path.stat().st_size, "sha256": digest_file(path)})
    files.sort(key=lambda item: item["path"])
    # For production packages, bind the entire original partition, not just DOL.
    # Unit fixtures patch the DOL constant and never qualify as real packages.
    from protector_native.executable_truth import RBNEG9_DOL_SHA256 as production_dol
    if RBNEG9_DOL_SHA256 == production_dol:
        lock = json.loads((Path(__file__).resolve().parents[1] / "reference/personal_build_inputs.json").read_text())
        actual_game = {item["path"][5:]: {"bytes": item["bytes"], "sha256": item["sha256"]}
                       for item in files if item["path"].startswith("Game/")}
        expected_game = {key: value for key, value in lock["game"].items()
                         if key.startswith(("sys/", "files/"))}
        # Accept either the runtime sys/files projection used by older packs or
        # the complete pinned nodtool extraction produced by personal_build.
        # Do not ignore arbitrary extras or admit a partial metadata subset.
        if actual_game not in (expected_game, lock["game"]):
            raise ContentError("Original content does not match the complete supported source partition")
        validate_enhancements(roots, files)
    return validate_manifest({"schema": SCHEMA, "runtime_version": 1,
        "source_dol_sha256": RBNEG9_DOL_SHA256, "files": files,
        "payload_bytes": sum(item["bytes"] for item in files),
        "content_id": hashlib.sha256(canonical(files)).hexdigest()})


def validate_enhancements(roots: dict[str, Path], files: list[dict]) -> None:
    table = {item["path"]: item for item in files}
    for label, (filename, schema, count) in ENHANCEMENTS.items():
        path = roots[label] / filename
        if path.stat().st_size > MAX_MANIFEST:
            raise ContentError(f"Oversized enhanced manifest: {label}")
        pack = json.loads(path.read_text())
        if (not isinstance(pack, dict) or pack.get("schema") != schema or
                pack.get("title_dol_sha256") != RBNEG9_DOL_SHA256 or
                not isinstance(pack.get("entries"), list) or len(pack["entries"]) != count):
            raise ContentError(f"Incomplete or unsupported enhanced manifest: {label}")
        for entry in pack["entries"]:
            if not isinstance(entry, dict):
                raise ContentError(f"Invalid enhanced entry: {label}")
            if label == "EnhancedModels":
                continue  # Geometry is inline; the runtime validates its stencils.
            if label == "RestoredArt":
                resource = entry.get("replacement", {})
                relative, identity, size = (resource.get(key) for key in ("path", "sha256", "byte_length"))
            else:
                relative, identity, size = (entry.get(key) for key in ("video", "video_sha256", "video_bytes"))
            if not isinstance(relative, str):
                raise ContentError("Enhanced asset reference is invalid")
            name = checked_path(f"{label}/{relative}")
            item = table.get(name)
            if not item or item["sha256"] != identity or item["bytes"] != size:
                raise ContentError(f"Enhanced asset is absent or mismatched: {name}")


def read_manifest(stream: BinaryIO) -> dict:
    header = stream.read(16)
    if len(header) != 16 or header[:8] != MAGIC:
        raise ContentError("Not a Protector content package")
    size, = struct.unpack("<Q", header[8:])
    if not 0 < size <= MAX_MANIFEST:
        raise ContentError("Manifest exceeds the safety limit")
    data = stream.read(size)
    if len(data) != size:
        raise ContentError("Truncated content manifest")
    try:
        return validate_manifest(json.loads(data))
    except (UnicodeError, json.JSONDecodeError, RecursionError) as exc:
        raise ContentError("Unreadable content manifest") from exc


def copy_verified(source: BinaryIO, item: dict, target: BinaryIO | None = None) -> None:
    remaining = item["bytes"]
    digest = hashlib.sha256()
    while remaining:
        block = source.read(min(BLOCK, remaining))
        if not block:
            raise ContentError(f"Truncated file: {item['path']}")
        remaining -= len(block)
        digest.update(block)
        if target is not None:
            target.write(block)
    if digest.hexdigest() != item["sha256"]:
        raise ContentError(f"Corrupt file: {item['path']}")


def write_package(roots: dict[str, Path], output: Path) -> dict:
    if output.exists() or output.is_symlink():
        raise ContentError("Refusing to overwrite an existing package")
    for root in roots.values():
        if output.resolve().is_relative_to(root.resolve()):
            raise ContentError("Package output must be outside source content")
    manifest = inventory(roots)
    encoded = canonical(manifest)
    if len(encoded) > MAX_MANIFEST:
        raise ContentError("Manifest exceeds the safety limit")
    if shutil.disk_usage(output.parent).free < manifest["payload_bytes"] + len(encoded) + 64 * BLOCK:
        raise ContentError("Not enough free space to create the content package")
    fd, temporary = tempfile.mkstemp(prefix=".protector-content-", dir=output.parent)
    temp = Path(temporary)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(MAGIC + struct.pack("<Q", len(encoded)) + encoded)
            for item in manifest["files"]:
                label, relative = item["path"].split("/", 1)
                path = roots[label] / relative
                if path.is_symlink() or not path.resolve().is_relative_to(roots[label].resolve()):
                    raise ContentError("Content source changed during packaging")
                with path.open("rb") as source:
                    copy_verified(source, item, stream)
                    if source.read(1):
                        raise ContentError("Content source grew during packaging")
            stream.flush()
            os.fsync(stream.fileno())
        # Exclusive publication: never replace someone else's output after a race.
        os.link(temp, output)
    finally:
        temp.unlink(missing_ok=True)
    return manifest


def verify_package(path: Path) -> dict:
    with path.open("rb") as stream:
        manifest = read_manifest(stream)
        for item in manifest["files"]:
            copy_verified(stream, item)
        if stream.read(1):
            raise ContentError("Unexpected trailing content")
    return manifest
