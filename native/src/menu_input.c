#include "protector/menu_input.h"
#include <math.h>
#include <string.h>

void protector_menu_input_reset(ProtectorMenuInput* state) {
    if (state) memset(state, 0, sizeof(*state));
}
ProtectorMenuCommand protector_menu_input_sample(ProtectorMenuInput* state,
        float x, float y, bool confirm, bool back, double seconds) {
    if (!state || !isfinite(seconds)) return PROTECTOR_MENU_NONE;
    if (!isfinite(x)) x = 0;
    if (!isfinite(y)) y = 0;
    const bool activate = confirm && !state->confirm_held;
    const bool cancel = back && !state->back_held;
    state->confirm_held = confirm;
    state->back_held = back;
    // A held direction releases below .35; new intent needs .55. Choose
    // one dominant axis so a diagonal cannot adjust and move in one sample.
    const float threshold = state->direction ? .35f : .55f;
    int direction = PROTECTOR_MENU_NONE;
    if (fabsf(y) >= threshold && fabsf(y) >= fabsf(x))
        direction = y > 0 ? PROTECTOR_MENU_UP : PROTECTOR_MENU_DOWN;
    else if (fabsf(x) >= threshold)
        direction = x > 0 ? PROTECTOR_MENU_RIGHT : PROTECTOR_MENU_LEFT;
    const bool changed = direction != state->direction;
    state->direction = direction;
    if (cancel || activate) {
        state->repeat_at = seconds + .38;
        return cancel ? PROTECTOR_MENU_BACK : PROTECTOR_MENU_CONFIRM;
    }
    if (!direction) { state->repeat_at = 0; return PROTECTOR_MENU_NONE; }
    if (changed) { state->repeat_at = seconds + .38; return (ProtectorMenuCommand)direction; }
    if (seconds >= state->repeat_at) {
        // Never catch up a backlog after an app stall.
        state->repeat_at = seconds + .12;
        return (ProtectorMenuCommand)direction;
    }
    return PROTECTOR_MENU_NONE;
}
