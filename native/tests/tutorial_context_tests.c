#include "protector/tutorial_context.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static void lifecycle(void) {
    ProtectorTutorialTracker tracker = {0};
    assert(protector_tutorial_frame(&tracker, 0) == PROTECTOR_UI_GAMEPLAY);
    tracker.count = 1;
    tracker.owners[0] = (ProtectorTutorialOwner){0x80001000, 0x90000000, 0, 12, PROTECTOR_UI_READING};
    assert(protector_tutorial_frame(&tracker, 14) == PROTECTOR_UI_READING);
    assert(protector_tutorial_frame(&tracker, 15) == PROTECTOR_UI_GAMEPLAY);
    assert(tracker.count == 0);
    tracker.count = 1;
    tracker.owners[0] = (ProtectorTutorialOwner){0x80001000, 0x90000000, 0, 12, PROTECTOR_UI_INSTRUCTION};
    assert(protector_tutorial_frame(&tracker, 11) == PROTECTOR_UI_GAMEPLAY);
}

static void redirect(void) {
    CPUState cpu = {0};
    cpu.ram_size = 0x300000; cpu.ram = calloc(1, cpu.ram_size);
    assert(cpu.ram);
    const u32 parameters = 0x80001000, table = 0x80002000, key = 0x80003000, text = 0x80004000;
    memcpy(cpu.ram + 0x3000, "panel-options-15", 17);
    mem_write32(&cpu, parameters + 8, table); mem_write32(&cpu, table, key);
    mem_write32(&cpu, table + 8, text); mem_write32(&cpu, 0x80256988, 1);
    mem_write8(&cpu, text, 1);
    cpu.pc = 0x80044884; cpu.gpr[3] = text; cpu.gpr[4] = parameters;
    cpu.gpr[24] = 0x80005000; cpu.gpr[26] = 0x90104744; cpu.presented_frame_count = 70;
    const CPUState before = cpu;
    ProtectorTutorialTracker tracker = {.pending_context = cpu.gpr[24], .pending_ip = cpu.gpr[26],
        .pending_text = text, .pending_frame = 70};
    const ProtectorTutorialTracker pending = tracker;
    assert(protector_tutorial_redirect_glyph(&tracker, &cpu, 0x8004488c));
    assert(cpu.gpr[3] == text + 1 && cpu.ram[0x4000] == 1 && cpu.ram[0x4001] == 0);
    assert(!protector_tutorial_redirect_glyph(&tracker, &cpu, 0x8004488c));
    cpu.gpr[3] = text;
    assert(!memcmp(&cpu, &before, sizeof(cpu)));
    for (unsigned failure = 0; failure < 7; ++failure) {
        tracker = pending;
        const u32 seam = failure == 0 ? 0x80044890 : 0x8004488c;
        if (failure == 1) cpu.gpr[3] += 1;
        if (failure == 2) cpu.gpr[24] += 4;
        if (failure == 3) cpu.gpr[26] += 4;
        if (failure == 4) cpu.presented_frame_count += 1;
        if (failure == 5) cpu.ram[0x4000] = 2;
        if (failure == 6) cpu.ram[0x3000] = 'P';
        assert(!protector_tutorial_redirect_glyph(&tracker, &cpu, seam));
        cpu = before; cpu.ram[0x4000] = 1; cpu.ram[0x3000] = 'p';
    }
    free(cpu.ram);
}

static void source_checks(const char* folder) {
    size_t count = 0, anchors = 0;
    const ProtectorTutorialRule* rules = protector_tutorial_rules(&count);
    assert(count == 108);
    for (size_t r = 0; r < count; ++r) {
        const ProtectorTutorialRule* rule = &rules[r];
        char path[2048]; snprintf(path, sizeof(path), "%s/%s.bin", folder, rule->package);
        FILE* file = fopen(path, "rb"); assert(file);
        CPUState cpu = {0}; cpu.mem2_size = rule->source.file_info_size;
        cpu.mem2 = malloc(cpu.mem2_size); assert(cpu.mem2);
        assert(fread(cpu.mem2, 1, cpu.mem2_size, file) == cpu.mem2_size); fclose(file);
        cpu.presented_frame_count = 7;
        const CPUState before = cpu;
        for (unsigned a = 0; a < 5; ++a) {
            const u32 offset = a < 3 ? rule->reading[a] : rule->ready[a - 3];
            if (!offset) continue;
            ++anchors;
            const u32 target = a == 0 && rule->reading[1] ? 0x80044278u :
                a == 2 ? 0x80043cc4u : 0x8004485cu;
            ProtectorUIText text = {.key_available = true, .language_slot = 1, .text_size = 1,
                .text_address = 0x80004000, .text = {1, 0}};
            strcpy(text.key, a < 3 ? "Tutorial-Header-1" : "panel-options-15");
            const u32 ip = 0x90000000 + offset, context = 0x80001000;
            ProtectorTutorialTracker tracker = {0};
            assert(protector_tutorial_observe(&tracker, &cpu, &text, target, context, ip) == (a >= 3));
            assert(tracker.count == 1 && tracker.admission_count == 1);
            assert(protector_tutorial_frame(&tracker, 7) == (a < 3 ? PROTECTOR_UI_READING : PROTECTOR_UI_INSTRUCTION));
            assert(protector_tutorial_observe(&tracker, &cpu, &text, target, context, ip) == (a >= 3));
            assert(tracker.admission_count == 1);
            assert(!protector_tutorial_observe(&tracker, &cpu, &text, target, context, ip + 4));
            assert(!tracker.pending_text);
            protector_tutorial_dispatch(&tracker, context, 0x90000000 + rule->depart, 0x81000000, 8);
            assert(protector_tutorial_frame(&tracker, 8) == PROTECTOR_UI_GAMEPLAY);
            /* Rendering the header during fade-out cannot restore controls. */
            assert(!protector_tutorial_observe(&tracker, &cpu, &text, target, context, ip));
            assert(tracker.owners[0].kind == PROTECTOR_UI_GAMEPLAY);
            protector_tutorial_dispatch(&tracker, context, ip, 0x89000000, 8);
            assert(!tracker.count);
            cpu.mem2[rule->source.code_offset] ^= 1;
            assert(!protector_tutorial_observe(&tracker, &cpu, &text, target, context, ip));
            assert(!tracker.count);
            cpu.mem2[rule->source.code_offset] ^= 1;
            assert(!protector_tutorial_observe(&tracker, &cpu, &text, target, context, ip + 4));
            if (a >= 3) {
                text.text[0] = 2;
                assert(!protector_tutorial_observe(&tracker, &cpu, &text, target, context, ip));
                text.text[0] = 1; text.key[0] = 'P';
                assert(!protector_tutorial_observe(&tracker, &cpu, &text, target, context, ip));
            }
        }
        assert(!memcmp(&cpu, &before, sizeof(cpu)));
        free(cpu.mem2);
    }
    assert(anchors == 484);
    puts("tutorial_context_tests: 108 source blocks, 484 anchors, cache, exact glyph, dismissal, fade, mutations and wrong IP passed");
}

int main(int argc, char** argv) {
    lifecycle(); redirect();
    if (argc == 2) source_checks(argv[1]);
    else puts("tutorial_context_tests: lifecycle and one-shot renderer-argument safety passed");
    return 0;
}
