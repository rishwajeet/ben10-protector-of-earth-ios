#ifndef PROTECTOR_UI_COPY_H
#define PROTECTOR_UI_COPY_H
#include "protector/ui_text.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ProtectorUICopyRule {
    const char* key;
    u32 source_size;
    u64 source_fnv1a64;
    const char* replacement;
} ProtectorUICopyRule;

/* Only reviewed English records in the hash-admitted RBNEG9 revision. This
 * fingerprint is a source-revision check, not a cryptographic trust boundary.
 * No substring, platform-prefix, control-byte or dialogue-wide matching. */
const ProtectorUICopyRule* protector_ui_copy_rules(size_t* count);
const ProtectorUICopyRule* protector_ui_copy_match(const ProtectorUIText* text);

#ifdef __cplusplus
}
#endif
#endif
