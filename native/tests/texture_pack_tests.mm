// Keep schema validation private while testing the actual shipping loader.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#include "../metal/texture_pack.mm"
#pragma clang diagnostic pop
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>

static const unsigned char kColors[3][4] = {
    {200, 100, 50, 255}, {40, 180, 20, 255}, {10, 30, 220, 255}};

static NSMutableDictionary* SyntheticPack(NSUInteger block, NSData** data) {
    NSMutableData* payload = [NSMutableData data];
    NSMutableArray* levels = [NSMutableArray array];
    for (NSUInteger index = 0, dimension = block; index < 3; ++index) {
        // ASTC LDR void-extent block with exact UNORM16 constant colors.
        unsigned char bytes[16] = {0xfc, 0xfd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
        for (NSUInteger channel = 0; channel < 4; ++channel)
            bytes[8 + channel * 2] = bytes[9 + channel * 2] = kColors[index][channel];
        [levels addObject:@{@"level":@(index), @"width":@(dimension), @"height":@(dimension),
            @"offset":@(payload.length), @"byte_length":@16}];
        [payload appendBytes:bytes length:sizeof(bytes)];
        dimension = dimension > 1 ? dimension / 2 : 1;
    }
    *data = payload;
    const unsigned char original[] = {128, 64, 32, 255};
    NSString* hash = PackSHA256(payload.bytes, payload.length);
    NSMutableDictionary* replacement = [@{@"width":@(block), @"height":@(block),
        @"format":[NSString stringWithFormat:@"astc-%lux%lu-ldr", (unsigned long)block,
            (unsigned long)block], @"alpha_mode":@"opaque", @"byte_length":@(payload.length),
        @"sha256":hash, @"path":[NSString stringWithFormat:@"textures/%@.astcmips", hash],
        @"mip_levels":levels} mutableCopy];
    return [@{@"schema":@"protector-native.texture-pack/v2", @"pack_id":@"synthetic-astc",
        @"status":@"candidate",
        @"title_dol_sha256":@"03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566",
        @"entries":@[@{@"source":@{@"width":@1, @"height":@1,
            @"rgba8_sha256":PackSHA256(original, sizeof(original))},
            @"replacement":replacement}]} mutableCopy];
}

static NSURL* WritePack(NSURL* root, NSDictionary* document, NSData* payload) {
    NSError* error = nil;
    assert([NSFileManager.defaultManager createDirectoryAtURL:
        [root URLByAppendingPathComponent:@"textures"] withIntermediateDirectories:YES
        attributes:nil error:&error]);
    NSString* path = document[@"entries"][0][@"replacement"][@"path"];
    assert([payload writeToURL:[root URLByAppendingPathComponent:path] options:0 error:&error]);
    NSURL* manifest = [root URLByAppendingPathComponent:@"pack.json"];
    assert([[NSJSONSerialization dataWithJSONObject:document options:0 error:&error]
        writeToURL:manifest options:0 error:&error]);
    assert(!error);
    return manifest;
}

static NSData* SampleMips(id<MTLDevice> device, id<MTLTexture> texture) {
    NSError* error = nil;
    NSString* shader = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void sample_mips(texture2d<float> art [[texture(0)]], "
        "device float4* output [[buffer(0)]], uint i [[thread_position_in_grid]]) {"
        "constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear, "
        "mip_filter::nearest); uint mip = i / 16; uint p = i % 16; "
        "float2 uv = (float2(p % 4, p / 4) + 0.5f) / 4.0f; "
        "output[i] = art.sample(s, uv, level(float(mip))); }";
    id<MTLLibrary> library = [device newLibraryWithSource:shader options:nil error:&error];
    assert(library && !error);
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:
        [library newFunctionWithName:@"sample_mips"] error:&error];
    assert(pipeline && !error);
    NSUInteger samples = texture.mipmapLevelCount * 16;
    id<MTLBuffer> output = [device newBufferWithLength:samples * 4 * sizeof(float)
        options:MTLResourceStorageModeShared];
    assert(output);
    memset(output.contents, 0, output.length);
    id<MTLCommandBuffer> command = [[device newCommandQueue] commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];
    [encoder setTexture:texture atIndex:0];
    [encoder setBuffer:output offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(samples, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(16, 1, 1)];
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    assert(command.status == MTLCommandBufferStatusCompleted && !command.error);
    return [NSData dataWithBytes:output.contents length:output.length];
}

// Sparse color samples cannot rule out a one-texel alpha defect. Inspect every
// texel at every stored mip on the actual GPU, without an RGBA8 readback that
// could round a nearly-opaque floating-point alpha back to 255.
static NSDictionary* InspectAllTexels(id<MTLDevice> device, id<MTLTexture> texture) {
    NSError* error = nil;
    static id<MTLComputePipelineState> pipeline = nil;
    if (!pipeline) {
        NSString* shader = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void inspect(texture2d<float> art [[texture(0)]], "
            "device atomic_uint* stats [[buffer(0)]], constant uint& mip [[buffer(1)]], "
            "uint2 p [[thread_position_in_grid]]) { float4 c = art.read(p, mip); "
            "if (!all(isfinite(c)) || any(c < 0.0f) || any(c > 1.0f)) "
            "atomic_fetch_add_explicit(stats + 1, 1u, memory_order_relaxed); "
            "if (c.a != 1.0f) { atomic_fetch_add_explicit(stats, 1u, memory_order_relaxed); "
            "atomic_fetch_min_explicit(stats + 2, as_type<uint>(c.a), memory_order_relaxed); }}";
        MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
        if (@available(macOS 15.0, iOS 18.0, *)) {
            options.mathMode = MTLMathModeSafe;
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            options.fastMathEnabled = NO;
#pragma clang diagnostic pop
        }
        id<MTLLibrary> library = [device newLibraryWithSource:shader options:options error:&error];
        if (!library) fprintf(stderr, "All-texel shader: %s\n", error.localizedDescription.UTF8String);
        assert(library && !error);
        pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"inspect"]
            error:&error];
        assert(pipeline && !error);
    }
    id<MTLBuffer> output = [device newBufferWithLength:3 * sizeof(uint32_t)
        options:MTLResourceStorageModeShared];
    uint32_t* stats = (uint32_t*)output.contents;
    stats[0] = stats[1] = 0;
    const float opaque = 1.0f;
    memcpy(stats + 2, &opaque, sizeof(opaque));
    id<MTLCommandBuffer> command = [[device newCommandQueue] commandBuffer];
    NSUInteger count = 0;
    for (uint32_t mip = 0; mip < texture.mipmapLevelCount; ++mip) {
        NSUInteger width = texture.width >> mip, height = texture.height >> mip;
        if (!width) width = 1;
        if (!height) height = 1;
        count += width * height;
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setTexture:texture atIndex:0];
        [encoder setBuffer:output offset:0 atIndex:0];
        [encoder setBytes:&mip length:sizeof(mip) atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(width, height, 1)
            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [encoder endEncoding];
    }
    [command commit];
    [command waitUntilCompleted];
    assert(command.status == MTLCommandBufferStatusCompleted && !command.error);
    float minimumAlpha;
    memcpy(&minimumAlpha, stats + 2, sizeof(minimumAlpha));
    return @{@"gpu_texel_count":@(count), @"gpu_nonopaque_texels":@(stats[0]),
        @"gpu_invalid_texels":@(stats[1]), @"gpu_min_alpha":@(minimumAlpha)};
}

static void TestCompressed(id<MTLDevice> device, NSURL* root, NSUInteger block) {
    NSData* payload = nil;
    NSMutableDictionary* document = SyntheticPack(block, &payload);
    NSURL* manifest = WritePack(root, document, payload);
    NSError* error = nil;
    ProtectorTexturePack* pack = [[ProtectorTexturePack alloc] initWithManifest:manifest
        device:device error:&error];
    assert(pack && !error && pack.entryCount == 1);
    const unsigned char source[] = {128, 64, 32, 255};
    NSString* key = [pack sourceKeyForRGBA:source length:sizeof(source) width:1 height:1];
    assert(key);
    [pack beginFrame];
    assert(pack.frameSourceKeys.count == 0);
    id<MTLTexture> texture = [pack textureForSourceKey:key error:&error];
    assert(texture && !error && texture.mipmapLevelCount == 3);
    assert(texture.pixelFormat == (block == 4 ? MTLPixelFormatASTC_4x4_LDR : MTLPixelFormatASTC_6x6_LDR));
    assert(pack.cacheBytes >= payload.length && pack.cacheBytes >= texture.allocatedSize);
    assert(pack.frameWorkingSetBytes == pack.cacheBytes);
    assert([pack.frameSourceKeys isEqual:@[key]]);
    NSData* samples = SampleMips(device, texture);
    NSDictionary* allTexels = InspectAllTexels(device, texture);
    assert([allTexels[@"gpu_nonopaque_texels"] unsignedIntegerValue] == 0);
    assert([allTexels[@"gpu_invalid_texels"] unsignedIntegerValue] == 0);
    assert([allTexels[@"gpu_min_alpha"] floatValue] == 1);
    assert([allTexels[@"gpu_texel_count"] unsignedIntegerValue] == (block == 4 ? 21 : 46));
    const float* pixels = (const float*)samples.bytes;
    for (NSUInteger mip = 0; mip < 3; ++mip)
        for (NSUInteger pixel = 0; pixel < 16; ++pixel)
            for (NSUInteger channel = 0; channel < 4; ++channel)
                assert(std::abs(pixels[(mip * 16 + pixel) * 4 + channel] * 255 -
                    kColors[mip][channel]) < 1.01f);
    assert([pack textureForSourceKey:key error:&error] == texture);
    assert(pack.replacementUploads == 1 && pack.replacementHits == 2);
    [pack beginFrame];
    assert(pack.frameWorkingSetBytes == 0);
    assert(pack.frameSourceKeys.count == 0 && pack.usedSourceKeys.count == 1);
    assert([pack textureForSourceKey:key error:&error] == texture);
    assert(pack.frameWorkingSetBytes == pack.cacheBytes && pack.usedSourceKeys.count == 1);

    // Reopen after tampering: the hash is rechecked off the render thread and
    // a mismatch withdraws the replacement (the original texture is used),
    // never a fatal render error.
    NSMutableData* corrupt = [payload mutableCopy];
    ((unsigned char*)corrupt.mutableBytes)[8] ^= 1;
    WritePack(root, document, corrupt);
    pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
    assert(pack && !error);
    assert([pack sourceKey:key allowsCompanion:nil]);
    (void)[pack textureForSourceKey:key error:&error];
    [pack waitForPendingVerification];
    assert(pack.rejectedReplacementCount == 1 && ![pack sourceKey:key allowsCompanion:nil]);
    error = nil;
    // The intact pack verifies once and stays admitted.
    WritePack(root, document, payload);
    pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
    assert([pack textureForSourceKey:key error:&error] && !error);
    [pack waitForPendingVerification];
    assert(pack.rejectedReplacementCount == 0 && [pack sourceKey:key allowsCompanion:nil]);

    // First use never stalls presentation: the load either lands within the
    // short wait or defers (draw the original) and lands on a later request.
    pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
    BOOL deferred = NO;
    id<MTLTexture> asynchronous = [pack textureForSourceKey:key companionSource:nil mipTail:nil
        deferred:&deferred error:&error];
    if (!asynchronous) {
        assert(deferred && !error);
        [pack waitForPendingLoads];
        asynchronous = [pack textureForSourceKey:key companionSource:nil mipTail:nil deferred:&deferred error:&error];
    }
    assert(asynchronous && !deferred && !error && pack.replacementUploads == 1 && pack.cacheBytes > 0);
    assert([[pack loadingDiagnostics][@"max_prepare_ms"] doubleValue] > 0);
    // A payload that no longer matches its manifest is withdrawn, not fatal.
    WritePack(root, document, [payload subdataWithRange:NSMakeRange(0, payload.length - 16)]);
    pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
    error = nil;
    assert(![pack textureForSourceKey:key companionSource:nil mipTail:nil deferred:&deferred error:&error]);
    assert(deferred && !error);
    [pack waitForPendingLoads];
    (void)[pack textureForSourceKey:key companionSource:nil mipTail:nil deferred:&deferred error:&error];
    assert(!error && pack.rejectedReplacementCount == 1 && ![pack sourceKey:key allowsCompanion:nil]);
    WritePack(root, document, payload);
}

static void TestAdmission(id<MTLDevice> device, NSURL* root) {
    NSData* payload = nil;
    NSMutableDictionary* document = SyntheticPack(4, &payload);
    NSMutableDictionary* replacement = document[@"entries"][0][@"replacement"];
    NSArray* levels = replacement[@"mip_levels"];
    assert(PackMipChainValid(levels, 4, 4, 4, 48));
    assert(!PackMipChainValid([levels subarrayWithRange:NSMakeRange(0, 2)], 4, 4, 4, 32));
    assert(!PackMipChainValid(levels, 4, 4, 4, 49));
    for (NSString* field in @[@"level", @"width", @"height", @"offset", @"byte_length"]) {
        NSMutableArray* bad = [levels mutableCopy];
        NSMutableDictionary* first = [bad[0] mutableCopy];
        first[field] = @999;
        bad[0] = first;
        assert(!PackMipChainValid(bad, 4, 4, 4, 48));
    }
    replacement[@"mip_levels"] = [levels subarrayWithRange:NSMakeRange(0, 2)];
    NSURL* manifest = WritePack(root, document, payload);
    NSError* error = nil;
    assert(![[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error]);
    assert(error);
    replacement[@"mip_levels"] = levels;
    replacement[@"alpha_mode"] = @"straight";
    WritePack(root, document, payload);
    error = nil;
    assert(![[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error] && error);
}

static void InspectExternal(id<MTLDevice> device, NSString* path) {
    NSError* error = nil;
    NSURL* manifest = [NSURL fileURLWithPath:path];
    ProtectorTexturePack* pack = [[ProtectorTexturePack alloc] initWithManifest:manifest
        device:device error:&error];
    if (!pack) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); assert(pack); }
    id document = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:manifest]
        options:0 error:&error];
    NSString* firstKey = nil;
    NSUInteger totalAllocation = 0, totalCharged = 0, totalEncoded = 0, peakCache = 0;
    for (NSDictionary* entry in document[@"entries"]) {
      @autoreleasepool {
        NSDictionary* source = entry[@"source"];
        NSString* key = [NSString stringWithFormat:@"%@x%@-%@", source[@"width"], source[@"height"],
            source[@"rgba8_sha256"]];
        if (!firstKey) firstKey = key;
        [pack beginFrame];
        id<MTLTexture> mipTail = nil;
        NSString* companion = [pack requiredCompanionsForSourceKey:key].firstObject;
        id<MTLTexture> texture = [pack textureForSourceKey:key companionSource:companion mipTail:&mipTail error:&error];
        if (!texture || error) fprintf(stderr, "Texture upload: %s\n", error.localizedDescription.UTF8String);
        assert(texture && !error);
        totalAllocation += texture.allocatedSize + mipTail.allocatedSize;
        totalCharged += pack.frameWorkingSetBytes;
        totalEncoded += pack.frameEncodedBytes;
        if (pack.cacheBytes > peakCache) peakCache = pack.cacheBytes;
        assert(pack.cacheBytes <= pack.residentBudgetBytes && pack.cacheEncodedBytes <= pack.encodedBudgetBytes);
        NSData* samples = SampleMips(device, texture);
        NSMutableDictionary* allTexels = [InspectAllTexels(device, texture) mutableCopy];
        if (mipTail) {
            NSDictionary* tailStats = InspectAllTexels(device, mipTail);
            for (NSString* field in @[@"gpu_texel_count", @"gpu_nonopaque_texels", @"gpu_invalid_texels"])
                allTexels[field] = @([allTexels[field] unsignedIntegerValue] + [tailStats[field] unsignedIntegerValue]);
            allTexels[@"gpu_min_alpha"] = @(std::min([allTexels[@"gpu_min_alpha"] floatValue], [tailStats[@"gpu_min_alpha"] floatValue]));
        }
        const BOOL straight = ([document[@"schema"] isEqual:@"protector-native.texture-pack/v4"] ||
            [document[@"schema"] isEqual:@"protector-native.texture-pack/v5"] ||
            [document[@"schema"] isEqual:@"protector-native.texture-pack/v6"]) &&
            [entry[@"replacement"][@"alpha_mode"] isEqual:@"straight"];
        if ((!straight && [allTexels[@"gpu_nonopaque_texels"] unsignedIntegerValue]) ||
            [allTexels[@"gpu_invalid_texels"] unsignedIntegerValue]) {
            fprintf(stderr, "Full GPU decode failed %s: %s\n", key.UTF8String,
                allTexels.description.UTF8String);
            assert(false);
        }
        const float* pixels = (const float*)samples.bytes;
        for (NSUInteger i = 0; i < samples.length / sizeof(float); ++i)
            assert(std::isfinite(pixels[i]) && pixels[i] >= 0 && pixels[i] <= 1 &&
                (straight || i % 4 != 3 || pixels[i] == 1));
        NSMutableDictionary* receipt = [@{@"source_key":key, @"mip_count":@(texture.mipmapLevelCount + mipTail.mipmapLevelCount),
            @"width":@(texture.width), @"height":@(texture.height),
            @"gpu_allocated_bytes":@(texture.allocatedSize + mipTail.allocatedSize), @"charged_cache_bytes":@(pack.cacheBytes),
            @"charged_frame_bytes":@(pack.frameWorkingSetBytes), @"encoded_frame_bytes":@(pack.frameEncodedBytes),
            @"memory_accounting":pack.memoryAccountingPolicy,
            @"gpu_sample_float32_sha256":PackSHA256(samples.bytes, samples.length),
            @"gpu_sample_count":@(samples.length / (4 * sizeof(float)))} mutableCopy];
        receipt[@"alpha_mode"] = straight ? @"straight" : @"opaque";
        if (companion) receipt[@"admitted_companion_source"] = companion;
        if (mipTail) {
            NSDictionary* replacement = entry[@"replacement"];
            NSData* payload = [NSData dataWithContentsOfURL:[manifest.URLByDeletingLastPathComponent
                URLByAppendingPathComponent:replacement[@"path"]]];
            NSMutableArray* observed = [NSMutableArray array];
            for (NSUInteger mip = 0; mip < mipTail.mipmapLevelCount; ++mip) {
                NSUInteger width = std::max((NSUInteger)1, mipTail.width >> mip);
                NSUInteger height = std::max((NSUInteger)1, mipTail.height >> mip);
                NSMutableData* data = [NSMutableData dataWithLength:width * height * 4];
                [mipTail getBytes:data.mutableBytes bytesPerRow:width * 4
                    fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:mip];
                NSDictionary* level = replacement[@"mip_levels"][texture.mipmapLevelCount + mip];
                NSData* expected = [payload subdataWithRange:NSMakeRange([level[@"offset"] unsignedIntegerValue], data.length)];
                assert([data isEqualToData:expected]);
                [observed addObject:@{@"logical_level":@(texture.mipmapLevelCount + mip),
                    @"width":@(width), @"height":@(height), @"gpu_rgba8_sha256":PackSHA256(data.bytes, data.length)}];
            }
            receipt[@"raw_tail_first_level"] = @(texture.mipmapLevelCount);
            receipt[@"gpu_exact_raw_tail_mips"] = observed;
        }
        if (straight && [entry[@"replacement"][@"format"] isEqual:@"rgba8-unorm"]) {
            NSMutableData* base = [NSMutableData dataWithLength:texture.width * texture.height * 4];
            [texture getBytes:base.mutableBytes bytesPerRow:texture.width * 4
                fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height) mipmapLevel:0];
            NSString* baseHash = PackSHA256(base.bytes, base.length);
            assert([baseHash isEqual:entry[@"replacement"][@"sha256"]]);
            receipt[@"gpu_base_rgba8_sha256"] = baseHash;
            receipt[@"mip_filter"] = entry[@"replacement"][@"mip_filter"];
        }
        [receipt addEntriesFromDictionary:allTexels];
        puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:receipt
            options:NSJSONWritingSortedKeys error:&error] encoding:NSUTF8StringEncoding].UTF8String);
      }
    }
    // A pack larger than the cache must evict and reload the first, oldest
    // texture. This validates actual cache turnover, not only a bounded counter.
    NSUInteger uploads = pack.replacementUploads;
    [pack beginFrame];
    id<MTLTexture> revisited = [pack textureForSourceKey:firstKey
        companionSource:[pack requiredCompanionsForSourceKey:firstKey].firstObject mipTail:nullptr error:&error];
    assert(revisited && !error && pack.cacheBytes <= pack.residentBudgetBytes && pack.cacheEncodedBytes <= pack.encodedBudgetBytes);
    bool expectedReload = totalCharged > pack.residentBudgetBytes || totalEncoded > pack.encodedBudgetBytes;
    assert(pack.replacementUploads == uploads + (expectedReload ? 1 : 0));
    NSDictionary* summary = @{@"event":@"cache-revisit", @"first_source_key":firstKey,
        @"total_gpu_allocation_bytes":@(totalAllocation), @"peak_cache_bytes":@(peakCache),
        @"total_charged_allocation_bytes":@(totalCharged), @"total_encoded_mip_bytes":@(totalEncoded),
        @"allocation_budget_bytes":@(pack.residentBudgetBytes), @"encoded_budget_bytes":@(pack.encodedBudgetBytes),
        @"memory_accounting":pack.memoryAccountingPolicy,
        @"final_cache_bytes":@(pack.cacheBytes), @"sequential_uploads":@(uploads),
        @"final_uploads":@(pack.replacementUploads), @"reload_expected":@(expectedReload)};
    fflush(stdout); // Keep the final stderr summary out of buffered JSON rows.
    fprintf(stderr, "%s\n", [[NSString alloc] initWithData:[NSJSONSerialization
        dataWithJSONObject:summary options:NSJSONWritingSortedKeys error:&error]
        encoding:NSUTF8StringEncoding].UTF8String);
}

static void TestNonopaqueTexels(id<MTLDevice> device, NSURL* root) {
    NSData* payload = nil;
    NSMutableDictionary* document = SyntheticPack(4, &payload);
    NSMutableData* changed = [payload mutableCopy];
    // Slightly below fully opaque in UNORM16: RGBA8 decoding rounds this to 255,
    // but full-precision GPU decoding must catch it in all sixteen base texels.
    ((unsigned char*)changed.mutableBytes)[14] = 0xbf;
    NSMutableDictionary* replacement = document[@"entries"][0][@"replacement"];
    NSString* hash = PackSHA256(changed.bytes, changed.length);
    replacement[@"sha256"] = hash;
    replacement[@"path"] = [NSString stringWithFormat:@"textures/%@.astcmips", hash];
    NSError* error = nil;
    ProtectorTexturePack* pack = [[ProtectorTexturePack alloc] initWithManifest:
        WritePack(root, document, changed) device:device error:&error];
    assert(pack && !error);
    const unsigned char original[] = {128, 64, 32, 255};
    NSString* key = [pack sourceKeyForRGBA:original length:sizeof(original) width:1 height:1];
    [pack beginFrame];
    id<MTLTexture> texture = [pack textureForSourceKey:key error:&error];
    assert(texture && !error);
    NSDictionary* receipt = InspectAllTexels(device, texture);
    assert([receipt[@"gpu_nonopaque_texels"] unsignedIntegerValue] == 16);
    assert([receipt[@"gpu_invalid_texels"] unsignedIntegerValue] == 0);
    assert([receipt[@"gpu_min_alpha"] floatValue] < 1);
}

static void TestMixed(id<MTLDevice> device, NSURL* root) {
    NSData* compressed = nil;
    NSMutableDictionary* document = SyntheticPack(4, &compressed);
    document[@"schema"] = @"protector-native.texture-pack/v3";
    unsigned char bytes[4 * 4 * 4];
    for (NSUInteger index = 0; index < 16; ++index) {
        bytes[index * 4] = bytes[index * 4 + 2] = 0;
        bytes[index * 4 + 1] = (unsigned char)(index * 17);
        bytes[index * 4 + 3] = 255;
    }
    NSData* raw = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSString* hash = PackSHA256(raw.bytes, raw.length);
    const unsigned char original[] = {0, 127, 0, 255};
    NSMutableDictionary* replacement = [@{@"width":@4, @"height":@4, @"format":@"rgba8-unorm",
        @"alpha_mode":@"opaque", @"byte_length":@(raw.length), @"sha256":hash,
        @"path":[NSString stringWithFormat:@"textures/%@.rgba", hash],
        @"_astc_block":@6} mutableCopy]; // Input must never override normalization.
    NSDictionary* rawEntry = @{@"source":@{@"width":@1, @"height":@1,
        @"rgba8_sha256":PackSHA256(original, sizeof(original))}, @"replacement":replacement};
    document[@"entries"] = @[document[@"entries"][0], rawEntry];
    NSURL* manifest = WritePack(root, document, compressed);
    NSError* error = nil;
    assert([raw writeToURL:[root URLByAppendingPathComponent:replacement[@"path"]] options:0 error:&error]);
    ProtectorTexturePack* pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
    assert(pack && !error && pack.entryCount == 2);
    [pack beginFrame];
    NSString* key = [pack sourceKeyForRGBA:original length:sizeof(original) width:1 height:1];
    id<MTLTexture> texture = [pack textureForSourceKey:key error:&error];
    assert(texture && !error && texture.pixelFormat == MTLPixelFormatRGBA8Unorm && texture.mipmapLevelCount == 3);
    const float* samples = (const float*)SampleMips(device, texture).bytes;
    for (NSUInteger index = 0; index < 16; ++index)
        for (NSUInteger channel = 0; channel < 4; ++channel)
            assert(std::abs(samples[index * 4 + channel] * 255 - bytes[index * 4 + channel]) < 0.01f);
    NSDictionary* inspection = InspectAllTexels(device, texture);
    assert([inspection[@"gpu_nonopaque_texels"] unsignedIntegerValue] == 0);
    assert([inspection[@"gpu_invalid_texels"] unsignedIntegerValue] == 0);
    const unsigned char compressedSource[] = {128, 64, 32, 255};
    id<MTLTexture> astc = [pack textureForRGBA:compressedSource length:sizeof(compressedSource) width:1 height:1 error:&error];
    assert(astc && !error && astc.pixelFormat == MTLPixelFormatASTC_4x4_LDR);
    assert(pack.replacementUploads == 2 && pack.frameWorkingSetBytes == pack.cacheBytes);
    for (NSString* mutation in @[@"format", @"alpha", @"mips"]) {
        if ([mutation isEqual:@"format"]) replacement[@"format"] = @"unknown";
        if ([mutation isEqual:@"alpha"]) replacement[@"alpha_mode"] = @"straight";
        if ([mutation isEqual:@"mips"]) replacement[@"mip_levels"] = @[];
        WritePack(root, document, compressed);
        error = nil;
        assert(![[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error] && error);
        replacement[@"format"] = @"rgba8-unorm";
        replacement[@"alpha_mode"] = @"opaque";
        [replacement removeObjectForKey:@"mip_levels"];
    }
    // The original raw schema remains valid without new format fields.
    document[@"schema"] = @"protector-native.texture-pack/v1";
    document[@"entries"] = @[rawEntry];
    [replacement removeObjectForKey:@"format"];
    [replacement removeObjectForKey:@"alpha_mode"];
    manifest = WritePack(root, document, raw);
    error = nil;
    pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
    assert(pack && !error && [pack textureForSourceKey:key error:&error] && !error);
}

static void TestCompressedAlpha(id<MTLDevice> device, NSURL* root) {
    NSData* originalPayload = nil;
    NSMutableDictionary* document = SyntheticPack(4, &originalPayload);
    NSMutableData* payload = [originalPayload mutableCopy];
    const unsigned char alphas[] = {255, 128, 0};
    for (NSUInteger mip = 0; mip < 3; ++mip)
        ((unsigned char*)payload.mutableBytes)[mip * 16 + 14] =
            ((unsigned char*)payload.mutableBytes)[mip * 16 + 15] = alphas[mip];
    const unsigned char source[] = {128, 64, 32, 123};
    NSMutableDictionary* entry = [document[@"entries"][0] mutableCopy];
    NSMutableDictionary* replacement = [entry[@"replacement"] mutableCopy];
    entry[@"source"] = @{@"width":@1, @"height":@1, @"rgba8_sha256":PackSHA256(source, sizeof(source))};
    replacement[@"sha256"] = PackSHA256(payload.bytes, payload.length);
    replacement[@"path"] = [NSString stringWithFormat:@"textures/%@.astcmips", replacement[@"sha256"]];
    replacement[@"alpha_mode"] = @"straight";
    replacement[@"mip_filter"] = @"alpha-weighted-box-unorm-v1";
    replacement[@"alpha_codec_policy"] = @"straight-alpha-composite-v1";
    entry[@"replacement"] = replacement;
    document[@"entries"] = @[entry];
    document[@"schema"] = @"protector-native.texture-pack/v5";
    NSURL* manifest = WritePack(root, document, payload);
    NSError* error = nil;
    ProtectorTexturePack* pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
    assert(pack && !error);
    NSString* key = [pack sourceKeyForRGBA:source length:sizeof(source) width:1 height:1];
    assert(key);
    [pack beginFrame];
    id<MTLTexture> texture = [pack textureForSourceKey:key error:&error];
    assert(texture && !error && texture.pixelFormat == MTLPixelFormatASTC_4x4_LDR);
    const float* samples = (const float*)SampleMips(device, texture).bytes;
    for (NSUInteger mip = 0; mip < 3; ++mip)
        for (NSUInteger p = 0; p < 16; ++p) {
            assert(std::abs(samples[(mip * 16 + p) * 4 + 3] * 255 - alphas[mip]) < 0.5);
            for (NSUInteger c = 0; c < 3; ++c)
                assert(std::abs(samples[(mip * 16 + p) * 4 + c] * 255 - kColors[mip][c]) < 0.5);
        }
    for (NSString* mutation in @[@"old", @"policy", @"filter", @"alpha", @"block"]) {
        if ([mutation isEqual:@"old"]) document[@"schema"] = @"protector-native.texture-pack/v4";
        if ([mutation isEqual:@"policy"]) replacement[@"alpha_codec_policy"] = @"unknown";
        if ([mutation isEqual:@"filter"]) replacement[@"mip_filter"] = @"linear-rgba";
        if ([mutation isEqual:@"alpha"]) replacement[@"alpha_mode"] = @"premultiplied";
        if ([mutation isEqual:@"block"]) replacement[@"format"] = @"astc-6x6-ldr";
        WritePack(root, document, payload);
        error = nil;
        assert(![[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error] && error);
        document[@"schema"] = @"protector-native.texture-pack/v5";
        replacement[@"alpha_codec_policy"] = @"straight-alpha-composite-v1";
        replacement[@"mip_filter"] = @"alpha-weighted-box-unorm-v1";
        replacement[@"alpha_mode"] = @"straight";
        replacement[@"format"] = @"astc-4x4-ldr";
    }
}

static void TestStraightAlpha(id<MTLDevice> device, NSURL* root) {
    const unsigned char pattern[4][4] = {{255, 0, 0, 255}, {0, 255, 0, 0},
        {0, 0, 255, 128}, {255, 255, 255, 0}};
    unsigned char bytes[4 * 4 * 4];
    for (NSUInteger y = 0; y < 4; ++y)
        for (NSUInteger x = 0; x < 4; ++x)
            memcpy(bytes + (y * 4 + x) * 4, pattern[(y % 2) * 2 + x % 2], 4);
    NSData* payload = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSString* hash = PackSHA256(payload.bytes, payload.length);
    const unsigned char original[] = {12, 22, 32, 123};
    NSMutableDictionary* replacement = [@{@"width":@4, @"height":@4, @"format":@"rgba8-unorm",
        @"alpha_mode":@"straight", @"mip_filter":@"alpha-weighted-box-unorm-v1",
        @"byte_length":@(payload.length), @"sha256":hash,
        @"path":[NSString stringWithFormat:@"textures/%@.rgba", hash],
        @"_straight_alpha":@NO, @"_astc_block":@6} mutableCopy];
    NSDictionary* entry = @{@"source":@{@"width":@1, @"height":@1,
        @"rgba8_sha256":PackSHA256(original, sizeof(original))}, @"replacement":replacement};
    NSMutableDictionary* document = [@{@"schema":@"protector-native.texture-pack/v4",
        @"pack_id":@"synthetic-straight", @"status":@"candidate",
        @"title_dol_sha256":@"03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566",
        @"entries":@[entry]} mutableCopy];
    NSURL* manifest = WritePack(root, document, payload);
    NSError* error = nil;
    ProtectorTexturePack* pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
    assert(pack && !error);
    NSString* key = [pack sourceKeyForRGBA:original length:sizeof(original) width:1 height:1];
    assert(key);
    const unsigned char changed[] = {12, 22, 32, 124};
    assert(![pack sourceKeyForRGBA:changed length:sizeof(changed) width:1 height:1]);
    [pack beginFrame];
    id<MTLTexture> texture = [pack textureForSourceKey:key error:&error];
    assert(texture && !error && texture.mipmapLevelCount == 3);
    const float* samples = (const float*)SampleMips(device, texture).bytes;
    for (NSUInteger i = 0; i < sizeof(bytes); ++i)
        assert(std::abs(samples[i] * 255 - bytes[i]) < 0.01f);
    // Transparent green/white must not darken or recolour the covered red/blue.
    const unsigned char expected[] = {170, 0, 85, 96};
    for (NSUInteger mip = 1; mip < 3; ++mip) {
        for (NSUInteger p = 0; p < 16; ++p)
            for (NSUInteger c = 0; c < 4; ++c)
                assert(std::abs(samples[(mip * 16 + p) * 4 + c] * 255 - expected[c]) < 0.01f);
    }
    NSDictionary* inspection = InspectAllTexels(device, texture);
    assert([inspection[@"gpu_nonopaque_texels"] unsignedIntegerValue] == 17);
    assert([inspection[@"gpu_invalid_texels"] unsignedIntegerValue] == 0);
    assert([inspection[@"gpu_min_alpha"] floatValue] == 0);
    for (NSString* mutation in @[@"old", @"filter", @"alpha", @"format", @"mips"]) {
        if ([mutation isEqual:@"old"]) document[@"schema"] = @"protector-native.texture-pack/v3";
        if ([mutation isEqual:@"filter"]) replacement[@"mip_filter"] = @"linear-rgba";
        if ([mutation isEqual:@"alpha"]) replacement[@"alpha_mode"] = @"premultiplied";
        if ([mutation isEqual:@"format"]) replacement[@"format"] = @"astc-4x4-ldr";
        if ([mutation isEqual:@"mips"]) replacement[@"mip_levels"] = @[];
        WritePack(root, document, payload);
        error = nil;
        assert(![[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error] && error);
        document[@"schema"] = @"protector-native.texture-pack/v4";
        replacement[@"mip_filter"] = @"alpha-weighted-box-unorm-v1";
        replacement[@"alpha_mode"] = @"straight";
        replacement[@"format"] = @"rgba8-unorm";
        [replacement removeObjectForKey:@"mip_levels"];
    }
    // The opaque schema's admission cannot be bypassed with normalized fields.
    document[@"schema"] = @"protector-native.texture-pack/v1";
    replacement[@"_straight_alpha"] = @YES;
    WritePack(root, document, payload);
    error = nil;
    pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
    assert(pack && !error && ![pack sourceKeyForRGBA:original length:sizeof(original) width:1 height:1]);
    assert(![pack textureForSourceKey:key error:&error] && error);

    // Odd-size and one-dimensional reductions include every input texel.
    const unsigned char odd[] = {255,0,0,255, 0,255,0,0, 0,0,255,255};
    NSData* oddData = [NSData dataWithBytes:odd length:sizeof(odd)];
    const unsigned char oddExpected[] = {128,0,128,170};
    NSData* horizontal = PackStraightMip(oddData, 3, 1);
    NSData* vertical = PackStraightMip(oddData, 1, 3);
    assert(horizontal.length == 4 && !memcmp(horizontal.bytes, oddExpected, 4));
    assert([horizontal isEqualToData:vertical]);
    const unsigned char clear[] = {0,100,200,0, 100,200,0,0};
    const unsigned char clearExpected[] = {50,150,100,0};
    NSData* empty = PackStraightMip([NSData dataWithBytes:clear length:sizeof(clear)], 2, 1);
    assert(!memcmp(empty.bytes, clearExpected, 4));
}

static void TestHybridAlpha(id<MTLDevice> device, NSURL* root) {
    NSData* originalPayload = nil;
    NSMutableDictionary* document = SyntheticPack(4, &originalPayload);
    NSMutableDictionary* replacement = document[@"entries"][0][@"replacement"];
    document[@"schema"] = @"protector-native.texture-pack/v5";
    NSMutableData* payload = [[originalPayload subdataWithRange:NSMakeRange(0, 16)] mutableCopy];
    const unsigned char tail[] = {255,0,0,255, 0,255,0,0, 0,0,255,128, 255,255,255,0,
        170,0,85,96};
    [payload appendBytes:tail length:sizeof(tail)];
    NSString* hash = PackSHA256(payload.bytes, payload.length);
    [replacement addEntriesFromDictionary:@{@"format":@"astc-4x4-ldr-rgba8-tail",
        @"alpha_mode":@"straight", @"mip_filter":@"alpha-weighted-box-unorm-v1",
        @"alpha_codec_policy":@"straight-alpha-composite-v1", @"raw_tail_first_level":@1,
        @"_raw_tail_first_level":@999, @"byte_length":@(payload.length), @"sha256":hash,
        @"path":[NSString stringWithFormat:@"textures/%@.hybridmips", hash],
        @"mip_levels":@[
            @{@"level":@0, @"width":@4, @"height":@4, @"offset":@0, @"byte_length":@16, @"format":@"astc-4x4-ldr"},
            @{@"level":@1, @"width":@2, @"height":@2, @"offset":@16, @"byte_length":@16, @"format":@"rgba8-unorm"},
            @{@"level":@2, @"width":@1, @"height":@1, @"offset":@32, @"byte_length":@4, @"format":@"rgba8-unorm"}]}];
    NSURL* manifest = WritePack(root, document, payload);
    NSError* error = nil;
    ProtectorTexturePack* pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
    assert(pack && !error);
    NSString* key = [NSString stringWithFormat:@"1x1-%@", document[@"entries"][0][@"source"][@"rgba8_sha256"]];
    id<MTLTexture> mipTail = nil;
    id<MTLTexture> head = [pack textureForSourceKey:key mipTail:&mipTail error:&error];
    assert(head && mipTail && !error && head.mipmapLevelCount == 1 && mipTail.mipmapLevelCount == 2);
    assert(head.pixelFormat == MTLPixelFormatASTC_4x4_LDR && mipTail.pixelFormat == MTLPixelFormatRGBA8Unorm);
    assert(mipTail.width == 2 && mipTail.height == 2);
    assert(pack.cacheBytes >= head.allocatedSize + mipTail.allocatedSize && pack.frameWorkingSetBytes == pack.cacheBytes);
    assert(pack.cacheEncodedBytes == 2 * PackPageAligned(1) && pack.frameEncodedBytes == pack.cacheEncodedBytes);
    unsigned char observed[sizeof(tail)] = {};
    [mipTail getBytes:observed bytesPerRow:8 fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0];
    [mipTail getBytes:observed + 16 bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:1];
    assert(!memcmp(observed, tail, sizeof(tail)));
    id<MTLTexture> oldTail = mipTail;
    [pack beginFrame];
    assert([pack textureForSourceKey:key mipTail:&mipTail error:&error] == head && mipTail == oldTail);
    assert(pack.replacementUploads == 1 && pack.frameWorkingSetBytes == pack.cacheBytes);
    assert(pack.frameEncodedBytes == pack.cacheEncodedBytes);
    assert([InspectAllTexels(device, mipTail)[@"gpu_invalid_texels"] unsignedIntegerValue] == 0);
    assert(![pack textureForSourceKey:@"missing" mipTail:&mipTail error:&error] && !mipTail);

    NSDictionary* baseline = [replacement copy];
    for (NSString* mutation in @[@"old", @"opaque", @"no-tail", @"zero", @"past-end", @"fraction", @"plain",
            @"tail-format", @"offset", @"raw-count", @"fake-prefix"]) {
        if ([mutation isEqual:@"old"]) document[@"schema"] = @"protector-native.texture-pack/v4";
        if ([mutation isEqual:@"opaque"]) replacement[@"alpha_mode"] = @"opaque";
        if ([mutation isEqual:@"no-tail"]) [replacement removeObjectForKey:@"raw_tail_first_level"];
        if ([mutation isEqual:@"zero"]) replacement[@"raw_tail_first_level"] = @0;
        if ([mutation isEqual:@"past-end"]) replacement[@"raw_tail_first_level"] = @3;
        if ([mutation isEqual:@"fraction"]) replacement[@"raw_tail_first_level"] = @1.5;
        if ([mutation isEqual:@"plain"]) replacement[@"format"] = @"astc-4x4-ldr";
        if ([mutation isEqual:@"tail-format"] || [mutation isEqual:@"offset"] ||
            [mutation isEqual:@"raw-count"] || [mutation isEqual:@"fake-prefix"]) {
            NSMutableArray* levels = [replacement[@"mip_levels"] mutableCopy];
            NSUInteger index = [mutation isEqual:@"fake-prefix"] ? 0 : 2;
            NSMutableDictionary* level = [levels[index] mutableCopy];
            if ([mutation isEqual:@"tail-format"]) level[@"format"] = @"astc-4x4-ldr";
            if ([mutation isEqual:@"fake-prefix"]) level[@"format"] = @"rgba8-unorm";
            if ([mutation isEqual:@"offset"]) level[@"offset"] = @31;
            if ([mutation isEqual:@"raw-count"]) level[@"byte_length"] = @16;
            levels[index] = level;
            replacement[@"mip_levels"] = levels;
        }
        WritePack(root, document, payload);
        error = nil;
        assert(![[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error] && error);
        document[@"schema"] = @"protector-native.texture-pack/v5";
        [replacement setDictionary:baseline];
    }
}

// Synthetic accounting pressure exercises both guards and LRU admission without
// allocating a gigabyte merely to test the simulator-only allowance. Native
// translated-game captures are the separate integration evidence.
static void TestBudgetAdmission(id<MTLDevice> device, NSURL* root) {
    assert(PackFitsBudget(99, 1, 100) && !PackFitsBudget(100, 1, 100));
    assert(!PackFitsBudget(NSUIntegerMax, 1, 100) && !PackFitsBudget(0, NSUIntegerMax, 100));
    NSData* payload = nil;
    NSDictionary* document = SyntheticPack(4, &payload);
    NSURL* manifest = WritePack(root, document, payload);
    NSString* key = [NSString stringWithFormat:@"1x1-%@", document[@"entries"][0][@"source"][@"rgba8_sha256"]];
    for (NSUInteger cached = 0; cached < 2; ++cached) {
        for (NSUInteger encoded = 0; encoded < 2; ++encoded) {
            NSError* error = nil;
            ProtectorTexturePack* pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
            assert(pack && !error && pack.encodedBudgetBytes == 256u * 1024u * 1024u);
#if TARGET_OS_SIMULATOR
            assert(pack.residentBudgetBytes == 1024u * 1024u * 1024u);
            assert([pack.memoryAccountingPolicy hasPrefix:@"simulator-"]);
#else
            assert(pack.residentBudgetBytes == 256u * 1024u * 1024u);
            assert([pack.memoryAccountingPolicy hasPrefix:@"native-"]);
#endif
            if (cached) assert([pack textureForSourceKey:key error:&error] && !error);
            [pack beginFrame];
            if (encoded) pack.frameEncodedBytes = pack.encodedBudgetBytes;
            else pack.frameWorkingSetBytes = pack.residentBudgetBytes;
            id<MTLTexture> tail = (id<MTLTexture>)[NSObject new];
            assert(![pack textureForSourceKey:key mipTail:&tail error:&error] && !tail);
            assert(error && error.code == (encoded ? 3 : 2));
            assert([error.userInfo[@"source_key"] isEqual:key]);
            assert([error.userInfo[@"encoded_budget_bytes"] unsignedIntegerValue] == pack.encodedBudgetBytes);
            assert([error.userInfo[@"allocation_budget_bytes"] unsignedIntegerValue] == pack.residentBudgetBytes);
            assert(pack.replacementUploads == cached && pack.frameSourceKeys.count == 0);
            [pack beginFrame]; error = nil;
            assert([pack textureForSourceKey:key error:&error] && !error && pack.replacementUploads == 1);
            const NSUInteger resident = pack.frameWorkingSetBytes, content = pack.frameEncodedBytes;
            assert(resident == pack.cacheBytes && content == pack.cacheEncodedBytes);
            assert(content == PackPageAligned(payload.length));
            assert([pack textureForSourceKey:key error:&error] && !error);
            assert(pack.frameWorkingSetBytes == resident && pack.frameEncodedBytes == content);
        }
    }
    for (NSUInteger encoded = 0; encoded < 2; ++encoded) {
        NSError* error = nil;
        ProtectorTexturePack* pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
        id<MTLTexture> reference = [pack textureForSourceKey:key error:&error];
        assert(reference && !error);
        const NSUInteger resident = pack.frameWorkingSetBytes, content = pack.frameEncodedBytes;
        [pack.cache removeAllObjects]; [pack beginFrame];
        ProtectorPackTexture* active = [ProtectorPackTexture new];
        active.texture = reference;
        active.cost = encoded ? resident : pack.residentBudgetBytes - resident;
        active.encodedCost = encoded ? pack.encodedBudgetBytes - content : content;
        ProtectorPackTexture* inactive = [ProtectorPackTexture new];
        inactive.texture = reference; inactive.cost = resident; inactive.encodedCost = content;
        inactive.lastUse = 1; // The active entry is older, but cannot be evicted.
        pack.cache[@"active"] = active; pack.cache[@"inactive"] = inactive;
        pack.cacheBytes = active.cost + inactive.cost;
        pack.cacheEncodedBytes = active.encodedCost + inactive.encodedCost;
        pack.frameWorkingSetBytes = active.cost; pack.frameEncodedBytes = active.encodedCost;
        [pack.frameUsed addObject:@"active"];
        assert([pack textureForSourceKey:key error:&error] && !error);
        assert(pack.cache[@"active"] == active && !pack.cache[@"inactive"] && pack.cache[key]);
        assert(pack.cacheBytes == active.cost + resident && pack.cacheEncodedBytes == active.encodedCost + content);
        assert(pack.frameWorkingSetBytes == pack.cacheBytes && pack.frameEncodedBytes == pack.cacheEncodedBytes);
    }
}

static void TestCompanionScope(id<MTLDevice> device, NSURL* root) {
    NSData* payload = nil;
    NSMutableDictionary* document = SyntheticPack(4, &payload);
    document[@"schema"] = @"protector-native.texture-pack/v6";
    NSMutableDictionary* a = [document[@"entries"][0] mutableCopy];
    NSMutableDictionary* b = [a mutableCopy];
    const unsigned char mask[] = {30, 100, 70, 255};
    b[@"source"] = @{@"width":@1, @"height":@1, @"rgba8_sha256":PackSHA256(mask, sizeof(mask))};
    NSString* ka = [@"1x1-" stringByAppendingString:a[@"source"][@"rgba8_sha256"]];
    NSString* kb = [@"1x1-" stringByAppendingString:b[@"source"][@"rgba8_sha256"]];
    a[@"required_companion_sources"] = @[kb]; b[@"required_companion_sources"] = @[ka];
    document[@"entries"] = @[a, b];
    NSURL* manifest = WritePack(root, document, payload);
    NSError* error = nil;
    ProtectorTexturePack* pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
    assert(pack && !error && pack.entryCount == 2);
    assert([[pack requiredCompanionsForSourceKey:ka] isEqual:@[kb]]);
    assert([pack sourceKey:ka allowsCompanion:kb] && ![pack sourceKey:ka allowsCompanion:ka]);
    for (NSUInteger warm = 0; warm < 2; ++warm) {
        [pack beginFrame];
        const uint64_t hits = pack.replacementHits, uploads = pack.replacementUploads;
        id<MTLTexture> tail = (id<MTLTexture>)[NSObject new];
        assert(![pack textureForSourceKey:ka mipTail:&tail error:&error] && !tail && !error);
        assert(![pack textureForSourceKey:ka companionSource:ka mipTail:&tail error:&error] && !tail && !error);
        assert(![pack textureForRGBA:mask length:sizeof(mask) width:1 height:1 error:&error] && !error);
        assert(pack.frameSourceKeys.count == 0 && pack.frameWorkingSetBytes == 0);
        assert(pack.replacementHits == hits && pack.replacementUploads == uploads);
        assert([pack textureForSourceKey:ka companionSource:kb mipTail:&tail error:&error] && !error && !tail);
        assert([pack textureForSourceKey:kb companionSource:ka mipTail:&tail error:&error] && !error);
        assert(pack.replacementUploads == 2 && pack.frameSourceKeys.count == 2);
    }
    for (NSString* mutation in @[@"old", @"none", @"empty", @"object", @"self", @"duplicate",
            @"unknown", @"nonreciprocal", @"number", @"oversize"]) {
        if ([mutation isEqual:@"old"]) document[@"schema"] = @"protector-native.texture-pack/v5";
        else if ([mutation isEqual:@"none"]) { [a removeObjectForKey:@"required_companion_sources"]; [b removeObjectForKey:@"required_companion_sources"]; }
        else if ([mutation isEqual:@"empty"]) a[@"required_companion_sources"] = @[];
        else if ([mutation isEqual:@"object"]) a[@"required_companion_sources"] = @{};
        else if ([mutation isEqual:@"self"]) a[@"required_companion_sources"] = @[ka];
        else if ([mutation isEqual:@"duplicate"]) a[@"required_companion_sources"] = @[kb,kb];
        else if ([mutation isEqual:@"unknown"]) a[@"required_companion_sources"] = @[@"1x1-unknown"];
        else if ([mutation isEqual:@"nonreciprocal"]) [b removeObjectForKey:@"required_companion_sources"];
        else if ([mutation isEqual:@"number"]) a[@"required_companion_sources"] = @[@1];
        else a[@"required_companion_sources"] = @[kb,kb,kb,kb,kb,kb,kb,kb,kb];
        WritePack(root, document, payload); error = nil;
        assert(![[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error] && error);
        document[@"schema"] = @"protector-native.texture-pack/v6";
        a[@"required_companion_sources"] = @[kb]; b[@"required_companion_sources"] = @[ka];
    }
    // Internal normalized fields supplied in JSON cannot forge or add a guard.
    document[@"schema"] = @"protector-native.texture-pack/v5";
    [a removeObjectForKey:@"required_companion_sources"]; [b removeObjectForKey:@"required_companion_sources"];
    a[@"replacement"][@"_required_companion_sources"] = @[kb];
    WritePack(root, document, payload); error = nil;
    pack = [[ProtectorTexturePack alloc] initWithManifest:manifest device:device error:&error];
    assert(pack && !error && [pack requiredCompanionsForSourceKey:ka].count == 0);
    assert([pack textureForSourceKey:ka error:&error] && !error);
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device && [device supportsFamily:MTLGPUFamilyApple2]);
        if (argc == 3 && strcmp(argv[1], "--manifest") == 0) {
            InspectExternal(device, [NSString stringWithUTF8String:argv[2]]);
            return 0;
        }
        const bool budgetOnly = argc == 2 && strcmp(argv[1], "--budget-only") == 0;
        assert(argc == 1 || budgetOnly);
        NSURL* root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"protector-astc-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
        TestBudgetAdmission(device, [root URLByAppendingPathComponent:@"budgets"]);
        if (budgetOnly) {
            assert([NSFileManager.defaultManager removeItemAtURL:root error:nil]);
            puts("Texture pack dual-budget admission, accounting, and protected LRU tests passed.");
            return 0;
        }
        TestCompressed(device, [root URLByAppendingPathComponent:@"four"], 4);
        TestCompressed(device, [root URLByAppendingPathComponent:@"six"], 6);
        TestAdmission(device, [root URLByAppendingPathComponent:@"invalid"]);
        TestCompanionScope(device, [root URLByAppendingPathComponent:@"companions"]);
        TestNonopaqueTexels(device, [root URLByAppendingPathComponent:@"nonopaque"]);
        TestMixed(device, [root URLByAppendingPathComponent:@"mixed"]);
        TestStraightAlpha(device, [root URLByAppendingPathComponent:@"straight"]);
        TestCompressedAlpha(device, [root URLByAppendingPathComponent:@"compressed-straight"]);
        TestHybridAlpha(device, [root URLByAppendingPathComponent:@"hybrid-straight"]);
        assert([NSFileManager.defaultManager removeItemAtURL:root error:nil]);
        puts("Texture pack raw/ASTC/mixed/straight-alpha GPU and admission tests passed.");
    }
    return 0;
}
