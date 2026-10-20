#ifndef PROTECTOR_CPU_H
#define PROTECTOR_CPU_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t s8;
typedef int16_t s16;
typedef int32_t s32;
typedef int64_t s64;
typedef float f32;
typedef double f64;

#define GC_MAIN_RAM_SIZE (24u * 1024u * 1024u)
#define GC_RAM_BASE 0x80000000u
#define GC_RAM_UNCACHED 0xC0000000u
#define WII_MEM2_SIZE (64u * 1024u * 1024u)
#define WII_MEM2_BASE 0x90000000u
#define WII_MEM2_UNCACHED 0xD0000000u

#define PPC_EXC_PROGRAM 0x00000001u
#define PPC_EXC_DSI 0x00000002u
#define PPC_EXC_ALIGNMENT 0x00000004u
#define PPC_EXC_SYSTEM_CALL 0x00000008u
#define PPC_PROGRAM_ILLEGAL 0x00080000u
#define PPC_PROGRAM_PRIV 0x00040000u
#define PPC_PROGRAM_TRAP 0x00020000u
#define PPC_GEKKO_PVR 0x00083214u
#define PPC_BROADWAY_PVR 0x00087102u
#define PPC_MSR_EE 0x00008000u
#define PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK 12u

typedef enum ProtectorStopReason {
    PROTECTOR_STOP_NONE = 0,
    PROTECTOR_STOP_HOST_SERVICE = 1,
    PROTECTOR_STOP_UNMAPPED_MEMORY = 2,
    PROTECTOR_STOP_ALIGNMENT = 3,
    PROTECTOR_STOP_UNKNOWN_INSTRUCTION = 4,
    PROTECTOR_STOP_EXCEPTION = 5,
    PROTECTOR_STOP_UNEXPECTED_DISPATCH = 6,
    PROTECTOR_STOP_PLATFORM_ERROR = 7,
} ProtectorStopReason;

typedef struct CPUState CPUState;
typedef u64 (*PPCExternalRead)(CPUState* cpu, u32 address, u8 size);
typedef void (*PPCExternalWrite)(
    CPUState* cpu, u32 address, u64 value, u8 size
);
typedef bool (*PPCHostCall)(CPUState* cpu, u32 address);
typedef bool (*PPCSystemCall)(CPUState* cpu, u32 address);
typedef void (*PPCStopHandler)(CPUState* cpu);
typedef void (*PPCInstructionFallback)(
    CPUState* cpu, u32 instruction, u32 address
);
typedef void (*PPCCacheControl)(
    CPUState* cpu, u8 operation, u32 address, u32 instruction_address
);

struct CPUState {
    u32 gpr[32];
    f64 fpr[32];
    f64 ps1[32];
    u32 pc;
    u32 lr;
    u32 ctr;
    u32 cr;
    u32 xer;
    u32 fpscr;
    u32 msr;
    u32 srr0;
    u32 srr1;
    u32 ear;
    u32 hid2;
    u64 timebase;
    u8 timebase_cycle_remainder;
    u64 core_cycles;
    u64 decrementer_deadline;
    u64 decrementer_deadline_core_cycles;
    bool decrementer_armed;
    u64 decrementer_interrupt_count;
    u32 sr[16];
    u32 gqr[8];
    u32 spr[1024];
    u32 exception;
    u32 program_exception;
    s64 downcount;

    u8* ram;
    u32 ram_size;
    u8* mem2;
    u32 mem2_size;

    u32 reservation_address;
    bool reservation_valid;

    PPCExternalRead external_read;
    PPCExternalWrite external_write;
    PPCInstructionFallback instruction_fallback;
    PPCHostCall host_call;
    PPCSystemCall system_call;
    PPCStopHandler stop_handler;
    PPCCacheControl cache_control;
    void* external_user_data;

    ProtectorStopReason stop_reason;
    u32 stop_pc;
    u32 stop_instruction;
    u32 stop_address;
    u64 memory_read_count;
    u64 memory_write_count;
    u64 cache_operation_count;
    u64 translated_dispatch_count;
    u64 presented_frame_count;
    bool content_trace_logical_clock_valid;
    u64 content_trace_logical_frame;
    u64 content_trace_absolute_checkpoint;
    u64 content_trace_request_serial;
    u64 atomic_success_count;
    u64 atomic_failure_count;
    u64 fpu_unavailable_count;
    u32 debug_memory_write_watch_address;
    u64 debug_memory_write_watch_start_frame;
    bool trap_privileged_boot;
};

typedef struct ProtectorDolInfo {
    u32 entry_point;
    u32 bss_address;
    u32 bss_size;
    u32 section_count;
    u64 loaded_bytes;
} ProtectorDolInfo;

static inline u16 bswap16(u16 value) {
    return (u16)((value << 8) | (value >> 8));
}

static inline u32 bswap32(u32 value) {
    return ((value & 0x000000FFu) << 24) |
           ((value & 0x0000FF00u) << 8) |
           ((value & 0x00FF0000u) >> 8) |
           ((value & 0xFF000000u) >> 24);
}

bool protector_cpu_init(CPUState* cpu);
void protector_cpu_reset(CPUState* cpu);
void protector_cpu_destroy(CPUState* cpu);
const char* protector_stop_reason_name(ProtectorStopReason reason);
void protector_stop(
    CPUState* cpu,
    ProtectorStopReason reason,
    u32 pc,
    u32 instruction,
    u32 address
);
bool protector_trap_instruction(
    CPUState* cpu, u32 pc, u32 instruction, const char* service
);

bool protector_load_dol(
    CPUState* cpu,
    const char* path,
    ProtectorDolInfo* info,
    char* error,
    size_t error_capacity
);
void protector_prepare_wii_boot(CPUState* cpu);

u64 mem_read64(CPUState* cpu, u32 address);
u32 mem_read32(CPUState* cpu, u32 address);
u16 mem_read16(CPUState* cpu, u32 address);
u8 mem_read8(CPUState* cpu, u32 address);
void mem_write64(CPUState* cpu, u32 address, u64 value);
void mem_write32(CPUState* cpu, u32 address, u32 value);
void mem_write16(CPUState* cpu, u32 address, u16 value);
void mem_write8(CPUState* cpu, u32 address, u8 value);

u32 protector_lwarx(CPUState* cpu, u32 address);
bool protector_stwcx(CPUState* cpu, u32 address, u32 value);
void protector_cache_operation(
    CPUState* cpu, u8 operation, u32 address, u32 instruction_address
);

/* Translated chunks perform a guest access for nearly every source load and
 * store. A chunk compiled with PROTECTOR_INLINE_GUEST_MEMORY resolves cached
 * MEM1/MEM2 accesses inline with the accessors' exact range, byte-order,
 * counter and reservation semantics; uncached aliases, MMIO, unmapped
 * addresses and stores while a debug write watch is armed take the
 * out-of-line accessors unchanged. */
#if defined(PROTECTOR_INLINE_GUEST_MEMORY) && \
    defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
static inline u8* protector_guest_cached(CPUState* cpu, u32 address, u32 size) {
    u32 offset = address - GC_RAM_BASE;
    if (__builtin_expect(offset < cpu->ram_size, 1))
        return cpu->ram_size - offset >= size ? cpu->ram + offset : NULL;
    offset = address - WII_MEM2_BASE;
    if (cpu->mem2 && offset < cpu->mem2_size && cpu->mem2_size - offset >= size)
        return cpu->mem2 + offset;
    return NULL;
}

static inline void protector_guest_store_reservation(CPUState* cpu, u32 address) {
    if (cpu->reservation_valid && ((cpu->reservation_address ^ address) & ~31u) == 0u)
        cpu->reservation_valid = false;
}

#define PROTECTOR_INLINE_READ(bits, type, swap)                                  \
    static inline type protector_inline_read##bits(CPUState* cpu, u32 address) { \
        const u8* bytes = protector_guest_cached(cpu, address, bits / 8u);       \
        if (__builtin_expect(bytes != NULL, 1)) {                                \
            type value;                                                          \
            __builtin_memcpy(&value, bytes, sizeof(value));                      \
            cpu->memory_read_count++;                                            \
            return swap(value);                                                  \
        }                                                                        \
        return mem_read##bits(cpu, address);                                     \
    }
#define PROTECTOR_INLINE_WRITE(bits, type, swap)                                 \
    static inline void protector_inline_write##bits(                             \
        CPUState* cpu, u32 address, type value) {                                \
        u8* bytes = cpu->debug_memory_write_watch_address == 0u                  \
            ? protector_guest_cached(cpu, address, bits / 8u) : NULL;            \
        if (__builtin_expect(bytes != NULL, 1)) {                                \
            protector_guest_store_reservation(cpu, address);                     \
            value = swap(value);                                                 \
            __builtin_memcpy(bytes, &value, sizeof(value));                      \
            cpu->memory_write_count++;                                           \
            return;                                                              \
        }                                                                        \
        mem_write##bits(cpu, address, value);                                    \
    }
#define PROTECTOR_SWAP_NONE(value) (value)
PROTECTOR_INLINE_READ(8, u8, PROTECTOR_SWAP_NONE)
PROTECTOR_INLINE_READ(16, u16, __builtin_bswap16)
PROTECTOR_INLINE_READ(32, u32, __builtin_bswap32)
PROTECTOR_INLINE_READ(64, u64, __builtin_bswap64)
PROTECTOR_INLINE_WRITE(8, u8, PROTECTOR_SWAP_NONE)
PROTECTOR_INLINE_WRITE(16, u16, __builtin_bswap16)
PROTECTOR_INLINE_WRITE(32, u32, __builtin_bswap32)
PROTECTOR_INLINE_WRITE(64, u64, __builtin_bswap64)
#undef PROTECTOR_INLINE_READ
#undef PROTECTOR_INLINE_WRITE
#undef PROTECTOR_SWAP_NONE
#define mem_read8(cpu, address) protector_inline_read8((cpu), (address))
#define mem_read16(cpu, address) protector_inline_read16((cpu), (address))
#define mem_read32(cpu, address) protector_inline_read32((cpu), (address))
#define mem_read64(cpu, address) protector_inline_read64((cpu), (address))
#define mem_write8(cpu, address, value) protector_inline_write8((cpu), (address), (value))
#define mem_write16(cpu, address, value) protector_inline_write16((cpu), (address), (value))
#define mem_write32(cpu, address, value) protector_inline_write32((cpu), (address), (value))
#define mem_write64(cpu, address, value) protector_inline_write64((cpu), (address), (value))
#endif

void ppc_fallback_instruction(CPUState* cpu, u32 instruction, u32 address);
bool ppc_host_call(CPUState* cpu, u32 address);
void ppc_program_exception(CPUState* cpu, u32 cause, u32 address);
void ppc_system_call_exception(CPUState* cpu, u32 address);
void ppc_rfi(CPUState* cpu, u32 address);
void ppc_memory_fence(void);
u32 ppc_mftb(CPUState* cpu, u16 register_index, u32 address);
void ppc_advance_broadway_cycles(CPUState* cpu, u64 cycles);
bool ppc_decrementer_pending(const CPUState* cpu);
void ppc_decrementer_delivered(CPUState* cpu);
bool ppc_trap_condition(u8 options, u32 left, u32 right);
bool ppc_fp_available(CPUState* cpu, u32 address);
void ppc_fpscr_updated(CPUState* cpu);
bool ppc_fres(CPUState* cpu, f64 value, f64* result);
bool ppc_frsqrte(CPUState* cpu, f64 value, f64* result);
bool ppc_fma(
    CPUState* cpu,
    f64 left,
    f64 multiplier,
    f64 addend,
    bool single,
    bool subtract,
    bool negative,
    f64* output
);
bool ppc_fctiw(CPUState* cpu, f64 value, bool toward_zero, u64* result);
bool ppc_psq_load(
    CPUState* cpu,
    u8 destination,
    u32 address,
    bool single,
    u8 gqr,
    bool indexed,
    u32 instruction_address
);
bool ppc_psq_store(
    CPUState* cpu,
    u8 source,
    u32 address,
    bool single,
    u8 gqr,
    bool indexed,
    u32 instruction_address
);

#ifdef __cplusplus
}
#endif

#endif
