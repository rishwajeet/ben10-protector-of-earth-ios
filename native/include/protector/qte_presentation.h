#ifndef PROTECTOR_QTE_PRESENTATION_H
#define PROTECTOR_QTE_PRESENTATION_H
#include <math.h>
#include <stdbool.h>

typedef struct ProtectorQTERect { float x, y, width, height; } ProtectorQTERect;

/* Presentation-only placement. Never move a source target to accommodate a
 * caption. Prefer the lower safe edge; use the upper edge when it is occupied.
 * A pathological target covering both edges suppresses the redundant cue. */
static inline bool protector_qte_cue_rect(ProtectorQTERect safe, float width, float height,
    ProtectorQTERect target, ProtectorQTERect* output) {
    if (!output || !isfinite(safe.x) || !isfinite(safe.y) || !isfinite(safe.width) ||
        !isfinite(safe.height) || !isfinite(width) || !isfinite(height) ||
        width <= 0 || height <= 0 || safe.width < width || safe.height < height + 16) return false;
    ProtectorQTERect cue = {safe.x + (safe.width-width)/2,
        safe.y + safe.height-height-8,width,height};
    const bool avoid=isfinite(target.x) && isfinite(target.y) &&
        isfinite(target.width) && isfinite(target.height) && target.width>0 && target.height>0;
    for (unsigned edge=0; edge<2; ++edge) {
        if (!avoid || cue.x+cue.width+8 <= target.x || target.x+target.width+8 <= cue.x ||
            cue.y+cue.height+8 <= target.y || target.y+target.height+8 <= cue.y) {
            *output=cue;return true;
        }
        cue.y=safe.y+8;
    }
    return false;
}

/* Host-only presentation of admitted original boss prompt draws. These flags
 * do not enable an action, advance a script, or decide whether a QTE succeeds. */
enum {
    PROTECTOR_QTE_NONE = 0,
    PROTECTOR_QTE_PAIRED_MOTION = 1,
    PROTECTOR_QTE_POINTER_TARGET = 2,
    PROTECTOR_QTE_SPECIAL = 4,
    PROTECTOR_QTE_BLOCK = 8,
    PROTECTOR_QTE_JUMP = 16,
    PROTECTOR_QTE_TRANSFORM = 32,
};

static inline const char* protector_qte_instruction(unsigned prompts, int controller, int keyboard) {
    if (prompts & PROTECTOR_QTE_PAIRED_MOTION)
        return controller ? "Hold both triggers" : keyboard ? "Hold M to interact" : "Hold Interact";
    if (prompts & PROTECTOR_QTE_POINTER_TARGET)
        return controller ? "Right stick: aim at target" : keyboard ? "Move pointer onto target" : "Drag onto the target";
    if (prompts & PROTECTOR_QTE_SPECIAL)
        return controller ? "Special: D-pad Down" : keyboard ? "Special: Down Arrow" : "Use Special";
    if (prompts & PROTECTOR_QTE_BLOCK)
        return controller ? "Block: left face button" : keyboard ? "Block: C" : "Use Block";
    if (prompts & PROTECTOR_QTE_JUMP)
        return controller ? "Jump: top face button" : keyboard ? "Jump: Shift" : "Use Jump";
    // Bound to GCExtendedGamepad.buttonOptions: View, Create or Minus by pad. Hosts may swap in the real name.
    if (prompts & PROTECTOR_QTE_TRANSFORM)
        return controller ? "Transform: View / Create / Minus" : keyboard ? "Transform: Minus" : "Use Transform";
    return "";
}

#endif
