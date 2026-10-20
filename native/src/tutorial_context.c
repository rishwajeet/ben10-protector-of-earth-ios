#include "protector/tutorial_context.h"
#include "tutorial_rules.inc"

static bool exact_prompt(const ProtectorUIText* text) {
    return text && text->key_available && text->language_slot > 0 && text->language_slot < 10 &&
        !strcmp(text->key, "panel-options-15") && text->text_size == 1 &&
        text->text[0] == 1 && text->text[1] == 0;
}

static ProtectorUIContext stage(const ProtectorTutorialRule* rule, u32 offset,
    u32 target, const ProtectorUIText* text) {
    for (unsigned i = 0; i < 3; ++i) {
        const u32 expected = i == 0 && rule->reading[1] ? 0x80044278u :
            i == 2 ? 0x80043CC4u : 0x8004485cu;
        if (rule->reading[i] && offset == rule->reading[i] && target == expected)
            return PROTECTOR_UI_READING;
    }
    if (target == 0x8004485cu && exact_prompt(text))
        for (unsigned i = 0; i < 2; ++i)
            if (offset == rule->ready[i]) return PROTECTOR_UI_INSTRUCTION;
    return PROTECTOR_UI_GAMEPLAY;
}

bool protector_tutorial_observe(ProtectorTutorialTracker* tracker, const CPUState* cpu,
    const ProtectorUIText* text, u32 target, u32 context, u32 ip) {
    if (!tracker) return false;
    tracker->pending_text = 0;
    if (!cpu || !text || !context || !text->key_available ||
        !memchr(text->key, 0, sizeof(text->key))) return false;
    for (size_t r = 0; r < sizeof(tutorial_rules) / sizeof(tutorial_rules[0]); ++r) {
        const ProtectorTutorialRule* rule = &tutorial_rules[r];
        ProtectorTutorialOwner* owner = NULL;
        for (u32 i = 0; i < tracker->count; ++i)
            if (tracker->owners[i].context == context && tracker->owners[i].rule_index == r) {
                owner = &tracker->owners[i]; break;
            }
        if (owner) {
            if (ip < owner->base) continue;
            const ProtectorUIContext kind = stage(rule, ip - owner->base, target, text);
            if (kind == PROTECTOR_UI_GAMEPLAY) continue;
            owner->last_frame = cpu->presented_frame_count;
            if (owner->kind == PROTECTOR_UI_GAMEPLAY) return false; /* source fade-out */
            if (kind == PROTECTOR_UI_INSTRUCTION) owner->kind = kind;
        } else {
            const u32* offsets = exact_prompt(text) ? rule->ready : rule->reading;
            const unsigned count = exact_prompt(text) ? 2 : 3;
            for (unsigned a = 0; a < count; ++a) {
                if (!offsets[a]) continue;
                const ProtectorUIContext kind = stage(rule, offsets[a], target, text);
                if (kind == PROTECTOR_UI_GAMEPLAY) continue;
                ProtectorScriptFlowRule source = rule->source;
                source.from_offset = offsets[a]; source.to_offset = offsets[a] + 4;
                ProtectorScriptFlowMatch match;
                if (!protector_script_flow_match(cpu, ip, &source, &match)) continue;
                u32 slot = tracker->count;
                for (u32 i = 0; i < tracker->count; ++i)
                    if (tracker->owners[i].context == context) { slot = i; break; }
                if (slot == 4) return false;
                if (slot == tracker->count) ++tracker->count;
                owner = &tracker->owners[slot];
                *owner = (ProtectorTutorialOwner){context, match.file_info_base, (u32)r,
                    cpu->presented_frame_count, kind};
                ++tracker->admission_count;
                break;
            }
            if (!owner) continue;
        }
        if (stage(rule, ip - owner->base, target, text) == PROTECTOR_UI_INSTRUCTION) {
            tracker->pending_context = context;
            tracker->pending_ip = ip;
            tracker->pending_frame = cpu->presented_frame_count;
            tracker->pending_text = text->text_address;
            return true;
        }
        return false;
    }
    return false;
}

void protector_tutorial_dispatch(ProtectorTutorialTracker* tracker,
    u32 context, u32 ip, u32 instruction, u64 frame) {
    if (!tracker) return;
    for (u32 i = 0; i < tracker->count; ++i) {
        ProtectorTutorialOwner* owner = &tracker->owners[i];
        if (owner->context != context) continue;
        const ProtectorTutorialRule* rule = &tutorial_rules[owner->rule_index];
        const u32 start = owner->base + rule->source.code_offset;
        if (ip < start || ip >= start + rule->source.code_size || (instruction >> 24) == 0x89) {
            tracker->owners[i] = tracker->owners[--tracker->count];
            return;
        }
        owner->last_frame = frame;
        if (ip >= owner->base + rule->depart) owner->kind = PROTECTOR_UI_GAMEPLAY;
        return;
    }
}

ProtectorUIContext protector_tutorial_frame(ProtectorTutorialTracker* tracker, u64 frame) {
    ProtectorUIContext result = PROTECTOR_UI_GAMEPLAY;
    if (!tracker) return result;
    for (u32 i = 0; i < tracker->count;) {
        ProtectorTutorialOwner* owner = &tracker->owners[i];
        if (frame < owner->last_frame || frame - owner->last_frame > 2) {
            tracker->owners[i] = tracker->owners[--tracker->count]; continue;
        }
        if (owner->kind > result) result = owner->kind;
        ++i;
    }
    return result;
}

bool protector_tutorial_redirect_glyph(ProtectorTutorialTracker* tracker, CPUState* cpu, u32 seam) {
    if (!tracker) return false;
    const u32 address = tracker->pending_text;
    tracker->pending_text = 0; /* one-shot even on a rejected seam */
    /* Internal hooks precede the generated label's pc assignment. The host
     * supplies its exact call site; cpu->pc can still name the prior branch. */
    if (!cpu || !address || seam != 0x8004488cu || cpu->gpr[3] != address ||
        cpu->gpr[24] != tracker->pending_context || cpu->gpr[26] != tracker->pending_ip ||
        cpu->presented_frame_count != tracker->pending_frame) return false;
    ProtectorUIText current;
    if (!protector_ui_text_read(cpu, 0x8004485cu, cpu->gpr[4], &current) ||
        !exact_prompt(&current) || current.text_address != address) return false;
    /* Only a volatile renderer argument changes. The source's one-byte glyph
     * remains intact for every other caller; the original builtin still draws
     * an empty string and runs its normal text-state reset and return. */
    cpu->gpr[3] = address + 1;
    ++tracker->redirected_glyphs;
    return true;
}

const ProtectorTutorialRule* protector_tutorial_rules(size_t* count) {
    if (count) *count = sizeof(tutorial_rules) / sizeof(tutorial_rules[0]);
    return tutorial_rules;
}
