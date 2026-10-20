#ifndef PROTECTOR_PLATFORM_H
#define PROTECTOR_PLATFORM_H

#include "protector/cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PROTECTOR_WII_FST_ADDRESS 0x817FC000u
#define PROTECTOR_WII_FST_CAPACITY 0x00002C00u
#define PROTECTOR_PLATFORM_PATH_CAPACITY 4096u
#define PROTECTOR_RELATIVE_PATH_CAPACITY 512u

typedef struct ProtectorDataMount {
    u32 fst_guest_address;
    u32 fst_size;
    u32 fst_entry_count;
    bool allow_source_prefix_files;
    char files_root[PROTECTOR_PLATFORM_PATH_CAPACITY];
    u8 fst_bytes[PROTECTOR_WII_FST_CAPACITY];
} ProtectorDataMount;

typedef struct ProtectorFileRead {
    u32 fst_entry_index;
    u32 disc_offset_words;
    u32 file_size;
    u32 file_offset;
    u32 requested_length;
    u32 bytes_from_file;
    char relative_path[PROTECTOR_RELATIVE_PATH_CAPACITY];
} ProtectorFileRead;

bool protector_mount_wii_data(
    CPUState* cpu,
    const char* data_root,
    ProtectorDataMount* mount,
    char* error,
    size_t error_capacity
);

bool protector_bind_rbneg9_dvdfs(CPUState* cpu);

bool protector_read_wii_file(
    CPUState* cpu,
    const ProtectorDataMount* mount,
    u32 disc_offset_words,
    u32 file_offset,
    u32 guest_destination,
    u32 length,
    ProtectorFileRead* read,
    char* error,
    size_t error_capacity
);

bool protector_prepare_wii_file_read(
    CPUState* cpu,
    const ProtectorDataMount* mount,
    u32 disc_offset_words,
    u32 file_offset,
    u32 guest_destination,
    u32 length,
    ProtectorFileRead* read,
    char* error,
    size_t error_capacity
);

bool protector_complete_wii_file_read(
    CPUState* cpu,
    const ProtectorDataMount* mount,
    const ProtectorFileRead* read,
    u32 guest_destination,
    char* error,
    size_t error_capacity
);

bool protector_trace_wii_file_completion(
    const CPUState* cpu,
    const ProtectorFileRead* read,
    u64 request_serial,
    u64 completion_serial,
    u64 payload_fnv1a64
);

#ifdef __cplusplus
}
#endif

#endif
