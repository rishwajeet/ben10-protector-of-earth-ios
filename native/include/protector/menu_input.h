#ifndef PROTECTOR_MENU_INPUT_H
#define PROTECTOR_MENU_INPUT_H
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef enum {
    PROTECTOR_MENU_NONE, PROTECTOR_MENU_UP, PROTECTOR_MENU_DOWN,
    PROTECTOR_MENU_LEFT, PROTECTOR_MENU_RIGHT, PROTECTOR_MENU_CONFIRM,
    PROTECTOR_MENU_BACK
} ProtectorMenuCommand;
typedef struct {
    int direction;
    bool confirm_held, back_held;
    double repeat_at;
} ProtectorMenuInput;
void protector_menu_input_reset(ProtectorMenuInput* state);
/* One command per sample; only directions repeat. +y means up. */
ProtectorMenuCommand protector_menu_input_sample(ProtectorMenuInput* state,
    float x, float y, bool confirm, bool back, double seconds);
#ifdef __cplusplus
}
#endif
#endif
