#include "protector/ax_diagnostics.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_signal_statistics(void) {
    ProtectorAXDiagnostics d;
    const s16 samples[] = {0, 100, INT16_MIN, -100, INT16_MAX, 0, 0, 100};
    protector_ax_diagnostics_init(&d, PROTECTOR_AX_OUTPUT_SILENT);
    assert(d.running && !d.configured && !d.failed && d.frames == 0);
    assert(protector_ax_diagnostics_pcm(&d, samples, 4));
    assert(d.frames == 4 && d.nonzero[0] == 2 && d.nonzero[1] == 3);
    assert(d.peak_absolute[0] == 32768 && d.peak_absolute[1] == 100);
    assert(d.full_scale[0] == 2 && d.full_scale[1] == 0);
    // Known little-endian byte sequence: 00 00 64 00 00 80 9c ff
    //                               ff 7f 00 00 00 00 64 00.
    u64 expected = UINT64_C(14695981039346656037);
    const u8 bytes[] = {0, 0, 100, 0, 0, 128, 156, 255, 255, 127, 0, 0, 0, 0, 100, 0};
    for (size_t i = 0; i < sizeof(bytes); ++i)
        expected = (expected ^ bytes[i]) * UINT64_C(1099511628211);
    assert(d.pcm_fnv1a64 == expected);
    assert(d.pcm_fnv1a64 == UINT64_C(0x35769a27c9f28202));
}

static void test_chunk_continuity_and_modes(void) {
    s16 samples[384];
    for (u32 i = 0; i < 384; ++i) samples[i] = (s16)((s32)i * 91 - 17300);
    ProtectorAXDiagnostics whole, chunks;
    protector_ax_diagnostics_init(&whole, PROTECTOR_AX_OUTPUT_SILENT);
    protector_ax_diagnostics_init(&chunks, PROTECTOR_AX_OUTPUT_CAPTURE);
    for (u32 i = 0; i < 192; i += 96)
        assert(protector_ax_diagnostics_pcm(&whole, samples + i * 2, 96));
    for (u32 i = 0; i < 192; i += 8)
        assert(protector_ax_diagnostics_pcm(&chunks, samples + i * 2, 8));
    assert(whole.frames == 192 && chunks.frames == 192);
    assert(whole.pcm_fnv1a64 == chunks.pcm_fnv1a64);
    assert(memcmp(whole.nonzero, chunks.nonzero, sizeof(whole.nonzero)) == 0);
    assert(memcmp(whole.peak_absolute, chunks.peak_absolute, sizeof(whole.peak_absolute)) == 0);
    assert(memcmp(whole.full_scale, chunks.full_scale, sizeof(whole.full_scale)) == 0);
}

static void test_invalid_samples_leave_state_unchanged(void) {
    ProtectorAXDiagnostics d;
    protector_ax_diagnostics_init(&d, PROTECTOR_AX_OUTPUT_SILENT);
    ProtectorAXDiagnostics before = d;
    s16 samples[192] = {0};
    assert(!protector_ax_diagnostics_pcm(NULL, samples, 1));
    assert(!protector_ax_diagnostics_pcm(&d, NULL, 1));
    assert(!protector_ax_diagnostics_pcm(&d, samples, 0));
    assert(!protector_ax_diagnostics_pcm(&d, samples, 97));
    assert(memcmp(&d, &before, sizeof(d)) == 0);
    d.frames = UINT64_MAX;
    before = d;
    assert(!protector_ax_diagnostics_pcm(&d, samples, 1));
    assert(memcmp(&d, &before, sizeof(d)) == 0);
    protector_ax_diagnostics_init(&d, PROTECTOR_AX_OUTPUT_DISABLED);
    assert(!protector_ax_diagnostics_pcm(&d, samples, 1));
    protector_ax_diagnostics_init(&d, PROTECTOR_AX_OUTPUT_CAPTURE);
    d.failed = true;
    assert(!protector_ax_diagnostics_pcm(&d, samples, 1));
    d.failed = false;
    d.running = false;
    assert(!protector_ax_diagnostics_pcm(&d, samples, 1));
}

static void test_snapshot_and_engine_state(void) {
    ProtectorAXDiagnostics d, copy;
    ProtectorAXEngine e = {0};
    protector_ax_diagnostics_init(&d, PROTECTOR_AX_OUTPUT_SILENT);
    e.configured = true;
    e.command_lists = 27;
    e.voices_processed = 101;
    e.command_mask = 0x411;
    e.ucode_hash = 0x347112ba;
    protector_ax_diagnostics_engine(&d, &e);
    protector_ax_diagnostics_publish(&d);
    memset(&d, 0xa5, sizeof(d));
    protector_ax_diagnostics_read(&copy);
    assert(copy.mode == PROTECTOR_AX_OUTPUT_SILENT && copy.configured);
    assert(copy.command_lists == 27 && copy.voices_processed == 101);
    assert(copy.command_mask == 0x411 && copy.ucode_hash == 0x347112ba);
    copy.running = false;
    copy.failed = true;
    strcpy(copy.error, "synthetic failure");
    protector_ax_diagnostics_publish(&copy);
    protector_ax_diagnostics_read(&d);
    assert(!d.running && d.failed && strcmp(d.error, "synthetic failure") == 0);
    protector_ax_diagnostics_read(NULL);
    protector_ax_diagnostics_publish(NULL);
    protector_ax_diagnostics_init(NULL, PROTECTOR_AX_OUTPUT_DISABLED);
}

int main(void) {
    test_signal_statistics();
    test_chunk_continuity_and_modes();
    test_invalid_samples_leave_state_unchanged();
    test_snapshot_and_engine_state();
    puts("AX diagnostics: PCM statistics, byte order, stream continuity and atomic snapshot passed");
    return 0;
}
