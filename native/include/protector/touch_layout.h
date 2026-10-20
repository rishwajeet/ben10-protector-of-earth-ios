#ifndef PROTECTOR_TOUCH_LAYOUT_H
#define PROTECTOR_TOUCH_LAYOUT_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ProtectorTouchRect { double x, y, width, height; } ProtectorTouchRect;
typedef struct ProtectorTouchInsets { double top, left, bottom, right; } ProtectorTouchInsets;
enum { PROTECTOR_TOUCH_ACTION_COUNT = 11 };
/* Actions retain the title's A, B, C, Z, plus, minus, left, up, right, down,
 * motion order. Layout knows no guest memory and cannot alter game rules. */
typedef struct ProtectorTouchLayout {
    ProtectorTouchRect stick;
    ProtectorTouchRect actions[PROTECTOR_TOUCH_ACTION_COUNT];
    ProtectorTouchRect pause;
    double effective_scale;
} ProtectorTouchLayout;

bool protector_touch_layout(double width, double height, ProtectorTouchInsets insets,
                            double scale, bool swapped, ProtectorTouchLayout* layout);
/* Contextual menu uses Confirm [0], Back [5], directions [6..9], Pause.
 * Other action rectangles are retained but not shown by the native caller. */
bool protector_touch_menu_layout(double width, double height, ProtectorTouchInsets insets,
                                 double scale, bool swapped, ProtectorTouchLayout* layout);
/* Gallery stacks Back above Confirm at the outer edge to leave both rows of
 * source thumbnails clear. Same targets and directional ring as Menu. */
bool protector_touch_gallery_layout(double width, double height, ProtectorTouchInsets insets,
                                    double scale, bool swapped, ProtectorTouchLayout* layout);
/* Dense collection grids use the same targets in a narrower direction diamond. */
bool protector_touch_extras_layout(double width, double height, ProtectorTouchInsets insets,
                                   double scale, bool swapped, ProtectorTouchLayout* layout);
/* Full character view retains the analogue camera and only Back/Pause. */
bool protector_touch_viewer_layout(double width, double height, ProtectorTouchInsets insets,
                                   double scale, bool swapped, ProtectorTouchLayout* layout);
/* Combo List has only left/right and Back. Wide phones use the side gutters;
 * narrower screens reserve a footer. content preserves the source 4:3 shape. */
bool protector_touch_combo_layout(double width, double height, ProtectorTouchInsets insets,
    double scale, bool swapped, ProtectorTouchLayout* layout, ProtectorTouchRect* content);
/* Upgrade keeps Left/Right and source-offered Unlock Move [0], never Back.
 * Choose the largest uniformly fitted source frame clear of either hand. */
bool protector_touch_upgrade_layout(double width, double height, ProtectorTouchInsets insets,
    double scale, bool swapped, ProtectorTouchLayout* layout, ProtectorTouchRect* content);
/* World map retains the stick and Confirm/Back. Optional Replay [2] and
 * Challenge [3] sit above them; visibility belongs to the source observer. */
bool protector_touch_map_layout(double width, double height, ProtectorTouchInsets insets,
                                double scale, bool swapped, ProtectorTouchLayout* layout);
/* Overview-only noninteractive reservations. Use the actual map stick,
 * Confirm/Back and Pause bounds; hiding controls never makes cards jump.
 * Detail/Replay/Challenge retain their separate source composition. */
typedef struct ProtectorMapContentLayout {
    ProtectorTouchRect title, cards, hints;
} ProtectorMapContentLayout;
bool protector_touch_map_content_layout(double width, double height, ProtectorTouchInsets insets,
    double scale, bool swapped, ProtectorMapContentLayout* content);
/* Enhanced widescreen gameplay: retain thumb zones, reserve the upper-left
 * source HUD and place the four existing top actions together at upper right.
 * hud is a noninteractive 277x120 source-unit cluster, not an input target. */
bool protector_touch_native_hud_layout(double width, double height, ProtectorTouchInsets insets,
    double scale, bool swapped, ProtectorTouchLayout* layout, ProtectorTouchRect* hud);
/* Source-space reservation for the single-player live COMBO label/count.
 * A fixed envelope preserves source pulse/centering without per-frame jitter. */
enum { PROTECTOR_COMBAT_FEEDBACK_LEFT = -40, PROTECTOR_COMBAT_FEEDBACK_TOP = 340,
       PROTECTOR_COMBAT_FEEDBACK_WIDTH = 184, PROTECTOR_COMBAT_FEEDBACK_HEIGHT = 108 };
/* This noninteractive frame clears configured controls even when hidden by
 * a controller. It never mirrors the feedback to follow a swapped stick. */
bool protector_touch_combat_feedback_layout(double width, double height, ProtectorTouchInsets insets,
    double scale, bool swapped, ProtectorTouchRect* feedback);

#ifdef __cplusplus
}
#endif
#endif
