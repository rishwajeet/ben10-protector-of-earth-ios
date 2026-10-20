#!/usr/bin/env python3
"""Acquire pinned public tools and build the personal recompiler outside Git.

No game download, shell installer, package-manager mutation, model download,
Apple-account access or signing occurs. CMake, Ninja and full Xcode are host
prerequisites. Downloaded upstream sources remain intact beside local binaries.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.personal_build import BuildError, doctor, file_table, outside_repo, run, write_json

SOURCES = ROOT / "reference/personal_tool_sources.json"


def fetch(path, record):
    if path.is_symlink():
        raise BuildError("Tool download path is a link")
    if path.exists():
        if path.stat().st_size != record["bytes"] or digest_file(path) != record["sha256"]:
            raise BuildError("Existing download does not match the pinned official resource")
        return path.read_bytes()
    if not 0 < record["bytes"] <= 32 * 1024**2 or not record["url"].startswith("https://"):
        raise BuildError("Invalid bounded HTTPS tool resource")
    print(f"Fetching pinned resource: {path.name}", flush=True)
    with urllib.request.urlopen(record["url"], timeout=45) as response:
        data = response.read(record["bytes"] + 1)
    if len(data) != record["bytes"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
        raise BuildError("Downloaded resource differs from its expected size/hash")
    with path.open("xb") as stream:
        stream.write(data)
    return data


def source_members(data, prefix):
    """Validate the complete archive before creating any source file."""
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        members = archive.getmembers()
        if len(members) > 4096:
            raise BuildError("Source archive member count exceeds its bound")
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != prefix:
                raise BuildError("Source archive escapes its pinned root")
            if member.isdir():
                continue
            if not member.isfile() or len(path.parts) < 2 or not 0 <= member.size <= 8 * 1024**2:
                raise BuildError("Unsupported link or oversized source archive member")
            relative = PurePosixPath(*path.parts[1:]).as_posix()
            if relative in files:
                raise BuildError("Repeated source archive member")
            with archive.extractfile(member) as stream:
                files[relative] = stream.read()
            if len(files[relative]) != member.size:
                raise BuildError("Truncated source archive member")
    if sum(map(len, files.values())) > 64 * 1024**2 or "CMakeLists.txt" not in files or "LICENSE" not in files:
        raise BuildError("Incomplete or excessive upstream source archive")
    return files


def verify_toolchain(work):
    work = outside_repo(work)
    receipt = json.loads((work / "toolchain.json").read_text())
    if receipt.get("schema") != "protector-native.personal-toolchain/v1" or \
            receipt.get("sources_sha256") != digest_file(SOURCES):
        raise BuildError("Toolchain belongs to another source contract")
    pins = json.loads(SOURCES.read_text())
    for name, record in pins["resources"].items():
        path = work / "downloads" / name
        if path.is_symlink() or path.stat().st_size != record["bytes"] or digest_file(path) != record["sha256"]:
            raise BuildError("Pinned downloaded tool resource changed")
    source = work / "source"
    if file_table(source) != receipt["source_files"]:
        raise BuildError("Pinned recompiler source tree changed")
    files = source_members((work / "downloads/dolrecomp-source.tar.gz").read_bytes(),
        "DolRecomp-" + pins["dolrecomp_revision"])
    expected = {name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()} for name, data in files.items()}
    if expected != receipt["source_files"]:
        raise BuildError("Toolchain source is not the pinned upstream archive")
    paths = {}
    for name, relative in {"nodtool": "bin/nodtool", "dolrecomp": "build/dolrecomp",
            "astcenc": "bin/astcenc", "coefficients": "downloads/dsp_coef.bin"}.items():
        path = work / relative
        if path.is_symlink() or digest_file(path) != receipt["binaries"][name]["sha256"]:
            raise BuildError("Locally qualified tool binary changed")
        paths[name] = path
    if receipt["binaries"]["nodtool"]["sha256"] != pins["resources"]["nodtool"]["sha256"] or \
            receipt["binaries"]["astcenc"]["sha256"] != pins["resources"]["astcenc.zip"]["binary_sha256"] or \
            receipt["binaries"]["coefficients"]["sha256"] != pins["resources"]["dsp_coef.bin"]["sha256"]:
        raise BuildError("Public tool binary identity differs")
    return paths


def bootstrap(work, jobs):
    host = doctor()
    if type(jobs) is not int or not 1 <= jobs <= 16:
        raise BuildError("Select 1 through 16 build jobs")
    work = outside_repo(work)
    if work.exists() and (work / "toolchain.json").is_file():
        paths = verify_toolchain(work)
        return {"status": "verified-existing-toolchain", "tools": {k: str(v) for k, v in paths.items()}}
    if not work.parent.is_dir() or shutil.disk_usage(work.parent).free < 2 * 1024**3:
        raise BuildError("Tool bootstrap needs an existing parent with 2 GiB free")
    pins = json.loads(SOURCES.read_text())
    owner = {"schema": "protector-native.personal-tool-bootstrap/v1", "sources_sha256": digest_file(SOURCES)}
    if work.exists():
        if work.is_symlink() or json.loads((work / "owner.json").read_text()) != owner:
            raise BuildError("Incomplete tool directory does not belong to this bootstrap")
    else:
        work.mkdir(mode=0o700)
        write_json(work / "owner.json", owner)
    downloads, source, bins = work / "downloads", work / "source", work / "bin"
    for path in (downloads, source, bins):
        if path.is_symlink():
            raise BuildError("Tool bootstrap directory is a link")
        path.mkdir(mode=0o700, exist_ok=True)
    data = {name: fetch(downloads / name, record) for name, record in pins["resources"].items()}
    members = source_members(data["dolrecomp-source.tar.gz"], "DolRecomp-" + pins["dolrecomp_revision"])
    for name, contents in members.items():
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            if path.is_symlink() or digest_file(path) != hashlib.sha256(contents).hexdigest():
                raise BuildError("Partially extracted upstream source changed")
            continue
        with path.open("xb") as stream:
            stream.write(contents)
    expected_source = {name: {"bytes": len(contents), "sha256": hashlib.sha256(contents).hexdigest()}
        for name, contents in members.items()}
    if file_table(source) != expected_source:
        raise BuildError("Unexpected file in pinned upstream source")
    with zipfile.ZipFile(io.BytesIO(data["astcenc.zip"])) as archive:
        if archive.namelist() != ["bin/astcenc"] or archive.getinfo("bin/astcenc").file_size > 8 * 1024**2:
            raise BuildError("ASTC archive layout differs")
        astc = archive.read("bin/astcenc")
    if hashlib.sha256(astc).hexdigest() != pins["resources"]["astcenc.zip"]["binary_sha256"]:
        raise BuildError("ASTC encoder binary identity differs")
    for name, contents in (("nodtool", data["nodtool"]), ("astcenc", astc)):
        path = bins / name
        if path.exists():
            if path.is_symlink() or digest_file(path) != hashlib.sha256(contents).hexdigest():
                raise BuildError("Partially installed tool binary changed")
        else:
            with path.open("xb") as stream:
                stream.write(contents)
        path.chmod(0o700)
    if (work / "build").is_symlink():
        raise BuildError("Tool build directory is a link")
    run(["cmake", "-S", source, "-B", work / "build", "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release", "-DDOLRECOMP_ENABLE_LLVM=OFF"])
    run(["cmake", "--build", work / "build", "--parallel", str(jobs)])
    run(["ctest", "--test-dir", work / "build", "--output-on-failure", "--parallel", str(jobs)])
    paths = {"nodtool": bins / "nodtool", "dolrecomp": work / "build/dolrecomp",
        "astcenc": bins / "astcenc", "coefficients": downloads / "dsp_coef.bin"}
    result = {"schema": "protector-native.personal-toolchain/v1", "sources_sha256": digest_file(SOURCES),
        "host": host, "source_files": file_table(source),
        "binaries": {k: {"path": str(v.relative_to(work)), "sha256": digest_file(v)} for k, v in paths.items()},
        "scope": "Pinned upstream tools acquired and recompiler source built/tested locally; exact personal-game translation is still checked by prepare"}
    write_json(work / "toolchain.json", result)
    verify_toolchain(work)
    return {"status": "built-and-verified-toolchain", "tools": {k: str(v) for k, v in paths.items()},
        "dolrecomp_sha256": result["binaries"]["dolrecomp"]["sha256"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    try:
        print(json.dumps(bootstrap(args.work_dir, args.jobs), indent=2))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(2, f"Tool bootstrap: {error}\n")


if __name__ == "__main__":
    main()
