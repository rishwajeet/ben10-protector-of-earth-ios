/* A controlled boundary probe, not a gameplay test: execute the original
 * translated DVDCancelAsync and resource callback against an in-flight host
 * event. The external DOL supplies the SDK's actual cancellation jump table.
 * No save store, sound output, or game-content mutation is involved. */
#define main protector_unused_boot_main
#include "../macos/boot_main.c"
#undef main
#include <assert.h>

#define PROBE_CANCEL_ASYNC 0x800D0BE4u
#define PROBE_RESOURCE_CALLBACK 0x8017EE94u
#define PROBE_RETURN 0x80001000u
#define PROBE_FILE_INFO 0x80452894u
#define PROBE_USER_DATA 0x808C2104u

static unsigned resource_callbacks;
static s32 resource_callback_result;

static unsigned run_until_return(CPUState* cpu, BootTrace* trace) {
    unsigned dispatches = 0;
    while (cpu->pc != PROBE_RETURN &&
           cpu->stop_reason == PROTECTOR_STOP_NONE && dispatches < 1000u) {
        if (cpu->pc == PROBE_RESOURCE_CALLBACK) {
            ++resource_callbacks;
            resource_callback_result = (s32)cpu->gpr[3];
        }
        if (!run_translated_dispatch(cpu, trace)) break;
        ++dispatches;
    }
    return dispatches;
}

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s /external/RBNEG9/sys/main.dol\n", argv[0]);
        return 2;
    }
    CPUState cpu;
    ProtectorDolInfo dol = {0};
    char error[256] = {0};
    assert(protector_cpu_init(&cpu));
    if (!protector_load_dol(&cpu, argv[1], &dol, error, sizeof(error)) ||
        dol.entry_point != RBNEG9_ENTRY) {
        fprintf(stderr, "RBNEG9 DOL load failed: %s\n", error);
        protector_cpu_destroy(&cpu);
        return 2;
    }
    BootTrace* trace = calloc(1, sizeof(*trace));
    assert(trace);
    cpu.external_user_data = trace;
    cpu.host_call = trace_host_call;
    cpu.stop_handler = abort_translated_dispatch;
    cpu.gpr[1] = 0x817FF000u;
    cpu.gpr[13] = 0x80311F60u;
    cpu.msr = PPC_MSR_EE;
    /* The live queue exposes state 2 (SDK WAITING); its translated cancel
     * path invokes the command-block callback with DVD_RESULT_CANCELED (-3). */
    mem_write32(&cpu, PROBE_FILE_INFO + 8u, 1u);
    mem_write32(&cpu, PROBE_FILE_INFO + 12u, 2u);
    mem_write32(&cpu, PROBE_FILE_INFO + 40u, WII_SDK_DVD_COMMAND_BLOCK_CALLBACK);
    mem_write32(&cpu, PROBE_FILE_INFO + 44u, PROBE_USER_DATA);
    mem_write32(&cpu, PROBE_FILE_INFO + 56u, PROBE_RESOURCE_CALLBACK);
    assert(queue_dvd_async_callback(&cpu, trace, PROBE_RESOURCE_CALLBACK,
        32768u, PROBE_FILE_INFO, 0x811C8C00u,
        WII_SDK_DVD_READ_ASYNC_PRIO, true, false, NULL));
    cpu.pc = PROBE_CANCEL_ASYNC;
    cpu.lr = PROBE_RETURN;
    cpu.gpr[3] = PROBE_FILE_INFO;
    cpu.gpr[4] = 0u;
    const unsigned cancel_dispatches = run_until_return(&cpu, trace);
    const bool cancel_returned = cpu.pc == PROBE_RETURN &&
        cpu.stop_reason == PROTECTOR_STOP_NONE && cpu.gpr[3] == 1u;
    const u32 cancelled_state = mem_read32(&cpu, PROBE_FILE_INFO + 12u);
    const u32 cancelled_user_data = mem_read32(&cpu, PROBE_FILE_INFO + 44u);
    const u32 queued_after_cancel = trace->dvd_async_callback_queue_count;
    trace->gx_completed_frame_count = 100u;
    const bool stale_dispatched = deliver_dvd_async_callback(&cpu, trace);
    if (stale_dispatched) (void)run_until_return(&cpu, trace);
    const bool passed = cancel_returned && cancelled_state == 10u &&
        cancelled_user_data == 0u && !stale_dispatched &&
        trace->dvd_async_callback_queue_count == 0u &&
        trace->dvd_async_cancelled_count == 1u &&
        resource_callbacks == 1u && resource_callback_result == -3 &&
        cpu.stop_reason == PROTECTOR_STOP_NONE;
    printf("{\"schema\":\"protector-native.dvd-cancel-boundary/v1\","
        "\"passed\":%s,\"cancel_returned\":%s,\"cancel_dispatches\":%u,"
        "\"cancelled_state\":%u,\"cancelled_user_data\":%u,"
        "\"queued_after_cancel\":%u,\"stale_dispatched\":%s,"
        "\"queued_final\":%u,\"stop_reason\":\"%s\","
        "\"retired_host_events\":%" PRIu64 ",\"resource_callbacks\":%u,"
        "\"resource_callback_result\":%d,"
        "\"stop_pc\":\"0x%08X\",\"stop_address\":\"0x%08X\"}\n",
        passed ? "true" : "false", cancel_returned ? "true" : "false",
        cancel_dispatches, cancelled_state, cancelled_user_data,
        queued_after_cancel, stale_dispatched ? "true" : "false",
        trace->dvd_async_callback_queue_count,
        protector_stop_reason_name(cpu.stop_reason),
        trace->dvd_async_cancelled_count, resource_callbacks, resource_callback_result,
        cpu.pc, cpu.stop_address);
    protector_cpu_destroy(&cpu);
    free(trace);
    return passed ? 0 : 1;
}
