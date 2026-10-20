#include "protector/cpu.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#define DOL_HEADER_SIZE 0x100u
#define DOL_TEXT_COUNT 7u
#define DOL_DATA_COUNT 11u

static u32 read_big32(const u8* source) {
    return ((u32)source[0] << 24) |
           ((u32)source[1] << 16) |
           ((u32)source[2] << 8) |
           source[3];
}

static void set_error(
    char* output, size_t capacity, const char* format, ...
) {
    if (!output || capacity == 0) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(output, capacity, format, arguments);
    va_end(arguments);
}

static u8* resolve_load_range(CPUState* cpu, u32 address, u32 size) {
    u32 offset;
    if (
        address >= GC_RAM_BASE &&
        address <= GC_RAM_BASE + cpu->ram_size &&
        size <= GC_RAM_BASE + cpu->ram_size - address
    ) {
        offset = address - GC_RAM_BASE;
        return cpu->ram + offset;
    }
    if (
        address >= WII_MEM2_BASE &&
        address <= WII_MEM2_BASE + cpu->mem2_size &&
        size <= WII_MEM2_BASE + cpu->mem2_size - address
    ) {
        offset = address - WII_MEM2_BASE;
        return cpu->mem2 + offset;
    }
    return NULL;
}

static bool load_section(
    CPUState* cpu,
    const u8* file,
    size_t file_size,
    u32 file_offset,
    u32 address,
    u32 size,
    ProtectorDolInfo* info,
    char* error,
    size_t error_capacity
) {
    if (size == 0) {
        return true;
    }
    if (
        file_offset > file_size ||
        size > file_size - file_offset
    ) {
        set_error(
            error,
            error_capacity,
            "DOL section at 0x%08X exceeds the input file",
            address
        );
        return false;
    }
    u8* destination = resolve_load_range(cpu, address, size);
    if (!destination) {
        set_error(
            error,
            error_capacity,
            "DOL section 0x%08X..0x%08X is outside MEM1/MEM2",
            address,
            address + size
        );
        return false;
    }
    memcpy(destination, file + file_offset, size);
    info->section_count++;
    info->loaded_bytes += size;
    return true;
}

bool protector_load_dol(
    CPUState* cpu,
    const char* path,
    ProtectorDolInfo* info,
    char* error,
    size_t error_capacity
) {
    if (!cpu || !path || !info) {
        set_error(error, error_capacity, "invalid DOL loader arguments");
        return false;
    }
    memset(info, 0, sizeof(*info));
    FILE* source = fopen(path, "rb");
    if (!source) {
        set_error(error, error_capacity, "cannot open DOL: %s", path);
        return false;
    }
    if (fseek(source, 0, SEEK_END) != 0) {
        fclose(source);
        set_error(error, error_capacity, "cannot seek DOL");
        return false;
    }
    long raw_size = ftell(source);
    if (raw_size < (long)DOL_HEADER_SIZE || fseek(source, 0, SEEK_SET) != 0) {
        fclose(source);
        set_error(error, error_capacity, "DOL is truncated");
        return false;
    }
    size_t file_size = (size_t)raw_size;
    u8* file = (u8*)malloc(file_size);
    if (!file || fread(file, 1, file_size, source) != file_size) {
        free(file);
        fclose(source);
        set_error(error, error_capacity, "cannot read DOL");
        return false;
    }
    fclose(source);

    bool valid = true;
    info->bss_address = read_big32(file + 0xD8);
    info->bss_size = read_big32(file + 0xDC);
    info->entry_point = read_big32(file + 0xE0);
    /*
     * The apploader clears BSS before copying initialized DOL sections.
     * Some retail DOLs deliberately place .sdata/.sbss payloads inside the
     * broad BSS range, so clearing after section copies destroys live data.
     */
    if (info->bss_size) {
        u8* bss = resolve_load_range(
            cpu, info->bss_address, info->bss_size
        );
        if (!bss) {
            set_error(
                error,
                error_capacity,
                "DOL BSS 0x%08X..0x%08X is outside MEM1/MEM2",
                info->bss_address,
                info->bss_address + info->bss_size
            );
            valid = false;
        } else {
            memset(bss, 0, info->bss_size);
        }
    }
    for (u32 index = 0; index < DOL_TEXT_COUNT && valid; index++) {
        valid = load_section(
            cpu,
            file,
            file_size,
            read_big32(file + index * 4),
            read_big32(file + 0x48 + index * 4),
            read_big32(file + 0x90 + index * 4),
            info,
            error,
            error_capacity
        );
    }
    for (u32 index = 0; index < DOL_DATA_COUNT && valid; index++) {
        valid = load_section(
            cpu,
            file,
            file_size,
            read_big32(file + 0x1C + index * 4),
            read_big32(file + 0x64 + index * 4),
            read_big32(file + 0xAC + index * 4),
            info,
            error,
            error_capacity
        );
    }

    free(file);
    return valid;
}
