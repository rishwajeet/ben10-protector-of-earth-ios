#!/usr/bin/env python3
"""Build and run the RBNEG9 entry chunk as native ARM64 code on Darwin."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from protector_native.executable_truth import RBNEG9_DOL_SHA256

GENERATED_HEADER_SHA256 = (
    "f75a67694bfd048fd3a10c01957070ed66708b81bcd3b5810bd729bbb69279b9"
)
GENERATED_ENTRY_CHUNK_SHA256 = (
    "3209d3b283145e501f054bc9adb28fcb96311ae2b8e8f29589f231cf0e4a4d47"
)
ENTRY_CHUNK = "chunks/chunk_0000_text0_80004000.c"
BOOT_INTERNAL_HOST_HOOKS = (
    0x80017D2C,  # original sphere visibility: horizontal extents ready
    0x800233C4,  # static map visibility result, before render admission
    0x800169C4,  # first game asset request
    0x800372E0,  # first instruction after logical-update counter store
    0x800396E8,  # first instruction after the final frame-delta write
    0x800396EC,  # post-store update-entry fencepost
    0x80039774,  # post-game-update, pre-render logical checkpoint
    0x80039868,  # translated render/presentation loop backedge
    0x8000E3FC,  # controller-manager call instruction
    0x8000F910,  # title controller-manager update
    0x8000F9B8,  # title controller-manager channel reconciliation
    0x8000F988,  # controller-update call instruction
    0x800B5A44,  # title controller update
    0x800B5ACC,  # first instruction after the title's KPADRead call
    0x800B8BC8,  # packaged save banner/icon loader
    0x800B8D38,  # save metadata initialization
    0x800B917C,  # save object constructor
    0x800B91D8,  # save manager initialization entry
    0x800B9264,  # save manager asynchronous load entry
    0x800B92B4,  # return from NANDOpen during asynchronous load
    0x800B9364,  # return from NANDGetStatus during asynchronous load
    0x800B493C,  # script MemcardLoad wrapper
    0x800B4928,  # script MemcardSave wrapper
    0x800B4994,  # script MemcardLoadSlot wrapper
    0x800B4950,  # script MemcardSaveSlot wrapper
    0x800A74E4,  # game script VM instruction dispatch
    0x800A92D0,  # indirect game-script built-in call variant 1
    0x800A92EC,  # indirect game-script built-in call variant 2
    0x800A9308,  # indirect game-script built-in call variant 3
    0x800A933C,  # indirect game-script built-in call variant 4
    0x8004488C,  # DisplayText string argument; retain draw/reset/return path
    0x8003E5EC,  # ass_AnimLooped diagnostic entry
    0x8003E62C,  # ass_AnimBlendWeight diagnostic entry
    0x8003E74C,  # ass_AnimBlend diagnostic entry
    0x8003E7B4,  # ass_AnimLength diagnostic entry
    0x8003E814,  # ass_AnimatingNextFrame diagnostic entry
    0x8003E850,  # ass_AnimBlendingOut diagnostic entry
    0x8003E8FC,  # ass_AnimPlaying diagnostic entry
    0x8003E91C,  # ass_AnimPlaying result writeback
    0x8003E934,  # ass_AnimTime diagnostic entry
    0x8003E960,  # ass_AnimTime result writeback
    0x8003E988,  # ass_AnimWeight diagnostic entry
    0x80094688,  # script property query selected by opcode 0x81
    0x8004A76C,  # script property query result writeback
    0x800A858C,  # game script VM global-variable write
    0x8009D10C,  # collision/contact event-table scan
    0x800A130C,  # collision/contact event-node allocation
    0x8009D1B4,  # collision/contact event-head writeback
    0x8009D1DC,  # script event dispatch
    0x800A1150,  # script event node creation
    0x8009D298,  # script event node creation return
    0x800492E8,  # script-spawn helper return
    0x80049414,  # spawn_after result in r3, before wrapper epilogue
    0x80067E14,  # sound_play_1 result after the sound-manager call
    0x8006DF9C,  # sound-manager allocation result before post-processing
    0x8009E774,  # strategy script-VM pointer assignment
    0x8009E4EC,  # strategy script-VM pointer clear
    0x800CCAD8,  # DVDReadAsyncPrio
    0x800CCBC0,  # DVDReadPrio
    0x800CCCF0,  # DVDSeekAsyncPrio
    0x800C1D00,  # DisableWriteGatherPipe
    0x800CAD98,  # __OSInitPlayTime
    0x800CADA8,  # return from NANDInit during __OSInitPlayTime
    0x800CA404,  # __OSInitSTM
    0x800CB1E0,  # __OSInitNet
    0x800CCE60,  # DVDInit
    0x800C26C8,  # OSLoadContext checkpoint
    0x800C99D0,  # OSSleepThread checkpoint
    0x800D49A4,  # VIWaitForRetrace
    0x800E2BE4,  # DSPAddTask
    0x8010AB8C,  # SCInit
    0x8010AC2C,  # SCCheckStatus
    0x801090A8,  # NANDGetStatus
    0x801095D4,  # NANDOpen
    0x80109854,  # NANDClose
    0x80109EC4,  # NANDInit
    0x8010F540,  # KPADRead
    0x801134E0,  # WPADProbe-shaped seam
    0x8011356C,  # WPADRead-shaped seam
    0x8014CCCC,  # WUDInit
    0x8014CF9C,  # WUDGetStatus
    0x8014FF88,  # IUSB_OpenDeviceIds
    0x80182AE0,  # BinkOpen
    0x800BB8B8,  # movie continuation result; explicit opening-logo tap skip
)
TRAP_NEEDLE = """label_800042E0:
    ctx->pc = 0x800042E0u;
    ctx->downcount -= 5;
    // 800042E0: mfmsr   r0
    ctx->gpr[0] = ctx->msr;
"""
TRAP_REPLACEMENT = """label_800042E0:
    if (protector_trap_instruction(
            ctx, 0x800042E0u, 0x7C0000A6u,
            "privileged_hardware_state")) {
        return;
    }
    ctx->pc = 0x800042E0u;
    ctx->downcount -= 5;
    // 800042E0: mfmsr   r0
    ctx->gpr[0] = ctx->msr;
"""


class NativeEntryError(RuntimeError):
    """Raised when an external input or native proof step fails."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require_hash(path: Path, expected: str, label: str) -> None:
    actual = sha256(path)
    if actual != expected:
        raise NativeEntryError(
            f"{label} SHA-256 mismatch: expected {expected}, got {actual}"
        )


def run(command: list[str], *, cwd: Path | None = None) -> None:
    print("+", " ".join(command))
    subprocess.run(command, cwd=cwd, check=True)


def write_text_if_changed(path: Path, value: str) -> None:
    # Prepared chunks may be symlinks into the external, ROM-derived
    # dolrecomp cache. Never follow one when materializing a patched chunk:
    # doing so would modify the source cache instead of the build input.
    if path.is_symlink():
        path.unlink()
    elif path.exists() and path.read_text(encoding="utf-8") == value:
        return
    path.write_text(value, encoding="utf-8")


def inject_internal_host_hook(value: str, address: int, chunk_name: str) -> str:
    """Install exactly one host hook at a translated internal label."""
    label = f"label_{address:08X}:"
    if label not in value:
        return value
    hook_line = (
        f"    if (ctx->host_call && ppc_host_call(ctx, 0x{address:08X}u)) return;"
    )
    # Normalize output from an interrupted/older preparation run before
    # deciding whether a hook already exists.
    lines = value.splitlines()
    normalized: list[str] = []
    hook_seen = False
    for line in lines:
        if line == hook_line:
            if hook_seen:
                continue
            hook_seen = True
        normalized.append(line)
    value = "\n".join(normalized) + ("\n" if value.endswith("\n") else "")
    if hook_seen:
        return value
    label_count = value.count(label)
    if label_count == 1:
        return value.replace(label, f"{label}\n{hook_line}")
    loop_marker = (
        f"static void loop_{address:08X}(CPUState* ctx) {{\n{label}"
    )
    if label_count > 1 and value.count(loop_marker) == 1:
        return value.replace(
            loop_marker,
            f"{loop_marker}\n{hook_line}",
        )
    if label_count != 1:
        raise NativeEntryError(f"internal hook {label} is not unique in {chunk_name}")
    raise NativeEntryError(f"internal hook {label} is missing in {chunk_name}")


def prepare_generated(
    source: Path,
    destination: Path,
    *,
    include_all_chunks: bool = False,
    internal_host_hooks: tuple[int, ...] = (),
) -> None:
    header = source / "RBNEG9.h"
    chunk = source / ENTRY_CHUNK
    require_hash(header, GENERATED_HEADER_SHA256, "RBNEG9 generated header")
    require_hash(
        chunk,
        GENERATED_ENTRY_CHUNK_SHA256,
        "RBNEG9 generated entry chunk",
    )

    value = chunk.read_text(encoding="utf-8")
    if value.count(TRAP_NEEDLE) != 1:
        raise NativeEntryError("entry chunk does not contain the exact trap site")
    patched = value.replace(TRAP_NEEDLE, TRAP_REPLACEMENT)

    (destination / "chunks").mkdir(parents=True, exist_ok=True)
    destination_header = destination / "RBNEG9.h"
    if (
        not destination_header.exists()
        or sha256(destination_header) != GENERATED_HEADER_SHA256
    ):
        shutil.copyfile(header, destination_header)
    prepared_chunks = {Path(ENTRY_CHUNK).name: patched}
    if include_all_chunks:
        chunks = tuple(sorted((source / "chunks").glob("*.c")))
        if len(chunks) != 120:
            raise NativeEntryError(
                f"full RBNEG9 translation requires 120 chunks, found {len(chunks)}"
            )
        missing_hooks = set(internal_host_hooks)
        for source_chunk in chunks:
            value = prepared_chunks.get(source_chunk.name)
            if value is None and internal_host_hooks:
                value = source_chunk.read_text(encoding="utf-8")
            if value is not None:
                for address in internal_host_hooks:
                    label = f"label_{address:08X}:"
                    if label not in value:
                        continue
                    value = inject_internal_host_hook(value, address, source_chunk.name)
                    missing_hooks.discard(address)
                if source_chunk.name in prepared_chunks or any(
                    f"ppc_host_call(ctx, 0x{address:08X}u)" in value
                    for address in internal_host_hooks
                ):
                    prepared_chunks[source_chunk.name] = value
            if source_chunk.name in prepared_chunks:
                continue
            destination_chunk = destination / "chunks" / source_chunk.name
            if (
                destination_chunk.is_symlink()
                and destination_chunk.resolve() == source_chunk.resolve()
            ):
                continue
            if destination_chunk.exists() or destination_chunk.is_symlink():
                destination_chunk.unlink()
            destination_chunk.symlink_to(source_chunk)
        if missing_hooks:
            formatted = ", ".join(
                f"0x{address:08X}" for address in sorted(missing_hooks)
            )
            raise NativeEntryError(
                f"generated translation is missing internal hooks: {formatted}"
            )

    for chunk_name, chunk_value in prepared_chunks.items():
        write_text_if_changed(
            destination / "chunks" / chunk_name,
            chunk_value,
        )


def validate_trace(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    expected = {
        "schema": "protector-native-entry-trace-v1",
        "revision": "RBNEG9",
        "material_state_match": True,
        "exceptions": 0,
    }
    for key, wanted in expected.items():
        if value.get(key) != wanted:
            raise NativeEntryError(
                f"trace {key} mismatch: expected {wanted!r}, got {value.get(key)!r}"
            )
    if value["host"] != {
        "platform": "darwin",
        "architecture": "arm64",
        "jit": False,
    }:
        raise NativeEntryError(f"unexpected native host proof: {value['host']!r}")
    if value["stop"] != {
        "reason": "host_service",
        "pc": "0x800042E0",
        "instruction": "0x7C0000A6",
        "service": "privileged_hardware_state",
    }:
        raise NativeEntryError(f"unexpected stop proof: {value['stop']!r}")
    if value["memory"]["runtime_writes"] != 0:
        raise NativeEntryError("entry path performed a memory write")
    if value.get("known_zero_registers_match") is not True:
        raise NativeEntryError("entry path changed a known-zero register")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dol", type=Path, required=True)
    parser.add_argument("--generated", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--build-type", default="Release")
    parser.add_argument("--repeat", type=int, default=3)
    args = parser.parse_args()

    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise NativeEntryError("native entry proof requires ARM64 Darwin")
    if args.repeat < 2:
        raise NativeEntryError("--repeat must be at least 2")
    require_hash(args.dol, RBNEG9_DOL_SHA256, "RBNEG9 main.dol")

    repository = Path(__file__).resolve().parents[1]
    prepared = args.output / "prepared-generated"
    build = args.output / "build"
    prepare_generated(args.generated, prepared)

    run(
        [
            "cmake",
            "-S",
            str(repository),
            "-B",
            str(build),
            "-G",
            "Ninja",
            f"-DCMAKE_BUILD_TYPE={args.build_type}",
            f"-DPROTECTOR_GENERATED_DIR={prepared}",
            "-DBUILD_TESTING=ON",
        ]
    )
    run(
        [
            "cmake",
            "--build",
            str(build),
            "--target",
            "protector_entry_harness",
            "protector_runtime_tests",
            "protector_room_tests",
        ]
    )
    run(["ctest", "--test-dir", str(build), "--output-on-failure"])
    executable = build / "protector_entry_harness"
    values: list[dict[str, object]] = []
    for run_index in range(args.repeat):
        run_trace = args.output / f"entry-trace-run-{run_index + 1}.json"
        run([str(executable), "--dol", str(args.dol), str(run_trace)])
        values.append(validate_trace(run_trace))
        print(f"entry checkpoint run {run_index + 1}/{args.repeat}: exact")
    if any(value != values[0] for value in values[1:]):
        raise NativeEntryError("native entry replay checkpoints diverged")
    value = values[0]
    trace = args.output / "entry-trace.json"
    trace.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")

    binary = subprocess.run(
        ["file", str(executable)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if "arm64" not in binary or "Mach-O" not in binary:
        raise NativeEntryError(f"binary is not ARM64 Mach-O: {binary}")
    proof = {
        "schema": "protector-native-build-proof-v1",
        "dol_sha256": sha256(args.dol),
        "generated_header_sha256": GENERATED_HEADER_SHA256,
        "generated_entry_chunk_sha256": GENERATED_ENTRY_CHUNK_SHA256,
        "executable_sha256": sha256(executable),
        "binary": binary,
        "trace": value,
        "replay": {
            "runs": args.repeat,
            "identical": True,
        },
    }
    proof_path = args.output / "build-proof.json"
    proof_path.write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
    print(f"Verified native ARM64 entry; wrote {proof_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
