#include "protector/live_input.h"

#include <math.h>
#include <stdatomic.h>
#include <string.h>

static atomic_flag input_lock = ATOMIC_FLAG_INIT;
static bool input_enabled;
static ProtectorLiveInputSample input_state;
static uint32_t last_sample_hold;
static bool pending_pointer;
static bool last_pointer_valid;
static float last_pointer_x;
static float last_pointer_y;
static uint32_t held_motion;
static uint32_t pending_motion;
static unsigned motion_phase[2];
static float last_motion_x[2];
static float last_motion_y[2];
static ProtectorLiveInputDiagnostics input_diagnostics;

/* Critical sections only update bounded input state and counters. They never
 * allocate, call platform APIs, wait for a frame, or cover guest execution. */
static void lock_input(void) {
    while (atomic_flag_test_and_set_explicit(&input_lock, memory_order_acquire)) {
    }
}

static void unlock_input(void) {
    atomic_flag_clear_explicit(&input_lock, memory_order_release);
}

static float bounded_axis(float value) {
    if (!isfinite(value)) return 0.0f;
    if (value > 1.0f) return 1.0f;
    if (value < -1.0f) return -1.0f;
    return value;
}

static void reset_auxiliary_input(void) {
    pending_pointer = false;
    last_pointer_valid = false;
    last_pointer_x = last_pointer_y = 0;
    held_motion = pending_motion = 0;
    memset(motion_phase, 0, sizeof(motion_phase));
    memset(last_motion_x, 0, sizeof(last_motion_x));
    last_motion_y[0] = last_motion_y[1] = -1;
}

void protector_live_input_enable(bool enabled) {
    lock_input();
    memset(&input_state, 0, sizeof(input_state));
    last_sample_hold = 0;
    reset_auxiliary_input();
    input_enabled = enabled;
    if (enabled) memset(&input_diagnostics, 0, sizeof(input_diagnostics));
    unlock_input();
}

bool protector_live_input_enabled(void) {
    lock_input();
    const bool enabled = input_enabled;
    unlock_input();
    return enabled;
}

void protector_live_input_cancel(void) {
    lock_input();
    memset(&input_state, 0, sizeof(input_state));
    input_state.release = last_sample_hold;
    reset_auxiliary_input();
    unlock_input();
}

void protector_live_input_update(uint32_t held, float stick_x, float stick_y) {
    lock_input();
    if (input_enabled) {
        input_state.trigger |= held & ~input_state.hold;
        input_state.release |= input_state.hold & ~held;
        input_state.hold = held;
        input_state.stick_x = bounded_axis(stick_x);
        input_state.stick_y = bounded_axis(stick_y);
    }
    unlock_input();
}

void protector_live_input_pointer(bool valid, float x, float y) {
    lock_input();
    if (input_enabled) {
        valid = valid && isfinite(x) && isfinite(y);
        input_state.pointer_valid = valid;
        if (valid) {
            input_state.pointer_x = bounded_axis(x);
            input_state.pointer_y = bounded_axis(y);
            pending_pointer = true;
        }
    }
    unlock_input();
}

void protector_live_input_clear_pointer(void) {
    lock_input();
    input_state.pointer_valid = false;
    input_state.pointer_x = input_state.pointer_y = 0;
    pending_pointer = last_pointer_valid = false;
    unlock_input();
}

void protector_live_input_motion(uint32_t held) {
    lock_input();
    if (input_enabled) {
        held &= PROTECTOR_MOTION_WIIMOTE | PROTECTOR_MOTION_NUNCHUK;
        pending_motion |= held & ~held_motion;
        held_motion = held;
    }
    unlock_input();
}

bool protector_live_input_map_pointer(float x, float y, float width, float height,
                                     float* pointer_x, float* pointer_y) {
    return protector_live_input_map_pointer_for_presentation(
        x, y, width, height, false, pointer_x, pointer_y);
}

bool protector_live_input_map_pointer_for_presentation(float x, float y,
    float width, float height, bool widescreen, float* pointer_x, float* pointer_y) {
    return protector_live_input_map_pointer_for_aspect(x, y, width, height,
        widescreen ? 16.0f / 9.0f : 4.0f / 3.0f, pointer_x, pointer_y);
}

bool protector_live_input_map_pointer_for_aspect(float x, float y,
    float width, float height, float aspect, float* pointer_x, float* pointer_y) {
    if (!pointer_x || !pointer_y || !isfinite(x) || !isfinite(y) ||
        !isfinite(width) || !isfinite(height) || width <= 0 || height <= 0 ||
        !isfinite(aspect) || aspect < 4.0f / 3.0f || aspect > 3)
        return false;
    const float game_height = fminf(height, width / aspect);
    const float game_width = game_height * (4.0f / 3.0f);
    const float left = (width - game_width) * 0.5f;
    const float top = (height - game_height) * 0.5f;
    if (x < left || x > left + game_width || y < top || y > top + game_height)
        return false;
    *pointer_x = bounded_axis((x - left) / game_width * 2.0f - 1.0f);
    *pointer_y = bounded_axis((y - top) / game_height * 2.0f - 1.0f);
    return true;
}

bool protector_live_input_map_qte_pointer_for_aspect(float x, float y,
    float width, float height, float aspect, float* pointer_x, float* pointer_y) {
    if (!pointer_x || !pointer_y) return false;
    float mapped_x, mapped_y;
    if (!protector_live_input_map_pointer_for_aspect(x,y,width,height,aspect,&mapped_x,&mapped_y))
        return false;
    *pointer_x = mapped_x * .5f;
    *pointer_y = mapped_y * .5f;
    return true;
}

static void sample_motion(float output[5], unsigned controller, bool active, bool paired) {
    /* A deliberate 12-poll shake cycle with neutral intervals. The original
     * controller history and gesture recognizer decide what it means. */
    static const float cycle[12] = {3, 3, 3, 0, 0, 0, -3, -3, -3, 0, 0, 0};
    const float x = active ? cycle[motion_phase[controller]] : 0;
    /* GiantVilgax's source predicate (11_07.gcs 0x23c5f8..0x23c6f4)
     * requires opposite vertical sign crossings from BOTH channels. The old
     * horizontal-only signal could never satisfy it. Keep the single-channel
     * shake unchanged; holding Interact/both triggers adds alternating Y.
     * The translated game still decides success and owns all QTE timing. */
    const float y = active && paired && x != 0 ? (controller ? -x : x) : -1;
    output[0] = x;
    output[1] = y;
    output[2] = 0;
    output[3] = hypotf(x, y);
    output[4] = active ? hypotf(x - last_motion_x[controller],
                               y - last_motion_y[controller]) : 0;
    last_motion_x[controller] = x;
    last_motion_y[controller] = y;
    motion_phase[controller] = active ? (motion_phase[controller] + 1u) % 12u : 0u;
}

bool protector_live_input_sample(ProtectorLiveInputSample* sample) {
    if (!sample) return false;
    lock_input();
    const bool enabled = input_enabled;
    *sample = input_state;
    /* A short host tap can finish before the next guest poll. Expose its down
     * transition for one sample, then its up transition, rather than presenting
     * an impossible down/up pair with hold=0 to the game's controller manager. */
    sample->hold |= input_state.trigger;
    sample->release &= ~sample->hold;
    input_state.trigger = 0u;
    input_state.release &= sample->hold;
    last_sample_hold = enabled ? sample->hold : 0;
    sample->pointer_valid = enabled && (input_state.pointer_valid || pending_pointer);
    sample->pointer_dx = sample->pointer_valid && last_pointer_valid
        ? sample->pointer_x - last_pointer_x : 0;
    sample->pointer_dy = sample->pointer_valid && last_pointer_valid
        ? sample->pointer_y - last_pointer_y : 0;
    last_pointer_valid = sample->pointer_valid;
    last_pointer_x = sample->pointer_x;
    last_pointer_y = sample->pointer_y;
    pending_pointer = false;
    const uint32_t motion = enabled ? held_motion | pending_motion : 0;
    const bool paired = (motion & (PROTECTOR_MOTION_WIIMOTE | PROTECTOR_MOTION_NUNCHUK))
        == (PROTECTOR_MOTION_WIIMOTE | PROTECTOR_MOTION_NUNCHUK);
    /* Triggers can be pressed on different polls; pairing must not depend on
     * their initial phase difference. A lone trigger retains its own cycle. */
    if (paired) motion_phase[1] = motion_phase[0];
    sample_motion(sample->wiimote_motion, 0, (motion & PROTECTOR_MOTION_WIIMOTE) != 0, paired);
    sample_motion(sample->nunchuk_motion, 1, (motion & PROTECTOR_MOTION_NUNCHUK) != 0, paired);
    pending_motion = 0;
    if (enabled) {
        input_diagnostics.samples++;
        input_diagnostics.camera_samples += (sample->hold & PROTECTOR_BUTTON_ONE) ? 1u : 0u;
        input_diagnostics.camera_trigger_samples += (sample->trigger & PROTECTOR_BUTTON_ONE) ? 1u : 0u;
        input_diagnostics.pointer_samples += sample->pointer_valid ? 1u : 0u;
        input_diagnostics.wiimote_motion_samples += (motion & PROTECTOR_MOTION_WIIMOTE) ? 1u : 0u;
        input_diagnostics.nunchuk_motion_samples += (motion & PROTECTOR_MOTION_NUNCHUK) ? 1u : 0u;
        input_diagnostics.last = *sample;
    }
    unlock_input();
    return enabled;
}

void protector_live_input_diagnostics(ProtectorLiveInputDiagnostics* diagnostics) {
    if (!diagnostics) return;
    lock_input();
    *diagnostics = input_diagnostics;
    unlock_input();
}

static void write_word(uint8_t* destination, uint32_t value) {
    destination[0] = (uint8_t)(value >> 24);
    destination[1] = (uint8_t)(value >> 16);
    destination[2] = (uint8_t)(value >> 8);
    destination[3] = (uint8_t)value;
}

static void write_float(uint8_t* destination, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    write_word(destination, bits);
}

bool protector_live_input_encode_kpad(const ProtectorLiveInputSample* sample,
                                     uint8_t* status, size_t size) {
    if (!sample || !status || size < PROTECTOR_KPAD_STATUS_SIZE ||
        !isfinite(sample->stick_x) || !isfinite(sample->stick_y) ||
        !isfinite(sample->pointer_x) || !isfinite(sample->pointer_y) ||
        !isfinite(sample->pointer_dx) || !isfinite(sample->pointer_dy) ||
        fabsf(sample->pointer_dx) > 2 || fabsf(sample->pointer_dy) > 2) return false;
    for (unsigned i = 0; i < 5; ++i)
        if (!isfinite(sample->wiimote_motion[i]) || !isfinite(sample->nunchuk_motion[i]))
            return false;
    /* Layout verified in RBNEG9 at 0x800B5734..0x800B58CC and matches:
     * github.com/kiwi515/ogws/blob/master/include/revolution/KPAD/KPAD.h.
     * KPAD pos is positive right/down (devkitPro/wut padscore documentation). */
    write_word(status, sample->hold);
    write_word(status + 4, sample->trigger);
    write_word(status + 8, sample->release);
    for (unsigned i = 0; i < 5; ++i) {
        write_float(status + 0x0C + i * 4, sample->wiimote_motion[i]);
        write_float(status + 0x68 + i * 4, sample->nunchuk_motion[i]);
    }
    write_float(status + 0x20, bounded_axis(sample->pointer_x));
    write_float(status + 0x24, bounded_axis(sample->pointer_y));
    write_float(status + 0x28, sample->pointer_valid ? sample->pointer_dx : 0);
    write_float(status + 0x2C, sample->pointer_valid ? sample->pointer_dy : 0);
    write_float(status + 0x30, sample->pointer_valid
        ? hypotf(sample->pointer_dx, sample->pointer_dy) : 0);
    status[0x5E] = sample->pointer_valid ? 2 : 0;
    write_float(status + 0x60, bounded_axis(sample->stick_x));
    write_float(status + 0x64, bounded_axis(sample->stick_y));
    return true;
}
