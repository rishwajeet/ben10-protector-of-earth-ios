#ifndef PROTECTOR_AX_ENGINE_H
#define PROTECTOR_AX_ENGINE_H
#include "protector/ax_audio.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef bool (*ProtectorAXPCMConsumer)(void* context, const s16* interleaved_lr, u32 frames);
typedef struct ProtectorAXEngine {
    s16 coefficients[PROTECTOR_AX_AUDIO_COEFFICIENTS];
    s32 buses[20][96];
    u32 ucode_hash;
    u16 pending_words;
    u16 main_volume;
    u16 aux_volume[3];
    u16 compressor_position;
    bool coefficients_valid;
    bool configured;
    u64 command_lists;
    u64 output_frames;
    u64 voices_processed;
    u32 command_mask;
    u32 error_address;
    char error[160];
    ProtectorAXPCMConsumer consumer;
    void* consumer_context;
} ProtectorAXEngine;

/* Pure synchronous DSP service. Never opens an audio device. */
void protector_ax_engine_init(ProtectorAXEngine* engine,
    const u8* coefficient_bytes, size_t byte_count,
    ProtectorAXPCMConsumer consumer, void* consumer_context);
bool protector_ax_engine_configure(ProtectorAXEngine* engine, CPUState* cpu, u32 dsp_task);
bool protector_ax_engine_mail(ProtectorAXEngine* engine, CPUState* cpu, u32 mail);
bool protector_ax_engine_execute(ProtectorAXEngine* engine, CPUState* cpu,
    u32 command_address, u16 word_count);

#ifdef __cplusplus
}
#endif
#endif
