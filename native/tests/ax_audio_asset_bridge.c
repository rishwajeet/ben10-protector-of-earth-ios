/* Offline verification adapter; never linked into the game. */
#include "protector/ax_audio.h"

typedef struct AssetMemory { const u8* bytes; size_t size; } AssetMemory;
static bool read_asset(void* context, u32 address, u8* value) {
    const AssetMemory* memory = context;
    if ((size_t)address >= memory->size + 8u) return false;
    /* The accelerator reads the next block header before handling end-of-voice.
     * Model an explicit eight-byte zero guard after this standalone asset. */
    *value = address < memory->size ? memory->bytes[address] : 0;
    return true;
}

int protector_ax_verify_asset_channel(
    const u8* bytes, size_t size, const s16* coefficients,
    u16 predictor_scale, s16 history_1, s16 history_2,
    u32 sample_count, s16* output) {
    if (!bytes || !coefficients || !output || !sample_count || size > UINT32_MAX - 8u)
        return PROTECTOR_AX_AUDIO_INVALID_ARGUMENT;
    const u64 last = ((u64)sample_count - 1u) / 14u * 16u +
        2u + ((u64)sample_count - 1u) % 14u;
    if (last > UINT32_MAX) return PROTECTOR_AX_AUDIO_INVALID_ARGUMENT;
    AssetMemory memory = {bytes, size};
    ProtectorAXVoice voice = {0};
    voice.running = true;
    voice.format = 0;
    voice.current_address = 2;
    voice.end_address = (u32)last;
    voice.predictor_scale = predictor_scale;
    voice.history_1 = history_1;
    voice.history_2 = history_2;
    voice.src_type = 2;
    memcpy(voice.adpcm_coefficients, coefficients, sizeof(voice.adpcm_coefficients));
    for (u32 cursor = 0; cursor < sample_count;) {
        const u16 count = sample_count - cursor > 96u ? 96u : (u16)(sample_count - cursor);
        ProtectorAXAudioResult result = protector_ax_decode_voice(
            &voice, read_asset, &memory, NULL, 0, count, output + cursor);
        if (result != PROTECTOR_AX_AUDIO_OK) return result;
        cursor += count;
    }
    return PROTECTOR_AX_AUDIO_OK;
}
