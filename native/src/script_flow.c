#include "protector/script_flow.h"

/* Full script-block fingerprints admit the relocated RBNEG9 source. Builtin
 * references are hashed as their resolved DOL addresses; only these declared
 * file-info pointers are normalized back to offsets. Unknown revisions fail
 * closed. tools/verify_native_startup.py derives and checks this metadata. */
static const u32 strap_pointers[] = {
    0x18c, 0x1a4, 0x1c8, 0x1e0, 0x1f4, 0x208, 0x21c, 0x248,
    0x260, 0x274, 0x288, 0x29c, 0x2c4, 0x2dc, 0x2f0, 0x304,
    0x318, 0x344, 0x35c, 0x370, 0x384, 0x398, 0x3c4, 0x3dc,
    0x3f0, 0x404, 0x418, 0x438, 0x450, 0x464, 0x478, 0x48c,
    0x4a0, 0x86c,
};
static const u32 nunchuk_pointers[] = {0x440, 0x458, 0x528, 0x558, 0x5b8};
static const u32 hardware_warning_pointers[] = {
    0x8fee0, 0x9050c, 0x90560, 0x905b0, 0x905dc,
    0x90630, 0x9065c, 0x906a4, 0x906f0,
};
static const ProtectorScriptFlowRule startup_rules[] = {
    {"WiiStrapReminderScreen", 0, 0x1e1dc0, 0xe0, 0x7cc, 0x180, 0x85c,
        strap_pointers, 34, UINT64_C(0x84eaaa57cc4d24a8)},
    {"WiiNunchuckNeededScreen", 6, 0xae0, 0x3dc, 0x1f4, 0x434, 0x5a8,
        nunchuk_pointers, 5, UINT64_C(0x0dacd1174d3b0761)},
    /* This is the script-owned Wii accessory/battery warning presenter, NOT
     * the executable's gameplay controller manager. Take its own Remove
     * branch before any panel, exclusivity, sound-pause or warning state.
     * Native controller handoff/pause remains owned by the Apple shell. */
    {"WiiControllerManager", 0x7cf07, 0x116420, 0x8fdf8, 0x984,
        0x90290, 0x902a4, hardware_warning_pointers, 9,
        UINT64_C(0x491c332094c1e44b)},
};

static const u8* bytes_at(const CPUState* cpu, u32 address, u32 size) {
    if (!cpu || !size) return NULL;
    const u32 bases[] = {GC_RAM_BASE, GC_RAM_UNCACHED, WII_MEM2_BASE, WII_MEM2_UNCACHED};
    for (u32 index = 0; index < 4; ++index) {
        const u32 capacity = index < 2 ? cpu->ram_size : cpu->mem2_size;
        const u8* bytes = index < 2 ? cpu->ram : cpu->mem2;
        if (bytes && address >= bases[index]) {
            const u32 offset = address - bases[index];
            if (offset < capacity && size <= capacity - offset) return bytes + offset;
        }
    }
    return NULL;
}

bool protector_script_flow_match(const CPUState* cpu, u32 ip,
    const ProtectorScriptFlowRule* rule, ProtectorScriptFlowMatch* output) {
    if (!cpu || !rule || !output || !rule->name || (ip & 3u) ||
        ip < rule->from_offset || !rule->code_size || rule->code_size > 131072 ||
        (rule->code_offset & 3u) || (rule->code_size & 3u) ||
        rule->code_offset > rule->file_info_size ||
        rule->code_size > rule->file_info_size - rule->code_offset ||
        rule->from_offset < rule->code_offset ||
        rule->from_offset >= rule->code_offset + rule->code_size ||
        rule->to_offset <= rule->from_offset || (rule->to_offset & 3u) ||
        rule->to_offset >= rule->code_offset + rule->code_size ||
        rule->pointer_count > rule->code_size / 4u ||
        (rule->pointer_count && !rule->pointer_offsets)) return false;
    const u32 base = ip - rule->from_offset;
    if (base > UINT32_MAX - rule->file_info_size) return false;
    const size_t name_size = strlen(rule->name) + 1;
    if (name_size > 128 || rule->name_offset >= rule->file_info_size ||
        name_size > rule->file_info_size - rule->name_offset) return false;
    const u8* name = bytes_at(cpu, base + rule->name_offset, (u32)name_size);
    if (!name || memcmp(name, rule->name, name_size)) return false;
    const u8* code = bytes_at(cpu, base + rule->code_offset, rule->code_size);
    if (!code) return false;
    u64 hash = UINT64_C(0xcbf29ce484222325);
    u32 pointer_index = 0;
    for (u32 offset = 0; offset < rule->code_size; offset += 4) {
        u32 word = (u32)code[offset] << 24u | (u32)code[offset + 1] << 16u |
            (u32)code[offset + 2] << 8u | code[offset + 3];
        if (pointer_index < rule->pointer_count &&
            rule->pointer_offsets[pointer_index] == rule->code_offset + offset) {
            if (word < base || word - base >= rule->file_info_size) return false;
            word -= base;
            pointer_index++;
        }
        for (u32 byte = 0; byte < 4; ++byte) {
            hash ^= (word >> (24u - byte * 8u)) & 0xffu;
            hash *= UINT64_C(0x100000001b3);
        }
    }
    if (pointer_index != rule->pointer_count || hash != rule->normalized_hash) return false;
    *output = (ProtectorScriptFlowMatch){rule, base, base + rule->to_offset};
    return true;
}

const ProtectorScriptFlowRule* protector_startup_flow_rules(size_t* count) {
    if (count) *count = sizeof(startup_rules) / sizeof(startup_rules[0]);
    return startup_rules;
}

bool protector_startup_flow_match(const CPUState* cpu, u32 ip,
    ProtectorScriptFlowMatch* output) {
    for (size_t index = 0; index < sizeof(startup_rules) / sizeof(startup_rules[0]); ++index)
        if (protector_script_flow_match(cpu, ip, &startup_rules[index], output)) return true;
    return false;
}
