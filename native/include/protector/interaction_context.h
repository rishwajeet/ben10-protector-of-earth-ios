#ifndef PROTECTOR_INTERACTION_CONTEXT_H
#define PROTECTOR_INTERACTION_CONTEXT_H
#include "protector/ui_context.h"
#include "protector/qte_presentation.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ProtectorInteractionRule {
    ProtectorScriptFlowRule source;
    u32 prompts[2];
    bool abstract[2];
} ProtectorInteractionRule;
typedef struct ProtectorInteractionOwner {
    u32 context, base, rule_index;
    u64 last_seen;
} ProtectorInteractionOwner;
typedef struct ProtectorInteractionTracker {
    ProtectorInteractionOwner owners[4];
    u32 count, pending_context, pending_ip, pending_text, pending_action, active_action;
    u64 pending_frame, active_frame, admission_count, redirected_glyphs;
} ProtectorInteractionTracker;
/* Admit complete source actor blocks and exact display call sites. Input,
 * script state, source glyph allocation and gameplay context remain untouched. */
bool protector_interaction_observe(ProtectorInteractionTracker* tracker,
    const CPUState* cpu, const ProtectorUIText* text, u32 target, u32 context, u32 ip);
bool protector_interaction_redirect_glyph(ProtectorInteractionTracker* tracker,
    CPUState* cpu, u32 seam);
u32 protector_interaction_frame(ProtectorInteractionTracker* tracker, u64 frame);
const ProtectorInteractionRule* protector_interaction_rules(size_t* count);
#ifdef __cplusplus
}
#endif
#endif
