#ifndef PROTECTOR_UI_TEXT_H
#define PROTECTOR_UI_TEXT_H
#include "protector/cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ProtectorUIText {
    u32 table;
    u32 text_address;
    u32 language_slot;
    u32 text_size;
    /* Slot zero is the authored key; reject arbitrary strings as identities. */
    bool key_available;
    char key[160];
    u8 text[8192];
} ProtectorUIText;

/* Passive RBNEG9 diagnostic reader. No writes, guest reads/counters, faults,
 * allocations, or changes to the caller's output on rejection. */
bool protector_ui_text_read(const CPUState* cpu, u32 builtin,
                           u32 parameters, ProtectorUIText* output);

/* Enhanced-only caller: replace a just-read localized string in its existing
 * allocation. Recheck every original byte, reject growth and key-slot writes,
 * and leave guest memory/counters/output untouched on rejection. No allocation
 * or pointer redirection. The source dump is never modified. */
bool protector_ui_text_replace(CPUState* cpu, const ProtectorUIText* original,
                               const char* replacement);

#ifdef __cplusplus
}
#endif
#endif
