#ifndef PROTECTOR_CINEMATIC_SURROUND_H
#define PROTECTOR_CINEMATIC_SURROUND_H

#include <algorithm>
#include <cmath>

struct CinematicSurroundLayout {
    bool enabled = false;
    float scaleX = 1;
    float scaleY = 1;
    float frameAspect = 4.0f / 3.0f;
    float filmAspect = 4.0f / 3.0f;
};

static inline CinematicSurroundLayout CinematicSurround(bool enhanced,
    bool sourceAdmitted, bool restored, double frameAspect, double restoredAspect = 16.0/9.0) {
    CinematicSurroundLayout result;
    if (!enhanced || !sourceAdmitted || !std::isfinite(frameAspect) ||
        frameAspect < 4.0/3.0 || frameAspect > 3.0) return result;
    if (restored && (!std::isfinite(restoredAspect) || restoredAspect < 4.0/3.0 ||
        restoredAspect > 16.0/9.0)) return result;
    const double film = restored ? restoredAspect : 4.0/3.0;
    result.frameAspect = (float)frameAspect;
    result.filmAspect = (float)film;
    result.scaleX = (float)std::min(1.0, film/frameAspect);
    result.scaleY = (float)std::min(1.0, frameAspect/film);
    result.enabled = result.scaleX < 0.99999f || result.scaleY < 0.99999f;
    return result;
}

// Appended after the shared presentation vertex declarations. This is native
// geometric chrome; no raster assets, clock, sampled video or hidden animation.
static constexpr const char* ProtectorCinematicSurroundShader = R"METAL(
fragment float4 live_cinematic_surround_fragment(
    PresentVarying input [[stage_in]], constant float4& aperture [[buffer(0)]]
) {
    float2 ndc = input.uv * 2.0 - 1.0;
    if (all(abs(ndc) <= aperture.xy)) discard_fragment();
    float2 p = ndc * float2(aperture.z, 1.0);
    float2 edge = aperture.xy * float2(aperture.z, 1.0);
    float2 separation = abs(p) - edge;
    float distance = max(separation.x, separation.y);
    float aa = 2.0 / max(aperture.w, 1.0);
    float3 ink = float3(0.035, 0.035, 0.035);
    float3 face = float3(0.048, 0.067, 0.057);
    float3 metal = float3(0.125, 0.157, 0.145);
    float3 green = float3(0.24, 0.42, 0.12);
    float3 color = face;

    // Cropped watch-material arc lives beyond the display edge. Only its quiet
    // strap-like arc enters the unused margin; it is not a duplicate button.
    bool sideMargin = (aperture.z-edge.x) > (1.0-edge.y);
    float2 center = sideMargin ? float2(copysign(aperture.z+0.40, p.x), 0.0)
                               : float2(0.0, copysign(1.40, p.y));
    float2 local = p-center;
    float radius = length(local);
    float band = 1.0-smoothstep(0.042-aa, 0.042+aa, abs(radius-0.69));
    float rim = 1.0-smoothstep(0.006-aa, 0.006+aa, abs(radius-0.736));
    color = mix(color, ink, band);
    color = mix(color, metal, rim*0.65);
    float cross = sideMargin ? abs(local.y) : abs(local.x);
    float mark = (1.0-smoothstep(0.019-aa, 0.019+aa, abs(cross-0.34))) *
        (1.0-smoothstep(0.025-aa, 0.025+aa, abs(radius-0.69)));
    color = mix(color, green, mark);

    // The shallow cel bevel is entirely OUTSIDE the film. Its innermost ink
    // isolates the image without clipping, adding a fake glow, or changing size.
    float bezel = 1.0-smoothstep(0.012-aa, 0.012+aa, distance);
    color = mix(color, metal, bezel*0.82);
    float innerInk = 1.0-smoothstep(0.004-aa, 0.004+aa, distance);
    color = mix(color, ink, innerInk);
    return float4(color, 1.0);
}
)METAL";

#endif
