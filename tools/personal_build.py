#!/usr/bin/env python3
"""Local-only RBNEG9 personal builder. No signing, upload or Apple credentials.

Heavy enhanced-asset reconstruction is a separately admitted recipe stage; this
tool does not claim that existing development packs are portable public inputs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from protector_native.executable_truth import RBNEG9_DOL_SHA256
from tools.build_native_entry import prepare_generated, BOOT_INTERNAL_HOST_HOOKS

TRANSLATOR_REVISION = "6f2336397ad9fde3743a63cf083776d18d38345c"
COEFFICIENTS_HASH = "d7741279c2e8ec5c5fb318f8fbdd6de6bf583520d288e836a5383233a4238179"
LOCK = ROOT / "reference/personal_build_inputs.json"


class BuildError(ValueError):
    pass


def run(arguments, *, cwd=None):
    print("Running:", " ".join(map(str, arguments)), flush=True)
    subprocess.run(list(map(str, arguments)), cwd=cwd, check=True)


def outside_repo(path: Path) -> Path:
    result = path.resolve()
    if result == ROOT or result.is_relative_to(ROOT):
        raise BuildError("Personal inputs and outputs must remain outside the source repository")
    return result


def write_json(path: Path, value):
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def file_table(root: Path) -> dict:
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise BuildError(f"Unexpected symbolic link: {path}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise BuildError(f"Not a regular file: {path}")
        result[path.relative_to(root).as_posix()] = {"bytes": path.stat().st_size, "sha256": digest_file(path)}
    return result


def check_table(root: Path, expected: dict, *, exact=True):
    actual = file_table(root)
    for name, record in expected.items():
        if actual.get(name) != record:
            raise BuildError(f"Source identity mismatch: {name}")
    if exact and set(actual) != set(expected):
        raise BuildError("Unexpected files in admitted source tree")


def cinematic_doctor():
    """Inspect advertised preparation capabilities without opening media/models."""
    binaries = {name: shutil.which(name) for name in ('ffmpeg', 'ffprobe')}
    missing = [name for name, path in binaries.items() if not path]
    if missing:
        raise BuildError('Cinematic preparation requires external tools on PATH: ' + ', '.join(missing))

    def query(name, *arguments):
        try:
            return subprocess.check_output([binaries[name], '-hide_banner', *arguments],
                text=True, stderr=subprocess.STDOUT, timeout=15).strip()
        except (OSError, subprocess.SubprocessError) as error:
            raise BuildError(f'Cinematic preflight could not inspect {name}: {error}') from error

    versions = {}
    for name in binaries:
        version = query(name, '-version').splitlines()
        if not version or not version[0].startswith(name + ' version '):
            raise BuildError(f'Cinematic preflight received no valid version from {name}')
        versions[name] = version[0]
    capabilities = {}
    for option, required in {
        '-decoders': {'binkvideo', 'hevc'},
        '-encoders': {'hevc_videotoolbox'},
        '-filters': {'bwdif', 'split', 'blend', 'scale', 'format', 'setsar'},
        '-bsfs': {'hevc_metadata'},
        '-hwaccels': {'videotoolbox'},
    }.items():
        listing = query('ffmpeg', option)
        if option in ('-bsfs', '-hwaccels'):
            available = {line.strip() for line in listing.splitlines()}
        else:
            available = set(re.findall(r'^\s*[A-Z.]{2,6}\s+(\S+)\s', listing, re.MULTILINE))
        missing = required - available
        if missing:
            raise BuildError(f'FFmpeg {option} missing required capabilities: ' + ', '.join(sorted(missing)))
        capabilities[option.lstrip('-')] = sorted(required)
    return {'status': 'advertised-capabilities-present', 'versions': versions,
            'capabilities': capabilities, 'python_version': platform.python_version(),
            'media_opened': False, 'models_loaded': False,
            'limitations': ['Not a hardware encoder execution or output-quality test.',
                           'Does not qualify memory, disk budget, model rights or all-library replay.']}


def doctor(*, cinematics=False):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise BuildError("The first supported build host is an Apple Silicon Mac")
    result = {"host": platform.platform(), "machine": platform.machine()}
    for key, command in {
        "xcode": ["xcodebuild", "-version"], "iphone_sdk": ["xcrun", "--sdk", "iphoneos", "--show-sdk-version"],
        "cmake": ["cmake", "--version"], "ninja": ["ninja", "--version"],
    }.items():
        result[key] = subprocess.check_output(command, text=True).strip()
    if "Xcode" not in result["xcode"]:
        raise BuildError("Full Xcode is required; Command Line Tools alone are insufficient")
    if cinematics:
        result['cinematic_preflight'] = cinematic_doctor()
    return result


def finish_preparation(work: Path, image: Path, host: dict, lock: dict):
    check_table(work / "extracted", lock["game"])
    generated = work / "translation/RBNEG9_generated"
    check_table(generated, lock["generated"], exact=False)
    if len(list((generated / "chunks").glob("*.c"))) != 120:
        raise BuildError("Translation did not produce exactly 120 chunks")
    prepared = work / "prepared-generated"
    prepare_generated(generated, prepared, include_all_chunks=True, internal_host_hooks=BOOT_INTERNAL_HOST_HOOKS)
    # The developer helper links unmodified chunks. A personal build must be
    # self-contained and its input manifest must not allow arbitrary links.
    for path in prepared.rglob("*"):
        if path.is_symlink():
            source = path.resolve()
            if not source.is_relative_to(generated.resolve()) or not source.is_file():
                raise BuildError("Prepared code links outside the verified translation")
            temporary = path.with_name(path.name + ".materialize")
            with temporary.open("xb") as output, source.open("rb") as original:
                shutil.copyfileobj(original, output)
            temporary.replace(path)
    write_json(work / "neutral-kpad.json", {"schema": "protector-native.neutral-kpad/v1"})
    write_json(work / "prepared.json", {"schema": "protector-native.personal-prepared/v1", "host": host,
        "source_dol_sha256": RBNEG9_DOL_SHA256, "input_sha256": digest_file(image),
        "lock_sha256": digest_file(LOCK), "prepared": file_table(prepared)})
    return {"prepared": str(work), "next": "build", "enhancements": "separate recipe work still required"}


def resume_preparation(args):
    work = outside_repo(args.work_dir)
    owner = json.loads((work / "owner.json").read_text())
    if owner.get("schema") != "protector-native.personal-build/v1":
        raise BuildError("Not a personal-builder work directory")
    return finish_preparation(work, outside_repo(Path(owner["input"])), doctor(), json.loads(LOCK.read_text()))


def prepare(args):
    host = doctor()
    lock = json.loads(LOCK.read_text())
    image = outside_repo(args.input)
    if not image.is_file() or image.is_symlink() or image.suffix.lower() not in (".iso", ".rvz"):
        raise BuildError("Choose a local, regular ISO or RVZ file of supported RBNEG9")
    work = outside_repo(args.work_dir)
    if work.exists():
        raise BuildError("Prepare requires a new work directory; use build to resume prepared work")
    if not work.parent.is_dir() or shutil.disk_usage(work.parent).free < 8 * 1024**3:
        raise BuildError("Prepare needs an existing output parent with at least 8 GiB free (enhancements need more)")
    for label, tool in (("nodtool", args.nodtool), ("dolrecomp", args.dolrecomp)):
        if digest_file(tool) != lock["tools"][label]["sha256"]:
            raise BuildError(f"Unqualified {label} binary; this local lock must be qualified for a new toolchain build")
    work.mkdir(mode=0o700)
    write_json(work / "owner.json", {"schema": "protector-native.personal-build/v1", "input": str(image)})
    extracted = work / "extracted"
    run([args.nodtool.resolve(), "extract", "--validate", "--partition", "data", image, extracted])
    if digest_file(extracted / "sys/main.dol") != RBNEG9_DOL_SHA256:
        raise BuildError("This game region or revision is not supported")
    check_table(extracted, lock["game"])
    (work / "database").mkdir()
    # The pinned recompiler otherwise silently enters titleless GameCube mode.
    (work / "database/titles.txt").write_text("RBNEG9 = Ben 10 - Protector of Earth\n")
    raw = work / "translation"
    run([args.dolrecomp.resolve(), "--cpu", "broadway", "-j", str(args.jobs),
         extracted / "sys/main.dol", "RBNEG9", raw], cwd=work)
    return finish_preparation(work, image, host, lock)


DEFAULT_BUNDLE_ID = "house.machine.ProtectorNative.Original"


def bundle_identifier(value: str) -> str:
    """Your own reverse-DNS ID; keep it identical for every later update."""
    if not isinstance(value, str) or len(value) > 155 or \
            not re.fullmatch(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+", value):
        raise BuildError("Bundle ID must look like com.example.protector")
    return value


def build(args):
    doctor()
    work = outside_repo(args.work_dir)
    receipt = json.loads((work / "prepared.json").read_text())
    if receipt.get("schema") != "protector-native.personal-prepared/v1" or receipt.get("lock_sha256") != digest_file(LOCK):
        raise BuildError("Prepared work does not match this builder's admission lock")
    lock = json.loads(LOCK.read_text())
    check_table(work / "extracted", lock["game"])
    check_table(work / "prepared-generated", receipt["prepared"])
    coefficients = outside_repo(args.coefficients)
    if coefficients.stat().st_size != 4096 or digest_file(coefficients) != COEFFICIENTS_HASH:
        raise BuildError("DSP coefficients are not the admitted free replacement table")
    build_dir = work / ("build-" + args.sdk)
    icon = []
    if args.authored_inputs:
        uv = shutil.which("uv")
        if not uv:
            raise BuildError("uv is required on PATH to render the app icon")
        run([uv, "run", "--no-project", "--with-requirements", ROOT / "requirements-personal-vectors.lock",
             "python", ROOT / "tools/make_app_icon.py", "--authored-inputs", args.authored_inputs,
             "--output", work / "app-icon"])
        icon = [f"-DPROTECTOR_IOS_ICON_CATALOG={work / 'app-icon/Assets.xcassets'}"]
    run(["cmake", "-S", ROOT, "-B", build_dir, "-G", "Ninja",
        "-DCMAKE_SYSTEM_NAME=iOS", f"-DCMAKE_OSX_SYSROOT={args.sdk}", "-DCMAKE_OSX_ARCHITECTURES=arm64",
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0", "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_TESTING=OFF",
        "-DPROTECTOR_BUILD_IOS_INTERACTIVE=ON", "-DPROTECTOR_ENABLE_LTO=ON",
        "-DPROTECTOR_IOS_EXTERNAL_CONTENT=ON", "-DPROTECTOR_IOS_CODE_SIGNING_ALLOWED=OFF",
        f"-DPROTECTOR_IOS_BUNDLE_IDENTIFIER={bundle_identifier(args.bundle_id)}",
        f"-DPROTECTOR_GENERATED_DIR={work / 'prepared-generated'}",
        f"-DPROTECTOR_IOS_DATA_ROOT={work / 'extracted'}",
        f"-DPROTECTOR_IOS_KPAD_REFERENCE={work / 'neutral-kpad.json'}",
        f"-DPROTECTOR_AX_COEFFICIENTS_FILE={coefficients}", *icon])
    run(["cmake", "--build", build_dir, "--target", "protector_ios_interactive", "-j", args.jobs])
    app = build_dir / "protector_ios_interactive.app"
    for directory in ("Game", "RestoredArt", "EnhancedModels", "RestoredCinematics"):
        if (app / directory).exists():
            raise BuildError("Content separation failed: large data was copied into the app")
    return {"app": str(app), "sdk": args.sdk, "signed_for_installation": False,
            "app_icon": (app / "Assets.car").is_file(), "files": file_table(app)}


def package_ipa(app: Path, output: Path):
    import plistlib
    app = outside_repo(app)
    output = outside_repo(output)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("DTPlatformName") != "iphoneos":
        raise BuildError("Only an iPhone device application can be packaged as an IPA")
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or Path(executable).name != executable:
        raise BuildError("The application executable name is invalid")
    macho = subprocess.check_output(["xcrun", "vtool", "-show-build", str(app / executable)], text=True)
    if not re.search(r"^\s*platform IOS\s*$", macho, re.MULTILINE) or "IOSSIMULATOR" in macho:
        raise BuildError("The executable is not built for a physical iOS device")
    if output.exists() or output.is_symlink():
        raise BuildError("Refusing to overwrite an IPA")
    files = file_table(app)
    if any(name.split("/")[0] in ("Game", "RestoredArt", "EnhancedModels", "RestoredCinematics") for name in files):
        raise BuildError("IPA must not contain the external content payload")
    fd, name = tempfile.mkstemp(prefix=".protector-ipa-", dir=output.parent)
    os.close(fd)
    temporary = Path(name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
            for relative in files:
                archive.write(app / relative, f"Payload/{app.name}/{relative}")
        with zipfile.ZipFile(temporary) as archive:
            bad = archive.testzip()
            if bad:
                raise BuildError(f"IPA verification failed: {bad}")
        os.link(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    return {"ipa": str(output), "bytes": output.stat().st_size, "sha256": digest_file(output),
            "installation": "Requires personal signing; no signing or upload was performed"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    doctor_parser = sub.add_parser("doctor")
    doctor_parser.add_argument('--cinematics', action='store_true',
                              help='Inspect FFmpeg/ffprobe capabilities without processing media or loading models')
    prep = sub.add_parser("prepare")
    for name in ("input", "work-dir", "nodtool", "dolrecomp"):
        prep.add_argument("--" + name, type=Path, required=True)
    prep.add_argument("--jobs", type=int, default=4)
    resume = sub.add_parser("resume-prepare")
    resume.add_argument("--work-dir", type=Path, required=True)
    compile_parser = sub.add_parser("build")
    compile_parser.add_argument("--work-dir", type=Path, required=True)
    compile_parser.add_argument("--coefficients", type=Path, required=True)
    compile_parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"), default="iphoneos")
    compile_parser.add_argument("--jobs", type=int, default=4)
    compile_parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID,
                                help="your own app ID, e.g. com.yourname.protector; never change it between updates")
    compile_parser.add_argument("--authored-inputs", type=Path,
                                help="the verified artwork bundle; renders the app icon from its Omnitrix vectors")
    ipa = sub.add_parser("ipa")
    ipa.add_argument("--app", type=Path, required=True)
    ipa.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if getattr(args, "jobs", 1) < 1:
            raise BuildError("Jobs must be a positive integer")
        result = {"doctor": lambda: doctor(cinematics=args.cinematics), "prepare": lambda: prepare(args),
                  "resume-prepare": lambda: resume_preparation(args),
                  "build": lambda: build(args), "ipa": lambda: package_ipa(args.app, args.output)}[args.command]()
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        parser.exit(2, f"Personal build: {exc}\n")


if __name__ == "__main__":
    main()
