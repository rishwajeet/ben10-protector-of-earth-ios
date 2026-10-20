#include "protector/cinematic.h"
#include "protector/live_gx.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

enum { SDA = 0x80290000u, PATH = 0x80300000u, HANDLE = 0x80400000u };
static unsigned opening_calls;
static ProtectorCinematicOpening received_opening;
static void receive_opening(ProtectorCinematicOpening opening, void* user_data) {
    assert(user_data == &opening_calls);
    ++opening_calls;
    received_opening = opening;
}
static void put(CPUState* cpu, u32 address, u32 value) {
    u8* p = cpu->ram + address - GC_RAM_BASE;
    p[0] = value >> 24; p[1] = value >> 16; p[2] = value >> 8; p[3] = value;
}
static void fixture(CPUState* cpu, const char* name) {
    cpu->lr = 0x800BB1C8u;
    cpu->gpr[3] = PATH; cpu->gpr[4] = 0x1400; cpu->gpr[13] = SDA;
    memset(cpu->ram + PATH - GC_RAM_BASE, 0, 128);
    memcpy(cpu->ram + PATH - GC_RAM_BASE, name, strlen(name) + 1);
    put(cpu, SDA - 17800, 0);
    const u32 fields[] = {640, 480, 2245, 102, 101, 10000000, 333333};
    for (u32 i = 0; i < 7; ++i) put(cpu, HANDLE + i * 4, fields[i]);
    put(cpu, HANDLE + 28, 0); put(cpu, HANDLE + 724, 101);
}
static ProtectorCinematicTracker begin(CPUState* cpu) {
    ProtectorCinematicTracker tracker = {0};
    assert(protector_cinematic_observe_open(&tracker, cpu));
    put(cpu, SDA - 17800, HANDLE);
    return tracker;
}
int main(int argc, char** argv) {
    CPUState cpu = {0};
    assert(protector_cpu_init(&cpu));
    size_t count = 0;
    const ProtectorCinematicSourceWord* words = protector_cinematic_source_words(&count);
    assert(count == 16);
    if (argc == 2) {
        ProtectorDolInfo info; char error[256];
        assert(protector_load_dol(&cpu, argv[1], &info, error, sizeof(error)));
        assert(protector_cinematic_source_valid(&cpu));
        puts("Cinematic anchors match the supplied original executable.");
    } else {
        for (size_t i = 0; i < count; ++i) put(&cpu, words[i].address, words[i].value);
    }
    for (size_t i = 0; i < count; ++i) {
        put(&cpu, words[i].address, words[i].value ^ 1);
        assert(!protector_cinematic_source_valid(&cpu));
        put(&cpu, words[i].address, words[i].value);
    }
    const char* valid[] = {"Movies/11_intro.bik", "/Movies/11_intro.bik", "\\Movies\\11_intro.bik",
        "11_intro.bik", "movies/55_outro_B.bik", "Movies/Arcade_Background.bik"};
    for (size_t i = 0; i < sizeof(valid)/sizeof(valid[0]); ++i) {
        fixture(&cpu, valid[i]);
        ProtectorCinematicTracker tracker = {0};
        const CPUState before = cpu;
        assert(protector_cinematic_observe_open(&tracker, &cpu));
        assert(!memcmp(&before, &cpu, sizeof(cpu)));
        assert(!protector_cinematic_observe_frame(&tracker, &cpu, 100).active);
        put(&cpu, SDA - 17800, HANDLE);
        CPUState saved = cpu;
        const u32 memory_hash = mem_read32(&cpu, HANDLE + 16); cpu = saved;
        ProtectorCinematicFrame frame = protector_cinematic_observe_frame(&tracker, &cpu, 101);
        assert(frame.active && frame.presentation_frame == 101 && frame.open_serial == 1);
        assert(frame.decoded_frame_one_based == 101 && frame.next_frame_one_based == 102);
        assert(frame.width == 640 && frame.height == 480 && frame.frame_count == 2245);
        assert(frame.rate_numerator == 10000000 && frame.rate_denominator == 333333);
        assert(!memcmp(&saved, &cpu, sizeof(cpu)));
        assert(mem_read32(&cpu, HANDLE + 16) == memory_hash); cpu = saved;
        ProtectorCinematicFrame held = protector_cinematic_observe_frame(&tracker, &cpu, 102);
        assert(held.decoded_frame_one_based == frame.decoded_frame_one_based);
        put(&cpu, HANDLE + 12, 2245); put(&cpu, HANDLE + 16, 2245); put(&cpu, HANDLE + 724, 2245);
        assert(protector_cinematic_observe_frame(&tracker, &cpu, 103).decoded_frame_one_based == 2245);
        put(&cpu, SDA - 17800, 0);
        assert(!protector_cinematic_observe_frame(&tracker, &cpu, 104).active);
        put(&cpu, SDA - 17800, HANDLE); /* closed handles cannot reappear without an observed open */
        assert(!protector_cinematic_observe_frame(&tracker, &cpu, 105).active);
        protector_live_gx_set_cinematic_frame(frame);
        ProtectorCinematicFrame readback = protector_live_gx_cinematic_frame();
        assert(!memcmp(&readback, &frame, sizeof(frame)));
    }
    const char* bad[] = {"", "../11_intro.bik", "/private/movie.bik", "Movies/../11_intro.bik",
        "Movies/11 intro.bik", "Movies/11_intro.mp4", "Movies/11_intro.bik/evil", "Movies/.bik"};
    for (size_t i = 0; i < sizeof(bad)/sizeof(bad[0]); ++i) {
        fixture(&cpu, bad[i]); ProtectorCinematicTracker t = {.pending = true};
        assert(!protector_cinematic_observe_open(&t, &cpu) && !t.pending);
    }
    fixture(&cpu, "11_intro.bik");
    ProtectorCinematicTracker t = {0};
    cpu.lr ^= 4; assert(!protector_cinematic_observe_open(&t, &cpu)); cpu.lr ^= 4;
    cpu.gpr[4] ^= 1; assert(!protector_cinematic_observe_open(&t, &cpu)); cpu.gpr[4] ^= 1;
    cpu.gpr[3] = UINT32_MAX - 3; assert(!protector_cinematic_observe_open(&t, &cpu));
    fixture(&cpu, "11_intro.bik"); put(&cpu, SDA - 17800, HANDLE);
    assert(!protector_cinematic_observe_open(&t, &cpu));
    const u32 bad_fields[][2] = {{0,0},{0,7681},{4,0},{4,4801},{8,0},{8,1000001},
        {12,0},{12,2246},{16,2246},{20,0},{20,40000001},{24,0},{24,10000001},{28,1},{724,100}};
    for (size_t i = 0; i < sizeof(bad_fields)/sizeof(bad_fields[0]); ++i) {
        fixture(&cpu, "11_intro.bik"); t = begin(&cpu);
        put(&cpu, HANDLE + bad_fields[i][0], bad_fields[i][1]);
        assert(!protector_cinematic_observe_frame(&t, &cpu, 1).active && !t.pending);
    }
    const u32 bad_handles[] = {HANDLE + 1, 0xffffffffu, GC_RAM_BASE + cpu.ram_size - 4, 0xcc000000};
    for (size_t i = 0; i < sizeof(bad_handles)/sizeof(bad_handles[0]); ++i) {
        fixture(&cpu, "11_intro.bik"); t = begin(&cpu);
        put(&cpu, SDA - 17800, bad_handles[i]);
        assert(!protector_cinematic_observe_frame(&t, &cpu, 1).active);
    }
    fixture(&cpu, "11_intro.bik"); t = begin(&cpu);
    put(&cpu, HANDLE + 12, 1); put(&cpu, HANDLE + 16, 0); put(&cpu, HANDLE + 724, 0);
    assert(!protector_cinematic_observe_frame(&t, &cpu, 1).active && t.pending);
    put(&cpu, HANDLE + 16, 1); put(&cpu, HANDLE + 724, 1);
    assert(protector_cinematic_observe_frame(&t, &cpu, 2).active);
    put(&cpu, SDA - 17800, HANDLE + 1024);
    assert(!protector_cinematic_observe_frame(&t, &cpu, 3).active && !t.pending);
    // A logo tap requests only this observed opening, and uses the ordinary
    // completion branch. Stale requests and changed source fail closed.
    fixture(&cpu, "CN.bik"); t = begin(&cpu);
    ProtectorCinematicFrame logo = protector_cinematic_observe_frame(&t,&cpu,10);
    assert(protector_cinematic_is_opening_logo(&logo));
    put(&cpu,0x800BB8B8u,0x2c000000u);
    cpu.gpr[0]=1;
    assert(protector_cinematic_request_logo_skip(&logo));
    assert(!protector_cinematic_apply_logo_skip(&t,&cpu,0x800BB8BCu));
    assert(protector_cinematic_apply_logo_skip(&t,&cpu,0x800BB8B8u));
    assert(cpu.gpr[0]==0);
    assert(!protector_cinematic_apply_logo_skip(&t,&cpu,0x800BB8B8u));
    assert(protector_cinematic_request_logo_skip(&logo));
    ++t.open_serial; cpu.gpr[0]=1;
    assert(!protector_cinematic_apply_logo_skip(&t,&cpu,0x800BB8B8u));
    assert(cpu.gpr[0]==1); --t.open_serial;
    assert(protector_cinematic_request_logo_skip(&logo));
    put(&cpu,0x800BB8B8u,0x2c000001u);
    assert(!protector_cinematic_apply_logo_skip(&t,&cpu,0x800BB8B8u));
    put(&cpu,0x800BB8B8u,0x2c000000u);
    assert(protector_cinematic_request_logo_skip(&logo));
    protector_cinematic_clear_logo_skip();
    assert(!protector_cinematic_apply_logo_skip(&t,&cpu,0x800BB8B8u));
    fixture(&cpu,"11_intro.bik"); t=begin(&cpu);
    logo=protector_cinematic_observe_frame(&t,&cpu,11);
    assert(!protector_cinematic_is_opening_logo(&logo));
    assert(!protector_cinematic_request_logo_skip(&logo));
    assert(protector_cinematic_can_skip(&logo));
    assert(protector_cinematic_request_skip(&logo));
    put(&cpu,0x800BB8B8u,0x2c000000u); cpu.gpr[0]=1;
    assert(protector_cinematic_apply_logo_skip(&t,&cpu,0x800BB8B8u));
    assert(cpu.gpr[0]==0);
    const char* skippable[]={"55_outro_B.bik","25_outro.bik","HVS_Kid_Intro.bik","credits.bik"};
    for(size_t i=0;i<sizeof(skippable)/sizeof(skippable[0]);++i) {
        fixture(&cpu,skippable[i]); t=begin(&cpu);
        logo=protector_cinematic_observe_frame(&t,&cpu,12+i);
        assert(protector_cinematic_can_skip(&logo));
    }
    const char* not_story[]={"Arcade_Background.bik","heatblast.bik","66_intro.bik","11_intro.mp4","","../11_intro.bik"};
    for(size_t i=0;i<sizeof(not_story)/sizeof(not_story[0]);++i) {
        snprintf(logo.movie,sizeof(logo.movie),"%s",not_story[i]);
        assert(!protector_cinematic_can_skip(&logo));
        assert(!protector_cinematic_request_skip(&logo));
    }
    memset(logo.movie,'a',sizeof(logo.movie));
    assert(!protector_cinematic_can_skip(&logo));
    ProtectorCinematicOpening opening = {.movie = "11_intro.bik", .open_serial = 27};
    protector_live_gx_prepare_cinematic(opening);
    assert(opening_calls == 0);
    protector_live_gx_set_cinematic_open_sink(receive_opening, &opening_calls);
    protector_live_gx_prepare_cinematic(opening);
    assert(opening_calls == 1 && received_opening.open_serial == 27);
    assert(!strcmp(received_opening.movie, "11_intro.bik"));
    ProtectorCinematicOpening invalid = opening;
    invalid.open_serial = 0; protector_live_gx_prepare_cinematic(invalid);
    invalid = opening; invalid.movie[0] = 0; protector_live_gx_prepare_cinematic(invalid);
    memset(invalid.movie, 'a', sizeof(invalid.movie)); protector_live_gx_prepare_cinematic(invalid);
    assert(opening_calls == 1);
    protector_live_gx_request_stop(); protector_live_gx_prepare_cinematic(opening);
    assert(opening_calls == 1);
    // Clearing the GX sink also revokes its movie callback and context.
    protector_live_gx_set_sink(NULL, NULL);
    protector_live_gx_prepare_cinematic(opening);
    assert(opening_calls == 1 && !protector_live_gx_stop_requested());
    protector_cpu_destroy(&cpu);
    puts("Cinematic observer tests passed (passive source timing; no movie replacement).");
    return 0;
}
