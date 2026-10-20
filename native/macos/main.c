#include "protector/cpu.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void func_80004000(CPUState* cpu);

#define RBNEG9_ENTRY 0x8000403Cu
#define FIRST_STOP_PC 0x800042E0u
#define FIRST_STOP_WORD 0x7C0000A6u

static u64 fnv1a_ram(
    const CPUState* cpu, u32 address, u32 length
) {
    if (
        address < GC_RAM_BASE ||
        (u64)(address - GC_RAM_BASE) + length > cpu->ram_size
    ) {
        return 0u;
    }
    u64 hash = UINT64_C(14695981039346656037);
    const u8* bytes = cpu->ram + (address - GC_RAM_BASE);
    for (u32 index = 0u; index < length; ++index) {
        hash ^= bytes[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static bool zero_registers_match(const CPUState* cpu) {
    for (u32 index = 3; index <= 12; index++) {
        if (cpu->gpr[index] != 0) {
            return false;
        }
    }
    for (u32 index = 14; index <= 31; index++) {
        if (cpu->gpr[index] != 0) {
            return false;
        }
    }
    return true;
}

static bool material_state_matches(
    const CPUState* cpu, const ProtectorDolInfo* dol
) {
    return dol->entry_point == RBNEG9_ENTRY &&
           cpu->stop_reason == PROTECTOR_STOP_HOST_SERVICE &&
           cpu->pc == FIRST_STOP_PC &&
           cpu->stop_pc == FIRST_STOP_PC &&
           cpu->stop_instruction == FIRST_STOP_WORD &&
           cpu->lr == 0x80004044u &&
           cpu->gpr[0] == 0 &&
           cpu->gpr[1] == 0x80320AA0u &&
           cpu->gpr[2] == 0x80316E20u &&
           cpu->gpr[13] == 0x80311F60u &&
           zero_registers_match(cpu) &&
           cpu->memory_write_count == 0 &&
           cpu->exception == 0;
}

static bool write_trace(
    const char* path,
    const CPUState* cpu,
    const ProtectorDolInfo* dol,
    bool matched
) {
    FILE* output = fopen(path, "wb");
    if (!output) {
        return false;
    }
#if defined(__aarch64__) || defined(__arm64__)
    const char* architecture = "arm64";
#else
    const char* architecture = "unsupported";
#endif
#if defined(PROTECTOR_DARWIN)
    const char* platform = "darwin";
#else
    const char* platform = "unsupported";
#endif
    fprintf(
        output,
        "{\n"
        "  \"schema\": \"protector-native-entry-trace-v1\",\n"
        "  \"revision\": \"RBNEG9\",\n"
        "  \"host\": {\"platform\": \"%s\", \"architecture\": \"%s\", "
        "\"jit\": false},\n"
        "  \"dol\": {\"entry\": \"0x%08X\", \"sections\": %u, "
        "\"loaded_bytes\": %" PRIu64 ", \"bss_address\": \"0x%08X\", "
        "\"bss_size\": %u},\n"
        "  \"stop\": {\"reason\": \"%s\", \"pc\": \"0x%08X\", "
        "\"instruction\": \"0x%08X\", \"service\": "
        "\"privileged_hardware_state\"},\n"
        "  \"registers\": {\"lr\": \"0x%08X\", \"r0\": \"0x%08X\", "
        "\"r1\": \"0x%08X\", \"r2\": \"0x%08X\", "
        "\"r13\": \"0x%08X\"},\n"
        "  \"known_zero_registers_match\": %s,\n"
        "  \"checkpoints\": {\"code_80004000_fnv1a64\": \"%016" PRIX64
        "\", \"stack_80320A00_fnv1a64\": \"%016" PRIX64
        "\", \"sda2_80316E20_fnv1a64\": \"%016" PRIX64
        "\", \"sda_80311F60_fnv1a64\": \"%016" PRIX64 "\"},\n"
        "  \"memory\": {\"runtime_reads\": %" PRIu64 ", "
        "\"runtime_writes\": %" PRIu64 "},\n"
        "  \"exceptions\": %u,\n"
        "  \"material_state_match\": %s\n"
        "}\n",
        platform,
        architecture,
        dol->entry_point,
        dol->section_count,
        dol->loaded_bytes,
        dol->bss_address,
        dol->bss_size,
        protector_stop_reason_name(cpu->stop_reason),
        cpu->stop_pc,
        cpu->stop_instruction,
        cpu->lr,
        cpu->gpr[0],
        cpu->gpr[1],
        cpu->gpr[2],
        cpu->gpr[13],
        zero_registers_match(cpu) ? "true" : "false",
        fnv1a_ram(cpu, 0x80004000u, 0x100u),
        fnv1a_ram(cpu, 0x80320A00u, 0xA0u),
        fnv1a_ram(cpu, 0x80316E20u, 0x100u),
        fnv1a_ram(cpu, 0x80311F60u, 0x100u),
        cpu->memory_read_count,
        cpu->memory_write_count,
        cpu->exception,
        matched ? "true" : "false"
    );
    return fclose(output) == 0;
}

int main(int argc, char** argv) {
    if (argc != 4 || strcmp(argv[1], "--dol") != 0) {
        fprintf(stderr, "usage: %s --dol PATH TRACE_JSON\n", argv[0]);
        return 2;
    }

    CPUState cpu;
    if (!protector_cpu_init(&cpu)) {
        fprintf(stderr, "failed to allocate guest memory\n");
        return 3;
    }

    ProtectorDolInfo dol;
    char error[256] = {0};
    if (!protector_load_dol(
            &cpu, argv[2], &dol, error, sizeof(error)
        )) {
        fprintf(stderr, "%s\n", error);
        protector_cpu_destroy(&cpu);
        return 4;
    }
    if (dol.entry_point != RBNEG9_ENTRY) {
        fprintf(
            stderr,
            "unexpected entry 0x%08X (expected 0x%08X)\n",
            dol.entry_point,
            RBNEG9_ENTRY
        );
        protector_cpu_destroy(&cpu);
        return 5;
    }

    cpu.pc = dol.entry_point;
    cpu.downcount = 0;
    cpu.trap_privileged_boot = true;
    func_80004000(&cpu);

    bool matched = material_state_matches(&cpu, &dol);
    if (!write_trace(argv[3], &cpu, &dol, matched)) {
        fprintf(stderr, "failed to write trace %s\n", argv[3]);
        protector_cpu_destroy(&cpu);
        return 6;
    }

    printf(
        "entry=0x%08X stop=0x%08X reason=%s match=%s writes=%" PRIu64 "\n",
        dol.entry_point,
        cpu.stop_pc,
        protector_stop_reason_name(cpu.stop_reason),
        matched ? "yes" : "no",
        cpu.memory_write_count
    );
    protector_cpu_destroy(&cpu);
    return matched ? 0 : 7;
}
