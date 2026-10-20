/* Asset-free tests call the production host queue, never a substitute game.
 * Actual SDK cancellation is separately exercised by dvd_cancel_asset_probe. */
#include "protector/cpu.h"
#include <assert.h>
static int dolrecomp_call(CPUState* cpu, u32 address) {
    (void)cpu;
    (void)address;
    assert(!"asset-free DVD tests must not execute translated code");
    return 0;
}
#define PROTECTOR_BOOT_DISPATCH_TEST 1
#define main protector_unused_boot_main
#include "../macos/boot_main.c"
#undef main

#define TEST_INFO 0x80400000u
#define TEST_CALLBACK 0x80100000u

static void reset(CPUState* cpu, BootTrace* trace) {
    protector_cpu_reset(cpu);
    memset(trace, 0, sizeof(*trace));
    cpu->external_user_data = trace;
    cpu->gpr[13] = 0x80311F60u;
    cpu->msr = PPC_MSR_EE;
}

static void queue(CPUState* cpu, BootTrace* trace, u32 info, u32 callback) {
    mem_write32(cpu, info + 12u, 2u);
    ++trace->file_read_count;
    assert(queue_dvd_async_callback(cpu, trace, callback, 32u, info,
        0x81000000u, WII_SDK_DVD_READ_ASYNC_PRIO, true, false, NULL));
    assert(cpu->stop_reason == PROTECTOR_STOP_NONE);
}

static void test_cancel_before_deadline_and_reuse(CPUState* cpu, BootTrace* trace) {
    reset(cpu, trace);
    queue(cpu, trace, TEST_INFO, TEST_CALLBACK);
    assert(trace->dvd_async_callback_queue[0].ready_frame > 0u);
    strcpy(trace->dvd_async_callback_queue[0].file_read.relative_path,
        "synthetic-must-not-read.bin");
    trace->dvd_async_callback_queue[0].file_read.requested_length = 32u;
    mem_write32(cpu, 0x81000000u, 0xA5A5A5A5u);
    mem_write32(cpu, TEST_INFO + 12u, 10u);
    mem_write32(cpu, TEST_INFO + 44u, 0u);
    /* Even though the event is not due, retire it without touching the SDK's
     * cancellation state, resources, CPU registers, or callback counts. */
    cpu->pc = 0x80001234u;
    cpu->gpr[3] = 0x12345678u;
    assert(!deliver_dvd_async_callback(cpu, trace));
    assert(trace->dvd_async_callback_queue_count == 0u);
    assert(trace->dvd_async_cancelled_count == 1u);
    assert(trace->dvd_async_callback_count == 0u);
    assert(cpu->pc == 0x80001234u && cpu->gpr[3] == 0x12345678u);
    assert(mem_read32(cpu, TEST_INFO + 12u) == 10u);
    assert(mem_read32(cpu, TEST_INFO + 44u) == 0u);
    assert(mem_read32(cpu, 0x81000000u) == 0xA5A5A5A5u);
    assert(cpu->stop_reason == PROTECTOR_STOP_NONE);
    queue(cpu, trace, TEST_INFO, TEST_CALLBACK + 4u);
    assert(trace->dvd_async_callback_queue_count == 1u);
    trace->gx_completed_frame_count = 100u;
    assert(deliver_dvd_async_callback(cpu, trace));
    assert(cpu->pc == TEST_CALLBACK + 4u && cpu->gpr[4] == TEST_INFO);
    assert(cpu->gpr[3] == 32u && mem_read32(cpu, TEST_INFO + 12u) == 0u);
    assert(trace->dvd_async_callback_count == 1u);
    assert(trace->dvd_async_callback_queue_count == 0u);
    assert(!deliver_dvd_async_callback(cpu, trace));
    cpu->lr = WII_OS_LOAD_CONTEXT;
    assert(trace_host_call(cpu, WII_OS_LOAD_CONTEXT));
    assert(cpu->pc == 0x80001234u && cpu->gpr[3] == 0x12345678u);
    assert(!trace->dvd_async_callback_dispatch_active);
}

static void test_wrapped_queue_and_active_callback(CPUState* cpu, BootTrace* trace) {
    reset(cpu, trace);
    trace->dvd_async_callback_queue_head = DVD_ASYNC_CALLBACK_QUEUE_SIZE - 2u;
    for (u32 i = 0; i < 5u; ++i)
        queue(cpu, trace, TEST_INFO + i * 64u, TEST_CALLBACK + i * 4u);
    for (u32 i = 0; i < 5u; i += 2u)
        mem_write32(cpu, TEST_INFO + i * 64u + 12u, 10u);
    trace->dvd_async_callback_dispatch_active = true;
    assert(!deliver_dvd_async_callback(cpu, trace));
    assert(trace->dvd_async_callback_queue_count == 2u);
    assert(trace->dvd_async_cancelled_count == 3u);
    for (u32 i = 0; i < 2u; ++i) {
        u32 index = (trace->dvd_async_callback_queue_head + i) %
            DVD_ASYNC_CALLBACK_QUEUE_SIZE;
        assert(trace->dvd_async_callback_queue[index].file_info ==
            TEST_INFO + (i * 2u + 1u) * 64u);
    }
    assert(trace->dvd_async_callback_dispatch_active);
    assert(trace->dvd_async_callback_count == 0u);
}

static void test_capacity_reclaimed_before_enqueue(CPUState* cpu, BootTrace* trace) {
    reset(cpu, trace);
    for (u32 i = 0; i < DVD_ASYNC_CALLBACK_QUEUE_SIZE; ++i)
        queue(cpu, trace, TEST_INFO + i * 64u, TEST_CALLBACK);
    mem_write32(cpu, TEST_INFO + 17u * 64u + 12u, 10u);
    queue(cpu, trace, TEST_INFO + DVD_ASYNC_CALLBACK_QUEUE_SIZE * 64u, TEST_CALLBACK);
    assert(trace->dvd_async_callback_queue_count == DVD_ASYNC_CALLBACK_QUEUE_SIZE);
    assert(trace->dvd_async_cancelled_count == 1u);
}

static void test_seek_reuse_and_callback_layout(CPUState* cpu, BootTrace* trace) {
    reset(cpu, trace);
    queue(cpu, trace, TEST_INFO, TEST_CALLBACK);
    mem_write32(cpu, TEST_INFO + 12u, 10u);
    cpu->gpr[3] = TEST_INFO;
    cpu->gpr[4] = 128u;
    cpu->gpr[5] = TEST_CALLBACK + 4u;
    cpu->lr = 0x80001234u;
    assert(trace_host_call(cpu, WII_SDK_DVD_SEEK_ASYNC_PRIO));
    assert(trace->dvd_async_cancelled_count == 1u);
    assert(trace->dvd_async_callback_queue_count == 1u);
    assert(mem_read32(cpu, TEST_INFO + 8u) == 2u);
    assert(mem_read32(cpu, TEST_INFO + 12u) == 2u);
    assert(mem_read32(cpu, TEST_INFO + 40u) == WII_SDK_DVD_SEEK_BLOCK_CALLBACK);
    assert(mem_read32(cpu, TEST_INFO + 56u) == TEST_CALLBACK + 4u);
    assert(cpu->pc == 0x80001234u && cpu->gpr[3] == 1u);
}

int main(void) {
    CPUState cpu;
    assert(protector_cpu_init(&cpu));
    BootTrace* trace = calloc(1, sizeof(*trace));
    assert(trace);
    test_cancel_before_deadline_and_reuse(&cpu, trace);
    test_wrapped_queue_and_active_callback(&cpu, trace);
    test_capacity_reclaimed_before_enqueue(&cpu, trace);
    test_seek_reuse_and_callback_layout(&cpu, trace);
    free(trace);
    protector_cpu_destroy(&cpu);
    puts("DVD async queue tests passed");
    return 0;
}
