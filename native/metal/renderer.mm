#import "protector/metal_renderer.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>

static NSString* const ProtectorMetalErrorDomain =
    @"house.machine.ProtectorNative.Metal";

typedef struct {
    simd_float4x4 mvp;
    simd_float4 materialColor;
    simd_float4 lighting;
    simd_float4 uvAnimation;
    simd_float4 fog;
    simd_float4 fogColor;
} ProtectorUniforms;

typedef struct {
    float position[3];
    float normal[3];
    float uv[2];
} ProtectorPackedVertex;

static NSString* const ProtectorShaderSource = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct ProtectorVertex {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 uv;
};

struct ProtectorUniforms {
    float4x4 mvp;
    float4 materialColor;
    float4 lighting;
    float4 uvAnimation;
    float4 fog;
    float4 fogColor;
};

struct ProtectorVarying {
    float4 position [[position]];
    float3 normal;
    float2 uv;
    float fogDepth;
};

vertex ProtectorVarying protector_vertex(
    uint vertexID [[vertex_id]],
    const device ProtectorVertex* vertices [[buffer(0)]],
    constant ProtectorUniforms& uniforms [[buffer(1)]]
) {
    ProtectorVertex input = vertices[vertexID];
    ProtectorVarying output;
    output.position = uniforms.mvp * float4(float3(input.position), 1.0);
    output.normal = normalize(float3(input.normal));
    output.uv = float2(input.uv) + uniforms.uvAnimation.xy;
    output.fogDepth = output.position.z / max(output.position.w, 0.00001);
    return output;
}

fragment float4 protector_fragment(
    ProtectorVarying input [[stage_in]],
    texture2d<float> colorTexture [[texture(0)]],
    sampler colorSampler [[sampler(0)]],
    constant ProtectorUniforms& uniforms [[buffer(1)]]
) {
    float4 texel = colorTexture.sample(colorSampler, input.uv);
    float4 material = texel * uniforms.materialColor;
    if (material.a <= (1.0 / 255.0)) {
        discard_fragment();
    }
    float lightingEnabled = uniforms.lighting.x;
    float ambient = uniforms.lighting.y;
    float diffuse = uniforms.lighting.z;
    float3 lightDirection = normalize(float3(-0.38, 0.82, 0.43));
    float lambert = max(dot(normalize(input.normal), lightDirection), 0.0);
    float light = mix(1.0, clamp(ambient + diffuse * lambert, 0.0, 1.0),
                      lightingEnabled);
    float3 litColor = material.rgb * light;
    float fogRange = max(uniforms.fog.z - uniforms.fog.y, 0.00001);
    float fogAmount = clamp((input.fogDepth - uniforms.fog.y) / fogRange,
                            0.0, 1.0) * uniforms.fog.x;
    return float4(mix(litColor, uniforms.fogColor.rgb, fogAmount),
                  material.a);
}
)METAL";

static NSError* ProtectorError(NSInteger code, NSString* message) {
    return [NSError errorWithDomain:ProtectorMetalErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

static simd_float4x4 ProtectorLookAt(
    simd_float3 eye,
    simd_float3 target,
    simd_float3 up
) {
    simd_float3 z = simd_normalize(target - eye);
    simd_float3 x = simd_normalize(simd_cross(up, z));
    simd_float3 y = simd_cross(z, x);
    return simd_float4x4{
        simd_float4{x.x, y.x, z.x, 0.0f},
        simd_float4{x.y, y.y, z.y, 0.0f},
        simd_float4{x.z, y.z, z.z, 0.0f},
        simd_float4{
            -simd_dot(x, eye),
            -simd_dot(y, eye),
            -simd_dot(z, eye),
            1.0f,
        },
    };
}

static simd_float4x4 ProtectorPerspective(
    float verticalFov,
    float aspect,
    float nearPlane,
    float farPlane
) {
    float yScale = 1.0f / tanf(verticalFov * 0.5f);
    float xScale = yScale / aspect;
    float zScale = farPlane / (farPlane - nearPlane);
    return simd_float4x4{
        simd_float4{xScale, 0.0f, 0.0f, 0.0f},
        simd_float4{0.0f, yScale, 0.0f, 0.0f},
        simd_float4{0.0f, 0.0f, zScale, 1.0f},
        simd_float4{0.0f, 0.0f, -nearPlane * zScale, 0.0f},
    };
}

static simd_float4x4 ProtectorGameplayLookAt(
    simd_float3 eye,
    simd_float3 target,
    simd_float3 up
) {
    simd_float3 backward = simd_normalize(eye - target);
    simd_float3 right = simd_normalize(simd_cross(up, backward));
    simd_float3 cameraUp = simd_cross(backward, right);
    return simd_float4x4{
        simd_float4{right.x, cameraUp.x, backward.x, 0.0f},
        simd_float4{right.y, cameraUp.y, backward.y, 0.0f},
        simd_float4{right.z, cameraUp.z, backward.z, 0.0f},
        simd_float4{
            -simd_dot(right, eye),
            -simd_dot(cameraUp, eye),
            -simd_dot(backward, eye),
            1.0f,
        },
    };
}

static simd_float4x4 ProtectorGameplayPerspective(
    float verticalFov,
    float aspect,
    float nearPlane,
    float farPlane
) {
    float yScale = 1.0f / tanf(verticalFov * 0.5f);
    float xScale = yScale / aspect;
    float zScale = farPlane / (nearPlane - farPlane);
    return simd_float4x4{
        simd_float4{xScale, 0.0f, 0.0f, 0.0f},
        simd_float4{0.0f, yScale, 0.0f, 0.0f},
        simd_float4{0.0f, 0.0f, zScale, -1.0f},
        simd_float4{0.0f, 0.0f, nearPlane * zScale, 0.0f},
    };
}

static simd_float4x4 ProtectorTranslationScale(
    simd_float3 translation,
    simd_float3 scale
) {
    return simd_float4x4{
        simd_float4{scale.x, 0.0f, 0.0f, 0.0f},
        simd_float4{0.0f, scale.y, 0.0f, 0.0f},
        simd_float4{0.0f, 0.0f, scale.z, 0.0f},
        simd_float4{translation.x, translation.y, translation.z, 1.0f},
    };
}

static simd_float4x4 ProtectorTranslationRotationScale(
    simd_float3 translation,
    simd_float3 rotation,
    simd_float3 scale
) {
    const float cx = cosf(rotation.x);
    const float sx = sinf(rotation.x);
    const float cy = cosf(rotation.y);
    const float sy = sinf(rotation.y);
    const float cz = cosf(rotation.z);
    const float sz = sinf(rotation.z);
    const simd_float4x4 rotateX = {
        simd_float4{1.0f, 0.0f, 0.0f, 0.0f},
        simd_float4{0.0f, cx, sx, 0.0f},
        simd_float4{0.0f, -sx, cx, 0.0f},
        simd_float4{0.0f, 0.0f, 0.0f, 1.0f},
    };
    const simd_float4x4 rotateY = {
        simd_float4{cy, 0.0f, -sy, 0.0f},
        simd_float4{0.0f, 1.0f, 0.0f, 0.0f},
        simd_float4{sy, 0.0f, cy, 0.0f},
        simd_float4{0.0f, 0.0f, 0.0f, 1.0f},
    };
    const simd_float4x4 rotateZ = {
        simd_float4{cz, sz, 0.0f, 0.0f},
        simd_float4{-sz, cz, 0.0f, 0.0f},
        simd_float4{0.0f, 0.0f, 1.0f, 0.0f},
        simd_float4{0.0f, 0.0f, 0.0f, 1.0f},
    };
    const simd_float4x4 scaleMatrix = ProtectorTranslationScale(
        simd_float3{0.0f, 0.0f, 0.0f},
        scale
    );
    simd_float4x4 model = simd_mul(
        rotateY,
        simd_mul(rotateZ, simd_mul(rotateX, scaleMatrix))
    );
    model.columns[3] =
        simd_float4{translation.x, translation.y, translation.z, 1.0f};
    return model;
}

static NSData* ProtectorActorCubeVertices(void) {
    static const simd_float3 corners[] = {
        {-0.5f, 0.0f, -0.5f},
        {0.5f, 0.0f, -0.5f},
        {0.5f, 1.0f, -0.5f},
        {-0.5f, 1.0f, -0.5f},
        {-0.5f, 0.0f, 0.5f},
        {0.5f, 0.0f, 0.5f},
        {0.5f, 1.0f, 0.5f},
        {-0.5f, 1.0f, 0.5f},
    };
    static const NSUInteger faces[][4] = {
        {0, 3, 2, 1},
        {4, 5, 6, 7},
        {0, 4, 7, 3},
        {1, 2, 6, 5},
        {3, 7, 6, 2},
        {0, 1, 5, 4},
    };
    static const simd_float3 normals[] = {
        {0.0f, 0.0f, -1.0f},
        {0.0f, 0.0f, 1.0f},
        {-1.0f, 0.0f, 0.0f},
        {1.0f, 0.0f, 0.0f},
        {0.0f, 1.0f, 0.0f},
        {0.0f, -1.0f, 0.0f},
    };
    static const NSUInteger triangleOrder[] = {0, 1, 2, 0, 2, 3};
    static const float uvs[][2] = {
        {0.0f, 0.0f},
        {0.0f, 1.0f},
        {1.0f, 1.0f},
        {1.0f, 0.0f},
    };
    NSMutableData* data = [NSMutableData
        dataWithLength:6 * 6 * sizeof(ProtectorPackedVertex)];
    ProtectorPackedVertex* vertices =
        (ProtectorPackedVertex*)data.mutableBytes;
    NSUInteger cursor = 0;
    for (NSUInteger face = 0; face < 6; ++face) {
        for (NSUInteger vertex = 0; vertex < 6; ++vertex) {
            NSUInteger cornerInFace = triangleOrder[vertex];
            simd_float3 position = corners[faces[face][cornerInFace]];
            simd_float3 normal = normals[face];
            ProtectorPackedVertex packed = {};
            packed.position[0] = position.x;
            packed.position[1] = position.y;
            packed.position[2] = position.z;
            packed.normal[0] = normal.x;
            packed.normal[1] = normal.y;
            packed.normal[2] = normal.z;
            packed.uv[0] = uvs[cornerInFace][0];
            packed.uv[1] = uvs[cornerInFace][1];
            vertices[cursor] = packed;
            cursor++;
        }
    }
    return data;
}

static simd_float3 ProtectorVector3(NSArray* value) {
    return simd_float3{
        [value[0] floatValue],
        [value[1] floatValue],
        [value[2] floatValue],
    };
}

static MTLSamplerAddressMode ProtectorAddressMode(NSString* value) {
    if ([value isEqualToString:@"repeat"]) {
        return MTLSamplerAddressModeRepeat;
    }
    if ([value isEqualToString:@"mirror"]) {
        return MTLSamplerAddressModeMirrorRepeat;
    }
    return MTLSamplerAddressModeClampToEdge;
}

static MTLSamplerMipFilter ProtectorMipFilter(NSString* value) {
    if ([value hasSuffix:@"mipmap_linear"]) {
        return MTLSamplerMipFilterLinear;
    }
    if ([value containsString:@"mipmap"]) {
        return MTLSamplerMipFilterNearest;
    }
    return MTLSamplerMipFilterNotMipmapped;
}

@interface ProtectorMetalRenderer ()
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLBuffer> vertexBuffer;
@property(nonatomic, strong) id<MTLBuffer> actorVertexBuffer;
@property(nonatomic, strong) NSArray<NSDictionary*>* draws;
@property(nonatomic, strong) NSArray<NSDictionary*>* gameplayActors;
@property(nonatomic, strong) NSArray<id<MTLTexture>>* textures;
@property(nonatomic, strong) NSArray<id<MTLSamplerState>>* samplers;
@property(nonatomic, strong)
    NSDictionary<NSString*, id<MTLRenderPipelineState>>* pipelines;
@property(nonatomic, strong)
    NSDictionary<NSString*, id<MTLDepthStencilState>>* depthStates;
@property(nonatomic, readwrite) NSUInteger width;
@property(nonatomic, readwrite) NSUInteger height;
@property(nonatomic, readwrite) NSUInteger preferredFramesPerSecond;
@property(nonatomic, readwrite)
    NSDictionary<NSString*, id>* stateCapture;
@property(nonatomic) simd_float4x4 mvp;
@property(nonatomic) float verticalFieldOfView;
@property(nonatomic) float nearPlane;
@property(nonatomic) float farPlane;
@property(nonatomic) BOOL gameplayRightHandedCamera;
@property(nonatomic) simd_float4 fog;
@property(nonatomic) simd_float4 fogColor;
@property(nonatomic, strong) id<MTLTexture> whiteTexture;
@property(nonatomic, strong) id<MTLSamplerState> whiteSampler;
@end

@implementation ProtectorMetalRenderer

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                           scenePackURL:(NSURL*)scenePackURL
                                  error:(NSError**)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    _device = device;
    _commandQueue = [device newCommandQueue];
    if (!_commandQueue) {
        if (error) {
            *error = ProtectorError(1, @"Metal command queue creation failed");
        }
        return nil;
    }

    NSURL* manifestURL = [scenePackURL URLByAppendingPathComponent:@"scene.json"];
    NSData* manifestData = [NSData dataWithContentsOfURL:manifestURL
                                                options:0
                                                  error:error];
    if (!manifestData) {
        return nil;
    }
    NSDictionary* manifest =
        [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:error];
    if (![manifest[@"schema"]
            isEqualToString:@"protector-native.gx-scene/v1"]) {
        if (error) {
            *error = ProtectorError(
                2,
                [NSString stringWithFormat:
                    @"Unsupported or missing GX scene schema: %@ (%@)",
                    manifest[@"schema"],
                    [manifest[@"schema"] class]]
            );
        }
        return nil;
    }
    NSDictionary* frame = manifest[@"frame"];
    _width = [frame[@"width"] unsignedIntegerValue];
    _height = [frame[@"height"] unsignedIntegerValue];
    _preferredFramesPerSecond =
        [frame[@"frame_rate"] unsignedIntegerValue];
    if (_width != 640 || _height != 480 || _preferredFramesPerSecond != 30) {
        if (error) {
            *error = ProtectorError(
                3,
                @"Milestone 4 requires the original 640x480 30 Hz baseline"
            );
        }
        return nil;
    }
    NSDictionary* fog = frame[@"fog"];
    NSString* fogMode = fog[@"mode"];
    if (![fogMode isEqualToString:@"off"] &&
        ![fogMode isEqualToString:@"linear"]) {
        if (error) {
            *error = ProtectorError(4, @"Unsupported GX fog mode");
        }
        return nil;
    }
    NSArray* fogColor = fog[@"color"];
    if (fogColor.count != 4) {
        if (error) {
            *error = ProtectorError(5, @"GX fog color is missing");
        }
        return nil;
    }
    _fog = simd_float4{
        [fogMode isEqualToString:@"linear"] ? 1.0f : 0.0f,
        [fog[@"start"] floatValue],
        [fog[@"end"] floatValue],
        0.0f,
    };
    _fogColor = simd_float4{
        [fogColor[0] floatValue],
        [fogColor[1] floatValue],
        [fogColor[2] floatValue],
        [fogColor[3] floatValue],
    };

    NSDictionary* vertexLayout = manifest[@"vertex_layout"];
    if ([vertexLayout[@"stride"] unsignedIntegerValue] != 32) {
        if (error) {
            *error = ProtectorError(6, @"Unexpected GX scene vertex stride");
        }
        return nil;
    }
    NSURL* vertexURL =
        [scenePackURL URLByAppendingPathComponent:vertexLayout[@"path"]];
    NSData* vertices = [NSData dataWithContentsOfURL:vertexURL
                                            options:NSDataReadingMappedIfSafe
                                              error:error];
    if (!vertices) {
        return nil;
    }
    NSUInteger expectedVertexCount = [vertexLayout[@"count"] unsignedIntegerValue];
    if (vertices.length != expectedVertexCount * 32) {
        if (error) {
            *error = ProtectorError(7, @"GX vertex buffer length mismatch");
        }
        return nil;
    }
    _vertexBuffer = [device newBufferWithBytes:vertices.bytes
                                        length:vertices.length
                                       options:MTLResourceStorageModeShared];
    _vertexBuffer.label = @"RBNEG9 Canyon GX vertices";
    NSData* actorVertices = ProtectorActorCubeVertices();
    _actorVertexBuffer =
        [device newBufferWithBytes:actorVertices.bytes
                           length:actorVertices.length
                          options:MTLResourceStorageModeShared];
    _actorVertexBuffer.label = @"Milestone 5 temporary actor proxy vertices";
    _gameplayActors = @[];

    NSError* libraryError = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:ProtectorShaderSource
                                                 options:nil
                                                   error:&libraryError];
    if (!library) {
        if (error) {
            *error = ProtectorError(
                8,
                [NSString stringWithFormat:
                    @"Metal shader compilation failed: %@",
                    libraryError.localizedDescription]
            );
        }
        return nil;
    }
    id<MTLFunction> vertexFunction =
        [library newFunctionWithName:@"protector_vertex"];
    id<MTLFunction> fragmentFunction =
        [library newFunctionWithName:@"protector_fragment"];
    if (!vertexFunction || !fragmentFunction) {
        if (error) {
            *error = ProtectorError(9, @"Metal entry points are missing");
        }
        return nil;
    }

    NSMutableDictionary* pipelines = [NSMutableDictionary dictionary];
    for (NSString* blend in @[@"opaque", @"source_alpha", @"shadow_subtract"]) {
        MTLRenderPipelineDescriptor* descriptor =
            [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label =
            [NSString stringWithFormat:@"GX TEV %@", blend];
        descriptor.vertexFunction = vertexFunction;
        descriptor.fragmentFunction = fragmentFunction;
        descriptor.colorAttachments[0].pixelFormat =
            MTLPixelFormatBGRA8Unorm_sRGB;
        descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        MTLRenderPipelineColorAttachmentDescriptor* color =
            descriptor.colorAttachments[0];
        if (![blend isEqualToString:@"opaque"]) {
            color.blendingEnabled = YES;
            if ([blend isEqualToString:@"source_alpha"]) {
                color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                color.destinationRGBBlendFactor =
                    MTLBlendFactorOneMinusSourceAlpha;
                color.sourceAlphaBlendFactor = MTLBlendFactorOne;
                color.destinationAlphaBlendFactor =
                    MTLBlendFactorOneMinusSourceAlpha;
            } else {
                color.rgbBlendOperation = MTLBlendOperationReverseSubtract;
                color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                color.destinationRGBBlendFactor = MTLBlendFactorOne;
                color.sourceAlphaBlendFactor = MTLBlendFactorZero;
                color.destinationAlphaBlendFactor = MTLBlendFactorOne;
            }
        }
        id<MTLRenderPipelineState> pipeline =
            [device newRenderPipelineStateWithDescriptor:descriptor error:error];
        if (!pipeline) {
            return nil;
        }
        pipelines[blend] = pipeline;
    }
    _pipelines = [pipelines copy];

    NSMutableDictionary* depthStates = [NSMutableDictionary dictionary];
    for (NSString* key in @[
        @"less_equal_write",
        @"less_equal_read",
        @"always_read",
    ]) {
        MTLDepthStencilDescriptor* descriptor =
            [[MTLDepthStencilDescriptor alloc] init];
        descriptor.depthCompareFunction =
            [key hasPrefix:@"always"]
                ? MTLCompareFunctionAlways
                : MTLCompareFunctionLessEqual;
        descriptor.depthWriteEnabled = [key hasSuffix:@"write"];
        depthStates[key] = [device newDepthStencilStateWithDescriptor:descriptor];
    }
    _depthStates = [depthStates copy];

    NSArray* textureRecords = manifest[@"textures"];
    NSMutableArray* textures = [NSMutableArray arrayWithCapacity:textureRecords.count];
    NSMutableArray* samplers = [NSMutableArray arrayWithCapacity:textureRecords.count];
    for (NSDictionary* record in textureRecords) {
        NSArray* levels = record[@"levels"];
        NSUInteger mipCount = levels.count;
        MTLTextureDescriptor* descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                MTLPixelFormatRGBA8Unorm_sRGB
                                                            width:
                [record[@"width"] unsignedIntegerValue]
                                                           height:
                [record[@"height"] unsignedIntegerValue]
                                                        mipmapped:mipCount > 1];
        descriptor.mipmapLevelCount = mipCount;
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        texture.label = [NSString stringWithFormat:
            @"GX texture %@", record[@"resource_offset"]];
        for (NSDictionary* level in levels) {
            NSURL* levelURL =
                [scenePackURL URLByAppendingPathComponent:level[@"path"]];
            NSData* rgba = [NSData dataWithContentsOfURL:levelURL
                                                options:NSDataReadingMappedIfSafe
                                                  error:error];
            if (!rgba) {
                return nil;
            }
            NSUInteger levelWidth = [level[@"width"] unsignedIntegerValue];
            NSUInteger levelHeight = [level[@"height"] unsignedIntegerValue];
            if (rgba.length != levelWidth * levelHeight * 4) {
                if (error) {
                    *error = ProtectorError(10, @"Decoded GX mip length mismatch");
                }
                return nil;
            }
            [texture replaceRegion:MTLRegionMake2D(0, 0, levelWidth, levelHeight)
                       mipmapLevel:[level[@"level"] unsignedIntegerValue]
                         withBytes:rgba.bytes
                       bytesPerRow:levelWidth * 4];
        }
        MTLSamplerDescriptor* samplerDescriptor =
            [[MTLSamplerDescriptor alloc] init];
        samplerDescriptor.sAddressMode = ProtectorAddressMode(record[@"wrap_s"]);
        samplerDescriptor.tAddressMode = ProtectorAddressMode(record[@"wrap_t"]);
        samplerDescriptor.minFilter =
            [record[@"min_filter"] hasPrefix:@"nearest"]
                ? MTLSamplerMinMagFilterNearest
                : MTLSamplerMinMagFilterLinear;
        samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
        samplerDescriptor.mipFilter = ProtectorMipFilter(record[@"min_filter"]);
        samplerDescriptor.lodBias = [record[@"lod_bias"] floatValue];
        samplerDescriptor.maxAnisotropy = 1;
        id<MTLSamplerState> sampler =
            [device newSamplerStateWithDescriptor:samplerDescriptor];
        [textures addObject:texture];
        [samplers addObject:sampler];
    }
    _textures = [textures copy];
    _samplers = [samplers copy];

    MTLTextureDescriptor* whiteDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatRGBA8Unorm_sRGB
                                                        width:1
                                                       height:1
                                                    mipmapped:NO];
    whiteDescriptor.storageMode = MTLStorageModeShared;
    _whiteTexture = [device newTextureWithDescriptor:whiteDescriptor];
    const uint8_t white[] = {255, 255, 255, 255};
    [_whiteTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                     mipmapLevel:0
                       withBytes:white
                     bytesPerRow:4];
    MTLSamplerDescriptor* whiteSamplerDescriptor =
        [[MTLSamplerDescriptor alloc] init];
    _whiteSampler = [device newSamplerStateWithDescriptor:whiteSamplerDescriptor];

    _draws = manifest[@"draws"];
    NSDictionary* camera = manifest[@"camera"];
    simd_float3 eye = ProtectorVector3(camera[@"eye"]);
    simd_float3 target = ProtectorVector3(camera[@"target"]);
    simd_float3 up = ProtectorVector3(camera[@"up"]);
    float fieldOfView =
        [camera[@"vertical_fov_degrees"] floatValue] *
        (float)M_PI / 180.0f;
    _verticalFieldOfView = fieldOfView;
    _nearPlane = [camera[@"near"] floatValue];
    _farPlane = [camera[@"far"] floatValue];
    simd_float4x4 view = ProtectorLookAt(eye, target, up);
    simd_float4x4 projection = ProtectorPerspective(
        fieldOfView,
        (float)_width / (float)_height,
        _nearPlane,
        _farPlane
    );
    _mvp = simd_mul(projection, view);

    NSURL* gxStateURL =
        [scenePackURL URLByAppendingPathComponent:manifest[@"gx_state"][@"path"]];
    NSData* gxStateData = [NSData dataWithContentsOfURL:gxStateURL
                                               options:0
                                                 error:error];
    if (!gxStateData) {
        return nil;
    }
    NSDictionary* gxState =
        [NSJSONSerialization JSONObjectWithData:gxStateData options:0 error:error];
    if (!gxState) {
        return nil;
    }
    _stateCapture = @{
        @"schema" : @"protector-native.gpu-state/metal-v1",
        @"source_gx_capture" : gxState,
        @"metal" : @{
            @"device" : device.name,
            @"color_format" : @"BGRA8Unorm_sRGB",
            @"texture_format" : @"RGBA8Unorm_sRGB",
            @"depth_format" : @"Depth32Float",
            @"pipeline_count" : @(_pipelines.count),
            @"depth_state_count" : @(_depthStates.count),
            @"texture_count" : @(_textures.count),
            @"draw_count" : @(_draws.count),
            @"vertex_buffer_bytes" : @(vertices.length),
            @"runtime_shader_compilation" : @YES,
            @"jit" : @NO,
            @"fog_mode" : fogMode,
            @"alpha_compare" : @"final_material_alpha_greater_than_1_over_255",
        },
    };
    return self;
}

- (BOOL)encodeFrameAtTime:(double)time
                  texture:(id<MTLTexture>)texture
             commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    error:(NSError**)error {
    if (texture.width != self.width || texture.height != self.height ||
        texture.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB) {
        if (error) {
            *error = ProtectorError(11, @"Metal render target contract mismatch");
        }
        return NO;
    }
    MTLTextureDescriptor* depthDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatDepth32Float
                                                        width:self.width
                                                       height:self.height
                                                    mipmapped:NO];
    depthDescriptor.storageMode = MTLStorageModePrivate;
    depthDescriptor.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> depthTexture =
        [self.device newTextureWithDescriptor:depthDescriptor];

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor =
        MTLClearColorMake(0.67, 0.77, 0.87, 1.0);
    pass.depthAttachment.texture = depthTexture;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;
    pass.depthAttachment.clearDepth = 1.0;
    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        if (error) {
            *error = ProtectorError(12, @"Metal render encoder creation failed");
        }
        return NO;
    }
    encoder.label = @"RBNEG9 Canyon first frame";
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [encoder setVertexBuffer:self.vertexBuffer offset:0 atIndex:0];

    for (NSDictionary* draw in self.draws) {
        NSDictionary* material = draw[@"material"];
        NSString* blend = material[@"blend"];
        id<MTLRenderPipelineState> pipeline = self.pipelines[blend];
        if (!pipeline) {
            [encoder endEncoding];
            if (error) {
                *error = ProtectorError(13, @"Missing cached GX/Metal pipeline");
            }
            return NO;
        }
        [encoder setRenderPipelineState:pipeline];
        BOOL depthWrite = [material[@"depth_write"] boolValue];
        NSString* depthCompare = material[@"depth_compare"];
        NSString* depthKey = [NSString stringWithFormat:
            @"%@_%@",
            depthCompare,
            depthWrite ? @"write" : @"read"];
        [encoder setDepthStencilState:
            self.depthStates[depthKey]];
        [encoder setCullMode:
            [material[@"cull"] isEqualToString:@"front"]
                ? self.gameplayRightHandedCamera
                    ? MTLCullModeFront
                    : MTLCullModeBack
                : MTLCullModeNone];

        NSInteger textureIndex = [draw[@"texture_index"] integerValue];
        id<MTLTexture> drawTexture = self.whiteTexture;
        id<MTLSamplerState> drawSampler = self.whiteSampler;
        if (textureIndex >= 0) {
            drawTexture = self.textures[(NSUInteger)textureIndex];
            drawSampler = self.samplers[(NSUInteger)textureIndex];
        }
        [encoder setFragmentTexture:drawTexture atIndex:0];
        [encoder setFragmentSamplerState:drawSampler atIndex:0];

        NSArray* color = draw[@"material_color"];
        NSDictionary* dynamic = draw[@"dynamic"];
        float uOffset = 0.0f;
        float vOffset = 0.0f;
        if ([dynamic isKindOfClass:[NSDictionary class]] &&
            [dynamic[@"kind"] isEqualToString:@"uv_animation"]) {
            double uFrequency = [dynamic[@"u_frequency"] doubleValue];
            double vFrequency = [dynamic[@"v_frequency"] doubleValue];
            double uPhase = [dynamic[@"u_phase"] doubleValue];
            double vPhase = [dynamic[@"v_phase"] doubleValue];
            uOffset = (float)([dynamic[@"u_amplitude"] doubleValue] *
                sin(time * uFrequency + uPhase));
            vOffset = (float)([dynamic[@"v_amplitude"] doubleValue] *
                sin(time * vFrequency + vPhase));
        }
        ProtectorUniforms uniforms = {};
        uniforms.mvp = self.mvp;
        uniforms.materialColor = simd_float4{
            [color[0] floatValue],
            [color[1] floatValue],
            [color[2] floatValue],
            [color[3] floatValue],
        };
        uniforms.lighting = simd_float4{
            [material[@"lighting"] boolValue] ? 1.0f : 0.0f,
            [draw[@"ambient"] floatValue],
            [draw[@"diffuse"] floatValue],
            0.0f,
        };
        uniforms.uvAnimation =
            simd_float4{uOffset, vOffset, 0.0f, 0.0f};
        uniforms.fog = self.fog;
        uniforms.fogColor = self.fogColor;
        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:[draw[@"vertex_offset"] unsignedIntegerValue]
                    vertexCount:[draw[@"vertex_count"] unsignedIntegerValue]];
    }

    if (self.gameplayActors.count > 0) {
        [encoder setRenderPipelineState:self.pipelines[@"opaque"]];
        [encoder setDepthStencilState:self.depthStates[@"less_equal_write"]];
        [encoder setCullMode:MTLCullModeBack];
        [encoder setFragmentTexture:self.whiteTexture atIndex:0];
        [encoder setFragmentSamplerState:self.whiteSampler atIndex:0];
        [encoder setVertexBuffer:self.actorVertexBuffer offset:0 atIndex:0];
        for (NSDictionary* actor in self.gameplayActors) {
            NSArray* position = actor[@"position"];
            NSArray* scale = actor[@"scale"];
            NSArray* rotation = actor[@"rotation"];
            NSArray* color = actor[@"color"];
            if (position.count != 3 || scale.count != 3 ||
                color.count != 4) {
                continue;
            }
            [encoder setRenderPipelineState:
                [actor[@"blend"] isEqualToString:@"source_alpha"]
                    ? self.pipelines[@"source_alpha"]
                    : self.pipelines[@"opaque"]];
            simd_float3 rotationVector =
                rotation.count == 3
                    ? ProtectorVector3(rotation)
                    : simd_float3{0.0f, 0.0f, 0.0f};
            simd_float4x4 model = ProtectorTranslationRotationScale(
                ProtectorVector3(position),
                rotationVector,
                ProtectorVector3(scale)
            );
            ProtectorUniforms uniforms = {};
            uniforms.mvp = simd_mul(self.mvp, model);
            uniforms.materialColor = simd_float4{
                [color[0] floatValue],
                [color[1] floatValue],
                [color[2] floatValue],
                [color[3] floatValue],
            };
            uniforms.lighting = simd_float4{1.0f, 0.6f, 0.4f, 0.0f};
            uniforms.fog = self.fog;
            uniforms.fogColor = self.fogColor;
            [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
            [encoder setFragmentBytes:&uniforms
                               length:sizeof(uniforms)
                              atIndex:1];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                        vertexStart:0
                        vertexCount:36];
        }
    }
    [encoder endEncoding];
    return YES;
}

- (void)setGameplayCameraEye:(simd_float3)eye
                      target:(simd_float3)target {
    self.gameplayRightHandedCamera = YES;
    simd_float4x4 view =
        ProtectorGameplayLookAt(
            eye,
            target,
            simd_float3{0.0f, 1.0f, 0.0f}
        );
    simd_float4x4 projection = ProtectorGameplayPerspective(
        self.verticalFieldOfView,
        (float)self.width / (float)self.height,
        self.nearPlane,
        self.farPlane
    );
    self.mvp = simd_mul(projection, view);
}

- (void)setGameplayVerticalFovDegrees:(float)degrees {
    if (isfinite(degrees) && degrees > 1.0f && degrees < 179.0f) {
        self.verticalFieldOfView = degrees * (float)M_PI / 180.0f;
    }
}

- (void)setGameplayActors:(NSArray<NSDictionary*>*)actors {
    _gameplayActors = [actors copy];
}

- (BOOL)renderFrameAtTime:(double)time
                    toURL:(NSURL*)destination
                    error:(NSError**)error {
    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatBGRA8Unorm_sRGB
                                                        width:self.width
                                                       height:self.height
                                                    mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage =
        MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> target = [self.device newTextureWithDescriptor:descriptor];
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (![self encodeFrameAtTime:time
                         texture:target
                    commandBuffer:commandBuffer
                           error:error]) {
        return NO;
    }
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.status == MTLCommandBufferStatusError) {
        if (error) {
            *error = commandBuffer.error;
        }
        return NO;
    }

    size_t bytesPerRow = self.width * 4;
    NSMutableData* pixels =
        [NSMutableData dataWithLength:bytesPerRow * self.height];
    [target getBytes:pixels.mutableBytes
         bytesPerRow:bytesPerRow
          fromRegion:MTLRegionMake2D(0, 0, self.width, self.height)
         mipmapLevel:0];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(
        (__bridge CFDataRef)pixels
    );
    CGBitmapInfo bitmapInfo =
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
    CGImageRef image = CGImageCreate(
        self.width,
        self.height,
        8,
        32,
        bytesPerRow,
        colorSpace,
        bitmapInfo,
        provider,
        NULL,
        false,
        kCGRenderingIntentDefault
    );
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    if (!image) {
        if (error) {
            *error = ProtectorError(14, @"Metal frame CGImage creation failed");
        }
        return NO;
    }
    CGImageDestinationRef imageDestination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)destination,
        CFSTR("public.png"),
        1,
        NULL
    );
    if (!imageDestination) {
        CGImageRelease(image);
        if (error) {
            *error = ProtectorError(15, @"PNG destination creation failed");
        }
        return NO;
    }
    CGImageDestinationAddImage(imageDestination, image, NULL);
    BOOL written = CGImageDestinationFinalize(imageDestination);
    CFRelease(imageDestination);
    CGImageRelease(image);
    if (!written && error) {
        *error = ProtectorError(16, @"PNG finalization failed");
    }
    return written;
}

- (BOOL)presentFrameAtTime:(double)time
                  drawable:(id<CAMetalDrawable>)drawable
                     error:(NSError**)error {
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) {
        if (error) {
            *error = ProtectorError(17, @"Metal presentation command buffer failed");
        }
        return NO;
    }
    if (![self encodeFrameAtTime:time
                         texture:drawable.texture
                    commandBuffer:commandBuffer
                           error:error]) {
        return NO;
    }
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    return YES;
}

@end
