#ifndef PROTECTOR_NATIVE_RESOLUTION_H
#define PROTECTOR_NATIVE_RESOLUTION_H

#include <math.h>

/* Physical drawable pixels and the source-owned display rectangle, not UIKit
 * points or a fixed assumed crop. Zero means invalid/unsupported, never a
 * silently undersized "Native" result. This changes no guest coordinates. */
static inline unsigned protector_native_render_scale(double pixel_width,
    double pixel_height, unsigned source_width, unsigned source_height) {
    if (!isfinite(pixel_width) || !isfinite(pixel_height) ||
        pixel_width <= 0 || pixel_height <= 0 || !source_width || !source_height ||
        source_width > 640 || source_height > 480) return 0;
    const double ratio = fmax(pixel_width / source_width, pixel_height / source_height);
    if (ratio > 6.0) return 0;
    return (unsigned)fmax(1.0, ceil(ratio));
}

/* Native presentation of a widened source is anamorphic: the 640-wide source
 * spans the drawable's full width while its 448/480 rows span the height.
 * Choose each axis independently so neither is oversampled by a whole extra
 * multiple. An axis whose next lower whole multiple leaves the display at most
 * 5% short uses it (2622 px over 640 → 4×, a 2.4% stretch, instead of shading
 * 22% extra columns at 5×). Same validity rules as the uniform policy. */
static inline unsigned protector_native_axis_scale(double pixels, unsigned source) {
    const double ratio = pixels / source;
    const double lower = floor(ratio);
    return (unsigned)(lower >= 1.0 && ratio / lower <= 1.05 ? lower : fmax(1.0, ceil(ratio)));
}
static inline int protector_native_render_scale_axes(double pixel_width,
    double pixel_height, unsigned source_width, unsigned source_height,
    unsigned* scale_x, unsigned* scale_y) {
    if (!scale_x || !scale_y ||
        !protector_native_render_scale(pixel_width, pixel_height, source_width, source_height)) return 0;
    *scale_x = protector_native_axis_scale(pixel_width, source_width);
    *scale_y = protector_native_axis_scale(pixel_height, source_height);
    return 1;
}

#endif
