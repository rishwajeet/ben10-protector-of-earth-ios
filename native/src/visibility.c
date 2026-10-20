#include "protector/visibility.h"
#include <math.h>
#include <stdatomic.h>

static _Atomic double presentation_aspect = 16.0 / 9.0;
void protector_visibility_set_presentation_aspect(double aspect) {
    if (isfinite(aspect) && aspect >= 4.0 / 3.0 && aspect <= PROTECTOR_MAX_PRESENTATION_ASPECT)
        atomic_store_explicit(&presentation_aspect,aspect,memory_order_relaxed);
}
double protector_visibility_presentation_aspect(void) {
    return atomic_load_explicit(&presentation_aspect,memory_order_relaxed);
}
bool protector_visibility_render_caller(uint32_t return_address) {
    // Static map and model-object render submissions, respectively. No
    // camera, actor-update, collision or arbitrary sphere-query caller.
    return return_address==0x800233C4u || return_address==0x8003A4C0u;
}

double protector_static_visibility_half_width(
    double current_half_width,
    double original_half_height,
    double source_height_over_width,
    double expanded_radius,
    double presentation_aspect
) {
    const double original_aspect = 4.0 / 3.0;
    if (!isfinite(presentation_aspect) || presentation_aspect <= original_aspect ||
        presentation_aspect > PROTECTOR_MAX_PRESENTATION_ASPECT ||
        !isfinite(current_half_width) || current_half_width <= 0 ||
        !isfinite(original_half_height) || original_half_height <= 0 ||
        !isfinite(source_height_over_width) || source_height_over_width <= 0 ||
        !isfinite(expanded_radius) || expanded_radius < 0) return current_half_width;

    const double scale = presentation_aspect / original_aspect;
    const double original_width = original_half_height / source_height_over_width;
    // The guest already scales sphere radius for its original side plane.
    // Scaling the whole horizontal sphere bound is conservative for a wider
    // plane: sqrt(1+(s*t)^2) <= s*sqrt(1+t^2), for s >= 1. Fold only the extra
    // radius into width, leaving the original radius for the vertical test.
    const float widened = (float)(original_width * scale + expanded_radius * (scale - 1));
    return isfinite(widened) && widened > current_half_width ? widened : current_half_width;
}
