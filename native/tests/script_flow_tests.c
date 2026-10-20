#include "protector/script_flow.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static void put(u8* bytes, u32 value) {
    bytes[0] = value >> 24; bytes[1] = value >> 16;
    bytes[2] = value >> 8; bytes[3] = value;
}

static u64 fingerprint(const u8* bytes, size_t size) {
    u64 hash = UINT64_C(0xcbf29ce484222325);
    for (size_t index = 0; index < size; ++index)
        hash = (hash ^ bytes[index]) * UINT64_C(0x100000001b3);
    return hash;
}

int main(int argc, char** argv) {
    CPUState cpu = {0};
    cpu.ram_size = 4096;
    cpu.ram = calloc(1, cpu.ram_size);
    assert(cpu.ram);
    const u32 base = GC_RAM_BASE + 256;
    strcpy((char*)cpu.ram + 256, "SyntheticFlow");
    u8* code = cpu.ram + 256 + 32;
    put(code, 0x12345678); put(code + 4, 12); put(code + 8, 0xabcdef01);
    const u32 pointer_offsets[] = {36};
    ProtectorScriptFlowRule rule = {"SyntheticFlow", 0, 64, 32, 12, 32, 40,
        pointer_offsets, 1, fingerprint(code, 12)};
    put(code + 4, base + 12);
    cpu.memory_read_count = 31; cpu.memory_write_count = 47; cpu.timebase = 101;
    CPUState before = cpu;
    ProtectorScriptFlowMatch match = {0};
    assert(protector_script_flow_match(&cpu, base + 32, &rule, &match));
    assert(match.destination == base + 40 && match.file_info_base == base);
    assert(!memcmp(&before, &cpu, sizeof(cpu)));
    assert(protector_script_flow_match(&cpu, GC_RAM_UNCACHED + 256 + 32,
        &(ProtectorScriptFlowRule){"SyntheticFlow", 0, 64, 32, 12, 32, 40,
            NULL, 0, fingerprint(code, 12)}, &match));
    match = (ProtectorScriptFlowMatch){0};
    const ProtectorScriptFlowMatch untouched = match;
    code[0] ^= 1;
    assert(!protector_script_flow_match(&cpu, base + 32, &rule, &match));
    code[0] ^= 1;
    put(code + 4, base + 64);
    assert(!protector_script_flow_match(&cpu, base + 32, &rule, &match));
    put(code + 4, base + 12);
    assert(!protector_script_flow_match(&cpu, base + 33, &rule, &match));
    assert(!protector_script_flow_match(&cpu, 4, &rule, &match));
    assert(!protector_script_flow_match(&cpu, 0xfffffffc, &rule, &match));
    assert(!protector_script_flow_match(NULL, base + 32, &rule, &match));
    assert(!protector_script_flow_match(&cpu, base + 32, NULL, &match));
    assert(!protector_script_flow_match(&cpu, base + 32, &rule, NULL));
    ProtectorScriptFlowRule invalid = rule;
    invalid.to_offset = invalid.from_offset;
    assert(!protector_script_flow_match(&cpu, base + 32, &invalid, &match));
    invalid = rule; invalid.pointer_count = 4;
    assert(!protector_script_flow_match(&cpu, base + 32, &invalid, &match));
    invalid = rule; invalid.code_size = 4100;
    assert(!protector_script_flow_match(&cpu, base + 32, &invalid, &match));
    invalid = rule; invalid.pointer_offsets = NULL;
    assert(!protector_script_flow_match(&cpu, base + 32, &invalid, &match));
    invalid = rule; invalid.name = "UnrelatedFlow";
    assert(!protector_script_flow_match(&cpu, base + 32, &invalid, &match));
    assert(!protector_startup_flow_match(&cpu, base + 32, &match));
    assert(!memcmp(&untouched, &match, sizeof(match)));
    assert(!memcmp(&before, &cpu, sizeof(cpu)));
    free(cpu.ram);

    /* Complete character blocks slightly exceed 64 KiB. Keep a finite
     * 128 KiB ceiling, including an explicit rejection above that bound. */
    CPUState large = {0};
    large.mem2_size = 131072 + 64;
    large.mem2 = calloc(1, large.mem2_size);
    assert(large.mem2);
    strcpy((char*)large.mem2, "SyntheticLarge");
    ProtectorScriptFlowRule large_rule = {"SyntheticLarge", 0, large.mem2_size,
        32, 131072, 32, 36, NULL, 0, fingerprint(large.mem2 + 32, 131072)};
    assert(protector_script_flow_match(&large, WII_MEM2_BASE + 32, &large_rule, &match));
    large_rule.code_size += 4;
    large_rule.normalized_hash = fingerprint(large.mem2 + 32, large_rule.code_size);
    assert(!protector_script_flow_match(&large, WII_MEM2_BASE + 32, &large_rule, &match));
    free(large.mem2);

    /* Optional external, source-derived fixture. Never checked into Git and
     * never represented as actual translated execution. */
    if (argc == 3) {
        size_t count = 0;
        const ProtectorScriptFlowRule* rules = protector_startup_flow_rules(&count);
        const unsigned long index = strtoul(argv[2], NULL, 10);
        assert(index < count);
        const ProtectorScriptFlowRule* selected = &rules[index];
        cpu = (CPUState){0};
        cpu.mem2_size = selected->file_info_size + 4096;
        cpu.mem2 = calloc(1, cpu.mem2_size);
        assert(cpu.mem2);
        FILE* stream = fopen(argv[1], "rb");
        assert(stream);
        assert(fread(cpu.mem2 + 4096, 1, selected->file_info_size, stream) == selected->file_info_size);
        assert(fgetc(stream) == EOF);
        fclose(stream);
        before = cpu;
        assert(protector_startup_flow_match(&cpu,
            WII_MEM2_BASE + 4096 + selected->from_offset, &match));
        assert(match.rule == selected);
        assert(match.destination == WII_MEM2_BASE + 4096 + selected->to_offset);
        assert(!memcmp(&cpu, &before, sizeof(cpu)));
        cpu.mem2[4096 + selected->to_offset] ^= 1;
        assert(!protector_startup_flow_match(&cpu,
            WII_MEM2_BASE + 4096 + selected->from_offset, &match));
        free(cpu.mem2);
        printf("script_flow_tests: external admitted source rule %lu and mutation rejection passed\n", index);
    } else assert(argc == 1);
    puts("script_flow_tests: synthetic matching and nonmutation/rejection passed");
    return 0;
}
