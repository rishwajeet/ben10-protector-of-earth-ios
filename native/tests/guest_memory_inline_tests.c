#define PROTECTOR_INLINE_GUEST_MEMORY 1
#include "protector/cpu.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The inline accessors must be observationally identical to the out-of-line
 * ones: value, byte order, counters, reservation, external handlers and stops.
 * A parenthesized name, (mem_read32)(...), calls the out-of-line accessor. */

typedef struct ExternalLog {
    u32 reads;
    u32 writes;
    u32 last_address;
    u64 last_value;
    u8 last_size;
} ExternalLog;

static ExternalLog external_logs[2];

static u64 external_read(CPUState* cpu, u32 address, u8 size) {
    ExternalLog* log = &external_logs[cpu->external_user_data != NULL];
    log->reads++;
    log->last_address = address;
    log->last_size = size;
    return 0xA5A5A5A55A5A5A5Aull ^ address ^ size;
}

static void external_write(CPUState* cpu, u32 address, u64 value, u8 size) {
    ExternalLog* log = &external_logs[cpu->external_user_data != NULL];
    log->writes++;
    log->last_address = address;
    log->last_value = value;
    log->last_size = size;
}

static u64 next_random(u64* state) {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    return *state;
}

static void prepare(CPUState* cpu, bool external, bool second) {
    assert(protector_cpu_init(cpu));
    u64 seed = 0x9E3779B97F4A7C15ull;
    for (u32 i = 0; i < cpu->ram_size; ++i) cpu->ram[i] = (u8)next_random(&seed);
    for (u32 i = 0; i < cpu->mem2_size; ++i) cpu->mem2[i] = (u8)next_random(&seed);
    if (external) {
        cpu->external_read = external_read;
        cpu->external_write = external_write;
    }
    cpu->external_user_data = second ? (void*)cpu : NULL;
}

static void assert_same(const CPUState* a, const CPUState* b) {
    assert(a->memory_read_count == b->memory_read_count);
    assert(a->memory_write_count == b->memory_write_count);
    assert(a->reservation_valid == b->reservation_valid);
    assert(a->reservation_address == b->reservation_address);
    assert(a->stop_reason == b->stop_reason);
    assert(a->stop_address == b->stop_address);
    assert(!memcmp(&external_logs[0], &external_logs[1], sizeof(ExternalLog)));
}

static const u32 kAddresses[] = {
    GC_RAM_BASE, GC_RAM_BASE + 1u, GC_RAM_BASE + 0x1234567u,
    GC_RAM_BASE + GC_MAIN_RAM_SIZE - 8u, GC_RAM_BASE + GC_MAIN_RAM_SIZE - 7u,
    GC_RAM_BASE + GC_MAIN_RAM_SIZE - 4u, GC_RAM_BASE + GC_MAIN_RAM_SIZE - 3u,
    GC_RAM_BASE + GC_MAIN_RAM_SIZE - 2u, GC_RAM_BASE + GC_MAIN_RAM_SIZE - 1u,
    GC_RAM_BASE + GC_MAIN_RAM_SIZE, GC_RAM_BASE - 1u, GC_RAM_BASE - 4u,
    GC_RAM_UNCACHED, GC_RAM_UNCACHED + 0x40u, GC_RAM_UNCACHED + GC_MAIN_RAM_SIZE - 2u,
    WII_MEM2_BASE, WII_MEM2_BASE + 3u, WII_MEM2_BASE + 0x2345678u,
    WII_MEM2_BASE + WII_MEM2_SIZE - 8u, WII_MEM2_BASE + WII_MEM2_SIZE - 5u,
    WII_MEM2_BASE + WII_MEM2_SIZE - 1u, WII_MEM2_BASE + WII_MEM2_SIZE,
    WII_MEM2_BASE - 2u, WII_MEM2_UNCACHED, WII_MEM2_UNCACHED + 0x80u,
    0xCC008000u, 0xCD000004u, 0x00001000u, 0x00000000u, 0xFFFFFFFCu, 0xFFFFFFFFu,
};

static void compare_reads(bool external) {
    CPUState a, b;
    prepare(&a, external, false);
    prepare(&b, external, true);
    memset(external_logs, 0, sizeof(external_logs));
    u64 seed = 0x1234ull;
    for (size_t pass = 0; pass < 2000; ++pass) {
        const u32 address = pass < sizeof(kAddresses) / sizeof(kAddresses[0])
            ? kAddresses[pass]
            : (pass & 1u ? GC_RAM_BASE : WII_MEM2_BASE) + (u32)(next_random(&seed) % 0x5000000u);
        a.stop_reason = b.stop_reason = PROTECTOR_STOP_NONE;
        a.stop_address = b.stop_address = 0;
        assert(mem_read8(&a, address) == (mem_read8)(&b, address));
        assert_same(&a, &b);
        assert(mem_read16(&a, address) == (mem_read16)(&b, address));
        assert_same(&a, &b);
        assert(mem_read32(&a, address) == (mem_read32)(&b, address));
        assert_same(&a, &b);
        assert(mem_read64(&a, address) == (mem_read64)(&b, address));
        assert_same(&a, &b);
    }
    protector_cpu_destroy(&a);
    protector_cpu_destroy(&b);
}

static void compare_writes(bool external, bool watch) {
    CPUState a, b;
    prepare(&a, external, false);
    prepare(&b, external, true);
    memset(external_logs, 0, sizeof(external_logs));
    u64 seed = 0x5678ull;
    for (size_t pass = 0; pass < 2000; ++pass) {
        const u32 address = pass < sizeof(kAddresses) / sizeof(kAddresses[0])
            ? kAddresses[pass]
            : (pass & 1u ? GC_RAM_BASE : WII_MEM2_BASE) + (u32)(next_random(&seed) % 0x5000000u);
        const u64 value = next_random(&seed);
        const u32 reservation = (pass % 3u) == 0u ? address :
            (pass % 3u) == 1u ? address + 32u : (address & ~31u) + 31u;
        a.reservation_valid = b.reservation_valid = (pass & 2u) != 0u;
        a.reservation_address = b.reservation_address = reservation;
        a.stop_reason = b.stop_reason = PROTECTOR_STOP_NONE;
        a.stop_address = b.stop_address = 0;
        if (watch) {
            /* An armed watch before its start frame: identical silent path. */
            a.debug_memory_write_watch_address = b.debug_memory_write_watch_address = GC_RAM_BASE + 0x100u;
            a.debug_memory_write_watch_start_frame = b.debug_memory_write_watch_start_frame = UINT64_MAX;
        }
        switch (pass % 4u) {
            case 0: mem_write8(&a, address, (u8)value); (mem_write8)(&b, address, (u8)value); break;
            case 1: mem_write16(&a, address, (u16)value); (mem_write16)(&b, address, (u16)value); break;
            case 2: mem_write32(&a, address, (u32)value); (mem_write32)(&b, address, (u32)value); break;
            default: mem_write64(&a, address, value); (mem_write64)(&b, address, value); break;
        }
        assert_same(&a, &b);
    }
    assert(!memcmp(a.ram, b.ram, a.ram_size));
    assert(!memcmp(a.mem2, b.mem2, a.mem2_size));
    protector_cpu_destroy(&a);
    protector_cpu_destroy(&b);
}

int main(void) {
    compare_reads(true);
    compare_reads(false);
    compare_writes(true, false);
    compare_writes(false, false);
    compare_writes(true, true);
    puts("guest memory inline accessors match out-of-line accessors");
    return 0;
}
