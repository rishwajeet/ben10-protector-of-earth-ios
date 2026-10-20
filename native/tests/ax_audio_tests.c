#include "protector/ax_audio.h"
#include "protector/ax_engine.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(test) do { if (!(test)) { \
    fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #test); ++failures; \
} } while (0)

typedef struct Memory { u8 bytes[2048]; size_t size; } Memory;
static bool read_sample(void* context, u32 address, u8* value) {
    Memory* memory = context;
    if (address >= memory->size) return false;
    *value = memory->bytes[address];
    return true;
}

static ProtectorAXVoice pcm16(void) {
    ProtectorAXVoice voice = {0};
    voice.running = true;
    voice.format = 10;
    voice.gain = 2048;
    voice.src_type = 2;
    voice.ratio = 65536;
    voice.end_address = 999;
    return voice;
}

static void write16(Memory* memory, u32 address, s16 sample) {
    memory->bytes[address] = (u16)sample >> 8;
    memory->bytes[address + 1] = (u8)sample;
}

static void test_pcm_and_end(void) {
    Memory memory = {.size = 16};
    const s16 expected[] = {1234, -3000, INT16_MAX, INT16_MIN, 0, 0, 0, 0};
    for (u32 i = 0; i < 4; ++i) write16(&memory, i * 2, expected[i]);
    ProtectorAXVoice voice = pcm16();
    voice.end_address = 3;
    s16 output[8];
    CHECK(protector_ax_decode_voice(&voice, read_sample, &memory, NULL, 0, 8, output) == 0);
    CHECK(memcmp(output, expected, sizeof(output)) == 0);
    CHECK(!voice.running && voice.current_address == 0);
    CHECK(voice.history_1 == INT16_MIN && voice.history_2 == INT16_MAX);
    CHECK(voice.last_samples[0] == 0 && voice.last_samples[3] == 0);

    voice = pcm16();
    voice.format = 25;
    voice.gain = 256;
    voice.end_address = 3;
    memory.bytes[0] = 0; memory.bytes[1] = 127;
    memory.bytes[2] = 128; memory.bytes[3] = 255;
    CHECK(protector_ax_decode_voice(&voice, read_sample, &memory, NULL, 0, 4, output) == 0);
    CHECK(output[0] == 0 && output[1] == 32512 && output[2] == -32768 && output[3] == -256);
}

static void test_adpcm_header_predictor_and_loop(void) {
    Memory memory = {.bytes = {0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde,
                              1, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11}, .size = 32};
    ProtectorAXVoice voice = pcm16();
    voice.format = 0;
    voice.current_address = 2;
    voice.end_address = 19;
    s16 output[20];
    CHECK(protector_ax_decode_voice(&voice, read_sample, &memory, NULL, 0, 20, output) == 0);
    const s16 expected[] = {1, 2, 3, 4, 5, 6, 7, -8, -7, -6, -5, -4, -3, -2, 2, 2, 0, 0, 0, 0};
    CHECK(memcmp(output, expected, sizeof(output)) == 0);
    CHECK(!voice.running && voice.current_address == 0 && voice.predictor_scale == 1);

    voice = pcm16();
    voice.format = 0; voice.current_address = 2; voice.end_address = 3;
    voice.loop_address = 2; voice.looping = true;
    voice.adpcm_coefficients[0] = 2048;
    voice.history_1 = 10; voice.loop_history_1 = 100;
    CHECK(protector_ax_decode_voice(&voice, read_sample, &memory, NULL, 0, 4, output) == 0);
    CHECK(output[0] == 11 && output[1] == 13 && output[2] == 101 && output[3] == 103);
    CHECK(voice.running && voice.current_address == 2 && voice.history_1 == 100);
    voice.stream = true;
    CHECK(protector_ax_decode_voice(&voice, read_sample, &memory, NULL, 0, 4, output) == 0);
    CHECK(output[0] == 101 && output[1] == 103 && output[2] == 104 && output[3] == 106);

    voice = pcm16(); voice.format = 0; voice.current_address = 2;
    voice.predictor_scale = 15;
    CHECK(protector_ax_decode_voice(&voice, read_sample, &memory, NULL, 0, 8, output) == 0);
    CHECK(output[0] == 32767 && output[7] == -32768);
}

static void test_resampling_and_failure_atomicity(void) {
    Memory memory = {.size = sizeof(memory.bytes)};
    for (u32 i = 0; i < 128; ++i) write16(&memory, i * 2, (s16)(1000 + 1000 * i));
    ProtectorAXVoice voice = pcm16();
    voice.src_type = 1; voice.ratio = 32768;
    s16 output[8];
    CHECK(protector_ax_decode_voice(&voice, read_sample, &memory, NULL, 0, 8, output) == 0);
    const s16 expected[] = {0, 0, 0, 0, 0, 0, 500, 1000};
    CHECK(memcmp(output, expected, sizeof(output)) == 0);
    CHECK(voice.current_address == 4 && voice.fraction == 0);
    CHECK(voice.last_samples[0] == 1000 && voice.last_samples[3] == 4000);

    voice.src_type = 0;
    ProtectorAXVoice before = voice;
    s16 old_output[8]; memcpy(old_output, output, sizeof(output));
    CHECK(protector_ax_decode_voice(&voice, read_sample, &memory, NULL, 0, 8, output) ==
          PROTECTOR_AX_AUDIO_MISSING_COEFFICIENTS);
    CHECK(memcmp(&voice, &before, sizeof(voice)) == 0);
    CHECK(memcmp(output, old_output, sizeof(output)) == 0);
    voice.src_type = 2; voice.current_address = 1023;
    before = voice;
    CHECK(protector_ax_decode_voice(&voice, read_sample, &memory, NULL, 0, 8, output) ==
          PROTECTOR_AX_AUDIO_UNMAPPED_SAMPLE);
    CHECK(memcmp(&voice, &before, sizeof(voice)) == 0);
    CHECK(memcmp(output, old_output, sizeof(output)) == 0);

    s16 coefficients[2048] = {0};
    for (u32 phase = 0; phase < 128; ++phase) coefficients[512 + phase * 4 + 3] = 16384;
    voice = pcm16(); voice.src_type = 0; voice.coefficient_set = 1;
    CHECK(protector_ax_decode_voice(&voice, read_sample, &memory, coefficients, 2048, 8, output) == 0);
    for (u32 i = 0; i < 8; ++i) CHECK(output[i] == (s16)(500 + i * 500));
    voice.ratio = 0xffffffffu;
    CHECK(protector_ax_decode_voice(&voice, read_sample, &memory, coefficients, 2048, 8, output) ==
          PROTECTOR_AX_AUDIO_INVALID_RATIO);
}

static u32 random_word(u32* state) {
    *state = *state * 1664525u + 1013904223u;
    return *state;
}

static void test_chunk_continuity(void) {
    u32 seed = 1234567;
    Memory memory = {.size = sizeof(memory.bytes)};
    s16 coefficients[2048];
    for (u32 i = 0; i < 2048; ++i) coefficients[i] = (s16)(random_word(&seed) >> 16);
    for (u32 test = 0; test < 1000; ++test) {
        for (u32 i = 0; i < memory.size; ++i) memory.bytes[i] = random_word(&seed) >> 24;
        ProtectorAXVoice full = pcm16();
        full.src_type = test % 3; full.ratio = 128 + random_word(&seed) % (0x40000 - 127);
        full.fraction = (u16)random_word(&seed);
        full.format = test % 2 ? 10 : 0;
        full.current_address = full.format == 0 ? 2 : 0;
        full.coefficient_set = test % 4;
        for (u32 i = 0; i < 16; ++i) full.adpcm_coefficients[i] = (s16)(random_word(&seed) >> 16);
        ProtectorAXVoice chunks = full;
        s16 a[96], b[96];
        CHECK(protector_ax_decode_voice(&full, read_sample, &memory, coefficients, 2048, 96, a) == 0);
        for (u32 part = 0; part < 3; ++part)
            CHECK(protector_ax_decode_voice(&chunks, read_sample, &memory, coefficients, 2048, 32, b + part * 32) == 0);
        CHECK(memcmp(a, b, sizeof(a)) == 0);
        CHECK(memcmp(&full, &chunks, sizeof(full)) == 0);
    }
}

static void test_mixing(void) {
    ProtectorAXVoiceMix mix = {.envelope = 32768};
    mix.buses[0] = (ProtectorAXMixVolume){.volume = 32768, .enabled = true};
    mix.buses[1] = (ProtectorAXMixVolume){.volume = 16384, .delta = -4096, .enabled = true, .ramp = true};
    mix.buses[9] = (ProtectorAXMixVolume){.volume = 32768, .enabled = true};
    s16 samples[4] = {1000, -2000, 3000, -4000};
    s32 buses[12][96] = {{0}};
    CHECK(protector_ax_mix_voice(&mix, samples, 4, buses));
    CHECK(buses[0][0] == 1000 && buses[0][3] == -4000);
    CHECK(buses[1][0] == 500 && buses[1][1] == -750 && buses[1][2] == 750 && buses[1][3] == -500);
    CHECK(buses[2][0] == 0 && buses[9][3] == -4000);
    CHECK(mix.buses[0].last_sample == -4000 && mix.buses[1].volume == 0);
    mix.low_pass = true; mix.low_pass_a0 = 16384; mix.low_pass_b0 = 16384;
    memset(buses, 0, sizeof(buses));
    CHECK(protector_ax_mix_voice(&mix, samples, 4, buses));
    CHECK(buses[0][0] == 500 && buses[0][1] == -750 && buses[0][2] == 1125 && buses[0][3] == -1438);
    CHECK(mix.low_pass_history == -1438);
    mix.low_pass = false; mix.envelope = 65535;
    samples[0] = 32767; buses[0][0] = INT32_MAX;
    CHECK(protector_ax_mix_voice(&mix, samples, 1, buses));
    CHECK(buses[0][0] == INT32_MIN + 32766);
}

static void test_physical_memory(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    u8 value = 0;
    cpu.ram[12] = 123;
    CHECK(protector_ax_read_physical_byte(&cpu, 12, &value) && value == 123);
    CHECK(!protector_ax_read_physical_byte(&cpu, GC_RAM_BASE + 12, &value));
    CHECK(!protector_ax_read_physical_byte(&cpu, cpu.ram_size, &value));
    CHECK(!protector_ax_read_physical_byte(&cpu, 0xffffffffu, &value));
    if (cpu.mem2) {
        cpu.mem2[15] = 87;
        CHECK(protector_ax_read_physical_byte(&cpu, 0x1000000fu, &value) && value == 87);
    }
    protector_cpu_destroy(&cpu);
}

static void test_guest_pb_adapter(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    const u32 pb = GC_RAM_BASE + 0x1000;
    const u32 sample = GC_RAM_BASE + 0x2000;
    mem_write16(&cpu, pb + 0x10, 1);  // running
    mem_write16(&cpu, pb + 0x08, 2);  // no SRC
    mem_write32(&cpu, pb + 0x0c, 0x08000003); // main L/R, AUX C R
    mem_write16(&cpu, pb + 0x14, 0x8000);
    mem_write16(&cpu, pb + 0x18, 0x4000);
    mem_write16(&cpu, pb + 0x30, 0x2000);
    mem_write16(&cpu, pb + 0x6a, 0x8000);
    mem_write16(&cpu, pb + 0x70, 10);  // PCM16
    mem_write32(&cpu, pb + 0x76, 0x1090);
    mem_write32(&cpu, pb + 0x7a, 0x1000);
    mem_write16(&cpu, pb + 0x9e, 2048);
    mem_write32(&cpu, pb + 0xa6, 65536);
    for (u32 i = 0; i < 100; ++i) mem_write16(&cpu, sample + i * 2, (u16)(i * 100));
    s32 buses[12][96] = {{0}};
    CHECK(protector_ax_process_pb(&cpu, pb, 0x347112ba, NULL, 0, buses) == 0);
    CHECK(buses[0][95] == 9500 && buses[1][95] == 4750 && buses[10][95] == 2375);
    CHECK(buses[2][95] == 0 && buses[9][95] == 0);
    CHECK(mem_read32(&cpu, pb + 0x7a) == 0x1060);
    CHECK(mem_read16(&cpu, pb + 0x52) == 9500 && mem_read16(&cpu, pb + 0x60) == 2375);
    CHECK(mem_read16(&cpu, pb + 0xa2) == 9500 && mem_read16(&cpu, pb + 0xa4) == 9400);
    CHECK(mem_read16(&cpu, pb + 0xac) == 9200 && mem_read16(&cpu, pb + 0xb2) == 9500);
    u8 before[0x140]; memcpy(before, cpu.ram + 0x1000, sizeof(before));
    s32 bus_before[12][96]; memcpy(bus_before, buses, sizeof(buses));
    CHECK(protector_ax_process_pb(&cpu, pb, 0x12345678, NULL, 0, buses) == PROTECTOR_AX_AUDIO_UNSUPPORTED_UCODE);
    CHECK(memcmp(before, cpu.ram + 0x1000, sizeof(before)) == 0);
    CHECK(memcmp(bus_before, buses, sizeof(buses)) == 0);
    mem_write16(&cpu, pb + 0xd6, 1);
    CHECK(protector_ax_process_pb(&cpu, pb, 0x347112ba, NULL, 0, buses) == PROTECTOR_AX_AUDIO_UNSUPPORTED_EFFECT);
    CHECK(memcmp(bus_before, buses, sizeof(buses)) == 0);
    mem_write16(&cpu, pb + 0xd6, 0);
    mem_write32(&cpu, pb + 0x7a, 0x1000);
    mem_write16(&cpu, pb + 0xc2, 1); // identity biquad
    mem_write16(&cpu, pb + 0xcc, 16384);
    memset(buses, 0, sizeof(buses));
    CHECK(protector_ax_process_pb(&cpu, pb, 0x347112ba, NULL, 0, buses) == 0);
    CHECK(buses[0][1] == 100 && buses[0][95] == 9500);
    CHECK(mem_read16(&cpu, pb + 0xc8) == 9500 && mem_read16(&cpu, pb + 0xca) == 9400);
    protector_cpu_destroy(&cpu);
}

static s16 captured_pcm[192];
static bool capture_pcm(void* context, const s16* samples, u32 frames) {
    u32* calls = context;
    if (frames != 96) return false;
    (*calls)++;
    memcpy(captured_pcm, samples, sizeof(captured_pcm));
    return true;
}

static void test_command_engine(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    ProtectorAXEngine engine;
    u32 calls = 0;
    protector_ax_engine_init(&engine, NULL, 0, capture_pcm, &calls);
    engine.configured = true; engine.ucode_hash = 0x347112ba;
    const u32 pb = GC_RAM_BASE + 0x1000;
    mem_write16(&cpu, pb + 0x10, 1);
    mem_write16(&cpu, pb + 0x08, 2);
    mem_write32(&cpu, pb + 0x0c, 3);
    mem_write16(&cpu, pb + 0x14, 32768); mem_write16(&cpu, pb + 0x18, 16384);
    mem_write16(&cpu, pb + 0x6a, 32768); mem_write16(&cpu, pb + 0x70, 10);
    mem_write32(&cpu, pb + 0x76, 0x1090); mem_write32(&cpu, pb + 0x7a, 0x1000);
    mem_write16(&cpu, pb + 0x9e, 2048);
    for (u32 i = 0; i < 96; ++i) {
        mem_write16(&cpu, GC_RAM_BASE + 0x2000 + i * 2, (u16)(i * 100));
        mem_write32(&cpu, GC_RAM_BASE + 0x4000 + i * 4, 1000);
    }
    /* The same command set as RBNEG9's captured title mix, with synthetic data. */
    const u16 commands[] = {0, 0x8000, 0x3000, 1, 0x8000, 0x4000,
        4, 0x8000, 0x1000, 10, 65535, 10, 0x8000, 0x8000,
        13, 0x8000, 0x9000, 0x8000, 0x9040, 0x8000, 0x9080, 0x8000, 0x90c0,
        11, 32768, 0x8000, 0x5000, 0x8000, 0x6000, 14};
    for (u32 i = 0; i < sizeof(commands) / sizeof(commands[0]); ++i)
        mem_write16(&cpu, GC_RAM_BASE + 0x7000 + i * 2, commands[i]);
    CHECK(protector_ax_engine_mail(&engine, &cpu, 0xbabe0000u | (sizeof(commands) / sizeof(commands[0]))));
    CHECK(engine.pending_words != 0);
    CHECK(protector_ax_engine_mail(&engine, &cpu, GC_RAM_BASE + 0x7000));
    CHECK(engine.command_lists == 1 && engine.output_frames == 96 && engine.voices_processed == 1);
    CHECK(calls == 1 && captured_pcm[0] == 1000 && captured_pcm[1] == 1000);
    CHECK(captured_pcm[190] == 10500 && captured_pcm[191] == 5750);
    CHECK(mem_read16(&cpu, GC_RAM_BASE + 0x6000 + 95 * 4) == 5750);
    CHECK(mem_read16(&cpu, GC_RAM_BASE + 0x6000 + 95 * 4 + 2) == 10500);
    CHECK(mem_read32(&cpu, GC_RAM_BASE + 0x5000 + 95 * 4) == 0);
    CHECK(mem_read16(&cpu, GC_RAM_BASE + 0x90c0) == 0);
    CHECK(!engine.error[0] && engine.pending_words == 0);
    CHECK(!protector_ax_engine_execute(&engine, &cpu, GC_RAM_BASE + 0x7000, 2));
    CHECK(strstr(engine.error, "truncated") != NULL);

    protector_ax_engine_init(&engine, NULL, 0, NULL, NULL);
    engine.configured = true; engine.ucode_hash = 0x347112ba;
    mem_write16(&cpu, GC_RAM_BASE + 0x7000, 4);
    mem_write16(&cpu, GC_RAM_BASE + 0x7002, 0x8000);
    mem_write16(&cpu, GC_RAM_BASE + 0x7004, 0x1000);
    mem_write16(&cpu, GC_RAM_BASE + 0x7006, 14);
    mem_write32(&cpu, pb, pb);
    CHECK(!protector_ax_engine_execute(&engine, &cpu, GC_RAM_BASE + 0x7000, 4));
    CHECK(strstr(engine.error, "cyclic") != NULL);
    protector_cpu_destroy(&cpu);
}

static void execute_words(ProtectorAXEngine* e, CPUState* cpu, const u16* words, u16 count) {
    for (u32 i = 0; i < count; ++i) mem_write16(cpu, GC_RAM_BASE + 0x1000 + i * 2, words[i]);
    CHECK(protector_ax_engine_execute(e, cpu, GC_RAM_BASE + 0x1000, count));
}

static void test_auxiliary_and_compressor_commands(void) {
    CPUState cpu; CHECK(protector_cpu_init(&cpu));
    ProtectorAXEngine engine;
    protector_ax_engine_init(&engine, NULL, 0, NULL, NULL);
    engine.configured = true; engine.ucode_hash = 0x347112ba;
    for (u32 i = 0; i < 96; ++i) {
        engine.buses[3][i] = 1234;
        engine.buses[4][i] = -2345;
        engine.buses[5][i] = 3456;
        for (u32 bus = 0; bus < 3; ++bus)
            mem_write32(&cpu, GC_RAM_BASE + 0x3000 + bus * 384 + i * 4, (bus + 1) * 100);
    }
    const u16 aux[] = {5, 32768, 0x8000, 0x2000, 0x8000, 0x3000, 14};
    execute_words(&engine, &cpu, aux, sizeof(aux) / 2);
    CHECK(mem_read32(&cpu, GC_RAM_BASE + 0x2000) == 1234);
    CHECK((s32)mem_read32(&cpu, GC_RAM_BASE + 0x2000 + 384) == -2345);
    CHECK(engine.buses[0][95] == 100 && engine.buses[1][95] == 200 && engine.buses[2][95] == 300);
    for (u32 i = 0; i < 96; ++i) {
        engine.buses[10][i] = 9876;
        for (u32 bus = 0; bus < 4; ++bus)
            mem_write32(&cpu, GC_RAM_BASE + 0x4000 + bus * 384 + i * 4, (bus + 1) * 1000);
    }
    const u16 upload[] = {8, 32768, 0x8000, 0x2000, 0x8000, 0x3000,
        0x8000, 0x4000, 0x8000, 0x4180, 0x8000, 0x4300, 0x8000, 0x4480, 14};
    execute_words(&engine, &cpu, upload, sizeof(upload) / 2);
    CHECK(mem_read32(&cpu, GC_RAM_BASE + 0x3000) == 9876);
    CHECK(engine.buses[0][95] == 1100 && engine.buses[1][95] == 2200 &&
          engine.buses[2][95] == 3300 && engine.buses[9][95] == 4000 && engine.buses[3][95] == 4000);
    for (u32 i = 0; i < 96; ++i) {
        engine.buses[0][i] = 1000; engine.buses[1][i] = -2000;
        mem_write16(&cpu, GC_RAM_BASE + 0x9000 + i * 2, 16384);
        mem_write16(&cpu, GC_RAM_BASE + 0x9000 + 12 * 192 + i * 2, 24576);
    }
    const u16 compressor[] = {10, 1500, 2, 0x8000, 0x9000, 14};
    execute_words(&engine, &cpu, compressor, sizeof(compressor) / 2);
    CHECK(engine.buses[0][95] == 500 && engine.buses[1][95] == -1000 && engine.compressor_position == 2);
    execute_words(&engine, &cpu, compressor, sizeof(compressor) / 2);
    CHECK(engine.buses[0][95] == 375 && engine.buses[1][95] == -750 && engine.compressor_position == 1);
    CHECK(!protector_ax_engine_execute(&engine, &cpu, 0x40001000, 6));
    CHECK(strstr(engine.error, "alias") != NULL);
    protector_cpu_destroy(&cpu);
}

int main(void) {
    test_pcm_and_end();
    test_adpcm_header_predictor_and_loop();
    test_resampling_and_failure_atomicity();
    test_chunk_continuity();
    test_mixing();
    test_physical_memory();
    test_guest_pb_adapter();
    test_command_engine();
    test_auxiliary_and_compressor_commands();
    if (failures) { fprintf(stderr, "%d audio failures\n", failures); return EXIT_FAILURE; }
    puts("AX audio tests passed (1000 chunk-continuity cases plus format, loop, SRC, mixer and memory checks)");
    return EXIT_SUCCESS;
}
