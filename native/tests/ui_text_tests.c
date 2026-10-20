#include "protector/ui_text.h"
#include "protector/ui_copy.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static void put(CPUState* cpu, u32 address, u32 value) {
    u8* bytes = cpu->ram + address - GC_RAM_BASE;
    bytes[0] = value >> 24; bytes[1] = value >> 16;
    bytes[2] = value >> 8; bytes[3] = value;
}

int main(void) {
    CPUState cpu = {0};
    cpu.ram_size = 0x260000;
    cpu.ram = calloc(1, cpu.ram_size);
    assert(cpu.ram);
    const u32 args = 0x80000100, table = 0x80000200;
    put(&cpu, args, table);
    put(&cpu, args + 8, table);
    put(&cpu, table, 0x80000300);
    put(&cpu, table + 8, 0x80000400);
    put(&cpu, 0x80256988, 1);
    strcpy((char*)cpu.ram + 0x300, "Platform-Example-300");
    strcpy((char*)cpu.ram + 0x400, "Press \x05 to transform.\x1f" "Choose a form.");
    cpu.memory_read_count = 17;
    cpu.memory_write_count = 19;
    cpu.timebase = 29;
    CPUState before = cpu;
    ProtectorUIText result = {0};
    assert(protector_ui_text_read(&cpu, 0x80041FF8, args, &result));
    assert(!strcmp(result.key, "Platform-Example-300"));
    assert(result.key_available);
    assert(result.table == table && result.language_slot == 1);
    assert(!strcmp((char*)result.text, (char*)cpu.ram + 0x400));
    assert(!memcmp(&cpu, &before, sizeof(cpu)));
    assert(protector_ui_text_read(&cpu, 0x80044278, args, &result));
    assert(protector_ui_text_read(&cpu, 0x80043CC4, args, &result));
    assert(protector_ui_text_read(&cpu, 0x8004485C, args, &result));
    assert(protector_ui_text_read(&cpu, 0x80041FC8, args, &result));
    put(&cpu, 0x80256988, 4);
    assert(protector_ui_text_read(&cpu, 0x80041FF8, args, &result));
    assert(result.language_slot == 0); /* exact source fallback is the key */
    assert(!strcmp((char*)result.text, "Platform-Example-300"));
    put(&cpu, table + 4 * 8, 0x80000500);
    strcpy((char*)cpu.ram + 0x500, "Hola");
    assert(protector_ui_text_read(&cpu, 0x80041FF8, args, &result));
    assert(result.language_slot == 4 && !strcmp((char*)result.text, "Hola"));
    ProtectorUIText saved = result;
    put(&cpu, 0x80256988, 10);
    assert(!protector_ui_text_read(&cpu, 0x80041FF8, args, &result));
    assert(!memcmp(&saved, &result, sizeof(result)));
    put(&cpu, 0x80256988, 1);
    assert(!protector_ui_text_read(&cpu, 0x12345678, args, &result));
    assert(!protector_ui_text_read(&cpu, 0x8004485C, 0xFFFFFFFC, &result));
    assert(!protector_ui_text_read(&cpu, 0x8004485C, args + 1, &result));
    strcpy((char*)cpu.ram + 0x300, "Random debug message");
    assert(protector_ui_text_read(&cpu, 0x80041FF8, args, &result));
    assert(!result.key_available && !result.key[0]);
    assert(!strcmp((char*)result.text, (char*)cpu.ram + 0x400));
    assert(cpu.memory_read_count == 17 && cpu.memory_write_count == 19 && cpu.timebase == 29);
    strcpy((char*)cpu.ram + 0x300, "Platform-Example-300");
    assert(protector_ui_text_read(&cpu, 0x80041FF8, args, &result));
    const u32 old_size = result.text_size;
    const u8 tail = cpu.ram[0x400 + old_size];
    cpu.ram[0x3ff] = 0xAC;
    cpu.ram[0x401 + old_size] = 0xBD;
    assert(!protector_ui_text_replace(&cpu, &result,
        "This replacement is deliberately too long to fit in the source string."));
    assert(cpu.memory_write_count == 19);
    ProtectorUIText stale = result;
    stale.text[0] ^= 1;
    assert(!protector_ui_text_replace(&cpu, &stale, "New text"));
    stale = result; stale.language_slot = 0;
    assert(!protector_ui_text_replace(&cpu, &stale, "New text"));
    stale = result; stale.text_address++;
    assert(!protector_ui_text_replace(&cpu, &stale, "New text"));
    stale = result; stale.key[0] ^= 1;
    assert(!protector_ui_text_replace(&cpu, &stale, "New text"));
    assert(protector_ui_text_replace(&cpu, &result, "New text"));
    assert(!strcmp((char*)cpu.ram + 0x400, "New text"));
    assert(cpu.memory_write_count == 28 && cpu.memory_read_count == 17 && cpu.timebase == 29);
    assert(cpu.ram[0x3ff] == 0xAC && cpu.ram[0x401 + old_size] == 0xBD);
    assert(cpu.ram[0x400 + old_size] == tail);
    assert(!protector_ui_text_replace(&cpu, &result, "Stale"));
    // Full-capacity replacement may use the original terminator but no byte after it.
    assert(protector_ui_text_read(&cpu, 0x80041FF8, args, &result));
    assert(protector_ui_text_replace(&cpu, &result, "Same len"));
    assert(!strcmp((char*)cpu.ram + 0x400, "Same len"));
    // The real short startup fixture is deliberately small; no game package is
    // embedded. Wrong key, localization, content or glyph leaves it unmatched.
    result = (ProtectorUIText){.key_available = true, .language_slot = 1, .text_size = 20};
    strcpy(result.key, "Platform-GameCube-22");
    strcpy((char*)result.text, "Press \x04 to continue.");
    const ProtectorUICopyRule* rule = protector_ui_copy_match(&result);
    assert(rule && !strcmp(rule->replacement, "Jump to continue."));
    result.language_slot = 2;
    assert(!protector_ui_copy_match(&result));
    result.language_slot = 1; result.text[6] = 1;
    assert(!protector_ui_copy_match(&result));
    result.text[6] = 4; strcpy(result.key, "Story-Dialogue-22");
    assert(!protector_ui_copy_match(&result));
    result = (ProtectorUIText){.key_available = true, .language_slot = 1, .text_size = 74};
    strcpy(result.key, "Front End UI-Load Tips-7");
    strcpy((char*)result.text, "A second player can join the game at any time to play in cooperative mode!");
    rule = protector_ui_copy_match(&result);
    assert(rule && !strcmp(rule->replacement,
        "Open Pause for touch settings, the controls guide, or the game menu."));
    result.language_slot = 2;
    assert(!protector_ui_copy_match(&result));
    result.language_slot = 1; result.text[0] = 'a';
    assert(!protector_ui_copy_match(&result));
    result = (ProtectorUIText){.key_available = true, .language_slot = 1, .text_size = 5};
    strcpy(result.key, "Panel-HubScreen-17");
    strcpy((char*)result.text, "\x01 Yes");
    rule = protector_ui_copy_match(&result);
    assert(rule && !strcmp(rule->replacement, "Yes"));
    result.text[0] = 2;
    assert(!protector_ui_copy_match(&result));
    result.text[0] = 1; result.language_slot = 2;
    assert(!protector_ui_copy_match(&result));
    result = (ProtectorUIText){.key_available = true, .language_slot = 1, .text_size = 4};
    strcpy(result.key, "Panel-HubScreen-18");
    strcpy((char*)result.text, "\x02 No");
    rule = protector_ui_copy_match(&result);
    assert(rule && !strcmp(rule->replacement, "No"));
    result.text[0] = 1;
    assert(!protector_ui_copy_match(&result));
    result.text[0] = 2; strcpy(result.key, "Panel-HubScreen-20");
    assert(!protector_ui_copy_match(&result));
    for (u8 glyph = 7; glyph <= 8; ++glyph) {
        result = (ProtectorUIText){.key_available = true, .language_slot = 1, .text_size = 1};
        strcpy(result.key, glyph == 7 ? "Panel-Buttons-7" : "Panel-Buttons-8");
        result.text[0] = glyph;
        rule = protector_ui_copy_match(&result);
        assert(rule && !strcmp(rule->replacement, glyph == 7 ? "<" : ">"));
        result.text[0] = glyph == 7 ? 8 : 7;
        assert(!protector_ui_copy_match(&result));
        result.text[0] = glyph; result.language_slot = 2;
        assert(!protector_ui_copy_match(&result));
        result.language_slot = 1; result.key[0] = 'p';
        assert(!protector_ui_copy_match(&result));
        result.key[0] = 'P'; result.text_size = 2;
        assert(!protector_ui_copy_match(&result));
        result.text_size = 1; result.text[1] = 'x';
        assert(!protector_ui_copy_match(&result));
    }
    size_t rule_count = 0;
    const ProtectorUICopyRule* rules = protector_ui_copy_rules(&rule_count);
    assert(rule_count == 96);
    for (size_t index = 0; index < rule_count; ++index) {
        assert(strlen(rules[index].replacement) <= rules[index].source_size);
        for (size_t other = index + 1; other < rule_count; ++other)
            assert(strcmp(rules[index].key, rules[other].key));
    }
    free(cpu.ram);
    puts("ui_text_tests: readback, bounded replacement, source matching, and rejection nonmutation passed");
    return 0;
}
