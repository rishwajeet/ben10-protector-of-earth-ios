#ifndef PROTECTOR_AX_H
#define PROTECTOR_AX_H

#include "protector/cpu.h"

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PROTECTOR_AX_VOICE_COUNT 96u
#define PROTECTOR_AX_PB_SIZE 0x140u
#define PROTECTOR_AX_SAMPLES_PER_FRAME 96u

bool protector_ax_find_dsp_pb_pool(
    CPUState* cpu, u32 address_hint, u32* pool_address
);

u32 protector_ax_source_sample_count(
    u16 src_select,
    u32 ratio,
    u16* current_fraction,
    u16 output_samples
);

u32 protector_ax_advance_sample_address(
    u16 format,
    u16 loop_flag,
    u32 loop_address,
    u32 end_address,
    u32 current_address,
    u32 source_samples,
    bool* running
);

u32 protector_ax_process_frame(
    CPUState* cpu,
    u32 dsp_pb_pool,
    u16 output_samples
);

#ifdef __cplusplus
}
#endif

#endif
