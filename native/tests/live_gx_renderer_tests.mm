// The decoder stays private to its translation unit. Include it here so tests
// exercise the production helpers without exposing a public testing API.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#include "../metal/live_gx_renderer.mm"
#pragma clang diagnostic pop
#include <cassert>
#include <cstdio>
#import <CommonCrypto/CommonDigest.h>
#include "geometry_fixture.h"

// Exercise the public display-thread entry without manufacturing a drawable.
// A failed present must be retained for the session's terminal receipt.
@interface FailingPresentationRenderer : ProtectorLiveMetalRenderer
@property(nonatomic) NSError* injectedPresentationError;
@property(nonatomic) BOOL returnSuccess;
@end
@implementation FailingPresentationRenderer
- (BOOL)presentLockedDrawable:(id<CAMetalDrawable>)drawable error:(NSError**)error {
    (void)drawable;
    if (error) *error = self.injectedPresentationError;
    return self.returnSuccess;
}
@end

static void TestPresentationFailureReceipt() {
    FailingPresentationRenderer* renderer = [[FailingPresentationRenderer alloc] init];
    NSError* expected = [NSError errorWithDomain:@"ProtectorTexturePack" code:2
        userInfo:@{NSLocalizedDescriptionKey:@"Restored textures exceed 256 MiB frame budget",
            @"frame_bytes":@240000000, @"requested_bytes":@45000000}];
    renderer.injectedPresentationError = expected;
    id<CAMetalDrawable> unused = (id<CAMetalDrawable>)[NSObject new];
    NSError* actual = nil;
    assert(![renderer presentLatestDrawable:unused error:&actual]);
    assert(actual == expected && renderer.failure == expected);
    assert([renderer.failure.userInfo[@"requested_bytes"] unsignedLongLongValue] == 45000000);

    renderer = [[FailingPresentationRenderer alloc] init];
    assert(![renderer presentLatestDrawable:unused error:nullptr] && renderer.failure);
    renderer = [[FailingPresentationRenderer alloc] init];
    renderer.returnSuccess = YES;
    assert([renderer presentLatestDrawable:unused error:nullptr] && !renderer.failure);
    assert([renderer presentLatestDrawable:unused minimumDuration:1.0/72 error:nullptr]);
    assert(renderer.presentationMinimumDuration == 1.0/72);
    for (double duration : {-1.0, 2.0, std::numeric_limits<double>::quiet_NaN()}) {
        assert([renderer presentLatestDrawable:unused minimumDuration:duration error:nullptr]);
        assert(renderer.presentationMinimumDuration == 0);
    }
}

static void TestHybridTextureTrilinearSeam() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    const unsigned char colors[4][4] = {{32,64,96,255}, {160,80,40,128},
        {12,200,70,32}, {222,150,20,200}};
    auto create = [&](MTLPixelFormat format, NSUInteger side, NSUInteger count) {
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
            width:side height:side mipmapped:YES];
        descriptor.mipmapLevelCount = count;
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        return [device newTextureWithDescriptor:descriptor];
    };
    id<MTLTexture> head = create(MTLPixelFormatASTC_4x4_LDR, 8, 2);
    id<MTLTexture> tail = create(MTLPixelFormatRGBA8Unorm, 2, 2);
    id<MTLTexture> full = create(MTLPixelFormatRGBA8Unorm, 8, 4);
    assert(head && tail && full);
    for (NSUInteger mip = 0, side = 8; mip < 4; ++mip, side = std::max((NSUInteger)1, side / 2)) {
        std::vector<unsigned char> raw(side * side * 4);
        for (NSUInteger p = 0; p < side * side; ++p) memcpy(raw.data() + p * 4, colors[mip], 4);
        [full replaceRegion:MTLRegionMake2D(0, 0, side, side) mipmapLevel:mip
            withBytes:raw.data() bytesPerRow:side * 4];
        if (mip >= 2) {
            [tail replaceRegion:MTLRegionMake2D(0, 0, side, side) mipmapLevel:mip - 2
                withBytes:raw.data() bytesPerRow:side * 4];
        } else {
            const NSUInteger blocks = ((side + 3) / 4) * ((side + 3) / 4);
            std::vector<unsigned char> compressed(blocks * 16);
            for (NSUInteger b = 0; b < blocks; ++b) {
                unsigned char* bytes = compressed.data() + b * 16;
                bytes[0] = 0xfc; bytes[1] = 0xfd;
                memset(bytes + 2, 0xff, 6);
                for (NSUInteger c = 0; c < 4; ++c) bytes[8 + c * 2] = bytes[9 + c * 2] = colors[mip][c];
            }
            [head replaceRegion:MTLRegionMake2D(0, 0, side, side) mipmapLevel:mip
                withBytes:compressed.data() bytesPerRow:((side + 3) / 4) * 16];
        }
    }
    NSString* probe = @R"METAL(
struct SeamVertex { float4 position [[position]]; float2 uv; };
vertex SeamVertex seam_vertex(uint i [[vertex_id]], constant float2& scale [[buffer(0)]]) {
    const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    SeamVertex v; v.position = float4(p[i], 0, 1); v.uv = (p[i] + 1) * 0.5f * scale; return v;
}
fragment float4 seam_fragment(SeamVertex v [[stage_in]],
    texture2d<float> head [[texture(0)]], texture2d<float> tail [[texture(1)]],
    texture2d<float> full [[texture(2)]], sampler s [[sampler(0)]]) {
    return abs(live_texture_sample(head, tail, s, v.uv, 2u) - full.sample(s, v.uv));
})METAL";
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:[ProtectorLiveShaderSource stringByAppendingString:probe]
        options:nil error:&error];
    if (!library) fprintf(stderr, "Mip seam shader: %s\n", error.localizedDescription.UTF8String);
    assert(library && !error);
    MTLRenderPipelineDescriptor* pipelineDescription = [MTLRenderPipelineDescriptor new];
    pipelineDescription.vertexFunction = [library newFunctionWithName:@"seam_vertex"];
    pipelineDescription.fragmentFunction = [library newFunctionWithName:@"seam_fragment"];
    pipelineDescription.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pipelineDescription error:&error];
    assert(pipeline && !error);
    MTLTextureDescriptor* outputDescription = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
        width:32 height:32 mipmapped:NO];
    outputDescription.storageMode = MTLStorageModeShared;
    outputDescription.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> output = [device newTextureWithDescriptor:outputDescription];
    id<MTLCommandQueue> queue = [device newCommandQueue];
    float maximumError = 0;
    // Native derivative-selected LOD, magnification through minification, with
    // eight substeps on both sides of the split and clamping beyond the chain.
    for (NSUInteger anisotropy : {1u, 4u}) for (float ratio : {1.0f, 2.0f, 4.0f, 8.0f}) {
      MTLSamplerDescriptor* samplerDescriptor = [MTLSamplerDescriptor new];
      samplerDescriptor.sAddressMode = samplerDescriptor.tAddressMode = MTLSamplerAddressModeRepeat;
      samplerDescriptor.minFilter = samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
      samplerDescriptor.mipFilter = MTLSamplerMipFilterLinear;
      samplerDescriptor.maxAnisotropy = anisotropy;
      id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:samplerDescriptor];
      for (int step = -8; step <= 40; ++step) {
        const float lod = step / 8.0f, scalar = std::exp2(lod) * 32.0f / 8.0f;
        const float scale[2] = {scalar * ratio, scalar};
        id<MTLCommandBuffer> command = [queue commandBuffer];
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = output;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:pipeline];
        [encoder setVertexBytes:scale length:sizeof(scale) atIndex:0];
        [encoder setFragmentTexture:head atIndex:0];
        [encoder setFragmentTexture:tail atIndex:1];
        [encoder setFragmentTexture:full atIndex:2];
        [encoder setFragmentSamplerState:sampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        assert(command.status == MTLCommandBufferStatusCompleted && !command.error);
        std::vector<float> pixels(32 * 32 * 4);
        [output getBytes:pixels.data() bytesPerRow:32 * 4 * sizeof(float)
            fromRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0];
        float localMaximum = 0;
        for (float value : pixels) {
            assert(std::isfinite(value));
            localMaximum = std::max(localMaximum, value * 255);
        }
        maximumError = std::max(maximumError, localMaximum);
        if (localMaximum > 0.6f) fprintf(stderr, "Hybrid mip seam AF %lu ratio %f lod %f differs by %f/255\n",
            (unsigned long)anisotropy, ratio, lod, localMaximum);
      }
    }
    assert(maximumError <= 0.6f);
}

static NSString* TestPixelHash(const std::vector<u8>& pixels) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(pixels.data(), (CC_LONG)pixels.size(), hash);
    NSMutableString* text = [NSMutableString string];
    for (unsigned char byte : hash) [text appendFormat:@"%02x", byte];
    return text;
}

static NSURL* TestWriteTexturePack(NSURL* output) {
    const std::vector<u8> source{128, 64, 32, 255};
    std::vector<u8> replacement;
    for (size_t pixel = 0; pixel < 16; ++pixel)
        replacement.insert(replacement.end(), {200, 100, 50, 255});
    NSString* path = [NSString stringWithFormat:@"textures/%@.rgba", TestPixelHash(replacement)];
    NSError* error = nil;
    assert([NSFileManager.defaultManager createDirectoryAtURL:
        [output URLByAppendingPathComponent:@"textures"] withIntermediateDirectories:YES
        attributes:nil error:&error]);
    assert([[NSData dataWithBytes:replacement.data() length:replacement.size()]
        writeToURL:[output URLByAppendingPathComponent:path] options:0 error:&error]);
    NSDictionary* manifest = @{
        @"schema":@"protector-native.texture-pack/v1", @"pack_id":@"synthetic-tests",
        @"status":@"candidate",
        @"title_dol_sha256":@"03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566",
        @"entries":@[@{@"source":@{@"width":@1, @"height":@1,
            @"rgba8_sha256":TestPixelHash(source)},
            @"replacement":@{@"width":@4, @"height":@4, @"byte_length":@64,
                @"sha256":TestPixelHash(replacement), @"path":path}}]};
    NSURL* url = [output URLByAppendingPathComponent:@"pack.json"];
    assert([[NSJSONSerialization dataWithJSONObject:manifest options:0 error:&error]
        writeToURL:url options:0 error:&error]);
    assert(!error);
    return url;
}

static void TestCompanionMaterialCache() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSURL* output = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"protector-companion-test-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    NSURL* manifest = TestWriteTexturePack([output URLByAppendingPathComponent:@"pack"]);
    NSError* error = nil;
    NSMutableDictionary* document = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:manifest]
        options:NSJSONReadingMutableContainers error:&error];
    const std::vector<u8> color{128,64,32,255}, mask{30,100,70,255};
    NSString* ka = [@"1x1-" stringByAppendingString:TestPixelHash(color)];
    NSString* kb = [@"1x1-" stringByAppendingString:TestPixelHash(mask)];
    const std::vector<u8> secondColor{90,60,30,255};
    NSString* kc = [@"1x1-" stringByAppendingString:TestPixelHash(secondColor)];
    NSMutableDictionary* a = document[@"entries"][0];
    a[@"replacement"][@"format"] = @"rgba8-unorm";
    a[@"replacement"][@"alpha_mode"] = @"opaque";
    NSMutableDictionary* b = [a mutableCopy];
    b[@"source"] = @{@"width":@1,@"height":@1,@"rgba8_sha256":TestPixelHash(mask)};
    NSMutableDictionary* c = [a mutableCopy];
    c[@"source"] = @{@"width":@1,@"height":@1,@"rgba8_sha256":TestPixelHash(secondColor)};
    a[@"required_companion_sources"] = @[kb]; b[@"required_companion_sources"] = @[ka,kc];
    c[@"required_companion_sources"] = @[kb];
    document[@"entries"] = @[a,b,c]; document[@"schema"] = @"protector-native.texture-pack/v6";
    assert([[NSJSONSerialization dataWithJSONObject:document options:0 error:&error] writeToURL:manifest options:0 error:&error]);
    ProtectorLiveMetalRenderer* renderer = [[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:device
        outputDirectory:output texturePackManifest:manifest error:&error];
    assert(renderer && !error);
    renderer.frameUsesRestoredArtwork = YES;
    LiveDraw draw;
    draw.fragment.stageCount = 2;
    for (size_t i = 0; i < 8; ++i) {
        draw.textureWidths[i] = draw.textureHeights[i] = 1;
        draw.textureAddresses[i] = 0x1000 + (u32)i * 0x100;
        draw.textureRGBA[i] = {255,255,255,255};
    }
    draw.textureRGBA[0] = color; draw.textureRGBA[1] = mask;
    for (BOOL cache : {YES, NO}) {
        renderer.textureCacheEnabled = cache;
        [renderer.textureCache removeAllObjects]; renderer.textureCacheBytes = 0;
        // Same address and mask bytes throughout. Both source -> restored and
        // restored -> source transitions must reassess the changing companion.
        for (NSUInteger pass = 0; pass < 6; ++pass) {
            const BOOL allowed = pass == 1 || pass == 2 || pass == 5;
            draw.textureRGBA[0] = color;
            if (!allowed) draw.textureRGBA[0][0] ^= 1;
            [renderer.texturePack beginFrame];
            BOOL restored = YES;
            id<MTLTexture> t = [renderer textureForDraw:draw stage:1 restored:&restored error:&error];
            assert(t && !error && restored == allowed && t.width == (allowed ? 4 : 1));
            u8 actual[4]{};
            [t getBytes:actual bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
            assert(actual[0] == (allowed ? 200 : 30));
            assert(renderer.texturePack.frameSourceKeys.count == (allowed ? 1 : 0));
        }
        draw.textureRGBA[0] = color;
        BOOL restored = NO;
        assert([renderer textureForDraw:draw stage:0 restored:&restored error:&error] && restored && !error);
        // Isolation must fall back both planes and re-admit both without a
        // global cache clear. Selecting A cannot disable shared mask B when
        // B is actually paired with C in another draw.
        renderer.materialAuditIsolate = YES;
        renderer.sceneEdgeRedraw = YES;
        for (id selected : @[NSNull.null,ka,NSNull.null,kb,NSNull.null,kc,NSNull.null]) {
            renderer.materialAuditSourceOnlyKey = selected == NSNull.null ? nil : selected;
            const BOOL allowed = selected == NSNull.null || [selected isEqual:kc];
            for (size_t stage = 0; stage < 2; ++stage) {
                id<MTLTexture> texture = [renderer textureForDraw:draw stage:stage restored:&restored error:&error];
                assert(texture && !error && restored == allowed && texture.width == (allowed ? 4 : 1));
            }
        }
        renderer.materialAuditSourceOnlyKey = ka;
        LiveDraw otherConsumer = draw;
        otherConsumer.textureRGBA[0] = secondColor;
        for (size_t stage = 0; stage < 2; ++stage)
            assert([renderer textureForDraw:otherConsumer stage:stage restored:&restored error:&error] && restored && !error);
        renderer.sceneEdgeRedraw = NO; // stale diagnostic selection cannot affect live play
        for (size_t stage = 0; stage < 2; ++stage)
            assert([renderer textureForDraw:draw stage:stage restored:&restored error:&error] && restored && !error);
        renderer.sceneEdgeRedraw = YES; renderer.materialAuditIsolate = NO;
        for (size_t stage = 0; stage < 2; ++stage)
            assert([renderer textureForDraw:draw stage:stage restored:&restored error:&error] && restored && !error);
        renderer.sceneEdgeRedraw = NO; renderer.materialAuditSourceOnlyKey = nil;
        for (NSUInteger invalid = 0; invalid < 5; ++invalid) {
            LiveDraw bad = draw;
            size_t stage = 1;
            if (invalid == 0) bad.fragment.stageCount = 1; // target outside direct stages
            if (invalid == 1) bad.fragment.stageCount = 5; // unsupported direct-stage count
            if (invalid == 2) { bad.textureWidths[0] = 2; bad.textureRGBA[0].insert(bad.textureRGBA[0].end(),color.begin(),color.end()); }
            if (invalid == 3) { bad.textureRGBA[0][0] ^= 1; bad.textureRGBA[4] = color; bad.fragment.indirectCount = 1; }
            if (invalid == 4) { bad.textureRGBA[4] = mask; stage = 4; bad.fragment.indirectCount = 1; }
            [renderer.texturePack beginFrame]; restored = YES;
            id<MTLTexture> t = [renderer textureForDraw:bad stage:stage restored:&restored error:&error];
            assert(t && !restored && !error && t.width == 1 && renderer.texturePack.frameSourceKeys.count == 0);
        }
    }
}

static void TestMaterialIsolationCapture() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSURL* output = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"protector-isolation-test-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    NSURL* manifest = TestWriteTexturePack([output URLByAppendingPathComponent:@"pack"]);
    const std::vector<u8> a{128,64,32,255}, b{60,120,180,255};
    NSString* key = [@"1x1-" stringByAppendingString:TestPixelHash(a)];
    NSError* error = nil;
    NSMutableDictionary* document = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:manifest]
        options:NSJSONReadingMutableContainers error:&error];
    NSMutableDictionary* second = [document[@"entries"][0] mutableCopy];
    second[@"source"] = @{@"width":@1,@"height":@1,@"rgba8_sha256":TestPixelHash(b)};
    document[@"entries"] = @[document[@"entries"][0],second];
    assert([[NSJSONSerialization dataWithJSONObject:document options:0 error:&error] writeToURL:manifest options:0 error:&error]);
    // Configuration fails closed. The normal observer keeps its two historical
    // comparison samples unless isolation is explicitly enabled.
    setenv("PROTECTOR_MATERIAL_AUDIT_ISOLATE", "1", 1);
    unsetenv("PROTECTOR_MATERIAL_AUDIT_KEYS");
    assert(![[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:device outputDirectory:output
        texturePackManifest:manifest error:&error] && error.code == 37);
    setenv("PROTECTOR_MATERIAL_AUDIT_KEYS", key.UTF8String, 1);
    error = nil;
    assert(![[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:device outputDirectory:output
        texturePackManifest:nil error:&error] && error.code == 37);
    for (const char* value : {"", "0", "true", "2"}) {
        setenv("PROTECTOR_MATERIAL_AUDIT_ISOLATE", value, 1); error = nil;
        assert(![[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:device outputDirectory:output
            texturePackManifest:manifest error:&error] && error.code == 37);
    }
    setenv("PROTECTOR_MATERIAL_AUDIT_ISOLATE", "1", 1); error = nil;
    ProtectorLiveMetalRenderer* renderer = [[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:device
        outputDirectory:output texturePackManifest:manifest error:&error];
    unsetenv("PROTECTOR_MATERIAL_AUDIT_ISOLATE"); unsetenv("PROTECTOR_MATERIAL_AUDIT_KEYS");
    assert(renderer && !error && renderer.materialAuditIsolate);
    std::vector<LiveDraw> draws;
    const float positions[6][2] = {{-1,-1},{1,-1},{-1,1},{-1,1},{1,-1},{1,1}};
    for (size_t half = 0; half < 2; ++half) {
        LiveDraw draw;
        draw.sourceVertexCount = 4; draw.fragment.stageCount = 1;
        draw.fragment.colorCombiners[0] = 0x80000u | 0xF8DFu;
        draw.fragment.alphaCombiners[0] = 0x80000u | (7u<<13u) | (7u<<10u) | (7u<<7u) | (4u<<4u);
        draw.fragment.textureAlphaChannels[0] = 3;
        for (size_t stage = 0; stage < 8; ++stage) {
            draw.textureWidths[stage] = draw.textureHeights[stage] = 1;
            draw.textureAddresses[stage] = 0x1000 + (u32)half*0x1000 + (u32)stage*0x100;
            draw.textureRGBA[stage] = half ? b : a;
            std::fill(draw.fragment.textureDimensions[stage], draw.fragment.textureDimensions[stage]+4, 1.0f);
        }
        for (const auto& position : positions) {
            LiveVertex vertex{};
            vertex.position[0] = position[0]*.5f + (half ? .5f : -.5f);
            vertex.position[1] = position[1]; vertex.position[3] = 1;
            std::fill(vertex.color, vertex.color+4, 1.0f);
            draw.vertices.push_back(vertex);
        }
        draws.push_back(draw);
    }
    NSString* digest = MotionVertexDigest(draws);
    const NSUInteger bytes = 640*480*4;
    std::vector<u8> baseline(bytes), fallback(bytes), returned(bytes);
    assert([renderer renderDraws:draws efbCopies:{} frame:17 error:&error]);
    [renderer.latestTexture getBytes:baseline.data() bytesPerRow:640*4 fromRegion:MTLRegionMake2D(0,0,640,480) mipmapLevel:0];
    assert(renderer.texturePack.frameSourceKeys.count == 2);
    renderer.sceneEdgeRedraw = YES; renderer.materialAuditSourceOnlyKey = key;
    assert([renderer renderDraws:draws efbCopies:{} frame:17 error:&error]);
    [renderer.latestTexture getBytes:fallback.data() bytesPerRow:640*4 fromRegion:MTLRegionMake2D(0,0,640,480) mipmapLevel:0];
    assert(renderer.texturePack.frameSourceKeys.count == 1);
    for (NSUInteger y=0;y<480;++y) for (NSUInteger x=0;x<640;++x) {
        const NSUInteger offset = (y*640+x)*4;
        if (x<320) assert(fallback[offset]==16 && fallback[offset+1]==32 && fallback[offset+2]==64);
        else assert(memcmp(baseline.data()+offset,fallback.data()+offset,4)==0);
    }
    renderer.materialAuditSourceOnlyKey = nil;
    assert([renderer renderDraws:draws efbCopies:{} frame:17 error:&error]);
    [renderer.latestTexture getBytes:returned.data() bytesPerRow:640*4 fromRegion:MTLRegionMake2D(0,0,640,480) mipmapLevel:0];
    assert(returned == baseline && renderer.renderedFrameCount == 1);
    renderer.sceneEdgeRedraw = NO;
    assert([renderer captureMaterialSources:draws copies:{} frame:17 guestTicks:800 error:&error]);
    assert(!error && renderer.renderedFrameCount == 1 && !renderer.sceneEdgeRedraw && !renderer.materialAuditSourceOnlyKey);
    assert([digest isEqual:MotionVertexDigest(draws)]);
    assert(renderer.stateCapture[@"material_audit_source_only_key"] == NSNull.null);
    NSURL* directory = [output URLByAppendingPathComponent:@"material-source-00"];
    NSDictionary* report = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:
        [directory URLByAppendingPathComponent:@"inspection.json"]] options:0 error:&error];
    assert(!error && [report[@"samples"] count] == 2 && [report[@"isolation_samples"] count] == 3);
    assert([report[@"guest_timebase"] intValue] == 800 && [report[@"isolation_enabled"] boolValue]);
    NSArray* variants = report[@"isolation_samples"];
    for (NSUInteger variant=0;variant<3;++variant) {
        NSDictionary* state = variants[variant][@"state"];
        assert([state[@"restored_artwork_enabled"] boolValue] && [state[@"frame_index"] intValue] == 17);
        assert([state[@"material_audit_source_only_key"] isEqual:variant == 1 ? key : NSNull.null]);
        assert([state[@"texture_pack_frame_sources"] count] == (variant == 1 ? 1 : 2));
    }
    NSData* full = [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:variants[0][@"image"]]];
    NSData* source = [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:variants[1][@"image"]]];
    NSData* roundtrip = [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:variants[2][@"image"]]];
    assert(full.length && source.length && [full isEqual:roundtrip] && ![full isEqual:source]);
    [renderer.latestTexture getBytes:returned.data() bytesPerRow:640*4 fromRegion:MTLRegionMake2D(0,0,640,480) mipmapLevel:0];
    assert(returned == baseline);
}

static void TestIntensityAlpha() {
    DecoderState state;
    std::vector<u8> pixels;
    std::array<u8, 32> tile{};
    for (size_t i = 0; i < tile.size(); ++i) tile[i] = (u8)(i * 7u);
    assert(DecodeTexture(tile.data(), tile.size(), state, 1, 8, 4, &pixels));
    for (size_t i = 0; i < tile.size(); ++i)
        for (size_t channel = 0; channel < 4; ++channel)
            assert(pixels[i * 4 + channel] == tile[i]);
    tile.fill(0x3Du);
    assert(DecodeTexture(tile.data(), tile.size(), state, 0, 8, 8, &pixels));
    for (size_t i = 0; i < 64; ++i)
        for (size_t channel = 0; channel < 4; ++channel)
            assert(pixels[i * 4 + channel] == (i % 2 ? 0xDD : 0x33));
}

static void TestPrimitiveIndices() {
    std::vector<u32> indices;
    NSString* error = nil;
    assert(BuildPrimitiveIndices(0x80, 8, &indices, &error));
    assert((indices == std::vector<u32>{0,1,2,0,2,3,4,5,6,4,6,7}));
    assert(BuildPrimitiveIndices(0x88, 4, &indices, &error));
    assert((indices == std::vector<u32>{0,1,2,0,2,3}));
    assert(BuildPrimitiveIndices(0x90, 6, &indices, &error));
    assert((indices == std::vector<u32>{0,1,2,3,4,5}));
    assert(BuildPrimitiveIndices(0x98, 6, &indices, &error));
    assert((indices == std::vector<u32>{0,1,2,2,1,3,2,3,4,4,3,5}));
    assert(BuildPrimitiveIndices(0xA0, 5, &indices, &error));
    assert((indices == std::vector<u32>{0,1,2,0,2,3,0,3,4}));
    for (u32 count : {0u, 1u, 2u}) {
        assert(BuildPrimitiveIndices(0x98, count, &indices, &error));
        assert(indices.empty());
    }
    assert(!BuildPrimitiveIndices(0x80, 3, &indices, &error));
    assert(!BuildPrimitiveIndices(0x90, 4, &indices, &error));
    assert(!BuildPrimitiveIndices(0xB0, 4, &indices, &error));
    assert(!BuildPrimitiveIndices(0x98, 65536, &indices, &error));
}

static void TestDecodedIndexedPrimitives() {
    DecoderState state;
    state.cp[0x50] = 1u << 9u; // Direct positions.
    state.cp[0x70] = 1u | (4u << 1u); // Three float32 components.
    CPUState cpu;
    assert(protector_cpu_init(&cpu));
    for (u8 opcode : {0x80, 0x88, 0x90, 0x98, 0xA0}) {
        const u32 count = opcode == 0x90 ? 6 : 8;
        std::vector<u8> payload;
        for (u32 i = 0; i < count * 3; ++i) {
            const float value = (float)i;
            u32 bits = 0;
            std::memcpy(&bits, &value, sizeof(bits));
            for (int shift : {24, 16, 8, 0}) payload.push_back((u8)(bits >> shift));
        }
        LiveDraw indexed, expanded;
        indexed.fragment.stageCount = expanded.fragment.stageCount = 0;
        NSString* error = nil;
        state.indexedVertices = true;
        assert(DecodePrimitiveVertices(state, &cpu, opcode, count,
            payload.data(), payload.size(), false, &indexed, &error));
        state.indexedVertices = false;
        assert(DecodePrimitiveVertices(state, &cpu, opcode, count,
            payload.data(), payload.size(), false, &expanded, &error));
        assert(indexed.indexed && !expanded.indexed && indexed.vertices.size() == count);
        assert(SubmittedVertexCount(indexed) == expanded.vertices.size());
        for (size_t i = 0; i < expanded.vertices.size(); ++i)
            assert(std::memcmp(&SubmittedVertex(indexed, i), &expanded.vertices[i], sizeof(LiveVertex)) == 0);
    }
    protector_cpu_destroy(&cpu);
}

static void TestSignedTevRegisters() {
    DecoderState state;
    // Color0 low: R=-179, A=154. High: B=-227, G=135.
    UpdateTevRegister(&state, 0xE2, ((154u & 0x7FFu) << 12u) | ((u32)-179 & 0x7FFu));
    UpdateTevRegister(&state, 0xE3, (135u << 12u) | ((u32)-227 & 0x7FFu));
    LiveDraw draw;
    NSString* error = nil;
    assert(PopulateFragmentState(state, &draw, &error));
    assert(draw.fragment.colorRegisters[0][0] == -179.0f / 255.0f);
    assert(draw.fragment.colorRegisters[0][1] == 135.0f / 255.0f);
    assert(draw.fragment.colorRegisters[0][2] == -227.0f / 255.0f);
    assert(draw.fragment.colorRegisters[0][3] == 154.0f / 255.0f);
}

static void TestBoundedSceneSourcePositionAudit() {
    CPUState cpu;
    assert(protector_cpu_init(&cpu));
    DecoderState state;
    state.cp[0x50] = (3u << 9u) | (1u << 13u); // 16-bit indexed XYZ, direct color, no normal.
    state.cp[0x70] = 1u | (4u << 1u) | (5u << 14u); // Float32 XYZ / RGBA8.
    state.cp[0xA0] = 0x1000;
    state.cp[0xB0] = 12;
    state.xf[0] = state.xf[5] = state.xf[10] = 0x3F800000;
    state.xf[0x1020] = state.xf[0x1022] = state.xf[0x1024] = 0x3F800000;
    std::vector<u8> raw, payload;
    for (u32 i = 0; i < 2049; ++i) {
        for (float value : {(float)i, (float)(i % 3), -4.0f}) {
            u32 word = 0; memcpy(&word, &value, 4);
            mem_write32(&cpu, 0x80001000u + (u32)raw.size(), word);
            for (int shift : {24,16,8,0}) raw.push_back((u8)(word >> shift));
        }
        payload.push_back((u8)(i >> 8));
        payload.push_back((u8)i);
        for (int component = 0; component < 4; ++component) payload.push_back(255);
    }
    auto decode = [&](u32 count, bool enabled, bool indexed) {
        state.sceneSourceAuditEnabled = enabled;
        state.indexedVertices = indexed;
        LiveDraw draw;
        draw.fragment.stageCount = 0; draw.displayListDepth = 1;
        draw.viewportWidth = 640; draw.viewportHeight = 448;
        NSString* error = nil;
        assert(DecodePrimitiveVertices(state, &cpu, 0x98, count,
            payload.data(), count*6, true, &draw, &error));
        assert(!draw.finiteBackdropIdentity && !draw.repeatingBackdropIdentity &&
            !draw.hillBackdropIdentity && !draw.canyonSkyIdentity && !draw.citySkyIdentity);
        return draw;
    };
    for (bool indexed : {true,false}) {
        for (u32 count : {21u, 64u, 65u, 1080u, 2048u}) {
            auto audited = decode(count, true, indexed), plain = decode(count, false, indexed);
            std::array<u8,CC_SHA256_DIGEST_LENGTH> digest{};
            CC_SHA256(raw.data(), count*12, digest.data());
            assert(audited.hasBackdropSourcePositionKey && audited.backdropSourcePositionKey == digest);
            assert(!plain.hasBackdropSourcePositionKey);
            assert(audited.indices == plain.indices && audited.vertices.size() == plain.vertices.size());
            assert(!memcmp(audited.vertices.data(), plain.vertices.data(), audited.vertices.size()*sizeof(LiveVertex)));
        }
        assert(!decode(2049, true, indexed).hasBackdropSourcePositionKey);
    }
    protector_cpu_destroy(&cpu);
}

static void TestFiniteRoomFraming() {
    std::vector<LiveDraw> room;
    for (u8 identity : {1,2,3}) {
        LiveDraw draw;
        draw.finiteRoomIdentity=identity;
        draw.sourceVertexCount=(u32)FiniteRoomSourceCount(identity);
        draw.indexed=true; draw.displayListDepth=1;
        draw.viewportWidth=640; draw.viewportHeight=448;
        draw.projectionWords={1071518207,0,1075748644,0,3114525735,3212839486,0};
        draw.vertices.resize(draw.sourceVertexCount);
        for (auto& vertex : draw.vertices) {
            vertex.position[2]=1; vertex.position[3]=10;
            for (float& component : vertex.color) component=1;
        }
        NSString* error=nil;
        assert(BuildPrimitiveIndices(0x98,draw.sourceVertexCount,&draw.indices,&error));
        room.push_back(draw);
    }
    room[1].vertices[562].position[0]=-14.0452f;
    const double phone=874.0/402.0;
    const auto result=IdentifyFiniteRoomFrame(room,phone);
    assert(result.enabled && result.bias<-.14f && result.bias>-.15f);
    assert(std::abs(result.anchorX+result.bias+1+2.0/640)<1e-6);
    const float ratio=(float)((4.0/3)/phone);
    assert(-ratio+result.bias>=-1 && ratio+result.bias<=1);
    assert((-1-result.bias)/ratio>=-2.25f && (1-result.bias)/ratio<=2.25f);
    for (double aspect : {4.0/3,16.0/9,3.0,3.01,1.0,double(NAN),double(INFINITY)})
        assert(!IdentifyFiniteRoomFrame(room,aspect).enabled);
    auto reject=[&](auto mutate) { auto bad=room; mutate(bad); assert(!IdentifyFiniteRoomFrame(bad,phone).enabled); };
    reject([](auto& v){v.pop_back();});
    reject([](auto& v){v.push_back(v[0]);});
    reject([](auto& v){v[0].finiteRoomIdentity=4;});
    reject([](auto& v){v[0].indices[4]+=1;});
    reject([](auto& v){v[1].sourceVertexCount-=1;});
    reject([](auto& v){v[2].vertices[0].position[3]=0;});
    reject([](auto& v){v[2].vertices[0].position[0]=NAN;});
    reject([](auto& v){v[2].projectionWords[2]+=1;});
    reject([](auto& v){v[1].vertices[202].position[0]+=.1f;});
    reject([](auto& v){v[1].vertices[562].position[1]=11;});
    reject([](auto& v){v[1].vertices[562].position[0]=-30;});
    reject([](auto& v){v[1].vertices[562].position[0]=-1;});
    auto expanded=room;
    for (auto& draw : expanded) {
        std::vector<LiveVertex> vertices;
        for (u32 index : draw.indices) vertices.push_back(draw.vertices[index]);
        draw.vertices=std::move(vertices); draw.indices.clear(); draw.indexed=false;
    }
    const auto expandedResult=IdentifyFiniteRoomFrame(expanded,phone);
    assert(expandedResult.enabled && expandedResult.bias==result.bias);
    expanded[0].vertices[3].color[0]=.5f;
    assert(!IdentifyFiniteRoomFrame(expanded,phone).enabled);
    assert(!FiniteRoomSourceIdentity(nullptr) && !FiniteRoomSourceIdentity("unknown"));
    assert(FiniteRoomSourceIdentity("367398081abdfd218b7543ca5b0254535ac50e13979938b25325981c2a8c1c2a")==1);
    assert(!FiniteRoomSourceUVMatches(1,room[0].vertices));
    // Optional local source fixture: proprietary vertex data never enters Git.
    if (const char* path=getenv("PROTECTOR_FINITE_ROOM_SOURCE_AUDIT")) {
        NSError* error=nil;
        NSDictionary* audit=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(path)] options:0 error:&error];
        assert(audit && !error);
        std::vector<LiveDraw> source;
        for (NSDictionary* record in audit[@"identities"]) {
            const u8 id=FiniteRoomSourceIdentity([record[@"source_position_sequence_sha256"] UTF8String]);
            if (!id || [record[@"texture_keys"] count]!=1) continue;
            LiveDraw draw=room[id-1];
            draw.vertices.clear(); draw.indices.clear();
            for (NSDictionary* point in record[@"decoded_vertices"]) {
                LiveVertex vertex{};
                for (size_t i=0;i<4;++i) {
                    vertex.position[i]=[point[@"clip"][i] floatValue];
                    vertex.color[i]=[point[@"color"][i] floatValue];
                }
                for (size_t i=0;i<2;++i) vertex.uv[0][i]=[point[@"uv"][i] floatValue];
                draw.vertices.push_back(vertex);
            }
            for (NSNumber* index in record[@"indices"]) draw.indices.push_back(index.unsignedIntValue);
            assert(FiniteRoomSourceUVMatches(id,draw.vertices));
            source.push_back(draw);
        }
        assert(source.size()==3);
        const auto native=IdentifyFiniteRoomFrame(source,phone);
        assert(native.enabled && std::abs(native.bias+.14177672025805188)<1e-6);
        std::puts("Exact native terminal-room source UV, topology and bounded framing fixture passed");
    }
    std::puts("Finite-room identity, cohort, projection, 4:3 and visibility-envelope framing tests passed");
}

static void TestIndexedXFLoads() {
    CPUState cpu;
    assert(protector_cpu_init(&cpu));
    DecoderState state;
    std::vector<LiveDraw> draws;
    std::vector<LiveEfbCopy> copies;
    auto load = [&](u8 opcode, u32 index, u32 destination, u32 words,
                    size_t bytes = 5u) {
        const u32 descriptor = (index << 16u) | ((words - 1u) << 12u) | destination;
        const u8 command[] = {opcode, (u8)(descriptor >> 24u),
            (u8)(descriptor >> 16u), (u8)(descriptor >> 8u), (u8)descriptor};
        NSString* error = nil;
        return DecodeFrame(&state, command, bytes, &cpu, false, true, 0,
            &draws, &copies, &error);
    };
    // All four banks use their own CP base and byte stride. Include MEM2,
    // a nonzero index, 1/16-word transfers, and big-endian data conversion.
    for (u32 bank = 0; bank < 4; ++bank) {
        const u32 address = bank == 3 ? kMem2PhysicalBase + 0x100 : 0x100 + bank * 0x100;
        state.cp[0xAC + bank] = address;
        state.cp[0xBC + bank] = 0x40;
        const u32 words = bank == 0 ? 1 : 16;
        for (u32 i = 0; i < words; ++i)
            mem_write32(&cpu, (address | 0x80000000u) + 0x80 + i * 4,
                0x3F000001 + bank * 0x100 + i);
        const u32 destination = bank * 0x100;
        assert(load((u8)(0x20 + bank * 8), 2, destination, words));
        for (u32 i = 0; i < words; ++i)
            assert(state.xf[destination + i] == 0x3F000001 + bank * 0x100 + i);
    }
    assert(state.indexedXFLoads == 4);
    const auto before = state.xf;
    assert(!load(0x28, 0, 0x400, 9, 4));
    assert(!load(0x28, 0, 0xFFF, 2));
    state.cp[0xAD] = 0x08000000;
    assert(!load(0x28, 0, 0x400, 9));
    state.cp[0xAD] = 0xFFFFFFF0;
    assert(!load(0x28, 2, 0x400, 9));
    assert(state.xf == before && state.indexedXFLoads == 4);

    // A loaded normal matrix must affect the actual transform, not merely
    // advance the FIFO cursor. This is identity at position-matrix index 6.
    state.cp[0xAD] = 0x1000;
    state.cp[0xBD] = 36;
    for (u32 i = 0; i < 9; ++i)
        mem_write32(&cpu, 0x80001000 + 36 + i * 4, i % 4 == 0 ? 0x3F800000 : 0);
    assert(load(0x28, 1, 0x412, 9));
    const float input[] = {0, 3, 4};
    float output[3] = {};
    assert(TransformNormal(state, 6, input, output));
    assert(output[0] == 0 && std::abs(output[1] - 0.6f) < 1e-6f &&
        std::abs(output[2] - 0.8f) < 1e-6f);
    protector_cpu_destroy(&cpu);
}

static void TestCollapsedNormalPrimitives() {
    CPUState cpu;
    assert(protector_cpu_init(&cpu));
    DecoderState state;
    state.cp[0x30] = 6;
    state.cp[0x50] = (1u << 9u) | (1u << 11u);
    state.cp[0x70] = 1u | (4u << 1u) | (4u << 10u);
    state.xf[0x1020] = state.xf[0x1022] = state.xf[0x1024] = 0x3F800000;
    state.xf[0x1026] = 1;
    state.xf[0x1B] = 0x3E800000; // Zero scale, finite translation.
    state.xf[0x1F] = 0xBE800000;
    state.xf[0x1009] = 1;
    state.xf[0x100C] = 0xFFFFFFFF;
    state.xf[0x100A] = 0x404040FF;
    state.xf[0x100E] = state.xf[0x1010] = 0x506;
    auto payload = [](bool matrixIndices, bool invalidNormal) {
        std::vector<u8> bytes;
        for (u32 vertex = 0; vertex < 3; ++vertex) {
            if (matrixIndices) bytes.push_back(vertex == 2 ? 9 : 6);
            const u32 words[] = {vertex == 0 ? 0xBF800000u : 0x3F800000u,
                vertex == 2 ? 0x3F800000u : 0xBF800000u, 0u,
                invalidNormal ? 0x7FC00000u : 0xC0000000u, 0x42540000u, 0x42080000u};
            for (u32 word : words)
                for (int shift : {24, 16, 8, 0}) bytes.push_back((u8)(word >> shift));
        }
        return bytes;
    };
    auto decode = [&](const std::vector<u8>& bytes, LiveDraw* draw) {
        NSString* error = nil;
        draw->fragment.stageCount = 0;
        return DecodePrimitiveVertices(state, &cpu, 0x90, 3,
            bytes.data(), bytes.size(), true, draw, &error);
    };
    for (bool indexed : {true, false}) {
        state.indexedVertices = indexed;
        LiveDraw draw;
        assert(decode(payload(false, false), &draw));
        assert(SubmittedVertexCount(draw) == 3);
        for (size_t i = 0; i < 3; ++i) {
            const auto& vertex = SubmittedVertex(draw, i);
            assert(vertex.position[0] == 0.25f && vertex.position[1] == -0.25f &&
                vertex.position[2] == 0.5f && vertex.position[3] == 1);
            for (float component : vertex.color) assert(std::isfinite(component));
        }
    }
    LiveDraw rejected;
    assert(!decode(payload(false, true), &rejected)); // Never admit NaN input.
    state.xf[0x18] = 0x3F800000;
    assert(!decode(payload(false, false), &rejected)); // Visible zero-normal geometry.
    state.xf[0x18] = 0;
    state.cp[0x50] |= 1u;
    state.xf[9 * 4 + 3] = 0x3F800000;
    assert(!decode(payload(true, false), &rejected)); // Not one common clip-space point.
    protector_cpu_destroy(&cpu);
}

static void TestOneOneBlendAdmission() {
    DecoderState state;
    LiveDraw draw;
    NSString* error = nil;
    state.bp[0x41] = 0x00313D;
    assert(PopulateFragmentState(state, &draw, &error));
    assert(draw.blendMode == 0x00313D && !error);
    // Similar factors do not silently admit subtraction or logic operations.
    for (u32 unsupported : {0x00393Du, 0x00313Fu, 0x00323Du}) {
        error = nil;
        state.bp[0x41] = unsupported;
        assert(!PopulateFragmentState(state, &draw, &error));
        assert(error);
    }
}

static void TestDecodedTextureCache() {
    DecoderState state;
    std::array<u8, 32> tile{};
    tile.fill(0x4E);
    std::shared_ptr<const std::vector<u8>> first, hit, changed;
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0x1000,
        1, 8, 4, 0, &first));
    assert(state.decodedTextures.misses == 1 && state.decodedTextures.hits == 0);
    assert(first->at(0) == 0x4E);
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0x1000,
        1, 8, 4, 0, &hit));
    assert(hit == first && state.decodedTextures.hits == 1);
    // Same guest address, new bytes. The earlier draw retains its old pixels.
    tile[0] = 0xA5;
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0x1000,
        1, 8, 4, 0, &changed));
    assert(changed != first && changed->at(0) == 0xA5 && first->at(0) == 0x4E);
    assert(state.decodedTextures.entries.size() == 1);
    assert(state.decodedTextures.bytes == 32 + 8 * 4 * 4);
    // Format and dimensions are independent parts of the identity.
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0x1000,
        2, 8, 4, 0, &hit));
    assert(hit != changed && hit->at(0) == 0x55 && hit->at(3) == 0xAA);
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0x1000,
        1, 4, 4, 0, &hit));
    assert(hit->size() == 4 * 4 * 4 && state.decodedTextures.entries.size() == 3);
    const size_t entries = state.decodedTextures.entries.size();
    assert(!ResolveDecodedTexture(&state, tile.data(), 31, 0x1000, 1, 8, 4, 0, &hit));
    assert(!ResolveDecodedTexture(&state, tile.data(), 32, 0x1000, 7, 8, 4, 0, &hit));
    assert(!ResolveDecodedTexture(&state, tile.data(), 32, 0x1000, 1, 0, 4, 0, &hit));
    assert(!ResolveDecodedTexture(&state, tile.data(), 32, 0x1000, 1, 2048, 4, 0, &hit));
    assert(!ResolveDecodedTexture(&state, tile.data(), 32, 0x1000, 1, 8, 4, 8, &hit));
    assert(state.decodedTextures.entries.size() == entries);
}

static void TestPaletteUnitsAndChanges() {
    DecoderState state;
    std::array<u8, 32> tile{};
    std::shared_ptr<const std::vector<u8>> pixels;
    for (u32 unit = 0; unit < 8; ++unit) {
        const u32 offset = (unit & 3u) + ((unit & 4u) << 3u);
        state.bp[0x98u + offset] = unit + 1;
        state.textureMemory[(unit + 1) * 512] = 255;
        state.textureMemory[(unit + 1) * 512 + 1] = (u8)(10 + unit);
    }
    for (u32 unit = 0; unit < 8; ++unit) {
        assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0x1000,
            8, 8, 8, unit, &pixels));
        assert(pixels->at(0) == 10 + unit && pixels->at(3) == 255);
    }
    assert(state.decodedTextures.entries.size() == 8);
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0x1000,
        8, 8, 8, 4, &pixels));
    const auto original = pixels;
    state.textureMemory[5 * 512 + 1] = 200;
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0x1000,
        8, 8, 8, 4, &pixels));
    assert(pixels != original && pixels->at(0) == 200 && original->at(0) == 14);
    const auto updated = pixels;
    // A write to another unit's palette must not corrupt or invalidate unit 4.
    state.textureMemory[8 * 512 + 1] = 99;
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0x1000,
        8, 8, 8, 4, &pixels));
    assert(pixels == updated);
    state.bp[0xB8] = 5 | (3u << 10u);
    assert(!ResolveDecodedTexture(&state, tile.data(), tile.size(), 0x1000,
        8, 8, 8, 4, &pixels));
}

static void TestCacheBoundsAndBypass() {
    DecoderState state;
    state.decodedTextures.byteLimit = 320;
    state.decodedTextures.entryLimit = 2;
    std::array<u8, 32> tile{};
    std::shared_ptr<const std::vector<u8>> first, second, pixels;
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0,
        1, 8, 4, 0, &first));
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 32,
        1, 8, 4, 0, &second));
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0,
        1, 8, 4, 0, &pixels));
    assert(pixels == first);
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 64,
        1, 8, 4, 0, &pixels));
    assert(state.decodedTextures.evictions == 1 && state.decodedTextures.bytes == 320);
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0,
        1, 8, 4, 0, &pixels));
    assert(pixels == first && second->size() == 128);
    assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 32,
        1, 8, 4, 0, &pixels));
    assert(pixels != second && *pixels == *second);
    DecoderState bypass;
    bypass.decodedTextures.enabled = false;
    assert(ResolveDecodedTexture(&bypass, tile.data(), tile.size(), 0,
        1, 8, 4, 0, &first));
    assert(ResolveDecodedTexture(&bypass, tile.data(), tile.size(), 0,
        1, 8, 4, 0, &pixels));
    assert(first != pixels && *first == *pixels);
    assert(bypass.decodedTextures.bytes == 0 && bypass.decodedTextures.entries.empty());
    bypass.decodedTextures.enabled = true;
    bypass.decodedTextures.byteLimit = 1;
    assert(ResolveDecodedTexture(&bypass, tile.data(), tile.size(), 0,
        1, 8, 4, 0, &pixels));
    assert(bypass.decodedTextures.entries.empty());
}

static void TestCachedAndUncachedFormats() {
    DecoderState state;
    u32 random = 0x139CE41u;
    auto next = [&]() { random = random * 1664525u + 1013904223u; return (u8)(random >> 24); };
    for (u32 format : {0u, 1u, 2u, 3u, 4u, 5u, 6u, 8u, 9u, 14u}) {
        size_t size = 0;
        assert(ExpectedTextureSize(format, 13, 11, &size));
        std::vector<u8> tile(size);
        std::shared_ptr<const std::vector<u8>> cached;
        for (unsigned iteration = 0; iteration < 20; ++iteration) {
            for (u8& byte : tile) byte = next();
            for (size_t byte = 0; byte < 512; ++byte) state.textureMemory[byte] = next();
            state.bp[0x98] = (iteration % 3) << 10;
            std::vector<u8> reference;
            assert(DecodeTexture(tile.data(), tile.size(), state, format, 13, 11, &reference));
            assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0x1000,
                format, 13, 11, 0, &cached));
            assert(*cached == reference);
            const auto old = cached;
            assert(ResolveDecodedTexture(&state, tile.data(), tile.size(), 0x1000,
                format, 13, 11, 0, &cached));
            assert(cached == old && *cached == reference);
        }
    }
}

static void TestDrawCacheMemoryAndTlutUpload() {
    DecoderState state;
    CPUState cpu;
    assert(protector_cpu_init(&cpu));
    const u32 unit = 7, offset = 0x23, address = 0x2000;
    state.bp[0x28] = (1u << 6u) | unit;
    state.bp[0x88 + offset] = (8u << 20u) | (7u << 10u) | 7u;
    state.bp[0x94 + offset] = address >> 5u;
    state.bp[0x98 + offset] = 1;
    state.textureMemory[512] = 255;
    state.textureMemory[513] = 42;
    LiveDraw first, second;
    first.fragment.stageCount = second.fragment.stageCount = 1;
    NSString* error = nil;
    assert(DecodeDrawTextures(state, &cpu, &first, &error));
    assert(TexturePixels(first, 0)[0] == 42);
    assert(DecodeDrawTextures(state, &cpu, &second, &error));
    assert(first.decodedPixels[0] == second.decodedPixels[0]);
    // The real FIFO TLUT upload changes palette bytes between two draws.
    cpu.ram[0x3000] = 255; cpu.ram[0x3001] = 99;
    const u8 load[] = {0x61, 0x64, 0, 1, 0x80, 0x61, 0x65, 0, 4, 1};
    std::vector<LiveDraw> draws;
    std::vector<LiveEfbCopy> copies;
    assert(DecodeFrame(&state, load, sizeof(load), &cpu, false, true, 0,
        &draws, &copies, &error));
    assert(DecodeDrawTextures(state, &cpu, &second, &error));
    assert(TexturePixels(second, 0)[0] == 99 && TexturePixels(first, 0)[0] == 42);
    // A cached identity cannot bypass physical-memory bounds checking.
    state.bp[0x94 + offset] = 0x7FFFFF;
    assert(!DecodeDrawTextures(state, &cpu, &second, &error));
    assert(error);
    protector_cpu_destroy(&cpu);
}

static void TestTevUsesEncodedComponents() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    assert(device);
    NSURL* output = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[@"protector-metal-test-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    NSError* error = nil;
    ProtectorLiveMetalRenderer* renderer = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output error:&error];
    assert(renderer && !error);
    LiveDraw draw;
    draw.sourceVertexCount = 4;
    draw.fragment.stageCount = 1;
    // D + (1-C)*A + C*B = 0 + 0.5 * texture, with opaque alpha.
    draw.fragment.colorCombiners[0] = 0x80000u | 0xF8DFu;
    draw.fragment.alphaCombiners[0] = 0x80000u | (7u << 13u) |
        (7u << 10u) | (7u << 7u) | (4u << 4u);
    draw.fragment.textureAlphaChannels[0] = 3;
    for (size_t stage = 0; stage < 8; ++stage) {
        draw.textureWidths[stage] = draw.textureHeights[stage] = 1;
        draw.textureRGBA[stage] = {128, 64, 32, 255};
        std::fill(draw.fragment.textureDimensions[stage],
                  draw.fragment.textureDimensions[stage] + 4, 1.0f);
    }
    const float positions[6][2] = {{-1,-1}, {1,-1}, {-1,1}, {-1,1}, {1,-1}, {1,1}};
    for (const auto& position : positions) {
        LiveVertex vertex{};
        vertex.position[0] = position[0]; vertex.position[1] = position[1];
        vertex.position[3] = 1;
        std::fill(vertex.color, vertex.color + 4, 1);
        draw.vertices.push_back(vertex);
    }
    std::vector<LiveDraw> draws{draw};
    const std::vector<LiveEfbCopy> copies;
    assert([renderer renderDraws:draws efbCopies:copies frame:0 error:&error]);
    u8 pixel[4]{};
    [renderer.latestTexture getBytes:pixel bytesPerRow:4
        fromRegion:MTLRegionMake2D(320, 240, 1, 1) mipmapLevel:0];
    assert(pixel[0] == 16 && pixel[1] == 32 && pixel[2] == 64 && pixel[3] == 255);

    // Source-bound replacement + original-art toggle change only artwork.
    // Prove full-frame original restoration, mip creation and cache reuse on
    // real Metal; this is a synthetic safety test, not an artistic verdict.
    std::vector<u8> originalFrame(640 * 480 * 4), restoredOriginal(originalFrame.size());
    [renderer.latestTexture getBytes:originalFrame.data() bytesPerRow:640 * 4
        fromRegion:MTLRegionMake2D(0, 0, 640, 480) mipmapLevel:0];
    NSURL* packURL = TestWriteTexturePack([output URLByAppendingPathComponent:@"pack"]);
    ProtectorLiveMetalRenderer* upgraded = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output texturePackManifest:packURL error:&error];
    assert(upgraded && !error && upgraded.restoredArtworkEnabled);
    assert([upgraded renderDraws:draws efbCopies:copies frame:0 error:&error]);
    [upgraded.latestTexture getBytes:pixel bytesPerRow:4
        fromRegion:MTLRegionMake2D(320, 240, 1, 1) mipmapLevel:0];
    assert(pixel[0] == 25 && pixel[1] == 50 && pixel[2] == 100 && pixel[3] == 255);
    assert(upgraded.texturePack.replacementUploads == 1 && upgraded.texturePack.entryCount == 1);
    // The logical mip bytes are 84, but GPU allocation padding also counts.
    assert(upgraded.texturePack.cacheBytes >= 84 &&
        upgraded.texturePack.frameWorkingSetBytes == upgraded.texturePack.cacheBytes);
    auto* preview = static_cast<ArtworkPreviewFrame*>(upgraded.artworkPreviewFrame);
    preview->draws = draws;
    preview->copies = copies;
    preview->index = 0;
    preview->valid = true;
    assert([upgraded selectRestoredArtwork:NO error:&error]);
    [upgraded.latestTexture getBytes:restoredOriginal.data() bytesPerRow:640 * 4
        fromRegion:MTLRegionMake2D(0, 0, 640, 480) mipmapLevel:0];
    assert(restoredOriginal == originalFrame && upgraded.texturePack.frameWorkingSetBytes == 0);
    assert([upgraded selectRestoredArtwork:YES error:&error]);
    assert(upgraded.texturePack.replacementUploads == 1);
    assert(upgraded.renderedFrameCount == 1 && upgraded.artworkPreviewRedrawCount == 2);
    assert([upgraded.stateCapture[@"frame_index"] isEqual:@0]);
    assert([upgraded.stateCapture[@"last_presentation_was_artwork_preview"] boolValue]);
    [upgraded.latestTexture getBytes:pixel bytesPerRow:4
        fromRegion:MTLRegionMake2D(320, 240, 1, 1) mipmapLevel:0];
    assert(pixel[0] == 25 && pixel[1] == 50 && pixel[2] == 100 && pixel[3] == 255);
    assert(![renderer selectRestoredArtwork:YES error:&error] && error.code == 25);
    error = nil;
    assert([renderer selectRestoredArtwork:NO error:&error] && !error);

    // The admitted zero-scale case is non-rasterizing, even when its color
    // differs from the background. Compare every GPU pixel, not just the center.
    std::vector<u8> beforePoint(640 * 480 * 4), afterPoint(beforePoint.size());
    [renderer.latestTexture getBytes:beforePoint.data() bytesPerRow:640 * 4
        fromRegion:MTLRegionMake2D(0, 0, 640, 480) mipmapLevel:0];
    LiveDraw point = draw;
    for (auto& vertex : point.vertices) {
        vertex.position[0] = 0.25f; vertex.position[1] = -0.25f;
        vertex.position[2] = 0.5f; vertex.position[3] = 1;
    }
    point.textureRGBA[0] = {255, 0, 255, 255};
    const std::vector<LiveDraw> withPoint{draw, point};
    assert([renderer renderDraws:withPoint efbCopies:copies frame:12 error:&error]);
    [renderer.latestTexture getBytes:afterPoint.data() bytesPerRow:640 * 4
        fromRegion:MTLRegionMake2D(0, 0, 640, 480) mipmapLevel:0];
    assert(beforePoint == afterPoint);

    // Production texture upload must use the immutable decode snapshot, not
    // the fallback vector. It also replaces a GPU cache entry at the same key.
    draw.decodedPixels[0] = std::make_shared<const std::vector<u8>>(
        std::initializer_list<u8>{200, 100, 50, 255});
    draw.textureRGBA[0] = {1, 1, 1, 1};
    draws[0] = draw;
    assert([renderer renderDraws:draws efbCopies:copies frame:9 error:&error]);
    [renderer.latestTexture getBytes:pixel bytesPerRow:4
        fromRegion:MTLRegionMake2D(320, 240, 1, 1) mipmapLevel:0];
    assert(pixel[0] == 25 && pixel[1] == 50 && pixel[2] == 100 && pixel[3] == 255);
    draw.decodedPixels[0].reset();

    // Actual ONE/ONE blending must add unweighted RGB and alpha. Using the
    // pre-existing source-alpha additive pipeline would make this too dark.
    LiveDraw base = draw;
    LiveDraw glow = draw;
    base.textureRGBA[0] = {80, 160, 240, 64};
    glow.textureRGBA[0] = {200, 100, 50, 64};
    glow.blendMode = 0x00313D;
    draws = {base, glow};
    assert([renderer renderDraws:draws efbCopies:copies frame:10 error:&error]);
    [renderer.latestTexture getBytes:pixel bytesPerRow:4
        fromRegion:MTLRegionMake2D(320, 240, 1, 1) mipmapLevel:0];
    assert(pixel[0] == 145 && pixel[1] == 130 && pixel[2] == 140 && pixel[3] == 128);
    draws = {base, glow, glow, glow};
    assert([renderer renderDraws:draws efbCopies:copies frame:11 error:&error]);
    [renderer.latestTexture getBytes:pixel bytesPerRow:4
        fromRegion:MTLRegionMake2D(320, 240, 1, 1) mipmapLevel:0];
    assert(pixel[0] == 195 && pixel[1] == 230 && pixel[2] == 255 && pixel[3] == 255);
    draws = {draw};

    // An indirect alpha value of 129, biased by -128, with a 512 coefficient
    // and a left shift of one produces an exact one-texel S offset.
    // This checks indirect sample channel order, bias, matrix and scale on GPU.
    draw.textureWidths[0] = 2;
    draw.textureRGBA[0] = {0, 0, 0, 255, 200, 100, 50, 255};
    draw.fragment.textureDimensions[0][0] = 2;
    draw.textureRGBA[4] = {0, 0, 0, 129};
    draw.fragment.indirectCount = 1;
    draw.fragment.indirectCommands[0] = (1u << 9u) | (1u << 4u);
    draw.fragment.indirectMatrices[0][0] = 512;
    draw.fragment.indirectMatrices[0][3] = -1;
    draws[0] = draw;
    assert([renderer renderDraws:draws efbCopies:copies frame:1 error:&error]);
    [renderer.latestTexture getBytes:pixel bytesPerRow:4
        fromRegion:MTLRegionMake2D(320, 240, 1, 1) mipmapLevel:0];
    assert(pixel[0] == 25 && pixel[1] == 50 && pixel[2] == 100 && pixel[3] == 255);

    LiveEfbCopy display;
    display.drawIndex = 1;
    display.width = 640;
    display.height = 448;
    display.command = 1u << 14u;
    display.yScale = 256;
    const std::vector<LiveEfbCopy> displayCopies{display};
    assert([renderer renderDraws:draws efbCopies:displayCopies frame:2 error:&error]);
    assert(renderer.latestTexture.width == 640 && renderer.latestTexture.height == 480);
    assert(renderer.latestPresentationTexture.width == 640 &&
           renderer.latestPresentationTexture.height == 448);
    [renderer.latestPresentationTexture getBytes:pixel bytesPerRow:4
        fromRegion:MTLRegionMake2D(320, 447, 1, 1) mipmapLevel:0];
    assert(pixel[0] == 25 && pixel[1] == 50 && pixel[2] == 100 && pixel[3] == 255);
    // Non-display copies must not accidentally crop the presentation.
    display.command = 0;
    const std::vector<LiveEfbCopy> textureCopies{display};
    assert([renderer renderDraws:draws efbCopies:textureCopies frame:3 error:&error]);
    assert(!renderer.latestPresentationTexture);

    // Different vertex ranges in one upload must survive an encoder restart.
    // An EFB copy between the two quads exercises that path without aliasing
    // either quad's ordinary texture address.
    LiveDraw left = draw;
    LiveDraw right = draw;
    left.fragment.indirectCount = right.fragment.indirectCount = 0;
    left.fragment.indirectCommands[0] = right.fragment.indirectCommands[0] = 0;
    left.textureWidths[0] = right.textureWidths[0] = 1;
    left.textureRGBA[0] = {128, 64, 32, 255};
    right.textureRGBA[0] = {200, 100, 50, 255};
    for (LiveVertex& vertex : left.vertices) vertex.position[0] = (vertex.position[0] - 1) * 0.5f;
    for (LiveVertex& vertex : right.vertices) vertex.position[0] = (vertex.position[0] + 1) * 0.5f;
    draws = {left, right};
    LiveEfbCopy betweenDraws = display;
    betweenDraws.drawIndex = 1;
    betweenDraws.destinationAddress = 0x01000000u;
    const std::vector<LiveEfbCopy> interleavedCopies{betweenDraws};
    assert([renderer renderDraws:draws efbCopies:interleavedCopies frame:4 error:&error]);
    [renderer.latestTexture getBytes:pixel bytesPerRow:4
        fromRegion:MTLRegionMake2D(160, 240, 1, 1) mipmapLevel:0];
    assert(pixel[0] == 16 && pixel[1] == 32 && pixel[2] == 64 && pixel[3] == 255);
    [renderer.latestTexture getBytes:pixel bytesPerRow:4
        fromRegion:MTLRegionMake2D(480, 240, 1, 1) mipmapLevel:0];
    assert(pixel[0] == 25 && pixel[1] == 50 && pixel[2] == 100 && pixel[3] == 255);

    // Regression at the real R8-mask/falloff spacing: the 16x16 ordinary
    // texture must reach the GPU, not the adjacent copied mask. Conversely,
    // an exact 256-square read must still consume the GPU copy.
    {
        auto maskCopy = betweenDraws;
        maskCopy.width = maskCopy.height = 256;
        maskCopy.destinationAddress = 268437600; maskCopy.command = 0x1000B;
        auto falloff = right;
        falloff.textureAddresses[0] = 268503168;
        falloff.textureWidths[0] = falloff.textureHeights[0] = 16;
        falloff.textureRGBA[0].clear();
        for (size_t i = 0; i < 16 * 16; ++i)
            falloff.textureRGBA[0].insert(falloff.textureRGBA[0].end(), {200, 100, 50, 255});
        assert(([renderer renderDraws:std::vector<LiveDraw>{left, falloff}
            efbCopies:std::vector<LiveEfbCopy>{maskCopy} frame:4 error:&error]));
        [renderer.latestTexture getBytes:pixel bytesPerRow:4
            fromRegion:MTLRegionMake2D(480, 240, 1, 1) mipmapLevel:0];
        assert(pixel[0] == 25 && pixel[1] == 50 && pixel[2] == 100 && pixel[3] == 255);
        falloff.textureAddresses[0] = maskCopy.destinationAddress;
        falloff.textureWidths[0] = falloff.textureHeights[0] = 256;
        assert(([renderer renderDraws:std::vector<LiveDraw>{left, falloff}
            efbCopies:std::vector<LiveEfbCopy>{maskCopy} frame:4 error:&error]));
        [renderer.latestTexture getBytes:pixel bytesPerRow:4
            fromRegion:MTLRegionMake2D(480, 240, 1, 1) mipmapLevel:0];
        assert(pixel[0] == 8 && pixel[1] == 16 && pixel[2] == 32 && pixel[3] == 255);
        assert([renderer renderDraws:draws efbCopies:interleavedCopies frame:4 error:&error]);
    }

    // Indexed triangles keep exact winding and per-draw base offsets across
    // the EFB encoder restart. Compare every pixel with expanded triangles.
    std::vector<u8> expanded(640 * 480 * 4), indexed(expanded.size());
    [renderer.latestTexture getBytes:expanded.data() bytesPerRow:640 * 4
        fromRegion:MTLRegionMake2D(0, 0, 640, 480) mipmapLevel:0];
    for (LiveDraw& indexedDraw : draws) {
        const auto original = indexedDraw.vertices;
        indexedDraw.vertices = {original[0], original[1], original[2], original[5]};
        indexedDraw.indices = {0, 1, 2, 2, 1, 3};
        indexedDraw.indexed = true;
    }
    assert([renderer renderDraws:draws efbCopies:interleavedCopies frame:5 error:&error]);
    [renderer.latestTexture getBytes:indexed.data() bytesPerRow:640 * 4
        fromRegion:MTLRegionMake2D(0, 0, 640, 480) mipmapLevel:0];
    assert(expanded == indexed);
    draws[0].indices[0] = 4;
    assert(![renderer renderDraws:draws efbCopies:copies frame:6 error:&error]);
    assert(error);
    error = nil;

    const std::vector<LiveDraw> noDraws;
    assert([renderer renderDraws:noDraws efbCopies:copies frame:5 error:&error]);
    [renderer.latestTexture getBytes:pixel bytesPerRow:4
        fromRegion:MTLRegionMake2D(320, 240, 1, 1) mipmapLevel:0];
    assert(pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 255);
}

static void TestPhysicalRenderScaling() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSURL* output = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[@"protector-scale-test-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    NSError* error = nil;
    ProtectorLiveMetalRenderer* original = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output error:&error];
    assert(original && original.renderScale == 1);
    assert(![original selectRenderScale:2 error:&error] && error.code == 26);
    error = nil;
    assert([original selectRenderScale:1 error:&error] && !error);

    // Resolution is an independent upgrade: no restored-art pack is present.
    ProtectorLiveMetalRenderer* renderer = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output texturePackManifest:nil
        presentationUpgrades:YES error:&error];
    assert(renderer && !error && renderer.renderScale == 1 && !renderer.restoredArtworkEnabled);
    renderer.projectionDiagnosticsEnabled = YES;
    LiveDraw draw;
    draw.projectionWords = {0x3F800000, 0, 0x40000000, 0, 0xBF800000, 0, 0};
    draw.sourceVertexCount = 4;
    draw.viewportX = 32; draw.viewportY = 16;
    draw.viewportWidth = 128; draw.viewportHeight = 96;
    draw.fragment.stageCount = 1;
    draw.fragment.colorCombiners[0] = 0x80000u | 0xF8DFu;
    draw.fragment.alphaCombiners[0] = 0x80000u | (7u << 13u) |
        (7u << 10u) | (7u << 7u) | (4u << 4u);
    draw.fragment.textureAlphaChannels[0] = 3;
    for (size_t stage = 0; stage < 8; ++stage) {
        draw.textureWidths[stage] = draw.textureHeights[stage] = 1;
        draw.textureRGBA[stage] = {128, 64, 32, 255};
        std::fill(draw.fragment.textureDimensions[stage],
                  draw.fragment.textureDimensions[stage] + 4, 1.0f);
    }
    const float positions[6][2] = {{-1,-1},{1,-1},{-1,1},{-1,1},{1,-1},{1,1}};
    for (const auto& position : positions) {
        LiveVertex vertex{};
        vertex.position[0] = position[0]; vertex.position[1] = position[1];
        vertex.position[3] = 1;
        std::fill(vertex.color, vertex.color + 4, 1);
        draw.vertices.push_back(vertex);
    }
    const std::vector<LiveDraw> draws{draw};
    LiveEfbCopy display;
    display.drawIndex = 1; display.sourceX = 16; display.sourceY = 8;
    display.width = 256; display.height = 224;
    display.command = 1u << 14u; display.yScale = 256;
    const std::vector<LiveEfbCopy> copies{display};
    assert([renderer renderDraws:draws efbCopies:copies frame:42 error:&error]);
    assert(renderer.latestTexture.width == 640 && renderer.latestPresentationTexture.width == 256);
    NSArray* profiles = renderer.stateCapture[@"projection_profiles"];
    assert(profiles.count == 1);
    assert([profiles[0][@"xf_words"][2] unsignedIntValue] == 0x40000000);
    assert([profiles[0][@"draw_count"] unsignedIntValue] == 1);
    assert([profiles[0][@"submitted_vertices"] unsignedIntValue] == 6);
    std::vector<u8> baseline(256 * 224 * 4), restored(baseline.size());
    [renderer.latestPresentationTexture getBytes:baseline.data() bytesPerRow:256 * 4
        fromRegion:MTLRegionMake2D(0, 0, 256, 224) mipmapLevel:0];
    auto* preview = static_cast<ArtworkPreviewFrame*>(renderer.artworkPreviewFrame);
    preview->draws = draws; preview->copies = copies; preview->index = 42; preview->valid = true;
    for (NSUInteger scale : {2u, 6u}) {
        assert([renderer selectRenderScale:scale error:&error] && !error);
        assert(renderer.latestTexture.width == 640 * scale && renderer.latestTexture.height == 480 * scale);
        assert(renderer.latestPresentationTexture.width == 256 * scale);
        assert(renderer.latestPresentationTexture.height == 224 * scale);
        u8 pixel[4]{};
        [renderer.latestPresentationTexture getBytes:pixel bytesPerRow:4
            fromRegion:MTLRegionMake2D(16 * scale, 8 * scale, 1, 1) mipmapLevel:0];
        assert(pixel[0] == 16 && pixel[1] == 32 && pixel[2] == 64 && pixel[3] == 255);
        [renderer.latestPresentationTexture getBytes:pixel bytesPerRow:4
            fromRegion:MTLRegionMake2D(16 * scale - 1, 8 * scale - 1, 1, 1) mipmapLevel:0];
        assert(pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 0);
        assert(renderer.renderedFrameCount == 1 && [renderer.stateCapture[@"frame_index"] isEqual:@42]);
        assert([renderer.stateCapture[@"presentation_aspect"] isEqual:@"4:3"]);
        assert([renderer.stateCapture[@"last_presentation_was_resolution_preview"] boolValue]);
        assert(![renderer.stateCapture[@"last_presentation_was_artwork_preview"] boolValue]);
    }
    assert([renderer selectRenderScale:1 error:&error]);
    [renderer.latestPresentationTexture getBytes:restored.data() bytesPerRow:256 * 4
        fromRegion:MTLRegionMake2D(0, 0, 256, 224) mipmapLevel:0];
    assert(restored == baseline && renderer.renderedFrameCount == 1);
    assert(renderer.resolutionPreviewRedrawCount == 3);
    for (NSUInteger scale : {0u, 7u}) {
        assert(![renderer selectRenderScale:scale error:&error] && error.code == 26);
        error = nil;
        assert(renderer.renderScale == 1);
    }

    // Native uses the actual 256x224 display crop, not the 640x480 EFB.
    assert([renderer selectNativeRenderSize:CGSizeMake(1024, 448) error:&error]);
    // Each axis covers the drawable once: 1024x448, not a uniform 1024x896.
    assert(renderer.nativeResolutionEnabled && renderer.renderScale == 4 && renderer.renderScaleY == 2);
    assert(renderer.latestPresentationTexture.width == 1024);
    assert(renderer.latestPresentationTexture.height == 448);
    assert([renderer.stateCapture[@"native_resolution_enabled"] boolValue]);
    assert([renderer.stateCapture[@"frame_index"] isEqual:@42] && renderer.renderedFrameCount == 1);
    // Initial EFB bounds fit, but the retained crop cannot cover this drawable.
    assert(![renderer selectNativeRenderSize:CGSizeMake(2622, 1206) error:&error]);
    assert(error.code == 26 && renderer.nativeResolutionEnabled && renderer.renderScale == 4);
    assert(CGSizeEqualToSize(renderer.nativeRenderPixelSize, CGSizeMake(1024,448)));
    error = nil;
    assert([renderer selectRenderScale:4 error:&error]);
    assert(!renderer.nativeResolutionEnabled && ![renderer.stateCapture[@"native_resolution_enabled"] boolValue]);
    assert([renderer selectNativeRenderSize:CGSizeMake(640, 672) error:&error]);
    assert(renderer.renderScale == 3 && renderer.renderScaleY == 3);
    assert([renderer selectNativeRenderSize:CGSizeMake(1280, 1120) error:&error]);
    assert(renderer.renderScale == 5 && renderer.renderScaleY == 5);
    assert([renderer selectRenderScale:1 error:&error]);
    assert(renderer.renderScaleY == 1); // Fixed scales stay uniform.
    [renderer.latestPresentationTexture getBytes:restored.data() bytesPerRow:256 * 4
        fromRegion:MTLRegionMake2D(0, 0, 256, 224) mipmapLevel:0];
    assert(restored == baseline && renderer.renderedFrameCount == 1);
    assert(![original selectNativeRenderSize:CGSizeMake(640,480) error:&error]);
    assert(error.code == 26 && !original.nativeResolutionEnabled);
    error = nil;

    // A bounded live queue may publish an immutable picture before completion.
    // Diagnostic capture must wait for that exact command, outside the lock.
    id<MTLTexture> retained = renderer.latestPresentationTexture;
    [renderer setPresentationPaused:YES];
    [renderer setPresentationPaused:NO];
    assert(renderer.synchronizeNextLiveRender);
    renderer.asynchronousPresentationRender = YES;
    assert([renderer renderDraws:draws efbCopies:copies frame:42 error:&error] && !error);
    assert(!renderer.synchronizeNextLiveRender);
    assert(renderer.latestRenderCommand.status == MTLCommandBufferStatusCompleted);
    for (unsigned i = 0; i < 12; ++i)
        assert([renderer renderDraws:draws efbCopies:copies frame:42 error:&error] && !error);
    [renderer.latestRenderCommand waitUntilCompleted];
    // Live frames reuse pooled targets once earlier frames complete.
    assert(!renderer.renderTargetOptimizationsEnabled || renderer.resourcePool.reuseCount > 0);
    renderer.asynchronousPresentationRender = NO;
    NSDictionary* asynchronousSnapshot = [renderer writeLatestDiagnosticFrameToURL:
        [output URLByAppendingPathComponent:@"asynchronous-frame.png"] error:&error];
    assert(asynchronousSnapshot && !error && [asynchronousSnapshot[@"frame_index"] isEqual:@42]);
    assert(renderer.latestRenderCommand.status == MTLCommandBufferStatusCompleted);
    [ReadableTexture(renderer.latestPresentationTexture,&error) getBytes:restored.data() bytesPerRow:256 * 4
        fromRegion:MTLRegionMake2D(0, 0, 256, 224) mipmapLevel:0];
    assert(restored == baseline);
    [retained getBytes:restored.data() bytesPerRow:256 * 4
        fromRegion:MTLRegionMake2D(0, 0, 256, 224) mipmapLevel:0];
    assert(restored == baseline && !renderer.failure);

    // Live presentation appends its final pass to the scene command before
    // committing; synchronous transactions must never leave a pending command.
    renderer.asynchronousPresentationRender = YES;
    renderer.deferPresentationCommit = YES;
    assert([renderer renderDraws:draws efbCopies:copies frame:42 error:&error] && !error);
    assert(renderer.pendingPresentationCommand == renderer.latestRenderCommand);
    assert(renderer.latestRenderCommand.status == MTLCommandBufferStatusNotEnqueued);
    id<MTLBlitCommandEncoder> tail = [renderer.pendingPresentationCommand blitCommandEncoder];
    assert(tail); [tail endEncoding];
    [renderer.pendingPresentationCommand commit];
    renderer.pendingPresentationCommand = nil;
    renderer.deferPresentationCommit = NO;
    renderer.asynchronousPresentationRender = NO;
    assert([renderer writeLatestDiagnosticFrameToURL:
        [output URLByAppendingPathComponent:@"combined-frame.png"] error:&error] && !error);
    [ReadableTexture(renderer.latestPresentationTexture,&error) getBytes:restored.data() bytesPerRow:256 * 4
        fromRegion:MTLRegionMake2D(0, 0, 256, 224) mipmapLevel:0];
    assert(restored == baseline && !renderer.failure);

    // Intermediate EFB copies scale their physical regions, but matching guest
    // texture addresses/dimensions retain original logical byte counts.
    assert([renderer selectRenderScale:2 error:&error]);
    assert(renderer.latestRenderCommand.status == MTLCommandBufferStatusCompleted);
    LiveEfbCopy efb = display;
    efb.sourceX = 32; efb.sourceY = 16; efb.width = efb.height = 64;
    efb.command = 0; efb.destinationAddress = 0x6000;
    LiveDraw copied = draw;
    copied.viewportX = copied.viewportY = 200;
    copied.viewportWidth = copied.viewportHeight = 64;
    copied.textureAddresses[0] = efb.destinationAddress;
    copied.textureWidths[0] = copied.textureHeights[0] = 64;
    const std::vector<LiveDraw> interleaved{draw, copied};
    const std::vector<LiveEfbCopy> intermediate{efb};
    assert([renderer renderDraws:interleaved efbCopies:intermediate frame:43 error:&error]);
    u8 pixel[4]{};
    [renderer.latestTexture getBytes:pixel bytesPerRow:4
        fromRegion:MTLRegionMake2D(402, 402, 1, 1) mipmapLevel:0];
    assert(pixel[0] == 8 && pixel[1] == 16 && pixel[2] == 32 && pixel[3] == 255);
    // A larger physical target must not admit rectangles outside the guest EFB.
    efb.sourceX = 639; efb.width = 2;
    const std::vector<LiveEfbCopy> invalid{efb};
    assert(![renderer renderDraws:interleaved efbCopies:invalid frame:44 error:&error]);
    assert(error.code == 12);
}

static void TestAlphaTestAndSubtractiveBlend() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSURL* output = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[@"protector-alpha-test-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    NSError* error = nil;
    ProtectorLiveMetalRenderer* renderer = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output error:&error];
    assert(renderer && !error);
    LiveDraw background;
    background.viewportWidth = background.viewportHeight = 16;
    background.fragment.stageCount = 1;
    background.fragment.colorCombiners[0] = 0x8FFF8u;
    background.fragment.alphaCombiners[0] = 0x80000u | (7u << 13u) |
        (7u << 10u) | (7u << 7u) | (4u << 4u);
    background.fragment.textureAlphaChannels[0] = 3;
    for (size_t stage = 0; stage < 8; ++stage) {
        background.textureWidths[stage] = background.textureHeights[stage] = 1;
        background.textureRGBA[stage] = {128, 96, 64, 255};
        std::fill(background.fragment.textureDimensions[stage],
            background.fragment.textureDimensions[stage] + 4, 1.0f);
    }
    for (auto point : {std::array<float,2>{-1,-1}, {1,-1}, {-1,1}, {-1,1}, {1,-1}, {1,1}}) {
        LiveVertex vertex{};
        vertex.position[0] = point[0]; vertex.position[1] = point[1]; vertex.position[3] = 1;
        background.vertices.push_back(vertex);
    }
    LiveDraw foreground = background;
    foreground.textureRGBA[0] = {48, 32, 16, 0};
    auto render = [&] {
        assert([renderer renderDraws:std::vector<LiveDraw>({background, foreground})
            efbCopies:std::vector<LiveEfbCopy>() frame:1 error:&error]);
        std::array<u8,4> pixel{};
        [renderer.latestTexture getBytes:pixel.data() bytesPerRow:4
            fromRegion:MTLRegionMake2D(8,8,1,1) mipmapLevel:0];
        return pixel;
    };
    // The live shadow material's zero alpha is valid under ALWAYS/ALWAYS.
    assert((render() == std::array<u8,4>{16,32,48,0}));
    foreground.blendMode = 0x3C3D; // Actual GX shadow state, including subtract.
    assert((render() == std::array<u8,4>{48,64,80,255}));
    foreground.blendMode = (1u << 11u) | (1u << 8u) | 1u; // encoded ONE/ZERO still subtracts
    assert((render() == std::array<u8,4>{48,64,80,255}));
    foreground.blendMode = 1u << 11u; // subtract bit alone does not enable blending
    assert((render() == std::array<u8,4>{16,32,48,0}));
    foreground.blendMode = 0;
    auto compare = [](u32 value, u32 reference, u32 op) {
        const bool expected[] = {false, value < reference, value == reference, value <= reference,
            value > reference, value != reference, value >= reference, true};
        return expected[op];
    };
    for (u32 slot : {0u, 1u}) for (u32 op = 0; op < 8; ++op) for (u32 alpha : {0u,127u,128u,129u,255u}) {
        foreground.textureRGBA[0][3] = (u8)alpha;
        foreground.fragment.alphaTest = 128u | (128u << 8u) |
            ((slot == 0 ? op : 7u) << 16u) | ((slot == 1 ? op : 7u) << 19u);
        assert(render()[2] == (compare(alpha, 128, op) ? 48 : 128));
    }
    for (u32 logic = 0; logic < 4; ++logic) for (u32 first : {0u, 7u}) for (u32 second : {0u, 7u}) {
        foreground.fragment.alphaTest = (first << 16u) | (second << 19u) | (logic << 22u);
        const bool a = first != 0, b = second != 0;
        const bool expected[] = {a && b, a || b, a != b, a == b};
        assert(render()[2] == (expected[logic] ? 48 : 128));
    }
    DecoderState source;
    source.bp[0xF3] = 0xA91234;
    LiveDraw decoded;
    NSString* decodeError = nil;
    assert(PopulateFragmentState(source, &decoded, &decodeError));
    assert(decoded.fragment.alphaTest == source.bp[0xF3]);
    auto changed = decoded.fragment;
    changed.alphaTest ^= 1;
    assert(!MotionFragmentCompatible(decoded.fragment, changed));
}

static void TestZeroAlphaPictureNoWrites() {
    LiveDraw background;
    background.viewportWidth = background.viewportHeight = 16;
    background.sourceVertexCount = 6;
    background.fragment.stageCount = 1;
    background.fragment.colorCombiners[0] = 64143;
    background.fragment.alphaCombiners[0] = 63088;
    background.fragment.textureAlphaChannels[0] = 3;
    background.fragment.rasterAlphaChannels[0] = 3;
    for (size_t stage = 0; stage < 8; ++stage) {
        background.textureWidths[stage] = background.textureHeights[stage] = 1;
        background.textureRGBA[stage] = {128,96,64,127};
        std::fill(background.fragment.textureDimensions[stage],
            background.fragment.textureDimensions[stage] + 4, 1.0f);
    }
    for (auto point : {std::array<float,2>{-1,-1}, {1,-1}, {-1,1}, {-1,1}, {1,-1}, {1,1}}) {
        LiveVertex vertex{};
        vertex.position[0] = point[0]; vertex.position[1] = point[1];
        vertex.position[2] = .5f; vertex.position[3] = 1;
        std::fill(vertex.color, vertex.color + 4, 1.0f);
        background.vertices.push_back(vertex);
    }
    LiveDraw foreground = background;
    foreground.projectionWords[6] = 1;
    foreground.blendMode = 13501;
    foreground.depthMode = 15;
    foreground.textureRGBA[0] = {48,32,16,255};
    for (auto& vertex : foreground.vertices) vertex.color[3] = 0;
    auto eligible = [](const LiveDraw& draw) {
        return ZeroAlphaPictureHasNoWrites(draw,draw.vertices.data(),draw.vertices.size());
    };
    assert(eligible(foreground));
    assert(!ZeroAlphaPictureHasNoWrites(foreground,nullptr,6));
    assert(!ZeroAlphaPictureHasNoWrites(foreground,foreground.vertices.data(),0));
    auto reject = [&](auto mutate) {
        auto changed = foreground; mutate(changed); assert(!eligible(changed));
    };
    reject([](LiveDraw& d) { d.projectionWords[6] = 0; });
    reject([](LiveDraw& d) { d.blendMode = 0; });
    reject([](LiveDraw& d) { d.blendMode = 0x3C3D; }); // subtractive shadow
    reject([](LiveDraw& d) { d.blendMode = 0x11D; }); // replace blend
    reject([](LiveDraw& d) { d.blendMode = 0x121; }); // ONE/ONE
    reject([](LiveDraw& d) { d.depthMode |= 16; });
    reject([](LiveDraw& d) { d.fragment.stageCount = 2; });
    reject([](LiveDraw& d) { d.fragment.indirectCount = 1; });
    reject([](LiveDraw& d) { d.fragment.colorCombiners[0] ^= 1; });
    reject([](LiveDraw& d) { d.fragment.alphaCombiners[0] ^= 1; });
    reject([](LiveDraw& d) { d.fragment.textureAlphaChannels[0] = 0; });
    reject([](LiveDraw& d) { d.fragment.rasterAlphaChannels[0] = 0; });
    reject([](LiveDraw& d) { d.fragment.alphaTest = 0; });
    reject([](LiveDraw& d) { d.vertices.back().color[3] = 1.0f/255; });
    reject([](LiveDraw& d) { d.vertices.back().color[0] = NAN; });
    reject([](LiveDraw& d) { d.vertices.back().color[0] = 2; });
    reject([](LiveDraw& d) { d.vertices.back().position[0] = INFINITY; });
    reject([](LiveDraw& d) { d.vertices.back().position[3] = 0; });
    reject([](LiveDraw& d) { d.vertices.back().uv[0][0] = NAN; });
    reject([](LiveDraw& d) { d.fragment.textureDimensions[0][0] = 0; });
    reject([](LiveDraw& d) { d.fragment.textureDimensions[0][1] = INFINITY; });

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSURL* output = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[@"protector-no-write-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    NSError* error = nil;
    ProtectorLiveMetalRenderer* renderer = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output error:&error];
    assert(renderer && !error);
    auto render = [&](const std::vector<LiveDraw>& draws, bool bypass,
                      const std::vector<LiveEfbCopy>& copies = {}) {
        renderer.disableNoWriteCulling = bypass;
        assert([renderer renderDraws:draws efbCopies:copies frame:42 error:&error] && !error);
        const auto texture = renderer.latestTexture;
        std::vector<u8> pixels(texture.width * texture.height * 4);
        [texture getBytes:pixels.data() bytesPerRow:texture.width*4
            fromRegion:MTLRegionMake2D(0,0,texture.width,texture.height) mipmapLevel:0];
        return pixels;
    };
    const std::vector<LiveDraw> draws{background,foreground};
    const auto reference = render(draws,true);
    assert([renderer.stateCapture[@"no_write_culled_draws"] unsignedIntegerValue] == 0);
    assert(reference == render(draws,false));
    assert([renderer.stateCapture[@"no_write_culled_draws"] unsignedIntegerValue] == 1);
    assert(reference == render({background},false));
    // A copy exactly at the skipped draw's boundary must still run and remain
    // available to a later consumer. Compare complete RGBA targets, not a pixel.
    LiveEfbCopy copy;
    copy.drawIndex = 1; copy.width = copy.height = 16;
    copy.destinationAddress = 0x6000; copy.yScale = 256;
    LiveDraw consumer = background;
    consumer.viewportX = 32;
    consumer.textureAddresses[0] = copy.destinationAddress;
    consumer.textureWidths[0] = consumer.textureHeights[0] = 16;
    const std::vector<LiveDraw> copied{background,foreground,consumer};
    assert(render(copied,true,{copy}) == render(copied,false,{copy}));
    // Fully visible and tiny-alpha pictures must render, not be thresholded.
    for (float alpha : {1.0f/255, .5f, 1.0f}) {
        for (auto& vertex : foreground.vertices) vertex.color[3] = alpha;
        const std::vector<LiveDraw> visible{background,foreground};
        assert(render(visible,true) == render(visible,false));
        assert([renderer.stateCapture[@"no_write_culled_draws"] unsignedIntegerValue] == 0);
    }
    std::puts("Zero-alpha picture no-write proof, negative guards, exact RGBA and EFB boundary tests passed");
}

static void TestFiniteBackdropAdmission() {
    assert(FiniteBackdropSourceIdentity(nullptr) == 0);
    assert(FiniteBackdropSourceIdentity("") == 0);
    assert(FiniteBackdropSourceIdentity("0dcb7cf93707cb516d0f046aa75ddfc17d6b2e1285da53235ea0e3775f4a2923") == 1);
    assert(FiniteBackdropSourceIdentity("f0ca2a5b6c6a9e9ece97d460fab97b2b4c1b0c0b2a58457a98125c280937c8e4") == 14);
    assert(FiniteBackdropSourceIdentity("0dcb7cf93707cb516d0f046aa75ddfc17d6b2e1285da53235ea0e3775f4a2924") == 0);
    LiveDraw source;
    source.viewportHeight = 448; source.displayListDepth = 1; source.sourceVertexCount = 3;
    source.blendMode = 13500; source.depthMode = 23; source.cullMode = 2;
    source.fragment.stageCount = 1; source.fragment.colorCombiners[0] = 587951;
    source.fragment.alphaCombiners[0] = 586480;
    source.textureWidths[0] = source.textureHeights[0] = 64; source.textureFormats[0] = 14;
    assert(FiniteBackdropMaterialMatches(source));
    auto reject = [&](auto mutate) { auto changed = source; mutate(changed); assert(!FiniteBackdropMaterialMatches(changed)); };
    reject([](LiveDraw& d) { d.sourceVertexCount = 430; });
    reject([](LiveDraw& d) { d.displayListDepth = 0; });
    reject([](LiveDraw& d) { d.projectionWords[6] = 1; });
    reject([](LiveDraw& d) { d.viewportWidth = 256; });
    reject([](LiveDraw& d) { d.cullMode = 0; });
    reject([](LiveDraw& d) { d.blendMode ^= 1; });
    reject([](LiveDraw& d) { d.fragment.colorCombiners[0] ^= 1; });
    reject([](LiveDraw& d) { d.fragment.alphaCombiners[0] ^= 1; });
    reject([](LiveDraw& d) { d.fragment.stageCount = 2; });
    reject([](LiveDraw& d) { d.fragment.indirectCount = 1; });
    reject([](LiveDraw& d) { d.fragment.alphaTest = 0; });
    reject([](LiveDraw& d) { d.textureFormats[0] = 0; });
    auto changed = source; changed.finiteBackdropIdentity = 1;
    assert(!MotionStateCompatible(source, changed));
    assert([MotionStateDifferences(source, changed) containsObject:@"finiteBackdropIdentity"]);
    source.finiteBackdropIdentity = 1; assert(MotionStateCompatible(source, changed));
}

static LiveDraw SyntheticRepeatingBackdrop(u8 identity) {
    // Synthetic plane coordinates, source-profile UVs. This fixture does not
    // contain game geometry or claim to exercise real source-hash admission.
    static const s16 uv[4][3][2] = {
        {{-24,1007},{-1628,10},{-1628,1007}}, {{-24,10},{1743,1007},{1743,10}},
        {{1743,1007},{-24,10},{-24,1007}}, {{-1628,10},{-24,1007},{-24,10}}};
    LiveDraw draw;
    draw.repeatingBackdropIdentity = identity;
    draw.viewportHeight = 448;
    draw.displayListDepth = 1; draw.sourceVertexCount = 3;
    draw.blendMode = 13501; draw.depthMode = 23; draw.cullMode = 2;
    draw.fragment.stageCount = 2;
    draw.fragment.colorCombiners[0] = 587951; draw.fragment.alphaCombiners[0] = 65520;
    draw.fragment.colorCombiners[1] = 589808; draw.fragment.alphaCombiners[1] = 586492;
    for (size_t stage = 0; stage < 2; ++stage) {
        draw.textureWidths[stage] = 256; draw.textureHeights[stage] = 128;
        draw.textureFormats[stage] = 14; draw.textureModes[stage] = 2206901;
    }
    for (size_t i = 0; i < 3; ++i) {
        LiveVertex vertex{};
        for (size_t stage = 0; stage < 2; ++stage) for (size_t component = 0; component < 2; ++component)
            vertex.uv[stage][component] = uv[identity-1][i][component]/1024.0f;
        vertex.position[0] = vertex.uv[0][0]*0.55f;
        vertex.position[1] = (0.5f-vertex.uv[0][1])*0.5f+0.6f;
        vertex.position[2] = 0.8f; vertex.position[3] = 1;
        for (float& component : vertex.color) component = 1;
        draw.vertices.push_back(vertex);
    }
    return draw;
}

static void TestRepeatingBackdropAdmission() {
    assert(RepeatingBackdropSourceIdentity(nullptr) == 0);
    assert(RepeatingBackdropSourceIdentity("unknown") == 0);
    assert(RepeatingBackdropSourceIdentity("8f56d6148837c51e3f29de3a0667c85be077392529e1f295c96effce69cd9b94") == 1);
    assert(RepeatingBackdropSourceIdentity("e8725bb6c3853efb445ac842a22405962e4bbfa1e7aa9814c1257adcd92fc821") == 4);
    auto draw = SyntheticRepeatingBackdrop(1);
    assert(RepeatingBackdropMaterialMatches(draw));
    assert(!RepeatingBackdropTexturesMatch(draw));
    auto reject = [&](auto mutate) { auto changed = draw; mutate(changed); assert(!RepeatingBackdropMaterialMatches(changed)); };
    reject([](LiveDraw& d) { d.sourceVertexCount = 6; });
    reject([](LiveDraw& d) { d.projectionWords[6] = 1; });
    reject([](LiveDraw& d) { d.cullMode = 0; });
    reject([](LiveDraw& d) { d.blendMode ^= 1; });
    reject([](LiveDraw& d) { d.depthMode ^= 1; });
    reject([](LiveDraw& d) { d.fragment.stageCount = 1; });
    reject([](LiveDraw& d) { d.fragment.indirectCount = 1; });
    reject([](LiveDraw& d) { d.fragment.alphaCombiners[1] ^= 1; });
    reject([](LiveDraw& d) { d.textureModes[1] &= ~3u; });
    reject([](LiveDraw& d) { d.textureCoordinates[1] = 1; });
    reject([](LiveDraw& d) { d.textureWidths[0] = 128; });
    std::vector<LiveDraw> cohort;
    for (u8 identity = 1; identity <= 4; ++identity) {
        cohort.push_back(SyntheticRepeatingBackdrop(identity));
        assert(RepeatingBackdropSourceUVMatches(identity,cohort.back().vertices));
    }
    assert(RepeatingBackdropCohort(cohort));
    auto bad = cohort; bad.pop_back(); assert(!RepeatingBackdropCohort(bad));
    bad = cohort; bad.push_back(draw); assert(!RepeatingBackdropCohort(bad));
    bad = cohort; bad[3].projectionWords[0] ^= 1; assert(!RepeatingBackdropCohort(bad));
    auto changed = draw; changed.vertices[0].uv[1][0] += 1.0f/1024;
    assert(!RepeatingBackdropSourceUVMatches(1,changed.vertices));
    changed = draw; changed.repeatingBackdropIdentity = 0;
    assert(!MotionStateCompatible(draw,changed));
    assert([MotionStateDifferences(draw,changed) containsObject:@"repeatingBackdropIdentity"]);
    std::array<LiveVertex,12> extension{};
    for (u8 identity : {1,2}) {
        auto source = SyntheticRepeatingBackdrop(identity);
        auto original = source.vertices;
        assert(RepeatingBackdropExtension(source,&extension));
        assert(!memcmp(original.data(),source.vertices.data(),original.size()*sizeof(LiveVertex)));
        for (size_t i = 0; i < extension.size(); ++i) {
            const auto& vertex = extension[i];
            assert(std::abs(vertex.position[0]-vertex.uv[0][0]*0.55f) < 1e-6f);
            assert((i >= 6 && vertex.position[1] == -1) ||
                std::abs(vertex.position[1]-((0.5f-vertex.uv[0][1])*0.5f+0.6f)) < 1e-6f);
            assert(vertex.position[2] == 0.8f && vertex.position[3] == 1);
            assert(!memcmp(vertex.uv[0],vertex.uv[1],sizeof(vertex.uv[0])));
            if (i >= 6) assert(vertex.uv[0][1] == 1007.0f/1024);
        }
        source.indexed = true; source.indices = {2,1,0};
        assert(RepeatingBackdropExtension(source,&extension));
        source.indices = {3,1,0}; assert(!RepeatingBackdropExtension(source,&extension));
    }
    auto extensionReject = [&](auto mutate) { auto changed = draw; mutate(changed); assert(!RepeatingBackdropExtension(changed,&extension)); };
    extensionReject([](LiveDraw& d) { d.repeatingBackdropIdentity = 0; });
    extensionReject([](LiveDraw& d) { d.vertices[0].position[0] = NAN; });
    extensionReject([](LiveDraw& d) { d.vertices[0].position[3] = 0; });
    extensionReject([](LiveDraw& d) { d.vertices[0].uv[0][0] = INFINITY; });
    extensionReject([](LiveDraw& d) { d.vertices[0].uv[0][1] = d.vertices[1].uv[0][1] = d.vertices[2].uv[0][1]; });
    extensionReject([](LiveDraw& d) { d.vertices[1].position[3] = d.vertices[2].position[3] = 0.01f; });
    assert(!RepeatingBackdropExtension(cohort[2],&extension));
    assert(!RepeatingBackdropExtension(cohort[3],&extension));
}

static LiveDraw SyntheticHillBackdrop(u8 identity) {
    // Source-profile UV metadata on an invented affine plane. No proprietary
    // positions/pixels; real source identity remains a separate native QA gate.
    static const s16 uv[2][16][2] = {
        {{279,-1062},{279,-1096},{-1974,-750},{-1974,-785},{-1974,-785},
         {-187,977},{-187,977},{279,-1062},{-1974,977},{-1974,-750}},
        {{505,964},{340,706},{-1990,967},{-1990,967},{-1989,375},{-1989,375},
         {-1989,375},{-1990,967},{-156,-65},{340,706},{340,706},{-156,-65},
         {-156,-65},{-156,-113},{-1989,375},{-1989,327}}};
    LiveDraw draw;
    draw.hillBackdropIdentity=identity;
    draw.viewportHeight=448; draw.displayListDepth=1;
    draw.sourceVertexCount=identity==1 ? 10 : 16;
    draw.blendMode=13500; draw.depthMode=23; draw.cullMode=2;
    draw.fragment.stageCount=1;
    draw.fragment.colorCombiners[0]=587951; draw.fragment.alphaCombiners[0]=586480;
    draw.textureWidths[0]=draw.textureHeights[0]=256;
    draw.textureFormats[0]=14; draw.textureModes[0]=2206901;
    for (size_t i=0;i<draw.sourceVertexCount;++i) {
        LiveVertex vertex{};
        for (size_t component=0;component<2;++component) vertex.uv[0][component]=uv[identity-1][i][component]/1024.0f;
        vertex.position[0]=vertex.uv[0][0]*.5f;
        vertex.position[1]=.5f-vertex.uv[0][1]*.3f;
        vertex.position[2]=.8f; vertex.position[3]=1;
        std::fill(std::begin(vertex.color),std::end(vertex.color),1);
        draw.vertices.push_back(vertex);
    }
    draw.indexed=true;
    NSString* error=nil;
    assert(BuildPrimitiveIndices(0x98,draw.sourceVertexCount,&draw.indices,&error));
    return draw;
}

static void TestHillBackdropAdmission() {
    assert(HillBackdropSourceIdentity(nullptr)==0 && HillBackdropSourceIdentity("unknown")==0);
    assert(HillBackdropSourceIdentity("f26f343c83fb17636859687d8c84f0c275cf92999446f9ab5d5b85bc1abee1ac")==1);
    assert(HillBackdropSourceIdentity("e6cd4b69752db4009811d1dbfc57f97fc22aab24c812f5006bd424bf25d5376a")==2);
    auto source=SyntheticHillBackdrop(1);
    assert(HillBackdropMaterialMatches(source));
    assert(!HillBackdropTexturesMatch(source));
    auto reject=[&](auto mutate) { auto changed=source; mutate(changed); assert(!HillBackdropMaterialMatches(changed)); };
    reject([](LiveDraw& d) { d.sourceVertexCount=11; });
    reject([](LiveDraw& d) { d.displayListDepth=0; });
    reject([](LiveDraw& d) { d.projectionWords[6]=1; });
    reject([](LiveDraw& d) { d.blendMode^=1; });
    reject([](LiveDraw& d) { d.depthMode^=1; });
    reject([](LiveDraw& d) { d.cullMode=0; });
    reject([](LiveDraw& d) { d.fragment.stageCount=2; });
    reject([](LiveDraw& d) { d.fragment.indirectCount=1; });
    reject([](LiveDraw& d) { d.fragment.colorCombiners[0]^=1; });
    reject([](LiveDraw& d) { d.fragment.alphaCombiners[0]^=1; });
    reject([](LiveDraw& d) { d.textureWidths[0]=128; });
    reject([](LiveDraw& d) { d.textureHeights[0]=128; });
    reject([](LiveDraw& d) { d.textureFormats[0]=5; });
    reject([](LiveDraw& d) { d.textureCoordinates[0]=1; });
    reject([](LiveDraw& d) { d.textureModes[0]^=1; });
    std::vector<LiveDraw> cohort{source,SyntheticHillBackdrop(2)};
    assert(HillBackdropCohort(cohort));
    auto bad=cohort; bad.pop_back(); assert(!HillBackdropCohort(bad));
    bad=cohort; bad.push_back(source); assert(!HillBackdropCohort(bad));
    bad=cohort; bad[1].projectionWords[0]^=1; assert(!HillBackdropCohort(bad));
    bad=cohort; bad[1].viewportWidth+=1; assert(!HillBackdropCohort(bad));
    bad=cohort; bad[1].indices[0]=100; assert(!HillBackdropCohort(bad));
    auto changed=source; changed.hillBackdropIdentity=0;
    assert(!MotionStateCompatible(source,changed));
    assert([MotionStateDifferences(source,changed) containsObject:@"hillBackdropIdentity"]);
    assert(!HillBackdropSourceUVMatches(0,source.vertices));
    changed=source; changed.vertices[0].uv[0][0]+=1.0f/1024;
    assert(!HillBackdropSourceUVMatches(1,changed.vertices));
    std::array<LiveVertex,12> extension{};
    for (u8 identity : {1,2}) {
        auto d=SyntheticHillBackdrop(identity);
        assert(HillBackdropSourceUVMatches(identity,d.vertices));
        assert(HillBackdropTopologyMatches(d));
        const size_t ink0=identity==1 ? 2 : 14, ink1=identity==1 ? 3 : 15;
        for (size_t i : {ink0,ink1}) for (size_t c=0;c<3;++c) d.vertices[i].color[c]=.2f;
        auto original=d.vertices;
        assert(HillBackdropExtension(d,&extension));
        assert(!memcmp(original.data(),d.vertices.data(),original.size()*sizeof(LiveVertex)));
        for (size_t i=0;i<extension.size();++i) {
            const auto& v=extension[i];
            assert(std::abs(v.position[0]-v.uv[0][0]*.5f)<1e-6);
            assert(std::abs(v.position[1]-(.5f-v.uv[0][1]*.3f))<1e-6);
            assert(v.position[2]==.8f && v.position[3]==1);
            assert(v.color[0]==(i<6 ? 1 : .2f));
        }
        // Indexed and flattened strip draws must create byte-identical added
        // geometry, including distinct body/ink colors at their shared corner.
        auto expanded=d; expanded.vertices.clear(); expanded.indexed=false;
        for (u32 i : d.indices) expanded.vertices.push_back(d.vertices[i]);
        expanded.indices.clear();
        std::array<LiveVertex,12> flat{};
        assert(HillBackdropExtension(expanded,&flat));
        assert(!memcmp(extension.data(),flat.data(),sizeof(extension)));
        expanded.vertices.pop_back(); assert(!HillBackdropExtension(expanded,&flat));
        // Mirror vertical geometry to exercise the opposite source winding.
        for (auto& v : d.vertices) v.position[1]=-v.position[1];
        assert(HillBackdropExtension(d,&extension));
    }
    auto extensionReject=[&](auto mutate) { auto changed=source; mutate(changed); assert(!HillBackdropExtension(changed,&extension)); };
    extensionReject([](LiveDraw& d) { d.hillBackdropIdentity=0; });
    extensionReject([](LiveDraw& d) { d.sourceVertexCount=16; });
    extensionReject([](LiveDraw& d) { d.indices[0]=2; });
    extensionReject([](LiveDraw& d) { d.vertices[0].position[0]=NAN; });
    extensionReject([](LiveDraw& d) { d.vertices[0].position[3]=0; });
    extensionReject([](LiveDraw& d) { d.vertices[0].color[0]=INFINITY; });
    extensionReject([](LiveDraw& d) { d.vertices[0].uv[0][0]=INFINITY; });
    extensionReject([](LiveDraw& d) { for (auto& v:d.vertices) v.uv[0][1]=0; });
    extensionReject([](LiveDraw& d) { for (auto& v:d.vertices) v.position[1]=0; });
    extensionReject([](LiveDraw& d) { for (auto& v:d.vertices) v.position[0]=-v.position[0]; });
    extensionReject([](LiveDraw& d) { for (auto& v:d.vertices) v.position[3]=1+v.uv[0][0]*.4f; });
}

static LiveDraw SyntheticCanyonSky(u8 identity, float phase = 0.25f) {
    assert(identity == 1 || identity == 2);
    LiveDraw draw;
    draw.canyonSkyIdentity = identity; draw.sourceVertexCount = 3;
    draw.viewportHeight = 448; draw.displayListDepth = 1;
    draw.blendMode = 13500; draw.depthMode = 23; draw.cullMode = 2;
    draw.fragment.stageCount = 1; draw.fragment.colorCombiners[0] = 587951;
    draw.fragment.alphaCombiners[0] = 586480;
    draw.textureWidths[0] = draw.textureHeights[0] = 64;
    draw.textureFormats[0] = 14; draw.textureModes[0] = 2206901;
    const float uv[2][3][2] = {{{1,28.0f/1024},{2,987.0f/1024},{2,28.0f/1024}},
                              {{2,987.0f/1024},{1,28.0f/1024},{1,987.0f/1024}}};
    for (size_t i = 0; i < 3; ++i) {
        LiveVertex v{};
        v.uv[0][0] = uv[identity-1][i][0] + phase;
        v.uv[0][1] = uv[identity-1][i][1];
        v.position[0] = uv[identity-1][i][0] - 0.8f;
        v.position[1] = 0.95f - v.uv[0][1]*0.4f;
        v.position[2] = 0.8f; v.position[3] = 1;
        std::fill(std::begin(v.color), std::end(v.color), 1);
        draw.vertices.push_back(v);
    }
    return draw;
}

static void TestCanyonSkyAdmission() {
    assert(CanyonSkySourceIdentity(nullptr) == 0 && CanyonSkySourceIdentity("unknown") == 0);
    assert(CanyonSkySourceIdentity("99d012d1caf85808dd590d7abac608111ee32aa664784fa3ab784361c576766b") == 1);
    assert(CanyonSkySourceIdentity("bc88bbfe894fb9549d56b2e8659da9bc8886fec3a653fb48576bbbc02569c214") == 2);
    auto source = SyntheticCanyonSky(1);
    assert(CanyonSkyMaterialMatches(source) && !CanyonSkyTextureMatches(source));
    auto rejectMaterial = [&](auto mutate) { auto d = source; mutate(d); assert(!CanyonSkyMaterialMatches(d)); };
    rejectMaterial([](auto& d) { d.sourceVertexCount = 4; });
    rejectMaterial([](auto& d) { d.displayListDepth = 2; });
    rejectMaterial([](auto& d) { d.viewportWidth = 256; });
    rejectMaterial([](auto& d) { d.projectionWords[6] = 1; });
    rejectMaterial([](auto& d) { d.fragment.stageCount = 2; });
    rejectMaterial([](auto& d) { d.textureModes[0] &= ~3u; });
    rejectMaterial([](auto& d) { d.textureCoordinates[0] = 1; });
    rejectMaterial([](auto& d) { d.fragment.alphaTest = 0; });
    rejectMaterial([](auto& d) { d.depthMode ^= 1; });
    const std::vector<LiveDraw> pair{source, SyntheticCanyonSky(2)};
    assert(CanyonSkyCohort(pair));
    auto reject = [&](auto mutate) { auto d = pair; mutate(d); assert(!CanyonSkyCohort(d)); };
    reject([](auto& d) { d.pop_back(); });
    reject([](auto& d) { d.push_back(d[0]); });
    reject([](auto& d) { d[1].canyonSkyIdentity = 3; });
    reject([](auto& d) { d[1].projectionWords[0] = 1; });
    reject([](auto& d) { d[1].viewportWidth = 641; });
    reject([](auto& d) { d[1].vertices[0].position[0] += .01; });
    reject([](auto& d) { d[1].vertices[2].position[0] = NAN; });
    reject([](auto& d) { d[1].vertices[2].position[3] = 0; });
    reject([](auto& d) { d[1].vertices[0].color[0] = .5; });
    reject([](auto& d) { d[1].vertices[2].color[0] = NAN; });
    reject([](auto& d) { d[0].vertices[2].uv[0][0] += 1.0f/1024; });
    reject([](auto& d) { d[0].vertices[2].uv[0][1] += 1.0f/1024; });
    reject([](auto& d) { for (auto& v : d[1].vertices) v.uv[0][0] += .125; });
    reject([](auto& d) { d[1].indexed = true; d[1].indices = {0,0,2}; });
    auto changed = source; changed.canyonSkyIdentity = 0;
    assert(!MotionStateCompatible(source, changed));
    assert([MotionStateDifferences(source, changed) containsObject:@"canyonSkyIdentity"]);
    std::array<LiveVertex, 6> extension{};
    for (float phase : {-0.25f, 0.0f, 0.73811126f, 0.999f, 8.125f}) {
        source = SyntheticCanyonSky(1, phase);
        const auto original = source.vertices;
        assert(CanyonSkyCohort({source, SyntheticCanyonSky(2, phase)}));
        assert(CanyonSkyExtension(source, &extension));
        assert(!memcmp(original.data(), source.vertices.data(), original.size()*sizeof(LiveVertex)));
        for (const auto& v : extension) {
            assert(std::abs(v.position[0] - (v.uv[0][0] - phase - .8f)) < 1e-6);
            assert(v.position[2] == .8f && v.position[3] == 1);
            assert(!memcmp(v.color, source.vertices[0].color, sizeof(v.color)));
        }
        source.indexed = true; source.indices = {2,1,0};
        assert(CanyonSkyExtension(source, &extension));
        source.indices = {3,1,0}; assert(!CanyonSkyExtension(source, &extension));
    }
    auto rejectExtension = [&](auto mutate) { auto d = pair[0]; mutate(d); assert(!CanyonSkyExtension(d, &extension)); };
    rejectExtension([](auto& d) { d.canyonSkyIdentity = 2; });
    rejectExtension([](auto& d) { d.vertices[0].position[0] = NAN; });
    rejectExtension([](auto& d) { d.vertices[0].color[0] = NAN; });
    rejectExtension([](auto& d) { d.vertices[0].uv[0][0] = INFINITY; });
    rejectExtension([](auto& d) { d.vertices[2].position[3] = 0; });
    rejectExtension([](auto& d) { d.vertices[2].position[3] = .1f; });
    rejectExtension([](auto& d) { for (auto& v : d.vertices) v.position[1] = .5; });
    rejectExtension([](auto& d) { for (auto& v : d.vertices) v.position[0] *= -1; });
    // Optional actual translated-source clip geometry, kept outside Git.
    if (const char* path = getenv("PROTECTOR_CANYON_SKY_SOURCE_AUDIT")) {
        NSError* error = nil;
        NSDictionary* audit = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(path)] options:0 error:&error];
        assert(audit && !error && [audit[@"source_vertices_immutable"] boolValue]);
        std::vector<LiveDraw> actual;
        for (NSDictionary* item in audit[@"identities"]) {
            const u8 identity = CanyonSkySourceIdentity([item[@"source_position_sequence_sha256"] UTF8String]);
            if (!identity) continue;
            LiveDraw draw = SyntheticCanyonSky(identity); draw.vertices.clear();
            for (NSDictionary* sample in item[@"decoded_vertices"]) {
                LiveVertex vertex{};
                for (size_t i = 0; i < 4; ++i) vertex.position[i] = [sample[@"clip"][i] floatValue];
                for (size_t i = 0; i < 2; ++i) vertex.uv[0][i] = [sample[@"uv"][i] floatValue];
                std::fill(std::begin(vertex.color), std::end(vertex.color), 1);
                draw.vertices.push_back(vertex);
            }
            actual.push_back(draw);
        }
        assert(actual.size() == 2 && CanyonSkyCohort(actual));
        const auto before = MotionVertexDigest(actual);
        const auto& edge = actual[0].canyonSkyIdentity == 1 ? actual[0] : actual[1];
        assert(CanyonSkyExtension(edge, &extension));
        assert([before isEqual:MotionVertexDigest(actual)]);
        // Two U repeats reach beyond the widest supported 3:1 right margin.
        assert(std::any_of(extension.begin(), extension.end(), [](const auto& v) {
            return (v.position[0]/v.position[3])*(4.0/9.0) > 1;
        }));
        std::puts("Canyon sky: actual source clip geometry admitted; immutable repeat continuation reaches 3:1 margin.");
    }
}

static LiveDraw SyntheticCitySky(u8 identity, float phase = .25f) {
    LiveDraw draw = SyntheticCanyonSky(1);
    draw.canyonSkyIdentity = 0; draw.citySkyIdentity = identity;
    draw.sourceVertexCount = (u32)CitySkySourceCount(identity);
    draw.textureWidths[0] = draw.textureHeights[0] = 128;
    draw.indexed = true; draw.vertices.clear();
    const int u[] = {0,-450,-450,-1351,-1351,-1351,0,0,0,-450,-450,-1351,-1351,-1351,0,0,0,-450,-450,-1351,-1351};
    const int v[2][21] = {{710,483,710,483,710,710,846,846,846,710,846,710,846,846,993,993,993,846,993,846,993},
                          {483,30,483,30,483}};
    assert(draw.sourceVertexCount);
    for (size_t i = 0; i < draw.sourceVertexCount; ++i) {
        LiveVertex vertex{};
        vertex.uv[0][0] = phase + u[i]/1024.0f;
        vertex.uv[0][1] = v[identity-1][i]/1024.0f;
        vertex.position[0] = u[i]/1024.0f;
        vertex.position[1] = 2.8f - vertex.uv[0][1]*3;
        vertex.position[2] = .8f; vertex.position[3] = 1;
        std::fill(std::begin(vertex.color), std::end(vertex.color), 1);
        draw.vertices.push_back(vertex);
    }
    NSString* error = nil;
    assert(BuildPrimitiveIndices(0x98, draw.sourceVertexCount, &draw.indices, &error));
    return draw;
}

static LiveDraw ExpandedCitySky(LiveDraw draw) {
    assert(draw.indexed);
    const auto original = draw.vertices;
    draw.vertices.clear();
    for (u32 index : draw.indices) draw.vertices.push_back(original[index]);
    draw.indices.clear(); draw.indexed = false;
    return draw;
}

static void TestCitySkyAdmission() {
    assert(CitySkySourceIdentity(nullptr) == 0 && CitySkySourceIdentity("unknown") == 0);
    assert(CitySkySourceIdentity("b5f3360c0774217ff96fae18db04656f2a21e516d5aab49a122d802e092ace49") == 1);
    assert(CitySkySourceIdentity("910c3a2ff90fe14dc6c67044b359503a58c51380e667ee982832cd8e68730d09") == 2);
    const std::vector<LiveDraw> pair{SyntheticCitySky(1), SyntheticCitySky(2)};
    assert(CitySkyMaterialMatches(pair[0]) && CitySkyMaterialMatches(pair[1]));
    assert(!CitySkyTextureMatches(pair[0]) && CitySkyCohort(pair));
    auto rejectMaterial = [&](auto mutate) { auto draw = pair[0]; mutate(draw); assert(!CitySkyMaterialMatches(draw)); };
    rejectMaterial([](auto& d) { d.sourceVertexCount = 20; });
    rejectMaterial([](auto& d) { d.displayListDepth = 2; });
    rejectMaterial([](auto& d) { d.viewportWidth = 256; });
    rejectMaterial([](auto& d) { d.projectionWords[6] = 1; });
    rejectMaterial([](auto& d) { d.fragment.stageCount = 2; });
    rejectMaterial([](auto& d) { d.fragment.indirectCount = 1; });
    rejectMaterial([](auto& d) { d.fragment.alphaTest = 0; });
    rejectMaterial([](auto& d) { d.textureModes[0] ^= 1; });
    rejectMaterial([](auto& d) { d.textureCoordinates[0] = 1; });
    rejectMaterial([](auto& d) { d.textureWidths[0] = 64; });
    rejectMaterial([](auto& d) { d.depthMode ^= 1; });
    auto reject = [&](auto mutate) { auto draws = pair; mutate(draws); assert(!CitySkyCohort(draws)); };
    reject([](auto& d) { d.pop_back(); });
    reject([](auto& d) { d.push_back(d[0]); });
    reject([](auto& d) { d[1].citySkyIdentity = 3; });
    reject([](auto& d) { d[1].projectionWords[0] ^= 1; });
    reject([](auto& d) { d[1].viewportX = 1; });
    reject([](auto& d) { d[1].vertices[2].position[0] += .01f; });
    reject([](auto& d) { d[1].vertices[4].color[0] = .5f; });
    reject([](auto& d) { for (auto& v : d[1].vertices) v.uv[0][0] += .125f; });
    reject([](auto& d) { d[0].vertices[12].uv[0][1] += 1.0f/1024; });
    reject([](auto& d) { d[0].vertices[0].position[3] = 0; });
    reject([](auto& d) { d[1].vertices[0].color[0] = INFINITY; });
    reject([](auto& d) { d[0].indices[0] = 2; });
    reject([](auto& d) { d[0].indices.pop_back(); });
    reject([](auto& d) { d[0] = ExpandedCitySky(d[0]); d[0].vertices[4].position[0] += .01f; });
    auto changed = pair[0]; changed.citySkyIdentity = 0;
    assert(!MotionStateCompatible(pair[0], changed));
    assert([MotionStateDifferences(pair[0], changed) containsObject:@"citySkyIdentity"]);
    std::array<LiveVertex,18> extension{};
    for (float phase : {-.25f, 0.0f, .73811126f, .999f, 8.125f}) {
        const auto draw = SyntheticCitySky(1, phase);
        const auto original = draw.vertices;
        assert(CitySkyCohort({draw, SyntheticCitySky(2, phase)}));
        assert(CitySkyExtension(draw, &extension));
        assert(!memcmp(original.data(), draw.vertices.data(), original.size()*sizeof(LiveVertex)));
        for (const auto& vertex : extension) {
            assert(std::abs(vertex.position[0] - (vertex.uv[0][0]-phase)) < 2e-6f);
            assert(vertex.position[2] == .8f && vertex.position[3] == 1);
        }
        std::array<LiveVertex,18> flat{};
        assert(CitySkyExtension(ExpandedCitySky(draw), &flat));
        assert(!memcmp(extension.data(), flat.data(), sizeof(extension)));
        assert(CitySkyCohort({ExpandedCitySky(draw), ExpandedCitySky(SyntheticCitySky(2, phase))}));
    }
    auto rejectExtension = [&](auto mutate) { auto draw = pair[0]; mutate(draw); assert(!CitySkyExtension(draw, &extension)); };
    rejectExtension([](auto& d) { d.citySkyIdentity = 2; });
    rejectExtension([](auto& d) { d.vertices[0].position[0] = NAN; });
    rejectExtension([](auto& d) { d.vertices[0].uv[0][0] = NAN; });
    rejectExtension([](auto& d) { for (auto& v : d.vertices) v.position[1] = .5f; });
    rejectExtension([](auto& d) { for (auto& v : d.vertices) v.position[0] *= -1; });
    rejectExtension([](auto& d) { d.vertices[3].position[3] = .01f; });
    if (const char* path = getenv("PROTECTOR_CITY_SKY_SOURCE_AUDIT")) {
        NSError* error = nil;
        NSDictionary* audit = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(path)] options:0 error:&error];
        assert(audit && !error && [audit[@"source_vertices_immutable"] boolValue]);
        std::vector<LiveDraw> actual;
        for (NSDictionary* item in audit[@"identities"]) {
            const u8 identity = CitySkySourceIdentity([item[@"source_position_sequence_sha256"] UTF8String]);
            if (!identity) continue;
            LiveDraw draw = SyntheticCitySky(identity); draw.vertices.clear(); draw.indices.clear();
            for (NSDictionary* sample in item[@"decoded_vertices"]) {
                LiveVertex vertex{};
                for (size_t i = 0; i < 4; ++i) {
                    vertex.position[i] = [sample[@"clip"][i] floatValue];
                    vertex.color[i] = [sample[@"color"][i] floatValue];
                }
                for (size_t i = 0; i < 2; ++i) vertex.uv[0][i] = [sample[@"uv"][i] floatValue];
                draw.vertices.push_back(vertex);
            }
            draw.indexed = [item[@"indexed"] boolValue];
            for (NSNumber* value in item[@"indices"]) draw.indices.push_back(value.unsignedIntValue);
            for (size_t i = 0; i < 7; ++i) draw.projectionWords[i] = [item[@"projection_words"][i] unsignedIntValue];
            actual.push_back(draw);
        }
        assert(actual.size() == 2 && CitySkyCohort(actual));
        const auto before = MotionVertexDigest(actual);
        const auto& edge = actual[0].citySkyIdentity == 1 ? actual[0] : actual[1];
        assert(CitySkyExtension(edge, &extension));
        assert([before isEqual:MotionVertexDigest(actual)]);
        // All four continued boundary rows reach beyond the supported 3:1 left edge.
        size_t beyond = 0;
        for (const auto& vertex : extension)
            beyond += vertex.position[0]/vertex.position[3]*(4.0/9.0) < -1;
        assert(beyond == 9);
        std::array<LiveVertex,18> expanded{};
        assert(CitySkyExtension(ExpandedCitySky(edge), &expanded));
        assert(!memcmp(extension.data(), expanded.data(), sizeof(extension)));
        std::puts("City sky: actual source geometry/animated UVs admitted; immutable indexed/expanded continuation reaches 3:1.");
    }
}

static LiveDraw SyntheticRelatedCitySky(u8 identity, float phase = .25f) {
    auto draw = SyntheticCitySky(1, phase);
    draw.citySkyIdentity = 0; draw.relatedCitySkyIdentity = identity;
    draw.sourceVertexCount = (u32)RelatedCitySkySourceCount(identity);
    draw.vertices.clear(); draw.indices.clear();
    const int u[4][9] = {{0,-953,-953,-953,0,0,0,-953,-953},
        {0,-953,-953,-953,0,0,0,-953,-953},
        {0,346,346,346,346,684,684},{346,684,684}};
    const int v[4][9] = {{713,476,713,713,476,476,476,30,476},
        {845,713,845,845,993,993,993,845,993},
        {560,12,560,560,560,12,560},{1014,560,1014}};
    assert(draw.sourceVertexCount);
    for (size_t i = 0; i < draw.sourceVertexCount; ++i) {
        LiveVertex vertex{};
        vertex.uv[0][0] = phase + u[identity-1][i]/1024.0f;
        vertex.uv[0][1] = v[identity-1][i]/1024.0f;
        vertex.position[0] = (identity <= 2 ? 1 : -1)*u[identity-1][i]/1024.0f;
        vertex.position[1] = 2.8f - vertex.uv[0][1]*3;
        vertex.position[2] = .8f; vertex.position[3] = 1;
        std::fill(std::begin(vertex.color), std::end(vertex.color), 1);
        draw.vertices.push_back(vertex);
    }
    NSString* error = nil;
    assert(BuildPrimitiveIndices(0x98, draw.sourceVertexCount, &draw.indices, &error));
    return draw;
}

static void TestRelatedCitySkyAdmission() {
    assert(!RelatedCitySkySourceIdentity(nullptr) && !RelatedCitySkySourceIdentity("unknown"));
    assert(RelatedCitySkySourceIdentity("ac9153b4946f6e38ffd502a631a84f6caed62ef07ad40da7861059ae501b5961") == 1);
    assert(RelatedCitySkySourceIdentity("0cd22e54a294857c11cdc393b7ce948d98e250d8e86af3297cb3294a204769d0") == 2);
    assert(RelatedCitySkySourceIdentity("6420a97ac92ba9e9ce4576a83b966c82c33addb86ae7b53a43de08bc7928a90a") == 3);
    assert(RelatedCitySkySourceIdentity("5facb82de19f15db1023a71ec05a21b690f5335ee1a0e12b659473c7bbcffb95") == 4);
    for (u8 first : {1,3}) {
        const u8 cohort = first == 1 ? 1 : 2;
        const std::vector<LiveDraw> pair{SyntheticRelatedCitySky(first), SyntheticRelatedCitySky(first+1)};
        assert(RelatedCitySkyMaterialMatches(pair[0]) && RelatedCitySkyMaterialMatches(pair[1]));
        auto rejectMaterial = [&](auto mutate) { auto d=pair[0]; mutate(d); assert(!RelatedCitySkyMaterialMatches(d)); };
        rejectMaterial([](auto& d){ d.displayListDepth=2; });
        rejectMaterial([](auto& d){ d.sourceVertexCount=8; });
        rejectMaterial([](auto& d){ d.viewportWidth=256; });
        rejectMaterial([](auto& d){ d.projectionWords[6]=1; });
        rejectMaterial([](auto& d){ d.fragment.stageCount=2; });
        rejectMaterial([](auto& d){ d.fragment.indirectCount=1; });
        rejectMaterial([](auto& d){ d.fragment.alphaTest=0; });
        rejectMaterial([](auto& d){ d.fragment.colorCombiners[0]^=1; });
        rejectMaterial([](auto& d){ d.textureModes[0]^=1; });
        rejectMaterial([](auto& d){ d.textureCoordinates[0]=1; });
        rejectMaterial([](auto& d){ d.textureWidths[0]=64; });
        rejectMaterial([](auto& d){ d.depthMode^=1; });
        auto reject = [&](auto mutate) {
            auto draws=pair; mutate(draws);
            std::vector<std::vector<LiveVertex>> untouched(1, std::vector<LiveVertex>(1));
            assert(!RelatedCitySkyContinuation(draws,&untouched));
            assert(untouched.size()==1 && untouched[0].size()==1);
        };
        reject([](auto& d){ d.pop_back(); });
        reject([](auto& d){ d.push_back(d[0]); });
        reject([](auto& d){ d[1].relatedCitySkyIdentity=5; });
        reject([](auto& d){ d[1].projectionWords[0]^=1; });
        reject([](auto& d){ d[1].viewportX=1; });
        reject([](auto& d){ d[1].vertices[1].position[0]+=.01f; });
        reject([](auto& d){ d[1].vertices[1].color[0]=.5f; });
        reject([](auto& d){ for(auto& v:d[1].vertices)v.uv[0][0]+=.125f; });
        reject([](auto& d){ d[0].vertices[0].uv[0][1]+=1.0f/1024; });
        reject([](auto& d){ d[0].vertices[0].uv[0][0]=NAN; });
        reject([](auto& d){ d[0].vertices[0].position[0]=INFINITY; });
        reject([](auto& d){ d[0].vertices[0].position[3]=0; });
        reject([](auto& d){ d[1].vertices[0].color[0]=NAN; });
        reject([](auto& d){ d[0].indices[0]=2; });
        reject([](auto& d){ d[0].indices.pop_back(); });
        reject([](auto& d){ d[0]=ExpandedCitySky(d[0]); d[0].vertices[4].position[0]+=.01f; });
        reject([](auto& d){ for(auto& s:d)for(auto& v:s.vertices)v.position[1]=.5f; });
        reject([](auto& d){ for(auto& s:d)for(auto& v:s.vertices)v.position[0]*=-1; });
        reject([](auto& d){ d[1].vertices[0].position[0]+=.1f; });
        auto changed=pair[0]; changed.relatedCitySkyIdentity=0;
        assert(!MotionStateCompatible(pair[0],changed));
        assert([MotionStateDifferences(pair[0],changed) containsObject:@"relatedCitySkyIdentity"]);
        for(float phase:{-.25f,0.0f,.73811126f,.999f,8.125f}) {
            std::vector<LiveDraw> draws{SyntheticRelatedCitySky(first,phase),SyntheticRelatedCitySky(first+1,phase)};
            const auto before=MotionVertexDigest(draws);
            std::vector<std::vector<LiveVertex>> extension,flat;
            assert(RelatedCitySkyContinuation(draws,nullptr)==cohort);
            assert(RelatedCitySkyContinuation(draws,&extension)==cohort);
            assert([before isEqual:MotionVertexDigest(draws)]);
            assert(extension.size()==2 && extension[0].size()==(first==1?12:6));
            assert(RelatedCitySkyContinuation({ExpandedCitySky(draws[0]),ExpandedCitySky(draws[1])},&flat)==cohort);
            for(size_t piece=0;piece<2;++piece) {
                assert(flat[piece].size()==extension[piece].size());
                assert(!memcmp(flat[piece].data(),extension[piece].data(),flat[piece].size()*sizeof(LiveVertex)));
                for(const auto& vertex:extension[piece]) {
                    assert(std::abs(vertex.position[0]-(first==1?1:-1)*(vertex.uv[0][0]-phase))<2e-6f);
                    assert(vertex.position[2]==.8f && vertex.position[3]==1);
                }
            }
        }
    }
    assert(!RelatedCitySkyContinuation({SyntheticRelatedCitySky(1),SyntheticRelatedCitySky(4)},nullptr));
    if(const char* path=getenv("PROTECTOR_RELATED_CITY_SKY_SOURCE_AUDIT")) {
        NSError* error=nil;
        NSDictionary* report=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(path)] options:0 error:&error];
        assert(report && !error && [report[@"cases"] count]==2);
        for(NSDictionary* item in report[@"cases"]) {
            std::vector<LiveDraw> draws;
            for(NSDictionary* row in item[@"source_rows"]) {
                NSDictionary* sample=row[@"identity"];
                const u8 identity=RelatedCitySkySourceIdentity([sample[@"source_position_sequence_sha256"] UTF8String]);
                assert(identity);
                auto d=SyntheticRelatedCitySky(identity);d.vertices.clear();d.indices.clear();
                for(NSDictionary* value in sample[@"decoded_vertices"]) {
                    LiveVertex v{};
                    for(size_t i=0;i<4;++i){v.position[i]=[value[@"clip"][i] floatValue];v.color[i]=[value[@"color"][i] floatValue];}
                    for(size_t i=0;i<2;++i)v.uv[0][i]=[value[@"uv"][i] floatValue];
                    d.vertices.push_back(v);
                }
                d.indexed=[sample[@"indexed"] boolValue];
                for(NSNumber* i in sample[@"indices"])d.indices.push_back(i.unsignedIntValue);
                for(size_t i=0;i<7;++i)d.projectionWords[i]=[sample[@"projection_words"][i] unsignedIntValue];
                draws.push_back(d);
            }
            assert(draws.size()==2);
            const auto before=MotionVertexDigest(draws);
            std::vector<std::vector<LiveVertex>> extensions,flat;
            const u8 cohort=RelatedCitySkyContinuation(draws,&extensions);
            assert(cohort && [before isEqual:MotionVertexDigest(draws)]);
            assert(RelatedCitySkyContinuation({ExpandedCitySky(draws[0]),ExpandedCitySky(draws[1])},&flat)==cohort);
            size_t beyond=0;
            for(size_t piece=0;piece<2;++piece) {
                assert(flat[piece].size()==extensions[piece].size());
                assert(!memcmp(flat[piece].data(),extensions[piece].data(),flat[piece].size()*sizeof(LiveVertex)));
                for(const auto& v:extensions[piece])beyond+=v.position[0]/v.position[3]*(4.0/9.0)<-1;
            }
            assert(beyond==(cohort==1?12:6));
        }
        std::puts("Related city sky: both actual source cohorts admit immutable indexed/expanded continuations reaching 3:1.");
    }
}

static void TestTextureProjectionDiagnostic() {
    DecoderState state;
    state.xf[0x1040] = 6; // Regular XYZ source with STQ projection.
    state.xf[0] = state.xf[5] = state.xf[10] = 0x3F800000;
    const float normal[3]{}, rawTextures[8][3]{}, color[4]{.2f,.3f,.4f,1};
    const u32 matrices[8]{};
    for (float q : {0.0f, .5f, 1.0f, 4.0f}) {
        const float position[3]{2,3,q};
        float oldUV[2]{}, measuredUV[2]{}, measuredQ = NAN;
        assert(GenerateTextureCoordinate(state,0,position,normal,rawTextures,matrices,color,oldUV));
        assert(GenerateTextureCoordinate(state,0,position,normal,rawTextures,matrices,color,measuredUV,&measuredQ));
        assert(measuredQ == q && !memcmp(oldUV,measuredUV,sizeof(oldUV)));
        assert(measuredUV[0] == 2/(q ? q : 1));
    }
    state.xf[0x1040] = 0; // ST generation always has the implicit unit Q.
    const float position[3]{2,3,9};
    float uv[2]{}, q = NAN;
    assert(GenerateTextureCoordinate(state,0,position,normal,rawTextures,matrices,color,uv,&q));
    assert(q == 1 && uv[0] == 2 && uv[1] == 3);
    state.xf[0x1040] = 0x20; // Color-derived coordinates also retain unit Q.
    assert(GenerateTextureCoordinate(state,0,position,normal,rawTextures,matrices,color,uv,&q));
    assert(q == 1 && uv[0] == color[0] && uv[1] == color[1]);
    std::puts("Texture Q diagnostics preserve the existing UV result; variable-Q rendering is not corrected by this measurement.");
}

static void TestWidescreenPreview() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSURL* output = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[@"protector-wide-test-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    NSError* error = nil;
    ProtectorLiveMetalRenderer* original = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output error:&error];
    assert(original && !original.widescreenEnabled);
    assert(![original selectWidescreen:YES error:&error] && error.code == 27);
    error = nil;
    assert([original selectWidescreen:NO error:&error] && !error);
    ProtectorLiveMetalRenderer* renderer = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output texturePackManifest:nil
        presentationUpgrades:YES error:&error];
    assert(renderer && !error && !renderer.widescreenEnabled);
    auto rectangle = [](float left, float right, float bottom, float top,
                         u8 red, u8 green, u8 blue, bool orthographic) {
        LiveDraw draw;
        draw.projectionWords[6] = orthographic ? 1 : 0;
        draw.viewportHeight = 448;
        draw.sourceVertexCount = 4;
        draw.fragment.stageCount = 1;
        draw.fragment.colorCombiners[0] = 0x80000u | 0xF8DFu;
        draw.fragment.alphaCombiners[0] = 0x80000u | (7u << 13u) |
            (7u << 10u) | (7u << 7u) | (4u << 4u);
        draw.fragment.textureAlphaChannels[0] = 3;
        for (size_t stage = 0; stage < 8; ++stage) {
            draw.textureWidths[stage] = draw.textureHeights[stage] = 1;
            draw.textureRGBA[stage] = {red, green, blue, 255};
            std::fill(draw.fragment.textureDimensions[stage],
                draw.fragment.textureDimensions[stage] + 4, 1.0f);
        }
        const float positions[6][2] = {{left,bottom},{right,bottom},{left,top},
            {left,top},{right,bottom},{right,top}};
        for (const auto& position : positions) {
            LiveVertex vertex{};
            vertex.position[0] = position[0]; vertex.position[1] = position[1];
            vertex.position[3] = 1;
            std::fill(vertex.color, vertex.color + 4, 1);
            draw.vertices.push_back(vertex);
        }
        return draw;
    };
    LiveDraw background = rectangle(-2,2,-1,1,20,40,80,false);
    LiveDraw center = rectangle(-0.25,0.25,-0.25,0.25,200,0,0,false);
    LiveDraw newlyVisible = rectangle(1.1,1.3,-0.25,0.25,240,240,0,false);
    LiveDraw hud = rectangle(-0.9,-0.6,0.4,0.8,0,200,0,true);
    assert(ClassifyWideDraw(background) == WideDrawRole::Scene);
    assert(ClassifyWideDraw(hud) == WideDrawRole::SafeArea);
    LiveDraw fade = rectangle(-1,1,-1,1,0,0,0,true);
    assert(ClassifyWideDraw(fade) == WideDrawRole::ScreenFill);
    fade.textureWidths[0] = 640; // A movie or a fullscreen artwork is not a fade.
    assert(ClassifyWideDraw(fade) == WideDrawRole::SafeArea);
    LiveDraw shadow = background;
    shadow.viewportWidth = shadow.viewportHeight = 256;
    assert(ClassifyWideDraw(shadow) == WideDrawRole::Unchanged);
    shadow.viewportWidth = 640; shadow.viewportHeight = 448; shadow.viewportX = 5;
    assert(ClassifyWideDraw(shadow) == WideDrawRole::Unchanged);
    const std::vector<LiveDraw> draws{background,center,newlyVisible,hud};
    LiveEfbCopy display;
    display.drawIndex = draws.size(); display.width = 640; display.height = 448;
    display.command = 1u << 14u; display.yScale = 256;
    const std::vector<LiveEfbCopy> copies{display};
    assert([renderer renderDraws:draws efbCopies:copies frame:77 error:&error]);
    std::vector<u8> baseline(640 * 448 * 4), roundtrip(baseline.size());
    [renderer.latestPresentationTexture getBytes:baseline.data() bytesPerRow:640*4
        fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    auto* preview = static_cast<ArtworkPreviewFrame*>(renderer.artworkPreviewFrame);
    preview->draws = draws; preview->copies = copies; preview->index = 77; preview->valid = true;
    auto pixel = [&](NSUInteger x, NSUInteger y) {
        std::array<u8,4> result{};
        [renderer.latestPresentationTexture getBytes:result.data() bytesPerRow:4
            fromRegion:MTLRegionMake2D(x,y,1,1) mipmapLevel:0];
        return result;
    };
    assert((pixel(250,224) == std::array<u8,4>{0,0,100,255}));
    assert((pixel(608,224) == std::array<u8,4>{40,20,10,255}));
    assert([renderer selectWidescreen:YES error:&error] && !error);
    assert(renderer.latestPresentationTexture.width == 640);
    assert((pixel(250,224) == std::array<u8,4>{40,20,10,255}));
    assert((pixel(270,224) == std::array<u8,4>{0,0,100,255}));
    assert((pixel(608,224) == std::array<u8,4>{0,120,120,255}));
    assert((pixel(120,80) == std::array<u8,4>{0,100,0,255}));
    assert((pixel(50,80) == std::array<u8,4>{40,20,10,255}));
    assert([renderer.stateCapture[@"presentation_aspect"] isEqual:@"16:9"]);
    assert([renderer.stateCapture[@"widescreen_scene_draws"] unsignedIntValue] == 3);
    assert([renderer.stateCapture[@"widescreen_safe_area_draws"] unsignedIntValue] == 1);
    assert([renderer.stateCapture[@"last_presentation_was_aspect_preview"] boolValue]);
    assert(renderer.renderedFrameCount == 1 && renderer.aspectPreviewRedrawCount == 1);
    assert(preview->draws[1].vertices[0].position[0] == -0.25f);
    assert([renderer selectRenderScale:3 error:&error] && renderer.widescreenEnabled);
    assert((pixel(608*3,224*3) == std::array<u8,4>{0,120,120,255}));
    assert([renderer selectRenderScale:1 error:&error]);
    assert([renderer selectWidescreen:NO error:&error]);
    [renderer.latestPresentationTexture getBytes:roundtrip.data() bytesPerRow:640*4
        fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    assert(roundtrip == baseline && renderer.renderedFrameCount == 1);
    assert(renderer.aspectPreviewRedrawCount == 2 && renderer.resolutionPreviewRedrawCount == 2);
    // The iPhone shell can use its exact landscape aspect without changing
    // default/macOS 16:9 or Original. Unknown HUD still stays centred.
    assert(![original configureNativePresentationSize:CGSizeMake(844,390)
        hudFrame:CGRectMake(60,8,208,96) error:&error] && error.code == 38);
    error = nil;
    assert([renderer configureNativePresentationSize:CGSizeMake(844,390)
        hudFrame:CGRectMake(60,8,208,96) error:&error]);
    assert(renderer.presentationAspect == 4.0/3.0);
    assert([renderer selectWidescreen:YES error:&error]);
    assert(std::abs(renderer.presentationAspect - 844.0/390.0) < 0.00001);
    assert([renderer.stateCapture[@"native_hud_draws"] unsignedIntValue] == 0);
    assert([renderer.stateCapture[@"presentation_aspect"] isEqual:@"native-landscape"]);
    assert(renderer.renderedFrameCount == 1);
    assert([renderer configureNativePresentationSize:CGSizeMake(1024,768)
        hudFrame:CGRectMake(12,32,208,96) error:&error]);
    assert(renderer.nativeViewportRedrawCount == 1 && renderer.renderedFrameCount == 1);
    assert(renderer.presentationAspect == 4.0/3.0);
    assert(![renderer configureNativePresentationSize:CGSizeMake(390,844)
        hudFrame:CGRectMake(12,8,208,96) error:&error] && error.code == 38);
    assert(renderer.nativePresentationSize.width == 1024);
    error = nil;
    assert([renderer selectWidescreen:NO error:&error]);
    [renderer.latestPresentationTexture getBytes:roundtrip.data() bytesPerRow:640*4
        fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    assert(roundtrip == baseline && renderer.renderedFrameCount == 1);
    // A failed redraw rolls the selected aspect back and preserves the image.
    assert([NSFileManager.defaultManager createDirectoryAtURL:output withIntermediateDirectories:YES
        attributes:nil error:&error]);
    renderer.sceneEdgeAuditEnabled = YES;
    auto sceneEvidence = draws;
    sceneEvidence[0].hasBackdropSourcePositionKey = true;
    sceneEvidence[0].backdropSourcePositionKey.fill(0x12);
    assert([renderer captureSceneEdges:sceneEvidence copies:copies frame:77 directory:output error:&error]);
    assert(!renderer.sceneEdgeRedraw && !renderer.widescreenEnabled && renderer.renderScale == 1);
    assert(renderer.nativePresentationSize.width == 1024 && renderer.renderedFrameCount == 1);
    [renderer.latestPresentationTexture getBytes:roundtrip.data() bytesPerRow:640*4
        fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    assert(roundtrip == baseline);
    NSDictionary* inspection = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:
        [output URLByAppendingPathComponent:@"scene-edges.json"]] options:0 error:&error];
    assert(inspection && !error && [inspection[@"source_vertices_immutable"] boolValue]);
    assert([inspection[@"samples"] count] == 5 && [inspection[@"identities"] count] == draws.size());
    NSDictionary* sourceEvidence = inspection[@"identities"][0];
    assert([sourceEvidence[@"source_position_sequence_sha256"] isEqualToString:
        @"1212121212121212121212121212121212121212121212121212121212121212"]);
    assert([sourceEvidence[@"decoded_vertices"] count] == draws[0].vertices.size());
    assert([sourceEvidence[@"decoded_vertices"][0][@"clip"] count] == 4);
    assert([sourceEvidence[@"decoded_vertices"][0][@"uv"] count] == 2);
    assert([sourceEvidence[@"decoded_vertices"][0][@"color"] count] == 4);
    assert([sourceEvidence[@"projection_words"] count] == 7);
    assert(!inspection[@"identities"][1][@"source_position_sequence_sha256"]);
    renderer.sceneEdgeAuditEnabled = NO;
    // Synthetic flag tests upload behavior, not real source-asset admission.
    assert([renderer configureNativePresentationSize:CGSizeMake(844,390)
        hudFrame:CGRectMake(60,8,208,96) error:&error]);
    renderer.widescreenEnabled = YES;
    LiveDraw finiteSky = rectangle(-1.05,1.05,-1,1,20,40,80,false);
    std::vector<LiveDraw> finiteDraws{finiteSky,center,newlyVisible,hud};
    assert([renderer renderDraws:finiteDraws efbCopies:copies frame:78 error:&error]);
    const auto blankCorner = pixel(10,10), unchangedCenter = pixel(320,224);
    assert(blankCorner[0] == 0 && blankCorner[1] == 0 && blankCorner[2] == 0);
    finiteDraws[0].finiteBackdropIdentity = 1;
    const auto originalVertices = finiteDraws[0].vertices;
    assert([renderer renderDraws:finiteDraws efbCopies:copies frame:78 error:&error]);
    assert((pixel(10,10) == std::array<u8,4>{40,20,10,255}));
    assert(pixel(320,224) == unchangedCenter);
    assert([renderer.stateCapture[@"finite_backdrop_draws"] unsignedIntValue] == 1);
    assert(!memcmp(originalVertices.data(), finiteDraws[0].vertices.data(), originalVertices.size()*sizeof(LiveVertex)));
    // A finite sky must also continue below its original lower boundary. This
    // tests exact edge attributes, expanded/indexed inputs, winding, depth and
    // no extension for inadmissible or already-covered geometry.
    finiteDraws[0] = rectangle(-1.05,1.05,0.5,1,20,40,80,false);
    finiteDraws[0].finiteBackdropIdentity = 1;
    finiteDraws[0].finiteBackdropLowerEdgeMask = (1u<<0)|(1u<<1)|(1u<<4);
    std::array<LiveVertex,6> extension{};
    assert(FiniteBackdropExtension(finiteDraws[0], &extension));
    assert(extension[1].position[1] == -1 && extension[2].position[1] == -1);
    assert(extension[1].position[2] == finiteDraws[0].vertices[0].position[2]);
    assert(!memcmp(extension[1].color,finiteDraws[0].vertices[0].color,sizeof(extension[1].color)));
    auto edgeReject = finiteDraws[0]; edgeReject.finiteBackdropIdentity = 0;
    assert(!FiniteBackdropExtension(edgeReject, &extension));
    edgeReject = finiteDraws[0]; edgeReject.finiteBackdropLowerEdgeMask = 1;
    assert(!FiniteBackdropExtension(edgeReject, &extension));
    edgeReject = finiteDraws[0]; edgeReject.vertices[0].position[3] = 0;
    assert(!FiniteBackdropExtension(edgeReject, &extension));
    edgeReject = finiteDraws[0]; edgeReject.vertices[0].position[0] = INFINITY;
    assert(!FiniteBackdropExtension(edgeReject, &extension));
    edgeReject = finiteDraws[0];
    for (auto& v : edgeReject.vertices) v.position[1] = -1;
    assert(!FiniteBackdropExtension(edgeReject, &extension));
    auto indexedEdge = finiteDraws[0]; indexedEdge.indexed = true;
    indexedEdge.vertices = {finiteDraws[0].vertices[0],finiteDraws[0].vertices[1],finiteDraws[0].vertices[2]};
    indexedEdge.indices = {0,1,2}; indexedEdge.finiteBackdropLowerEdgeMask = 3;
    assert(FiniteBackdropExtension(indexedEdge, &extension));
    indexedEdge.indices = {2,1,0};
    assert(FiniteBackdropExtension(indexedEdge, &extension));
    indexedEdge.indices = {6,1,0};
    assert(!FiniteBackdropExtension(indexedEdge, &extension));
    const auto shortSky = finiteDraws[0].vertices;
    assert([renderer renderDraws:finiteDraws efbCopies:copies frame:78 error:&error]);
    assert((pixel(10,200) == std::array<u8,4>{40,20,10,255}));
    assert(pixel(320,224) == unchangedCenter);
    assert([renderer.stateCapture[@"finite_backdrop_extensions"] unsignedIntValue] == 1);
    assert(!memcmp(shortSky.data(),finiteDraws[0].vertices.data(),shortSky.size()*sizeof(LiveVertex)));
    NSURL* backdropOutput = [output URLByAppendingPathComponent:@"finite-backdrop"];
    assert([NSFileManager.defaultManager createDirectoryAtURL:backdropOutput withIntermediateDirectories:YES
        attributes:nil error:&error]);
    renderer.sceneEdgeAuditEnabled = YES;
    assert([renderer captureSceneEdges:finiteDraws copies:copies frame:78 directory:backdropOutput error:&error]);
    NSDictionary* backdropInspection = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:
        [backdropOutput URLByAppendingPathComponent:@"scene-edges.json"]] options:0 error:&error];
    assert([backdropInspection[@"samples"] count] == 6);
    assert([backdropInspection[@"identities"][0][@"finite_backdrop_identity"] unsignedIntValue] == 1);
    assert([backdropInspection[@"samples"][5][@"state"][@"finite_backdrop_draws"] unsignedIntValue] == 0);
    assert([backdropInspection[@"samples"][5][@"state"][@"finite_backdrop_extensions"] unsignedIntValue] == 0);
    assert([backdropInspection[@"source_vertices_immutable"] boolValue]);
    renderer.sceneEdgeAuditEnabled = NO;
    renderer.widescreenEnabled = NO;
    // Continuation is extra host geometry only, disabled at 4:3 or with an
    // incomplete/invalid four-source cohort; frozen ablation retains the sky.
    std::vector<LiveDraw> forest{finiteDraws[0]};
    for (u8 identity = 1; identity <= 4; ++identity) {
        auto tree = rectangle(-1,1,-1,1,30,80,20,false);
        tree.repeatingBackdropIdentity = identity;
        tree.vertices = SyntheticRepeatingBackdrop(identity).vertices;
        forest.push_back(tree);
    }
    forest.push_back(center);
    auto forestCopies = copies; forestCopies[0].drawIndex = forest.size();
    assert([renderer renderDraws:forest efbCopies:forestCopies frame:79 error:&error]);
    assert([renderer.stateCapture[@"repeating_backdrop_extensions"] unsignedIntValue] == 0);
    renderer.widescreenEnabled = YES;
    const auto forestDigest = MotionVertexDigest(forest);
    assert([renderer renderDraws:forest efbCopies:forestCopies frame:79 error:&error]);
    assert([renderer.stateCapture[@"repeating_backdrop_extensions"] unsignedIntValue] == 2);
    assert((pixel(620,80) == std::array<u8,4>{10,40,15,255}));
    assert((pixel(620,190) == std::array<u8,4>{10,40,15,255}));
    assert(pixel(320,224) == unchangedCenter);
    assert([forestDigest isEqual:MotionVertexDigest(forest)]);
    auto incompleteForest = forest; incompleteForest[4].repeatingBackdropIdentity = 0;
    assert([renderer renderDraws:incompleteForest efbCopies:forestCopies frame:79 error:&error]);
    assert([renderer.stateCapture[@"repeating_backdrop_extensions"] unsignedIntValue] == 0);
    assert((pixel(620,80) == std::array<u8,4>{40,20,10,255}));
    auto invalidForest = forest; invalidForest[1].vertices[0].position[3] = 0;
    assert([renderer renderDraws:invalidForest efbCopies:forestCopies frame:79 error:&error]);
    assert([renderer.stateCapture[@"repeating_backdrop_extensions"] unsignedIntValue] == 0);
    renderer.nativePresentationSize = CGSizeMake(1024,768);
    assert([renderer renderDraws:forest efbCopies:forestCopies frame:79 error:&error]);
    assert([renderer.stateCapture[@"repeating_backdrop_extensions"] unsignedIntValue] == 0);
    renderer.nativePresentationSize = CGSizeMake(844,390);
    NSURL* repeatingOutput = [output URLByAppendingPathComponent:@"repeating-backdrop"];
    assert([NSFileManager.defaultManager createDirectoryAtURL:repeatingOutput withIntermediateDirectories:YES
        attributes:nil error:&error]);
    renderer.sceneEdgeAuditEnabled = YES;
    assert([renderer captureSceneEdges:forest copies:forestCopies frame:79 directory:repeatingOutput error:&error]);
    NSDictionary* repeatingInspection = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:
        [repeatingOutput URLByAppendingPathComponent:@"scene-edges.json"]] options:0 error:&error];
    assert([repeatingInspection[@"samples"] count] == 7);
    assert([repeatingInspection[@"samples"][6][@"state"][@"repeating_backdrop_extensions"] unsignedIntValue] == 0);
    assert([repeatingInspection[@"samples"][6][@"state"][@"finite_backdrop_extensions"] unsignedIntValue] == 1);
    assert([repeatingInspection[@"source_vertices_immutable"] boolValue]);
    renderer.sceneEdgeAuditEnabled = NO;
    // Source-bound hill additions remain independent of the sky and forest;
    // their ablation removes only the two hill strips, not either prior fix.
    auto hills=forest;
    for (u8 identity : {1,2}) {
        auto hill=rectangle(-1,1,-1,1,140,160,100,false);
        const auto fixture=SyntheticHillBackdrop(identity);
        hill.hillBackdropIdentity=identity;
        hill.sourceVertexCount=fixture.sourceVertexCount;
        hill.vertices=fixture.vertices; hill.indices=fixture.indices; hill.indexed=true;
        hills.insert(hills.end()-1,hill);
    }
    auto hillCopies=copies; hillCopies[0].drawIndex=hills.size();
    const auto hillDigest=MotionVertexDigest(hills);
    assert([renderer renderDraws:hills efbCopies:hillCopies frame:80 error:&error]);
    assert([renderer.stateCapture[@"hill_backdrop_extensions"] unsignedIntValue]==2);
    assert([renderer.stateCapture[@"repeating_backdrop_extensions"] unsignedIntValue]==2);
    assert((pixel(10,100)==std::array<u8,4>{50,80,70,255}));
    assert(pixel(320,224)==unchangedCenter);
    assert([hillDigest isEqual:MotionVertexDigest(hills)]);
    auto badHills=hills; badHills[5].hillBackdropIdentity=0;
    assert([renderer renderDraws:badHills efbCopies:hillCopies frame:80 error:&error]);
    assert([renderer.stateCapture[@"hill_backdrop_extensions"] unsignedIntValue]==0);
    assert((pixel(10,100)==std::array<u8,4>{10,40,15,255}));
    badHills=hills; badHills[5].vertices[0].position[3]=0;
    assert([renderer renderDraws:badHills efbCopies:hillCopies frame:80 error:&error]);
    assert([renderer.stateCapture[@"hill_backdrop_extensions"] unsignedIntValue]==0);
    renderer.nativePresentationSize=CGSizeMake(1024,768);
    assert([renderer renderDraws:hills efbCopies:hillCopies frame:80 error:&error]);
    assert([renderer.stateCapture[@"hill_backdrop_extensions"] unsignedIntValue]==0);
    renderer.nativePresentationSize=CGSizeMake(844,390);
    renderer.widescreenEnabled=NO;
    assert([renderer renderDraws:hills efbCopies:hillCopies frame:80 error:&error]);
    assert([renderer.stateCapture[@"hill_backdrop_extensions"] unsignedIntValue]==0);
    renderer.widescreenEnabled=YES;
    NSURL* hillOutput=[output URLByAppendingPathComponent:@"hill-backdrop"];
    assert([NSFileManager.defaultManager createDirectoryAtURL:hillOutput withIntermediateDirectories:YES attributes:nil error:&error]);
    renderer.sceneEdgeAuditEnabled=YES;
    assert([renderer captureSceneEdges:hills copies:hillCopies frame:80 directory:hillOutput error:&error]);
    NSDictionary* hillInspection=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:
        [hillOutput URLByAppendingPathComponent:@"scene-edges.json"]] options:0 error:&error];
    assert([hillInspection[@"samples"] count]==8);
    assert([hillInspection[@"samples"][7][@"image"] isEqual:@"scene-hill-backdrop-baseline.png"]);
    assert([hillInspection[@"samples"][7][@"state"][@"hill_backdrop_extensions"] unsignedIntValue]==0);
    assert([hillInspection[@"samples"][7][@"state"][@"repeating_backdrop_extensions"] unsignedIntValue]==2);
    assert([hillInspection[@"samples"][7][@"state"][@"finite_backdrop_extensions"] unsignedIntValue]==1);
    assert([hillInspection[@"source_vertices_immutable"] boolValue]);
    renderer.sceneEdgeAuditEnabled=NO;
    // Canyon's two-triangle source pair gets one side strip. It never changes
    // source pixels at 4:3, the foreground, source vertices or other backdrops.
    std::vector<LiveDraw> canyon;
    for (u8 identity : {1,2}) {
        auto sky = rectangle(-1,1,-1,1,20,100,200,false);
        sky.canyonSkyIdentity = identity;
        sky.vertices = SyntheticCanyonSky(identity).vertices;
        canyon.push_back(sky);
    }
    canyon.push_back(center); canyon.push_back(hud);
    const auto canyonDigest = MotionVertexDigest(canyon);
    auto disabledCanyon = canyon;
    for (auto& draw : disabledCanyon) draw.canyonSkyIdentity = 0;
    renderer.nativePresentationSize = CGSizeMake(874,402);
    assert([renderer renderDraws:disabledCanyon efbCopies:copies frame:81 error:&error]);
    assert((pixel(620,70) == std::array<u8,4>{0,0,0,255}));
    assert([renderer renderDraws:canyon efbCopies:copies frame:81 error:&error]);
    assert([renderer.stateCapture[@"canyon_sky_cohort"] boolValue]);
    assert([renderer.stateCapture[@"canyon_sky_extensions"] unsignedIntValue] == 1);
    assert((pixel(620,70) == std::array<u8,4>{100,50,10,255}));
    assert(pixel(320,224) == unchangedCenter);
    assert([canyonDigest isEqual:MotionVertexDigest(canyon)]);
    auto brokenCanyon = canyon; brokenCanyon[1].vertices[0].position[0] += .01;
    assert([renderer renderDraws:brokenCanyon efbCopies:copies frame:81 error:&error]);
    assert([renderer.stateCapture[@"canyon_sky_extensions"] unsignedIntValue] == 0);
    assert((pixel(620,70) == std::array<u8,4>{0,0,0,255}));
    for (CGSize viewport : {CGSizeMake(1024,768), CGSizeMake(1280,400)}) {
        renderer.nativePresentationSize = viewport;
        assert([renderer renderDraws:canyon efbCopies:copies frame:81 error:&error]);
        assert([renderer.stateCapture[@"canyon_sky_extensions"] unsignedIntValue] == 0);
        [renderer.latestPresentationTexture getBytes:baseline.data() bytesPerRow:640*4
            fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
        assert([renderer renderDraws:disabledCanyon efbCopies:copies frame:81 error:&error]);
        [renderer.latestPresentationTexture getBytes:roundtrip.data() bytesPerRow:640*4
            fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
        assert(roundtrip == baseline);
    }
    renderer.nativePresentationSize = CGSizeMake(874,402);
    NSURL* canyonOutput = [output URLByAppendingPathComponent:@"canyon-sky"];
    assert([NSFileManager.defaultManager createDirectoryAtURL:canyonOutput withIntermediateDirectories:YES attributes:nil error:&error]);
    renderer.sceneEdgeAuditEnabled = YES;
    assert([renderer captureSceneEdges:canyon copies:copies frame:81 directory:canyonOutput error:&error]);
    NSDictionary* canyonInspection = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:
        [canyonOutput URLByAppendingPathComponent:@"scene-edges.json"]] options:0 error:&error];
    assert([canyonInspection[@"samples"] count] == 6);
    assert([canyonInspection[@"samples"][0][@"state"][@"canyon_sky_extensions"] unsignedIntValue] == 1);
    assert([canyonInspection[@"samples"][5][@"image"] isEqual:@"scene-canyon-sky-baseline.png"]);
    assert([canyonInspection[@"samples"][5][@"state"][@"canyon_sky_extensions"] unsignedIntValue] == 0);
    assert([canyonInspection[@"source_vertices_immutable"] boolValue]);
    renderer.sceneEdgeAuditEnabled = NO;
    std::vector<LiveDraw> city;
    for (u8 identity : {1,2}) {
        auto sky = rectangle(-1,1,-1,1,20,100,200,false);
        const auto source = SyntheticCitySky(identity);
        sky.citySkyIdentity = identity; sky.sourceVertexCount = source.sourceVertexCount;
        sky.vertices = source.vertices; sky.indices = source.indices; sky.indexed = true;
        city.push_back(sky);
    }
    city.push_back(center); city.push_back(hud);
    const auto cityDigest = MotionVertexDigest(city);
    auto disabledCity = city;
    for (auto& draw : disabledCity) draw.citySkyIdentity = 0;
    for (CGSize viewport : {CGSizeMake(874,402), CGSizeMake(1600,900), CGSizeMake(1200,400)}) {
        renderer.nativePresentationSize = viewport;
        assert([renderer renderDraws:disabledCity efbCopies:copies frame:82 error:&error]);
        // At 16:9 the synthetic edge is x=3.36; use a pixel outside it at
        // every aspect in the matrix, not x=10 which is already source sky.
        assert((pixel(1,70) == std::array<u8,4>{0,0,0,255}));
        assert([renderer renderDraws:city efbCopies:copies frame:82 error:&error]);
        assert([renderer.stateCapture[@"city_sky_cohort"] boolValue]);
        assert([renderer.stateCapture[@"city_sky_extensions"] unsignedIntValue] == 3);
        assert((pixel(1,70) == std::array<u8,4>{100,50,10,255}));
        assert(pixel(320,224) == unchangedCenter);
        assert([cityDigest isEqual:MotionVertexDigest(city)]);
        [renderer.latestPresentationTexture getBytes:baseline.data() bytesPerRow:640*4
            fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
        auto flat = city; flat[0] = ExpandedCitySky(flat[0]); flat[1] = ExpandedCitySky(flat[1]);
        assert([renderer renderDraws:flat efbCopies:copies frame:82 error:&error]);
        [renderer.latestPresentationTexture getBytes:roundtrip.data() bytesPerRow:640*4
            fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
        assert(roundtrip == baseline);
    }
    for (CGSize viewport : {CGSizeMake(1024,768), CGSizeMake(1280,400)}) {
        renderer.nativePresentationSize = viewport;
        assert([renderer renderDraws:city efbCopies:copies frame:82 error:&error]);
        assert([renderer.stateCapture[@"city_sky_extensions"] unsignedIntValue] == 0);
        [renderer.latestPresentationTexture getBytes:baseline.data() bytesPerRow:640*4
            fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
        assert([renderer renderDraws:disabledCity efbCopies:copies frame:82 error:&error]);
        [renderer.latestPresentationTexture getBytes:roundtrip.data() bytesPerRow:640*4
            fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
        assert(roundtrip == baseline);
    }
    NSURL* cityOutput = [output URLByAppendingPathComponent:@"city-sky"];
    assert([NSFileManager.defaultManager createDirectoryAtURL:cityOutput withIntermediateDirectories:YES attributes:nil error:&error]);
    renderer.sceneEdgeAuditEnabled = YES;
    assert([renderer captureSceneEdges:city copies:copies frame:82 directory:cityOutput error:&error]);
    NSDictionary* cityInspection = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:
        [cityOutput URLByAppendingPathComponent:@"scene-edges.json"]] options:0 error:&error];
    assert([cityInspection[@"samples"] count] == 6);
    assert([cityInspection[@"samples"][0][@"state"][@"city_sky_extensions"] unsignedIntValue] == 3);
    assert([cityInspection[@"samples"][5][@"image"] isEqual:@"scene-city-sky-baseline.png"]);
    assert([cityInspection[@"samples"][5][@"state"][@"city_sky_extensions"] unsignedIntValue] == 0);
    assert([cityInspection[@"source_vertices_immutable"] boolValue]);
    renderer.sceneEdgeAuditEnabled = NO;
    for (u8 first : {1,3}) {
        std::vector<LiveDraw> related;
        for (u8 identity : {first, (u8)(first+1)}) {
            auto sky = rectangle(-1,1,-1,1,20,100,200,false);
            const auto source = SyntheticRelatedCitySky(identity);
            sky.relatedCitySkyIdentity = identity; sky.sourceVertexCount = source.sourceVertexCount;
            sky.vertices = source.vertices; sky.indices = source.indices; sky.indexed = true;
            related.push_back(sky);
        }
        related.push_back(center); related.push_back(hud);
        const auto digest = MotionVertexDigest(related);
        auto disabled = related;
        for (auto& draw : disabled) draw.relatedCitySkyIdentity = 0;
        for (CGSize viewport : {CGSizeMake(874,402), CGSizeMake(1600,900), CGSizeMake(1200,400)}) {
            renderer.nativePresentationSize = viewport;
            assert([renderer renderDraws:disabled efbCopies:copies frame:83 error:&error]);
            assert((pixel(1,70) == std::array<u8,4>{0,0,0,255}));
            assert([renderer renderDraws:related efbCopies:copies frame:83 error:&error]);
            assert([renderer.stateCapture[@"related_city_sky_cohort"] unsignedIntValue] == (first == 1 ? 1 : 2));
            assert([renderer.stateCapture[@"related_city_sky_extensions"] unsignedIntValue] == (first == 1 ? 4 : 2));
            assert((pixel(1,70) == std::array<u8,4>{100,50,10,255}));
            assert(pixel(320,224) == unchangedCenter);
            assert([digest isEqual:MotionVertexDigest(related)]);
            [renderer.latestPresentationTexture getBytes:baseline.data() bytesPerRow:640*4
                fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
            auto flat = related; flat[0] = ExpandedCitySky(flat[0]); flat[1] = ExpandedCitySky(flat[1]);
            assert([renderer renderDraws:flat efbCopies:copies frame:83 error:&error]);
            [renderer.latestPresentationTexture getBytes:roundtrip.data() bytesPerRow:640*4
                fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
            assert(roundtrip == baseline);
        }
        auto broken = related; broken[1].vertices[1].position[0] += .01f;
        assert([renderer renderDraws:broken efbCopies:copies frame:83 error:&error]);
        assert([renderer.stateCapture[@"related_city_sky_extensions"] unsignedIntValue] == 0);
        assert((pixel(1,70) == std::array<u8,4>{0,0,0,255}));
        for (CGSize viewport : {CGSizeMake(1024,768), CGSizeMake(1280,400)}) {
            renderer.nativePresentationSize = viewport;
            assert([renderer renderDraws:related efbCopies:copies frame:83 error:&error]);
            assert([renderer.stateCapture[@"related_city_sky_extensions"] unsignedIntValue] == 0);
            [renderer.latestPresentationTexture getBytes:baseline.data() bytesPerRow:640*4
                fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
            assert([renderer renderDraws:disabled efbCopies:copies frame:83 error:&error]);
            [renderer.latestPresentationTexture getBytes:roundtrip.data() bytesPerRow:640*4
                fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
            assert(roundtrip == baseline);
        }
        renderer.nativePresentationSize = CGSizeMake(874,402);
        NSURL* relatedOutput = [output URLByAppendingPathComponent:first == 1 ? @"lakeside-sky" : @"crane-sky"];
        assert([NSFileManager.defaultManager createDirectoryAtURL:relatedOutput withIntermediateDirectories:YES attributes:nil error:&error]);
        renderer.sceneEdgeAuditEnabled = YES;
        assert([renderer captureSceneEdges:related copies:copies frame:83 directory:relatedOutput error:&error]);
        NSDictionary* inspection = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:
            [relatedOutput URLByAppendingPathComponent:@"scene-edges.json"]] options:0 error:&error];
        assert([inspection[@"samples"] count] == 6);
        assert([inspection[@"samples"][0][@"state"][@"related_city_sky_extensions"] unsignedIntValue] == (first == 1 ? 4 : 2));
        assert([inspection[@"samples"][5][@"image"] isEqual:@"scene-related-city-sky-baseline.png"]);
        assert([inspection[@"samples"][5][@"state"][@"related_city_sky_extensions"] unsignedIntValue] == 0);
        assert([inspection[@"source_vertices_immutable"] boolValue]);
        renderer.sceneEdgeAuditEnabled = NO;
    }
    renderer.widescreenEnabled = NO;
    preview->copies[0].width = 641;
    assert(![renderer selectWidescreen:YES error:&error] && error.code == 23);
    assert(!renderer.widescreenEnabled && renderer.aspectPreviewRedrawCount == 4);
}

static void TestWorldMapOceanAdmission() {
    std::vector<LiveDraw> draws(24);
    for (size_t i = 0; i < draws.size(); ++i) {
        auto& draw = draws[i];
        const bool masked = i == 6 || i == 7;
        draw.projectionWords = {994888909,2147483648,3146926373,0,3131299594,3212627148,1};
        draw.viewportHeight = 448; draw.depthMode = 15; draw.blendMode = 13501;
        draw.fragment.alphaTest = 4128768; draw.fragment.stageCount = masked ? 2 : 1;
        draw.indexed = true; draw.indices = {0,1,2,0,2,3};
        for (size_t stage = 0; stage < draw.fragment.stageCount; ++stage) {
            draw.textureWidths[stage] = draw.textureHeights[stage] = i < 20 ? 256 : 32;
            draw.textureFormats[stage] = 14; draw.textureUnits[stage] = (u32)stage;
            draw.textureModes[stage] = 2097360;
            draw.fragment.colorCombiners[stage] = stage ? 589808 : 64143;
            draw.fragment.alphaCombiners[stage] = stage ? 63100 : masked ? 65520 : 63088;
        }
        const float left = (float)(i < 20 ? i % 5 : 5) - 1;
        const float top = 3 - (float)(i < 20 ? i / 5 : i-20);
        const float corners[][2] = {{0,0},{1,0},{1,1},{0,1}};
        for (const auto& uv : corners) {
            LiveVertex v{};
            v.position[0] = left + uv[0]; v.position[1] = top - uv[1];
            v.position[2] = 0.00625; v.position[3] = 1;
            std::copy(uv, uv+2, v.uv[0]); std::fill(v.color, v.color+4, 1);
            draw.vertices.push_back(v);
        }
        NSString* key = @(i < 20 ? kWorldMapTiles[i] : kWorldMapOcean);
        NSString* mask = masked ? @(kWorldMapMask) : nil;
        assert(WorldMapKeyMatches(i, key, mask));
        assert(!WorldMapKeyMatches(i, @"unknown", mask));
        assert(!WorldMapKeyMatches(i, key, masked ? nil : @"extra-plane"));
    }
    assert(!WorldMapKeyMatches(24, @(kWorldMapOcean), nil));
    assert(WorldMapGeometryMatches(draws));
    LiveEfbCopy display;
    display.drawIndex = draws.size(); display.width = 640; display.height = 448;
    display.command = 18435; display.yScale = 256;
    assert(!IdentifyWorldMap(draws, {display})); // No source pixels: shape alone never admits.
    auto reject = [&](auto mutate) { auto changed = draws; mutate(changed); assert(!WorldMapGeometryMatches(changed)); };
    reject([](auto& d) { d.pop_back(); });
    reject([](auto& d) { d[0].projectionWords[6] = 0; });
    reject([](auto& d) { d[1].projectionWords[0]++; });
    reject([](auto& d) { d[0].viewportHeight = 480; });
    reject([](auto& d) { d[0].blendMode = 13373; });
    reject([](auto& d) { d[0].depthMode = 7; });
    reject([](auto& d) { d[0].fragment.indirectCount = 1; });
    reject([](auto& d) { d[0].textureModes[0] = 0; });
    reject([](auto& d) { d[6].fragment.stageCount = 1; });
    reject([](auto& d) { d[7].fragment.alphaCombiners[1] = 63088; });
    reject([](auto& d) { d[0].indices[2] = 3; });
    reject([](auto& d) { d[8].vertices[0].position[0] += 0.1; });
    reject([](auto& d) { for (auto& v : d[8].vertices) v.position[0] += 0.1; });
    reject([](auto& d) { for (auto& v : d[20].vertices) v.position[1] += 0.1; });
    reject([](auto& d) { d[4].vertices[1].uv[0][0] = 0.5; });
    reject([](auto& d) { d[0].vertices[0].color[0] = NAN; });
    reject([](auto& d) { d[0].vertices[0].color[0] = 0.5; });
    reject([](auto& d) { d[1].vertices[0].color[3] = 0.5; });
    reject([](auto& d) { d[1].vertices[0].position[2] = NAN; });
    reject([](auto& d) { d[1].vertices[0].position[3] = 2; });
    for (auto& d : draws) for (auto& v : d.vertices)
        for (size_t c = 0; c < 3; ++c) v.color[c] = 127.0f/255.0f;
    assert(WorldMapGeometryMatches(draws));
    for (auto& d : draws) {
        const auto corners = d.vertices;
        d.vertices.clear();
        for (u32 index : d.indices) d.vertices.push_back(corners[index]);
        d.indices.clear(); d.indexed = false;
    }
    assert(WorldMapGeometryMatches(draws));
    const auto ocean = WorldMapOceanColor(1);
    const auto dimmed = WorldMapOceanColor(127.0f/255.0f);
    assert(ocean.red == 167.0/255.0 && ocean.green == 223.0/255.0 && ocean.blue == 1 && ocean.alpha == 1);
    assert(std::abs(dimmed.red - ocean.red * 127.0/255.0) < 0.00001 && dimmed.alpha == 1);
    // Metal clear uses exactly the same normalized source colour, without a
    // palette conversion or different zoom tint on the added margin.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    id<MTLCommandBuffer> command = [[device newCommandQueue] commandBuffer];
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = ocean;
    [[command renderCommandEncoderWithDescriptor:pass] endEncoding];
    [command commit]; [command waitUntilCompleted];
    std::array<u8,4> pixel{};
    [texture getBytes:pixel.data() bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
    assert((pixel == std::array<u8,4>{255,223,167,255}));
}

static void TestNativeHudAdmissionAndTransform() {
    for (const auto& profile : kNativeHudTextures) {
        assert(NativeHudRoleForKeys(@(profile.primary), @(profile.auxiliary)) == profile.role);
        assert(NativeHudRoleForKeys(@(profile.primary), @"wrong-mask") == NativeHudRole::Unknown);
    }
    assert(NativeHudRoleForKeys(nil, nil) == NativeHudRole::Unknown);
    NSString* closedColour = @"128x128-c0be976ea3631efdd16a854c138b3baf98d27aad611fb4c62a5eaf8c70a2c67d";
    NSString* closedMask = @"128x128-f6a0510cd4b0b254817f0fae5da8592d0ccd5efd999cd3f2618ae8d8a01e04fe";
    assert(NativeHudRoleForKeys(closedColour, closedMask) == NativeHudRole::WatchRing);
    assert(NativeHudRoleForKeys(closedColour,
        @"128x128-b6a91e35fa0ae98a6b9d7e8a025d09d5f6282408a8aaa5bf6ea8ebe6bccb93fb") == NativeHudRole::Unknown);
    std::vector<NativeHudRole> closedRoles(17, NativeHudRole::Detail);
    closedRoles[0] = NativeHudRole::EnergyFrame;
    closedRoles[1] = NativeHudRole::HealthFrame;
    closedRoles[14] = NativeHudRoleForKeys(closedColour, closedMask);
    closedRoles[15] = NativeHudRole::WatchLights;
    assert(AdmitNativeHudRoles(closedRoles).count == 17);
    const std::vector<NativeHudRole> roles{NativeHudRole::Unknown, NativeHudRole::EnergyFrame,
        NativeHudRole::HealthFrame, NativeHudRole::Detail, NativeHudRole::Detail,
        NativeHudRole::WatchRing, NativeHudRole::WatchLights, NativeHudRole::Detail,
        NativeHudRole::Unknown, NativeHudRole::Detail};
    const auto admitted = AdmitNativeHudRoles(roles);
    assert(admitted.count == 7 && !admitted.draws[0] && !admitted.draws[8] && !admitted.draws[9]);
    auto incomplete = roles;
    incomplete[3] = NativeHudRole::Unknown;
    // An unidentified draw inside the span no longer drops the whole HUD to
    // 4:3; without geometry it is left untouched (foreign).
    const auto withForeign = AdmitNativeHudRoles(incomplete);
    assert(withForeign.count == 6 && !withForeign.draws[3] && withForeign.foreign == 1);
    incomplete = roles; incomplete[5] = NativeHudRole::Detail;
    assert(AdmitNativeHudRoles(incomplete).count == 0);
    incomplete = roles; incomplete[9] = NativeHudRole::WatchRing;
    assert(AdmitNativeHudRoles(incomplete).count == 0);
    LiveDraw source;
    source.viewportHeight = 448; source.projectionWords[6] = 1;
    source.indexed = true; source.indices = {0,1,2,0,2,3};
    source.vertices.resize(4);
    for (auto& vertex : source.vertices) {
        vertex.position[0] = -0.8; vertex.position[1] = 0.8; vertex.position[3] = 1;
    }
    source.depthMode = 15; source.blendMode = 13501;
    source.fragment.alphaTest = 4128768; source.fragment.stageCount = 1;
    source.fragment.colorCombiners[0] = 64143; source.fragment.alphaCombiners[0] = 63088;
    source.textureFormats[0] = 14;
    assert(NativeHudDrawStateMatches(source));
    // Exact rotating light quad retained from cycling-only rejection frame
    // 2908. It is not valid for arbitrary HUD details or a right-player HUD.
    auto cyclingLights = source;
    const float cyclingXY[4][2] = {{47,-24},{140,66},{82,173},{-11,82}};
    for(size_t i=0;i<4;++i) {
        cyclingLights.vertices[i].position[0]=cyclingXY[i][0]/320-1;
        cyclingLights.vertices[i].position[1]=1-cyclingXY[i][1]/224;
    }
    assert(!NativeHudDrawStateMatches(cyclingLights));
    assert(!NativeHudDrawStateMatches(cyclingLights,NativeHudRole::Detail));
    assert(NativeHudDrawStateMatches(cyclingLights,NativeHudRole::WatchLights));
    auto displacedLights=cyclingLights;
    displacedLights.vertices[2].position[1]=1-200.0f/224;
    assert(!NativeHudDrawStateMatches(displacedLights,NativeHudRole::WatchLights));
    displacedLights=cyclingLights;
    for(auto& vertex:displacedLights.vertices)vertex.position[0]+=1;
    assert(!NativeHudDrawStateMatches(displacedLights,NativeHudRole::WatchLights));
    auto glow=source;
    glow.blendMode=13373;
    const float glowXY[4][2]={{65,-42},{151,75},{64,190},{-22,74}};
    for(size_t i=0;i<4;++i) {
        glow.vertices[i].position[0]=glowXY[i][0]/320-1;
        glow.vertices[i].position[1]=1-glowXY[i][1]/224;
    }
    assert(NativeHudRoleForKeys(@"64x64-6c3d61c672d5f3716b0ba03fc5c89aa910826ee9d163a2bc1325fa6663a071d8",@"")==NativeHudRole::WatchGlow);
    assert(!NativeHudDrawStateMatches(glow,NativeHudRole::Detail));
    assert(!NativeHudDrawStateMatches(glow,NativeHudRole::WatchLights));
    assert(NativeHudDrawStateMatches(glow,NativeHudRole::WatchGlow));
    auto shiftedGlow=glow;
    for(auto& vertex:shiftedGlow.vertices)vertex.position[0]+=20.f/320;
    assert(!NativeHudDrawStateMatches(shiftedGlow,NativeHudRole::WatchGlow));
    auto tooLargeGlow=glow;
    tooLargeGlow.vertices[0].position[1]=1+87.f/224;
    assert(!NativeHudDrawStateMatches(tooLargeGlow,NativeHudRole::WatchGlow));
    auto wrongGlow=glow;wrongGlow.fragment.alphaCombiners[0]=0;
    assert(!NativeHudDrawStateMatches(wrongGlow,NativeHudRole::WatchGlow));
    auto glowingRoles=roles;glowingRoles[3]=glowingRoles[4]=NativeHudRole::WatchGlow;
    assert(AdmitNativeHudRoles(glowingRoles).count==7);
    glowingRoles[5]=NativeHudRole::WatchGlow; // Glow never supplies a missing ring anchor.
    assert(!AdmitNativeHudRoles(glowingRoles).count);
    // Captured translated 33_03 health frame: source x118..318, y64..85.
    // The old x310 guard dropped this recognized anchor, hence the whole HUD.
    auto longerHealth = source;
    const float healthXY[4][2] = {{118,64},{318,64},{318,85},{118,85}};
    for(size_t i=0;i<4;++i) {
        longerHealth.vertices[i].position[0] = healthXY[i][0]/320-1;
        longerHealth.vertices[i].position[1] = 1-healthXY[i][1]/224;
    }
    assert(NativeHudDrawStateMatches(longerHealth));
    auto acrossMidline = longerHealth;
    acrossMidline.vertices[1].position[0] = 321.0f/320-1;
    assert(!NativeHudDrawStateMatches(acrossMidline));
    auto wrong = source; wrong.vertices[0].position[0] = 0.9;
    assert(!NativeHudDrawStateMatches(wrong));
    wrong = source; wrong.fragment.alphaCombiners[0] = 0;
    assert(!NativeHudDrawStateMatches(wrong));
    wrong = source; wrong.depthMode = 0;
    assert(!NativeHudDrawStateMatches(wrong));
    wrong = source; wrong.viewportWidth = 256;
    assert(!NativeHudDrawStateMatches(wrong));
    wrong = source; wrong.vertices[0].position[0] = NAN;
    assert(!NativeHudDrawStateMatches(wrong));
    // A recognised draw state with unrecognised source pixels is not enough.
    assert(IdentifyNativeHud({source}).count == 0);
    LiveVertex original{};
    original.position[0] = 1.0f / 320 - 1;
    original.position[1] = 1 - 14.0f / 224;
    original.position[2] = .25; original.position[3] = 1;
    original.color[0] = .3; original.uv[0][0] = .37;
    auto transformed = original;
    TransformNativeHudVertex(&transformed, CGSizeMake(844,390), CGRectMake(60,8,207.75,96.428571));
    assert(std::abs(transformed.position[0] - (120.0/844 - 1)) < .000001);
    assert(std::abs(transformed.position[1] - (1 - 16.0/390)) < .000001);
    assert(transformed.position[2] == original.position[2] && transformed.position[3] == original.position[3]);
    assert(std::memcmp(transformed.color, original.color, sizeof(original.color)) == 0);
    assert(std::memcmp(transformed.uv, original.uv, sizeof(original.uv)) == 0);

    // Carry-over: with remembered anchor centres, two unmoved anchors keep the
    // HUD admitted for a bounded number of source frames; moved anchors, too
    // few anchors or an expired memory do not.
    std::vector<NativeHudQuadFacts> facts(roles.size());
    const double centres[10][2] = {{0,0},{198,92},{168,75},{50,50},{60,60},{65,74},{65,74},{70,70},{0,0},{80,80}};
    for (size_t i = 0; i < facts.size(); ++i) {
        facts[i].ok = true; facts[i].cx = centres[i][0]; facts[i].cy = centres[i][1];
        facts[i].minX = facts[i].cx - 8; facts[i].maxX = facts[i].cx + 8;
        facts[i].minY = facts[i].cy - 8; facts[i].maxY = facts[i].cy + 8;
    }
    std::vector<LiveDraw> plain(roles.size());
    const auto full = AdmitNativeHudRoles(roles, &facts, &plain);
    assert(full.count == 7 && !full.partial && full.anchorSeen[0] && full.anchorSeen[3]);
    NativeHudMemory memory; memory.valid = true; memory.frame = 100; memory.anchorCentre = full.anchorCentre;
    auto flashed = roles; flashed[1] = flashed[2] = NativeHudRole::Unknown; // both frame anchors unrecognisable
    const auto carried = AdmitNativeHudRoles(flashed, &facts, &plain, &memory, 130);
    assert(carried.count >= 5 && carried.partial && !strcmp(carried.reason, "carried-anchor-cluster"));
    assert(!AdmitNativeHudRoles(flashed, &facts, &plain, &memory, 146).count);   // memory expired
    assert(!AdmitNativeHudRoles(flashed, &facts, &plain, nullptr, 130).count);   // no memory
    auto movedFacts = facts; movedFacts[5].cx += 20;                              // ring moved: not the same HUD
    assert(!AdmitNativeHudRoles(flashed, &movedFacts, &plain, &memory, 130).count);
    auto lonely = flashed; lonely[6] = NativeHudRole::Unknown;                    // one anchor is not enough
    assert(!AdmitNativeHudRoles(lonely, &facts, &plain, &memory, 130).count);

    // Containment: an unidentified small quad inside the HUD region moves with
    // it; a full-frame quad in the span is left alone; neither rejects.
    auto withUnknown = roles; withUnknown[3] = NativeHudRole::Unknown; withUnknown[4] = NativeHudRole::Unknown;
    auto fullFrame = plain;
    {
        LiveDraw cover; cover.projectionWords[6] = 1; cover.viewportHeight = 448;
        for (const auto& xy : {std::array<float,2>{-1,-1}, std::array<float,2>{1,-1},
                               std::array<float,2>{1,1}, std::array<float,2>{-1,1}}) {
            LiveVertex vertex{}; vertex.position[0] = xy[0]; vertex.position[1] = xy[1]; vertex.position[3] = 1;
            cover.vertices.push_back(vertex);
        }
        fullFrame[4] = cover;
    }
    const auto contained = AdmitNativeHudRoles(withUnknown, &facts, &fullFrame);
    assert(contained.count == 6 && contained.draws[3] && !contained.draws[4]);
    assert(contained.contained == 1 && contained.foreign == 1);
    auto distant = facts; distant[3].minX = 400; distant[3].maxX = 420;            // outside the HUD region
    assert(!AdmitNativeHudRoles(withUnknown, &distant, &fullFrame).draws[3]);

    // Soft state: an identified anchor whose TEV/blend changed (a pickup flash)
    // is still that anchor; geometry outside the HUD region is not.
    auto flashedAnchor = source; flashedAnchor.blendMode = 12604; flashedAnchor.fragment.colorCombiners[0] = 0;
    assert(!NativeHudDrawStateMatches(flashedAnchor) && NativeHudQuad(flashedAnchor).ok);
    auto rightSide = source;
    for (auto& vertex : rightSide.vertices) vertex.position[0] = 0.8f;
    assert(NativeHudQuad(rightSide).ok && NativeHudQuad(rightSide).cx > 330);
}

static void TestGeometryBindAnchor() {
    CPUState cpu;
    assert(protector_cpu_init(&cpu));
    NSError* error = nil;
    DecoderState state;
    state.geometryPack = [[ProtectorGeometryPack alloc]
        initWithManifest:WriteGeometryFixture(GeometryFixture(true)) error:&error];
    assert(state.geometryPack && !error);
    const auto* profile = [state.geometryPack profileForPrimitive:
        GeometryFixtureCommand.data() length:GeometryFixtureCommand.size()];
    state.cp[0xB4] = 4;
    state.cp[0xA4] = 0x104;
    std::memcpy(cpu.ram + 0x100, GeometryFixtureAnchor.data(), GeometryFixtureAnchor.size());
    assert(GeometrySourceMatches(state, &cpu, profile));
    // Topology/UV sharing is insufficient: a changed bind byte must fall back
    // to the original draw without mutating guest memory or refusing the game.
    cpu.ram[0x100] ^= 1;
    assert(!GeometrySourceMatches(state, &cpu, profile));
    cpu.ram[0x100] ^= 1;
    state.cp[0xB4] = 8;
    assert(!GeometrySourceMatches(state, &cpu, profile));
    state.cp[0xB4] = 4;
    state.cp[0xA4] = 0;
    assert(!GeometrySourceMatches(state, &cpu, profile)); // No unsigned prefix underflow.
    state.cp[0xA4] = (u32)cpu.ram_size - 2;
    assert(!GeometrySourceMatches(state, &cpu, profile)); // Truncated UV buffer.
    state.cp[0xA4] = kMem2PhysicalBase + 4;
    std::memcpy(cpu.mem2, GeometryFixtureAnchor.data(), GeometryFixtureAnchor.size());
    assert(GeometrySourceMatches(state, &cpu, profile));
    cpu.mem2[4] ^= 1;
    assert(!GeometrySourceMatches(state, &cpu, profile));
    assert(!GeometrySourceMatches(state, &cpu, nullptr));
    protector_cpu_destroy(&cpu);
}

static void TestRigidGeometrySourceArrays() {
    CPUState cpu;
    assert(protector_cpu_init(&cpu));
    for (bool color : {false, true}) {
        NSError* error = nil;
        DecoderState state;
        state.geometryPack = [[ProtectorGeometryPack alloc]
            initWithManifest:WriteGeometryFixture(RigidGeometryFixture(color)) error:&error];
        assert(state.geometryPack && !error);
        const auto* profile = [state.geometryPack profileForPrimitive:
            GeometryFixtureCommand.data() length:GeometryFixtureCommand.size()];
        const u32 middle = color ? 2 : 1;
        const auto bytes = RigidGeometryFixtureAnchor(color);
        for (u32 base : {0x100u, kMem2PhysicalBase + 0x100u}) {
            u8* memory = base < kMem2PhysicalBase ? cpu.ram + base : cpu.mem2 + base - kMem2PhysicalBase;
            std::memcpy(memory, bytes.data(), bytes.size());
            state.cp[0xA0] = base; state.cp[0xA0 + middle] = base + 36; state.cp[0xA4] = base + 48;
            state.cp[0xB0] = 12; state.cp[0xB0 + middle] = color ? 4 : 3; state.cp[0xB4] = 4;
            state.cp[0x50] = (2u << 9u) | (2u << (color ? 13u : 11u)); state.cp[0x60] = 2;
            state.cp[0x76] = 9u | (7u << 21u) | (color ? 11u << 13u : 2u << 9u);
            assert(GeometrySourceMatches(state, &cpu, profile));
            for (u32 reg : {0xA0u, 0xA0u + middle, 0xA4u, 0xB0u, 0xB0u + middle, 0xB4u}) {
                const u32 original = state.cp[reg];
                state.cp[reg] += 4;
                assert(!GeometrySourceMatches(state, &cpu, profile));
                state.cp[reg] = original;
            }
            // Reject every changed active/extra descriptor bit, but do not pin
            // source-owned object matrices, lighting, texture scaling or pose.
            for (u32 bit = 0; bit < 17; ++bit) {
                state.cp[0x50] ^= 1u << bit;
                assert(!GeometrySourceMatches(state, &cpu, profile));
                state.cp[0x50] ^= 1u << bit;
            }
            for (u32 bit = 0; bit < 16; ++bit) {
                state.cp[0x60] ^= 1u << bit;
                assert(!GeometrySourceMatches(state, &cpu, profile));
                state.cp[0x60] ^= 1u << bit;
            }
            for (u32 bit : {0u, 1u, 2u, 3u, 21u, 22u, 23u, 24u,
                           color ? 13u : 9u, color ? 14u : 10u, color ? 15u : 11u, color ? 16u : 12u}) {
                state.cp[0x76] ^= 1u << bit;
                assert(!GeometrySourceMatches(state, &cpu, profile));
                state.cp[0x76] ^= 1u << bit;
            }
            if (!color) {
                state.cp[0x76] |= 1u << 31u; assert(!GeometrySourceMatches(state, &cpu, profile));
                state.cp[0x76] &= ~(1u << 31u);
            }
            for (u32 offset : {0u, 35u, 36u, 44u, 48u, 51u}) {
                memory[offset] ^= 1; assert(!GeometrySourceMatches(state, &cpu, profile)); memory[offset] ^= 1;
            }
            assert(!std::memcmp(memory, bytes.data(), bytes.size()));
            assert(GeometrySourceMatches(state, &cpu, profile));
        }
        state.cp[0xA4] = 4;
        assert(!GeometrySourceMatches(state, &cpu, profile));
    }
    protector_cpu_destroy(&cpu);
}

static void TestRigidTopologyVariantSelection() {
    CPUState cpu;
    assert(protector_cpu_init(&cpu));
    for (bool color : {false,true}) for (bool reverse : {false,true}) {
        NSError* error = nil;
        DecoderState state;
        state.geometryPack = [[ProtectorGeometryPack alloc]
            initWithManifest:WriteGeometryFixture(RigidGeometryVariantsFixture(color,reverse)) error:&error];
        assert(state.geometryPack && !error);
        const u32 middle = color ? 2 : 1;
        for (u32 base : {0x100u,kMem2PhysicalBase+0x100u}) {
            u8* memory = base < kMem2PhysicalBase ? cpu.ram+base : cpu.mem2+base-kMem2PhysicalBase;
            state.cp[0xA0] = base; state.cp[0xA0+middle] = base+36; state.cp[0xA4] = base+48;
            state.cp[0xB0] = 12; state.cp[0xB0+middle] = color ? 4 : 3; state.cp[0xB4] = 4;
            state.cp[0x50] = (2u<<9u) | (2u<<(color ? 13u : 11u)); state.cp[0x60] = 2;
            state.cp[0x76] = 9u | (7u<<21u) | (color ? 11u<<13u : 2u<<9u);
            for (bool right : {false,true}) {
                auto bytes = RigidGeometryFixtureAnchor(color);
                if (right) bytes[0] ^= 0x40;
                memcpy(memory,bytes.data(),bytes.size());
                const auto* profile = GeometryProfileForDraw(state,&cpu,GeometryFixtureCommand.data(),GeometryFixtureCommand.size(),3);
                assert(profile && profile->identity == (right ? "rigid-right" : "rigid-left"));
                assert(!memcmp(memory,bytes.data(),bytes.size()));
                assert(!GeometryProfileForDraw(state,&cpu,GeometryFixtureCommand.data(),GeometryFixtureCommand.size(),4));
                memory[1] ^= 1;
                assert(!GeometryProfileForDraw(state,&cpu,GeometryFixtureCommand.data(),GeometryFixtureCommand.size(),3));
                memory[1] ^= 1;
                state.cp[0xA0] += 4;
                assert(!GeometryProfileForDraw(state,&cpu,GeometryFixtureCommand.data(),GeometryFixtureCommand.size(),3));
                state.cp[0xA0] -= 4;
                assert(!memcmp(memory,bytes.data(),bytes.size()));
            }
        }
    }
    protector_cpu_destroy(&cpu);
}

static void TestGeometryPreview() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSURL* output = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"protector-geometry-preview-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    NSURL* manifest = WriteGeometryFixture(GeometryFixture());
    NSError* error = nil;
    ProtectorLiveMetalRenderer* original = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output error:&error];
    assert(original && ![original loadGeometryPack:manifest error:&error] && error.code == 28);
    error = nil;
    assert(![original selectEnhancedModels:YES error:&error] && error.code == 28);
    error = nil;
    ProtectorLiveMetalRenderer* renderer = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output texturePackManifest:nil presentationUpgrades:YES error:&error];
    assert(renderer && [renderer loadGeometryPack:manifest error:&error] && !error);
    assert(renderer.enhancedModelsEnabled);
    const auto* profile = [renderer.geometryPack profileForPrimitive:GeometryFixtureCommand.data() length:GeometryFixtureCommand.size()];
    LiveDraw draw;
    draw.geometryProfile = profile;
    draw.sourceVertexCount = 3;
    draw.indexed = true;
    draw.indices = {0,1,2};
    draw.viewportHeight = 448;
    draw.fragment.stageCount = 1;
    draw.fragment.colorCombiners[0] = 0x80000u | 0xF8DFu;
    draw.fragment.alphaCombiners[0] = 0x80000u | (7u << 13u) | (7u << 10u) | (7u << 7u) | (4u << 4u);
    draw.fragment.textureAlphaChannels[0] = 3;
    for (size_t stage = 0; stage < 8; ++stage) {
        draw.textureWidths[stage] = draw.textureHeights[stage] = 1;
        draw.textureRGBA[stage] = {100,200,50,255};
        std::fill(draw.fragment.textureDimensions[stage], draw.fragment.textureDimensions[stage] + 4, 1.0f);
    }
    const float positions[3][2] = {{-0.5,-0.3},{0.5,-0.3},{0,0.5}};
    for (const auto& position : positions) {
        LiveVertex vertex{};
        vertex.position[0] = position[0]; vertex.position[1] = position[1]; vertex.position[3] = 1;
        std::fill(vertex.color, vertex.color + 4, 1);
        draw.vertices.push_back(vertex);
    }
    const auto unchanged = draw.vertices;
    assert(RefineGeometry(&draw, draw.vertices));
    assert(draw.refinedVertices.size() == 6);
    assert(std::abs(draw.refinedVertices[3].position[1] - (-0.46f)) < 1e-6);
    assert(std::abs(draw.refinedVertices[3].position[3] - 1) < 1e-6);
    assert(memcmp(unchanged.data(), draw.vertices.data(), unchanged.size() * sizeof(LiveVertex)) == 0);
    draw.hasMotionSourceKey = true;
    draw.motionSourceKey.fill(0x43);
    const std::vector<LiveDraw> draws{draw};
    LiveEfbCopy display;
    display.drawIndex = 1; display.width = 640; display.height = 448;
    display.command = 1u << 14u; display.yScale = 256;
    const std::vector<LiveEfbCopy> copies{display};
    assert([renderer renderDraws:draws efbCopies:copies frame:21 error:&error]);
    std::vector<u8> refined(640 * 448 * 4), baseline(refined.size()), returned(refined.size());
    auto pixels = [&](std::vector<u8>& result) {
        [renderer.latestPresentationTexture getBytes:result.data() bytesPerRow:640 * 4
            fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    };
    pixels(refined);
    auto* preview = static_cast<ArtworkPreviewFrame*>(renderer.artworkPreviewFrame);
    preview->draws = draws; preview->copies = copies; preview->index = 21; preview->valid = true;
    assert([renderer.stateCapture[@"geometry_refined_draws"] unsignedIntValue] == 1);
    assert([renderer.stateCapture[@"geometry_refined_triangles"] unsignedIntValue] == 4);
    assert([renderer selectEnhancedModels:NO error:&error]); pixels(baseline);
    assert(refined != baseline && ![renderer.stateCapture[@"enhanced_models_enabled"] boolValue]);
    assert([renderer selectEnhancedModels:YES error:&error]); pixels(returned);
    assert(returned == refined && renderer.renderedFrameCount == 1 && renderer.geometryPreviewRedrawCount == 2);
    assert([renderer.stateCapture[@"frame_index"] unsignedIntValue] == 21);
    assert(![renderer loadGeometryPack:manifest error:&error]);
    error = nil;
    auto moved = draw;
    for (auto& vertex : moved.vertices) vertex.position[0] += 0.1f;
    for (auto& vertex : moved.refinedVertices) vertex.position[0] += 0.1f;
    renderer.motionProofMinimumFrame = 22;
    renderer.motionProofRequireShadow = YES;
    assert([renderer captureMotionProof:std::vector<LiveDraw>{moved} efbCopies:copies
        frame:22 guestTicks:2000000 error:&error]);
    assert(!renderer.motionProofCaptured && !error); // no shadow must not satisfy a shadow proof
    renderer.motionProofRequireShadow = NO;
    assert([renderer captureMotionProof:std::vector<LiveDraw>{moved} efbCopies:copies
        frame:22 guestTicks:2000000 error:&error]);
    assert(!error && renderer.motionProofCaptured && !renderer.motionProofRedraw);
    assert(renderer.renderedFrameCount == 1);
    NSURL* proofRoot = [output URLByAppendingPathComponent:@"motion-proof"];
    NSData* middle = [NSData dataWithContentsOfURL:[proofRoot URLByAppendingPathComponent:@"half.png"]];
    NSData* end = [NSData dataWithContentsOfURL:[proofRoot URLByAppendingPathComponent:@"current.png"]];
    NSData* reference = [NSData dataWithContentsOfURL:[proofRoot URLByAppendingPathComponent:@"current-reference.png"]];
    assert(middle && end && ![middle isEqual:end] && [end isEqual:reference]);
    assert(!renderer.motionProofShadowTextures);
    // Capture the actual offscreen GPU texture, not only admitted vertices.
    NSURL* shadowOutput = [output URLByAppendingPathComponent:@"shadow-proof-test"];
    ProtectorLiveMetalRenderer* shadowRenderer = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:shadowOutput texturePackManifest:nil presentationUpgrades:YES error:&error];
    assert(shadowRenderer && !error);
    auto shadowDraw = draw;
    shadowDraw.viewportWidth = shadowDraw.viewportHeight = 256;
    auto movedShadow = moved;
    movedShadow.viewportWidth = movedShadow.viewportHeight = 256;
    LiveEfbCopy backup;
    backup.drawIndex = 1; backup.width = backup.height = 256;
    backup.command = 0x10063; backup.yScale = 256; backup.destinationAddress = 0x10001000;
    auto silhouette = backup;
    silhouette.drawIndex = 2; silhouette.command = 0x1000B; silhouette.destinationAddress = 0x10002000;
    auto shadowDisplay = display; shadowDisplay.drawIndex = 3;
    LiveDraw receiver = draw;
    receiver.refinedVertices.clear(); receiver.geometryProfile = nullptr; receiver.hasMotionSourceKey = false;
    for (auto& vertex : receiver.vertices) vertex.position[0] -= .2f;
    receiver.textureAddresses[0] = silhouette.destinationAddress;
    receiver.textureWidths[0] = receiver.textureHeights[0] = 256; receiver.textureFormats[0] = 1;
    std::vector<LiveDraw> shadowSources{draw, shadowDraw, receiver}, shadowCurrent{moved, movedShadow, receiver};
    std::vector<LiveEfbCopy> shadowCopies{backup, silhouette, shadowDisplay};
    auto* shadowPreview = static_cast<ArtworkPreviewFrame*>(shadowRenderer.artworkPreviewFrame);
    shadowPreview->draws = shadowSources; shadowPreview->copies = shadowCopies;
    shadowPreview->index = 21; shadowPreview->valid = true;
    shadowRenderer.motionProofMinimumFrame = 22;
    shadowRenderer.motionProofRequireShadow = YES;
    assert([shadowRenderer captureMotionProof:shadowCurrent efbCopies:shadowCopies frame:22 guestTicks:2000000 error:&error]);
    assert(shadowRenderer.motionProofCaptured && !shadowRenderer.motionProofShadowTextures && !error);
    NSURL* shadowRoot = [shadowOutput URLByAppendingPathComponent:@"motion-proof"];
    NSData* shadowMiddle = [NSData dataWithContentsOfURL:[shadowRoot URLByAppendingPathComponent:@"half-shadow-1.png"]];
    NSData* shadowEnd = [NSData dataWithContentsOfURL:[shadowRoot URLByAppendingPathComponent:@"current-shadow-1.png"]];
    NSData* shadowReference = [NSData dataWithContentsOfURL:[shadowRoot URLByAppendingPathComponent:@"current-reference-shadow-1.png"]];
    assert(shadowMiddle && shadowEnd && ![shadowMiddle isEqual:shadowEnd] && [shadowEnd isEqual:shadowReference]);
    NSDictionary* shadowProof = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfURL:[shadowRoot URLByAppendingPathComponent:@"proof.json"]] options:0 error:&error];
    assert([shadowProof[@"reference_shadow_copy_images"] count] == 1 && [shadowProof[@"moving_shadow_model"] boolValue]);
    assert([shadowProof[@"receiver_diagnostic_images"] count] == 3);
    for (NSString* name in shadowProof[@"receiver_diagnostic_images"])
        assert([NSData dataWithContentsOfURL:[shadowRoot URLByAppendingPathComponent:name]]);
    assert([shadowRenderer renderDraws:shadowCurrent efbCopies:shadowCopies frame:23 error:&error]);
    assert(!shadowRenderer.motionProofShadowTextures); // no retained readback in normal rendering
    renderer.motionProofCaptured = NO;
    assert(![renderer captureMotionProof:std::vector<LiveDraw>{moved} efbCopies:copies
        frame:22 guestTicks:2000000 error:&error] && error.code == 35);
    error = nil;
    preview->copies[0].width = 641;
    assert(![renderer selectEnhancedModels:NO error:&error] && renderer.enhancedModelsEnabled);
    assert(renderer.geometryPreviewRedrawCount == 2);
    auto invalid = unchanged;
    invalid[0].position[0] = INFINITY;
    LiveDraw rejected;
    rejected.geometryProfile = profile;
    assert(!RefineGeometry(&rejected, invalid) && rejected.refinedVertices.empty());
}

static void TestMotionInitialColorRegisters() {
    LiveFragmentUniforms a;
    a.stageCount = 1;
    a.colorCombiners[0] = 0xFFFFu; // all zero arguments, no register read
    a.alphaCombiners[0] = 0xFFF0u;
    auto b = a;
    for (auto& reg : b.colorRegisters) for (float& component : reg) component = 0.5f;
    assert(MotionInitialColorRegisterReads(a) == 0);
    assert(MotionFragmentCompatible(a, b));
    for (u32 selector = 2; selector <= 7; ++selector) {
        auto reads = a;
        reads.colorCombiners[0] = (0xFFF0u | selector);
        auto changed = reads;
        const u32 reg = selector / 2 - 1;
        changed.colorRegisters[reg][selector & 1 ? 3 : 1] = 0.5f;
        assert(MotionInitialColorRegisterReads(reads) == ((selector & 1 ? 8u : 7u) << (4 * reg)));
        assert(!MotionFragmentCompatible(reads, changed));
        changed = reads;
        changed.colorRegisters[reg][selector & 1 ? 1 : 3] = 0.5f;
        assert(MotionFragmentCompatible(reads, changed)); // other half stays unused
    }
    for (u32 selector = 1; selector <= 3; ++selector) {
        auto reads = a;
        reads.alphaCombiners[0] = 0xFF80u | (selector << 4);
        auto changed = reads;
        changed.colorRegisters[selector - 1][3] = 0.5f;
        assert(MotionInitialColorRegisterReads(reads) == (8u << (4 * (selector - 1))));
        assert(!MotionFragmentCompatible(reads, changed));
    }
    auto overwritten = a;
    overwritten.stageCount = 2;
    overwritten.colorCombiners[0] |= 1u << 22; // writes register 1 RGB only
    overwritten.colorCombiners[1] = 0xFFF2u; // next stage reads its RGB
    overwritten.alphaCombiners[1] = 0xFFF0u;
    assert(MotionInitialColorRegisterReads(overwritten) == 0);
    overwritten.alphaCombiners[1] = 0xFF90u; // next stage reads register 1 alpha
    assert(MotionInitialColorRegisterReads(overwritten) == 8u);
    overwritten.alphaCombiners[0] |= 1u << 22;
    assert(MotionInitialColorRegisterReads(overwritten) == 0);
    overwritten.colorCombiners[0] = (1u << 22) | 0xFFF2u; // same-stage read happens before overwrite
    assert(MotionInitialColorRegisterReads(overwritten) == 7u);
    b = a; b.konstColors[0][0] = 0.5f;
    assert(!MotionFragmentCompatible(a, b)); // all other uniforms still exact
    b = a; b.colorCombiners[0] = 0xFFF2u;
    assert(!MotionFragmentCompatible(a, b)); // changed program still rejects
}

static void TestMotionCorrespondenceAudit() {
    DecoderState state;
    state.cp[0x50] = 3u << 9u; // indexed positions; absent arrays must not affect identity
    const u8 primitive[] = {0x9E, 0, 3, 1, 2, 3};
    LiveDraw a;
    a.indexed = true; a.indices = {0, 1, 2};
    a.viewportHeight = 448;
    a.vertices.resize(3);
    for (size_t i = 0; i < 3; ++i) {
        a.vertices[i].position[0] = (float)i * 0.1f;
        a.vertices[i].position[3] = 1;
    }
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x123000, 4, &a);
    assert(!a.hasMotionSourceKey);
    state.motionAuditEnabled = true;
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x123000, 4, &a);
    assert(a.hasMotionSourceKey);
    LiveDraw b = a;
    assert(MotionStateDifferences(a, b).count == 0);
    b.fragment.konstColors[0][0] = 0.5f;
    b.textureAddresses[7] = 256;
    assert([MotionStateDifferences(a, b) containsObject:@"fragment.konstColors"]);
    assert([MotionStateDifferences(a, b) containsObject:@"textureAddresses"]);
    assert(!MotionStateCompatible(a, b));
    b = a;
    state.cp[0xA0] = 0x1000;
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x123000, 4, &b);
    assert(a.motionSourceKey != b.motionSourceKey);
    LiveDraw unused = b;
    state.cp[0xA2] = 0xABCDEF; state.cp[0xB2] = 17;
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x123000, 4, &unused);
    assert(unused.motionSourceKey == b.motionSourceKey);
    state.cp[0x50] |= 1u << 13u; // direct color also ignores the array registers
    LiveDraw directA, directB;
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x123000, 4, &directA);
    state.cp[0xA2] = 0x8888; state.cp[0xB2] = 4;
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x123000, 4, &directB);
    assert(directA.motionSourceKey == directB.motionSourceKey);
    state.cp[0x50] = (3u << 9u) | (3u << 13u);
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x123000, 4, &directA);
    state.cp[0xA2] += 32;
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x123000, 4, &directB);
    assert(directA.motionSourceKey != directB.motionSourceKey); // active indexed color remains identity
    state.cp[0x50] = 3u << 9u;
    LiveDraw other = a;
    state.cp[0xA0] = 0;
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x123000, 8, &other);
    assert(a.motionSourceKey != other.motionSourceKey);
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x234000, 4, &other);
    assert(a.motionSourceKey != other.motionSourceKey);
    LiveDraw inlineA = a, inlineB = a;
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0, 4, &inlineA);
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0, 99, &inlineB);
    assert(inlineA.motionSourceKey == inlineB.motionSourceKey);
    ProtectorGeometryProfile profile;
    profile.sourceAnchorPrefixBytes = 64;
    profile.sourceAnchorSHA256 = std::string(64, 'a');
    LiveDraw skinA = a, skinB = a;
    skinA.geometryProfile = &profile; skinB.geometryProfile = &profile;
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x123000, 4, &skinA);
    state.cp[0xA0] = 0x2000; state.cp[0xA1] = 0x4000;
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x123000, 4, &skinB);
    assert(skinA.motionSourceKey == skinB.motionSourceKey);
    assert(skinA.motionSourceArrays[0] != skinB.motionSourceArrays[0]);
    profile.sourceAnchorSHA256 = std::string(64, 'b');
    SetMotionSourceKey(state, primitive, sizeof(primitive), 0x123000, 4, &skinB);
    assert(skinA.motionSourceKey != skinB.motionSourceKey);

    // Unrefined skinning is identified only by an exact original helper record
    // and its current CP output bindings. Legacy guard keys remain untouched.
    {
        auto skinState=state;
        skinState.cp[0x50]=(3u<<9u)|(3u<<11u);
        skinState.cp[0xB0]=skinState.cp[0xB1]=12;
        skinState.cp[0xA0]=0x2000;skinState.cp[0xA1]=0x4000;
        auto first=a, second=a;
        first.motionInstance={7,0x80773000,0x928D8000,{}};
        auto& source=first.motionInstance.skin;
        source.source_draw=0x90001000;source.output_position=0x80002000;source.output_normal=0x80004000;
        // The helper retains cached pointers; DecodeFrame passes physical DL addresses.
        source.source_words[4]=0x80123000;source.source_words[6]=0x90002000;source.source_words[7]=0x90004000;
        SetMotionSourceKey(skinState,primitive,sizeof(primitive),0x123000,4,&first);
        second=first;
        skinState.cp[0xA0]=0x6000;skinState.cp[0xA1]=0x8000;
        second.motionInstance.skin.output_position=0x80006000;second.motionInstance.skin.output_normal=0x80008000;
        SetMotionSourceKey(skinState,primitive,sizeof(primitive),0x123000,4,&second);
        assert(first.motionSourceKey==second.motionSourceKey && first.motionMeshKey!=second.motionMeshKey);
        auto unknown=second;unknown.motionInstance.skin={};
        SetMotionSourceKey(skinState,primitive,sizeof(primitive),0x123000,4,&unknown);
        assert(unknown.motionSourceKey!=second.motionSourceKey && unknown.motionMeshKey==second.motionMeshKey);
        for(size_t i=0;i<18;++i) {
            auto changed=second;changed.motionInstance.skin.source_words[i]^=1;
            SetMotionSourceKey(skinState,primitive,sizeof(primitive),0x123000,4,&changed);
            assert(changed.motionSourceKey!=second.motionSourceKey);
        }
        auto changed=second;changed.motionInstance.skin.source_draw+=56;
        SetMotionSourceKey(skinState,primitive,sizeof(primitive),0x123000,4,&changed);
        assert(changed.motionSourceKey!=second.motionSourceKey);
        changed=second;changed.motionInstance.generation++;
        SetMotionSourceKey(skinState,primitive,sizeof(primitive),0x123000,4,&changed);
        assert(changed.motionSourceKey!=second.motionSourceKey);
        changed=second;changed.motionInstance.skin.output_position+=4;
        SetMotionSourceKey(skinState,primitive,sizeof(primitive),0x123000,4,&changed);
        assert(changed.motionSourceKey==unknown.motionSourceKey); // mismatched CP falls back
        skinState.cp[0xB0]=8;
        SetMotionSourceKey(skinState,primitive,sizeof(primitive),0x123000,4,&changed);
        assert(changed.motionSourceKey!=second.motionSourceKey);
        // Refinement anchors retain their established main/shadow identity.
        skinState.cp[0xB0]=12;first.geometryProfile=second.geometryProfile=&profile;
        SetMotionSourceKey(skinState,primitive,sizeof(primitive),0x123000,4,&first);
        SetMotionSourceKey(skinState,primitive,sizeof(primitive),0x123000,4,&second);
        assert(first.motionSourceKey==second.motionSourceKey);
    }

    // Distinct source lifetimes disambiguate identical meshes without using
    // positions or draw order. Unadmitted and reused objects cannot cross-match.
    {
        auto one=a, two=a, reused=a;
        one.motionInstance={1,0x80773000,0x928D8000,{}};
        two.motionInstance={2,0x80773400,0x928D8000,{}};
        reused.motionInstance={3,0x80773000,0x928D8000,{}};
        for (auto* draw : {&one,&two,&reused})
            SetMotionSourceKey(state,primitive,sizeof(primitive),0x123000,4,draw);
        assert(one.motionSourceKey!=two.motionSourceKey && one.motionSourceKey!=reused.motionSourceKey);
        ArtworkPreviewFrame old; old.valid=true; old.index=8; old.draws={one,two};
        std::vector<s32> pairs;
        auto audit=MotionCorrespondenceAudit(&old,{two,one},9,&pairs);
        assert([audit[@"eligible_draws"] unsignedIntValue]==2 && pairs[0]==1 && pairs[1]==0);
        audit=MotionCorrespondenceAudit(&old,{two,reused},9);
        assert([audit[@"eligible_draws"] unsignedIntValue]==1 && [audit[@"unmatched_draws"] unsignedIntValue]==1);
        audit=MotionCorrespondenceAudit(&old,{one,one},9);
        assert([audit[@"ambiguous_draws"] unsignedIntValue]==2);
        // Main/shadow and other parts remain conservatively profile-coupled:
        // a missing identity must not make a partial articulated model move.
        ProtectorGeometryProfile member; member.identity="instance-test-draw-0";
        old.draws[0].geometryProfile=&member; old.draws[1].geometryProfile=&member;
        auto now=old.draws; now[1].motionInstance={}; now[1].hasMotionSourceKey=false;
        MotionCorrespondenceAudit(&old,now,9,&pairs);
        auto guarded=GuardMotionGroups(old,now,pairs);
        assert(guarded[0]==-1 && guarded[1]==-1);
        auto untyped=one; untyped.motionInstance={};
        SetMotionSourceKey(state,primitive,sizeof(primitive),0x123000,4,&untyped);
        for(auto& vertex:untyped.vertices)vertex.position[0]+=0.6f;
        old.draws={one};
        guarded=GuardMotionGroups(old,{one,untyped},{0,-1});
        assert(guarded[0]==-1 && guarded[1]==-1); // pre-instance main/shadow coupling survives

        // Unrefined, disconnected pieces still belong to the same source actor.
        auto part=one, other=two;
        for(auto& vertex:part.vertices)vertex.position[0]+=0.4f;
        for(auto& vertex:other.vertices)vertex.position[0]-=0.4f;
        part.motionSourceKey[0]^=0x40; part.motionMeshKey[0]^=0x40;
        other.motionSourceKey[0]^=0x80; other.motionMeshKey[0]^=0x80;
        old.draws={one,part,other};
        assert((GuardMotionGroups(old,old.draws,{0,1,2})==std::vector<s32>{0,1,2}));
        assert((GuardMotionGroups(old,old.draws,{0,-1,2})==std::vector<s32>{-1,-1,2}));
        auto instanceAudit=MotionSourceInstanceAudit(old.draws,{-1,-1,2},
            {MotionDrawRole::Scene,MotionDrawRole::Scene,MotionDrawRole::Scene});
        assert(instanceAudit.count==2);
        assert([instanceAudit[0][@"submitted_draws"] unsignedIntValue]==2 &&
            [instanceAudit[0][@"matched_draws"] unsignedIntValue]==0 &&
            [instanceAudit[1][@"matched_draws"] unsignedIntValue]==1);
        assert(MotionSourceInstanceAudit(old.draws,{}, {})==nil);
        // Removing a submitted piece holds its surviving actor, not a neighbor.
        assert((GuardMotionGroups(old,{one,other},{0,2})==std::vector<s32>{-1,2}));
        // Reordering is legal; an epoch or model-binding change is not.
        assert((GuardMotionGroups(old,{other,part,one},{2,1,0})==std::vector<s32>{2,1,0}));
        auto changed=part; changed.motionInstance.generation++;
        assert((GuardMotionGroups(old,{one,changed,other},{0,1,2})==std::vector<s32>{-1,-1,2}));
        changed=part; changed.motionInstance.binding+=4;
        assert((GuardMotionGroups(old,{one,changed,other},{0,1,2})==std::vector<s32>{-1,-1,2}));
    }

    ArtworkPreviewFrame previous;
    previous.valid = true; previous.index = 8; previous.draws = {a, b};
    auto current = std::vector<LiveDraw>{b, a}; // culling/reordering does not determine identity
    current[0].vertices[0].position[0] += 0.1f;
    NSDictionary* receipt = MotionCorrespondenceAudit(&previous, current, 9);
    assert([receipt[@"eligible_draws"] unsignedIntValue] == 2);
    assert([receipt[@"eligible_vertices"] unsignedIntValue] == 6);
    assert([receipt[@"maximum_eligible_ndc_step"] doubleValue] > 0.09);
    assert(![receipt[@"interpolation_enabled"] boolValue]);
    assert(previous.draws[1].vertices[0].position[0] == 0); // audit never edits geometry
    std::vector<s32> detailedPairs, compactPairs;
    MotionCorrespondenceAudit(&previous,current,9,&detailedPairs,nullptr,true);
    NSDictionary* compact=MotionCorrespondenceAudit(&previous,current,9,&compactPairs,nullptr,false);
    assert(detailedPairs==compactPairs);
    assert([compact[@"eligible_draws"] isEqual:receipt[@"eligible_draws"]]);
    assert(![compact[@"detailed_audit"] boolValue]);
    assert([compact[@"model_profiles"] count]==0 && [compact[@"rejection_sample"] count]==0);
    auto withShadow = previous;
    auto shadow = a;
    shadow.viewportWidth = 256; shadow.viewportHeight = 256;
    withShadow.draws.push_back(shadow);
    receipt = MotionCorrespondenceAudit(&withShadow, {a, b, shadow}, 9);
    assert([receipt[@"eligible_draws"] unsignedIntValue] == 2);
    NSArray* offscreen = MotionOffscreenAudit(withShadow, {a, b, shadow});
    assert(offscreen.count == 1 && [offscreen[0][@"draw"] unsignedIntValue] == 2);
    assert([offscreen[0][@"source_arrays"] count] == 12 && [offscreen[0][@"projection_words"] count] == 7);
    assert([offscreen[0][@"candidates"] count] == 2); // main and shadow key: state still distinguishes them
    assert(![offscreen[0][@"candidates"][0][@"compatible_state"] boolValue]);
    assert([offscreen[0][@"candidates"][1][@"compatible_state"] boolValue]);
    assert([offscreen[0][@"candidates"][1][@"valid_clip"] boolValue]);
    auto unknown = shadow;
    unknown.hasMotionSourceKey = false;
    assert([MotionOffscreenAudit(withShadow, {unknown})[0][@"candidates"] count] == 0);
    assert(MotionOffscreenAudit(withShadow, std::vector<LiveDraw>(129, shadow)).count == 128);
    receipt = MotionCorrespondenceAudit(&previous, current, 10);
    assert([receipt[@"unmatched_draws"] unsignedIntValue] == 2);
    current = {a, a};
    receipt = MotionCorrespondenceAudit(&previous, current, 9);
    assert([receipt[@"ambiguous_draws"] unsignedIntValue] == 2);
    previous.draws = {a, a}; current = {a};
    receipt = MotionCorrespondenceAudit(&previous, current, 9);
    assert([receipt[@"ambiguous_draws"] unsignedIntValue] == 1);
    previous.draws = {a}; current = {a};
    current[0].blendMode = 7;
    receipt = MotionCorrespondenceAudit(&previous, current, 9);
    assert([receipt[@"incompatible_draws"] unsignedIntValue] == 1);
    current = {a}; current[0].vertices[0].position[0] += 0.5f;
    receipt = MotionCorrespondenceAudit(&previous, current, 9);
    assert([receipt[@"discontinuous_draws"] unsignedIntValue] == 1);
    current = {a}; current[0].vertices[0].position[3] = -1;
    receipt = MotionCorrespondenceAudit(&previous, current, 9);
    assert([receipt[@"discontinuous_draws"] unsignedIntValue] == 1);
    current = {a}; current[0].vertices[0].position[0] = NAN;
    receipt = MotionCorrespondenceAudit(&previous, current, 9);
    assert([receipt[@"discontinuous_draws"] unsignedIntValue] == 1);
    current = {a}; current[0].projectionWords[6] = 1; // menus are not scene motion
    receipt = MotionCorrespondenceAudit(&previous, current, 9);
    assert([receipt[@"scene_draws"] unsignedIntValue] == 0);
    current = {a}; current[0].textureRGBA[0] = {0, 0, 0, 255};
    assert(!MotionStateCompatible(a, current[0]));
    current = {a}; current[0].indices = {0, 2, 1};
    assert(!MotionStateCompatible(a, current[0]));

    previous.draws = {a}; current = {a};
    current[0].vertices[0].position[0] = 0.2f;
    current[0].vertices[0].color[0] = 1;
    current[0].vertices[0].uv[0][0] = 0.5f;
    previous.draws[0].refinedVertices = previous.draws[0].vertices;
    current[0].refinedVertices = current[0].vertices;
    const auto before = MotionVertexDigest(current);
    std::vector<LiveDraw> blended;
    assert(BlendMotionDraws(previous, current, {0}, 0.5, &blended));
    assert(std::abs(blended[0].vertices[0].position[0] - 0.1f) < 1e-6);
    assert(blended[0].vertices[0].color[0] == 0.5f && blended[0].vertices[0].uv[0][0] == 0.25f);
    assert(blended[0].refinedVertices[0].position[0] == blended[0].vertices[0].position[0]);
    assert([before isEqual:MotionVertexDigest(current)]);
    assert(BlendMotionDraws(previous, current, {0}, 1, &blended));
    assert([before isEqual:MotionVertexDigest(blended)]);
    assert(BlendMotionDraws(previous, current, {0}, 0, &blended));
    assert([MotionVertexDigest(previous.draws) isEqual:MotionVertexDigest(blended)]);
    assert(BlendMotionDraws(previous, current, {-1}, 0.5, &blended));
    assert([before isEqual:MotionVertexDigest(blended)]);
    assert(!BlendMotionDraws(previous, current, {7}, 0.5, &blended));
    assert(!BlendMotionDraws(previous, current, {-2}, 0.5, &blended));
    assert(!BlendMotionDraws(previous, current, {}, 0.5, &blended));
    for (double fraction : {-0.1, 1.1, (double)NAN, (double)INFINITY})
        assert(!BlendMotionDraws(previous, current, {0}, fraction, &blended));
    ProtectorGeometryProfile bodyProfile, shellProfile;
    bodyProfile.identity = "test-character-draw-1";
    shellProfile.identity = "test-character-draw-0";
    a.geometryProfile = &bodyProfile; b.geometryProfile = &shellProfile;
    previous.draws = {a, b}; current = {a, b};
    assert((GuardMotionGroups(previous, current, {0, 1}) == std::vector<s32>{0, 1}));
    assert((GuardMotionGroups(previous, current, {0, -1}) == std::vector<s32>{-1, -1}));
    NSMutableArray* guardedModels = [NSMutableArray array];
    GuardMotionGroups(previous, current, {0, -1}, guardedModels);
    assert(guardedModels.count == 1);
    assert([guardedModels[0][@"model_group"] isEqual:@"test-character"]);
    assert([guardedModels[0][@"causes"][0][@"unmatched"] boolValue]);
    assert((GuardMotionGroups(previous, {a}, {0}) == std::vector<s32>{-1}));
    a.geometryProfile = nullptr; b.geometryProfile = nullptr;
    previous.draws = {a, b}; current = {a, b};
    assert((GuardMotionGroups(previous, current, {0, -1}) == std::vector<s32>{-1, -1}));
    previous.draws[1].vertices[0].position[0] += 0.001f;
    assert((GuardMotionGroups(previous, current, {0, 1}) == std::vector<s32>{-1, -1}));
    previous.draws[1].vertices[0].position[0] = 2 * FLT_EPSILON;
    assert((GuardMotionGroups(previous, current, {0, 1}) == std::vector<s32>{0, 1}));
    previous.draws[1].vertices[0].position[0] = 32 * FLT_EPSILON;
    assert((GuardMotionGroups(previous, current, {0, 1}) == std::vector<s32>{0, 1}));
    previous.draws[1].vertices[0].position[0] = 64 * FLT_EPSILON;
    assert((GuardMotionGroups(previous, current, {0, 1}) == std::vector<s32>{-1, -1}));
    const float tinyW[] = {0, 0, 0, 0.0002f};
    const float screenGap[] = {FLT_EPSILON, 0, 0, 0.0002f};
    assert(!MotionBoundaryCompatible(tinyW, screenGap)); // small absolute delta is not enough near eye plane
    const float invalidW[] = {0, 0, 0, -1};
    assert(!MotionBoundaryCompatible(tinyW, invalidW));
    const float sameScreen[] = {0, 0, 0, 1};
    const float changedScale[] = {0, 0, 0, 1 + 64 * FLT_EPSILON};
    assert(!MotionBoundaryCompatible(sameScreen, changedScale)); // perspective weights must remain near-exact too
    previous.draws = {a, a};
    previous.draws[1].blendMode = 7;
    current = previous.draws;
    receipt = MotionCorrespondenceAudit(&previous, current, 9);
    assert([receipt[@"eligible_draws"] unsignedIntValue] == 2); // distinct exact passes
}

static void TestMotionCopyPassBoundaries() {
    LiveEfbCopy offscreen, display;
    offscreen.drawIndex = 1; offscreen.width = offscreen.height = 256;
    offscreen.destinationAddress = 0x12340; offscreen.yScale = 256;
    display.drawIndex = 2; display.width = 640; display.height = 448;
    display.command = 1u << 14u; display.yScale = 256;
    std::vector<LiveEfbCopy> previous{offscreen, display}, current = previous;
    current[0].drawIndex = 2; current[1].drawIndex = 3;
    assert(MotionCopiesCompatible(previous, 2, current, 3));
    std::vector<s32> matches{0, -1, 1};
    GuardMotionCopyPasses(previous, current, &matches);
    assert((matches == std::vector<s32>{0, -1, 1})); // extra draw, same semantic passes
    matches = {-1, 1, -1};
    GuardMotionCopyPasses(previous, current, &matches);
    assert((matches == std::vector<s32>{-1, -1, -1})); // identical source crossed a copy fence
    auto changed = current;
    changed[0].destinationAddress += 32;
    assert(!MotionCopiesCompatible(previous, 2, changed, 3));
    changed = current; changed[0].height = 128;
    assert(!MotionCopiesCompatible(previous, 2, changed, 3));
    changed = current; changed[1].drawIndex = 2;
    assert(!MotionCopiesCompatible(previous, 2, changed, 3)); // display must be terminal
    changed = current; changed[0].drawIndex = 4;
    assert(!MotionCopiesCompatible(previous, 2, changed, 3)); // bounds/order
    changed.pop_back();
    assert(!MotionCopiesCompatible(previous, 2, changed, 3));
    assert(MotionCopiesCompatible({}, 0, {}, 4));
}

static void TestMotionShadowPass() {
    LiveDraw main;
    main.viewportHeight = 448;
    main.hasMotionSourceKey = true;
    main.motionSourceKey.fill(0x56);
    LiveVertex vertex{};
    vertex.position[3] = 1;
    main.vertices = {vertex};
    auto shadow = main;
    shadow.viewportWidth = shadow.viewportHeight = 256;
    auto quad = shadow;
    quad.projectionWords[6] = 1;
    quad.hasMotionSourceKey = false;
    std::vector<LiveDraw> draws{main, quad, shadow, quad};
    LiveEfbCopy backup;
    backup.drawIndex = 1; backup.width = backup.height = 256;
    backup.command = 0x10063; backup.yScale = 256; backup.destinationAddress = 0x10001000;
    auto silhouette = backup;
    silhouette.drawIndex = 3; silhouette.command = 0x1000B; silhouette.destinationAddress = 0x10002000;
    auto display = backup;
    display.drawIndex = 4; display.width = 640; display.height = 448; display.command = 1u << 14u;
    std::vector<LiveEfbCopy> copies{backup, silhouette, display};
    const auto roles = MotionDrawRoles(draws, &copies);
    assert((roles == std::vector<MotionDrawRole>{MotionDrawRole::Scene, MotionDrawRole::Hold,
        MotionDrawRole::Shadow, MotionDrawRole::Hold}));
    assert(MotionDrawRoles(draws, nullptr)[2] == MotionDrawRole::Hold);
    for (int change = 0; change < 7; ++change) {
        auto bad = copies;
        switch (change) {
            case 0: bad[1].command ^= 4; break;
            case 1: bad[0].command ^= 4; break;
            case 2: bad[1].width = 255; break;
            case 3: bad[1].sourceX = 1; break;
            case 4: bad[1].yScale = 255; break;
            case 5: bad[1].destinationAddress = 0; break;
            case 6: bad[2].drawIndex = 3; break;
        }
        assert(MotionDrawRoles(draws, &bad)[2] == MotionDrawRole::Hold);
    }
    auto movedViewport = draws;
    movedViewport[2].viewportX = 1;
    assert(MotionDrawRoles(movedViewport, &copies)[2] == MotionDrawRole::Hold);
    ArtworkPreviewFrame previous;
    previous.draws = draws; previous.copies = copies; previous.valid = true; previous.index = 8;
    draws[0].vertices[0].position[0] = .1f;
    draws[2].vertices[0].position[0] = .2f;
    std::vector<s32> matches;
    auto audit = MotionCorrespondenceAudit(&previous, draws, 9, &matches, &copies);
    assert([audit[@"scene_draws"] unsignedIntValue] == 1);
    assert([audit[@"eligible_draws"] unsignedIntValue] == 2);
    assert([audit[@"shadow_draws"] unsignedIntValue] == 1);
    assert([audit[@"eligible_shadow_draws"] unsignedIntValue] == 1);
    assert((matches == std::vector<s32>{0, -1, 2, -1}));
    assert(GuardMotionGroups(previous, draws, matches, nil, &copies) == matches);
    auto shadowHeld = matches;
    shadowHeld[2] = -1;
    assert((GuardMotionGroups(previous, draws, shadowHeld, nil, &copies) == std::vector<s32>(4, -1)));
    auto sceneHeld = matches;
    sceneHeld[0] = -1;
    assert((GuardMotionGroups(previous, draws, sceneHeld, nil, &copies) == std::vector<s32>(4, -1)));
    std::vector<LiveDraw> blended;
    assert(BlendMotionDraws(previous, draws, matches, .5, &blended));
    assert(blended[0].vertices[0].position[0] == .05f && blended[2].vertices[0].position[0] == .1f);
    assert(blended[1].vertices[0].position[0] == 0); // clear/restore untouched
    draws[2].motionSourceKey.fill(0x57);
    draws[2].vertices[0].position[0] = draws[0].vertices[0].position[0];
    previous.draws[2].vertices[0].position[0] = -.1f;
    // Unrelated geometry at numerically equal points in different projections
    // must not create a fictitious shared seam.
    assert(GuardMotionGroups(previous, draws, matches, nil, &copies) == matches);

    // A far-away depthless shadow projection can amplify one source-Z ulp.
    // Screen XY and perspective W remain subpixel-compatible; unused Z is not
    // a separating surface, provided all endpoints stay inside the clip range.
    const float clipA[] = {500, 1000, 800, 10000};
    const float clipB[] = {500.0001f, 1000.0005f, 800.25f, 10000.001f};
    assert(!MotionBoundaryCompatible(clipA, clipB));
    assert(MotionDepthlessShadowBoundaryCompatible(clipA, clipB, clipA));
    for (size_t component = 0; component < 4; ++component) {
        auto bad = std::array<float, 4>{clipB[0], clipB[1], clipB[2], clipB[3]};
        bad[component] = NAN;
        assert(!MotionDepthlessShadowBoundaryCompatible(clipA, bad.data(), clipA));
    }
    for (float z : {-1.0f, 0.0f, 10000.001f, 11000.0f}) {
        const float clipped[] = {500, 1000, z, 10000.001f};
        assert(!MotionDepthlessShadowBoundaryCompatible(clipA, clipped, clipA));
        assert(!MotionDepthlessShadowBoundaryCompatible(clipA, clipB, clipped));
    }
    const float screenGap[] = {501, 1000, 800, 10000};
    const float weightGap[] = {500, 1000, 800, 10001};
    assert(!MotionDepthlessShadowBoundaryCompatible(clipA, screenGap, clipA));
    assert(!MotionDepthlessShadowBoundaryCompatible(clipA, weightGap, clipA));

    auto second = main;
    second.motionSourceKey.fill(0x57);
    auto shadowA = shadow, shadowB = shadow;
    shadowB.motionSourceKey = second.motionSourceKey;
    for (LiveDraw* draw : {&shadowA, &shadowB}) {
        draw->depthMode = 14; // no depth comparison and no depth write
        std::copy(clipA, clipA + 4, draw->vertices[0].position);
    }
    draws = {main, second, quad, shadowA, shadowB, quad};
    copies[0].drawIndex = 2; copies[1].drawIndex = 5; copies[2].drawIndex = 6;
    previous.draws = draws; previous.copies = copies;
    std::copy(clipB, clipB + 4, previous.draws[4].vertices[0].position);
    matches = {0, 1, -1, 3, 4, -1};
    NSMutableDictionary* maskEvidence = [NSMutableDictionary dictionary];
    assert(GuardMotionGroups(previous, draws, matches, nil, &copies, maskEvidence) == matches);
    assert([maskEvidence[@"admitted_boundary_pairs"] unsignedIntValue] == 1);
    assert([maskEvidence[@"depth_test_and_write_disabled"] boolValue]);
    for (u32 enabled : {1u, 16u}) for (size_t index : {3u, 4u}) {
        draws[index].depthMode |= enabled;
        assert((GuardMotionGroups(previous, draws, matches, nil, &copies) == std::vector<s32>(6, -1)));
        draws[index].depthMode = 14;
        previous.draws[index].depthMode |= enabled;
        assert((GuardMotionGroups(previous, draws, matches, nil, &copies) == std::vector<s32>(6, -1)));
        previous.draws[index].depthMode = 14;
    }
    // The mask exception must not affect the identical numeric scene seam.
    previous.draws = {shadowA, shadowB}; draws = previous.draws;
    for (auto* list : {&previous.draws, &draws}) for (auto& draw : *list) {
        draw.viewportWidth = 640; draw.viewportHeight = 448;
    }
    std::copy(clipB, clipB + 4, previous.draws[1].vertices[0].position);
    previous.copies.clear();
    assert((GuardMotionGroups(previous, draws, {0, 1}) == std::vector<s32>{-1, -1}));
}

static void TestExactEfbTextureCopyBindings() {
    // Actual Canyon shadow, falloff and saved-tile addresses from the bounded
    // source proof. The falloff lies 32 bytes after the 65536-byte R8 mask.
    LiveEfbCopy tile;
    tile.destinationAddress = 268503456; tile.width = tile.height = 256; tile.command = 0x10063;
    LiveEfbCopy mask = tile;
    mask.destinationAddress = 268437600; mask.command = 0x1000B;
    std::vector<LiveEfbCopy> copies{tile, mask};
    LiveDraw ground;
    ground.textureAddresses[0] = 268503168; ground.textureWidths[0] = ground.textureHeights[0] = 16;
    ground.textureAddresses[1] = mask.destinationAddress;
    ground.textureWidths[1] = ground.textureHeights[1] = 256;
    assert(ExactEfbTextureCopyIndex(ground, 0, copies, 2) == -1);
    assert(ExactEfbTextureCopyIndex(ground, 1, copies, 1) == -1); // copy not performed yet
    assert(ExactEfbTextureCopyIndex(ground, 1, copies, 2) == 1);
    ground.textureAddresses[1] = tile.destinationAddress;
    assert(ExactEfbTextureCopyIndex(ground, 1, copies, 2) == 0);
    ground.textureWidths[1] = 16;
    assert(ExactEfbTextureCopyIndex(ground, 1, copies, 2) == -1); // no guessed crop
    ground.textureWidths[1] = 256;
    copies.push_back(tile);
    assert(ExactEfbTextureCopyIndex(ground, 1, copies, 3) == 2); // latest write
    copies.back().width = 128;
    assert(ExactEfbTextureCopyIndex(ground, 1, copies, 3) == -1); // no stale earlier image
    assert(ExactEfbTextureCopyIndex(ground, 8, copies, 3) == -1);
    copies[0].command = 1u << 14u;
    assert(ExactEfbTextureCopyIndex(ground, 1, copies, 1) == -1); // not a texture copy
}

static void TestMotionPresentationHistory() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSURL* output = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"protector-motion-live-test-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    NSError* error = nil;
    setenv("PROTECTOR_MOTION_PRESENTATION", "1", 1);
    ProtectorLiveMetalRenderer* original = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output error:&error];
    assert(original && !original.motionHistory); // Original stays original even with the opt-in.
    for (const char* invalid : {"", "-1", "100001", "760x"}) {
        setenv("PROTECTOR_MOTION_PRESENTATION_MIN_FRAME", invalid, 1);
        ProtectorLiveMetalRenderer* rejected = [[ProtectorLiveMetalRenderer alloc]
            initContinuousWithDevice:device outputDirectory:output texturePackManifest:nil presentationUpgrades:YES error:&error];
        assert(!rejected && error.code == 36);
        error = nil;
    }
    setenv("PROTECTOR_MOTION_PRESENTATION_MIN_FRAME", "760", 1);
    ProtectorLiveMetalRenderer* renderer = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output texturePackManifest:nil presentationUpgrades:YES error:&error];
    unsetenv("PROTECTOR_MOTION_PRESENTATION");
    unsetenv("PROTECTOR_MOTION_PRESENTATION_MIN_FRAME");
    assert(renderer && renderer.motionHistory && !error);
    assert(renderer.motionPresentationMinimumFrame == 760);
    auto* history = static_cast<MotionPresentationHistory*>(renderer.motionHistory);
    auto* current = static_cast<ArtworkPreviewFrame*>(renderer.artworkPreviewFrame);
    LiveDraw draw;
    draw.hasMotionSourceKey = true; draw.motionSourceKey.fill(0x47);
    draw.sourceVertexCount = 3; draw.viewportHeight = 448;
    draw.fragment.stageCount = 1;
    draw.fragment.colorCombiners[0] = 0x80000u | 0xF8DFu;
    draw.fragment.alphaCombiners[0] = 0x80000u | (7u << 13u) | (7u << 10u) | (7u << 7u) | (4u << 4u);
    draw.fragment.textureAlphaChannels[0] = 3;
    for (size_t stage = 0; stage < 8; ++stage) {
        draw.textureWidths[stage] = draw.textureHeights[stage] = 1;
        draw.textureRGBA[stage] = {100,200,50,255};
        std::fill(draw.fragment.textureDimensions[stage], draw.fragment.textureDimensions[stage] + 4, 1.0f);
    }
    const float positions[3][2] = {{-0.5,-0.3},{0.5,-0.3},{0,0.5}};
    for (const auto& position : positions) {
        LiveVertex vertex{};
        vertex.position[0] = position[0]; vertex.position[1] = position[1]; vertex.position[3] = 1;
        std::fill(vertex.color, vertex.color + 4, 1);
        draw.vertices.push_back(vertex);
    }
    LiveEfbCopy display;
    display.drawIndex = 1; display.width = 640; display.height = 448;
    display.command = 1u << 14u; display.yScale = 256;
    const u64 tickStep = 2025000;
    const auto stage = [&](const LiveDraw& source, u32 index, double deadline) {
        std::vector<LiveDraw> draws{source}; std::vector<LiveEfbCopy> copies{display};
        [renderer stageMotionDraws:draws copies:copies frame:index guestTicks:index * tickStep deadline:deadline];
        assert(draws.empty() && copies.empty()); // ownership, not guest memory, is transferred
    };
    stage(draw, 1, 8);
    assert(!history->ready && history->sourceFrames == 1 && !renderer.latestTexture);
    assert(!strcmp(history->holdReason, "history-empty"));
    assert([renderer renderMotionAtTime:8 error:&error] && !error && history->renderedFraction == 1);
    auto moved = draw;
    for (auto& vertex : moved.vertices) vertex.position[0] += 0.2f;
    for (auto& reg : moved.fragment.colorRegisters) for (float& component : reg) component = 0.75f;
    stage(moved, 2, 8 + 1.0 / 30.0);
    assert(history->ready && history->matchedDraws == 1 && history->previous.index == 1);
    assert(history->matchedUnusedColorDraws == 1);
    NSString* sourceHash = MotionVertexDigest(current->draws);
    // A display-grid sample a few ms before the new frame's deadline is the
    // start of the new pair, never a snap to its end (that read as judder).
    assert([renderer renderMotionAtTime:8 + 1.0 / 30.0 - 0.004 error:&error]);
    assert(history->renderedFraction == 0);
    assert([renderer renderMotionAtTime:8 + 1.0 / 30.0 + 1.0 / 60.0 error:&error]);
    assert(std::abs(history->renderedFraction - 0.5) < 1e-12 && history->generatedFrames == 1);
    std::vector<u8> middle(640 * 448 * 4), endpoint(middle.size());
    [renderer.latestPresentationTexture getBytes:middle.data() bytesPerRow:640*4
        fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    assert([renderer renderMotionAtTime:9 error:&error] && history->renderedFraction == 1);
    [renderer.latestPresentationTexture getBytes:endpoint.data() bytesPerRow:640*4
        fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    assert(middle != endpoint && [sourceHash isEqual:MotionVertexDigest(current->draws)]);
    NSDictionary* captured = [renderer writeLatestDiagnosticFrameToURL:
        [output URLByAppendingPathComponent:@"diagnostic.png"] error:&error];
    assert(captured && [captured[@"frame_index"] unsignedIntValue] == 2);
    assert([captured[@"motion_presentation"][@"fraction"] doubleValue] == 1);
    const u64 renders = renderer.renderedFrameCount;
    assert([renderer renderMotionAtTime:10 error:&error] && renderer.renderedFrameCount == renders);
    assert([renderer.stateCapture[@"motion_presentation"][@"original_guest_frames"] unsignedIntValue] == 2);
    assert(history->sourceFrames == 2); // intermediate frames are not guest updates
    [renderer setPresentationPaused:YES];
    assert(history->paused && !history->ready && !history->previous.valid && current->hostDeadline == 0);
    stage(draw, 3, 9); // an already-admitted callback racing a pause cannot rebuild history
    assert(!history->ready && current->hostDeadline == 0);
    [renderer setPresentationPaused:NO];
    stage(draw, 4, 9 + 1.0 / 30.0);
    assert(!history->ready);
    stage(moved, 5, 9 + 2.0 / 30.0);
    assert(history->ready);
    assert([renderer selectWidescreen:YES error:&error]);
    assert(!history->ready && current->hostDeadline == 0);
    stage(draw, 6, 9.1); stage(moved, 7, 9.1 + 1.0 / 30.0);
    assert(history->ready);
    stage(draw, 9, 9.1 + 3.0 / 30.0); // skipped source frame
    assert(!history->ready);
    assert(!strcmp(history->holdReason, "source-frame-gap"));
    stage(moved, 10, 12); // host deadline rebase
    assert(!history->ready);
    assert(!strcmp(history->holdReason, "clock-discontinuity"));
    stage(draw, 11, 12 + 1.0 / 30.0);
    assert(history->ready);
    display.height = 444;
    stage(moved, 12, 12 + 2.0 / 30.0); // changed EFB/display-copy layout
    assert(!history->ready);
    assert(!strcmp(history->holdReason, "changed-copy-layout"));
    assert([renderer.motionCopyMismatch[@"previous"][@"copies"][0][@"height"] unsignedIntValue] == 448);
    assert([renderer.motionCopyMismatch[@"current"][@"copies"][0][@"height"] unsignedIntValue] == 444);
    assert([renderer.motionCopyMismatch[@"current"][@"draw_count"] unsignedIntValue] == 1);
    stage(draw, 13, NAN);
    assert(!history->ready && current->hostDeadline == 0);
    assert(!renderer.motionCopyMismatch);
    assert(!error);
    // The admitted unused-register difference must be pixel-identical on the
    // actual Metal shader, not just a successful CPU mask calculation.
    display.height = 448;
    assert([renderer renderDraws:std::vector<LiveDraw>{moved} efbCopies:std::vector<LiveEfbCopy>{display}
        frame:14 error:&error]);
    [renderer.latestPresentationTexture getBytes:endpoint.data() bytesPerRow:640*4
        fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    for (auto& reg : moved.fragment.colorRegisters) for (float& component : reg) component = 0;
    assert([renderer renderDraws:std::vector<LiveDraw>{moved} efbCopies:std::vector<LiveEfbCopy>{display}
        frame:14 error:&error]);
    [renderer.latestPresentationTexture getBytes:middle.data() bytesPerRow:640*4
        fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    assert(endpoint == middle);

    // Public preview controls work without the developer logging environment.
    assert(!original.smoothMotionAvailable && !original.smoothMotionEnabled);
    assert([original selectSmoothMotion:NO error:&error]);
    assert(![original selectSmoothMotion:YES error:&error] && error.code == 26);
    error = nil;
    ProtectorLiveMetalRenderer* selectable = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output texturePackManifest:nil
        presentationUpgrades:YES error:&error];
    assert(selectable.smoothMotionAvailable && !selectable.smoothMotionEnabled && !selectable.motionHistory);
    [selectable setPresentationPaused:YES]; // opening Pause precedes the first enable
    assert([selectable selectSmoothMotion:YES error:&error]);
    assert(selectable.smoothMotionEnabled && !selectable.motionPresentationLog);
    auto* selectionHistory = static_cast<MotionPresentationHistory*>(selectable.motionHistory);
    assert(selectionHistory->paused && !selectionHistory->ready);
    auto stageSelection = [&](const LiveDraw& source, u32 frame) {
        std::vector<LiveDraw> draws{source}; std::vector<LiveEfbCopy> copies{display};
        [selectable stageMotionDraws:draws copies:copies frame:frame guestTicks:frame * tickStep
            deadline:20.0 + frame / 30.0];
    };
    stageSelection(draw, 1);
    assert(!selectionHistory->ready && !strcmp(selectionHistory->holdReason, "host-paused"));
    [selectable setPresentationPaused:NO];
    stageSelection(draw, 2);
    assert(!selectionHistory->ready);
    stageSelection(moved, 3);
    assert(selectionHistory->ready);
    assert([selectable renderMotionAtTime:20.15 error:&error]); // exact endpoint
    [selectable.latestPresentationTexture getBytes:endpoint.data() bytesPerRow:640*4
        fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    assert([selectable renderMotionAtTime:20.1 + 1.0/60.0 error:&error]);
    [selectable.latestPresentationTexture getBytes:middle.data() bytesPerRow:640*4
        fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    assert(middle != endpoint);
    const u64 renderedBeforeToggle = selectable.renderedFrameCount;
    const u64 sourcesBeforeToggle = selectionHistory->sourceFrames;
    const u64 intermediatesBeforeToggle = selectionHistory->generatedFrames;
    assert([selectable selectSmoothMotion:NO error:&error]);
    assert(!selectable.smoothMotionEnabled && !selectable.motionPresentationPrototypeEnabled);
    assert(selectionHistory->previous.draws.empty() && selectionHistory->matches.empty() && !selectionHistory->ready);
    [selectable.latestPresentationTexture getBytes:middle.data() bytesPerRow:640*4
        fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    assert(middle == endpoint && selectable.renderedFrameCount == renderedBeforeToggle);
    assert([selectable renderMotionAtTime:21 error:&error]); // disabled display loop is inert
    assert(selectionHistory->sourceFrames == sourcesBeforeToggle &&
        selectionHistory->generatedFrames == intermediatesBeforeToggle);
    assert(![selectable.stateCapture[@"smooth_motion_enabled"] boolValue]);
    assert(!selectable.stateCapture[@"motion_presentation"]);
    assert([selectable selectSmoothMotion:YES error:&error]);
    assert(selectable.motionHistory == selectionHistory); // bounded history and monotonic counters
    stageSelection(draw, 4);
    assert(!selectionHistory->ready);
    stageSelection(moved, 5);
    assert(selectionHistory->ready && selectionHistory->sourceFrames == sourcesBeforeToggle + 2);
    assert([selectable selectSmoothMotion:NO error:&error]);
    selectable.motionProofMinimumFrame = 2;
    assert(!selectable.smoothMotionAvailable);
    assert(![selectable selectSmoothMotion:YES error:&error] && error.code == 26);
}

static void TestCombatFeedbackSourceGlyphs() {
    LiveDraw draw{};draw.indexed=true;draw.vertices.resize(4);
    for (const auto& cell:kCombatFeedbackGlyphs) {
        const float uv[][2]={{cell.left,cell.bottom},{cell.left,cell.top},
            {cell.right,cell.top},{cell.right,cell.bottom}};
        for (size_t i=0;i<4;++i)for(size_t a=0;a<2;++a)draw.vertices[i].uv[0][a]=uv[i][a];
        const auto before=draw.vertices;
        assert(CombatFeedbackQuadGlyph(draw,0)==cell.character);
        assert(!CombatFeedbackQuadGlyph(draw,1));
        assert(!memcmp(draw.vertices.data(),before.data(),4*sizeof(LiveVertex)));
        draw.vertices[0].uv[0][0]+=.001f;assert(!CombatFeedbackQuadGlyph(draw,0));
        draw.vertices[0].uv[0][0]=NAN;assert(!CombatFeedbackQuadGlyph(draw,0));
    }
    draw.indexed=false;assert(!CombatFeedbackQuadGlyph(draw,0));
    assert(!CombatFeedbackAuditContainsLabel({draw}));
    assert(!CombatFeedbackAuditContainsLabel({}));
    assert(CombatFeedbackCount("2")==2 && CombatFeedbackCount("999")==999);
    assert(CombatFeedbackCount("1,000")==1000 && CombatFeedbackCount("2,147,483,647")==INT32_MAX);
    for(const char* text:{"","0","02","-2","1000","1,00","2,147,483,648","COMBO",",2","2,"})
        assert(!CombatFeedbackCount(text));
}

static void TestInterfaceSourceAudit() {
    LiveDraw hud;
    hud.projectionWords[6] = 1;
    hud.viewportHeight = 448;
    hud.fragment.stageCount = 2;
    hud.indexed = true;
    hud.indices = {0, 1, 2};
    const std::vector<u8> pixels{128, 64, 32, 0, 255, 16, 4, 127};
    for (size_t stage = 0; stage < 2; ++stage) {
        hud.textureWidths[stage] = 2;
        hud.textureHeights[stage] = 1;
        hud.textureFormats[stage] = 6;
        hud.textureAddresses[stage] = 0x1000;
    }
    hud.decodedPixels[0] = std::make_shared<const std::vector<u8>>(pixels);
    hud.textureRGBA[1] = pixels; // cached and owned pixels have identical identity
    // DecodeDrawTextures supplies a 1x1 fallback for unused Metal bindings.
    // Keep this GPU fixture as complete as a decoded game draw.
    for (size_t stage = 2; stage < 8; ++stage) {
        hud.textureWidths[stage] = hud.textureHeights[stage] = 1;
        hud.textureRGBA[stage] = {255,255,255,255};
    }
    LiveVertex vertex{};
    vertex.position[0] = -0.8f;
    vertex.position[1] = 0.5f;
    vertex.position[3] = 1;
    vertex.uv[0][0] = 0.25f;
    vertex.uv[0][1] = 0.75f;
    vertex.color[0] = 1;
    hud.vertices.assign(3, vertex);
    LiveDraw scene = hud;
    scene.projectionWords[6] = 0;
    LiveDraw unknown = hud;
    unknown.viewportWidth = 256;
    unknown.viewportHeight = 256;
    const std::vector<LiveDraw> draws{scene, hud, unknown};
    NSString* before = MotionVertexDigest(draws);
    NSMutableDictionary<NSString*, NSData*>* textures = [NSMutableDictionary dictionary];
    NSDictionary* audit = InterfaceSourceAudit(draws, {}, textures);
    assert([audit[@"total_draws"] unsignedIntValue] == 3 && [audit[@"draws"] count] == 2);
    assert([audit[@"draws"][0][@"draw_index"] unsignedIntValue] == 1);
    assert([audit[@"draws"][0][@"role"] isEqual:@"centred-4:3"]);
    assert([audit[@"draws"][1][@"role"] isEqual:@"unknown-offscreen"]);
    assert([audit[@"draws"][0][@"vertices"][0][@"uv"][0][0] floatValue] == 0.25f);
    assert(([audit[@"draws"][0][@"indices"] isEqual:@[@0, @1, @2]]));
    NSString* expected = [@"2x1-" stringByAppendingString:TestPixelHash(pixels)];
    assert(InterfaceAuditSourceKeyValid(expected));
    assert(!InterfaceAuditSourceKeyValid(nil));
    assert(!InterfaceAuditSourceKeyValid([expected stringByAppendingString:@"\n"]));
    assert(!InterfaceAuditSourceKeyValid([@"0" stringByAppendingString:expected]));
    assert(!InterfaceAuditSourceKeyValid([expected uppercaseString]));
    assert(!InterfaceAuditSourceKeyValid([expected stringByReplacingOccurrencesOfString:@"2x1-" withString:@"2049x1-"]));
    assert(InterfaceAuditContainsSource(draws,expected));
    assert(!InterfaceAuditContainsSource({scene},expected));
    LiveDraw changed = hud;
    changed.decodedPixels[0].reset();
    changed.textureRGBA[0] = pixels; changed.textureRGBA[0][0] ^= 1;
    changed.fragment.stageCount = 1;
    assert(!InterfaceAuditContainsSource({changed},expected));
    assert((MaterialAuditDrawIndices(draws,expected) == std::vector<size_t>{0,1,2}));
    assert((MaterialAuditDrawIndices({scene},expected) == std::vector<size_t>{0}));
    assert(MaterialAuditDrawIndices({changed},expected).empty());
    assert(MaterialAuditDrawIndices(draws,nil).empty());
    assert(MaterialAuditDrawIndices(draws,[expected stringByAppendingString:@"\n"]).empty());
    // Fillers are valid decoded draws with a different exact material key;
    // zero-initialized textures are not valid Metal submissions.
    auto denseDraws = std::vector<LiveDraw>(3304,changed);
    denseDraws.insert(denseDraws.end(), draws.begin(), draws.end());
    assert((MaterialAuditDrawIndices(denseDraws,expected) == std::vector<size_t>{3304,3305,3306}));
    auto atLimit = std::vector<LiveDraw>(kMaterialAuditMaxDraws);
    atLimit.back() = hud;
    assert((MaterialAuditDrawIndices(atLimit,expected) == std::vector<size_t>{kMaterialAuditMaxDraws-1}));
    atLimit.emplace_back();
    assert(MaterialAuditDrawIndices(atLimit,expected).empty());
    LiveDraw unsupportedMaterial = hud;
    unsupportedMaterial.fragment.stageCount = 5;
    assert(MaterialAuditDrawIndices({unsupportedMaterial},expected).empty());
    auto beyond = std::vector<LiveDraw>(256,changed);
    beyond.push_back(hud);
    assert(!InterfaceAuditContainsSource(beyond,expected));
    beyond.erase(beyond.begin());
    assert(InterfaceAuditContainsSource(beyond,expected));
    assert([audit[@"draws"][0][@"textures"][0][@"source_key"] isEqual:expected]);
    assert(textures.count == 1 && [audit[@"texture_bytes"] unsignedIntValue] == pixels.size());
    assert([textures[expected] isEqual:[NSData dataWithBytes:pixels.data() length:pixels.size()]]);
    assert([before isEqual:MotionVertexDigest(draws)] && TexturePixels(draws[1], 0) == pixels);

    // The scene-material observer is explicitly configured, bounded, and
    // freezes both artwork comparisons at the same source submission.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSURL* output = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"protector-material-test-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    NSError* materialError = nil;
    // Readiness is opt-in, must belong to an explicitly configured observer,
    // and cannot turn a pipe/symlink/large file into a blocking renderer read.
    NSString* markerPath = [[output URLByAppendingPathComponent:@"ready-marker"] path];
    unsetenv("PROTECTOR_MATERIAL_AUDIT_KEYS");
    setenv("PROTECTOR_MATERIAL_AUDIT_READY_PATH", markerPath.UTF8String, 1);
    assert(![[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:device outputDirectory:output
        texturePackManifest:nil presentationUpgrades:YES error:&materialError] && materialError.code == 37);
    setenv("PROTECTOR_MATERIAL_AUDIT_KEYS", expected.UTF8String, 1);
    for (NSString* badPath in @[@"", @"relative/ready", @"/tmp/ready\n", [@"/" stringByPaddingToLength:1025 withString:@"x" startingAtIndex:0]]) {
        materialError = nil;
        setenv("PROTECTOR_MATERIAL_AUDIT_READY_PATH", badPath.UTF8String, 1);
        assert(![[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:device outputDirectory:output
            texturePackManifest:nil presentationUpgrades:YES error:&materialError] && materialError.code == 37);
    }
    setenv("PROTECTOR_MATERIAL_AUDIT_READY_PATH", markerPath.UTF8String, 1);
    materialError = nil;
    NSURL* gatedOutput = [output URLByAppendingPathComponent:@"gated" isDirectory:YES];
    ProtectorLiveMetalRenderer* gated = [[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:device
        outputDirectory:gatedOutput texturePackManifest:nil presentationUpgrades:YES error:&materialError];
    unsetenv("PROTECTOR_MATERIAL_AUDIT_READY_PATH");
    assert(gated && !materialError && !gated.materialAuditReady);
    assert([gated captureMaterialSources:draws copies:{} frame:38 guestTicks:12341 error:&materialError]);
    assert(gated.materialAuditCaptured.count == 0 && gated.renderedFrameCount == 0);
    for (NSString* wrong in @[@"", @"ready", @"Ready\n", @"ready\nx"]) {
        assert([[wrong dataUsingEncoding:NSUTF8StringEncoding] writeToFile:markerPath atomically:YES]);
        assert([gated captureMaterialSources:draws copies:{} frame:39 guestTicks:12342 error:&materialError]);
        assert(!gated.materialAuditReady && gated.materialAuditCaptured.count == 0);
    }
    assert([NSFileManager.defaultManager removeItemAtPath:markerPath error:&materialError]);
    NSString* realMarker = [markerPath stringByAppendingString:@".real"];
    assert([[@"ready\n" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:realMarker atomically:YES]);
    assert([NSFileManager.defaultManager createSymbolicLinkAtPath:markerPath withDestinationPath:realMarker error:&materialError]);
    assert([gated captureMaterialSources:draws copies:{} frame:40 guestTicks:12343 error:&materialError]);
    assert(!gated.materialAuditReady && gated.materialAuditCaptured.count == 0);
    assert([NSFileManager.defaultManager removeItemAtPath:markerPath error:&materialError]);
    assert(mkfifo(markerPath.fileSystemRepresentation, 0600) == 0);
    assert([gated captureMaterialSources:draws copies:{} frame:40 guestTicks:12343 error:&materialError]);
    assert(!gated.materialAuditReady && gated.materialAuditCaptured.count == 0);
    assert([NSFileManager.defaultManager removeItemAtPath:markerPath error:&materialError]);
    assert(![NSFileManager.defaultManager fileExistsAtPath:[gatedOutput URLByAppendingPathComponent:@"material-source-00"].path]);
    assert([[@"ready\n" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:markerPath atomically:YES]);
    assert([gated captureMaterialSources:draws copies:{} frame:41 guestTicks:12344 error:&materialError]);
    assert(gated.materialAuditReady && gated.materialAuditCaptured.count == 1 && gated.renderedFrameCount == 0);
    NSDictionary* gatedMaterial = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:
        [gatedOutput URLByAppendingPathComponent:@"material-source-00/inspection.json"]] options:0 error:&materialError];
    assert(gatedMaterial && !materialError && [gatedMaterial[@"frame_index"] unsignedIntValue] == 41);
    assert([gatedMaterial[@"readiness_gate_configured"] boolValue] && [gatedMaterial[@"readiness_gate_released"] boolValue]);
    assert([NSFileManager.defaultManager removeItemAtPath:markerPath error:&materialError]);
    assert([gated captureMaterialSources:draws copies:{} frame:42 guestTicks:12345 error:&materialError]);
    assert(gated.materialAuditReady && gated.materialAuditCaptured.count == 1);
    setenv("PROTECTOR_MATERIAL_AUDIT_KEYS", "", 1);
    assert(![[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:device outputDirectory:output
        texturePackManifest:nil presentationUpgrades:YES error:&materialError] && materialError.code == 37);
    materialError = nil;
    NSString* duplicateKeys = [NSString stringWithFormat:@"%@,%@",expected,expected];
    setenv("PROTECTOR_MATERIAL_AUDIT_KEYS", duplicateKeys.UTF8String, 1);
    assert(![[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:device outputDirectory:output
        texturePackManifest:nil presentationUpgrades:YES error:&materialError] && materialError.code == 37);
    materialError = nil;
    setenv("PROTECTOR_MATERIAL_AUDIT_KEYS", expected.UTF8String, 1);
    ProtectorLiveMetalRenderer* observed = [[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:device
        outputDirectory:output texturePackManifest:nil presentationUpgrades:YES error:&materialError];
    unsetenv("PROTECTOR_MATERIAL_AUDIT_KEYS");
    assert(observed && !materialError && observed.materialAuditKeys.count == 1);
    assert(![observed captureMaterialSources:atLimit copies:{} frame:42 guestTicks:12345 error:&materialError]);
    assert(materialError.code == 37 && observed.materialAuditCaptured.count == 0);
    assert(![NSFileManager.defaultManager fileExistsAtPath:[output URLByAppendingPathComponent:@"material-source-00"].path]);
    materialError = nil;
    NSString* denseBefore = MotionVertexDigest(denseDraws);
    assert([observed captureMaterialSources:denseDraws copies:{} frame:42 guestTicks:12345 error:&materialError]);
    assert([denseBefore isEqual:MotionVertexDigest(denseDraws)]);
    assert(observed.materialAuditCaptured.count == 1 && observed.renderedFrameCount == 0 && !observed.sceneEdgeRedraw);
    NSURL* inspectionURL = [output URLByAppendingPathComponent:@"material-source-00/inspection.json"];
    NSDictionary* material = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:inspectionURL]
        options:0 error:&materialError];
    assert(material && !materialError && [material[@"source_key"] isEqual:expected]);
    assert(![material[@"readiness_gate_configured"] boolValue] && ![material[@"readiness_gate_released"] boolValue]);
    assert([material[@"frame_index"] unsignedIntValue] == 42 && [material[@"guest_timebase"] unsignedIntValue] == 12345);
    assert([material[@"draws"] count] == 3 && [material[@"samples"] count] == 2);
    assert([material[@"draws"][0][@"draw_index"] unsignedIntValue] == 3304);
    assert([material[@"draws"][2][@"draw_index"] unsignedIntValue] == 3306);
    assert(![material[@"draws"][0][@"orthographic"] boolValue]);
    assert([material[@"draws"][1][@"orthographic"] boolValue]);
    assert([material[@"draws"][0][@"stages"] count] == 2);
    NSData* inspectionBytes = [NSData dataWithContentsOfURL:inspectionURL];
    assert([observed captureMaterialSources:draws copies:{} frame:43 guestTicks:12346 error:&materialError]);
    assert([inspectionBytes isEqual:[NSData dataWithContentsOfURL:inspectionURL]]); // no repeated capture
    [observed.materialAuditCaptured removeAllObjects];
    assert(![observed captureMaterialSources:draws copies:{} frame:43 guestTicks:12346 error:&materialError]);
    assert(materialError.code == 37 && [inspectionBytes isEqual:[NSData dataWithContentsOfURL:inspectionURL]]);
    assert([before isEqual:MotionVertexDigest(draws)] && observed.renderedFrameCount == 0);

    hud.vertices.assign(129, vertex);
    hud.vertices[0].position[0] = std::numeric_limits<float>::quiet_NaN();
    hud.textureWidths[1] = 2049; // rejected dimensions, not an out-of-bounds hash
    textures = [NSMutableDictionary dictionary];
    audit = InterfaceSourceAudit({hud}, {}, textures);
    assert([audit[@"omitted_vertices"] unsignedIntValue] == 1);
    assert(audit[@"draws"][0][@"vertices"][0][@"clip"][0] == NSNull.null);
    assert(audit[@"draws"][0][@"textures"][1][@"source_key"] == NSNull.null);
    NSError* error = nil;
    assert([NSJSONSerialization dataWithJSONObject:audit options:0 error:&error] && !error);
    textures = [NSMutableDictionary dictionary];
    audit = InterfaceSourceAudit(std::vector<LiveDraw>(260, hud), {}, textures);
    assert([audit[@"draws"] count] == 256 && [audit[@"omitted_orthographic_draws"] unsignedIntValue] == 4);
    size_t count = 0;
    for (NSDictionary* draw in audit[@"draws"]) count += [draw[@"vertices"] count];
    assert(count == 8192 && [audit[@"omitted_vertices"] unsignedIntValue] == 256 * 129 - 8192);
}

static void TestCinematicDrawAdmissionAndAperture() {
    ProtectorCinematicFrame movie{};
    movie.active = true; movie.width = 640; movie.height = 480;
    movie.decoded_frame_one_based = 91; movie.frame_count = 156;
    LiveDraw draw;
    draw.projectionWords[6] = 1; draw.fragment.stageCount = 4; draw.fragment.indirectCount = 3;
    draw.depthMode = 23; draw.blendMode = 285; draw.cullMode = 0;
    draw.fragment.alphaTest = 4128768; draw.indexed = true;
    draw.indices = {0,1,2,0,2,3}; draw.viewportWidth = 640; draw.viewportHeight = 448;
    const u32 colors[4] = {63714,1112288,587968,528623};
    const u32 alphas[4] = {324368,324352,565120,588528};
    const u32 units[4] = {4,3,0,0}, coordinates[4] = {0,0,3,0};
    for (size_t i=0; i<4; ++i) {
        draw.textureWidths[i] = i<2 ? 320 : i==2 ? 640 : 1;
        draw.textureHeights[i] = i<2 ? 240 : i==2 ? 480 : 1;
        draw.textureFormats[i] = i<3 ? 1 : 0; draw.textureModes[i] = 256;
        draw.textureUnits[i] = units[i]; draw.textureCoordinates[i] = coordinates[i];
        draw.fragment.colorCombiners[i] = colors[i]; draw.fragment.alphaCombiners[i] = alphas[i];
        LiveVertex v{};
        v.uv[0][0] = (i==1 || i==2) ? 1 : 0; v.uv[0][1] = i>=2 ? 1 : 0;
        v.position[0] = 2*v.uv[0][0]-1;
        v.position[1] = i<2 ? 1 : 1-2*480.0f/448.0f;
        v.position[2] = 0.00625f; v.position[3] = 1;
        for (float& c : v.color) c = 1;
        draw.vertices.push_back(v);
    }
    assert(IdentifyCinematicDraw({draw},movie)==0);
    assert(IdentifyCinematicDraw({draw,draw},movie)==-1);
    const LiveDraw original = draw;
    for (double aspect : {4.0/3,16.0/9,2.17}) {
      for (double film : {4.0/3,16.0/9}) {
        auto vertices = draw.vertices;
        for (auto& v : vertices) TransformCinematicVertex(&v,aspect,film);
        const double width = vertices[1].position[0]-vertices[0].position[0];
        const double height = vertices[0].position[1]-vertices[2].position[1];
        assert(std::abs(width/height*aspect-film)<0.000001);
        for (const auto& v : vertices) {
            assert(std::abs(v.position[0])<=1 && std::abs(v.position[1])<=1);
            assert(v.position[2]==0.00625f && v.position[3]==1);
        }
      }
    }
    assert(memcmp(original.vertices.data(),draw.vertices.data(),4*sizeof(LiveVertex))==0);
    draw.vertices[2].position[1] = -1; // wrong movie extent, not a permissible approximation
    assert(IdentifyCinematicDraw({draw},movie)==-1);
    draw = original; draw.fragment.alphaCombiners[1]++;
    assert(IdentifyCinematicDraw({draw},movie)==-1);
    draw = original; draw.viewportHeight = 480;
    draw.vertices[2].position[1] = draw.vertices[3].position[1] = -1;
    assert(IdentifyCinematicDraw({draw},movie)==0);
    movie.height = 448;
    for (size_t i=0; i<3; ++i) draw.textureHeights[i] = i<2 ? 224 : 448;
    draw.vertices[2].position[1] = draw.vertices[3].position[1] = 1-2*448.0f/480.0f;
    assert(IdentifyCinematicDraw({draw},movie)==0);
    movie.active = false;
    assert(IdentifyCinematicDraw({draw},movie)==-1);

    LiveEfbCopy copy{}; copy.command = 1u<<14; copy.width = 640; copy.height = 448;
    copy.yScale = 256; copy.drawIndex = 1;
    MTLViewport viewport{};
    assert(CinematicDisplayViewport({copy},1,3,3,&viewport));
    assert(viewport.width==1920 && viewport.height==1344);
    assert(CinematicDisplayViewport({copy},1,5,3,&viewport) && viewport.width==3200 && viewport.height==1344);
    assert(!CinematicDisplayViewport({},1,3,3,&viewport));
    assert(!CinematicDisplayViewport({copy,copy},1,3,3,&viewport));
    assert(!CinematicDisplayViewport({copy},2,3,3,&viewport));
    copy.sourceY = 1;
    assert(!CinematicDisplayViewport({copy},1,3,3,&viewport));
}

static LiveDraw InstrumentationRectangle(float left, float right, float bottom, float top,
                                         bool orthographic, u32 textureSize = 1) {
    LiveDraw draw;
    draw.projectionWords[6] = orthographic ? 1 : 0;
    draw.viewportHeight = 448;
    draw.fragment.stageCount = 1;
    for (size_t stage = 0; stage < 8; ++stage) {
        draw.textureWidths[stage] = draw.textureHeights[stage] = stage ? 1 : textureSize;
        draw.textureRGBA[stage] = {255, 255, 255, 255};
    }
    draw.textureRGBA[0].assign((size_t)textureSize * textureSize * 4, 200);
    const float positions[4][2] = {{left,bottom},{right,bottom},{right,top},{left,top}};
    for (const auto& position : positions) {
        LiveVertex vertex{};
        vertex.position[0] = position[0]; vertex.position[1] = position[1]; vertex.position[3] = 1;
        std::fill(vertex.color, vertex.color + 4, 1);
        draw.vertices.push_back(vertex);
    }
    return draw;
}

static void TestPresentationInstrumentation() {
    // Wide-role summary: counts only, never a role change.
    LiveDraw scene = InstrumentationRectangle(-1,1,-1,1,false);
    LiveDraw shaken = scene; shaken.viewportX = 3; shaken.viewportY = -2;
    LiveDraw resized = scene; resized.viewportHeight = 456;
    LiveDraw shadow = scene; shadow.viewportWidth = shadow.viewportHeight = 256;
    LiveDraw hud = InstrumentationRectangle(-0.9,-0.6,0.4,0.8,true);
    LiveDraw fade = InstrumentationRectangle(-1,1,-1,1,true);
    LiveDraw overlay = InstrumentationRectangle(-1,1,-1,1,true,8);
    LiveDraw shakenHud = hud; shakenHud.viewportX = 3;
    assert(ClassifyWideDraw(shaken) == WideDrawRole::Unchanged);
    assert(ClassifyWideDraw(overlay) == WideDrawRole::SafeArea);
    const std::vector<LiveDraw> frame{scene, shaken, shaken, resized, shadow, hud, fade, overlay, shakenHud};
    const auto summary = SummarizeWideDraws(frame);
    assert(summary.scene == 1 && summary.safeArea == 2 && summary.screenFill == 1 && summary.unchanged == 5);
    assert(summary.unchangedPerspective == 4 && summary.unchangedOrthographic == 1);
    assert(summary.nearMainUnchanged == 4); // Two shaken, one resized, one shaken orthographic.
    assert(summary.fullFrameOverlays == 1); // The textured quad, not the HUD rectangle.
    assert(summary.unchangedViewports.size() == 4 && summary.unchangedViewports[0].draws == 2);
    NSDictionary* receipt = WideFrameReceipt(summary);
    assert([receipt[@"near_main_unchanged"] isEqual:@4] && [receipt[@"unchanged_viewports"] count] == 4);
    assert([NSJSONSerialization isValidJSONObject:receipt]);
    std::vector<LiveDraw> many;
    for (int i = 0; i < 12; ++i) { auto draw = shadow; draw.viewportX = 300 + i; many.push_back(draw); }
    const auto bounded = SummarizeWideDraws(many);
    assert(bounded.unchangedViewports.size() == 8 && bounded.omittedViewports == 4 && !bounded.nearMainUnchanged);
    NSArray* layout = AllDrawLayoutSummary(frame);
    assert(layout.count == frame.size() && [layout[1][@"role"] isEqual:@"unchanged"] &&
        [layout[1][@"viewport"][0] isEqual:@3] && [layout[7][@"role"] isEqual:@"centred-4:3"]);
    assert([NSJSONSerialization isValidJSONObject:layout]);

    // Transition classifier and audit selection.
    PresentationTransitionState admitted{true, true, 0, 0}, lost{false, true, 0, 0}, menu{false, false, 0, 0};
    PresentationTransitionState unwidened{false, true, 4, 0}, flashed{true, true, 0, 1};
    assert(ClassifyPresentationTransition(admitted, admitted) == 0);
    assert(ClassifyPresentationTransition(admitted, lost) == PresentationTransitionHudLost);
    assert(ClassifyPresentationTransition(lost, admitted) == PresentationTransitionHudRestored);
    assert(ClassifyPresentationTransition(admitted, unwidened) ==
        (PresentationTransitionHudLost | PresentationTransitionNearMainAppeared));
    assert(ClassifyPresentationTransition(admitted, flashed) == PresentationTransitionOverlayAppeared);
    assert(PresentationTransitionNeedsAudit(PresentationTransitionHudLost, lost));
    assert(!PresentationTransitionNeedsAudit(PresentationTransitionHudLost, menu)); // Menus: log only.
    assert(PresentationTransitionNeedsAudit(PresentationTransitionNearMainAppeared,
        PresentationTransitionState{false, false, 2, 0}));
    assert(!PresentationTransitionNeedsAudit(PresentationTransitionHudRestored, admitted));
    assert([PresentationTransitionNames(PresentationTransitionHudLost | PresentationTransitionOverlayCleared)
        isEqual:(@[@"hud-lost", @"full-frame-overlay-cleared"])]);

    // Two-segment ring keeps the newest one-to-two segments of records.
    NSFileManager* files = NSFileManager.defaultManager;
    NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"protector-instrumentation-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    assert([files createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:nil]);
    NSError* error = nil;
    assert(![[ProtectorPerformanceRing alloc] initWithDirectory:directory stem:@"bad" recordsPerSegment:1 error:&error]);
    assert(error.code == 36);
    error = nil;
    ProtectorPerformanceRing* ring = [[ProtectorPerformanceRing alloc] initWithDirectory:directory
        stem:@"performance-presentation-test" recordsPerSegment:3 error:&error];
    assert(ring && !error && ring.filenames.count == 2);
    assert(![[ProtectorPerformanceRing alloc] initWithDirectory:directory
        stem:@"performance-presentation-test" recordsPerSegment:3 error:nil]); // Never overwrites.
    for (int sequence = 1; sequence <= 8; ++sequence) {
        NSData* line = [[NSString stringWithFormat:@"{\"sequence\":%d}\n", sequence] dataUsingEncoding:NSUTF8StringEncoding];
        assert([ring writeRecord:line error:&error]);
    }
    assert(ring.totalRecords == 8 && ring.rotations == 2 && ring.activeSegment == 0);
    [ring close];
    NSMutableArray* retained = [NSMutableArray array];
    for (NSString* name in ring.filenames) {
        NSString* text = [NSString stringWithContentsOfURL:[directory URLByAppendingPathComponent:name]
            encoding:NSUTF8StringEncoding error:nil];
        for (NSString* row in [text componentsSeparatedByString:@"\n"]) if (row.length)
            [retained addObject:[NSJSONSerialization JSONObjectWithData:[row dataUsingEncoding:NSUTF8StringEncoding]
                options:0 error:nil][@"sequence"]];
    }
    [retained sortUsingSelector:@selector(compare:)];
    assert([retained isEqual:(@[@4, @5, @6, @7, @8])]);
    assert([[ring receipt][@"files"] isEqual:ring.filenames]);

    // Transition evidence through the renderer: log every change, audit only
    // scene-visible losses, rotate six slots, keep files outside the session.
    setenv("PROTECTOR_HUD_TRANSITION_AUDIT", "1", 1);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    ProtectorLiveMetalRenderer* renderer = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:directory texturePackManifest:nil
        presentationUpgrades:YES error:&error];
    unsetenv("PROTECTOR_HUD_TRANSITION_AUDIT");
    assert(renderer && !error && renderer.presentationTransitionAuditEnabled);
    NativeHudAdmission none;
    NativeHudAdmission hudAdmitted; hudAdmitted.count = 17; hudAdmitted.reason = "source-bound-cluster";
    const std::vector<LiveDraw> evidence{scene, shaken, overlay};
    const std::vector<LiveEfbCopy> copies;
    NSDictionary* wide = WideFrameReceipt(SummarizeWideDraws(evidence));
    assert(PresentationAuditLane(PresentationTransitionHudLost | PresentationTransitionOverlayAppeared) == 0);
    assert(PresentationAuditLane(PresentationTransitionOverlayAppeared) == 2);
    assert(PresentationAuditLane(PresentationTransitionHudRestored) == -1);
    assert(PresentationAuditDue(100, 0) && PresentationAuditDue(102, 100) && !PresentationAuditDue(101.5, 100));
    double now = 1000;
    [renderer notePresentationTransition:admitted frame:10 hud:hudAdmitted wide:wide draws:evidence copies:copies
        antialias:"test" hostSeconds:now];
    assert(renderer.presentationTransitionEvents == 0); // First state primes only.
    [renderer notePresentationTransition:menu frame:11 hud:none wide:wide draws:evidence copies:copies
        antialias:"test" hostSeconds:now];
    assert(renderer.presentationTransitionEvents == 1 && renderer.presentationTransitionAudits == 0);
    for (u32 frame = 12; frame < 28; frame += 2) {
        now += 3;
        [renderer notePresentationTransition:admitted frame:frame hud:hudAdmitted wide:wide draws:evidence
            copies:copies antialias:"test" hostSeconds:now];
        [renderer notePresentationTransition:lost frame:frame + 1 hud:none wide:wide draws:evidence
            copies:copies antialias:"test" hostSeconds:now];
    }
    assert(renderer.presentationTransitionEvents == 17 && renderer.presentationTransitionAudits == 8);
    assert([renderer.lastPresentationTransition[@"transitions"] isEqual:@[@"hud-lost"]]);
    assert([renderer.lastPresentationTransition[@"audit_slot"] isEqual:@1]);
    // A repeat within two seconds is logged but not audited.
    [renderer notePresentationTransition:admitted frame:28 hud:hudAdmitted wide:wide draws:evidence
        copies:copies antialias:"test" hostSeconds:now + 0.25];
    [renderer notePresentationTransition:lost frame:29 hud:none wide:wide draws:evidence
        copies:copies antialias:"test" hostSeconds:now + 0.5];
    assert(renderer.presentationTransitionEvents == 19 && renderer.presentationTransitionAudits == 8);
    assert(renderer.presentationTransitionAuditsSuppressed == 1 &&
        renderer.lastPresentationTransition[@"audit_slot"] == NSNull.null);
    dispatch_sync(renderer.presentationTransitionQueue, ^{});
    assert(renderer.presentationTransitionWriteFailures == 0);
    NSString* log = [NSString stringWithContentsOfURL:[directory URLByAppendingPathComponent:
        [renderer.presentationTransitionLogName stringByAppendingString:@"-ring0.jsonl"]]
        encoding:NSUTF8StringEncoding error:nil];
    assert([log componentsSeparatedByString:@"\n"].count == 20);
    NSArray* slots = [[files contentsOfDirectoryAtPath:directory.path error:nil] filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'presentation-transition-'"]];
    assert(slots.count == 6);
    NSURL* slot1 = [directory URLByAppendingPathComponent:[NSString stringWithFormat:
        @"presentation-transition-%@-slot1", renderer.presentationTransitionSession]];
    NSDictionary* audit = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:
        [slot1 URLByAppendingPathComponent:@"audit.json"]] options:0 error:nil];
    assert([audit[@"frame_index"] isEqual:@27] && [audit[@"all_draws"] count] == 3);
    assert([audit[@"all_draws"][1][@"viewport"][0] isEqual:@3] && [audit[@"draws"] count] == 1);
    NSString* plane = audit[@"draws"][0][@"textures"][0][@"source_key"];
    assert([files fileExistsAtPath:[slot1 URLByAppendingPathComponent:[plane stringByAppendingString:@".rgba"]].path]);
    // The display thread's aspect read is published, not lock-taking, and
    // falls back exactly as before when a status carries no aspect.
    const double fallback = renderer.presentationAspect;
    assert(fallback > 1.3);
    [renderer publishStateCapture:@{@"presentation_aspect_ratio":@2.1741293532338308}];
    assert(renderer.presentationAspect == 2.1741293532338308 && renderer.publishedPresentationAspect > 2);
    [renderer publishStateCapture:@{@"schema":@"no-aspect"}];
    assert(renderer.publishedPresentationAspect == 0 && renderer.presentationAspect == fallback);
    // Memory pressure trim is safe with empty caches and leaves them usable.
    (void)[renderer trimCachesForMemoryPressure];
    assert(renderer.textureCacheBytes == 0 && renderer.textureCache.count == 0);
    renderer = nil;
    [files removeItemAtURL:directory error:nil];
    std::puts("presentation instrumentation: wide summary, transitions, audit slots and ring passed");
}

static void TestMotionPlanOutsideLock() {
    // A correspondence plan computed without the renderer lock must commit
    // exactly what the locked path commits, and a plan made stale by a reset
    // is recomputed rather than applied.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSURL* output = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"protector-motion-plan-test-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    setenv("PROTECTOR_MOTION_PRESENTATION", "1", 1);
    const auto make = [&]() {
        NSError* error = nil;
        ProtectorLiveMetalRenderer* renderer = [[ProtectorLiveMetalRenderer alloc]
            initContinuousWithDevice:device outputDirectory:[output URLByAppendingPathComponent:NSUUID.UUID.UUIDString]
            texturePackManifest:nil presentationUpgrades:YES error:&error];
        assert(renderer && renderer.motionHistory && !error);
        return renderer;
    };
    LiveDraw draw;
    draw.hasMotionSourceKey = true; draw.motionSourceKey.fill(0x52);
    draw.sourceVertexCount = 3; draw.viewportHeight = 448;
    draw.fragment.stageCount = 1;
    for (size_t stage = 0; stage < 8; ++stage) {
        draw.textureWidths[stage] = draw.textureHeights[stage] = 1;
        draw.textureRGBA[stage] = {100,200,50,255};
    }
    const float positions[3][2] = {{-0.5,-0.3},{0.5,-0.3},{0,0.5}};
    for (const auto& position : positions) {
        LiveVertex vertex{};
        vertex.position[0] = position[0]; vertex.position[1] = position[1]; vertex.position[3] = 1;
        std::fill(vertex.color, vertex.color + 4, 1);
        draw.vertices.push_back(vertex);
    }
    auto moved = draw;
    for (auto& vertex : moved.vertices) vertex.position[0] += 0.2f;
    LiveEfbCopy display;
    display.drawIndex = 1; display.width = 640; display.height = 448;
    display.command = 1u << 14u; display.yScale = 256;
    const u64 tickStep = 2025000;
    const double second = 8 + 1.0 / 30.0;
    const auto stage = [&](ProtectorLiveMetalRenderer* renderer, const LiveDraw& source, u32 index, double deadline,
                           bool planned, bool resetBetween) {
        std::vector<LiveDraw> draws{source}; std::vector<LiveEfbCopy> copies{display};
        if (!planned) {
            [renderer stageMotionDraws:draws copies:copies frame:index guestTicks:index * tickStep deadline:deadline];
            return;
        }
        MotionStagePlan plan = PlanMotionStage(*static_cast<ArtworkPreviewFrame*>(renderer.artworkPreviewFrame),
            [renderer motionStageInputs], draws, copies, index, index * tickStep, deadline);
        assert(plan.ready && plan.matchedDraws == 1);
        if (resetBetween) [renderer resetMotionHistory];
        [renderer stageMotionDraws:draws copies:copies frame:index guestTicks:index * tickStep deadline:deadline plan:&plan];
    };
    ProtectorLiveMetalRenderer* locked = make();
    ProtectorLiveMetalRenderer* unlocked = make();
    stage(locked, draw, 1, 8, false, false); stage(locked, moved, 2, second, false, false);
    stage(unlocked, draw, 1, 8, false, false); stage(unlocked, moved, 2, second, true, false);
    const auto& a = *static_cast<MotionPresentationHistory*>(locked.motionHistory);
    const auto& b = *static_cast<MotionPresentationHistory*>(unlocked.motionHistory);
    assert(a.ready && b.ready && !strcmp(a.holdReason, b.holdReason) && a.matches == b.matches);
    assert(a.interval == b.interval && a.matchedDraws == b.matchedDraws && a.sceneDraws == b.sceneDraws);
    assert(a.previous.index == b.previous.index && a.sourceFrames == b.sourceFrames);
    assert(MotionVertexDigest(static_cast<ArtworkPreviewFrame*>(locked.artworkPreviewFrame)->draws).length &&
        [MotionVertexDigest(static_cast<ArtworkPreviewFrame*>(locked.artworkPreviewFrame)->draws)
            isEqual:MotionVertexDigest(static_cast<ArtworkPreviewFrame*>(unlocked.artworkPreviewFrame)->draws)]);
    // Stale plan: a reset between planning and commit forces the locked
    // recomputation, which sees the cleared deadline and holds.
    ProtectorLiveMetalRenderer* reset = make();
    stage(reset, draw, 1, 8, false, false); stage(reset, moved, 2, second, true, true);
    const auto& c = *static_cast<MotionPresentationHistory*>(reset.motionHistory);
    assert(!c.ready && !strcmp(c.holdReason, "clock-discontinuity") && c.matches.empty());
    unsetenv("PROTECTOR_MOTION_PRESENTATION");
    [NSFileManager.defaultManager removeItemAtURL:output error:nil];
    // Reusing one blended copy across presentations is bit-identical to a
    // fresh blend at every fraction, including the exact endpoint.
    {
        auto& history = *static_cast<MotionPresentationHistory*>(unlocked.motionHistory);
        const auto& endpoint = *static_cast<ArtworkPreviewFrame*>(unlocked.artworkPreviewFrame);
        std::vector<LiveDraw> reused;
        bool prepared = false;
        for (double fraction : {0.25, 0.0, 0.8, 1.0, 0.5, 0.999}) {
            std::vector<LiveDraw> fresh;
            assert(BlendMotionDraws(history.previous, endpoint.draws, history.matches, fraction, &fresh));
            assert(BlendMotionDrawsInto(history.previous, endpoint.draws, history.matches, fraction, &reused, prepared));
            prepared = true;
            assert([MotionVertexDigest(fresh) isEqual:MotionVertexDigest(reused)]);
        }
    }
    std::puts("motion plan off-lock commit equals locked path; stale plans recompute");
}

static void TestShadowWindowRedirect() {
    // Synthetic RBNEG9-shaped frame: scene, copy A (corner), clear quad,
    // silhouette, copy B (mask), restore from A, receiver sampling B, display.
    const auto quad = [](float l, float r, float b, float t, bool ortho, u8 red, u8 green, u8 blue) {
        LiveDraw draw;
        draw.projectionWords[6] = ortho ? 1 : 0;
        draw.viewportHeight = 448;
        draw.sourceVertexCount = 6;
        draw.fragment.stageCount = 1;
        draw.fragment.colorCombiners[0] = 0x80000u | 0xF8DFu;
        draw.fragment.alphaCombiners[0] = 0x80000u | (7u << 13u) | (7u << 10u) | (7u << 7u) | (4u << 4u);
        draw.fragment.textureAlphaChannels[0] = 3;
        for (size_t stage = 0; stage < 8; ++stage) {
            draw.textureWidths[stage] = draw.textureHeights[stage] = 1;
            draw.textureRGBA[stage] = {red, green, blue, 255};
            std::fill(draw.fragment.textureDimensions[stage], draw.fragment.textureDimensions[stage] + 4, 1.0f);
        }
        const float corners[6][4] = {{l,b,0,1},{r,b,1,1},{l,t,0,0},{l,t,0,0},{r,b,1,1},{r,t,1,0}};
        for (const auto& c : corners) {
            LiveVertex vertex{};
            vertex.position[0] = c[0]; vertex.position[1] = c[1]; vertex.position[3] = 1;
            vertex.uv[0][0] = c[2]; vertex.uv[0][1] = c[3];
            std::fill(vertex.color, vertex.color + 4, 1);
            draw.vertices.push_back(vertex);
        }
        return draw;
    };
    const u32 tileAddress = 268503456, maskAddress = 268437600;
    LiveDraw scene = quad(-1, 1, -1, 1, false, 30, 90, 160);
    LiveDraw clear = quad(-1, 1, -1, 1, true, 255, 255, 255);
    LiveDraw silhouette = quad(-0.4f, 0.4f, -0.6f, 0.6f, false, 0, 0, 0);
    LiveDraw restore = quad(-1, 1, -1, 1, true, 0, 0, 0);
    for (LiveDraw* draw : {&clear, &silhouette, &restore}) {
        draw->viewportWidth = draw->viewportHeight = 256;
        draw->depthMode = 14;
    }
    clear.blendMode = restore.blendMode = 12604;
    clear.fragment.alphaTest = restore.fragment.alphaTest = 4128768;
    restore.fragment.colorCombiners[0] = 589816; restore.fragment.alphaCombiners[0] = 589792;
    restore.textureAddresses[0] = tileAddress;
    restore.textureWidths[0] = restore.textureHeights[0] = 256;
    restore.textureRGBA[0].assign(256 * 256 * 4, 0);
    LiveDraw receiver = quad(-1, 1, -1, 1, false, 255, 255, 255);
    receiver.textureAddresses[0] = maskAddress;
    receiver.textureWidths[0] = receiver.textureHeights[0] = 256;
    receiver.textureRGBA[0].assign(256 * 256 * 4, 0);
    LiveDraw overlay = quad(-0.9f, -0.5f, 0.5f, 0.9f, true, 200, 40, 40); // HUD-like draw over the corner
    const std::vector<LiveDraw> draws{scene, clear, silhouette, restore, receiver, overlay};
    LiveEfbCopy tile; tile.drawIndex = 1; tile.width = tile.height = 256; tile.command = 0x10063;
    tile.yScale = 256; tile.destinationAddress = tileAddress;
    LiveEfbCopy mask = tile; mask.drawIndex = 3; mask.command = 0x1000B; mask.destinationAddress = maskAddress;
    LiveEfbCopy display; display.drawIndex = draws.size(); display.width = 640; display.height = 448;
    display.command = 1u << 14u; display.yScale = 256;
    const std::vector<LiveEfbCopy> copies{tile, mask, display};

    // Pure eligibility, each condition flipped falls back with its reason.
    const auto plan = PlanShadowWindow(draws, copies, SIZE_MAX, -1);
    assert(plan.eligible && plan.copyA == 0 && plan.copyB == 1 && plan.first == 1 && plan.restore == 3);
    const auto reason = [&](std::vector<LiveDraw> d, std::vector<LiveEfbCopy> c, size_t aa = SIZE_MAX) {
        const auto result = PlanShadowWindow(d, c, aa, -1);
        assert(!result.eligible);
        return std::string(result.reason);
    };
    { auto d = draws; d[2].depthMode = 15; assert(reason(d, copies) == "window-depth"); }
    { auto d = draws; d[2].viewportX = 1; assert(reason(d, copies) == "window-viewport"); }
    { auto d = draws; d[2].textureAddresses[0] = tileAddress; d[2].textureWidths[0] = d[2].textureHeights[0] = 256;
      assert(reason(d, copies) == "window-samples-copy"); }
    { auto d = draws; d[1].blendMode = 12605; assert(reason(d, copies) == "window-not-initialised"); }
    { auto d = draws; d[1].vertices[0].position[0] = -0.9f; assert(reason(d, copies) == "window-not-initialised"); }
    { auto d = draws; d[3].fragment.colorCombiners[0] ^= 1; assert(reason(d, copies) == "restore-not-copy"); }
    { auto d = draws; d[3].vertices[1].uv[0][0] = 0.5f; assert(reason(d, copies) == "restore-not-copy"); }
    { auto d = draws; d[4].textureAddresses[1] = tileAddress; d[4].textureWidths[1] = d[4].textureHeights[1] = 256;
      assert(reason(d, copies) == "copy-a-other-consumer"); }
    { assert(reason(draws, copies, 2) == "boundary-inside-window"); }
    { auto d = draws; d[5].blendMode = 1u | (6u << 5); assert(reason(d, copies) == "later-destination-alpha"); }
    { auto c = copies; auto extra = tile; extra.drawIndex = 5; extra.destinationAddress = 1;
      c.insert(c.begin() + 2, extra); assert(reason(draws, c) == "later-efb-copy"); }
    { auto c = copies; c[1].command = 0x1000A; assert(!PlanShadowWindow(draws, c, SIZE_MAX, -1).eligible); }

    // GPU: the same frame rendered live with and without the redirect has
    // identical colour everywhere (the corner keeps scene alpha, which no
    // later draw or copy reads, as conditions 7-8 guarantee).
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSURL* output = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"protector-shadow-window-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    NSError* error = nil;
    ProtectorLiveMetalRenderer* renderer = [[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:device outputDirectory:output texturePackManifest:nil
        presentationUpgrades:YES error:&error];
    assert(renderer && !error);
    auto* preview = static_cast<ArtworkPreviewFrame*>(renderer.artworkPreviewFrame);
    preview->draws = draws; preview->copies = copies; preview->index = 7; preview->valid = true;
    assert([renderer selectNativeRenderSize:CGSizeMake(1920, 672) error:&error] && !error);
    assert(renderer.renderScale == 3 && renderer.renderScaleY == 2);
    const auto render = [&](BOOL redirect) {
        renderer.shadowWindowRedirectEnabled = redirect;
        renderer.asynchronousPresentationRender = YES;
        NSError* failure = nil;
        assert([renderer renderDraws:draws efbCopies:copies frame:7 error:&failure] && !failure);
        renderer.asynchronousPresentationRender = NO;
        [renderer.latestRenderCommand waitUntilCompleted];
        id<MTLTexture> picture = ReadableTexture(renderer.latestPresentationTexture, &failure);
        assert(picture && !failure && picture.width == 1920 && picture.height == 896);
        std::vector<u8> bytes(picture.width * picture.height * 4);
        [picture getBytes:bytes.data() bytesPerRow:picture.width * 4
            fromRegion:MTLRegionMake2D(0, 0, picture.width, picture.height) mipmapLevel:0];
        return bytes;
    };
    const auto original = render(NO);
    assert(![renderer.stateCapture[@"shadow_window"][@"elided"] boolValue]);
    const auto redirected = render(YES);
    assert([renderer.stateCapture[@"shadow_window"][@"elided"] boolValue]);
    assert([renderer.stateCapture[@"shadow_window"][@"reason"] isEqual:@"elided"]);
    size_t differing = 0, shadowPixels = 0;
    for (size_t i = 0; i < original.size(); i += 4) {
        if (memcmp(&original[i], &redirected[i], 3)) ++differing;
        if (original[i] != original[(original.size() / 2) & ~(size_t)3]) ++shadowPixels;
    }
    assert(differing == 0);
    assert(shadowPixels > 0); // the receiver really shows the mask, not a flat frame
    [NSFileManager.defaultManager removeItemAtURL:output error:nil];
    std::puts("shadow window redirect: 12 fallback conditions; live 3x2 render colour-identical to the copy/restore path");
}

static void TestCinematicSurroundProtectedPixels() {
    assert(!CinematicSurround(false,true,true,2.17).enabled);
    assert(!CinematicSurround(true,false,true,2.17).enabled);
    assert(!CinematicSurround(true,true,true,NAN).enabled);
    assert(!CinematicSurround(true,true,true,4).enabled);
    assert(!CinematicSurround(true,true,true,16.0/9).enabled);
    const auto phone = CinematicSurround(true,true,true,2.17);
    const auto tablet = CinematicSurround(true,true,true,4.0/3);
    assert(phone.enabled && phone.scaleY == 1 && phone.scaleX < 1);
    assert(tablet.enabled && tablet.scaleX == 1 && std::abs(tablet.scaleY-.75f)<0.000001f);
    const auto source = CinematicSurround(true,true,false,2.17);
    assert(source.enabled && source.scaleX < phone.scaleX && source.scaleY == 1);
    const auto complete = CinematicSurround(true,true,true,2.17,4.0/3);
    assert(complete.scaleX == source.scaleX && complete.scaleY == source.scaleY);
    assert(!CinematicSurround(true,true,true,4.0/3,4.0/3).enabled);
    assert(!CinematicSurround(true,true,true,2.17,NAN).enabled);
    assert(!CinematicSurround(true,true,true,2.17,0).enabled);

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:[ProtectorLiveShaderSource
        stringByAppendingString:@(ProtectorCinematicSurroundShader)] options:nil error:&error];
    if (!library) fprintf(stderr,"Surround shader: %s\n",error.localizedDescription.UTF8String);
    assert(library && !error);
    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"live_present_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"live_cinematic_surround_fragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    assert(pipeline && !error);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    size_t protectedPixels = 0;
    for (auto size : {std::array<NSUInteger,2>{436,200}, {320,240}, {384,216}}) {
        for (int mode : {0,1,2}) {
            const bool restored = mode != 0;
            const double film = mode == 2 ? 4.0/3 : 16.0/9;
            const auto layout = CinematicSurround(true,true,restored,(double)size[0]/size[1],film);
            auto textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                width:size[0] height:size[1] mipmapped:NO];
            textureDescriptor.storageMode = MTLStorageModeShared;
            textureDescriptor.usage = MTLTextureUsageRenderTarget;
            id<MTLTexture> output = [device newTextureWithDescriptor:textureDescriptor];
            MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = output;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(1,0,1,1);
            id<MTLCommandBuffer> command = [queue commandBuffer];
            id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
            const float full[2] = {1,1};
            const float aperture[4] = {layout.scaleX,layout.scaleY,layout.frameAspect,(float)size[1]};
            [encoder setRenderPipelineState:pipeline];
            [encoder setVertexBytes:full length:sizeof(full) atIndex:0];
            [encoder setFragmentBytes:aperture length:sizeof(aperture) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
            assert(command.status == MTLCommandBufferStatusCompleted && !command.error);
            std::vector<u8> pixels(size[0]*size[1]*4);
            [output getBytes:pixels.data() bytesPerRow:size[0]*4
                fromRegion:MTLRegionMake2D(0,0,size[0],size[1]) mipmapLevel:0];
            size_t changedOutside = 0;
            for (NSUInteger y=0;y<size[1];++y) for (NSUInteger x=0;x<size[0];++x) {
                const float nx=2*((float)x+.5f)/(float)size[0]-1;
                const float ny=2*((float)y+.5f)/(float)size[1]-1;
                const u8* pixel = pixels.data()+(y*size[0]+x)*4;
                const bool unchanged = pixel[0]==255 && pixel[1]==0 && pixel[2]==255 && pixel[3]==255;
                if (std::abs(nx)<=layout.scaleX-.00001f && std::abs(ny)<=layout.scaleY-.00001f) {
                    assert(unchanged); ++protectedPixels;
                } else if (!unchanged) ++changedOutside;
            }
            assert((changedOutside > 0)==layout.enabled);
        }
    }
    std::printf("Cinematic surround GPU protected pixels unchanged: %zu; 9 aspect/source cases\n",protectedPixels);
}

static void TestGalleryModelFrame() {
    assert(!IdentifyGalleryModelFrame({},{}).enabled);
    GalleryLayoutAdmission gallery;
    gallery.enabled=true; gallery.extrasBrowser=true; gallery.extrasFullView=true; gallery.extrasItems=11;
    auto fromTuple=[](const GalleryModelTuple& tuple) {
        LiveDraw draw;
        draw.projectionWords={1071518207,0,1075748644,0,3131313033,3212847363,0};
        draw.viewportWidth=640;draw.viewportHeight=448;draw.displayListDepth=1;
        draw.hasNormal=tuple.normal;draw.blendMode=tuple.blend;draw.depthMode=tuple.depth;
        draw.cullMode=tuple.cull;draw.fragment.alphaTest=tuple.alphaTest;draw.fragment.stageCount=tuple.stages;
        for(size_t i=0;i<tuple.stages;++i) {
            draw.fragment.colorCombiners[i]=tuple.colors[i];draw.fragment.alphaCombiners[i]=tuple.alphas[i];
        }
        LiveVertex v{};v.position[0]=2;v.position[1]=-3;v.position[2]=2;v.position[3]=5;
        v.color[0]=.3f;v.uv[1][0]=.7f;draw.vertices.push_back(v);return draw;
    };
    for(unsigned profile:{51u,53u}) {
        std::vector<LiveDraw> draws;
        std::vector<const GalleryModelTuple*> tuples;
        for(const auto& tuple:kGalleryModelTuples) if(tuple.family<=1 || tuple.family==profile) {
            draws.push_back(fromTuple(tuple));tuples.push_back(&tuple);
        }
        gallery.first=draws.size();
        auto key=[&](size_t i,size_t stage)->NSString*{return tuples[i]->keys[stage];};
        auto admitted=IdentifyGalleryModelFrameWithKeys(draws,gallery,key);
        assert(admitted.enabled && admitted.profile==profile && admitted.modelDraws && admitted.roomDraws);
        const auto digest=MotionVertexDigest(draws);
        for(double aspect:{4.0/3.0,16.0/9.0,2622.0/1206.0,3.0}) {
            for(size_t i=0;i<draws.size();++i) {
                auto copy=draws[i].vertices[0],before=copy;
                if(admitted.contains(i)) {
                    TransformGalleryModelVertex(&copy,admitted,aspect);
                    assert(std::abs(copy.position[0]-before.position[0]*admitted.scale*(4.0/3.0)/aspect)<.00001);
                    assert(std::abs(copy.position[1]-before.position[1]*admitted.scale-admitted.centerY*before.position[3])<.00001);
                    copy.position[0]=before.position[0];copy.position[1]=before.position[1];
                }
                assert(memcmp(&copy,&before,sizeof(copy))==0);
                assert(admitted.contains(i)==(tuples[i]->family!=0));
            }
        }
        assert([digest isEqual:MotionVertexDigest(draws)]);
        for(double aspect:{(double)NAN,(double)INFINITY,1.0,3.1}) {
            auto copy=draws[0].vertices[0],before=copy;
            TransformGalleryModelVertex(&copy,admitted,aspect);assert(memcmp(&copy,&before,sizeof(copy))==0);
        }
        auto disabled=gallery;disabled.enabled=false;
        assert(!IdentifyGalleryModelFrameWithKeys(draws,disabled,key).enabled);
        disabled=gallery;disabled.extrasFullView=false;
        assert(!IdentifyGalleryModelFrameWithKeys(draws,disabled,key).enabled);
        disabled=gallery;disabled.extrasMovie=true;
        assert(!IdentifyGalleryModelFrameWithKeys(draws,disabled,key).enabled);
        for(size_t items:{0u,14u,20u,30u}) {
            disabled=gallery;disabled.extrasItems=items;
            assert(!IdentifyGalleryModelFrameWithKeys(draws,disabled,key).enabled);
        }
        assert(!IdentifyGalleryModelFrameWithKeys(draws,gallery,[&](size_t i,size_t stage)->NSString*{
            return i==0 && stage==0 ? @"unknown" : key(i,stage);
        }).enabled);
        for(size_t i=0;i<draws.size();++i) {
            auto altered=draws;altered[i].projectionWords[0]^=1;
            assert(!IdentifyGalleryModelFrameWithKeys(altered,gallery,key).enabled);
            altered=draws;altered[i].fragment.colorCombiners[0]^=1;
            assert(!IdentifyGalleryModelFrameWithKeys(altered,gallery,key).enabled);
            altered=draws;altered[i].viewportHeight=480;
            assert(!IdentifyGalleryModelFrameWithKeys(altered,gallery,key).enabled);
            altered=draws;altered[i].vertices[0].position[0]=NAN;
            assert(!IdentifyGalleryModelFrameWithKeys(altered,gallery,key).enabled);
            altered=draws;altered[i].vertices.clear();
            assert(!IdentifyGalleryModelFrameWithKeys(altered,gallery,key).enabled);
        }
        auto altered=draws;altered[0].vertices.resize(65537,altered[0].vertices[0]);
        assert(!IdentifyGalleryModelFrameWithKeys(altered,gallery,key).enabled);
        auto withoutRoom=gallery;withoutRoom.first=0;
        assert(!IdentifyGalleryModelFrameWithKeys(draws,withoutRoom,key).enabled);
    }

    const char* path=getenv("PROTECTOR_GALLERY_MODEL_SOURCE_AUDIT");
    if(!path || !path[0])return;
    NSData* data=[NSData dataWithContentsOfFile:@(path)];
    assert(data && data.length<32*1024*1024);
    NSDictionary* audit=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    assert([audit[@"schema"] isEqual:@"protector-native.gallery-model-source-audit/v1"]);
    assert([audit[@"status"] isEqual:@"complete-perspective-sequence"]);
    NSArray* records=audit[@"draws"];
    std::vector<LiveDraw> draws;
    for(NSDictionary* record in records) {
        LiveDraw draw;
        for(size_t i=0;i<7;++i)draw.projectionWords[i]=[record[@"projection_words"][i] unsignedIntValue];
        NSArray* viewport=record[@"viewport"];
        draw.viewportX=[viewport[0] doubleValue];draw.viewportY=[viewport[1] doubleValue];
        draw.viewportWidth=[viewport[2] doubleValue];draw.viewportHeight=[viewport[3] doubleValue];
        draw.displayListDepth=[record[@"display_list_depth"] unsignedIntValue];
        draw.hasNormal=[record[@"has_normal"] boolValue];
        draw.blendMode=[record[@"blend_mode"] unsignedIntValue];draw.depthMode=[record[@"depth_mode"] unsignedIntValue];
        draw.cullMode=[record[@"cull_mode"] unsignedIntValue];draw.fragment.alphaTest=[record[@"alpha_test"] unsignedIntValue];
        draw.fragment.indirectCount=[record[@"indirect_count"] unsignedIntValue];
        draw.fragment.stageCount=[record[@"stage_count"] unsignedIntValue];
        for(NSDictionary* stage in record[@"stages"]) {
            size_t i=[stage[@"stage"] unsignedIntegerValue];
            draw.fragment.colorCombiners[i]=[stage[@"color_combiner"] unsignedIntValue];
            draw.fragment.alphaCombiners[i]=[stage[@"alpha_combiner"] unsignedIntValue];
        }
        for(NSArray* position in record[@"clip_positions"]) {
            LiveVertex vertex{};
            for(size_t i=0;i<4;++i)vertex.position[i]=[position[i] floatValue];
            draw.vertices.push_back(vertex);
        }
        draws.push_back(draw);
    }
    gallery.first=draws.size();
    const auto original=MotionVertexDigest(draws);
    // This replay checks recorded exact source keys/geometry. Actual RGBA key
    // hashing and the full UI admission are exercised in native observations.
    const auto frame=IdentifyGalleryModelFrameWithKeys(draws,gallery,[&](size_t i,size_t stage)->NSString*{
        return records[i][@"stages"][stage][@"source_key"];
    });
    assert(frame.enabled && (frame.profile==51 || frame.profile==53));
    for(double aspect:{4.0/3.0,16.0/9.0,2622.0/1206.0,3.0}) {
        NSDictionary* receipt=GalleryModelFrameReceipt(draws,frame,aspect);
        assert([receipt[@"outside_viewport_vertices"] unsignedIntegerValue]==0);
        assert([receipt[@"behind_camera_vertices"] unsignedIntegerValue]==0);
        assert([receipt[@"source_vertices"] unsignedIntegerValue]>10000);
        NSArray* bounds=receipt[@"ndc_bounds"];
        for(NSNumber* value in bounds)assert(std::abs(value.floatValue)<.9f);
    }
    assert([original isEqual:MotionVertexDigest(draws)]);
    std::printf("Gallery framing recorded source replay: profile %u, %zu model and %zu room draws; four aspect bounds passed\n",
        frame.profile,frame.modelDraws,frame.roomDraws);
}


static void TestFrontendSourceAudit() {
    const char* path = getenv("PROTECTOR_FRONTEND_SOURCE_AUDIT");
    bool galleryAudit = false;
    if (!path || !path[0]) { path = getenv("PROTECTOR_GALLERY_SOURCE_AUDIT"); galleryAudit = true; }
    bool browserAudit = false;
    if (!path || !path[0]) { path = getenv("PROTECTOR_EXTRAS_BROWSER_SOURCE_AUDIT"); browserAudit = true; }
    bool movieAudit = false;
    if (!path || !path[0]) { path = getenv("PROTECTOR_EXTRAS_MOVIE_SOURCE_AUDIT"); movieAudit = path && path[0]; }
    bool optionsAudit = false;
    if (!path || !path[0]) { path = getenv("PROTECTOR_EXTRAS_OPTIONS_SOURCE_AUDIT"); optionsAudit = true; browserAudit = false; }
    bool comboAudit = false;
    if (!path || !path[0]) { path = getenv("PROTECTOR_COMBO_SOURCE_AUDIT"); comboAudit = true; }
    bool combatAudit=false;
    if (!path || !path[0]) { path=getenv("PROTECTOR_COMBAT_FEEDBACK_SOURCE_AUDIT");combatAudit=true;comboAudit=false; }
    bool upgradeAudit=false;
    if (!path || !path[0]) { path=getenv("PROTECTOR_UPGRADE_SOURCE_AUDIT");upgradeAudit=true;combatAudit=false; }
    bool hudAudit=false;
    if (!path || !path[0]) { path=getenv("PROTECTOR_HUD_SOURCE_AUDIT");hudAudit=true;upgradeAudit=false; }
    bool mapAudit=false;
    if (!path || !path[0]) { path=getenv("PROTECTOR_WORLD_MAP_SOURCE_AUDIT");mapAudit=true;hudAudit=false; }
    bool moveAudit=false;
    if (!path || !path[0]) { path=getenv("PROTECTOR_MOVE_LABEL_SOURCE_AUDIT");moveAudit=true;mapAudit=false; }
    if (!path || !path[0]) return;
    NSString* auditPath = @(path);
    NSData* bytes = [NSData dataWithContentsOfFile:auditPath];
    assert(bytes && bytes.length < 8*1024*1024);
    NSDictionary* audit = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    assert([audit[@"schema"] isEqual:@"protector-native.interface-source-audit/v1"]);
    assert([audit[@"source"] isEqual:@"translated_execution_callback"] ||
        (hudAudit && [audit[@"admission"] isEqual:@"unrecognized-cluster-layer"] &&
         [audit[@"source_vertices_immutable"] boolValue]));
    assert([audit[@"omitted_vertices"] unsignedIntegerValue] == 0);
    assert([audit[@"omitted_orthographic_draws"] unsignedIntegerValue] == 0);
    NSArray* records = audit[@"draws"];
    const size_t first = movieAudit ? 1 : galleryAudit ? [records[0][@"draw_index"] unsignedIntegerValue] : 0;
    assert((hudAudit || comboAudit || upgradeAudit || combatAudit || moveAudit || records.count+(movieAudit ? 0 : first) == [audit[@"total_draws"] unsignedIntegerValue]) && records.count <= ((combatAudit || moveAudit) ? 256u : 192u));
    std::vector<LiveDraw> draws;
    if (galleryAudit && !movieAudit) {
        // This bounded audit serializes only orthographic draws. Reconstruct
        // the unmodified prefix as classification placeholders, not room art.
        if(!hudAudit && !comboAudit && !upgradeAudit && !combatAudit && !moveAudit) assert(first == [audit[@"render_state"][@"widescreen_scene_draws"] unsignedIntegerValue]);
        draws.resize(first);
        for (const auto& draw : draws) assert(ClassifyWideDraw(draw) == WideDrawRole::Scene);
    }
    size_t totalBytes = 0;
    std::map<std::string,std::shared_ptr<const std::vector<u8>>> textures;
    for (NSDictionary* record in records) {
        if(hudAudit || comboAudit || upgradeAudit || combatAudit || moveAudit)draws.resize([record[@"draw_index"] unsignedIntegerValue]);
        assert([record[@"draw_index"] unsignedIntegerValue] == draws.size());
        LiveDraw draw;
        draw.indexed = [record[@"indexed"] boolValue];
        draw.blendMode = [record[@"blend_mode"] unsignedIntValue];
        draw.depthMode = [record[@"depth_mode"] unsignedIntValue];
        draw.fragment.alphaTest = [record[@"alpha_test"] unsignedIntValue];
        NSArray* viewport = record[@"viewport"];
        draw.viewportX = [viewport[0] doubleValue]; draw.viewportY = [viewport[1] doubleValue];
        draw.viewportWidth = [viewport[2] doubleValue]; draw.viewportHeight = [viewport[3] doubleValue];
        for (NSUInteger i=0; i<7; ++i) draw.projectionWords[i] = [record[@"projection_words"][i] unsignedIntValue];
        for (NSNumber* index in record[@"indices"]) draw.indices.push_back(index.unsignedIntValue);
        for (NSDictionary* source in record[@"vertices"]) {
            LiveVertex vertex{};
            for (NSUInteger i=0; i<4; ++i) {
                vertex.position[i] = [source[@"clip"][i] floatValue];
                vertex.color[i] = [source[@"color"][i] floatValue];
                for (NSUInteger axis=0; axis<2; ++axis) vertex.uv[i][axis] = [source[@"uv"][i][axis] floatValue];
            }
            draw.vertices.push_back(vertex);
        }
        for (NSDictionary* texture in record[@"textures"]) {
            const size_t stage = draw.fragment.stageCount++;
            assert(stage < (movieAudit && draws.empty() ? 4u : 2u) && [texture[@"stage"] unsignedIntegerValue] == stage);
            NSString* sourceKey = texture[@"source_key"];
            assert([sourceKey.lastPathComponent isEqual:sourceKey] && [texture[@"pixels_included"] boolValue]);
            auto found = textures.find(sourceKey.UTF8String);
            if (found == textures.end()) {
                NSData* data = [NSData dataWithContentsOfFile:[[auditPath stringByDeletingLastPathComponent]
                    stringByAppendingPathComponent:[sourceKey stringByAppendingString:@".rgba"]]];
                assert(data && data.length <= 16*1024*1024);
                totalBytes += data.length; assert(totalBytes <= 64*1024*1024);
                const auto* begin = static_cast<const u8*>(data.bytes);
                found = textures.emplace(sourceKey.UTF8String,std::make_shared<const std::vector<u8>>(begin,begin+data.length)).first;
            }
            draw.decodedPixels[stage] = found->second;
            draw.textureWidths[stage] = [texture[@"width"] unsignedIntValue];
            draw.textureHeights[stage] = [texture[@"height"] unsignedIntValue];
            draw.textureFormats[stage] = [texture[@"gx_format"] unsignedIntValue];
            draw.textureModes[stage] = [texture[@"gx_mode"] unsignedIntValue];
            draw.textureCoordinates[stage] = [texture[@"uv_set"] unsignedIntValue];
            draw.textureUnits[stage] = [texture[@"texture_unit"] unsignedIntValue];
            draw.fragment.colorCombiners[stage] = [texture[@"color_combiner"] unsignedIntValue];
            draw.fragment.alphaCombiners[stage] = [texture[@"alpha_combiner"] unsignedIntValue];
            assert([sourceKey isEqual:InterfaceTextureKey(TexturePixels(draw,stage),draw.textureWidths[stage],draw.textureHeights[stage])]);
        }
        int profile = FrontendProfileForKeys(InterfaceTextureKey(TexturePixels(draw,0),draw.textureWidths[0],draw.textureHeights[0]),
            draw.fragment.stageCount == 2 ? InterfaceTextureKey(TexturePixels(draw,1),draw.textureWidths[1],draw.textureHeights[1]) : nil);
        if (!galleryAudit && (profile < 0 || !FrontendDrawStateMatches(draw,kFrontendTextures[profile].role,kFrontendTextures[profile].blend)))
            std::fprintf(stderr,"Frontend source mismatch at draw %zu profile %d\n",draws.size(),profile);
        if (!galleryAudit) assert(profile >= 0 && FrontendDrawStateMatches(draw,kFrontendTextures[profile].role,kFrontendTextures[profile].blend));
        draws.push_back(draw);
    }
    std::vector<LiveEfbCopy> copies;
    for (NSDictionary* copy in audit[@"copy_layout"][@"copies"]) {
        LiveEfbCopy value;
        value.drawIndex = [copy[@"draw_index"] unsignedIntegerValue];
        value.command = [copy[@"command"] unsignedIntValue]; value.yScale = [copy[@"y_scale"] unsignedIntValue];
        value.sourceX = [copy[@"source_x"] unsignedIntValue]; value.sourceY = [copy[@"source_y"] unsignedIntValue];
        value.width = [copy[@"width"] unsignedIntValue]; value.height = [copy[@"height"] unsignedIntValue];
        copies.push_back(value);
    }
    if(mapAudit) {
        const auto before=MotionVertexDigest(draws);
        assert(IdentifyWorldMap(draws,copies));
        const auto admitted=IdentifyMapLayout(draws,copies);
        const bool detail=[auditPath containsString:@"detail"]||[auditPath containsString:@"source-zoom"];
        std::printf("Map source audit: %s, region %d, selected %d, %zu draws, last %zu\n",
            admitted.reason,admitted.region,admitted.selected,draws.size(),admitted.rejectedDraw);
        std::fflush(stdout);
        assert(admitted.enabled!=detail);
        if(detail) {
            for(const auto size:{CGSizeMake(874,402),CGSizeMake(1376,1032)}) {
                const auto backdrop=PlanMapDetailBackdrop(draws,true,size);
                assert(backdrop.enabled);
                auto first=draws[0].vertices[0],last=draws[19].vertices[2];
                TransformMapDetailBackdrop(&first,backdrop);TransformMapDetailBackdrop(&last,backdrop);
                assert(first.position[0]<=-1+.0001&&first.position[1]>=1-.0001);
                assert(last.position[0]>=1-.0001&&last.position[1]<=-1+.0001);
                for(size_t i=0;i<29;++i)for(const auto& source:draws[i].vertices) {
                    auto v=source;TransformMapDetailBackdrop(&v,backdrop);
                    assert(v.position[2]==source.position[2]&&v.position[3]==source.position[3]);
                    assert(!memcmp(v.color,source.color,sizeof(v.color))&&!memcmp(v.uv,source.uv,sizeof(v.uv)));
                }
                auto changed=draws;changed[24].vertices[0].color[3]=1;
                assert(!PlanMapDetailBackdrop(changed,true,size).enabled);
                assert(!PlanMapDetailBackdrop(draws,false,size).enabled);
            }
        } else if(admitted.country) {
            for(const auto size:{CGSizeMake(874,402),CGSizeMake(1376,1032)})
                for(bool swapped:{false,true}) {
                    ProtectorMapContentLayout content;
                    const ProtectorTouchInsets insets=size.width==874?ProtectorTouchInsets{0,62,21,62}:ProtectorTouchInsets{24,0,20,0};
                    assert(protector_touch_map_content_layout(size.width,size.height,insets,1,swapped,&content));
                    auto rect=[](ProtectorTouchRect r){return CGRectMake(r.x,r.y,r.width,r.height);};
                    const auto plan=PlanMapLayout(admitted,size,rect(content.title),rect(content.cards),rect(content.hints));
                    assert(plan.enabled&&MapValidRect(plan.title,size));
                    assert(plan.title.origin.x>=content.hints.x&&CGRectGetMaxX(plan.title)<=size.width*.55+.01);
                    size_t transformed=0;
                    for(size_t i=0;i<draws.size();++i) {
                        if(admitted.groups[i]>=0)++transformed;
                        for(const auto& source:draws[i].vertices) {
                            auto v=source;TransformMapVertex(&v,admitted.groups[i],admitted,plan);
                            assert(v.position[2]==source.position[2]&&v.position[3]==source.position[3]);
                            assert(!memcmp(v.color,source.color,sizeof(v.color))&&!memcmp(v.uv,source.uv,sizeof(v.uv)));
                            if(admitted.groups[i]<0)assert(!memcmp(&v,&source,sizeof(v)));
                        }
                    }
                    assert(transformed==4);
                }
            auto changed=draws;changed[24].vertices[0].color[3]=.5f;
            assert(!IdentifyMapLayout(changed,copies).enabled);
            changed=draws;std::swap(changed[24],changed[25]);
            assert(!IdentifyMapLayout(changed,copies).enabled);
        } else {
            for(const auto size:{CGSizeMake(844,390),CGSizeMake(1376,1032),CGSizeMake(480,260)})
                for(double scale:{.85,1.0,1.25})for(bool swapped:{false,true}) {
                    ProtectorMapContentLayout content;
                    const ProtectorTouchInsets insets=size.width==844?ProtectorTouchInsets{0,47,21,47}:ProtectorTouchInsets{0,0,0,0};
                    assert(protector_touch_map_content_layout(size.width,size.height,insets,scale,swapped,&content));
                    auto rect=[](ProtectorTouchRect r){return CGRectMake(r.x,r.y,r.width,r.height);};
                    const auto plan=PlanMapLayout(admitted,size,rect(content.title),rect(content.cards),rect(content.hints));
                    assert(plan.enabled);
                    for(size_t hint=0;hint<admitted.hintCount;++hint) {
                        assert(CGRectContainsRect(CGRectInset(rect(content.hints),-.01,-.01),plan.helpFrames[hint]));
                        if(size.width>=844)assert(plan.helpFrames[hint].size.height>=31.99);
                    }
                    assert(!PlanMapLayout(admitted,size,rect(content.cards),rect(content.cards),rect(content.hints)).enabled);
                    auto alternate=admitted;
                    const int first=admitted.region*5,last=std::min(first+5,24);
                    alternate.selected=first+(admitted.selected-first+1)%(last-first);
                    const auto stable=PlanMapLayout(alternate,size,rect(content.title),rect(content.cards),rect(content.hints));
                    assert(plan.cardScale==stable.cardScale);
                    for(int n=first;n<last;++n) {
                        assert(CGRectContainsRect(CGRectInset(rect(content.cards),-.01,-.01),plan.envelopes[n]));
                        assert(CGRectEqualToRect(plan.envelopes[n],stable.envelopes[n]));
                        for(int j=n+1;j<last;++j)assert(!CGRectIntersectsRect(plan.envelopes[n],plan.envelopes[j]));
                    }
                    for(size_t i=0;i<draws.size();++i) {
                        const int group=admitted.groups[i];
                        for(const auto& source:draws[i].vertices) {
                            auto upload=source;
                            TransformMapVertex(&upload,group,admitted,plan);
                            assert(upload.position[2]==source.position[2]&&upload.position[3]==source.position[3]);
                            assert(!memcmp(upload.color,source.color,sizeof(source.color)));
                            assert(!memcmp(upload.uv,source.uv,sizeof(source.uv)));
                            if(group<0)assert(!memcmp(&upload,&source,sizeof(source)));
                            if(group<first||group>=last)continue;
                            const auto frame=CGRectInset(plan.envelopes[group],-.01,-.01);
                            const auto point=CGPointMake((upload.position[0]+1)*size.width/2,(1-upload.position[1])*size.height/2);
                            assert(CGRectContainsPoint(frame,point));
                        }
                    }
            }
            auto changed=draws;
            changed[24].vertices[0].color[3]=.5f;
            assert(!IdentifyMapLayout(changed,copies).enabled);
            changed=draws;changed[29].vertices[0].uv[0][0]+=.1f;
            assert(!IdentifyMapLayout(changed,copies).enabled);
            changed=draws;changed[29].fragment.alphaCombiners[1]^=1;
            assert(!IdentifyMapLayout(changed,copies).enabled);
            changed=draws;changed[0].decodedPixels[0]=draws[1].decodedPixels[0];
            assert(!IdentifyMapLayout(changed,copies).enabled);
            changed=draws;std::swap(changed[24],changed[25]);
            assert(!IdentifyMapLayout(changed,copies).enabled);
            changed=draws;changed.erase(changed.begin()+29);
            assert(!IdentifyMapLayout(changed,copies).enabled);
            for(size_t i=29;i<draws.size();++i)if(admitted.groups[i]>=0) {
                changed=draws;changed[i].vertices[0].position[2]+=.05f;
                assert(!IdentifyMapLayout(changed,copies).enabled);
                changed=draws;changed[i].vertices[0].color[3]=.5f;
                assert(!IdentifyMapLayout(changed,copies).enabled);
            }
        }
        assert([before isEqual:MotionVertexDigest(draws)]);
        return;
    }
    if(moveAudit) {
        const auto before=MotionVertexDigest(draws);
        const auto hud=IdentifyNativeHud(draws);
        const auto admitted=IdentifyCombatMoves(draws,copies,hud);
        assert(admitted.count==2 && admitted.contains(426) && admitted.contains(427));
        for(size_t i=0;i<draws.size();++i)assert(admitted.contains(i)==(i==426 || i==427));
        assert(CombatMoveKind(draws[426])==2 && CombatMoveKind(draws[427])==1);
        assert(!IdentifyCombatMoves(draws,copies,NativeHudAdmission{}).count);
        for(size_t index:{426u,427u}) {
            auto changed=draws;changed[index].vertices[0].uv[0][0]+=.001f;
            assert(!IdentifyCombatMoves(changed,copies,hud).contains(index));
            changed=draws;changed[index].depthMode^=1;
            assert(!IdentifyCombatMoves(changed,copies,hud).contains(index));
            changed=draws;changed[index].indices[0]=1;
            assert(!IdentifyCombatMoves(changed,copies,hud).contains(index));
            changed=draws;changed[index].vertices[0].position[1]=NAN;
            assert(!IdentifyCombatMoves(changed,copies,hud).contains(index));
            changed=draws;changed[index].vertices[0].color[0]=.5f;
            assert(!IdentifyCombatMoves(changed,copies,hud).contains(index));
            changed=draws;changed[index].comboScheme=1;
            assert(!IdentifyCombatMoves(changed,copies,hud).contains(index));
            changed=draws;
            for(auto& v:changed[index].vertices)v.position[0]+=1.6875f;
            assert(!IdentifyCombatMoves(changed,copies,hud).contains(index));
            changed=draws;
            auto pixels=std::make_shared<std::vector<u8>>(*changed[index].decodedPixels[0]);
            (*pixels)[0]^=1;changed[index].decodedPixels[0]=pixels;
            assert(!IdentifyCombatMoves(changed,copies,hud).contains(index));
        }
        auto wrong=copies;wrong.back().width--;
        assert(!IdentifyCombatMoves(draws,wrong,hud).count);
        auto duplicate=draws;duplicate[428]=draws[427];
        assert(!IdentifyCombatMoves(duplicate,copies,hud).count);
        // Shared HUD transform preserves relative placement, UVs, depth,
        // colours and the original source snapshots at both native sizes.
        for(const CGSize size:{CGSizeMake(874,402),CGSizeMake(1376,1032)}) {
            const CGRect destination=CGRectMake(74,8,207.75,96.4285714);
            for(size_t index:{426u,427u})for(const auto& source:draws[index].vertices) {
                auto v=source;TransformNativeHudVertex(&v,size,destination);
                assert(v.position[2]==source.position[2] && v.position[3]==source.position[3]);
                assert(!memcmp(v.color,source.color,sizeof(v.color)) && !memcmp(v.uv,source.uv,sizeof(v.uv)));
                const double x=(v.position[0]+1)*size.width/2,y=(1-v.position[1])*size.height/2;
                assert(x>destination.origin.x && x<CGRectGetMaxX(destination));
                assert(y>destination.origin.y-.001 && y<=CGRectGetMaxY(destination)+.001);
            }
        }
        assert([before isEqual:MotionVertexDigest(draws)]);
        std::printf("Translated move labels: exact two source runs and fail-closed mutations passed; shared HUD placement immutable\n");
        return;
    }
    if(hudAudit) {
        if ([audit[@"frame_index"] unsignedIntegerValue]==5885 &&
            [audit[@"admission"] isEqual:@"unrecognized-cluster-layer"]) {
            assert(draws.size()==472);
            const auto before=MotionVertexDigest(draws);
            const auto admitted=IdentifyNativeHud(draws);
            assert(admitted.count==17);
            for(size_t i=0;i<draws.size();++i)assert(admitted.draws[i]==(i>=447 && i<=463));
            assert([before isEqual:MotionVertexDigest(draws)]);
            assert(!NativeHudDrawStateMatches(draws[459],NativeHudRole::Detail));
            assert(NativeHudDrawStateMatches(draws[459],NativeHudRole::WatchGlow));
            assert(!admitted.partial && !admitted.softDraws && !admitted.contained && !admitted.foreign);
            // A pulse, swapped texture or changed shader on one layer no longer
            // snaps the whole HUD back to 4:3: the layer stays with the HUD.
            auto changed=draws;
            for(auto& vertex:changed[459].vertices)vertex.position[0]+=20.f/320;
            auto mutated=IdentifyNativeHud(changed);
            assert(mutated.count==17 && mutated.softDraws==1 && mutated.draws[459]);
            changed=draws;changed[459].decodedPixels[0]=draws[460].decodedPixels[0];
            mutated=IdentifyNativeHud(changed);
            assert(mutated.count==17 && mutated.contained==1 && mutated.draws[459]);
            changed=draws;changed[459].fragment.alphaCombiners[0]^=1;
            mutated=IdentifyNativeHud(changed);
            assert(mutated.count==17 && mutated.softDraws==1);
            // Both frame anchors flashing (state change) remain identified.
            changed=draws;changed[447].blendMode=12604;changed[448].fragment.colorCombiners[0]^=1;
            mutated=IdentifyNativeHud(changed);
            assert(mutated.count==17 && mutated.softDraws==2 && !mutated.partial);
            // A non-HUD draw elsewhere is untouched.
            for(size_t i=0;i<draws.size();++i)if(i<447||i>463)assert(!mutated.draws[i]);
            std::puts("RJ frame 5885: exact 17-layer glow HUD admitted; pulse, texture and shader changes keep it in place.");
            return;
        }
        // Frozen translated 33_03 frame, with exact decoded source RGBA and
        // original TEV/viewport/topology. Keep proprietary data outside Git.
        assert(draws.size()==535);
        const auto before=MotionVertexDigest(draws);
        const auto admitted=IdentifyNativeHud(draws);
        assert(admitted.count==18);
        for(size_t i=0;i<draws.size();++i)assert(admitted.draws[i]==(i>=517 && i<=534));
        assert([before isEqual:MotionVertexDigest(draws)]);
        assert(NativeHudDrawStateMatches(draws[518]));
        assert(std::abs((draws[518].vertices[1].position[0]+1)*320-318)<.001);
        // Geometry and state drift on an identified anchor is soft; identity
        // (exact texture pair) and quad topology remain hard requirements.
        auto changed=draws;
        changed[518].vertices[1].position[0]=321.0f/320-1;
        auto mutated=IdentifyNativeHud(changed);
        assert(mutated.count==18 && mutated.softDraws==1);
        changed=draws;changed[518].fragment.alphaCombiners[1]^=1;
        mutated=IdentifyNativeHud(changed);
        assert(mutated.count==18 && mutated.softDraws==1);
        changed=draws;changed[518].decodedPixels[1]=draws[533].decodedPixels[1];
        assert(!IdentifyNativeHud(changed).count);
        changed=draws;changed[518].indices[0]=1;
        assert(!IdentifyNativeHud(changed).count);
        std::printf("Translated 33_03 HUD: 18 exact source draws admitted; soft drift kept, identity/topology mutations rejected\n");
        return;
    }
    if(combatAudit) {
        const auto admitted=IdentifyCombatFeedback(draws,copies);
        assert(admitted.enabled && admitted.label==310 && admitted.number==309 && admitted.count==2);
        const auto knownHud=IdentifyNativeHud(draws);
        const auto reused=IdentifyCombatFeedback(draws,copies,&knownHud);
        assert(reused.enabled && reused.label==admitted.label && reused.number==admitted.number && reused.count==admitted.count);
        const NativeHudAdmission missingHud{};
        assert(!IdentifyCombatFeedback(draws,copies,&missingHud).enabled);
        assert(CombatFeedbackAuditContainsLabel(draws));
        const auto before=draws;
        for(size_t index:{admitted.number,admitted.label}) {
            auto changed=draws;changed[index].vertices[0].uv[0][0]+=.001f;
            assert(!IdentifyCombatFeedback(changed,copies).enabled);
            changed=draws;changed[index].depthMode^=1;
            assert(!IdentifyCombatFeedback(changed,copies).enabled);
            changed=draws;changed[index].indices[0]=1;
            assert(!IdentifyCombatFeedback(changed,copies).enabled);
            changed=draws;changed[index].vertices[0].position[1]=NAN;
            assert(!IdentifyCombatFeedback(changed,copies).enabled);
            changed=draws;
            auto pixels=std::make_shared<std::vector<u8>>(*changed[index].decodedPixels[0]);
            (*pixels)[0]^=1;changed[index].decodedPixels[0]=pixels;
            assert(!IdentifyCombatFeedback(changed,copies).enabled);
        }
        auto changed=draws;std::swap(changed[309],changed[310]);
        assert(!IdentifyCombatFeedback(changed,copies).enabled);
        changed=draws;changed[310].comboScheme=1;
        assert(!IdentifyCombatFeedback(changed,copies).enabled);
        changed=draws;
        for(size_t i:{309u,310u})for(auto& v:changed[i].vertices)v.position[0]+=1.6875f;
        assert(!IdentifyCombatFeedback(changed,copies).enabled); // Right-player branch.
        auto wrong=copies;wrong.back().width--;
        assert(!IdentifyCombatFeedback(draws,wrong).enabled);
        changed=draws;
        const auto hud=IdentifyNativeHud(changed);
        assert(hud.count);
        for(size_t i=0;i<changed.size();++i)if(hud.draws[i])changed[i].vertices.clear();
        assert(!IdentifyCombatFeedback(changed,copies).enabled);
        changed=draws;
        changed.push_back(draws[309]);changed.push_back(draws[310]);
        auto duplicateCopies=copies;duplicateCopies.back().drawIndex=changed.size();
        assert(!IdentifyCombatFeedback(changed,duplicateCopies).enabled);
        // The formatter's longest valid string and generous geometry extremes
        // are synthetic boundary cases, not observations of billion-hit play.
        auto numberRun=[&](const char* text) {
            LiveDraw run=draws[309];run.vertices.clear();run.indices.clear();
            const double advance=176.0/strlen(text),left=52-88;
            for(size_t q=0;q<strlen(text);++q) {
                const auto cell=std::find_if(std::begin(kCombatFeedbackGlyphs),std::end(kCombatFeedbackGlyphs),
                    [&](const auto& value){return value.character==text[q];});
                assert(cell!=std::end(kCombatFeedbackGlyphs));
                const double x=left+q*advance,width=advance*.9;
                const double xy[][2]={{x,447},{x,400},{x+width,400},{x+width,447}};
                const float uv[][2]={{cell->left,cell->bottom},{cell->left,cell->top},
                    {cell->right,cell->top},{cell->right,cell->bottom}};
                for(size_t c=0;c<4;++c) {
                    auto v=draws[309].vertices[c];v.position[0]=xy[c][0]/320-1;v.position[1]=1-xy[c][1]/224;
                    memcpy(v.uv[0],uv[c],sizeof(uv[c]));run.vertices.push_back(v);
                }
                for(u32 corner:{0u,1u,2u,0u,2u,3u})run.indices.push_back((u32)(q*4)+corner);
            }
            return run;
        };
        changed=draws;changed[309]=numberRun("2,147,483,647");
        assert(IdentifyCombatFeedback(changed,copies).count==INT32_MAX);
        changed[309]=numberRun("2,147,483,648");assert(!IdentifyCombatFeedback(changed,copies).enabled);
        changed[309]=numberRun("12,34");assert(!IdentifyCombatFeedback(changed,copies).enabled);
        changed[309]=numberRun("2,147,483,647");changed[309].vertices[0].position[1]=1-449.0/224;
        assert(!IdentifyCombatFeedback(changed,copies).enabled);
        for(const CGSize size:{CGSizeMake(480,260),CGSizeMake(852,393),CGSizeMake(1376,1032)}) {
            for(bool swapped:{false,true}) {
                ProtectorTouchRect frame;
                assert(protector_touch_combat_feedback_layout(size.width,size.height,{0,0,0,0},1.25,swapped,&frame));
                for(size_t i=0;i<draws.size();++i) {
                    auto upload=draws[i].vertices;
                    if(admitted.contains(i))for(auto& v:upload)
                        TransformCombatFeedbackVertex(&v,size,CGRectMake(frame.x,frame.y,frame.width,frame.height));
                    for(size_t n=0;n<upload.size();++n) {
                        const auto& a=draws[i].vertices[n];const auto& b=upload[n];
                        if(!admitted.contains(i))assert(!memcmp(&a,&b,sizeof(a)));
                        else {
                            const double x=(b.position[0]+1)*size.width/2,y=(1-b.position[1])*size.height/2;
                            assert(x>=frame.x-.001 && x<=frame.x+frame.width+.001 && y>=frame.y-.001 && y<=frame.y+frame.height+.001);
                            assert(a.position[2]==b.position[2] && a.position[3]==b.position[3]);
                            assert(!memcmp(a.color,b.color,sizeof(a.color)) && !memcmp(a.uv,b.uv,sizeof(a.uv)));
                        }
                    }
                }
            }
        }
        assert([MotionVertexDigest(before) isEqual:MotionVertexDigest(draws)]);
        std::puts("Combat feedback: source two-draw group admitted; exact pixels, order, geometry and player-side negatives pass; host-only transform preserves other text.");
        return;
    }
    if(upgradeAudit) {
        assert(!IdentifyUpgradeGlyphs(draws,copies).enabled);
        for(auto& draw:draws){draw.upgradeActive=true;draw.upgradeReady=true;draw.upgradeScheme=1;}
        const auto admitted=IdentifyUpgradeGlyphs(draws,copies);
        std::fprintf(stderr,"Upgrade admission enabled=%d first=%zu scheme=%u glyphs=%zu\n",
            admitted.enabled,admitted.first,admitted.scheme,admitted.glyphCount);
        assert(admitted.enabled && admitted.first==214 && admitted.scheme==1 && admitted.glyphCount==3);
        assert(!IdentifyComboGlyphs(draws,copies).enabled);
        const auto original=draws;
        for(size_t i=0;i<draws.size();++i) {
            auto changed=draws;changed[i].upgradeActive=false;
            assert(!IdentifyUpgradeGlyphs(changed,copies).enabled);
            changed=draws;changed[i].upgradeReady=false;
            assert(!IdentifyUpgradeGlyphs(changed,copies).enabled);
            changed=draws;changed[i].upgradeScheme=0;
            assert(!IdentifyUpgradeGlyphs(changed,copies).enabled);
            if(!admitted.contains(i))continue;
            changed=draws;changed[i].depthMode^=1;
            assert(!IdentifyUpgradeGlyphs(changed,copies).enabled);
            if(i<230 || i>=237)for(size_t stage=0;stage<draws[i].fragment.stageCount;++stage) {
                changed=draws;
                auto pixels=std::make_shared<std::vector<u8>>(*changed[i].decodedPixels[stage]);
                (*pixels)[0]^=1;changed[i].decodedPixels[stage]=pixels;
                assert(!IdentifyUpgradeGlyphs(changed,copies).enabled);
            }
            if(i<230)for(size_t axis=0;axis<2;++axis) {
                changed=draws;changed[i].vertices[0].position[axis]+=.002f;
                assert(!IdentifyUpgradeGlyphs(changed,copies).enabled);
            }
            if(!admitted.actions[i].empty()) {
                changed=draws;changed[i].vertices[0].uv[0][0]+=.002f;
                assert(!IdentifyUpgradeGlyphs(changed,copies).enabled);
            }
            auto uploaded=draws[i].vertices;
            if(!admitted.actions[i].empty())UploadComboGlyphs(uploaded.data(),admitted.actions[i],.330357164f,.169642866f);
            for(auto& vertex:uploaded)TransformComboVertex(&vertex,CGSizeMake(1376,1032),CGRectMake(104,32,1168,876));
            assert(!memcmp(draws[i].vertices.data(),original[i].vertices.data(),draws[i].vertices.size()*sizeof(LiveVertex)));
        }
        // An unavailable form has no notation, but retains independently
        // admitted panel/navigation. This is a synthetic boundary, not native QA.
        auto unavailable=draws;
        unavailable.erase(unavailable.begin()+242,unavailable.end());
        unavailable.erase(unavailable.begin()+237);
        for(auto& draw:unavailable){draw.upgradeReady=false;draw.upgradeScheme=0;}
        auto emptyCopies=copies;emptyCopies.back().drawIndex=unavailable.size();
        const auto empty=IdentifyUpgradeGlyphs(unavailable,emptyCopies);
        assert(empty.enabled && !empty.ready && !empty.scheme && !empty.glyphCount);
        auto wrong=copies;wrong.back().width--;
        assert(!IdentifyUpgradeGlyphs(draws,wrong).enabled);
        std::puts("Upgrade source audit: independent owner, complete panel, exact notation/navigation and host-only upload mutations pass.");
        return;
    }
    if(comboAudit) {
        assert(!IdentifyComboGlyphs(draws,copies).enabled);
        for(auto& draw:draws)draw.comboScheme=1;
        const auto admitted=IdentifyComboGlyphs(draws,copies);
        std::fprintf(stderr,"Combo admission enabled=%d first=%zu scheme=%u glyphs=%zu\n",
            admitted.enabled,admitted.first,admitted.scheme,admitted.glyphCount);
        assert(admitted.enabled && admitted.first==214 && admitted.scheme==1 && admitted.glyphCount==18);
        const auto original=draws;
        constexpr unsigned sourceGlyph[3][4]={{1,2,4,6},{1,2,4,9},{2,6,1,4}};
        auto setGlyph=[](LiveVertex* v,unsigned glyph) {
            const float left=glyph==1?0:glyph==2?.140625f:glyph==4?.421875f:glyph==6?.703125f:.140625f;
            const float right=left+(glyph==9?.25f:.125f);
            const float bottom=glyph==9?.875f:.9375f,top=glyph==9?.9375f:1;
            const float uv[][2]={{left,bottom},{left,top},{right,top},{right,bottom}};
            for(size_t n=0;n<4;++n)memcpy(v[n].uv[0],uv[n],sizeof(uv[n]));
        };
        for(unsigned scheme=1;scheme<=3;++scheme) {
            auto family=draws;
            for(auto& draw:family)draw.comboScheme=scheme;
            for(size_t i=0;i<family.size();++i)for(size_t q=0;q<admitted.actions[i].size();++q) {
                const unsigned action=admitted.actions[i][q];
                if(action<=4)setGlyph(family[i].vertices.data()+q*4,sourceGlyph[scheme-1][action-1]);
            }
            const auto variant=IdentifyComboGlyphs(family,copies);
            assert(variant.enabled && variant.scheme==scheme && variant.actions==admitted.actions);
            for(unsigned ordinal=1;ordinal<=19;++ordinal) {
                const char* sequence=protector_combo_action_sequence(ordinal);
                for(size_t q=0;q<strlen(sequence);++q) {
                    LiveDraw glyph=draws[270];
                    const unsigned action=sequence[q]-'0';
                    setGlyph(glyph.vertices.data(),sourceGlyph[scheme-1][action-1]);
                    assert(ComboQuadAction(glyph,0,scheme)==action);
                    glyph.vertices[0].uv[0][0]+=.001f;
                    assert(!ComboQuadAction(glyph,0,scheme));
                }
            }
        }
        for(size_t i=0;i<draws.size();++i) {
            assert(admitted.contains(i)==(i>=admitted.first));
            auto changed=draws;changed[i].comboScheme=0;
            assert(!IdentifyComboGlyphs(changed,copies).enabled);
            if(i<admitted.first)continue;
            changed=draws;changed[i].depthMode^=1;
            assert(!IdentifyComboGlyphs(changed,copies).enabled);
            if(i<admitted.first+19 || i>=240) {
                for(size_t stage=0;stage<draws[i].fragment.stageCount;++stage) {
                    changed=draws;
                    auto pixels=std::make_shared<std::vector<u8>>(*draws[i].decodedPixels[stage]);
                    (*pixels)[0]^=1;changed[i].decodedPixels[stage]=pixels;
                    assert(!IdentifyComboGlyphs(changed,copies).enabled);
                }
            }
            if(i<admitted.first+4) {
                for(size_t corner=0;corner<4;++corner) {
                    changed=draws;changed[i].vertices[corner].position[0]+=.003f;
                    assert(!IdentifyComboGlyphs(changed,copies).enabled);
                    for(size_t stage=0;stage<2;++stage) {
                        changed=draws;changed[i].vertices[corner].uv[stage][0]+=.003f;
                        assert(!IdentifyComboGlyphs(changed,copies).enabled);
                    }
                }
            }
            auto uploaded=draws[i].vertices;
            UploadComboGlyphs(uploaded.data(),admitted.actions[i]);
            for(auto& v:uploaded)TransformComboVertex(&v,CGSizeMake(1024,768),CGRectMake(85.333333,32,853.333333,640));
            assert(!memcmp(draws[i].vertices.data(),original[i].vertices.data(),draws[i].vertices.size()*sizeof(LiveVertex)));
            if(!admitted.actions[i].empty()) {
                changed=draws;changed[i].vertices[0].uv[0][0]+=.003f;
                assert(!IdentifyComboGlyphs(changed,copies).enabled);
            }
        }
        auto changed=draws;changed.erase(changed.begin()+218);
        assert(!IdentifyComboGlyphs(changed,copies).enabled);
        auto wrong=copies;wrong.back().width--;
        assert(!IdentifyComboGlyphs(draws,wrong).enabled);
        id<MTLTexture> texture=CreateComboGlyphTexture(MTLCreateSystemDefaultDevice());
        assert(texture && texture.width==768 && texture.height==128);
        std::vector<u8> pixels(768*128*4);
        [texture getBytes:pixels.data() bytesPerRow:768*4 fromRegion:MTLRegionMake2D(0,0,768,128) mipmapLevel:0];
        for(size_t action=0;action<6;++action) {
            size_t visible=0,transparent=0;
            for(size_t y=0;y<128;++y)for(size_t x=action*128;x<(action+1)*128;++x) {
                const auto alpha=pixels[(y*768+x)*4+3];visible+=alpha>0;transparent+=alpha==0;
            }
            assert(visible>500 && transparent>2000);
        }
        std::printf("Combo source audit: exact panel and %zu action glyphs admitted; source buffers immutable; mutations rejected\n",admitted.glyphCount);
        return;
    }
    if (galleryAudit) {
        // The captured renderer admitted this YUV quad using its full draw
        // contract and live decode clock. Old audit files omit cull/indirect
        // state, so this test exercises the downstream layout only; the
        // independent cinematic-admission tests cover those missing fields.
        if (movieAudit) {
            assert(records.count==35 && [audit[@"render_state"][@"source_cinematic"][@"active"] boolValue]);
            assert([audit[@"render_state"][@"cinematic_draw_index"] intValue]==0);
            assert(draws[0].fragment.stageCount==4 && draws[0].vertices.size()==4);
            assert(!::IdentifyGalleryLayout(draws,copies).enabled);
            assert(!::IdentifyGalleryLayout(draws,copies,1).enabled);
        }
        auto IdentifyGalleryLayout = [movieAudit](const std::vector<LiveDraw>& input,
            const std::vector<LiveEfbCopy>& inputCopies) {
            return ::IdentifyGalleryLayout(input,inputCopies,movieAudit ? 0 : -1);
        };
        const auto admitted = IdentifyGalleryLayout(draws,copies);
        assert(admitted.enabled && admitted.first == first &&
            admitted.gallery == (!browserAudit && !optionsAudit && records.count != 20) &&
            admitted.extrasBrowser == browserAudit && admitted.extrasOptions == optionsAudit &&
            admitted.extrasMovie == movieAudit);
        for (size_t i=first; i<draws.size(); ++i) {
            const auto& original = draws[i].vertices;
            float left = original.front().position[0], right = left;
            for (const auto& v : original) { left = std::min(left,v.position[0]); right = std::max(right,v.position[0]); }
            for (double aspect : {4.0/3,16.0/9,2.17,3.0}) {
                auto uploaded = original;
                for (auto& v : uploaded) TransformGalleryLayoutVertex(&v,admitted.role(i),aspect,left,right,admitted.panelCenter);
                for (size_t v=0; v<original.size(); ++v) {
                    if (aspect == 4.0/3 || admitted.role(i) == FrontendRole::Unknown)
                        assert(memcmp(&uploaded[v],&original[v],sizeof(LiveVertex)) == 0);
                    assert(std::isfinite(uploaded[v].position[0]));
                    for (size_t axis=1; axis<4; ++axis) assert(uploaded[v].position[axis] == original[v].position[axis]);
                    assert(memcmp(uploaded[v].uv,original[v].uv,sizeof(original[v].uv)) == 0);
                    assert(memcmp(uploaded[v].color,original[v].color,sizeof(original[v].color)) == 0);
                }
            }
            auto changed = draws; changed[i].depthMode ^= 1;
            assert(!IdentifyGalleryLayout(changed,copies).enabled);
        }
        for (size_t i=0; i<10; ++i) {
            auto changed = draws;
            auto pixels = std::make_shared<std::vector<u8>>(*changed[first+i].decodedPixels[0]);
            (*pixels)[0] ^= 1; changed[first+i].decodedPixels[0] = pixels;
            assert(!IdentifyGalleryLayout(changed,copies).enabled);
        }
        auto changed = draws; changed[first].vertices[0].position[0] += .01f;
        assert(!IdentifyGalleryLayout(changed,copies).enabled);
        changed = draws; changed.erase(changed.begin()+first);
        assert(!IdentifyGalleryLayout(changed,copies).enabled);
        changed = draws;
        if(movieAudit)changed[0].projectionWords[6] = 0;
        else changed[0].projectionWords[6] = 1;
        assert(!IdentifyGalleryLayout(changed,copies).enabled);
        auto changedCopies = copies; changedCopies[0].width = 639;
        assert(!IdentifyGalleryLayout(draws,changedCopies).enabled);
        if (admitted.extrasOptions) {
            const bool code = records.count == 29;
            const size_t fonts = code ? 23 : 25;
            for (size_t i=10; i<records.count; ++i) {
                assert(admitted.role(first+i) == FrontendRole::Unknown);
                // Every fixed panel and font tuple is required. Code symbols
                // deliberately remain source-owned changing content.
                if (!code || i<19 || i>=fonts) {
                    for (size_t stage=0; stage<draws[first+i].fragment.stageCount; ++stage) {
                        if (code && i==18 && stage==1) continue; // alien-owned silhouette
                        changed = draws;
                        auto pixels = std::make_shared<std::vector<u8>>(*changed[first+i].decodedPixels[stage]);
                        (*pixels)[0] ^= 1; changed[first+i].decodedPixels[stage] = pixels;
                        assert(!IdentifyGalleryLayout(changed,copies).enabled);
                    }
                }
                if (i < fonts) {
                    changed = draws; changed[first+i].vertices[0].position[0] += .01f;
                    assert(!IdentifyGalleryLayout(changed,copies).enabled);
                }
            }
            if (code) {
                float originalCenter = 0;
                for (const auto& vertex : draws[first+18].vertices) originalCenter += vertex.position[0]/4;
                for (size_t column=0; column<4; ++column) {
                    changed = draws;
                    const float shift = -.46875f+.3125f*column-originalCenter;
                    for (size_t i : {16u,17u,18u})
                        for (auto& vertex : changed[first+i].vertices) vertex.position[0] += shift;
                    assert(IdentifyGalleryLayout(changed,copies).enabled);
                }
                changed = draws;
                for (auto& vertex : changed[first+18].vertices) vertex.position[0] += .1f;
                assert(!IdentifyGalleryLayout(changed,copies).enabled);
                changed = draws; std::swap(changed[first+19].decodedPixels,changed[first+22].decodedPixels);
                assert(IdentifyGalleryLayout(changed,copies).enabled);
                changed = draws;
                auto mask = std::make_shared<std::vector<u8>>(*changed[first+18].decodedPixels[1]);
                (*mask)[0] ^= 1; changed[first+18].decodedPixels[1] = mask;
                assert(IdentifyGalleryLayout(changed,copies).enabled);
                changed[first+18].textureWidths[1] = 127;
                assert(!IdentifyGalleryLayout(changed,copies).enabled);
            } else {
                // Synthetic count bounds cover wrapping/unlocked labels, not
                // claimed rendered states. Complete columns remain mandatory.
                for (size_t count : {37u,56u}) {
                    changed = draws; changed.resize(first+count,draws.back());
                    changedCopies = copies; changedCopies[0].drawIndex = changed.size();
                    assert(IdentifyGalleryLayout(changed,changedCopies).enabled);
                }
                for (size_t count : {36u,57u}) {
                    changed = draws; changed.resize(first+count,draws.back());
                    changedCopies = copies; changedCopies[0].drawIndex = changed.size();
                    assert(!IdentifyGalleryLayout(changed,changedCopies).enabled);
                }
            }
        }
        if (admitted.extrasBrowser) {
            for (size_t i=10; i<19; ++i) {
                changed = draws; changed[first+i].vertices[0].position[0] += .01f;
                assert(!IdentifyGalleryLayout(changed,copies).enabled);
                for (size_t stage=0; stage<draws[first+i].fragment.stageCount; ++stage) {
                    changed = draws;
                    auto pixels = std::make_shared<std::vector<u8>>(*changed[first+i].decodedPixels[stage]);
                    (*pixels)[0] ^= 1; changed[first+i].decodedPixels[stage] = pixels;
                    assert(!IdentifyGalleryLayout(changed,copies).enabled);
                }
            }
            size_t selectors = 0, fonts = 0;
            for (size_t i=first+19; i<draws.size(); ++i) {
                const auto& draw = draws[i];
                assert(admitted.role(i) == FrontendRole::Unknown);
                const bool selector = [InterfaceTextureKey(TexturePixels(draw,0),draw.textureWidths[0],draw.textureHeights[0])
                    isEqualToString:@"64x64-282b4fb9a89612a84eef5e9f37d05cbf7defe7809d5190c706b274c0d92de922"];
                const bool font = draw.textureFormats[0] == 9;
                selectors += selector; fonts += font;
                if (!selector && !font) continue;
                for (size_t stage=0; stage<draw.fragment.stageCount; ++stage) {
                    changed = draws;
                    auto pixels = std::make_shared<std::vector<u8>>(*changed[i].decodedPixels[stage]);
                    (*pixels)[0] ^= 1; changed[i].decodedPixels[stage] = pixels;
                    assert(!IdentifyGalleryLayout(changed,copies).enabled);
                }
                // Navigation may move the glow and alter its draw order; no
                // browser entry or selection vertex receives an upload edit.
                if (selector) {
                    changed = draws;
                    for (auto& vertex : changed[i].vertices) vertex.position[0] += .1f;
                    assert(IdentifyGalleryLayout(changed,copies).enabled);
                    std::swap(changed[first+19],changed[i]);
                    assert(IdentifyGalleryLayout(changed,copies).enabled);
                }
            }
            const size_t items=draws.size()-first-20-fonts;
            const size_t baseFonts=items==30 ? 4 : 3;
            const size_t fullViewFonts=items==30 ? 3 : 2;
            assert(selectors==1 && (movieAudit ? fonts==0 : admitted.extrasFullView ? fonts==fullViewFonts : fonts>=3));
            if(movieAudit) {
                assert(items==14 && admitted.role(0)==FrontendRole::Unknown);
                // No film or collection-item vertices can acquire a layout
                // role. A missing item, extra font or incomplete movie does
                // not turn a partial component into a recognized browser.
                changed=draws;changed.pop_back();changedCopies=copies;
                changedCopies[0].drawIndex=changed.size();
                assert(!IdentifyGalleryLayout(changed,changedCopies).enabled);
                changed=draws;changed.push_back(draws.back());changedCopies=copies;
                changedCopies[0].drawIndex=changed.size();
                assert(!IdentifyGalleryLayout(changed,changedCopies).enabled);
                std::printf("Extras movie source audit: complete 34-draw hidden browser; film and items immutable; source mutations rejected\n");
                return;
            }
            if((items==20 || items==11) && !admitted.extrasFullView) {
                const size_t oldFontStart=draws.size()-fonts;
                LiveDraw tag=draws[oldFontStart];
                // Synthetic three-glyph headline-font row, not additional
                // observed text or native coverage. Source reconstruction
                // above separately proves the actual unlocked tag geometry.
                assert(tag.indexed && tag.vertices.size()>=12 && tag.indices.size()>=18);
                tag.vertices.resize(12);tag.indices.resize(18);
                for(size_t tags=0;tags<=items+1;++tags) for(size_t body=1;body<=4;++body) {
                    changed=draws;changed.resize(first+20+items);
                    changed.push_back(draws[oldFontStart]);
                    for(size_t n=0;n<tags;++n)changed.push_back(tag);
                    for(size_t n=0;n<body;++n)changed.push_back(draws.back());
                    changedCopies=copies;changedCopies[0].drawIndex=changed.size();
                    assert(IdentifyGalleryLayout(changed,changedCopies).enabled==(tags<=items && body>=2 && body<=3));
                }
                changed=draws;changed.resize(first+20+items);
                changed.push_back(draws[oldFontStart]);changed.push_back(tag);
                changed.push_back(draws.back());changed.push_back(draws.back());
                changedCopies=copies;changedCopies[0].drawIndex=changed.size();
                assert(IdentifyGalleryLayout(changed,changedCopies).enabled);
                changed[first+20+items+1].vertices.resize(8);
                changed[first+20+items+1].indices.resize(12);
                assert(!IdentifyGalleryLayout(changed,changedCopies).enabled);
                changed[first+20+items+1]=tag;
                std::swap(changed[first+20+items+1],changed.back());
                assert(!IdentifyGalleryLayout(changed,changedCopies).enabled);
            } else for(size_t count=1;count<=baseFonts+items+2;++count) {
                changed=draws;changed.resize(first+20+items);
                const size_t oldFontStart=draws.size()-fonts;
                for(size_t n=0;n<count;++n)changed.push_back(draws[n==0 ? oldFontStart : draws.size()-1]);
                changedCopies=copies;changedCopies[0].drawIndex=changed.size();
                const bool expected=admitted.extrasFullView ? count==fullViewFonts : count>=baseFonts && count<=baseFonts+items+1;
                assert(IdentifyGalleryLayout(changed,changedCopies).enabled==expected);
            }
        }
        if (admitted.gallery) {
            // Both complete source panels and the frame anchor every gallery
            // variant, while art/thumbnail vertices remain byte-identical.
            for (size_t i=10; i<20; ++i) {
                changed = draws; changed[first+i].vertices[0].position[0] += .01f;
                assert(!IdentifyGalleryLayout(changed,copies).enabled);
                changed = draws;
                auto pixels = std::make_shared<std::vector<u8>>(*changed[first+i].decodedPixels[0]);
                (*pixels)[0] ^= 1; changed[first+i].decodedPixels[0] = pixels;
                assert(!IdentifyGalleryLayout(changed,copies).enabled);
            }
            for (size_t i=first+34; i<draws.size(); ++i) {
                changed = draws;
                changed[i].decodedPixels[0] = draws[first].decodedPixels[0];
                assert(!IdentifyGalleryLayout(changed,copies).enabled);
            }
            // Synthetic label-count boundaries exercise admission only. They
            // are not additional observed game states or visual coverage.
            const bool fullArt = records.count == 36;
            for (size_t count=34; count<=53; ++count) {
                changed = draws;
                changed.resize(first+34);
                while (changed.size() < first+count) changed.push_back(draws.back());
                changedCopies = copies; changedCopies[0].drawIndex = changed.size();
                const bool expected = fullArt ? count == 36 : count >= 39 && count <= 52;
                assert(IdentifyGalleryLayout(changed,changedCopies).enabled == expected);
            }
        }
        std::printf("Live scene-menu component audit admitted: %s, frame %u, %zu orthographic draws, %zu hashed bytes; room prefix is classification-only\n",
            admitted.reason,[audit[@"frame_index"] unsignedIntValue],records.count,totalBytes);
        return;
    }
    const auto admitted = IdentifyFrontend(draws,copies);
    assert(admitted.enabled);
    if (admitted.secondary) {
        for (size_t i=0; i<draws.size(); ++i) {
            const auto& original = draws[i].vertices;
            float left = original.front().position[0], right = left;
            for (const auto& vertex : original) {
                left = std::min(left,vertex.position[0]); right = std::max(right,vertex.position[0]);
            }
            for (double aspect : {4.0/3,16.0/9,2.17,3.0}) {
                auto uploaded = original;
                for (auto& vertex : uploaded)
                    TransformSecondaryFrontendVertex(&vertex,admitted.roles[i],aspect,left,right,admitted.panelCenter);
                for (size_t v=0; v<original.size(); ++v) {
                    if (aspect == 4.0/3) assert(memcmp(&uploaded[v],&original[v],sizeof(LiveVertex)) == 0);
                    assert(std::isfinite(uploaded[v].position[0]) && std::isfinite(uploaded[v].position[1]));
                    assert(uploaded[v].position[2] == original[v].position[2]);
                    assert(uploaded[v].position[3] == original[v].position[3]);
                    assert(memcmp(uploaded[v].uv,original[v].uv,sizeof(original[v].uv)) == 0);
                    assert(memcmp(uploaded[v].color,original[v].color,sizeof(original[v].color)) == 0);
                }
            }
        }
    }
    std::printf("Live frontend source audit admitted: %s, frame %u, %zu draws, %zu hashed bytes\n",
        admitted.reason,[audit[@"frame_index"] unsignedIntValue],draws.size(),totalBytes);
}

static LiveDraw SharedPanelTestDraw(SharedPanelRole role) {
    LiveDraw draw;
    draw.indexed = true; draw.indices = {0,1,2,0,2,3};
    draw.viewportWidth = 640; draw.viewportHeight = 448;
    draw.projectionWords = {994888909,2147483648,3146926373,0,3131299594,3212627148,1};
    draw.depthMode = 15; draw.blendMode = 13501; draw.fragment.alphaTest = 4128768;
    draw.fragment.stageCount = 2;
    for (size_t stage=0;stage<2;++stage) {
        draw.textureWidths[stage] = 32; draw.textureHeights[stage] = 128;
        draw.textureFormats[stage] = 14; draw.textureModes[stage] = 2097360;
        draw.textureCoordinates[stage] = 0; draw.textureUnits[stage] = (u32)stage;
        draw.fragment.colorCombiners[stage] = stage ? 589808 : 64143;
        draw.fragment.alphaCombiners[stage] = stage ? 63100 : 65520;
    }
    float left = role == SharedPanelRole::Center ? -0.625f :
        role == SharedPanelRole::LeftCap ? -0.725f : 0.725f;
    float right = role == SharedPanelRole::LeftCap ? -0.625f : 0.625f;
    const float xs[] = {left,right,right,left};
    const float ys[] = {0.5357143283f,0.5357143283f,-0.6294643283f,-0.6294643283f};
    const float uv[][2] = {{0,0},{1,0},{1,1},{0,1}};
    for (size_t i=0;i<4;++i) {
        LiveVertex vertex{};
        vertex.position[0] = xs[i]; vertex.position[1] = ys[i];
        vertex.position[2] = 0.00625002384f; vertex.position[3] = 1;
        for (float& color : vertex.color) color = 1;
        for (size_t stage=0;stage<2;++stage)
            for (size_t axis=0;axis<2;++axis) vertex.uv[stage][axis] = uv[i][axis];
        draw.vertices.push_back(vertex);
    }
    return draw;
}

static void TestSharedPanelAdmissionAndTransform() {
    std::vector<LiveDraw> fixture;
    for (auto role : {SharedPanelRole::Center,SharedPanelRole::LeftCap,SharedPanelRole::RightCap}) {
        LiveDraw draw = SharedPanelTestDraw(role);
        assert(SharedPanelGeometryMatches(draw,role));
        assert(!SharedPanelGeometryMatches(draw,SharedPanelRole::None));
        auto reject = [&](LiveDraw bad) { assert(!SharedPanelGeometryMatches(bad,role)); };
        { auto bad=draw; bad.vertices[0].position[0]+=.01f; reject(bad); }
        { auto bad=draw; bad.vertices[1].uv[1][0]=.5f; reject(bad); }
        { auto bad=draw; bad.vertices[0].color[2]=.4f; reject(bad); }
        { auto bad=draw; bad.textureFormats[1]=4; reject(bad); }
        { auto bad=draw; bad.fragment.alphaCombiners[0]=63088; reject(bad); }
        { auto bad=draw; bad.viewportWidth=639; reject(bad); }
        { auto bad=draw; bad.indices[0]=1; reject(bad); }
        { auto bad=draw; bad.vertices.pop_back(); reject(bad); }
        for (double aspect : {4.0/3,16.0/9,2.17,3.0}) {
            auto changed=draw.vertices;
            for (auto& vertex:changed) TransformSharedPanelVertex(&vertex,role,aspect);
            for (size_t i=0;i<4;++i) {
                if (aspect==4.0/3) assert(!memcmp(&changed[i],&draw.vertices[i],sizeof(LiveVertex)));
                assert(std::abs(changed[i].position[0])<.73f);
                for (size_t axis=1;axis<4;++axis) assert(changed[i].position[axis]==draw.vertices[i].position[axis]);
                assert(!memcmp(changed[i].color,draw.vertices[i].color,sizeof(changed[i].color)));
                assert(!memcmp(changed[i].uv,draw.vertices[i].uv,sizeof(changed[i].uv)));
            }
            if (role != SharedPanelRole::Center)
                assert(std::abs((changed[1].position[0]-changed[0].position[0])*aspect-
                    (draw.vertices[1].position[0]-draw.vertices[0].position[0])*(4.0/3))<.00001);
        }
        for (double invalid : {0.0,1.0,3.1,(double)INFINITY,(double)NAN}) {
            auto vertex=draw.vertices[0]; TransformSharedPanelVertex(&vertex,role,invalid);
            assert(!memcmp(&vertex,&draw.vertices[0],sizeof(vertex)));
        }
        fixture.push_back(draw);
    }
    // Matching geometry without original decoded plane identities is rejected.
    assert(!IdentifySharedPanel(fixture).enabled);
    for (double aspect : {4.0/3,16.0/9,2.17,3.0}) {
        auto centre=fixture[0].vertices, left=fixture[1].vertices, right=fixture[2].vertices;
        for (auto& v:centre) TransformSharedPanelVertex(&v,SharedPanelRole::Center,aspect);
        for (auto& v:left) TransformSharedPanelVertex(&v,SharedPanelRole::LeftCap,aspect);
        for (auto& v:right) TransformSharedPanelVertex(&v,SharedPanelRole::RightCap,aspect);
        assert(std::abs(centre[0].position[0]-left[1].position[0])<.000001);
        assert(std::abs(centre[1].position[0]-right[1].position[0])<.000001);
    }
}

static void TestSharedPanelSourceAudit() {
    const char* path=getenv("PROTECTOR_SHARED_PANEL_SOURCE_AUDIT");
    if (!path || !path[0]) return;
    NSString* auditPath=@(path);
    NSData* bytes=[NSData dataWithContentsOfFile:auditPath];
    assert(bytes && bytes.length<8*1024*1024);
    NSDictionary* audit=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    assert([audit[@"schema"] isEqual:@"protector-native.interface-source-audit/v1"]);
    assert([audit[@"source"] isEqual:@"translated_execution_callback"]);
    std::vector<LiveDraw> selected;
    NSMutableArray* selectedIndices=[NSMutableArray array];
    for (NSDictionary* record in audit[@"draws"]) {
        NSArray* stages=record[@"textures"];
        if (stages.count!=2 || [stages[0][@"width"] unsignedIntValue]!=32 ||
            [stages[0][@"height"] unsignedIntValue]!=128) continue;
        LiveDraw draw;
        draw.indexed=[record[@"indexed"] boolValue]; draw.blendMode=[record[@"blend_mode"] unsignedIntValue];
        draw.depthMode=[record[@"depth_mode"] unsignedIntValue]; draw.fragment.alphaTest=[record[@"alpha_test"] unsignedIntValue];
        NSArray* viewport=record[@"viewport"];
        draw.viewportX=[viewport[0] doubleValue]; draw.viewportY=[viewport[1] doubleValue];
        draw.viewportWidth=[viewport[2] doubleValue]; draw.viewportHeight=[viewport[3] doubleValue];
        for (size_t i=0;i<7;++i) draw.projectionWords[i]=[record[@"projection_words"][i] unsignedIntValue];
        for (NSNumber* index in record[@"indices"]) draw.indices.push_back(index.unsignedIntValue);
        for (NSDictionary* source in record[@"vertices"]) {
            LiveVertex vertex{};
            for (size_t i=0;i<4;++i) {
                vertex.position[i]=[source[@"clip"][i] floatValue]; vertex.color[i]=[source[@"color"][i] floatValue];
                for(size_t axis=0;axis<2;++axis) vertex.uv[i][axis]=[source[@"uv"][i][axis] floatValue];
            }
            draw.vertices.push_back(vertex);
        }
        for (NSDictionary* texture in stages) {
            size_t stage=draw.fragment.stageCount++;
            assert(stage<2 && [texture[@"stage"] unsignedIntegerValue]==stage && [texture[@"pixels_included"] boolValue]);
            NSString* key=texture[@"source_key"];
            assert([key.lastPathComponent isEqual:key]);
            NSData* data=[NSData dataWithContentsOfFile:[[auditPath stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:[key stringByAppendingString:@".rgba"]]];
            assert(data.length==32*128*4);
            const auto* begin=static_cast<const u8*>(data.bytes);
            draw.textureRGBA[stage].assign(begin,begin+data.length);
            draw.textureWidths[stage]=[texture[@"width"] unsignedIntValue]; draw.textureHeights[stage]=[texture[@"height"] unsignedIntValue];
            draw.textureFormats[stage]=[texture[@"gx_format"] unsignedIntValue]; draw.textureModes[stage]=[texture[@"gx_mode"] unsignedIntValue];
            draw.textureCoordinates[stage]=[texture[@"uv_set"] unsignedIntValue]; draw.textureUnits[stage]=[texture[@"texture_unit"] unsignedIntValue];
            draw.fragment.colorCombiners[stage]=[texture[@"color_combiner"] unsignedIntValue];
            draw.fragment.alphaCombiners[stage]=[texture[@"alpha_combiner"] unsignedIntValue];
            assert([key isEqual:InterfaceTextureKey(TexturePixels(draw,stage),32,128)]);
        }
        selected.push_back(draw); [selectedIndices addObject:record[@"draw_index"]];
    }
    assert(selected.size()==3);
    assert([selectedIndices[1] unsignedIntegerValue]==[selectedIndices[0] unsignedIntegerValue]+1);
    assert([selectedIndices[2] unsignedIntegerValue]==[selectedIndices[0] unsignedIntegerValue]+2);
    auto result=IdentifySharedPanel(selected);
    assert(result.enabled && result.first==0 && result.role(3)==SharedPanelRole::None);
    auto bad=selected; bad[1].textureRGBA[1][1]^=1; assert(!IdentifySharedPanel(bad).enabled);
    bad=selected; std::swap(bad[1],bad[2]); assert(!IdentifySharedPanel(bad).enabled);
    bad=selected; bad.pop_back(); assert(!IdentifySharedPanel(bad).enabled);
    bad=selected; bad.insert(bad.end(),selected.begin(),selected.end()); assert(!IdentifySharedPanel(bad).enabled);
    std::printf("Live shared panel source quads admitted: frame %u, source indices %s; full-frame coverage not claimed\n",
        [audit[@"frame_index"] unsignedIntValue],selectedIndices.description.UTF8String);
}

static void TestFrontendAdmissionAndTransform() {
    for (size_t i = 0; i < kFrontendTextureCount; ++i) {
        const auto& profile = kFrontendTextures[i];
        NSString* mask = profile.auxiliary[0] ? @(profile.auxiliary) : nil;
        assert(FrontendProfileForKeys(@(profile.primary),mask) == (int)i);
        assert(FrontendProfileForKeys(@(profile.primary),@"wrong-mask") == -1);
        if (mask) assert(FrontendProfileForKeys(@(profile.primary),nil) == -1);
    }
    assert(FrontendProfileForKeys(nil,nil) == -1);
    std::vector<int> prefix{0};
    for (int i = 0; i < 48; ++i) { prefix.push_back(1); prefix.push_back(2); }
    assert(AdmitFrontendProfiles(prefix).enabled);
    auto partialBackground=prefix; partialBackground.pop_back();
    assert(!AdmitFrontendProfiles(partialBackground).enabled);
    partialBackground=prefix; partialBackground[42]=1;
    assert(!AdmitFrontendProfiles(partialBackground).enabled);
    auto title = prefix;
    title.insert(title.end(),{3,4,5,19});
    assert(AdmitFrontendProfiles(title).enabled && !AdmitFrontendProfiles(title).menu);
    auto menu = prefix;
    for (int i = 6; i <= 18; ++i) menu.push_back(i);
    menu.insert(menu.end(),{4,5,19,19,19,20});
    assert(AdmitFrontendProfiles(menu).enabled && AdmitFrontendProfiles(menu).menu);
    auto transition = menu;
    transition.insert(transition.end(),{3,4,5,19});
    assert(AdmitFrontendProfiles(transition).enabled);
    for (size_t i = 0; i < menu.size(); ++i) {
        auto missing = menu; missing[i] = -1;
        assert(!AdmitFrontendProfiles(missing).enabled);
    }
    auto wrong = title; wrong[3] = 2; assert(!AdmitFrontendProfiles(wrong).enabled);
    wrong = title; wrong.erase(wrong.begin()+97); assert(!AdmitFrontendProfiles(wrong).enabled);
    wrong = menu; wrong.erase(wrong.begin()+97); assert(!AdmitFrontendProfiles(wrong).enabled);
    wrong = title; wrong.push_back(0); assert(!AdmitFrontendProfiles(wrong).enabled);
    assert(!AdmitFrontendProfiles(std::vector<int>(193,0)).enabled);

    auto panel = prefix;
    panel.insert(panel.end(),{6,7,8,9,10,11,12,13,14,15,16,17,17,17,17,
        18,18,18,18,4,5,21,21,21,21,23,22,22,22,22,24,19,19,20});
    assert(AdmitFrontendProfiles(panel).enabled && AdmitFrontendProfiles(panel).secondary);
    auto enteringPanel=panel;
    enteringPanel.erase(enteringPanel.begin()+128,enteringPanel.end());
    enteringPanel.push_back(20); // source frame 1523: heading not present yet
    assert(AdmitFrontendProfiles(enteringPanel).secondary);
    assert(AdmitFrontendProfiles(enteringPanel).panelFill==122);
    auto leavingPanel=enteringPanel;
    leavingPanel.erase(leavingPanel.begin()+118,leavingPanel.begin()+127);
    assert(AdmitFrontendProfiles(leavingPanel).secondary); // source frame 1631
    assert(AdmitFrontendProfiles(leavingPanel).panelFill==SIZE_MAX);
    auto options = panel; options[127] = 25;
    assert(AdmitFrontendProfiles(options).secondary);
    auto audio = options;
    audio.insert(audio.begin()+128,{26,26,26,26,27,27,27,27});
    assert(AdmitFrontendProfiles(audio).secondary);
    for (const auto* valid : {&panel,&options,&audio}) {
        for (size_t i=0; i<valid->size(); ++i) {
            wrong = *valid; wrong[i] = -1;
            assert(!AdmitFrontendProfiles(wrong).enabled);
        }
        for (size_t i=97; i<128; ++i) {
            wrong = *valid; wrong.erase(wrong.begin()+i);
            assert(!AdmitFrontendProfiles(wrong).enabled);
        }
    }
    wrong = audio; wrong[127] = 24; assert(!AdmitFrontendProfiles(wrong).enabled);
    wrong = audio; std::swap(wrong[131],wrong[132]); assert(!AdmitFrontendProfiles(wrong).enabled);
    wrong = panel; wrong.push_back(23); assert(!AdmitFrontendProfiles(wrong).enabled);
    wrong = menu; wrong.push_back(24); assert(!AdmitFrontendProfiles(wrong).enabled);
    wrong = title; wrong.push_back(21); assert(!AdmitFrontendProfiles(wrong).enabled);

    LiveDraw source;
    source.viewportHeight = 448; source.depthMode = 15; source.blendMode = 13501;
    source.projectionWords = {994888909,2147483648,3146926373,0,3131299594,3212627148,1};
    source.fragment.alphaTest = 4128768; source.fragment.stageCount = 1;
    source.textureFormats[0] = 14; source.textureModes[0] = 2097360;
    source.fragment.colorCombiners[0] = 64143; source.fragment.alphaCombiners[0] = 63088;
    source.indexed = true; source.indices = {0,1,2,0,2,3};
    constexpr float uv[][2] = {{0,0},{1,0},{1,1},{0,1}};
    for (const auto& corner : uv) {
        LiveVertex vertex{};
        vertex.position[0] = 2*corner[0]-1;
        vertex.position[1] = corner[1] ? -1.0625f : 1.0669643879f;
        vertex.position[2] = 0.00625; vertex.position[3] = 1;
        std::copy(corner,corner+2,vertex.uv[0]); std::fill(vertex.color,vertex.color+4,1);
        source.vertices.push_back(vertex);
    }
    assert(FrontendDrawStateMatches(source,FrontendRole::Background));
    auto reject = [&](auto mutate) { auto changed = source; mutate(changed);
        assert(!FrontendDrawStateMatches(changed,FrontendRole::Background)); };
    reject([](auto& d) { d.projectionWords[0]++; });
    reject([](auto& d) { d.textureModes[0]++; });
    reject([](auto& d) { d.fragment.indirectCount = 1; });
    reject([](auto& d) { d.vertices[0].uv[0][0] = 0.1; });
    reject([](auto& d) { d.vertices[0].position[0] = -0.9; });
    reject([](auto& d) { d.indices[1] = 2; });
    reject([](auto& d) { d.vertices[0].position[3] = NAN; });
    reject([](auto& d) { d.vertices[0].color[3] = 2; });
    reject([](auto& d) { d.viewportHeight = 480; });
    reject([](auto& d) { d.blendMode = 13373; });
    reject([](auto& d) { d.textureFormats[0] = 9; });
    auto bubble = source;
    assert(FrontendDrawStateMatches(bubble,FrontendRole::Bubble,kFrontendTextures[1].blend));
    assert(!FrontendDrawStateMatches(bubble,FrontendRole::Bubble,kFrontendTextures[2].blend));
    bubble.blendMode = 13373;
    assert(!FrontendDrawStateMatches(bubble,FrontendRole::Bubble,kFrontendTextures[1].blend));
    assert(FrontendDrawStateMatches(bubble,FrontendRole::Bubble,kFrontendTextures[2].blend));
    assert(!IdentifyFrontend(std::vector<LiveDraw>(101,source),{}).enabled);

    for (const auto& profile : kFrontendTextures) {
        const LiveVertex original = source.vertices[0];
        LiveVertex identity = original;
        TransformFrontendVertex(&identity,profile.role,4.0/3,0.35,true);
        assert(memcmp(&identity,&original,sizeof(identity)) == 0);
        for (double invalid : {double(NAN),double(INFINITY),1.0,4.0}) {
            identity = original; TransformFrontendVertex(&identity,profile.role,invalid,0.35,true);
            assert(memcmp(&identity,&original,sizeof(identity)) == 0);
        }
        for (double aspect : {16.0/9,2.17,3.0}) {
            auto left = original, right = original;
            right.position[0] += 0.25; right.position[1] += 0.5;
            TransformFrontendVertex(&left,profile.role,aspect,0.35,true);
            TransformFrontendVertex(&right,profile.role,aspect,0.35,true);
            // Physical width/height ratio is preserved even for the cover crop.
            const double actual = (right.position[0]-left.position[0])*aspect /
                (right.position[1]-left.position[1]);
            assert(std::abs(actual - (0.25*(4.0/3)/0.5)) < 0.00001);
            assert(left.position[2] == original.position[2] && left.position[3] == original.position[3]);
            assert(memcmp(left.uv,original.uv,sizeof(left.uv)) == 0);
            assert(memcmp(left.color,original.color,sizeof(left.color)) == 0);
        }
    }
    LiveVertex art = source.vertices[0], text = art;
    TransformFrontendVertex(&art,FrontendRole::MenuArt,2.17,0,true);
    TransformFrontendVertex(&text,FrontendRole::Text,2.17,0,true);
    assert(memcmp(&art,&text,sizeof(art)) == 0);
    for (double aspect : {16.0/9,2.17,3.0}) {
        auto edge = source.vertices[0]; edge.position[0] = 1.06875002384f;
        TransformFrontendVertex(&edge,FrontendRole::MenuArt,aspect,0,true);
        assert(edge.position[0] >= 1); // No exposed right-hand bezel cut.
        auto logo = source.vertices[0], subtitle = logo, titleLogo = logo;
        TransformFrontendVertex(&logo,FrontendRole::Logo,aspect,0,true);
        TransformFrontendVertex(&subtitle,FrontendRole::Subtitle,aspect,0,true);
        TransformFrontendVertex(&titleLogo,FrontendRole::Logo,aspect,0,false);
        assert(memcmp(&logo,&subtitle,sizeof(logo)) == 0);
        assert(titleLogo.position[1] == source.vertices[0].position[1]);
        assert(logo.position[1] > titleLogo.position[1]);
        auto labelEdge = source.vertices[0]; labelEdge.position[0] = 0.703125f;
        TransformFrontendVertex(&labelEdge,FrontendRole::Text,aspect,0,true);
        assert(labelEdge.position[0] < 0.88f); // Longest observed selected row stays in frame.
    }
    std::puts("Frontend tuple/state admission, source identity and proportional layout tests passed");

    for (const auto& profile : kFrontendTextures) {
        const LiveVertex original = source.vertices[0];
        for (double invalid : {double(NAN),double(INFINITY),1.0,4.0,4.0/3}) {
            auto identity = original;
            TransformSecondaryFrontendVertex(&identity,profile.role,invalid,-1,1,0.3f);
            assert(memcmp(&identity,&original,sizeof(identity)) == 0);
        }
        for (double aspect : {16.0/9,2.17,3.0}) {
            auto left = original, right = original;
            right.position[0] += 0.1f; right.position[1] += 0.5f;
            TransformSecondaryFrontendVertex(&left,profile.role,aspect,-1,-0.9f,0.3f);
            TransformSecondaryFrontendVertex(&right,profile.role,aspect,-1,-0.9f,0.3f);
            if (profile.role != FrontendRole::PanelFill) {
                const double actual = (right.position[0]-left.position[0])*aspect /
                    (right.position[1]-left.position[1]);
                assert(std::abs(actual - (0.1*(4.0/3)/0.5)) < 0.00001);
            }
        }
    }
    for (double aspect : {16.0/9,2.17,3.0}) {
        auto heatEdge = source.vertices[0], xlrEdge = heatEdge;
        heatEdge.position[0] = 1.00625002384f; xlrEdge.position[0] = -1;
        TransformSecondaryFrontendVertex(&heatEdge,FrontendRole::Heatblast,aspect,0.40625f,1.00625f,0);
        TransformSecondaryFrontendVertex(&xlrEdge,FrontendRole::XLR8,aspect,-1,0.6f,0);
        assert(heatEdge.position[0] >= 1 && xlrEdge.position[0] <= -1);
        auto label = source.vertices[0], track = label, knob = label;
        TransformSecondaryFrontendVertex(&label,FrontendRole::AuxiliaryText,aspect,-1,1,0.14f);
        TransformSecondaryFrontendVertex(&track,FrontendRole::SliderTrack,aspect,-1,1,0.14f);
        TransformSecondaryFrontendVertex(&knob,FrontendRole::SliderKnob,aspect,-1,1,0.14f);
        assert(memcmp(&label,&track,sizeof(label)) == 0 && memcmp(&label,&knob,sizeof(label)) == 0);
        auto corner = source.vertices[0], span = corner;
        TransformSecondaryFrontendVertex(&corner,FrontendRole::PanelCorner,aspect,-1,-0.8,0);
        TransformSecondaryFrontendVertex(&span,FrontendRole::PanelStrip,aspect,-1,1,0);
        assert(std::abs(corner.position[0]-span.position[0]) < 0.000001);
    }
    std::puts("Secondary panel completeness, 4:3 identity, proportional content and span registration tests passed");
    for (double aspect : {double(NAN),double(INFINITY),1.0,4.0,4.0/3}) {
        auto unchanged = source.vertices[0];
        TransformGalleryLayoutVertex(&unchanged,FrontendRole::XLR8,aspect,-2.3625f,-.7625f,-.3f);
        assert(memcmp(&unchanged,&source.vertices[0],sizeof(unchanged)) == 0);
    }
    for (double aspect : {16.0/9,2.17,3.0}) {
        auto left = source.vertices[0], right = left;
        left.position[0] = -1; right.position[0] = .6f;
        TransformGalleryLayoutVertex(&left,FrontendRole::XLR8,aspect,-1,.6f,-.3f);
        TransformGalleryLayoutVertex(&right,FrontendRole::XLR8,aspect,-1,.6f,-.3f);
        assert(std::abs(left.position[0]+1) < .000001);
        assert(std::abs((right.position[0]-left.position[0])*aspect-1.6f*4/3) < .000001);
        auto exit = source.vertices[0]; exit.position[0] = -.7625f;
        TransformGalleryLayoutVertex(&exit,FrontendRole::XLR8,aspect,-2.3625f,-.7625f,-.3f);
        assert(exit.position[0] < -1);
    }
    assert(!IdentifyGalleryLayout({},{}).enabled);
    std::puts("Scene-menu 4:3 identity, invalid-aspect fallback, proportional character and source exit tests passed");
}

static void TestQTEObjectAndGlyphBoundaries() {
    // Synthetic admission boundaries, not a translated encounter result.
    for(const auto& object:kQTEObjects) {
        assert(QTERoleForPair(@(object.primary),@(object.coverage))==object.role);
        assert(QTERoleForPair(@(object.coverage),@(object.primary))==QTEObjectRole::None);
        assert(QTERoleForPair(@(object.primary),nil)==QTEObjectRole::None);
        assert(QTERoleForPair(@(object.primary),@"128x128-unknown")==QTEObjectRole::None);
    }
    LiveDraw draw;draw.indexed=true;draw.indices={0,1,2,0,2,3};draw.vertices.resize(4);
    draw.projectionWords[6]=1;draw.blendMode=13501;draw.depthMode=15;
    draw.fragment.stageCount=2;draw.fragment.alphaTest=4128768;
    draw.fragment.colorCombiners[0]=64143;draw.fragment.colorCombiners[1]=589808;
    draw.fragment.alphaCombiners[0]=65520;draw.fragment.alphaCombiners[1]=63100;
    draw.fragment.textureAlphaChannels[1]=1;draw.fragment.rasterAlphaChannels[1]=3;
    draw.textureFormats[0]=draw.textureFormats[1]=14;draw.textureUnits[1]=1;
    draw.textureWidths[0]=draw.textureHeights[0]=draw.textureWidths[1]=draw.textureHeights[1]=128;
    for(size_t i=0;i<4;++i) {
        auto& v=draw.vertices[i];v.position[0]=(i==0 || i==3)?-.2f:.2f;
        v.position[1]=i<2?-.2f:.2f;v.position[3]=1;
        for(float& c:v.color)c=1;
    }
    assert(QTEPictureState(draw));
    auto changed=draw;changed.fragment.textureAlphaChannels[1]=3;assert(!QTEPictureState(changed));
    changed=draw;changed.fragment.stageCount=1;assert(!QTEPictureState(changed));
    changed=draw;changed.vertices[0].uv[1][0]=.25;assert(!QTEPictureState(changed));
    changed=draw;for(auto& v:changed.vertices)v.color[3]=0;assert(!QTEPictureState(changed));
    assert(!IdentifyQTE({draw}).prompts); // Shapes alone cannot admit a prompt.
    QTEAdmission bounds;
    assert(CGRectIsNull(QTENativeTargetRect(bounds,4.0/3.0)));
    bounds.targetClipRect=CGRectMake(-.4,-.8,.2,.2);
    const CGRect normal=QTENativeTargetRect(bounds,4.0/3.0);
    const CGRect wide=QTENativeTargetRect(bounds,874.0/402.0);
    assert(fabs(normal.origin.x-.3)<1e-6 && fabs(normal.origin.y-.8)<1e-6);
    assert(fabs(normal.size.width-.1)<1e-6 && fabs(normal.size.height-.1)<1e-6);
    assert(wide.origin.x>normal.origin.x && wide.size.width<normal.size.width);
    assert(wide.origin.y==normal.origin.y && wide.size.height==normal.size.height);
    assert(CGRectIsNull(QTENativeTargetRect(bounds,NAN)));
    bounds.motionClipRect=CGRectMake(-.9,-.8,.6,.2);
    LiveVertex motion{};motion.position[0]=-.9;motion.position[1]=-.8;motion.position[3]=1;
    const auto unchanged=motion;
    FitQTEMotionVertex(&motion,bounds,4.0/3.0,CGRectZero);
    assert(!memcmp(&motion,&unchanged,sizeof(motion)));
    FitQTEMotionVertex(&motion,bounds,4.0/3.0,CGRectMake(.2,0,.5,1));
    assert(fabs(motion.position[0]+.6)<1e-6 && motion.position[1]==unchanged.position[1]);
    motion=unchanged;
    FitQTEMotionVertex(&motion,bounds,4.0/3.0,CGRectMake(.3,0,.15,1));
    assert(fabs(motion.position[0]+.4)<1e-6 && fabs(motion.position[1]+.75)<1e-6);
    assert(motion.position[3]==1);
    const auto glyph=CreateQTEGlyphTextures(MTLCreateSystemDefaultDevice());
    std::vector<u8> color(512*512*4),coverage(color.size());
    assert(glyph[0] && glyph[1]);
    [glyph[0] getBytes:color.data() bytesPerRow:512*4 fromRegion:MTLRegionMake2D(0,0,512,512) mipmapLevel:0];
    [glyph[1] getBytes:coverage.data() bytesPerRow:512*4 fromRegion:MTLRegionMake2D(0,0,512,512) mipmapLevel:0];
    size_t visible=0,clear=0;
    for(size_t p=0;p<color.size();p+=4) {
        assert(color[p+3]==255 && coverage[p+3]==255);
        assert(coverage[p]==coverage[p+1] && coverage[p+1]==coverage[p+2]);
        visible+=coverage[p+1]>0;clear+=coverage[p+1]==0;
    }
    assert(visible>10000 && clear>50000);
    assert(!strcmp(protector_qte_instruction(PROTECTOR_QTE_PAIRED_MOTION,1,0),"Hold both triggers"));
    assert(!strcmp(protector_qte_instruction(PROTECTOR_QTE_POINTER_TARGET,0,0),"Drag onto the target"));
    assert(!*protector_qte_instruction(0,0,0));
    std::puts("QTE exact-pair, shader-channel, visibility and authored two-plane glyph boundaries passed (synthetic).");
}

static void TestSceneAntialiasBoundary() {
    LiveDraw scene, ui, offscreen;
    scene.viewportWidth=640;scene.viewportHeight=448;
    ui=scene;ui.projectionWords[6]=1;ui.vertices.resize(3);
    offscreen=scene;offscreen.viewportWidth=offscreen.viewportHeight=256;
    LiveEfbCopy display{};display.command=1u<<14;display.drawIndex=3;
    std::vector<LiveDraw> draws{offscreen,scene,ui};
    assert(IdentifySceneAntialiasBoundary(draws,{display}).enabled);
    assert(IdentifySceneAntialiasBoundary(draws,{display}).index==2);
    assert(!IdentifySceneAntialiasBoundary({ui},{display}).enabled);
    assert(!IdentifySceneAntialiasBoundary({ui,scene,ui},{display}).enabled);
    assert(!IdentifySceneAntialiasBoundary({scene,ui,offscreen},{display}).enabled);
    assert(!IdentifySceneAntialiasBoundary(draws,{}).enabled);
    auto late=display;late.command=0x1000B;late.drawIndex=2;
    assert(!IdentifySceneAntialiasBoundary(draws,{late,display}).enabled);
    late.drawIndex=1;assert(IdentifySceneAntialiasBoundary(draws,{late,display}).enabled);
    display.drawIndex=1;assert(!IdentifySceneAntialiasBoundary(draws,{display}).enabled);
    display.drawIndex=2;assert(!IdentifySceneAntialiasBoundary({scene,scene},{display}).enabled);
}

static void TestSceneAntialiasIntegration() {
    NSError* error=nil;
    NSURL* output=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"protector-aa-test-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    ProtectorLiveMetalRenderer* renderer=[[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:MTLCreateSystemDefaultDevice() outputDirectory:output
        texturePackManifest:nil presentationUpgrades:YES error:&error];
    assert(renderer && !error && [renderer selectWidescreen:YES error:&error]);
    // Synthetic color inputs exercise the real encoder boundary without
    // depending on proprietary artwork or model-pack fixtures.
    renderer.restoredArtworkEnabled=YES;renderer.enhancedModelsEnabled=YES;
    LiveDraw scene;
    scene.viewportWidth=640;scene.viewportHeight=448;scene.sourceVertexCount=3;
    scene.fragment.stageCount=1;scene.fragment.colorCombiners[0]=0x8F8DF;
    scene.fragment.alphaCombiners[0]=0x80000|(7u<<13)|(7u<<10)|(7u<<7)|(4u<<4);
    scene.fragment.textureAlphaChannels[0]=3;
    for(size_t stage=0;stage<8;++stage) {
        scene.textureWidths[stage]=scene.textureHeights[stage]=1;
        scene.textureRGBA[stage]={220,220,220,255};
        std::fill(scene.fragment.textureDimensions[stage],scene.fragment.textureDimensions[stage]+4,1.f);
    }
    for(const auto& p:std::array<std::array<float,2>,3>{{{{-.9f,-.8f}},{{.9f,-.4f}},{{-.9f,.9f}}}}) {
        LiveVertex vertex{};vertex.position[0]=p[0];vertex.position[1]=p[1];vertex.position[3]=1;
        std::fill(vertex.color,vertex.color+4,1.f);scene.vertices.push_back(vertex);
    }
    LiveDraw hud=scene;hud.projectionWords[6]=1;hud.sourceVertexCount=6;hud.vertices.clear();
    hud.textureRGBA[0]={16,220,32,255};
    const float corners[6][2]={{-.3f,.3f},{.3f,.3f},{-.3f,.8f},{-.3f,.8f},{.3f,.3f},{.3f,.8f}};
    for(const auto& p:corners) {
        LiveVertex vertex{};vertex.position[0]=p[0];vertex.position[1]=p[1];vertex.position[3]=1;
        std::fill(vertex.color,vertex.color+4,1.f);hud.vertices.push_back(vertex);
    }
    LiveEfbCopy copy{};copy.drawIndex=2;copy.command=1u<<14;copy.yScale=256;copy.width=640;copy.height=448;
    std::vector<LiveDraw> draws{scene,hud};const auto originalVertices=scene.vertices;
    auto capture=[&](bool enabled) {
        renderer.sceneAntialiasEnabled=enabled;
        assert([renderer renderDraws:draws efbCopies:{copy} frame:42 error:&error] && !error);
        assert([renderer.stateCapture[@"scene_antialias"][@"applied"] boolValue]==enabled);
        std::vector<u8> pixels(640*448*4);
        [renderer.latestPresentationTexture getBytes:pixels.data() bytesPerRow:640*4
            fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
        return pixels;
    };
    const auto baseline=capture(false),filtered=capture(true),again=capture(false);
    assert(baseline==again && baseline!=filtered);
    renderer.renderTargetOptimizationsEnabled=NO;
    const auto legacyFiltered=capture(true);
    assert(filtered==legacyFiltered);
    renderer.renderTargetOptimizationsEnabled=YES;
    renderer.asynchronousPresentationRender=YES;
    assert([renderer renderDraws:draws efbCopies:{copy} frame:42 error:&error] && !error);
    [renderer.latestRenderCommand waitUntilCompleted];
    assert(renderer.latestTexture.storageMode==MTLStorageModePrivate);
    assert(renderer.latestPresentationTexture.storageMode==MTLStorageModePrivate);
    std::vector<u8> privatePixels(filtered.size());
    [ReadableTexture(renderer.latestPresentationTexture,&error) getBytes:privatePixels.data() bytesPerRow:640*4
        fromRegion:MTLRegionMake2D(0,0,640,448) mipmapLevel:0];
    assert(!error && privatePixels==legacyFiltered);
    assert([renderer writeLatestFrameToURL:[output URLByAppendingPathComponent:@"private-aa.png"] error:&error]);
    renderer.asynchronousPresentationRender=NO;
    // Repeat the lossless comparison at the phone's current 5x workload.
    renderer.renderScale=5;
    auto captureHigh=[&](bool optimized) {
        renderer.renderTargetOptimizationsEnabled=optimized;
        renderer.asynchronousPresentationRender=optimized;
        assert([renderer renderDraws:draws efbCopies:{copy} frame:43 error:&error] && !error);
        [renderer.latestRenderCommand waitUntilCompleted];
        std::vector<u8> pixels(3200*2240*4);
        [ReadableTexture(renderer.latestPresentationTexture,&error) getBytes:pixels.data() bytesPerRow:3200*4
            fromRegion:MTLRegionMake2D(0,0,3200,2240) mipmapLevel:0];
        assert(!error);
        return pixels;
    };
    const auto highLegacy=captureHigh(false),highOptimized=captureHigh(true);
    assert(highLegacy==highOptimized);
    renderer.asynchronousPresentationRender=NO;
    for(size_t y=50;y<150;++y)for(size_t x=260;x<380;++x) {
        const size_t p=(y*640+x)*4;
        assert(!memcmp(baseline.data()+p,filtered.data()+p,4));
        assert(filtered[p+1]==110 && filtered[p]==16 && filtered[p+2]==8);
    }
    assert(!memcmp(draws[0].vertices.data(),originalVertices.data(),originalVertices.size()*sizeof(LiveVertex)));
    std::puts("Scene AA real encoder off/on/off, untouched overlay, source vertices and 1x/5x lossless private-target comparisons passed (synthetic).");
}

static void TestSceneAntialiasGPU() {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);
    NSError* error=nil;
    id<MTLLibrary> library=[device newLibraryWithSource:[ProtectorLiveShaderSource
        stringByAppendingString:@(ProtectorSceneAntialiasShader)] options:nil error:&error];
    if(!library)fprintf(stderr,"AA shader: %s\n",error.localizedDescription.UTF8String);
    assert(library && !error);
    MTLRenderPipelineDescriptor* description=[MTLRenderPipelineDescriptor new];
    description.vertexFunction=[library newFunctionWithName:@"live_present_vertex"];
    description.fragmentFunction=[library newFunctionWithName:@"live_scene_antialias_fragment"];
    description.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:description error:&error];
    assert(pipeline && !error);
    MTLSamplerDescriptor* sampling=[MTLSamplerDescriptor new];
    sampling.minFilter=sampling.magFilter=MTLSamplerMinMagFilterLinear;
    sampling.sAddressMode=sampling.tAddressMode=MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler=[device newSamplerStateWithDescriptor:sampling];
    id<MTLCommandQueue> queue=[device newCommandQueue];
    auto process=[&](const std::vector<u8>& pixels,NSUInteger side) {
        MTLTextureDescriptor* textureDescription=[MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:side height:side mipmapped:NO];
        textureDescription.storageMode=MTLStorageModeShared;textureDescription.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> source=[device newTextureWithDescriptor:textureDescription];
        textureDescription.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> target=[device newTextureWithDescriptor:textureDescription];assert(source && target);
        [source replaceRegion:MTLRegionMake2D(0,0,side,side) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:side*4];
        MTLRenderPassDescriptor* pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLCommandBuffer> command=[queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
        const float scale[2]={1,1};
        [encoder setRenderPipelineState:pipeline];[encoder setVertexBytes:scale length:sizeof(scale) atIndex:0];
        [encoder setFragmentTexture:source atIndex:0];[encoder setFragmentSamplerState:sampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[encoder endEncoding];
        [command commit];[command waitUntilCompleted];assert(!command.error);
        std::vector<u8> output(pixels.size());
        [target getBytes:output.data() bytesPerRow:side*4 fromRegion:MTLRegionMake2D(0,0,side,side) mipmapLevel:0];
        std::vector<u8> original(pixels.size());
        [source getBytes:original.data() bytesPerRow:side*4 fromRegion:MTLRegionMake2D(0,0,side,side) mipmapLevel:0];
        assert(original==pixels);return output;
    };
    for(NSUInteger side:{1u,2u,128u}) {
        std::vector<u8> solid(side*side*4,89);assert(process(solid,side)==solid);
    }
    const NSUInteger side=128;std::vector<u8> input(side*side*4,255);
    for(int mode=0;mode<4;++mode) {
        for(NSUInteger y=0;y<side;++y)for(NSUInteger x=0;x<side;++x) {
            const bool ink=mode==0?x<64:mode==1?y<64:mode==2?y<24+x/3:y<24+x/3;
            const u8 value=mode==3?(ink?100:104):(ink?16:240);
            for(size_t c=0;c<3;++c)input[(y*side+x)*4+c]=value;
            input[(y*side+x)*4+3]=(u8)((x+y)%256);
        }
        const auto output=process(input,side);assert(process(input,side)==output);
        size_t changed=0;
        for(size_t p=0;p<input.size();p+=4) {
            assert(output[p+3]==input[p+3]);
            assert(output[p]>=16 && output[p]<=240 && output[p]==output[p+1] && output[p+1]==output[p+2]);
            changed+=output[p]!=input[p];
        }
        if(mode==2) assert(changed>50 && changed<400);
        else assert(changed==0);
    }
    std::puts("Scene AA bounded ordering and GPU edge/flat/axis/alpha/source-preservation tests passed (synthetic).");
}

static void TestDirectShaderSpecialization() {
    LiveFragmentUniforms state;
    assert(!DirectShaderStages(state));
    state.stageCount=1;assert(DirectShaderStages(state)==1);
    state.stageCount=2;assert(DirectShaderStages(state)==2);
    state.stageCount=3;assert(!DirectShaderStages(state));
    state.stageCount=2;state.indirectCount=1;assert(!DirectShaderStages(state));
    state.indirectCount=0;state.indirectCommands[1]=1u<<13;assert(!DirectShaderStages(state));
    state.indirectCommands[1]=0;state.alphaTest^=1;assert(!DirectShaderStages(state));

    NSError* error=nil;
    NSURL* output=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"protector-direct-shader-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
    ProtectorLiveMetalRenderer* renderer=[[ProtectorLiveMetalRenderer alloc]
        initContinuousWithDevice:MTLCreateSystemDefaultDevice() outputDirectory:output
        texturePackManifest:nil presentationUpgrades:YES error:&error];
    assert(renderer && !error);
    renderer.sceneAntialiasEnabled=NO;
    LiveDraw draw;
    draw.viewportWidth=640;draw.viewportHeight=448;draw.sourceVertexCount=6;
    const float corners[6][2]={{-1,-1},{1,-1},{-1,1},{-1,1},{1,-1},{1,1}};
    for (const auto& p:corners) {
        LiveVertex vertex{};vertex.position[0]=p[0];vertex.position[1]=p[1];
        vertex.position[2]=.25;vertex.position[3]=1;
        for (size_t stage=0;stage<4;++stage) {
            vertex.uv[stage][0]=(p[0]+1)*1.37f-.25f;
            vertex.uv[stage][1]=(p[1]+1)*.71f;
        }
        vertex.color[0]=.73;vertex.color[1]=.31;vertex.color[2]=.87;vertex.color[3]=.59;
        draw.vertices.push_back(vertex);
    }
    for (size_t stage=0;stage<8;++stage) {
        draw.textureWidths[stage]=draw.textureHeights[stage]=8;
        draw.textureModes[stage]=0x91;
        for (size_t p=0;p<64;++p) {
            draw.textureRGBA[stage].push_back((u8)(p*3+stage*17));
            draw.textureRGBA[stage].push_back((u8)(255-p*2));
            draw.textureRGBA[stage].push_back((u8)(p*5+11));
            draw.textureRGBA[stage].push_back((u8)(p*4));
        }
        std::fill(draw.fragment.textureDimensions[stage],draw.fragment.textureDimensions[stage]+4,8.f);
    }
    const auto originalVertices=draw.vertices;
    LiveEfbCopy copy{};copy.drawIndex=1;copy.command=1u<<14;copy.yScale=256;copy.width=640;copy.height=448;
    auto capture=[&](bool specialized) {
        renderer.shaderSpecializationEnabled=specialized;
        assert([renderer renderDraws:{draw} efbCopies:{copy} frame:123 error:&error] && !error);
        [renderer.latestRenderCommand waitUntilCompleted];
        const auto expected=specialized && DirectShaderStages(draw.fragment) ? 1u : 0u;
        assert([renderer.stateCapture[@"shader_specialization"][@"specialized_draws"] unsignedIntValue]==expected);
        const NSUInteger width=renderer.latestPresentationTexture.width,height=renderer.latestPresentationTexture.height;
        std::vector<u8> pixels(width*height*4);
        [ReadableTexture(renderer.latestPresentationTexture,&error) getBytes:pixels.data() bytesPerRow:width*4
            fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];
        assert(!error);return pixels;
    };
    const u32 colors[]={64143u,587951u,589808u,0x8F8DFu,0x8F8AFu,0x8F82Fu,0x9F8AFu,0xAF8AFu};
    for (u32 stages:{1u,2u}) for (u32 blend:{0u,13501u,0x309Du,0x313Du,0x801u})
        for (u32 variant=0;variant<8;++variant) {
            draw.fragment.stageCount=stages;draw.blendMode=blend;
            for (u32 stage=0;stage<stages;++stage) {
                draw.fragment.colorCombiners[stage]=colors[(variant+stage)%8];
                draw.fragment.alphaCombiners[stage]=stage?63100u:63088u;
                draw.fragment.textureAlphaChannels[stage]=variant%4;
                draw.fragment.rasterAlphaChannels[stage]=(variant+1)%4;
                for (u32 channel=0;channel<4;++channel)
                    draw.fragment.konstColors[stage][channel]=.1f*(channel+1);
            }
            for (u32 reg=0;reg<3;++reg) for (u32 channel=0;channel<4;++channel)
                draw.fragment.colorRegisters[reg][channel]=.07f*(reg+channel+1);
            const auto generic=capture(false),specialized=capture(true);
            assert(generic==specialized);
        }
    for (u32 negative=0;negative<3;++negative) {
        auto saved=draw.fragment;
        if (negative==0) draw.fragment.alphaTest=0;
        if (negative==1) draw.fragment.indirectCommands[0]=1u<<13;
        if (negative==2) draw.fragment.indirectCount=1;
        assert(!DirectShaderStages(draw.fragment));
        const auto generic=capture(false),fallback=capture(true);assert(generic==fallback);
        draw.fragment=saved;
    }
    renderer.renderScale=5;
    const auto generic5x=capture(false),specialized5x=capture(true);assert(generic5x==specialized5x);
    assert(!memcmp(draw.vertices.data(),originalVertices.data(),originalVertices.size()*sizeof(LiveVertex)));
    if (getenv("PROTECTOR_SHADER_BENCHMARK")) {
        draw.fragment.stageCount=1;draw.fragment.colorCombiners[0]=587951;
        draw.fragment.alphaCombiners[0]=586480;draw.blendMode=13501;
        std::vector<LiveDraw> load(12,draw);copy.drawIndex=load.size();
        std::array<std::vector<double>,2> timings;
        // Alternate warm pairs to limit order bias. This is a synthetic Mac
        // GPU comparison, never a phone FPS or thermal acceptance result.
        for (u32 pair=0;pair<8;++pair) for (u32 turn=0;turn<2;++turn) {
            const bool specialized=(turn^(pair&1))!=0;
            renderer.shaderSpecializationEnabled=specialized;
            assert([renderer renderDraws:load efbCopies:{copy} frame:124 error:&error] && !error);
            [renderer.latestRenderCommand waitUntilCompleted];
            if(pair>1) timings[specialized].push_back(1000*(renderer.latestRenderCommand.GPUEndTime-renderer.latestRenderCommand.GPUStartTime));
        }
        for (auto& values:timings) std::sort(values.begin(),values.end());
        std::printf("Synthetic 5x 12-layer GPU median: generic %.3f ms, specialized %.3f ms (not phone FPS).\n",
            (timings[0][2]+timings[0][3])/2,(timings[1][2]+timings[1][3])/2);
    }
    std::puts("Direct shader specialization: 80 exact pixel comparisons, 3 guarded fallbacks, 5x and unchanged source vertices passed.");
}

// Per-pass GPU timing: one labelled render pass and blit resolve to finite,
// non-negative durations on a GPU with stage-boundary counters.
static void TestPassTimingResolves() {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCounterSet> timestamps = nil;
    for (id<MTLCounterSet> set in device.counterSets)
        if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) timestamps = set;
    if (!device || !timestamps || ![device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
        std::puts("pass timing: stage-boundary counters unavailable; skipped");
        return;
    }
    MTLCounterSampleBufferDescriptor* descriptor = [[MTLCounterSampleBufferDescriptor alloc] init];
    descriptor.counterSet = timestamps;
    descriptor.sampleCount = 96;
    descriptor.storageMode = MTLStorageModeShared;
    ProtectorPassTiming* timing = [[ProtectorPassTiming alloc] init];
    timing.buffer = [device newCounterSampleBufferWithDescriptor:descriptor error:nil];
    timing.kinds = [NSMutableArray array];
    assert(timing.buffer);
    MTLTextureDescriptor* texture = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:256 height:256 mipmapped:NO];
    texture.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    texture.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device newTextureWithDescriptor:texture], copy = [device newTextureWithDescriptor:texture];
    MTLTimestamp cpu0 = 0, gpu0 = 0, cpu1 = 0, gpu1 = 0;
    [device sampleTimestamps:&cpu0 gpuTimestamp:&gpu0];
    id<MTLCommandBuffer> command = [[device newCommandQueue] commandBuffer];
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    [timing attachRender:pass kind:@"scene"];
    [[command renderCommandEncoderWithDescriptor:pass] endEncoding];
    id<MTLBlitCommandEncoder> blit = [timing blitEncoder:command kind:@"copy-blit"];
    [blit copyFromTexture:target toTexture:copy];
    [blit endEncoding];
    [timing attachRender:pass kind:@"scene-resume"];
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    [[command renderCommandEncoderWithDescriptor:pass] endEncoding];
    [command commit];
    [command waitUntilCompleted];
    assert(command.status == MTLCommandBufferStatusCompleted);
    [device sampleTimestamps:&cpu1 gpuTimestamp:&gpu1];
    const double secondsPerTick = gpu1 > gpu0 ? (double)(cpu1 - cpu0) * 1e-9 / (double)(gpu1 - gpu0) : 0;
    NSDictionary* passes = [timing resolveWithSecondsPerTick:secondsPerTick];
    assert(passes && [passes[@"passes"] unsignedIntegerValue] == 3);
    for (NSString* kind in @[@"scene", @"copy-blit", @"scene-resume"]) {
        const double ms = [passes[@"ms"][kind] doubleValue];
        assert(std::isfinite(ms) && ms >= 0 && ms < 1000);
        assert([passes[@"count"][kind] unsignedIntegerValue] == 1);
    }
    std::printf("pass timing: %s\n", [[passes description] UTF8String]);
}

// Captured fire-tornado frame 1927 (41_01): the game copies the whole screen,
// blurs it through a downsampled chain and composites it back with full-screen
// orthographic quads. Those quads must stay full width, not move to 4:3.
static void TestScreenCopyCompositeStaysFullWidth() {
    const auto quad = [](u32 stages) {
        LiveDraw draw;
        draw.viewportWidth = 640; draw.viewportHeight = 448;
        draw.projectionWords[6] = 1u;
        draw.fragment.stageCount = stages;
        const float corners[4][2] = {{-1, 1}, {1, 1}, {1, -1}, {-1, -1}};
        for (const auto& corner : corners) {
            LiveVertex vertex{};
            vertex.position[0] = corner[0]; vertex.position[1] = corner[1]; vertex.position[3] = 1;
            for (u32 stage = 0; stage < stages; ++stage) {
                vertex.uv[stage][0] = corner[0] > 0 ? 1 : 0;
                vertex.uv[stage][1] = corner[1] > 0 ? 0 : 1;
            }
            draw.vertices.push_back(vertex);
        }
        return draw;
    };
    std::vector<LiveEfbCopy> copies(2);
    copies[0].width = 640; copies[0].height = 448; copies[0].destinationAddress = 0x10010000u;
    copies[1].width = 320; copies[1].height = 224; copies[1].destinationAddress = 0x10120000u;
    std::vector<LiveDraw> draws = {quad(2), quad(1), quad(1)};
    draws[0].textureAddresses[0] = 0x10120000u; draws[0].textureWidths[0] = 320; draws[0].textureHeights[0] = 224;
    draws[0].textureAddresses[1] = 0x10010000u; draws[0].textureWidths[1] = 640; draws[0].textureHeights[1] = 448;
    draws[1].textureAddresses[0] = 0x10010000u; draws[1].textureWidths[0] = 640; draws[1].textureHeights[0] = 448;
    // Menu art at the same size but not a screen copy keeps its centred safe area.
    draws[2].textureAddresses[0] = 0x80400000u; draws[2].textureWidths[0] = 640; draws[2].textureHeights[0] = 448;
    MarkScreenCopyComposites(draws, copies);
    assert(draws[0].screenCopyComposite && ClassifyWideDraw(draws[0]) == WideDrawRole::ScreenFill);
    assert(draws[1].screenCopyComposite && ClassifyWideDraw(draws[1]) == WideDrawRole::ScreenFill);
    assert(!draws[2].screenCopyComposite && ClassifyWideDraw(draws[2]) == WideDrawRole::SafeArea);
    // A copy that is not the whole screen (the 256-square shadow window) does not qualify.
    copies[0].width = 256; copies[0].height = 256;
    draws[1].textureWidths[0] = 256; draws[1].textureHeights[0] = 256;
    MarkScreenCopyComposites(draws, copies);
    assert(!draws[1].screenCopyComposite && ClassifyWideDraw(draws[1]) == WideDrawRole::SafeArea);
}

// Projective (STQ) texgen: S/T stay undivided and Q reaches the fragment
// stage, which divides per pixel like GX. A per-vertex divide made projected
// shadows streak across the ground when Q approached zero at some vertices.
static void TestProjectiveTexgenDefersDivide() {
    DecoderState state;
    const auto word = [](float value) { u32 bits; std::memcpy(&bits, &value, sizeof(bits)); return bits; };
    state.xf[0x1040] = 1u << 1u; // texcoord 0: STQ projection, AB11 input, position source
    state.xf[0] = word(1); state.xf[5] = word(1);
    state.xf[8] = word(0.5f); state.xf[11] = word(0.25f); // q = 0.5x + 0.25
    const float normal[3] = {0, 0, 1}, color[4] = {1, 1, 1, 1};
    const float textures[8][3] = {};
    const u32 matrices[8] = {};
    const float position[3] = {2, 3, 7};
    float divided[2] = {}, undivided[2] = {}, q = 0;
    assert(GenerateTextureCoordinate(state, 0, position, normal, textures, matrices, color, divided));
    assert(GenerateTextureCoordinate(state, 0, position, normal, textures, matrices, color, undivided, nullptr, &q));
    assert(divided[0] == 2.0f / 1.25f && divided[1] == 3.0f / 1.25f);
    assert(undivided[0] == 2.0f && undivided[1] == 3.0f && q == 1.25f);
    const float plane[3] = {-0.5f, 3, 7}; // q == 0: same fallback divisor as before
    assert(GenerateTextureCoordinate(state, 0, plane, normal, textures, matrices, color, undivided, nullptr, &q));
    assert(undivided[0] == -0.5f && q == 1.0f);
    state.xf[0x1040] = 0; // non-projective coordinates keep Q = 1
    assert(GenerateTextureCoordinate(state, 0, position, normal, textures, matrices, color, undivided, nullptr, &q));
    assert(undivided[0] == 2.0f && undivided[1] == 3.0f && q == 1.0f);
    const LiveVertex vertex{};
    for (float value : vertex.uvQ) assert(value == 1.0f);
}

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc==2 && !strcmp(argv[1],"--projective-texgen")) { TestProjectiveTexgenDefersDivide(); return 0; }
        if (argc==2 && !strcmp(argv[1],"--screen-copy-composite")) { TestScreenCopyCompositeStaysFullWidth(); return 0; }
        if (argc==2 && !strcmp(argv[1],"--pass-timing")) { TestPassTimingResolves(); return 0; }
        if (argc==2 && !strcmp(argv[1],"--presentation-instrumentation")) {
            TestPresentationInstrumentation();TestMotionPlanOutsideLock();TestShadowWindowRedirect();return 0;
        }
        if (argc==2 && !strcmp(argv[1],"--shader-specialization")) {
            TestDirectShaderSpecialization();return 0;
        }
        if (argc==2 && !strcmp(argv[1],"--scene-antialias")) {
            TestSceneAntialiasBoundary();TestSceneAntialiasGPU();TestSceneAntialiasIntegration();return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--native-resolution")) {
            assert(protector_native_render_scale(2622,1206,640,448) == 5);
            assert(protector_native_render_scale(2752,2064,640,448) == 5);
            assert(protector_native_render_scale(3840,2160,640,448) == 6);
            assert(protector_native_render_scale(1920,1440,640,480) == 3);
            assert(protector_native_render_scale(1921,1440,640,480) == 4);
            assert(protector_native_render_scale(100,100,640,480) == 1);
            assert(!protector_native_render_scale(3841,2160,640,448));
            assert(!protector_native_render_scale(NAN,1206,640,448));
            assert(!protector_native_render_scale(2622,INFINITY,640,448));
            assert(!protector_native_render_scale(0,1206,640,448));
            assert(!protector_native_render_scale(-1,1206,640,448));
            assert(!protector_native_render_scale(2622,1206,0,448));
            assert(!protector_native_render_scale(2622,1206,641,448));
            assert(!protector_native_render_scale(2622,1206,640,481));
            unsigned sx = 0, sy = 0;
            // iPhone 18 Pro widened presentation: 3200x1344 source rows, not 3200x2240.
            assert(protector_native_render_scale_axes(2622,1206,640,448,&sx,&sy) && sx == 4 && sy == 3);
            assert(protector_native_render_scale_axes(2752,2064,640,448,&sx,&sy) && sx == 5 && sy == 5);
            assert(protector_native_render_scale_axes(2560,1344,640,448,&sx,&sy) && sx == 4 && sy == 3);
            assert(protector_native_render_scale_axes(3840,2160,640,448,&sx,&sy) && sx == 6 && sy == 5);
            assert(protector_native_render_scale_axes(1920,1440,640,480,&sx,&sy) && sx == 3 && sy == 3);
            assert(!protector_native_render_scale_axes(3841,2160,640,448,&sx,&sy));
            assert(!protector_native_render_scale_axes(2622,1206,640,448,nullptr,&sy));
            TestPhysicalRenderScaling();
            std::puts("native resolution policy, Metal crop, frozen redraw and rollback tests passed (synthetic)");
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--geometry-admission")) {
            TestGeometryBindAnchor();
            TestRigidGeometrySourceArrays();
            TestRigidTopologyVariantSelection();
            TestGeometryPreview();
            std::puts("geometry admission and render-preview tests passed");
            return 0;
        }
        assert(argc == 1);
        TestDirectShaderSpecialization();
        TestSceneAntialiasBoundary();TestSceneAntialiasGPU();TestSceneAntialiasIntegration();
        TestQTEObjectAndGlyphBoundaries();
        TestPresentationFailureReceipt();
        TestHybridTextureTrilinearSeam();
        TestIntensityAlpha();
        TestPrimitiveIndices();
        TestDecodedIndexedPrimitives();
        TestSignedTevRegisters();
        TestIndexedXFLoads();
        TestCollapsedNormalPrimitives();
        TestOneOneBlendAdmission();
        TestDecodedTextureCache();
        TestPaletteUnitsAndChanges();
        TestCacheBoundsAndBypass();
        TestCachedAndUncachedFormats();
        TestDrawCacheMemoryAndTlutUpload();
        TestTevUsesEncodedComponents();
        TestPhysicalRenderScaling();
        TestAlphaTestAndSubtractiveBlend();
        TestZeroAlphaPictureNoWrites();
        TestFiniteBackdropAdmission();
        TestBoundedSceneSourcePositionAudit();
        TestFiniteRoomFraming();
        TestRepeatingBackdropAdmission();
        TestHillBackdropAdmission();
        TestCanyonSkyAdmission();
        TestCitySkyAdmission();
        TestRelatedCitySkyAdmission();
        TestTextureProjectionDiagnostic();
        TestWidescreenPreview();
        TestNativeHudAdmissionAndTransform();
        TestWorldMapOceanAdmission();
        TestFrontendAdmissionAndTransform();
        TestFrontendSourceAudit();
        TestGalleryModelFrame();
        TestSharedPanelAdmissionAndTransform();
        TestSharedPanelSourceAudit();
        TestGeometryBindAnchor();
        TestRigidGeometrySourceArrays();
        TestRigidTopologyVariantSelection();
        TestGeometryPreview();
        TestMotionCorrespondenceAudit();
        TestMotionInitialColorRegisters();
        TestMotionPresentationHistory();
        TestMotionCopyPassBoundaries();
        TestMotionShadowPass();
        TestExactEfbTextureCopyBindings();
        TestInterfaceSourceAudit();
        TestCombatFeedbackSourceGlyphs();
        TestCompanionMaterialCache();
        TestMaterialIsolationCapture();
        TestCinematicDrawAdmissionAndAperture();
        TestCinematicSurroundProtectedPixels();
        TestPresentationInstrumentation();
        TestMotionPlanOutsideLock();
        TestShadowWindowRedirect();
        TestProjectiveTexgenDefersDivide();
        TestScreenCopyCompositeStaysFullWidth();
        TestPassTimingResolves();
        std::puts("live GX decoder tests passed");
    }
    return 0;
}
