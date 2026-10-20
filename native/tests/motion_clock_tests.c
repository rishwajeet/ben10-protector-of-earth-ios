#include "protector/motion_clock.h"
#include "protector/motion_identity.h"
#include "protector/guest_pacer.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static void word(u8* p, u32 value) {
    p[0]=value>>24; p[1]=value>>16; p[2]=value>>8; p[3]=value;
}
static void test_source_identity(void) {
    CPUState cpu={0};
    u8 memory[4096]={0}, fifo[32]={0};
    cpu.ram=memory; cpu.ram_size=sizeof(memory);
    const u32 object=GC_RAM_BASE+1024, sp=GC_RAM_BASE;
    cpu.gpr[3]=object; cpu.lr=0x8009ECFC;
    ProtectorMotionIdentity* state=calloc(1,sizeof(*state)); assert(state);
    protector_motion_identity_lifecycle(state,&cpu,0x80072520);
    assert(state->serial==0);
    word(memory,sp+32); word(memory+36,0x8001CCBC);
    word(memory+32,sp+144); word(memory+148,0x8001C7C0);
    word(memory+836,0x8003A9DC); word(memory+88,object);
    word(memory+1024,0x801FF408); word(memory+1340,GC_RAM_BASE+2048);
    cpu.lr=0x800A187C;
    protector_motion_identity_lifecycle(state,&cpu,0x8009E6C0);
    assert(state->serial==1);
    cpu.pc=0x800E9B20; cpu.gpr[1]=sp; cpu.gpr[29]=0x90003000; cpu.gpr[30]=32;
    fifo[8]=0x40; word(fifo+9,cpu.gpr[29]); word(fifo+13,32);
    CPUState before=cpu; u8 memoryBefore[4096]; memcpy(memoryBefore,memory,sizeof(memory));
    protector_motion_identity_fifo(state,&cpu,8,0x40,1);
    assert(state->count==1 && state->calls[0].instance.generation==1);
    assert(!memcmp(&cpu,&before,sizeof(cpu)) && !memcmp(memory,memoryBefore,sizeof(memory)));
    protector_motion_identity_publish(state,&cpu,fifo,sizeof(fifo));
    ProtectorMotionInstance tag=protector_motion_identity_lookup(&cpu,fifo,sizeof(fifo),8,0x90003000,32);
    assert(tag.object==object && tag.generation==1 && tag.binding==GC_RAM_BASE+2048);
    assert(!protector_motion_identity_lookup(&before,fifo,sizeof(fifo),8,0x90003000,32).generation);
    assert(!protector_motion_identity_lookup(&cpu,fifo,sizeof(fifo)-1,8,0x90003000,32).generation);
    assert(!protector_motion_identity_lookup(&cpu,fifo,sizeof(fifo),9,0x90003000,32).generation);
    assert(!protector_motion_identity_lookup(&cpu,fifo,sizeof(fifo),8,0x90003001,32).generation);
    assert(!protector_motion_identity_lookup(&cpu,fifo,sizeof(fifo),8,0x90003000,31).generation);
    protector_motion_identity_publish(NULL,NULL,NULL,0);
    assert(!protector_motion_identity_lookup(&cpu,fifo,sizeof(fifo),8,0x90003000,32).generation);
    // The original helper's source table, descriptor and output ranges qualify
    // a changing skin buffer. Invalid metadata drops skin admission, not the
    // independently proven actor identity; neither guest state nor RAM changes.
    {
        const u32 group=GC_RAM_BASE+2048, record=GC_RAM_BASE+2176;
        word(memory+20,record); word(memory+2048+28,record); word(memory+2048+36,1);
        memory[2048+44]=3;
        word(memory+2176+4,3); word(memory+2176+12,32); word(memory+2176+16,0x90003000);
        word(memory+2176+20,GC_RAM_BASE+2304); word(memory+2176+24,GC_RAM_BASE+2368);
        word(memory+2176+28,GC_RAM_BASE+2432);
        cpu.gpr[16]=group; cpu.gpr[20]=1; cpu.gpr[21]=group+44; cpu.gpr[26]=0;
        cpu.gpr[25]=GC_RAM_BASE+3072; cpu.gpr[24]=GC_RAM_BASE+3200;
        CPUState skinCPU=cpu; u8 skinRAM[4096]; memcpy(skinRAM,memory,sizeof(memory));
        protector_motion_identity_next_frame(state);
        protector_motion_identity_fifo(state,&cpu,8,0x40,1);
        assert(state->count==1 && state->calls[0].instance.skin.source_draw==record);
        assert(state->calls[0].instance.skin.output_position==GC_RAM_BASE+3072);
        assert(state->calls[0].instance.skin.output_normal==GC_RAM_BASE+3200);
        assert(state->calls[0].instance.skin.source_words[6]==GC_RAM_BASE+2368);
        assert(!memcmp(&cpu,&skinCPU,sizeof(cpu)) && !memcmp(memory,skinRAM,sizeof(memory)));
        const size_t fields[]={20,2048+28,2048+36,2048+44,2176+4,2176+12,2176+16,2176+20,2176+24,2176+28};
        for(size_t i=0;i<sizeof(fields)/sizeof(*fields);++i) {
            u8 saved[4];memcpy(saved,memory+fields[i],4);word(memory+fields[i],0);
            protector_motion_identity_next_frame(state);protector_motion_identity_fifo(state,&cpu,8,0x40,1);
            assert(state->count==1 && state->calls[0].instance.generation==1 && !state->calls[0].instance.skin.source_draw);
            memcpy(memory+fields[i],saved,4);
        }
        const u32 registers[]={16,20,21,24,25,26};
        for(size_t i=0;i<sizeof(registers)/sizeof(*registers);++i) {
            u32 reg=registers[i],saved=cpu.gpr[reg];cpu.gpr[reg]=UINT32_MAX;
            protector_motion_identity_next_frame(state);protector_motion_identity_fifo(state,&cpu,8,0x40,1);
            assert(state->count==1 && !state->calls[0].instance.skin.source_draw);cpu.gpr[reg]=saved;
        }
        // Position-only skinning is legal; rigid draws must never use the path.
        cpu.gpr[24]=0;word(memory+2176+28,0);
        protector_motion_identity_next_frame(state);protector_motion_identity_fifo(state,&cpu,8,0x40,1);
        assert(state->calls[0].instance.skin.source_draw==record && !state->calls[0].instance.skin.output_normal);
        cpu.gpr[25]=0;
        protector_motion_identity_next_frame(state);protector_motion_identity_fifo(state,&cpu,8,0x40,1);
        assert(!state->calls[0].instance.skin.source_draw);
        memcpy(memory,memoryBefore,sizeof(memory));cpu=before;
    }
    protector_motion_identity_next_frame(state);
    // Same address after destruction must never inherit the previous lifetime.
    protector_motion_identity_lifecycle(state,&cpu,0x800723DC);
    protector_motion_identity_fifo(state,&cpu,8,0x40,1); assert(state->count==0);
    cpu.lr=0x8009ECFC;
    protector_motion_identity_lifecycle(state,&cpu,0x80072520);
    protector_motion_identity_fifo(state,&cpu,8,0x40,1); assert(state->count==0);
    cpu.lr=0x800A187C;
    protector_motion_identity_lifecycle(state,&cpu,0x8009E6C0);
    protector_motion_identity_fifo(state,&cpu,8,0x40,1);
    assert(state->count==1 && state->calls[0].instance.generation==2);
    protector_motion_identity_next_frame(state);
    protector_motion_identity_lifecycle(state,&cpu,0x8009E53C); // pool release, no destruction
    protector_motion_identity_fifo(state,&cpu,8,0x40,1); assert(!state->count);
    protector_motion_identity_lifecycle(state,&cpu,0x80039FE8); // rebind must not reactivate a free slot
    protector_motion_identity_fifo(state,&cpu,8,0x40,1); assert(!state->count);
    protector_motion_identity_lifecycle(state,&cpu,0x8009E6C0);
    protector_motion_identity_fifo(state,&cpu,8,0x40,1);
    assert(state->calls[0].instance.generation==3);
    protector_motion_identity_next_frame(state);
    protector_motion_identity_lifecycle(state,&cpu,0x80039FE8); // same-model rebind still changes epoch
    protector_motion_identity_fifo(state,&cpu,8,0x40,1);
    assert(state->calls[0].instance.generation==4);
    protector_motion_identity_next_frame(state);
    // Every independently checked caller/typing field fails closed.
    const size_t checked[]={0,36,32,148,836,88,1024,1340};
    for (size_t i=0; i<sizeof(checked)/sizeof(*checked); ++i) {
        const size_t offset=checked[i]; u8 saved[4]; memcpy(saved,memory+offset,4);
        word(memory+offset,0); protector_motion_identity_fifo(state,&cpu,8,0x40,1);
        assert(state->count==0); memcpy(memory+offset,saved,4);
    }
    cpu.gpr[1]=UINT32_MAX-3; protector_motion_identity_fifo(state,&cpu,8,0x40,1); assert(!state->count);
    cpu.gpr[1]=sp; cpu.pc=0; protector_motion_identity_fifo(state,&cpu,8,0x40,1); assert(!state->count);
    cpu.pc=0x800E9B20; protector_motion_identity_fifo(state,&cpu,8,0x40,4); assert(!state->count);
    protector_motion_identity_fifo(state,&cpu,8,0x41,1); assert(!state->count);
    protector_motion_identity_fifo(state,&cpu,8,0x40,1);
    protector_motion_identity_fifo(state,&cpu,8,0x40,1); assert(state->overflow);
    protector_motion_identity_publish(state,&cpu,fifo,sizeof(fifo));
    assert(!protector_motion_identity_lookup(&cpu,fifo,sizeof(fifo),8,0x90003000,32).generation);
    protector_motion_identity_next_frame(state);
    state->count=2048; protector_motion_identity_fifo(state,&cpu,8,0x40,1); assert(state->overflow);
    protector_motion_identity_next_frame(state);
    cpu.lr=0; protector_motion_identity_lifecycle(state,&cpu,0x80072520);
    protector_motion_identity_fifo(state,&cpu,8,0x40,1); assert(!state->count); // unknown reconstruction
    state->serial=UINT64_MAX; cpu.lr=0x8009ECFC;
    protector_motion_identity_lifecycle(state,&cpu,0x80072520);
    cpu.lr=0x800A187C; protector_motion_identity_lifecycle(state,&cpu,0x8009E6C0);
    protector_motion_identity_fifo(state,&cpu,8,0x40,1); assert(!state->count);
    protector_motion_identity_publish(NULL,NULL,NULL,0); free(state);
    puts("source-instance lifetime, exact FIFO attachment and fail-closed tests passed");
}

int main(void) {
    test_source_identity();
    assert(protector_motion_display_rate(144) == 72);
    assert(protector_motion_display_rate(120) == 60);
    assert(protector_motion_display_rate(60) == 60);
    assert(protector_motion_display_rate(75) == 75);
    assert(protector_motion_display_rate(30) == 30);
    assert(protector_motion_display_rate(0) == 60);
    double interval = 0;
    const u64 ticks = PROTECTOR_WII_TIMEBASE_HZ / 30;
    assert(protector_motion_interval(100, 100 + ticks, 8, 8 + 1.0 / 30.0, &interval));
    assert(fabs(interval - 1.0 / 30.0) < 1e-12);
    assert(protector_motion_fraction(8, interval, 8) == 0);
    assert(fabs(protector_motion_fraction(8, interval, 8 + 1.0 / 60.0) - 0.5) < 1e-12);
    assert(protector_motion_fraction(8, interval, 8.5) == 1); // no extrapolation
    assert(protector_motion_fraction(8, interval, 7) == 1); // no reverse clock
    assert(protector_motion_fraction(8, interval, NAN) == 1);
    assert(protector_motion_fraction(8, NAN, 8) == 1);
    assert(protector_motion_fraction(INFINITY, interval, 8) == 1);
    assert(!protector_motion_interval(100, 100, 8, 8.03, &interval));
    assert(!protector_motion_interval(100, 99, 8, 8.03, &interval));
    assert(!protector_motion_interval(0, ticks, 0, 0.03, &interval));
    assert(!protector_motion_interval(0, ticks, 8, 9, &interval)); // host rebase
    assert(!protector_motion_interval(0, ticks, 8, NAN, &interval));
    assert(!protector_motion_interval(0, PROTECTOR_WII_TIMEBASE_HZ, 8, 9, &interval));
    assert(!protector_motion_interval(0, 1, 8, 8.00001, &interval));
    assert(!protector_motion_interval(0, ticks, 8, 8.03, NULL));
    // Irregular 29.8 Hz source delivery still samples at the actual 60 Hz
    // display times, not an assumed alternating endpoint/midpoint cadence.
    const double irregular = 0.033557;
    const u64 irregular_ticks = (u64)(irregular * PROTECTOR_WII_TIMEBASE_HZ);
    assert(protector_motion_interval(0, irregular_ticks, 8, 8 + irregular, &interval));
    const double phase = protector_motion_fraction(8, interval, 8 + 1.0 / 60.0);
    assert(phase > 0.49 && phase < 0.5);
    ProtectorPresentationPacing pacing;
    protector_pacing_init(&pacing);
    assert(pacing.rate == 60);
    assert(protector_pacing_update(&pacing, 0.0, 0.020, 0) == 60);  /* one slow frame: hold */
    assert(protector_pacing_update(&pacing, 0.5, 0.020, 0) == 60);
    assert(protector_pacing_update(&pacing, 1.0, 0.020, 0) == 30);  /* sustained: drop */
    assert(protector_pacing_update(&pacing, 1.5, 0.012, 0) == 30);  /* in band: hold */
    assert(protector_pacing_update(&pacing, 2.0, 0.008, 0) == 30);
    assert(protector_pacing_update(&pacing, 4.0, 0.008, 0) == 30);
    assert(protector_pacing_update(&pacing, 5.9, 0.020, 0) == 30);  /* spike resets headroom */
    assert(protector_pacing_update(&pacing, 6.0, 0.008, 0) == 30);
    assert(protector_pacing_update(&pacing, 10.0, 0.008, 0) == 60); /* sustained headroom */
    assert(protector_pacing_update(&pacing, 10.1, 0.008, 2) == 30); /* serious thermal: drop now */
    assert(protector_pacing_update(&pacing, 20.0, 0.008, 1) == 30);
    assert(protector_pacing_update(&pacing, 24.0, 0.008, 1) == 60);
    assert(protector_pacing_update(&pacing, 24.1, NAN, 0) == 60);
    assert(protector_pacing_update(NULL, 1, 1, 3) == 60);
    pacing.rate = 45; /* corrupted state reinitialises */
    assert(protector_pacing_update(&pacing, 30.0, 0.012, 0) == 60);
    puts("motion presentation clock tests passed");
    return 0;
}
