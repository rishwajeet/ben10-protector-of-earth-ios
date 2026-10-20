#include "protector/platform.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define WII_BOOT_INFO_ARENA_HI 0x80000034u
#define WII_BOOT_INFO_FST_LOCATION 0x80000038u
#define WII_BOOT_INFO_FST_MAX_LENGTH 0x8000003Cu

#define RBNEG9_DVDFS_BOOT_INFO_R13_OFFSET (-17124)
#define RBNEG9_DVDFS_FST_START_R13_OFFSET (-17128)
#define RBNEG9_DVDFS_STRING_START_R13_OFFSET (-17132)
#define RBNEG9_DVDFS_MAX_ENTRY_R13_OFFSET (-17136)

typedef struct DirectoryFrame {
    u32 end_index;
    size_t parent_length;
} DirectoryFrame;

static void set_error(
    char* error,
    size_t error_capacity,
    const char* format,
    const char* detail
) {
    if (!error || error_capacity == 0u) {
        return;
    }
    (void)snprintf(error, error_capacity, format, detail);
}

static bool join_path(
    char* output,
    size_t output_capacity,
    const char* root,
    const char* suffix
) {
    int length = snprintf(output, output_capacity, "%s/%s", root, suffix);
    return length >= 0 && (size_t)length < output_capacity;
}

bool protector_mount_wii_data(
    CPUState* cpu,
    const char* data_root,
    ProtectorDataMount* mount,
    char* error,
    size_t error_capacity
) {
    if (!cpu || !data_root || !data_root[0] || !mount) {
        set_error(error, error_capacity, "%s", "invalid data mount arguments");
        return false;
    }

    char fst_path[4096];
    char files_path[4096];
    if (
        !join_path(fst_path, sizeof(fst_path), data_root, "sys/fst.bin") ||
        !join_path(files_path, sizeof(files_path), data_root, "files")
    ) {
        set_error(error, error_capacity, "%s", "data-root path is too long");
        return false;
    }

    struct stat files_info;
    if (stat(files_path, &files_info) != 0 || !S_ISDIR(files_info.st_mode)) {
        set_error(
            error,
            error_capacity,
            "data root has no files directory: %s",
            files_path
        );
        return false;
    }

    FILE* source = fopen(fst_path, "rb");
    if (!source) {
        set_error(
            error,
            error_capacity,
            "cannot open Wii FST: %s",
            fst_path
        );
        return false;
    }
    if (fseek(source, 0, SEEK_END) != 0) {
        set_error(error, error_capacity, "cannot size Wii FST: %s", fst_path);
        (void)fclose(source);
        return false;
    }
    long signed_size = ftell(source);
    if (signed_size < 0) {
        set_error(error, error_capacity, "cannot size Wii FST: %s", fst_path);
        (void)fclose(source);
        return false;
    }
    if (signed_size < 12 || (u64)signed_size > PROTECTOR_WII_FST_CAPACITY) {
        set_error(
            error,
            error_capacity,
            "Wii FST has an unsupported size: %s",
            fst_path
        );
        (void)fclose(source);
        return false;
    }
    if (fseek(source, 0, SEEK_SET) != 0) {
        set_error(error, error_capacity, "cannot rewind Wii FST: %s", fst_path);
        (void)fclose(source);
        return false;
    }

    u32 fst_size = (u32)signed_size;
    u8 bytes[PROTECTOR_WII_FST_CAPACITY];
    if (fread(bytes, 1, fst_size, source) != fst_size) {
        set_error(error, error_capacity, "cannot read Wii FST: %s", fst_path);
        (void)fclose(source);
        return false;
    }
    if (fclose(source) != 0) {
        set_error(error, error_capacity, "cannot close Wii FST: %s", fst_path);
        return false;
    }

    u32 entry_count =
        ((u32)bytes[8] << 24) |
        ((u32)bytes[9] << 16) |
        ((u32)bytes[10] << 8) |
        bytes[11];
    if (
        bytes[0] != 1u ||
        entry_count == 0u ||
        (u64)entry_count * 12u > fst_size
    ) {
        set_error(error, error_capacity, "invalid Wii FST root: %s", fst_path);
        return false;
    }

    for (u32 index = 0; index < fst_size; ++index) {
        mem_write8(
            cpu,
            PROTECTOR_WII_FST_ADDRESS + index,
            bytes[index]
        );
    }
    if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
        set_error(error, error_capacity, "%s", "FST does not fit guest memory");
        return false;
    }

    mem_write32(cpu, WII_BOOT_INFO_ARENA_HI, PROTECTOR_WII_FST_ADDRESS);
    mem_write32(
        cpu,
        WII_BOOT_INFO_FST_LOCATION,
        PROTECTOR_WII_FST_ADDRESS
    );
    mem_write32(cpu, WII_BOOT_INFO_FST_MAX_LENGTH, fst_size);
    if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
        set_error(
            error,
            error_capacity,
            "%s",
            "cannot publish FST in Wii boot info"
        );
        return false;
    }

    mount->fst_guest_address = PROTECTOR_WII_FST_ADDRESS;
    mount->fst_size = fst_size;
    mount->fst_entry_count = entry_count;
    const char* allow_prefix_files =
        getenv("PROTECTOR_ALLOW_SOURCE_PREFIX_FILES");
    mount->allow_source_prefix_files =
        allow_prefix_files &&
        strcmp(allow_prefix_files, "1") == 0;
    memcpy(mount->fst_bytes, bytes, fst_size);
    if (!join_path(
            mount->files_root,
            sizeof(mount->files_root),
            data_root,
            "files"
        )) {
        set_error(error, error_capacity, "%s", "data-root path is too long");
        return false;
    }
    return true;
}

bool protector_bind_rbneg9_dvdfs(CPUState* cpu) {
    if (!cpu) {
        return false;
    }
    u32 fst_start = mem_read32(cpu, WII_BOOT_INFO_FST_LOCATION);
    u32 fst_size = mem_read32(cpu, WII_BOOT_INFO_FST_MAX_LENGTH);
    if (
        cpu->stop_reason != PROTECTOR_STOP_NONE ||
        fst_start == 0u ||
        fst_size < 12u
    ) {
        return false;
    }
    u32 entry_count = mem_read32(cpu, fst_start + 8u);
    if (
        cpu->stop_reason != PROTECTOR_STOP_NONE ||
        entry_count == 0u ||
        (u64)entry_count * 12u > fst_size
    ) {
        return false;
    }

    u32 r13 = cpu->gpr[13];
    mem_write32(
        cpu,
        r13 + (u32)(s32)RBNEG9_DVDFS_BOOT_INFO_R13_OFFSET,
        0x80000000u
    );
    mem_write32(
        cpu,
        r13 + (u32)(s32)RBNEG9_DVDFS_FST_START_R13_OFFSET,
        fst_start
    );
    mem_write32(
        cpu,
        r13 + (u32)(s32)RBNEG9_DVDFS_MAX_ENTRY_R13_OFFSET,
        entry_count
    );
    mem_write32(
        cpu,
        r13 + (u32)(s32)RBNEG9_DVDFS_STRING_START_R13_OFFSET,
        fst_start + entry_count * 12u
    );
    return cpu->stop_reason == PROTECTOR_STOP_NONE;
}

static u32 read_be32(const u8* bytes) {
    return ((u32)bytes[0] << 24) |
           ((u32)bytes[1] << 16) |
           ((u32)bytes[2] << 8) |
           bytes[3];
}

static bool valid_component(const char* value) {
    if (
        !value[0] ||
        strcmp(value, ".") == 0 ||
        strcmp(value, "..") == 0
    ) {
        return false;
    }
    for (const char* cursor = value; *cursor; ++cursor) {
        if (*cursor == '/' || *cursor == '\\') {
            return false;
        }
    }
    return true;
}

static bool append_component(
    char* path,
    size_t path_capacity,
    const char* component
) {
    size_t path_length = strlen(path);
    size_t component_length = strlen(component);
    size_t separator = path_length == 0u ? 0u : 1u;
    if (
        path_length + separator + component_length + 1u >
        path_capacity
    ) {
        return false;
    }
    if (separator) {
        path[path_length++] = '/';
    }
    memcpy(path + path_length, component, component_length + 1u);
    return true;
}

static bool find_file_path(
    const ProtectorDataMount* mount,
    u32 disc_offset_words,
    ProtectorFileRead* read,
    char* error,
    size_t error_capacity
) {
    const u8* fst = mount->fst_bytes;
    u32 string_offset = mount->fst_entry_count * 12u;
    if (string_offset > mount->fst_size) {
        set_error(error, error_capacity, "%s", "invalid mounted FST");
        return false;
    }

    DirectoryFrame directories[64];
    size_t depth = 1u;
    directories[0].end_index = mount->fst_entry_count;
    directories[0].parent_length = 0u;
    char relative[PROTECTOR_RELATIVE_PATH_CAPACITY] = {0};

    for (u32 index = 1u; index < mount->fst_entry_count; ++index) {
        while (
            depth > 1u &&
            index >= directories[depth - 1u].end_index
        ) {
            relative[directories[depth - 1u].parent_length] = '\0';
            depth--;
        }

        const u8* entry = fst + index * 12u;
        u32 type_and_name = read_be32(entry);
        bool is_directory = (type_and_name >> 24) != 0u;
        u32 name_offset = type_and_name & 0x00FFFFFFu;
        if (name_offset >= mount->fst_size - string_offset) {
            set_error(error, error_capacity, "%s", "invalid FST name offset");
            return false;
        }
        const char* name =
            (const char*)(fst + string_offset + name_offset);
        size_t available =
            mount->fst_size - string_offset - name_offset;
        if (!memchr(name, '\0', available) || !valid_component(name)) {
            set_error(error, error_capacity, "%s", "unsafe FST path component");
            return false;
        }

        size_t parent_length = strlen(relative);
        if (!append_component(
                relative,
                sizeof(relative),
                name
            )) {
            set_error(error, error_capacity, "%s", "FST path is too long");
            return false;
        }

        u32 word1 = read_be32(entry + 4u);
        u32 word2 = read_be32(entry + 8u);
        if (is_directory) {
            if (
                depth >= sizeof(directories) / sizeof(directories[0]) ||
                word2 <= index ||
                word2 > mount->fst_entry_count
            ) {
                set_error(
                    error,
                    error_capacity,
                    "%s",
                    "invalid FST directory"
                );
                return false;
            }
            directories[depth].end_index = word2;
            directories[depth].parent_length = parent_length;
            depth++;
            continue;
        }

        if (word1 == disc_offset_words) {
            read->fst_entry_index = index;
            read->disc_offset_words = word1;
            read->file_size = word2;
            (void)snprintf(
                read->relative_path,
                sizeof(read->relative_path),
                "%s",
                relative
            );
            return true;
        }
        relative[parent_length] = '\0';
    }

    set_error(
        error,
        error_capacity,
        "no FST file starts at disc word offset %s",
        "requested by the guest"
    );
    return false;
}

static bool write_guest_buffer(
    CPUState* cpu,
    u32 destination,
    const u8* bytes,
    u32 length
) {
    for (u32 index = 0u; index < length; ++index) {
        mem_write8(cpu, destination + index, bytes[index]);
        if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
            return false;
        }
    }
    return true;
}

static bool trace_wii_file_event(
    const CPUState* cpu,
    const ProtectorFileRead* read,
    const char* phase,
    u64 request_serial,
    bool has_completion_serial,
    u64 completion_serial,
    bool has_payload_hash,
    u64 payload_fnv1a64
) {
    const char* trace_path = getenv("PROTECTOR_FILE_READ_TRACE");
    if (!trace_path || !trace_path[0]) {
        return true;
    }
    FILE* trace = fopen(trace_path, "a");
    if (!trace) {
        return false;
    }
    const int wrote = fprintf(
        trace,
        "%s\t%" PRIu64 "\t",
        phase,
        request_serial
    );
    bool success = wrote > 0;
    if (success) {
        success = has_completion_serial
            ? fprintf(trace, "%" PRIu64 "\t", completion_serial) > 0
            : fprintf(trace, "-\t") > 0;
    }
    if (success) {
        success = fprintf(
            trace,
            "%s\t%u\t%u\t%u\t%" PRIu64 "\t%" PRIu64
            "\t0x%08X\t%" PRIu64 "\t",
            read->relative_path,
            read->file_offset,
            read->requested_length,
            read->file_size,
            cpu->translated_dispatch_count,
            cpu->presented_frame_count,
            cpu->pc,
            cpu->timebase
        ) > 0;
    }
    if (success) {
        success = cpu->content_trace_logical_clock_valid
            ? fprintf(
                  trace,
                  "%" PRIu64 "\t%" PRIu64 "\t",
                  cpu->content_trace_logical_frame,
                  cpu->content_trace_absolute_checkpoint
              ) > 0
            : fprintf(trace, "-\t-\t") > 0;
    }
    if (success) {
        success = has_payload_hash
            ? fprintf(trace, "%016" PRIX64 "\n", payload_fnv1a64) > 0
            : fprintf(trace, "-\n") > 0;
    }
    if (fflush(trace) != 0) {
        success = false;
    }
    if (fclose(trace) != 0) {
        success = false;
    }
    return success;
}

static bool trace_wii_file_read(
    const CPUState* cpu,
    const ProtectorFileRead* read
) {
    return trace_wii_file_event(
        cpu,
        read,
        "request",
        cpu->content_trace_request_serial,
        false,
        0u,
        false,
        0u
    );
}

bool protector_trace_wii_file_completion(
    const CPUState* cpu,
    const ProtectorFileRead* read,
    u64 request_serial,
    u64 completion_serial,
    u64 payload_fnv1a64
) {
    if (!cpu || !read || !read->relative_path[0]) {
        return false;
    }
    return trace_wii_file_event(
        cpu,
        read,
        "completion",
        request_serial,
        true,
        completion_serial,
        true,
        payload_fnv1a64
    );
}

static bool describe_wii_file_read(
    CPUState* cpu,
    const ProtectorDataMount* mount,
    u32 disc_offset_words,
    u32 file_offset,
    u32 guest_destination,
    u32 length,
    ProtectorFileRead* read,
    char* error,
    size_t error_capacity
) {
    if (!cpu || !mount || !read) {
        set_error(error, error_capacity, "%s", "invalid file-read arguments");
        return false;
    }
    memset(read, 0, sizeof(*read));
    if (!find_file_path(
            mount,
            disc_offset_words,
            read,
            error,
            error_capacity
        )) {
        return false;
    }

    u64 padded_size = ((u64)read->file_size + 31u) & ~(u64)31u;
    u64 requested_end = (u64)file_offset + length;
    if (
        file_offset > read->file_size ||
        requested_end > padded_size ||
        (u64)guest_destination + length > 0x100000000ull
    ) {
        set_error(
            error,
            error_capacity,
            "%s",
            "file read is outside the mounted FST entry"
        );
        return false;
    }

    char host_path[PROTECTOR_PLATFORM_PATH_CAPACITY];
    if (!join_path(
            host_path,
            sizeof(host_path),
            mount->files_root,
            read->relative_path
        )) {
        set_error(error, error_capacity, "%s", "host file path is too long");
        return false;
    }
    struct stat host_info;
    bool source_exists =
        stat(host_path, &host_info) == 0 &&
        S_ISREG(host_info.st_mode);
    bool exact_source_size =
        source_exists &&
        host_info.st_size >= 0 &&
        (u64)host_info.st_size == read->file_size;
    bool valid_source_prefix =
        source_exists &&
        mount->allow_source_prefix_files &&
        host_info.st_size >= 0 &&
        (u64)host_info.st_size < read->file_size &&
        requested_end <= (u64)host_info.st_size;
    if (!exact_source_size && !valid_source_prefix) {
        set_error(error, error_capacity, "host file mismatches FST: %s", host_path);
        return false;
    }

    read->file_offset = file_offset;
    read->requested_length = length;
    u32 available = read->file_size - file_offset;
    read->bytes_from_file = length < available ? length : available;
    return true;
}

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
) {
    if (!describe_wii_file_read(
            cpu,
            mount,
            disc_offset_words,
            file_offset,
            guest_destination,
            length,
            read,
            error,
            error_capacity
        )) {
        return false;
    }
    if (!trace_wii_file_read(cpu, read)) {
        set_error(
            error,
            error_capacity,
            "%s",
            "cannot append file-read request trace"
        );
        return false;
    }
    return true;
}

bool protector_complete_wii_file_read(
    CPUState* cpu,
    const ProtectorDataMount* mount,
    const ProtectorFileRead* read,
    u32 guest_destination,
    char* error,
    size_t error_capacity
) {
    if (
        !cpu || !mount || !read || !read->relative_path[0] ||
        read->file_offset > read->file_size ||
        read->bytes_from_file > read->requested_length ||
        (u64)read->file_offset + read->bytes_from_file > read->file_size ||
        (u64)guest_destination + read->requested_length > 0x100000000ull
    ) {
        set_error(error, error_capacity, "%s", "invalid prepared file read");
        return false;
    }

    char host_path[PROTECTOR_PLATFORM_PATH_CAPACITY];
    if (!join_path(
            host_path,
            sizeof(host_path),
            mount->files_root,
            read->relative_path
        )) {
        set_error(error, error_capacity, "%s", "host file path is too long");
        return false;
    }
    struct stat host_info;
    const bool source_exists =
        stat(host_path, &host_info) == 0 &&
        S_ISREG(host_info.st_mode) &&
        host_info.st_size >= 0;
    const bool exact_source_size =
        source_exists && (u64)host_info.st_size == read->file_size;
    const bool valid_source_prefix =
        source_exists &&
        mount->allow_source_prefix_files &&
        (u64)host_info.st_size < read->file_size &&
        (u64)read->file_offset + read->bytes_from_file <=
            (u64)host_info.st_size;
    if (!exact_source_size && !valid_source_prefix) {
        set_error(error, error_capacity, "host file mismatches FST: %s", host_path);
        return false;
    }

    FILE* source = fopen(host_path, "rb");
    if (!source) {
        set_error(error, error_capacity, "cannot open mounted file: %s", host_path);
        return false;
    }
    if (fseek(source, (long)read->file_offset, SEEK_SET) != 0) {
        set_error(error, error_capacity, "cannot seek mounted file: %s", host_path);
        (void)fclose(source);
        return false;
    }

    u8 buffer[64u * 1024u];
    u32 completed = 0u;
    bool success = true;
    while (completed < read->bytes_from_file) {
        u32 remaining = read->bytes_from_file - completed;
        u32 chunk = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
        if (fread(buffer, 1, chunk, source) != chunk) {
            set_error(error, error_capacity, "cannot read mounted file: %s", host_path);
            success = false;
            break;
        }
        if (!write_guest_buffer(
                cpu,
                guest_destination + completed,
                buffer,
                chunk
            )) {
            set_error(error, error_capacity, "%s", "file destination is unmapped");
            success = false;
            break;
        }
        completed += chunk;
    }
    if (success && completed < read->requested_length) {
        memset(buffer, 0, sizeof(buffer));
        while (completed < read->requested_length) {
            u32 remaining = read->requested_length - completed;
            u32 chunk = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
            if (!write_guest_buffer(
                    cpu,
                    guest_destination + completed,
                    buffer,
                    chunk
                )) {
                set_error(
                    error,
                    error_capacity,
                    "%s",
                    "file destination is unmapped"
                );
                success = false;
                break;
            }
            completed += chunk;
        }
    }
    if (fclose(source) != 0 && success) {
        set_error(error, error_capacity, "cannot close mounted file: %s", host_path);
        success = false;
    }
    return success;
}

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
) {
    if (!describe_wii_file_read(
            cpu,
            mount,
            disc_offset_words,
            file_offset,
            guest_destination,
            length,
            read,
            error,
            error_capacity
        ) ||
        !protector_complete_wii_file_read(
            cpu,
            mount,
            read,
            guest_destination,
            error,
            error_capacity
        )) {
        return false;
    }
    if (!trace_wii_file_read(cpu, read)) {
        set_error(
            error,
            error_capacity,
            "%s",
            "cannot append file-read request trace"
        );
        return false;
    }
    return true;
}
