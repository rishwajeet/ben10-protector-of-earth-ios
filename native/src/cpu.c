#include "protector/cpu.h"

#include <fenv.h>
#include <float.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct MemoryRange {
    u8* bytes;
    u32 available;
} MemoryRange;

static MemoryRange resolve_memory(CPUState* cpu, u32 address) {
    MemoryRange range = {NULL, 0};
    u32 offset;

    if (address >= GC_RAM_BASE && address < GC_RAM_BASE + cpu->ram_size) {
        offset = address - GC_RAM_BASE;
        range.bytes = cpu->ram + offset;
        range.available = cpu->ram_size - offset;
        return range;
    }
    if (
        address >= GC_RAM_UNCACHED &&
        address < GC_RAM_UNCACHED + cpu->ram_size
    ) {
        offset = address - GC_RAM_UNCACHED;
        range.bytes = cpu->ram + offset;
        range.available = cpu->ram_size - offset;
        return range;
    }
    if (
        cpu->mem2 &&
        address >= WII_MEM2_BASE &&
        address < WII_MEM2_BASE + cpu->mem2_size
    ) {
        offset = address - WII_MEM2_BASE;
        range.bytes = cpu->mem2 + offset;
        range.available = cpu->mem2_size - offset;
        return range;
    }
    if (
        cpu->mem2 &&
        address >= WII_MEM2_UNCACHED &&
        address < WII_MEM2_UNCACHED + cpu->mem2_size
    ) {
        offset = address - WII_MEM2_UNCACHED;
        range.bytes = cpu->mem2 + offset;
        range.available = cpu->mem2_size - offset;
    }
    return range;
}

static bool memory_write_watch_overlaps(
    CPUState* cpu,
    u32 address,
    u32 size
) {
    if (
        cpu->debug_memory_write_watch_address == 0u ||
        cpu->presented_frame_count <
            cpu->debug_memory_write_watch_start_frame
    ) {
        return false;
    }

    MemoryRange write_range = resolve_memory(cpu, address);
    MemoryRange watch_range = resolve_memory(
        cpu,
        cpu->debug_memory_write_watch_address
    );
    return
        write_range.bytes != NULL &&
        write_range.available >= size &&
        watch_range.bytes != NULL &&
        watch_range.available >= sizeof(u32) &&
        watch_range.bytes >= write_range.bytes &&
        watch_range.bytes < write_range.bytes + size;
}

static bool require_memory(
    CPUState* cpu,
    u32 address,
    u32 size,
    bool external_handler_available,
    MemoryRange* output
) {
    MemoryRange range = resolve_memory(cpu, address);
    if (!range.bytes || range.available < size) {
        if (external_handler_available) {
            return false;
        }
        protector_stop(
            cpu,
            PROTECTOR_STOP_UNMAPPED_MEMORY,
            cpu->pc,
            0,
            address
        );
        return false;
    }
    *output = range;
    return true;
}

static u16 read_big16(const u8* source) {
    return (u16)(((u16)source[0] << 8) | source[1]);
}

static u32 read_big32(const u8* source) {
    return ((u32)source[0] << 24) |
           ((u32)source[1] << 16) |
           ((u32)source[2] << 8) |
           source[3];
}

static u64 read_big64(const u8* source) {
    return ((u64)read_big32(source) << 32) | read_big32(source + 4);
}

static void write_big16(u8* destination, u16 value) {
    destination[0] = (u8)(value >> 8);
    destination[1] = (u8)value;
}

static void write_big32(u8* destination, u32 value) {
    destination[0] = (u8)(value >> 24);
    destination[1] = (u8)(value >> 16);
    destination[2] = (u8)(value >> 8);
    destination[3] = (u8)value;
}

static void write_big64(u8* destination, u64 value) {
    write_big32(destination, (u32)(value >> 32));
    write_big32(destination + 4, (u32)value);
}

static void clear_reservation_for_store(CPUState* cpu, u32 address) {
    if (
        cpu->reservation_valid &&
        (cpu->reservation_address & ~31u) == (address & ~31u)
    ) {
        cpu->reservation_valid = false;
    }
}

bool protector_cpu_init(CPUState* cpu) {
    if (!cpu) {
        return false;
    }
    memset(cpu, 0, sizeof(*cpu));
    cpu->ram = (u8*)calloc(1, GC_MAIN_RAM_SIZE);
    cpu->mem2 = (u8*)calloc(1, WII_MEM2_SIZE);
    if (!cpu->ram || !cpu->mem2) {
        protector_cpu_destroy(cpu);
        return false;
    }
    cpu->ram_size = GC_MAIN_RAM_SIZE;
    cpu->mem2_size = WII_MEM2_SIZE;
    cpu->spr[287] = PPC_BROADWAY_PVR;
    return true;
}

void protector_cpu_reset(CPUState* cpu) {
    u8* ram = cpu->ram;
    u32 ram_size = cpu->ram_size;
    u8* mem2 = cpu->mem2;
    u32 mem2_size = cpu->mem2_size;
    PPCExternalRead external_read = cpu->external_read;
    PPCExternalWrite external_write = cpu->external_write;
    PPCInstructionFallback instruction_fallback = cpu->instruction_fallback;
    PPCHostCall host_call = cpu->host_call;
    PPCSystemCall system_call = cpu->system_call;
    PPCStopHandler stop_handler = cpu->stop_handler;
    PPCCacheControl cache_control = cpu->cache_control;
    void* external_user_data = cpu->external_user_data;
    u32 debug_memory_write_watch_address =
        cpu->debug_memory_write_watch_address;
    u64 debug_memory_write_watch_start_frame =
        cpu->debug_memory_write_watch_start_frame;

    memset(cpu, 0, sizeof(*cpu));
    cpu->ram = ram;
    cpu->ram_size = ram_size;
    cpu->mem2 = mem2;
    cpu->mem2_size = mem2_size;
    cpu->external_read = external_read;
    cpu->external_write = external_write;
    cpu->instruction_fallback = instruction_fallback;
    cpu->host_call = host_call;
    cpu->system_call = system_call;
    cpu->stop_handler = stop_handler;
    cpu->cache_control = cache_control;
    cpu->external_user_data = external_user_data;
    cpu->debug_memory_write_watch_address =
        debug_memory_write_watch_address;
    cpu->debug_memory_write_watch_start_frame =
        debug_memory_write_watch_start_frame;
    memset(cpu->ram, 0, cpu->ram_size);
    memset(cpu->mem2, 0, cpu->mem2_size);
    cpu->spr[287] = PPC_BROADWAY_PVR;
}

void protector_cpu_destroy(CPUState* cpu) {
    if (!cpu) {
        return;
    }
    free(cpu->ram);
    free(cpu->mem2);
    cpu->ram = NULL;
    cpu->mem2 = NULL;
    cpu->ram_size = 0;
    cpu->mem2_size = 0;
}

const char* protector_stop_reason_name(ProtectorStopReason reason) {
    switch (reason) {
    case PROTECTOR_STOP_NONE:
        return "none";
    case PROTECTOR_STOP_HOST_SERVICE:
        return "host_service";
    case PROTECTOR_STOP_UNMAPPED_MEMORY:
        return "unmapped_memory";
    case PROTECTOR_STOP_ALIGNMENT:
        return "alignment";
    case PROTECTOR_STOP_UNKNOWN_INSTRUCTION:
        return "unknown_instruction";
    case PROTECTOR_STOP_EXCEPTION:
        return "exception";
    case PROTECTOR_STOP_UNEXPECTED_DISPATCH:
        return "unexpected_dispatch";
    case PROTECTOR_STOP_PLATFORM_ERROR:
        return "platform_error";
    }
    return "invalid";
}

void protector_stop(
    CPUState* cpu,
    ProtectorStopReason reason,
    u32 pc,
    u32 instruction,
    u32 address
) {
    if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
        return;
    }
    cpu->stop_reason = reason;
    cpu->stop_pc = pc;
    cpu->stop_instruction = instruction;
    cpu->stop_address = address;
    cpu->pc = pc;
    if (cpu->stop_handler) {
        cpu->stop_handler(cpu);
    }
}

bool protector_trap_instruction(
    CPUState* cpu, u32 pc, u32 instruction, const char* service
) {
    (void)service;
    if (!cpu->trap_privileged_boot) {
        return false;
    }
    protector_stop(
        cpu,
        PROTECTOR_STOP_HOST_SERVICE,
        pc,
        instruction,
        pc
    );
    return true;
}

u64 mem_read64(CPUState* cpu, u32 address) {
    MemoryRange range;
    if (!require_memory(cpu, address, 8, cpu->external_read != NULL, &range)) {
        return cpu->external_read
            ? cpu->external_read(cpu, address, 8)
            : 0;
    }
    cpu->memory_read_count++;
    return read_big64(range.bytes);
}

u32 mem_read32(CPUState* cpu, u32 address) {
    MemoryRange range;
    if (!require_memory(cpu, address, 4, cpu->external_read != NULL, &range)) {
        return cpu->external_read
            ? (u32)cpu->external_read(cpu, address, 4)
            : 0;
    }
    cpu->memory_read_count++;
    return read_big32(range.bytes);
}

u16 mem_read16(CPUState* cpu, u32 address) {
    MemoryRange range;
    if (!require_memory(cpu, address, 2, cpu->external_read != NULL, &range)) {
        return cpu->external_read
            ? (u16)cpu->external_read(cpu, address, 2)
            : 0;
    }
    cpu->memory_read_count++;
    return read_big16(range.bytes);
}

u8 mem_read8(CPUState* cpu, u32 address) {
    MemoryRange range;
    if (!require_memory(cpu, address, 1, cpu->external_read != NULL, &range)) {
        return cpu->external_read
            ? (u8)cpu->external_read(cpu, address, 1)
            : 0;
    }
    cpu->memory_read_count++;
    return range.bytes[0];
}

void mem_write64(CPUState* cpu, u32 address, u64 value) {
    MemoryRange range;
    if (!require_memory(cpu, address, 8, cpu->external_write != NULL, &range)) {
        if (cpu->external_write) {
            cpu->external_write(cpu, address, value, 8);
        }
        return;
    }
    clear_reservation_for_store(cpu, address);
    write_big64(range.bytes, value);
    cpu->memory_write_count++;
    if (memory_write_watch_overlaps(cpu, address, sizeof(value))) {
        fprintf(
            stderr,
            "memory_write_watch64 pc=0x%08X address=0x%08X "
            "value=0x%016llX watched_address=0x%08X "
            "watched_value=0x%08X frame=%llu timebase=%llu "
            "r0=0x%08X r3=0x%08X r4=0x%08X r5=0x%08X "
            "r6=0x%08X r24=0x%08X r25=0x%08X r26=0x%08X "
            "lr=0x%08X\n",
            cpu->pc,
            address,
            (unsigned long long)value,
            cpu->debug_memory_write_watch_address,
            read_big32(resolve_memory(
                cpu,
                cpu->debug_memory_write_watch_address
            ).bytes),
            (unsigned long long)cpu->presented_frame_count,
            (unsigned long long)cpu->timebase,
            cpu->gpr[0],
            cpu->gpr[3],
            cpu->gpr[4],
            cpu->gpr[5],
            cpu->gpr[6],
            cpu->gpr[24],
            cpu->gpr[25],
            cpu->gpr[26],
            cpu->lr
        );
    }
}

// Keep the large diagnostic stack frame out of every ordinary guest store.
// The watch still runs after the write and observes the same post-store state.
#if defined(__GNUC__) || defined(__clang__)
__attribute__((cold, noinline))
#endif
static void trace_memory_write32(CPUState* cpu, u32 address, u32 value) {
    if (memory_write_watch_overlaps(cpu, address, sizeof(value))) {
        MemoryRange input = resolve_memory(cpu, cpu->gpr[6]);
        const bool input_valid = input.bytes && input.available >= 12u;
        const u32 input0 = input_valid ? read_big32(input.bytes) : 0u;
        const u32 input1 = input_valid ? read_big32(input.bytes + 4u) : 0u;
        const u32 input2 = input_valid ? read_big32(input.bytes + 8u) : 0u;
        MemoryRange operand4 = resolve_memory(cpu, cpu->gpr[4]);
        MemoryRange operand5 = resolve_memory(cpu, cpu->gpr[5]);
        MemoryRange stack384 = resolve_memory(cpu, cpu->gpr[1] + 384u);
        const bool operand4_valid =
            operand4.bytes && operand4.available >= 12u;
        const bool operand5_valid =
            operand5.bytes && operand5.available >= 12u;
        union {
            u32 bits;
            float value;
        } decoded = {.bits = value};
        fprintf(
            stderr,
            "memory_write_watch pc=0x%08X address=0x%08X "
            "value=0x%08X f32=%.17g frame=%llu timebase=%llu "
            "r0=0x%08X r1=0x%08X r3=0x%08X r4=0x%08X r5=0x%08X r6=0x%08X "
            "r24=0x%08X r25=0x%08X r26=0x%08X "
            "r28=0x%08X r29=0x%08X r30=0x%08X r31=0x%08X "
            "lr=0x%08X "
            "input_valid=%u input=0x%08X,0x%08X,0x%08X "
            "operand4=0x%08X,0x%08X,0x%08X "
            "operand5=0x%08X,0x%08X,0x%08X "
            "fpr0=%.17g fpr1=%.17g fpr2=%.17g fpr3=%.17g "
            "fpr4=%.17g fpr5=%.17g fpr6=%.17g fpr7=%.17g "
            "fpr8=%.17g fpr9=%.17g fpr10=%.17g fpr11=%.17g "
            "fpr19=%.17g fpr24=%.17g fpr25=%.17g fpr26=%.17g "
            "fpr27=%.17g fpr28=%.17g fpr29=%.17g fpr30=%.17g "
            "fpr31=%.17g "
            "stack384=0x%08X,0x%08X,0x%08X,0x%08X,"
            "0x%08X,0x%08X,0x%08X,0x%08X\n",
            cpu->pc,
            address,
            value,
            (double)decoded.value,
            (unsigned long long)cpu->presented_frame_count,
            (unsigned long long)cpu->timebase,
            cpu->gpr[0],
            cpu->gpr[1],
            cpu->gpr[3],
            cpu->gpr[4],
            cpu->gpr[5],
            cpu->gpr[6],
            cpu->gpr[24],
            cpu->gpr[25],
            cpu->gpr[26],
            cpu->gpr[28],
            cpu->gpr[29],
            cpu->gpr[30],
            cpu->gpr[31],
            cpu->lr,
            input_valid ? 1u : 0u,
            input0,
            input1,
            input2,
            operand4_valid ? read_big32(operand4.bytes) : 0u,
            operand4_valid ? read_big32(operand4.bytes + 4u) : 0u,
            operand4_valid ? read_big32(operand4.bytes + 8u) : 0u,
            operand5_valid ? read_big32(operand5.bytes) : 0u,
            operand5_valid ? read_big32(operand5.bytes + 4u) : 0u,
            operand5_valid ? read_big32(operand5.bytes + 8u) : 0u,
            cpu->fpr[0],
            cpu->fpr[1],
            cpu->fpr[2],
            cpu->fpr[3],
            cpu->fpr[4],
            cpu->fpr[5],
            cpu->fpr[6],
            cpu->fpr[7],
            cpu->fpr[8],
            cpu->fpr[9],
            cpu->fpr[10],
            cpu->fpr[11],
            cpu->fpr[19],
            cpu->fpr[24],
            cpu->fpr[25],
            cpu->fpr[26],
            cpu->fpr[27],
            cpu->fpr[28],
            cpu->fpr[29],
            cpu->fpr[30],
            cpu->fpr[31],
            stack384.bytes && stack384.available >= 32u
                ? read_big32(stack384.bytes) : 0u,
            stack384.bytes && stack384.available >= 32u
                ? read_big32(stack384.bytes + 4u) : 0u,
            stack384.bytes && stack384.available >= 32u
                ? read_big32(stack384.bytes + 8u) : 0u,
            stack384.bytes && stack384.available >= 32u
                ? read_big32(stack384.bytes + 12u) : 0u,
            stack384.bytes && stack384.available >= 32u
                ? read_big32(stack384.bytes + 16u) : 0u,
            stack384.bytes && stack384.available >= 32u
                ? read_big32(stack384.bytes + 20u) : 0u,
            stack384.bytes && stack384.available >= 32u
                ? read_big32(stack384.bytes + 24u) : 0u,
            stack384.bytes && stack384.available >= 32u
                ? read_big32(stack384.bytes + 28u) : 0u
        );
        if (cpu->pc == 0x8009A330u) {
            const u32 snapshot_addresses[] = {
                cpu->gpr[1] + 208u,
                cpu->gpr[1] + 288u,
                cpu->gpr[21],
            };
            const u32 snapshot_word_counts[] = {4u, 12u, 16u};
            const char* snapshot_names[] = {
                "stack208",
                "stack288",
                "pose_r21",
            };
            fprintf(
                stderr,
                "root_motion_writer_snapshot "
                "r1=0x%08X r21=0x%08X r29=0x%08X r31=0x%08X",
                cpu->gpr[1],
                cpu->gpr[21],
                cpu->gpr[29],
                cpu->gpr[31]
            );
            for (u32 range_index = 0u; range_index < 3u; range_index++) {
                MemoryRange snapshot = resolve_memory(
                    cpu,
                    snapshot_addresses[range_index]
                );
                fprintf(stderr, " %s=", snapshot_names[range_index]);
                for (
                    u32 word_index = 0u;
                    word_index < snapshot_word_counts[range_index];
                    word_index++
                ) {
                    const bool valid =
                        snapshot.bytes &&
                        snapshot.available >= (word_index + 1u) * 4u;
                    fprintf(
                        stderr,
                        "%s%08X",
                        word_index == 0u ? "" : ",",
                        valid
                            ? read_big32(snapshot.bytes + word_index * 4u)
                            : 0u
                    );
                }
            }
            fprintf(stderr, " fpr_f32=");
            const u32 fpr_indices[] = {
                0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u, 8u, 9u, 10u,
                11u, 12u, 13u, 26u, 27u, 28u, 29u, 30u, 31u,
            };
            for (u32 index = 0u; index < 20u; index++) {
                union {
                    float value;
                    u32 bits;
                } encoded = {.value = (float)cpu->fpr[fpr_indices[index]]};
                fprintf(
                    stderr,
                    "%sf%u:%08X",
                    index == 0u ? "" : ",",
                    fpr_indices[index],
                    encoded.bits
                );
            }
            fprintf(stderr, "\n");
        }
    }
}

void mem_write32(CPUState* cpu, u32 address, u32 value) {
    MemoryRange range;
    if (!require_memory(cpu, address, 4, cpu->external_write != NULL, &range)) {
        if (cpu->external_write) {
            cpu->external_write(cpu, address, value, 4);
        }
        return;
    }
    clear_reservation_for_store(cpu, address);
    write_big32(range.bytes, value);
    cpu->memory_write_count++;
    if (cpu->debug_memory_write_watch_address != 0u &&
        cpu->presented_frame_count >= cpu->debug_memory_write_watch_start_frame) {
        trace_memory_write32(cpu, address, value);
    }
}

void mem_write16(CPUState* cpu, u32 address, u16 value) {
    MemoryRange range;
    if (!require_memory(cpu, address, 2, cpu->external_write != NULL, &range)) {
        if (cpu->external_write) {
            cpu->external_write(cpu, address, value, 2);
        }
        return;
    }
    clear_reservation_for_store(cpu, address);
    write_big16(range.bytes, value);
    cpu->memory_write_count++;
    if (memory_write_watch_overlaps(cpu, address, sizeof(value))) {
        fprintf(
            stderr,
            "memory_write_watch16 pc=0x%08X address=0x%08X "
            "value=0x%04X frame=%llu timebase=%llu "
            "r0=0x%08X r3=0x%08X r4=0x%08X r5=0x%08X "
            "r6=0x%08X r24=0x%08X r25=0x%08X r26=0x%08X "
            "lr=0x%08X\n",
            cpu->pc,
            address,
            (u32)value,
            (unsigned long long)cpu->presented_frame_count,
            (unsigned long long)cpu->timebase,
            cpu->gpr[0],
            cpu->gpr[3],
            cpu->gpr[4],
            cpu->gpr[5],
            cpu->gpr[6],
            cpu->gpr[24],
            cpu->gpr[25],
            cpu->gpr[26],
            cpu->lr
        );
    }
}

void mem_write8(CPUState* cpu, u32 address, u8 value) {
    MemoryRange range;
    if (!require_memory(cpu, address, 1, cpu->external_write != NULL, &range)) {
        if (cpu->external_write) {
            cpu->external_write(cpu, address, value, 1);
        }
        return;
    }
    clear_reservation_for_store(cpu, address);
    range.bytes[0] = value;
    cpu->memory_write_count++;
    if (memory_write_watch_overlaps(cpu, address, sizeof(value))) {
        fprintf(
            stderr,
            "memory_write_watch8 pc=0x%08X address=0x%08X "
            "value=0x%02X frame=%llu timebase=%llu "
            "r0=0x%08X r3=0x%08X r4=0x%08X r5=0x%08X "
            "r6=0x%08X r24=0x%08X r25=0x%08X r26=0x%08X "
            "lr=0x%08X\n",
            cpu->pc,
            address,
            (u32)value,
            (unsigned long long)cpu->presented_frame_count,
            (unsigned long long)cpu->timebase,
            cpu->gpr[0],
            cpu->gpr[3],
            cpu->gpr[4],
            cpu->gpr[5],
            cpu->gpr[6],
            cpu->gpr[24],
            cpu->gpr[25],
            cpu->gpr[26],
            cpu->lr
        );
    }
}

u32 protector_lwarx(CPUState* cpu, u32 address) {
    if (address % 4u != 0u) {
        protector_stop(
            cpu,
            PROTECTOR_STOP_ALIGNMENT,
            cpu->pc,
            0,
            address
        );
        return 0u;
    }
    u32 value = mem_read32(cpu, address);
    if (cpu->stop_reason == PROTECTOR_STOP_NONE) {
        cpu->reservation_address = address;
        cpu->reservation_valid = true;
    }
    return value;
}

bool protector_stwcx(CPUState* cpu, u32 address, u32 value) {
    if (address % 4u != 0u) {
        cpu->reservation_valid = false;
        protector_stop(
            cpu,
            PROTECTOR_STOP_ALIGNMENT,
            cpu->pc,
            0,
            address
        );
        return false;
    }
    bool succeeds = cpu->reservation_valid &&
                    (cpu->reservation_address & ~31u) ==
                        (address & ~31u);
    cpu->reservation_valid = false;
    cpu->cr &= 0x0FFFFFFFu;
    if (succeeds) {
        mem_write32(cpu, address, value);
        cpu->cr |= 0x20000000u;
        cpu->atomic_success_count++;
    } else {
        cpu->atomic_failure_count++;
    }
    return succeeds;
}

void protector_cache_operation(
    CPUState* cpu, u8 operation, u32 address, u32 instruction_address
) {
    cpu->cache_operation_count++;
    if (cpu->cache_control) {
        cpu->cache_control(cpu, operation, address, instruction_address);
    }
}

void ppc_fallback_instruction(CPUState* cpu, u32 instruction, u32 address) {
    if (cpu->instruction_fallback) {
        cpu->instruction_fallback(cpu, instruction, address);
        return;
    }
    u32 opcode = instruction >> 26;
    u32 extended_opcode = (instruction >> 1) & 0x3FFu;
    if (opcode == 31 && extended_opcode == 339) {
        u32 destination = (instruction >> 21) & 31u;
        u32 special_register = ((instruction >> 16) & 31u) |
                               ((instruction >> 6) & 0x3E0u);
        cpu->gpr[destination] = cpu->spr[special_register];
        if (special_register == 22) {
            if (
                !cpu->decrementer_armed ||
                cpu->core_cycles >= cpu->decrementer_deadline_core_cycles
            ) {
                cpu->gpr[destination] = 0u;
            } else {
                const u64 remaining =
                    cpu->decrementer_deadline_core_cycles -
                    cpu->core_cycles;
                cpu->gpr[destination] = (u32)(
                    (remaining +
                        PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK - 1u) /
                    PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK
                );
            }
        }
        if (special_register == 920) {
            cpu->gpr[destination] = cpu->hid2;
        }
        cpu->pc = address + 4;
        return;
    }
    if (opcode == 31 && extended_opcode == 467) {
        u32 source = (instruction >> 21) & 31u;
        u32 special_register = ((instruction >> 16) & 31u) |
                               ((instruction >> 6) & 0x3E0u);
        cpu->spr[special_register] = cpu->gpr[source];
        if (special_register == 22) {
            s32 value = (s32)cpu->gpr[source];
            cpu->decrementer_deadline =
                value <= 0
                    ? cpu->timebase
                    : cpu->timebase + (u32)value;
            cpu->decrementer_deadline_core_cycles =
                value <= 0
                    ? cpu->core_cycles
                    : cpu->core_cycles +
                        (u64)(u32)value *
                            PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK;
            cpu->decrementer_armed = true;
        }
        if (special_register == 920) {
            cpu->hid2 = cpu->gpr[source];
        }
        cpu->pc = address + 4;
        return;
    }
    if (
        opcode == 31 &&
        (
            extended_opcode == 54 ||
            extended_opcode == 86 ||
            extended_opcode == 470 ||
            extended_opcode == 982
        )
    ) {
        u32 base_register = (instruction >> 16) & 31u;
        u32 index_register = (instruction >> 11) & 31u;
        u32 effective_address =
            (base_register ? cpu->gpr[base_register] : 0) +
            cpu->gpr[index_register];
        u8 operation = extended_opcode == 54 ? 0 :
                       extended_opcode == 86 ? 1 :
                       extended_opcode == 470 ? 2 : 3;
        protector_cache_operation(
            cpu, operation, effective_address, address
        );
        cpu->pc = address + 4;
        return;
    }
    protector_stop(
        cpu,
        PROTECTOR_STOP_UNKNOWN_INSTRUCTION,
        address,
        instruction,
        address
    );
}

bool ppc_host_call(CPUState* cpu, u32 address) {
    return cpu->host_call ? cpu->host_call(cpu, address) : false;
}

void ppc_program_exception(CPUState* cpu, u32 cause, u32 address) {
    cpu->program_exception |= cause;
    cpu->exception |= PPC_EXC_PROGRAM;
    cpu->srr0 = address;
    cpu->srr1 = cpu->msr | cause;
    protector_stop(
        cpu,
        PROTECTOR_STOP_EXCEPTION,
        address,
        0,
        address
    );
}

void ppc_system_call_exception(CPUState* cpu, u32 address) {
    if (cpu->system_call && cpu->system_call(cpu, address)) {
        return;
    }
    cpu->exception |= PPC_EXC_SYSTEM_CALL;
    cpu->srr0 = address + 4;
    cpu->srr1 = cpu->msr;
    protector_stop(
        cpu,
        PROTECTOR_STOP_EXCEPTION,
        address,
        0x44000002u,
        address
    );
}

void ppc_rfi(CPUState* cpu, u32 address) {
    (void)address;
    cpu->pc = cpu->srr0 & ~3u;
    cpu->msr = cpu->srr1;
    cpu->exception = 0;
}

void ppc_memory_fence(void) {
    atomic_thread_fence(memory_order_seq_cst);
}

u32 ppc_mftb(CPUState* cpu, u16 register_index, u32 address) {
    if (register_index == 269) {
        return (u32)(cpu->timebase >> 32);
    }
    if (register_index == 268) {
        return (u32)cpu->timebase;
    }
    protector_stop(
        cpu,
        PROTECTOR_STOP_UNKNOWN_INSTRUCTION,
        address,
        0,
        register_index
    );
    return 0;
}

void ppc_advance_broadway_cycles(CPUState* cpu, u64 cycles) {
    if (!cpu) {
        return;
    }
    cpu->core_cycles += cycles;
    u64 ticks =
        cycles / PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK;
    u64 remaining_cycles =
        cycles % PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK;
    remaining_cycles += cpu->timebase_cycle_remainder;
    ticks +=
        remaining_cycles /
        PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK;
    cpu->timebase_cycle_remainder =
        (u8)(
            remaining_cycles %
            PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK
        );
    cpu->timebase += ticks;
}

bool ppc_decrementer_pending(const CPUState* cpu) {
    return cpu &&
           cpu->decrementer_armed &&
           (cpu->msr & PPC_MSR_EE) != 0u &&
           cpu->core_cycles >= cpu->decrementer_deadline_core_cycles;
}

void ppc_decrementer_delivered(CPUState* cpu) {
    if (!cpu) {
        return;
    }
    cpu->decrementer_armed = false;
    cpu->decrementer_interrupt_count++;
}

bool ppc_trap_condition(u8 options, u32 left, u32 right) {
    s32 signed_left = (s32)left;
    s32 signed_right = (s32)right;
    return ((options & 0x10u) && signed_left < signed_right) ||
           ((options & 0x08u) && signed_left > signed_right) ||
           ((options & 0x04u) && left == right) ||
           ((options & 0x02u) && left < right) ||
           ((options & 0x01u) && left > right);
}

bool ppc_fp_available(CPUState* cpu, u32 address) {
    (void)address;
    if (cpu->msr & 0x00002000u) {
        return true;
    }

    /*
     * Revolution OS uses lazy FPU ownership: OSContextInit clears MSR[FP],
     * then the first floating-point instruction transfers ownership to the
     * current context through the FPU-unavailable exception handler. The
     * native single-thread boot slice has one current guest context, so the
     * observable result of that handler is to enable MSR[FP] and retry the
     * instruction. Count the delivery so it remains visible in traces.
     */
    cpu->fpu_unavailable_count++;
    cpu->msr |= 0x00002000u;
    return true;
}

void ppc_fpscr_updated(CPUState* cpu) {
    (void)cpu;
}

typedef struct PPCReciprocalEstimate {
    s32 base;
    s32 decrement;
} PPCReciprocalEstimate;

/*
 * Gekko/Broadway reciprocal instructions return table estimates, not host
 * division results. Keep the hardware lookup constants explicit and freeze
 * representative output bits in runtime_tests.c.
 * The tables and reciprocal-estimate arithmetic below correspond to Dolphin's
 * Common/FloatUtils.cpp (Copyright 2018 Dolphin Emulator Project,
 * GPL-2.0-or-later). See native/licenses/README.md for the audited upstream
 * revision and scope; this notice does not license unrelated code in this file.
 */
static const PPCReciprocalEstimate ppc_fres_estimates[32] = {
    {0x7FF800, 0x3E1}, {0x783800, 0x3A7},
    {0x70EA00, 0x371}, {0x6A0800, 0x340},
    {0x638800, 0x313}, {0x5D6200, 0x2EA},
    {0x579000, 0x2C4}, {0x520800, 0x2A0},
    {0x4CC800, 0x27F}, {0x47CA00, 0x261},
    {0x430800, 0x245}, {0x3E8000, 0x22A},
    {0x3A2C00, 0x212}, {0x360800, 0x1FB},
    {0x321400, 0x1E5}, {0x2E4A00, 0x1D1},
    {0x2AA800, 0x1BE}, {0x272C00, 0x1AC},
    {0x23D600, 0x19B}, {0x209E00, 0x18B},
    {0x1D8800, 0x17C}, {0x1A9000, 0x16E},
    {0x17AE00, 0x15B}, {0x14F800, 0x15B},
    {0x124400, 0x143}, {0x0FBE00, 0x143},
    {0x0D3800, 0x12D}, {0x0ADE00, 0x12D},
    {0x088400, 0x11A}, {0x065000, 0x11A},
    {0x041C00, 0x108}, {0x020C00, 0x106},
};

static const PPCReciprocalEstimate ppc_frsqrte_estimates[32] = {
    {0x1A7E800, -0x568}, {0x17CB800, -0x4F3},
    {0x1552800, -0x48D}, {0x130C000, -0x435},
    {0x10F2000, -0x3E7}, {0x0EFF000, -0x3A2},
    {0x0D2E000, -0x365}, {0x0B7C000, -0x32E},
    {0x09E5000, -0x2FC}, {0x0867000, -0x2D0},
    {0x06FF000, -0x2A8}, {0x05AB800, -0x283},
    {0x046A000, -0x261}, {0x0339800, -0x243},
    {0x0218800, -0x226}, {0x0105800, -0x20B},
    {0x3FFA000, -0x7A4}, {0x3C29000, -0x700},
    {0x38AA000, -0x670}, {0x3572000, -0x5F2},
    {0x3279000, -0x584}, {0x2FB7000, -0x524},
    {0x2D26000, -0x4CC}, {0x2AC0000, -0x47E},
    {0x2881000, -0x43A}, {0x2665000, -0x3FA},
    {0x2468000, -0x3C2}, {0x2287000, -0x38E},
    {0x20C1000, -0x35E}, {0x1F12000, -0x332},
    {0x1D79000, -0x30A}, {0x1BF4000, -0x2E6},
};

static u64 ppc_f64_bits(f64 value) {
    u64 bits = 0u;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static f64 ppc_f64_from_bits(u64 bits) {
    f64 value = 0.0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static f64 ppc_quiet_nan(f64 value) {
    return ppc_f64_from_bits(
        ppc_f64_bits(value) | UINT64_C(0x0008000000000000)
    );
}

bool ppc_fres(CPUState* cpu, f64 value, f64* result) {
    (void)cpu;
    if (!result) {
        return false;
    }
    const u64 bits = ppc_f64_bits(value);
    const u64 mantissa = bits & UINT64_C(0x000FFFFFFFFFFFFF);
    const u64 sign = bits & UINT64_C(0x8000000000000000);
    const u64 exponent = bits & UINT64_C(0x7FF0000000000000);
    if (mantissa == 0u && exponent == 0u) {
        *result = copysign(INFINITY, value);
        return true;
    }
    if (exponent == UINT64_C(0x7FF0000000000000)) {
        *result = mantissa == 0u
            ? copysign(0.0, value)
            : ppc_quiet_nan(value);
        return true;
    }
    if (exponent < (UINT64_C(895) << 52u)) {
        *result = copysign((f64)FLT_MAX, value);
        return true;
    }
    if (exponent >= (UINT64_C(1149) << 52u)) {
        *result = copysign(0.0, value);
        return true;
    }

    const u64 output_exponent =
        (UINT64_C(0x7FD) << 52u) - exponent;
    const u32 index = (u32)(mantissa >> 37u);
    const PPCReciprocalEstimate estimate =
        ppc_fres_estimates[index / 1024u];
    const s64 fraction =
        estimate.base -
        (estimate.decrement * (s64)(index % 1024u) + 1) / 2;
    *result = ppc_f64_from_bits(
        sign |
        output_exponent |
        (u64)fraction << 29u
    );
    return true;
}

bool ppc_frsqrte(CPUState* cpu, f64 value, f64* result) {
    (void)cpu;
    if (!result) {
        return false;
    }
    const u64 bits = ppc_f64_bits(value);
    u64 mantissa = bits & UINT64_C(0x000FFFFFFFFFFFFF);
    const u64 sign = bits & UINT64_C(0x8000000000000000);
    s64 exponent = (s64)(
        bits & UINT64_C(0x7FF0000000000000)
    );
    if (mantissa == 0u && exponent == 0) {
        *result = sign ? -INFINITY : INFINITY;
        return true;
    }
    if (exponent == (s64)UINT64_C(0x7FF0000000000000)) {
        if (mantissa == 0u) {
            *result = sign
                ? ppc_f64_from_bits(
                    UINT64_C(0x7FF8000000000000)
                )
                : 0.0;
        } else {
            *result = ppc_quiet_nan(value);
        }
        return true;
    }
    if (sign) {
        *result = ppc_f64_from_bits(
            UINT64_C(0x7FF8000000000000)
        );
        return true;
    }
    if (exponent == 0) {
        do {
            exponent -= (s64)UINT64_C(1) << 52u;
            mantissa <<= 1u;
        } while (
            (mantissa & (UINT64_C(1) << 52u)) == 0u
        );
        mantissa &= UINT64_C(0x000FFFFFFFFFFFFF);
        exponent += (s64)UINT64_C(1) << 52u;
    }

    const s64 exponent_lsb =
        exponent & ((s64)UINT64_C(1) << 52u);
    const s64 output_exponent = (
        ((s64)UINT64_C(0x3FF) << 52u) -
        (
            exponent -
            ((s64)UINT64_C(0x3FE) << 52u)
        ) / 2
    ) & (s64)UINT64_C(0x7FF0000000000000);
    const u32 index =
        (u32)(((u64)exponent_lsb | mantissa) >> 37u);
    const PPCReciprocalEstimate estimate =
        ppc_frsqrte_estimates[index / 2048u];
    const s64 fraction =
        estimate.base +
        estimate.decrement * (s64)(index % 2048u);
    *result = ppc_f64_from_bits(
        (u64)output_exponent |
        (u64)fraction << 26u
    );
    return true;
}

bool ppc_fma(
    CPUState* cpu,
    f64 left,
    f64 multiplier,
    f64 addend,
    bool single,
    bool subtract,
    bool negative,
    f64* output
) {
    (void)cpu;
    if (!output) {
        return false;
    }
    f64 result = fma(left, multiplier, subtract ? -addend : addend);
    if (negative) {
        result = -result;
    }
    *output = single ? (f64)(f32)result : result;
    return true;
}

bool ppc_fctiw(CPUState* cpu, f64 value, bool toward_zero, u64* result) {
    (void)cpu;
    if (!result || isnan(value)) {
        return false;
    }
    f64 rounded = toward_zero ? trunc(value) : nearbyint(value);
    if (rounded > 2147483647.0) {
        rounded = 2147483647.0;
    } else if (rounded < -2147483648.0) {
        rounded = -2147483648.0;
    }
    *result = 0xFFF8000000000000ull | (u32)(s32)rounded;
    return true;
}

enum {
    PPC_QUANTIZE_FLOAT = 0,
    PPC_QUANTIZE_U8 = 4,
    PPC_QUANTIZE_U16 = 5,
    PPC_QUANTIZE_S8 = 6,
    PPC_QUANTIZE_S16 = 7,
};

static int ppc_quantization_exponent(u32 scale) {
    scale &= 0x3Fu;
    return scale < 32u ? (int)scale : (int)scale - 64;
}

static f32 ppc_quantize_factor(u32 scale) {
    return ldexpf(1.0f, ppc_quantization_exponent(scale));
}

static f32 ppc_dequantize_factor(u32 scale) {
    return ldexpf(1.0f, -ppc_quantization_exponent(scale));
}

static u32 ppc_quantize_unsigned(
    f64 value, f32 factor, u32 maximum
) {
    f32 scaled = (f32)value * factor;
    if (isnan(scaled) || scaled <= 0.0f) {
        return 0u;
    }
    if (scaled >= (f32)maximum) {
        return maximum;
    }
    return (u32)scaled;
}

static s32 ppc_quantize_signed(
    f64 value, f32 factor, s32 minimum, s32 maximum
) {
    f32 scaled = (f32)value * factor;
    if (isnan(scaled)) {
        return 0;
    }
    if (scaled <= (f32)minimum) {
        return minimum;
    }
    if (scaled >= (f32)maximum) {
        return maximum;
    }
    return (s32)scaled;
}

bool ppc_psq_load(
    CPUState* cpu,
    u8 destination,
    u32 address,
    bool single,
    u8 gqr,
    bool indexed,
    u32 instruction_address
) {
    (void)indexed;
    (void)instruction_address;
    if (destination >= 32 || gqr >= 8) {
        return false;
    }

    u32 value = cpu->gqr[gqr];
    u32 load_type = (value >> 16) & 0x7u;
    u32 load_scale = (value >> 24) & 0x3Fu;
    f32 factor = ppc_dequantize_factor(load_scale);
    f64 first = 0.0;
    f64 second = 1.0;
    switch (load_type) {
        case PPC_QUANTIZE_FLOAT: {
            union {
                u32 bits;
                f32 value;
            } converted = {mem_read32(cpu, address)};
            first = converted.value;
            if (!single) {
                converted.bits = mem_read32(cpu, address + 4u);
                second = converted.value;
            }
            break;
        }
        case PPC_QUANTIZE_U8:
            first = (f32)mem_read8(cpu, address) * factor;
            if (!single) {
                second = (f32)mem_read8(cpu, address + 1u) * factor;
            }
            break;
        case PPC_QUANTIZE_U16:
            first = (f32)mem_read16(cpu, address) * factor;
            if (!single) {
                second = (f32)mem_read16(cpu, address + 2u) * factor;
            }
            break;
        case PPC_QUANTIZE_S8:
            first = (f32)(s8)mem_read8(cpu, address) * factor;
            if (!single) {
                second =
                    (f32)(s8)mem_read8(cpu, address + 1u) * factor;
            }
            break;
        case PPC_QUANTIZE_S16:
            first = (f32)(s16)mem_read16(cpu, address) * factor;
            if (!single) {
                second =
                    (f32)(s16)mem_read16(cpu, address + 2u) * factor;
            }
            break;
        default:
            return false;
    }
    cpu->fpr[destination] = first;
    cpu->ps1[destination] = second;
    return cpu->stop_reason == PROTECTOR_STOP_NONE;
}

bool ppc_psq_store(
    CPUState* cpu,
    u8 source,
    u32 address,
    bool single,
    u8 gqr,
    bool indexed,
    u32 instruction_address
) {
    (void)indexed;
    (void)instruction_address;
    if (source >= 32 || gqr >= 8) {
        return false;
    }

    u32 value = cpu->gqr[gqr];
    u32 store_type = value & 0x7u;
    u32 store_scale = (value >> 8) & 0x3Fu;
    f32 factor = ppc_quantize_factor(store_scale);
    switch (store_type) {
        case PPC_QUANTIZE_FLOAT: {
            union {
                f32 value;
                u32 bits;
            } converted = {(f32)cpu->fpr[source]};
            mem_write32(cpu, address, converted.bits);
            if (!single) {
                converted.value = (f32)cpu->ps1[source];
                mem_write32(cpu, address + 4u, converted.bits);
            }
            break;
        }
        case PPC_QUANTIZE_U8:
            mem_write8(
                cpu,
                address,
                (u8)ppc_quantize_unsigned(
                    cpu->fpr[source], factor, UINT8_MAX
                )
            );
            if (!single) {
                mem_write8(
                    cpu,
                    address + 1u,
                    (u8)ppc_quantize_unsigned(
                        cpu->ps1[source], factor, UINT8_MAX
                    )
                );
            }
            break;
        case PPC_QUANTIZE_U16:
            mem_write16(
                cpu,
                address,
                (u16)ppc_quantize_unsigned(
                    cpu->fpr[source], factor, UINT16_MAX
                )
            );
            if (!single) {
                mem_write16(
                    cpu,
                    address + 2u,
                    (u16)ppc_quantize_unsigned(
                        cpu->ps1[source], factor, UINT16_MAX
                    )
                );
            }
            break;
        case PPC_QUANTIZE_S8:
            mem_write8(
                cpu,
                address,
                (u8)(s8)ppc_quantize_signed(
                    cpu->fpr[source], factor, INT8_MIN, INT8_MAX
                )
            );
            if (!single) {
                mem_write8(
                    cpu,
                    address + 1u,
                    (u8)(s8)ppc_quantize_signed(
                        cpu->ps1[source],
                        factor,
                        INT8_MIN,
                        INT8_MAX
                    )
                );
            }
            break;
        case PPC_QUANTIZE_S16:
            mem_write16(
                cpu,
                address,
                (u16)(s16)ppc_quantize_signed(
                    cpu->fpr[source], factor, INT16_MIN, INT16_MAX
                )
            );
            if (!single) {
                mem_write16(
                    cpu,
                    address + 2u,
                    (u16)(s16)ppc_quantize_signed(
                        cpu->ps1[source],
                        factor,
                        INT16_MIN,
                        INT16_MAX
                    )
                );
            }
            break;
        default:
            return false;
    }
    return cpu->stop_reason == PROTECTOR_STOP_NONE;
}
