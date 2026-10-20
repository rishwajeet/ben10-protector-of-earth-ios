// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later
// Wii PB layout and bus routing adapted from Dolphin AXStructs.h/AXWii.cpp,
// e6f3ae17627e4344da95b13424af5baf4c892b08. Explicit byte layout and checked
// transactional guest adapter are local. Only the identified RBNEG9 ucode
// is admitted; another game must supply its own verified layout.
#include "protector/ax_audio.h"

static s16 as_signed(u16 value) {
    return (s16)(value <= 32767u ? (s32)value : (s32)value - 65536);
}

static u32 pair(const u16* pb, unsigned offset) {
    return ((u32)pb[offset / 2] << 16) | pb[offset / 2 + 1];
}

static void put_pair(u16* pb, unsigned offset, u32 value) {
    pb[offset / 2] = (u16)(value >> 16);
    pb[offset / 2 + 1] = (u16)value;
}

ProtectorAXAudioResult protector_ax_process_pb(
    CPUState* cpu, u32 address, u32 ucode_hash,
    const s16* coefficients, size_t coefficient_count, s32 buses[12][96]) {
    if (!cpu || !cpu->ram || !buses || address < GC_RAM_BASE ||
        cpu->ram_size < 0x140u || address - GC_RAM_BASE > cpu->ram_size - 0x140u ||
        (address & 1u))
        return PROTECTOR_AX_AUDIO_INVALID_ARGUMENT;
    if (ucode_hash != 0x347112bau) return PROTECTOR_AX_AUDIO_UNSUPPORTED_UCODE;
    u16 pb[0xa0];
    const u8* source = cpu->ram + address - GC_RAM_BASE;
    for (u32 i = 0; i < 0xa0; ++i) pb[i] = ((u16)source[i * 2] << 8) | source[i * 2 + 1];
    if (pb[0x10 / 2] != 1u) return PROTECTOR_AX_AUDIO_OK;
    /* The core does not pretend that unsupported speaker/phase-delay routing
     * produced a correct mix. These modes can be added against captured use. */
    if (pb[0x44 / 2] || pb[0xd6 / 2]) return PROTECTOR_AX_AUDIO_UNSUPPORTED_EFFECT;
    ProtectorAXVoice voice = {0};
    voice.running = true;
    voice.stream = pb[0x12 / 2] == 1;
    voice.src_type = pb[0x08 / 2];
    voice.coefficient_set = pb[0x0a / 2];
    voice.looping = pb[0x6e / 2] != 0;
    voice.format = pb[0x70 / 2];
    voice.loop_address = pair(pb, 0x72);
    voice.end_address = pair(pb, 0x76);
    voice.current_address = pair(pb, 0x7a);
    for (u32 i = 0; i < 16; ++i) voice.adpcm_coefficients[i] = as_signed(pb[0x7e / 2 + i]);
    voice.gain = as_signed(pb[0x9e / 2]);
    voice.predictor_scale = pb[0xa0 / 2];
    voice.history_1 = as_signed(pb[0xa2 / 2]);
    voice.history_2 = as_signed(pb[0xa4 / 2]);
    voice.ratio = pair(pb, 0xa6);
    voice.fraction = pb[0xaa / 2];
    for (u32 i = 0; i < 4; ++i) voice.last_samples[i] = as_signed(pb[0xac / 2 + i]);
    voice.loop_predictor_scale = pb[0xb4 / 2];
    voice.loop_history_1 = as_signed(pb[0xb6 / 2]);
    voice.loop_history_2 = as_signed(pb[0xb8 / 2]);

    ProtectorAXVoiceMix mix = {0};
    mix.envelope = pb[0x6a / 2];
    mix.envelope_delta = as_signed(pb[0x6c / 2]);
    mix.low_pass = pb[0xba / 2] != 0;
    mix.low_pass_history = as_signed(pb[0xbc / 2]);
    mix.low_pass_a0 = pb[0xbe / 2];
    mix.low_pass_b0 = as_signed(pb[0xc0 / 2]);
    mix.biquad = pb[0xc2 / 2] != 0;
    mix.biquad_x1 = as_signed(pb[0xc4 / 2]); mix.biquad_x2 = as_signed(pb[0xc6 / 2]);
    mix.biquad_y1 = as_signed(pb[0xc8 / 2]); mix.biquad_y2 = as_signed(pb[0xca / 2]);
    mix.biquad_b0 = as_signed(pb[0xcc / 2]); mix.biquad_b1 = as_signed(pb[0xce / 2]);
    mix.biquad_b2 = as_signed(pb[0xd0 / 2]); mix.biquad_a1 = as_signed(pb[0xd2 / 2]);
    mix.biquad_a2 = as_signed(pb[0xd4 / 2]);

    const u32 control = pair(pb, 0x0c);
    /* Bus order is output order, independent of the DSP PB's packed order. */
    const u8 volume_offsets[12] = {0x14, 0x18, 0x34, 0x1c, 0x20, 0x38,
                                  0x24, 0x28, 0x3c, 0x2c, 0x30, 0x40};
    const u8 dpop_offsets[12] = {0x52, 0x5a, 0x62, 0x54, 0x5c, 0x64,
                                0x56, 0x5e, 0x66, 0x58, 0x60, 0x68};
    const u32 enable[12] = {1, 2, 8, 0x10000, 0x20000, 0x80000,
                            0x200000, 0x400000, 0x1000000, 0x4000000, 0x8000000, 0x20000000};
    const u32 ramp[12] = {4, 4, 16, 0x40000, 0x40000, 0x100000,
                          0x800000, 0x800000, 0x2000000, 0x10000000, 0x10000000, 0x40000000};
    for (u32 bus = 0; bus < 12; ++bus) {
        const u32 index = volume_offsets[bus] / 2;
        mix.buses[bus] = (ProtectorAXMixVolume){
            .volume = pb[index], .delta = as_signed(pb[index + 1]),
            .enabled = (control & (enable[bus] | ramp[bus])) != 0,
            .ramp = (control & ramp[bus]) != 0,
            .last_sample = as_signed(pb[dpop_offsets[bus] / 2])};
    }
    s16 samples[96];
    const ProtectorAXAudioResult result = protector_ax_decode_voice(
        &voice, protector_ax_read_physical_byte, cpu, coefficients, coefficient_count, 96, samples);
    if (result != PROTECTOR_AX_AUDIO_OK) return result;
    (void)protector_ax_mix_voice(&mix, samples, 96, buses);

    pb[0x10 / 2] = voice.running;
    put_pair(pb, 0x7a, voice.current_address);
    pb[0xa0 / 2] = voice.predictor_scale;
    pb[0xa2 / 2] = (u16)voice.history_1; pb[0xa4 / 2] = (u16)voice.history_2;
    pb[0xaa / 2] = voice.fraction;
    for (u32 i = 0; i < 4; ++i) pb[0xac / 2 + i] = (u16)voice.last_samples[i];
    pb[0x6a / 2] = mix.envelope;
    pb[0xbc / 2] = (u16)mix.low_pass_history;
    pb[0xc4 / 2] = (u16)mix.biquad_x1; pb[0xc6 / 2] = (u16)mix.biquad_x2;
    pb[0xc8 / 2] = (u16)mix.biquad_y1; pb[0xca / 2] = (u16)mix.biquad_y2;
    for (u32 bus = 0; bus < 12; ++bus) {
        pb[volume_offsets[bus] / 2] = mix.buses[bus].volume;
        pb[dpop_offsets[bus] / 2] = (u16)mix.buses[bus].last_sample;
    }
    u8* destination = cpu->ram + address - GC_RAM_BASE;
    for (u32 i = 0; i < 0xa0; ++i) {
        destination[i * 2] = pb[i] >> 8;
        destination[i * 2 + 1] = (u8)pb[i];
    }
    return PROTECTOR_AX_AUDIO_OK;
}
