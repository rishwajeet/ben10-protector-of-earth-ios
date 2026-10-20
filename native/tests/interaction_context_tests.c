#include "protector/interaction_context.h"
#include "protector/live_gx.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static void lifecycle(void) {
    ProtectorInteractionTracker tracker={0};
    assert(!protector_interaction_frame(&tracker,0));
    tracker.active_frame=8;tracker.active_action=PROTECTOR_QTE_SPECIAL;tracker.redirected_glyphs=1;
    assert(protector_interaction_frame(&tracker,8)==PROTECTOR_QTE_SPECIAL);
    assert(!protector_interaction_frame(&tracker,7));
    assert(!protector_interaction_frame(&tracker,9));
    assert(!strcmp(protector_qte_instruction(PROTECTOR_QTE_SPECIAL,0,0),"Use Special"));
    assert(!strcmp(protector_qte_instruction(PROTECTOR_QTE_SPECIAL,1,0),"Special: D-pad Down"));
    assert(!strcmp(protector_qte_instruction(PROTECTOR_QTE_BLOCK,1,0),"Block: left face button"));
    assert(!strcmp(protector_qte_instruction(PROTECTOR_QTE_JUMP,0,1),"Jump: Shift"));
    assert(!strcmp(protector_qte_instruction(PROTECTOR_QTE_TRANSFORM,0,0),"Use Transform"));
    assert(!strcmp(protector_qte_instruction(PROTECTOR_QTE_SPECIAL|PROTECTOR_QTE_POINTER_TARGET,0,0),"Drag onto the target"));
    protector_live_gx_set_interaction_frame((ProtectorLiveInteractionFrame){8,PROTECTOR_QTE_SPECIAL});
    assert(protector_live_gx_interaction_frame().prompts==PROTECTOR_QTE_SPECIAL);
    protector_live_gx_set_sink(NULL,NULL);
    assert(!protector_live_gx_interaction_frame().prompts);
}

static void source_checks(const char* folder) {
    size_t count=0,anchors=0;
    const ProtectorInteractionRule* rules=protector_interaction_rules(&count);
    assert(count==18);
    for(size_t r=0;r<count;++r) {
        const ProtectorInteractionRule* rule=&rules[r];
        char path[2048];snprintf(path,sizeof(path),"%s/99_%u.gcs.bin",folder,93+(unsigned)(r/6));
        FILE* file=fopen(path,"rb");assert(file);
        CPUState cpu={0};cpu.mem2_size=rule->source.file_info_size;
        cpu.mem2=malloc(cpu.mem2_size);cpu.ram_size=0x400000;cpu.ram=calloc(1,cpu.ram_size);
        assert(cpu.mem2 && cpu.ram);
        assert(fread(cpu.mem2,1,cpu.mem2_size,file)==cpu.mem2_size);fclose(file);
        cpu.gpr[13]=0x80330000;mem_write32(&cpu,cpu.gpr[13]-20000,0x80060000);
        cpu.presented_frame_count=7;
        for(unsigned a=0;a<2;++a) {
            if(!rule->prompts[a])continue;
            ++anchors;
            const u32 ip=0x90000000+rule->prompts[a],context=0x80001000;
            ProtectorUIText text={.key_available=true,.language_slot=1,.text_size=1,
                .text_address=0x80004000,.text={6,0}};
            strcpy(text.key,"Platform-PC-43");
            for(unsigned scheme=0;scheme<6;++scheme) {
                mem_write32(&cpu,0x80060000+4100+0x83*4,scheme);
                ProtectorInteractionTracker tracker={0};
                const CPUState before=cpu;
                const bool valid=!rule->abstract[a] || scheme<5;
                assert(protector_interaction_observe(&tracker,&cpu,&text,0x8004485c,context,ip)==valid);
                assert(!memcmp(&cpu,&before,sizeof(cpu)));
                assert(tracker.admission_count==1);
                if(!valid){assert(!tracker.pending_text);continue;}
                const u32 actions[]={PROTECTOR_QTE_SPECIAL,PROTECTOR_QTE_BLOCK,PROTECTOR_QTE_JUMP,
                    PROTECTOR_QTE_BLOCK,PROTECTOR_QTE_TRANSFORM};
                assert(tracker.pending_action==(rule->abstract[a]?actions[scheme]:PROTECTOR_QTE_SPECIAL));
                assert(!protector_interaction_frame(&tracker,7)); /* no successful draw yet */
                assert(protector_interaction_observe(&tracker,&cpu,&text,0x8004485c,context,ip));
                assert(tracker.admission_count==1);
                const ProtectorInteractionTracker pending=tracker;
                memcpy(cpu.ram+0x3000,"Platform-PC-43",15);
                mem_write32(&cpu,0x80002008,0x80005000);
                mem_write32(&cpu,0x80005000,0x80003000);
                mem_write32(&cpu,0x80005008,text.text_address);
                mem_write32(&cpu,0x80256988,1);mem_write8(&cpu,text.text_address,6);
                cpu.gpr[3]=text.text_address;cpu.gpr[4]=0x80002000;cpu.gpr[24]=context;cpu.gpr[26]=ip;
                const CPUState draw_cpu=cpu;
                assert(protector_interaction_redirect_glyph(&tracker,&cpu,0x8004488c));
                assert(cpu.gpr[3]==text.text_address+1 && cpu.ram[0x4000]==6 && !cpu.ram[0x4001]);
                assert(protector_interaction_frame(&tracker,7)==pending.pending_action);
                assert(!protector_interaction_frame(&tracker,8));
                assert(!protector_interaction_redirect_glyph(&tracker,&cpu,0x8004488c));
                cpu.gpr[3]=draw_cpu.gpr[3];assert(!memcmp(&cpu,&draw_cpu,sizeof(cpu)));
                for(unsigned bad=0;bad<7;++bad) {
                    tracker=pending;cpu=draw_cpu;
                    if(bad==1)++cpu.gpr[3];
                    if(bad==2)cpu.gpr[24]+=4;
                    if(bad==3)cpu.gpr[26]+=4;
                    if(bad==4)++cpu.presented_frame_count;
                    if(bad==5)cpu.ram[0x4000]=7;
                    if(bad==6)cpu.ram[0x3000]='p';
                    assert(!protector_interaction_redirect_glyph(&tracker,&cpu,bad==0?0x80044890:0x8004488c));
                    assert(!tracker.pending_text && !tracker.redirected_glyphs);
                    cpu.ram[0x4000]=6;cpu.ram[0x3000]='P';
                }
                cpu=before;
            }
            mem_write32(&cpu,0x80060000+4100+0x83*4,0);
            ProtectorInteractionTracker tracker={0};
            assert(!protector_interaction_observe(&tracker,&cpu,&text,0x8004485c,context,ip+4));
            assert(!protector_interaction_observe(&tracker,&cpu,&text,0x80044278,context,ip));
            cpu.mem2[rule->source.code_offset]^=1;
            assert(!protector_interaction_observe(&tracker,&cpu,&text,0x8004485c,context,ip));
            cpu.mem2[rule->source.code_offset]^=1;
            text.text[0]=1;
            assert(!protector_interaction_observe(&tracker,&cpu,&text,0x8004485c,context,ip));
            text.text[0]=6;text.language_slot=0;
            assert(!protector_interaction_observe(&tracker,&cpu,&text,0x8004485c,context,ip));
        }
        free(cpu.mem2);free(cpu.ram);
    }
    assert(anchors==24);
    puts("interaction_context_tests: 18 original actor blocks, 24 prompts, five source modes, exact one-shot draw, frame expiry and rejection checks passed");
}

int main(int argc,char**argv) {
    lifecycle();
    if(argc==2)source_checks(argv[1]);
    else puts("interaction_context_tests: frame lifetime, cue vocabulary and sink reset passed");
    return 0;
}
