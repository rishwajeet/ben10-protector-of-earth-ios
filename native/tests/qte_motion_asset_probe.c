/* Controlled input boundary: original script and translated VM, no gameplay,
 * UI, save files, scheduler, sound device or source-script modifications. */
#include "protector/cpu.h"
#include "protector/platform.h"
#include "protector/live_input.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
extern void func_800A6720(CPUState*);
#define SCRIPT 0x90000000u
#define VARS 0x90400000u
#define CONTEXT 0x80400000u
static bool returned;
static unsigned instructions;
static bool stop_at_return(CPUState* cpu, u32 address) {
    assert(address == 0x800A74E4u);
    assert(++instructions < 256);
    u32 ip=cpu->gpr[26];
    assert(ip >= SCRIPT && ip < SCRIPT+0xfc);
    if (mem_read32(cpu, ip) == 0x88ffffffu) {returned=true;return true;}
    return false;
}
static void put_float(CPUState* cpu,u32 address,float value) {
    u32 bits;memcpy(&bits,&value,4);mem_write32(cpu,address,bits);
}
static float get_float(CPUState* cpu,u32 address) {
    u32 bits=mem_read32(cpu,address);float value;memcpy(&value,&bits,4);return value;
}
static unsigned predicate(CPUState* cpu,float remote_y,float extension_y) {
    put_float(cpu,VARS+1024+0x4a*4,remote_y);
    put_float(cpu,VARS+1024+0x47*4,extension_y);
    cpu->pc=0x800A74B4u;cpu->gpr[26]=SCRIPT;
    returned=false;instructions=0;
    for(unsigned i=0;!returned && i<10000;i++) {
        cpu->downcount=100000;
        assert(cpu->pc>=0x800A6720u && cpu->pc<0x800AA720u);
        func_800A6720(cpu);
        assert(cpu->stop_reason==PROTECTOR_STOP_NONE);
    }
    assert(returned);
    unsigned result=mem_read32(cpu,VARS+1024+0x4c*4);
    assert(result<=1);return result;
}
int main(int argc,char** argv) {
    assert(argc==3);
    CPUState cpu;assert(protector_cpu_init(&cpu));
    ProtectorDolInfo dol={0};char error[256]={0};
    assert(protector_load_dol(&cpu,argv[1],&dol,error,sizeof(error)));
    FILE* f=fopen(argv[2],"rb");assert(f);unsigned char script[0xfc];
    assert(fread(script,1,sizeof(script),f)==sizeof(script));assert(fgetc(f)==EOF);fclose(f);
    for(unsigned i=0;i<sizeof(script);i++)mem_write8(&cpu,SCRIPT+i,script[i]);
    assert(mem_read32(&cpu,SCRIPT)==0x82010000u);
    cpu.host_call=stop_at_return;cpu.msr=0x2000;
    cpu.gpr[1]=0x817FF000u;cpu.gpr[2]=0x80316E20u;
    cpu.gpr[24]=CONTEXT;mem_write32(&cpu,CONTEXT+0x1d8,VARS);
    mem_write32(&cpu,cpu.gpr[1]+0x18,0x43300000u);
    mem_write32(&cpu,cpu.gpr[1]+0x20,0x43300000u);
    for(unsigned scenario=0;scenario<4;scenario++) {
        put_float(&cpu,VARS+0x7f*4,0);put_float(&cpu,VARS+0x7e*4,0);
        protector_live_input_enable(true);
        protector_live_input_motion(PROTECTOR_MOTION_WIIMOTE|PROTECTOR_MOTION_NUNCHUK);
        unsigned accepted=0;
        for(unsigned i=0;i<36;i++) {
            ProtectorLiveInputSample sample;assert(protector_live_input_sample(&sample));
            float a=sample.wiimote_motion[1],b=sample.nunchuk_motion[1];
            if(scenario==1) {a=sample.wiimote_motion[0];b=-sample.nunchuk_motion[0];}
            if(scenario==2) {a=sample.wiimote_motion[0];b=sample.nunchuk_motion[0];}
            if(scenario==3) {a=0;b=0;}
            accepted+=predicate(&cpu,a,b);
        }
        printf("scenario=%u accepted=%u previous_remote_y=%g previous_extension_y=%g\n",scenario,accepted,get_float(&cpu,VARS+0x7f*4),get_float(&cpu,VARS+0x7e*4));
        assert(accepted == (scenario < 2 ? 6u : 0u));
    }
    unsigned staggered_passes=0, single_channel_passes=0;
    for(unsigned first=0;first<2;first++) {
        for(unsigned delay=0;delay<12;delay++) {
            put_float(&cpu,VARS+0x7f*4,0);put_float(&cpu,VARS+0x7e*4,0);
            protector_live_input_enable(true);
            protector_live_input_motion(first ? PROTECTOR_MOTION_NUNCHUK : PROTECTOR_MOTION_WIIMOTE);
            ProtectorLiveInputSample sample;
            for(unsigned i=0;i<delay;i++)assert(protector_live_input_sample(&sample));
            protector_live_input_motion(PROTECTOR_MOTION_WIIMOTE|PROTECTOR_MOTION_NUNCHUK);
            unsigned accepted=0;
            for(unsigned i=0;i<36;i++) {
                assert(protector_live_input_sample(&sample));
                accepted+=predicate(&cpu,sample.wiimote_motion[1],sample.nunchuk_motion[1]);
            }
            /* An already-active trigger can begin part-way through a lobe.
             * This finite 36-poll interval then includes one extra crossing. */
            assert(accepted>=6 && accepted<=7);staggered_passes++;
            protector_live_input_cancel();
            for(unsigned i=0;i<24;i++) {
                assert(protector_live_input_sample(&sample));
                assert(predicate(&cpu,sample.wiimote_motion[1],sample.nunchuk_motion[1])==0);
            }
        }
        put_float(&cpu,VARS+0x7f*4,0);put_float(&cpu,VARS+0x7e*4,0);
        protector_live_input_enable(true);
        protector_live_input_motion(first ? PROTECTOR_MOTION_NUNCHUK : PROTECTOR_MOTION_WIIMOTE);
        for(unsigned i=0;i<36;i++) {
            ProtectorLiveInputSample sample;assert(protector_live_input_sample(&sample));
            assert(predicate(&cpu,sample.wiimote_motion[1],sample.nunchuk_motion[1])==0);
        }
        single_channel_passes++;
    }
    printf("staggered_passes=%u cancellation_passes=%u single_channel_negative_controls=%u\n",staggered_passes,staggered_passes,single_channel_passes);
    protector_cpu_destroy(&cpu);return 0;
}
