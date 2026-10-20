#include "protector/interaction_context.h"
#include "interaction_rules.inc"

static bool exact_prompt(const ProtectorUIText* text) {
    return text && text->key_available && text->language_slot == 1 &&
        memchr(text->key, 0, sizeof(text->key)) && !strcmp(text->key, "Platform-PC-43") &&
        text->text_size == 1 && text->text[0] == 6 && text->text[1] == 0;
}

static bool passive_word(const CPUState* cpu, u32 address, u32* output) {
    if (!cpu || (address & 3u)) return false;
    const u32 bases[] = {GC_RAM_BASE, GC_RAM_UNCACHED, WII_MEM2_BASE, WII_MEM2_UNCACHED};
    for (unsigned i=0; i<4; ++i) {
        const u32 capacity=i<2?cpu->ram_size:cpu->mem2_size;
        const u8* data=i<2?cpu->ram:cpu->mem2;
        if (!data || address<bases[i] || capacity<4 || address-bases[i]>capacity-4) continue;
        data+=address-bases[i];
        *output=(u32)data[0]<<24 | (u32)data[1]<<16 | (u32)data[2]<<8 | data[3];
        return true;
    }
    return false;
}

static u32 source_action(const CPUState* cpu, bool abstract) {
    if (!abstract) return PROTECTOR_QTE_SPECIAL;
    /* Original global-bank access: DOL 800a8414..800a8424. InitSystem keeps
     * per-player mapper selection synchronized with global control mode 0x83.
     * Five source schemes have explicit digital-input proof. Unknown values
     * retain the original glyph instead of inventing a native action. */
    u32 bank=0, scheme=0;
    if (cpu->gpr[13]<20000 || !passive_word(cpu,cpu->gpr[13]-20000,&bank) ||
        bank>UINT32_MAX-4100-0x83*4 ||
        !passive_word(cpu,bank+4100+0x83*4,&scheme)) return 0;
    const u32 actions[] = {PROTECTOR_QTE_SPECIAL, PROTECTOR_QTE_BLOCK,
        PROTECTOR_QTE_JUMP, PROTECTOR_QTE_BLOCK, PROTECTOR_QTE_TRANSFORM};
    return scheme<sizeof(actions)/sizeof(actions[0])?actions[scheme]:0;
}

bool protector_interaction_observe(ProtectorInteractionTracker* tracker,
    const CPUState* cpu, const ProtectorUIText* text, u32 target, u32 context, u32 ip) {
    if (!tracker) return false;
    tracker->pending_text=0;
    if (!cpu || !context || target!=0x8004485cu || !exact_prompt(text)) return false;
    for (u32 i=0; i<tracker->count;) {
        if (cpu->presented_frame_count<tracker->owners[i].last_seen ||
            cpu->presented_frame_count-tracker->owners[i].last_seen>60)
            tracker->owners[i]=tracker->owners[--tracker->count];
        else ++i;
    }
    for (size_t r=0; r<sizeof(interaction_rules)/sizeof(interaction_rules[0]); ++r) {
        const ProtectorInteractionRule* rule=&interaction_rules[r];
        for (unsigned a=0; a<2; ++a) {
            if (!rule->prompts[a] || ip<rule->prompts[a]) continue;
            const u32 base=ip-rule->prompts[a];
            ProtectorInteractionOwner* owner=NULL;
            for (u32 i=0; i<tracker->count; ++i)
                if (tracker->owners[i].context==context && tracker->owners[i].base==base &&
                    tracker->owners[i].rule_index==r) {owner=&tracker->owners[i];break;}
            if (!owner) {
                ProtectorScriptFlowRule source=rule->source;
                source.from_offset=rule->prompts[a];source.to_offset=source.from_offset+4;
                ProtectorScriptFlowMatch match;
                if (!protector_script_flow_match(cpu,ip,&source,&match)) continue;
                u32 slot=tracker->count;
                for (u32 i=0;i<tracker->count;++i)
                    if(tracker->owners[i].context==context){slot=i;break;}
                if(slot==4)return false;
                if(slot==tracker->count)++tracker->count;
                owner=&tracker->owners[slot];
                *owner=(ProtectorInteractionOwner){context,match.file_info_base,(u32)r,cpu->presented_frame_count};
                ++tracker->admission_count;
            }
            owner->last_seen=cpu->presented_frame_count;
            const u32 action=source_action(cpu,rule->abstract[a]);
            if(!action)return false;
            tracker->pending_context=context;tracker->pending_ip=ip;
            tracker->pending_frame=cpu->presented_frame_count;
            tracker->pending_action=action;tracker->pending_text=text->text_address;
            return true;
        }
    }
    return false;
}

bool protector_interaction_redirect_glyph(ProtectorInteractionTracker* tracker,
    CPUState* cpu, u32 seam) {
    if(!tracker)return false;
    const u32 address=tracker->pending_text;tracker->pending_text=0;
    if(!cpu || !address || seam!=0x8004488cu || cpu->gpr[3]!=address ||
        cpu->gpr[24]!=tracker->pending_context || cpu->gpr[26]!=tracker->pending_ip ||
        cpu->presented_frame_count!=tracker->pending_frame)return false;
    ProtectorUIText current;
    if(!protector_ui_text_read(cpu,0x8004485cu,cpu->gpr[4],&current) ||
        !exact_prompt(&current) || current.text_address!=address)return false;
    /* The original renderer sees the existing terminator for this one draw.
     * Every other consumer keeps its intact shared glyph; no guest allocation,
     * text-buffer mutation, input injection, IP change or skipped builtin. */
    cpu->gpr[3]=address+1;
    tracker->active_action=tracker->pending_action;
    tracker->active_frame=cpu->presented_frame_count;
    ++tracker->redirected_glyphs;
    return true;
}

u32 protector_interaction_frame(ProtectorInteractionTracker* tracker,u64 frame) {
    if(!tracker)return 0;
    /* No fade timer extends the prompt beyond its actual submitted frame. */
    return tracker->redirected_glyphs && tracker->active_frame==frame ? tracker->active_action : 0;
}

const ProtectorInteractionRule* protector_interaction_rules(size_t* count) {
    if(count)*count=sizeof(interaction_rules)/sizeof(interaction_rules[0]);
    return interaction_rules;
}
