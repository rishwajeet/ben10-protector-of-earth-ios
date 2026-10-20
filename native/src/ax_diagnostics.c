#include "protector/ax_diagnostics.h"

#include <stdatomic.h>
#include <string.h>

static atomic_flag snapshot_lock = ATOMIC_FLAG_INIT;
static ProtectorAXDiagnostics snapshot;

void protector_ax_diagnostics_init(ProtectorAXDiagnostics* d, ProtectorAXOutputMode mode) {
    if (!d) return;
    memset(d, 0, sizeof(*d));
    d->mode = mode;
    d->running = mode != PROTECTOR_AX_OUTPUT_DISABLED;
    d->pcm_fnv1a64 = UINT64_C(14695981039346656037);
}

bool protector_ax_diagnostics_pcm(ProtectorAXDiagnostics* d, const s16* samples, u32 frames) {
    if (!d || !samples || !frames || frames > PROTECTOR_AX_AUDIO_MAX_SAMPLES ||
        !d->running || d->failed || d->mode == PROTECTOR_AX_OUTPUT_DISABLED ||
        d->frames > UINT64_MAX - frames) return false;
    for (u32 i = 0; i < frames * 2; ++i) {
        const u32 channel = i & 1u;
        const s32 value = samples[i];
        const u16 raw = (u16)samples[i];
        const u32 absolute = (u32)(value < 0 ? -value : value);
        d->nonzero[channel] += value != 0;
        d->full_scale[channel] += value == INT16_MIN || value == INT16_MAX;
        if (absolute > d->peak_absolute[channel]) d->peak_absolute[channel] = absolute;
        d->pcm_fnv1a64 ^= raw & 0xffu;
        d->pcm_fnv1a64 *= UINT64_C(1099511628211);
        d->pcm_fnv1a64 ^= raw >> 8;
        d->pcm_fnv1a64 *= UINT64_C(1099511628211);
    }
    d->frames += frames;
    return true;
}

void protector_ax_diagnostics_engine(ProtectorAXDiagnostics* d, const ProtectorAXEngine* e) {
    if (!d || !e) return;
    d->configured = e->configured;
    d->command_lists = e->command_lists;
    d->voices_processed = e->voices_processed;
    d->command_mask = e->command_mask;
    d->ucode_hash = e->ucode_hash;
}

void protector_ax_diagnostics_publish(const ProtectorAXDiagnostics* d) {
    if (!d) return;
    while (atomic_flag_test_and_set_explicit(&snapshot_lock, memory_order_acquire)) {}
    snapshot = *d;
    atomic_flag_clear_explicit(&snapshot_lock, memory_order_release);
}

void protector_ax_diagnostics_read(ProtectorAXDiagnostics* d) {
    if (!d) return;
    while (atomic_flag_test_and_set_explicit(&snapshot_lock, memory_order_acquire)) {}
    *d = snapshot;
    atomic_flag_clear_explicit(&snapshot_lock, memory_order_release);
}
