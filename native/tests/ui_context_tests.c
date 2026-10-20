#include "protector/ui_context.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static void tracker_checks(void) {
    ProtectorUIContextTracker tracker = {0};
    assert(protector_ui_context_frame(&tracker, 0) == PROTECTOR_UI_GAMEPLAY);
    tracker.owners[0] = (ProtectorUIContextOwner){0x1000, 0x2000, 0x3000, 10, PROTECTOR_UI_TITLE, 0};
    tracker.count = 1;
    protector_ui_context_dispatch(&tracker, 0x9999, 0, 0, 11);
    assert(tracker.owners[0].last_frame == 10);
    /* No text is necessary while the source script runs (blinking title). */
    for (unsigned frame = 11; frame < 300; ++frame) {
        protector_ui_context_dispatch(&tracker, 0x1000, 0x2020, 0x81000000, frame);
        assert(protector_ui_context_frame(&tracker, frame) == PROTECTOR_UI_TITLE);
    }
    /* Frozen guest time retains context no matter how often the host reads. */
    for (unsigned i = 0; i < 100; ++i)
        assert(protector_ui_context_frame(&tracker, 299) == PROTECTOR_UI_TITLE);
    assert(protector_ui_context_frame(&tracker, 301) == PROTECTOR_UI_TITLE);
    assert(protector_ui_context_frame(&tracker, 302) == PROTECTOR_UI_GAMEPLAY);
    assert(tracker.count == 0);
    tracker.owners[0] = (ProtectorUIContextOwner){0x1000, 0x2000, 0x3000, 20, PROTECTOR_UI_TITLE, 0};
    tracker.owners[1] = (ProtectorUIContextOwner){0x4000, 0x5000, 0x6000, 20, PROTECTOR_UI_MENU, 1};
    tracker.count = 2;
    assert(protector_ui_context_frame(&tracker, 20) == PROTECTOR_UI_MENU);
    protector_ui_context_dispatch(&tracker, 0x4000, 0x5100, 0x89ffffff, 20);
    assert(protector_ui_context_frame(&tracker, 20) == PROTECTOR_UI_TITLE);
    protector_ui_context_dispatch(&tracker, 0x1000, 0x3000, 0, 20);
    assert(protector_ui_context_frame(&tracker, 20) == PROTECTOR_UI_GAMEPLAY);
    tracker.count = 1;
    tracker.owners[0] = (ProtectorUIContextOwner){0x1000, 0x2000, 0x3000, 20, PROTECTOR_UI_MENU, 1};
    assert(protector_ui_context_frame(&tracker, 19) == PROTECTOR_UI_GAMEPLAY);
    protector_ui_context_publish(PROTECTOR_UI_MENU);
    assert(protector_ui_context_current() == PROTECTOR_UI_MENU);
    assert(!strcmp(protector_ui_context_name(PROTECTOR_UI_MENU), "menu"));
    protector_ui_context_publish_snapshot(PROTECTOR_UI_GALLERY, 3);
    assert(protector_ui_context_current() == PROTECTOR_UI_GALLERY);
    assert(protector_ui_context_snapshot().map_actions == 0);
    assert(!strcmp(protector_ui_context_name(PROTECTOR_UI_GALLERY), "gallery"));
    protector_ui_context_publish_snapshot(PROTECTOR_UI_EXTRAS_BROWSER, 3);
    assert(protector_ui_context_current() == PROTECTOR_UI_EXTRAS_BROWSER);
    assert(protector_ui_context_snapshot().map_actions == 0);
    assert(!strcmp(protector_ui_context_name(PROTECTOR_UI_EXTRAS_BROWSER), "extras-browser"));
    protector_ui_context_publish_snapshot(PROTECTOR_UI_EXTRAS_OPTIONS, 3);
    assert(protector_ui_context_current() == PROTECTOR_UI_EXTRAS_OPTIONS);
    assert(protector_ui_context_snapshot().map_actions == 0);
    assert(!strcmp(protector_ui_context_name(PROTECTOR_UI_EXTRAS_OPTIONS), "extras-options"));
    protector_ui_context_publish_snapshot(PROTECTOR_UI_EXTRAS_ROOT, 3);
    assert(protector_ui_context_current() == PROTECTOR_UI_EXTRAS_ROOT);
    assert(protector_ui_context_snapshot().map_actions == 0);
    assert(!strcmp(protector_ui_context_name(PROTECTOR_UI_EXTRAS_ROOT), "extras-root"));
    /* Gallery wins an overlapping Menu lease, but not later source stages,
     * independent of owner order. */
    for (ProtectorUIContext browser = PROTECTOR_UI_GALLERY; browser <= PROTECTOR_UI_UPGRADE_READY; ++browser)
    for (unsigned reversed = 0; reversed < 2; ++reversed) {
        for (ProtectorUIContext other = PROTECTOR_UI_GAMEPLAY; other <= PROTECTOR_UI_DEFEAT; ++other) {
            ProtectorUIContextTracker priority = {0};
            priority.count = 2;
            priority.owners[reversed] = (ProtectorUIContextOwner){.last_frame = 20, .kind = browser};
            priority.owners[1 - reversed] = (ProtectorUIContextOwner){.last_frame = 20, .kind = other};
            assert(protector_ui_context_frame(&priority, 20) ==
                (other > PROTECTOR_UI_MENU ? other : browser));
        }
    }
    /* A child wins the Extras root's short departure lease in either order. */
    for (ProtectorUIContext child = PROTECTOR_UI_GALLERY; child <= PROTECTOR_UI_EXTRAS_OPTIONS; ++child)
    for (unsigned reversed = 0; reversed < 2; ++reversed) {
        ProtectorUIContextTracker priority = {0};
        priority.count = 2;
        priority.owners[reversed] = (ProtectorUIContextOwner){.last_frame = 20, .kind = child};
        priority.owners[1 - reversed] = (ProtectorUIContextOwner){.last_frame = 20, .kind = PROTECTOR_UI_EXTRAS_ROOT};
        assert(protector_ui_context_frame(&priority, 20) == child);
    }
    assert(!strcmp(protector_ui_context_name(PROTECTOR_UI_LOADING), "loading"));
    assert(!strcmp(protector_ui_context_name(PROTECTOR_UI_PROMPT), "confirm-prompt"));
    assert(!strcmp(protector_ui_context_name(PROTECTOR_UI_MAP), "world-map"));
    protector_ui_context_publish(PROTECTOR_UI_DEFEAT);
    assert(protector_ui_context_current() == PROTECTOR_UI_DEFEAT);
    assert(!strcmp(protector_ui_context_name(PROTECTOR_UI_DEFEAT), "defeat-ready"));
    protector_ui_context_publish_snapshot(PROTECTOR_UI_MAP, 0xffffffff);
    ProtectorUIContextSnapshot snapshot = protector_ui_context_snapshot();
    assert(snapshot.context == PROTECTOR_UI_MAP && snapshot.map_actions == 3);
    protector_ui_context_publish(PROTECTOR_UI_MAP);
    assert(protector_ui_context_snapshot().map_actions == 0);
    protector_ui_context_publish_snapshot(PROTECTOR_UI_MENU, 3);
    assert(protector_ui_context_snapshot().map_actions == 0);
    tracker = (ProtectorUIContextTracker){0};
    tracker.owners[0] = (ProtectorUIContextOwner){.context = 0x1000,
        .begin = 0x2000, .end = 0x3000, .last_frame = 10, .kind = PROTECTOR_UI_MAP,
        .map_actions_frame = 10, .map_actions = 3};
    tracker.count = 1;
    assert(protector_ui_context_map_actions(&tracker, 9) == 0);
    assert(protector_ui_context_map_actions(&tracker, 10) == 3);
    assert(protector_ui_context_map_actions(&tracker, 12) == 3);
    assert(protector_ui_context_map_actions(&tracker, 13) == 0);
    protector_ui_context_dispatch(&tracker, 0x1000, 0x2100, 0x89ffffff, 10);
    assert(protector_ui_context_map_actions(&tracker, 10) == 0);
    /* InitSystem survives loading. Keep its silent loading-to-tip gap, but
     * leave on the explicit ready-prompt acceptance, not its global lifetime. */
    const ProtectorUIContext transient[] = {PROTECTOR_UI_LOADING, PROTECTOR_UI_PROMPT};
    for (size_t i = 0; i < 2; ++i) {
        tracker = (ProtectorUIContextTracker){0};
        tracker.owners[0] = (ProtectorUIContextOwner){0x1000, 0x2000, 0x3000, 20, transient[i], 8, 0x2400, 0x2500};
        tracker.count = 1;
        for (u64 frame = 21; frame < 100; ++frame) {
            protector_ui_context_dispatch(&tracker, 0x1000, 0x2100, 0x81000000, frame);
            assert(protector_ui_context_frame(&tracker, frame) == transient[i]);
        }
        protector_ui_context_dispatch(&tracker, 0x1000, 0x2400 + i * 0x40, 0x81000000, 100);
        assert(protector_ui_context_frame(&tracker, 100) == PROTECTOR_UI_GAMEPLAY);
        tracker.owners[0] = (ProtectorUIContextOwner){0x1000, 0x2000, 0x3000, 20, transient[i], 8, 0x2400, 0x2500};
        tracker.count = 1;
        /* Rendering may continue during a long source wait without any VM
         * dispatch. Neither loading nor the ready action may flash combat UI. */
        assert(protector_ui_context_frame(&tracker, 200) == transient[i]);
        protector_ui_context_dispatch(&tracker, 0x1000, 0x3100, 0x81000000, 201);
        assert(protector_ui_context_frame(&tracker, 201) == PROTECTOR_UI_GAMEPLAY);
        tracker.owners[0] = (ProtectorUIContextOwner){0x1000, 0x2000, 0x3000, 20, transient[i], 8, 0x2400, 0x2500};
        tracker.count = 1;
        assert(protector_ui_context_frame(&tracker, 19) == PROTECTOR_UI_GAMEPLAY);
    }
    protector_ui_context_publish(PROTECTOR_UI_GAMEPLAY);
}

static void combo_checks(CPUState* cpu, const ProtectorUIContextTracker* admitted) {
    const bool upgrade=admitted->owners[0].kind==PROTECTOR_UI_UPGRADE_MENU ||
        admitted->owners[0].kind==PROTECTOR_UI_UPGRADE_READY;
    const u32 context=0x80001000,ip=upgrade?0x90010800:0x9000e2f0;
    u32 (*scheme_for)(const ProtectorUIContextTracker*,u64)=upgrade?
        protector_ui_context_upgrade_scheme:protector_ui_context_combo_scheme;
    u32 (*other_scheme)(const ProtectorUIContextTracker*,u64)=upgrade?
        protector_ui_context_combo_scheme:protector_ui_context_upgrade_scheme;
    static const u8 glyphs[3][4]={{1,2,4,6},{1,2,4,9},{2,6,1,4}};
    for(u32 scheme=1;scheme<=3;++scheme)for(u32 ordinal=1;ordinal<=19;++ordinal) {
        const char* actions=protector_combo_action_sequence(ordinal);
        ProtectorUIText text={.key_available=true,.language_slot=1,.text_size=(u32)strlen(actions)};
        if(scheme==1)snprintf(text.key,sizeof(text.key),"Panel-CombosButtonsOnlyWii-%u",ordinal);
        else snprintf(text.key,sizeof(text.key),"Panel-CombosButtonsOnlyWii%u-%u",scheme,ordinal);
        for(size_t b=0;b<strlen(actions);++b)text.text[b]=glyphs[scheme-1][actions[b]-'1'];
        ProtectorUIContextTracker tracker=*admitted;
        protector_ui_context_observe(&tracker,cpu,&text,context,ip);
        assert(scheme_for(&tracker,7)==scheme);
        assert(!other_scheme(&tracker,7));
        assert(!scheme_for(&tracker,6));
        assert(!scheme_for(&tracker,8));
        for(unsigned mutation=0;mutation<9;++mutation) {
            tracker=*admitted;ProtectorUIText invalid=text;
            u32 wrong_context=context,wrong_ip=ip;
            switch(mutation) {
                case 0:invalid.text[0]^=0x40;break;
                case 1:invalid.language_slot=2;break;
                case 2:invalid.text_size=0;break;
                case 3:invalid.text[invalid.text_size]=1;break;
                case 4:invalid.key[0]='X';break;
                case 5:wrong_context+=4;break;
                case 6:wrong_ip+=4;break;
                case 7:invalid.text_size=4;break;
                case 8:wrong_ip=upgrade?0x9000e2f0:0x90010800;break;
            }
            protector_ui_context_observe(&tracker,cpu,&invalid,wrong_context,wrong_ip);
            assert(!scheme_for(&tracker,7));
            if(mutation!=5 && mutation!=6 && mutation!=8) {
                protector_ui_context_observe(&tracker,cpu,&text,context,ip);
                assert(!scheme_for(&tracker,7));
            }
        }
        tracker=*admitted;
        protector_ui_context_observe(&tracker,cpu,&text,context,ip);
        ProtectorUIText other={.key_available=true,.language_slot=1,.text_size=1};
        const u32 next=scheme%3+1;
        if(next==1)strcpy(other.key,"Panel-CombosButtonsOnlyWii-1");
        else snprintf(other.key,sizeof(other.key),"Panel-CombosButtonsOnlyWii%u-1",next);
        other.text[0]=glyphs[next-1][0];
        protector_ui_context_observe(&tracker,cpu,&other,context,ip);
        assert(!scheme_for(&tracker,7));
        cpu->presented_frame_count=8;
        tracker.owners[0].last_frame=8;
        protector_ui_context_observe(&tracker,cpu,&text,context,ip);
        assert(scheme_for(&tracker,8)==scheme);
        protector_ui_context_dispatch(&tracker,context,ip,0x89ffffff,8);
        assert(!scheme_for(&tracker,8));
        cpu->presented_frame_count=7;
    }
    assert(!protector_combo_action_sequence(0) && !protector_combo_action_sequence(20));
    for(u32 scheme=0;scheme<=4;++scheme)for(u32 glyph=0;glyph<256;++glyph) {
        u32 expected=0;
        if(scheme>=1 && scheme<=3)for(u32 action=0;action<4;++action)
            if(glyphs[scheme-1][action]==glyph)expected=action+1;
        assert(protector_combo_action_for_glyph(scheme,(u8)glyph)==expected);
    }
}

static void dispatch_admission_checks(CPUState* cpu) {
    size_t count=0,rule_count=0;
    const ProtectorUIContextDispatchAdmission* entries=protector_ui_context_dispatch_admissions(&count);
    const ProtectorScriptFlowRule* rules=protector_ui_context_rules(&rule_count);
    assert(count==9 && rule_count==49);
    const ProtectorUIContextDispatchAdmission* entry=&entries[0];
    const ProtectorScriptFlowRule* source=&rules[entry->rule_index];
    const u32 context=0x80001000,ip=0x90000000+entry->offset;
    ProtectorUIContextTracker tracker={0};
    if(cpu->mem2_size!=source->file_info_size) {
        assert(!protector_ui_context_admit_dispatch(&tracker,cpu,context,ip,entry->instruction));
        return;
    }
    // Extras has no live map/text owner. Its independent marker must admit
    // the full script, without prematurely exposing the source's Skip input.
    assert(protector_ui_context_admit_dispatch(&tracker,cpu,context,ip,entry->instruction));
    assert(tracker.count==1 && tracker.admission_count==1);
    assert(tracker.owners[0].rule_index==25);
    assert(protector_ui_context_frame(&tracker,7)==PROTECTOR_UI_CINEMATIC);
    protector_ui_context_dispatch(&tracker,context,0x90000364,0xebff0606,7);
    assert(protector_ui_context_frame(&tracker,7)==PROTECTOR_UI_CINEMATIC);
    protector_ui_context_dispatch(&tracker,context,0x9000036c,0x4209702a,7);
    assert(protector_ui_context_frame(&tracker,7)==PROTECTOR_UI_CINEMATIC_READY);
    protector_ui_context_dispatch(&tracker,context,0x900003b0,0x44017090,7);
    assert(protector_ui_context_frame(&tracker,7)==PROTECTOR_UI_GAMEPLAY);
    assert(protector_ui_context_frame(&tracker,10)==PROTECTOR_UI_GAMEPLAY);
    for(unsigned mutation=0;mutation<8;++mutation) {
        tracker=(ProtectorUIContextTracker){0};
        u32 site=ip,instruction=entry->instruction,owner=context,offset=0;
        switch(mutation) {
            case 0: site+=4;break;
            case 1: instruction^=1;break;
            case 2: owner=0;break;
            case 3: offset=entry->offset;break;
            case 4: offset=source->code_offset+0x40;break;
            case 5: offset=source->name_offset;break;
            case 6: offset=source->pointer_offsets[0];break;
            case 7: site=0xffffffff;break;
        }
        const bool mutate_bytes=mutation>=3 && mutation<=6;
        if(mutate_bytes)cpu->mem2[offset]^=1;
        assert(!protector_ui_context_admit_dispatch(&tracker,cpu,owner,site,instruction));
        if(mutate_bytes)cpu->mem2[offset]^=1;
        assert(!tracker.count && !tracker.admission_count && !tracker.last_admission);
    }
    tracker=(ProtectorUIContextTracker){.count=4};
    for(u32 i=0;i<4;++i)tracker.owners[i]=(ProtectorUIContextOwner){.context=context+4*(i+1),.kind=PROTECTOR_UI_MENU};
    ProtectorUIContextTracker full=tracker;
    assert(!protector_ui_context_admit_dispatch(&tracker,cpu,context,ip,entry->instruction));
    assert(!memcmp(&tracker,&full,sizeof(tracker)));
    tracker.owners[2].context=context;
    assert(protector_ui_context_admit_dispatch(&tracker,cpu,context,ip,entry->instruction));
    assert(tracker.count==4 && tracker.owners[2].kind==PROTECTOR_UI_CINEMATIC);
    assert(!tracker.owners[2].leave_end && !tracker.owners[2].loading_confirmed);
    assert(!protector_ui_context_admit_dispatch(NULL,cpu,context,ip,entry->instruction));
    assert(!protector_ui_context_admit_dispatch(&tracker,NULL,context,ip,entry->instruction));
    // A concurrently dispatching browser cannot suppress either playback
    // stage, but must reappear as soon as the movie reaches its cleanup.
    tracker=(ProtectorUIContextTracker){.count=1};
    tracker.owners[0]=(ProtectorUIContextOwner){.context=context+4,.last_frame=7,
        .kind=PROTECTOR_UI_EXTRAS_BROWSER};
    assert(protector_ui_context_admit_dispatch(&tracker,cpu,context,ip,entry->instruction));
    assert(protector_ui_context_frame(&tracker,7)==PROTECTOR_UI_CINEMATIC);
    protector_ui_context_dispatch(&tracker,context,0x9000036c,0x4209702a,7);
    assert(protector_ui_context_frame(&tracker,7)==PROTECTOR_UI_CINEMATIC_READY);
    protector_ui_context_dispatch(&tracker,context,0x900003b0,0x44017090,7);
    assert(protector_ui_context_frame(&tracker,7)==PROTECTOR_UI_EXTRAS_BROWSER);
}

static void choice_dispatch_checks(CPUState* cpu) {
    size_t count=0,rule_count=0;
    const ProtectorUIContextDispatchAdmission* entries=protector_ui_context_dispatch_admissions(&count);
    const ProtectorScriptFlowRule* rules=protector_ui_context_rules(&rule_count);
    assert(count==9 && rule_count==49);
    for(size_t n=1;n<count;++n) {
        const ProtectorUIContextDispatchAdmission* entry=&entries[n];
        const ProtectorScriptFlowRule* source=&rules[entry->rule_index];
        const u32 context=0x80001000,ip=0x90000000+entry->offset;
        ProtectorUIContextTracker tracker={0};
        if(cpu->mem2_size!=source->file_info_size) {
            assert(!protector_ui_context_admit_dispatch(&tracker,cpu,context,ip,entry->instruction));
            continue;
        }
        assert(!source->pointer_count && !source->pointer_offsets);
        assert(protector_ui_context_admit_dispatch(&tracker,cpu,context,ip,entry->instruction));
        assert(tracker.count==1 && tracker.admission_count==1);
        assert(tracker.owners[0].rule_index==entry->rule_index);
        assert(protector_ui_context_frame(&tracker,7)==PROTECTOR_UI_CHOICE_DIALOG);
        ProtectorUIContextTracker accepted=tracker;
        // Context survives drawing/yield; source completion, not a native tap,
        // ends ownership. Choices must win a still-live loading/menu lease.
        tracker.owners[tracker.count++]=(ProtectorUIContextOwner){.context=context+4,
            .last_frame=7,.kind=PROTECTOR_UI_LOADING};
        assert(protector_ui_context_frame(&tracker,7)==PROTECTOR_UI_CHOICE_DIALOG);
        protector_ui_context_dispatch(&tracker,context,ip+4,0,8);
        assert(protector_ui_context_frame(&tracker,8)==PROTECTOR_UI_CHOICE_DIALOG);
        protector_ui_context_dispatch(&tracker,context,0x90000000+source->code_offset+source->code_size-4,0x89ffffff,8);
        assert(protector_ui_context_frame(&tracker,8)==PROTECTOR_UI_LOADING);
        tracker=accepted;
        assert(protector_ui_context_frame(&tracker,10)==PROTECTOR_UI_GAMEPLAY);
        for(unsigned mutation=0;mutation<7;++mutation) {
            tracker=(ProtectorUIContextTracker){0};
            u32 site=ip,instruction=entry->instruction,owner=context,offset=0;
            switch(mutation) {
                case 0:site+=4;break;
                case 1:instruction^=1;break;
                case 2:owner=0;break;
                case 3:offset=entry->offset;break;
                case 4:offset=source->code_offset+0x40;break;
                case 5:offset=source->name_offset;break;
                case 6:offset=source->code_offset+source->code_size-4;break;
            }
            if(mutation>=3)cpu->mem2[offset]^=1;
            assert(!protector_ui_context_admit_dispatch(&tracker,cpu,owner,site,instruction));
            if(mutation>=3)cpu->mem2[offset]^=1;
            assert(!tracker.count && !tracker.admission_count);
        }
    }
    protector_ui_context_publish_snapshot(PROTECTOR_UI_CHOICE_DIALOG,3);
    assert(protector_ui_context_current()==PROTECTOR_UI_CHOICE_DIALOG);
    assert(!protector_ui_context_snapshot().map_actions);
    assert(!strcmp(protector_ui_context_name(PROTECTOR_UI_CHOICE_DIALOG),"choice-dialog"));
    protector_ui_context_publish(PROTECTOR_UI_GAMEPLAY);
}

static size_t source_checks(const char* path) {
        CPUState cpu = {0};
        FILE* file = fopen(path, "rb");
        assert(file && !fseek(file, 0, SEEK_END));
        const long size = ftell(file);
        assert((size == 0x207420 || size == 0x48f40 || size == 0x116420 || size == 0x2b1f00 ||
                size == 0x4ffd40 || size == 0x542520 || size == 0x5405c0 ||
                size == 0x5c860 || size == 0x1ab040 || size == 0x2cb540 ||
                size == 0x386e40 || size == 0x270f60 || size == 0x540) && !fseek(file, 0, SEEK_SET));
        cpu.mem2 = malloc((size_t)size); cpu.mem2_size = (u32)size;
        assert(cpu.mem2 && fread(cpu.mem2, 1, (size_t)size, file) == (size_t)size);
        fclose(file);
        cpu.presented_frame_count = 7;
        CPUState before = cpu;
        size_t rule_count = 0, admission_count = 0;
        const ProtectorScriptFlowRule* rules = protector_ui_context_rules(&rule_count);
        const ProtectorUIContextAdmission* admissions = protector_ui_context_admissions(&admission_count);
        assert(rule_count == 49 && admission_count == 56);
        dispatch_admission_checks(&cpu);
        choice_dispatch_checks(&cpu);
        size_t checked = 0;
        ProtectorUIContextTracker reused = {0};
        for (size_t i = 0; i < admission_count; ++i) {
            const ProtectorUIContextAdmission* admission = &admissions[i];
            assert(admission->rule_index < rule_count);
            const ProtectorScriptFlowRule* source = &rules[admission->rule_index];
            const u32 ip = 0x90000000 + admission->return_offset;
            ProtectorUIText text = {.key_available = true, .language_slot = 1};
            strcpy(text.key, admission->key);
            ProtectorUIContextTracker tracker = {0};
            if (source->file_info_size != (u32)size) {
                assert(!protector_ui_context_observe(&tracker, &cpu, &text, 0x80001000, ip));
                continue;
            }
            ++checked;
            assert(protector_ui_context_observe(&tracker, &cpu, &text, 0x80001000, ip));
            assert(protector_ui_context_frame(&tracker, 7) == admission->kind);
            assert(protector_ui_context_observe(&tracker, &cpu, &text, 0x80001000, ip));
            assert(tracker.count == 1 && tracker.admission_count == 1);
            if (admission->kind == PROTECTOR_UI_FATAL_DIALOG) {
                ProtectorUIContextTracker fatal = tracker;
                ProtectorUIText saving = {.key_available=true};
                strcpy(saving.key, "Platform-Wii-1");
                assert(!protector_ui_context_observe(&fatal,&cpu,&saving,0x80001000,ip+4));
                assert(protector_ui_context_frame(&fatal,7)==PROTECTOR_UI_FATAL_DIALOG);
                assert(!protector_ui_context_observe(&fatal,&cpu,&saving,0x80001000,ip));
                assert(fatal.count==0);
                assert(protector_ui_context_frame(&fatal,7)==PROTECTOR_UI_GAMEPLAY);
                assert(protector_ui_context_observe(&fatal,&cpu,&text,0x80001000,ip));
                saving.key_available=false;
                assert(!protector_ui_context_observe(&fatal,&cpu,&saving,0x80001000,ip));
                assert(fatal.count==0);
                assert(protector_ui_context_frame(&tracker,7)==PROTECTOR_UI_FATAL_DIALOG);
            }
            if(admission->kind==PROTECTOR_UI_COMBO_LIST || admission->kind==PROTECTOR_UI_UPGRADE_MENU ||
                admission->kind==PROTECTOR_UI_UPGRADE_READY)
                combo_checks(&cpu,&tracker);
            if(admission->kind==PROTECTOR_UI_UPGRADE_MENU) {
                ProtectorUIContextTracker upgrade=tracker;
                ProtectorUIText offered={.key_available=true,.language_slot=1};
                strcpy(offered.key,"Panel-UpgradeScreen-1");
                assert(!protector_ui_context_observe(&upgrade,&cpu,&offered,0x80001000,0x900110bc));
                assert(protector_ui_context_frame(&upgrade,7)==PROTECTOR_UI_UPGRADE_MENU);
                assert(protector_ui_context_observe(&upgrade,&cpu,&offered,0x80001000,0x900110b8));
                assert(protector_ui_context_frame(&upgrade,7)==PROTECTOR_UI_UPGRADE_READY);
                assert(protector_ui_context_observe(&upgrade,&cpu,&text,0x80001000,ip));
                assert(protector_ui_context_frame(&upgrade,7)==PROTECTOR_UI_UPGRADE_MENU);
                assert(upgrade.count==1 && upgrade.admission_count==1);
            }
            /* Cache hits must keep the exact return contract too. */
            assert(!protector_ui_context_observe(&tracker, &cpu, &text, 0x80001000, ip + 4));
            assert(!strcmp(tracker.last_admission, source->name));
            assert(protector_ui_context_observe(&reused, &cpu, &text, 0x80001000, ip));
            assert(reused.count == 1);
            if (admission->kind == PROTECTOR_UI_DEFEAT) {
                /* These full blocks are relocation-equivalent. An earlier
                 * reviewed variant can match with a shifted inferred base;
                 * every actual code address and departure must still agree. */
                assert(reused.owners[0].rule_index >= 11 && reused.owners[0].rule_index <= 13);
                assert(reused.owners[0].begin == 0x90000000 + source->code_offset);
                assert(reused.owners[0].end == 0x90000000 + source->code_offset + source->code_size);
            } else if (!strcmp(source->name, "EndOfLevelStats")) {
                /* The complete results blocks have the same relocation-
                 * normalized shape; verify absolute ownership, not variant ID. */
                assert(reused.owners[0].rule_index >= 30 && reused.owners[0].rule_index <= 32);
                assert(reused.owners[0].begin == 0x90000000 + source->code_offset);
                assert(reused.owners[0].end == 0x90000000 + source->code_offset + source->code_size);
            } else assert(reused.owners[0].rule_index == admission->rule_index);
            assert(reused.owners[0].kind == admission->kind);
            if (admission->kind == PROTECTOR_UI_MAP) {
                const u32 offered = !strcmp(admission->key, "Panel-HubScreen-5") ?
                    PROTECTOR_UI_MAP_REPLAY : !strcmp(admission->key, "Panel-HubScreen-8") ?
                    PROTECTOR_UI_MAP_CHALLENGE : 0;
                assert(protector_ui_context_map_actions(&tracker, 7) == offered);
                ProtectorUIContextTracker map = tracker;
                ProtectorUIText map_text = {.key_available = true, .language_slot = 1};
                strcpy(map_text.key, "Panel-HubScreen-5");
                assert(protector_ui_context_observe(&map, &cpu, &map_text, 0x80001000, 0x900166b4));
                strcpy(map_text.key, "Panel-HubScreen-8");
                assert(protector_ui_context_observe(&map, &cpu, &map_text, 0x80001000, 0x90016770));
                assert(protector_ui_context_map_actions(&map, 7) == 3);
                /* Base draw in the same frame cannot erase earlier offers. */
                strcpy(map_text.key, "Platform-PC-41");
                assert(protector_ui_context_observe(&map, &cpu, &map_text, 0x80001000, 0x900163d4));
                assert(protector_ui_context_map_actions(&map, 7) == 3);
                cpu.presented_frame_count = 8;
                /* No matching draw: a wrong IP cannot update optional state. */
                assert(!protector_ui_context_observe(&map, &cpu, &map_text, 0x80001000, 0x900163d8));
                assert(protector_ui_context_map_actions(&map, 8) == 3);
                assert(protector_ui_context_observe(&map, &cpu, &map_text, 0x80001000, 0x900163d4));
                assert(protector_ui_context_frame(&map, 8) == PROTECTOR_UI_MAP);
                assert(protector_ui_context_map_actions(&map, 8) == 0);
                assert(map.admission_count == 1);
                size_t transition_count = 0;
                const ProtectorUIContextTransition* transitions = protector_ui_context_transitions(&transition_count);
                assert(transition_count == 15);
                for (size_t n = 0; n < transition_count; ++n) {
                    if (transitions[n].rule_index != admission->rule_index) continue;
                    const ProtectorUIContext previous = protector_ui_context_frame(&map, 8);
                    const u32 site = 0x90000000 + transitions[n].offset;
                    protector_ui_context_dispatch(&map, 0x80001100, site, 0, 8);
                    assert(protector_ui_context_frame(&map, 8) == previous);
                    protector_ui_context_dispatch(&map, 0x80001000, site + 4, 0, 8);
                    assert(protector_ui_context_frame(&map, 8) == previous);
                    protector_ui_context_dispatch(&map, 0x80001000, site, 0, 8);
                    assert(protector_ui_context_frame(&map, 8) == transitions[n].kind);
                    assert(protector_ui_context_map_actions(&map, 8) == 0);
                }
                /* A later visible map reacquires its context without a stale
                 * movie/skip state. A stopped owner still expires normally. */
                assert(protector_ui_context_observe(&map, &cpu, &map_text, 0x80001000, 0x900163d4));
                assert(protector_ui_context_frame(&map, 8) == PROTECTOR_UI_MAP);
                assert(protector_ui_context_frame(&map, 11) == PROTECTOR_UI_GAMEPLAY);
                cpu.presented_frame_count = 7;
            }
            if (admission->kind == PROTECTOR_UI_DEFEAT) {
                size_t transition_count = 0, departures = 0;
                const ProtectorUIContextTransition* transitions = protector_ui_context_transitions(&transition_count);
                assert(transition_count == 15);
                for (size_t n = 0; n < transition_count; ++n) {
                    if (transitions[n].rule_index != admission->rule_index) continue;
                    ++departures;
                    ProtectorUIContextTracker death = tracker;
                    const u32 site = 0x90000000 + transitions[n].offset;
                    protector_ui_context_dispatch(&death, 0x80001100, site, 0, 8);
                    assert(protector_ui_context_frame(&death, 8) == PROTECTOR_UI_DEFEAT);
                    protector_ui_context_dispatch(&death, 0x80001000, site + 4, 0, 8);
                    assert(protector_ui_context_frame(&death, 8) == PROTECTOR_UI_DEFEAT);
                    protector_ui_context_dispatch(&death, 0x80001000, site, 0, 8);
                    assert(protector_ui_context_frame(&death, 8) == PROTECTOR_UI_LOADING);
                    assert(protector_ui_context_frame(&death, 11) == PROTECTOR_UI_GAMEPLAY);
                }
                assert(departures == 2);
                ProtectorUIContextTracker death = tracker;
                assert(protector_ui_context_frame(&death, 9) == PROTECTOR_UI_DEFEAT);
                assert(protector_ui_context_frame(&death, 10) == PROTECTOR_UI_GAMEPLAY);
                death = tracker;
                protector_ui_context_dispatch(&death, 0x80001000,
                    0x90000000 + source->code_offset + source->code_size, 0, 8);
                assert(protector_ui_context_frame(&death, 8) == PROTECTOR_UI_GAMEPLAY);
                death = tracker;
                protector_ui_context_dispatch(&death, 0x80001000, ip, 0x89ffffff, 8);
                assert(protector_ui_context_frame(&death, 8) == PROTECTOR_UI_GAMEPLAY);
                ProtectorUIText header = text;
                strcpy(header.key, "Panel-Options-6");
                death = (ProtectorUIContextTracker){0};
                assert(!protector_ui_context_observe(&death, &cpu, &header, 0x80001000, ip - 24));
                assert(!protector_ui_context_observe(&death, &cpu, &header, 0x80001000, ip));
            }
            if (!strcmp(source->name, "EndOfLevelStats")) {
                ProtectorUIContextTracker results = tracker;
                const u32 departure = 0x90000000 + source->code_offset + 0xbec;
                protector_ui_context_dispatch(&results, 0x80001100, departure, 0, 8);
                assert(protector_ui_context_frame(&results, 8) == PROTECTOR_UI_CONTINUE_DIALOG);
                protector_ui_context_dispatch(&results, 0x80001000, departure - 4, 0, 8);
                assert(protector_ui_context_frame(&results, 8) == PROTECTOR_UI_CONTINUE_DIALOG);
                protector_ui_context_dispatch(&results, 0x80001000, departure, 0, 8);
                assert(protector_ui_context_frame(&results, 8) == PROTECTOR_UI_LOADING);
                protector_ui_context_dispatch(&results, 0x80001000,
                    0x90000000 + source->code_offset + source->code_size - 4, 0x89ffffff, 8);
                assert(protector_ui_context_frame(&results, 8) == PROTECTOR_UI_GAMEPLAY);
            }
            if (admission->kind == PROTECTOR_UI_TITLE || admission->kind == PROTECTOR_UI_MENU ||
                admission->kind == PROTECTOR_UI_MAP || admission->kind == PROTECTOR_UI_GALLERY ||
                admission->kind == PROTECTOR_UI_EXTRAS_ROOT) {
                /* A source-verified menu takes over a no-tip loading stage,
                 * on both new admission and the existing owner's cache path. */
                ProtectorUIContextTracker menu = {0};
                menu.owners[0] = (ProtectorUIContextOwner){0x80006000, 0x2000, 0x3000,
                    7, PROTECTOR_UI_LOADING, 8, 0x2400, 0x2500};
                menu.count = 1;
                assert(!protector_ui_context_observe(&menu, &cpu, &text, 0x80001000, ip + 4));
                assert(menu.count == 1 && menu.owners[0].kind == PROTECTOR_UI_LOADING);
                assert(protector_ui_context_observe(&menu, &cpu, &text, 0x80001000, ip));
                assert(menu.count == 1 && protector_ui_context_frame(&menu, 7) == admission->kind);
                menu.owners[1] = (ProtectorUIContextOwner){0x80006000, 0x2000, 0x3000,
                    7, PROTECTOR_UI_PROMPT, 8, 0x2400, 0x2500};
                menu.count = 2;
                assert(protector_ui_context_observe(&menu, &cpu, &text, 0x80001000, ip));
                assert(menu.count == 1 && protector_ui_context_frame(&menu, 7) == admission->kind);
            }
            if (admission->leave_end) {
                assert(tracker.owners[0].leave_begin == 0x90000000 + admission->leave_begin);
                assert(tracker.owners[0].leave_end == 0x90000000 + admission->leave_end);
                ProtectorUIContextTracker leaving = tracker;
                protector_ui_context_dispatch(&leaving, 0x80001000, 0x90088634, 0x3239ff04, 8);
                assert(protector_ui_context_frame(&leaving, 8) == PROTECTOR_UI_GAMEPLAY);
                leaving = tracker;
                protector_ui_context_dispatch(&leaving, 0x80001000, 0x90088674, 0x47ffff00, 8);
                assert(protector_ui_context_frame(&leaving, 8) == admission->kind);
                assert(protector_ui_context_frame(&leaving, 208) == admission->kind);
                if (admission->kind == PROTECTOR_UI_PROMPT) {
                    /* Actual Redwood sequence: ready acceptance, another
                     * loading label, STOP's no-tip branch, idle. Bootstrap
                     * gaps above must remain loading, even for 200 frames. */
                    leaving = tracker;
                    protector_ui_context_dispatch(&leaving, 0x80001000, 0x90088634, 0x3239ff04, 8);
                    assert(leaving.count == 1 && leaving.owners[0].loading_confirmed);
                    assert(protector_ui_context_frame(&leaving, 8) == PROTECTOR_UI_GAMEPLAY);
                    ProtectorUIText load_text = {.key_available = true, .language_slot = 1};
                    strcpy(load_text.key, "Panel-Misc-4");
                    cpu.presented_frame_count = 9;
                    assert(protector_ui_context_observe(&leaving, &cpu, &load_text, 0x80001000, 0x90088528));
                    assert(leaving.admission_count == 1);
                    assert(protector_ui_context_frame(&leaving, 200) == PROTECTOR_UI_LOADING);
                    protector_ui_context_dispatch(&leaving, 0x80002000, 0x90088674, 0x47ffff00, 200);
                    protector_ui_context_dispatch(&leaving, 0x80001000, 0x90088678, 0x47ffff00, 200);
                    protector_ui_context_dispatch(&leaving, 0x80001000, 0x90088674, 0x47ffff01, 200);
                    assert(protector_ui_context_frame(&leaving, 200) == PROTECTOR_UI_LOADING);
                    protector_ui_context_dispatch(&leaving, 0x80001000, 0x90088674, 0x47ffff00, 201);
                    assert(protector_ui_context_frame(&leaving, 201) == PROTECTOR_UI_GAMEPLAY);
                    cpu.presented_frame_count = 202;
                    assert(protector_ui_context_observe(&leaving, &cpu, &text, 0x80001000, ip));
                    protector_ui_context_dispatch(&leaving, 0x80001000, 0x90088674, 0x47ffff00, 203);
                    assert(protector_ui_context_frame(&leaving, 203) == PROTECTOR_UI_PROMPT);
                    /* Reused/rewound state must not inherit confirmation. */
                    cpu.presented_frame_count = 7;
                    assert(protector_ui_context_observe(&leaving, &cpu, &load_text, 0x80001000, 0x90088528));
                    assert(!leaving.owners[0].loading_confirmed);
                    protector_ui_context_dispatch(&leaving, 0x80001000, 0x90088674, 0x47ffff00, 8);
                    assert(protector_ui_context_frame(&leaving, 8) == PROTECTOR_UI_LOADING);
                    protector_ui_context_dispatch(&leaving, 0x80001000, 0x90088678, 0x89ffffff, 8);
                    assert(leaving.count == 0);
                    assert(protector_ui_context_observe(&leaving, &cpu, &load_text, 0x80001000, 0x90088528));
                    assert(!leaving.owners[0].loading_confirmed);
                }
            }
            assert(!strcmp(reused.last_admission, source->name));
            /* Each additional owner is bounded; overflow keeps the current UI. */
            for (u32 owner = 2; owner <= 4; ++owner)
                assert(protector_ui_context_observe(&tracker, &cpu, &text, owner * 0x800, ip));
            assert(!protector_ui_context_observe(&tracker, &cpu, &text, 0x80005000, ip));
            assert(tracker.count == 4 && tracker.admission_count == 4);
            tracker = (ProtectorUIContextTracker){0};
            cpu.mem2[source->code_offset] ^= 1;
            assert(!protector_ui_context_observe(&tracker, &cpu, &text, 0x80001000, ip));
            cpu.mem2[source->code_offset] ^= 1;
            /* The Controller's handlers follow its visible definition body.
             * Corruption there must reject the same header admission. */
            if (!strcmp(source->name, "Ben10ControllerScreenWII") || !strcmp(source->name, "PlayerDeathScreen") ||
                admission->rule_index >= 14) {
                const u32 tail = source->code_offset + source->code_size - 1;
                cpu.mem2[tail] ^= 1;
                assert(!protector_ui_context_observe(&tracker, &cpu, &text, 0x80001000, ip));
                cpu.mem2[tail] ^= 1;
            }
            assert(!protector_ui_context_observe(&tracker, &cpu, &text, 0x80001000, ip + 4));
            text.key_available = false;
            assert(!protector_ui_context_observe(&tracker, &cpu, &text, 0x80001000, ip));
            text.key_available = true; text.key[0] ^= 1;
            assert(!protector_ui_context_observe(&tracker, &cpu, &text, 0x80001000, ip));
            assert(!tracker.admission_count && !tracker.last_admission);
            if (!strcmp(source->name, "Menu")) {
                strcpy(text.key, "Panel-Options-1");
                /* Root header may not be moved to the shared item-loop call. */
                assert(!protector_ui_context_observe(&tracker, &cpu, &text,
                    0x80001000, ip - 0x80));
                strcpy(text.key, "Panel-Options-2");
                assert(!protector_ui_context_observe(&tracker, &cpu, &text, 0x80001000, ip));
                strcpy(text.key, "Panel-Options-1");
                cpu.mem2[source->name_offset] ^= 1;
                assert(!protector_ui_context_observe(&tracker, &cpu, &text, 0x80001000, ip));
                cpu.mem2[source->name_offset] ^= 1;
            }
        }
        assert(!memcmp(&cpu, &before, sizeof(cpu)));
        free(cpu.mem2);
        // The independent movie player is admitted by dispatch, not text.
        assert(checked > 0 || size == 0x540);
        return checked;
}

int main(int argc, char** argv) {
    bool observed = false;
    ProtectorUIContextSnapshot cold = {PROTECTOR_UI_GAMEPLAY, 0};
    for (unsigned i = 0; i < 100; ++i) {
        ProtectorUIContextSnapshot result = protector_ui_context_startup_snapshot(cold, &observed);
        assert(result.context == PROTECTOR_UI_LOADING && !result.map_actions && !observed);
    }
    ProtectorUIContextSnapshot title = {PROTECTOR_UI_TITLE, 0};
    assert(protector_ui_context_startup_snapshot(title, &observed).context == PROTECTOR_UI_TITLE);
    assert(observed);
    assert(protector_ui_context_startup_snapshot(cold, &observed).context == PROTECTOR_UI_GAMEPLAY);
    ProtectorUIContextSnapshot map = {PROTECTOR_UI_MAP, PROTECTOR_UI_MAP_REPLAY};
    assert(protector_ui_context_startup_snapshot(map, &observed).map_actions == PROTECTOR_UI_MAP_REPLAY);
    observed = false; /* A new view/session must not inherit the old latch. */
    assert(protector_ui_context_startup_snapshot(cold, &observed).context == PROTECTOR_UI_LOADING);
    ProtectorUIContextSnapshot film = {PROTECTOR_UI_CINEMATIC, 0};
    assert(protector_ui_context_startup_snapshot(film, &observed).context == PROTECTOR_UI_CINEMATIC);
    assert(protector_ui_context_startup_snapshot(cold, NULL).context == PROTECTOR_UI_GAMEPLAY);
    tracker_checks();
    if (argc > 1) {
        size_t checked = 0;
        for (int i = 1; i < argc; ++i) checked += source_checks(argv[i]);
        if (argc == 14) assert(checked == 56);
        printf("ui_context_tests: %zu relocated anchors matched; mutation, wrong package/IP/key rejected without CPU changes\n", checked);
    } else puts("ui_context_tests: lifecycle, blinking, pause, expiry, reuse and publication passed");
    return 0;
}
