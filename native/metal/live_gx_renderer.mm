#import "protector/live_metal_renderer.h"
#import "protector/visibility.h"
#import "protector/geometry_pack.h"
#import "protector/texture_pack.h"
#import "protector/motion_clock.h"
#import "protector/motion_identity.h"
#import "protector/cinematic_pack.h"
#import "protector/ui_context.h"
#import "protector/native_resolution.h"
#include "protector/audio_output.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <TargetConditionals.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <cfloat>
#include <map>
#include <unordered_map>
#include <memory>
#include <mutex>
#include <os/lock.h>
#include <atomic>
#include <numeric>
#include <tuple>
#include <vector>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "cinematic_surround.h"
#include "scene_antialias.h"

static NSString* const ProtectorLiveMetalErrorDomain =
    @"house.machine.ProtectorNative.LiveMetal";

static NSString* const ProtectorLiveShaderSource = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct LiveVertex {
    packed_float4 position;
    packed_float2 uv0;
    packed_float2 uv1;
    packed_float2 uv2;
    packed_float2 uv3;
    packed_float2 indirectUV0;
    packed_float2 indirectUV1;
    packed_float2 indirectUV2;
    packed_float2 indirectUV3;
    packed_float4 color;
    // Projective (STQ) texgen keeps S/T undivided; Q is divided per pixel,
    // as GX does. Non-projective coordinates carry Q = 1.
    packed_float4 uvQ;
};

struct LiveVarying {
    float4 position [[position]];
    float2 uv0;
    float2 uv1;
    float2 uv2;
    float2 uv3;
    float2 indirectUV0;
    float2 indirectUV1;
    float2 indirectUV2;
    float2 indirectUV3;
    float4 color;
    float4 uvQ;
};

struct LiveFragmentUniforms {
    float4 rasterColor;
    float4 colorRegisters[3];
    float4 konstColors[4];
    uint colorCombiners[4];
    uint alphaCombiners[4];
    uint textureAlphaChannels[4];
    uint rasterAlphaChannels[4];
    float4 textureDimensions[8];
    int4 indirectMatrices[6];
    uint indirectCommands[4];
    uint indirectScales[4];
    uint alphaTest;
    uint indirectCount;
    uint stageCount;
    uint shadowBorderMask; // stages whose outside-window samples read as white
};

// A small, eagerly compiled family for direct one/two-stage materials. The
// unspecialized function remains authoritative for every other GX state.
// Keep the same arithmetic, texture/LOD path and uniforms in both functions.
constant uint live_direct_stages [[function_constant(0)]];

vertex LiveVarying live_gx_vertex(
    uint vertexID [[vertex_id]],
    const device LiveVertex* vertices [[buffer(0)]]
) {
    LiveVertex input = vertices[vertexID];
    LiveVarying output;
    output.position = input.position;
    output.uv0 = input.uv0;
    output.uv1 = input.uv1;
    output.uv2 = input.uv2;
    output.uv3 = input.uv3;
    output.indirectUV0 = input.indirectUV0;
    output.indirectUV1 = input.indirectUV1;
    output.indirectUV2 = input.indirectUV2;
    output.indirectUV3 = input.indirectUV3;
    output.color = input.color;
    output.uvQ = input.uvQ;
    return output;
}

float2 live_project(float2 uv, float q) {
    return isfinite(q) && fabs(q) > 1e-8 ? uv / q : uv;
}

float live_component(float4 value, uint channel) {
    switch (channel & 3u) {
        case 0u: return value.r;
        case 1u: return value.g;
        case 2u: return value.b;
        default: return value.a;
    }
}

float3 live_color_arg(
    uint selector,
    float4 previous,
    float4 textureColor,
    float4 rasterColor,
    thread float4* registers,
    uint textureAlphaChannel,
    uint rasterAlphaChannel,
    float4 konstColor
) {
    switch (selector & 15u) {
        case 0u: return previous.rgb;
        case 1u: return previous.aaa;
        case 2u: return registers[1].rgb;
        case 3u: return registers[1].aaa;
        case 4u: return registers[2].rgb;
        case 5u: return registers[2].aaa;
        case 6u: return registers[3].rgb;
        case 7u: return registers[3].aaa;
        case 8u: return textureColor.rgb;
        case 9u:
            return float3(live_component(
                textureColor, textureAlphaChannel
            ));
        case 10u: return rasterColor.rgb;
        case 11u:
            return float3(live_component(
                rasterColor, rasterAlphaChannel
            ));
        case 12u: return float3(1.0);
        case 13u: return float3(0.5);
        case 14u: return konstColor.rgb;
        default: return float3(0.0);
    }
}

float live_alpha_arg(
    uint selector,
    float4 previous,
    float4 textureColor,
    float4 rasterColor,
    thread float4* registers,
    uint textureAlphaChannel,
    uint rasterAlphaChannel,
    float4 konstColor
) {
    switch (selector & 7u) {
        case 0u: return previous.a;
        case 1u: return registers[1].a;
        case 2u: return registers[2].a;
        case 3u: return registers[3].a;
        case 4u:
            return live_component(textureColor, textureAlphaChannel);
        case 5u:
            return live_component(rasterColor, rasterAlphaChannel);
        case 6u: return konstColor.a;
        default: return 0.0;
    }
}

float live_tev_scale(uint combiner) {
    switch ((combiner >> 20u) & 3u) {
        case 1u: return 2.0;
        case 2u: return 4.0;
        case 3u: return 0.5;
        default: return 1.0;
    }
}

int live_indirect_wrap(int coordinate, uint mode) {
    if (mode == 0u) return coordinate;
    if (mode >= 6u) return 0;
    return coordinate & ((32768 >> (mode - 1u)) - 1);
}

int2 live_indirect_shift(int2 value, int shift) {
    // Use unsigned left shifts for GX's wrapping 24-bit coordinate arithmetic.
    return shift >= 0 ? value >> min(shift, 31) : int2(uint2(value) << min(-shift, 31));
}

bool live_alpha_compare(uint value, uint reference, uint operation) {
    switch (operation) {
        case 0u: return false;
        case 1u: return value < reference;
        case 2u: return value == reference;
        case 3u: return value <= reference;
        case 4u: return value > reference;
        case 5u: return value != reference;
        case 6u: return value >= reference;
        default: return true;
    }
}

// The two physical allocations are one logical trilinear mip chain. Preserve
// the hardware's implicit filtering within each allocation, blending only the
// clamped boundary levels. Both samples run before the blend, so derivatives
// are defined even when adjacent pixels straddle the split's LOD boundary.
float4 live_texture_sample(texture2d<float> head, texture2d<float> tail,
    sampler s, float2 uv, uint tailFirstLevel) {
    if (tailFirstLevel == 0u) return head.sample(s, uv);
    const float lod = head.calculate_unclamped_lod(s, uv);
    const float4 a = head.sample(s, uv);
    const float4 b = tail.sample(s, uv);
    return mix(a, b, saturate(lod - float(tailFirstLevel - 1u)));
}

fragment float4 live_gx_fragment(
    LiveVarying input [[stage_in]],
    array<texture2d<float>, 8> textures [[texture(0)]],
    array<texture2d<float>, 8> mipTails [[texture(8)]],
    array<sampler, 8> samplers [[sampler(0)]],
    constant LiveFragmentUniforms& state [[buffer(0)]],
    constant uint* tailFirstLevels [[buffer(1)]]
) {
    float4 registers[4] = {
        float4(0.0),
        state.colorRegisters[0],
        state.colorRegisters[1],
        state.colorRegisters[2],
    };
    const float2 uvs[8] = {live_project(input.uv0, input.uvQ.x), live_project(input.uv1, input.uvQ.y),
        live_project(input.uv2, input.uvQ.z), live_project(input.uv3, input.uvQ.w),
        input.indirectUV0, input.indirectUV1, input.indirectUV2, input.indirectUV3};
    int3 indirectSamples[4] = {int3(0), int3(0), int3(0), int3(0)};
    const uint indirectCount = is_function_constant_defined(live_direct_stages) ? 0u : state.indirectCount;
    const uint stageCount = is_function_constant_defined(live_direct_stages) ? live_direct_stages : state.stageCount;
    for (uint indirect = 0u; indirect < indirectCount; ++indirect) {
        const uint slot = indirect + 4u;
        int2 coordinate = int2(uvs[slot] * state.textureDimensions[slot].zw * 128.0);
        const uint scale = state.indirectScales[indirect];
        coordinate >>= int2(scale & 15u, (scale >> 4u) & 15u);
        const float2 uv = float2(coordinate) / (128.0 * state.textureDimensions[slot].xy);
        indirectSamples[indirect] = int3(round(live_texture_sample(textures[slot], mipTails[slot],
            samplers[slot], uv, tailFirstLevels[slot]).abg * 255.0));
    }
    int2 tevCoordinate = int2(0);
    for (uint stage = 0u; stage < 4u; ++stage) {
        const uint command = is_function_constant_defined(live_direct_stages) ? 0u : state.indirectCommands[stage];
        const uint matrixIndex = (command >> 9u) & 3u;
        const uint indirect = command & 3u;
        const int2 coordinate = int2(uvs[stage] * state.textureDimensions[stage].zw * 128.0);
        int2 offset = int2(0);
        if (indirect < indirectCount && matrixIndex != 0u) {
            const uint format = (command >> 2u) & 3u;
            const uint formatShift = format == 0u ? 0u : format + 2u;
            int3 value = indirectSamples[indirect] >> formatShift;
            const int bias = format == 0u ? -128 : 1;
            if ((command & 0x10u) != 0u) value.x += bias;
            if ((command & 0x20u) != 0u) value.y += bias;
            if ((command & 0x40u) != 0u) value.z += bias;
            const uint matrixRow = 2u * (matrixIndex - 1u);
            const int4 row0 = state.indirectMatrices[matrixRow];
            const int4 row1 = state.indirectMatrices[matrixRow + 1u];
            const uint matrixType = (command >> 11u) & 3u;
            if (matrixType == 0u) {
                offset = int2(row0.x * value.x + row0.y * value.y + row0.z * value.z,
                              row1.x * value.x + row1.y * value.y + row1.z * value.z) >> 3;
            } else if (matrixType == 1u) {
                offset = (coordinate * value.x) >> 8;
            } else if (matrixType == 2u) {
                offset = (coordinate * value.y) >> 8;
            }
            offset = live_indirect_shift(offset, row0.w);
        }
        const int2 wrapped = int2(live_indirect_wrap(coordinate.x, (command >> 13u) & 7u),
                                  live_indirect_wrap(coordinate.y, (command >> 16u) & 7u));
        tevCoordinate = ((command & (1u << 20u)) != 0u ? tevCoordinate : int2(0)) + wrapped + offset;
        tevCoordinate = int2(uint2(tevCoordinate) << 8u) >> 8;
        const float2 uv = float2(tevCoordinate) / (128.0 * state.textureDimensions[stage].xy);
        float4 textureColor = live_texture_sample(textures[stage], mipTails[stage],
            samplers[stage], uv, tailFirstLevels[stage]);
        if (((state.shadowBorderMask >> stage) & 1u) != 0u && (any(uv < 0.0) || any(uv > 1.0)))
            textureColor = float4(1.0);
        const uint colorCombiner = state.colorCombiners[stage];
        const uint alphaCombiner = state.alphaCombiners[stage];
        const uint textureAlphaChannel =
            state.textureAlphaChannels[stage];
        const uint rasterAlphaChannel =
            state.rasterAlphaChannels[stage];
        const float4 konstColor = state.konstColors[stage];
        const float4 previous = registers[0];
        const float3 colorA = live_color_arg(
            (colorCombiner >> 12u) & 15u,
            previous,
            textureColor,
            input.color,
            registers,
            textureAlphaChannel,
            rasterAlphaChannel,
            konstColor
        );
        const float3 colorB = live_color_arg(
            (colorCombiner >> 8u) & 15u,
            previous,
            textureColor,
            input.color,
            registers,
            textureAlphaChannel,
            rasterAlphaChannel,
            konstColor
        );
        const float3 colorC = live_color_arg(
            (colorCombiner >> 4u) & 15u,
            previous,
            textureColor,
            input.color,
            registers,
            textureAlphaChannel,
            rasterAlphaChannel,
            konstColor
        );
        const float3 colorD = live_color_arg(
            colorCombiner & 15u,
            previous,
            textureColor,
            input.color,
            registers,
            textureAlphaChannel,
            rasterAlphaChannel,
            konstColor
        );
        const float alphaA = live_alpha_arg(
            (alphaCombiner >> 13u) & 7u,
            previous,
            textureColor,
            input.color,
            registers,
            textureAlphaChannel,
            rasterAlphaChannel,
            konstColor
        );
        const float alphaB = live_alpha_arg(
            (alphaCombiner >> 10u) & 7u,
            previous,
            textureColor,
            input.color,
            registers,
            textureAlphaChannel,
            rasterAlphaChannel,
            konstColor
        );
        const float alphaC = live_alpha_arg(
            (alphaCombiner >> 7u) & 7u,
            previous,
            textureColor,
            input.color,
            registers,
            textureAlphaChannel,
            rasterAlphaChannel,
            konstColor
        );
        const float alphaD = live_alpha_arg(
            (alphaCombiner >> 4u) & 7u,
            previous,
            textureColor,
            input.color,
            registers,
            textureAlphaChannel,
            rasterAlphaChannel,
            konstColor
        );
        const uint colorBias = (colorCombiner >> 16u) & 3u;
        const uint alphaBias = (alphaCombiner >> 16u) & 3u;
        float3 nextColor;
        float nextAlpha;
        if (colorBias == 3u) {
            const bool compare = ((colorCombiner >> 18u) & 1u) != 0u
                ? colorA.r == colorB.r
                : colorA.r > colorB.r;
            nextColor = colorD + (compare ? colorC : float3(0.0));
        } else {
            nextColor = colorD + mix(colorA, colorB, colorC);
            if (((colorCombiner >> 18u) & 1u) != 0u) {
                nextColor = colorD - mix(colorA, colorB, colorC);
            }
            if (colorBias == 1u) {
                nextColor += 0.5;
            } else if (colorBias == 2u) {
                nextColor -= 0.5;
            }
        }
        if (alphaBias == 3u) {
            const bool compare = ((alphaCombiner >> 18u) & 1u) != 0u
                ? alphaA == alphaB
                : alphaA > alphaB;
            nextAlpha = alphaD + (compare ? alphaC : 0.0);
        } else {
            nextAlpha = alphaD + mix(alphaA, alphaB, alphaC);
            if (((alphaCombiner >> 18u) & 1u) != 0u) {
                nextAlpha = alphaD - mix(alphaA, alphaB, alphaC);
            }
            if (alphaBias == 1u) {
                nextAlpha += 0.5;
            } else if (alphaBias == 2u) {
                nextAlpha -= 0.5;
            }
        }
        nextColor *= live_tev_scale(colorCombiner);
        nextAlpha *= live_tev_scale(alphaCombiner);
        if (((colorCombiner >> 19u) & 1u) != 0u) {
            nextColor = saturate(nextColor);
        }
        if (((alphaCombiner >> 19u) & 1u) != 0u) {
            nextAlpha = saturate(nextAlpha);
        }
        registers[(colorCombiner >> 22u) & 3u].rgb = nextColor;
        registers[(alphaCombiner >> 22u) & 3u].a = nextAlpha;
        if (stage + 1u >= stageCount) {
            break;
        }
    }
    const float4 color = registers[0];
    // Admission requires GX's exact ALWAYS/ALWAYS/AND alpha test. Eliding its
    // discard path allows the compiler to optimize opaque depth processing;
    // alpha-tested foliage and effects still use the original generic shader.
    if (!is_function_constant_defined(live_direct_stages)) {
    const uint alpha = uint(round(saturate(color.a) * 255.0));
    const bool test0 = live_alpha_compare(alpha, state.alphaTest & 255u, (state.alphaTest >> 16u) & 7u);
    const bool test1 = live_alpha_compare(alpha, (state.alphaTest >> 8u) & 255u, (state.alphaTest >> 19u) & 7u);
    bool passes;
    switch ((state.alphaTest >> 22u) & 3u) {
        case 0u: passes = test0 && test1; break;
        case 1u: passes = test0 || test1; break;
        case 2u: passes = test0 != test1; break;
        default: passes = test0 == test1; break;
    }
    if (!passes) {
        discard_fragment();
    }
    }
    return color;
}

struct PresentVarying {
    float4 position [[position]];
    float2 uv;
};

// The restored master is tagged limited-range BT.709 NV12. This path replaces
// only an admitted source Bink quad, never a generic texture or menu image.
fragment float4 live_cinematic_fragment(
    LiveVarying input [[stage_in]],
    texture2d<float> luma [[texture(0)]],
    texture2d<float> chroma [[texture(1)]],
    sampler videoSampler [[sampler(0)]]
) {
    float y = (luma.sample(videoSampler,input.uv0).r - 16.0/255.0) * (255.0/219.0);
    float2 c = (chroma.sample(videoSampler,input.uv0).rg - 128.0/255.0) * (255.0/224.0);
    return float4(clamp(float3(y + 1.5748*c.y, y - 0.187324*c.x - 0.468124*c.y,
        y + 1.8556*c.x),0.0,1.0),1.0);
}

vertex PresentVarying live_present_vertex(
    uint vertexID [[vertex_id]],
    constant float2& scale [[buffer(0)]]
) {
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0),
    };
    const float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0),
    };
    PresentVarying output;
    output.position = float4(positions[vertexID] * scale, 0.0, 1.0);
    output.uv = uvs[vertexID];
    return output;
}

fragment float4 live_present_fragment(
    PresentVarying input [[stage_in]],
    texture2d<float> source [[texture(0)]],
    sampler sourceSampler [[sampler(0)]]
) {
    return source.sample(sourceSampler, input.uv);
}
)METAL";

namespace {

constexpr size_t kCPWords = 256;
constexpr size_t kBPWords = 256;
constexpr size_t kXFWords = 0x1058;
constexpr size_t kTextureMemoryBytes = 1024 * 1024;
constexpr u32 kMem2PhysicalBase = 0x10000000u;

struct LiveVertex {
    float position[4];
    float uv[4][2];
    float indirectUV[4][2];
    float color[4];
    // Per TEV stage. For projective texgen uv holds undivided S/T and the
    // fragment stage divides by Q; otherwise Q is 1 and uv is final.
    float uvQ[4] = {1.0f, 1.0f, 1.0f, 1.0f};
};

struct alignas(16) LiveFragmentUniforms {
    float rasterColor[4] = {};
    float colorRegisters[3][4] = {};
    float konstColors[4][4] = {};
    u32 colorCombiners[4] = {};
    u32 alphaCombiners[4] = {};
    u32 textureAlphaChannels[4] = {};
    u32 rasterAlphaChannels[4] = {};
    float textureDimensions[8][4] = {};
    s32 indirectMatrices[6][4] = {};
    u32 indirectCommands[4] = {};
    u32 indirectScales[4] = {};
    u32 alphaTest = 0x3F0000u; // ALWAYS/ALWAYS for synthetic draws; decoded draws use BP F3.
    u32 indirectCount = 0u;
    u32 stageCount = 0u;
    u32 shadowBorderMask = 0u;
};
static_assert(
    sizeof(LiveFragmentUniforms) % 16u == 0u,
    "Metal fragment uniforms must preserve 16-byte alignment"
);

static u32 DirectShaderStages(const LiveFragmentUniforms& state) {
    if (state.stageCount < 1 || state.stageCount > 2 || state.indirectCount ||
        state.alphaTest != 0x3F0000u) return 0;
    for (u32 stage=0; stage<state.stageCount; ++stage)
        if (state.indirectCommands[stage]) return 0;
    return state.stageCount;
}

struct LiveDraw {
    std::vector<LiveVertex> vertices;
    std::vector<u32> indices;
    std::vector<LiveVertex> refinedVertices;
    const ProtectorGeometryProfile* geometryProfile = nullptr;
    bool indexed = false;
    // Presentation-only temporal identity. Never infer correspondence from draw
    // order: culling and repeated objects can change the list each guest frame.
    std::array<u8, CC_SHA256_DIGEST_LENGTH> motionSourceKey{};
    std::array<u8, CC_SHA256_DIGEST_LENGTH> motionMeshKey{};
    std::array<u32, 12> motionSourceArrays{};
    bool hasMotionSourceKey = false;
    ProtectorMotionInstance motionInstance{};
    // Opt-in source-to-clip evidence for bounded backdrop candidates. Never
    // participates in presentation admission or changes decoded geometry.
    std::array<u8, CC_SHA256_DIGEST_LENGTH> backdropSourcePositionKey{};
    bool hasBackdropSourcePositionKey = false;
    // One-based identity of a source-bound finite gradient-sky piece; zero is
    // ordinary geometry. This is host presentation metadata, never guest state.
    u8 finiteBackdropIdentity = 0;
    u8 finiteBackdropLowerEdgeMask = 0;
    u8 repeatingBackdropIdentity = 0;
    u8 hillBackdropIdentity = 0;
    u8 canyonSkyIdentity = 0;
    u8 citySkyIdentity = 0;
    u8 relatedCitySkyIdentity = 0;
    u8 finiteRoomIdentity = 0;
    u8 comboScheme = 0; // frame-scoped source script/text admission
    // A full-screen orthographic quad whose every stage samples a same-frame
    // copy of the whole screen (glow/blur composites). The copy already holds
    // the widened frame, so it composites 1:1 at full width.
    bool screenCopyComposite = false;
    u8 interactionPrompts = 0;
    u8 upgradeScheme = 0;
    bool upgradeActive = false, upgradeReady = false;
    std::array<std::vector<u8>, 8> textureRGBA;
    // Decoded guest textures are immutable snapshots shared by draws. A later
    // guest write must not change an earlier draw that uses the same address.
    std::array<std::shared_ptr<const std::vector<u8>>, 8> decodedPixels;
    std::array<u32, 8> textureWidths{};
    std::array<u32, 8> textureHeights{};
    u32 blendMode = 0u;
    u32 depthMode = 0u;
    u32 cullMode = 0u;
    u32 sourceVertexCount = 0u;
    u32 displayListDepth = 0u;
    bool hasNormal = false;
    bool hasVertexColor = false;
    u32 numColorChannels = 0u;
    u32 numTextureGenerators = 0u;
    u32 ambientColor = 0u;
    u32 materialColor = 0u;
    u32 colorChannel = 0u;
    u32 alphaChannel = 0u;
    std::array<u32, 10> xfChannelWords{}; // source-only proof diagnostics
    std::array<u32, 4> tevRasterSources{};
    std::array<u32, 8> textureCoordinates{};
    std::array<u32, 8> textureUnits{};
    std::array<u32, 8> textureAddresses{};
    std::array<u32, 8> textureModes{};
    std::array<u32, 8> textureFormats{};
    std::array<u32, 8> textureImage1{};
    std::array<u32, 8> textureImage2{};
    // Read-only scene-audit evidence. The current UV calculation and uploaded
    // vertices are unchanged; measure Q before deciding on a projection fix.
    std::array<std::array<float, 2>, 8> textureQBounds{};
    std::array<u32, 8> textureGenerationInfo{};
    std::array<bool, 8> textureQCaptured{};
    std::array<u32, 4> indirectCommands{};
    std::array<u32, 4> textureScaleS{};
    std::array<u32, 4> textureScaleT{};
    double viewportX = 0.0;
    double viewportY = 0.0;
    double viewportWidth = 640.0;
    double viewportHeight = 480.0;
    std::array<u32, 7> projectionWords{};
    LiveFragmentUniforms fragment;
};

struct LiveEfbCopy {
    size_t drawIndex = 0u;
    u32 sourceX = 0u;
    u32 sourceY = 0u;
    u32 width = 0u;
    u32 height = 0u;
    u32 destinationAddress = 0u;
    u32 command = 0u;
    u32 yScale = 0u;
};

// A deliberately narrow no-write proof, not an opacity heuristic. These are
// the original orthographic picture draws: RGB = texture.rgb * vertex.rgb,
// A = texture.a * vertex.a, with ordinary source-alpha blending and no depth
// writes. For finite unit colors and zero alpha the blend is destination * 1
// in every channel. Keep subtractive shadows, depth-only work, other TEV
// programs, nonzero alpha and malformed data on the normal rendering path.
// Evaluate the actual upload so presentation transforms cannot invalidate it.
static bool ZeroAlphaPictureHasNoWrites(const LiveDraw& draw,
                                       const LiveVertex* vertices, size_t count) {
    if (!vertices || !count || draw.projectionWords[6] != 1 ||
        draw.blendMode != 13501 || draw.depthMode != 15 ||
        draw.fragment.stageCount != 1 || draw.fragment.indirectCount != 0 ||
        draw.fragment.colorCombiners[0] != 64143 ||
        draw.fragment.alphaCombiners[0] != 63088 ||
        draw.fragment.textureAlphaChannels[0] != 3 ||
        draw.fragment.rasterAlphaChannels[0] != 3 ||
        draw.fragment.alphaTest != 4128768) return false;
    for (size_t index = 0; index < count; ++index) {
        const auto& vertex = vertices[index];
        if (vertex.color[3] != 0 || vertex.position[3] <= 0) return false;
        for (float value : vertex.color)
            if (!std::isfinite(value) || value < 0 || value > 1) return false;
        for (float value : vertex.position) if (!std::isfinite(value)) return false;
        for (const auto& uv : vertex.uv)
            for (float value : uv) if (!std::isfinite(value)) return false;
    }
    for (float value : draw.fragment.textureDimensions[0])
        if (!std::isfinite(value) || value <= 0) return false;
    return true;
}

struct ArtworkPreviewFrame {
    std::vector<LiveDraw> draws;
    std::vector<LiveEfbCopy> copies;
    u32 index = 0;
    u64 guestTicks = 0;
    double hostDeadline = 0;
    ProtectorCinematicFrame cinematic{};
    bool valid = false;
};

static NSDictionary* CinematicReceipt(const ProtectorCinematicFrame& movie,
    ProtectorCinematicImage* replacement = nil) {
    if (!movie.active) return @{@"active":@NO, @"presentation_frame":@(movie.presentation_frame)};
    return @{@"active":@YES, @"movie":@(movie.movie), @"guest_handle":@(movie.handle),
        @"presentation_frame":@(movie.presentation_frame), @"open_serial":@(movie.open_serial),
        @"source_width":@(movie.width), @"source_height":@(movie.height),
        @"source_frame_count":@(movie.frame_count),
        @"decoded_frame_zero_based":@(movie.decoded_frame_one_based - 1u),
        @"next_frame_one_based":@(movie.next_frame_one_based),
        @"rate_numerator":@(movie.rate_numerator), @"rate_denominator":@(movie.rate_denominator),
        @"replacement_active":@(replacement != nil),
        @"replacement_frame_zero_based":replacement ? @(replacement.frameIndex) : NSNull.null,
        @"replacement_dimensions":replacement ? @[@(replacement.luma.width),@(replacement.luma.height)] : @[]};
}

static s32 IdentifyCinematicDraw(const std::vector<LiveDraw>& draws, const ProtectorCinematicFrame& movie) {
    if (!movie.active || !movie.decoded_frame_one_based || movie.decoded_frame_one_based > movie.frame_count ||
        movie.width != 640 || (movie.height != 448 && movie.height != 480)) return -1;
    s32 found = -1;
    for (size_t index=0; index<draws.size(); ++index) {
        const auto& draw = draws[index];
        if (draw.projectionWords[6] != 1 || draw.fragment.stageCount != 4 || draw.fragment.indirectCount != 3 ||
            draw.depthMode != 23 || draw.blendMode != 285 || draw.cullMode != 0 ||
            draw.fragment.alphaTest != 4128768 || !draw.indexed || draw.vertices.size() != 4 ||
            draw.indices != std::vector<u32>({0,1,2,0,2,3}) || draw.viewportX != 0 || draw.viewportY != 0 ||
            draw.viewportWidth != 640 || (draw.viewportHeight != 448 && draw.viewportHeight != 480)) continue;
        const u32 colors[4] = {63714,1112288,587968,528623};
        const u32 alphas[4] = {324368,324352,565120,588528};
        const u32 units[4] = {4,3,0,0};
        const u32 coordinates[4] = {0,0,3,0};
        bool matches = true;
        for (size_t stage=0; stage<4; ++stage) {
            const u32 w = stage < 2 ? movie.width/2 : stage == 2 ? movie.width : 1;
            const u32 h = stage < 2 ? movie.height/2 : stage == 2 ? movie.height : 1;
            matches &= draw.textureWidths[stage] == w && draw.textureHeights[stage] == h &&
                draw.textureFormats[stage] == (stage < 3 ? 1u : 0u) && draw.textureModes[stage] == 256 &&
                draw.textureUnits[stage] == units[stage] && draw.textureCoordinates[stage] == coordinates[stage] &&
                draw.fragment.colorCombiners[stage] == colors[stage] && draw.fragment.alphaCombiners[stage] == alphas[stage];
        }
        const float corners[4][2] = {{-1,1},{1,1},{1,-1},{-1,-1}};
        for (size_t vertex=0; vertex<4; ++vertex) {
            const auto& v = draw.vertices[vertex];
            // The source quad spans the movie's pixels, not necessarily its
            // viewport: D3 is 480 high through the game's 448-high viewport.
            const float sourceY = vertex < 2 ? 1 : 1-2*(float)movie.height/draw.viewportHeight;
            matches &= v.position[3] == 1 && std::abs(v.position[0]-corners[vertex][0]) < 0.0001f &&
                std::abs(v.position[1]-sourceY) < 0.0001f &&
                std::isfinite(v.position[2]) && v.position[2] >= 0 && v.position[2] <= 1;
            for (size_t c=0; c<4; ++c) matches &= v.color[c] == 1;
            matches &= v.uv[0][0] == (corners[vertex][0]+1)*0.5f &&
                v.uv[0][1] == (1-corners[vertex][1])*0.5f;
        }
        if (matches) {
            if (found >= 0) return -1; // Ambiguous multiple movie quads never replace.
            found = (s32)index;
        }
    }
    return found;
}

static bool CinematicDisplayViewport(const std::vector<LiveEfbCopy>& copies, size_t drawCount,
                                    NSUInteger scale, NSUInteger scaleY, MTLViewport* viewport) {
    bool found = false;
    for (const auto& copy : copies) {
        if (!(copy.command & (1u << 14))) continue;
        if (found || copy.drawIndex != drawCount || copy.yScale != 256 ||
            ((copy.command >> 12) & 3) || ((copy.command >> 7) & 3) ||
            copy.sourceX || copy.sourceY || copy.width != 640 ||
            (copy.height != 448 && copy.height != 480)) return false;
        *viewport = {0,0,(double)copy.width*scale,(double)copy.height*scaleY,0,1};
        found = true;
    }
    return found;
}

static void TransformCinematicVertex(LiveVertex* vertex, double frameAspect, double filmAspect = 16.0/9.0) {
    const float x = (float)std::min(1.0,filmAspect/frameAspect);
    const float y = (float)std::min(1.0,frameAspect/filmAspect);
    // Use the full UV rectangle. Multiplying the source clip coordinates
    // retains its 480/448 overscan and would crop the restored master again.
    vertex->position[0] = (2*vertex->uv[0][0]-1)*x;
    vertex->position[1] = (1-2*vertex->uv[0][1])*y;
}

struct MotionPresentationHistory {
    ArtworkPreviewFrame previous;
    std::vector<s32> matches;
    std::vector<LiveDraw> blended;               // reused across presentations of one guest frame
    uint64_t blendedGeneration = UINT64_MAX;     // motion-state generation it was built for
    double interval = 0;
    bool ready = false;
    bool copyFencesShifted = false;
    bool paused = false;
    bool rendered = false;
    u32 renderedIndex = 0;
    double renderedFraction = 1;
    size_t matchedDraws = 0;
    size_t matchedModelDraws = 0;
    size_t matchedShadowDraws = 0;
    size_t matchedShadowModelDraws = 0;
    size_t matchedUnusedColorDraws = 0;
    size_t sceneDraws = 0;
    size_t shadowDraws = 0;
    const char* holdReason = "history-empty";
    u64 sourceFrames = 0;
    u64 generatedFrames = 0;
};

enum class WideDrawRole { Unchanged, Scene, SafeArea, ScreenFill };

static WideDrawRole ClassifyWideDraw(const LiveDraw& draw) {
    // RBNEG9's observed main view is 640x448; 640x480 also occurs in the
    // frontend. The 256-square shadow passes must never inherit the TV aspect.
    // Unknown sub-viewports retain original behavior rather than a guessed FOV.
    if (std::abs(draw.viewportX) > 0.01 || std::abs(draw.viewportY) > 0.01 ||
        std::abs(draw.viewportWidth - 640.0) > 0.01 ||
        (std::abs(draw.viewportHeight - 448.0) > 0.01 &&
         std::abs(draw.viewportHeight - 480.0) > 0.01)) return WideDrawRole::Unchanged;
    if (draw.projectionWords[6] == 0u) return WideDrawRole::Scene;
    if (draw.screenCopyComposite) return WideDrawRole::ScreenFill;
    // Solid fullscreen fades must cover the added scene margins too. Preserve
    // textured movies and menu art in the centred safe area. Deliberately admit
    // only a rectangular, uniform-color, constant-texture primitive here.
    bool solid = draw.vertices.size() >= 4u && draw.vertices.size() <= 6u;
    for (size_t stage = 0; stage < 8 && solid; ++stage) {
        if (draw.textureWidths[stage] > 1u || draw.textureHeights[stage] > 1u) solid = false;
    }
    unsigned corners = 0;
    for (const LiveVertex& vertex : draw.vertices) {
        if (!solid || vertex.position[3] == 0.0f) { solid = false; break; }
        const float x = vertex.position[0] / vertex.position[3];
        const float y = vertex.position[1] / vertex.position[3];
        if (std::abs(std::abs(x) - 1.0f) > 0.001f ||
            std::abs(std::abs(y) - 1.0f) > 0.001f ||
            std::memcmp(vertex.color, draw.vertices.front().color, sizeof(vertex.color)) != 0) {
            solid = false; break;
        }
        corners |= 1u << ((x > 0 ? 1u : 0u) | (y > 0 ? 2u : 0u));
    }
    return solid && corners == 15u ? WideDrawRole::ScreenFill : WideDrawRole::SafeArea;
}

struct SceneAntialiasBoundary {
    size_t index = 0;
    const char* reason = "no-scene";
    bool enabled = false;
};

static SceneAntialiasBoundary IdentifySceneAntialiasBoundary(
    const std::vector<LiveDraw>& draws, const std::vector<LiveEfbCopy>& copies) {
    SceneAntialiasBoundary result;
    for (size_t i = 0; i < draws.size(); ++i)
        if (ClassifyWideDraw(draws[i]) == WideDrawRole::Scene) result.index = i+1;
    if (!result.index) return result;
    // Never filter already composited orthographic UI. Unknown orderings keep
    // the existing image, rather than classifying lettering by its pixels.
    for (size_t i = 0; i < result.index; ++i) {
        if (ClassifyWideDraw(draws[i]) == WideDrawRole::SafeArea) {
            result.reason = "orthographic-before-scene-end"; return result;
        }
    }
    for (size_t i = result.index; i < draws.size(); ++i) {
        if (ClassifyWideDraw(draws[i]) == WideDrawRole::Unchanged) {
            result.reason = "unknown-overlay-viewport"; return result;
        }
    }
    bool display = false;
    for (const auto& copy : copies) {
        if (copy.command & (1u<<14u)) {
            if (copy.drawIndex != draws.size()) {
                result.reason = "nonterminal-display-copy"; return result;
            }
            display = true;
        } else if (copy.drawIndex >= result.index) {
            result.reason = "scene-copy-after-boundary"; return result;
        }
    }
    if (!display || result.index == draws.size()) {
        result.reason = "no-final-overlay-boundary"; return result;
    }
    result.enabled = true; result.reason = "scene-before-orthographic-overlay";
    return result;
}

static u8 FiniteBackdropSourceIdentity(const char* digest) {
    // Exact untransformed big-endian XYZ bytes in source vertex order. These
    // fourteen pieces are the finite vertex-colour sky in 25_01 / 26_01, not
    // the campfire sharing its dummy texture. Source evidence is recorded in
    // docs/NATIVE_FINITE_BACKDROP_BRIEF.md; hashes contain no asset geometry.
    static const char* const identities[] = {
        "0dcb7cf93707cb516d0f046aa75ddfc17d6b2e1285da53235ea0e3775f4a2923",
        "16b05915ceab24e8e09697cea7ba9c54f2520d52d2c3b02fbe70c28f41096d8b",
        "16ef8d6a3184545125e51d8288225aed29cd6c8e28c893e70637ed9392d1b3b1",
        "325266dc8db8e20a4e6e3b8c7ac3ce9b2d193fc366a7a3d79e8d2514dfa3b65d",
        "4491e1c9e0b5239a3e23dd6e71111c0b3503b45f191b350d555db13be8aa99a4",
        "82f1d7ff84e81b9c6d7b089eeed1475c225a919712beabeace3a5c3512a068fb",
        "9b253f017d033ea3d12f4917b12815b21285246678f0a6b79971ebb89a4e7756",
        "b81391a66a5a10e9bba26f81bd3395921869b0acee7ffaa8290fcfc16abf1a9f",
        "c7fcba1625dbbadd4b53d86f041e20b9255ef41001e08a59a77ab0c9d875dd11",
        "d8ec5ef1c604884e8d1edf166dab74e1caf69878794dac20a4b3614ffbf5b787",
        "d9f0dc120394eed0e9a6c51a94f987aae1af3871c29692449eb9f9988b317b27",
        "e64d6c03a74fe8f429ed4fe66bae8aa021d0548cbf8c10dd8e3f717e69ea2ba7",
        "ef2c9635d2dc5a9ca59041ef9192c18e8ac19472b2207a6d8e2df442f1e7e1c3",
        "f0ca2a5b6c6a9e9ece97d460fab97b2b4c1b0c0b2a58457a98125c280937c8e4",
    };
    if (!digest) return 0;
    for (size_t i = 0; i < sizeof(identities)/sizeof(identities[0]); ++i)
        if (!strcmp(digest, identities[i])) return (u8)(i + 1);
    return 0;
}

static bool FiniteBackdropMaterialMatches(const LiveDraw& draw) {
    return ClassifyWideDraw(draw) == WideDrawRole::Scene && draw.displayListDepth == 1 &&
        (draw.sourceVertexCount == 3 || draw.sourceVertexCount == 4) &&
        draw.blendMode == 13500 &&
        draw.depthMode == 23 && draw.cullMode == 2 && draw.fragment.stageCount == 1 &&
        draw.fragment.indirectCount == 0 && draw.fragment.colorCombiners[0] == 587951 &&
        draw.fragment.alphaCombiners[0] == 586480 && draw.fragment.alphaTest == 4128768 &&
        draw.textureWidths[0] == 64 && draw.textureHeights[0] == 64 && draw.textureFormats[0] == 14;
}

static bool FiniteBackdropExtension(const LiveDraw& draw, std::array<LiveVertex, 6>* output) {
    if (!output || !draw.finiteBackdropIdentity || !draw.finiteBackdropLowerEdgeMask ||
        draw.vertices.size() > 6 || draw.vertices.size() < 3) return false;
    std::vector<LiveVertex> edge;
    for (size_t i = 0; i < draw.vertices.size(); ++i) if (draw.finiteBackdropLowerEdgeMask & (1u << i)) {
        const auto& vertex = draw.vertices[i];
        for (float component : vertex.position) if (!std::isfinite(component)) return false;
        if (vertex.position[3] <= 0) return false;
        if (std::none_of(edge.begin(), edge.end(), [&](const LiveVertex& existing) {
            return memcmp(vertex.position, existing.position, sizeof(vertex.position)) == 0;
        }))
            edge.push_back(vertex);
    }
    if (edge.size() != 2) return false;
    auto downA = edge[0], downB = edge[1];
    downA.position[1] = std::min(downA.position[1], -downA.position[3]);
    downB.position[1] = std::min(downB.position[1], -downB.position[3]);
    if (downA.position[1] == edge[0].position[1] && downB.position[1] == edge[1].position[1]) return false;
    auto area = [](const LiveVertex& a, const LiveVertex& b, const LiveVertex& c) {
        return (b.position[0]/b.position[3]-a.position[0]/a.position[3]) *
                   (c.position[1]/c.position[3]-a.position[1]/a.position[3]) -
               (b.position[1]/b.position[3]-a.position[1]/a.position[3]) *
                   (c.position[0]/c.position[3]-a.position[0]/a.position[3]);
    };
    const auto& ids = draw.indices;
    if (draw.indexed && (ids.size() < 3 || ids[0] >= draw.vertices.size() ||
        ids[1] >= draw.vertices.size() || ids[2] >= draw.vertices.size())) return false;
    const float winding = area(draw.vertices[draw.indexed ? ids[0] : 0],
        draw.vertices[draw.indexed ? ids[1] : 1], draw.vertices[draw.indexed ? ids[2] : 2]);
    if (!std::isfinite(winding) || std::abs(winding) < 1e-8f) return false;
    *output = {edge[0], downA, downB, edge[0], downB, edge[1]};
    for (size_t i = 0; i < 6; i += 3)
        if (area((*output)[i], (*output)[i+1], (*output)[i+2]) * winding < 0)
            std::swap((*output)[i+1], (*output)[i+2]);
    return true;
}

enum class MotionDrawRole { Hold, Scene, Shadow };

static s32 ExactEfbTextureCopyIndex(const LiveDraw& draw, size_t stage,
    const std::vector<LiveEfbCopy>& copies, size_t completedCopies) {
    if (stage >= draw.textureAddresses.size()) return -1;
    // An EFB texture is not an arbitrary four-byte-per-pixel guest range.
    // RBNEG9's 256x256 R8 shadow ends before its separate 16x16 falloff image;
    // treating the mask as RGBA8 incorrectly captured that neighboring image.
    // Only substitute complete, exact images. Cropped/reinterpreted aliases
    // need an explicit format/stride/offset implementation, not a whole view.
    for (size_t i = std::min(completedCopies, copies.size()); i > 0; --i) {
        const LiveEfbCopy& copy = copies[i - 1];
        if ((copy.command & (1u << 14u)) || copy.destinationAddress == 0 ||
            draw.textureAddresses[stage] != copy.destinationAddress) continue;
        // The newest write owns this address even when its dimensions changed.
        return draw.textureWidths[stage] == copy.width && draw.textureHeights[stage] == copy.height
            ? (s32)(i - 1) : -1;
    }
    return -1;
}

static size_t MotionCopyPassIndex(const std::vector<LiveEfbCopy>& copies, size_t index) {
    return (size_t)(std::upper_bound(copies.begin(), copies.end(), index,
        [](size_t value, const LiveEfbCopy& copy) { return value < copy.drawIndex; }) - copies.begin());
}

static std::vector<MotionDrawRole> MotionDrawRoles(const std::vector<LiveDraw>& draws,
    const std::vector<LiveEfbCopy>* copies) {
    std::vector<MotionDrawRole> roles(draws.size(), MotionDrawRole::Hold);
    bool validCopies = copies != nullptr;
    size_t fence = 0;
    if (copies) for (const auto& copy : *copies) {
        if (copy.drawIndex < fence || copy.drawIndex > draws.size() ||
            ((copy.command & (1u << 14u)) && copy.drawIndex != draws.size())) validCopies = false;
        fence = copy.drawIndex;
    }
    const auto square = [](const LiveEfbCopy& copy, u32 command) {
        return copy.command == command && copy.sourceX == 0 && copy.sourceY == 0 &&
            copy.width == 256 && copy.height == 256 && copy.yScale == 256 && copy.destinationAddress != 0;
    };
    for (size_t i = 0; i < draws.size(); ++i) {
        const auto& draw = draws[i];
        if (ClassifyWideDraw(draw) == WideDrawRole::Scene) { roles[i] = MotionDrawRole::Scene; continue; }
        // Observed RBNEG9 shadow pass: save the 256-square main-view tile,
        // render perspective silhouettes, then copy the shadow texture. The
        // two orthographic clear/restore quads and unknown targets stay held.
        if (!validCopies || draw.viewportX != 0 || draw.viewportY != 0 ||
            draw.viewportWidth != 256 || draw.viewportHeight != 256 || draw.projectionWords[6] != 0) continue;
        const size_t pass = MotionCopyPassIndex(*copies, i);
        if (pass > 0 && pass < copies->size() && square((*copies)[pass - 1], 0x10063u) &&
            square((*copies)[pass], 0x1000Bu)) roles[i] = MotionDrawRole::Shadow;
    }
    return roles;
}

// RBNEG9 draws each character-shadow mask in the main view's top-left
// 256-square: copy the corner (A), clear it and draw silhouettes, copy the
// mask (B), then restore the corner from A. On a tile GPU each copy ends and
// reloads the whole 5x colour+depth pass. When the window provably touches
// neither depth nor anything outside its viewport, render it into its own
// small target before the main pass and skip A, the restore and both splits.
// Any failed condition keeps the original sequence (reason is reported).
struct ShadowWindowPlan {
    bool eligible = false;
    size_t copyA = 0, copyB = 0;   // indices into the copy list
    size_t first = 0, restore = 0; // window draws [first, restore); restore draw index
    const char* reason = "no-shadow-copies";
};

static bool ShadowDepthInert(const LiveDraw& draw) { return (draw.depthMode & 0x11u) == 0; }
static bool ShadowReplaceBlend(const LiveDraw& draw) {
    return (draw.blendMode & 0x3u) == 0 && (draw.blendMode & 0x18u) == 0x18u;
}
static bool ShadowAlphaAlways(const LiveDraw& draw) { return draw.fragment.alphaTest == 4128768u; }
static bool ShadowCornerViewport(const LiveDraw& draw) {
    return draw.viewportX == 0 && draw.viewportY == 0 && draw.viewportWidth == 256 && draw.viewportHeight == 256;
}
// An orthographic quad whose corners are exactly the viewport corners.
static bool ShadowFullViewportQuad(const LiveDraw& draw, bool checkUV) {
    if (draw.projectionWords[6] == 0u || (draw.vertices.size() != 4 && draw.vertices.size() != 6)) return false;
    unsigned corners = 0;
    for (const auto& vertex : draw.vertices) {
        if (!std::isfinite(vertex.position[3]) || vertex.position[3] == 0) return false;
        const float x = vertex.position[0] / vertex.position[3], y = vertex.position[1] / vertex.position[3];
        if (std::abs(std::abs(x) - 1) > 1e-4f || std::abs(std::abs(y) - 1) > 1e-4f) return false;
        if (checkUV && (std::abs(vertex.uv[0][0] - (x > 0 ? 1 : 0)) > 1e-5f ||
                        std::abs(vertex.uv[0][1] - (y > 0 ? 0 : 1)) > 1e-5f)) return false;
        corners |= 1u << ((x > 0 ? 1u : 0u) | (y > 0 ? 2u : 0u));
    }
    return corners == 15u;
}

// Approximate shaded area of one draw in render-target pixels: its clip-space
// bounding box within the viewport. A vertex at or behind the eye counts as
// the whole viewport (conservative). Diagnostics only.
static double DrawShadedArea(const LiveDraw& draw, const std::vector<LiveVertex>& vertices,
                             double scaleX, double scaleY) {
    if (vertices.empty()) return 0;
    double minX = 1, minY = 1, maxX = -1, maxY = -1;
    for (const auto& vertex : vertices) {
        const float w = vertex.position[3];
        if (!(w > 1e-4f)) { minX = minY = -1; maxX = maxY = 1; break; }
        const double x = vertex.position[0] / w, y = vertex.position[1] / w;
        minX = std::min(minX, x); maxX = std::max(maxX, x); minY = std::min(minY, y); maxY = std::max(maxY, y);
    }
    minX = std::max(minX, -1.0); minY = std::max(minY, -1.0); maxX = std::min(maxX, 1.0); maxY = std::min(maxY, 1.0);
    if (maxX <= minX || maxY <= minY) return 0;
    return (maxX - minX) * 0.5 * draw.viewportWidth * scaleX * (maxY - minY) * 0.5 * draw.viewportHeight * scaleY;
}

// Why a draw takes the general TEV shader, plus its stage count and blend kind.
static NSString* GeneralShaderSignature(const LiveFragmentUniforms& state, NSUInteger blendKind) {
    bool indirectCommand = false;
    for (u32 stage = 0; stage < std::min(state.stageCount, 4u); ++stage)
        indirectCommand = indirectCommand || state.indirectCommands[stage];
    NSMutableArray* reasons = [NSMutableArray array];
    if (state.stageCount > 2) [reasons addObject:@"stages>2"];
    if (state.indirectCount) [reasons addObject:@"indirect"];
    if (indirectCommand) [reasons addObject:@"indirect-command"];
    if (state.alphaTest != 0x3F0000u) [reasons addObject:@"alpha-test"];
    if (!reasons.count) [reasons addObject:@"specialization-off"];
    return [NSString stringWithFormat:@"%@ stages=%u blend=%lu", [reasons componentsJoinedByString:@"+"],
        state.stageCount, (unsigned long)blendKind];
}

static NSDictionary* ShadingSummary(double specializedArea, double generalArea,
    NSDictionary<NSString*, NSNumber*>* areas, NSDictionary<NSString*, NSNumber*>* counts, double targetPixels) {
    NSArray<NSString*>* top = [areas keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber* a, NSNumber* b) {
        return [b compare:a];
    }];
    NSMutableArray* general = [NSMutableArray array];
    for (NSString* key in top) {
        if (general.count == 5) break;
        [general addObject:@{@"signature":key, @"area_screens":@(areas[key].doubleValue / targetPixels),
            @"draws":counts[key]}];
    }
    return @{@"specialized_screens":@(specializedArea / targetPixels),
        @"general_screens":@(generalArea / targetPixels), @"top_general":general};
}

static void MarkScreenCopyComposites(std::vector<LiveDraw>& draws, const std::vector<LiveEfbCopy>& copies) {
    for (size_t i = 0; i < draws.size(); ++i) {
        LiveDraw& draw = draws[i];
        draw.screenCopyComposite = false;
        if (draw.projectionWords[6] == 0u || draw.viewportX != 0 || draw.viewportY != 0 ||
            draw.viewportWidth != 640 || (draw.viewportHeight != 448 && draw.viewportHeight != 480) ||
            !draw.fragment.stageCount || draw.fragment.indirectCount ||
            !ShadowFullViewportQuad(draw, false)) continue;
        bool composite = true;
        const size_t completed = MotionCopyPassIndex(copies, i);
        for (size_t stage = 0; stage < draw.fragment.stageCount && composite; ++stage) {
            const s32 index = ExactEfbTextureCopyIndex(draw, stage, copies, completed);
            if (index < 0) { composite = false; break; }
            const LiveEfbCopy& copy = copies[(size_t)index];
            // Whole-screen copies and their downsampled chain keep the 640:448 shape.
            composite = copy.sourceX == 0 && copy.sourceY == 0 && copy.width && copy.height &&
                (u64)copy.width * (u64)draw.viewportHeight == (u64)copy.height * 640u;
            for (const auto& vertex : draw.vertices) {
                const float x = vertex.position[0] / vertex.position[3], y = vertex.position[1] / vertex.position[3];
                composite = composite && vertex.uvQ[stage] == 1.0f &&
                    std::abs(vertex.uv[stage][0] - (x > 0 ? 1.0f : 0.0f)) <= 1e-4f &&
                    std::abs(vertex.uv[stage][1] - (y > 0 ? 0.0f : 1.0f)) <= 1e-4f;
            }
        }
        draw.screenCopyComposite = composite;
    }
}

static ShadowWindowPlan PlanShadowWindow(const std::vector<LiveDraw>& draws, const std::vector<LiveEfbCopy>& copies,
                                         size_t antialiasBoundary, s32 cinematicDraw) {
    ShadowWindowPlan plan;
    const auto square = [](const LiveEfbCopy& copy, u32 command) {
        return copy.command == command && copy.sourceX == 0 && copy.sourceY == 0 &&
            copy.width == 256 && copy.height == 256 && copy.yScale == 256 && copy.destinationAddress != 0;
    };
    size_t a = copies.size();
    for (size_t i = 0; i + 1 < copies.size(); ++i)
        if (square(copies[i], 0x10063u) && square(copies[i + 1], 0x1000Bu)) { a = i; break; }
    if (a == copies.size()) return plan;
    const LiveEfbCopy& copyA = copies[a];
    const LiveEfbCopy& copyB = copies[a + 1];
    const size_t first = copyA.drawIndex, restore = copyB.drawIndex;
    plan.reason = "window-order";
    if (!(first < restore && restore + 1 < draws.size())) return plan;
    // 1-2. Window draws: corner viewport, depth inert, no EFB-copy sampling.
    for (size_t i = first; i < restore; ++i) {
        const auto& draw = draws[i];
        plan.reason = "window-viewport";
        if (!ShadowCornerViewport(draw)) return plan;
        plan.reason = "window-depth";
        if (!ShadowDepthInert(draw)) return plan;
        plan.reason = "window-samples-copy";
        const size_t completed = MotionCopyPassIndex(copies, i);
        for (size_t stage = 0; stage < 8; ++stage)
            if (ExactEfbTextureCopyIndex(draw, stage, copies, completed) >= 0) return plan;
    }
    // 3. The first window draw replaces the whole corner.
    plan.reason = "window-not-initialised";
    const auto& clear = draws[first];
    if (!ShadowReplaceBlend(clear) || !ShadowAlphaAlways(clear) || !ShadowFullViewportQuad(clear, false)) return plan;
    // 4. The restore draw is a pure copy of A back into the corner.
    plan.reason = "restore-not-copy";
    const auto& restoreDraw = draws[restore];
    if (!ShadowCornerViewport(restoreDraw) || !ShadowDepthInert(restoreDraw) ||
        !ShadowReplaceBlend(restoreDraw) || !ShadowAlphaAlways(restoreDraw) ||
        restoreDraw.fragment.stageCount != 1 || restoreDraw.fragment.indirectCount ||
        restoreDraw.fragment.colorCombiners[0] != 589816u || restoreDraw.fragment.alphaCombiners[0] != 589792u ||
        ExactEfbTextureCopyIndex(restoreDraw, 0, copies, MotionCopyPassIndex(copies, restore)) != (s32)a ||
        !ShadowFullViewportQuad(restoreDraw, true)) return plan;
    // 5. Nothing else reads copy A.
    plan.reason = "copy-a-other-consumer";
    for (size_t i = 0; i < draws.size(); ++i) {
        if (i >= first && i <= restore) continue;
        const size_t completed = MotionCopyPassIndex(copies, i);
        for (size_t stage = 0; stage < 8; ++stage)
            if (ExactEfbTextureCopyIndex(draws[i], stage, copies, completed) == (s32)a) return plan;
    }
    // 6. No other pass boundary inside the skipped range.
    plan.reason = "boundary-inside-window";
    if ((antialiasBoundary >= first && antialiasBoundary <= restore) ||
        (cinematicDraw >= 0 && (size_t)cinematicDraw >= first && (size_t)cinematicDraw <= restore)) return plan;
    // 7. The restore writes konst alpha, the redirect leaves scene alpha in
    // the corner. Colour is identical; require that nothing later reads
    // destination alpha or copies the EFB again before display.
    plan.reason = "later-destination-alpha";
    for (size_t i = restore + 1; i < draws.size(); ++i) {
        const u32 blend = draws[i].blendMode;
        if (!(blend & 1u)) continue;
        const u32 dst = (blend >> 5) & 7u, src = (blend >> 8) & 7u;
        if (dst == 6 || dst == 7 || src == 6 || src == 7) return plan;
    }
    plan.reason = "later-efb-copy";
    for (size_t i = a + 2; i < copies.size(); ++i)
        if (!(copies[i].command & (1u << 14u))) return plan;
    plan = {true, a, a + 1, first, restore, "elided"};
    return plan;
}

using DecodedTextureKey = std::array<u32, 5>;
struct DecodedTextureEntry {
    std::vector<u8> source;
    std::vector<u8> palette;
    std::shared_ptr<const std::vector<u8>> pixels;
    u64 lastUse = 0;
    size_t size() const { return source.size() + palette.size() + pixels->size(); }
};

struct DecodedTextureCache {
    std::map<DecodedTextureKey, DecodedTextureEntry> entries;
    size_t bytes = 0;
    size_t byteLimit = 32u * 1024u * 1024u;
    size_t entryLimit = 512;
    u64 hits = 0;
    u64 misses = 0;
    u64 evictions = 0;
    u64 serial = 0;
    bool enabled = true;
};

struct DecoderState {
    std::array<u32, kCPWords> cp{};
    std::array<u32, kBPWords> bp{};
    std::array<u32, kXFWords> xf{};
    std::array<u8, kTextureMemoryBytes> textureMemory{};
    std::array<std::array<s16, 4>, 4> tevColorRegisters{};
    std::array<std::array<u16, 4>, 4> tevKonstRegisters{};
    DecodedTextureCache decodedTextures;
    bool indexedVertices = true;
    bool motionAuditEnabled = false;
    bool sceneSourceAuditEnabled = false;
    bool geometrySourceTrace = false;
    ProtectorGeometryPack* geometryPack = nil;
    u64 indexedXFLoads = 0u;

    DecoderState() {
        bp[0xFE] = 0xFFFFFFu;
    }
};

static void SetMotionSourceKey(const DecoderState& state, const u8* primitive,
                              size_t size, u32 displayListAddress, size_t offset,
                              LiveDraw* draw) {
    if (!state.motionAuditEnabled || !primitive || !size || size > UINT32_MAX) return;
    // The primitive pins exact source indices, including matrix-index bytes.
    // Attribute-array bindings distinguish source meshes using the same index
    // stream. Inline/direct changing vertices intentionally fail to match.
    std::vector<u8> identity(primitive, primitive + size);
    const auto append = [&](u32 word) {
        for (int shift = 24; shift >= 0; shift -= 8) identity.push_back((u8)(word >> shift));
    };
    const bool anchoredSkin = draw->geometryProfile && draw->geometryProfile->sourceAnchorPrefixBytes;
    append(anchoredSkin ? 0u : displayListAddress);
    // FIFO offsets drift with culling. Only a source display-list offset is an
    // identity; duplicate inline submissions remain ambiguous and are rejected.
    append(!anchoredSkin && displayListAddress ? (u32)offset : 0u);
    append(state.cp[0x50]); append(state.cp[0x60]);
    const u32 vat = primitive[0] & 7u;
    append(state.cp[0x70 + vat]); append(state.cp[0x80 + vat]); append(state.cp[0x90 + vat]);
    std::array<size_t, 2> skinArrayOffsets{};
    for (u32 attribute = 0; attribute < 12; ++attribute) {
        draw->motionSourceArrays[attribute] = state.cp[0xA0 + attribute];
        const u32 type = attribute < 4 ? (state.cp[0x50] >> (9u + 2u * attribute)) & 3u
            : (state.cp[0x60] >> (2u * (attribute - 4u))) & 3u;
        const bool indexed = type >= 2u;
        // Original CPU skinning writes into changing output buffers. Only a
        // successfully bind-anchored geometry source may omit those addresses;
        // its immutable source hash below replaces the unstable memory key.
        // Absent/direct attributes never read their CP arrays. Those registers
        // retain unrelated previous draws' bindings and cannot identify a mesh.
        if (attribute < 2) skinArrayOffsets[attribute] = identity.size();
        append(!indexed || (anchoredSkin && attribute < 4) ? 0u : state.cp[0xA0 + attribute]);
        append(indexed ? state.cp[0xB0 + attribute] & 0xFFu : 0u);
    }
    if (anchoredSkin) identity.insert(identity.end(), draw->geometryProfile->sourceAnchorSHA256.begin(),
                                     draw->geometryProfile->sourceAnchorSHA256.end());
    if (identity.size() > UINT32_MAX) return;
    CC_SHA256(identity.data(), (CC_LONG)identity.size(), draw->motionMeshKey.data());
    draw->motionSourceKey = draw->motionMeshKey;
    if (draw->motionInstance.generation) {
        const auto& skin = draw->motionInstance.skin;
        const bool sourceSkin = !anchoredSkin && displayListAddress && skin.source_draw &&
            (skin.source_words[4] & 0x3FFFFFFFu) == displayListAddress &&
            ((state.cp[0x50] >> 9u) & 3u) >= 2u && (state.cp[0xB0] & 0xFFu) == 12u &&
            state.cp[0xA0] == (skin.output_position & 0x3FFFFFFFu) &&
            (!skin.output_normal || (((state.cp[0x50] >> 11u) & 3u) >= 2u &&
                (state.cp[0xB1] & 0xFFu) == 12u && state.cp[0xA1] == (skin.output_normal & 0x3FFFFFFFu)));
        if (sourceSkin) {
            // Normalize only the exact original helper's changing output
            // arrays, after preserving the legacy mesh key for shadow guards.
            // All source records, descriptor words, indices and live formats
            // remain identity. Unknown buffers retain the old conservative key.
            for (size_t attribute = 0; attribute < 2; ++attribute) {
                if (attribute == 1 && !skin.output_normal) continue;
                const u32 original = skin.source_words[6+attribute];
                for (size_t byte = 0; byte < 4; ++byte)
                    identity[skinArrayOffsets[attribute]+byte] = (u8)(original >> (24-8*byte));
            }
            append(0x534B4E31u); append(skin.source_draw);
            for (u32 word : skin.source_words) append(word);
        }
        append(0x4F424A31u); // source-owned lifetime, not submission order
        append(draw->motionInstance.object); append(draw->motionInstance.binding);
        append((u32)(draw->motionInstance.generation >> 32));
        append((u32)draw->motionInstance.generation);
        if (identity.size() > UINT32_MAX) return;
        CC_SHA256(identity.data(), (CC_LONG)identity.size(), draw->motionSourceKey.data());
    }
    draw->hasMotionSourceKey = true;
}

static u32 MotionInitialColorRegisterReads(const LiveFragmentUniforms& fragment) {
    // Mirror live_color_arg/live_alpha_arg and their read-before-write ordering.
    // Every syntactically read input counts, even when algebra could cancel it.
    // RGB and alpha destinations are independent; later reads of an overwritten
    // component no longer depend on its initial GX register value.
    u32 available = 0xFFFu, reads = 0;
    for (u32 stage = 0; stage < 4; ++stage) {
        const u32 color = fragment.colorCombiners[stage];
        const u32 alpha = fragment.alphaCombiners[stage];
        for (u32 shift : {12u, 8u, 4u, 0u}) {
            const u32 selector = (color >> shift) & 15u;
            if (selector >= 2u && selector <= 7u) {
                const u32 reg = selector / 2u - 1u;
                reads |= available & ((selector & 1u ? 8u : 7u) << (4u * reg));
            }
        }
        for (u32 shift : {13u, 10u, 7u, 4u}) {
            const u32 selector = (alpha >> shift) & 7u;
            if (selector >= 1u && selector <= 3u)
                reads |= available & (8u << (4u * (selector - 1u)));
        }
        const u32 colorDestination = (color >> 22u) & 3u;
        const u32 alphaDestination = (alpha >> 22u) & 3u;
        if (colorDestination) available &= ~(7u << (4u * (colorDestination - 1u)));
        if (alphaDestination) available &= ~(8u << (4u * (alphaDestination - 1u)));
        if (stage + 1u >= fragment.stageCount) break;
    }
    return reads;
}

static bool MotionFragmentCompatible(const LiveFragmentUniforms& a, const LiveFragmentUniforms& b) {
    constexpr size_t end = offsetof(LiveFragmentUniforms, stageCount) + sizeof(a.stageCount);
    if (!memcmp(&a, &b, end)) return true;
    constexpr size_t colors = offsetof(LiveFragmentUniforms, colorRegisters);
    constexpr size_t afterColors = offsetof(LiveFragmentUniforms, konstColors);
    // Programs, material state and all other uniforms still match bit-for-bit.
    if (memcmp(&a, &b, colors) || memcmp((const u8*)&a + afterColors,
            (const u8*)&b + afterColors, end - afterColors)) return false;
    const u32 reads = MotionInitialColorRegisterReads(a);
    for (u32 reg = 0; reg < 3; ++reg) for (u32 component = 0; component < 4; ++component)
        if ((reads & (1u << (4u * reg + component))) &&
            memcmp(&a.colorRegisters[reg][component], &b.colorRegisters[reg][component], sizeof(float))) return false;
    return true;
}

static bool MotionStateCompatible(const LiveDraw& a, const LiveDraw& b) {
    if (a.indexed != b.indexed || a.indices != b.indices || a.vertices.size() != b.vertices.size() ||
        a.finiteBackdropIdentity != b.finiteBackdropIdentity ||
        a.finiteBackdropLowerEdgeMask != b.finiteBackdropLowerEdgeMask ||
        a.repeatingBackdropIdentity != b.repeatingBackdropIdentity ||
        a.hillBackdropIdentity != b.hillBackdropIdentity ||
        a.canyonSkyIdentity != b.canyonSkyIdentity ||
        a.citySkyIdentity != b.citySkyIdentity ||
        a.relatedCitySkyIdentity != b.relatedCitySkyIdentity ||
        a.comboScheme != b.comboScheme ||
        a.interactionPrompts != b.interactionPrompts ||
        a.upgradeScheme != b.upgradeScheme || a.upgradeActive != b.upgradeActive || a.upgradeReady != b.upgradeReady ||
        a.geometryProfile != b.geometryProfile || a.refinedVertices.size() != b.refinedVertices.size() ||
        a.blendMode != b.blendMode || a.depthMode != b.depthMode || a.cullMode != b.cullMode ||
        a.projectionWords[6] != b.projectionWords[6] || a.viewportX != b.viewportX ||
        a.viewportY != b.viewportY || a.viewportWidth != b.viewportWidth || a.viewportHeight != b.viewportHeight ||
        a.textureWidths != b.textureWidths || a.textureHeights != b.textureHeights ||
        a.textureAddresses != b.textureAddresses || a.textureModes != b.textureModes ||
        a.textureFormats != b.textureFormats || a.textureUnits != b.textureUnits ||
        a.textureCoordinates != b.textureCoordinates ||
        // The 16-byte-aligned upload struct has trailing padding. Compare its
        // actual 32-bit fields, not indeterminate padding copied by the ABI.
        !MotionFragmentCompatible(a.fragment, b.fragment)) return false;
    for (size_t stage = 0; stage < 8; ++stage) {
        // Shared decode-cache snapshots make the usual case constant time.
        if (a.decodedPixels[stage] && a.decodedPixels[stage] == b.decodedPixels[stage]) continue;
        const auto& ap = a.decodedPixels[stage] ? *a.decodedPixels[stage] : a.textureRGBA[stage];
        const auto& bp = b.decodedPixels[stage] ? *b.decodedPixels[stage] : b.textureRGBA[stage];
        if (ap != bp) return false;
    }
    return true;
}

static NSArray* MotionStateDifferences(const LiveDraw& a, const LiveDraw& b) {
    // Diagnostic only. Keep admission in MotionStateCompatible exact until a
    // source-bound reason for a changing field is demonstrated.
    NSMutableArray* fields = [NSMutableArray array];
#define MOTION_DIFFERENCE(field) if (a.field != b.field) [fields addObject:@#field]
    MOTION_DIFFERENCE(indexed); MOTION_DIFFERENCE(indices);
    MOTION_DIFFERENCE(finiteBackdropIdentity);
    MOTION_DIFFERENCE(finiteBackdropLowerEdgeMask);
    MOTION_DIFFERENCE(repeatingBackdropIdentity);
    MOTION_DIFFERENCE(hillBackdropIdentity);
    MOTION_DIFFERENCE(canyonSkyIdentity);
    MOTION_DIFFERENCE(citySkyIdentity);
    MOTION_DIFFERENCE(relatedCitySkyIdentity);
    MOTION_DIFFERENCE(comboScheme);
    MOTION_DIFFERENCE(interactionPrompts);
    MOTION_DIFFERENCE(upgradeScheme);
    MOTION_DIFFERENCE(upgradeActive);
    MOTION_DIFFERENCE(upgradeReady);
    if (a.vertices.size() != b.vertices.size()) [fields addObject:@"vertices.size"];
    MOTION_DIFFERENCE(geometryProfile);
    if (a.refinedVertices.size() != b.refinedVertices.size()) [fields addObject:@"refinedVertices.size"];
    MOTION_DIFFERENCE(blendMode); MOTION_DIFFERENCE(depthMode); MOTION_DIFFERENCE(cullMode);
    if (a.projectionWords[6] != b.projectionWords[6]) [fields addObject:@"projectionKind"];
    MOTION_DIFFERENCE(viewportX); MOTION_DIFFERENCE(viewportY);
    MOTION_DIFFERENCE(viewportWidth); MOTION_DIFFERENCE(viewportHeight);
    MOTION_DIFFERENCE(textureWidths); MOTION_DIFFERENCE(textureHeights);
    MOTION_DIFFERENCE(textureAddresses); MOTION_DIFFERENCE(textureModes);
    MOTION_DIFFERENCE(textureFormats); MOTION_DIFFERENCE(textureUnits);
    MOTION_DIFFERENCE(textureCoordinates);
#undef MOTION_DIFFERENCE
#define MOTION_FRAGMENT_DIFFERENCE(field) \
    if (memcmp(&a.fragment.field, &b.fragment.field, sizeof(a.fragment.field))) \
        [fields addObject:@"fragment." #field]
    MOTION_FRAGMENT_DIFFERENCE(rasterColor); MOTION_FRAGMENT_DIFFERENCE(colorRegisters);
    MOTION_FRAGMENT_DIFFERENCE(konstColors); MOTION_FRAGMENT_DIFFERENCE(colorCombiners);
    MOTION_FRAGMENT_DIFFERENCE(alphaCombiners); MOTION_FRAGMENT_DIFFERENCE(textureAlphaChannels);
    MOTION_FRAGMENT_DIFFERENCE(rasterAlphaChannels); MOTION_FRAGMENT_DIFFERENCE(textureDimensions);
    MOTION_FRAGMENT_DIFFERENCE(indirectMatrices); MOTION_FRAGMENT_DIFFERENCE(indirectCommands);
    MOTION_FRAGMENT_DIFFERENCE(indirectScales); MOTION_FRAGMENT_DIFFERENCE(indirectCount);
    MOTION_FRAGMENT_DIFFERENCE(stageCount);
#undef MOTION_FRAGMENT_DIFFERENCE
    for (size_t stage = 0; stage < 8; ++stage) {
        if (a.decodedPixels[stage] && a.decodedPixels[stage] == b.decodedPixels[stage]) continue;
        const auto& ap = a.decodedPixels[stage] ? *a.decodedPixels[stage] : a.textureRGBA[stage];
        const auto& bp = b.decodedPixels[stage] ? *b.decodedPixels[stage] : b.textureRGBA[stage];
        if (ap != bp) [fields addObject:[NSString stringWithFormat:@"texturePixels[%zu]", stage]];
    }
    return fields;
}

static bool MotionPositionDelta(const LiveDraw& a, const LiveDraw& b, double* maximum) {
    if (!maximum || a.vertices.empty() || a.vertices.size() != b.vertices.size()) return false;
    *maximum = 0;
    for (size_t i = 0; i < a.vertices.size(); ++i) {
        const auto& p = a.vertices[i].position;
        const auto& q = b.vertices[i].position;
        for (size_t component = 0; component < 4; ++component)
            if (!std::isfinite(p[component]) || !std::isfinite(q[component])) return false;
        // Crossing the eye/near plane makes a clip-space correspondence unsafe.
        if (p[3] <= 0.0001f || q[3] <= 0.0001f) return false;
        const double x = (double)p[0] / p[3] - (double)q[0] / q[3];
        const double y = (double)p[1] / p[3] - (double)q[1] / q[3];
        *maximum = std::max(*maximum, std::hypot(x, y));
    }
    return true;
}

static NSDictionary* MotionCorrespondenceAudit(const ArtworkPreviewFrame* previous,
    const std::vector<LiveDraw>& current, u32 frameIndex, std::vector<s32>* matches = nullptr,
    const std::vector<LiveEfbCopy>* copies = nullptr, bool detailed = true) {
    if (matches) matches->assign(current.size(), -1);
    using Key = std::array<u8, CC_SHA256_DIGEST_LENGTH>;
    std::map<Key, std::vector<size_t>> oldByKey, newByKey;
    const bool consecutive = previous && previous->valid && previous->index != UINT32_MAX &&
        frameIndex == previous->index + 1;
    const auto currentRoles = MotionDrawRoles(current, copies);
    const auto previousRoles = consecutive ? MotionDrawRoles(previous->draws, &previous->copies)
        : std::vector<MotionDrawRole>();
    if (consecutive) for (size_t i = 0; i < previous->draws.size(); ++i)
        if (previous->draws[i].hasMotionSourceKey && previousRoles[i] != MotionDrawRole::Hold)
            oldByKey[previous->draws[i].motionSourceKey].push_back(i);
    for (size_t i = 0; i < current.size(); ++i)
        if (current[i].hasMotionSourceKey && currentRoles[i] != MotionDrawRole::Hold)
            newByKey[current[i].motionSourceKey].push_back(i);
    NSUInteger scene = 0, eligible = 0, ambiguous = 0, missing = 0, incompatible = 0, discontinuous = 0;
    NSUInteger eligibleVertices = 0, sceneVertices = 0, omitted = 0;
    NSUInteger shadows = 0, eligibleShadows = 0;
    double largestDelta = 0;
    NSMutableArray* profiles = detailed ? [NSMutableArray array] : nil;
    NSMutableArray* rejections = detailed ? [NSMutableArray array] : nil;
    for (size_t i = 0; i < current.size(); ++i) {
        const auto& draw = current[i];
        if (currentRoles[i] == MotionDrawRole::Hold) continue;
        if (currentRoles[i] == MotionDrawRole::Shadow) ++shadows;
        else { ++scene; sceneVertices += draw.vertices.size(); }
        NSString* reason = nil;
        auto found = oldByKey.find(draw.motionSourceKey);
        if (!consecutive || !draw.hasMotionSourceKey || found == oldByKey.end()) {
            ++missing; reason = @"new-or-unmatched-source";
        } else {
            // A mesh can be submitted by distinct passes with different exact
            // material/depth state. Those are not competing object instances.
            std::vector<size_t> compatible;
            for (size_t oldIndex : found->second)
                if (MotionStateCompatible(previous->draws[oldIndex], draw)) compatible.push_back(oldIndex);
            if (compatible.empty()) { ++incompatible; reason = @"changed-draw-state"; }
            else if (compatible.size() != 1) { ++ambiguous; reason = @"ambiguous-source-instance"; }
            else {
                const auto& old = previous->draws[compatible.front()];
                const auto& candidates = newByKey[draw.motionSourceKey];
                const size_t reciprocal = std::count_if(candidates.begin(), candidates.end(),
                    [&](size_t index) { return MotionStateCompatible(old, current[index]); });
                double delta = 0;
                if (reciprocal != 1) { ++ambiguous; reason = @"ambiguous-source-instance"; }
                else if (!MotionPositionDelta(old, draw, &delta) || delta > 0.25) {
                    ++discontinuous; reason = @"clip-plane-or-large-screen-step";
                } else {
                    ++eligible; eligibleVertices += draw.vertices.size(); largestDelta = std::max(largestDelta, delta);
                    eligibleShadows += currentRoles[i] == MotionDrawRole::Shadow;
                    if (matches) (*matches)[i] = (s32)compatible.front();
                }
            }
        }
        if (detailed && draw.geometryProfile) {
            NSMutableDictionary* profile = [@{@"draw":@(i),
            @"profile":@(draw.geometryProfile->identity.c_str()), @"eligible":@(reason == nil),
            @"motion_role":currentRoles[i] == MotionDrawRole::Shadow ? @"shadow" : @"scene",
            @"source_position_array":@(draw.motionSourceArrays[0]),
            @"source_normal_array":@(draw.motionSourceArrays[1]),
            @"source_uv_array":@(draw.motionSourceArrays[4]),
            @"source_instance":@(draw.motionInstance.object),
            @"source_instance_generation":@(draw.motionInstance.generation),
            @"source_instance_binding":@(draw.motionInstance.binding),
            @"reason":reason ? reason : @"unique-compatible-source"} mutableCopy];
            if ([reason isEqualToString:@"changed-draw-state"] && found != oldByKey.end()) {
                NSMutableArray* differences = [NSMutableArray array];
                for (size_t oldIndex : found->second) {
                    if (differences.count >= 4) break;
                    [differences addObject:@{@"previous_draw":@(oldIndex),
                        @"fields":MotionStateDifferences(previous->draws[oldIndex], draw)}];
                }
                profile[@"state_differences"] = differences;
            }
            [profiles addObject:profile];
        }
        if (detailed && reason && rejections.count < 16) [rejections addObject:@{@"draw":@(i), @"reason":reason,
            @"vertices":@(draw.vertices.size()), @"display_list_depth":@(draw.displayListDepth)}];
        else if (reason) ++omitted;
    }
    return @{@"schema":@"protector-native.motion-correspondence-audit/v1",
        @"frame_index":@(frameIndex), @"previous_frame":consecutive ? @(previous->index) : NSNull.null,
        @"render_only_audit":@YES, @"interpolation_enabled":@NO,
        @"scene_draws":@(scene), @"scene_vertices":@(sceneVertices), @"eligible_draws":@(eligible),
        @"shadow_draws":@(shadows), @"eligible_shadow_draws":@(eligibleShadows),
        @"eligible_vertices":@(eligibleVertices), @"ambiguous_draws":@(ambiguous),
        @"unmatched_draws":@(missing), @"incompatible_draws":@(incompatible),
        @"discontinuous_draws":@(discontinuous), @"maximum_eligible_ndc_step":@(largestDelta),
        @"model_profiles":profiles ? profiles : @[], @"rejection_sample":rejections ? rejections : @[], @"omitted_rejections":@(omitted),
        @"detailed_audit":@(detailed)};
}

static bool MotionBoundaryCompatible(const float* a, const float* b) {
    if (!a || !b || a[3] <= 0.0001f || b[3] <= 0.0001f) return false;
    for (size_t component = 0; component < 4; ++component) {
        if (!std::isfinite(a[component]) || !std::isfinite(b[component])) return false;
        const double scale = std::max(component == 3 ? 0.0 : 1.0,
            std::max(std::abs((double)a[component]), std::abs((double)b[component])));
        // CPU-skinned and rigid companion pieces take different multiply/add
        // paths; observed roundoff reaches several micro-units. Retain a tight
        // relative bound as well as the unchanged subpixel screen/depth bound.
        if (std::abs((double)a[component] - b[component]) > 32 * (double)FLT_EPSILON * scale) return false;
        // Absolute screen/depth bound as well as relative float error. At a
        // 3840-wide render this is under 0.03 pixel, not a spatial seam waiver.
        if (component < 3 && std::abs((double)a[component] / a[3] -
                (double)b[component] / b[3]) > 1.0 / 65536.0) return false;
    }
    return true;
}

static bool MotionDepthlessShadowBoundaryCompatible(const float* a, const float* b,
                                                     const float* current) {
    // The admitted shadow mask has depth testing/writing disabled. Its distant
    // projection amplifies one eye-Z ulp into a much larger unused clip-Z delta
    // between CPU-skinned and rigid seams. Judge the actual screen boundary in
    // normalized space, retaining the same 32-epsilon and subpixel limits.
    // All endpoints must be inside the depth clip volume: an unused depth test
    // does not make near/far-plane clipping irrelevant.
    for (const float* p : {a, b, current}) {
        if (!p) return false;
        for (size_t c = 0; c < 4; ++c) if (!std::isfinite(p[c])) return false;
        if (p[3] <= 0.0001f || p[2] <= 0 || p[2] >= p[3]) return false;
    }
    const double wScale = std::max(std::abs((double)a[3]), std::abs((double)b[3]));
    if (std::abs((double)a[3] - b[3]) > 32 * (double)FLT_EPSILON * wScale) return false;
    for (size_t c = 0; c < 2; ++c) {
        const double x = (double)a[c] / a[3], y = (double)b[c] / b[3];
        const double delta = std::abs(x - y);
        if (delta > 32 * (double)FLT_EPSILON * std::max(1.0, std::max(std::abs(x), std::abs(y))) ||
            delta > 1.0 / 65536.0) return false;
    }
    return true;
}

// First-owner table for shared clip-space boundary vertices. Equivalent to
// std::map::emplace (the first inserted vertex owns its key) without one heap
// node per vertex per frame. Slots are stamped, so reuse needs no clearing.
class MotionBoundaryOwners {
public:
    struct Owner { u32 draw, vertex; };
    void reset(size_t keys) {
        size_t capacity = 64;
        while (capacity < keys + keys / 2 + 1) capacity <<= 1;
        if (capacity > _slots.size()) { _slots.assign(capacity, Slot{}); _stamp = 0; }
        _mask = capacity - 1;
        if (++_stamp == 0) { std::fill(_slots.begin(), _slots.end(), Slot{}); _stamp = 1; }
    }
    // Returns the existing owner, or records `owner` and returns nullptr.
    const Owner* emplace(u32 space, const std::array<u32, 4>& position, Owner owner) {
        u64 hash = 0x9E3779B97F4A7C15ull ^ space;
        for (u32 component : position) hash = (hash ^ component) * 0xFF51AFD7ED558CCDull;
        hash ^= hash >> 33;
        for (size_t index = hash & _mask;; index = (index + 1) & _mask) {
            Slot& slot = _slots[index];
            if (slot.stamp != _stamp) {
                slot = Slot{position, space, owner, _stamp};
                return nullptr;
            }
            if (slot.space == space && slot.position == position) return &slot.owner;
        }
    }
private:
    struct Slot { std::array<u32, 4> position{}; u32 space = 0; Owner owner{}; u32 stamp = 0; };
    std::vector<Slot> _slots;
    size_t _mask = 0;
    u32 _stamp = 0;
};

static std::vector<s32> GuardMotionGroups(const ArtworkPreviewFrame& previous,
    const std::vector<LiveDraw>& current, std::vector<s32> matches, NSMutableArray* diagnostics = nil,
    const std::vector<LiveEfbCopy>* copies = nullptr, NSMutableDictionary* shadowRoundoff = nil) {
    if (matches.size() != current.size()) return std::vector<s32>(current.size(), -1);
    for (size_t i = 0; i < current.size(); ++i)
        if (matches[i] < -1 || (matches[i] >= 0 && ((size_t)matches[i] >= previous.draws.size() ||
            previous.draws[matches[i]].vertices.size() != current[i].vertices.size())))
            return std::vector<s32>(current.size(), -1);
    std::vector<size_t> parent(current.size());
    std::iota(parent.begin(), parent.end(), 0);
    const auto root = [&](size_t i) {
        while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i]; }
        return i;
    };
    const auto unite = [&](size_t a, size_t b) { parent[root(b)] = root(a); };
    const auto currentRoles = MotionDrawRoles(current, copies);
    const auto previousRoles = MotionDrawRoles(previous.draws, &previous.copies);
    // Source-owned actors include pieces that do not have a refinement profile
    // and need not share exact boundary vertices (for example, separate limbs).
    // Keep the complete submitted actor at one phase. A disappearing piece also
    // invalidates the pair; never infer identity from position or draw order.
    using InstanceKey = std::tuple<u64, u32, u32>;
    const auto instanceKey = [](const LiveDraw& draw) {
        return InstanceKey{draw.motionInstance.generation, draw.motionInstance.object,
            draw.motionInstance.binding};
    };
    std::map<InstanceKey, std::vector<size_t>> instances;
    std::map<InstanceKey, size_t> previousInstances;
    for (size_t i = 0; i < current.size(); ++i)
        if (current[i].motionInstance.generation && currentRoles[i] != MotionDrawRole::Hold)
            instances[instanceKey(current[i])].push_back(i);
    for (size_t i = 0; i < previous.draws.size(); ++i)
        if (previous.draws[i].motionInstance.generation && previousRoles[i] != MotionDrawRole::Hold)
            ++previousInstances[instanceKey(previous.draws[i])];
    for (const auto& entry : instances) {
        const auto& indices = entry.second;
        for (size_t i : indices) unite(indices.front(), i);
        const bool complete = previousInstances[entry.first] == indices.size() &&
            std::all_of(indices.begin(), indices.end(), [&](size_t i) {
                return matches[i] >= 0 && instanceKey(previous.draws[matches[i]]) == entry.first;
            });
        if (!complete) for (size_t i : indices) matches[i] = -1;
    }
    std::map<std::string, std::vector<size_t>> groups;
    std::map<std::string, size_t> previousGroups;
    const auto group = [](const LiveDraw& draw) {
        const std::string& identity = draw.geometryProfile->identity;
        return identity.substr(0, identity.rfind("-draw-"));
    };
    for (size_t i = 0; i < current.size(); ++i)
        if (current[i].geometryProfile && currentRoles[i] != MotionDrawRole::Hold)
            groups[group(current[i])].push_back(i);
    for (size_t i = 0; i < previous.draws.size(); ++i)
        if (previous.draws[i].geometryProfile && previousRoles[i] != MotionDrawRole::Hold)
            ++previousGroups[group(previous.draws[i])];
    // A character's lit pieces and outline are one unit. Never move one part
    // to an intermediate pose while its companion remains at the endpoint.
    for (const auto& entry : groups) {
        const auto& name = entry.first;
        const auto& indices = entry.second;
        for (size_t i : indices) unite(indices.front(), i);
        const bool complete = previousGroups[name] == indices.size() &&
            std::all_of(indices.begin(), indices.end(), [&](size_t i) { return matches[i] >= 0; });
        if (!complete) for (size_t i : indices) matches[i] = -1;
    }
    // A source mesh may be split across material draws. Shared original clip
    // vertices must remain at one temporal phase, including at an unmatched
    // neighbor. Hold the whole connected surface instead of opening a seam.
    // Corresponding main/shadow submissions form one temporal unit even when
    // they have different projection and material state. Duplicate object
    // instances remain conservatively coupled rather than guessed by position.
    std::map<std::array<u8, CC_SHA256_DIGEST_LENGTH>, size_t> sourceOwners;
    for (size_t i = 0; i < current.size(); ++i) {
        if (currentRoles[i] == MotionDrawRole::Hold || !current[i].hasMotionSourceKey) continue;
        // Keep the pre-instance key for temporal coupling. An admitted main
        // draw must not lose its conservative link to an untyped shadow pass.
        auto inserted = sourceOwners.emplace(current[i].motionInstance.generation ?
            current[i].motionMeshKey : current[i].motionSourceKey, i);
        if (!inserted.second) unite(i, inserted.first->second);
    }
    size_t boundaryKeys = 0;
    for (size_t i = 0; i < current.size(); ++i)
        if (currentRoles[i] != MotionDrawRole::Hold) boundaryKeys += current[i].vertices.size();
    if (boundaryKeys > 1000000) return std::vector<s32>(current.size(), -1);
    thread_local MotionBoundaryOwners owners;
    owners.reset(boundaryKeys);
    std::vector<bool> boundaryMismatch(current.size(), false);
    std::vector<double> boundaryDelta(current.size(), 0);
    NSMutableDictionary* boundarySamples = diagnostics ? [NSMutableDictionary dictionary] : nil;
    size_t maskRoundoffPairs = 0;
    double maximumMaskScreenDelta = 0, maximumMaskWRelativeDelta = 0, maximumUnusedDepthDelta = 0;
    for (size_t i = 0; i < current.size(); ++i) {
        if (currentRoles[i] == MotionDrawRole::Hold) continue;
        // Equal clip coordinates in different projection spaces are not a seam.
        const size_t space = currentRoles[i] == MotionDrawRole::Shadow ? MotionCopyPassIndex(*copies, i) + 1 : 0;
        for (size_t vertexIndex = 0; vertexIndex < current[i].vertices.size(); ++vertexIndex) {
            const auto& vertex = current[i].vertices[vertexIndex];
            std::array<u32, 4> position{};
            bool finite = true;
            for (size_t component = 0; component < 4; ++component) {
                finite = finite && std::isfinite(vertex.position[component]);
                const float value = vertex.position[component] == 0 ? 0 : vertex.position[component];
                memcpy(&position[component], &value, sizeof(value));
            }
            if (!finite || vertex.position[3] <= 0.0001f) continue;
            const auto* existing = owners.emplace((u32)space, position,
                MotionBoundaryOwners::Owner{(u32)i, (u32)vertexIndex});
            if (existing) {
                const size_t owner = existing->draw;
                unite(i, owner);
                if (matches[i] >= 0 && matches[owner] >= 0) {
                    const auto& a = previous.draws[matches[i]].vertices[vertexIndex].position;
                    const auto& b = previous.draws[matches[owner]].vertices[existing->vertex].position;
                    bool compatible = MotionBoundaryCompatible(a, b);
                    if (!compatible && currentRoles[i] == MotionDrawRole::Shadow &&
                        currentRoles[owner] == MotionDrawRole::Shadow &&
                        ((current[i].depthMode | current[owner].depthMode |
                          previous.draws[matches[i]].depthMode | previous.draws[matches[owner]].depthMode) & 0x11u) == 0 &&
                        MotionDepthlessShadowBoundaryCompatible(a, b, vertex.position)) {
                        compatible = true;
                        ++maskRoundoffPairs;
                        for (size_t c = 0; c < 2; ++c)
                            maximumMaskScreenDelta = std::max(maximumMaskScreenDelta,
                                std::abs((double)a[c] / a[3] - (double)b[c] / b[3]));
                        maximumMaskWRelativeDelta = std::max(maximumMaskWRelativeDelta,
                            std::abs((double)a[3] - b[3]) / std::max(std::abs((double)a[3]), std::abs((double)b[3])));
                        maximumUnusedDepthDelta = std::max(maximumUnusedDepthDelta, std::abs((double)a[2] - b[2]));
                    }
                    if (!compatible) {
                        boundaryMismatch[i] = true;
                        if (boundarySamples) {
                            NSMutableArray* samples = boundarySamples[@(i)];
                            if (!samples) boundarySamples[@(i)] = samples = [NSMutableArray array];
                            if (samples.count < 4) [samples addObject:@{
                                @"vertex":@(vertexIndex), @"owner_draw":@(owner),
                                @"owner_vertex":@(existing->vertex), @"projection_space":@(space),
                                @"current_clip":@[@(vertex.position[0]), @(vertex.position[1]), @(vertex.position[2]), @(vertex.position[3])],
                                @"previous_clip":@[@(a[0]), @(a[1]), @(a[2]), @(a[3])],
                                @"owner_previous_clip":@[@(b[0]), @(b[1]), @(b[2]), @(b[3])],
                                @"owner_position_array":@(current[owner].motionSourceArrays[0])}];
                        }
                        for (size_t component = 0; component < 4; ++component)
                            boundaryDelta[i] = std::max(boundaryDelta[i], std::abs((double)a[component] - b[component]));
                    }
                }
            }
        }
    }
    if (shadowRoundoff && maskRoundoffPairs) {
        shadowRoundoff[@"admitted_boundary_pairs"] = @(maskRoundoffPairs);
        shadowRoundoff[@"maximum_ndc_xy_delta"] = @(maximumMaskScreenDelta);
        shadowRoundoff[@"maximum_relative_w_delta"] = @(maximumMaskWRelativeDelta);
        shadowRoundoff[@"maximum_unused_clip_z_delta"] = @(maximumUnusedDepthDelta);
        shadowRoundoff[@"depth_test_and_write_disabled"] = @YES;
        shadowRoundoff[@"all_endpoints_inside_depth_clip"] = @YES;
    }
    std::vector<bool> guarded(current.size(), false);
    for (size_t i = 0; i < current.size(); ++i)
        if (currentRoles[i] != MotionDrawRole::Hold &&
            (matches[i] < 0 || boundaryMismatch[i])) guarded[root(i)] = true;
    if (diagnostics) for (const auto& entry : groups) {
        const size_t groupRoot = root(entry.second.front());
        if (!guarded[groupRoot]) continue;
        NSMutableArray* causes = [NSMutableArray array];
        for (size_t i = 0; i < current.size(); ++i)
            if (root(i) == groupRoot && (matches[i] < 0 || boundaryMismatch[i]) && causes.count < 16)
                [causes addObject:@{@"draw":@(i), @"vertices":@(current[i].vertices.size()),
                    @"unmatched":@(matches[i] < 0), @"shared_boundary_mismatch":@((bool)boundaryMismatch[i]),
                    @"maximum_previous_clip_delta":@(boundaryDelta[i]),
                    @"boundary_samples":boundarySamples[@(i)] ? boundarySamples[@(i)] : @[],
                    @"profile":current[i].geometryProfile ? @(current[i].geometryProfile->identity.c_str()) : (id)NSNull.null,
                    @"position_array":@(current[i].motionSourceArrays[0]),
                    @"uv_array":@(current[i].motionSourceArrays[4])}];
        if (diagnostics.count < 16) [diagnostics addObject:@{@"model_group":@(entry.first.c_str()), @"causes":causes}];
    }
    for (size_t i = 0; i < current.size(); ++i) if (guarded[root(i)]) matches[i] = -1;
    return matches;
}

static NSArray* MotionSourceInstanceAudit(const std::vector<LiveDraw>& draws,
    const std::vector<s32>& matches, const std::vector<MotionDrawRole>& roles) {
    if (matches.size() != draws.size() || roles.size() != draws.size()) return nil;
    using Key = std::tuple<u64, u32, u32>;
    std::map<Key, std::array<size_t, 4>> counts;
    for (size_t i=0; i<draws.size(); ++i) {
        const auto& instance = draws[i].motionInstance;
        if (!instance.generation || roles[i] == MotionDrawRole::Hold) continue;
        auto& count = counts[{instance.generation, instance.object, instance.binding}];
        ++count[0]; count[1] += matches[i] >= 0;
        if (instance.skin.source_draw) { ++count[2]; count[3] += matches[i] >= 0; }
    }
    NSMutableArray* result = [NSMutableArray array];
    for (const auto& entry : counts) [result addObject:@{
        @"source_instance_generation":@(std::get<0>(entry.first)),
        @"source_instance":@(std::get<1>(entry.first)),
        @"source_instance_binding":@(std::get<2>(entry.first)),
        @"submitted_draws":@(entry.second[0]), @"matched_draws":@(entry.second[1]),
        @"skin_draws":@(entry.second[2]), @"matched_skin_draws":@(entry.second[3])}];
    return result;
}

// prepared: *output already holds a validated copy of this same current
// frame from an earlier presentation. Only matched draws' vertex arrays
// differ between presentations, and every component of them is rewritten,
// so reuse is bit-identical to a fresh copy and saves a deep copy of every
// draw (texture planes included) on every interpolated presentation.
static bool BlendMotionDrawsInto(const ArtworkPreviewFrame& previous,
    const std::vector<LiveDraw>& current, const std::vector<s32>& matches,
    double fraction, std::vector<LiveDraw>* output, bool prepared) {
    if (!output || !std::isfinite(fraction) || fraction < 0 || fraction > 1 ||
        matches.size() != current.size()) return false;
    if (!prepared || output->size() != current.size()) {
        for (size_t i = 0; i < current.size(); ++i)
            if (matches[i] < -1 || (matches[i] >= 0 && ((size_t)matches[i] >= previous.draws.size() ||
                    !MotionStateCompatible(previous.draws[matches[i]], current[i])))) return false;
        *output = current;
    }
    if (fraction == 1) { // exact endpoint bytes, including signed zero
        if (prepared) for (size_t i = 0; i < current.size(); ++i) if (matches[i] >= 0) {
            (*output)[i].vertices = current[i].vertices;
            (*output)[i].refinedVertices = current[i].refinedVertices;
        }
        return true;
    }
    const auto blend = [fraction](const std::vector<LiveVertex>& old,
                                 const std::vector<LiveVertex>& now, std::vector<LiveVertex>& result) {
        if (fraction == 0) { result = old; return; }
        const auto value = [fraction](float a, float b) { return (float)((double)a + ((double)b - a) * fraction); };
        for (size_t i = 0; i < result.size(); ++i) {
            for (size_t component = 0; component < 4; ++component) {
                result[i].position[component] = value(old[i].position[component], now[i].position[component]);
                result[i].color[component] = value(old[i].color[component], now[i].color[component]);
            }
            for (size_t stage = 0; stage < 4; ++stage) for (size_t axis = 0; axis < 2; ++axis) {
                result[i].uv[stage][axis] = value(old[i].uv[stage][axis], now[i].uv[stage][axis]);
                result[i].indirectUV[stage][axis] = value(old[i].indirectUV[stage][axis], now[i].indirectUV[stage][axis]);
            }
            for (size_t stage = 0; stage < 4; ++stage)
                result[i].uvQ[stage] = value(old[i].uvQ[stage], now[i].uvQ[stage]);
        }
    };
    for (size_t i = 0; i < current.size(); ++i) if (matches[i] >= 0) {
        const auto& old = previous.draws[matches[i]];
        blend(old.vertices, current[i].vertices, (*output)[i].vertices);
        blend(old.refinedVertices, current[i].refinedVertices, (*output)[i].refinedVertices);
    }
    return true;
}

static bool BlendMotionDraws(const ArtworkPreviewFrame& previous,
    const std::vector<LiveDraw>& current, const std::vector<s32>& matches,
    double fraction, std::vector<LiveDraw>* output) {
    return BlendMotionDrawsInto(previous, current, matches, fraction, output, false);
}

static NSString* MotionVertexDigest(const std::vector<LiveDraw>& draws) {
    NSMutableData* bytes = [NSMutableData data];
    for (const auto& draw : draws) {
        const u64 counts[] = {(u64)draw.vertices.size(), (u64)draw.refinedVertices.size()};
        [bytes appendBytes:counts length:sizeof(counts)];
        if (!draw.vertices.empty()) [bytes appendBytes:draw.vertices.data() length:draw.vertices.size() * sizeof(LiveVertex)];
        if (!draw.refinedVertices.empty()) [bytes appendBytes:draw.refinedVertices.data() length:draw.refinedVertices.size() * sizeof(LiveVertex)];
    }
    if (bytes.length > UINT32_MAX) return nil;
    std::array<u8, CC_SHA256_DIGEST_LENGTH> hash{};
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, hash.data());
    NSMutableString* result = [NSMutableString string];
    for (u8 value : hash) [result appendFormat:@"%02x", value];
    return result;
}

static bool MotionCopyFencesValid(const std::vector<LiveEfbCopy>& copies, size_t draws) {
    size_t previous = 0;
    for (const auto& copy : copies) {
        if (copy.drawIndex < previous || copy.drawIndex > draws ||
            ((copy.command & (1u << 14u)) && copy.drawIndex != draws)) return false;
        previous = copy.drawIndex;
    }
    return true;
}

static bool MotionCopiesCompatible(const std::vector<LiveEfbCopy>& a, size_t aDraws,
                                   const std::vector<LiveEfbCopy>& b, size_t bDraws) {
    if (!MotionCopyFencesValid(a, aDraws) || !MotionCopyFencesValid(b, bDraws)) return false;
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        if (a[i].sourceX != b[i].sourceX ||
            a[i].sourceY != b[i].sourceY || a[i].width != b[i].width || a[i].height != b[i].height ||
            a[i].destinationAddress != b[i].destinationAddress || a[i].command != b[i].command ||
            a[i].yScale != b[i].yScale) return false;
    }
    return true;
}

static void GuardMotionCopyPasses(const std::vector<LiveEfbCopy>& previous,
    const std::vector<LiveEfbCopy>& current, std::vector<s32>* matches) {
    // Culling/UI changes shift numeric copy indices. The ordered copy topology
    // is stable only if every admitted draw remains between the same fences.
    // Never match a mesh from the other side of an EFB copy, even with the same
    // source/material identity. Call only after validating the copy topology.
    for (size_t i = 0; i < matches->size(); ++i)
        if ((*matches)[i] >= 0 && MotionCopyPassIndex(previous, (size_t)(*matches)[i]) != MotionCopyPassIndex(current, i))
            (*matches)[i] = -1;
}

static NSDictionary* MotionCopyLayout(const std::vector<LiveEfbCopy>& copies, size_t draws) {
    NSMutableArray* values = [NSMutableArray arrayWithCapacity:copies.size()];
    for (const auto& copy : copies) {
        [values addObject:@{@"draw_index":@(copy.drawIndex), @"source_x":@(copy.sourceX),
            @"source_y":@(copy.sourceY), @"width":@(copy.width), @"height":@(copy.height),
            @"destination":@(copy.destinationAddress), @"command":@(copy.command), @"y_scale":@(copy.yScale)}];
    }
    return @{@"draw_count":@(draws), @"copies":values};
}

static NSArray* MotionOffscreenAudit(const ArtworkPreviewFrame& previous,
    const std::vector<LiveDraw>& current) {
    // One spatial-proof diagnostic, not admission. Inspect the source of
    // offscreen silhouettes before allowing them to share a temporal phase.
    NSMutableArray* result = [NSMutableArray array];
    for (size_t i = 0; i < current.size() && result.count < 128; ++i) {
        const auto& draw = current[i];
        if (ClassifyWideDraw(draw) != WideDrawRole::Unchanged) continue;
        NSMutableArray* candidates = [NSMutableArray array];
        for (size_t oldIndex = 0; oldIndex < previous.draws.size() && candidates.count < 8; ++oldIndex) {
            const auto& old = previous.draws[oldIndex];
            if (!draw.hasMotionSourceKey || !old.hasMotionSourceKey || old.motionSourceKey != draw.motionSourceKey) continue;
            double delta = 0;
            const bool valid = MotionPositionDelta(old, draw, &delta);
            [candidates addObject:@{@"previous_draw":@(oldIndex),
                @"compatible_state":@(MotionStateCompatible(old, draw)),
                @"valid_clip":@(valid), @"maximum_ndc_step":@(delta),
                @"state_differences":MotionStateDifferences(old, draw)}];
        }
        NSMutableArray* arrays = [NSMutableArray array];
        NSMutableArray* words = [NSMutableArray array];
        for (u32 address : draw.motionSourceArrays) [arrays addObject:@(address)];
        for (u32 word : draw.projectionWords) [words addObject:@(word)];
        [result addObject:@{@"draw":@(i), @"vertices":@(draw.vertices.size()),
            @"viewport":@[@(draw.viewportX), @(draw.viewportY), @(draw.viewportWidth), @(draw.viewportHeight)],
            @"projection_words":words, @"source_arrays":arrays,
            @"profile":draw.geometryProfile ? @(draw.geometryProfile->identity.c_str()) : (id)NSNull.null,
            @"has_source_key":@(draw.hasMotionSourceKey), @"candidates":candidates}];
    }
    return result;
}

static const std::vector<u8>& TexturePixels(const LiveDraw& draw, size_t stage) {
    return draw.decodedPixels[stage] ? *draw.decodedPixels[stage] : draw.textureRGBA[stage];
}

static NSString* InterfaceTextureKey(const std::vector<u8>& pixels, u32 width, u32 height) {
    if (!width || !height || width > 2048 || height > 2048 ||
        pixels.size() != (size_t)width * height * 4) return nil;
    std::array<u8, CC_SHA256_DIGEST_LENGTH> hash{};
    CC_SHA256(pixels.data(), (CC_LONG)pixels.size(), hash.data());
    static const char digits[] = "0123456789abcdef";
    char text[32 + 2 * CC_SHA256_DIGEST_LENGTH];
    size_t length = (size_t)snprintf(text, sizeof(text), "%ux%u-", width, height);
    for (u8 value : hash) { text[length++] = digits[value >> 4]; text[length++] = digits[value & 15]; }
    return [[NSString alloc] initWithBytes:text length:length encoding:NSASCIIStringEncoding];
}

// Decoded guest textures are immutable shared snapshots that persist across
// presentations, so their key is a function of the snapshot. Hash each one
// once per thread; an expired or reused allocation is never trusted.
static NSString* InterfaceTextureKeyForDraw(const LiveDraw& draw, size_t stage) {
    const u32 width = draw.textureWidths[stage], height = draw.textureHeights[stage];
    const auto& snapshot = draw.decodedPixels[stage];
    if (!snapshot) return InterfaceTextureKey(draw.textureRGBA[stage], width, height);
    struct Entry { std::weak_ptr<const std::vector<u8>> owner; u32 width, height; NSString* key; };
    thread_local std::unordered_map<const void*, Entry> memo;
    const auto found = memo.find(snapshot.get());
    if (found != memo.end() && found->second.width == width && found->second.height == height &&
        found->second.owner.lock() == snapshot) return found->second.key;
    NSString* key = InterfaceTextureKey(*snapshot, width, height);
    if (memo.size() >= 4096) {
        for (auto entry = memo.begin(); entry != memo.end();)
            entry = entry->second.owner.expired() ? memo.erase(entry) : std::next(entry);
        if (memo.size() >= 4096) memo.clear();
    }
    memo[snapshot.get()] = Entry{snapshot, width, height, key};
    return key;
}

#include "frontend_layout.h"
#include "shared_panel_layout.h"
#include "gallery_layout.h"
#include "gallery_model_frame.h"
#include "combo_glyphs.h"
#include "qte_glyphs.h"
#include "upgrade_glyphs.h"
#include "repeating_backdrop.h"
#include "hill_backdrop.h"
#include "canyon_sky.h"
#include "city_sky.h"
#include "related_city_sky.h"
#include "finite_room_frame.h"

// Ordered source identities from the two RBNEG9 map/zoom audits. These are
// fingerprints, not replacement pixels. A partial/reordered/unknown map never
// earns an ocean underlay, and none of its source geometry is transformed here.
static constexpr const char* kWorldMapTiles[] = {
    "256x256-2584e84b1f84cf818a443f1a17121873658957be5a60e278d8e501eb3a70a21b",
    "256x256-f315d678c2bcccec89078b592427af4c82fca23610a8cd8de0cb33c48e3e93c1",
    "256x256-dc601c24ed03b4da93a71929dc5c2d4a3156b08f3c14b19a6225fcf2a083a0bd",
    "256x256-0dbbff2feaa2d6a71eca8c95ab3b3db9870445b5c8368ef65cab758fc26194b1",
    "256x256-92665eafa45aa0b6964b1eb4908a9f9c9ac20c3f3ea91d53f3f993c614f2becf",
    "256x256-d9859f3dd40d48696a29d48718339a8cb369431d021ec09cc8d8e76d7ff28e98",
    "256x256-b250ae599c55529295e05533bff2be17fd4e3e396f968b132d5e0d7994d0cb5a",
    "256x256-98b624b2d16eb04d0391baf0dba7827f34aa3ed017a3716e44d360fd09983d77",
    "256x256-77a92fedc5179c5e4a6af1dabd897ee1c9ebbf28f81f35f79479a0f58b2c5ce1",
    "256x256-a98907faf40b567719121d0d46195caa41e15bfc4bb501763e611d49de5f5208",
    "256x256-35cb601008aa24a2e4405196c41fdba6d98c8383a487a31e68eb579905d4bd7d",
    "256x256-8ce8f2cb956fa845cf72c4fd4303a1f87c8b1328163658047a782fd1fadfb017",
    "256x256-ea859c65fcb6e364c59237214e1b238e09afee070e161184668eba9058ab4532",
    "256x256-cf21c90d1d40fc9e1cc1eee3bb42c67897cb325e39c0418bd938e56ce3495f23",
    "256x256-b5dda190819576842144984e3199caeec357a7ecfea27c878dfd5d1e93483e78",
    "256x256-0d2dbcbf1b644112fc4f192407bb49bbca91a41336d848e0cf4f5017e4393b96",
    "256x256-b2ff1721f9098032d3c0c9c01f3eecd4faa85028143d6520608954e8066d7a8c",
    "256x256-d508c437f16b5f37cae07004598e21b8a775ff16e801ee9a22996acd3b243aa7",
    "256x256-c7f277f43c5fdf5330858b0eae8405fabd0d5225bceaa7de9c1c2e54d6d15fcf",
    "256x256-d4f3746743d49fb025e25767f9a7159e352efbaad1f37073cd0c3065e913e335",
};
static constexpr const char* kWorldMapMask =
    "256x256-088045b924dd7ed92b6798832e0f8a748a31e0003d63831c6a947619ddada48d";
static constexpr const char* kWorldMapOcean =
    "32x32-854987aad57a3260417107b43a082a181151afb8c45de454eb7b90e2984ec3a3";

static bool WorldMapKeyMatches(size_t draw, NSString* primary, NSString* auxiliary) {
    if (draw >= 24 || ![primary isEqualToString:@(draw < 20 ? kWorldMapTiles[draw] : kWorldMapOcean)])
        return false;
    return draw == 6 || draw == 7 ? [auxiliary isEqualToString:@(kWorldMapMask)] : auxiliary == nil;
}

static bool WorldMapGeometryMatches(const std::vector<LiveDraw>& draws) {
    if (draws.size() < 24) return false;
    constexpr std::array<u32, 7> projection{994888909,2147483648,3146926373,0,3131299594,3212627148,1};
    auto equal = [](double a, double b) { return std::isfinite(a) && std::isfinite(b) && std::abs(a-b) < 0.00001; };
    std::array<std::array<float, 4>, 24> bounds{};
    float tint = 0, z = 0;
    for (size_t i = 0; i < 24; ++i) {
        const auto& draw = draws[i];
        const bool masked = i == 6 || i == 7;
        if (ClassifyWideDraw(draw) != WideDrawRole::SafeArea ||
            !equal(draw.viewportHeight, 448) || draw.projectionWords != projection ||
            draw.depthMode != 15 || draw.blendMode != 13501 || draw.fragment.alphaTest != 4128768 ||
            draw.fragment.indirectCount || draw.fragment.stageCount != (masked ? 2u : 1u)) return false;
        if (draw.indexed ? (draw.vertices.size() != 4 || draw.indices != std::vector<u32>{0,1,2,0,2,3})
                         : draw.vertices.size() != 6) return false;
        for (size_t stage = 0; stage < draw.fragment.stageCount; ++stage) {
            const u32 side = i < 20 ? 256 : 32;
            if (draw.textureWidths[stage] != side || draw.textureHeights[stage] != side ||
                draw.textureFormats[stage] != 14 || draw.textureCoordinates[stage] != 0 ||
                draw.textureUnits[stage] != stage || draw.textureModes[stage] != 2097360 ||
                draw.fragment.colorCombiners[stage] != (stage ? 589808u : 64143u) ||
                draw.fragment.alphaCombiners[stage] != (stage ? 63100u : masked ? 65520u : 63088u)) return false;
        }
        const auto& first = draw.vertices[0];
        if (!i) { tint = first.color[0]; z = first.position[2]; }
        if (!std::isfinite(tint) || tint < 0 || tint > 1) return false;
        const auto& third = draw.vertices[2];
        bounds[i] = {first.position[0], first.position[1], third.position[0], third.position[1]};
        const auto& b = bounds[i];
        if (!(b[0] < b[2] && b[3] < b[1])) return false;
        constexpr size_t expanded[] = {0,1,2,0,2,3};
        constexpr float uv[][2] = {{0,0},{1,0},{1,1},{0,1}};
        for (size_t v = 0; v < draw.vertices.size(); ++v) {
            const auto& vertex = draw.vertices[v];
            const size_t corner = draw.indexed ? v : expanded[v];
            if (!equal(vertex.position[0], corner == 0 || corner == 3 ? b[0] : b[2]) ||
                !equal(vertex.position[1], corner < 2 ? b[1] : b[3]) ||
                !equal(vertex.position[2], z) || !equal(vertex.position[3], 1) ||
                !equal(vertex.color[3], 1)) return false;
            for (size_t c = 0; c < 3; ++c) if (!equal(vertex.color[c], tint)) return false;
            for (size_t c = 0; c < 2; ++c) if (!equal(vertex.uv[0][c], uv[corner][c])) return false;
        }
        if (i < 20) {
            if (i % 5 && (!equal(b[0], bounds[i-1][2]) || !equal(b[1], bounds[i-1][1]) ||
                !equal(b[3], bounds[i-1][3]))) return false;
            if (i >= 5 && (!equal(b[1], bounds[i-5][3]) || !equal(b[0], bounds[i-5][0]) ||
                !equal(b[2], bounds[i-5][2]))) return false;
        } else {
            const auto& edge = bounds[(i-20)*5+4];
            if (!equal(b[0], edge[2]) || !equal(b[1], edge[1]) || !equal(b[3], edge[3])) return false;
        }
    }
    return true;
}

static MTLClearColor WorldMapOceanColor(float tint) {
    // The original 32-square edge fill is opaque RGB(167,223,255); its TEV
    // state multiplies vertex RGB. Do not bake zoom/fade tint into restored art.
    return MTLClearColorMake(167.0 / 255.0 * tint, 223.0 / 255.0 * tint, tint, 1);
}

static bool IdentifyWorldMap(const std::vector<LiveDraw>& draws, const std::vector<LiveEfbCopy>& copies) {
    if (copies.size() != 1 || copies[0].drawIndex != draws.size() || copies[0].command != 18435 ||
        copies[0].sourceX || copies[0].sourceY || copies[0].width != 640 || copies[0].height != 448 ||
        copies[0].yScale != 256 || !WorldMapGeometryMatches(draws)) return false;
    for (size_t i = 0; i < 24; ++i) {
        const auto& draw = draws[i];
        NSString* primary = InterfaceTextureKeyForDraw(draw, 0);
        NSString* auxiliary = draw.fragment.stageCount == 2 ? InterfaceTextureKeyForDraw(draw, 1) : nil;
        if (!WorldMapKeyMatches(i, primary, auxiliary)) return false;
    }
    return true;
}

#include "world_map_layout.h"

enum class NativeHudRole { Unknown, Detail, HealthFrame, EnergyFrame, WatchRing, WatchLights, WatchGlow, Foreign };

struct NativeHudTextureProfile {
    const char* primary;
    const char* auxiliary;
    NativeHudRole role;
};

// Source identities only, not extracted artwork. Verified against the typed
// texture objects in RBNEG9 common packages 99_93/94/95 and a live frame-1500
// audit. A black or white primary alone is deliberately not an icon identity.
static constexpr NativeHudTextureProfile kNativeHudTextures[] = {
    {"128x128-37c9997882c714810ce351b5957eb49e4b76f3a85da7d8b4f187cd3f05d5bae3", "128x128-da18a06e8a0b35cc0b38b4790361599af6d12c44e5f783c72c67d37935334fab", NativeHudRole::Detail},
    {"128x128-5c61ba7e7b5cc249be89045889f39228984220d84e507ad4be21c76549e6f19e", "128x128-56047d83dbbaa1e096c95079ea4d996d997f745e713a479aff3e6aaa06a271cb", NativeHudRole::WatchLights},
    {"128x128-f05569679d62206ee7a46e2310f122085ed63da5681d1acdc87b9723e8083bfb", "128x128-b6a91e35fa0ae98a6b9d7e8a025d09d5f6282408a8aaa5bf6ea8ebe6bccb93fb", NativeHudRole::WatchRing},
    // The transformed watch closes the selection aperture into an hourglass.
    // Its typed colour/coverage pair occupies the same anchor role; omitting
    // it makes the whole cluster jump back to the original safe area.
    {"128x128-c0be976ea3631efdd16a854c138b3baf98d27aad611fb4c62a5eaf8c70a2c67d", "128x128-f6a0510cd4b0b254817f0fae5da8592d0ccd5efd999cd3f2618ae8d8a01e04fe", NativeHudRole::WatchRing},
    {"64x64-6c3d61c672d5f3716b0ba03fc5c89aa910826ee9d163a2bc1325fa6663a071d8", "", NativeHudRole::WatchGlow},
    {"32x32-5276f1e17562f90b2b4716cfd777b28dff4d0f2d1a97c1afc78696cf47f76b0a", "32x32-f1e3666cfd164b164c15ef549eb8007cff486569c22e8eaf6419c3845750d25e", NativeHudRole::Detail},
    {"32x32-a13ff800fe7ef5841d1ea40ed46b1bad0f63f23b1febb57b189a0829599dbb6e", "32x32-fc4c6dafb2f53fff6aa006f64b3d686bc550679665bbf962af5b407020b96394", NativeHudRole::Detail},
    {"32x32-afd7e6b96a99c6efacd55f9885589ae59c08b1b2e4ed41a7de2d1546c4e20b49", "32x32-26a79b0e271f1e7fb416b1100ed9d25885bfd0d7aa39f1eac41d6894ea300f15", NativeHudRole::Detail},
    {"32x32-ca68d25e4d0e9641620f5d949c3ff044b71d88be00a6f0873439e6bffd896bf1", "32x32-b803fa2aad4c4436588189422e9997650ccfb7e1a304144eba897bac40233713", NativeHudRole::Detail},
    {"32x32-28ba02a1a738da7d10de418bcf94dded72a04e151926e2b06b0ffbb29d63d3e0", "32x32-433b0906a667478ff5d13729f6156ce9b0078acd532363cf2329f4f5eeb5f53d", NativeHudRole::Detail},
    {"16x32-037b6c71fe503cc0ef05e53cdb2436fe8302336ae74e0837defb90a92e5539dd", "", NativeHudRole::Detail},
    {"32x32-a500c236f02dba2bf0641d4124f17b569f38563e9527abf7d3dd4401d6ed372e", "", NativeHudRole::Detail},
    {"128x16-c1cf872dbe0c1196283bb94a5b155cc84cb5fb2baab59f198c8821f4cedec857", "", NativeHudRole::Detail},
    {"128x16-9f6b6acdd95c7b863b5423eee44e909e7a4f0b1be50d160e0b3489f3c0ba1563", "128x16-145d514c60ff95519bf527437999e72e237e12b534a3d54eb31aa59aca6668b3", NativeHudRole::HealthFrame},
    {"128x32-77662539dd5cec69aaa07f9be4c168f9548aa4a12f78760002af0dbd1e6d394d", "128x32-27b1db0bca422eb0414ed5e9cc977fa5a6406692cf727f59c8bac2bd273f65ef", NativeHudRole::EnergyFrame},
    {"32x32-74169ab1be1c130ca2b08f83d53b9e9e5d05e72c761449ae0bed76caafa44706", "32x32-23713419d1d373d4921836c39b44f8d314c86a8a4b2744136fdc0dc77d24c527", NativeHudRole::Detail},
    // Exact return-to-Ben transition pair, captured at frame 3106. The
    // alternate colour plane shares the admitted mask, not an inferred tint.
    {"32x32-c0af54ef484e5ae1de4ec3587492debf5c090403309b4604bd4c26f73ccc3ecb", "32x32-23713419d1d373d4921836c39b44f8d314c86a8a4b2744136fdc0dc77d24c527", NativeHudRole::Detail},
    {"64x64-62fb561c59d0cea247fc588f3311ee665375f35d8675b186e2792cb7dfcff88c", "64x64-8ed7a5804eef176ef500f7f763de1b37c3721a998b0c6ca4df210472889f0ed5", NativeHudRole::Detail},
    {"64x64-62fb561c59d0cea247fc588f3311ee665375f35d8675b186e2792cb7dfcff88c", "64x64-6c3255d57c7bbbba24c160e30953396738cc465184c0fabad3290dbb4d6aa7bc", NativeHudRole::Detail},
    {"64x64-62fb561c59d0cea247fc588f3311ee665375f35d8675b186e2792cb7dfcff88c", "64x64-33bf77424826765d18bbe61a0dfc826d7430b73fe3f22796d87cc1573ca8bcb4", NativeHudRole::Detail},
    {"64x64-62fb561c59d0cea247fc588f3311ee665375f35d8675b186e2792cb7dfcff88c", "64x64-ddf149d43376776e69ae51aaad0d6520fb4ce3dd988505a82b3aa05a7c08fd35", NativeHudRole::Detail},
    {"64x64-62fb561c59d0cea247fc588f3311ee665375f35d8675b186e2792cb7dfcff88c", "64x64-4157a1ac113e60eb8c6761b4ae629089a0e7645946fc4e47d6f7bedd4a0a272a", NativeHudRole::Detail},
    {"64x64-62fb561c59d0cea247fc588f3311ee665375f35d8675b186e2792cb7dfcff88c", "64x64-fe184cc1e365b85b7c7fc10faa398548ac3277aaa0f605d75c726a382ea860f8", NativeHudRole::Detail},
};

static NativeHudRole NativeHudRoleForKeys(NSString* primary, NSString* auxiliary) {
    for (const auto& profile : kNativeHudTextures)
        if ([primary isEqualToString:@(profile.primary)] && [auxiliary isEqualToString:@(profile.auxiliary)])
            return profile.role;
    return NativeHudRole::Unknown;
}

static bool NativeHudDrawStateMatches(const LiveDraw& draw, NativeHudRole role = NativeHudRole::Unknown) {
    if (ClassifyWideDraw(draw) != WideDrawRole::SafeArea ||
        std::abs(draw.viewportHeight - 448) > 0.01 || draw.depthMode != 15 ||
        (draw.blendMode != 13501 && draw.blendMode != 13373) ||
        draw.fragment.alphaTest != 4128768 || draw.fragment.indirectCount ||
        (draw.fragment.stageCount != 1 && draw.fragment.stageCount != 2)) return false;
    if (draw.indexed) {
        if (draw.vertices.size() != 4 || draw.indices != std::vector<u32>{0,1,2,0,2,3}) return false;
    } else if (draw.vertices.size() != 6) return false;
    for (const auto& vertex : draw.vertices) {
        for (float value : vertex.position) if (!std::isfinite(value)) return false;
        if (std::abs(vertex.position[3] - 1) > 0.00001) return false;
        // The source cluster may pulse/rotate/fill but remains in this bounded
        // upper-left region. Right-player and frontend uses are not admitted.
        const double x = (vertex.position[0] + 1) * 320;
        const double y = (1 - vertex.position[1]) * 224;
        // The original 33_03 health frame reaches x=318 (118+200).
        // The old 310 cutoff rejected that exact source-bound anchor and
        // returned the entire HUD to its large 4:3 placement. Admit the full
        // left half, still excluding right-player geometry. Source texture
        // pairs, TEV state and the complete anchor cluster remain mandatory.
        if (role == NativeHudRole::WatchGlow) {
            // Exact single-plane watch glow, captured on RJ at frame 5885.
            // Its rotating/pulsing corners exceed the generic detail box.
            // A separate bounded envelope never broadens arbitrary details.
            if (std::hypot(x - 65, y - 74) > 160) return false;
        } else if (role == NativeHudRole::WatchLights) {
            // Alien selection rotates/pulses this exact source texture pair
            // around (65,74). Captured cycling frame 2908 reaches y=173:
            // the general y=170 guard incorrectly dropped the whole cluster.
            // Bound its rotational envelope, not the unrotated HUD rectangle.
            if (std::hypot(x - 65, y - 74) > 112) return false;
        } else if (x < -32 || x > 320 || y < -32 || y > 170) return false;
    }
    if (role == NativeHudRole::WatchGlow) {
        double x=0,y=0;
        for (const auto& vertex : draw.vertices) {
            x+=(vertex.position[0]+1)*320;
            y+=(1-vertex.position[1])*224;
        }
        // Indexed quads have four unique corners; expanded triangles weight
        // opposite corners equally and retain the same source center.
        if (std::hypot(x/draw.vertices.size()-65,y/draw.vertices.size()-74)>2 ||
            draw.fragment.stageCount!=1) return false;
    }
    for (size_t stage = 0; stage < draw.fragment.stageCount; ++stage) {
        if (draw.textureFormats[stage] != 14 || draw.textureCoordinates[stage] != 0 ||
            draw.textureUnits[stage] != stage) return false;
        if (stage == 0 && (draw.fragment.colorCombiners[0] != 64143 ||
            draw.fragment.alphaCombiners[0] != (draw.fragment.stageCount == 1 ? 63088u : 65520u))) return false;
        if (stage == 1 && (draw.fragment.colorCombiners[1] != 589808 ||
            draw.fragment.alphaCombiners[1] != 63100)) return false;
    }
    return true;
}

struct NativeHudAdmission {
    std::vector<bool> draws;
    std::array<size_t, 8> roleCounts{};
    size_t count = 0;
    const char* reason = "anchor-cluster-absent";
    bool partial = false;          // admitted from remembered anchor positions
    size_t softDraws = 0;          // identified HUD draws whose TEV/blend/bounds left the strict envelope
    size_t contained = 0;          // unidentified quads inside the HUD span that move with it
    size_t foreign = 0;            // other draws inside the span, left untouched
    std::array<bool, 4> anchorSeen{};
    std::array<std::array<double, 2>, 4> anchorCentre{};
};

// Geometry of an orthographic HUD-style quad in 640x448 source pixels. State
// (TEV, blend, alpha test) is deliberately not part of HUD identity: pickups
// and damage flash, tint or pulse the same source textures.
static bool CoversSourceFrame(const LiveDraw& draw);

struct NativeHudQuadFacts {
    bool ok = false;
    double minX = 0, maxX = 0, minY = 0, maxY = 0, cx = 0, cy = 0;
};

static NativeHudQuadFacts NativeHudQuad(const LiveDraw& draw) {
    NativeHudQuadFacts facts;
    if (ClassifyWideDraw(draw) != WideDrawRole::SafeArea || std::abs(draw.viewportHeight - 448) > 0.01) return facts;
    if (draw.indexed) {
        if (draw.vertices.size() != 4 || draw.indices != std::vector<u32>{0,1,2,0,2,3}) return facts;
    } else if (draw.vertices.size() != 6) return facts;
    facts.minX = facts.minY = INFINITY; facts.maxX = facts.maxY = -INFINITY;
    for (const auto& vertex : draw.vertices) {
        for (float value : vertex.position) if (!std::isfinite(value)) return facts;
        if (std::abs(vertex.position[3] - 1) > 0.00001) return facts;
        const double x = (vertex.position[0] + 1) * 320, y = (1 - vertex.position[1]) * 224;
        facts.minX = std::min(facts.minX, x); facts.maxX = std::max(facts.maxX, x);
        facts.minY = std::min(facts.minY, y); facts.maxY = std::max(facts.maxY, y);
        facts.cx += x; facts.cy += y;
    }
    facts.cx /= draw.vertices.size(); facts.cy /= draw.vertices.size();
    facts.ok = true;
    return facts;
}

static int NativeHudAnchorSlot(NativeHudRole role) {
    switch (role) {
        case NativeHudRole::HealthFrame: return 0;
        case NativeHudRole::EnergyFrame: return 1;
        case NativeHudRole::WatchRing: return 2;
        case NativeHudRole::WatchLights: return 3;
        default: return -1;
    }
}

// Anchor positions from the last fully admitted source frame. A HUD whose
// anchors are partly unrecognisable for a moment (a pickup's new texture
// plane, a flash) but whose remaining anchors have not moved is still the
// same HUD: keep it in place instead of snapping it back to 4:3.
struct NativeHudMemory {
    bool valid = false;
    u32 frame = 0;
    std::array<std::array<double, 2>, 4> anchorCentre{};
};
static constexpr u32 kNativeHudCarryFrames = 45;   // ~1.5 s of source frames
static constexpr double kNativeHudCarryTolerance = 8; // source pixels

static NativeHudAdmission AdmitNativeHudRoles(std::vector<NativeHudRole> roles,
    const std::vector<NativeHudQuadFacts>* facts = nullptr, const std::vector<LiveDraw>* draws = nullptr,
    const NativeHudMemory* memory = nullptr, u32 frameIndex = 0) {
    NativeHudAdmission result;
    result.draws.resize(roles.size(), false);
    auto& counts = result.roleCounts;
    size_t first = roles.size(), last = 0;
    for (size_t index = 0; index < roles.size(); ++index) {
        const int slot = NativeHudAnchorSlot(roles[index]);
        if (slot < 0) continue;
        ++counts[(size_t)roles[index]];
        result.anchorSeen[slot] = true;
        if (facts && (*facts)[index].ok) result.anchorCentre[slot] = {(*facts)[index].cx, (*facts)[index].cy};
        first = std::min(first, index);
        last = std::max(last, index);
    }
    size_t seen = 0;
    for (auto role : {NativeHudRole::HealthFrame, NativeHudRole::EnergyFrame,
                     NativeHudRole::WatchRing, NativeHudRole::WatchLights}) {
        if (counts[(size_t)role] > 1) { result.reason = "duplicate-anchor"; return result; }
        seen += counts[(size_t)role];
    }
    if (seen < 4) {
        bool carried = memory && memory->valid && facts && seen >= 2 && frameIndex >= memory->frame &&
            frameIndex - memory->frame <= kNativeHudCarryFrames;
        for (int slot = 0; carried && slot < 4; ++slot)
            if (result.anchorSeen[slot] &&
                std::hypot(result.anchorCentre[slot][0] - memory->anchorCentre[slot][0],
                    result.anchorCentre[slot][1] - memory->anchorCentre[slot][1]) > kNativeHudCarryTolerance)
                carried = false;
        if (!carried) return result;
        result.partial = true;
    }
    const auto detail=[](NativeHudRole role) { return role==NativeHudRole::Detail || role==NativeHudRole::WatchGlow; };
    while (first && detail(roles[first - 1])) --first;
    while (last + 1 < roles.size() && detail(roles[last + 1])) ++last;
    if (last - first >= 40) { result.reason = "cluster-too-large"; return result; }
    for (size_t index = first; index <= last; ++index) {
        if (roles[index] != NativeHudRole::Unknown) continue;
        // An unidentified small quad inside the HUD region belongs to it (a
        // pickup icon, a flash layer); anything else in the span is left as
        // the source drew it and no longer rejects the whole HUD.
        const NativeHudQuadFacts* quad = facts && (*facts)[index].ok ? &(*facts)[index] : nullptr;
        const bool contained = quad && draws && result.contained < 6 &&
            quad->minX >= -60 && quad->maxX <= 330 && quad->minY >= -60 && quad->maxY <= 200 &&
            !CoversSourceFrame((*draws)[index]);
        roles[index] = contained ? NativeHudRole::Detail : NativeHudRole::Foreign;
        ++(contained ? result.contained : result.foreign);
        ++counts[(size_t)roles[index]];
    }
    for (size_t index = first; index <= last; ++index)
        if (roles[index] != NativeHudRole::Foreign) { result.draws[index] = true; ++result.count; }
    result.reason = result.partial ? "carried-anchor-cluster" : "source-bound-cluster";
    return result;
}

static NativeHudAdmission IdentifyNativeHud(const std::vector<LiveDraw>& draws,
                                            const NativeHudMemory* memory = nullptr, u32 frameIndex = 0) {
    std::vector<NativeHudRole> roles(draws.size(), NativeHudRole::Unknown);
    std::vector<NativeHudQuadFacts> facts(draws.size());
    size_t softDraws = 0;
    for (size_t index = 0; index < draws.size(); ++index) {
        const auto& draw = draws[index];
        facts[index] = NativeHudQuad(draw);
        const auto& quad = facts[index];
        // Cheap geometry filtering stays ahead of texture hashing. Identity is
        // the exact source texture pair; state only marks a soft match.
        if (!quad.ok || draw.fragment.indirectCount ||
            (draw.fragment.stageCount != 1 && draw.fragment.stageCount != 2) ||
            quad.cx < -40 || quad.cx > 330 || quad.cy < -40 || quad.cy > 200) continue;
        NSString* first = InterfaceTextureKeyForDraw(draw, 0);
        NSString* second = draw.fragment.stageCount == 2 ? InterfaceTextureKeyForDraw(draw, 1) : @"";
        const auto role = NativeHudRoleForKeys(first, second);
        if (role == NativeHudRole::Unknown) continue;
        roles[index] = role;
        if (!NativeHudDrawStateMatches(draw, role)) ++softDraws;
    }
    auto result = AdmitNativeHudRoles(std::move(roles), &facts, &draws, memory, frameIndex);
    result.softDraws = softDraws;
    return result;
}

static void TransformNativeHudVertex(LiveVertex* vertex, CGSize size, CGRect destination) {
    const double sourceX = (vertex->position[0] + 1) * 320;
    const double sourceY = (1 - vertex->position[1]) * 224;
    const double x = destination.origin.x + (sourceX - 1) * destination.size.width / 277;
    const double y = destination.origin.y + (sourceY - 14) * destination.size.height / 120;
    vertex->position[0] = (float)(2 * x / size.width - 1);
    vertex->position[1] = (float)(1 - 2 * y / size.height);
}

static bool InterfaceAuditSourceKeyValid(NSString* key) {
    if (!key || key.length > 74) return false;
    NSRegularExpression* pattern = [NSRegularExpression regularExpressionWithPattern:
        @"^[1-9][0-9]{0,3}x[1-9][0-9]{0,3}-[0-9a-f]{64}\\z" options:0 error:nil];
    if ([pattern numberOfMatchesInString:key options:0 range:NSMakeRange(0,key.length)] != 1) return false;
    NSArray<NSString*>* dimensions = [[key componentsSeparatedByString:@"-"].firstObject componentsSeparatedByString:@"x"];
    return dimensions[0].integerValue <= 2048 && dimensions[1].integerValue <= 2048;
}

#include "combat_hud.h"
#include "combat_move_labels.h"

static bool InterfaceAuditContainsSource(const std::vector<LiveDraw>& draws, NSString* key) {
    // Optional diagnostic trigger only. It never admits artwork or changes a
    // game state. Match only draws/stages the existing bounded audit can retain.
    if (!InterfaceAuditSourceKeyValid(key)) return false;
    NSArray<NSString*>* dimensions = [[key componentsSeparatedByString:@"-"].firstObject componentsSeparatedByString:@"x"];
    const u32 width = (u32)dimensions[0].integerValue, height = (u32)dimensions[1].integerValue;
    size_t orthographic = 0;
    for (const auto& draw : draws) {
        if (!draw.projectionWords[6]) continue;
        if (++orthographic > 256) break;
        for (size_t stage = 0; stage < std::min((size_t)draw.fragment.stageCount,(size_t)8); ++stage) {
            if (draw.textureWidths[stage] != width || draw.textureHeights[stage] != height) continue;
            if ([InterfaceTextureKeyForDraw(draw, stage) isEqualToString:key]) return true;
        }
    }
    return false;
}

// Dense original rooms (51_03 submits over 3300 draws) exceed the old
// 2048-draw observer limit. Keep discovery and capture on one finite bound;
// this opt-in diagnostic does not change the game's rendering budget.
static constexpr size_t kMaterialAuditMaxDraws = 4096;

static std::vector<size_t> MaterialAuditDrawIndices(const std::vector<LiveDraw>& draws, NSString* key) {
    // Separate from the orthographic UI observer: animated scene materials
    // must be matched by exact decoded pixels, never by a semantic guess.
    std::vector<size_t> result;
    if (draws.size() > kMaterialAuditMaxDraws || !InterfaceAuditSourceKeyValid(key)) return result;
    NSArray<NSString*>* dimensions = [[key componentsSeparatedByString:@"-"].firstObject componentsSeparatedByString:@"x"];
    const u32 width = (u32)dimensions[0].integerValue, height = (u32)dimensions[1].integerValue;
    for (size_t index = 0; index < draws.size(); ++index) {
        const auto& draw = draws[index];
        // This backend has four direct TEV stages. The other four texture
        // bindings belong to indirect inputs, not extra combiner registers.
        if (draw.fragment.stageCount > 4) continue;
        for (size_t stage = 0; stage < draw.fragment.stageCount; ++stage) {
            if (draw.textureWidths[stage] == width && draw.textureHeights[stage] == height &&
                [InterfaceTextureKeyForDraw(draw, stage) isEqualToString:key]) {
                result.push_back(index);
                break;
            }
        }
    }
    return result;
}

static NSDictionary* InterfaceSourceAudit(const std::vector<LiveDraw>& draws,
    const std::vector<LiveEfbCopy>& copies, NSMutableDictionary<NSString*, NSData*>* textures) {
    // Source discovery only. Orthographic is not synonymous with HUD: retain
    // fades, movies, menus and unknown offscreen passes as distinct observations.
    // Caps bound both the report and copied pixels; omitted data is explicit.
    NSMutableArray* records = [NSMutableArray array];
    size_t omittedDraws = 0, omittedVertices = 0, textureBytes = 0, vertices = 0;
    const auto number = [](float value) -> id { return std::isfinite(value) ? @(value) : (id)NSNull.null; };
    for (size_t index = 0; index < draws.size(); ++index) {
        const LiveDraw& draw = draws[index];
        if (draw.projectionWords[6] == 0u) continue;
        if (records.count >= 256) { ++omittedDraws; continue; }
        NSMutableArray* points = [NSMutableArray array];
        for (const LiveVertex& vertex : draw.vertices) {
            if (points.count >= 128 || vertices >= 8192) { ++omittedVertices; continue; }
            NSMutableArray* uv = [NSMutableArray array];
            for (size_t stage = 0; stage < 4; ++stage)
                [uv addObject:@[number(vertex.uv[stage][0]), number(vertex.uv[stage][1])]];
            [points addObject:@{@"clip":@[number(vertex.position[0]), number(vertex.position[1]),
                number(vertex.position[2]), number(vertex.position[3])],
                @"color":@[number(vertex.color[0]), number(vertex.color[1]),
                    number(vertex.color[2]), number(vertex.color[3])], @"uv":uv}];
            ++vertices;
        }
        NSMutableArray* stages = [NSMutableArray array];
        for (size_t stage = 0; stage < std::min((size_t)draw.fragment.stageCount, (size_t)8); ++stage) {
            const auto& pixels = TexturePixels(draw, stage);
            NSString* key = InterfaceTextureKeyForDraw(draw, stage);
            if (key && !textures[key] && textureBytes + pixels.size() <= 64 * 1024 * 1024) {
                textures[key] = [NSData dataWithBytes:pixels.data() length:pixels.size()];
                textureBytes += pixels.size();
            }
            [stages addObject:@{@"stage":@(stage), @"source_key":key ? key : (id)NSNull.null,
                @"pixels_included":@(key && textures[key]), @"address":@(draw.textureAddresses[stage]),
                @"width":@(draw.textureWidths[stage]), @"height":@(draw.textureHeights[stage]),
                @"gx_format":@(draw.textureFormats[stage]), @"gx_mode":@(draw.textureModes[stage]),
                @"texture_unit":@(draw.textureUnits[stage]), @"uv_set":@(draw.textureCoordinates[stage]),
                @"color_combiner":@(draw.fragment.colorCombiners[stage]),
                @"alpha_combiner":@(draw.fragment.alphaCombiners[stage])}];
        }
        NSMutableArray* projection = [NSMutableArray array];
        for (u32 word : draw.projectionWords) [projection addObject:@(word)];
        NSMutableArray* indices = [NSMutableArray array];
        for (size_t i = 0; i < std::min(draw.indices.size(), (size_t)384); ++i) [indices addObject:@(draw.indices[i])];
        const auto role = ClassifyWideDraw(draw);
        [records addObject:@{@"draw_index":@(index),
            @"role":role == WideDrawRole::ScreenFill ? @"screen-fill" :
                role == WideDrawRole::SafeArea ? @"centred-4:3" : @"unknown-offscreen",
            @"viewport":@[@(draw.viewportX), @(draw.viewportY), @(draw.viewportWidth), @(draw.viewportHeight)],
            @"projection_words":projection, @"blend_mode":@(draw.blendMode), @"depth_mode":@(draw.depthMode),
            @"alpha_test":@(draw.fragment.alphaTest), @"vertex_count":@(draw.vertices.size()),
            @"vertices":points, @"indexed":@(draw.indexed), @"index_count":@(draw.indices.size()),
            @"indices":indices, @"textures":stages}];
    }
    return @{@"schema":@"protector-native.interface-source-audit/v1",
        @"scope":@"source orthographic draws; semantic HUD roles are not inferred",
        @"draws":records, @"total_draws":@(draws.size()), @"omitted_orthographic_draws":@(omittedDraws),
        @"omitted_vertices":@(omittedVertices), @"texture_bytes":@(textureBytes),
        @"texture_count":@(textures.count), @"copy_layout":MotionCopyLayout(copies, draws.size()),
        @"source_vertices_immutable":@YES, @"texture_encoding":@"straight RGBA8; original decoded pixels"};
}

// Per-frame widescreen classification evidence. Counts only; it never changes
// a role. "Near main" isolates the main 640-wide view with a shifted origin or
// a few pixels of size change, which the exact classifier leaves unwidened.
struct WideFrameSummary {
    struct Viewport { double x = 0, y = 0, width = 0, height = 0; bool perspective = false; size_t draws = 0; };
    size_t scene = 0, safeArea = 0, screenFill = 0, unchanged = 0;
    size_t unchangedPerspective = 0, unchangedOrthographic = 0;
    size_t nearMainUnchanged = 0;
    size_t fullFrameOverlays = 0;
    std::vector<Viewport> unchangedViewports;
    size_t omittedViewports = 0;
};

static bool NearMainViewport(const LiveDraw& draw) {
    return std::abs(draw.viewportWidth - 640.0) <= 16.0 &&
        (std::abs(draw.viewportHeight - 448.0) <= 16.0 || std::abs(draw.viewportHeight - 480.0) <= 16.0) &&
        std::abs(draw.viewportX) <= 64.0 && std::abs(draw.viewportY) <= 64.0;
}

static bool CoversSourceFrame(const LiveDraw& draw) {
    if (draw.vertices.empty()) return false;
    float left = INFINITY, right = -INFINITY, bottom = INFINITY, top = -INFINITY;
    for (const LiveVertex& vertex : draw.vertices) {
        if (!std::isfinite(vertex.position[3]) || vertex.position[3] == 0.0f) return false;
        const float x = vertex.position[0] / vertex.position[3], y = vertex.position[1] / vertex.position[3];
        if (!std::isfinite(x) || !std::isfinite(y)) return false;
        left = std::min(left, x); right = std::max(right, x);
        bottom = std::min(bottom, y); top = std::max(top, y);
    }
    return left <= -0.99f && right >= 0.99f && bottom <= -0.99f && top >= 0.99f;
}

static WideFrameSummary SummarizeWideDraws(const std::vector<LiveDraw>& draws) {
    WideFrameSummary summary;
    for (const LiveDraw& draw : draws) {
        const auto role = ClassifyWideDraw(draw);
        const bool perspective = draw.projectionWords[6] == 0u;
        if (role == WideDrawRole::Scene) ++summary.scene;
        else if (role == WideDrawRole::ScreenFill) ++summary.screenFill;
        else if (role == WideDrawRole::SafeArea) {
            ++summary.safeArea;
            if (CoversSourceFrame(draw)) ++summary.fullFrameOverlays;
        } else {
            ++summary.unchanged;
            ++(perspective ? summary.unchangedPerspective : summary.unchangedOrthographic);
            if (NearMainViewport(draw)) ++summary.nearMainUnchanged;
            auto existing = std::find_if(summary.unchangedViewports.begin(), summary.unchangedViewports.end(),
                [&](const WideFrameSummary::Viewport& viewport) {
                    return viewport.x == draw.viewportX && viewport.y == draw.viewportY &&
                        viewport.width == draw.viewportWidth && viewport.height == draw.viewportHeight &&
                        viewport.perspective == perspective;
                });
            if (existing != summary.unchangedViewports.end()) ++existing->draws;
            else if (summary.unchangedViewports.size() < 8)
                summary.unchangedViewports.push_back({draw.viewportX, draw.viewportY,
                    draw.viewportWidth, draw.viewportHeight, perspective, 1});
            else ++summary.omittedViewports;
        }
    }
    return summary;
}

static NSDictionary* WideFrameReceipt(const WideFrameSummary& summary) {
    NSMutableArray* viewports = [NSMutableArray array];
    for (const auto& viewport : summary.unchangedViewports)
        [viewports addObject:@{@"viewport":@[@(viewport.x), @(viewport.y), @(viewport.width), @(viewport.height)],
            @"projection":viewport.perspective ? @"perspective" : @"orthographic", @"draws":@(viewport.draws)}];
    return @{@"scene":@(summary.scene), @"safe_area":@(summary.safeArea), @"screen_fill":@(summary.screenFill),
        @"unchanged":@(summary.unchanged), @"unchanged_perspective":@(summary.unchangedPerspective),
        @"unchanged_orthographic":@(summary.unchangedOrthographic),
        @"near_main_unchanged":@(summary.nearMainUnchanged),
        @"full_frame_overlays":@(summary.fullFrameOverlays),
        @"unchanged_viewports":viewports, @"omitted_viewports":@(summary.omittedViewports)};
}

// Diagnostic triggers for transient presentation changes. A trigger records
// evidence only; no admission or layout depends on it.
struct PresentationTransitionState {
    bool hudAdmitted = false;
    bool gameplayScene = false;
    size_t nearMainUnchanged = 0;
    size_t fullFrameOverlays = 0;
};

enum PresentationTransitionFlags : unsigned {
    PresentationTransitionHudLost = 1u << 0u,
    PresentationTransitionHudRestored = 1u << 1u,
    PresentationTransitionNearMainAppeared = 1u << 2u,
    PresentationTransitionNearMainCleared = 1u << 3u,
    PresentationTransitionOverlayAppeared = 1u << 4u,
    PresentationTransitionOverlayCleared = 1u << 5u,
};

static unsigned ClassifyPresentationTransition(const PresentationTransitionState& previous,
                                               const PresentationTransitionState& current) {
    unsigned flags = 0;
    if (previous.hudAdmitted && !current.hudAdmitted) flags |= PresentationTransitionHudLost;
    if (!previous.hudAdmitted && current.hudAdmitted) flags |= PresentationTransitionHudRestored;
    if (!previous.nearMainUnchanged && current.nearMainUnchanged) flags |= PresentationTransitionNearMainAppeared;
    if (previous.nearMainUnchanged && !current.nearMainUnchanged) flags |= PresentationTransitionNearMainCleared;
    if (!previous.fullFrameOverlays && current.fullFrameOverlays) flags |= PresentationTransitionOverlayAppeared;
    if (previous.fullFrameOverlays && !current.fullFrameOverlays) flags |= PresentationTransitionOverlayCleared;
    return flags;
}

// A full audit is worth its cost only when the frame still has a world scene
// (or an unwidened main view) and something visible changed. Restorations are
// logged, not audited.
static bool PresentationTransitionNeedsAudit(unsigned flags, const PresentationTransitionState& current) {
    const bool sceneVisible = current.gameplayScene || current.nearMainUnchanged;
    return sceneVisible && (flags & (PresentationTransitionHudLost | PresentationTransitionNearMainAppeared |
        PresentationTransitionOverlayAppeared));
}

// One rate-limit lane per audit trigger, so a flickering overlay cannot
// consume the slots (or the I/O budget) needed by a HUD loss or viewport change.
static int PresentationAuditLane(unsigned flags) {
    if (flags & PresentationTransitionHudLost) return 0;
    if (flags & PresentationTransitionNearMainAppeared) return 1;
    if (flags & PresentationTransitionOverlayAppeared) return 2;
    return -1;
}

static bool PresentationAuditDue(double now, double previous, double spacing = 2.0) {
    return !(previous > 0) || !std::isfinite(now) || now - previous >= spacing;
}

// Manual-capture evidence: every draw sampling a same-frame EFB copy (shadow
// receivers, screen composites) with its copy binding and submitted vertices.
static NSArray* CopyConsumerAudit(const std::vector<LiveDraw>& draws, const std::vector<LiveEfbCopy>& copies) {
    NSMutableArray* result = [NSMutableArray array];
    const auto number = [](float value) -> id { return std::isfinite(value) ? (id)@(value) : (id)NSNull.null; };
    for (size_t i = 0; i < draws.size() && result.count < 256; ++i) {
        const LiveDraw& draw = draws[i];
        const size_t completed = MotionCopyPassIndex(copies, i);
        NSMutableArray* stages = [NSMutableArray array];
        bool consumer = false;
        for (size_t stage = 0; stage < 8; ++stage) {
            if ((stage < 4 && stage >= draw.fragment.stageCount) ||
                (stage >= 4 && stage - 4 >= draw.fragment.indirectCount)) continue;
            const s32 copy = ExactEfbTextureCopyIndex(draw, stage, copies, completed);
            consumer = consumer || copy >= 0;
            NSString* pixels = nil;
            if (copy < 0 && draw.textureWidths[stage] * draw.textureHeights[stage] <= 1024u) {
                const auto& rgba = TexturePixels(draw, stage);
                NSMutableString* hex = [NSMutableString stringWithCapacity:rgba.size() * 2];
                for (u8 value : rgba) [hex appendFormat:@"%02x", value];
                pixels = hex;
            }
            [stages addObject:@{@"stage":@(stage), @"copy":@(copy), @"address":@(draw.textureAddresses[stage]),
                @"color_combiner":@(stage < 4 ? draw.fragment.colorCombiners[stage] : 0u),
                @"alpha_combiner":@(stage < 4 ? draw.fragment.alphaCombiners[stage] : 0u),
                @"rgba":pixels ? pixels : (id)NSNull.null,
                @"width":@(draw.textureWidths[stage]), @"height":@(draw.textureHeights[stage]),
                @"gx_mode":@(draw.textureModes[stage]), @"gx_format":@(draw.textureFormats[stage]),
                @"texcoord":@(draw.textureCoordinates[stage])}];
        }
        if (!consumer) continue;
        NSMutableArray* vertices = [NSMutableArray array];
        for (size_t v = 0; v < draw.vertices.size() && v < 96; ++v) {
            const LiveVertex& vertex = draw.vertices[v];
            NSMutableArray* uv = [NSMutableArray array];
            for (size_t stage = 0; stage < 4; ++stage)
                [uv addObject:@[number(vertex.uv[stage][0]), number(vertex.uv[stage][1]), number(vertex.uvQ[stage])]];
            [vertices addObject:@{@"clip":@[number(vertex.position[0]), number(vertex.position[1]),
                number(vertex.position[2]), number(vertex.position[3])], @"uvq":uv}];
        }
        const WideDrawRole role = ClassifyWideDraw(draw);
        [result addObject:@{@"draw":@(i), @"stages":stages, @"vertex_count":@(draw.vertices.size()), @"vertices":vertices,
            @"viewport":@[@(draw.viewportX), @(draw.viewportY), @(draw.viewportWidth), @(draw.viewportHeight)],
            @"projection":draw.projectionWords[6] ? @"orthographic" : @"perspective",
            @"wide_role":role == WideDrawRole::Scene ? @"scene" : role == WideDrawRole::ScreenFill ? @"screen-fill" :
                role == WideDrawRole::SafeArea ? @"centred-4:3" : @"unchanged",
            @"blend_mode":@(draw.blendMode), @"depth_mode":@(draw.depthMode),
            @"stage_count":@(draw.fragment.stageCount), @"alpha_test":@(draw.fragment.alphaTest),
            @"konst":@[@(draw.fragment.konstColors[0][0]), @(draw.fragment.konstColors[0][1]),
                @(draw.fragment.konstColors[0][2]), @(draw.fragment.konstColors[0][3])],
            @"registers":@[@(draw.fragment.colorRegisters[0][0]), @(draw.fragment.colorRegisters[0][1]),
                @(draw.fragment.colorRegisters[0][2]), @(draw.fragment.colorRegisters[0][3])],
            @"raster":@[@(draw.fragment.rasterColor[0]), @(draw.fragment.rasterColor[1]),
                @(draw.fragment.rasterColor[2]), @(draw.fragment.rasterColor[3])]}];
    }
    return result;
}

static NSArray* PresentationTransitionNames(unsigned flags) {
    NSMutableArray* names = [NSMutableArray array];
    if (flags & PresentationTransitionHudLost) [names addObject:@"hud-lost"];
    if (flags & PresentationTransitionHudRestored) [names addObject:@"hud-restored"];
    if (flags & PresentationTransitionNearMainAppeared) [names addObject:@"near-main-viewport-appeared"];
    if (flags & PresentationTransitionNearMainCleared) [names addObject:@"near-main-viewport-cleared"];
    if (flags & PresentationTransitionOverlayAppeared) [names addObject:@"full-frame-overlay-appeared"];
    if (flags & PresentationTransitionOverlayCleared) [names addObject:@"full-frame-overlay-cleared"];
    return names;
}

// Compact geometry/state summary of every draw, perspective included, so a
// transition audit can show viewport/projection changes the orthographic
// interface audit cannot. No pixels or full vertex lists.
static NSArray* AllDrawLayoutSummary(const std::vector<LiveDraw>& draws, size_t limit = 1024) {
    NSMutableArray* records = [NSMutableArray array];
    for (size_t index = 0; index < draws.size() && records.count < limit; ++index) {
        const LiveDraw& draw = draws[index];
        float left = INFINITY, right = -INFINITY, bottom = INFINITY, top = -INFINITY;
        for (const LiveVertex& vertex : draw.vertices) {
            if (!std::isfinite(vertex.position[3]) || vertex.position[3] == 0.0f) continue;
            const float x = vertex.position[0] / vertex.position[3], y = vertex.position[1] / vertex.position[3];
            if (!std::isfinite(x) || !std::isfinite(y)) continue;
            left = std::min(left, x); right = std::max(right, x);
            bottom = std::min(bottom, y); top = std::max(top, y);
        }
        const auto role = ClassifyWideDraw(draw);
        const bool bounded = left <= right && bottom <= top;
        [records addObject:@{@"draw_index":@(index),
            @"role":role == WideDrawRole::Scene ? @"scene" : role == WideDrawRole::ScreenFill ? @"screen-fill" :
                role == WideDrawRole::SafeArea ? @"centred-4:3" : @"unchanged",
            @"projection":draw.projectionWords[6] == 0u ? @"perspective" : @"orthographic",
            @"viewport":@[@(draw.viewportX), @(draw.viewportY), @(draw.viewportWidth), @(draw.viewportHeight)],
            @"ndc_bounds":bounded ? @[@(left), @(bottom), @(right), @(top)] : (id)NSNull.null,
            @"vertices":@(draw.vertices.size()), @"stages":@(draw.fragment.stageCount),
            @"blend_mode":@(draw.blendMode), @"depth_mode":@(draw.depthMode),
            @"texture_sizes":@[@(draw.textureWidths[0]), @(draw.textureHeights[0])],
            @"geometry_profile":draw.geometryProfile ? @(draw.geometryProfile->identity.c_str()) : (id)NSNull.null}];
    }
    return records;
}


static bool UsesRefinedGeometry(const LiveDraw& draw, bool enabled) {
    return enabled && draw.geometryProfile && !draw.refinedVertices.empty();
}

static const std::vector<LiveVertex>& RenderVertices(const LiveDraw& draw, bool enhanced = false) {
    return UsesRefinedGeometry(draw, enhanced) ? draw.refinedVertices : draw.vertices;
}

static const std::vector<u32>& RenderIndices(const LiveDraw& draw, bool enhanced = false) {
    return UsesRefinedGeometry(draw, enhanced) ? draw.geometryProfile->indices : draw.indices;
}

static bool RenderIndexed(const LiveDraw& draw, bool enhanced = false) {
    return UsesRefinedGeometry(draw, enhanced) || draw.indexed;
}

static size_t SubmittedVertexCount(const LiveDraw& draw, bool enhanced = false) {
    return RenderIndexed(draw, enhanced) ? RenderIndices(draw, enhanced).size() : RenderVertices(draw, enhanced).size();
}

static const LiveVertex& SubmittedVertex(const LiveDraw& draw, size_t index, bool enhanced = false) {
    return RenderVertices(draw, enhanced)[RenderIndexed(draw, enhanced) ? RenderIndices(draw, enhanced)[index] : index];
}

static bool RefineGeometry(LiveDraw* draw, const std::vector<LiveVertex>& source) {
    const auto* profile = draw->geometryProfile;
    if (!profile || profile->sourceVertexCount != source.size()) return false;
    std::vector<LiveVertex> refined = source;
    refined.reserve(source.size() + profile->addedVertices.size());
    for (const auto& record : profile->addedVertices) {
        const LiveVertex& a = source[record.attributes[0]];
        const LiveVertex& b = source[record.attributes[1]];
        LiveVertex vertex{};
        for (size_t component = 0; component < 4; ++component) {
            double position = 0;
            for (const auto& influence : record.positions)
                position += source[influence.source].position[component] * influence.weight;
            vertex.position[component] = (float)position;
            if (!std::isfinite(vertex.position[component])) return false;
            vertex.color[component] = (a.color[component] + b.color[component]) * 0.5f;
            vertex.uvQ[component] = (a.uvQ[component] + b.uvQ[component]) * 0.5f;
            for (size_t axis = 0; axis < 2; ++axis) {
                vertex.uv[component][axis] = (a.uv[component][axis] + b.uv[component][axis]) * 0.5f;
                vertex.indirectUV[component][axis] = (a.indirectUV[component][axis] + b.indirectUV[component][axis]) * 0.5f;
            }
        }
        refined.push_back(vertex);
    }
    draw->refinedVertices = std::move(refined);
    return true;
}

static bool BuildPrimitiveIndices(u8 opcode, u32 count, std::vector<u32>* indices,
                                  NSString** error) {
    const u32 primitive = (opcode & 0x78u) >> 3u;
    if (count > 65535u || primitive > 4u ||
        (primitive <= 1u && count % 4u != 0u) ||
        (primitive == 2u && count % 3u != 0u)) {
        *error = @"invalid triangle primitive type or vertex count";
        return false;
    }
    indices->clear();
    indices->reserve((size_t)count * 3u);
    auto triangle = [&](u32 a, u32 b, u32 c) {
        indices->push_back(a); indices->push_back(b); indices->push_back(c);
    };
    if (primitive <= 1u) {
        for (u32 i = 0; i < count; i += 4u) {
            triangle(i, i + 1u, i + 2u);
            triangle(i, i + 2u, i + 3u);
        }
    } else if (primitive == 2u) {
        for (u32 i = 0; i < count; i += 3u) triangle(i, i + 1u, i + 2u);
    } else if (primitive == 3u) {
        for (u32 i = 2; i < count; ++i) {
            if ((i & 1u) == 0u) triangle(i - 2u, i - 1u, i);
            else triangle(i - 1u, i - 2u, i);
        }
    } else {
        for (u32 i = 2; i < count; ++i) triangle(0, i - 1u, i);
    }
    return true;
}

static NSError* LiveError(NSInteger code, NSString* message) {
    return [NSError errorWithDomain:ProtectorLiveMetalErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

static u16 ReadBE16(const u8* value) {
    return (u16)((u16)value[0] << 8u | (u16)value[1]);
}

static u32 ReadBE24(const u8* value) {
    return
        (u32)value[0] << 16u |
        (u32)value[1] << 8u |
        (u32)value[2];
}

static u32 ReadBE32(const u8* value) {
    return
        (u32)value[0] << 24u |
        (u32)value[1] << 16u |
        (u32)value[2] << 8u |
        (u32)value[3];
}

static float ReadBEFloat(const u8* value) {
    u32 bits = ReadBE32(value);
    float result = 0.0f;
    static_assert(
        sizeof(result) == sizeof(bits),
        "float and u32 must have equal size"
    );
    std::memcpy(&result, &bits, sizeof(result));
    return result;
}

static size_t Align(size_t value, size_t alignment) {
    return (value + alignment - 1u) / alignment * alignment;
}

static s16 SignExtend11(u32 value) {
    value &= 0x7FFu;
    return (s16)(
        (value & 0x400u) != 0u ? value | 0xF800u : value
    );
}

static void UpdateTevRegister(
    DecoderState* state,
    u32 reg,
    u32 value
) {
    if (reg < 0xE0u || reg > 0xE7u) {
        return;
    }
    const size_t index = (reg - 0xE0u) / 2u;
    const bool high = (reg & 1u) != 0u;
    const bool konst = (value & 0x800000u) != 0u;
    const u32 first = value & 0x7FFu;
    const u32 second = (value >> 12u) & 0x7FFu;
    if (konst) {
        std::array<u16, 4>& target = state->tevKonstRegisters[index];
        if (high) {
            target[2] = (u16)std::min<u32>(first, 255u);
            target[1] = (u16)std::min<u32>(second, 255u);
        } else {
            target[0] = (u16)std::min<u32>(first, 255u);
            target[3] = (u16)std::min<u32>(second, 255u);
        }
        return;
    }
    std::array<s16, 4>& target = state->tevColorRegisters[index];
    if (high) {
        target[2] = SignExtend11(first);
        target[1] = SignExtend11(second);
    } else {
        target[0] = SignExtend11(first);
        target[3] = SignExtend11(second);
    }
}

static u32 SwapTableChannel(
    const DecoderState& state,
    u32 table,
    u32 outputChannel
) {
    const u32 reg =
        0xF6u + (table & 3u) * 2u + ((outputChannel & 3u) / 2u);
    const u32 shift = (outputChannel & 1u) != 0u ? 2u : 0u;
    return (state.bp[reg] >> shift) & 3u;
}

static float KonstFraction(u32 selector) {
    constexpr float fractions[] = {
        1.0f,
        7.0f / 8.0f,
        3.0f / 4.0f,
        5.0f / 8.0f,
        1.0f / 2.0f,
        3.0f / 8.0f,
        1.0f / 4.0f,
        1.0f / 8.0f,
    };
    return selector < 8u ? fractions[selector] : 0.0f;
}

static void PopulateKonstColor(
    const DecoderState& state,
    u32 colorSelector,
    u32 alphaSelector,
    float* output
) {
    if (colorSelector < 8u) {
        std::fill(output, output + 3u, KonstFraction(colorSelector));
    } else if (colorSelector >= 12u && colorSelector < 16u) {
        const auto& source = state.tevKonstRegisters[colorSelector - 12u];
        for (u32 component = 0u; component < 3u; ++component) {
            output[component] = source[component] / 255.0f;
        }
    } else if (colorSelector >= 16u) {
        const u32 registerIndex = colorSelector & 3u;
        const u32 component = (colorSelector - 16u) / 4u;
        const float value =
            state.tevKonstRegisters[registerIndex][component] / 255.0f;
        std::fill(output, output + 3u, value);
    } else {
        std::fill(output, output + 3u, 0.0f);
    }

    if (alphaSelector < 8u) {
        output[3] = KonstFraction(alphaSelector);
    } else if (alphaSelector >= 16u) {
        const u32 registerIndex = alphaSelector & 3u;
        const u32 component = (alphaSelector - 16u) / 4u;
        output[3] =
            state.tevKonstRegisters[registerIndex][component] / 255.0f;
    } else {
        output[3] = 0.0f;
    }
}

static bool ReadPhysical(
    const CPUState* cpu,
    u32 address,
    size_t size,
    const u8** output
);
static bool GeometrySourceMatches(const DecoderState& state, const CPUState* cpu,
                                  const ProtectorGeometryProfile* profile) {
    if (!profile || !state.geometryPack || (state.cp[0xB4] & 0xFFu) != 4u) return false;
    const u8* uvs = nullptr;
    const u32 address = state.cp[0xA4];
    if (profile->rigidSourceArrays) {
        // Do not infer a rigid match merely from a neighbouring bind/UV span:
        // the submitted positions and normals/colors must be those exact bytes.
        // Original matrices, materials and lighting remain source-owned.
        const u32 prefix = profile->sourceAnchorPrefixBytes;
        const u32 middle = profile->hasNormals ? 1u : 2u;
        const u32 descriptor = ((profile->indexWidths[0] + 1u) << 9u) |
            ((profile->indexWidths[1] + 1u) << (profile->hasNormals ? 11u : 13u));
        const u32 format = state.cp[0x76]; // Exact source primitive is VAT6.
        if (address < prefix || state.cp[0xA0] != address - prefix ||
            state.cp[0xA0 + middle] != address - prefix + profile->rigidPositionBytes ||
            (state.cp[0xB0] & 0xFFu) != 12u ||
            (state.cp[0xB0 + middle] & 0xFFu) != (profile->hasNormals ? 3u : 4u) ||
            (state.cp[0x50] & 0x1FFFFu) != descriptor ||
            (state.cp[0x60] & 0xFFFFu) != profile->indexWidths[2] + 1u ||
            (format & 0xFu) != 9u || // XYZ float positions.
            ((format >> 21u) & 0xFu) != 7u || // ST signed-16 UVs.
            (profile->hasNormals ? ((format >> 9u) & 0xFu) != 2u || (format >> 31u) != 0u
                                 : ((format >> 13u) & 0xFu) != 11u)) return false;
    }
    if (!ReadPhysical(cpu, address, profile->uvBytes, &uvs) ||
        ![state.geometryPack matchesUVs:uvs length:profile->uvBytes profile:profile]) return false;
    if (profile->sourceAnchorPrefixBytes) {
        const u8* anchor = nullptr;
        const u32 prefix = profile->sourceAnchorPrefixBytes;
        const size_t length = (size_t)prefix + profile->uvBytes;
        if (address < prefix || !ReadPhysical(cpu, address - prefix, length, &anchor) ||
            ![state.geometryPack matchesSourceAnchor:anchor length:length profile:profile]) return false;
    }
    return true;
}

static const ProtectorGeometryProfile* GeometryProfileForDraw(const DecoderState& state,
        const CPUState* cpu, const u8* primitive, size_t length, u32 vertexCount) {
    if (!state.geometryPack) return nullptr;
    const u32 normalType = (state.cp[0x50] >> 11u) & 3u;
    const u32 colorType = (state.cp[0x50] >> 13u) & 3u;
    const ProtectorGeometryProfile* selected = nullptr;
    for (const auto* profile : [state.geometryPack profilesForPrimitive:primitive length:length]) {
        if (profile->sourceVertexCount != vertexCount ||
            (normalType != 0u) != profile->hasNormals ||
            (colorType != 0u) == profile->hasNormals || !GeometrySourceMatches(state, cpu, profile)) continue;
        if (selected) return nullptr; // Ambiguity always leaves the source draw intact.
        selected = profile;
    }
    return selected;
}

static bool ExpectedTextureSize(
    u32 format,
    u32 width,
    u32 height,
    size_t* output
);
static bool DecodeTexture(
    const u8* source,
    size_t sourceSize,
    const DecoderState& state,
    u32 format,
    u32 width,
    u32 height,
    std::vector<u8>* output,
    u32 textureUnit = 0u
);
static bool ResolveDecodedTexture(DecoderState* state, const u8* source,
    size_t sourceSize, u32 address, u32 format, u32 width, u32 height,
    u32 textureUnit, std::shared_ptr<const std::vector<u8>>* pixels);
static std::array<u8, 4> RGB565(u16 value);
static float WordFloat(u32 value);

static bool PopulateFragmentState(
    const DecoderState& state,
    LiveDraw* draw,
    NSString** errorMessage
) {
    LiveFragmentUniforms& fragment = draw->fragment;
    fragment.alphaTest = state.bp[0xF3] & 0xFFFFFFu;
    draw->numColorChannels = state.xf[0x1009] & 3u;
    draw->numTextureGenerators = state.xf[0x103F] & 0xFu;
    draw->ambientColor = state.xf[0x100A];
    draw->materialColor = state.xf[0x100C];
    draw->colorChannel = state.xf[0x100E];
    draw->alphaChannel = state.xf[0x1010];
    std::copy_n(state.xf.begin() + 0x1009, draw->xfChannelWords.size(), draw->xfChannelWords.begin());
    const u32 raster = state.xf[0x100C];
    fragment.rasterColor[0] = ((raster >> 24u) & 0xFFu) / 255.0f;
    fragment.rasterColor[1] = ((raster >> 16u) & 0xFFu) / 255.0f;
    fragment.rasterColor[2] = ((raster >> 8u) & 0xFFu) / 255.0f;
    fragment.rasterColor[3] = (raster & 0xFFu) / 255.0f;
    for (size_t index = 0u; index < 3u; ++index) {
        const std::array<s16, 4>& source =
            state.tevColorRegisters[index + 1u];
        for (size_t component = 0u; component < 4u; ++component) {
            // TEV registers are signed 11-bit values, not UNORM colors.
            // Bink's YUV conversion deliberately loads negative RGB offsets.
            fragment.colorRegisters[index][component] =
                (float)source[component] / 255.0f;
        }
    }
    const u32 stageCount = ((state.bp[0x00] >> 10u) & 0xFu) + 1u;
    if (stageCount == 0u || stageCount > 4u) {
        *errorMessage = [NSString stringWithFormat:
            @"unsupported target TEV stage count %u",
            stageCount
        ];
        return false;
    }
    fragment.stageCount = stageCount;
    fragment.indirectCount = (state.bp[0x00] >> 16u) & 7u;
    if (fragment.indirectCount > 4u) {
        *errorMessage = @"invalid GX indirect stage count";
        return false;
    }
    for (u32 matrix = 0; matrix < 3; ++matrix) {
        u32 scale = 0;
        for (u32 column = 0; column < 3; ++column) {
            const u32 value = state.bp[0x06u + matrix * 3u + column];
            fragment.indirectMatrices[matrix * 2u][column] = SignExtend11(value);
            fragment.indirectMatrices[matrix * 2u + 1u][column] = SignExtend11(value >> 11u);
            scale |= ((value >> 22u) & 3u) << (column * 2u);
        }
        fragment.indirectMatrices[matrix * 2u][3] = 17 - (s32)scale;
        fragment.indirectMatrices[matrix * 2u + 1u][3] = 17 - (s32)scale;
    }
    for (u32 indirect = 0; indirect < 4; ++indirect) {
        fragment.indirectScales[indirect] =
            (state.bp[0x25u + indirect / 2u] >> ((indirect & 1u) * 8u)) & 0xFFu;
    }
    for (u32 stage = 0u; stage < stageCount; ++stage) {
        draw->tevRasterSources[stage] = (state.bp[0x28u + stage / 2u] >> (7u + 12u * (stage & 1u))) & 7u;
        const u32 indirect = state.bp[0x10u + stage] & 0x1FFFFFu;
        if ((indirect & 3u) < fragment.indirectCount &&
            (((indirect >> 7u) & 3u) != 0u || ((indirect >> 11u) & 3u) == 3u)) {
            *errorMessage = @"unsupported GX indirect bump alpha or matrix type";
            return false;
        }
        fragment.indirectCommands[stage] = indirect;
        const u32 color = state.bp[0xC0u + stage * 2u] & 0xFFFFFFu;
        const u32 alpha = state.bp[0xC1u + stage * 2u] & 0xFFFFFFu;
        const u32 ksel = state.bp[0xF6u + stage / 2u] & 0xFFFFFFu;
        const u32 colorKonstSelector = (ksel >> (
            (stage & 1u) != 0u ? 14u : 4u
        )) & 0x1Fu;
        const u32 alphaKonstSelector = (ksel >> (
            (stage & 1u) != 0u ? 19u : 9u
        )) & 0x1Fu;
        fragment.colorCombiners[stage] = color;
        fragment.alphaCombiners[stage] = alpha;
        PopulateKonstColor(
            state,
            colorKonstSelector,
            alphaKonstSelector,
            fragment.konstColors[stage]
        );
        fragment.rasterAlphaChannels[stage] =
            SwapTableChannel(state, alpha & 3u, 3u);
        fragment.textureAlphaChannels[stage] =
            SwapTableChannel(state, (alpha >> 2u) & 3u, 3u);
    }
    draw->blendMode = state.bp[0x41] & 0xFFFFFFu;
    draw->depthMode = state.bp[0x40] & 0xFFFFFFu;
    draw->cullMode = (state.bp[0x00] >> 14u) & 0x3u;
    const double viewportScaleX = WordFloat(state.xf[0x101A]);
    const double viewportScaleY = WordFloat(state.xf[0x101B]);
    const double viewportOffsetX = WordFloat(state.xf[0x101D]);
    const double viewportOffsetY = WordFloat(state.xf[0x101E]);
    draw->viewportX = viewportOffsetX - viewportScaleX - 342.0;
    draw->viewportY = viewportOffsetY + viewportScaleY - 342.0;
    draw->viewportWidth = viewportScaleX * 2.0;
    draw->viewportHeight = -viewportScaleY * 2.0;
    std::copy_n(state.xf.begin() + 0x1020, 7, draw->projectionWords.begin());
    const bool blendEnabled = (draw->blendMode & 1u) != 0u;
    const u32 sourceFactor = (draw->blendMode >> 8u) & 7u;
    const u32 destinationFactor = (draw->blendMode >> 5u) & 7u;
    const bool replaceBlend = sourceFactor == 1u && destinationFactor == 0u;
    // San Francisco's original first scene uses BP 0x41 = 0x00313D:
    // additive ONE/ONE, with neither subtract nor logic-operation enabled.
    const bool oneOneBlend = sourceFactor == 1u && destinationFactor == 1u &&
        (draw->blendMode & 0x802u) == 0u;
    if (
        blendEnabled && !replaceBlend && !oneOneBlend &&
        (
            sourceFactor != 4u ||
            (destinationFactor != 1u && destinationFactor != 5u)
        )
    ) {
        *errorMessage = [NSString stringWithFormat:
            @"unsupported target blend mode 0x%06X",
            draw->blendMode
        ];
        return false;
    }
    return true;
}

static bool DecodeDrawTextures(
    DecoderState& state,
    CPUState* cpu,
    LiveDraw* draw,
    NSString** errorMessage
) {
    for (u32 stage = 0u; stage < 8u; ++stage) {
        draw->decodedPixels[stage].reset();
        draw->textureRGBA[stage] = {255u, 255u, 255u, 255u};
        draw->textureWidths[stage] = draw->textureHeights[stage] = 1u;
        std::fill(draw->fragment.textureDimensions[stage],
                  draw->fragment.textureDimensions[stage] + 4, 1.0f);
        if ((stage < 4u && stage >= draw->fragment.stageCount) ||
            (stage >= 4u && stage - 4u >= draw->fragment.indirectCount)) continue;
        const bool isIndirect = stage >= 4u;
        const u32 order = isIndirect ? state.bp[0x27u] : state.bp[0x28u + stage / 2u];
        const u32 shift = isIndirect ? (stage - 4u) * 6u : (stage & 1u) * 12u;
        const u32 textureUnit = (order >> shift) & 7u;
        const u32 textureCoordinate = (order >> (shift + 3u)) & 7u;
        const bool textureEnabled = isIndirect || ((order >> (shift + 6u)) & 1u) != 0u;
        draw->textureCoordinates[stage] = textureCoordinate;
        draw->textureUnits[stage] = textureUnit;
        if (!isIndirect) {
            draw->indirectCommands[stage] = state.bp[0x10u + stage];
            draw->textureScaleS[stage] = state.bp[0x30u + 2u * textureCoordinate];
            draw->textureScaleT[stage] = state.bp[0x31u + 2u * textureCoordinate];
        }
        draw->fragment.textureDimensions[stage][2] =
            (float)((state.bp[0x30u + 2u * textureCoordinate] & 0xFFFFu) + 1u);
        draw->fragment.textureDimensions[stage][3] =
            (float)((state.bp[0x31u + 2u * textureCoordinate] & 0xFFFFu) + 1u);
        // BP texture units 4..7 occupy a second bank at +0x20, rather than
        // following unit 3 contiguously. Bink's YUV planes use that bank.
        const u32 textureRegisterOffset =
            (textureUnit & 3u) + ((textureUnit & 4u) != 0u ? 0x20u : 0u);
        draw->textureModes[stage] =
            state.bp[0x80u + textureRegisterOffset] & 0xFFFFFFu;
        if (!textureEnabled) {
            draw->textureRGBA[stage] = {255u, 255u, 255u, 255u};
            draw->textureWidths[stage] = 1u;
            draw->textureHeights[stage] = 1u;
            continue;
        }
        if (
            textureCoordinate >= 8u ||
            textureUnit >= 8u
        ) {
            *errorMessage = [NSString stringWithFormat:
                @"unsupported target TEV order "
                 "stage=%u order=0x%06X",
                stage,
                order
            ];
            return false;
        }
        const u32 image0 =
            state.bp[0x88u + textureRegisterOffset] & 0xFFFFFFu;
        const u32 image3 =
            state.bp[0x94u + textureRegisterOffset] & 0xFFFFFFu;
        draw->textureImage1[stage] = state.bp[0x8Cu + textureRegisterOffset] & 0xFFFFFFu;
        draw->textureImage2[stage] = state.bp[0x90u + textureRegisterOffset] & 0xFFFFFFu;
        const u32 width = (image0 & 0x3FFu) + 1u;
        const u32 height = ((image0 >> 10u) & 0x3FFu) + 1u;
        const u32 format = (image0 >> 20u) & 0xFu;
        draw->textureFormats[stage] = format;
        const u32 textureAddress = image3 << 5u;
        draw->textureAddresses[stage] = textureAddress;
        size_t textureSize = 0u;
        const u8* textureSource = nullptr;
        if (
            !ExpectedTextureSize(format, width, height, &textureSize) ||
            !ReadPhysical(
                cpu,
                textureAddress,
                textureSize,
                &textureSource
            ) ||
            !ResolveDecodedTexture(
                &state,
                textureSource,
                textureSize,
                textureAddress,
                format,
                width,
                height,
                textureUnit,
                &draw->decodedPixels[stage]
            )
        ) {
            *errorMessage = [NSString stringWithFormat:
                @"failed to decode target TEV texture "
                 "stage=%u unit=%u address=0x%08X "
                 "format=%u size=%ux%u",
                stage,
                textureUnit,
                textureAddress,
                format,
                width,
                height
            ];
            return false;
        }
        draw->textureWidths[stage] = width;
        draw->textureHeights[stage] = height;
        draw->fragment.textureDimensions[stage][0] = (float)width;
        draw->fragment.textureDimensions[stage][1] = (float)height;
    }
    return true;
}

static size_t ComponentSize(
    u32 componentType,
    size_t directSize,
    size_t indexedMultiplier = 1u
) {
    switch (componentType) {
        case 0:
            return 0;
        case 1:
            return directSize;
        case 2:
            return indexedMultiplier;
        case 3:
            return indexedMultiplier * 2u;
        default:
            return std::numeric_limits<size_t>::max();
    }
}

static size_t ElementSize(u32 format) {
    return format < 2u ? 1u : format < 4u ? 2u : 4u;
}

static bool VertexSize(
    const DecoderState& state,
    u32 vat,
    size_t* output
) {
    const u32 descriptorLow = state.cp[0x50];
    const u32 descriptorHigh = state.cp[0x60];
    const u32 group0 = state.cp[0x70 + vat];
    const u32 group1 = state.cp[0x80 + vat];
    const u32 group2 = state.cp[0x90 + vat];
    size_t size = (size_t)__builtin_popcount(descriptorLow & 0x1FFu);

    size_t component = ComponentSize(
        (descriptorLow >> 9u) & 0x3u,
        ElementSize((group0 >> 1u) & 0x7u) *
            (2u + (group0 & 0x1u))
    );
    if (component == std::numeric_limits<size_t>::max()) {
        return false;
    }
    size += component;

    const bool normalElements = ((group0 >> 9u) & 0x1u) != 0u;
    const bool normalIndex3 = ((group0 >> 31u) & 0x1u) != 0u;
    component = ComponentSize(
        (descriptorLow >> 11u) & 0x3u,
        ElementSize((group0 >> 10u) & 0x7u) *
            (normalElements ? 9u : 3u),
        normalElements && normalIndex3 ? 3u : 1u
    );
    if (component == std::numeric_limits<size_t>::max()) {
        return false;
    }
    size += component;

    constexpr size_t colorSizes[] = {2u, 3u, 4u, 2u, 3u, 4u};
    for (u32 index = 0u; index < 2u; ++index) {
        const u32 typeShift = index == 0u ? 13u : 15u;
        const u32 formatShift = index == 0u ? 14u : 18u;
        const u32 type = (descriptorLow >> typeShift) & 0x3u;
        const u32 format = (group0 >> formatShift) & 0x7u;
        if (
            type == 1u &&
            format >= sizeof(colorSizes) / sizeof(colorSizes[0])
        ) {
            return false;
        }
        component = ComponentSize(
            type,
            type == 1u ? colorSizes[format] : 0u
        );
        if (component == std::numeric_limits<size_t>::max()) {
            return false;
        }
        size += component;
    }

    const std::array<std::pair<u32, u32>, 8> textureFields = {{
        {(group0 >> 21u) & 0x1u, (group0 >> 22u) & 0x7u},
        {(group1 >> 0u) & 0x1u, (group1 >> 1u) & 0x7u},
        {(group1 >> 9u) & 0x1u, (group1 >> 10u) & 0x7u},
        {(group1 >> 18u) & 0x1u, (group1 >> 19u) & 0x7u},
        {(group1 >> 27u) & 0x1u, (group1 >> 28u) & 0x7u},
        {(group2 >> 5u) & 0x1u, (group2 >> 6u) & 0x7u},
        {(group2 >> 14u) & 0x1u, (group2 >> 15u) & 0x7u},
        {(group2 >> 23u) & 0x1u, (group2 >> 24u) & 0x7u},
    }};
    for (u32 index = 0u; index < textureFields.size(); ++index) {
        component = ComponentSize(
            (descriptorHigh >> (index * 2u)) & 0x3u,
            ElementSize(textureFields[index].second) *
                (1u + textureFields[index].first)
        );
        if (component == std::numeric_limits<size_t>::max()) {
            return false;
        }
        size += component;
    }
    *output = size;
    return true;
}

static float WordFloat(u32 value) {
    float result = 0.0f;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

static bool DecodeNumericComponents(
    const u8* source,
    size_t sourceSize,
    u32 format,
    u32 fractionalBits,
    u32 componentCount,
    float* output
) {
    const size_t elementSize = ElementSize(format);
    if (
        format > 4u ||
        componentCount > std::numeric_limits<size_t>::max() / elementSize ||
        sourceSize < componentCount * elementSize
    ) {
        return false;
    }
    const float scale = std::ldexp(1.0f, -(int)fractionalBits);
    for (u32 index = 0u; index < componentCount; ++index) {
        const u8* value = source + (size_t)index * elementSize;
        if (format == 0u) {
            output[index] = (float)value[0] * scale;
        } else if (format == 1u) {
            output[index] = (float)(s8)value[0] * scale;
        } else if (format == 2u) {
            output[index] = (float)ReadBE16(value) * scale;
        } else if (format == 3u) {
            output[index] = (float)(s16)ReadBE16(value) * scale;
        } else {
            output[index] = ReadBEFloat(value);
        }
    }
    return true;
}

static bool ResolveAttribute(
    const DecoderState& state,
    CPUState* cpu,
    const u8* payload,
    size_t payloadSize,
    size_t* cursor,
    u32 componentType,
    u32 arrayIndex,
    size_t directSize,
    const u8** source
) {
    *source = nullptr;
    if (componentType == 0u) {
        return true;
    }
    if (componentType == 1u) {
        if (*cursor > payloadSize || payloadSize - *cursor < directSize) {
            return false;
        }
        *source = payload + *cursor;
        *cursor += directSize;
        return true;
    }
    const size_t indexSize = componentType == 2u ? 1u : 2u;
    if (*cursor > payloadSize || payloadSize - *cursor < indexSize) {
        return false;
    }
    const u32 index = indexSize == 1u
        ? payload[*cursor]
        : ReadBE16(payload + *cursor);
    *cursor += indexSize;
    const uint64_t address =
        (uint64_t)state.cp[0xA0u + arrayIndex] +
        (uint64_t)index * state.cp[0xB0u + arrayIndex];
    if (address > UINT32_MAX) {
        return false;
    }
    return ReadPhysical(cpu, (u32)address, directSize, source);
}

static bool DecodeColor(
    const u8* source,
    u32 format,
    float* output
) {
    std::array<u8, 4> color{};
    if (format == 0u) {
        color = RGB565(ReadBE16(source));
    } else if (format == 1u) {
        color = {source[0], source[1], source[2], 255u};
    } else if (format == 2u) {
        color = {source[0], source[1], source[2], 255u};
    } else if (format == 3u) {
        const u16 value = ReadBE16(source);
        const u8 red = (u8)((value >> 12u) & 0xFu);
        const u8 green = (u8)((value >> 8u) & 0xFu);
        const u8 blue = (u8)((value >> 4u) & 0xFu);
        const u8 alpha = (u8)(value & 0xFu);
        color = {
            (u8)((red << 4u) | red),
            (u8)((green << 4u) | green),
            (u8)((blue << 4u) | blue),
            (u8)((alpha << 4u) | alpha),
        };
    } else if (format == 4u) {
        const u32 value = ReadBE24(source);
        color = {
            (u8)((value >> 18u) & 0x3Fu),
            (u8)((value >> 12u) & 0x3Fu),
            (u8)((value >> 6u) & 0x3Fu),
            (u8)(value & 0x3Fu),
        };
        for (u8& component : color) {
            component = (u8)((component << 2u) | (component >> 4u));
        }
    } else if (format == 5u) {
        color = {source[0], source[1], source[2], source[3]};
    } else {
        return false;
    }
    for (u32 index = 0u; index < 4u; ++index) {
        output[index] = color[index] / 255.0f;
    }
    return true;
}

static bool TransformPosition(
    const DecoderState& state,
    u32 matrixIndex,
    const float* position,
    float* output,
    float* eyeOutput = nullptr
) {
    const size_t matrixBase = (size_t)(matrixIndex & 0x3Fu) * 4u;
    if (matrixBase + 12u > state.xf.size()) {
        return false;
    }
    float eye[3] = {};
    for (u32 row = 0u; row < 3u; ++row) {
        eye[row] =
            WordFloat(state.xf[matrixBase + row * 4u]) * position[0] +
            WordFloat(state.xf[matrixBase + row * 4u + 1u]) * position[1] +
            WordFloat(state.xf[matrixBase + row * 4u + 2u]) * position[2] +
            WordFloat(state.xf[matrixBase + row * 4u + 3u]);
    }
    if (eyeOutput) {
        std::copy(eye, eye + 3u, eyeOutput);
    }
    const float projection[] = {
        WordFloat(state.xf[0x1020]),
        WordFloat(state.xf[0x1021]),
        WordFloat(state.xf[0x1022]),
        WordFloat(state.xf[0x1023]),
        WordFloat(state.xf[0x1024]),
        WordFloat(state.xf[0x1025]),
    };
    if (state.xf[0x1026] == 0u) {
        output[0] = projection[0] * eye[0] + projection[1] * eye[2];
        output[1] = projection[2] * eye[1] + projection[3] * eye[2];
        output[2] = projection[4] * eye[2] + projection[5];
        output[3] = -eye[2];
    } else {
        output[0] = projection[0] * eye[0] + projection[1];
        output[1] = projection[2] * eye[1] + projection[3];
        output[2] = projection[4] * eye[2] + projection[5];
        output[3] = 1.0f;
    }
    output[2] = (output[2] + output[3]) * 0.5f;
    return std::isfinite(output[0]) &&
           std::isfinite(output[1]) &&
           std::isfinite(output[2]) &&
           std::isfinite(output[3]);
}

static float Dot3(const float* first, const float* second) {
    return
        first[0] * second[0] +
        first[1] * second[1] +
        first[2] * second[2];
}

static bool Normalize3(float* value) {
    const float lengthSquared = Dot3(value, value);
    if (!std::isfinite(lengthSquared) || lengthSquared <= 0.0f) {
        return false;
    }
    const float inverseLength = 1.0f / std::sqrt(lengthSquared);
    for (u32 component = 0u; component < 3u; ++component) {
        value[component] *= inverseLength;
    }
    return true;
}

static bool TransformNormal(
    const DecoderState& state,
    u32 matrixIndex,
    const float* input,
    float* output
) {
    const size_t matrixBase =
        0x400u + 3u * (size_t)(matrixIndex & 0x1Fu);
    if (matrixBase + 9u > state.xf.size()) {
        return false;
    }
    for (u32 row = 0u; row < 3u; ++row) {
        output[row] =
            WordFloat(state.xf[matrixBase + row * 3u]) * input[0] +
            WordFloat(state.xf[matrixBase + row * 3u + 1u]) * input[1] +
            WordFloat(state.xf[matrixBase + row * 3u + 2u]) * input[2];
    }
    return Normalize3(output);
}

static void PackedColor(u32 packed, float* output) {
    output[0] = (float)((packed >> 24u) & 0xFFu);
    output[1] = (float)((packed >> 16u) & 0xFFu);
    output[2] = (float)((packed >> 8u) & 0xFFu);
    output[3] = (float)(packed & 0xFFu);
}

static float LightAttenuation(
    const DecoderState& state,
    u32 lightIndex,
    u32 attenuationFunction,
    u32 diffuseFunction,
    const float* eye,
    const float* normal,
    float* lightDirection
) {
    const size_t lightBase = 0x600u + lightIndex * 16u;
    const float lightPosition[] = {
        WordFloat(state.xf[lightBase + 10u]),
        WordFloat(state.xf[lightBase + 11u]),
        WordFloat(state.xf[lightBase + 12u]),
    };
    const float lightVector[] = {
        WordFloat(state.xf[lightBase + 13u]),
        WordFloat(state.xf[lightBase + 14u]),
        WordFloat(state.xf[lightBase + 15u]),
    };
    for (u32 component = 0u; component < 3u; ++component) {
        lightDirection[component] =
            lightPosition[component] - eye[component];
    }
    if (attenuationFunction == 0u || attenuationFunction == 2u) {
        if (!Normalize3(lightDirection)) {
            std::copy(normal, normal + 3u, lightDirection);
        }
        return 1.0f;
    }
    if (attenuationFunction == 1u) {
        if (!Normalize3(lightDirection)) {
            std::copy(normal, normal + 3u, lightDirection);
        }
        float attenuation = Dot3(normal, lightDirection) >= 0.0f
            ? std::max(0.0f, Dot3(normal, lightVector))
            : 0.0f;
        const float basis[] = {
            1.0f, attenuation, attenuation * attenuation
        };
        const float cosAttenuation[] = {
            WordFloat(state.xf[lightBase + 4u]),
            WordFloat(state.xf[lightBase + 5u]),
            WordFloat(state.xf[lightBase + 6u]),
        };
        float distanceAttenuation[] = {
            WordFloat(state.xf[lightBase + 7u]),
            WordFloat(state.xf[lightBase + 8u]),
            WordFloat(state.xf[lightBase + 9u]),
        };
        if (diffuseFunction != 0u) {
            Normalize3(distanceAttenuation);
        }
        const float denominator = Dot3(distanceAttenuation, basis);
        return denominator != 0.0f
            ? std::max(0.0f, Dot3(cosAttenuation, basis)) / denominator
            : 0.0f;
    }

    const float distanceSquared = Dot3(lightDirection, lightDirection);
    const float distance = std::sqrt(std::max(distanceSquared, 0.0f));
    if (distance > 0.0f) {
        for (u32 component = 0u; component < 3u; ++component) {
            lightDirection[component] /= distance;
        }
    } else {
        std::copy(normal, normal + 3u, lightDirection);
    }
    float angle = std::max(0.0f, Dot3(lightDirection, lightVector));
    const float numerator =
        WordFloat(state.xf[lightBase + 4u]) +
        WordFloat(state.xf[lightBase + 5u]) * angle +
        WordFloat(state.xf[lightBase + 6u]) * angle * angle;
    const float denominator =
        WordFloat(state.xf[lightBase + 7u]) +
        WordFloat(state.xf[lightBase + 8u]) * distance +
        WordFloat(state.xf[lightBase + 9u]) * distanceSquared;
    return denominator != 0.0f
        ? std::max(0.0f, numerator) / denominator
        : 0.0f;
}

static void ApplyLightingComponent(
    const DecoderState& state,
    u32 channel,
    bool alpha,
    const float* baseColor,
    const float* eye,
    const float* normal,
    float* output
) {
    const u32 config = state.xf[
        (alpha ? 0x1010u : 0x100Eu) + channel
    ];
    float material[4] = {};
    float ambient[4] = {};
    PackedColor(state.xf[0x100Cu + channel], material);
    PackedColor(state.xf[0x100Au + channel], ambient);
    const bool materialFromVertex = (config & 1u) != 0u;
    const bool lightingEnabled = ((config >> 1u) & 1u) != 0u;
    const bool ambientFromVertex = ((config >> 6u) & 1u) != 0u;
    const u32 diffuseFunction = (config >> 7u) & 3u;
    const u32 attenuationFunction = (config >> 9u) & 3u;
    const u32 lightMask =
        ((config >> 2u) & 0xFu) |
        (((config >> 11u) & 0xFu) << 4u);

    const u32 firstComponent = alpha ? 3u : 0u;
    const u32 componentCount = alpha ? 1u : 3u;
    float accumulator[4] = {};
    for (
        u32 component = firstComponent;
        component < firstComponent + componentCount;
        ++component
    ) {
        accumulator[component] = lightingEnabled
            ? (ambientFromVertex ? baseColor[component] * 255.0f
                                 : ambient[component])
            : 255.0f;
    }
    if (lightingEnabled) {
        for (u32 lightIndex = 0u; lightIndex < 8u; ++lightIndex) {
            if ((lightMask & (1u << lightIndex)) == 0u) {
                continue;
            }
            float direction[3] = {};
            const float attenuation = LightAttenuation(
                state,
                lightIndex,
                attenuationFunction,
                diffuseFunction,
                eye,
                normal,
                direction
            );
            float diffuse = 1.0f;
            if (diffuseFunction == 1u) {
                diffuse = Dot3(direction, normal);
            } else if (diffuseFunction == 2u) {
                diffuse = std::max(0.0f, Dot3(direction, normal));
            }
            float lightColor[4] = {};
            PackedColor(
                state.xf[0x600u + lightIndex * 16u + 3u],
                lightColor
            );
            for (
                u32 component = firstComponent;
                component < firstComponent + componentCount;
                ++component
            ) {
                accumulator[component] += std::round(
                    attenuation * diffuse * lightColor[component]
                );
            }
        }
    }
    for (
        u32 component = firstComponent;
        component < firstComponent + componentCount;
        ++component
    ) {
        const int lightValue = std::max(
            0,
            std::min(
                (int)std::round(accumulator[component]),
                255
            )
        );
        const int materialValue = std::max(
            0,
            std::min(
                (int)std::round(
                materialFromVertex
                    ? baseColor[component] * 255.0f
                    : material[component]
                ),
                255
            )
        );
        output[component] = (
            (materialValue * (lightValue + (lightValue >> 7))) >> 8
        ) / 255.0f;
    }
}

static void ApplyLighting(
    const DecoderState& state,
    const float* baseColor,
    const float* eye,
    const float* normal,
    float* output
) {
    if ((state.xf[0x1009] & 3u) == 0u) {
        std::fill(output, output + 4u, 0.0f);
        return;
    }
    ApplyLightingComponent(
        state, 0u, false, baseColor, eye, normal, output
    );
    ApplyLightingComponent(
        state, 0u, true, baseColor, eye, normal, output
    );
}

static u32 DefaultTextureMatrixIndex(
    const DecoderState& state,
    u32 textureCoordinate
) {
    if (textureCoordinate < 4u) {
        return (
            state.cp[0x30] >> (6u * (textureCoordinate + 1u))
        ) & 0x3Fu;
    }
    return (
        state.cp[0x40] >> (6u * (textureCoordinate - 4u))
    ) & 0x3Fu;
}

static bool GenerateTextureCoordinate(
    const DecoderState& state,
    u32 textureCoordinate,
    const float* rawPosition,
    const float* rawNormal,
    const float rawTextures[8][3],
    const u32* textureMatrixIndices,
    const float* litColor,
    float* output,
    float* generatedQ = nullptr,
    float* projectiveQ = nullptr
) {
    if (textureCoordinate >= 8u) {
        return false;
    }
    const u32 info = state.xf[0x1040u + textureCoordinate];
    const u32 projection = (info >> 1u) & 1u;
    const u32 inputForm = (info >> 2u) & 1u;
    const u32 type = (info >> 4u) & 7u;
    const u32 sourceRow = (info >> 7u) & 0x1Fu;
    if (type == 2u || type == 3u) {
        output[0] = litColor[0];
        output[1] = litColor[1];
        if (generatedQ) *generatedQ = 1.0f;
        return true;
    }
    if (type != 0u) {
        return false;
    }

    float coordinate[4] = {0.0f, 0.0f, 1.0f, 1.0f};
    if (sourceRow == 0u) {
        std::copy(rawPosition, rawPosition + 3u, coordinate);
    } else if (sourceRow == 1u) {
        std::copy(rawNormal, rawNormal + 3u, coordinate);
    } else if (sourceRow >= 5u && sourceRow <= 12u) {
        const float* source = rawTextures[sourceRow - 5u];
        coordinate[0] = source[0];
        coordinate[1] = source[1];
        coordinate[2] = source[2];
    } else {
        return false;
    }
    if (inputForm == 0u) {
        coordinate[2] = 1.0f;
    }
    for (float& value : coordinate) {
        if (std::isnan(value)) {
            value = 1.0f;
        }
    }

    const size_t matrixBase =
        (size_t)(textureMatrixIndices[textureCoordinate] & 0x3Fu) * 4u;
    if (matrixBase + (projection != 0u ? 12u : 8u) > state.xf.size()) {
        return false;
    }
    float generated[3] = {0.0f, 0.0f, 1.0f};
    for (u32 row = 0u; row < (projection != 0u ? 3u : 2u); ++row) {
        generated[row] =
            WordFloat(state.xf[matrixBase + row * 4u]) * coordinate[0] +
            WordFloat(state.xf[matrixBase + row * 4u + 1u]) * coordinate[1] +
            WordFloat(state.xf[matrixBase + row * 4u + 2u]) * coordinate[2] +
            WordFloat(state.xf[matrixBase + row * 4u + 3u]) * coordinate[3];
    }

    if ((state.xf[0x1012] & 1u) != 0u) {
        const u32 postInfo = state.xf[0x1050u + textureCoordinate];
        if (((postInfo >> 8u) & 1u) != 0u) {
            Normalize3(generated);
        }
        const u32 postIndex = postInfo & 0x3Fu;
        float transformed[3] = {};
        for (u32 row = 0u; row < 3u; ++row) {
            const size_t base =
                0x500u + (size_t)((postIndex + row) & 0x3Fu) * 4u;
            transformed[row] =
                WordFloat(state.xf[base]) * generated[0] +
                WordFloat(state.xf[base + 1u]) * generated[1] +
                WordFloat(state.xf[base + 2u]) * generated[2] +
                WordFloat(state.xf[base + 3u]);
        }
        std::copy(transformed, transformed + 3u, generated);
    }
    if (generatedQ) *generatedQ = generated[2];
    const float divisor =
        std::isfinite(generated[2]) && std::abs(generated[2]) > 1e-8f
            ? generated[2]
            : 1.0f;
    // GX divides projective coordinates per pixel. A per-vertex divide
    // explodes across triangles whose Q approaches zero (projected shadows).
    if (projectiveQ) {
        *projectiveQ = divisor;
        output[0] = generated[0];
        output[1] = generated[1];
    } else {
        output[0] = generated[0] / divisor;
        output[1] = generated[1] / divisor;
    }
    return std::isfinite(output[0]) && std::isfinite(output[1]);
}

static bool ReadPhysical(
    const CPUState* cpu,
    u32 address,
    size_t size,
    const u8** output
) {
    const uint64_t end = (uint64_t)address + size;
    if (end <= cpu->ram_size) {
        *output = cpu->ram + address;
        return true;
    }
    if (address >= kMem2PhysicalBase) {
        const uint64_t offset = (uint64_t)address - kMem2PhysicalBase;
        if (offset + size <= cpu->mem2_size) {
            *output = cpu->mem2 + offset;
            return true;
        }
    }
    return false;
}

static bool ExpectedTextureSize(
    u32 format,
    u32 width,
    u32 height,
    size_t* output
) {
    if (width == 0u || height == 0u) {
        return false;
    }
    if (format == 0u || format == 8u || format == 14u) {
        *output = Align(width, 8u) * Align(height, 8u) / 2u;
        return true;
    }
    if (format == 1u || format == 2u || format == 9u) {
        *output = Align(width, 8u) * Align(height, 4u);
        return true;
    }
    if (format == 3u || format == 4u || format == 5u) {
        *output = Align(width, 4u) * Align(height, 4u) * 2u;
        return true;
    }
    if (format == 6u) {
        *output = Align(width, 4u) * Align(height, 4u) * 4u;
        return true;
    }
    return false;
}

static std::array<u8, 4> RGB565(u16 value) {
    const u8 red = (u8)((value >> 11u) & 0x1Fu);
    const u8 green = (u8)((value >> 5u) & 0x3Fu);
    const u8 blue = (u8)(value & 0x1Fu);
    return {
        (u8)((red << 3u) | (red >> 2u)),
        (u8)((green << 2u) | (green >> 4u)),
        (u8)((blue << 3u) | (blue >> 2u)),
        255u,
    };
}

static std::array<u8, 4> RGB5A3(u16 value) {
    if ((value & 0x8000u) != 0u) {
        const u8 red = (u8)((value >> 10u) & 0x1Fu);
        const u8 green = (u8)((value >> 5u) & 0x1Fu);
        const u8 blue = (u8)(value & 0x1Fu);
        return {
            (u8)((red << 3u) | (red >> 2u)),
            (u8)((green << 3u) | (green >> 2u)),
            (u8)((blue << 3u) | (blue >> 2u)),
            255u,
        };
    }
    const u8 alpha = (u8)((value >> 12u) & 0x7u);
    const u8 red = (u8)((value >> 8u) & 0xFu);
    const u8 green = (u8)((value >> 4u) & 0xFu);
    const u8 blue = (u8)(value & 0xFu);
    return {
        (u8)((red << 4u) | red),
        (u8)((green << 4u) | green),
        (u8)((blue << 4u) | blue),
        (u8)((alpha << 5u) | (alpha << 2u) | (alpha >> 1u)),
    };
}

static void StorePixel(
    std::vector<u8>& output,
    u32 width,
    u32 height,
    u32 x,
    u32 y,
    const std::array<u8, 4>& rgba
) {
    if (x >= width || y >= height) {
        return;
    }
    const size_t destination = ((size_t)y * width + x) * 4u;
    std::copy(rgba.begin(), rgba.end(), output.begin() + destination);
}

static bool DecodeCMPR(
    const u8* source,
    size_t sourceSize,
    u32 width,
    u32 height,
    std::vector<u8>* output
) {
    size_t expected = 0;
    if (
        !ExpectedTextureSize(14u, width, height, &expected) ||
        expected != sourceSize
    ) {
        return false;
    }
    output->assign((size_t)width * height * 4u, 0u);
    size_t cursor = 0u;
    for (u32 tileY = 0u; tileY < Align(height, 8u); tileY += 8u) {
        for (u32 tileX = 0u; tileX < Align(width, 8u); tileX += 8u) {
            for (u32 blockIndex = 0u; blockIndex < 4u; ++blockIndex) {
                const u8* block = source + cursor;
                cursor += 8u;
                const u16 colorZero = ReadBE16(block);
                const u16 colorOne = ReadBE16(block + 2u);
                std::array<std::array<u8, 4>, 4> palette = {
                    RGB565(colorZero),
                    RGB565(colorOne),
                    {},
                    {},
                };
                if (colorZero > colorOne) {
                    for (u32 channel = 0u; channel < 3u; ++channel) {
                        palette[2][channel] = (u8)(
                            (
                                (u32)palette[0][channel] * 2u +
                                palette[1][channel]
                            ) /
                            3u
                        );
                        palette[3][channel] = (u8)(
                            (
                                palette[0][channel] +
                                (u32)palette[1][channel] * 2u
                            ) /
                            3u
                        );
                    }
                    palette[2][3] = 255u;
                    palette[3][3] = 255u;
                } else {
                    for (u32 channel = 0u; channel < 3u; ++channel) {
                        palette[2][channel] = (u8)(
                            (
                                (u32)palette[0][channel] +
                                palette[1][channel]
                            ) /
                            2u
                        );
                    }
                    palette[2][3] = 255u;
                    palette[3] = {0u, 0u, 0u, 0u};
                }
                const u32 blockX = tileX + (blockIndex & 1u) * 4u;
                const u32 blockY = tileY + (blockIndex >> 1u) * 4u;
                for (u32 y = 0u; y < 4u; ++y) {
                    const u8 indices = block[4u + y];
                    for (u32 x = 0u; x < 4u; ++x) {
                        StorePixel(
                            *output,
                            width,
                            height,
                            blockX + x,
                            blockY + y,
                            palette[(indices >> (6u - x * 2u)) & 0x3u]
                        );
                    }
                }
            }
        }
    }
    return true;
}

static bool DecodeTexture(
    const u8* source,
    size_t sourceSize,
    const DecoderState& state,
    u32 format,
    u32 width,
    u32 height,
    std::vector<u8>* output,
    u32 textureUnit
) {
    if (textureUnit >= 8u) return false;
    if (format == 14u) {
        return DecodeCMPR(source, sourceSize, width, height, output);
    }
    size_t expected = 0u;
    if (
        !ExpectedTextureSize(format, width, height, &expected) ||
        expected != sourceSize
    ) {
        return false;
    }
    output->assign((size_t)width * height * 4u, 0u);
    const u32 blockWidth =
        format == 0u || format == 8u || format == 1u ||
                format == 2u || format == 9u
            ? 8u
            : 4u;
    const u32 blockHeight =
        format == 0u || format == 8u
            ? 8u
            : format == 1u || format == 2u || format == 9u
                ? 4u
                : 4u;
    const size_t blockBytes = format == 6u ? 64u : 32u;
    const bool indexed = format == 8u || format == 9u;
    const u32 paletteEntries = format == 8u ? 16u : 256u;
    const u32 textureRegisterOffset = (textureUnit & 3u) + ((textureUnit & 4u) << 3u);
    const u32 paletteRegister = state.bp[0x98u + textureRegisterOffset] & 0xFFFFFFu;
    const u32 paletteOffset = (paletteRegister & 0x3FFu) << 9u;
    const u32 paletteFormat = (paletteRegister >> 10u) & 0x3u;
    if (
        indexed &&
        (
            paletteFormat > 2u ||
            (uint64_t)paletteOffset + paletteEntries * 2u >
                state.textureMemory.size()
        )
    ) {
        return false;
    }
    auto paletteColor = [&](u32 index) {
        const u16 value = ReadBE16(
            state.textureMemory.data() + paletteOffset + index * 2u
        );
        if (paletteFormat == 0u) {
            const u8 alpha = (u8)(value >> 8u);
            const u8 intensity = (u8)value;
            return std::array<u8, 4>{
                intensity, intensity, intensity, alpha
            };
        }
        return paletteFormat == 1u ? RGB565(value) : RGB5A3(value);
    };

    size_t cursor = 0u;
    for (
        u32 tileY = 0u;
        tileY < Align(height, blockHeight);
        tileY += blockHeight
    ) {
        for (
            u32 tileX = 0u;
            tileX < Align(width, blockWidth);
            tileX += blockWidth
        ) {
            const u8* tile = source + cursor;
            cursor += blockBytes;
            for (u32 y = 0u; y < blockHeight; ++y) {
                for (u32 x = 0u; x < blockWidth; ++x) {
                    const u32 pixel = y * blockWidth + x;
                    std::array<u8, 4> rgba{};
                    if (format == 0u) {
                        const u8 packed = tile[pixel / 2u];
                        u8 intensity = pixel % 2u == 0u
                            ? packed >> 4u
                            : packed & 0xFu;
                        intensity = (u8)((intensity << 4u) | intensity);
                        rgba = {intensity, intensity, intensity, intensity};
                    } else if (format == 1u) {
                        const u8 intensity = tile[pixel];
                        rgba = {intensity, intensity, intensity, intensity};
                    } else if (format == 2u) {
                        const u8 packed = tile[pixel];
                        const u8 alpha = (u8)(packed >> 4u);
                        const u8 intensity = (u8)(packed & 0xFu);
                        const u8 expandedI =
                            (u8)((intensity << 4u) | intensity);
                        const u8 expandedA = (u8)((alpha << 4u) | alpha);
                        rgba = {expandedI, expandedI, expandedI, expandedA};
                    } else if (format == 3u) {
                        const u8 alpha = tile[pixel * 2u];
                        const u8 intensity = tile[pixel * 2u + 1u];
                        rgba = {intensity, intensity, intensity, alpha};
                    } else if (format == 4u) {
                        rgba = RGB565(ReadBE16(tile + pixel * 2u));
                    } else if (format == 5u) {
                        rgba = RGB5A3(ReadBE16(tile + pixel * 2u));
                    } else if (format == 6u) {
                        rgba = {
                            tile[pixel * 2u + 1u],
                            tile[32u + pixel * 2u],
                            tile[32u + pixel * 2u + 1u],
                            tile[pixel * 2u],
                        };
                    } else if (format == 8u) {
                        const u8 packed = tile[pixel / 2u];
                        const u32 index = pixel % 2u == 0u
                            ? packed >> 4u
                            : packed & 0xFu;
                        rgba = paletteColor(index);
                    } else if (format == 9u) {
                        rgba = paletteColor(tile[pixel]);
                    } else {
                        return false;
                    }
                    StorePixel(
                        *output,
                        width,
                        height,
                        tileX + x,
                        tileY + y,
                        rgba
                    );
                }
            }
        }
    }
    return cursor == sourceSize;
}

static bool ResolveDecodedTexture(DecoderState* state, const u8* source,
    size_t sourceSize, u32 address, u32 format, u32 width, u32 height,
    u32 textureUnit, std::shared_ptr<const std::vector<u8>>* pixels) {
    if (!state || !source || !pixels || textureUnit >= 8u) return false;
    if (width > 1024u || height > 1024u) return false;
    size_t expected = 0;
    if (!ExpectedTextureSize(format, width, height, &expected) || sourceSize != expected)
        return false;
    const bool indexed = format == 8u || format == 9u;
    const u32 registerOffset = (textureUnit & 3u) + ((textureUnit & 4u) << 3u);
    const u32 paletteRegister = indexed ? state->bp[0x98u + registerOffset] & 0xFFFFFFu : 0;
    const size_t paletteSize = indexed ? (format == 8u ? 32u : 512u) : 0;
    const size_t paletteOffset = (paletteRegister & 0x3FFu) << 9u;
    if (indexed && (((paletteRegister >> 10u) & 3u) > 2u ||
        paletteOffset + paletteSize > state->textureMemory.size())) return false;
    const u8* palette = state->textureMemory.data() + paletteOffset;
    auto& cache = state->decodedTextures;
    const DecodedTextureKey key{address, format, width, height, paletteRegister};
    auto found = cache.entries.find(key);
    if (cache.enabled && found != cache.entries.end() &&
        found->second.source.size() == sourceSize && found->second.palette.size() == paletteSize &&
        std::memcmp(found->second.source.data(), source, sourceSize) == 0 &&
        (paletteSize == 0 || std::memcmp(found->second.palette.data(), palette, paletteSize) == 0)) {
        ++cache.hits;
        found->second.lastUse = ++cache.serial;
        *pixels = found->second.pixels;
        return true;
    }
    ++cache.misses;
    auto decoded = std::make_shared<std::vector<u8>>();
    if (!DecodeTexture(source, sourceSize, *state, format, width, height, decoded.get(), textureUnit))
        return false;
    *pixels = decoded;
    // The byte budget covers retained encoded, palette and decoded payloads.
    // Draw references keep evicted immutable pixels alive only until submission.
    const size_t entryBytes = sourceSize + paletteSize + decoded->size();
    if (!cache.enabled || entryBytes > cache.byteLimit || cache.entryLimit == 0) return true;
    if (found != cache.entries.end()) {
        cache.bytes -= found->second.size();
        cache.entries.erase(found);
    }
    while (!cache.entries.empty() &&
           (cache.bytes + entryBytes > cache.byteLimit || cache.entries.size() >= cache.entryLimit)) {
        auto oldest = std::min_element(cache.entries.begin(), cache.entries.end(),
            [](const auto& a, const auto& b) { return a.second.lastUse < b.second.lastUse; });
        cache.bytes -= oldest->second.size();
        cache.entries.erase(oldest);
        ++cache.evictions;
    }
    DecodedTextureEntry entry;
    entry.source.assign(source, source + sourceSize);
    if (paletteSize) entry.palette.assign(palette, palette + paletteSize);
    entry.pixels = std::move(decoded);
    entry.lastUse = ++cache.serial;
    cache.bytes += entryBytes;
    cache.entries.emplace(key, std::move(entry));
    return true;
}

static bool DecodePrimitiveVertices(
    const DecoderState& state,
    CPUState* cpu,
    u8 opcode,
    u32 vertexCount,
    const u8* payload,
    size_t payloadSize,
    bool transformPositions,
    LiveDraw* draw,
    NSString** errorMessage
) {
    const u32 vat = opcode & 0x7u;
    draw->sourceVertexCount = vertexCount;
    const u32 descriptorLow = state.cp[0x50];
    const u32 descriptorHigh = state.cp[0x60];
    const u32 group0 = state.cp[0x70u + vat];
    const u32 group1 = state.cp[0x80u + vat];
    const u32 group2 = state.cp[0x90u + vat];
    std::vector<LiveVertex> sourceVertices;
    sourceVertices.reserve(vertexCount);
    const bool sourceBackdropAttributes = transformPositions &&
        ((descriptorLow >> 9u) & 3u) >= 2u && ((descriptorLow >> 11u) & 3u) == 0u &&
        ((descriptorLow >> 13u) & 3u) != 0u && (group0 & 1u) && ((group0 >> 1u) & 7u) == 4u;
    const bool backdropCandidate = sourceBackdropAttributes && FiniteBackdropMaterialMatches(*draw);
    const bool repeatingCandidate = sourceBackdropAttributes && RepeatingBackdropMaterialMatches(*draw);
    const bool hillCandidate = sourceBackdropAttributes && (opcode & 0xf8u) == 0x98u &&
        HillBackdropMaterialMatches(*draw);
    const bool citySkyCandidate = sourceBackdropAttributes && (opcode & 0xf8u) == 0x98u &&
        CitySkyMaterialMatches(*draw);
    const bool relatedCitySkyCandidate = sourceBackdropAttributes && (opcode & 0xf8u) == 0x98u &&
        RelatedCitySkyMaterialMatches(*draw);
    const bool finiteRoomCandidate = sourceBackdropAttributes && (opcode & 0xf8u) == 0x98u &&
        FiniteRoomMaterialMatches(*draw);
    std::array<u8, 16*12> backdropPositions{};
    std::array<u8, 21*12> citySkyPositions{};
    std::array<u8, 9*12> relatedCitySkyPositions{};
    // Opt-in diagnostics must also identify finite meshes outside the existing
    // correction families, including the 1080-vertex terminal room wall. The
    // bounded source copy supplies evidence only; it admits no presentation fix.
    const bool sceneAuditCandidate = state.sceneSourceAuditEnabled && sourceBackdropAttributes &&
        vertexCount > 0 && vertexCount <= 2048 && draw->displayListDepth == 1 &&
        ClassifyWideDraw(*draw) == WideDrawRole::Scene;
    const bool captureSourcePositions = sceneAuditCandidate || finiteRoomCandidate;
    std::vector<u8> sceneAuditPositions(captureSourcePositions ? vertexCount*12u : 0u);
    NSString* collapsedNormalFailure = nil;
    size_t cursor = 0u;
    for (u32 vertexIndex = 0u; vertexIndex < vertexCount; ++vertexIndex) {
        u32 positionMatrix = state.cp[0x30] & 0x3Fu;
        u32 textureMatrixIndices[8] = {};
        for (u32 textureIndex = 0u; textureIndex < 8u; ++textureIndex) {
            textureMatrixIndices[textureIndex] =
                DefaultTextureMatrixIndex(state, textureIndex);
        }
        for (u32 matrixIndex = 0u; matrixIndex < 9u; ++matrixIndex) {
            if (((descriptorLow >> matrixIndex) & 1u) == 0u) {
                continue;
            }
            if (cursor >= payloadSize) {
                *errorMessage = @"primitive matrix index exceeds payload";
                return false;
            }
            const u32 value = payload[cursor++];
            if (matrixIndex == 0u) {
                positionMatrix = value & 0x3Fu;
            } else {
                textureMatrixIndices[matrixIndex - 1u] = value & 0x3Fu;
            }
        }

        LiveVertex vertex{};
        float baseColor[4] = {1.0f, 1.0f, 1.0f, 1.0f};

        const u32 positionType = (descriptorLow >> 9u) & 0x3u;
        const u32 positionElements = 2u + (group0 & 1u);
        const u32 positionFormat = (group0 >> 1u) & 0x7u;
        const u32 positionFraction = (group0 >> 4u) & 0x1Fu;
        const size_t positionSize =
            ElementSize(positionFormat) * positionElements;
        const u8* positionSource = nullptr;
        if (
            !ResolveAttribute(
                state,
                cpu,
                payload,
                payloadSize,
                &cursor,
                positionType,
                0u,
                positionSize,
                &positionSource
            ) ||
            !positionSource
        ) {
            *errorMessage = @"failed to resolve primitive position";
            return false;
        }
        float position[3] = {0.0f, 0.0f, 0.0f};
        if (backdropCandidate || repeatingCandidate || hillCandidate)
            memcpy(backdropPositions.data() + vertexIndex * 12u, positionSource, 12u);
        if (citySkyCandidate)
            memcpy(citySkyPositions.data() + vertexIndex * 12u, positionSource, 12u);
        if (relatedCitySkyCandidate)
            memcpy(relatedCitySkyPositions.data() + vertexIndex * 12u, positionSource, 12u);
        if (captureSourcePositions)
            memcpy(sceneAuditPositions.data() + vertexIndex * 12u, positionSource, 12u);
        if (!DecodeNumericComponents(
                positionSource,
                positionSize,
                positionFormat,
                positionFraction,
                positionElements,
                position
            )) {
            *errorMessage = @"failed to decode primitive position";
            return false;
        }

        float rawNormal[3] = {0.0f, 0.0f, 1.0f};
        const u32 normalType = (descriptorLow >> 11u) & 0x3u;
        if (normalType != 0u) {
            const u32 normalElements = (group0 >> 9u) & 1u;
            const u32 normalFormat = (group0 >> 10u) & 0x7u;
            const size_t normalSize =
                ElementSize(normalFormat) *
                (normalElements != 0u ? 9u : 3u);
            const u8* normalSource = nullptr;
            if (!ResolveAttribute(
                    state,
                    cpu,
                    payload,
                    payloadSize,
                    &cursor,
                    normalType,
                    1u,
                    normalSize,
                    &normalSource
                ) ||
                !normalSource ||
                !DecodeNumericComponents(
                    normalSource,
                    normalSize,
                    normalFormat,
                    0u,
                    3u,
                    rawNormal
                )
            ) {
                *errorMessage = @"failed to resolve primitive normal";
                return false;
            }
            draw->hasNormal = true;
        }

        constexpr size_t colorSizes[] = {2u, 3u, 4u, 2u, 3u, 4u};
        for (u32 colorIndex = 0u; colorIndex < 2u; ++colorIndex) {
            const u32 typeShift = colorIndex == 0u ? 13u : 15u;
            const u32 formatShift = colorIndex == 0u ? 14u : 18u;
            const u32 colorType = (descriptorLow >> typeShift) & 0x3u;
            const u32 colorFormat = (group0 >> formatShift) & 0x7u;
            if (colorType == 0u) {
                continue;
            }
            if (colorFormat >= sizeof(colorSizes) / sizeof(colorSizes[0])) {
                *errorMessage = @"primitive color format is invalid";
                return false;
            }
            const u8* colorSource = nullptr;
            if (!ResolveAttribute(
                    state,
                    cpu,
                    payload,
                    payloadSize,
                    &cursor,
                    colorType,
                    2u + colorIndex,
                    colorSizes[colorFormat],
                    &colorSource
                )) {
                *errorMessage = @"failed to resolve primitive color";
                return false;
            }
            if (
                colorIndex == 0u &&
                !DecodeColor(colorSource, colorFormat, baseColor)
            ) {
                *errorMessage = @"failed to decode primitive color";
                return false;
            }
            if (colorIndex == 0u) {
                draw->hasVertexColor = true;
            }
        }

        float rawTextures[8][3] = {};
        for (auto& coordinate : rawTextures) {
            coordinate[2] = 1.0f;
        }
        const std::array<std::pair<u32, u32>, 8> textureFields = {{
            {(group0 >> 21u) & 0x1u, (group0 >> 22u) & 0x7u},
            {(group1 >> 0u) & 0x1u, (group1 >> 1u) & 0x7u},
            {(group1 >> 9u) & 0x1u, (group1 >> 10u) & 0x7u},
            {(group1 >> 18u) & 0x1u, (group1 >> 19u) & 0x7u},
            {(group1 >> 27u) & 0x1u, (group1 >> 28u) & 0x7u},
            {(group2 >> 5u) & 0x1u, (group2 >> 6u) & 0x7u},
            {(group2 >> 14u) & 0x1u, (group2 >> 15u) & 0x7u},
            {(group2 >> 23u) & 0x1u, (group2 >> 24u) & 0x7u},
        }};
        for (u32 textureIndex = 0u; textureIndex < 8u; ++textureIndex) {
            const u32 textureType =
                (descriptorHigh >> (textureIndex * 2u)) & 0x3u;
            if (textureType == 0u) {
                continue;
            }
            const u32 elements = 1u + textureFields[textureIndex].first;
            const u32 format = textureFields[textureIndex].second;
            const u32 fraction =
                textureIndex == 0u
                    ? (group0 >> 25u) & 0x1Fu
                    : textureIndex < 4u
                        ? (
                            group1 >>
                            (textureIndex == 1u
                                ? 4u
                                : textureIndex == 2u ? 13u : 22u)
                          ) & 0x1Fu
                        : (
                            group2 >>
                            (textureIndex == 4u
                                ? 0u
                                : 9u + (textureIndex - 5u) * 9u)
                          ) & 0x1Fu;
            const size_t textureSize = ElementSize(format) * elements;
            const u8* textureSource = nullptr;
            if (!ResolveAttribute(
                    state,
                    cpu,
                    payload,
                    payloadSize,
                    &cursor,
                    textureType,
                    4u + textureIndex,
                    textureSize,
                    &textureSource
                )) {
                *errorMessage = @"failed to resolve texture coordinate";
                return false;
            }
            if (
                !DecodeNumericComponents(
                    textureSource,
                    textureSize,
                    format,
                    fraction,
                    elements,
                    rawTextures[textureIndex]
                )
            ) {
                *errorMessage = @"failed to decode texture coordinate";
                return false;
            }
        }

        float eye[3] = {};
        if (transformPositions) {
            if (!TransformPosition(
                    state,
                    positionMatrix,
                    position,
                    vertex.position,
                    eye
                )) {
                *errorMessage = @"failed to transform primitive position";
                return false;
            }
        } else {
            vertex.position[0] = position[0] / 320.0f;
            vertex.position[1] = -position[1] / 240.0f;
            vertex.position[2] = 0.0f;
            vertex.position[3] = 1.0f;
            std::copy(position, position + 3u, eye);
        }
        float transformedNormal[3] = {
            rawNormal[0], rawNormal[1], rawNormal[2]
        };
        if (
            normalType != 0u &&
            !TransformNormal(
                state,
                positionMatrix,
                rawNormal,
                transformedNormal
            )
        ) {
            const size_t normalBase = 0x400u + 3u * (positionMatrix & 0x1Fu);
            NSString* normalFailure = collapsedNormalFailure ? collapsedNormalFailure : [NSString stringWithFormat:
                @"failed to transform primitive normal matrix=%u "
                 "raw=(%g,%g,%g) transformed=(%g,%g,%g) channels=%08X/%08X "
                 "xf=[%08X,%08X,%08X;%08X,%08X,%08X;%08X,%08X,%08X] "
                 "position=(%g,%g,%g) clip=(%g,%g,%g,%g)",
                positionMatrix, rawNormal[0], rawNormal[1], rawNormal[2],
                transformedNormal[0], transformedNormal[1], transformedNormal[2],
                state.xf[0x100E], state.xf[0x1010],
                state.xf[normalBase], state.xf[normalBase + 1], state.xf[normalBase + 2],
                state.xf[normalBase + 3], state.xf[normalBase + 4], state.xf[normalBase + 5],
                state.xf[normalBase + 6], state.xf[normalBase + 7], state.xf[normalBase + 8],
                position[0], position[1], position[2], vertex.position[0],
                vertex.position[1], vertex.position[2], vertex.position[3]];
            // The title submits zero-scale objects (including their normal
            // matrices). Defer this one finite-zero case until all vertices
            // prove the primitive is a single clip-space point. Do not invent
            // a normal for visible geometry or admit NaNs/infinities.
            bool zeroScale = transformPositions && transformedNormal[0] == 0.0f &&
                transformedNormal[1] == 0.0f && transformedNormal[2] == 0.0f;
            const size_t positionBase = (positionMatrix & 0x3Fu) * 4u;
            for (u32 row = 0u; row < 3u; ++row)
                for (u32 column = 0u; column < 3u; ++column)
                    zeroScale = zeroScale &&
                        WordFloat(state.xf[positionBase + row * 4u + column]) == 0.0f;
            if (!zeroScale) {
                *errorMessage = normalFailure;
                return false;
            }
            if (!collapsedNormalFailure) collapsedNormalFailure = normalFailure;
        }
        ApplyLighting(
            state,
            baseColor,
            eye,
            transformedNormal,
            vertex.color
        );
        for (
            u32 stage = 0u;
            stage < 8u;
            ++stage
        ) {
            if ((stage < 4u && stage >= draw->fragment.stageCount) ||
                (stage >= 4u && stage - 4u >= draw->fragment.indirectCount)) continue;
            float diagnosticQ = NAN;
            if (!GenerateTextureCoordinate(
                    state,
                    draw->textureCoordinates[stage],
                    position,
                    rawNormal,
                    rawTextures,
                    textureMatrixIndices,
                    vertex.color,
                    stage < 4u ? vertex.uv[stage] : vertex.indirectUV[stage - 4u],
                    state.sceneSourceAuditEnabled ? &diagnosticQ : nullptr,
                    stage < 4u ? &vertex.uvQ[stage] : nullptr
                )) {
                *errorMessage = [NSString stringWithFormat:
                    @"unsupported texture generation stage=%u coord=%u "
                     "info=0x%08X",
                    stage,
                    draw->textureCoordinates[stage],
                    state.xf[
                        0x1040u + draw->textureCoordinates[stage]
                    ]
                ];
                return false;
            }
            if (state.sceneSourceAuditEnabled && std::isfinite(diagnosticQ)) {
                auto& range = draw->textureQBounds[stage];
                if (!draw->textureQCaptured[stage]) range = {diagnosticQ, diagnosticQ};
                else {
                    range[0] = std::min(range[0], diagnosticQ);
                    range[1] = std::max(range[1], diagnosticQ);
                }
                draw->textureQCaptured[stage] = true;
                draw->textureGenerationInfo[stage] = state.xf[0x1040u + draw->textureCoordinates[stage]];
            }
        }
        sourceVertices.push_back(vertex);
    }
    if (cursor != payloadSize) {
        *errorMessage = [NSString stringWithFormat:
            @"primitive payload mismatch consumed=%zu expected=%zu",
            cursor,
            payloadSize
        ];
        return false;
    }

    if (!BuildPrimitiveIndices(opcode, vertexCount, &draw->indices, errorMessage)) return false;
    if (captureSourcePositions) {
        std::array<u8,CC_SHA256_DIGEST_LENGTH> hash{};
        CC_SHA256(sceneAuditPositions.data(), vertexCount * 12u,
                  hash.data());
        if (sceneAuditCandidate) {
            draw->backdropSourcePositionKey = hash;
            draw->hasBackdropSourcePositionKey = true;
        }
        if (finiteRoomCandidate && !draw->hasNormal && draw->hasVertexColor) {
            char digest[65]{};
            for (size_t i=0; i<hash.size(); ++i) snprintf(digest+i*2,3,"%02x",hash[i]);
            const u8 identity=FiniteRoomSourceIdentity(digest);
            if (FiniteRoomSourceUVMatches(identity,sourceVertices) && FiniteRoomTextureMatches(*draw,identity))
                draw->finiteRoomIdentity=identity;
        }
    }
    if (citySkyCandidate && !draw->hasNormal && draw->hasVertexColor) {
        std::array<u8, CC_SHA256_DIGEST_LENGTH> hash{};
        CC_SHA256(citySkyPositions.data(), vertexCount*12u, hash.data());
        char digest[65]{};
        for (size_t i = 0; i < hash.size(); ++i) snprintf(digest+i*2, 3, "%02x", hash[i]);
        const u8 identity = CitySkySourceIdentity(digest);
        if (CitySkySourceUVMatches(identity, sourceVertices.data(), sourceVertices.size()) &&
            CitySkyTextureMatches(*draw)) draw->citySkyIdentity = identity;
    }
    if (relatedCitySkyCandidate && !draw->hasNormal && draw->hasVertexColor) {
        std::array<u8, CC_SHA256_DIGEST_LENGTH> hash{};
        CC_SHA256(relatedCitySkyPositions.data(), vertexCount*12u, hash.data());
        char digest[65]{};
        for (size_t i = 0; i < hash.size(); ++i) snprintf(digest+i*2,3,"%02x",hash[i]);
        const u8 identity = RelatedCitySkySourceIdentity(digest);
        if (RelatedCitySkyUVMatches(identity,sourceVertices.data(),sourceVertices.size()) &&
            CitySkyTextureMatches(*draw)) draw->relatedCitySkyIdentity = identity;
    }
    if (hillCandidate && !draw->hasNormal && draw->hasVertexColor) {
        std::array<u8,CC_SHA256_DIGEST_LENGTH> hash{};
        CC_SHA256(backdropPositions.data(),vertexCount*12u,hash.data());
        char digest[65]{};
        for (size_t i=0;i<hash.size();++i) snprintf(digest+i*2,3,"%02x",hash[i]);
        const u8 identity=HillBackdropSourceIdentity(digest);
        if (HillBackdropSourceUVMatches(identity,sourceVertices) && HillBackdropTexturesMatch(*draw))
            draw->hillBackdropIdentity=identity;
    }
    if (repeatingCandidate && !draw->hasNormal && draw->hasVertexColor) {
        std::array<u8, CC_SHA256_DIGEST_LENGTH> hash{};
        CC_SHA256(backdropPositions.data(), vertexCount*12u, hash.data());
        char digest[65]{};
        for (size_t i = 0; i < hash.size(); ++i) snprintf(digest+i*2,3,"%02x",hash[i]);
        const u8 identity = RepeatingBackdropSourceIdentity(digest);
        if (RepeatingBackdropSourceUVMatches(identity,sourceVertices) && RepeatingBackdropTexturesMatch(*draw))
            draw->repeatingBackdropIdentity = identity;
    }
    if (backdropCandidate && !draw->hasNormal && draw->hasVertexColor) {
        std::array<u8, CC_SHA256_DIGEST_LENGTH> hash{};
        CC_SHA256(backdropPositions.data(), vertexCount * 12u, hash.data());
        char digest[65]{};
        for (size_t i = 0; i < hash.size(); ++i) snprintf(digest + i*2, 3, "%02x", hash[i]);
        if (CanyonSkyMaterialMatches(*draw)) {
            const u8 identity = CanyonSkySourceIdentity(digest);
            if (CanyonSkySourceUVMatches(identity, sourceVertices) && CanyonSkyTextureMatches(*draw))
                draw->canyonSkyIdentity = identity;
        }
        if (std::all_of(sourceVertices.begin(), sourceVertices.end(), [](const LiveVertex& v) {
            return v.uv[0][0] == 400.0f/1024.0f && v.uv[0][1] == 281.0f/1024.0f;
        })) draw->finiteBackdropIdentity = FiniteBackdropSourceIdentity(digest);
        if (draw->finiteBackdropIdentity) {
            float minimum = INFINITY;
            for (u32 i = 0; i < vertexCount; ++i)
                minimum = std::min(minimum, ReadBEFloat(backdropPositions.data() + i*12 + 4));
            u8 sourceMask = 0;
            for (u32 i = 0; i < vertexCount; ++i)
                if (ReadBEFloat(backdropPositions.data() + i*12 + 4) == minimum) sourceMask |= 1u << i;
            if (state.indexedVertices) draw->finiteBackdropLowerEdgeMask = sourceMask;
            else for (size_t i = 0; i < draw->indices.size(); ++i)
                if (sourceMask & (1u << draw->indices[i])) draw->finiteBackdropLowerEdgeMask |= 1u << i;
        }
    }
    if (collapsedNormalFailure && !sourceVertices.empty()) {
        for (const LiveVertex& vertex : sourceVertices) {
            for (u32 component = 0u; component < 4u; ++component) {
                if (vertex.position[component] != sourceVertices.front().position[component]) {
                    *errorMessage = collapsedNormalFailure;
                    return false;
                }
            }
        }
    }
    if (draw->geometryProfile && !RefineGeometry(draw, sourceVertices)) {
        *errorMessage = @"source-bound model refinement produced invalid geometry";
        return false;
    }
    draw->indexed = state.indexedVertices;
    if (draw->indexed) {
        draw->vertices = std::move(sourceVertices);
    } else {
        draw->vertices.reserve(draw->indices.size());
        for (u32 index : draw->indices) draw->vertices.push_back(sourceVertices[index]);
        draw->indices.clear();
    }
    return true;
}

static bool DecodeFrame(
    DecoderState* state,
    const u8* fifo,
    size_t fifoSize,
    CPUState* cpu,
    bool collectDraws,
    bool transformPositions,
    u32 recursionDepth,
    std::vector<LiveDraw>* draws,
    std::vector<LiveEfbCopy>* efbCopies,
    NSString** errorMessage,
    u32 displayListAddress = 0u,
    ProtectorMotionInstance motionInstance = {}
) {
    size_t offset = 0u;
    while (offset < fifoSize) {
        const u8 opcode = fifo[offset];
        const size_t available = fifoSize - offset;
        size_t commandSize = 1u;
        if (opcode == 0x00u) {
            commandSize = 1u;
        } else if (opcode == 0x08u) {
            commandSize = 6u;
            if (available < commandSize) {
                *errorMessage = @"truncated CP command";
                return false;
            }
            state->cp[fifo[offset + 1u]] =
                ReadBE32(fifo + offset + 2u);
        } else if (opcode == 0x10u) {
            if (available < 5u) {
                *errorMessage = @"truncated XF command";
                return false;
            }
            const u32 header = ReadBE32(fifo + offset + 1u);
            const size_t words = ((header >> 16u) & 0xFFFFu) + 1u;
            commandSize = 5u + words * 4u;
            if (available < commandSize) {
                *errorMessage = @"XF command exceeds frame";
                return false;
            }
            const u32 destination = header & 0xFFFFu;
            for (size_t index = 0u; index < words; ++index) {
                if (destination + index < state->xf.size()) {
                    state->xf[destination + index] =
                        ReadBE32(fifo + offset + 5u + index * 4u);
                }
            }
        } else if (
            opcode == 0x20u || opcode == 0x28u ||
            opcode == 0x30u || opcode == 0x38u
        ) {
            commandSize = 5u;
            if (available < commandSize) {
                *errorMessage = @"truncated indexed XF command";
                return false;
            }
            const u32 descriptor = ReadBE32(fifo + offset + 1u);
            const u32 array = 12u + ((opcode - 0x20u) / 8u);
            const u32 index = descriptor >> 16u;
            const u32 destination = descriptor & 0xFFFu;
            const u32 words = ((descriptor >> 12u) & 0xFu) + 1u;
            const uint64_t address = (uint64_t)state->cp[0xA0u + array] +
                (uint64_t)index * (state->cp[0xB0u + array] & 0xFFu);
            const u8* source = nullptr;
            if (address > UINT32_MAX || destination + words > 0x1000u ||
                !ReadPhysical(cpu, (u32)address, words * 4u, &source)) {
                *errorMessage = [NSString stringWithFormat:
                    @"invalid indexed XF load array=%u index=%u "
                     "address=0x%llX destination=0x%03X words=%u",
                    array, index, (unsigned long long)address, destination, words];
                return false;
            }
            for (u32 word = 0u; word < words; ++word) {
                state->xf[destination + word] = ReadBE32(source + word * 4u);
            }
            ++state->indexedXFLoads;
        } else if (opcode == 0x40u) {
            commandSize = 9u;
            if (available < commandSize) {
                *errorMessage = @"truncated display-list call";
                return false;
            }
            if (collectDraws) {
                if (recursionDepth >= 4u) {
                    *errorMessage = @"GX display-list recursion limit exceeded";
                    return false;
                }
                const u32 address = ReadBE32(fifo + offset + 1u);
                const u32 length = ReadBE32(fifo + offset + 5u);
                const u8* displayList = nullptr;
                if (
                    length == 0u ||
                    !ReadPhysical(
                        cpu,
                        address & 0x3FFFFFFFu,
                        length,
                        &displayList
                    )
                ) {
                    *errorMessage = [NSString stringWithFormat:
                        @"failed to resolve GX display list "
                         "address=0x%08X bytes=%u",
                        address,
                        length
                    ];
                    return false;
                }
                if (!DecodeFrame(
                        state,
                        displayList,
                        length,
                        cpu,
                        true,
                        true,
                        recursionDepth + 1u,
                        draws,
                        efbCopies,
                        errorMessage,
                        address & 0x3FFFFFFFu,
                        recursionDepth == 0 ? protector_motion_identity_lookup(cpu, fifo, fifoSize, offset, address, length)
                                            : ProtectorMotionInstance{}
                    )) {
                    return false;
                }
            }
        } else if (opcode == 0x44u || opcode == 0x48u) {
            commandSize = 1u;
        } else if (opcode == 0x61u) {
            commandSize = 5u;
            if (available < commandSize) {
                *errorMessage = @"truncated BP command";
                return false;
            }
            const u32 reg = fifo[offset + 1u];
            const u32 written = ReadBE24(fifo + offset + 2u);
            const u32 mask = state->bp[0xFE] & 0xFFFFFFu;
            const u32 old = state->bp[reg] & 0xFFFFFFu;
            state->bp[reg] = (old & ~mask) | (written & mask);
            UpdateTevRegister(state, reg, state->bp[reg]);
            if (reg != 0xFEu) {
                state->bp[0xFE] = 0xFFFFFFu;
            }
            if (reg == 0x65u) {
                const u32 sourceAddress =
                    (state->bp[0x64] & 0xFFFFFFu) << 5u;
                const u32 destination =
                    (state->bp[0x65] & 0x3FFu) << 9u;
                const size_t transferSize =
                    ((state->bp[0x65] >> 10u) & 0x7FFu) * 32u;
                const u8* source = nullptr;
                if (
                    transferSize > 0u &&
                    (uint64_t)destination + transferSize <=
                        state->textureMemory.size() &&
                    ReadPhysical(cpu, sourceAddress, transferSize, &source)
                ) {
                    std::memcpy(
                        state->textureMemory.data() + destination,
                        source,
                        transferSize
                    );
                }
            }
            if (collectDraws && reg == 0x52u) {
                const u32 source = state->bp[0x49] & 0xFFFFFFu;
                const u32 size = state->bp[0x4A] & 0xFFFFFFu;
                LiveEfbCopy copy;
                copy.drawIndex = draws->size();
                copy.sourceX = source & 0x3FFu;
                copy.sourceY = (source >> 10u) & 0x3FFu;
                copy.width = (size & 0x3FFu) + 1u;
                copy.height = ((size >> 10u) & 0x3FFu) + 1u;
                copy.destinationAddress =
                    (state->bp[0x4B] & 0xFFFFFFu) << 5u;
                copy.command = state->bp[0x52] & 0xFFFFFFu;
                copy.yScale = state->bp[0x4E] & 0x1FFu;
                efbCopies->push_back(copy);
            }
        } else if (opcode >= 0x80u && opcode <= 0xBFu) {
            if (available < 3u) {
                *errorMessage = @"truncated primitive";
                return false;
            }
            const u32 vertexCount = ReadBE16(fifo + offset + 1u);
            const u32 vat = opcode & 0x7u;
            size_t vertexSize = 0u;
            if (!VertexSize(*state, vat, &vertexSize)) {
                *errorMessage = @"invalid VAT while sizing primitive";
                return false;
            }
            if (
                vertexSize > std::numeric_limits<size_t>::max() /
                    std::max<u32>(vertexCount, 1u)
            ) {
                *errorMessage = @"primitive size overflow";
                return false;
            }
            commandSize = 3u + (size_t)vertexCount * vertexSize;
            if (available < commandSize) {
                *errorMessage = @"primitive exceeds frame";
                return false;
            }
            if (collectDraws && vertexCount > 0u) {
                if (state->geometrySourceTrace) {
                    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
                    CC_SHA256(fifo + offset, (CC_LONG)commandSize, digest);
                    char hex[65]{};
                    for (size_t i = 0; i < sizeof(digest); ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
                    fprintf(stderr, "geometry_source draw=%zu opcode=%02X vertices=%u bytes=%zu sha256=%s cp50=%08X cp60=%08X vat=%08X arrays=%08X,%08X,%08X,%08X strides=%u,%u,%u,%u depth=%06X projection=%08X,%08X,%08X,%08X,%08X,%08X,%08X\n",
                        draws->size(), opcode, vertexCount, commandSize, hex,
                        state->cp[0x50], state->cp[0x60], state->cp[0x70 + vat],
                        state->cp[0xA0], state->cp[0xA1], state->cp[0xA2], state->cp[0xA4],
                        state->cp[0xB0] & 255u, state->cp[0xB1] & 255u, state->cp[0xB2] & 255u, state->cp[0xB4] & 255u,
                        state->bp[0x40] & 0xFFFFFFu, state->xf[0x1020], state->xf[0x1021], state->xf[0x1022],
                        state->xf[0x1023], state->xf[0x1024], state->xf[0x1025], state->xf[0x1026]);
                }
                LiveDraw draw;
                draw.motionInstance = motionInstance;
                draw.displayListDepth = recursionDepth;
                if (!PopulateFragmentState(*state, &draw, errorMessage)) {
                    return false;
                }
                if (!DecodeDrawTextures(
                        *state, cpu, &draw, errorMessage
                    )) {
                    return false;
                }
                const u8* payload = fifo + offset + 3u;
                if (state->geometryPack && transformPositions && opcode == 0x9Eu) {
                    const auto* profile = GeometryProfileForDraw(*state, cpu, fifo + offset, commandSize, vertexCount);
                    if (profile && getenv("PROTECTOR_GEOMETRY_ADMISSION_TRACE")) {
                        static unsigned diagnostics = 0;
                        if (diagnostics++ < 32u) fprintf(stderr,
                            "geometry_admission source_match=%d vertices=%u cp50=%08X cp60=%08X vat6=%08X arrays=%08X,%08X,%08X,%08X strides=%u,%u,%u,%u\n",
                            GeometrySourceMatches(*state, cpu, profile), vertexCount,
                            state->cp[0x50], state->cp[0x60], state->cp[0x76],
                            state->cp[0xA0], state->cp[0xA1], state->cp[0xA2], state->cp[0xA4],
                            state->cp[0xB0] & 255u, state->cp[0xB1] & 255u,
                            state->cp[0xB2] & 255u, state->cp[0xB4] & 255u);
                    }
                    draw.geometryProfile = profile;
                }
                SetMotionSourceKey(*state, fifo + offset, commandSize, displayListAddress, offset, &draw);
                if (!DecodePrimitiveVertices(
                        *state,
                        cpu,
                        opcode,
                        vertexCount,
                        payload,
                        (size_t)vertexCount * vertexSize,
                        transformPositions,
                        &draw,
                        errorMessage
                    )) {
                    return false;
                }
                draws->push_back(std::move(draw));
            }
        } else {
            *errorMessage = [NSString stringWithFormat:
                @"unsupported GX opcode 0x%02X at 0x%zX",
                opcode,
                offset
            ];
            return false;
        }
        if (commandSize == 0u || commandSize > available) {
            *errorMessage = [NSString stringWithFormat:
                @"GX command 0x%02X exceeds frame at 0x%zX",
                opcode,
                offset
            ];
            return false;
        }
        offset += commandSize;
    }
    return true;
}

static MTLCompareFunction MetalCompareFunction(u32 gxCompare) {
    switch (gxCompare & 7u) {
        case 0u: return MTLCompareFunctionNever;
        case 1u: return MTLCompareFunctionLess;
        case 2u: return MTLCompareFunctionEqual;
        case 3u: return MTLCompareFunctionLessEqual;
        case 4u: return MTLCompareFunctionGreater;
        case 5u: return MTLCompareFunctionNotEqual;
        case 6u: return MTLCompareFunctionGreaterEqual;
        default: return MTLCompareFunctionAlways;
    }
}

static MTLSamplerAddressMode MetalAddressMode(u32 gxWrap) {
    if (gxWrap == 1u) {
        return MTLSamplerAddressModeRepeat;
    }
    if (gxWrap == 2u) {
        return MTLSamplerAddressModeMirrorRepeat;
    }
    return MTLSamplerAddressModeClampToEdge;
}

// Explicit diagnostics may read a private live target only after its render
// command completes. Stage that one requested picture, not every live frame.
static id<MTLTexture> ReadableTexture(id<MTLTexture> texture, NSError** error) {
    if (texture.storageMode != MTLStorageModePrivate) return texture;
    MTLTextureDescriptor* descriptor=[MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:texture.pixelFormat
        width:texture.width height:texture.height mipmapped:NO];
    descriptor.storageMode=MTLStorageModeShared;
    descriptor.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> readable=[texture.device newTextureWithDescriptor:descriptor];
    id<MTLCommandQueue> queue=[texture.device newCommandQueue];
    id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    if (!readable || !blit) {
        if (blit) [blit endEncoding];
        if (error) *error=LiveError(20,@"Diagnostic picture staging allocation failed.");
        return nil;
    }
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(texture.width,texture.height,1) toTexture:readable
        destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];[command commit];[command waitUntilCompleted];
    if (command.status==MTLCommandBufferStatusError) {
        if (error) *error=command.error ? command.error : LiveError(20,@"Diagnostic picture staging failed.");
        return nil;
    }
    return readable;
}

static bool WritePNG(
    id<MTLTexture> texture,
    NSURL* destination,
    NSError** error,
    CGImageAlphaInfo alphaInfo = kCGImageAlphaPremultipliedFirst
) {
    texture=ReadableTexture(texture,error);
    if (!texture) return false;
    const size_t bytesPerRow = texture.width * 4u;
    NSMutableData* pixels = [NSMutableData
        dataWithLength:bytesPerRow * texture.height];
    [texture getBytes:pixels.mutableBytes
          bytesPerRow:bytesPerRow
           fromRegion:MTLRegionMake2D(
                0, 0, texture.width, texture.height
           )
          mipmapLevel:0];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(
        (__bridge CFDataRef)pixels
    );
    CGImageRef image = CGImageCreate(
        texture.width,
        texture.height,
        8,
        32,
        bytesPerRow,
        colorSpace,
        kCGBitmapByteOrder32Little | alphaInfo,
        provider,
        NULL,
        false,
        kCGRenderingIntentDefault
    );
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    if (!image) {
        if (error) {
            *error = LiveError(20, @"failed to create live GX image");
        }
        return false;
    }
    CGImageDestinationRef output = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)destination,
        (__bridge CFStringRef)UTTypePNG.identifier,
        1,
        NULL
    );
    if (!output) {
        CGImageRelease(image);
        if (error) {
            *error = LiveError(21, @"failed to create PNG destination");
        }
        return false;
    }
    CGImageDestinationAddImage(output, image, NULL);
    const bool wrote = CGImageDestinationFinalize(output);
    CFRelease(output);
    CGImageRelease(image);
    if (!wrote && error) {
        *error = LiveError(22, @"failed to finalize live GX PNG");
    }
    return wrote;
}

}  // namespace

// Motion correspondence for one new guest frame, computed from immutable
// inputs so the guest thread can do it without holding the renderer lock.
// Only the guest thread writes the current endpoint's draws and copies; the
// scalar fields other threads may reset are passed in as a locked snapshot.
struct MotionStageInputs {
    uint64_t generation = 0;
    bool paused = false;
    double currentDeadline = 0;
    bool detailedAudit = false;
    bool sourceInstanceAudit = false;
};

struct MotionStagePlan {
    uint64_t generation = 0;
    double interval = 0;
    const char* holdReason = "history-empty";
    bool ready = false;
    bool copyFencesShifted = false;
    NSDictionary* copyMismatch = nil;
    std::vector<s32> matches;
    size_t matchedDraws = 0, matchedModelDraws = 0, matchedShadowDraws = 0;
    size_t matchedShadowModelDraws = 0, matchedUnusedColorDraws = 0;
    size_t sceneDraws = 0, shadowDraws = 0;
    NSDictionary* audit = nil;
};

static MotionStagePlan PlanMotionStage(const ArtworkPreviewFrame& current, const MotionStageInputs& inputs,
    const std::vector<LiveDraw>& draws, const std::vector<LiveEfbCopy>& copies, u32 index, u64 ticks,
    double deadline) {
    MotionStagePlan plan;
    plan.generation = inputs.generation;
    plan.holdReason = inputs.paused ? "host-paused" : !current.valid ? "history-empty" :
        current.index == UINT32_MAX || index != current.index + 1 ? "source-frame-gap" :
        !MotionCopiesCompatible(current.copies, current.draws.size(), copies, draws.size()) ? "changed-copy-layout" :
        !protector_motion_interval(current.guestTicks, ticks, inputs.currentDeadline, deadline, &plan.interval)
            ? "clock-discontinuity" : "none";
    plan.ready = strcmp(plan.holdReason, "none") == 0;
    plan.copyMismatch = strcmp(plan.holdReason, "changed-copy-layout") == 0
        ? @{@"previous":MotionCopyLayout(current.copies, current.draws.size()),
            @"current":MotionCopyLayout(copies, draws.size())} : nil;
    plan.sceneDraws = std::count_if(draws.begin(), draws.end(),
        [](const LiveDraw& draw) { return ClassifyWideDraw(draw) == WideDrawRole::Scene; });
    const auto roles = MotionDrawRoles(draws, &copies);
    plan.shadowDraws = std::count(roles.begin(), roles.end(), MotionDrawRole::Shadow);
    if (!plan.ready) return plan;
    for (size_t i = 0; i < copies.size(); ++i)
        if (current.copies[i].drawIndex != copies[i].drawIndex) plan.copyFencesShifted = true;
    NSMutableDictionary* audit = [MotionCorrespondenceAudit(&current, draws, index, &plan.matches, &copies,
        inputs.detailedAudit) mutableCopy];
    GuardMotionCopyPasses(current.copies, copies, &plan.matches);
    NSMutableArray* guards = inputs.detailedAudit ? [NSMutableArray array] : nil;
    NSMutableDictionary* shadowRoundoff = inputs.detailedAudit ? [NSMutableDictionary dictionary] : nil;
    plan.matches = GuardMotionGroups(current, draws, std::move(plan.matches), guards, &copies, shadowRoundoff);
    // Compact, final-guard evidence for source-owned unrefined pieces.
    // Normal sessions do not pay for this opt-in bounded QA summary.
    if (inputs.sourceInstanceAudit)
        audit[@"source_instances"] = MotionSourceInstanceAudit(draws, plan.matches, roles);
    audit[@"guarded_models"] = guards ? guards : @[];
    if (shadowRoundoff.count) audit[@"depthless_shadow_roundoff"] = shadowRoundoff;
    plan.matchedDraws = std::count_if(plan.matches.begin(), plan.matches.end(), [](s32 i) { return i >= 0; });
    plan.ready = plan.matchedDraws > 0;
    if (!plan.ready) plan.holdReason = "no-compatible-geometry";
    for (size_t i = 0; i < plan.matches.size(); ++i) if (plan.matches[i] >= 0) {
        if (draws[i].geometryProfile && roles[i] == MotionDrawRole::Scene) ++plan.matchedModelDraws;
        if (roles[i] == MotionDrawRole::Shadow) ++plan.matchedShadowDraws;
        if (draws[i].geometryProfile && roles[i] == MotionDrawRole::Shadow) ++plan.matchedShadowModelDraws;
        if (memcmp(current.draws[plan.matches[i]].fragment.colorRegisters, draws[i].fragment.colorRegisters,
                sizeof(draws[i].fragment.colorRegisters))) ++plan.matchedUnusedColorDraws;
    }
    audit[@"render_only_audit"] = @NO;
    audit[@"interpolation_enabled"] = @(plan.ready);
    audit[@"guarded_matched_draws"] = @(plan.matchedDraws);
    plan.audit = audit;
    return plan;
}

// Published decoder counters: the display thread reports these without
// touching decoder state that the guest thread mutates outside the lock.
struct DecoderStatsSnapshot {
    bool cacheEnabled = true;
    u64 hits = 0, misses = 0, evictions = 0;
    size_t bytes = 0;
    bool indexedVertices = true;
    u64 indexedXFLoads = 0;
};

static DecoderStatsSnapshot SnapshotDecoderStats(const DecoderState& state) {
    DecoderStatsSnapshot stats;
    stats.cacheEnabled = state.decodedTextures.enabled;
    stats.hits = state.decodedTextures.hits;
    stats.misses = state.decodedTextures.misses;
    stats.evictions = state.decodedTextures.evictions;
    stats.bytes = state.decodedTextures.bytes;
    stats.indexedVertices = state.indexedVertices;
    stats.indexedXFLoads = state.indexedXFLoads;
    return stats;
}


// Live presentation reuses its large render targets and vertex upload buffer
// instead of allocating ~120 MB of fresh textures every frame. A frame's
// resources return to the pool only when its holder is released: after its
// command buffer completes and a newer frame has replaced it as "latest".
// Opt-in per-pass GPU cost (performance capture only): stage-boundary
// timestamps around each render pass and blit of one live frame, labelled by
// kind and resolved after the command buffer completes.
@interface ProtectorPassTiming : NSObject
@property(nonatomic) id<MTLCounterSampleBuffer> buffer;
@property(nonatomic) NSMutableArray<NSString*>* kinds;
@end

@implementation ProtectorPassTiming
- (void)attachRender:(MTLRenderPassDescriptor*)pass kind:(NSString*)kind {
    MTLRenderPassSampleBufferAttachmentDescriptor* attachment = pass.sampleBufferAttachments[0];
    const NSUInteger index = self.kinds.count * 2;
    if (!self.buffer || index + 2 > self.buffer.sampleCount) { attachment.sampleBuffer = nil; return; }
    attachment.sampleBuffer = self.buffer;
    attachment.startOfVertexSampleIndex = index;
    attachment.endOfVertexSampleIndex = MTLCounterDontSample;
    attachment.startOfFragmentSampleIndex = MTLCounterDontSample;
    attachment.endOfFragmentSampleIndex = index + 1;
    [self.kinds addObject:kind];
}
- (id<MTLBlitCommandEncoder>)blitEncoder:(id<MTLCommandBuffer>)command kind:(NSString*)kind {
    const NSUInteger index = self.kinds.count * 2;
    if (!self.buffer || index + 2 > self.buffer.sampleCount) return [command blitCommandEncoder];
    MTLBlitPassDescriptor* descriptor = [MTLBlitPassDescriptor blitPassDescriptor];
    descriptor.sampleBufferAttachments[0].sampleBuffer = self.buffer;
    descriptor.sampleBufferAttachments[0].startOfEncoderSampleIndex = index;
    descriptor.sampleBufferAttachments[0].endOfEncoderSampleIndex = index + 1;
    [self.kinds addObject:kind];
    return [command blitCommandEncoderWithDescriptor:descriptor];
}
// Milliseconds and pass counts per kind; nil when any sample is unusable.
- (NSDictionary*)resolveWithSecondsPerTick:(double)secondsPerTick {
    if (!self.buffer || !self.kinds.count || !(secondsPerTick > 0)) return nil;
    NSData* data = [self.buffer resolveCounterRange:NSMakeRange(0, self.kinds.count * 2)];
    if (data.length < self.kinds.count * 2 * sizeof(MTLCounterResultTimestamp)) return nil;
    const auto* stamps = static_cast<const MTLCounterResultTimestamp*>(data.bytes);
    NSMutableDictionary<NSString*, NSNumber*>* milliseconds = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* counts = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < self.kinds.count; ++i) {
        const uint64_t start = stamps[2 * i].timestamp, end = stamps[2 * i + 1].timestamp;
        if (start == MTLCounterErrorValue || end == MTLCounterErrorValue || end < start) return nil;
        NSString* kind = self.kinds[i];
        milliseconds[kind] = @(milliseconds[kind].doubleValue + (double)(end - start) * secondsPerTick * 1000.0);
        counts[kind] = @(counts[kind].unsignedIntegerValue + 1);
    }
    return @{@"ms":milliseconds, @"count":counts, @"passes":@(self.kinds.count)};
}
@end

@interface ProtectorResourcePool : NSObject
- (id<MTLTexture>)textureWithDescriptor:(MTLTextureDescriptor*)descriptor device:(id<MTLDevice>)device;
- (id<MTLBuffer>)bufferWithLength:(NSUInteger)length device:(id<MTLDevice>)device;
- (void)recycleTextures:(NSArray<id<MTLTexture>>*)textures buffers:(NSArray<id<MTLBuffer>>*)buffers;
- (void)drain;
@property(nonatomic, readonly) NSUInteger pooledCount;
@property(nonatomic, readonly) uint64_t reuseCount;
@end

@implementation ProtectorResourcePool {
    os_unfair_lock _lock;
    NSMutableDictionary<NSString*, NSMutableArray*>* _free;
    NSUInteger _pooled;
    uint64_t _reused;
}
- (instancetype)init {
    if ((self = [super init])) { _lock = OS_UNFAIR_LOCK_INIT; _free = [NSMutableDictionary dictionary]; }
    return self;
}
static NSString* PoolTextureKey(NSUInteger w, NSUInteger h, MTLPixelFormat f, MTLStorageMode s, MTLTextureUsage u) {
    return [NSString stringWithFormat:@"t%lux%lu-%lu-%lu-%lu", (unsigned long)w, (unsigned long)h,
        (unsigned long)f, (unsigned long)s, (unsigned long)u];
}
static NSUInteger PoolBufferLength(NSUInteger length) { return ((length + 0xFFFFFu) / 0x100000u) * 0x100000u; }
- (id)takeKey:(NSString*)key {
    os_unfair_lock_lock(&_lock);
    NSMutableArray* list = _free[key];
    id object = list.lastObject;
    if (object) { [list removeLastObject]; --_pooled; ++_reused; }
    os_unfair_lock_unlock(&_lock);
    return object;
}
- (id<MTLTexture>)textureWithDescriptor:(MTLTextureDescriptor*)d device:(id<MTLDevice>)device {
    id<MTLTexture> texture = [self takeKey:PoolTextureKey(d.width, d.height, d.pixelFormat, d.storageMode, d.usage)];
    return texture ? texture : [device newTextureWithDescriptor:d];
}
- (id<MTLBuffer>)bufferWithLength:(NSUInteger)length device:(id<MTLDevice>)device {
    const NSUInteger rounded = PoolBufferLength(length);
    id<MTLBuffer> buffer = [self takeKey:[NSString stringWithFormat:@"b%lu", (unsigned long)rounded]];
    return buffer ? buffer : (rounded <= device.maxBufferLength
        ? [device newBufferWithLength:rounded options:MTLResourceStorageModeShared] : nil);
}
- (void)recycleTextures:(NSArray<id<MTLTexture>>*)textures buffers:(NSArray<id<MTLBuffer>>*)buffers {
    os_unfair_lock_lock(&_lock);
    const auto keep = [&](NSString* key, id object) {
        NSMutableArray* list = _free[key];
        if (!list) _free[key] = list = [NSMutableArray array];
        // A few frames in flight plus latest and a reader; anything beyond
        // that (or a stale size after a scale change) is released.
        if (list.count < 5 && _pooled < 96) { [list addObject:object]; ++_pooled; }
    };
    for (id<MTLTexture> t in textures)
        keep(PoolTextureKey(t.width, t.height, t.pixelFormat, t.storageMode, t.usage), t);
    for (id<MTLBuffer> b in buffers) keep([NSString stringWithFormat:@"b%lu", (unsigned long)b.length], b);
    os_unfair_lock_unlock(&_lock);
}
- (void)drain {
    os_unfair_lock_lock(&_lock);
    [_free removeAllObjects]; _pooled = 0;
    os_unfair_lock_unlock(&_lock);
}
- (NSUInteger)pooledCount { os_unfair_lock_lock(&_lock); const NSUInteger n = _pooled; os_unfair_lock_unlock(&_lock); return n; }
- (uint64_t)reuseCount { os_unfair_lock_lock(&_lock); const uint64_t n = _reused; os_unfair_lock_unlock(&_lock); return n; }
@end

@interface ProtectorFrameResources : NSObject
- (instancetype)initWithPool:(ProtectorResourcePool*)pool device:(id<MTLDevice>)device;
- (id<MTLTexture>)texture:(MTLTextureDescriptor*)descriptor;
- (id<MTLBuffer>)buffer:(NSUInteger)length;
@end

@implementation ProtectorFrameResources {
    ProtectorResourcePool* _pool;
    id<MTLDevice> _device;
    NSMutableArray<id<MTLTexture>>* _textures;
    NSMutableArray<id<MTLBuffer>>* _buffers;
}
- (instancetype)initWithPool:(ProtectorResourcePool*)pool device:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _pool = pool; _device = device;
        _textures = [NSMutableArray array]; _buffers = [NSMutableArray array];
    }
    return self;
}
- (id<MTLTexture>)texture:(MTLTextureDescriptor*)descriptor {
    id<MTLTexture> texture = [_pool textureWithDescriptor:descriptor device:_device];
    if (texture) [_textures addObject:texture];
    return texture;
}
- (id<MTLBuffer>)buffer:(NSUInteger)length {
    id<MTLBuffer> buffer = [_pool bufferWithLength:length device:_device];
    if (buffer) [_buffers addObject:buffer];
    return buffer;
}
- (void)dealloc { [_pool recycleTextures:_textures buffers:_buffers]; }
@end

@interface ProtectorPerformanceRing : NSObject
@property(nonatomic, readonly) NSArray<NSString*>* filenames;
@property(nonatomic, readonly) NSUInteger recordsPerSegment;
@property(nonatomic, readonly) NSUInteger activeSegment;
@property(nonatomic, readonly) NSUInteger totalRecords;
@property(nonatomic, readonly) NSUInteger rotations;
- (nullable instancetype)initWithDirectory:(NSURL*)directory stem:(NSString*)stem
                         recordsPerSegment:(NSUInteger)records error:(NSError**)error;
- (BOOL)writeRecord:(NSData*)line error:(NSError**)error;
- (NSDictionary*)receipt;
- (void)close;
@end

@implementation ProtectorPerformanceRing {
    NSArray<NSFileHandle*>* _handles;
    NSUInteger _segmentRecords;
}
// Two alternating JSONL segments retain the newest records without a cap that
// ends a session's evidence. A reader orders both files by "sequence"; the
// retained window is always between one and two segments.
- (instancetype)initWithDirectory:(NSURL*)directory stem:(NSString*)stem
                recordsPerSegment:(NSUInteger)records error:(NSError**)error {
    if (!(self = [super init])) return nil;
    if (records < 2 || records > 65536) {
        if (error) *error = LiveError(36, @"Performance ring segment size must be between 2 and 65536 records.");
        return nil;
    }
    NSMutableArray* names = [NSMutableArray array];
    NSMutableArray* handles = [NSMutableArray array];
    for (NSUInteger segment = 0; segment < 2; ++segment) {
        NSString* name = [NSString stringWithFormat:@"%@-ring%lu.jsonl", stem, (unsigned long)segment];
        NSURL* url = [directory URLByAppendingPathComponent:name];
        if (![[NSData data] writeToURL:url options:NSDataWritingWithoutOverwriting error:error]) return nil;
        NSFileHandle* handle = [NSFileHandle fileHandleForWritingToURL:url error:error];
        if (!handle) return nil;
        [names addObject:name];
        [handles addObject:handle];
    }
    _filenames = names;
    _handles = handles;
    _recordsPerSegment = records;
    return self;
}
- (BOOL)writeRecord:(NSData*)line error:(NSError**)error {
    @synchronized(self) {
        if (_segmentRecords >= _recordsPerSegment) {
            _activeSegment = 1 - _activeSegment;
            if (![_handles[_activeSegment] truncateAtOffset:0 error:error]) return NO;
            _segmentRecords = 0;
            ++_rotations;
        }
        if (![_handles[_activeSegment] writeData:line error:error]) return NO;
        ++_segmentRecords;
        ++_totalRecords;
        return YES;
    }
}
- (NSDictionary*)receipt {
    @synchronized(self) {
        return @{@"files":_filenames, @"records_per_segment":@(_recordsPerSegment),
            @"active_segment":@(_activeSegment), @"total_records":@(_totalRecords),
            @"rotations":@(_rotations), @"order":@"merge both files by sequence"};
    }
}
- (void)close {
    @synchronized(self) { for (NSFileHandle* handle in _handles) [handle closeAndReturnError:nil]; }
}
@end

@interface ProtectorTextureCacheEntry : NSObject {
@public
    // The immutable decoded snapshot these pixels came from. The same
    // snapshot pointer means the same bytes, so most presentations skip the
    // byte comparison entirely.
    decltype(LiveDraw::decodedPixels)::value_type snapshot;
}
@property(nonatomic) NSData* pixels;
@property(nonatomic) id<MTLTexture> texture;
@property(nonatomic) NSString* candidateSourceKey;
@property(nonatomic) NSString* restoredSourceKey;
@end
@implementation ProtectorTextureCacheEntry
@end

@interface ProtectorLiveMetalRenderer ()
@property(atomic, readwrite) unsigned qtePrompts;
@property(atomic, readwrite) BOOL qtePointerActive;
@property(atomic, readwrite) CGRect qteTargetRect;
@property(nonatomic, strong) id<MTLTexture> qteGlyphColor;
@property(nonatomic, strong) id<MTLTexture> qteGlyphCoverage;
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLRenderPipelineState> opaquePipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> alphaPipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> additivePipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> oneOnePipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> subtractPipeline;
@property(nonatomic, strong) NSDictionary<NSNumber*, NSArray<id<MTLRenderPipelineState>>*>* directPipelines;
@property(nonatomic) BOOL shaderSpecializationEnabled; // private pixel/performance comparison
@property(nonatomic, strong) id<MTLRenderPipelineState> presentPipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> sceneAntialiasPipeline;
@property(nonatomic) BOOL sceneAntialiasEnabled; // enabled normally; private comparison control only
@property(nonatomic) BOOL renderTargetOptimizationsEnabled; // internal lossless A/B check
@property(nonatomic, strong) id<MTLRenderPipelineState> cinematicPipeline;
@property(nonatomic, strong) id<MTLDepthStencilState> cinematicDepthState;
@property(nonatomic, strong) id<MTLRenderPipelineState> cinematicSurroundPipeline;
@property(nonatomic, strong) id<MTLDepthStencilState> cinematicSurroundDepthState;
@property(nonatomic, strong) id<MTLSamplerState> sampler;
@property(atomic, strong, nullable) id<MTLTexture> latestTexture;
@property(atomic, strong, nullable) id<MTLTexture> latestPresentationTexture;
@property(nonatomic, strong) NSURL* outputDirectory;
@property(nonatomic, strong) NSIndexSet* targetFrames;
@property(nonatomic, strong) NSArray<NSNumber*>* targetFrameValues;
@property(nonatomic, strong) NSMutableArray<NSDictionary*>* submissions;
@property(nonatomic) void* decoderState;
@property(nonatomic) BOOL continuousPresentation;
@property(nonatomic) uint64_t renderedFrameCount;
@property(nonatomic) NSMutableDictionary<NSNumber*, ProtectorTextureCacheEntry*>* textureCache;
@property(nonatomic) NSMutableDictionary<NSNumber*, id<MTLSamplerState>>* samplerCache;
@property(nonatomic) NSMutableDictionary<NSNumber*, id<MTLDepthStencilState>>* depthCache;
@property(nonatomic) NSUInteger textureCacheBytes;
@property(nonatomic) uint64_t textureCacheHits;
@property(nonatomic) uint64_t textureCacheMisses;
@property(nonatomic) BOOL textureCacheEnabled;
@property(nonatomic) ProtectorTexturePack* texturePack;
@property(nonatomic) ProtectorGeometryPack* geometryPack;
@property(nonatomic) ProtectorCinematicPack* cinematicPack;
@property(atomic, readwrite) BOOL enhancedModelsEnabled;
@property(nonatomic) uint64_t geometryPreviewRedrawCount;
@property(nonatomic) BOOL geometryPreviewRedraw;
@property(nonatomic) BOOL frameUsesRestoredArtwork;
@property(nonatomic) void* artworkPreviewFrame;
@property(nonatomic) BOOL artworkPreviewRedraw;
@property(nonatomic) uint64_t artworkPreviewRedrawCount;
@property(nonatomic) BOOL resolutionPreviewRedraw;
@property(nonatomic) uint64_t resolutionPreviewRedrawCount;
@property(atomic, readwrite) NSUInteger renderScale;
@property(atomic, readwrite) NSUInteger renderScaleY;
@property(atomic, readwrite) BOOL nativeResolutionEnabled;
@property(nonatomic) CGSize nativeRenderPixelSize;
@property(atomic, readwrite) BOOL widescreenEnabled;
@property(nonatomic) BOOL aspectPreviewRedraw;
@property(nonatomic) uint64_t aspectPreviewRedrawCount;
@property(nonatomic) CGSize nativePresentationSize;
@property(nonatomic) CGRect nativeHudFrame;
@property(nonatomic) CGRect nativeComboFrame;
@property(nonatomic) CGRect nativeUpgradeFrame;
@property(nonatomic) CGRect nativeCombatFeedbackFrame;
@property(nonatomic) CGRect nativeMapTitleFrame;
@property(nonatomic) CGRect nativeMapCardsFrame;
@property(nonatomic) CGRect nativeMapHintsFrame;
@property(nonatomic, strong) id<MTLTexture> comboGlyphTexture;
@property(nonatomic) BOOL nativeViewportRedraw;
@property(nonatomic) uint64_t nativeViewportRedrawCount;
@property(nonatomic) BOOL projectionDiagnosticsEnabled;
@property(nonatomic) NSUInteger interfaceAuditMinimumFrame;
@property(nonatomic) NSString* interfaceAuditSourceKey;
@property(nonatomic) BOOL interfaceAuditCombatFeedback;
@property(nonatomic) BOOL combatFeedbackProofEnabled;
@property(nonatomic) BOOL combatFeedbackProofCaptured;
@property(nonatomic) ProtectorCinematicFrame pendingCinematic;
@property(atomic, readwrite) ProtectorCinematicFrame cinematicFrame;
@property(nonatomic) BOOL hudRejectionCaptured;
@property(nonatomic) NSUInteger hudRejectedFrames;
@property(nonatomic) NSUInteger hudLostEvents;
@property(nonatomic) NSUInteger hudCarriedFrames;
@property(nonatomic) u32 hudLastRejectedFrame;
@property(nonatomic) NSString* cinematicAuditMovie;
@property(nonatomic) NSUInteger cinematicAuditFrame;
@property(nonatomic) BOOL cinematicAuditCaptured;
@property(nonatomic) BOOL cinematicAuditWasActive;
@property(nonatomic) BOOL cinematicAuditFinished;
@property(nonatomic) NSUInteger cinematicAuditRows;
@property(nonatomic) NSFileHandle* cinematicAuditLog;
@property(nonatomic) BOOL interfaceAuditCaptured;
@property(nonatomic) BOOL sceneEdgeAuditEnabled;
@property(nonatomic) BOOL sceneEdgeRedraw;
@property(nonatomic) NSArray<NSString*>* materialAuditKeys;
@property(nonatomic) NSMutableSet<NSString*>* materialAuditCaptured;
@property(nonatomic) NSString* materialAuditReadyPath;
@property(nonatomic) BOOL materialAuditReady;
@property(nonatomic) BOOL materialAuditIsolate;
@property(nonatomic) NSString* materialAuditSourceOnlyKey;
@property(nonatomic) BOOL materialAuditNoWriteProof;
@property(nonatomic) BOOL disableNoWriteCulling; // frozen diagnostic reference only
@property(nonatomic) NSFileHandle* motionAuditLog;
@property(nonatomic) NSDictionary* motionAuditState;
@property(nonatomic) NSDictionary* motionCopyMismatch;
@property(nonatomic) NSUInteger motionAuditFrames;
@property(nonatomic) NSUInteger motionProofMinimumFrame;
@property(nonatomic) BOOL motionProofRequireUnusedColor;
@property(nonatomic) BOOL motionProofRequireShadow;
@property(nonatomic) BOOL motionProofCaptured;
@property(nonatomic) BOOL motionProofRedraw;
@property(nonatomic) NSDictionary<NSNumber*, id<MTLTexture>>* motionProofShadowTextures;
@property(nonatomic) NSArray* motionProofCopyConsumers;
@property(nonatomic) void* motionHistory;
@property(nonatomic) BOOL smoothMotionActive;
@property(nonatomic) BOOL presentationPaused;
@property(nonatomic) BOOL motionSettingRedraw;
@property(nonatomic) NSFileHandle* motionPresentationLog;
@property(nonatomic) BOOL lightweightPerformanceCapture;
@property(nonatomic) NSString* performanceCaptureFilename;
@property(nonatomic) ProtectorPerformanceRing* performanceRing;
@property(nonatomic) NSUInteger performanceRingWriteFailures;
@property(nonatomic) BOOL presentationTransitionAuditEnabled;
@property(atomic) BOOL manualAuditRequested;
@property(nonatomic) NSMutableArray<ProtectorPassTiming*>* passTimings;
@property(nonatomic) NSUInteger passTimingCursor;
@property(nonatomic) BOOL passTimingUnavailable;
@property(nonatomic) MTLTimestamp passTimingCPUBase;
@property(nonatomic) MTLTimestamp passTimingGPUBase;
@property(atomic) ProtectorPassTiming* latestPassTiming;
@property(nonatomic) BOOL shadowBorderEnabled;
@property(atomic) NSUInteger shadowBorderSamples;
@property(nonatomic) BOOL presentationTransitionPrimed;
@property(nonatomic) ProtectorPerformanceRing* presentationTransitionLog;
@property(nonatomic) NSString* presentationTransitionLogName;
@property(nonatomic) NSString* presentationTransitionSession;
@property(nonatomic) dispatch_queue_t presentationTransitionQueue;
@property(nonatomic) NSUInteger presentationTransitionEvents;
@property(nonatomic) NSUInteger presentationTransitionAudits;
@property(nonatomic) NSUInteger presentationTransitionAuditsSuppressed;
@property(nonatomic) NSUInteger presentationTransitionWriteFailures;
@property(nonatomic) NSDictionary* lastPresentationTransition;
@property(nonatomic) double guestLockWaitMax;
@property(nonatomic) double guestLockHeldMax;
@property(nonatomic) double displayLockWaitMax;
@property(atomic) double publishedPresentationAspect;
@property(nonatomic) ProtectorResourcePool* resourcePool;
@property(nonatomic) BOOL shadowWindowRedirectEnabled;
@property(nonatomic) uint64_t shadowWindowsElided;
@property(nonatomic) ProtectorFrameResources* latestFrameResources;
@property(atomic, readwrite) double smoothedGPUSeconds;
- (MotionStageInputs)motionStageInputs;
- (void)stageMotionDraws:(std::vector<LiveDraw>&)draws copies:(std::vector<LiveEfbCopy>&)copies
                   frame:(u32)index guestTicks:(u64)ticks deadline:(double)deadline
                    plan:(MotionStagePlan*)precomputed;
- (void)publishStateCapture:(NSDictionary*)state;
- (void)notePresentationTransition:(const PresentationTransitionState&)current frame:(u32)frameIndex
                                hud:(const NativeHudAdmission&)hud wide:(NSDictionary*)wide
                              draws:(const std::vector<LiveDraw>&)draws copies:(const std::vector<LiveEfbCopy>&)copies
                          antialias:(const char*)antialias hostSeconds:(double)now;
@property(nonatomic) NSDictionary* lastRenderCost;
@property(nonatomic) id<MTLCommandBuffer> latestRenderCommand;
@property(nonatomic) BOOL asynchronousPresentationRender;
@property(nonatomic) BOOL deferPresentationCommit;
@property(nonatomic) id<MTLCommandBuffer> pendingPresentationCommand;
@property(nonatomic) CFTimeInterval presentationMinimumDuration;
@property(nonatomic) BOOL synchronizeNextLiveRender;
@property(nonatomic) uint64_t motionPresentationCount;
@property(nonatomic) NSUInteger motionPresentationMinimumFrame;
@property(nonatomic) BOOL motionLoggedPause;
@property(nonatomic) double pendingHostDeadline;
@property(atomic, readwrite) BOOL complete;
@property(atomic, readwrite, nullable) NSError* failure;
@property(atomic, readwrite)
    NSDictionary<NSString*, id>* stateCapture;
@end

@implementation ProtectorLiveMetalRenderer {
    PresentationTransitionState _previousTransitionState;
    double _lastTransitionAudit[3];
    uint64_t _motionStateGeneration;
    std::atomic<unsigned> _consecutiveGPUFailures;
    NativeHudMemory _hudMemory;
    uint64_t _hudSignature;
    NativeHudAdmission _hudCached;
    bool _hudPreviouslyAdmitted;
    std::mutex _decoderMutex;
    DecoderStatsSnapshot _decoderStats;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                         outputDirectory:(NSURL*)outputDirectory
                            targetFrames:(NSArray<NSNumber*>*)targetFrames
                                   error:(NSError**)error {
    return [self initWithDevice:device outputDirectory:outputDirectory
                  targetFrames:targetFrames continuous:NO error:error];
}

- (nullable instancetype)initContinuousWithDevice:(id<MTLDevice>)device
                                  outputDirectory:(NSURL*)outputDirectory
                                            error:(NSError**)error {
    return [self initContinuousWithDevice:device outputDirectory:outputDirectory
        texturePackManifest:nil error:error];
}

- (nullable instancetype)initContinuousWithDevice:(id<MTLDevice>)device
                                  outputDirectory:(NSURL*)outputDirectory
                              texturePackManifest:(nullable NSURL*)manifest
                                            error:(NSError**)error {
    return [self initContinuousWithDevice:device outputDirectory:outputDirectory
        texturePackManifest:manifest presentationUpgrades:manifest != nil error:error];
}

- (nullable instancetype)initContinuousWithDevice:(id<MTLDevice>)device
                                  outputDirectory:(NSURL*)outputDirectory
                              texturePackManifest:(nullable NSURL*)manifest
                             presentationUpgrades:(BOOL)enabled
                                            error:(NSError**)error {
    if (manifest && !enabled) {
        if (error) *error = LiveError(26, @"Restored artwork requires the upgraded presentation lane.");
        return nil;
    }
    self = [self initWithDevice:device outputDirectory:outputDirectory
        targetFrames:@[] continuous:YES error:error];
    if (self && _materialAuditIsolate && !manifest) {
        if (error) *error = LiveError(37, @"Material isolation requires a texture pack.");
        return nil;
    }
    if (self && manifest) {
        _texturePack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:error];
        if (!_texturePack) return nil;
        _restoredArtworkEnabled = YES;
    }
    if (self && enabled) {
        _artworkPreviewFrame = new ArtworkPreviewFrame();
        _presentationTransitionAuditEnabled = getenv("PROTECTOR_HUD_TRANSITION_AUDIT") &&
            !strcmp(getenv("PROTECTOR_HUD_TRANSITION_AUDIT"), "1");
        _lightweightPerformanceCapture=getenv("PROTECTOR_PERFORMANCE_CAPTURE") &&
            !strcmp(getenv("PROTECTOR_PERFORMANCE_CAPTURE"),"1");
        if (_lightweightPerformanceCapture ||
            (getenv("PROTECTOR_MOTION_PRESENTATION") && strcmp(getenv("PROTECTOR_MOTION_PRESENTATION"), "1") == 0)) {
            if (getenv("PROTECTOR_MOTION_PROOF_MIN_FRAME")) {
                if (error) *error = LiveError(36, @"Use separate spatial-proof and live-motion sessions.");
                return nil;
            }
            const char* minimum = getenv("PROTECTOR_MOTION_PRESENTATION_MIN_FRAME");
            if (minimum) {
                char* end = nullptr;
                const unsigned long long value = strtoull(minimum, &end, 10);
                if (!*minimum || *end || value > 100000) {
                    if (error) *error = LiveError(36, @"Motion logging frame must be between 0 and 100000.");
                    return nil;
                }
                _motionPresentationMinimumFrame = (NSUInteger)value;
            }
            if (_lightweightPerformanceCapture) {
                // All presentations, newest retained: menus, cinematics and
                // HUD fallbacks are recorded with a gameplay flag, not filtered.
                NSUInteger segment = 4096;
                if (const char* override = getenv("PROTECTOR_PERFORMANCE_RING_RECORDS")) {
                    char* end = nullptr;
                    const unsigned long long value = strtoull(override, &end, 10);
                    if (!*override || *end || value < 64 || value > 65536) {
                        if (error) *error = LiveError(36, @"Performance ring segment must be between 64 and 65536 records.");
                        return nil;
                    }
                    segment = (NSUInteger)value;
                }
                _performanceRing = [[ProtectorPerformanceRing alloc] initWithDirectory:outputDirectory
                    stem:[NSString stringWithFormat:@"performance-presentation-%@", NSUUID.UUID.UUIDString]
                    recordsPerSegment:segment error:error];
                if (!_performanceRing) return nil;
                _performanceCaptureFilename = _performanceRing.filenames.firstObject;
                // Gates the existing timing paths; ring segments own all writes.
                _motionPresentationLog = NSFileHandle.fileHandleWithNullDevice;
            } else {
                NSURL* log = [outputDirectory URLByAppendingPathComponent:@"motion-presentation.jsonl"];
                if (![[NSData data] writeToURL:log options:NSDataWritingWithoutOverwriting error:error]) return nil;
                _motionPresentationLog = [NSFileHandle fileHandleForWritingToURL:log error:error];
                if (!_motionPresentationLog) return nil;
            }
            _motionHistory = new MotionPresentationHistory();
            _smoothMotionActive = YES;
            static_cast<DecoderState*>(_decoderState)->motionAuditEnabled = true;
        }
        if (getenv("PROTECTOR_MOTION_AUDIT") && strcmp(getenv("PROTECTOR_MOTION_AUDIT"), "1") == 0) {
            NSURL* log = [outputDirectory URLByAppendingPathComponent:@"motion-audit.jsonl"];
            if (![[NSData data] writeToURL:log options:NSDataWritingWithoutOverwriting error:error]) return nil;
            _motionAuditLog = [NSFileHandle fileHandleForWritingToURL:log error:error];
            if (!_motionAuditLog) return nil;
            static_cast<DecoderState*>(_decoderState)->motionAuditEnabled = true;
            const char* minimum = getenv("PROTECTOR_MOTION_PROOF_MIN_FRAME");
            if (minimum) {
                char* end = nullptr;
                const unsigned long long value = strtoull(minimum, &end, 10);
                if (!*minimum || *end || value < 2 || value > 100000) {
                    if (error) *error = LiveError(35, @"Motion proof frame must be between 2 and 100000.");
                    return nil;
                }
                _motionProofMinimumFrame = (NSUInteger)value;
                const char* unused = getenv("PROTECTOR_MOTION_PROOF_REQUIRE_UNUSED_COLOR");
                _motionProofRequireUnusedColor = unused && strcmp(unused, "1") == 0;
                const char* shadow = getenv("PROTECTOR_MOTION_PROOF_REQUIRE_SHADOW");
                _motionProofRequireShadow = shadow && strcmp(shadow, "1") == 0;
            }
        }
    }
    return self;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                         outputDirectory:(NSURL*)outputDirectory
                            targetFrames:(NSArray<NSNumber*>*)targetFrames
                              continuous:(BOOL)continuous
                                   error:(NSError**)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    if (!continuous && targetFrames.count == 0u) {
        if (error) {
            *error = LiveError(1, @"live GX target frame list is empty");
        }
        return nil;
    }
    NSMutableIndexSet* indexes = [NSMutableIndexSet indexSet];
    for (NSNumber* frame in targetFrames) {
        [indexes addIndex:frame.unsignedIntegerValue];
    }
    if (indexes.count != targetFrames.count) {
        if (error) {
            *error = LiveError(2, @"live GX target frames must be unique");
        }
        return nil;
    }
    _device = device;
    _renderScale = 1u;
    _renderScaleY = 1u;
    _projectionDiagnosticsEnabled = getenv("PROTECTOR_PROJECTION_AUDIT") &&
        strcmp(getenv("PROTECTOR_PROJECTION_AUDIT"), "1") == 0;
    const char* cinematicMovie = getenv("PROTECTOR_CINEMATIC_AUDIT_MOVIE");
    if (cinematicMovie) {
        NSString* name = [NSString stringWithUTF8String:cinematicMovie];
        NSString* stem = name.stringByDeletingPathExtension;
        if (!name || name.length > 95 || !stem.length || ![name.pathExtension isEqual:@"bik"] ||
            [stem rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet]].location != NSNotFound) {
            if (error) *error = LiveError(38,@"Cinematic audit requires one source movie basename.");
            return nil;
        }
        _cinematicAuditMovie = name;
        const char* minimum = getenv("PROTECTOR_CINEMATIC_AUDIT_FRAME");
        if (minimum) {
            char* end = nullptr;
            const unsigned long value = strtoul(minimum,&end,10);
            if (!*minimum || *end || value > 1000000) {
                if (error) *error = LiveError(38,@"Cinematic audit frame is out of bounds.");
                return nil;
            }
            _cinematicAuditFrame = value;
        }
        NSURL* log = [outputDirectory URLByAppendingPathComponent:@"cinematic-presentation.jsonl"];
        if (![NSFileManager.defaultManager createDirectoryAtURL:outputDirectory withIntermediateDirectories:YES
            attributes:nil error:error]) return nil;
        if (![[NSData data] writeToURL:log options:NSDataWritingWithoutOverwriting error:error]) return nil;
        _cinematicAuditLog = [NSFileHandle fileHandleForWritingToURL:log error:error];
        if (!_cinematicAuditLog) return nil;
    }
    const char* interfaceFrame = getenv("PROTECTOR_INTERFACE_AUDIT_FRAME");
    const char* interfaceSource = getenv("PROTECTOR_INTERFACE_AUDIT_SOURCE_KEY");
    const char* combatFeedback = getenv("PROTECTOR_INTERFACE_AUDIT_COMBAT_FEEDBACK");
    if (combatFeedback && (strcmp(combatFeedback,"1") || !interfaceFrame)) {
        if (error) *error = LiveError(37,@"Combat feedback inspection requires interface audit and value 1.");
        return nil;
    }
    _interfaceAuditCombatFeedback = combatFeedback != nullptr;
    const char* combatProof = getenv("PROTECTOR_COMBAT_FEEDBACK_PROOF");
    if (combatProof && strcmp(combatProof,"1")) {
        if (error) *error = LiveError(37,@"Combat feedback proof requires value 1.");
        return nil;
    }
    _combatFeedbackProofEnabled = combatProof != nullptr;
    if (interfaceSource) {
        NSString* key = [NSString stringWithUTF8String:interfaceSource];
        if (!interfaceFrame || !InterfaceAuditSourceKeyValid(key)) {
            if (error) *error = LiveError(37,@"Interface source trigger requires a bounded exact texture key and interface audit.");
            return nil;
        }
        _interfaceAuditSourceKey = key;
    }
    const char* sceneEdges = getenv("PROTECTOR_SCENE_EDGE_AUDIT");
    if (sceneEdges && (strcmp(sceneEdges, "1") || !interfaceFrame)) {
        if (error) *error = LiveError(37, @"Scene edge inspection requires interface audit and value 1.");
        return nil;
    }
    _sceneEdgeAuditEnabled = sceneEdges != nullptr;
    const char* materialKeys = getenv("PROTECTOR_MATERIAL_AUDIT_KEYS");
    if (materialKeys) {
        NSString* text = [NSString stringWithUTF8String:materialKeys];
        NSArray<NSString*>* keys = [text componentsSeparatedByString:@","];
        BOOL validKeys = YES;
        for (NSString* key in keys) if (!InterfaceAuditSourceKeyValid(key)) validKeys = NO;
        if (!continuous || !text || text.length > 599 || !keys.count || keys.count > 8 ||
            [NSSet setWithArray:keys].count != keys.count || !validKeys) {
            if (error) *error = LiveError(37, @"Material inspection requires one to eight unique exact source keys and continuous presentation.");
            return nil;
        }
        _materialAuditKeys = keys;
        _materialAuditCaptured = [NSMutableSet set];
    }
    const char* materialReady = getenv("PROTECTOR_MATERIAL_AUDIT_READY_PATH");
    if (materialReady) {
        NSString* path = [NSString stringWithUTF8String:materialReady];
        if (!_materialAuditKeys.count || !path.isAbsolutePath || path.length > 1024 ||
            [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
            if (error) *error = LiveError(37, @"Material readiness requires configured source keys and a bounded absolute marker path.");
            return nil;
        }
        _materialAuditReadyPath = path;
    }
    const char* materialIsolate = getenv("PROTECTOR_MATERIAL_AUDIT_ISOLATE");
    if (materialIsolate && (strcmp(materialIsolate, "1") || !_materialAuditKeys.count)) {
        if (error) *error = LiveError(37, @"Material isolation requires configured source keys and value 1.");
        return nil;
    }
    _materialAuditIsolate = materialIsolate != nullptr;
    const char* noWriteProof = getenv("PROTECTOR_MATERIAL_NO_WRITE_PROOF");
    if (noWriteProof && (strcmp(noWriteProof, "1") || !_materialAuditKeys.count)) {
        if (error) *error = LiveError(37, @"No-write proof requires configured material source keys and value 1.");
        return nil;
    }
    _materialAuditNoWriteProof = noWriteProof != nullptr;
    if (interfaceFrame) {
        char* end = nullptr;
        const unsigned long long value = strtoull(interfaceFrame, &end, 10);
        if (!continuous || !*interfaceFrame || *end || value < 1 || value > 100000 ||
            getenv("PROTECTOR_MOTION_PRESENTATION") || getenv("PROTECTOR_MOTION_PROOF_MIN_FRAME")) {
            if (error) *error = LiveError(37, @"Interface audit requires a continuous source frame between 1 and 100000.");
            return nil;
        }
        _interfaceAuditMinimumFrame = (NSUInteger)value;
    }
    _continuousPresentation = continuous;
    // Render and presentation use one ordered queue. Bound outstanding work
    // instead of allowing asynchronous high-resolution frames to accumulate.
    _commandQueue = [device newCommandQueueWithMaxCommandBufferCount:3];
    _synchronizeNextLiveRender = YES;
    _outputDirectory = outputDirectory;
    _targetFrames = [indexes copy];
    _targetFrameValues = [targetFrames copy];
    _submissions = [NSMutableArray array];
    _textureCache = [NSMutableDictionary dictionary];
    _samplerCache = [NSMutableDictionary dictionary];
    _depthCache = [NSMutableDictionary dictionary];
    _textureCacheEnabled = getenv("PROTECTOR_DISABLE_TEXTURE_CACHE") == NULL;
    _decoderState = new DecoderState();
    static_cast<DecoderState*>(_decoderState)->sceneSourceAuditEnabled = _sceneEdgeAuditEnabled;
    static_cast<DecoderState*>(_decoderState)->decodedTextures.enabled =
        _textureCacheEnabled && getenv("PROTECTOR_DISABLE_DECODED_TEXTURE_CACHE") == NULL;
    static_cast<DecoderState*>(_decoderState)->indexedVertices =
        getenv("PROTECTOR_DISABLE_INDEXED_VERTICES") == NULL;
    if (!_commandQueue || !_decoderState) {
        if (error) {
            *error = LiveError(3, @"live GX Metal state allocation failed");
        }
        return nil;
    }
    NSError* directoryError = nil;
    if (![
        NSFileManager.defaultManager
        createDirectoryAtURL:outputDirectory
        withIntermediateDirectories:YES
        attributes:nil
        error:&directoryError
    ]) {
        if (error) {
            *error = directoryError;
        }
        return nil;
    }

    id<MTLLibrary> library = [
        device newLibraryWithSource:[[ProtectorLiveShaderSource
            stringByAppendingString:@(ProtectorCinematicSurroundShader)]
            stringByAppendingString:@(ProtectorSceneAntialiasShader)]
        options:nil
        error:error
    ];
    if (!library) {
        return nil;
    }
    MTLRenderPipelineDescriptor* pipelineDescriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.vertexFunction =
        [library newFunctionWithName:@"live_gx_vertex"];
    pipelineDescriptor.fragmentFunction =
        [library newFunctionWithName:@"live_gx_fragment" constantValues:[MTLFunctionConstantValues new] error:error];
    if (!pipelineDescriptor.fragmentFunction) return nil;
    pipelineDescriptor.colorAttachments[0].pixelFormat =
        MTLPixelFormatBGRA8Unorm;
    MTLRenderPipelineColorAttachmentDescriptor* color =
        pipelineDescriptor.colorAttachments[0];
    pipelineDescriptor.depthAttachmentPixelFormat =
        MTLPixelFormatDepth32Float;
    NSMutableArray<MTLRenderPipelineDescriptor*>* blendDescriptors = [NSMutableArray array];
    color.blendingEnabled = NO;
    [blendDescriptors addObject:[pipelineDescriptor copy]];
    _opaquePipeline = [
        device newRenderPipelineStateWithDescriptor:pipelineDescriptor
        error:error
    ];
    if (!_opaquePipeline) {
        return nil;
    }
    color.blendingEnabled = YES;
    color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    color.destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    color.sourceAlphaBlendFactor = MTLBlendFactorOne;
    color.destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    [blendDescriptors addObject:[pipelineDescriptor copy]];
    _alphaPipeline = [
        device newRenderPipelineStateWithDescriptor:pipelineDescriptor
        error:error
    ];
    if (!_alphaPipeline) {
        return nil;
    }
    color.destinationRGBBlendFactor = MTLBlendFactorOne;
    color.destinationAlphaBlendFactor = MTLBlendFactorOne;
    [blendDescriptors addObject:[pipelineDescriptor copy]];
    _additivePipeline = [
        device newRenderPipelineStateWithDescriptor:pipelineDescriptor
        error:error
    ];
    if (!_additivePipeline) {
        return nil;
    }
    color.sourceRGBBlendFactor = MTLBlendFactorOne;
    [blendDescriptors addObject:[pipelineDescriptor copy]];
    _oneOnePipeline = [
        device newRenderPipelineStateWithDescriptor:pipelineDescriptor
        error:error
    ];
    if (!_oneOnePipeline) {
        return nil;
    }
    // GX subtract mode ignores the encoded factors and computes destination
    // minus source. Zero source alpha must not suppress its RGB contribution.
    color.rgbBlendOperation = MTLBlendOperationReverseSubtract;
    color.alphaBlendOperation = MTLBlendOperationReverseSubtract;
    [blendDescriptors addObject:[pipelineDescriptor copy]];
    _subtractPipeline = [device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:error];
    if (!_subtractPipeline) return nil;
    _shaderSpecializationEnabled = ![NSProcessInfo.processInfo.environment[@"PROTECTOR_SHADER_SPECIALIZATION"] isEqual:@"0"];
    NSMutableDictionary* directPipelines = [NSMutableDictionary dictionary];
    for (uint32_t stages : {1u, 2u}) {
        MTLFunctionConstantValues* constants = [MTLFunctionConstantValues new];
        [constants setConstantValue:&stages type:MTLDataTypeUInt atIndex:0];
        id<MTLFunction> function = [library newFunctionWithName:@"live_gx_fragment" constantValues:constants error:error];
        if (!function) return nil;
        NSMutableArray* variants = [NSMutableArray array];
        for (MTLRenderPipelineDescriptor* blend in blendDescriptors) {
            MTLRenderPipelineDescriptor* specialized = [blend copy];
            specialized.fragmentFunction = function;
            id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:specialized error:error];
            if (!pipeline) return nil;
            [variants addObject:pipeline];
        }
        directPipelines[@(stages)] = variants;
    }
    _directPipelines = directPipelines;
    MTLRenderPipelineDescriptor* presentDescriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    presentDescriptor.vertexFunction =
        [library newFunctionWithName:@"live_present_vertex"];
    presentDescriptor.fragmentFunction =
        [library newFunctionWithName:@"live_present_fragment"];
    presentDescriptor.colorAttachments[0].pixelFormat =
        MTLPixelFormatBGRA8Unorm;
    _presentPipeline = [
        device newRenderPipelineStateWithDescriptor:presentDescriptor
        error:error
    ];
    if (!_presentPipeline) {
        return nil;
    }
    presentDescriptor.fragmentFunction = [library newFunctionWithName:@"live_scene_antialias_fragment"];
    presentDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    _sceneAntialiasPipeline = [device newRenderPipelineStateWithDescriptor:presentDescriptor error:error];
    if (!_sceneAntialiasPipeline) return nil;
    _sceneAntialiasEnabled = ![NSProcessInfo.processInfo.environment[@"PROTECTOR_SCENE_AA"] isEqual:@"0"];
    _renderTargetOptimizationsEnabled = ![NSProcessInfo.processInfo.environment[@"PROTECTOR_RENDER_TARGET_OPTIMIZATIONS"] isEqual:@"0"];
    _shadowWindowRedirectEnabled = ![NSProcessInfo.processInfo.environment[@"PROTECTOR_SHADOW_WINDOW_REDIRECT"] isEqual:@"0"];
    _shadowBorderEnabled = ![NSProcessInfo.processInfo.environment[@"PROTECTOR_SHADOW_WINDOW_BORDER"] isEqual:@"0"];
    MTLRenderPipelineDescriptor* movieDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    movieDescriptor.vertexFunction = [library newFunctionWithName:@"live_gx_vertex"];
    movieDescriptor.fragmentFunction = [library newFunctionWithName:@"live_cinematic_fragment"];
    movieDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    movieDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    _cinematicPipeline = [device newRenderPipelineStateWithDescriptor:movieDescriptor error:error];
    MTLDepthStencilDescriptor* movieDepth = [[MTLDepthStencilDescriptor alloc] init];
    movieDepth.depthCompareFunction = MTLCompareFunctionLessEqual;
    movieDepth.depthWriteEnabled = YES;
    _cinematicDepthState = [device newDepthStencilStateWithDescriptor:movieDepth];
    if (!_cinematicPipeline || !_cinematicDepthState) return nil;
    MTLRenderPipelineDescriptor* surroundDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    surroundDescriptor.vertexFunction = [library newFunctionWithName:@"live_present_vertex"];
    surroundDescriptor.fragmentFunction = [library newFunctionWithName:@"live_cinematic_surround_fragment"];
    surroundDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    surroundDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    _cinematicSurroundPipeline = [device newRenderPipelineStateWithDescriptor:surroundDescriptor error:error];
    MTLDepthStencilDescriptor* surroundDepth = [[MTLDepthStencilDescriptor alloc] init];
    surroundDepth.depthCompareFunction = MTLCompareFunctionAlways;
    surroundDepth.depthWriteEnabled = NO;
    _cinematicSurroundDepthState = [device newDepthStencilStateWithDescriptor:surroundDepth];
    if (!_cinematicSurroundPipeline || !_cinematicSurroundDepthState) return nil;
    MTLSamplerDescriptor* samplerDescriptor =
        [[MTLSamplerDescriptor alloc] init];
    samplerDescriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    samplerDescriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
    _sampler = [device newSamplerStateWithDescriptor:samplerDescriptor];
    if (!_sampler) {
        if (error) {
            *error = LiveError(4, @"live GX sampler creation failed");
        }
        return nil;
    }
    _stateCapture = @{
        @"schema" : @"protector-native.live-metal/v1",
        @"source" : @"translated_execution_callback",
        @"external_scene_pack" : @NO,
        @"device" : device.name,
        @"target_frames" : targetFrames,
        @"submissions" : @[],
        @"complete" : @NO,
    };
    return self;
}

- (void)dealloc {
    [self.motionAuditLog closeAndReturnError:nil];
    [self.motionPresentationLog closeAndReturnError:nil];
    [self.performanceRing close];
    [self.presentationTransitionLog close];
    delete static_cast<DecoderState*>(self.decoderState);
    delete static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
    delete static_cast<MotionPresentationHistory*>(self.motionHistory);
}

- (void)resetMotionHistory {
    @synchronized(self) {
        auto* history = static_cast<MotionPresentationHistory*>(self.motionHistory);
        if (!history) return;
        history->previous = ArtworkPreviewFrame();
        history->matches.clear();
        history->ready = false;
        history->copyFencesShifted = false;
        history->rendered = false;
        history->matchedDraws = 0;
        history->matchedModelDraws = 0;
        history->matchedShadowDraws = 0;
        history->matchedShadowModelDraws = 0;
        history->matchedUnusedColorDraws = 0;
        history->holdReason = "history-reset";
        ++_motionStateGeneration;
        self.motionCopyMismatch = nil;
        history->interval = 0;
        auto* current = static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if (current) current->hostDeadline = 0;
    }
}

- (BOOL)smoothMotionAvailable {
    @synchronized(self) { return self.artworkPreviewFrame && !self.motionProofMinimumFrame; }
}
- (BOOL)smoothMotionEnabled {
    @synchronized(self) { return self.smoothMotionActive; }
}
- (BOOL)motionPresentationPrototypeEnabled { return self.smoothMotionEnabled; }

- (BOOL)selectSmoothMotion:(BOOL)enabled error:(NSError**)error {
    @synchronized(self) {
        if (enabled && !self.smoothMotionAvailable) {
            if (error) *error = LiveError(26, @"Smooth motion requires Enhanced and is unavailable during a spatial proof.");
            return NO;
        }
        if (enabled == self.smoothMotionActive) return YES;
        if (enabled && !self.motionHistory) self.motionHistory = new MotionPresentationHistory();
        auto* history = static_cast<MotionPresentationHistory*>(self.motionHistory);
        if (history) history->paused = self.presentationPaused;
        ++_motionStateGeneration;
        [self resetMotionHistory];
        self.smoothMotionActive = enabled;
        // Disabling while a generated pose is visible must return immediately
        // to the immutable current endpoint, even when the guest is paused.
        auto* current = static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if (!enabled && current && current->valid) {
            self.motionSettingRedraw = YES;
            const BOOL rendered = [self renderDraws:current->draws efbCopies:current->copies
                frame:current->index error:error];
            self.motionSettingRedraw = NO;
            if (!rendered) { self.smoothMotionActive = YES; return NO; }
        }
        {
            std::lock_guard<std::mutex> guard(_decoderMutex);
            static_cast<DecoderState*>(self.decoderState)->motionAuditEnabled = enabled || self.motionAuditLog != nil;
        }
        self.motionAuditState = nil;
        if (self.stateCapture) {
            NSMutableDictionary* state = [self.stateCapture mutableCopy];
            state[@"smooth_motion_enabled"] = @(enabled);
            [state removeObjectForKey:@"motion_presentation"];
            state[@"motion_correspondence_audit"] = NSNull.null;
            [self publishStateCapture:state];
        }
        return YES;
    }
}

- (void)setPresentationPaused:(BOOL)paused {
    @synchronized(self) {
        if (_presentationPaused && !paused) self.synchronizeNextLiveRender = YES;
        _presentationPaused = paused;
        auto* history = static_cast<MotionPresentationHistory*>(self.motionHistory);
        if (!history || history->paused == (bool)paused) return;
        history->paused = paused;
        ++_motionStateGeneration;
        [self resetMotionHistory];
    }
}

- (BOOL)selectRestoredArtwork:(BOOL)enabled error:(NSError**)error {
    @synchronized(self) {
        if (!self.texturePack) {
            if (enabled && error) *error = LiveError(25, @"Load an upgraded artwork pack before selecting restored artwork.");
            return !enabled;
        }
        const BOOL previous = self.restoredArtworkEnabled;
        self.restoredArtworkEnabled = enabled;
        [self resetMotionHistory];
        auto* snapshot = static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if (!snapshot || !snapshot->valid) return YES;
        self.artworkPreviewRedraw = YES;
        ++self.artworkPreviewRedrawCount;
        const BOOL rendered = [self renderDraws:snapshot->draws efbCopies:snapshot->copies
            frame:snapshot->index error:error];
        self.artworkPreviewRedraw = NO;
        if (!rendered) self.restoredArtworkEnabled = previous;
        return rendered;
    }
}

- (BOOL)loadGeometryPack:(NSURL*)manifest error:(NSError**)error {
    @synchronized(self) {
        if (!self.artworkPreviewFrame || self.renderedFrameCount || self.geometryPack ||
            static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame)->valid) {
            if (error) *error = LiveError(28, @"Load model geometry once, before starting an Upgraded session.");
            return NO;
        }
        ProtectorGeometryPack* pack = [[ProtectorGeometryPack alloc] initWithManifest:manifest error:error];
        if (!pack) return NO;
        self.geometryPack = pack;
        {
            std::lock_guard<std::mutex> guard(_decoderMutex);
            static_cast<DecoderState*>(self.decoderState)->geometryPack = pack;
        }
        self.enhancedModelsEnabled = YES;
        return YES;
    }
}

- (void)prepareCinematicOpening:(ProtectorCinematicOpening)opening {
    @synchronized(self) {
        [self.cinematicPack prepareOpening:opening];
    }
}

- (ProtectorCinematicOpeningStatus)statusForCinematicOpening:(ProtectorCinematicOpening)opening {
    @synchronized(self) { return [self.cinematicPack statusForOpening:opening]; }
}

- (void)abandonCinematicOpening:(ProtectorCinematicOpening)opening {
    @synchronized(self) { [self.cinematicPack abandonOpening:opening]; }
}

- (BOOL)loadCinematicPack:(NSURL*)manifest sourceDirectory:(NSURL*)source error:(NSError**)error {
    @synchronized(self) {
        if (!self.artworkPreviewFrame || self.renderedFrameCount || self.cinematicPack ||
            static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame)->valid) {
            if (error) *error = LiveError(38,@"Load cinematic restoration once, before starting the Enhanced session.");
            return NO;
        }
        ProtectorCinematicPack* pack = [[ProtectorCinematicPack alloc] initWithManifest:manifest
            sourceDirectory:source device:self.device error:error];
        if (!pack) return NO;
        self.cinematicPack = pack;
        return YES;
    }
}

- (BOOL)selectEnhancedModels:(BOOL)enabled error:(NSError**)error {
    @synchronized(self) {
        if (enabled && !self.geometryPack) {
            if (error) *error = LiveError(28, @"Load a source-bound model pack before enabling enhanced geometry.");
            return NO;
        }
        const BOOL previous = self.enhancedModelsEnabled;
        if (enabled == previous) return YES;
        self.enhancedModelsEnabled = enabled;
        [self resetMotionHistory];
        auto* snapshot = static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if (!snapshot || !snapshot->valid) return YES;
        self.geometryPreviewRedraw = YES;
        ++self.geometryPreviewRedrawCount;
        const BOOL result = [self renderDraws:snapshot->draws efbCopies:snapshot->copies frame:snapshot->index error:error];
        self.geometryPreviewRedraw = NO;
        if (!result) {
            self.enhancedModelsEnabled = previous;
            --self.geometryPreviewRedrawCount;
        }
        return result;
    }
}

- (BOOL)selectRenderScale:(NSUInteger)scale error:(NSError**)error {
    @synchronized(self) {
        if (scale < 1u || scale > 6u || (!self.artworkPreviewFrame && scale != 1u)) {
            if (error) *error = LiveError(26,
                @"Render scale must be 1–6; higher resolutions require an Upgraded session.");
            return NO;
        }
        const NSUInteger previous = self.renderScale;
        const BOOL previousNative = self.nativeResolutionEnabled;
        if (scale == previous && !previousNative) return YES;
        self.nativeResolutionEnabled = NO;
        self.renderScale = scale;
        [self resetMotionHistory];
        auto* snapshot = static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if (!snapshot || !snapshot->valid) return YES;
        self.resolutionPreviewRedraw = YES;
        ++self.resolutionPreviewRedrawCount;
        const BOOL rendered = [self renderDraws:snapshot->draws efbCopies:snapshot->copies
            frame:snapshot->index error:error];
        self.resolutionPreviewRedraw = NO;
        if (!rendered) {
            self.renderScale = previous;
            self.nativeResolutionEnabled = previousNative;
            --self.resolutionPreviewRedrawCount;
        }
        return rendered;
    }
}

- (BOOL)selectNativeRenderSize:(CGSize)pixels error:(NSError**)error {
    @synchronized(self) {
        if (!self.artworkPreviewFrame ||
            !protector_native_render_scale(pixels.width, pixels.height, 640, 480)) {
            if (error) *error = LiveError(26,
                @"Native resolution is unavailable for this display. Choose a fixed render scale.");
            return NO;
        }
        if (self.nativeResolutionEnabled && CGSizeEqualToSize(pixels, self.nativeRenderPixelSize)) return YES;
        const BOOL previousNative = self.nativeResolutionEnabled;
        const CGSize previousPixels = self.nativeRenderPixelSize;
        const NSUInteger previousScale = self.renderScale;
        self.nativeResolutionEnabled = YES;
        self.nativeRenderPixelSize = pixels;
        [self resetMotionHistory];
        auto* snapshot = static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if (!snapshot->valid) return YES;
        self.resolutionPreviewRedraw = YES;
        ++self.resolutionPreviewRedrawCount;
        const BOOL rendered = [self renderDraws:snapshot->draws efbCopies:snapshot->copies
            frame:snapshot->index error:error];
        self.resolutionPreviewRedraw = NO;
        if (!rendered) {
            self.nativeResolutionEnabled = previousNative;
            self.nativeRenderPixelSize = previousPixels;
            self.renderScale = previousScale;
            --self.resolutionPreviewRedrawCount;
        }
        return rendered;
    }
}

- (BOOL)selectWidescreen:(BOOL)enabled error:(NSError**)error {
    @synchronized(self) {
        if (enabled && !self.artworkPreviewFrame) {
            if (error) *error = LiveError(27, @"Widescreen preview requires an Upgraded session.");
            return NO;
        }
        const BOOL previous = self.widescreenEnabled;
        if (enabled == previous) return YES;
        self.widescreenEnabled = enabled;
        [self resetMotionHistory];
        auto* snapshot = static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if (!snapshot || !snapshot->valid) return YES;
        self.aspectPreviewRedraw = YES;
        ++self.aspectPreviewRedrawCount;
        const BOOL rendered = [self renderDraws:snapshot->draws efbCopies:snapshot->copies
            frame:snapshot->index error:error];
        self.aspectPreviewRedraw = NO;
        if (!rendered) {
            self.widescreenEnabled = previous;
            --self.aspectPreviewRedrawCount;
        }
        return rendered;
    }
}

- (NSUInteger)trimCachesForMemoryPressure {
    NSUInteger released = 0;
    @synchronized(self) {
        released += [self.texturePack trimToFrameWorkingSet];
        released += self.textureCacheBytes;
        [self.textureCache removeAllObjects];
        self.textureCacheBytes = 0;
        [self.resourcePool drain];
    }
    {
        // Decoded guest textures are rebuilt from guest memory on next use.
        std::lock_guard<std::mutex> guard(_decoderMutex);
        auto& cache = static_cast<DecoderState*>(self.decoderState)->decodedTextures;
        released += cache.bytes;
        cache.entries.clear();
        cache.bytes = 0;
    }
    return released;
}

- (void)publishStateCapture:(NSDictionary*)state {
    self.stateCapture = state;
    // UIKit reads this every display tick. Publishing it atomically keeps the
    // display thread off the renderer lock while the guest decodes a frame.
    self.publishedPresentationAspect = [state[@"presentation_aspect_ratio"] doubleValue];
}

- (double)presentationAspect {
    const double published = self.publishedPresentationAspect;
    if (published > 0) return published;
    @synchronized(self) {
        const double completed = [self.stateCapture[@"presentation_aspect_ratio"] doubleValue];
        if (completed > 0) return completed;
        return !self.widescreenEnabled ? 4.0 / 3.0 : self.nativePresentationSize.height > 0
            ? self.nativePresentationSize.width / self.nativePresentationSize.height : 16.0 / 9.0;
    }
}

- (BOOL)configureNativePresentationSize:(CGSize)size hudFrame:(CGRect)hud error:(NSError**)error {
    @synchronized(self) {
        const double aspect = size.width / size.height;
        if (!self.artworkPreviewFrame || !std::isfinite(size.width) || !std::isfinite(size.height) ||
            size.width < 480 || size.height < 260 || !std::isfinite(aspect) ||
            aspect < 4.0 / 3.0 || aspect > PROTECTOR_MAX_PRESENTATION_ASPECT ||
            !std::isfinite(hud.origin.x) || !std::isfinite(hud.origin.y) ||
            !std::isfinite(hud.size.width) || !std::isfinite(hud.size.height) ||
            hud.origin.x < 0 || hud.origin.y < 0 || hud.size.width <= 0 || hud.size.height <= 0 ||
            CGRectGetMaxX(hud) > size.width || CGRectGetMaxY(hud) > size.height) {
            if (error) *error = LiveError(38, @"Native presentation requires valid Enhanced landscape bounds.");
            return NO;
        }
        if (CGSizeEqualToSize(size, self.nativePresentationSize) && CGRectEqualToRect(hud, self.nativeHudFrame)) return YES;
        const CGSize previousSize = self.nativePresentationSize;
        const CGRect previousHud = self.nativeHudFrame;
        self.nativePresentationSize = size;
        protector_visibility_set_presentation_aspect(aspect);
        self.nativeHudFrame = hud;
        [self resetMotionHistory];
        auto* snapshot = static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if (!self.widescreenEnabled || !snapshot->valid) return YES;
        self.nativeViewportRedraw = YES;
        ++self.nativeViewportRedrawCount;
        const BOOL rendered = [self renderDraws:snapshot->draws efbCopies:snapshot->copies frame:snapshot->index error:error];
        self.nativeViewportRedraw = NO;
        if (!rendered) {
            self.nativePresentationSize = previousSize;
            if(previousSize.height>0)
                protector_visibility_set_presentation_aspect(previousSize.width/previousSize.height);
            self.nativeHudFrame = previousHud;
            --self.nativeViewportRedrawCount;
        }
        return rendered;
    }
}

- (BOOL)configureNativeComboFrame:(CGRect)frame error:(NSError**)error {
    @synchronized(self) {
        if (!std::isfinite(frame.origin.x) || !std::isfinite(frame.origin.y) ||
            !std::isfinite(frame.size.width) || !std::isfinite(frame.size.height) ||
            frame.origin.x < 0 || frame.origin.y < 0 || frame.size.width <= 0 || frame.size.height <= 0 ||
            CGRectGetMaxX(frame)>self.nativePresentationSize.width+.01 ||
            CGRectGetMaxY(frame)>self.nativePresentationSize.height+.01 ||
            std::abs(frame.size.width/frame.size.height-4.0/3.0)>.0001) {
            if(error)*error=LiveError(38,@"Combo List requires a valid 4:3 content frame inside the native viewport.");
            return NO;
        }
        if(CGRectEqualToRect(frame,self.nativeComboFrame))return YES;
        const CGRect previous=self.nativeComboFrame;
        self.nativeComboFrame=frame;
        auto* snapshot=static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if(!snapshot || !snapshot->valid || !self.widescreenEnabled ||
            !IdentifyComboGlyphs(snapshot->draws,snapshot->copies).enabled)return YES;
        [self resetMotionHistory];
        self.nativeViewportRedraw=YES;++self.nativeViewportRedrawCount;
        const BOOL rendered=[self renderDraws:snapshot->draws efbCopies:snapshot->copies frame:snapshot->index error:error];
        self.nativeViewportRedraw=NO;
        if(!rendered){self.nativeComboFrame=previous;--self.nativeViewportRedrawCount;}
        return rendered;
    }
}

- (BOOL)configureNativeUpgradeFrame:(CGRect)frame error:(NSError**)error {
    @synchronized(self) {
        if (!std::isfinite(frame.origin.x) || !std::isfinite(frame.origin.y) ||
            !std::isfinite(frame.size.width) || !std::isfinite(frame.size.height) ||
            frame.origin.x<0 || frame.origin.y<0 || frame.size.width<=0 || frame.size.height<=0 ||
            CGRectGetMaxX(frame)>self.nativePresentationSize.width+.01 ||
            CGRectGetMaxY(frame)>self.nativePresentationSize.height+.01 ||
            std::abs(frame.size.width/frame.size.height-4.0/3.0)>.0001) {
            if(error)*error=LiveError(38,@"Upgrade Menu requires a valid 4:3 content frame inside the native viewport.");
            return NO;
        }
        if(CGRectEqualToRect(frame,self.nativeUpgradeFrame))return YES;
        const CGRect previous=self.nativeUpgradeFrame;self.nativeUpgradeFrame=frame;
        auto* snapshot=static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if(!snapshot || !snapshot->valid || !self.widescreenEnabled ||
            !IdentifyUpgradeGlyphs(snapshot->draws,snapshot->copies).enabled)return YES;
        [self resetMotionHistory];
        self.nativeViewportRedraw=YES;++self.nativeViewportRedrawCount;
        const BOOL rendered=[self renderDraws:snapshot->draws efbCopies:snapshot->copies frame:snapshot->index error:error];
        self.nativeViewportRedraw=NO;
        if(!rendered){self.nativeUpgradeFrame=previous;--self.nativeViewportRedrawCount;}
        return rendered;
    }
}

- (BOOL)configureNativeMapTitle:(CGRect)title cards:(CGRect)cards hints:(CGRect)hints error:(NSError**)error {
    @synchronized(self) {
        if(!MapValidRect(title,self.nativePresentationSize)||!MapValidRect(cards,self.nativePresentationSize)||
            !MapValidRect(hints,self.nativePresentationSize)||CGRectIntersectsRect(title,cards)||
            CGRectIntersectsRect(title,hints)||CGRectIntersectsRect(cards,hints)) {
            if(error)*error=LiveError(38,@"Map content needs separate title, card and help frames inside the native viewport.");
            return NO;
        }
        if(CGRectEqualToRect(title,self.nativeMapTitleFrame)&&CGRectEqualToRect(cards,self.nativeMapCardsFrame)&&
            CGRectEqualToRect(hints,self.nativeMapHintsFrame))return YES;
        const auto oldTitle=self.nativeMapTitleFrame,oldCards=self.nativeMapCardsFrame,oldHints=self.nativeMapHintsFrame;
        self.nativeMapTitleFrame=title;self.nativeMapCardsFrame=cards;self.nativeMapHintsFrame=hints;
        auto* snapshot=static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if(!snapshot||!snapshot->valid||!self.widescreenEnabled||
            !IdentifyMapLayout(snapshot->draws,snapshot->copies).enabled)return YES;
        [self resetMotionHistory];self.nativeViewportRedraw=YES;++self.nativeViewportRedrawCount;
        const BOOL rendered=[self renderDraws:snapshot->draws efbCopies:snapshot->copies frame:snapshot->index error:error];
        self.nativeViewportRedraw=NO;
        if(!rendered) {
            self.nativeMapTitleFrame=oldTitle;self.nativeMapCardsFrame=oldCards;self.nativeMapHintsFrame=oldHints;
            --self.nativeViewportRedrawCount;
        }
        return rendered;
    }
}

- (BOOL)configureNativeCombatFeedbackFrame:(CGRect)frame error:(NSError**)error {
    @synchronized(self) {
        const double sourceAspect=(double)PROTECTOR_COMBAT_FEEDBACK_WIDTH/PROTECTOR_COMBAT_FEEDBACK_HEIGHT*448/480;
        if (!std::isfinite(frame.origin.x) || !std::isfinite(frame.origin.y) ||
            !std::isfinite(frame.size.width) || !std::isfinite(frame.size.height) ||
            frame.origin.x<0 || frame.origin.y<0 || frame.size.width<=0 || frame.size.height<=0 ||
            CGRectGetMaxX(frame)>self.nativePresentationSize.width+.01 ||
            CGRectGetMaxY(frame)>self.nativePresentationSize.height+.01 ||
            std::abs(frame.size.width/frame.size.height-sourceAspect)>.0001) {
            if(error)*error=LiveError(38,@"Combat feedback requires a proportional frame inside the native viewport.");
            return NO;
        }
        if(CGRectEqualToRect(frame,self.nativeCombatFeedbackFrame))return YES;
        const CGRect previous=self.nativeCombatFeedbackFrame;
        self.nativeCombatFeedbackFrame=frame;
        auto* snapshot=static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if(!snapshot || !snapshot->valid || !self.widescreenEnabled ||
            !IdentifyCombatFeedback(snapshot->draws,snapshot->copies).enabled)return YES;
        [self resetMotionHistory];self.nativeViewportRedraw=YES;++self.nativeViewportRedrawCount;
        const BOOL rendered=[self renderDraws:snapshot->draws efbCopies:snapshot->copies frame:snapshot->index error:error];
        self.nativeViewportRedraw=NO;
        if(!rendered){self.nativeCombatFeedbackFrame=previous;--self.nativeViewportRedrawCount;}
        return rendered;
    }
}

- (id<MTLTexture>)textureForDraw:(const LiveDraw&)draw stage:(size_t)stage
                       restored:(BOOL*)restored error:(NSError**)error {
    return [self textureForDraw:draw stage:stage restored:restored mipTail:nullptr error:error];
}

- (id<MTLTexture>)textureForDraw:(const LiveDraw&)draw stage:(size_t)stage
                       restored:(BOOL*)restored mipTail:(id<MTLTexture> _Nullable* _Nullable)mipTail
                          error:(NSError**)error {
    if (mipTail) *mipTail = nil;
    *restored = NO;
    const auto& pixels = TexturePixels(draw, stage);
    const u32 width = draw.textureWidths[stage];
    const u32 height = draw.textureHeights[stage];
    NSNumber* key = @(((uint64_t)draw.textureAddresses[stage] << 32u) |
                     ((uint64_t)width << 16u) | height);
    ProtectorTextureCacheEntry* entry = self.textureCacheEnabled ? self.textureCache[key] : nil;
    // Address alone is not an identity: the guest rewrites texture memory and
    // palettes. Verify every decoded byte, including animated/movie textures.
    const auto& snapshot = draw.decodedPixels[stage];
    BOOL samePixels = NO;
    if (entry && snapshot && entry->snapshot.get() == snapshot.get()) samePixels = YES;
    else if (entry && entry.pixels.length == pixels.size() &&
             memcmp(entry.pixels.bytes, pixels.data(), pixels.size()) == 0) {
        samePixels = YES;
        if (snapshot) entry->snapshot = snapshot;
    }
    NSString* candidateKey = self.frameUsesRestoredArtwork ? (samePixels ? entry.candidateSourceKey :
        [self.texturePack sourceKeyForRGBA:pixels.data() length:pixels.size() width:width height:height]) : nil;
    NSString* companion = nil;
    NSArray<NSString*>* required = candidateKey ? [self.texturePack requiredCompanionsForSourceKey:candidateKey] : nil;
    // Only direct TEV stages in this very draw can satisfy the material guard.
    // Indirect samplers, an unused binding, or a preceding draw cannot qualify.
    if (required.count && stage < draw.fragment.stageCount && draw.fragment.stageCount <= 4) {
        for (size_t other = 0; other < draw.fragment.stageCount; ++other) {
            if (other == stage) continue;
            NSString* source = InterfaceTextureKeyForDraw(draw, other);
            if (source && [required containsObject:source]) { companion = source; break; }
        }
    }
    NSString* restoredKey = candidateKey && [self.texturePack sourceKey:candidateKey allowsCompanion:companion]
        ? candidateKey : nil;
    // Internal frozen-frame attribution only. Keep a paired material atomic
    // for this draw; a shared auxiliary's other consumers stay restored.
    // Retain candidateKey in the cache so source -> restored re-admission is
    // checked on the return frame, including when decoded bytes are unchanged.
    if (self.sceneEdgeRedraw && self.materialAuditIsolate && self.materialAuditSourceOnlyKey &&
        ([candidateKey isEqualToString:self.materialAuditSourceOnlyKey] ||
         [companion isEqualToString:self.materialAuditSourceOnlyKey])) restoredKey = nil;
    const BOOL sameAdmission = (!restoredKey && !entry.restoredSourceKey) ||
        [restoredKey isEqualToString:entry.restoredSourceKey];
    // A restored texture that is still loading must not stall presentation:
    // draw the original pixels this time and ask again next presentation.
    const auto originalTexture = [&]() -> id<MTLTexture> {
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> original = [self.device newTextureWithDescriptor:descriptor];
        [original replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0
            withBytes:pixels.data() bytesPerRow:width * 4u];
        return original;
    };
    const BOOL live = self.asynchronousPresentationRender;
    if (samePixels && sameAdmission) {
        self.textureCacheHits++;
        if (entry.restoredSourceKey) {
            BOOL deferred = NO;
            id<MTLTexture> texture = [self.texturePack textureForSourceKey:entry.restoredSourceKey
                companionSource:companion mipTail:mipTail deferred:live ? &deferred : nullptr error:error];
            if (texture) { *restored = YES; return texture; }
            return deferred ? originalTexture() : nil;
        }
        return entry.texture;
    }
    self.textureCacheMisses++;
    id<MTLTexture> texture = nil;
    if (restoredKey) {
        BOOL deferred = NO;
        texture = [self.texturePack textureForSourceKey:restoredKey companionSource:companion mipTail:mipTail
            deferred:live ? &deferred : nullptr error:error];
        if (texture) *restored = YES;
        else if (deferred) texture = originalTexture();   // entry keeps its restored intent
        else return nil;
    } else {
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:width height:height mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        texture = [self.device newTextureWithDescriptor:descriptor];
        [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0
            withBytes:pixels.data() bytesPerRow:width * 4u];
    }
    const NSUInteger limit = 32u * 1024u * 1024u;
    if (texture && self.textureCacheEnabled && pixels.size() <= limit) {
        if (entry) {
            self.textureCacheBytes -= entry.pixels.length;
            [self.textureCache removeObjectForKey:key];
        }
        if (self.textureCacheBytes + pixels.size() > limit || self.textureCache.count >= 512) {
            [self.textureCache removeAllObjects];
            self.textureCacheBytes = 0;
        }
        entry = [[ProtectorTextureCacheEntry alloc] init];
        entry.pixels = [NSData dataWithBytes:pixels.data() length:pixels.size()];
        entry->snapshot = draw.decodedPixels[stage];
        // Pack textures live only in their budgeted LRU, not this second cache.
        entry.texture = restoredKey ? nil : texture;
        entry.candidateSourceKey = candidateKey;
        entry.restoredSourceKey = restoredKey;
        self.textureCache[key] = entry;
        self.textureCacheBytes += pixels.size();
    }
    return texture;
}

- (void)notePresentationTransition:(const PresentationTransitionState&)current frame:(u32)frameIndex
                                hud:(const NativeHudAdmission&)hud wide:(NSDictionary*)wide
                              draws:(const std::vector<LiveDraw>&)draws copies:(const std::vector<LiveEfbCopy>&)copies
                          antialias:(const char*)antialias hostSeconds:(double)now {
    // Opt-in evidence for transient presentation changes. Never alters layout,
    // never fails gameplay; bounded log lines and six rotating audit slots.
    const unsigned flags = self.presentationTransitionPrimed
        ? ClassifyPresentationTransition(_previousTransitionState, current) : 0;
    _previousTransitionState = current;
    self.presentationTransitionPrimed = YES;
    const BOOL manual = self.manualAuditRequested;
    if (manual) self.manualAuditRequested = NO;
    if (!flags && !manual) return;
    if (!self.presentationTransitionSession) {
        self.presentationTransitionSession = NSUUID.UUID.UUIDString;
        self.presentationTransitionQueue = dispatch_queue_create("house.machine.protector.transition-audit",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    }
    const int lane = PresentationAuditLane(flags);
    BOOL audit = PresentationTransitionNeedsAudit(flags, current) && lane >= 0;
    if (audit && !PresentationAuditDue(now, _lastTransitionAudit[lane])) {
        audit = NO;
        ++self->_presentationTransitionAuditsSuppressed;
    }
    if (audit) _lastTransitionAudit[lane] = now;
    audit = audit || manual;
    const NSUInteger slot = self.presentationTransitionAudits % 6;
    NSMutableArray* roles = [NSMutableArray array];
    for (size_t count : hud.roleCounts) [roles addObject:@(count)];
    NSDictionary* event = @{@"schema":@"protector-native.presentation-transition/v1",
        @"sequence":@(++self->_presentationTransitionEvents), @"frame_index":@(frameIndex),
        @"host_seconds":@(now), @"transitions":manual ?
            [PresentationTransitionNames(flags) arrayByAddingObject:@"manual-capture"] : PresentationTransitionNames(flags),
        @"hud_admission":@(hud.reason), @"hud_draws":@(hud.count), @"hud_role_counts":roles,
        @"gameplay_scene":@(current.gameplayScene), @"wide_frame":wide,
        @"scene_antialias":@(antialias), @"copy_layout":MotionCopyLayout(copies, draws.size()),
        @"draw_count":@(draws.size()), @"thermal_state":@(NSProcessInfo.processInfo.thermalState),
        @"audit_slot":audit ? @(slot) : (id)NSNull.null};
    self.lastPresentationTransition = event;
    NSMutableData* line = [[NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys
        error:nil] mutableCopy];
    [line appendBytes:"\n" length:1];
    NSDictionary* report = nil;
    NSDictionary<NSString*, NSData*>* planes = nil;
    if (audit) {
        NSMutableDictionary<NSString*, NSData*>* textures = [NSMutableDictionary dictionary];
        NSMutableDictionary* interface = [InterfaceSourceAudit(draws, copies, textures) mutableCopy];
        interface[@"all_draws"] = AllDrawLayoutSummary(draws);
        interface[@"transition"] = event;
        interface[@"frame_index"] = @(frameIndex);
        if (manual) interface[@"copy_consumers"] = CopyConsumerAudit(draws, copies);
        report = interface;
        planes = textures;
        ++self->_presentationTransitionAudits;
    }
    NSURL* directory = self.outputDirectory;
    NSString* session = self.presentationTransitionSession;
    if (!self.presentationTransitionLogName)
        self.presentationTransitionLogName = [NSString stringWithFormat:@"presentation-transitions-%@", session];
    NSString* logName = self.presentationTransitionLogName;
    __weak ProtectorLiveMetalRenderer* weakSelf = self;
    dispatch_async(self.presentationTransitionQueue, ^{
        @autoreleasepool {
            ProtectorLiveMetalRenderer* renderer = weakSelf;
            if (!renderer) return;
            BOOL failed = NO;
            NSError* writeError = nil;
            if (line) {
                // Newest transitions retained: two alternating 2048-line segments.
                if (!renderer.presentationTransitionLog)
                    renderer.presentationTransitionLog = [[ProtectorPerformanceRing alloc] initWithDirectory:directory
                        stem:logName recordsPerSegment:2048 error:&writeError];
                if (!renderer.presentationTransitionLog ||
                    ![renderer.presentationTransitionLog writeRecord:line error:&writeError]) failed = YES;
            }
            if (report) {
                NSFileManager* files = NSFileManager.defaultManager;
                NSURL* folder = [directory URLByAppendingPathComponent:[NSString stringWithFormat:
                    @"presentation-transition-%@-slot%lu", session, (unsigned long)slot] isDirectory:YES];
                // Only this session's own slot is replaced; other sessions' evidence is untouched.
                if ([files fileExistsAtPath:folder.path]) [files removeItemAtURL:folder error:nil];
                NSData* json = [NSJSONSerialization dataWithJSONObject:report
                    options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&writeError];
                if (![files createDirectoryAtURL:folder withIntermediateDirectories:NO attributes:nil error:&writeError] ||
                    !json || ![json writeToURL:[folder URLByAppendingPathComponent:@"audit.json"]
                        options:NSDataWritingWithoutOverwriting error:&writeError]) failed = YES;
                else for (NSString* key in planes)
                    if (![planes[key] writeToURL:[folder URLByAppendingPathComponent:[key stringByAppendingString:@".rgba"]]
                            options:NSDataWritingWithoutOverwriting error:&writeError]) { failed = YES; break; }
            }
            if (failed) @synchronized(renderer) { ++renderer->_presentationTransitionWriteFailures; }
        }
    });
}

- (ProtectorPassTiming*)nextPassTiming {
    if (!self.lightweightPerformanceCapture || self.passTimingUnavailable) return nil;
    if (!self.passTimings) {
        id<MTLCounterSet> timestamps = nil;
        for (id<MTLCounterSet> set in self.device.counterSets)
            if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) timestamps = set;
        if (!timestamps || ![self.device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
            self.passTimingUnavailable = YES;
            return nil;
        }
        MTLCounterSampleBufferDescriptor* descriptor = [[MTLCounterSampleBufferDescriptor alloc] init];
        descriptor.counterSet = timestamps;
        descriptor.sampleCount = 96;
        descriptor.storageMode = MTLStorageModeShared;
        NSMutableArray* pool = [NSMutableArray array];
        for (int i = 0; i < 8; ++i) {
            id<MTLCounterSampleBuffer> buffer = [self.device newCounterSampleBufferWithDescriptor:descriptor error:nil];
            if (!buffer) { self.passTimingUnavailable = YES; return nil; }
            ProtectorPassTiming* timing = [[ProtectorPassTiming alloc] init];
            timing.buffer = buffer;
            [pool addObject:timing];
        }
        MTLTimestamp cpu = 0, gpu = 0;
        [self.device sampleTimestamps:&cpu gpuTimestamp:&gpu];
        self.passTimingCPUBase = cpu;
        self.passTimingGPUBase = gpu;
        self.passTimings = pool;
    }
    ProtectorPassTiming* timing = self.passTimings[self.passTimingCursor++ % self.passTimings.count];
    timing.kinds = [NSMutableArray array];
    return timing;
}

// GPU timestamp ticks to seconds, from the device's CPU/GPU clock correlation.
- (double)passTimingSecondsPerTick {
    MTLTimestamp cpu = 0, gpu = 0;
    [self.device sampleTimestamps:&cpu gpuTimestamp:&gpu];
    if (gpu <= self.passTimingGPUBase || cpu <= self.passTimingCPUBase) return 0;
    return (double)(cpu - self.passTimingCPUBase) * 1e-9 / (double)(gpu - self.passTimingGPUBase);
}

- (BOOL)requestManualFrameAudit {
    if (!self.presentationTransitionAuditEnabled) return NO;
    self.manualAuditRequested = YES;
    return YES;
}

// HUD admission once per source frame (renderer lock held). Interpolated
// re-renders of the same frame reuse it, and only new source frames update
// the remembered anchor positions and the loss counter.
- (NativeHudAdmission)nativeHudForDraws:(const std::vector<LiveDraw>&)draws frame:(u32)frameIndex {
    uint64_t signature = 1469598103934665603ull;
    const auto mix = [&](uint64_t value) { signature = (signature ^ value) * 1099511628211ull; };
    mix(frameIndex); mix(draws.size());
    for (const auto& draw : draws) {
        if (draw.projectionWords[6] == 0u) continue;
        mix(draw.textureAddresses[0]); mix(draw.textureAddresses[1]); mix(draw.vertices.size());
        if (!draw.vertices.empty()) {
            u32 bits[2]; memcpy(bits, draw.vertices.front().position, sizeof(bits));
            mix(bits[0]); mix(bits[1]);
        }
    }
    if (signature == _hudSignature && _hudCached.draws.size() == draws.size()) return _hudCached;
    NativeHudAdmission admission = IdentifyNativeHud(draws, &_hudMemory, frameIndex);
    if (admission.count && !admission.partial) {
        _hudMemory.valid = true;
        _hudMemory.frame = frameIndex;
        _hudMemory.anchorCentre = admission.anchorCentre;
    }
    if (admission.partial) ++self->_hudCarriedFrames;
    // Counted for every admitted-to-lost change, recognised anchors or not.
    if (_hudPreviouslyAdmitted && !admission.count) ++self->_hudLostEvents;
    _hudPreviouslyAdmitted = admission.count > 0;
    _hudSignature = signature;
    _hudCached = admission;
    return admission;
}

- (BOOL)renderDraws:(const std::vector<LiveDraw>&)draws
          efbCopies:(const std::vector<LiveEfbCopy>&)efbCopies
              frame:(u32)frameIndex
              error:(NSError**)error {
    const double renderStart = self.motionPresentationLog ? CACurrentMediaTime() : 0;
    // Guest rectangles, texture addresses and XF coordinates remain logical.
    // Scale only physical render targets, viewports and GPU-to-GPU copy regions.
    NSUInteger renderScale = self.renderScale;
    // Fixed scales stay uniform; Native resolution scales each axis to the
    // drawable (renderScale is the horizontal factor).
    NSUInteger renderScaleY = renderScale;
    if (self.nativeResolutionEnabled) {
        unsigned sourceWidth = 640, sourceHeight = 480;
        for (const LiveEfbCopy& copy : efbCopies) {
            if (!(copy.command & (1u << 14u))) continue;
            if (copy.drawIndex != draws.size() || copy.yScale != 256u ||
                ((copy.command >> 12u) & 3u) || ((copy.command >> 7u) & 3u) ||
                !copy.width || !copy.height ||
                (uint64_t)copy.sourceX + copy.width > 640u ||
                (uint64_t)copy.sourceY + copy.height > 480u) {
                if (error) *error = LiveError(23, @"Unsupported display copy for Native resolution.");
                return NO;
            }
            sourceWidth = copy.width; sourceHeight = copy.height;
        }
        unsigned scaleX = 0, scaleY = 0;
        renderScale = protector_native_render_scale_axes(self.nativeRenderPixelSize.width,
            self.nativeRenderPixelSize.height, sourceWidth, sourceHeight, &scaleX, &scaleY) ? scaleX : 0;
        renderScaleY = scaleY;
        if (!renderScale) {
            if (error) *error = LiveError(26,
                @"This source picture cannot cover the display at Native resolution. Choose a fixed render scale.");
            return NO;
        }
    }
    const BOOL widescreen = self.widescreenEnabled;
    const BOOL nativeViewport = widescreen && self.nativePresentationSize.height > 0;
    const double frameAspect = !widescreen ? 4.0 / 3.0 : nativeViewport
        ? self.nativePresentationSize.width / self.nativePresentationSize.height : 16.0 / 9.0;
    const float wideRatio = (float)((4.0 / 3.0) / frameAspect);
    ProtectorCinematicFrame cinematic{};
    cinematic.presentation_frame = frameIndex;
    if (self.pendingCinematic.presentation_frame == frameIndex) cinematic = self.pendingCinematic;
    else if (self.artworkPreviewFrame) {
        const auto* snapshot = static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        if (snapshot->valid && snapshot->index == frameIndex) cinematic = snapshot->cinematic;
        else if (self.motionHistory) {
            const auto& previous = static_cast<MotionPresentationHistory*>(self.motionHistory)->previous;
            if (previous.valid && previous.index == frameIndex) cinematic = previous.cinematic;
        }
    }
    MTLViewport movieViewport{};
    const s32 cinematicDraw =
        CinematicDisplayViewport(efbCopies,draws.size(),renderScale,renderScaleY,&movieViewport)
        ? IdentifyCinematicDraw(draws,cinematic) : -1;
    // Precise lifetime retains the CVPixelBuffer/CVMetalTexture wrappers until
    // after this function's command-buffer wait, not just the Metal texture.
    ProtectorCinematicImage* __attribute__((objc_precise_lifetime)) cinematicImage = cinematicDraw >= 0
        ? [self.cinematicPack imageForFrame:cinematic] : nil;
    const double movieAspect = cinematicImage ? (double)cinematicImage.luma.width/cinematicImage.luma.height : 4.0/3.0;
    const auto surround = CinematicSurround(widescreen, cinematicDraw >= 0, cinematicImage != nil, frameAspect, movieAspect);
    const auto nativeHud = nativeViewport ? [self nativeHudForDraws:draws frame:frameIndex] : NativeHudAdmission{};
    if (!nativeHud.count && (nativeHud.roleCounts[2] || nativeHud.roleCounts[3])) {
        ++self->_hudRejectedFrames;
        self.hudLastRejectedFrame=frameIndex;
    }
    if (!nativeHud.count && (nativeHud.roleCounts[2] || nativeHud.roleCounts[3]) &&
        !self.hudRejectionCaptured && getenv("PROTECTOR_HUD_TRANSITION_AUDIT")) {
        self.hudRejectionCaptured=YES;
        NSMutableDictionary* textures=[NSMutableDictionary dictionary];
        NSMutableDictionary* audit=[InterfaceSourceAudit(draws,efbCopies,textures) mutableCopy];
        audit[@"frame_index"]=@(frameIndex);
        audit[@"admission"]=@(nativeHud.reason);
        NSData* encoded=[NSJSONSerialization dataWithJSONObject:audit options:0 error:nil];
        [encoded writeToURL:[self.outputDirectory URLByAppendingPathComponent:@"hud-transition-rejection.json"] atomically:YES];
    }
    const auto frontend = widescreen && frameAspect >= 4.0/3.0 && frameAspect <= 3.0
        ? IdentifyFrontend(draws, efbCopies) : FrontendAdmission{};
    const auto sharedPanel = widescreen && frameAspect >= 4.0/3.0 && frameAspect <= 3.0
        ? IdentifySharedPanel(draws) : SharedPanelAdmission{};
    const auto galleryLayout = widescreen && !frontend.enabled && frameAspect >= 4.0/3.0 && frameAspect <= 3.0
        ? IdentifyGalleryLayout(draws,efbCopies,cinematicDraw) : GalleryLayoutAdmission{};
    const auto galleryModelFrame = IdentifyGalleryModelFrame(draws,galleryLayout);
    const auto combo=IdentifyComboGlyphs(draws,efbCopies);
    const auto upgrade=IdentifyUpgradeGlyphs(draws,efbCopies);
    auto qte=self.artworkPreviewFrame && self.restoredArtworkEnabled ? IdentifyQTE(draws) : QTEAdmission{};
    if(self.artworkPreviewFrame && self.restoredArtworkEnabled && !draws.empty()) {
        const u32 prompt=draws.front().interactionPrompts;
        bool same=true;
        for(const auto& draw:draws)if(draw.interactionPrompts!=prompt){same=false;break;}
        if(same)qte.prompts|=prompt;
    }
    if(qte.motionDraws && (!self.qteGlyphColor || !self.qteGlyphCoverage)) {
        const auto glyph=CreateQTEGlyphTextures(self.device);
        self.qteGlyphColor=glyph[0];self.qteGlyphCoverage=glyph[1];
        if(!self.qteGlyphColor || !self.qteGlyphCoverage) {
            self.qtePrompts=0;self.qtePointerActive=NO;self.qteTargetRect=CGRectNull;
            if(error)*error=LiveError(15,@"Native interaction glyph allocation failed.");
            return NO;
        }
    }
    const auto combatFeedback=nativeViewport && !frontend.enabled && !galleryLayout.enabled &&
        !sharedPanel.enabled && !combo.enabled && !upgrade.enabled && cinematicDraw<0
        ? IdentifyCombatFeedback(draws,efbCopies,&nativeHud) : CombatFeedbackAdmission{};
    const bool combatFeedbackLayout=combatFeedback.enabled && self.nativeCombatFeedbackFrame.size.height>0;
    const auto combatMoves=nativeViewport && !frontend.enabled && !galleryLayout.enabled &&
        !sharedPanel.enabled && !combo.enabled && !upgrade.enabled && cinematicDraw<0
        ? IdentifyCombatMoves(draws,efbCopies,nativeHud) : CombatMoveAdmission{};
    const bool comboLayout=nativeViewport && combo.enabled && self.nativeComboFrame.size.height>0;
    const bool upgradeLayout=nativeViewport && upgrade.enabled && self.nativeUpgradeFrame.size.height>0;
    if((combo.enabled || upgrade.enabled) && !self.comboGlyphTexture)self.comboGlyphTexture=CreateComboGlyphTexture(self.device);
    if((combo.enabled || upgrade.enabled) && !self.comboGlyphTexture) {
        if(error)*error=LiveError(15,@"Native move action texture allocation failed.");
        return NO;
    }
    const bool worldMap = widescreen && IdentifyWorldMap(draws, efbCopies);
    const auto sceneAntialias = IdentifySceneAntialiasBoundary(draws, efbCopies);
    const bool applySceneAntialias = self.sceneAntialiasEnabled && widescreen &&
        self.restoredArtworkEnabled && self.enhancedModelsEnabled &&
        cinematicDraw < 0 && !frontend.enabled && !galleryLayout.enabled &&
        !combo.enabled && !upgrade.enabled && !worldMap && sceneAntialias.enabled;
    const auto wideFrame = widescreen ? SummarizeWideDraws(draws) : WideFrameSummary{};
    NSDictionary* wideFrameReceipt = WideFrameReceipt(wideFrame);
    if (self.presentationTransitionAuditEnabled && nativeViewport) {
        PresentationTransitionState transition;
        transition.hudAdmitted = nativeHud.count > 0;
        transition.gameplayScene = wideFrame.scene > 0 && cinematicDraw < 0;
        transition.nearMainUnchanged = wideFrame.nearMainUnchanged;
        transition.fullFrameOverlays = wideFrame.fullFrameOverlays;
        [self notePresentationTransition:transition frame:frameIndex hud:nativeHud wide:wideFrameReceipt
            draws:draws copies:efbCopies antialias:sceneAntialias.reason hostSeconds:CACurrentMediaTime()];
    }
    const auto mapLayout=worldMap?IdentifyMapLayout(draws,efbCopies,true):MapLayoutAdmission{};
    const CGSize mapViewport=nativeViewport?self.nativePresentationSize:CGSizeMake(480*frameAspect,480);
    const auto mapDetailBackdrop=PlanMapDetailBackdrop(draws,worldMap,mapViewport);
    const auto mapPlan=PlanMapLayout(mapLayout,mapViewport,
        nativeViewport?self.nativeMapTitleFrame:CGRectMake(12,8,mapViewport.width-24,60),
        nativeViewport?self.nativeMapCardsFrame:CGRectMake(12,80,mapViewport.width-24,336),
        nativeViewport?self.nativeMapHintsFrame:CGRectMake(12,440,mapViewport.width-24,28));
    const auto finiteRoomFrame = widescreen && !frontend.enabled && !galleryLayout.enabled &&
        !sharedPanel.enabled && !combo.enabled && !upgrade.enabled && !worldMap && cinematicDraw<0
        ? IdentifyFiniteRoomFrame(draws,frameAspect) : FiniteRoomFrame{};
    const MTLClearColor background = worldMap ? WorldMapOceanColor(draws[0].vertices[0].color[0])
                                            : MTLClearColorMake(0, 0, 0, 1);
    const BOOL enhancedModels = self.enhancedModelsEnabled;
    const NSUInteger logicalWidth = 640u, logicalHeight = 480u;
    const BOOL restored = self.restoredArtworkEnabled && self.texturePack != nil;
    if (restored != self.frameUsesRestoredArtwork) {
        [self.textureCache removeAllObjects];
        self.textureCacheBytes = 0;
        self.frameUsesRestoredArtwork = restored;
    }
    [self.texturePack beginFrame];
    // One immutable upload per frame avoids hundreds of small Metal buffers.
    // Each draw still has its own shader-visible base, including after an EFB
    // copy ends and recreates the render encoder. The command buffer retains
    // this resource until completion; no in-flight storage is overwritten.
    static_assert(sizeof(LiveVertex) % 16u == 0u, "vertex offsets must be aligned");
    std::vector<NSUInteger> vertexOffsets;
    std::vector<NSUInteger> indexOffsets;
    vertexOffsets.reserve(draws.size());
    NSUInteger vertexBytes = 0u;
    for (const LiveDraw& draw : draws) {
        const auto& vertices = RenderVertices(draw, enhancedModels);
        vertexOffsets.push_back(vertexBytes);
        if (vertices.size() >
                (self.device.maxBufferLength - vertexBytes) / sizeof(LiveVertex)) {
            if (error) *error = LiveError(25, @"frame vertex upload exceeds Metal buffer limit");
            return NO;
        }
        vertexBytes += vertices.size() * sizeof(LiveVertex);
    }
    // Continue the admitted source's lower boundary behind the scenery. The
    // existing gradient is untouched: duplicate its edge colors, UV and depth,
    // extending only the extra upload's Y coordinates to the viewport bottom.
    const NSUInteger backdropVertexOffset = vertexBytes;
    std::vector<NSUInteger> backdropOffsets(draws.size(), 0);
    std::vector<LiveVertex> backdropVertices;
    if (widescreen) for (size_t i = 0; i < draws.size(); ++i) {
        std::array<LiveVertex, 6> extension{};
        if (FiniteBackdropExtension(draws[i], &extension)) {
            backdropOffsets[i] = vertexBytes;
            backdropVertices.insert(backdropVertices.end(), extension.begin(), extension.end());
            vertexBytes += sizeof(extension);
        }
    }
    if (vertexBytes > self.device.maxBufferLength) {
        if (error) *error = LiveError(25, @"backdrop extension exceeds Metal buffer limit");
        return NO;
    }
    const NSUInteger repeatingVertexOffset = vertexBytes;
    std::vector<NSUInteger> repeatingOffsets(draws.size(),0);
    std::vector<LiveVertex> repeatingVertices;
    const bool repeatingCohort = widescreen && frameAspect > 4.0/3.0 + 1e-6 &&
        frameAspect <= 3.0 && RepeatingBackdropCohort(draws);
    if (repeatingCohort) for (size_t i = 0; i < draws.size(); ++i) {
        std::array<LiveVertex,12> extension{};
        if (RepeatingBackdropExtension(draws[i],&extension)) {
            for (auto& vertex : extension) vertex.position[0] *= wideRatio;
            repeatingOffsets[i] = vertexBytes;
            repeatingVertices.insert(repeatingVertices.end(),extension.begin(),extension.end());
            vertexBytes += sizeof(extension);
        }
    }
    if (repeatingVertices.size() != 24) {
        repeatingVertices.clear();
        std::fill(repeatingOffsets.begin(),repeatingOffsets.end(),0);
        vertexBytes = repeatingVertexOffset;
    }
    if (vertexBytes > self.device.maxBufferLength) {
        if (error) *error = LiveError(25,@"repeating backdrop extension exceeds Metal buffer limit");
        return NO;
    }
    const NSUInteger hillVertexOffset=vertexBytes;
    std::vector<NSUInteger> hillOffsets(draws.size(),0);
    std::vector<LiveVertex> hillVertices;
    const bool hillCohort=widescreen && frameAspect>4.0/3.0+1e-6 &&
        frameAspect<=3.0 && HillBackdropCohort(draws);
    if (hillCohort) for (size_t i=0;i<draws.size();++i) {
        std::array<LiveVertex,12> extension{};
        if (HillBackdropExtension(draws[i],&extension)) {
            for (auto& vertex : extension) vertex.position[0]*=wideRatio;
            hillOffsets[i]=vertexBytes;
            hillVertices.insert(hillVertices.end(),extension.begin(),extension.end());
            vertexBytes+=sizeof(extension);
        }
    }
    if (hillVertices.size()!=24) {
        hillVertices.clear();
        std::fill(hillOffsets.begin(),hillOffsets.end(),0);
        vertexBytes=hillVertexOffset;
    }
    if (vertexBytes>self.device.maxBufferLength) {
        if (error) *error=LiveError(25,@"hill backdrop extension exceeds Metal buffer limit");
        return NO;
    }
    const NSUInteger canyonSkyVertexOffset = vertexBytes;
    std::vector<NSUInteger> canyonSkyOffsets(draws.size(), 0);
    std::vector<LiveVertex> canyonSkyVertices;
    const bool canyonSkyCohort = widescreen && frameAspect > 4.0/3.0 + 1e-6 &&
        frameAspect <= 3.0 && CanyonSkyCohort(draws);
    if (canyonSkyCohort) for (size_t i = 0; i < draws.size(); ++i) {
        std::array<LiveVertex, 6> extension{};
        if (CanyonSkyExtension(draws[i], &extension)) {
            for (auto& vertex : extension) vertex.position[0] *= wideRatio;
            canyonSkyOffsets[i] = vertexBytes;
            canyonSkyVertices.insert(canyonSkyVertices.end(), extension.begin(), extension.end());
            vertexBytes += sizeof(extension);
        }
    }
    if (vertexBytes > self.device.maxBufferLength) {
        if (error) *error = LiveError(25, @"Canyon sky continuation exceeds Metal buffer limit");
        return NO;
    }
    const NSUInteger citySkyVertexOffset = vertexBytes;
    std::vector<NSUInteger> citySkyOffsets(draws.size(), 0);
    std::vector<LiveVertex> citySkyVertices;
    const bool citySkyCohort = widescreen && frameAspect > 4.0/3.0 + 1e-6 &&
        frameAspect <= 3.0 && CitySkyCohort(draws);
    if (citySkyCohort) for (size_t i = 0; i < draws.size(); ++i) {
        std::array<LiveVertex,18> extension{};
        if (CitySkyExtension(draws[i], &extension)) {
            for (auto& vertex : extension) vertex.position[0] *= wideRatio;
            citySkyOffsets[i] = vertexBytes;
            citySkyVertices.insert(citySkyVertices.end(), extension.begin(), extension.end());
            vertexBytes += sizeof(extension);
        }
    }
    if (vertexBytes > self.device.maxBufferLength) {
        if (error) *error = LiveError(25, @"City sky continuation exceeds Metal buffer limit");
        return NO;
    }
    const NSUInteger relatedCitySkyVertexOffset = vertexBytes;
    std::vector<NSUInteger> relatedCitySkyOffsets(draws.size(), 0);
    std::vector<std::vector<LiveVertex>> relatedCitySkyPieces;
    std::vector<LiveVertex> relatedCitySkyVertices;
    const u8 relatedCitySkyCohort = widescreen && frameAspect > 4.0/3.0 + 1e-6 &&
        frameAspect <= 3.0 ? RelatedCitySkyContinuation(draws, &relatedCitySkyPieces) : 0;
    if (relatedCitySkyCohort) for (size_t i = 0; i < draws.size(); ++i) {
        auto& extension = relatedCitySkyPieces[i];
        if (extension.empty()) continue;
        for (auto& vertex : extension) vertex.position[0] *= wideRatio;
        relatedCitySkyOffsets[i] = vertexBytes;
        relatedCitySkyVertices.insert(relatedCitySkyVertices.end(),extension.begin(),extension.end());
        vertexBytes += extension.size()*sizeof(LiveVertex);
    }
    if (vertexBytes > self.device.maxBufferLength) {
        if (error) *error = LiveError(25, @"Related city sky continuation exceeds Metal buffer limit");
        return NO;
    }
    const NSUInteger vertexPayloadBytes = vertexBytes;
    for (const LiveDraw& draw : draws) {
        const auto& vertices = RenderVertices(draw, enhancedModels);
        const auto& indices = RenderIndices(draw, enhancedModels);
        indexOffsets.push_back(vertexBytes);
        if (indices.size() > (self.device.maxBufferLength - vertexBytes) / sizeof(u32)) {
            if (error) *error = LiveError(25, @"frame index upload exceeds Metal buffer limit");
            return NO;
        }
        if (RenderIndexed(draw, enhancedModels) && std::any_of(indices.begin(), indices.end(),
                [&](u32 index) { return index >= vertices.size(); })) {
            if (error) *error = LiveError(25, @"triangle index exceeds vertex range");
            return NO;
        }
        vertexBytes += indices.size() * sizeof(u32);
    }
    // Live play pools its targets and upload buffer; proofs, tests and
    // diagnostics keep fresh, independent allocations.
    if (!self.resourcePool) self.resourcePool = [[ProtectorResourcePool alloc] init];
    ProtectorFrameResources* frameResources = self.renderTargetOptimizationsEnabled &&
        self.asynchronousPresentationRender && !self.motionProofRedraw
        ? [[ProtectorFrameResources alloc] initWithPool:self.resourcePool device:self.device] : nil;
    id<MTLBuffer> frameVertices = frameResources
        ? [frameResources buffer:std::max<NSUInteger>(vertexBytes, sizeof(LiveVertex))]
        : [self.device newBufferWithLength:std::max<NSUInteger>(vertexBytes, sizeof(LiveVertex))
            options:MTLResourceStorageModeShared];
    if (!frameVertices || !frameVertices.contents) {
        if (error) *error = LiveError(25, @"frame vertex upload allocation failed");
        return NO;
    }
    NSUInteger wideSceneDraws = 0, wideSafeAreaDraws = 0, wideScreenFills = 0, finiteBackdropDraws = 0;
    if (!backdropVertices.empty()) memcpy(static_cast<u8*>(frameVertices.contents) + backdropVertexOffset,
        backdropVertices.data(), backdropVertices.size() * sizeof(LiveVertex));
    if (!repeatingVertices.empty()) memcpy(static_cast<u8*>(frameVertices.contents) + repeatingVertexOffset,
        repeatingVertices.data(), repeatingVertices.size()*sizeof(LiveVertex));
    if (!hillVertices.empty()) memcpy(static_cast<u8*>(frameVertices.contents)+hillVertexOffset,
        hillVertices.data(),hillVertices.size()*sizeof(LiveVertex));
    if (!canyonSkyVertices.empty()) memcpy(static_cast<u8*>(frameVertices.contents) + canyonSkyVertexOffset,
        canyonSkyVertices.data(), canyonSkyVertices.size()*sizeof(LiveVertex));
    if (!citySkyVertices.empty()) memcpy(static_cast<u8*>(frameVertices.contents) + citySkyVertexOffset,
        citySkyVertices.data(), citySkyVertices.size()*sizeof(LiveVertex));
    if (!relatedCitySkyVertices.empty()) memcpy(static_cast<u8*>(frameVertices.contents) + relatedCitySkyVertexOffset,
        relatedCitySkyVertices.data(),relatedCitySkyVertices.size()*sizeof(LiveVertex));
    NSUInteger refinedDraws = 0, refinedTriangles = 0;
    NSMutableSet<NSString*>* modelIdentities = [NSMutableSet set];
    for (size_t index = 0u; index < draws.size(); ++index) {
        const auto& vertices = RenderVertices(draws[index], enhancedModels);
        if (UsesRefinedGeometry(draws[index], enhancedModels)) {
            ++refinedDraws;
            refinedTriangles += draws[index].geometryProfile->indices.size() / 3;
            [modelIdentities addObject:[NSString stringWithUTF8String:draws[index].geometryProfile->identity.c_str()]];
        }
        if (!vertices.empty()) {
            auto* uploaded = reinterpret_cast<LiveVertex*>(
                static_cast<u8*>(frameVertices.contents) + vertexOffsets[index]);
            memcpy(uploaded, vertices.data(), vertices.size() * sizeof(LiveVertex));
            if(combo.enabled && !combo.actions[index].empty())UploadComboGlyphs(uploaded,combo.actions[index]);
            if(upgrade.enabled && !upgrade.actions[index].empty())
                UploadComboGlyphs(uploaded,upgrade.actions[index],.330357164f,.169642866f);
            if (cinematicImage && (s32)index == cinematicDraw) {
                for (size_t vertex=0; vertex<vertices.size(); ++vertex)
                    TransformCinematicVertex(&uploaded[vertex],frameAspect,movieAspect);
            } else if (widescreen) {
                const WideDrawRole role = ClassifyWideDraw(draws[index]);
                wideSceneDraws += role == WideDrawRole::Scene;
                wideSafeAreaDraws += role == WideDrawRole::SafeArea;
                wideScreenFills += role == WideDrawRole::ScreenFill;
                if(mapDetailBackdrop.enabled&&index<29) {
                    for(size_t vertex=0;vertex<vertices.size();++vertex)
                        TransformMapDetailBackdrop(&uploaded[vertex],mapDetailBackdrop);
                } else if(mapPlan.enabled&&mapLayout.groups[index]>=0) {
                    for(size_t vertex=0;vertex<vertices.size();++vertex)
                        TransformMapVertex(&uploaded[vertex],mapLayout.groups[index],mapLayout,mapPlan);
                } else if (upgradeLayout && upgrade.contains(index)) {
                    for(size_t vertex=0;vertex<vertices.size();++vertex)
                        TransformComboVertex(&uploaded[vertex],self.nativePresentationSize,self.nativeUpgradeFrame);
                } else if (comboLayout && combo.contains(index)) {
                    for(size_t vertex=0;vertex<vertices.size();++vertex)
                        TransformComboVertex(&uploaded[vertex],self.nativePresentationSize,self.nativeComboFrame);
                } else if (combatFeedbackLayout && combatFeedback.contains(index)) {
                    for(size_t vertex=0;vertex<vertices.size();++vertex)
                        TransformCombatFeedbackVertex(&uploaded[vertex],self.nativePresentationSize,self.nativeCombatFeedbackFrame);
                } else if (frontend.enabled) {
                    float left = vertices.front().position[0], right = left;
                    for (const auto& vertex : vertices) {
                        left = std::min(left, vertex.position[0]); right = std::max(right, vertex.position[0]);
                    }
                    for (size_t vertex = 0; vertex < vertices.size(); ++vertex) {
                        if (frontend.secondary)
                            TransformSecondaryFrontendVertex(&uploaded[vertex],frontend.roles[index],frameAspect,
                                left,right,frontend.panelCenter);
                        else TransformFrontendVertex(&uploaded[vertex], frontend.roles[index], frameAspect,
                            (left+right)/2, frontend.menu);
                    }
                } else if (galleryModelFrame.contains(index)) {
                    for (size_t vertex=0;vertex<vertices.size();++vertex)
                        TransformGalleryModelVertex(&uploaded[vertex],galleryModelFrame,frameAspect);
                } else if (galleryLayout.role(index) != FrontendRole::Unknown) {
                    float left = vertices.front().position[0], right = left;
                    for (const auto& vertex : vertices) {
                        left = std::min(left,vertex.position[0]); right = std::max(right,vertex.position[0]);
                    }
                    for (size_t vertex=0;vertex<vertices.size();++vertex)
                        TransformGalleryLayoutVertex(&uploaded[vertex],galleryLayout.role(index),frameAspect,
                            left,right,galleryLayout.panelCenter);
                } else if (sharedPanel.role(index) != SharedPanelRole::None) {
                    for (size_t vertex=0;vertex<vertices.size();++vertex)
                        TransformSharedPanelVertex(&uploaded[vertex],sharedPanel.role(index),frameAspect);
                } else if ((nativeHud.count && nativeHud.draws[index]) || combatMoves.contains(index)) {
                    for (size_t vertex = 0; vertex < vertices.size(); ++vertex)
                        TransformNativeHudVertex(&uploaded[vertex], self.nativePresentationSize, self.nativeHudFrame);
                } else if (role == WideDrawRole::Scene && draws[index].finiteBackdropIdentity) {
                    // Source-bound nontextured gradient sky remains full width.
                    // Retain its original horizontal clip extent; only foreground
                    // perspective expands. Do not alter depth, colors or guest XF.
                    ++finiteBackdropDraws;
                } else if (role == WideDrawRole::Scene || role == WideDrawRole::SafeArea) {
                    // 4:3 / presentation aspect. Scene: wider horizontal FOV at unchanged
                    // vertical FOV; 2D: original proportions in a safe area.
                    // Modify only this upload, never guest XF or the snapshot.
                    for (size_t vertex = 0; vertex < vertices.size(); ++vertex) {
                        uploaded[vertex].position[0] *= wideRatio;
                        if (role == WideDrawRole::Scene && finiteRoomFrame.enabled)
                            uploaded[vertex].position[0] += finiteRoomFrame.bias*uploaded[vertex].position[3];
                    }
                }
            }
        }
        const auto& indices = RenderIndices(draws[index], enhancedModels);
        if(widescreen && qte.replaces(index)) {
            auto* uploaded=reinterpret_cast<LiveVertex*>(static_cast<u8*>(frameVertices.contents)+vertexOffsets[index]);
            for(size_t vertex=0;vertex<vertices.size();++vertex)
                FitQTEMotionVertex(&uploaded[vertex],qte,frameAspect,self.qteMotionSafeRect);
        }
        if (!indices.empty()) memcpy(static_cast<u8*>(frameVertices.contents) + indexOffsets[index],
                                     indices.data(), indices.size() * sizeof(u32));
    }
    MTLTextureDescriptor* targetDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatBGRA8Unorm
                                                        width:logicalWidth * renderScale
                                                       height:logicalHeight * renderScaleY
                                                    mipmapped:NO];
    const BOOL privateLiveTargets=self.renderTargetOptimizationsEnabled && self.asynchronousPresentationRender;
    targetDescriptor.storageMode = privateLiveTargets ? MTLStorageModePrivate : MTLStorageModeShared;
    targetDescriptor.usage =
        MTLTextureUsageRenderTarget |
        MTLTextureUsageShaderRead;
    id<MTLTexture> target = frameResources ? [frameResources texture:targetDescriptor]
        : [self.device newTextureWithDescriptor:targetDescriptor];
    MTLTextureDescriptor* depthDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatDepth32Float
                                                        width:logicalWidth * renderScale
                                                       height:logicalHeight * renderScaleY
                                                    mipmapped:NO];
    depthDescriptor.storageMode = MTLStorageModePrivate;
    depthDescriptor.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> depth = frameResources ? [frameResources texture:depthDescriptor]
        : [self.device newTextureWithDescriptor:depthDescriptor];
    id<MTLCommandBuffer> commandBuffer =
        [self.commandQueue commandBuffer];
    MTLRenderPassDescriptor* pass =
        [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = background;
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1.0;
    // Shadow-mask window in its own small target (live play only; proofs,
    // tests and diagnostics keep the original copy/restore sequence).
    ShadowWindowPlan shadowWindow;
    shadowWindow.reason = "disabled";
    id<MTLTexture> shadowTarget = nil;
    MTLRenderPassDescriptor* shadowPass = nil;
    if (frameResources && self.shadowWindowRedirectEnabled)
        shadowWindow = PlanShadowWindow(draws, efbCopies, applySceneAntialias ? sceneAntialias.index : SIZE_MAX,
            cinematicDraw);
    if (shadowWindow.eligible) {
        const LiveEfbCopy& maskCopy = efbCopies[shadowWindow.copyB];
        MTLTextureDescriptor* shadowDescriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:maskCopy.width * renderScale height:maskCopy.height * renderScaleY mipmapped:NO];
        shadowDescriptor.storageMode = MTLStorageModePrivate;
        shadowDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        MTLTextureDescriptor* shadowDepthDescriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
            width:shadowDescriptor.width height:shadowDescriptor.height mipmapped:NO];
        // The window never tests or writes depth; the attachment only keeps
        // the shared pipelines' depth format valid.
        const BOOL memoryless = [self.device supportsFamily:MTLGPUFamilyApple1];
        shadowDepthDescriptor.storageMode = memoryless ? MTLStorageModeMemoryless : MTLStorageModePrivate;
        shadowDepthDescriptor.usage = MTLTextureUsageRenderTarget;
        shadowTarget = [frameResources texture:shadowDescriptor];
        id<MTLTexture> shadowDepth = memoryless ? [self.device newTextureWithDescriptor:shadowDepthDescriptor]
            : [frameResources texture:shadowDepthDescriptor];
        if (shadowTarget && shadowDepth) {
            shadowPass = [MTLRenderPassDescriptor renderPassDescriptor];
            shadowPass.colorAttachments[0].texture = shadowTarget;
            shadowPass.colorAttachments[0].loadAction = MTLLoadActionClear;
            shadowPass.colorAttachments[0].storeAction = MTLStoreActionStore;
            shadowPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            shadowPass.depthAttachment.texture = shadowDepth;
            shadowPass.depthAttachment.loadAction = MTLLoadActionClear;
            shadowPass.depthAttachment.storeAction = MTLStoreActionDontCare;
            shadowPass.depthAttachment.clearDepth = 1.0;
            ++self->_shadowWindowsElided;
        } else {
            shadowWindow.eligible = false;
            shadowWindow.reason = "side-target-allocation";
        }
    }
    // Encode order: the shadow window first (into its side target), then
    // every other draw in source order, skipping the window and its restore.
    std::vector<size_t> drawOrder;
    drawOrder.reserve(draws.size());
    size_t mainStart = 0;
    if (shadowWindow.eligible) {
        for (size_t i = shadowWindow.first; i < shadowWindow.restore; ++i) drawOrder.push_back(i);
        mainStart = drawOrder.size();
        for (size_t i = 0; i < draws.size(); ++i)
            if (i < shadowWindow.first || i > shadowWindow.restore) drawOrder.push_back(i);
    } else for (size_t i = 0; i < draws.size(); ++i) drawOrder.push_back(i);
    ProtectorPassTiming* passTiming = [self nextPassTiming];
    [passTiming attachRender:shadowWindow.eligible ? shadowPass : pass
                        kind:shadowWindow.eligible ? @"shadow-window" : @"scene"];
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:shadowWindow.eligible ? shadowPass : pass];
    if (!target || !depth || !commandBuffer || !encoder) {
        if (encoder) [encoder endEncoding];
        if (error) {
            *error = LiveError(10, @"live GX command encoding failed");
        }
        return NO;
    }
    NSUInteger sourceVertices = 0u;
    NSUInteger noWriteCulledDraws = 0u;
    NSUInteger specializedDraws = 0u;
    // Opt-in (performance capture): where the shaded pixels go, by shader path.
    const BOOL shadingSummary = self.lightweightPerformanceCapture;
    double specializedArea = 0, generalArea = 0;
    NSMutableDictionary<NSString*, NSNumber*>* generalAreas = shadingSummary ? [NSMutableDictionary dictionary] : nil;
    NSMutableDictionary<NSString*, NSNumber*>* generalCounts = shadingSummary ? [NSMutableDictionary dictionary] : nil;
    NSMutableArray<NSDictionary*>* drawDiagnostics =
        [NSMutableArray arrayWithCapacity:draws.size()];
    NSMutableArray* efbTextures =
        [NSMutableArray arrayWithCapacity:efbCopies.size()];
    // Readable copies exist only during the bounded spatial proof. Normal
    // gameplay retains private GPU resources and performs no PNG readback.
    NSMutableDictionary* proofShadowTextures = self.motionProofRedraw ? [NSMutableDictionary dictionary] : nil;
    NSMutableArray* proofCopyConsumers = self.motionProofRedraw ? [NSMutableArray array] : nil;
    self.motionProofShadowTextures = nil;
    self.motionProofCopyConsumers = nil;
    for (size_t index = 0u; index < efbCopies.size(); ++index) {
        [efbTextures addObject:NSNull.null];
    }
    size_t nextEfbCopy = 0u;
    for (size_t orderIndex = 0u; orderIndex < drawOrder.size(); ++orderIndex) {
        const size_t drawIndex = drawOrder[orderIndex];
        const bool inShadowWindow = shadowWindow.eligible && orderIndex < mainStart;
        if (shadowWindow.eligible && orderIndex == mainStart) {
            // Side pass complete; the main pass starts exactly as it would have.
            [encoder endEncoding];
            [passTiming attachRender:pass kind:@"scene"];
            encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
            if (!encoder) {
                if (error) *error = LiveError(14, @"EFB pass start failed");
                return NO;
            }
        }
        // Fences are processed in source order; "<=" also covers copies whose
        // draw index belongs to the skipped window.
        while (
            !inShadowWindow &&
            nextEfbCopy < efbCopies.size() &&
            efbCopies[nextEfbCopy].drawIndex <= drawIndex
        ) {
            if (shadowWindow.eligible && (nextEfbCopy == shadowWindow.copyA || nextEfbCopy == shadowWindow.copyB)) {
                // A is never read (its only consumer, the restore, is skipped);
                // B is the side target itself. No blit, no pass split.
                if (nextEfbCopy == shadowWindow.copyB)
                    [efbTextures replaceObjectAtIndex:nextEfbCopy withObject:shadowTarget];
                ++nextEfbCopy;
                continue;
            }
            const LiveEfbCopy& copy = efbCopies[nextEfbCopy];
            if (
                copy.width == 0u ||
                copy.height == 0u ||
                (uint64_t)copy.sourceX + copy.width > logicalWidth ||
                (uint64_t)copy.sourceY + copy.height > logicalHeight
            ) {
                [encoder endEncoding];
                if (error) {
                    *error = LiveError(
                        12,
                        [NSString stringWithFormat:
                            @"invalid EFB copy %zu rect %u,%u %ux%u",
                            nextEfbCopy,
                            copy.sourceX,
                            copy.sourceY,
                            copy.width,
                            copy.height
                        ]
                    );
                }
                return NO;
            }
            [encoder endEncoding];
            MTLTextureDescriptor* copyDescriptor =
                [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:
                        MTLPixelFormatBGRA8Unorm
                    width:copy.width * renderScale
                    height:copy.height * renderScaleY
                    mipmapped:NO
                ];
            const BOOL proofShadow = self.motionProofRedraw && proofShadowTextures.count < 8 &&
                copy.command == 0x1000Bu && copy.width == 256 && copy.height == 256 &&
                copy.sourceX == 0 && copy.sourceY == 0 && copy.yScale == 256;
            copyDescriptor.storageMode = proofShadow ? MTLStorageModeShared : MTLStorageModePrivate;
            copyDescriptor.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> copyTexture = frameResources && !proofShadow ? [frameResources texture:copyDescriptor]
                : [self.device newTextureWithDescriptor:copyDescriptor];
            id<MTLBlitCommandEncoder> blit = passTiming
                ? [passTiming blitEncoder:commandBuffer kind:@"copy-blit"] : [commandBuffer blitCommandEncoder];
            if (!copyTexture || !blit) {
                if (blit) [blit endEncoding];
                if (error) {
                    *error = LiveError(13, @"EFB copy encoding failed");
                }
                return NO;
            }
            [blit copyFromTexture:target
                      sourceSlice:0u
                      sourceLevel:0u
                     sourceOrigin:MTLOriginMake(
                         copy.sourceX * renderScale,
                         copy.sourceY * renderScaleY,
                         0u
                     )
                       sourceSize:MTLSizeMake(
                           copy.width * renderScale,
                           copy.height * renderScaleY,
                           1u
                       )
                        toTexture:copyTexture
                 destinationSlice:0u
                 destinationLevel:0u
                destinationOrigin:MTLOriginMake(0u, 0u, 0u)];
            [blit endEncoding];
            [efbTextures replaceObjectAtIndex:nextEfbCopy
                                   withObject:copyTexture];
            if (proofShadow) proofShadowTextures[@(nextEfbCopy)] = copyTexture;
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            pass.depthAttachment.loadAction = MTLLoadActionLoad;
            [passTiming attachRender:pass kind:@"scene-resume"];
            encoder =
                [commandBuffer renderCommandEncoderWithDescriptor:pass];
            if (!encoder) {
                if (error) {
                    *error = LiveError(14, @"EFB copy resume failed");
                }
                return NO;
            }
            ++nextEfbCopy;
        }
        if (applySceneAntialias && drawIndex == sceneAntialias.index) {
            // The completed scene itself can be sampled while AA fills a new
            // target. This removes a full-resolution copy without changing the
            // shader, pixels, depth continuity or orthographic overlay order.
            [encoder endEncoding];
            id<MTLTexture> scene=target;
            if (self.renderTargetOptimizationsEnabled) {
                target=frameResources ? [frameResources texture:targetDescriptor]
                    : [self.device newTextureWithDescriptor:targetDescriptor];
                if (!target) {
                    if (error) *error=LiveError(27,@"Scene antialias target allocation failed.");
                    return NO;
                }
                pass.colorAttachments[0].texture=target;
                pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;
            } else {
            MTLTextureDescriptor* sceneDescriptor = [targetDescriptor copy];
            sceneDescriptor.storageMode = MTLStorageModePrivate;
            sceneDescriptor.usage = MTLTextureUsageShaderRead;
            scene = [self.device newTextureWithDescriptor:sceneDescriptor];
            id<MTLBlitCommandEncoder> blit = passTiming
                ? [passTiming blitEncoder:commandBuffer kind:@"antialias-snapshot"] : [commandBuffer blitCommandEncoder];
            if (!scene || !blit) {
                if (blit) [blit endEncoding];
                if (error) *error = LiveError(27, @"Scene antialias snapshot allocation failed.");
                return NO;
            }
            [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(target.width,target.height,1) toTexture:scene
                destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
            [blit endEncoding];
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            }
            pass.depthAttachment.loadAction = MTLLoadActionLoad;
            [passTiming attachRender:pass kind:@"antialias-overlay"];
            encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
            if (!encoder) {
                if (error) *error = LiveError(27, @"Scene antialias encoding failed.");
                return NO;
            }
            const float fullScreen[2] = {1,1};
            [encoder setRenderPipelineState:self.sceneAntialiasPipeline];
            [encoder setDepthStencilState:self.cinematicSurroundDepthState];
            [encoder setCullMode:MTLCullModeNone];
            [encoder setViewport:MTLViewport{0,0,(double)target.width,(double)target.height,0,1}];
            [encoder setVertexBytes:fullScreen length:sizeof(fullScreen) atIndex:0];
            [encoder setFragmentTexture:scene atIndex:0];
            [encoder setFragmentSamplerState:self.sampler atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        const LiveDraw& draw = draws[drawIndex];
        if (surround.enabled && (s32)drawIndex == cinematicDraw) {
            const float fullScreen[2] = {1,1};
            const float aperture[4] = {surround.scaleX,surround.scaleY,
                surround.frameAspect,(float)movieViewport.height};
            [encoder setRenderPipelineState:self.cinematicSurroundPipeline];
            [encoder setDepthStencilState:self.cinematicSurroundDepthState];
            [encoder setCullMode:MTLCullModeNone];
            [encoder setViewport:movieViewport];
            [encoder setVertexBytes:fullScreen length:sizeof(fullScreen) atIndex:0];
            [encoder setFragmentBytes:aperture length:sizeof(aperture) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        if (cinematicImage && (s32)drawIndex == cinematicDraw) {
            [encoder setRenderPipelineState:self.cinematicPipeline];
            [encoder setDepthStencilState:self.cinematicDepthState];
            [encoder setCullMode:MTLCullModeNone];
            [encoder setViewport:movieViewport];
            [encoder setVertexBuffer:frameVertices offset:vertexOffsets[drawIndex] atIndex:0];
            [encoder setFragmentTexture:cinematicImage.luma atIndex:0];
            [encoder setFragmentTexture:cinematicImage.chroma atIndex:1];
            [encoder setFragmentSamplerState:self.sampler atIndex:0];
            [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt32
                indexBuffer:frameVertices indexBufferOffset:indexOffsets[drawIndex]];
            sourceVertices += draw.sourceVertexCount;
            continue;
        }
        // EFB copies at this draw boundary have already executed. Do not
        // allocate any replacement texture for a proven no-write draw. Source
        // snapshots, guest timing, draw ordering and source counts stay intact.
        const auto* uploaded = reinterpret_cast<const LiveVertex*>(
            static_cast<const u8*>(frameVertices.contents) + vertexOffsets[drawIndex]);
        if (!self.disableNoWriteCulling && !backdropOffsets[drawIndex] &&
            !repeatingOffsets[drawIndex] && !hillOffsets[drawIndex] &&
            !canyonSkyOffsets[drawIndex] && !citySkyOffsets[drawIndex] &&
            !relatedCitySkyOffsets[drawIndex] &&
            ZeroAlphaPictureHasNoWrites(draw, uploaded, RenderVertices(draw, enhancedModels).size())) {
            ++noWriteCulledDraws;
            sourceVertices += draw.sourceVertexCount;
            continue;
        }
        std::array<id<MTLTexture>, 8> textures{};
        std::array<id<MTLTexture>, 8> mipTails{};
        std::array<u32, 8> tailFirstLevels{};
        std::array<id<MTLSamplerState>, 8> samplers;
        std::array<int, 8> efbCopyIndexes;
        efbCopyIndexes.fill(-1);
        const bool comboSymbols=(combo.enabled && !combo.actions[drawIndex].empty()) ||
            (upgrade.enabled && !upgrade.actions[drawIndex].empty());
        u32 shadowBorderMask = 0u;
        for (size_t stage = 0u; stage < textures.size(); ++stage) {
            const s32 candidateIndex = ExactEfbTextureCopyIndex(draw, stage, efbCopies, nextEfbCopy);
            if (candidateIndex >= 0 && efbTextures[(NSUInteger)candidateIndex] != NSNull.null) {
                textures[stage] = efbTextures[(NSUInteger)candidateIndex];
                efbCopyIndexes[stage] = candidateIndex;
            }
            BOOL restoredTexture = NO;
            if(comboSymbols && stage==0)textures[stage]=self.comboGlyphTexture;
            // Replace the whole verified color/coverage object together. The
            // old Wii silhouette must never mask the native Interact glyph.
            if(qte.replaces(drawIndex) && stage<2) {
                textures[stage]=stage?self.qteGlyphCoverage:self.qteGlyphColor;
                efbCopyIndexes[stage]=-1;
            }
            if (!textures[stage]) {
                id<MTLTexture> mipTail = nil;
                textures[stage] = [self textureForDraw:draw stage:stage
                    restored:&restoredTexture mipTail:&mipTail error:error];
                mipTails[stage] = mipTail;
            }
            if (!textures[stage]) {
                [encoder endEncoding];
                if (error && !*error) *error = LiveError(15, @"texture allocation failed");
                return NO;
            }
            const u32 mode = draw.textureModes[stage];
            const BOOL hybrid = mipTails[stage] != nil;
            tailFirstLevels[stage] = hybrid ? (u32)textures[stage].mipmapLevelCount : 0;
            // RBNEG9's shadow map: receivers compare their light distance with
            // the 256-square window (TEV compare mode). The window is cleared to
            // white ("no occluder"), but a silhouette that crosses its edge leaves
            // occluder texels there and clamping repeats them to the horizon.
            // Outside the window there is no occluder, so sample white there.
            const BOOL shadowWindowBorder = self.shadowBorderEnabled && stage < 4 && efbCopyIndexes[stage] >= 0 &&
                (mode & 0xFu) == 0u && ((draw.fragment.colorCombiners[stage] >> 16u) & 3u) == 3u &&
                efbCopies[(size_t)efbCopyIndexes[stage]].sourceX == 0 && efbCopies[(size_t)efbCopyIndexes[stage]].sourceY == 0 &&
                efbCopies[(size_t)efbCopyIndexes[stage]].width == 256 && efbCopies[(size_t)efbCopyIndexes[stage]].height == 256;
            if (shadowWindowBorder) { shadowBorderMask |= 1u << stage; self.shadowBorderSamples += 1; }
            NSNumber* samplerKey = @((mode & 0x9Fu) | (restoredTexture ? 0x100u : 0u));
            samplers[stage] = self.samplerCache[samplerKey];
            if (!samplers[stage]) {
                MTLSamplerDescriptor* samplerDescriptor = [[MTLSamplerDescriptor alloc] init];
                samplerDescriptor.sAddressMode = MetalAddressMode(mode & 3u);
                samplerDescriptor.tAddressMode = MetalAddressMode((mode >> 2u) & 3u);
                samplerDescriptor.magFilter = ((mode >> 4u) & 1u) != 0u
                    ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
                samplerDescriptor.minFilter = ((mode >> 7u) & 1u) != 0u
                    ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
                if (restoredTexture) {
                    samplerDescriptor.mipFilter = MTLSamplerMipFilterLinear;
                    samplerDescriptor.maxAnisotropy = 4u;
                }
                samplers[stage] = [self.device newSamplerStateWithDescriptor:samplerDescriptor];
                if (!samplers[stage]) {
                    [encoder endEncoding];
                    if (error) *error = LiveError(16, @"sampler allocation failed");
                    return NO;
                }
                self.samplerCache[samplerKey] = samplers[stage];
            }
        }
        const u32 destinationFactor = (draw.blendMode >> 5u) & 7u;
        if (self.motionProofRedraw && proofCopyConsumers.count < 128 &&
            std::any_of(efbCopyIndexes.begin(), efbCopyIndexes.end(), [](int index) { return index >= 0; })) {
            NSMutableArray* stages = [NSMutableArray array];
            const auto& submitted = RenderVertices(draw, enhancedModels);
            for (size_t stage = 0; stage < 8; ++stage) if (stage < draw.fragment.stageCount ||
                    (stage >= 4 && stage - 4 < draw.fragment.indirectCount)) {
                float uvBounds[4] = {INFINITY, INFINITY, -INFINITY, -INFINITY};
                for (const auto& vertex : submitted) {
                    const float* uv = stage < 4 ? vertex.uv[stage] : vertex.indirectUV[stage - 4];
                    uvBounds[0] = std::min(uvBounds[0], uv[0]); uvBounds[1] = std::min(uvBounds[1], uv[1]);
                    uvBounds[2] = std::max(uvBounds[2], uv[0]); uvBounds[3] = std::max(uvBounds[3], uv[1]);
                }
                if (submitted.empty()) std::fill(uvBounds, uvBounds + 4, 0);
                NSMutableArray* pixelSamples = [NSMutableArray array];
                const auto& sourcePixels = TexturePixels(draw, stage);
                for (size_t p = 0; p + 3 < sourcePixels.size() && p < 16; p += 4)
                    [pixelSamples addObject:@[@(sourcePixels[p]), @(sourcePixels[p+1]),
                        @(sourcePixels[p+2]), @(sourcePixels[p+3])]];
                [stages addObject:@{@"stage":@(stage), @"copy_index":@(efbCopyIndexes[stage]),
                    @"format":@(draw.textureFormats[stage]), @"address":@(draw.textureAddresses[stage]),
                    @"width":@(draw.textureWidths[stage]), @"height":@(draw.textureHeights[stage]),
                    @"source_pixel_samples":pixelSamples,
                    @"uv_bounds":@[@(uvBounds[0]), @(uvBounds[1]), @(uvBounds[2]), @(uvBounds[3])],
                    @"texture_dimensions":@[@(draw.fragment.textureDimensions[stage][0]),
                        @(draw.fragment.textureDimensions[stage][1]), @(draw.fragment.textureDimensions[stage][2]),
                        @(draw.fragment.textureDimensions[stage][3])],
                    @"color_combiner":@(stage < 4 ? draw.fragment.colorCombiners[stage] : 0),
                    @"alpha_combiner":@(stage < 4 ? draw.fragment.alphaCombiners[stage] : 0),
                    @"raster_source":@(stage < 4 ? draw.tevRasterSources[stage] : 0),
                    @"raster_alpha_channel":@(stage < 4 ? draw.fragment.rasterAlphaChannels[stage] : 0),
                    @"alpha_channel":@(stage < 4 ? draw.fragment.textureAlphaChannels[stage] : 0)}];
            }
            NSMutableArray* vertexSamples = [NSMutableArray array];
            for (size_t v = 0; v < std::min<size_t>(16, submitted.size()); ++v) {
                const auto& vertex = submitted[v];
                [vertexSamples addObject:@{@"clip":@[@(vertex.position[0]), @(vertex.position[1]),
                    @(vertex.position[2]), @(vertex.position[3])],
                    @"color":@[@(vertex.color[0]), @(vertex.color[1]), @(vertex.color[2]), @(vertex.color[3])],
                    @"uv0":@[@(vertex.uv[0][0]), @(vertex.uv[0][1])],
                    @"uv1":@[@(vertex.uv[1][0]), @(vertex.uv[1][1])]}];
            }
            NSMutableArray* xfChannels = [NSMutableArray array];
            for (u32 word : draw.xfChannelWords) [xfChannels addObject:@(word)];
            [proofCopyConsumers addObject:@{@"draw_index":@(drawIndex), @"stages":stages,
                @"xf_channel_words":xfChannels, @"num_color_channels":@(draw.numColorChannels),
                @"has_vertex_color":@(draw.hasVertexColor),
                @"alpha_test":@(draw.fragment.alphaTest),
                @"stage_count":@(draw.fragment.stageCount), @"indirect_count":@(draw.fragment.indirectCount),
                @"blend_mode":@(draw.blendMode), @"depth_mode":@(draw.depthMode),
                @"vertices":vertexSamples,
                @"color_registers":@[@[@(draw.fragment.colorRegisters[0][0]), @(draw.fragment.colorRegisters[0][1]),
                    @(draw.fragment.colorRegisters[0][2]), @(draw.fragment.colorRegisters[0][3])],
                    @[@(draw.fragment.colorRegisters[1][0]), @(draw.fragment.colorRegisters[1][1]),
                    @(draw.fragment.colorRegisters[1][2]), @(draw.fragment.colorRegisters[1][3])],
                    @[@(draw.fragment.colorRegisters[2][0]), @(draw.fragment.colorRegisters[2][1]),
                    @(draw.fragment.colorRegisters[2][2]), @(draw.fragment.colorRegisters[2][3])]],
                @"viewport":@[@(draw.viewportX), @(draw.viewportY), @(draw.viewportWidth), @(draw.viewportHeight)]}];
        }
        const u32 sourceFactor = (draw.blendMode >> 8u) & 7u;
        const bool blendEnabled = (draw.blendMode & 1u) != 0u;
        // GX ONE/ZERO is replacement, identical to disabled blending. The
        // original publisher-logo transition uses this (BP 0x41 = 0x00011D).
        const bool replaceBlend = sourceFactor == 1u && destinationFactor == 0u;
        const NSUInteger blendKind = blendEnabled && (draw.blendMode & (1u << 11u)) != 0u
            ? 4u : !blendEnabled || replaceBlend ? 0u : destinationFactor == 1u
            ? (sourceFactor == 1u ? 3u : 2u) : 1u;
        const u32 directStages = self.shaderSpecializationEnabled ? DirectShaderStages(draw.fragment) : 0;
        id<MTLRenderPipelineState> pipeline = directStages ? self.directPipelines[@(directStages)][blendKind] : nil;
        if (shadingSummary) {
            const double area = DrawShadedArea(draw, RenderVertices(draw, enhancedModels), renderScale, renderScaleY);
            if (pipeline) specializedArea += area;
            else {
                generalArea += area;
                NSString* signature = GeneralShaderSignature(draw.fragment, blendKind);
                generalAreas[signature] = @(generalAreas[signature].doubleValue + area);
                generalCounts[signature] = @(generalCounts[signature].unsignedIntegerValue + 1);
            }
        }
        if (pipeline) ++specializedDraws;
        else pipeline = blendKind == 4 ? self.subtractPipeline : blendKind == 0 ? self.opaquePipeline
            : blendKind == 3 ? self.oneOnePipeline : blendKind == 2 ? self.additivePipeline : self.alphaPipeline;
        [encoder setRenderPipelineState:pipeline];
        NSNumber* depthKey = @(draw.depthMode & 0x1Fu);
        id<MTLDepthStencilState> depthState = self.depthCache[depthKey];
        if (!depthState) {
            MTLDepthStencilDescriptor* depthStateDescriptor = [[MTLDepthStencilDescriptor alloc] init];
            depthStateDescriptor.depthCompareFunction = (draw.depthMode & 1u) != 0u
                ? MetalCompareFunction((draw.depthMode >> 1u) & 7u) : MTLCompareFunctionAlways;
            depthStateDescriptor.depthWriteEnabled = ((draw.depthMode >> 4u) & 1u) != 0u;
            depthState = [self.device newDepthStencilStateWithDescriptor:depthStateDescriptor];
            if (!depthState) {
                [encoder endEncoding];
                if (error) *error = LiveError(17, @"depth state allocation failed");
                return NO;
            }
            self.depthCache[depthKey] = depthState;
        }
        [encoder setDepthStencilState:depthState];
        [encoder setFrontFacingWinding:MTLWindingClockwise];
        // BP GenMode uses the hardware encoding: 1 culls back faces and 2
        // culls front faces (the public GX enum values are bit-swapped).
        [encoder setCullMode:
            draw.cullMode == 1u
                ? MTLCullModeBack
                : draw.cullMode == 2u
                    ? MTLCullModeFront
                    : MTLCullModeNone
        ];
        const MTLViewport viewport = {
            draw.viewportX * renderScale,
            draw.viewportY * renderScaleY,
            draw.viewportWidth * renderScale,
            draw.viewportHeight * renderScaleY,
            0.0,
            1.0,
        };
        [encoder setViewport:viewport];
        [encoder setVertexBuffer:frameVertices
                          offset:RenderVertices(draw, enhancedModels).empty() ? 0u : vertexOffsets[drawIndex]
                         atIndex:0];
        for (NSUInteger slot = 0; slot < textures.size(); ++slot) {
            [encoder setFragmentTexture:textures[slot] atIndex:slot];
            [encoder setFragmentTexture:mipTails[slot] ? mipTails[slot] : textures[slot] atIndex:slot + 8];
            [encoder setFragmentSamplerState:samplers[slot] atIndex:slot];
        }
        LiveFragmentUniforms fragment = draw.fragment;
        fragment.shadowBorderMask = shadowBorderMask;
        [encoder setFragmentBytes:&fragment length:sizeof(fragment) atIndex:0];
        [encoder setFragmentBytes:tailFirstLevels.data() length:sizeof(tailFirstLevels) atIndex:1];
        if (RenderIndexed(draw, enhancedModels)) {
            if (!RenderIndices(draw, enhancedModels).empty()) [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                indexCount:RenderIndices(draw, enhancedModels).size() indexType:MTLIndexTypeUInt32
                indexBuffer:frameVertices indexBufferOffset:indexOffsets[drawIndex]];
        } else {
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:RenderVertices(draw, enhancedModels).size()];
        }
        if (backdropOffsets[drawIndex]) {
            [encoder setVertexBuffer:frameVertices offset:backdropOffsets[drawIndex] atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }
        if (repeatingOffsets[drawIndex]) {
            [encoder setVertexBuffer:frameVertices offset:repeatingOffsets[drawIndex] atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
        }
        if (hillOffsets[drawIndex]) {
            [encoder setVertexBuffer:frameVertices offset:hillOffsets[drawIndex] atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
        }
        if (canyonSkyOffsets[drawIndex]) {
            [encoder setVertexBuffer:frameVertices offset:canyonSkyOffsets[drawIndex] atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }
        if (citySkyOffsets[drawIndex]) {
            [encoder setVertexBuffer:frameVertices offset:citySkyOffsets[drawIndex] atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:18];
        }
        if (relatedCitySkyOffsets[drawIndex]) {
            [encoder setVertexBuffer:frameVertices offset:relatedCitySkyOffsets[drawIndex] atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:relatedCitySkyPieces[drawIndex].size()];
        }
        sourceVertices += draw.sourceVertexCount;

        if (self.continuousPresentation && !self.sceneEdgeRedraw) {
            continue;
        }

        double minScreenX = std::numeric_limits<double>::infinity();
        double minScreenY = std::numeric_limits<double>::infinity();
        double maxScreenX = -std::numeric_limits<double>::infinity();
        double maxScreenY = -std::numeric_limits<double>::infinity();
        double averageColor[4] = {};
        for (size_t index = 0; index < SubmittedVertexCount(draw, enhancedModels); ++index) {
            const LiveVertex& vertex = SubmittedVertex(draw, index, enhancedModels);
            if (std::abs(vertex.position[3]) > 1e-12f) {
                const double ndcX =
                    vertex.position[0] / vertex.position[3];
                const double ndcY =
                    vertex.position[1] / vertex.position[3];
                const double screenX =
                    draw.viewportX + (ndcX + 1.0) *
                        draw.viewportWidth * 0.5;
                const double screenY =
                    draw.viewportY + (1.0 - ndcY) *
                        draw.viewportHeight * 0.5;
                minScreenX = std::min(minScreenX, screenX);
                minScreenY = std::min(minScreenY, screenY);
                maxScreenX = std::max(maxScreenX, screenX);
                maxScreenY = std::max(maxScreenY, screenY);
            }
            for (u32 component = 0u; component < 4u; ++component) {
                averageColor[component] += vertex.color[component];
            }
        }
        if (SubmittedVertexCount(draw, enhancedModels) != 0) {
            for (double& component : averageColor) {
                component /= SubmittedVertexCount(draw, enhancedModels);
            }
        }
        if (!std::isfinite(minScreenX)) {
            minScreenX = minScreenY = maxScreenX = maxScreenY = 0.0;
        }
        NSMutableArray<NSDictionary*>* textureDiagnostics =
            [NSMutableArray arrayWithCapacity:draw.fragment.stageCount];
        for (
            u32 stage = 0u;
            stage < 8u;
            ++stage
        ) {
            if ((stage < 4u && stage >= draw.fragment.stageCount) ||
                (stage >= 4u && stage - 4u >= draw.fragment.indirectCount)) continue;
            const std::vector<u8>& pixels = TexturePixels(draw, stage);
            float uvBounds[4] = {INFINITY, INFINITY, -INFINITY, -INFINITY};
            for (size_t index = 0; index < SubmittedVertexCount(draw, enhancedModels); ++index) {
                const LiveVertex& vertex = SubmittedVertex(draw, index, enhancedModels);
                const float* uv = stage < 4u ? vertex.uv[stage] : vertex.indirectUV[stage - 4u];
                uvBounds[0] = std::min(uvBounds[0], uv[0]);
                uvBounds[1] = std::min(uvBounds[1], uv[1]);
                uvBounds[2] = std::max(uvBounds[2], uv[0]);
                uvBounds[3] = std::max(uvBounds[3], uv[1]);
            }
            if (getenv("PROTECTOR_METAL_DUMP_TEXTURES")) {
                NSURL* textureOutput = [self.outputDirectory URLByAppendingPathComponent:
                    [NSString stringWithFormat:@"frame-%04u-draw-%zu-stage-%u.rgba",
                        frameIndex, drawIndex, stage]];
                NSData* data = [NSData dataWithBytes:pixels.data() length:pixels.size()];
                if (![data writeToURL:textureOutput options:NSDataWritingAtomic error:error]) {
                    return NO;
                }
            }
            double averageTexture[4] = {};
            for (size_t pixel = 0u; pixel + 3u < pixels.size(); pixel += 4u) {
                for (u32 component = 0u; component < 4u; ++component) {
                    averageTexture[component] += pixels[pixel + component];
                }
            }
            const double pixelCount = pixels.size() / 4u;
            if (pixelCount > 0.0) {
                for (double& component : averageTexture) {
                    component /= pixelCount * 255.0;
                }
            }
            [textureDiagnostics addObject:@{
                @"stage" : @(stage),
                @"unit" : @(draw.textureUnits[stage]),
                @"coordinate" : @(draw.textureCoordinates[stage]),
                @"width" : @(draw.textureWidths[stage]),
                @"height" : @(draw.textureHeights[stage]),
                @"format" : @(draw.textureFormats[stage]),
                @"image1" : @(draw.textureImage1[stage]),
                @"image2" : @(draw.textureImage2[stage]),
                @"indirect_command" : @(stage < 4u ? draw.indirectCommands[stage] : 0u),
                @"coordinate_scale" : @[@(draw.fragment.textureDimensions[stage][2]),
                                         @(draw.fragment.textureDimensions[stage][3])],
                @"uv_bounds" : @[@(uvBounds[0]), @(uvBounds[1]),
                                @(uvBounds[2]), @(uvBounds[3])],
                @"texgen_q_captured" : @(draw.textureQCaptured[stage]),
                @"texgen_info" : @(draw.textureGenerationInfo[stage]),
                @"texgen_q_bounds" : draw.textureQCaptured[stage] ?
                    @[@(draw.textureQBounds[stage][0]), @(draw.textureQBounds[stage][1])] : (id)NSNull.null,
                @"address" : [NSString stringWithFormat:
                    @"0x%08X", draw.textureAddresses[stage]
                ],
                @"efb_copy_index" : @(efbCopyIndexes[stage]),
                @"mode" : @(draw.textureModes[stage]),
                @"average_rgba" : @[
                    @(averageTexture[0]),
                    @(averageTexture[1]),
                    @(averageTexture[2]),
                    @(averageTexture[3]),
                ],
                @"color_combiner" : @(
                    stage < 4u ? draw.fragment.colorCombiners[stage] : 0u
                ),
                @"alpha_combiner" : @(
                    stage < 4u ? draw.fragment.alphaCombiners[stage] : 0u
                ),
            }];
        }
        [drawDiagnostics addObject:@{
            @"index" : @(drawIndex),
            @"display_list_depth" : @(draw.displayListDepth),
            @"source_vertex_count" : @(draw.sourceVertexCount),
            @"metal_vertex_count" : @(SubmittedVertexCount(draw, enhancedModels)),
            @"has_normal" : @(draw.hasNormal),
            @"has_vertex_color" : @(draw.hasVertexColor),
            @"num_color_channels" : @(draw.numColorChannels),
            @"num_texture_generators" : @(draw.numTextureGenerators),
            @"ambient_color" : @(draw.ambientColor),
            @"material_color" : @(draw.materialColor),
            @"color_channel" : @(draw.colorChannel),
            @"alpha_channel" : @(draw.alphaChannel),
            @"blend_mode" : @(draw.blendMode),
            @"depth_mode" : @(draw.depthMode),
            @"cull_mode" : @(draw.cullMode),
            @"tev_stage_count" : @(draw.fragment.stageCount),
            @"indirect_stage_count" : @(draw.fragment.indirectCount),
            @"viewport" : @[@(draw.viewportX), @(draw.viewportY),
                            @(draw.viewportWidth), @(draw.viewportHeight)],
            @"color_registers" : @[
                @[@(draw.fragment.colorRegisters[0][0]), @(draw.fragment.colorRegisters[0][1]),
                  @(draw.fragment.colorRegisters[0][2]), @(draw.fragment.colorRegisters[0][3])],
                @[@(draw.fragment.colorRegisters[1][0]), @(draw.fragment.colorRegisters[1][1]),
                  @(draw.fragment.colorRegisters[1][2]), @(draw.fragment.colorRegisters[1][3])],
                @[@(draw.fragment.colorRegisters[2][0]), @(draw.fragment.colorRegisters[2][1]),
                  @(draw.fragment.colorRegisters[2][2]), @(draw.fragment.colorRegisters[2][3])]
            ],
            @"average_vertex_rgba" : @[
                @(averageColor[0]),
                @(averageColor[1]),
                @(averageColor[2]),
                @(averageColor[3]),
            ],
            @"screen_bounds" : @[
                @(minScreenX),
                @(minScreenY),
                @(maxScreenX),
                @(maxScreenY),
            ],
            @"textures" : textureDiagnostics,
        }];
    }
    // Depth must survive intermediate EFB/AA passes, but nothing reads it
    // after the final scene/HUD pass. Do not store the discarded final depth.
    if (self.renderTargetOptimizationsEnabled) [encoder setDepthStoreAction:MTLStoreActionDontCare];
    [encoder endEncoding];
    // A display copy selects the part of the EFB actually sent to the TV.
    // Keep raw EFB proof PNGs unchanged; live presentation and its snapshots
    // use this source-owned rectangle instead of showing unused EFB rows.
    id<MTLTexture> presentation = nil;
    for (const LiveEfbCopy& copy : efbCopies) {
        if ((copy.command & (1u << 14u)) == 0u) continue;
        if (copy.drawIndex != draws.size() || copy.yScale != 256u ||
            ((copy.command >> 12u) & 3u) != 0u ||
            ((copy.command >> 7u) & 3u) != 0u ||
            copy.width == 0u || copy.height == 0u ||
            (uint64_t)copy.sourceX + copy.width > logicalWidth ||
            (uint64_t)copy.sourceY + copy.height > logicalHeight) {
            if (error) *error = LiveError(23,
                @"unsupported display copy timing, scale, field, gamma or rectangle");
            return NO;
        }
        MTLTextureDescriptor* displayDescriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:copy.width * renderScale height:copy.height * renderScaleY mipmapped:NO];
        displayDescriptor.storageMode = privateLiveTargets ? MTLStorageModePrivate : MTLStorageModeShared;
        displayDescriptor.usage = MTLTextureUsageShaderRead;
        presentation = frameResources ? [frameResources texture:displayDescriptor]
            : [self.device newTextureWithDescriptor:displayDescriptor];
        id<MTLBlitCommandEncoder> displayBlit = passTiming
            ? [passTiming blitEncoder:commandBuffer kind:@"display-copy"] : [commandBuffer blitCommandEncoder];
        if (!presentation || !displayBlit) {
            if (error) *error = LiveError(24, @"display copy allocation failed");
            return NO;
        }
        [displayBlit copyFromTexture:target sourceSlice:0 sourceLevel:0
            sourceOrigin:MTLOriginMake(copy.sourceX * renderScale, copy.sourceY * renderScaleY, 0)
            sourceSize:MTLSizeMake(copy.width * renderScale, copy.height * renderScaleY, 1)
            toTexture:presentation destinationSlice:0 destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [displayBlit endEncoding];
    }
    // Only the live drawable path overlaps CPU preparation and GPU execution.
    // Proofs, paused configuration transactions and CV-backed movie frames keep
    // synchronous completion. Each output texture is immutable after submission.
    const BOOL asynchronous = self.asynchronousPresentationRender && !self.presentationPaused &&
        !self.synchronizeNextLiveRender && !cinematicImage;
    if (asynchronous) {
        __weak ProtectorLiveMetalRenderer* renderer = self;
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            // No renderer lock here: snapshots may wait for this command.
            // One failed frame is dropped, not fatal: a command caught by
            // backgrounding (NotPermitted) is expected, and only repeated
            // consecutive failures end the session.
            ProtectorLiveMetalRenderer* owner = renderer;
            if (!owner) return;
            if (completed.status == MTLCommandBufferStatusError) {
                const BOOL background = completed.error.code == MTLCommandBufferErrorNotPermitted;
                if (!background && ++owner->_consecutiveGPUFailures >= 4)
                    owner.failure = completed.error ? completed.error : LiveError(11, @"Live render command failed.");
            } else owner->_consecutiveGPUFailures = 0;
            const double gpu = completed.GPUEndTime - completed.GPUStartTime;
            if (std::isfinite(gpu) && gpu > 0 && gpu < 1) {
                const double previous = owner.smoothedGPUSeconds;
                owner.smoothedGPUSeconds = previous > 0 ? previous * 0.9 + gpu * 0.1 : gpu;
            }
        }];
    }
    if (frameResources) {
        // The completed command releases its hold; "latest" holds the other.
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            (void)completed; (void)frameResources;
        }];
    }
    const double encodedAt = renderStart ? CACurrentMediaTime() : 0;
    const BOOL deferred = asynchronous && self.deferPresentationCommit;
    if (deferred) self.pendingPresentationCommand = commandBuffer;
    else [commandBuffer commit];
    if (!asynchronous) [commandBuffer waitUntilCompleted];
    if (renderStart) {
        // Opt-in diagnostics only. GPU work and synchronous host wait overlap;
        // do not add these durations or treat either as display cadence.
        self.lastRenderCost = @{@"frame_index":@(frameIndex), @"render_scale":@(renderScale), @"render_scale_y":@(renderScaleY), @"asynchronous":@(asynchronous), @"combined_presentation":@(deferred),
            @"encode_seconds":@(encodedAt-renderStart),
            @"shading":shadingSummary ? ShadingSummary(specializedArea, generalArea, generalAreas, generalCounts,
                (double)target.width * target.height) : (id)NSNull.null,
            @"submit_wait_seconds":@(CACurrentMediaTime()-encodedAt),
            @"gpu_seconds":@(commandBuffer.GPUEndTime-commandBuffer.GPUStartTime)};
    }
    if (commandBuffer.status == MTLCommandBufferStatusError) {
        if (error) {
            *error = commandBuffer.error;
        }
        return NO;
    }
    self.latestRenderCommand = commandBuffer;
    self.latestPassTiming = passTiming;
    // Resume has no preceding live GPU work to overlap. Complete its first
    // scene before queuing a drawable so an immediate second submission cannot
    // displace that first picture while its render is still pending.
    if (self.asynchronousPresentationRender && !self.presentationPaused)
        self.synchronizeNextLiveRender = NO;
    self.latestTexture = target;
    self.cinematicFrame = cinematic;
    self.renderScale = renderScale;
    self.renderScaleY = renderScaleY;
    self.qteTargetRect=QTENativeTargetRect(qte,frameAspect);
    self.qtePrompts=qte.prompts;
    self.qtePointerActive=qte.cursorDraws || qte.targetDraws || qte.feedbackDraws;
    self.latestPresentationTexture = presentation;
    self.latestFrameResources = frameResources;
    self.motionProofShadowTextures = proofShadowTextures;
    self.motionProofCopyConsumers = proofCopyConsumers;
    if (self.continuousPresentation) {
        if (!self.artworkPreviewRedraw && !self.resolutionPreviewRedraw && !self.aspectPreviewRedraw &&
            !self.geometryPreviewRedraw && !self.motionProofRedraw && !self.motionSettingRedraw &&
            !self.nativeViewportRedraw && !self.sceneEdgeRedraw)
            self.renderedFrameCount++;
        const DecoderStatsSnapshot decoderStats = _decoderStats;
        // Opt-in source evidence for camera/HUD upgrades. Never infer aspect
        // from the SC settings flag or stretch a frame based on that flag.
        NSMutableArray* projectionProfiles = [NSMutableArray array];
        NSUInteger omittedProjectionDraws = 0;
        if (self.projectionDiagnosticsEnabled) {
            std::map<std::array<u32, 7>, std::pair<size_t, size_t>> profiles;
            for (const LiveDraw& draw : draws) {
                auto entry = profiles.find(draw.projectionWords);
                if (entry == profiles.end() && profiles.size() >= 16) {
                    ++omittedProjectionDraws;
                    continue;
                }
                auto& counts = profiles[draw.projectionWords];
                ++counts.first;
                counts.second += SubmittedVertexCount(draw, enhancedModels);
            }
            for (const auto& profile : profiles) {
                NSMutableArray* words = [NSMutableArray arrayWithCapacity:7];
                for (u32 word : profile.first) [words addObject:@(word)];
                [projectionProfiles addObject:@{@"xf_words": words,
                    @"draw_count": @(profile.second.first),
                    @"submitted_vertices": @(profile.second.second)}];
            }
        }
        NSMutableArray* frontendProfiles = [NSMutableArray array];
        for (int profile : frontend.observedProfiles) [frontendProfiles addObject:@(profile)];
        [self publishStateCapture:@{
            @"schema" : @"protector-native.interactive-metal/v1",
            @"source" : @"translated_execution_callback",
            @"external_scene_pack" : @NO,
            @"device" : self.device.name,
            @"frame_index" : @(frameIndex),
            @"rendered_frame_count" : @(self.renderedFrameCount),
            @"draw_count" : @(draws.size()),
            @"shader_specialization":@{@"enabled":@(self.shaderSpecializationEnabled),
                @"specialized_draws":@(specializedDraws),@"compiled_variants":@10,
                @"runtime_compilation":@NO},
            @"thermal_state":@(NSProcessInfo.processInfo.thermalState),
            @"render_target_optimizations":@{@"enabled":@(self.renderTargetOptimizationsEnabled),
                @"private_live_targets":@(privateLiveTargets),
                @"scene_snapshot_copy_elided":@(applySceneAntialias && self.renderTargetOptimizationsEnabled),
                @"final_depth_store_elided":@(self.renderTargetOptimizationsEnabled)},
            @"performance_capture_file":self.performanceCaptureFilename ? self.performanceCaptureFilename : (id)NSNull.null,
            @"scene_antialias":@{@"requested":@(self.sceneAntialiasEnabled),
                @"applied":@(applySceneAntialias),@"boundary_draw":@(sceneAntialias.index),
                @"admission":@(sceneAntialias.reason),@"method":@"bounded-edge-only-v1",
                @"temporary_bytes":@(applySceneAntialias ? target.width*target.height*4 : 0)},
            @"native_qte":@{@"prompts":@(qte.prompts),@"motion_draws":@(qte.motionDraws),
                @"target_rect":CGRectIsNull(self.qteTargetRect)?(id)NSNull.null:
                    @[@(self.qteTargetRect.origin.x),@(self.qteTargetRect.origin.y),
                        @(self.qteTargetRect.size.width),@(self.qteTargetRect.size.height)],
                @"target_draws":@(qte.targetDraws),@"cursor_draws":@(qte.cursorDraws),
                @"feedback_draws":@(qte.feedbackDraws),@"guest_mutation":@NO,
                @"glyph_bytes":@(self.qteGlyphColor && self.qteGlyphCoverage ? 2*512*512*4 : 0)},
            @"source_cinematic" : CinematicReceipt(cinematic,cinematicImage),
            @"cinematic_pack" : self.cinematicPack ? [self.cinematicPack diagnostics] : NSNull.null,
            @"cinematic_draw_index" : @(cinematicDraw),
            @"cinematic_surround" : @{@"visible":@(surround.enabled),@"style":@"omnitrix-kit-v1",
                @"protected_scale":@[@(surround.scaleX),@(surround.scaleY)],
                @"film_aspect":@(surround.filmAspect),@"animated":@NO},
            @"projection_audit_enabled" : @(self.projectionDiagnosticsEnabled),
            @"projection_profiles" : projectionProfiles,
            @"projection_audit_omitted_draws" : @(omittedProjectionDraws),
            @"motion_correspondence_audit" : self.motionAuditState ? self.motionAuditState : NSNull.null,
            @"motion_audit_logged_frames" : @(self.motionAuditFrames),
            @"source_vertex_count" : @(sourceVertices),
            @"presentation_width" : @(presentation ? presentation.width : target.width),
            @"presentation_height" : @(presentation ? presentation.height : target.height),
            @"presentation_aspect" : nativeViewport ? @"native-landscape" : widescreen ? @"16:9" : @"4:3",
            @"presentation_aspect_ratio" : @(frameAspect),
            @"widescreen_enabled" : @(widescreen),
            @"widescreen_scene_draws" : @(wideSceneDraws),
            @"widescreen_safe_area_draws" : @(wideSafeAreaDraws),
            @"widescreen_screen_fills" : @(wideScreenFills),
            @"wide_frame" : wideFrameReceipt,
            @"resource_pool" : @{@"pooled":@(self.resourcePool.pooledCount), @"reused":@(self.resourcePool.reuseCount)},
            @"texture_pack_loading" : self.texturePack ? [self.texturePack loadingDiagnostics] : (id)NSNull.null,
            @"shadow_window" : @{@"elided":@(shadowWindow.eligible), @"reason":@(shadowWindow.reason),
                @"elided_frames":@(self.shadowWindowsElided), @"border_enabled":@(self.shadowBorderEnabled),
                @"border_samples":@(self.shadowBorderSamples)},
            @"low_power_mode" : @(NSProcessInfo.processInfo.lowPowerModeEnabled),
            @"performance_capture_ring" : self.performanceRing ? [self.performanceRing receipt] : (id)NSNull.null,
            @"presentation_transitions" : @{@"enabled":@(self.presentationTransitionAuditEnabled),
                @"events":@(self.presentationTransitionEvents), @"audits":@(self.presentationTransitionAudits),
                @"session":self.presentationTransitionSession ? self.presentationTransitionSession : (id)NSNull.null,
                @"audit_slots":@6, @"audit_spacing_seconds":@2,
                @"audits_rate_limited":@(self.presentationTransitionAuditsSuppressed),
                @"write_failures":@(self.presentationTransitionWriteFailures),
                @"log_files":self.presentationTransitionLogName ? @[
                    [self.presentationTransitionLogName stringByAppendingString:@"-ring0.jsonl"],
                    [self.presentationTransitionLogName stringByAppendingString:@"-ring1.jsonl"]] : (id)NSNull.null,
                @"last":self.lastPresentationTransition ? self.lastPresentationTransition : (id)NSNull.null},
            @"hud_safe_area_aspect" : nativeHud.count ? @"native-safe-area" : @"4:3",
            @"native_hud_draws" : @(nativeHud.count),
            @"native_hud_rejected_frames" : @(self.hudRejectedFrames),
            @"native_hud_last_rejected_frame" : @(self.hudLastRejectedFrame),
            @"native_hud_role_counts" : @[@(nativeHud.roleCounts[0]), @(nativeHud.roleCounts[1]),
                @(nativeHud.roleCounts[2]), @(nativeHud.roleCounts[3]), @(nativeHud.roleCounts[4]), @(nativeHud.roleCounts[5])],
            @"native_hud_detail" : @{@"partial":@(nativeHud.partial), @"soft_draws":@(nativeHud.softDraws),
                @"contained":@(nativeHud.contained), @"foreign":@(nativeHud.foreign),
                @"lost_events":@(self.hudLostEvents), @"carried_frames":@(self.hudCarriedFrames)},
            @"native_hud_admission" : nativeViewport ? @(nativeHud.reason) : @"disabled",
            @"world_map_ocean_underlay" : @(worldMap),
            @"native_map_detail_backdrop" : @{@"enabled":@(mapDetailBackdrop.enabled),
                @"scale":@(mapDetailBackdrop.scale),@"offset_x":@(mapDetailBackdrop.offsetX),
                @"offset_y":@(mapDetailBackdrop.offsetY),@"source_vertices_immutable":@YES},
            @"native_world_map_layout" : @{@"enabled":@(mapPlan.enabled),@"admission":@(mapLayout.reason),
                @"country":@(mapLayout.country),
                @"region":@(mapLayout.region),@"selected_ordinal":@(mapLayout.selected),
                @"card_scale":@(mapPlan.cardScale),@"help_count":@(mapLayout.hintCount),
                @"title_frame":MapRectArray(mapPlan.title),@"cards_frame":MapRectArray(mapPlan.cards),
                @"help_frame":MapRectArray(mapPlan.hints),@"source_vertices_immutable":@YES},
            @"native_frontend_layout" : @{@"enabled":@(frontend.enabled),
                @"observed_profiles":frontendProfiles,
                @"admission":@(frontend.reason),@"menu":@(frontend.menu),
                @"secondary":@(frontend.secondary),@"panel_center":@(frontend.panelCenter),
                @"draws":@(frontend.enabled ? frontend.roles.size() : 0),
                @"source_vertices_immutable":@YES,@"background_treatment":@"uniform-cover"},
            @"world_map_ocean_rgba" : @[@(background.red), @(background.green), @(background.blue), @(background.alpha)],
            @"native_shared_panel_layout" : @{@"enabled":@(sharedPanel.enabled),
                @"admission":@(sharedPanel.reason),@"draws":@(sharedPanel.enabled ? 3 : 0),
                @"source_vertices_immutable":@YES,@"corner_treatment":@"proportional-translation"},
            @"native_gallery_layout" : @{@"enabled":@(galleryLayout.enabled),
                @"extras_movie":@(galleryLayout.extrasMovie),
                @"admission":@(galleryLayout.reason),@"gallery":@(galleryLayout.gallery),
                @"extras_browser":@(galleryLayout.extrasBrowser),
                @"extras_full_view":@(galleryLayout.extrasFullView),
                @"extras_options":@(galleryLayout.extrasOptions),
                @"first_draw":@(galleryLayout.first),@"panel_center":@(galleryLayout.panelCenter),
                @"draws":@(galleryLayout.enabled ? (galleryLayout.gallery || galleryLayout.extrasBrowser || galleryLayout.extrasOptions) ? 10 : 20 : 0),
                @"source_vertices_immutable":@YES,@"art_canvases_unchanged":@YES},
            @"native_gallery_model_frame" : GalleryModelFrameReceipt(draws,galleryModelFrame,frameAspect),
            @"native_combo_list" : @{@"enabled":@(combo.enabled),@"layout_enabled":@(comboLayout),
                @"admission":@(combo.reason),@"scheme":@(combo.scheme),@"first_draw":@(combo.first),
                @"glyphs":@(combo.glyphCount),@"navigation_glyphs":@(combo.enabled?2:0),
                @"source_vertices_immutable":@YES,@"source_textures_immutable":@YES,
                @"frame_points":@[@(self.nativeComboFrame.origin.x),@(self.nativeComboFrame.origin.y),
                    @(self.nativeComboFrame.size.width),@(self.nativeComboFrame.size.height)]},
            @"native_presentation_points" : @[@(self.nativePresentationSize.width), @(self.nativePresentationSize.height)],
            @"native_upgrade_menu" : @{@"enabled":@(upgrade.enabled),@"layout_enabled":@(upgradeLayout),
                @"admission":@(upgrade.reason),@"scheme":@(upgrade.scheme),@"ready":@(upgrade.ready),
                @"first_draw":@(upgrade.first),@"glyphs":@(upgrade.glyphCount),
                @"source_vertices_immutable":@YES,@"source_textures_immutable":@YES,
                @"frame_points":@[@(self.nativeUpgradeFrame.origin.x),@(self.nativeUpgradeFrame.origin.y),
                    @(self.nativeUpgradeFrame.size.width),@(self.nativeUpgradeFrame.size.height)]},
            @"native_combat_feedback" : @{@"enabled":@(combatFeedback.enabled),@"layout_enabled":@(combatFeedbackLayout),
                @"admission":@(combatFeedback.reason),@"label_draw":@(combatFeedback.label),@"number_draw":@(combatFeedback.number),
                @"count":@(combatFeedback.count),@"source_vertices_immutable":@YES,@"source_textures_immutable":@YES,
                @"frame_points":@[@(self.nativeCombatFeedbackFrame.origin.x),@(self.nativeCombatFeedbackFrame.origin.y),
                    @(self.nativeCombatFeedbackFrame.size.width),@(self.nativeCombatFeedbackFrame.size.height)]},
            @"native_move_labels" : @{@"count":@(combatMoves.count),@"admission":@(combatMoves.reason),
                @"first_draw":@(combatMoves.count?combatMoves.indices[0]:0),
                @"second_draw":@(combatMoves.count>1?combatMoves.indices[1]:0),
                @"source_vertices_immutable":@YES,@"source_textures_immutable":@YES},
            @"native_hud_frame_points" : @[@(self.nativeHudFrame.origin.x), @(self.nativeHudFrame.origin.y),
                @(self.nativeHudFrame.size.width), @(self.nativeHudFrame.size.height)],
            @"native_viewport_redraw_count" : @(self.nativeViewportRedrawCount),
            @"finite_backdrop_draws" : @(finiteBackdropDraws),
            @"finite_backdrop_extensions" : @(backdropVertices.size() / 6),
            @"repeating_backdrop_cohort" : @(repeatingCohort),
            @"repeating_backdrop_extensions" : @(repeatingVertices.size() / 12),
            @"hill_backdrop_cohort" : @(hillCohort),
            @"hill_backdrop_extensions" : @(hillVertices.size()/12),
            @"canyon_sky_cohort" : @(canyonSkyCohort),
            @"canyon_sky_extensions" : @(canyonSkyVertices.size()/6),
            @"city_sky_cohort" : @(citySkyCohort),
            @"city_sky_extensions" : @(citySkyVertices.size()/6),
            @"related_city_sky_cohort" : @(relatedCitySkyCohort),
            @"related_city_sky_extensions" : @(relatedCitySkyVertices.size()/6),
            @"finite_room_frame" : @{@"enabled":@(finiteRoomFrame.enabled),
                @"bias_ndc":@(finiteRoomFrame.bias),@"anchor_x_ndc":@(finiteRoomFrame.anchorX),
                @"reason":@(finiteRoomFrame.reason),@"source_vertices_immutable":@YES,
                @"guest_camera_unchanged":@YES,@"static_visibility_aspect":@(PROTECTOR_MAX_PRESENTATION_ASPECT)},
            @"aspect_preview_redraw_count" : @(self.aspectPreviewRedrawCount),
            @"last_presentation_was_aspect_preview" : @(self.aspectPreviewRedraw),
            @"render_scale" : @(renderScale),
            @"render_scale_y" : @(renderScaleY),
            @"native_resolution_enabled" : @(self.nativeResolutionEnabled),
            @"native_render_pixel_size" : @[@(self.nativeRenderPixelSize.width), @(self.nativeRenderPixelSize.height)],
            @"efb_width" : @(target.width),
            @"efb_height" : @(target.height),
            @"logical_efb_width" : @(logicalWidth),
            @"logical_efb_height" : @(logicalHeight),
            @"resolution_preview_redraw_count" : @(self.resolutionPreviewRedrawCount),
            @"last_presentation_was_resolution_preview" : @(self.resolutionPreviewRedraw),
            @"texture_cache_hits" : @(self.textureCacheHits),
            @"texture_cache_misses" : @(self.textureCacheMisses),
            @"texture_cache_bytes" : @(self.textureCacheBytes),
            @"no_write_culling_enabled" : @(!self.disableNoWriteCulling),
            @"no_write_culled_draws" : @(noWriteCulledDraws),
            @"restored_artwork_enabled" : @(self.frameUsesRestoredArtwork),
            @"enhanced_models_enabled" : @(enhancedModels),
            @"smooth_motion_enabled" : @(self.smoothMotionActive),
            @"geometry_pack_id" : self.geometryPack ? self.geometryPack.packID : NSNull.null,
            @"geometry_pack_manifest_sha256" : self.geometryPack ? self.geometryPack.manifestSHA256 : NSNull.null,
            @"geometry_pack_entries" : @(self.geometryPack.entryCount),
            @"geometry_refined_draws" : @(refinedDraws),
            @"geometry_refined_triangles" : @(refinedTriangles),
            @"geometry_used_profiles" : [modelIdentities.allObjects sortedArrayUsingSelector:@selector(compare:)],
            @"geometry_preview_redraw_count" : @(self.geometryPreviewRedrawCount),
            @"last_presentation_was_geometry_preview" : @(self.geometryPreviewRedraw),
            @"artwork_preview_redraw_count" : @(self.artworkPreviewRedrawCount),
            @"last_presentation_was_artwork_preview" : @(self.artworkPreviewRedraw),
            @"texture_pack_id" : self.texturePack ? self.texturePack.packID : NSNull.null,
            @"texture_pack_manifest_sha256" : self.texturePack ? self.texturePack.manifestSHA256 : NSNull.null,
            @"texture_pack_entries" : @(self.texturePack.entryCount),
            @"texture_pack_used_sources" : self.texturePack ? self.texturePack.usedSourceKeys : @[],
            @"texture_pack_frame_sources" : self.texturePack ? self.texturePack.frameSourceKeys : @[],
            @"material_audit_source_only_key" : self.sceneEdgeRedraw && self.materialAuditIsolate &&
                self.materialAuditSourceOnlyKey ? (id)self.materialAuditSourceOnlyKey : NSNull.null,
            @"texture_pack_hits" : @(self.texturePack.replacementHits),
            @"texture_pack_uploads" : @(self.texturePack.replacementUploads),
            @"texture_pack_cache_bytes" : @(self.texturePack.cacheBytes),
            @"texture_pack_frame_bytes" : @(self.texturePack.frameWorkingSetBytes),
            @"texture_pack_cache_encoded_bytes" : @(self.texturePack.cacheEncodedBytes),
            @"texture_pack_frame_encoded_bytes" : @(self.texturePack.frameEncodedBytes),
            @"texture_pack_allocation_budget_bytes" : @(self.texturePack.residentBudgetBytes),
            @"texture_pack_encoded_budget_bytes" : @(self.texturePack.encodedBudgetBytes),
            @"texture_pack_memory_accounting" : self.texturePack ? self.texturePack.memoryAccountingPolicy : NSNull.null,
            @"texture_decode_cache_enabled" : @(decoderStats.cacheEnabled),
            @"texture_decode_cache_hits" : @(decoderStats.hits),
            @"texture_decode_cache_misses" : @(decoderStats.misses),
            @"texture_decode_cache_evictions" : @(decoderStats.evictions),
            @"texture_decode_cache_bytes" : @(decoderStats.bytes),
            @"indexed_vertices_enabled" : @(decoderStats.indexedVertices),
            @"indexed_xf_loads" : @(decoderStats.indexedXFLoads),
            @"vertex_upload_bytes" : @(vertexPayloadBytes),
            @"index_upload_bytes" : @(vertexBytes - vertexPayloadBytes),
            @"audio_output" : @"disabled",
            @"complete" : @NO,
        }];
        if (self.smoothMotionActive) {
            const auto& history = *static_cast<MotionPresentationHistory*>(self.motionHistory);
            NSMutableDictionary* state = [self.stateCapture mutableCopy];
            state[@"motion_presentation"] = @{@"mode":@"experimental-source-interpolation",
                @"original_guest_frames":@(history.sourceFrames),
                @"intermediate_rendered_frames":@(history.generatedFrames),
                @"pair_ready":@(history.ready), @"matched_draws":@(history.matchedDraws),
                @"matched_model_draws":@(history.matchedModelDraws), @"scene_draws":@(history.sceneDraws),
                @"matched_shadow_draws":@(history.matchedShadowDraws), @"shadow_draws":@(history.shadowDraws),
                @"matched_shadow_model_draws":@(history.matchedShadowModelDraws),
                @"matched_unused_color_draws":@(history.matchedUnusedColorDraws),
                @"hold_reason":@(history.holdReason),
                @"copy_fences_shifted":@(history.copyFencesShifted),
                @"fraction":@(history.renderedFraction), @"paused":@(history.paused),
                @"simulation_clock_modified":@NO, @"extrapolation":@NO};
            [self publishStateCapture:state];
        }
        if (self.sceneEdgeRedraw) {
            NSMutableDictionary* inspection = [self.stateCapture mutableCopy];
            inspection[@"scene_edge_draws"] = drawDiagnostics;
            [self publishStateCapture:inspection];
        }
        if (self.cinematicAuditMovie && !self.cinematicAuditFinished) {
            const BOOL selected = cinematic.active && [self.cinematicAuditMovie isEqual:@(cinematic.movie)];
            if ((selected || self.cinematicAuditWasActive) && self.cinematicAuditRows < 4096) {
                NSDictionary* row = @{@"presentation_frame":@(frameIndex), @"source":CinematicReceipt(cinematic,cinematicImage),
                    @"draw_index":@(cinematicDraw), @"replacement_pack":self.cinematicPack ? [self.cinematicPack diagnostics] : NSNull.null,
                    @"handoff":@(!selected && self.cinematicAuditWasActive), @"audio_output":@"disabled"};
                NSMutableData* line = [[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:error] mutableCopy];
                [line appendBytes:"\n" length:1];
                if (!line || ![self.cinematicAuditLog writeData:line error:error]) return NO;
                ++self.cinematicAuditRows;
            }
            if (selected && !self.cinematicAuditCaptured && cinematic.decoded_frame_one_based-1 >= self.cinematicAuditFrame) {
                NSURL* directory = [self.outputDirectory URLByAppendingPathComponent:@"cinematic-source" isDirectory:YES];
                if ([NSFileManager.defaultManager fileExistsAtPath:directory.path] ||
                    ![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:error]) {
                    if (error && !*error) *error = LiveError(38,@"Cinematic audit refuses existing output.");
                    return NO;
                }
                NSMutableDictionary<NSString*,NSData*>* textures = [NSMutableDictionary dictionary];
                NSMutableDictionary* audit = [InterfaceSourceAudit(draws,efbCopies,textures) mutableCopy];
                audit[@"source"] = @"translated_execution_callback";
                audit[@"frame_index"] = @(frameIndex);
                audit[@"render_state"] = self.stateCapture;
                for (NSString* key in textures)
                    if (![textures[key] writeToURL:[directory URLByAppendingPathComponent:[key stringByAppendingString:@".rgba"]]
                        options:NSDataWritingWithoutOverwriting error:error]) return NO;
                NSData* json = [NSJSONSerialization dataWithJSONObject:audit
                    options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];
                if (!json || ![json writeToURL:[directory URLByAppendingPathComponent:@"audit.json"]
                        options:NSDataWritingWithoutOverwriting error:error] ||
                    !WritePNG(presentation ? presentation : target,[directory URLByAppendingPathComponent:@"frame.png"],error)) return NO;
                self.cinematicAuditCaptured = YES;
            }
            if (!selected && self.cinematicAuditWasActive) self.cinematicAuditFinished = YES;
            self.cinematicAuditWasActive = selected;
        }
        return YES;
    }
    NSURL* output = [
        self.outputDirectory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"frame-%04u.png", frameIndex]
    ];
    if (!WritePNG(target, output, error)) {
        return NO;
    }
    self.latestTexture = target;
    NSMutableArray* copyDiagnostics = [NSMutableArray arrayWithCapacity:efbCopies.size()];
    for (const LiveEfbCopy& copy : efbCopies) {
        [copyDiagnostics addObject:@{
            @"draw_index" : @(copy.drawIndex),
            @"source_rect" : @[@(copy.sourceX), @(copy.sourceY), @(copy.width), @(copy.height)],
            @"destination_address" : @(copy.destinationAddress),
            @"command" : @(copy.command),
            @"y_scale" : @(copy.yScale),
        }];
    }
    [self.submissions addObject:@{
        @"frame_index" : @(frameIndex),
        @"draw_count" : @(draws.size()),
        @"efb_copy_count" : @(efbCopies.size()),
        @"efb_copies" : copyDiagnostics,
        @"source_vertex_count" : @(sourceVertices),
        @"metal_vertex_count" : @(
            std::accumulate(
                draws.begin(),
                draws.end(),
                (size_t)0u,
                [enhancedModels](size_t count, const LiveDraw& draw) {
                    return count + SubmittedVertexCount(draw, enhancedModels);
                }
            )
        ),
        @"draw_diagnostics" : drawDiagnostics,
        @"output" : output.lastPathComponent,
        @"submission_source" : @"translated_execution_callback",
    }];
    return YES;
}

- (BOOL)writeLatestFrameToURL:(NSURL*)destination error:(NSError**)error {
    return [self writeLatestDiagnosticFrameToURL:destination error:error] != nil;
}

- (NSDictionary*)writeLatestDiagnosticFrameToURL:(NSURL*)destination error:(NSError**)error {
    id<MTLTexture> latest = nil;
    id<MTLCommandBuffer> completedFrame = nil;
    NSDictionary* state = nil;
    // Holding the frame's resources keeps a pooled picture from being reused
    // while this reader waits and reads it outside the lock.
    ProtectorFrameResources* __attribute__((objc_precise_lifetime)) heldResources = nil;
    @synchronized(self) {
        heldResources = self.latestFrameResources;
        latest = self.latestPresentationTexture;
        if (!latest) latest = self.latestTexture;
        state = self.stateCapture;
        completedFrame = self.latestRenderCommand;
    }
    if (!latest) {
        if (error) *error = LiveError(12, @"no translated frame rendered yet");
        return nil;
    }
    // Retain the matching immutable picture and command under the renderer
    // lock, then wait/read outside it. A newer frame cannot overwrite this one.
    [completedFrame waitUntilCompleted];
    if (completedFrame.status == MTLCommandBufferStatusError) {
        self.failure = completedFrame.error ? completedFrame.error : LiveError(11, @"Diagnostic frame render failed.");
        if (error) *error = self.failure;
        return nil;
    }
    return WritePNG(latest, destination, error) ? state : nil;
}

- (BOOL)presentLatestDrawable:(id<CAMetalDrawable>)drawable
                        error:(NSError**)error {
    return [self presentLatestDrawable:drawable minimumDuration:0 error:error];
}

- (BOOL)presentLatestDrawable:(id<CAMetalDrawable>)drawable
             minimumDuration:(CFTimeInterval)duration
                        error:(NSError**)error {
    const double lockRequested = CACurrentMediaTime();
    @synchronized(self) {
        self.displayLockWaitMax = std::max(self.displayLockWaitMax, CACurrentMediaTime() - lockRequested);
        self.presentationMinimumDuration = std::isfinite(duration) && duration > 0 && duration <= 1 ? duration : 0;
        NSError* presentationError = nil;
        const BOOL result = [self presentLockedDrawable:drawable error:&presentationError];
        if (!result) {
            // Presentation runs on the host display thread. Its fatal errors
            // must survive requestStop just like translated-frame failures;
            // otherwise the saved receipt falsely reports a clean stop.
            self.failure = presentationError ? presentationError : LiveError(11, @"Live presentation failed.");
            if (error) *error = self.failure;
        }
        return result;
    }
}

- (BOOL)presentLockedDrawable:(id<CAMetalDrawable>)drawable error:(NSError**)error {
    if (self.failure) { if (error) *error = self.failure; return NO; }
    const double sampled = CACurrentMediaTime();
    BOOL rendered = NO;
    self.asynchronousPresentationRender = YES;
    self.deferPresentationCommit = YES;
    @try { rendered = [self renderMotionAtTime:sampled error:error]; }
    @finally { self.asynchronousPresentationRender = NO; self.deferPresentationCommit = NO; }
    // Keep scene rendering and its drawable in one bounded queue slot. Two
    // buffers per frame can stall CPU encoding while the GPU waits for display.
    // The renderer lock spans encoding through commit, so a diagnostic reader
    // can never retain an unsubmitted latestRenderCommand.
    id<MTLCommandBuffer> commandBuffer = self.pendingPresentationCommand;
    self.pendingPresentationCommand = nil;
    if (!rendered) { if (commandBuffer) [commandBuffer commit]; return NO; }
    id<MTLTexture> source = self.latestPresentationTexture;
    if (!source) source = self.latestTexture;
    if (!source) {
        if (commandBuffer) [commandBuffer commit];
        return YES;
    }
    if (!commandBuffer) commandBuffer = [self.commandQueue commandBuffer];
    // This pass may re-present an earlier frame's picture: keep that frame's
    // pooled targets out of the pool until this command has read them.
    if (ProtectorFrameResources* sourceResources = self.latestFrameResources)
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            (void)completed; (void)sourceResources;
        }];
    MTLRenderPassDescriptor* pass =
        [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!commandBuffer || !encoder) {
        // Drain the scene work even when the drawable encoder fails; matching
        // snapshots must not block forever on an uncommitted command.
        if (commandBuffer) [commandBuffer commit];
        if (error) {
            *error = LiveError(
                11,
                @"live GX drawable command encoding failed"
            );
        }
        return NO;
    }
    // EFB/XFB pixels are anamorphic: their dimensions do not define TV aspect.
    // Use the aspect of the completed frame, not a concurrently requested mode.
    const float sourceAspect = (float)self.presentationAspect;
    const float drawableAspect =
        (float)drawable.texture.width / (float)drawable.texture.height;
    float scale[] = {1.0f, 1.0f};
    if (drawableAspect > sourceAspect) {
        scale[0] = sourceAspect / drawableAspect;
    } else {
        scale[1] = drawableAspect / sourceAspect;
    }
    [encoder setRenderPipelineState:self.presentPipeline];
    [encoder setVertexBytes:scale length:sizeof(scale) atIndex:0];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder setFragmentSamplerState:self.sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
    [encoder endEncoding];
    auto* motion = static_cast<MotionPresentationHistory*>(self.motionHistory);
    NSArray* hudRoles=self.stateCapture[@"native_hud_role_counts"];
    const BOOL gameplayForPerformance=[self.stateCapture[@"native_hud_draws"] unsignedIntegerValue]>0 ||
        (hudRoles.count>=4 && ([hudRoles[2] unsignedIntegerValue] || [hudRoles[3] unsignedIntegerValue]));
    if (self.smoothMotionActive && motion && self.motionPresentationLog &&
        static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame)->index >= self.motionPresentationMinimumFrame &&
        (self.performanceRing || self.motionPresentationCount < 4096u) &&
        (!motion->paused || !self.motionLoggedPause)) {
        self.motionLoggedPause = motion->paused;
        const auto& history = *static_cast<MotionPresentationHistory*>(self.motionHistory);
        const auto& current = *static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
        NSMutableDictionary* record = [@{@"schema":@"protector-native.motion-presentation/v1",
            @"sequence":@(++self->_motionPresentationCount), @"source_frame":@(current.index),
            @"previous_frame":@(history.previous.index), @"fraction":@(history.renderedFraction),
            @"pair_ready":@(history.ready), @"matched_draws":@(history.matchedDraws),
            @"matched_model_draws":@(history.matchedModelDraws), @"scene_draws":@(history.sceneDraws),
            @"matched_shadow_draws":@(history.matchedShadowDraws), @"shadow_draws":@(history.shadowDraws),
            @"matched_shadow_model_draws":@(history.matchedShadowModelDraws),
            @"matched_unused_color_draws":@(history.matchedUnusedColorDraws),
            @"hold_reason":@(history.holdReason),
            @"copy_fences_shifted":@(history.copyFencesShifted),
            @"paused":@(history.paused), @"sampled_host_seconds":@(sampled),
            @"source_host_deadline":@(current.hostDeadline), @"guest_interval_seconds":@(history.interval),
            @"source_guest_ticks":@(current.guestTicks),
            @"render_finished_seconds":@(CACurrentMediaTime()),
            @"original_guest_frames":@(history.sourceFrames),
            @"intermediate_rendered_frames":@(history.generatedFrames),
            @"audio_output":protector_audio_output_enabled() ? @"native-transport-enabled" : @"disabled",
            @"audio_underrun_frames":@(protector_audio_output_underrun()),
            @"audio_dropped_frames":@(protector_audio_output_dropped()),
            @"presentation_aspect_ratio":@(self.presentationAspect),
            @"native_hud_admission":self.stateCapture[@"native_hud_admission"],
            @"native_hud_rejected_frames":self.stateCapture[@"native_hud_rejected_frames"],
            @"render_target_optimizations":@(self.renderTargetOptimizationsEnabled),
            @"shader_specialization":self.stateCapture[@"shader_specialization"],
            @"thermal_state":@(NSProcessInfo.processInfo.thermalState),
            @"lightweight_capture":@(self.lightweightPerformanceCapture),
            @"gameplay":@(gameplayForPerformance),
            @"presentation_rate":@(self.presentationMinimumDuration > 0 ? std::round(1.0 / self.presentationMinimumDuration) : 0),
            @"smoothed_gpu_ms":@(self.smoothedGPUSeconds * 1000),
            @"native_hud_role_counts":hudRoles ? hudRoles : @[],
            @"wide_frame":self.stateCapture[@"wide_frame"] ? self.stateCapture[@"wide_frame"] : (id)NSNull.null,
            @"presentation_transition_events":@(self.presentationTransitionEvents),
            @"native_hud_detail":self.stateCapture[@"native_hud_detail"] ? self.stateCapture[@"native_hud_detail"] : (id)NSNull.null,
            @"low_power_mode":@(NSProcessInfo.processInfo.lowPowerModeEnabled),
            @"guest_lock_wait_ms":@(self.guestLockWaitMax * 1000),
            @"guest_lock_held_ms":@(self.guestLockHeldMax * 1000),
            @"display_lock_wait_ms":@(self.displayLockWaitMax * 1000)} mutableCopy];
        // Maxima since the previous record: each lock-cost window is reported once.
        self.guestLockWaitMax = self.guestLockHeldMax = self.displayLockWaitMax = 0;
        if (self.lastRenderCost) record[@"render_cost"] = self.lastRenderCost;
        if (self.motionCopyMismatch) record[@"copy_layout_mismatch"] = self.motionCopyMismatch;
        if ([self.motionAuditState[@"guarded_models"] count])
            record[@"guarded_models"] = self.motionAuditState[@"guarded_models"];
        if (self.motionAuditState[@"depthless_shadow_roundoff"])
            record[@"depthless_shadow_roundoff"] = self.motionAuditState[@"depthless_shadow_roundoff"];
        if (self.motionAuditState[@"source_instances"])
            record[@"source_instances"] = self.motionAuditState[@"source_instances"];
        NSMutableArray* stateRejections = [NSMutableArray array];
        for (NSDictionary* profile in self.motionAuditState[@"model_profiles"])
            if (profile[@"state_differences"]) [stateRejections addObject:profile];
        if (stateRejections.count) record[@"model_state_rejections"] = stateRejections;
        id<MTLCommandBuffer> renderCommand = self.latestRenderCommand;
        ProtectorPassTiming* passTiming = self.latestPassTiming;
        ProtectorPerformanceRing* ring = self.performanceRing;
        void (^recordTiming)(id, NSString*) = ^(id actualTime, NSString* clockKind) {
            @autoreleasepool {
                // Core Animation calls this while holding its drawable lock.
                // Never acquire the renderer lock here: the display thread can
                // hold that lock while adding a handler to another drawable.
                @synchronized(self.motionPresentationLog) {
                    record[@"actual_presented_seconds"] = actualTime;
                    record[@"timing_source"] = clockKind;
                    record[@"callback_host_seconds"] = @(CACurrentMediaTime());
                    if (record[@"render_cost"] && renderCommand) {
                        NSMutableDictionary* cost = [record[@"render_cost"] mutableCopy];
                        cost[@"gpu_seconds"] = @(renderCommand.GPUEndTime-renderCommand.GPUStartTime);
                        if (passTiming && renderCommand.status == MTLCommandBufferStatusCompleted) {
                            NSDictionary* passes = [passTiming resolveWithSecondsPerTick:[self passTimingSecondsPerTick]];
                            if (passes) cost[@"passes"] = passes;
                        }
                        record[@"render_cost"] = cost;
                    }
                    NSError* logError = nil;
                    NSMutableData* data = [[NSJSONSerialization dataWithJSONObject:record
                        options:NSJSONWritingSortedKeys error:&logError] mutableCopy];
                    [data appendBytes:"\n" length:1];
                    if (ring) {
                        // Diagnostics must not stop play; count the miss instead.
                        if (!data || ![ring writeRecord:data error:&logError]) ++self->_performanceRingWriteFailures;
                    } else if (!data || ![self.motionPresentationLog writeData:data error:&logError])
                        self.failure = logError ? logError : LiveError(36, @"Motion presentation evidence write failed.");
                }
            }
        };
#if TARGET_OS_SIMULATOR
        // The simulator SDK omits MTLDrawable's presentation-time APIs. GPU
        // completion is useful diagnostic evidence, but not a display timestamp.
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            (void)completed;
            recordTiming(NSNull.null, @"simulator-command-completion-only");
        }];
#else
        [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
            recordTiming(@(presented.presentedTime), @"drawable-presented-time");
        }];
#endif
    }
#if TARGET_OS_SIMULATOR
    // Simulator Metal omits both display timestamps and duration scheduling.
    // Its completion callback remains functional evidence, never display fps.
    [commandBuffer presentDrawable:drawable];
#else
    if (self.presentationMinimumDuration > 0)
        [commandBuffer presentDrawable:drawable afterMinimumDuration:self.presentationMinimumDuration];
    else [commandBuffer presentDrawable:drawable];
#endif
    [commandBuffer commit];
    return YES;
}

- (MotionStageInputs)motionStageInputs {
    const auto& current = *static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
    const auto& history = *static_cast<MotionPresentationHistory*>(self.motionHistory);
    MotionStageInputs inputs;
    inputs.generation = _motionStateGeneration;
    inputs.paused = history.paused;
    inputs.currentDeadline = current.hostDeadline;
    inputs.detailedAudit = self.motionAuditLog != nil ||
        (self.motionPresentationLog != nil && !self.lightweightPerformanceCapture);
    inputs.sourceInstanceAudit = self.motionPresentationLog && !self.lightweightPerformanceCapture &&
        self.motionPresentationCount < 4096;
    return inputs;
}

- (void)stageMotionDraws:(std::vector<LiveDraw>&)draws copies:(std::vector<LiveEfbCopy>&)copies
                   frame:(u32)index guestTicks:(u64)ticks deadline:(double)deadline {
    [self stageMotionDraws:draws copies:copies frame:index guestTicks:ticks deadline:deadline plan:nullptr];
}

- (void)stageMotionDraws:(std::vector<LiveDraw>&)draws copies:(std::vector<LiveEfbCopy>&)copies
                   frame:(u32)index guestTicks:(u64)ticks deadline:(double)deadline
                    plan:(MotionStagePlan*)precomputed {
    auto& current = *static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
    auto& history = *static_cast<MotionPresentationHistory*>(self.motionHistory);
    // A plan made outside the lock is valid only if no reset, pause or other
    // commit happened since its snapshot; otherwise recompute here, unchanged.
    MotionStagePlan local;
    MotionStagePlan* plan = precomputed;
    if (!plan || plan->generation != _motionStateGeneration) {
        local = PlanMotionStage(current, [self motionStageInputs], draws, copies, index, ticks, deadline);
        plan = &local;
    }
    history.interval = plan->interval;
    history.holdReason = plan->holdReason;
    history.ready = plan->ready;
    history.copyFencesShifted = plan->copyFencesShifted;
    self.motionCopyMismatch = plan->copyMismatch;
    history.matches = std::move(plan->matches);
    history.matchedDraws = plan->matchedDraws;
    history.matchedModelDraws = plan->matchedModelDraws;
    history.matchedShadowDraws = plan->matchedShadowDraws;
    history.matchedShadowModelDraws = plan->matchedShadowModelDraws;
    history.matchedUnusedColorDraws = plan->matchedUnusedColorDraws;
    history.sceneDraws = plan->sceneDraws;
    history.shadowDraws = plan->shadowDraws;
    // A held frame must not inherit a previous frame's admission audit.
    self.motionAuditState = plan->audit;
    history.previous = history.ready ? std::move(current) : ArtworkPreviewFrame();
    current.draws = std::move(draws);
    current.copies = std::move(copies);
    current.index = index;
    current.guestTicks = ticks;
    current.cinematic = self.pendingCinematic;
    current.hostDeadline = !history.paused && std::isfinite(deadline) && deadline > 0 ? deadline : 0;
    current.valid = true;
    ++history.sourceFrames;
    ++_motionStateGeneration;
}

- (BOOL)renderMotionAtTime:(double)hostTime error:(NSError**)error {
    if (!self.smoothMotionActive) return YES;
    auto& history = *static_cast<MotionPresentationHistory*>(self.motionHistory);
    const auto& current = *static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
    if (!current.valid) return YES;
    // A sample just before the newest frame's deadline is the start of the
    // new pair (fraction 0, where the previous pair ended), not the
    // reverse-clock case that snaps to its end; snapping reads as judder.
    double sampleTime = hostTime;
    if (history.ready && !history.paused && current.hostDeadline > 0 && sampleTime < current.hostDeadline &&
        current.hostDeadline - sampleTime < 0.05) sampleTime = current.hostDeadline;
    const double fraction = history.ready && !history.paused ?
        protector_motion_fraction(current.hostDeadline, history.interval, sampleTime) : 1;
    if (history.rendered && history.renderedIndex == current.index && history.renderedFraction == fraction) return YES;
    // Reuse the blended copy across presentations of the same guest frame.
    auto& blended = history.blended;
    const bool prepared = history.blendedGeneration == _motionStateGeneration && !blended.empty();
    if (fraction < 1 && !BlendMotionDrawsInto(history.previous, current.draws, history.matches, fraction,
            &blended, prepared)) {
        if (error) *error = LiveError(36, @"Motion presentation rejected an inconsistent frame pair.");
        return NO;
    }
    history.renderedFraction = fraction;
    history.renderedIndex = current.index;
    history.rendered = false;
    if (fraction > 0 && fraction < 1) ++history.generatedFrames;
    if (fraction < 1) history.blendedGeneration = _motionStateGeneration;
    const BOOL result = [self renderDraws:fraction < 1 ? blended : current.draws
        efbCopies:current.copies frame:current.index error:error];
    history.rendered = result;
    return result;
}

- (NSArray*)writeMotionShadowCopies:(NSString*)prefix directory:(NSURL*)directory error:(NSError**)error {
    NSMutableArray* images = [NSMutableArray array];
    for (NSNumber* index in [self.motionProofShadowTextures.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString* name = [NSString stringWithFormat:@"%@-shadow-%@.png", prefix, index];
        // An EFB mask is independent color/alpha data, not premultiplied color.
        // Preserve those channels; also provide an opaque RGB inspection view.
        NSString* rgbName = [NSString stringWithFormat:@"%@-shadow-%@-rgb.png", prefix, index];
        if (!WritePNG(self.motionProofShadowTextures[index], [directory URLByAppendingPathComponent:name], error,
                kCGImageAlphaFirst) ||
            !WritePNG(self.motionProofShadowTextures[index], [directory URLByAppendingPathComponent:rgbName], error,
                kCGImageAlphaNoneSkipFirst))
            return nil;
        [images addObject:@{@"copy_index":index, @"image":name, @"rgb_inspection_image":rgbName,
            @"channel_encoding":@"independent-rgba"}];
    }
    return images;
}

- (BOOL)captureMotionProof:(const std::vector<LiveDraw>&)draws
                 efbCopies:(const std::vector<LiveEfbCopy>&)copies
                     frame:(u32)frameIndex guestTicks:(u64)guestTicks error:(NSError**)error {
    if (!self.motionProofMinimumFrame || self.motionProofCaptured || frameIndex < self.motionProofMinimumFrame)
        return YES;
    const auto* previous = static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
    if (!previous || !previous->valid || previous->index == UINT32_MAX || frameIndex != previous->index + 1)
        return YES;
    if (!MotionCopiesCompatible(previous->copies, previous->draws.size(), copies, draws.size())) return YES;
    std::vector<s32> matches;
    NSDictionary* audit = MotionCorrespondenceAudit(previous, draws, frameIndex, &matches, &copies);
    GuardMotionCopyPasses(previous->copies, copies, &matches);
    matches = GuardMotionGroups(*previous, draws, std::move(matches), nil, &copies);
    const auto roles = MotionDrawRoles(draws, &copies);
    bool movingModel = false;
    bool movingShadowModel = false;
    NSUInteger unusedColorModels = 0;
    NSMutableArray* pairs = [NSMutableArray array];
    NSMutableArray* shadowPairs = [NSMutableArray array];
    NSMutableSet* modelIDs = [NSMutableSet set];
    for (size_t i = 0; i < matches.size(); ++i) if (matches[i] >= 0) {
        [pairs addObject:@[@(i), @(matches[i])]];
        if (roles[i] == MotionDrawRole::Shadow) [shadowPairs addObject:@[@(i), @(matches[i])]];
        if (draws[i].geometryProfile && roles[i] == MotionDrawRole::Shadow) {
            double delta = 0;
            if (MotionPositionDelta(previous->draws[matches[i]], draws[i], &delta) && delta > 0.0005)
                movingShadowModel = true;
        }
        if (draws[i].geometryProfile && roles[i] == MotionDrawRole::Scene) {
            if (memcmp(previous->draws[matches[i]].fragment.colorRegisters, draws[i].fragment.colorRegisters,
                    sizeof(draws[i].fragment.colorRegisters))) ++unusedColorModels;
            double delta = 0;
            if (MotionPositionDelta(previous->draws[matches[i]], draws[i], &delta) && delta > 0.0005)
                movingModel = true;
            [modelIDs addObject:@(draws[i].geometryProfile->identity.c_str())];
        }
    }
    if (!movingModel || (self.motionProofRequireUnusedColor && !unusedColorModels) ||
        (self.motionProofRequireShadow && !movingShadowModel)) return YES;
    NSURL* directory = [self.outputDirectory URLByAppendingPathComponent:@"motion-proof" isDirectory:YES];
    if ([NSFileManager.defaultManager fileExistsAtPath:directory.path]) {
        if (error) *error = LiveError(35, @"Motion evidence already exists; choose a fresh output directory.");
        return NO;
    }
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO
            attributes:nil error:error]) return NO;
    NSString* oldHash = MotionVertexDigest(previous->draws);
    NSString* newHash = MotionVertexDigest(draws);
    if (!oldHash || !newHash) {
        if (error) *error = LiveError(35, @"Motion source snapshot exceeds the proof hash bound.");
        return NO;
    }
    const uint64_t sourceCount = self.renderedFrameCount;
    self.motionProofRedraw = YES;
    @try {
        // This is one bounded spatial proof, not the live presentation path.
        // Keep endpoint images separate from the matched-only starting pose.
        if (![self renderDraws:draws efbCopies:copies frame:frameIndex error:error] ||
            ![self writeLatestFrameToURL:[directory URLByAppendingPathComponent:@"current-reference.png"] error:error]) return NO;
        NSArray* referenceShadows = [self writeMotionShadowCopies:@"current-reference" directory:directory error:error];
        NSArray* copyConsumers = self.motionProofCopyConsumers;
        NSMutableIndexSet* receivers = [NSMutableIndexSet indexSet];
        for (NSDictionary* consumer in copyConsumers) {
            const NSUInteger index = [consumer[@"draw_index"] unsignedIntegerValue];
            if (index >= draws.size() || ClassifyWideDraw(draws[index]) != WideDrawRole::Scene) continue;
            for (NSDictionary* stage in consumer[@"stages"]) {
                const NSInteger copy = [stage[@"copy_index"] integerValue];
                if (copy >= 0 && (size_t)copy < copies.size() && copies[copy].command == 0x1000Bu)
                    [receivers addIndex:index];
            }
        }
        NSArray* receiverDiagnosticImages = receivers.count ?
            @[@"current-without-shadow-receivers.png", @"current-shadow-receiver-surface.png",
              @"current-shadow-receiver-no-depth.png"] : @[];
        for (NSUInteger diagnostic = 0; diagnostic < receiverDiagnosticImages.count; ++diagnostic) {
            auto inspection = draws;
            for (NSUInteger index = receivers.firstIndex; index != NSNotFound; index = [receivers indexGreaterThanIndex:index]) {
                auto& draw = inspection[index];
                if (diagnostic == 0) {
                    draw.vertices.clear(); draw.indices.clear(); draw.refinedVertices.clear();
                    draw.geometryProfile = nullptr; draw.sourceVertexCount = 0;
                } else {
                    // Proof-only magenta diagnostic: shows original receiving
                    // geometry, not an alternative or accepted game material.
                    draw.fragment.stageCount = 1; draw.fragment.indirectCount = 0;
                    draw.fragment.indirectCommands[0] = 0;
                    draw.fragment.colorCombiners[0] = 0x8FFFE;
                    draw.fragment.alphaCombiners[0] = 0x8FFE0;
                    draw.fragment.konstColors[0][0] = draw.fragment.konstColors[0][2] =
                        draw.fragment.konstColors[0][3] = 1;
                    draw.fragment.konstColors[0][1] = 0;
                    if (diagnostic == 2) draw.depthMode = 0;
                }
            }
            if (![self renderDraws:inspection efbCopies:copies frame:frameIndex error:error] ||
                ![self writeLatestFrameToURL:[directory URLByAppendingPathComponent:receiverDiagnosticImages[diagnostic]] error:error])
                return NO;
        }
        if (!referenceShadows ||
            ![self renderDraws:previous->draws efbCopies:previous->copies frame:previous->index error:error] ||
            ![self writeLatestFrameToURL:[directory URLByAppendingPathComponent:@"previous-source.png"] error:error]) return NO;
        NSArray* previousShadows = [self writeMotionShadowCopies:@"previous-source" directory:directory error:error];
        if (!previousShadows) return NO;
        NSArray* names = @[@"matched-start.png", @"quarter.png", @"half.png", @"three-quarter.png", @"current.png"];
        NSMutableArray* samples = [NSMutableArray array];
        for (NSUInteger step = 0; step <= 4; ++step) {
            std::vector<LiveDraw> blended;
            const double fraction = (double)step / 4;
            if (!BlendMotionDraws(*previous, draws, matches, fraction, &blended)) {
                if (error) *error = LiveError(35, @"Motion proof rejected an inconsistent source pair.");
                return NO;
            }
            if (![self renderDraws:blended efbCopies:copies frame:frameIndex error:error] ||
                ![self writeLatestFrameToURL:[directory URLByAppendingPathComponent:names[step]] error:error]) return NO;
            NSArray* shadowImages = [self writeMotionShadowCopies:[names[step] stringByDeletingPathExtension]
                directory:directory error:error];
            if (!shadowImages) return NO;
            [samples addObject:@{@"fraction":@(fraction), @"image":names[step],
                @"shadow_copy_images":shadowImages,
                @"submitted_vertex_sha256":MotionVertexDigest(blended)}];
        }
        const bool immutable = [oldHash isEqual:MotionVertexDigest(previous->draws)] &&
            [newHash isEqual:MotionVertexDigest(draws)] && sourceCount == self.renderedFrameCount;
        NSData* reference = [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"current-reference.png"]
            options:0 error:error];
        NSData* endpoint = [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"current.png"]
            options:0 error:error];
        if (!immutable || !reference || ![reference isEqual:endpoint]) {
            if (error) *error = LiveError(35, @"Motion proof changed source vertices or its exact endpoint image.");
            return NO;
        }
        NSDictionary* proof = @{@"schema":@"protector-native.motion-spatial-proof/v1",
            @"source":@"translated_execution_callback", @"previous_frame":@(previous->index),
            @"current_frame":@(frameIndex), @"previous_guest_timebase":@(previous->guestTicks),
            @"current_guest_timebase":@(guestTicks), @"source_vertices_immutable":@YES,
            @"current_endpoint_byte_exact":@YES, @"original_guest_updates_during_proof":@0,
            @"previous_vertex_sha256":oldHash, @"current_vertex_sha256":newHash,
            @"matched_draw_pairs":pairs, @"model_profiles":[modelIDs.allObjects sortedArrayUsingSelector:@selector(compare:)],
            @"matched_shadow_draw_pairs":shadowPairs,
            @"reference_shadow_copy_images":referenceShadows,
            @"previous_shadow_copy_images":previousShadows,
            @"current_efb_copy_consumers":copyConsumers,
            @"receiver_diagnostic_images":receiverDiagnosticImages,
            @"moving_shadow_model":@(movingShadowModel),
            @"matched_unused_color_model_draws":@(unusedColorModels),
            @"previous_copy_layout":MotionCopyLayout(previous->copies, previous->draws.size()),
            @"current_copy_layout":MotionCopyLayout(copies, draws.size()),
            @"offscreen_audit":MotionOffscreenAudit(*previous, draws),
            @"samples":samples, @"render_scale":@(self.renderScale), @"widescreen":@(self.widescreenEnabled),
            @"enhanced_models":@(self.enhancedModelsEnabled), @"restored_artwork":@(self.restoredArtworkEnabled),
            @"audio_output":@"disabled", @"audit":audit,
            @"limitations":@[@"five spatial samples, not continuous 60 fps presentation",
                @"unmatched draws and unrecognized offscreen passes retain current-frame geometry",
                @"source identity and outline grouping are guarded; whole-scene motion acceptance remains open"]};
        NSData* json = [NSJSONSerialization dataWithJSONObject:proof options:NSJSONWritingPrettyPrinted error:error];
        if (!json || ![json writeToURL:[directory URLByAppendingPathComponent:@"proof.json"]
                options:NSDataWritingWithoutOverwriting error:error]) return NO;
        self.motionProofCaptured = YES;
    } @finally {
        self.motionProofRedraw = NO;
        self.motionProofShadowTextures = nil;
        self.motionProofCopyConsumers = nil;
    }
    return YES;
}

- (BOOL)captureSceneEdges:(const std::vector<LiveDraw>&)draws copies:(const std::vector<LiveEfbCopy>&)copies
                   frame:(u32)frameIndex directory:(NSURL*)directory error:(NSError**)error {
    if (!self.sceneEdgeAuditEnabled) return YES;
    if (draws.size() > 2048 || !self.artworkPreviewFrame) {
        if (error) *error = LiveError(37, @"Scene inspection requires bounded upgraded source draws.");
        return NO;
    }
    const BOOL savedWide = self.widescreenEnabled;
    const CGSize savedSize = self.nativePresentationSize;
    const CGRect savedHud = self.nativeHudFrame;
    const NSUInteger savedScale = self.renderScale;
    const BOOL savedArtwork = self.restoredArtworkEnabled;
    const uint64_t savedCount = self.renderedFrameCount;
    NSString* digest = MotionVertexDigest(draws);
    NSMutableArray* samples = [NSMutableArray array];
    NSMutableArray* identities = [NSMutableArray array];
    for (size_t index = 0; index < draws.size(); ++index) {
        const u32 color = (u32)((index + 1) * 0x457381u) & 0xFFFFFFu;
        NSMutableArray* keys = [NSMutableArray array];
        for (u32 stage = 0; stage < std::min<u32>(draws[index].fragment.stageCount, 4); ++stage) {
            NSString* key = InterfaceTextureKeyForDraw(draws[index], stage);
            [keys addObject:key ? (id)key : (id)NSNull.null];
        }
        NSMutableDictionary* identity = [@{@"index":@(index), @"identifier_rgb":@[@((color >> 16) & 255),
            @((color >> 8) & 255), @(color & 255)], @"texture_keys":keys,
            @"display_list_depth":@(draws[index].displayListDepth),
            @"finite_backdrop_identity":@(draws[index].finiteBackdropIdentity),
            @"repeating_backdrop_identity":@(draws[index].repeatingBackdropIdentity),
            @"hill_backdrop_identity":@(draws[index].hillBackdropIdentity)} mutableCopy];
        identity[@"canyon_sky_identity"] = @(draws[index].canyonSkyIdentity);
        identity[@"city_sky_identity"] = @(draws[index].citySkyIdentity);
        identity[@"related_city_sky_identity"] = @(draws[index].relatedCitySkyIdentity);
        identity[@"finite_room_identity"] = @(draws[index].finiteRoomIdentity);
        const auto& draw = draws[index];
        identity[@"source_vertex_count"] = @(draw.sourceVertexCount);
        identity[@"material_state"] = @{@"stage_count":@(draw.fragment.stageCount),
            @"indirect_count":@(draw.fragment.indirectCount),@"blend":@(draw.blendMode),
            @"depth":@(draw.depthMode),@"cull":@(draw.cullMode),@"alpha_test":@(draw.fragment.alphaTest),
            @"has_normal":@(draw.hasNormal),@"has_vertex_color":@(draw.hasVertexColor),
            @"first_texture_format":@(draw.textureFormats[0]),@"first_texture_coordinate":@(draw.textureCoordinates[0])};
        NSMutableArray* sceneProjection = [NSMutableArray array];
        for (u32 value : draw.projectionWords) [sceneProjection addObject:@(value)];
        identity[@"projection_words"] = sceneProjection;
        identity[@"viewport"] = @[@(draw.viewportX),@(draw.viewportY),@(draw.viewportWidth),@(draw.viewportHeight)];
        if (draw.hasBackdropSourcePositionKey) {
            char hash[65]{};
            for (size_t i = 0; i < draw.backdropSourcePositionKey.size(); ++i)
                snprintf(hash + i*2, 3, "%02x", draw.backdropSourcePositionKey[i]);
            NSMutableArray* vertices = [NSMutableArray array];
            for (const auto& vertex : draw.vertices) {
                [vertices addObject:@{@"clip":@[@(vertex.position[0]), @(vertex.position[1]),
                    @(vertex.position[2]), @(vertex.position[3])],
                    @"uv":@[@(vertex.uv[0][0]), @(vertex.uv[0][1])],
                    @"color":@[@(vertex.color[0]), @(vertex.color[1]),
                        @(vertex.color[2]), @(vertex.color[3])]}];
            }
            NSMutableArray* indices = [NSMutableArray array];
            for (u32 value : draw.indices) [indices addObject:@(value)];
            identity[@"source_position_sequence_sha256"] = [NSString stringWithUTF8String:hash];
            identity[@"decoded_vertices"] = vertices;
            identity[@"indices"] = indices;
            identity[@"indexed"] = @(draw.indexed);
            identity[@"source_vertex_count"] = @(draw.sourceVertexCount);
            identity[@"viewport"] = @[@(draw.viewportX), @(draw.viewportY),
                @(draw.viewportWidth), @(draw.viewportHeight)];
            NSMutableArray* projection = [NSMutableArray array];
            for (u32 value : draw.projectionWords) [projection addObject:@(value)];
            identity[@"projection_words"] = projection;
        }
        [identities addObject:identity];
    }
    self.sceneEdgeRedraw = YES;
    BOOL success = YES;
    @try {
        self.widescreenEnabled = YES;
        self.nativePresentationSize = CGSizeMake(874, 402);
        self.nativeHudFrame = CGRectMake(74, 8, 207.75, 96.43);
        self.renderScale = 2;
        NSMutableArray* names = [@[@"scene-native.png", @"scene-native-no-cull.png",
            @"scene-draw-identifiers.png", @"scene-draw-identifiers-no-cull.png", @"scene-source-artwork.png"] mutableCopy];
        if (std::any_of(draws.begin(), draws.end(), [](const LiveDraw& draw) { return draw.finiteBackdropIdentity != 0; }))
            [names addObject:@"scene-finite-backdrop-baseline.png"];
        if (RepeatingBackdropCohort(draws)) [names addObject:@"scene-repeating-backdrop-baseline.png"];
        if (HillBackdropCohort(draws)) [names addObject:@"scene-hill-backdrop-baseline.png"];
        if (CanyonSkyCohort(draws)) [names addObject:@"scene-canyon-sky-baseline.png"];
        if (CitySkyCohort(draws)) [names addObject:@"scene-city-sky-baseline.png"];
        if (RelatedCitySkyContinuation(draws, nullptr)) [names addObject:@"scene-related-city-sky-baseline.png"];
        if (std::any_of(draws.begin(),draws.end(),[](const LiveDraw& draw){ return draw.finiteRoomIdentity!=0; }))
            [names addObjectsFromArray:@[@"scene-room-frame-baseline.png",@"scene-room-frame-4x3.png",@"scene-room-frame-4x3-baseline.png"]];
        for (NSUInteger variant = 0; variant < names.count; ++variant) {
            auto inspection = draws;
            self.nativePresentationSize = [names[variant] containsString:@"room-frame-4x3"]
                ? CGSizeMake(536,402) : CGSizeMake(874,402);
            self.restoredArtworkEnabled = variant == 4 ? NO : savedArtwork;
            for (size_t index = 0; index < inspection.size(); ++index) {
                auto& draw = inspection[index];
                if ([names[variant] isEqualToString:@"scene-finite-backdrop-baseline.png"]) draw.finiteBackdropIdentity = 0;
                if ([names[variant] isEqualToString:@"scene-repeating-backdrop-baseline.png"]) draw.repeatingBackdropIdentity = 0;
                if ([names[variant] isEqualToString:@"scene-hill-backdrop-baseline.png"]) draw.hillBackdropIdentity = 0;
                if ([names[variant] isEqualToString:@"scene-canyon-sky-baseline.png"]) draw.canyonSkyIdentity = 0;
                if ([names[variant] isEqualToString:@"scene-city-sky-baseline.png"]) draw.citySkyIdentity = 0;
                if ([names[variant] isEqualToString:@"scene-related-city-sky-baseline.png"]) draw.relatedCitySkyIdentity = 0;
                if ([names[variant] isEqualToString:@"scene-room-frame-baseline.png"] ||
                    [names[variant] isEqualToString:@"scene-room-frame-4x3-baseline.png"]) draw.finiteRoomIdentity = 0;
                if (ClassifyWideDraw(draw) != WideDrawRole::Scene) continue;
                if (variant == 1 || variant == 3) draw.cullMode = 0;
                if (variant == 2 || variant == 3) {
                    const u32 color = (u32)((index + 1) * 0x457381u) & 0xFFFFFFu;
                    draw.fragment.stageCount = 1; draw.fragment.indirectCount = 0;
                    draw.fragment.indirectCommands[0] = 0;
                    draw.fragment.colorCombiners[0] = 0x8FFFE;
                    draw.fragment.alphaCombiners[0] = 0x8FFE0;
                    draw.fragment.alphaTest = 0x3F0000;
                    draw.fragment.konstColors[0][0] = ((color >> 16) & 255) / 255.0f;
                    draw.fragment.konstColors[0][1] = ((color >> 8) & 255) / 255.0f;
                    draw.fragment.konstColors[0][2] = (color & 255) / 255.0f;
                    draw.fragment.konstColors[0][3] = 1;
                    draw.blendMode &= ~1u;
                }
            }
            if (![self renderDraws:inspection efbCopies:copies frame:frameIndex error:error] ||
                ![self writeLatestFrameToURL:[directory URLByAppendingPathComponent:names[variant]] error:error]) {
                success = NO; break;
            }
            [samples addObject:@{@"image":names[variant], @"state":self.stateCapture}];
        }
    } @finally {
        self.widescreenEnabled = savedWide; self.nativePresentationSize = savedSize;
        self.nativeHudFrame = savedHud; self.renderScale = savedScale;
        self.restoredArtworkEnabled = savedArtwork;
        if (![self renderDraws:draws efbCopies:copies frame:frameIndex error:error]) success = NO;
        self.sceneEdgeRedraw = NO;
    }
    if (!success) return NO;
    if (![digest isEqual:MotionVertexDigest(draws)] || savedCount != self.renderedFrameCount) {
        if (error) *error = LiveError(37, @"Scene inspection changed its source or frame count.");
        return NO;
    }
    NSDictionary* report = @{@"schema":@"protector-native.scene-edge-inspection/v1", @"frame_index":@(frameIndex),
        @"source":@"translated_execution_callback", @"source_vertices_immutable":@YES,
        @"source_vertex_sha256":digest, @"guest_updates_during_inspection":@0,
        @"identities":identities, @"samples":samples,
        @"limitations":@"Identifier variants replace materials, alpha tests and blending for picking only; not accepted game output."};
    NSData* json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:error];
    return json && [json writeToURL:[directory URLByAppendingPathComponent:@"scene-edges.json"]
        options:NSDataWritingWithoutOverwriting error:error];
}

- (BOOL)captureMaterialSources:(const std::vector<LiveDraw>&)draws copies:(const std::vector<LiveEfbCopy>&)copies
                        frame:(u32)frameIndex guestTicks:(uint64_t)guestTicks error:(NSError**)error {
    if (!self.materialAuditKeys.count || self.materialAuditCaptured.count == self.materialAuditKeys.count) return YES;
    // The QA runner releases this gate only after native gameplay/readback has
    // settled. First texture use can otherwise occur behind a loading fade.
    // No configured gate means unchanged historical observer behavior; normal
    // builds never open a marker. Reject non-regular files and bound every read.
    if (self.materialAuditReadyPath && !self.materialAuditReady) {
        const int marker = open(self.materialAuditReadyPath.fileSystemRepresentation,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
        if (marker < 0) return YES;
        struct stat info{};
        char token[7]{};
        const BOOL ready = fstat(marker, &info) == 0 && S_ISREG(info.st_mode) && info.st_size == 6 &&
            read(marker, token, sizeof(token)) == 6 && memcmp(token, "ready\n", 6) == 0;
        close(marker);
        if (!ready) return YES;
        self.materialAuditReady = YES;
    }
    if (draws.size() > kMaterialAuditMaxDraws || !self.artworkPreviewFrame) {
        if (error) *error = LiveError(37, @"Material inspection requires enhanced source draws, at most 4096 per frame.");
        return NO;
    }
    for (NSUInteger ordinal = 0; ordinal < self.materialAuditKeys.count; ++ordinal) {
        NSString* key = self.materialAuditKeys[ordinal];
        if ([self.materialAuditCaptured containsObject:key]) continue;
        const auto matches = MaterialAuditDrawIndices(draws,key);
        if (matches.empty()) continue;
        NSURL* directory = [self.outputDirectory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"material-source-%02lu",(unsigned long)ordinal] isDirectory:YES];
        if ([NSFileManager.defaultManager fileExistsAtPath:directory.path] ||
            ![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
                attributes:nil error:error]) {
            if (error && !*error) *error = LiveError(37, @"Material inspection refuses an existing output directory.");
            return NO;
        }
        NSMutableArray* records = [NSMutableArray array];
        for (size_t index : matches) {
            const auto& draw = draws[index];
            NSMutableArray* stages = [NSMutableArray array];
            for (size_t stage = 0; stage < draw.fragment.stageCount; ++stage) {
                NSString* source = InterfaceTextureKeyForDraw(draw, stage);
                [stages addObject:@{@"stage":@(stage), @"source_key":source ? (id)source : NSNull.null,
                    @"gx_format":@(draw.textureFormats[stage]), @"gx_mode":@(draw.textureModes[stage]),
                    @"texture_unit":@(draw.textureUnits[stage]), @"uv_set":@(draw.textureCoordinates[stage]),
                    @"color_combiner":@(draw.fragment.colorCombiners[stage]),
                    @"alpha_combiner":@(draw.fragment.alphaCombiners[stage])}];
            }
            [records addObject:@{@"draw_index":@(index), @"orthographic":@(draw.projectionWords[6] != 0),
                @"blend_mode":@(draw.blendMode), @"depth_mode":@(draw.depthMode), @"cull_mode":@(draw.cullMode),
                @"alpha_test":@(draw.fragment.alphaTest), @"indirect_count":@(draw.fragment.indirectCount),
                @"vertex_count":@(draw.vertices.size()), @"index_count":@(draw.indices.size()),
                @"display_list_depth":@(draw.displayListDepth), @"stages":stages}];
        }
        const BOOL savedArtwork = self.restoredArtworkEnabled, savedRedraw = self.sceneEdgeRedraw;
        NSString* savedSourceOnly = self.materialAuditSourceOnlyKey;
        const uint64_t savedCount = self.renderedFrameCount;
        NSString* digest = MotionVertexDigest(draws);
        NSMutableArray* samples = [NSMutableArray array];
        NSMutableArray* isolationSamples = [NSMutableArray array];
        NSMutableArray* noWriteSamples = [NSMutableArray array];
        const BOOL savedNoWriteBypass = self.disableNoWriteCulling;
        BOOL success = YES;
        self.sceneEdgeRedraw = YES; // Suppress diagnostic frame-count and movie-observation side effects.
        @try {
            self.materialAuditSourceOnlyKey = nil;
            if (self.materialAuditNoWriteProof) {
                // Use original textures for the reference so the failed bulk
                // replacement allocation is not required to prove equivalence.
                // All three draws use this same immutable translated frame.
                self.restoredArtworkEnabled = NO;
                for (NSUInteger variant = 0; variant < 3; ++variant) {
                    self.disableNoWriteCulling = variant == 1;
                    NSString* name = @[@"no-write-source.png", @"no-write-reference.png",
                        @"no-write-return.png"][variant];
                    if (![self renderDraws:draws efbCopies:copies frame:frameIndex error:error] ||
                        ![self writeLatestFrameToURL:[directory URLByAppendingPathComponent:name] error:error]) {
                        success = NO; break;
                    }
                    [noWriteSamples addObject:@{@"image":name, @"state":self.stateCapture}];
                }
                self.disableNoWriteCulling = savedNoWriteBypass;
            }
            for (NSUInteger variant = 0; success && variant < 2; ++variant) {
                self.restoredArtworkEnabled = variant != 0;
                NSString* name = variant ? @"restored.png" : @"source.png";
                if (![self renderDraws:draws efbCopies:copies frame:frameIndex error:error] ||
                    ![self writeLatestFrameToURL:[directory URLByAppendingPathComponent:name] error:error]) {
                    success = NO; break;
                }
                [samples addObject:@{@"image":name, @"state":self.stateCapture}];
            }
            if (success && self.materialAuditIsolate) {
                self.restoredArtworkEnabled = YES;
                for (NSUInteger variant = 0; variant < 3; ++variant) {
                    self.materialAuditSourceOnlyKey = variant == 1 ? key : nil;
                    NSString* name = @[@"isolated-restored.png", @"isolated-source.png", @"isolated-restored-return.png"][variant];
                    if (![self renderDraws:draws efbCopies:copies frame:frameIndex error:error] ||
                        ![self writeLatestFrameToURL:[directory URLByAppendingPathComponent:name] error:error]) {
                        success = NO; break;
                    }
                    [isolationSamples addObject:@{@"image":name, @"state":self.stateCapture}];
                }
            }
        } @finally {
            self.disableNoWriteCulling = savedNoWriteBypass;
            self.materialAuditSourceOnlyKey = savedSourceOnly;
            self.restoredArtworkEnabled = savedArtwork;
            if (![self renderDraws:draws efbCopies:copies frame:frameIndex error:error]) success = NO;
            self.sceneEdgeRedraw = savedRedraw;
        }
        if (!success) return NO;
        if (savedCount != self.renderedFrameCount || ![digest isEqual:MotionVertexDigest(draws)]) {
            if (error) *error = LiveError(37, @"Material inspection changed its source or frame count.");
            return NO;
        }
        if (NSDictionary* gallerySource = GalleryModelSourceAudit(draws,copies)) {
            NSMutableDictionary* galleryReport = [gallerySource mutableCopy];
            galleryReport[@"frame_index"] = @(frameIndex);
            galleryReport[@"guest_timebase"] = @(guestTicks);
            galleryReport[@"guest_updates_during_inspection"] = @0;
            NSData* galleryJSON = [NSJSONSerialization dataWithJSONObject:galleryReport
                options:NSJSONWritingPrettyPrinted error:error];
            if (!galleryJSON || ![galleryJSON writeToURL:[directory URLByAppendingPathComponent:@"gallery-model-source.json"]
                options:NSDataWritingWithoutOverwriting error:error]) return NO;
        }
        NSDictionary* report = @{@"schema":@"protector-native.material-source-inspection/v1",
            @"source":@"translated_execution_callback", @"source_key":key, @"frame_index":@(frameIndex),
            @"guest_timebase":@(guestTicks), @"guest_updates_during_inspection":@0,
            @"source_vertices_immutable":@YES, @"source_vertex_sha256":digest,
            @"readiness_gate_configured":@(self.materialAuditReadyPath != nil),
            @"readiness_gate_released":@(self.materialAuditReady),
            @"draws":records, @"samples":samples,
            @"no_write_proof_samples":noWriteSamples,
            @"isolation_samples":isolationSamples, @"isolation_enabled":@(self.materialAuditIsolate),
            @"isolation_policy":@"Selected exact source key and its directly required companion fall back atomically per draw; other replacements remain enabled. Pixel differences establish visible contribution, not every covered fragment.",
            @"limitations":@"First observed occurrence per exact key after any configured readiness gate. Frozen source/restored images do not establish motion or all-consumer acceptance."};
        NSData* json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:error];
        if (!json || ![json writeToURL:[directory URLByAppendingPathComponent:@"inspection.json"]
            options:NSDataWritingWithoutOverwriting error:error]) return NO;
        [self.materialAuditCaptured addObject:key];
    }
    return YES;
}

- (BOOL)captureCombatFeedback:(const std::vector<LiveDraw>&)draws copies:(const std::vector<LiveEfbCopy>&)copies
                        frame:(u32)frameIndex guestTicks:(uint64_t)guestTicks error:(NSError**)error {
    if (!self.combatFeedbackProofEnabled || self.combatFeedbackProofCaptured ||
        self.nativeCombatFeedbackFrame.size.height<=0 || !IdentifyCombatFeedback(draws,copies).enabled) return YES;
    NSURL* directory=[self.outputDirectory URLByAppendingPathComponent:@"combat-feedback" isDirectory:YES];
    if ([NSFileManager.defaultManager fileExistsAtPath:directory.path] ||
        ![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) {
        if (error && !*error) *error=LiveError(37,@"Combat feedback proof refuses an existing output directory.");
        return NO;
    }
    const CGRect savedFrame=self.nativeCombatFeedbackFrame;
    const BOOL savedRedraw=self.sceneEdgeRedraw;
    const uint64_t savedCount=self.renderedFrameCount;
    NSString* digest=MotionVertexDigest(draws);
    NSMutableArray* samples=[NSMutableArray array];
    BOOL success=YES;
    self.sceneEdgeRedraw=YES;
    @try {
        for(NSUInteger variant=0;variant<3;++variant) {
            self.nativeCombatFeedbackFrame=variant==1 ? CGRectZero : savedFrame;
            NSString* name=@[@"placed.png",@"source-position.png",@"placed-return.png"][variant];
            if(![self renderDraws:draws efbCopies:copies frame:frameIndex error:error] ||
                ![self writeLatestFrameToURL:[directory URLByAppendingPathComponent:name] error:error]) {
                success=NO;break;
            }
            [samples addObject:@{@"image":name,@"state":self.stateCapture}];
        }
    } @finally {
        self.nativeCombatFeedbackFrame=savedFrame;
        if(!success && ![self renderDraws:draws efbCopies:copies frame:frameIndex error:error]) success=NO;
        self.sceneEdgeRedraw=savedRedraw;
    }
    if(!success)return NO;
    if(savedCount!=self.renderedFrameCount || ![digest isEqual:MotionVertexDigest(draws)]) {
        if(error)*error=LiveError(37,@"Combat feedback inspection changed its source or frame count.");
        return NO;
    }
    NSDictionary* report=@{@"schema":@"protector-native.combat-feedback-proof/v1",
        @"source":@"translated_execution_callback",@"frame_index":@(frameIndex),@"guest_timebase":@(guestTicks),
        @"guest_updates_during_inspection":@0,@"source_vertices_immutable":@YES,@"source_vertex_sha256":digest,
        @"completed_unix":@(NSDate.date.timeIntervalSince1970),@"samples":samples,
        @"limitations":@"Same-source placement-only comparison. Renderer pixels exclude UIKit controls; native screen recording is separate. No performance qualification."};
    NSData* json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:error];
    if(!json || ![json writeToURL:[directory URLByAppendingPathComponent:@"inspection.json"]
        options:NSDataWritingWithoutOverwriting error:error])return NO;
    self.combatFeedbackProofCaptured=YES;
    return YES;
}

- (ProtectorLiveGXResult)consumeFrame:(u32)frameIndex
                                 fifo:(const u8*)fifo
                                 size:(size_t)fifoSize
                                  cpu:(CPUState*)cpu {
    return [self consumeFrame:frameIndex fifo:fifo size:fifoSize cpu:cpu hostDeadline:0];
}

- (ProtectorLiveGXResult)consumeFrame:(u32)frameIndex fifo:(const u8*)fifo
                                 size:(size_t)fifoSize cpu:(CPUState*)cpu hostDeadline:(double)deadline {
    // The display thread renders and presents under the renderer lock. Keep
    // this thread's share of it short: lifecycle checks and the cinematic
    // observation stay locked and ordered, decode and motion correspondence
    // run unlocked, and the result is committed in one short locked step.
    double lockWait = 0, lockHeld = 0;
    BOOL target = NO, planMotion = NO;
    MotionStageInputs inputs;
    double requested = CACurrentMediaTime();
    @synchronized(self) {
        const double acquired = CACurrentMediaTime();
        lockWait += acquired - requested;
        if (self.failure) return PROTECTOR_LIVE_GX_ERROR;
        if (self.complete) return PROTECTOR_LIVE_GX_COMPLETE;
        self.pendingHostDeadline = deadline;
        ProtectorCinematicFrame cinematic = protector_live_gx_cinematic_frame();
        if (cinematic.presentation_frame != frameIndex) {
            cinematic = ProtectorCinematicFrame{};
            cinematic.presentation_frame = frameIndex;
        }
        self.pendingCinematic = cinematic;
        [self.cinematicPack observeFrame:cinematic];
        target = self.continuousPresentation || [self.targetFrames containsIndex:frameIndex];
        planMotion = target && self.smoothMotionActive && self.motionHistory && self.artworkPreviewFrame;
        if (planMotion) inputs = [self motionStageInputs];
        lockHeld += CACurrentMediaTime() - acquired;
    }
    std::vector<LiveDraw> draws;
    std::vector<LiveEfbCopy> efbCopies;
    NSString* message = nil;
    bool decoded = false;
    DecoderStatsSnapshot stats;
    {
        // Only this thread decodes. Settings that touch decoder state take
        // the same mutex, never while this thread waits for the renderer.
        std::lock_guard<std::mutex> guard(_decoderMutex);
        auto* state = static_cast<DecoderState*>(self.decoderState);
        const char* geometryTrace = getenv("PROTECTOR_GEOMETRY_SOURCE_TRACE_FRAME");
        state->geometrySourceTrace = geometryTrace && strtoul(geometryTrace, nullptr, 10) == frameIndex;
        decoded = DecodeFrame(state, fifo, fifoSize, cpu, target, true, 0u, &draws, &efbCopies, &message);
        stats = SnapshotDecoderStats(*state);
    }
    if (decoded && target) MarkScreenCopyComposites(draws, efbCopies);
    if (decoded && target) {
        const ProtectorLiveComboFrame combo=protector_live_gx_combo_frame();
        if(combo.presentation_frame==frameIndex && combo.scheme>=1 && combo.scheme<=3)
            for(auto& draw:draws)draw.comboScheme=(u8)combo.scheme;
        const ProtectorLiveInteractionFrame interaction=protector_live_gx_interaction_frame();
        if(interaction.presentation_frame==frameIndex &&
            (interaction.prompts==PROTECTOR_QTE_SPECIAL || interaction.prompts==PROTECTOR_QTE_BLOCK ||
             interaction.prompts==PROTECTOR_QTE_JUMP || interaction.prompts==PROTECTOR_QTE_TRANSFORM))
            for(auto& draw:draws)draw.interactionPrompts=(u8)interaction.prompts;
        const ProtectorLiveUpgradeFrame upgrade=protector_live_gx_upgrade_frame();
        if(upgrade.presentation_frame==frameIndex && upgrade.active && upgrade.scheme<=3)
            for(auto& draw:draws) {
                draw.upgradeActive=true;draw.upgradeReady=upgrade.ready;draw.upgradeScheme=(u8)upgrade.scheme;
            }
    }
    MotionStagePlan plan;
    if (decoded && planMotion) {
        // Reads the current endpoint's draws/copies, which only this thread
        // writes; a concurrent reset is detected by generation at commit.
        plan = PlanMotionStage(*static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame), inputs,
            draws, efbCopies, frameIndex, cpu->timebase, deadline);
    }
    requested = CACurrentMediaTime();
    @synchronized(self) {
        const double acquired = CACurrentMediaTime();
        lockWait += acquired - requested;
        _decoderStats = stats;
        ProtectorLiveGXResult result = PROTECTOR_LIVE_GX_CONTINUE;
        if (self.failure) result = PROTECTOR_LIVE_GX_ERROR;
        else if (!decoded) {
            self.failure = LiveError(30, [NSString stringWithFormat:@"live GX frame %u failed: %@",
                frameIndex, message ? message : @"unknown decoder error"]);
            result = PROTECTOR_LIVE_GX_ERROR;
        } else if (target)
            result = [self consumeDecodedFrame:frameIndex draws:draws copies:efbCopies cpu:cpu
                plan:planMotion ? &plan : nullptr];
        lockHeld += CACurrentMediaTime() - acquired;
        // Guest-thread contention evidence: time waiting for the display
        // thread's encode, and time this thread blocks the display.
        self.guestLockWaitMax = std::max(self.guestLockWaitMax, lockWait);
        self.guestLockHeldMax = std::max(self.guestLockHeldMax, lockHeld);
        return result;
    }
}

- (ProtectorLiveGXResult)consumeDecodedFrame:(u32)frameIndex draws:(std::vector<LiveDraw>&)draws
                                      copies:(std::vector<LiveEfbCopy>&)efbCopies cpu:(CPUState*)cpu
                                        plan:(MotionStagePlan*)plan {
    if (draws.empty() && !self.continuousPresentation) {
        self.failure = LiveError(
            31,
            [NSString stringWithFormat:
                @"target live GX frame %u has no draws",
                frameIndex
            ]
        );
        return PROTECTOR_LIVE_GX_ERROR;
    }
    NSError* renderError = nil;
    if (![self captureCombatFeedback:draws copies:efbCopies frame:frameIndex guestTicks:cpu->timebase error:&renderError]) {
        self.failure=renderError;
        return PROTECTOR_LIVE_GX_ERROR;
    }
    if (![self captureMaterialSources:draws copies:efbCopies frame:frameIndex guestTicks:cpu->timebase error:&renderError]) {
        self.failure = renderError;
        return PROTECTOR_LIVE_GX_ERROR;
    }
    if (self.motionAuditLog) {
        self.motionAuditState = MotionCorrespondenceAudit(
            static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame), draws, frameIndex, nullptr, &efbCopies);
        // Deliberately bounded developer evidence, never an unbounded per-frame
        // production log. This mode does not generate or display new frames.
        if (self.motionAuditFrames < 4096) {
            NSMutableDictionary* receipt = [self.motionAuditState mutableCopy];
            receipt[@"guest_timebase"] = @(cpu->timebase);
            NSMutableData* line = [[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingSortedKeys
                error:&renderError] mutableCopy];
            [line appendBytes:"\n" length:1];
            if (!line || ![self.motionAuditLog writeData:line error:&renderError]) {
                self.failure = renderError ? renderError : LiveError(35, @"Could not write bounded motion audit.");
                return PROTECTOR_LIVE_GX_ERROR;
            }
            ++self.motionAuditFrames;
        }
    }
    if (self.smoothMotionActive) {
        [self stageMotionDraws:draws copies:efbCopies frame:frameIndex guestTicks:cpu->timebase
            deadline:self.pendingHostDeadline plan:plan];
        return PROTECTOR_LIVE_GX_CONTINUE;
    }
    if (![self captureMotionProof:draws efbCopies:efbCopies frame:frameIndex guestTicks:cpu->timebase error:&renderError] ||
        ![self renderDraws:draws
                 efbCopies:efbCopies
                     frame:frameIndex
                     error:&renderError]) {
        self.failure = renderError;
        return PROTECTOR_LIVE_GX_ERROR;
    }
    if (self.continuousPresentation) {
        if (self.interfaceAuditMinimumFrame && !self.interfaceAuditCaptured &&
            frameIndex >= self.interfaceAuditMinimumFrame &&
            (!self.interfaceAuditCombatFeedback || CombatFeedbackAuditContainsLabel(draws)) &&
            (!self.interfaceAuditSourceKey || InterfaceAuditContainsSource(draws,self.interfaceAuditSourceKey)) &&
            (!self.sceneEdgeAuditEnabled || (IdentifyNativeHud(draws).count &&
                std::none_of(draws.begin(), draws.end(), [](const LiveDraw& draw) {
                    return ClassifyWideDraw(draw) == WideDrawRole::ScreenFill &&
                        !draw.vertices.empty() && draw.vertices.front().color[3] > 0.01f;
                })))) {
            NSURL* directory = [self.outputDirectory URLByAppendingPathComponent:@"interface-source" isDirectory:YES];
            if ([NSFileManager.defaultManager fileExistsAtPath:directory.path] ||
                ![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO
                    attributes:nil error:&renderError]) {
                self.failure = renderError ? renderError : LiveError(37, @"Interface audit refuses an existing output directory.");
                return PROTECTOR_LIVE_GX_ERROR;
            }
            NSMutableDictionary<NSString*, NSData*>* textures = [NSMutableDictionary dictionary];
            NSMutableDictionary* report = [InterfaceSourceAudit(draws, efbCopies, textures) mutableCopy];
            report[@"frame_index"] = @(frameIndex);
            report[@"guest_timebase"] = @(cpu->timebase);
            report[@"render_state"] = self.stateCapture;
            report[@"source"] = @"translated_execution_callback";
            if (self.interfaceAuditSourceKey) report[@"capture_source_key"] = self.interfaceAuditSourceKey;
            if (self.interfaceAuditCombatFeedback) report[@"capture_combat_feedback"] = @YES;
            BOOL written = YES;
            for (NSString* key in textures) {
                NSURL* path = [directory URLByAppendingPathComponent:[key stringByAppendingString:@".rgba"]];
                if (![textures[key] writeToURL:path options:NSDataWritingWithoutOverwriting error:&renderError]) {
                    written = NO;
                    break;
                }
            }
            NSData* json = written ? [NSJSONSerialization dataWithJSONObject:report
                options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&renderError] : nil;
            if (!json || ![json writeToURL:[directory URLByAppendingPathComponent:@"audit.json"]
                    options:NSDataWritingWithoutOverwriting error:&renderError] ||
                ![self writeLatestFrameToURL:[directory URLByAppendingPathComponent:@"frame.png"] error:&renderError]) {
                self.failure = renderError ? renderError : LiveError(37, @"Could not write bounded interface-source audit.");
                return PROTECTOR_LIVE_GX_ERROR;
            }
            self.interfaceAuditCaptured = YES;
            if (![self captureSceneEdges:draws copies:efbCopies frame:frameIndex directory:directory error:&renderError]) {
                self.failure = renderError;
                return PROTECTOR_LIVE_GX_ERROR;
            }
        }
        if (self.artworkPreviewFrame) {
            auto* snapshot = static_cast<ArtworkPreviewFrame*>(self.artworkPreviewFrame);
            snapshot->draws = std::move(draws);
            snapshot->copies = std::move(efbCopies);
            snapshot->index = frameIndex;
            snapshot->guestTicks = cpu->timebase;
            snapshot->cinematic = self.pendingCinematic;
            snapshot->valid = true;
            ++_motionStateGeneration;
        }
        return PROTECTOR_LIVE_GX_CONTINUE;
    }
    self.complete = self.submissions.count == self.targetFrames.count;
    const DecoderStatsSnapshot decoderStats = _decoderStats;
    [self publishStateCapture:@{
        @"schema" : @"protector-native.live-metal/v1",
        @"source" : @"translated_execution_callback",
        @"external_scene_pack" : @NO,
        @"device" : self.device.name,
        @"target_frames" : self.targetFrameValues,
        @"submissions" : [self.submissions copy],
        @"texture_decode_cache_enabled" : @(decoderStats.cacheEnabled),
        @"texture_decode_cache_hits" : @(decoderStats.hits),
        @"texture_decode_cache_misses" : @(decoderStats.misses),
        @"texture_decode_cache_evictions" : @(decoderStats.evictions),
        @"texture_decode_cache_bytes" : @(decoderStats.bytes),
        @"indexed_vertices_enabled" : @(decoderStats.indexedVertices),
        @"indexed_xf_loads" : @(decoderStats.indexedXFLoads),
        @"complete" : @(self.complete),
    }];
    return self.complete
        ? PROTECTOR_LIVE_GX_COMPLETE
        : PROTECTOR_LIVE_GX_CONTINUE;
}

@end
