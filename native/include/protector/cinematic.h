#ifndef PROTECTOR_CINEMATIC_H
#define PROTECTOR_CINEMATIC_H
#include "protector/cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Passive RBNEG9 movie observer. Guest Bink owns decoding, time and Skip.
 * This does not start a second clock, change memory or authorize a crop. */
typedef struct ProtectorCinematicFrame {
    char movie[96]; /* basename, not a host path */
    u32 handle, width, height, frame_count;
    u32 next_frame_one_based, decoded_frame_one_based;
    u32 rate_numerator, rate_denominator;
    u64 presentation_frame, open_serial;
    bool active;
} ProtectorCinematicFrame;

typedef struct ProtectorCinematicTracker {
    char movie[96];
    u32 small_data_base, bound_handle;
    u64 open_serial;
    bool pending;
} ProtectorCinematicTracker;

/* Advisory preparation signal from the verified source BinkOpen boundary.
 * It is not a decoded frame and can never authorize a replacement draw. */
typedef struct ProtectorCinematicOpening {
    char movie[96];
    u64 open_serial;
} ProtectorCinematicOpening;

typedef struct ProtectorCinematicSourceWord { u32 address, value; } ProtectorCinematicSourceWord;
const ProtectorCinematicSourceWord* protector_cinematic_source_words(size_t* count);
bool protector_cinematic_source_valid(const CPUState* cpu);
/* Call only at BinkOpen, before translated execution; caller/flags are checked. */
bool protector_cinematic_observe_open(ProtectorCinematicTracker* tracker, const CPUState* cpu);
/* Call at a completed guest GX frame. Inactive is an explicit empty result. */
ProtectorCinematicFrame protector_cinematic_observe_frame(ProtectorCinematicTracker* tracker,
    const CPUState* cpu, u64 presentation_frame);

/* Explicit host request, bound to one observed movie serial. The worker takes the
 * original movie-completion branch; no simulated Confirm can leak to a menu. */
bool protector_cinematic_is_opening_logo(const ProtectorCinematicFrame* frame);
bool protector_cinematic_can_skip(const ProtectorCinematicFrame* frame);
bool protector_cinematic_request_skip(const ProtectorCinematicFrame* frame);
/* Legacy logo-only entry point remains narrower than story Skip. */
bool protector_cinematic_request_logo_skip(const ProtectorCinematicFrame* frame);
void protector_cinematic_clear_logo_skip(void);
bool protector_cinematic_apply_logo_skip(ProtectorCinematicTracker* tracker,
    CPUState* cpu, u32 address);

#ifdef __cplusplus
}
#endif
#endif
