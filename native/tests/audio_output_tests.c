#include "protector/audio_output.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    static int16_t stereo[16384 * 2];
    static float left[16384], right[16384];
    for (unsigned i=0;i<16384;++i) { stereo[i*2]=16384; stereo[i*2+1]=-16384; }
    protector_audio_output_reset();
    protector_audio_output_push(stereo,96);
    assert(protector_audio_output_pull(left,right,96)==0); // disabled by default
    for (unsigned i=0;i<96;++i) assert(left[i]==0 && right[i]==0);
    protector_audio_output_enable(true);
    // Priming: silence, not an underrun, until a 1024-frame cushion exists.
    protector_audio_output_push(stereo,96);
    assert(protector_audio_output_pull(left,right,96)==0 && protector_audio_output_underrun()==0);
    protector_audio_output_push(stereo,1024);
    assert(protector_audio_output_pull(left,right,96)==96);
    assert(left[0]>0 && left[0]<0.05f && right[0]<0 && right[0]>-0.05f); // fade-in, no step
    assert(left[95]==0.5f && right[95]==-0.5f);
    assert(protector_audio_output_pull(left,right,1000)==1000);
    for (unsigned i=0;i<1000;++i) assert(left[i]==0.5f && right[i]==-0.5f);
    // Underrun: the remaining 24 frames fade out instead of cutting off.
    assert(protector_audio_output_pull(left,right,96)==24);
    assert(protector_audio_output_underrun()==72);
    assert(left[0]<0.5f && left[23]<0.05f && left[23]>0);
    for (unsigned i=24;i<96;++i) assert(left[i]==0 && right[i]==0);
    // After an underrun the reader re-primes rather than clicking on every chunk.
    protector_audio_output_push(stereo,96);
    assert(protector_audio_output_pull(left,right,96)==0 && protector_audio_output_underrun()==72);
    // Capacity: 16384 frames; overflow drops the newest frames only.
    protector_audio_output_push(stereo,16384);
    assert(protector_audio_output_dropped()==96);
    assert(protector_audio_output_pull(left,right,16384)==16384);
    protector_audio_output_push(stereo,2048);
    protector_audio_output_enable(false);
    protector_audio_output_enable(true);
    assert(protector_audio_output_pull(left,right,96)==0); // stale pause audio discarded
    protector_audio_output_push(stereo,1024);
    assert(protector_audio_output_pull(left,right,96)==96);
    protector_audio_output_enable(false);
    puts("audio output transport: silent default, priming, fades, bounds, underrun and pause pass");
    return 0;
}
