"""Versioned executable-truth records for the RBNEG9 Wii baseline.

The constants in this module are source-only reverse-engineering results.  The
verification tool reads the lawful external DOL, DTK assembly, and DolRecomp
report and proves that those external inputs still support the checked-in map.
"""

from __future__ import annotations

import re
from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

from protector_native.dol import DolImage

EXECUTABLE_TRUTH_SCHEMA = "protector-native-executable-truth-v1"
RBNEG9_DOL_SHA256 = "03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566"
RBNEG9_SMC_SHA256 = "15d362d5e28af64368a45ce7de3922359ddace8f6307fea40c46df072d4d5b8f"


class ExecutableTruthError(ValueError):
    """Raised when external executable evidence disagrees with the truth map."""


@dataclass(frozen=True, order=True)
class AddressRange:
    start: int
    end: int

    def __post_init__(self) -> None:
        if self.start > self.end or self.start % 4 or self.end % 4:
            raise ExecutableTruthError("instruction ranges must be aligned and ordered")

    def addresses(self) -> tuple[int, ...]:
        return tuple(range(self.start, self.end + 1, 4))

    def label(self) -> str:
        return f"0x{self.start:08X}-0x{self.end:08X}"


@dataclass(frozen=True)
class InstructionEvidence:
    address: int
    word: int
    mnemonic: str
    source: str
    line: int


@dataclass(frozen=True)
class WriteDisposition:
    address_range: AddressRange
    function: str
    category: str
    operation: str
    native_disposition: str


@dataclass(frozen=True)
class HostBoundary:
    address: int
    guest_name: str
    service: str
    native_contract: str


@dataclass(frozen=True)
class FirstHostStop:
    address: int
    word: int
    instruction: str
    reason: str
    registers: tuple[tuple[str, int], ...]
    zero_registers: tuple[str, ...]
    memory_writes_since_entry: int
    unknown_registers: tuple[str, ...]


_SMC_RANGE = re.compile(r"^0x(?P<start>[0-9A-Fa-f]{8})-0x(?P<end>[0-9A-Fa-f]{8})$")
_ASM_INSTRUCTION = re.compile(
    r"^/\*\s*(?P<address>[0-9A-Fa-f]{8})\s+[0-9A-Fa-f]{8}\s+"
    r"(?P<bytes>(?:[0-9A-Fa-f]{2}\s+){3}[0-9A-Fa-f]{2})\s*\*/\s*"
    r"(?P<mnemonic>.+?)\s*$"
)


def parse_smc_report(value: str) -> tuple[AddressRange, ...]:
    """Parse DolRecomp's possible-patching range report."""

    ranges: list[AddressRange] = []
    saw_header = False
    for raw_line in value.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line == "possible patching instructions:":
            saw_header = True
            continue
        match = _SMC_RANGE.fullmatch(line)
        if not match:
            raise ExecutableTruthError(f"unrecognized SMC report line: {line!r}")
        ranges.append(
            AddressRange(
                int(match.group("start"), 16),
                int(match.group("end"), 16),
            )
        )
    if not saw_header:
        raise ExecutableTruthError("SMC report header is missing")
    if not ranges:
        raise ExecutableTruthError("SMC report has no instruction ranges")
    if len(set(ranges)) != len(ranges):
        raise ExecutableTruthError("SMC report repeats an instruction range")
    return tuple(ranges)


def parse_dtk_assembly(paths: Iterable[Path]) -> dict[int, InstructionEvidence]:
    """Index DTK instruction comments without retaining the external assembly."""

    instructions: dict[int, InstructionEvidence] = {}
    for path in sorted(paths):
        with path.open(encoding="utf-8") as source:
            for line_number, raw_line in enumerate(source, 1):
                match = _ASM_INSTRUCTION.match(raw_line.rstrip())
                if not match:
                    continue
                address = int(match.group("address"), 16)
                if address in instructions:
                    raise ExecutableTruthError(
                        f"duplicate DTK instruction address 0x{address:08X}"
                    )
                raw_bytes = bytes.fromhex(match.group("bytes"))
                instructions[address] = InstructionEvidence(
                    address=address,
                    word=int.from_bytes(raw_bytes, "big"),
                    mnemonic=match.group("mnemonic"),
                    source=path.name,
                    line=line_number,
                )
    if not instructions:
        raise ExecutableTruthError("no DTK instructions were parsed")
    return instructions


def verify_external_instructions(
    dol: DolImage,
    assembly: dict[int, InstructionEvidence],
    ranges: Iterable[AddressRange],
) -> tuple[InstructionEvidence, ...]:
    """Verify every flagged instruction byte-for-byte against the DOL."""

    evidence: list[InstructionEvidence] = []
    for address_range in ranges:
        for address in address_range.addresses():
            instruction = assembly.get(address)
            if instruction is None:
                raise ExecutableTruthError(
                    f"DTK assembly is missing flagged address 0x{address:08X}"
                )
            actual = dol.u32(address)
            if actual != instruction.word:
                raise ExecutableTruthError(
                    f"DOL/DTK mismatch at 0x{address:08X}: "
                    f"0x{actual:08X} != 0x{instruction.word:08X}"
                )
            evidence.append(instruction)
    return tuple(evidence)


def _range(start: int, end: int | None = None) -> AddressRange:
    return AddressRange(start, start if end is None else end)


WRITE_DISPOSITIONS = (
    WriteDisposition(
        _range(0x80004320),
        "__flush_cache",
        "cache_only",
        "Instruction-cache block invalidate; it does not store a byte.",
        "Host instruction/data cache coherence boundary; no guest code mutation.",
    ),
    WriteDisposition(
        _range(0x800046C8),
        "embedded exception template",
        "cache_only",
        "Instruction-cache block invalidate in a low-level exception template.",
        "Omit with the Wii exception template under the host exception service.",
    ),
    WriteDisposition(
        _range(0x8003F870),
        "fn_8003F86C",
        "ordinary_data",
        "Insert a node into a singly linked list through caller-owned pointers.",
        "Translate as an ordinary data-structure store.",
    ),
    WriteDisposition(
        _range(0x8005C15C),
        "fn_8005B9E4",
        "ordinary_data",
        "Write a switch result to the caller's output word.",
        "Translate as an ordinary output-parameter store.",
    ),
    WriteDisposition(
        _range(0x8005C168),
        "fn_8005B9E4",
        "ordinary_data",
        "Write a switch result to the caller's output word.",
        "Translate as an ordinary output-parameter store.",
    ),
    WriteDisposition(
        _range(0x8005C180),
        "fn_8005B9E4",
        "ordinary_data",
        "Write a switch result to the caller's output word.",
        "Translate as an ordinary output-parameter store.",
    ),
    WriteDisposition(
        _range(0x8009F034),
        "fn_8009F030",
        "ordinary_data",
        "Insert a node into a singly linked list through caller-owned pointers.",
        "Translate as an ordinary data-structure store.",
    ),
    WriteDisposition(
        _range(0x8009F07C),
        "fn_8009F040",
        "ordinary_data",
        "Clamp the Y component of a caller-owned vector.",
        "Translate as an ordinary floating-point data store.",
    ),
    WriteDisposition(
        _range(0x800C0B8C),
        "OSExceptionInit",
        "guest_sdk_code_template",
        "Patch the exception number into the SDK's handler template.",
        "Replace OSExceptionInit with a host exception boundary; never patch translated code.",
    ),
    WriteDisposition(
        _range(0x800C0BE0, 0x800C0BFC),
        "OSExceptionInit",
        "guest_sdk_code_template",
        "Fill the SDK debug-vector template with PowerPC NOP instructions.",
        "Replace OSExceptionInit with a host exception boundary; do not materialize vectors.",
    ),
    WriteDisposition(
        _range(0x800C0C14),
        "OSExceptionInit",
        "guest_sdk_code_template",
        "Finish the SDK debug-vector NOP fill for the remainder count.",
        "Replace OSExceptionInit with a host exception boundary; do not materialize vectors.",
    ),
    WriteDisposition(
        _range(0x800C0CF0),
        "OSExceptionInit",
        "guest_sdk_code_template",
        "Restore the original instruction in the mutable handler template.",
        "Replace OSExceptionInit with a host exception boundary; never patch translated code.",
    ),
    WriteDisposition(
        _range(0x800C20A8),
        "ICInvalidateRange",
        "cache_only",
        "Instruction-cache block invalidate loop; it does not store a byte.",
        "Host instruction/data cache coherence boundary; no guest code mutation.",
    ),
    WriteDisposition(
        _range(0x800D07B8, 0x800D07CC),
        "fn_800D0790",
        "ordinary_data",
        "Initialize fields in a DVD request/control object before queueing it.",
        "Translate as request-structure stores behind the file-service boundary.",
    ),
    WriteDisposition(
        _range(0x80100894),
        "fn_80100874",
        "cache_only",
        "Data-cache flush and instruction-cache invalidate loop.",
        "Host instruction/data cache coherence boundary; no guest code mutation.",
    ),
    WriteDisposition(
        _range(0x8010A64C),
        "fn_8010A624",
        "ordinary_data",
        "Store callback/context state in a NAND request object.",
        "Translate as request data behind the save-service boundary.",
    ),
    *(
        WriteDisposition(
            _range(address),
            "fn_80185E58",
            "ordinary_data",
            "Write a byte-swapped word back into a streaming data buffer.",
            "Translate as an in-place endian conversion on data.",
        )
        for address in (
            0x80185E78,
            0x80185E84,
            0x80185E90,
            0x80185E9C,
            0x80185EA8,
            0x80185EB4,
            0x80185EC0,
            0x80185ECC,
            0x80185EE8,
        )
    ),
)

EXPECTED_SMC_RANGES = tuple(item.address_range for item in WRITE_DISPOSITIONS)


HOST_BOUNDARIES = (
    HostBoundary(
        0x800883C0,
        "fn_800883C0",
        "memory",
        "Allocate title memory with preserved alignment and lifetime.",
    ),
    HostBoundary(
        0x800A2828,
        "fn_800A2828",
        "audio",
        "Initialize the title audio middleware over a host mixer.",
    ),
    HostBoundary(
        0x800B4928,
        "ass_MemcardSave",
        "save",
        "Commit the active game state to a sandboxed local save.",
    ),
    HostBoundary(
        0x800B4950,
        "ass_MemcardSaveSlot",
        "save",
        "Select a slot and commit through the game save manager.",
    ),
    HostBoundary(
        0x800BB168,
        "CBinkPlayer::Play",
        "bink",
        "Open and play a title-owned Bink movie through the host media service.",
    ),
    HostBoundary(
        0x800C0690, "OSInit", "os", "Process/bootstrap state and host diagnostics."
    ),
    HostBoundary(
        0x800C1FD4, "DCFlushRange", "cache", "Host memory-order/coherence operation."
    ),
    HostBoundary(
        0x800C208C, "ICInvalidateRange", "cache", "Host code/data coherence operation."
    ),
    HostBoundary(
        0x800C5F64,
        "OSDisableInterrupts",
        "synchronization",
        "Enter host critical section.",
    ),
    HostBoundary(
        0x800C5F8C,
        "OSRestoreInterrupts",
        "synchronization",
        "Leave host critical section.",
    ),
    HostBoundary(
        0x800C8700, "__OSThreadInit", "thread", "Initialize guest-visible thread state."
    ),
    HostBoundary(
        0x800C8984,
        "OSInitThreadQueue",
        "thread",
        "Initialize a host-backed wait queue.",
    ),
    HostBoundary(
        0x800C99D0, "OSSleepThread", "thread", "Block on a host-backed wait queue."
    ),
    HostBoundary(0x800C9C18, "OSGetTime", "timer", "Read the monotonic runtime clock."),
    HostBoundary(0x800C9C30, "OSGetTick", "timer", "Read the runtime tick clock."),
    HostBoundary(
        0x800CC2A8,
        "__DVDFSInit",
        "file",
        "Initialize the title-scoped virtual filesystem.",
    ),
    HostBoundary(
        0x800CCE60, "DVDInit", "file", "Initialize asynchronous title-file services."
    ),
    HostBoundary(
        0x800D5C5C, "VIGetTvFormat", "video", "Query the host display policy."
    ),
    HostBoundary(
        0x800E39A8, "GXInit", "graphics", "Initialize the Metal-backed GX service."
    ),
    HostBoundary(
        0x80109764, "NANDPrivateOpenAsync", "save", "Open a sandboxed local-save file."
    ),
    HostBoundary(0x80109EC4, "NANDInit", "save", "Initialize local-save services."),
    HostBoundary(0x8010AB8C, "SCInit", "settings", "Initialize title settings."),
    HostBoundary(
        0x8010C4F0,
        "SCGetAspectRatio",
        "settings",
        "Read the title-visible widescreen setting.",
    ),
    HostBoundary(
        0x80111FEC,
        "fn_80111FEC (WPADInit)",
        "controller",
        "Initialize controller input.",
    ),
    HostBoundary(
        0x80182AE0,
        "BinkOpen",
        "bink",
        "Decode a title-owned movie into host video/audio surfaces.",
    ),
)


FIRST_HOST_STOP = FirstHostStop(
    address=0x800042E0,
    word=0x7C0000A6,
    instruction="mfmsr r0",
    reason="first privileged hardware-state instruction in __init_hardware",
    registers=(
        ("pc", 0x800042E0),
        ("lr", 0x80004044),
        ("r0", 0),
        ("r1", 0x80320AA0),
        ("r2", 0x80316E20),
        ("r13", 0x80311F60),
    ),
    zero_registers=tuple(
        [f"r{number}" for number in range(3, 13)]
        + [f"r{number}" for number in range(14, 32)]
    ),
    memory_writes_since_entry=0,
    unknown_registers=("ctr", "cr", "xer", "msr"),
)


def disposition_counts() -> dict[str, int]:
    return dict(sorted(Counter(item.category for item in WRITE_DISPOSITIONS).items()))


def validate_truth_map(ranges: Iterable[AddressRange]) -> None:
    actual = tuple(ranges)
    if actual != EXPECTED_SMC_RANGES:
        missing = set(EXPECTED_SMC_RANGES) - set(actual)
        extra = set(actual) - set(EXPECTED_SMC_RANGES)
        raise ExecutableTruthError(
            "SMC candidate set/order differs from the frozen truth map; "
            f"missing={[item.label() for item in sorted(missing)]}, "
            f"extra={[item.label() for item in sorted(extra)]}"
        )
    if len(WRITE_DISPOSITIONS) != 25:
        raise ExecutableTruthError("truth map must classify exactly 25 SMC ranges")
