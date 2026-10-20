#ifndef PROTECTOR_FULL_STATE_H
#define PROTECTOR_FULL_STATE_H

#include "protector/cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PROTECTOR_FULL_STATE_GAME_ID_CAPACITY 8u
#define PROTECTOR_FULL_STATE_ANCHOR_CAPACITY 33u
#define PROTECTOR_SHA256_SIZE 32u

typedef struct ProtectorFullStateMetadata {
    char game_id[PROTECTOR_FULL_STATE_GAME_ID_CAPACITY];
    char anchor[PROTECTOR_FULL_STATE_ANCHOR_CAPACITY];
    u32 checkpoint;
    u32 next_input_sample;
    u32 saved_pc;
    u64 source_core_ticks;
    u8 source_state_sha256[PROTECTOR_SHA256_SIZE];
    u8 cpu_sha256[PROTECTOR_SHA256_SIZE];
    u8 mem1_sha256[PROTECTOR_SHA256_SIZE];
    u8 mem2_sha256[PROTECTOR_SHA256_SIZE];
} ProtectorFullStateMetadata;

bool protector_load_full_state(
    CPUState* cpu,
    const char* path,
    ProtectorFullStateMetadata* metadata,
    char* error,
    size_t error_capacity
);

#ifdef __cplusplus
}
#endif

#endif
