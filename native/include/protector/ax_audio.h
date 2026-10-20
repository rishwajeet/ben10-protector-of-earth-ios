#ifndef PROTECTOR_AX_AUDIO_H
#define PROTECTOR_AX_AUDIO_H

#include "protector/cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PROTECTOR_AX_AUDIO_MAX_SAMPLES 96u
#define PROTECTOR_AX_AUDIO_COEFFICIENTS 2048u
#define PROTECTOR_AX_AUDIO_BUSES 12u

/* Reads DSP physical byte addresses, not PPC virtual addresses. */
typedef bool (*ProtectorAXReadByte)(void* context, u32 address, u8* value);

typedef enum ProtectorAXAudioResult {
    PROTECTOR_AX_AUDIO_OK = 0,
    PROTECTOR_AX_AUDIO_INVALID_ARGUMENT,
    PROTECTOR_AX_AUDIO_UNSUPPORTED_FORMAT,
    PROTECTOR_AX_AUDIO_UNSUPPORTED_SRC,
    PROTECTOR_AX_AUDIO_MISSING_COEFFICIENTS,
    PROTECTOR_AX_AUDIO_INVALID_RATIO,
    PROTECTOR_AX_AUDIO_UNMAPPED_SAMPLE,
    PROTECTOR_AX_AUDIO_UNSUPPORTED_UCODE,
    PROTECTOR_AX_AUDIO_UNSUPPORTED_EFFECT,
} ProtectorAXAudioResult;

typedef struct ProtectorAXVoice {
    bool running;
    bool looping;
    bool stream;
    u16 format;
    u32 loop_address;
    u32 end_address;
    u32 current_address;
    s16 adpcm_coefficients[16];
    s16 gain;
    u16 predictor_scale;
    s16 history_1;
    s16 history_2;
    u16 loop_predictor_scale;
    s16 loop_history_1;
    s16 loop_history_2;
    u16 src_type;
    u16 coefficient_set;
    u32 ratio;
    u16 fraction;
    s16 last_samples[4];
} ProtectorAXVoice;

typedef struct ProtectorAXMixVolume {
    u16 volume;
    s16 delta;
    bool enabled;
    bool ramp;
    s16 last_sample;
} ProtectorAXMixVolume;

typedef struct ProtectorAXVoiceMix {
    u16 envelope;
    s16 envelope_delta;
    bool low_pass;
    s16 low_pass_history;
    u16 low_pass_a0;
    s16 low_pass_b0;
    bool biquad;
    s16 biquad_x1, biquad_x2, biquad_y1, biquad_y2;
    s16 biquad_b0, biquad_b1, biquad_b2, biquad_a1, biquad_a2;
    /* Main L/R/S, AUX A L/R/S, AUX B L/R/S, AUX C L/R/S. */
    ProtectorAXMixVolume buses[PROTECTOR_AX_AUDIO_BUSES];
} ProtectorAXVoiceMix;

/* Transactional: an error leaves the voice and destination unchanged.
 * Polyphase SRC requires the original coefficient table; no linear fallback.
 * This is a voice processor, not the AX command-list or AI output service. */
ProtectorAXAudioResult protector_ax_decode_voice(
    ProtectorAXVoice* voice, ProtectorAXReadByte read_byte, void* context,
    const s16* coefficients, size_t coefficient_count,
    u16 sample_count, s16* output);

/* Apply Wii envelope/LPF and accumulate the 12 routing buses. Bus values are
 * intentionally 32-bit: final clipping belongs to the AX OUTPUT command. */
bool protector_ax_mix_voice(
    ProtectorAXVoiceMix* mix, const s16* samples, u16 sample_count,
    s32 buses[PROTECTOR_AX_AUDIO_BUSES][PROTECTOR_AX_AUDIO_MAX_SAMPLES]);

bool protector_ax_read_physical_byte(void* context, u32 address, u8* value);
/* RBNEG9's hash-identified AXWii 0x347112ba layout. On failure, neither the
 * guest PB nor the buses change. Remote/initial-time-delay paths reject. */
ProtectorAXAudioResult protector_ax_process_pb(
    CPUState* cpu, u32 pb_address, u32 ucode_hash,
    const s16* coefficients, size_t coefficient_count,
    s32 buses[PROTECTOR_AX_AUDIO_BUSES][PROTECTOR_AX_AUDIO_MAX_SAMPLES]);
const char* protector_ax_audio_result_name(ProtectorAXAudioResult result);

#ifdef __cplusplus
}
#endif
#endif
