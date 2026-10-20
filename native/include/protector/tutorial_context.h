#ifndef PROTECTOR_TUTORIAL_CONTEXT_H
#define PROTECTOR_TUTORIAL_CONTEXT_H
#include "protector/ui_context.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct ProtectorTutorialRule {
    ProtectorScriptFlowRule source;
    u32 reading[3], ready[2], depart;
    const char* package;
} ProtectorTutorialRule;
typedef struct ProtectorTutorialOwner {
    u32 context, base, rule_index;
    u64 last_frame;
    ProtectorUIContext kind; /* GAMEPLAY means dismissed, retained through fade. */
} ProtectorTutorialOwner;
typedef struct ProtectorTutorialTracker {
    ProtectorTutorialOwner owners[4];
    u32 count;
    u64 admission_count, redirected_glyphs;
    u32 pending_context, pending_ip, pending_text;
    u64 pending_frame;
} ProtectorTutorialTracker;

/* Passive source admission. A returned true value permits one later empty
 * glyph draw at the exact DisplayText seam, never a shared text-buffer edit. */
bool protector_tutorial_observe(ProtectorTutorialTracker* tracker, const CPUState* cpu,
    const ProtectorUIText* text, u32 target, u32 context, u32 ip);
void protector_tutorial_dispatch(ProtectorTutorialTracker* tracker,
    u32 context, u32 ip, u32 instruction, u64 frame);
ProtectorUIContext protector_tutorial_frame(ProtectorTutorialTracker* tracker, u64 frame);
bool protector_tutorial_redirect_glyph(ProtectorTutorialTracker* tracker, CPUState* cpu, u32 seam);
const ProtectorTutorialRule* protector_tutorial_rules(size_t* count);
#ifdef __cplusplus
}
#endif
#endif
