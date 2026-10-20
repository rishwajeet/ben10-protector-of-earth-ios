#ifndef PROTECTOR_SCENE_ANTIALIAS_H
#define PROTECTOR_SCENE_ANTIALIAS_H

// Edge-only spatial reconstruction, independently expressed for Metal from
// the method described by Timothy Lottes, FXAA whitepaper (NVIDIA, 2011).
// https://developer.download.nvidia.com/assets/gamedev/files/sdk/11/FXAA_WhitePaper.pdf
// No low-pass/subpixel blend: preserve the cartoon's painted texture and ink.
// Apply to perceptually encoded scene color before HUD, never to movie frames.
static const char* ProtectorSceneAntialiasShader = R"METAL(
float scene_edge_luma(float3 rgb) { return dot(rgb, float3(0.299, 0.587, 0.114)); }

fragment float4 live_scene_antialias_fragment(
    PresentVarying input [[stage_in]], texture2d<float> picture [[texture(0)]],
    sampler pictureSampler [[sampler(0)]]) {
    const float2 pixel = 1.0 / float2(picture.get_width(), picture.get_height());
    const float2 uv = input.uv;
    const float4 center = picture.sample(pictureSampler, uv);
    const float m = scene_edge_luma(center.rgb);
    const float n = scene_edge_luma(picture.sample(pictureSampler, uv + float2(0,-pixel.y)).rgb);
    const float s = scene_edge_luma(picture.sample(pictureSampler, uv + float2(0, pixel.y)).rgb);
    const float w = scene_edge_luma(picture.sample(pictureSampler, uv + float2(-pixel.x,0)).rgb);
    const float e = scene_edge_luma(picture.sample(pictureSampler, uv + float2( pixel.x,0)).rgb);
    const float lo = min(m, min(min(n,s),min(w,e)));
    const float hi = max(m, max(max(n,s),max(w,e)));
    if (hi - lo < max(1.0/16.0, hi/8.0)) return center;
    const float nw = scene_edge_luma(picture.sample(pictureSampler,uv + pixel*float2(-1,-1)).rgb);
    const float ne = scene_edge_luma(picture.sample(pictureSampler,uv + pixel*float2( 1,-1)).rgb);
    const float sw = scene_edge_luma(picture.sample(pictureSampler,uv + pixel*float2(-1, 1)).rgb);
    const float se = scene_edge_luma(picture.sample(pictureSampler,uv + pixel*float2( 1, 1)).rgb);
    const float horizontal = abs(nw+sw-2*w)+2*abs(n+s-2*m)+abs(ne+se-2*e);
    const float vertical = abs(nw+ne-2*n)+2*abs(w+e-2*m)+abs(sw+se-2*s);
    const bool alongX = horizontal >= vertical;
    const float a = alongX ? n : w, b = alongX ? s : e;
    const bool towardA = abs(a-m) >= abs(b-m);
    const float neighbor = towardA ? a : b;
    const float pairMean = (m+neighbor)*0.5;
    const float threshold = abs(neighbor-m)*0.25;
    const float2 normal = (alongX ? float2(0,pixel.y) : float2(pixel.x,0)) * (towardA ? -1.0 : 1.0);
    const float2 tangent = alongX ? float2(pixel.x,0) : float2(0,pixel.y);
    const float2 edge = uv + normal*0.5;
    bool leftFound = false, rightFound = false;
    float leftDelta = 0, rightDelta = 0;
    float leftLength = 8, rightLength = 8;
    for (uint distance = 1; distance <= 8; ++distance) {
        if (!leftFound) {
            leftDelta = scene_edge_luma(picture.sample(pictureSampler,edge-tangent*float(distance)).rgb)-pairMean;
            leftFound = abs(leftDelta) >= threshold;
            leftLength = float(distance);
        }
        if (!rightFound) {
            rightDelta = scene_edge_luma(picture.sample(pictureSampler,edge+tangent*float(distance)).rgb)-pairMean;
            rightFound = abs(rightDelta) >= threshold;
            rightLength = float(distance);
        }
        if (leftFound && rightFound) break;
    }
    const bool leftNearest = leftLength <= rightLength;
    const bool found = leftNearest ? leftFound : rightFound;
    const float endDelta = leftNearest ? leftDelta : rightDelta;
    // A straight unbroken edge, or an endpoint on the wrong side, is not a
    // staircase to round. In particular do not blur axis-aligned ink lines.
    if (!found || (endDelta < 0) == (m-pairMean < 0)) return center;
    const float shift = max(0.0, 0.5-min(leftLength,rightLength)/(leftLength+rightLength));
    return float4(picture.sample(pictureSampler,uv+normal*shift).rgb,center.a);
}
)METAL";
#endif
