#include "protector/cpu.h"
#include "protector/live_gx.h"
#include "protector/visibility.h"
#include "protector/platform.h"

#include <stdlib.h>
#include <math.h>
#include <stdio.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>

static int failures = 0;

typedef struct LiveGXProbe {
    u32 frame_index;
    size_t fifo_size;
    const CPUState* cpu;
    u32 calls;
} LiveGXProbe;

static ProtectorLiveGXResult receive_live_gx(
    u32 frame_index,
    const u8* fifo,
    size_t fifo_size,
    CPUState* cpu,
    void* user_data
) {
    LiveGXProbe* probe = (LiveGXProbe*)user_data;
    probe->frame_index = frame_index;
    probe->fifo_size = fifo_size;
    probe->cpu = cpu;
    probe->calls++;
    return fifo && fifo_size == 3u
        ? PROTECTOR_LIVE_GX_COMPLETE
        : PROTECTOR_LIVE_GX_ERROR;
}
static u64 external_read_value = 0;
static u32 handled_system_call = 0;

#define CHECK(expression)                                                      \
    do {                                                                       \
        if (!(expression)) {                                                   \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expression); \
            failures++;                                                        \
        }                                                                      \
    } while (0)

static u64 test_external_read(CPUState* cpu, u32 address, u8 size) {
    (void)cpu;
    (void)address;
    (void)size;
    return external_read_value;
}

static bool test_system_call(CPUState* cpu, u32 address) {
    handled_system_call = address;
    cpu->pc = address + 4u;
    return true;
}

static void write_be32(u8* destination, u32 value) {
    destination[0] = (u8)(value >> 24);
    destination[1] = (u8)(value >> 16);
    destination[2] = (u8)(value >> 8);
    destination[3] = (u8)value;
}

static u64 f64_bits(f64 value) {
    u64 bits = 0u;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static f64 f64_from_bits(u64 bits) {
    f64 value = 0.0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static void test_big_endian_memory_and_aliases(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));

    mem_write32(&cpu, 0x80001000u, 0x11223344u);
    CHECK(cpu.ram[0x1000] == 0x11);
    CHECK(cpu.ram[0x1001] == 0x22);
    CHECK(cpu.ram[0x1002] == 0x33);
    CHECK(cpu.ram[0x1003] == 0x44);
    CHECK(mem_read32(&cpu, 0xC0001000u) == 0x11223344u);

    mem_write64(&cpu, 0x90000000u, 0x0123456789ABCDEFull);
    CHECK(mem_read64(&cpu, 0xD0000000u) == 0x0123456789ABCDEFull);
    CHECK(cpu.memory_write_count == 2);
    protector_cpu_destroy(&cpu);
}

static void test_unaligned_scalar_access_and_unmapped_stops(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));

    mem_write32(&cpu, 0x80000002u, 0x11223344u);
    CHECK(mem_read32(&cpu, 0x80000002u) == 0x11223344u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_NONE);

    (void)protector_lwarx(&cpu, 0x80000002u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_ALIGNMENT);
    CHECK(cpu.stop_address == 0x80000002u);

    cpu.stop_reason = PROTECTOR_STOP_NONE;
    (void)mem_read8(&cpu, 0x70000000u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_UNMAPPED_MEMORY);
    CHECK(cpu.stop_address == 0x70000000u);
    protector_cpu_destroy(&cpu);
}

static void test_memory_write_watch_preserves_post_store_diagnostics(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    int capture[2];
    if (pipe(capture) != 0) {
        CHECK(false);
        protector_cpu_destroy(&cpu);
        return;
    }
    fflush(stderr);
    const int saved_stderr = dup(STDERR_FILENO);
    if (saved_stderr < 0 || dup2(capture[1], STDERR_FILENO) < 0) {
        CHECK(false);
        close(capture[0]);
        close(capture[1]);
        if (saved_stderr >= 0) close(saved_stderr);
        protector_cpu_destroy(&cpu);
        return;
    }
    close(capture[1]);

    mem_write32(&cpu, 0x80001000u, 0x11111111u);  // Watch disabled.
    cpu.debug_memory_write_watch_address = 0x80001000u;
    cpu.debug_memory_write_watch_start_frame = 10u;
    cpu.presented_frame_count = 9u;
    mem_write32(&cpu, 0x80001000u, 0x22222222u);  // Before start frame.
    cpu.presented_frame_count = 10u;
    mem_write32(&cpu, 0x80001010u, 0x33333333u);  // Nonoverlapping.
    (void)protector_lwarx(&cpu, 0xC0001000u);
    mem_write32(&cpu, 0xC0001000u, 0x33445566u);  // MEM1 alias.
    CHECK(!cpu.reservation_valid);
    CHECK(mem_read32(&cpu, 0x80001000u) == 0x33445566u);
    cpu.debug_memory_write_watch_address = 0x90001000u;
    mem_write32(&cpu, 0xD0001000u, 0xAABBCCDDu);  // MEM2 alias.
    CHECK(mem_read32(&cpu, 0x90001000u) == 0xAABBCCDDu);
    CHECK(cpu.memory_write_count == 5u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_NONE);

    fflush(stderr);
    CHECK(dup2(saved_stderr, STDERR_FILENO) >= 0);
    close(saved_stderr);
    char log[8192];
    size_t used = 0u;
    ssize_t count;
    while (used + 1u < sizeof(log) &&
           (count = read(capture[0], log + used, sizeof(log) - used - 1u)) > 0) {
        used += (size_t)count;
    }
    log[used] = '\0';
    close(capture[0]);
    const char* first = strstr(log, "memory_write_watch pc=");
    const char* second = first ? strstr(first + 1, "memory_write_watch pc=") : NULL;
    CHECK(first != NULL && second != NULL);
    CHECK(!second || strstr(second + 1, "memory_write_watch pc=") == NULL);
    CHECK(strstr(log, "address=0xC0001000 value=0x33445566") != NULL);
    CHECK(strstr(log, "address=0xD0001000 value=0xAABBCCDD") != NULL);
    CHECK(strstr(log, "frame=10") != NULL);
    CHECK(strstr(log, "value=0x11111111") == NULL);
    CHECK(strstr(log, "value=0x22222222") == NULL);
    CHECK(strstr(log, "value=0x33333333") == NULL);
    protector_cpu_destroy(&cpu);
}

static void test_external_memory_is_explicitly_delegated(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    external_read_value = 0x12345678u;
    cpu.external_read = test_external_read;

    CHECK(mem_read32(&cpu, 0xCC003004u) == 0x12345678u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_NONE);
    protector_cpu_destroy(&cpu);
}

static void test_atomic_reservation(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    mem_write32(&cpu, 0x80002000u, 3);

    CHECK(protector_lwarx(&cpu, 0x80002000u) == 3);
    CHECK(protector_stwcx(&cpu, 0x80002000u, 4));
    CHECK(mem_read32(&cpu, 0x80002000u) == 4);
    CHECK((cpu.cr & 0x20000000u) != 0);

    CHECK(!protector_stwcx(&cpu, 0x80002000u, 5));
    CHECK(mem_read32(&cpu, 0x80002000u) == 4);
    CHECK(cpu.atomic_success_count == 1);
    CHECK(cpu.atomic_failure_count == 1);
    protector_cpu_destroy(&cpu);
}

static void test_cache_and_exception_paths_are_explicit(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));

    protector_cache_operation(&cpu, 3, 0x80003000u, 0x80004000u);
    CHECK(cpu.cache_operation_count == 1);

    ppc_fallback_instruction(&cpu, 0xFFFFFFFFu, 0x80004000u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_UNKNOWN_INSTRUCTION);
    CHECK(cpu.stop_instruction == 0xFFFFFFFFu);

    cpu.stop_reason = PROTECTOR_STOP_NONE;
    ppc_system_call_exception(&cpu, 0x80004004u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_EXCEPTION);
    CHECK((cpu.exception & PPC_EXC_SYSTEM_CALL) != 0);
    CHECK(cpu.srr0 == 0x80004008u);

    cpu.stop_reason = PROTECTOR_STOP_NONE;
    cpu.exception = 0;
    handled_system_call = 0;
    cpu.system_call = test_system_call;
    ppc_system_call_exception(&cpu, 0x80004010u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_NONE);
    CHECK(cpu.exception == 0);
    CHECK(cpu.pc == 0x80004014u);
    CHECK(handled_system_call == 0x80004010u);
    protector_cpu_destroy(&cpu);
}

static void test_timebase_register_halves(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    cpu.timebase = 0x1122334455667788ull;

    CHECK(ppc_mftb(&cpu, 268u, 0x80001000u) == 0x55667788u);
    CHECK(ppc_mftb(&cpu, 269u, 0x80001004u) == 0x11223344u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_NONE);
    (void)ppc_mftb(&cpu, 270u, 0x80001008u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_UNKNOWN_INSTRUCTION);
    CHECK(cpu.stop_address == 270u);
    protector_cpu_destroy(&cpu);
}

static void test_broadway_cycle_to_timebase_ratio(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    cpu.timebase = 100u;

    ppc_advance_broadway_cycles(&cpu, 11u);
    CHECK(cpu.timebase == 100u);
    CHECK(cpu.timebase_cycle_remainder == 11u);
    ppc_advance_broadway_cycles(&cpu, 1u);
    CHECK(cpu.timebase == 101u);
    CHECK(cpu.timebase_cycle_remainder == 0u);

    ppc_advance_broadway_cycles(&cpu, 25u);
    CHECK(cpu.timebase == 103u);
    CHECK(cpu.timebase_cycle_remainder == 1u);
    ppc_advance_broadway_cycles(&cpu, 35u);
    CHECK(cpu.timebase == 106u);
    CHECK(cpu.timebase_cycle_remainder == 0u);

    ppc_advance_broadway_cycles(
        &cpu,
        UINT64_MAX -
            (UINT64_MAX %
             PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK)
    );
    CHECK(
        cpu.timebase ==
        106u +
            UINT64_MAX /
                PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK
    );
    CHECK(cpu.timebase_cycle_remainder == 0u);
    protector_cpu_destroy(&cpu);
}

static void test_live_gx_sink_is_explicit_and_in_memory(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    LiveGXProbe probe = {0};
    const u8 fifo[] = {0x61u, 0x41u, 0x00u};

    CHECK(!protector_live_gx_has_sink());
    CHECK(
        protector_live_gx_submit(
            4u, fifo, sizeof(fifo), &cpu
        ) == PROTECTOR_LIVE_GX_CONTINUE
    );
    protector_live_gx_set_sink(receive_live_gx, &probe);
    CHECK(protector_live_gx_has_sink());
    CHECK(
        protector_live_gx_submit(
            7u, fifo, sizeof(fifo), &cpu
        ) == PROTECTOR_LIVE_GX_COMPLETE
    );
    CHECK(probe.calls == 1u);
    CHECK(probe.frame_index == 7u);
    CHECK(probe.fifo_size == sizeof(fifo));
    CHECK(probe.cpu == &cpu);
    protector_live_gx_set_sink(NULL, NULL);
    CHECK(!protector_live_gx_has_sink());
    protector_cpu_destroy(&cpu);
}

static void test_static_visibility_envelope(void) {
    CHECK(protector_visibility_render_caller(0x800233C4));
    CHECK(protector_visibility_render_caller(0x8003A4C0));
    CHECK(!protector_visibility_render_caller(0x8003A4BC));
    CHECK(!protector_visibility_render_caller(0));
    protector_visibility_set_presentation_aspect(2622.0/1206.0);
    CHECK(protector_visibility_presentation_aspect()==2622.0/1206.0);
    protector_visibility_set_presentation_aspect(NAN);
    protector_visibility_set_presentation_aspect(3.1);
    CHECK(protector_visibility_presentation_aspect()==2622.0/1206.0);
    // A small object already inside the physical phone's visible wings must
    // not be rejected by the old narrower horizontal sphere plane.
    const double phone_bound=protector_static_visibility_half_width(10,7,0.7,1,
        protector_visibility_presentation_aspect());
    CHECK(phone_bound>=15 && phone_bound<24);
    protector_visibility_set_presentation_aspect(16.0/9.0);
    const double original = 14.9048967;
    const double height = 10.4334278;
    const double radius = 22.9641914;
    const double x = 38.7593269;
    CHECK(original < x - radius); // actual Canyon source rejects this rock
    const double wide = protector_static_visibility_half_width(original, height, 0.7, radius, 3.0);
    CHECK(wide >= x - radius);
    CHECK(protector_static_visibility_half_width(wide, height, 0.7, radius, 3.0) == wide);
    CHECK(protector_static_visibility_half_width(original, height, 0.7, radius, 4.0 / 3.0) == original);
    CHECK(protector_static_visibility_half_width(original, height, 0.7, radius, 3.01) == original);
    CHECK(protector_static_visibility_half_width(original, height, 0, radius, 3.0) == original);
    CHECK(protector_static_visibility_half_width(original, -1, 0.7, radius, 3.0) == original);
    CHECK(protector_static_visibility_half_width(original, height, 0.7, -1, 3.0) == original);
    CHECK(protector_static_visibility_half_width(original, height, NAN, radius, 3.0) == original);
    CHECK(protector_static_visibility_half_width(original, height, 0.7, radius, INFINITY) == original);
    CHECK(protector_static_visibility_half_width(-0.0, height, 0.7, radius, 3.0) == 0);
    CHECK(signbit(protector_static_visibility_half_width(-0.0, height, 0.7, radius, 3.0)));
    // At arbitrary camera slopes, radius expansion stays conservative for both
    // horizontal sides. This helper receives no vertical/depth/state pointers.
    for (unsigned slope = 1; slope < 40; ++slope) {
        const double t = slope / 10.0;
        const double r = 3.0 * sqrt(1 + t * t);
        const double w = 20.0 * t;
        const double widened = protector_static_visibility_half_width(w, w * 0.7, 0.7, r, 3.0);
        const double required = 20.0 * t * 2.25 + 3.0 * sqrt(1 + t * t * 2.25 * 2.25);
        CHECK(widened + r >= required - 0.0001);
    }
}

static void test_decrementer_deadline(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    cpu.pc = 0x80001000u;
    cpu.timebase = 100u;
    cpu.core_cycles = 1200u;
    cpu.gpr[3] = 25u;
    ppc_fallback_instruction(&cpu, 0x7C7603A6u, cpu.pc);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_NONE);
    CHECK(cpu.decrementer_armed);
    CHECK(cpu.decrementer_deadline == 125u);
    CHECK(cpu.decrementer_deadline_core_cycles == 1500u);
    CHECK(!ppc_decrementer_pending(&cpu));
    cpu.msr |= PPC_MSR_EE;
    ppc_advance_broadway_cycles(&cpu, 299u);
    CHECK(!ppc_decrementer_pending(&cpu));
    ppc_advance_broadway_cycles(&cpu, 1u);
    CHECK(ppc_decrementer_pending(&cpu));
    ppc_decrementer_delivered(&cpu);
    CHECK(!cpu.decrementer_armed);
    CHECK(cpu.decrementer_interrupt_count == 1u);
    protector_cpu_destroy(&cpu);
}

static void test_generated_fallback_subset_is_deliberate(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));

    cpu.spr[1008] = 0xA5A50000u;
    ppc_fallback_instruction(&cpu, 0x7C70FAA6u, 0x800C20C0u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_NONE);
    CHECK(cpu.gpr[3] == 0xA5A50000u);
    CHECK(cpu.pc == 0x800C20C4u);

    cpu.gpr[3] = 0x5A5A0000u;
    ppc_fallback_instruction(&cpu, 0x7C70FBA6u, 0x800C20C8u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_NONE);
    CHECK(cpu.spr[1008] == 0x5A5A0000u);
    CHECK(cpu.pc == 0x800C20CCu);

    ppc_fallback_instruction(&cpu, 0x7C001FACu, 0x800C20A8u);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_NONE);
    CHECK(cpu.cache_operation_count == 1);
    CHECK(cpu.pc == 0x800C20ACu);
    protector_cpu_destroy(&cpu);
}

static void test_wii_boot_contract(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));

    protector_prepare_wii_boot(&cpu);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_NONE);
    CHECK(cpu.msr == 0x00002032u);
    CHECK(cpu.hid2 == 0xE0000000u);
    CHECK(cpu.gpr[1] == 0x8004D4BCu);
    CHECK(mem_read32(&cpu, 0x80000020u) == 0x0D15EA5Eu);
    CHECK(mem_read32(&cpu, 0x80000028u) == GC_MAIN_RAM_SIZE);
    CHECK(mem_read32(&cpu, 0x80000034u) == 0x817FEC60u);
    CHECK(mem_read32(&cpu, 0x800000F4u) == 0x8179B500u);
    CHECK(mem_read32(&cpu, 0x80003100u) == GC_MAIN_RAM_SIZE);
    CHECK(mem_read32(&cpu, 0x80003108u) == 0x81800000u);
    CHECK(mem_read32(&cpu, 0x80003118u) == WII_MEM2_SIZE);
    CHECK(mem_read32(&cpu, 0x80003120u) == 0x93400000u);
    CHECK(mem_read32(&cpu, 0x80003124u) == 0x90000800u);
    CHECK(mem_read32(&cpu, 0x80003128u) == 0x933E0000u);
    CHECK(mem_read32(&cpu, 0x80003130u) == 0x933E0000u);
    CHECK(mem_read32(&cpu, 0x80003134u) == 0x93400000u);
    CHECK(mem_read32(&cpu, 0x80003140u) == 0x0015040Fu);
    CHECK(mem_read32(&cpu, 0x80003158u) == 0x0000FF01u);
    CHECK(mem_read16(&cpu, 0x800030E6u) == 0x8201u);
    CHECK(mem_read8(&cpu, 0x8000315Cu) == 0x80u);
    CHECK(mem_read16(&cpu, 0x8000315Eu) == 0x0113u);
    protector_cpu_destroy(&cpu);
}

static void test_lazy_fpu_transition(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    cpu.msr = 0x00008032u;

    CHECK(ppc_fp_available(&cpu, 0x80001000u));
    CHECK((cpu.msr & 0x00002000u) != 0u);
    CHECK(cpu.fpu_unavailable_count == 1u);
    CHECK(cpu.exception == 0u);

    CHECK(ppc_fp_available(&cpu, 0x80001004u));
    CHECK(cpu.fpu_unavailable_count == 1u);
    protector_cpu_destroy(&cpu);
}

static void test_broadway_reciprocal_estimates(void) {
    CPUState cpu = {0};
    f64 result = 0.0;

    CHECK(ppc_fres(&cpu, 1.0, &result));
    CHECK(f64_bits(result) == UINT64_C(0x3FEFFF0000000000));
    CHECK(ppc_fres(&cpu, 3.0, &result));
    CHECK(f64_bits(result) == UINT64_C(0x3FD5550000000000));
    CHECK(ppc_fres(&cpu, 123.25, &result));
    CHECK(f64_bits(result) == UINT64_C(0x3F809DF000000000));
    CHECK(ppc_fres(&cpu, -0.0, &result));
    CHECK(f64_bits(result) == UINT64_C(0xFFF0000000000000));
    CHECK(ppc_fres(
        &cpu,
        f64_from_bits(UINT64_C(0x7FF0000000000000)),
        &result
    ));
    CHECK(f64_bits(result) == 0u);

    CHECK(ppc_frsqrte(&cpu, 1.0, &result));
    CHECK(f64_bits(result) == UINT64_C(0x3FEFFE8000000000));
    CHECK(ppc_frsqrte(&cpu, 2.0, &result));
    CHECK(f64_bits(result) == UINT64_C(0x3FE69FA000000000));
    CHECK(ppc_frsqrte(&cpu, 123.25, &result));
    CHECK(f64_bits(result) == UINT64_C(0x3FB70F3C00000000));
    CHECK(ppc_frsqrte(&cpu, -1.0, &result));
    CHECK(f64_bits(result) == UINT64_C(0x7FF8000000000000));
    CHECK(ppc_frsqrte(&cpu, -0.0, &result));
    CHECK(f64_bits(result) == UINT64_C(0xFFF0000000000000));
}

static void test_paired_single_gqr_quantization(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));

    cpu.gqr[2] = 4u | (1u << 8);
    cpu.fpr[3] = 12.75;
    cpu.ps1[3] = -3.0;
    CHECK(ppc_psq_store(
        &cpu, 3u, 0x80001000u, false, 2u, false, 0x80002000u
    ));
    CHECK(mem_read8(&cpu, 0x80001000u) == 25u);
    CHECK(mem_read8(&cpu, 0x80001001u) == 0u);

    cpu.gqr[2] = 7u | (63u << 8);
    cpu.fpr[3] = -10.0;
    cpu.ps1[3] = 10.0;
    CHECK(ppc_psq_store(
        &cpu, 3u, 0x80001002u, false, 2u, false, 0x80002004u
    ));
    CHECK((s16)mem_read16(&cpu, 0x80001002u) == -5);
    CHECK((s16)mem_read16(&cpu, 0x80001004u) == 5);

    cpu.gqr[4] = (5u << 16) | (2u << 24);
    mem_write16(&cpu, 0x80001008u, 8u);
    mem_write16(&cpu, 0x8000100Au, 12u);
    CHECK(ppc_psq_load(
        &cpu, 5u, 0x80001008u, false, 4u, false, 0x80002008u
    ));
    CHECK(cpu.fpr[5] == 2.0);
    CHECK(cpu.ps1[5] == 3.0);

    cpu.gqr[4] = (6u << 16) | (63u << 24);
    mem_write8(&cpu, 0x8000100Cu, (u8)(s8)-4);
    mem_write8(&cpu, 0x8000100Du, 5u);
    CHECK(ppc_psq_load(
        &cpu, 5u, 0x8000100Cu, false, 4u, false, 0x8000200Cu
    ));
    CHECK(cpu.fpr[5] == -8.0);
    CHECK(cpu.ps1[5] == 10.0);

    cpu.gqr[4] = 4u << 16;
    mem_write8(&cpu, 0x8000100Eu, 7u);
    CHECK(ppc_psq_load(
        &cpu, 5u, 0x8000100Eu, true, 4u, false, 0x80002010u
    ));
    CHECK(cpu.fpr[5] == 7.0);
    CHECK(cpu.ps1[5] == 1.0);
    CHECK(cpu.stop_reason == PROTECTOR_STOP_NONE);
    protector_cpu_destroy(&cpu);
}

static void test_dol_sections_overlay_bss(void) {
    char path[128];
    snprintf(
        path,
        sizeof(path),
        "/tmp/protector-dol-loader-%ld.dol",
        (long)getpid()
    );
    u8 image[0x104] = {0};
    write_be32(image + 0x1C, 0x100u);
    write_be32(image + 0x64, 0x80001008u);
    write_be32(image + 0xAC, 4u);
    write_be32(image + 0xD8, 0x80001000u);
    write_be32(image + 0xDC, 0x20u);
    write_be32(image + 0xE0, 0x80001008u);
    write_be32(image + 0x100, 0xA1B2C3D4u);

    FILE* file = fopen(path, "wb");
    CHECK(file != NULL);
    if (file) {
        CHECK(fwrite(image, 1, sizeof(image), file) == sizeof(image));
        CHECK(fclose(file) == 0);
    }

    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    memset(cpu.ram + 0x1000, 0xFF, 0x20);
    ProtectorDolInfo info;
    char error[256] = {0};
    CHECK(protector_load_dol(
        &cpu, path, &info, error, sizeof(error)
    ));
    CHECK(mem_read32(&cpu, 0x80001000u) == 0u);
    CHECK(mem_read32(&cpu, 0x80001008u) == 0xA1B2C3D4u);
    CHECK(mem_read32(&cpu, 0x8000101Cu) == 0u);
    CHECK(info.bss_address == 0x80001000u);
    CHECK(info.bss_size == 0x20u);
    protector_cpu_destroy(&cpu);
    CHECK(unlink(path) == 0);
}

static void test_wii_data_mount_and_dvdfs_binding(void) {
    char root[128];
    char sys_path[160];
    char files_path[160];
    char fst_path[192];
    snprintf(
        root,
        sizeof(root),
        "/tmp/protector-data-mount-%ld",
        (long)getpid()
    );
    snprintf(sys_path, sizeof(sys_path), "%s/sys", root);
    snprintf(files_path, sizeof(files_path), "%s/files", root);
    snprintf(fst_path, sizeof(fst_path), "%s/fst.bin", sys_path);
    CHECK(mkdir(root, 0700) == 0);
    CHECK(mkdir(sys_path, 0700) == 0);
    CHECK(mkdir(files_path, 0700) == 0);

    u8 fst[33] = {0};
    fst[0] = 1u;
    write_be32(fst + 8, 2u);
    write_be32(fst + 16, 0x1234u);
    write_be32(fst + 20, 4u);
    memcpy(fst + 24, "boot.bin", 9u);
    FILE* file = fopen(fst_path, "wb");
    CHECK(file != NULL);
    if (file) {
        CHECK(fwrite(fst, 1, sizeof(fst), file) == sizeof(fst));
        CHECK(fclose(file) == 0);
    }
    char data_path[192];
    snprintf(data_path, sizeof(data_path), "%s/boot.bin", files_path);
    const u8 data[] = {0x10u, 0x20u, 0x30u, 0x40u};
    file = fopen(data_path, "wb");
    CHECK(file != NULL);
    if (file) {
        CHECK(fwrite(data, 1, sizeof(data), file) == sizeof(data));
        CHECK(fclose(file) == 0);
    }

    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    ProtectorDataMount mount = {0};
    char error[256] = {0};
    CHECK(protector_mount_wii_data(
        &cpu, root, &mount, error, sizeof(error)
    ));
    CHECK(mount.fst_guest_address == PROTECTOR_WII_FST_ADDRESS);
    CHECK(mount.fst_size == sizeof(fst));
    CHECK(mount.fst_entry_count == 2u);
    CHECK(
        mem_read32(&cpu, 0x80000038u) ==
        PROTECTOR_WII_FST_ADDRESS
    );
    CHECK(mem_read32(&cpu, PROTECTOR_WII_FST_ADDRESS + 8u) == 2u);

    cpu.gpr[13] = 0x80300000u;
    CHECK(protector_bind_rbneg9_dvdfs(&cpu));
    CHECK(mem_read32(&cpu, 0x802FBD1Cu) == 0x80000000u);
    CHECK(
        mem_read32(&cpu, 0x802FBD18u) ==
        PROTECTOR_WII_FST_ADDRESS
    );
    CHECK(mem_read32(&cpu, 0x802FBD10u) == 2u);
    CHECK(
        mem_read32(&cpu, 0x802FBD14u) ==
        PROTECTOR_WII_FST_ADDRESS + 24u
    );

    ProtectorFileRead read = {0};
    CHECK(protector_read_wii_file(
        &cpu,
        &mount,
        0x1234u,
        0u,
        0x80002000u,
        32u,
        &read,
        error,
        sizeof(error)
    ));
    CHECK(read.fst_entry_index == 1u);
    CHECK(read.file_size == 4u);
    CHECK(read.bytes_from_file == 4u);
    CHECK(strcmp(read.relative_path, "boot.bin") == 0);
    CHECK(mem_read32(&cpu, 0x80002000u) == 0x10203040u);
    CHECK(mem_read32(&cpu, 0x80002004u) == 0u);

    char trace_path[192];
    snprintf(trace_path, sizeof(trace_path), "%s/read-trace.tsv", root);
    CHECK(setenv("PROTECTOR_FILE_READ_TRACE", trace_path, 1) == 0);
    cpu.translated_dispatch_count = 42u;
    cpu.presented_frame_count = 3008u;
    cpu.pc = 0x800CCAD8u;
    cpu.timebase = 99u;
    cpu.content_trace_request_serial = 7u;
    cpu.content_trace_logical_clock_valid = true;
    cpu.content_trace_logical_frame = 6u;
    cpu.content_trace_absolute_checkpoint = 3009u;
    ProtectorFileRead traced = {0};
    CHECK(protector_prepare_wii_file_read(
        &cpu,
        &mount,
        0x1234u,
        0u,
        0x80002010u,
        4u,
        &traced,
        error,
        sizeof(error)
    ));
    cpu.content_trace_logical_frame = 10u;
    cpu.content_trace_absolute_checkpoint = 3013u;
    CHECK(protector_trace_wii_file_completion(
        &cpu,
        &traced,
        7u,
        3u,
        0x0123456789ABCDEFull
    ));
    CHECK(unsetenv("PROTECTOR_FILE_READ_TRACE") == 0);
    char trace_text[1024] = {0};
    file = fopen(trace_path, "rb");
    CHECK(file != NULL);
    if (file) {
        const size_t read_size = fread(
            trace_text, 1u, sizeof(trace_text) - 1u, file
        );
        trace_text[read_size] = '\0';
        CHECK(fclose(file) == 0);
    }
    CHECK(strcmp(
        trace_text,
        "request\t7\t-\tboot.bin\t0\t4\t4\t42\t3008\t"
        "0x800CCAD8\t99\t6\t3009\t-\n"
        "completion\t7\t3\tboot.bin\t0\t4\t4\t42\t3008\t"
        "0x800CCAD8\t99\t10\t3013\t0123456789ABCDEF\n"
    ) == 0);
    CHECK(unlink(trace_path) == 0);

    snprintf(
        trace_path,
        sizeof(trace_path),
        "%s/missing/read-trace.tsv",
        root
    );
    CHECK(setenv("PROTECTOR_FILE_READ_TRACE", trace_path, 1) == 0);
    memset(error, 0, sizeof(error));
    CHECK(!protector_prepare_wii_file_read(
        &cpu,
        &mount,
        0x1234u,
        0u,
        0x80002010u,
        4u,
        &traced,
        error,
        sizeof(error)
    ));
    CHECK(strstr(error, "cannot append") != NULL);
    CHECK(unsetenv("PROTECTOR_FILE_READ_TRACE") == 0);

    mem_write32(&cpu, 0x80002020u, 0xA5A5A5A5u);
    ProtectorFileRead deferred_first = {0};
    ProtectorFileRead deferred_second = {0};
    CHECK(protector_prepare_wii_file_read(
        &cpu,
        &mount,
        0x1234u,
        0u,
        0x80002020u,
        2u,
        &deferred_first,
        error,
        sizeof(error)
    ));
    CHECK(protector_prepare_wii_file_read(
        &cpu,
        &mount,
        0x1234u,
        2u,
        0x80002020u,
        2u,
        &deferred_second,
        error,
        sizeof(error)
    ));
    CHECK(mem_read32(&cpu, 0x80002020u) == 0xA5A5A5A5u);
    CHECK(protector_complete_wii_file_read(
        &cpu,
        &mount,
        &deferred_first,
        0x80002020u,
        error,
        sizeof(error)
    ));
    CHECK(mem_read16(&cpu, 0x80002020u) == 0x1020u);
    CHECK(protector_complete_wii_file_read(
        &cpu,
        &mount,
        &deferred_second,
        0x80002020u,
        error,
        sizeof(error)
    ));
    CHECK(mem_read16(&cpu, 0x80002020u) == 0x3040u);

    CHECK(truncate(data_path, 2) == 0);
    memset(error, 0, sizeof(error));
    CHECK(!protector_read_wii_file(
        &cpu,
        &mount,
        0x1234u,
        0u,
        0x80002100u,
        2u,
        &read,
        error,
        sizeof(error)
    ));
    mount.allow_source_prefix_files = true;
    memset(error, 0, sizeof(error));
    CHECK(protector_read_wii_file(
        &cpu,
        &mount,
        0x1234u,
        0u,
        0x80002100u,
        2u,
        &read,
        error,
        sizeof(error)
    ));
    CHECK(mem_read16(&cpu, 0x80002100u) == 0x1020u);
    memset(error, 0, sizeof(error));
    CHECK(!protector_read_wii_file(
        &cpu,
        &mount,
        0x1234u,
        0u,
        0x80002120u,
        4u,
        &read,
        error,
        sizeof(error)
    ));
    protector_cpu_destroy(&cpu);

    CHECK(unlink(data_path) == 0);
    CHECK(unlink(fst_path) == 0);
    CHECK(rmdir(files_path) == 0);
    CHECK(rmdir(sys_path) == 0);
    CHECK(rmdir(root) == 0);
}

int main(void) {
    test_big_endian_memory_and_aliases();
    test_unaligned_scalar_access_and_unmapped_stops();
    test_memory_write_watch_preserves_post_store_diagnostics();
    test_external_memory_is_explicitly_delegated();
    test_atomic_reservation();
    test_cache_and_exception_paths_are_explicit();
    test_timebase_register_halves();
    test_broadway_cycle_to_timebase_ratio();
    test_live_gx_sink_is_explicit_and_in_memory();
    test_static_visibility_envelope();
    test_decrementer_deadline();
    test_generated_fallback_subset_is_deliberate();
    test_wii_boot_contract();
    test_lazy_fpu_transition();
    test_broadway_reciprocal_estimates();
    test_paired_single_gqr_quantization();
    test_dol_sections_overlay_bss();
    test_wii_data_mount_and_dvdfs_binding();

    if (failures) {
        fprintf(stderr, "%d runtime tests failed\n", failures);
        return 1;
    }
    puts("protector runtime tests passed");
    return 0;
}
