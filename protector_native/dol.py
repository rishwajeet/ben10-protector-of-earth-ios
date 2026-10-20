"""Minimal Nintendo DOL reader for executable-derived format registries."""

from __future__ import annotations

import struct
from dataclasses import dataclass


class DolError(ValueError):
    """Raised when a DOL address or section violates the container."""


@dataclass(frozen=True)
class DolSection:
    file_offset: int
    address: int
    size: int

    @property
    def end_address(self) -> int:
        return self.address + self.size


class DolImage:
    """Read virtual-addressed bytes from a Nintendo DOL image."""

    def __init__(self, value: bytes):
        if len(value) < 0x100:
            raise DolError("DOL header is truncated")
        self.value = value
        sections: list[DolSection] = []
        for count, file_base, address_base, size_base in (
            (7, 0x00, 0x48, 0x90),
            (11, 0x1C, 0x64, 0xAC),
        ):
            for index in range(count):
                file_offset = self._header_u32(file_base + index * 4)
                address = self._header_u32(address_base + index * 4)
                size = self._header_u32(size_base + index * 4)
                if not size:
                    continue
                if file_offset + size > len(value):
                    raise DolError(f"DOL section at 0x{address:08x} exceeds file size")
                sections.append(DolSection(file_offset, address, size))
        if not sections:
            raise DolError("DOL has no populated sections")
        self.sections = tuple(sorted(sections, key=lambda section: section.address))

    def _header_u32(self, offset: int) -> int:
        return struct.unpack_from(">I", self.value, offset)[0]

    def read(self, address: int, size: int) -> bytes:
        if size < 0:
            raise DolError("negative DOL read size")
        for section in self.sections:
            if section.address <= address and address + size <= section.end_address:
                offset = section.file_offset + address - section.address
                return self.value[offset : offset + size]
        raise DolError(
            f"virtual range 0x{address:08x}..0x{address + size:08x} "
            "is not backed by a DOL section"
        )

    def u32(self, address: int) -> int:
        return struct.unpack(">I", self.read(address, 4))[0]

    def cstring(self, address: int, *, maximum: int = 512) -> str:
        raw = bytearray()
        for index in range(maximum):
            character = self.read(address + index, 1)[0]
            if character == 0:
                try:
                    return raw.decode("ascii")
                except UnicodeDecodeError as error:
                    raise DolError(
                        f"non-ASCII string at virtual address 0x{address:08x}"
                    ) from error
            raw.append(character)
        raise DolError(f"unterminated string at virtual address 0x{address:08x}")
