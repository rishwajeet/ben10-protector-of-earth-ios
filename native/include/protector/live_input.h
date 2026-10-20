#ifndef PROTECTOR_LIVE_INPUT_H
#define PROTECTOR_LIVE_INPUT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Title-facing Nintendo KPAD masks, not libogc's byte-swapped WPAD masks.
 * Confirmed A in the source-bound title replay; layout also documented at
 * github.com/kiwi515/ogws/blob/master/include/revolution/WPAD/WPAD.h. */
enum {
    PROTECTOR_BUTTON_LEFT = 0x0001,
    PROTECTOR_BUTTON_RIGHT = 0x0002,
    PROTECTOR_BUTTON_DOWN = 0x0004,
    PROTECTOR_BUTTON_UP = 0x0008,
    PROTECTOR_BUTTON_PLUS = 0x0010,
    PROTECTOR_BUTTON_TWO = 0x0100,
    PROTECTOR_BUTTON_ONE = 0x0200,
    PROTECTOR_BUTTON_B = 0x0400,
    PROTECTOR_BUTTON_A = 0x0800,
    PROTECTOR_BUTTON_MINUS = 0x1000,
    PROTECTOR_BUTTON_Z = 0x2000,
    PROTECTOR_BUTTON_C = 0x4000,
    PROTECTOR_BUTTON_HOME = 0x8000,
};

typedef struct ProtectorLiveInputSample {
    uint32_t hold;
    uint32_t trigger;
    uint32_t release;
    float stick_x;
    float stick_y;
    bool pointer_valid;
    float pointer_x;
    float pointer_y;
    float pointer_dx;
    float pointer_dy;
    /* x/y/z acceleration, magnitude, variation; title-facing KPAD units. */
    float wiimote_motion[5];
    float nunchuk_motion[5];
} ProtectorLiveInputSample;

typedef struct ProtectorLiveInputDiagnostics {
    uint64_t samples;
    uint64_t pointer_samples;
    uint64_t wiimote_motion_samples;
    uint64_t nunchuk_motion_samples;
    uint64_t camera_samples;
    uint64_t camera_trigger_samples;
    ProtectorLiveInputSample last;
} ProtectorLiveInputDiagnostics;

enum {
    PROTECTOR_MOTION_WIIMOTE = 1u,
    PROTECTOR_MOTION_NUNCHUK = 2u,
    PROTECTOR_KPAD_STATUS_SIZE = 132u,
};

/* One process-wide player. Enable/disable only while the runtime is stopped.
 * Updates and sampling may run concurrently. No game memory is accessed here.
 * Edges are latched until sampled, including taps between two KPAD polls. */
void protector_live_input_enable(bool enabled);
bool protector_live_input_enabled(void);
/* Suspend/focus-loss boundary: discard pending taps and neutralize the stick.
 * A button already observed by the guest receives one release sample. */
void protector_live_input_cancel(void);
void protector_live_input_update(uint32_t held, float stick_x, float stick_y);
/* Pointer coordinates are centered [-1,1], positive right/down. A quick touch
 * is retained for one guest poll. Keyboard navigation should clear the pointer
 * explicitly so a stale hover cannot undo a D-pad selection. */
void protector_live_input_pointer(bool valid, float x, float y);
void protector_live_input_clear_pointer(void);
/* Explicit accessibility replacement for shaking the two Wii controllers.
 * It does not read host sensors or alter any original game/QTE rules. */
void protector_live_input_motion(uint32_t held);
/* Map top-left-origin view coordinates through the renderer's 4:3 letterbox.
 * Reject black bars and invalid geometry; leave outputs unchanged on failure. */
bool protector_live_input_map_pointer(float x, float y, float width, float height,
                                     float* pointer_x, float* pointer_y);
/* Widescreen preview keeps the original 4:3 UI inside a letterboxed 16:9
 * presentation. Map that UI region, not the wider scene or the black bars. */
bool protector_live_input_map_pointer_for_presentation(float x, float y,
    float width, float height, bool widescreen, float* pointer_x, float* pointer_y);
/* Native landscape displays use their own aspect. Menus still occupy a centred
 * 4:3 region; the noninteractive re-anchored gameplay HUD has no pointer hits. */
bool protector_live_input_map_pointer_for_aspect(float x, float y,
    float width, float height, float aspect, float* pointer_x, float* pointer_y);
/* Source-identified pointer QTEs place targets in centred whole-screen units
 * [-.5,.5], unlike menu clip coordinates. Select only for admitted QTE draws;
 * this changes host coordinates, never source targets or acceptance rules. */
bool protector_live_input_map_qte_pointer_for_aspect(float x, float y,
    float width, float height, float aspect, float* pointer_x, float* pointer_y);
bool protector_live_input_sample(ProtectorLiveInputSample* sample);
/* Read-only evidence of samples actually delivered, without consuming edges. */
void protector_live_input_diagnostics(ProtectorLiveInputDiagnostics* diagnostics);
/* Patch the RBNEG9 132-byte big-endian KPAD record. Retain reference connection,
 * calibration and extension metadata. Invalid arguments leave it unchanged. */
bool protector_live_input_encode_kpad(const ProtectorLiveInputSample* sample,
                                     uint8_t* status, size_t size);

#ifdef __cplusplus
}
#endif
#endif
