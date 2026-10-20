#ifndef PROTECTOR_LIVE_GX_H
#define PROTECTOR_LIVE_GX_H

#include "protector/cpu.h"
#include "protector/cinematic.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum ProtectorLiveGXResult {
    PROTECTOR_LIVE_GX_CONTINUE = 0,
    PROTECTOR_LIVE_GX_COMPLETE = 1,
    PROTECTOR_LIVE_GX_ERROR = 2,
} ProtectorLiveGXResult;

typedef ProtectorLiveGXResult (*ProtectorLiveGXSink)(
    u32 frame_index,
    const u8* fifo,
    size_t fifo_size,
    CPUState* cpu,
    void* user_data
);
typedef void (*ProtectorLiveCinematicOpenSink)(ProtectorCinematicOpening opening, void* user_data);

void protector_live_gx_set_sink(
    ProtectorLiveGXSink sink,
    void* user_data
);
bool protector_live_gx_has_sink(void);
/* Advisory metadata, set/read on the submitting worker only. The sink must
 * copy it before returning; it is not a second playback clock. */
void protector_live_gx_set_cinematic_frame(ProtectorCinematicFrame frame);
ProtectorCinematicFrame protector_live_gx_cinematic_frame(void);
/* Source-admitted action notation on this exact submitted frame. Zero scheme
 * means no replacement. Copy into decoded draws so retained frames stay true. */
typedef struct ProtectorLiveComboFrame { u32 presentation_frame, scheme; } ProtectorLiveComboFrame;
void protector_live_gx_set_combo_frame(ProtectorLiveComboFrame frame);
ProtectorLiveComboFrame protector_live_gx_combo_frame(void);
typedef struct ProtectorLiveInteractionFrame { u32 presentation_frame, prompts; } ProtectorLiveInteractionFrame;
void protector_live_gx_set_interaction_frame(ProtectorLiveInteractionFrame frame);
ProtectorLiveInteractionFrame protector_live_gx_interaction_frame(void);
/* Upgrade has distinct ownership even when no notation or move is offered. */
typedef struct ProtectorLiveUpgradeFrame { u32 presentation_frame, scheme; bool active, ready; } ProtectorLiveUpgradeFrame;
void protector_live_gx_set_upgrade_frame(ProtectorLiveUpgradeFrame frame);
ProtectorLiveUpgradeFrame protector_live_gx_upgrade_frame(void);
/* Set/reset while stopped, like the GX sink. Delivery runs on the submitting
 * worker and must only enqueue preparation, never wait for replacement media. */
void protector_live_gx_set_cinematic_open_sink(ProtectorLiveCinematicOpenSink sink, void* user_data);
void protector_live_gx_prepare_cinematic(ProtectorCinematicOpening opening);
/* Set/reset the sink only while the runtime is stopped. Stop requests are
 * thread-safe and are also checked between translated blocks. */
void protector_live_gx_request_stop(void);
bool protector_live_gx_stop_requested(void);
ProtectorLiveGXResult protector_live_gx_submit(
    u32 frame_index,
    const u8* fifo,
    size_t fifo_size,
    CPUState* cpu
);

#ifdef __cplusplus
}
#endif

#endif
