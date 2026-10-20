#include "protector/ui_text.h"

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

static bool word_at(const CPUState* cpu, u32 address, u32* output) {
    const u8* bytes = bytes_at(cpu, address, 4);
    if (!bytes || (address & 3u)) return false;
    *output = (u32)bytes[0] << 24u | (u32)bytes[1] << 16u |
              (u32)bytes[2] << 8u | bytes[3];
    return true;
}

static bool string_at(const CPUState* cpu, u32 address, u8* output,
                      u32 capacity, u32* length) {
    if (address > UINT32_MAX - capacity) return false;
    for (u32 index = 0; index < capacity; ++index) {
        const u8* bytes = bytes_at(cpu, address + index, 1);
        if (!bytes) return false;
        output[index] = *bytes;
        if (!*bytes) { *length = index; return true; }
    }
    return false;
}

static bool key_at(const CPUState* cpu, u32 table, char* output) {
    u32 pointer = 0, length = 0;
    if (!word_at(cpu, table, &pointer) ||
        !string_at(cpu, pointer, (u8*)output, 160, &length) || length < 3) return false;
    bool digit_suffix = false;
    for (u32 index = 0; index < length; ++index) {
        const u8 value = (u8)output[index];
        if (value < 32 || value > 126) return false;
        if (value == '-') digit_suffix = index + 1 < length;
        else if (value < '0' || value > '9') digit_suffix = false;
    }
    return digit_suffix;
}

bool protector_ui_text_read(const CPUState* cpu, u32 builtin,
                           u32 parameters, ProtectorUIText* output) {
    if (!cpu || !output) return false;
    u32 offset = 0;
    switch (builtin) {
        case 0x80041FF8u: /* SetWordWrapText */
        case 0x80041FC8u: /* AddWordWrapText */
            break;
        case 0x8004485Cu: /* DisplayText */
        case 0x80044278u: /* DisplayTextLeft */
        case 0x80043CC4u: /* DisplayTextRight */
            offset = 8;
            break;
        default: return false;
    }
    ProtectorUIText result = {0};
    if (parameters > UINT32_MAX - offset ||
        !word_at(cpu, parameters + offset, &result.table) ||
        !word_at(cpu, 0x80256988u, &result.language_slot) || result.language_slot >= 10 ||
        result.table > UINT32_MAX - 72u ||
        !word_at(cpu, result.table + result.language_slot * 8u, &result.text_address)) return false;
    if (!result.text_address) {
        result.language_slot = 0;
        if (!word_at(cpu, result.table, &result.text_address)) return false;
    }
    if (!string_at(cpu, result.text_address, result.text, sizeof(result.text), &result.text_size))
        return false;
    result.key_available = key_at(cpu, result.table, result.key);
    if (!result.key_available) memset(result.key, 0, sizeof(result.key));
    *output = result;
    return true;
}

bool protector_ui_text_replace(CPUState* cpu, const ProtectorUIText* original,
                               const char* replacement) {
    if (!cpu || !original || !replacement || !original->key_available ||
        original->language_slot == 0 || original->language_slot >= 10 ||
        original->text_size >= sizeof(original->text) ||
        !memchr(original->key, 0, sizeof(original->key)) ||
        original->text[original->text_size] != 0) return false;
    const size_t size = strlen(replacement);
    if (size > original->text_size) return false;
    u32 pointer = 0, key_pointer = 0;
    if (original->table > UINT32_MAX - 72u ||
        !word_at(cpu, original->table + original->language_slot * 8u, &pointer) ||
        pointer != original->text_address ||
        !word_at(cpu, original->table, &key_pointer) || pointer == key_pointer) return false;
    char key[160];
    if (!key_at(cpu, original->table, key) || strcmp(key, original->key)) return false;
    const u8* current = bytes_at(cpu, pointer, original->text_size + 1u);
    if (!current || memcmp(current, original->text, original->text_size + 1u)) return false;
    /* Preflight covers the complete write; mem_write8 retains normal RAM
     * instrumentation and cache invalidation without allocating guest space. */
    for (size_t index = 0; index <= size; ++index)
        mem_write8(cpu, pointer + (u32)index, (u8)replacement[index]);
    return true;
}
