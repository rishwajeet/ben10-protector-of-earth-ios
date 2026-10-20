#ifndef PROTECTOR_MOTION_IDENTITY_H
#define PROTECTOR_MOTION_IDENTITY_H

#include "protector/cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Presentation-only RBNEG9 evidence. No guest writes or guessed nearest
 * object. Track construction plus pool activation/release and model rebinding;
 * a preconstructed pool slot is not yet a live actor. */
typedef struct ProtectorMotionSkin {
    u32 source_draw, output_position, output_normal;
    /* Exact immutable 56-byte draw record and 16-byte source descriptor.
     * Filled only for the verified original CPU-skinning helper path. */
    u32 source_words[18];
} ProtectorMotionSkin;
typedef struct ProtectorMotionInstance {
    u64 generation;
    u32 object, binding;
    ProtectorMotionSkin skin;
} ProtectorMotionInstance;
typedef struct ProtectorMotionCall {
    size_t fifo_offset;
    u32 display_list, length;
    ProtectorMotionInstance instance;
} ProtectorMotionCall;
enum { PROTECTOR_MOTION_OWNER_LIMIT = 4096, PROTECTOR_MOTION_CALL_LIMIT = 2048 };
typedef struct ProtectorMotionIdentity {
    u64 serial;
    struct { u32 object; u64 generation; } owners[PROTECTOR_MOTION_OWNER_LIMIT];
    ProtectorMotionCall calls[PROTECTOR_MOTION_CALL_LIMIT];
    size_t count;
    bool overflow;
} ProtectorMotionIdentity;

void protector_motion_identity_lifecycle(ProtectorMotionIdentity*, const CPUState*, u32 address);
void protector_motion_identity_fifo(ProtectorMotionIdentity*, const CPUState*, size_t offset, u64 value, u8 size);
void protector_motion_identity_next_frame(ProtectorMotionIdentity*);
/* Borrowed only during the synchronous GX sink call, then explicitly cleared.
 * Exact stream/CPU/offset/address/length admission prevents stale attachment. */
void protector_motion_identity_publish(const ProtectorMotionIdentity*, const CPUState*, const u8*, size_t);
ProtectorMotionInstance protector_motion_identity_lookup(const CPUState*, const u8*, size_t,
                                                        size_t offset, u32 address, u32 length);

#ifdef __cplusplus
}
#endif
#endif
