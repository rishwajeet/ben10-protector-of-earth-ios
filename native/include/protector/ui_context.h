#ifndef PROTECTOR_UI_CONTEXT_H
#define PROTECTOR_UI_CONTEXT_H
#include "protector/ui_text.h"
#include "protector/script_flow.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum ProtectorUIContext {
    PROTECTOR_UI_GAMEPLAY = 0, /* Safe full-control fallback, not proof of play. */
    PROTECTOR_UI_TITLE = 1,
    PROTECTOR_UI_MAP = 2, /* Stick, Confirm/Back and source-offered extras. */
    PROTECTOR_UI_MENU = 3,
    PROTECTOR_UI_LOADING = 4, /* Visible source loading stage: Pause only. */
    PROTECTOR_UI_PROMPT = 5, /* Source has explicitly offered Confirm. */
    PROTECTOR_UI_READING = 6, /* Tutorial is visible but source input is delayed. */
    PROTECTOR_UI_INSTRUCTION = 7, /* Tutorial or enemy introduction offers Confirm. */
    PROTECTOR_UI_CINEMATIC = 8, /* Authored movie, before source permits Skip. */
    PROTECTOR_UI_CINEMATIC_READY = 9, /* Source movie's A-input check is active. */
    PROTECTOR_UI_CONTROLS_GUIDE = 10, /* Exact original Controller screen. */
    PROTECTOR_UI_DEFEAT = 11, /* Exact PlayerDeathScreen offers Continue. */
    PROTECTOR_UI_GALLERY = 12, /* Exact ConceptArt; menu priority, edge actions. */
    PROTECTOR_UI_EXTRAS_BROWSER = 13, /* Movies/character grids; compact edge controls. */
    PROTECTOR_UI_EXTRAS_OPTIONS = 14, /* Secrets/code input; same compact controls. */
    PROTECTOR_UI_EXTRAS_ROOT = 15, /* Extras list; compact controls clear long selections. */
    PROTECTOR_UI_COMBO_LIST = 16, /* Exact original move list; horizontal browse and Back. */
    PROTECTOR_UI_EXTRAS_VIEWER = 17, /* Character full view; original analogue camera and Back. */
    PROTECTOR_UI_UPGRADE_MENU = 18, /* Exact original Upgrade Menu; not a move-list alias. */
    PROTECTOR_UI_UPGRADE_READY = 19, /* Same menu has actually offered Unlock Move this frame. */
    PROTECTOR_UI_CONTINUE_DIALOG = 20, /* Exact source one-action dialog or results. */
    PROTECTOR_UI_CHOICE_DIALOG = 21, /* Exact source two/three-choice dialog; no Back. */
    PROTECTOR_UI_FATAL_DIALOG = 22, /* Exact fatal storage text; native stop, not guest Confirm. */
} ProtectorUIContext;

enum { PROTECTOR_UI_MAP_REPLAY = 1, PROTECTOR_UI_MAP_CHALLENGE = 2 };
typedef struct ProtectorUIContextSnapshot {
    ProtectorUIContext context;
    u32 map_actions;
} ProtectorUIContextSnapshot;

typedef struct ProtectorUIContextOwner {
    u32 context, begin, end;
    u64 last_frame;
    ProtectorUIContext kind;
    u32 rule_index;
    /* An optional source-verified departure window inside a long-lived block. */
    u32 leave_begin, leave_end;
    u64 map_actions_frame;
    u32 map_actions;
    /* Same admitted InitSystem has passed its authored ready acceptance.
     * Retain this passive owner in gameplay so later no-tip loads can end. */
    bool loading_confirmed;
    /* Only exact English move-notation records observed in this same frame.
     * A conflicting family fails closed rather than relabeling source input. */
    u64 combo_glyph_frame;
    u32 combo_glyph_families;
} ProtectorUIContextOwner;
typedef struct ProtectorUIContextTracker {
    ProtectorUIContextOwner owners[4];
    u32 count;
    /* Worker-only admission receipt; cache hits do not increment this. */
    u64 admission_count;
    const char* last_admission;
} ProtectorUIContextTracker;

typedef struct ProtectorUIContextAdmission {
    u32 rule_index, return_offset;
    const char* key;
    ProtectorUIContext kind;
    u32 leave_begin, leave_end;
} ProtectorUIContextAdmission;

typedef struct ProtectorUIContextTransition {
    u32 rule_index, offset;
    ProtectorUIContext kind;
} ProtectorUIContextTransition;

typedef struct ProtectorUIContextDispatchAdmission {
    u32 rule_index, offset, instruction;
    ProtectorUIContext kind;
} ProtectorUIContextDispatchAdmission;

/* Worker-only passive source matching and VM liveness. No guest mutation.
 * Diagnostic source runs may omit the observer; the product is Enhanced-only.
 * The publisher is the only shared state. */
bool protector_ui_context_observe(ProtectorUIContextTracker* tracker,
    const CPUState* cpu, const ProtectorUIText* text, u32 context, u32 ip);
/* Rare exact VM markers can establish ownership without a prior text draw.
 * The whole relocated script is verified before any new owner is installed. */
bool protector_ui_context_admit_dispatch(ProtectorUIContextTracker* tracker,
    const CPUState* cpu, u32 context, u32 ip, u32 instruction);
void protector_ui_context_dispatch(ProtectorUIContextTracker* tracker,
    u32 context, u32 ip, u32 instruction, u64 frame);
ProtectorUIContext protector_ui_context_frame(ProtectorUIContextTracker* tracker, u64 frame);
u32 protector_ui_context_map_actions(const ProtectorUIContextTracker* tracker, u64 frame);
u32 protector_ui_context_combo_scheme(const ProtectorUIContextTracker* tracker, u64 frame);
u32 protector_ui_context_upgrade_scheme(const ProtectorUIContextTracker* tracker, u64 frame);
/* Semantic action IDs match the shared authored glyphs: Attack, Heavy, Jump,
 * Special. Zero means no verified mapping. No guest bytes are modified. */
u32 protector_combo_action_for_glyph(u32 scheme, u8 glyph);
const char* protector_combo_action_sequence(u32 ordinal);
/* Publish context and conditional map actions atomically as one UI snapshot. */
void protector_ui_context_publish_snapshot(ProtectorUIContext context, u32 map_actions);
ProtectorUIContextSnapshot protector_ui_context_snapshot(void);
/* Per-view cold-start latch: unknown boot frames are not gameplay. Once a
 * source screen is observed, preserve the ordinary full-control fallback. */
ProtectorUIContextSnapshot protector_ui_context_startup_snapshot(
    ProtectorUIContextSnapshot snapshot, bool* observed_source_screen);
void protector_ui_context_publish(ProtectorUIContext context);
ProtectorUIContext protector_ui_context_current(void);
const char* protector_ui_context_name(ProtectorUIContext context);
/* Read-only metadata for source verification and relocated-fixture tests. */
const ProtectorScriptFlowRule* protector_ui_context_rules(size_t* count);
const ProtectorUIContextAdmission* protector_ui_context_admissions(size_t* count);
const ProtectorUIContextTransition* protector_ui_context_transitions(size_t* count);
const ProtectorUIContextDispatchAdmission* protector_ui_context_dispatch_admissions(size_t* count);

#ifdef __cplusplus
}
#endif
#endif
