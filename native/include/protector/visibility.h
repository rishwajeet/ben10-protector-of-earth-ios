#ifndef PROTECTOR_VISIBILITY_H
#define PROTECTOR_VISIBILITY_H
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PROTECTOR_MAX_PRESENTATION_ASPECT 3.0

/* Published by the native viewport, read by the translated render worker. */
void protector_visibility_set_presentation_aspect(double aspect);
double protector_visibility_presentation_aspect(void);
bool protector_visibility_render_caller(uint32_t return_address);

/* Conservative horizontal sphere envelope for Enhanced static-map rendering.
 * Reconstruct from the unmodified vertical extent so repeated host seams are
 * idempotent. The caller retains the original near/far, vertical and backface
 * tests. Invalid inputs and 4:3 return the current value unchanged. */
double protector_static_visibility_half_width(
    double current_half_width,
    double original_half_height,
    double source_height_over_width,
    double expanded_radius,
    double presentation_aspect
);

#ifdef __cplusplus
}
#endif
#endif
