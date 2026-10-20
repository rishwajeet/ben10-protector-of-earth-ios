#ifndef PROTECTOR_AX_DIAGNOSTICS_H
#define PROTECTOR_AX_DIAGNOSTICS_H

#include "protector/ax_engine.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum ProtectorAXOutputMode {
    PROTECTOR_AX_OUTPUT_DISABLED,
    PROTECTOR_AX_OUTPUT_SILENT,
    PROTECTOR_AX_OUTPUT_CAPTURE,
} ProtectorAXOutputMode;

typedef struct ProtectorAXDiagnostics {
    ProtectorAXOutputMode mode;
    bool running;
    bool configured;
    bool failed;
    u64 frames;
    u64 pcm_fnv1a64;
    u64 nonzero[2];
    u64 full_scale[2];
    u32 peak_absolute[2];
    u64 command_lists;
    u64 voices_processed;
    u32 command_mask;
    u32 ucode_hash;
    char error[160];
} ProtectorAXDiagnostics;

/* Worker-owned accumulation. No PCM storage, audio device or game-state edits.
 * The hash is over interleaved little-endian PCM16, independent of host endian. */
void protector_ax_diagnostics_init(ProtectorAXDiagnostics* diagnostics,
                                   ProtectorAXOutputMode mode);
bool protector_ax_diagnostics_pcm(ProtectorAXDiagnostics* diagnostics,
                                  const s16* samples, u32 frames);
void protector_ax_diagnostics_engine(ProtectorAXDiagnostics* diagnostics,
                                     const ProtectorAXEngine* engine);
/* Publish after a complete mailbox operation. Readers receive an atomic copy
 * without touching the engine, consuming audio or racing its mutable state. */
void protector_ax_diagnostics_publish(const ProtectorAXDiagnostics* diagnostics);
void protector_ax_diagnostics_read(ProtectorAXDiagnostics* diagnostics);

#ifdef __cplusplus
}
#endif
#endif
