// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted for Protector Native from Dolphin DSPAccelerator.cpp and AXVoice.h,
// commit e6f3ae17627e4344da95b13424af5baf4c892b08. Host API, validation,
// transactional decoding, physical-memory adapter and tests added locally.
#include "protector/ax_audio.h"

#include <limits.h>
#include <string.h>

static s16 clamp16(s64 value) {
    return (s16)(value < INT16_MIN ? INT16_MIN :
                 value > INT16_MAX ? INT16_MAX : value);
}

/* Explicit arithmetic shift keeps negative rounding portable in C11. */
static s64 shift_right(s64 value, unsigned bits) {
    if (value >= 0) return value >> bits;
    return -1 - ((-1 - value) >> bits);
}

static s16 signed16(u16 value) {
    return (s16)(value <= INT16_MAX ? (s32)value : (s32)value - 65536);
}

bool protector_ax_read_physical_byte(void* context, u32 address, u8* value) {
    const CPUState* cpu = context;
    if (!cpu || !value) return false;
    if (cpu->ram && address < cpu->ram_size) {
        *value = cpu->ram[address];
        return true;
    }
    if (cpu->mem2 && address >= 0x10000000u &&
        address - 0x10000000u < cpu->mem2_size) {
        *value = cpu->mem2[address - 0x10000000u];
        return true;
    }
    return false;
}

typedef struct Decoder {
    ProtectorAXVoice voice;
    ProtectorAXReadByte read;
    void* context;
    bool stopped;
    bool failed;
} Decoder;

static u8 read_byte(Decoder* decoder, u32 address) {
    u8 value = 0;
    if (!decoder->failed && !decoder->read(decoder->context, address, &value))
        decoder->failed = true;
    return value;
}

static s16 next_sample(Decoder* decoder) {
    if (decoder->stopped || decoder->failed) return 0;
    ProtectorAXVoice* v = &decoder->voice;
    u16 raw;
    if (v->format == 0u) {
        const u8 byte = read_byte(decoder, v->current_address >> 1);
        raw = v->current_address & 1u ? byte & 15u : byte >> 4;
    } else if (v->format == 25u) {
        raw = read_byte(decoder, v->current_address);
    } else {
        const u32 address = v->current_address * 2u;
        raw = (u16)((u16)read_byte(decoder, address) << 8);
        raw |= read_byte(decoder, address + 1u);
    }
    const unsigned predictor = ((v->predictor_scale >> 4) & 7u) * 2u;
    const s64 c1 = v->adpcm_coefficients[predictor];
    const s64 c2 = v->adpcm_coefficients[predictor + 1u];
    s16 value;
    u32 step = 2u;
    if (v->format == 0u) {
        const s32 nibble = raw < 8u ? raw : (s32)raw - 16;
        const s32 scale = 1 << (v->predictor_scale & 15u);
        value = clamp16((s64)scale * nibble + shift_right(
            0x400 + c1 * v->history_1 + c2 * v->history_2, 11));
    } else {
        const unsigned shift = v->format == 25u ? 0u : 11u;
        const s64 decoded = shift_right((s64)v->gain * signed16(raw), shift) +
            shift_right(c1 * v->history_1, shift) +
            shift_right(c2 * v->history_2, shift);
        value = signed16((u16)decoded);  // PCM wraps; ADPCM saturates.
    }
    v->history_2 = v->history_1;
    v->history_1 = value;
    v->current_address++;
    if (v->format == 0u) {
        if ((v->end_address & 15u) == 0u && v->current_address == v->end_address) {
            v->current_address = v->loop_address + 1u;
        } else if ((v->end_address & 15u) == 1u &&
                   v->current_address == v->end_address - 1u) {
            v->current_address = v->loop_address;
        } else if ((v->current_address & 15u) == 0u) {
            v->predictor_scale = read_byte(decoder, v->current_address >> 1) & 0x7fu;
            v->current_address += 2u;
            step += 2u;
        }
    }
    if (v->current_address == v->end_address + step - 1u) {
        v->current_address = v->loop_address;
        if (v->looping) {
            v->predictor_scale = v->loop_predictor_scale & 0x7fu;
            if (!v->stream) {
                v->history_1 = v->loop_history_1;
                v->history_2 = v->loop_history_2;
            }
        } else {
            v->running = false;
            decoder->stopped = true;
        }
    }
    v->current_address &= 0xbfffffffu;
    return value;
}

ProtectorAXAudioResult protector_ax_decode_voice(
    ProtectorAXVoice* voice, ProtectorAXReadByte read, void* context,
    const s16* coefficients, size_t coefficient_count,
    u16 count, s16* output) {
    if (!voice || !read || !output || count == 0u ||
        count > PROTECTOR_AX_AUDIO_MAX_SAMPLES)
        return PROTECTOR_AX_AUDIO_INVALID_ARGUMENT;
    if (!voice->running) {
        memset(output, 0, count * sizeof(*output));
        return PROTECTOR_AX_AUDIO_OK;
    }
    if (voice->format != 0u && voice->format != 10u && voice->format != 25u)
        return PROTECTOR_AX_AUDIO_UNSUPPORTED_FORMAT;
    if (voice->src_type > 2u) return PROTECTOR_AX_AUDIO_UNSUPPORTED_SRC;
    if (voice->src_type == 0u &&
        (!coefficients || coefficient_count < PROTECTOR_AX_AUDIO_COEFFICIENTS ||
         voice->coefficient_set > 3u))
        return PROTECTOR_AX_AUDIO_MISSING_COEFFICIENTS;
    if (voice->src_type != 2u && (voice->ratio < 128u || voice->ratio > 0x40000u))
        return PROTECTOR_AX_AUDIO_INVALID_RATIO;

    Decoder decoder = {*voice, read, context, false, false};
    ProtectorAXVoice* v = &decoder.voice;
    v->current_address &= 0xbfffffffu;
    v->end_address &= 0x3fffffffu;
    v->loop_address &= 0x3fffffffu;
    v->predictor_scale &= 0x7fu;
    s16 result[PROTECTOR_AX_AUDIO_MAX_SAMPLES];
    s16 history[4];
    memcpy(history, v->last_samples, sizeof(history));
    u32 head = 0u;
    u32 fraction = v->fraction;
    for (u32 i = 0; i < count; ++i) {
        if (v->src_type == 2u) {
            result[i] = next_sample(&decoder);
            history[head++ & 3u] = result[i];
        } else {
            fraction += v->ratio;
            while (fraction >= 0x10000u) {
                history[head++ & 3u] = next_sample(&decoder);
                fraction -= 0x10000u;
            }
            if (v->src_type == 0u) {
                const s16* c = coefficients + v->coefficient_set * 512u +
                    ((fraction >> 9) * 4u);
                s64 sum = 0;
                for (u32 tap = 0; tap < 4u; ++tap)
                    sum += (s64)history[(head + tap) & 3u] * c[tap];
                result[i] = clamp16(shift_right(sum, 15));
            } else if (fraction != 0u) {
                const s64 a = history[head & 3u];
                const s64 b = history[(head + 1u) & 3u];
                result[i] = (s16)shift_right(a * (65536u - fraction) + b * fraction, 16);
            } else {
                result[i] = history[head & 3u];
            }
        }
    }
    if (decoder.failed) return PROTECTOR_AX_AUDIO_UNMAPPED_SAMPLE;
    for (u32 i = 0; i < 4u; ++i) v->last_samples[i] = history[(head + i) & 3u];
    v->fraction = (u16)fraction;
    *voice = *v;
    memcpy(output, result, count * sizeof(*output));
    return PROTECTOR_AX_AUDIO_OK;
}

bool protector_ax_mix_voice(
    ProtectorAXVoiceMix* mix, const s16* input, u16 count,
    s32 buses[PROTECTOR_AX_AUDIO_BUSES][PROTECTOR_AX_AUDIO_MAX_SAMPLES]) {
    if (!mix || !input || !buses || count == 0u || count > PROTECTOR_AX_AUDIO_MAX_SAMPLES)
        return false;
    for (u32 i = 0; i < count; ++i) {
        s16 sample = clamp16(shift_right((s64)input[i] * mix->envelope, 15));
        mix->envelope = (u16)(mix->envelope + mix->envelope_delta);
        if (mix->low_pass) {
            sample = clamp16(shift_right((s64)mix->low_pass_a0 * sample +
                (s64)mix->low_pass_b0 * mix->low_pass_history, 15));
            mix->low_pass_history = sample;
        }
        if (mix->biquad) {
            s64 sum = (s64)mix->biquad_b0 * sample +
                (s64)mix->biquad_b1 * mix->biquad_x1 +
                (s64)mix->biquad_b2 * mix->biquad_x2 +
                (s64)mix->biquad_a1 * mix->biquad_y1 +
                (s64)mix->biquad_a2 * mix->biquad_y2;
            sum *= 4;
            sum += ((u64)sum & 0x10000u) ? 0x8000 : 0x7fff;
            const s16 filtered = clamp16(shift_right(sum, 16));
            mix->biquad_x2 = mix->biquad_x1;
            mix->biquad_x1 = sample;
            mix->biquad_y2 = mix->biquad_y1;
            mix->biquad_y1 = filtered;
            sample = filtered;
        }
        for (u32 bus = 0; bus < PROTECTOR_AX_AUDIO_BUSES; ++bus) {
            ProtectorAXMixVolume* volume = &mix->buses[bus];
            if (!volume->enabled) continue;
            const s16 scaled = clamp16(shift_right((s64)sample * volume->volume, 15));
            /* Hardware accumulation is 32-bit, including wrap at overflow. */
            const u32 sum = (u32)buses[bus][i] + (u32)(s32)scaled;
            buses[bus][i] = sum <= INT32_MAX ? (s32)sum :
                (s32)((s64)sum - 0x100000000LL);
            if (volume->ramp) volume->volume = (u16)(volume->volume + volume->delta);
            volume->last_sample = scaled;
        }
    }
    return true;
}

const char* protector_ax_audio_result_name(ProtectorAXAudioResult result) {
    switch (result) {
        case PROTECTOR_AX_AUDIO_OK: return "ok";
        case PROTECTOR_AX_AUDIO_INVALID_ARGUMENT: return "invalid_argument";
        case PROTECTOR_AX_AUDIO_UNSUPPORTED_FORMAT: return "unsupported_format";
        case PROTECTOR_AX_AUDIO_UNSUPPORTED_SRC: return "unsupported_src";
        case PROTECTOR_AX_AUDIO_MISSING_COEFFICIENTS: return "missing_coefficients";
        case PROTECTOR_AX_AUDIO_INVALID_RATIO: return "invalid_ratio";
        case PROTECTOR_AX_AUDIO_UNMAPPED_SAMPLE: return "unmapped_sample";
        case PROTECTOR_AX_AUDIO_UNSUPPORTED_UCODE: return "unsupported_ucode";
        case PROTECTOR_AX_AUDIO_UNSUPPORTED_EFFECT: return "unsupported_effect";
    }
    return "unknown";
}
