#import "protector/texture_pack.h"
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#include <os/lock.h>
#include <algorithm>
#include <unistd.h>

static const NSUInteger ProtectorPackBudget = 256u * 1024u * 1024u;
// Simulator's Metal bridge estimates ASTC storage as expanded RGBA, and
// allocatedSize reports zero. Do not mistake that estimate for device memory
// or reduce the shipping artwork to make the simulator match device accounting.
// Keep the encoded-mip limit on every platform and a second finite host limit.
// Real Mac/iPhone allocations retain the original 256 MiB limit.
#if TARGET_OS_SIMULATOR
static const NSUInteger ProtectorPackResidentBudget = 1024u * 1024u * 1024u;
#else
static const NSUInteger ProtectorPackResidentBudget = ProtectorPackBudget;
#endif

static BOOL PackFitsBudget(NSUInteger current, NSUInteger addition, NSUInteger budget) {
    return addition <= budget && current <= budget - addition;
}

static NSUInteger PackPageAligned(NSUInteger bytes) {
    const NSUInteger page = (NSUInteger)getpagesize();
    return ((bytes + page - 1) / page) * page;
}

static NSError* PackError(NSString* message) {
    return [NSError errorWithDomain:@"ProtectorTexturePack" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSString* PackSHA256(const void* bytes, NSUInteger length) {
    if (length > UINT32_MAX) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)length, hash);
    NSMutableString* result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger index = 0; index < sizeof(hash); ++index)
        [result appendFormat:@"%02x", hash[index]];
    return result;
}

static BOOL PackHashValid(id hash) {
    if (![hash isKindOfClass:NSString.class] || [hash length] != 64) return NO;
    NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdef"] invertedSet];
    return [hash rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static BOOL PackInteger(id number, NSUInteger minimum, NSUInteger maximum) {
    return [number isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)number) != CFBooleanGetTypeID() &&
        [number doubleValue] >= minimum && [number doubleValue] <= maximum &&
        [number doubleValue] == (double)[number unsignedIntegerValue];
}

static NSUInteger PackASTCBlock(NSString* format) {
    if ([format isEqual:@"astc-4x4-ldr"]) return 4;
    if ([format isEqual:@"astc-4x4-ldr-rgba8-tail"]) return 4;
    if ([format isEqual:@"astc-6x6-ldr"]) return 6;
    return 0;
}

static BOOL PackMipChainValid(id levels, NSUInteger width, NSUInteger height,
                             NSUInteger block, NSUInteger length, NSUInteger rawTail = 0) {
    if (![levels isKindOfClass:NSArray.class] || [levels count] == 0 ||
        [levels count] > 13 || block == 0 || rawTail >= [levels count]) return NO;
    NSUInteger offset = 0, index = 0;
    for (id level in levels) {
        const BOOL raw = rawTail && index >= rawTail;
        const NSUInteger size = raw ? width * height * 4 : ((width + block - 1) / block) *
            ((height + block - 1) / block) * 16;
        if (![level isKindOfClass:NSDictionary.class] ||
            !PackInteger(level[@"level"], index, index) ||
            !PackInteger(level[@"width"], width, width) ||
            !PackInteger(level[@"height"], height, height) ||
            !PackInteger(level[@"offset"], offset, offset) ||
            !PackInteger(level[@"byte_length"], size, size) ||
            (rawTail && ![level[@"format"] isEqual:raw ? @"rgba8-unorm" : @"astc-4x4-ldr"]) ||
            (!rawTail && level[@"format"])) return NO;
        offset += size;
        ++index;
        if (width == 1 && height == 1)
            return index == [levels count] && offset == length;
        width = width > 1 ? width / 2 : 1;
        height = height > 1 ? height / 2 : 1;
    }
    return NO; // Missing the terminal 1x1 mip is not a complete chain.
}

// Straight-alpha artwork needs coverage-weighted colour filtering. The GX
// shader still receives straight RGBA; premultiplication is local to this
// offline-in-upload reduction, never a change to source blending or base pixels.
// Integer area weights also retain the last row/column of odd-sized textures.
static NSData* PackStraightMip(NSData* source, NSUInteger width, NSUInteger height) {
    const NSUInteger nextWidth = width > 1 ? width / 2 : 1;
    const NSUInteger nextHeight = height > 1 ? height / 2 : 1;
    NSMutableData* result = [NSMutableData dataWithLength:nextWidth * nextHeight * 4];
    const unsigned char* input = (const unsigned char*)source.bytes;
    unsigned char* output = (unsigned char*)result.mutableBytes;
    for (NSUInteger y = 0; y < nextHeight; ++y) {
        const NSUInteger top = y * height, bottom = (y + 1) * height;
        for (NSUInteger x = 0; x < nextWidth; ++x) {
            const NSUInteger left = x * width, right = (x + 1) * width;
            uint64_t weightSum = 0, alphaSum = 0, colour[3] = {}, hidden[3] = {};
            for (NSUInteger sy = top / nextHeight; sy * nextHeight < bottom; ++sy) {
                const NSUInteger wy = std::min((sy + 1) * nextHeight, bottom) - std::max(sy * nextHeight, top);
                for (NSUInteger sx = left / nextWidth; sx * nextWidth < right; ++sx) {
                    const NSUInteger wx = std::min((sx + 1) * nextWidth, right) - std::max(sx * nextWidth, left);
                    const uint64_t weight = wx * wy;
                    const unsigned char* pixel = input + (sy * width + sx) * 4;
                    weightSum += weight;
                    alphaSum += pixel[3] * weight;
                    for (NSUInteger channel = 0; channel < 3; ++channel) {
                        colour[channel] += pixel[channel] * pixel[3] * weight;
                        hidden[channel] += pixel[channel] * weight;
                    }
                }
            }
            unsigned char* pixel = output + (y * nextWidth + x) * 4;
            pixel[3] = (unsigned char)((alphaSum + weightSum / 2) / weightSum);
            for (NSUInteger channel = 0; channel < 3; ++channel)
                pixel[channel] = (unsigned char)(alphaSum ? (colour[channel] + alphaSum / 2) / alphaSum :
                    (hidden[channel] + weightSum / 2) / weightSum);
        }
    }
    return result;
}

@interface ProtectorPackTexture : NSObject
@property(nonatomic) id<MTLTexture> texture;
@property(nonatomic) id<MTLTexture> mipTail;
@property(nonatomic) NSUInteger cost;
@property(nonatomic) NSUInteger encodedCost;
@property(nonatomic) uint64_t lastUse;
@end
@implementation ProtectorPackTexture
@end

@interface ProtectorTexturePack ()
@property(nonatomic, readwrite) NSString* packID;
@property(nonatomic, readwrite) NSString* manifestSHA256;
@property(nonatomic, readwrite) NSUInteger entryCount;
@property(nonatomic, readwrite) NSUInteger cacheBytes;
@property(nonatomic, readwrite) NSUInteger frameWorkingSetBytes;
@property(nonatomic, readwrite) NSUInteger cacheEncodedBytes;
@property(nonatomic, readwrite) NSUInteger frameEncodedBytes;
@property(nonatomic, readwrite) uint64_t replacementHits;
@property(nonatomic, readwrite) uint64_t replacementUploads;
@property(nonatomic) NSURL* directory;
@property(nonatomic) id<MTLDevice> device;
@property(nonatomic) id<MTLCommandQueue> uploadQueue;
@property(nonatomic) NSDictionary<NSString*, NSDictionary*>* entries;
@property(nonatomic) NSSet<NSString*>* sourceSizes;
@property(nonatomic) NSMutableDictionary<NSString*, ProtectorPackTexture*>* cache;
@property(nonatomic) NSMutableSet<NSString*>* used;
@property(nonatomic) NSMutableSet<NSString*>* frameUsed;
@property(nonatomic) uint64_t serial;
@property(nonatomic) dispatch_queue_t verifyQueue;
@end

@implementation ProtectorTexturePack {
    // Payload integrity is verified once per session off the render thread;
    // a mismatch withdraws that replacement and the original texture is used.
    os_unfair_lock _verificationLock;
    NSMutableSet<NSString*>* _verified;
    NSMutableSet<NSString*>* _rejected;
    // Asynchronous first-use preparation (render thread commits).
    NSCondition* _loadCondition;
    NSMutableDictionary<NSString*, id>* _loadResults;
    NSMutableSet<NSString*>* _loading;
    dispatch_queue_t _loadQueue;
    uint64_t _deferredRequests;
    double _maxPrepareSeconds;
    double _lastPrepareSeconds;
}
- (nullable instancetype)initWithManifest:(NSURL*)manifest
                                   device:(id<MTLDevice>)device
                                    error:(NSError**)error {
    self = [super init];
    if (!self) return nil;
    if (!manifest.isFileURL) {
        if (error) *error = PackError(@"Texture packs must be local files.");
        return nil;
    }
    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:
        manifest.path error:error];
    if (!attributes) return nil;
    if ([attributes[NSFileSize] unsignedLongLongValue] > 32u * 1024u * 1024u) {
        if (error) *error = PackError(@"Texture pack manifest is too large.");
        return nil;
    }
    NSData* data = [NSData dataWithContentsOfURL:manifest options:0 error:error];
    id document = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if (!document) return nil;
    const BOOL validObject = [document isKindOfClass:NSDictionary.class];
    const BOOL cooked = validObject && [document[@"schema"] isEqual:@"protector-native.texture-pack/v2"];
    const BOOL paired = validObject && [document[@"schema"] isEqual:@"protector-native.texture-pack/v6"];
    const BOOL alphaCompressed = paired || (validObject && [document[@"schema"] isEqual:@"protector-native.texture-pack/v5"]);
    const BOOL alphaAware = alphaCompressed || (validObject && [document[@"schema"] isEqual:@"protector-native.texture-pack/v4"]);
    const BOOL mixed = alphaAware || (validObject && [document[@"schema"] isEqual:@"protector-native.texture-pack/v3"]);
    if (!validObject ||
        (!cooked && !mixed && ![document[@"schema"] isEqual:@"protector-native.texture-pack/v1"]) ||
        ![document[@"title_dol_sha256"] isEqual:
            @"03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566"] ||
        ![document[@"status"] isEqual:@"candidate"] ||
        ![document[@"pack_id"] isKindOfClass:NSString.class] ||
        [document[@"pack_id"] length] == 0 || [document[@"pack_id"] length] > 64 ||
        ![document[@"entries"] isKindOfClass:NSArray.class] ||
        [document[@"entries"] count] == 0 || [document[@"entries"] count] > 16384) {
        if (error) *error = PackError(@"Invalid texture pack identity or schema.");
        return nil;
    }
    _directory = manifest.URLByDeletingLastPathComponent.URLByResolvingSymlinksInPath;
    NSMutableDictionary* entries = [NSMutableDictionary dictionary];
    NSMutableSet* sourceSizes = [NSMutableSet set];
    for (id entry in document[@"entries"]) {
        if (![entry isKindOfClass:NSDictionary.class] ||
            ![entry[@"source"] isKindOfClass:NSDictionary.class] ||
            ![entry[@"replacement"] isKindOfClass:NSDictionary.class]) {
            if (error) *error = PackError(@"Malformed texture pack entry.");
            return nil;
        }
        NSDictionary* source = entry[@"source"];
        NSDictionary* replacement = entry[@"replacement"];
        if (!PackInteger(source[@"width"], 1, 1024) || !PackInteger(source[@"height"], 1, 1024) ||
            !PackHashValid(source[@"rgba8_sha256"]) ||
            !PackInteger(replacement[@"width"], 1, 4096) ||
            !PackInteger(replacement[@"height"], 1, 4096) ||
            !PackHashValid(replacement[@"sha256"]) ||
            !PackInteger(replacement[@"byte_length"], 4, 4096u * 4096u * 4u) ||
            ![replacement[@"path"] isKindOfClass:NSString.class]) {
            if (error) *error = PackError(@"Invalid texture dimensions, size or hash.");
            return nil;
        }
        NSUInteger sw = [source[@"width"] unsignedIntegerValue];
        NSUInteger sh = [source[@"height"] unsignedIntegerValue];
        NSUInteger width = [replacement[@"width"] unsignedIntegerValue];
        NSUInteger height = [replacement[@"height"] unsignedIntegerValue];
        const NSUInteger block = (cooked || mixed) ? PackASTCBlock(replacement[@"format"]) : 0;
        const BOOL compressed = cooked || (mixed && block != 0);
        const BOOL straight = alphaAware && (!compressed || alphaCompressed) && [replacement[@"alpha_mode"] isEqual:@"straight"];
        const BOOL hybrid = [replacement[@"format"] isEqual:@"astc-4x4-ldr-rgba8-tail"];
        const NSUInteger rawTail = hybrid ? [replacement[@"raw_tail_first_level"] unsignedIntegerValue] : 0;
        const NSUInteger byteLength = [replacement[@"byte_length"] unsignedIntegerValue];
        if ((hybrid && (!alphaCompressed || !straight ||
                !PackInteger(replacement[@"raw_tail_first_level"], 1, 12))) ||
                (!hybrid && replacement[@"raw_tail_first_level"])) {
            if (error) *error = PackError(@"A lossless mip tail requires an explicit v5 straight-alpha hybrid texture.");
            return nil;
        }
        if (mixed && ((!compressed && ![replacement[@"format"] isEqual:@"rgba8-unorm"]) ||
                (!straight && ![replacement[@"alpha_mode"] isEqual:@"opaque"]) ||
                (!compressed && replacement[@"mip_levels"]) ||
                (straight && ![replacement[@"mip_filter"] isEqual:@"alpha-weighted-box-unorm-v1"]) ||
                (!straight && replacement[@"mip_filter"]) ||
                ((!straight || !compressed) && replacement[@"alpha_codec_policy"]))) {
            if (error) *error = PackError(@"Mixed texture packs require explicit format/alpha; v4 straight raw artwork requires coverage-weighted mips.");
            return nil;
        }
        if (compressed && (block == 0 || (!straight && ![replacement[@"alpha_mode"] isEqual:@"opaque"]) ||
                (straight && (block != 4 || ![replacement[@"alpha_codec_policy"] isEqual:@"straight-alpha-composite-v1"])) ||
                !PackMipChainValid(replacement[@"mip_levels"], width, height, block, byteLength, rawTail))) {
            if (error) *error = PackError(@"Invalid compressed texture format, alpha mode or complete mip chain.");
            return nil;
        }
        if (compressed && ![device supportsFamily:MTLGPUFamilyApple2]) {
            if (error) *error = PackError(@"This graphics device does not support the ASTC artwork pack; choose raw artwork.");
            return nil;
        }
        NSString* expectedPath = [NSString stringWithFormat:@"textures/%@.%@", replacement[@"sha256"],
            hybrid ? @"hybridmips" : compressed ? @"astcmips" : @"rgba"];
        NSURL* file = [_directory URLByAppendingPathComponent:expectedPath];
        NSString* resolved = file.URLByResolvingSymlinksInPath.path;
        if (width < sw || height < sh || width * sh != height * sw ||
            (!compressed && width * height * 4 != byteLength) ||
            ![replacement[@"path"] isEqual:expectedPath] ||
            ![resolved hasPrefix:[_directory.path stringByAppendingString:@"/"]]) {
            if (error) *error = PackError(@"Texture replacement changes aspect or escapes its pack.");
            return nil;
        }
        NSString* size = [NSString stringWithFormat:@"%lux%lu", (unsigned long)sw, (unsigned long)sh];
        NSString* key = [NSString stringWithFormat:@"%@-%@", size, source[@"rgba8_sha256"]];
        if (entries[key]) {
            if (error) *error = PackError(@"Duplicate source identity in texture pack.");
            return nil;
        }
        id companions = entry[@"required_companion_sources"];
        if (companions) {
            if (!paired || ![companions isKindOfClass:NSArray.class] ||
                    [companions count] == 0 || [companions count] > 8) {
                if (error) *error = PackError(@"Companion sources require a bounded nonempty v6 pair list.");
                return nil;
            }
            NSMutableSet* unique = [NSMutableSet set];
            for (id companion in companions) {
                if (![companion isKindOfClass:NSString.class] || [companion length] > 75 ||
                        [companion isEqual:key] || [unique containsObject:companion]) {
                    if (error) *error = PackError(@"Invalid, duplicate or self-referential texture companion.");
                    return nil;
                }
                [unique addObject:companion];
            }
        }
        // Derive runtime fields; never trust similarly named input JSON fields.
        NSMutableDictionary* normalized = [replacement mutableCopy];
        normalized[@"_astc_block"] = @(block);
        normalized[@"_straight_alpha"] = @(straight);
        normalized[@"_raw_tail_first_level"] = @(rawTail);
        // Overwrite even an input-injected runtime field with validated metadata.
        normalized[@"_required_companion_sources"] = companions ? [companions copy] : @[];
        entries[key] = normalized;
        [sourceSizes addObject:size];
    }
    NSUInteger scopedCount = 0;
    for (NSString* key in entries) {
        NSArray* companions = entries[key][@"_required_companion_sources"];
        if (companions.count) ++scopedCount;
        for (NSString* companion in companions) {
            if (!entries[companion] ||
                    ![entries[companion][@"_required_companion_sources"] containsObject:key]) {
                if (error) *error = PackError(@"Texture companions must be present and reciprocally scoped in this pack.");
                return nil;
            }
        }
    }
    if (paired && scopedCount == 0) {
        if (error) *error = PackError(@"A v6 pack must declare at least one reciprocal texture pair.");
        return nil;
    }
    _device = device;
    _uploadQueue = [device newCommandQueue];
    if (!_uploadQueue) {
        if (error) *error = PackError(@"Texture upload queue is unavailable.");
        return nil;
    }
    _packID = [document[@"pack_id"] copy];
    _manifestSHA256 = PackSHA256(data.bytes, data.length);
    _entries = [entries copy];
    _sourceSizes = [sourceSizes copy];
    _entryCount = entries.count;
    _cache = [NSMutableDictionary dictionary];
    _used = [NSMutableSet set];
    _frameUsed = [NSMutableSet set];
    _verificationLock = OS_UNFAIR_LOCK_INIT;
    _verified = [NSMutableSet set];
    _rejected = [NSMutableSet set];
    _loadCondition = [[NSCondition alloc] init];
    _loadResults = [NSMutableDictionary dictionary];
    _loading = [NSMutableSet set];
    _loadQueue = dispatch_queue_create("house.machine.protector.texture-load",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    _verifyQueue = dispatch_queue_create("house.machine.protector.texture-verify",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    return self;
}

- (BOOL)replacementRejected:(NSString*)key {
    os_unfair_lock_lock(&_verificationLock);
    const BOOL rejected = [_rejected containsObject:key];
    os_unfair_lock_unlock(&_verificationLock);
    return rejected;
}

- (NSUInteger)rejectedReplacementCount {
    os_unfair_lock_lock(&_verificationLock);
    const NSUInteger count = _rejected.count;
    os_unfair_lock_unlock(&_verificationLock);
    return count;
}

- (NSDictionary*)loadingDiagnostics {
    os_unfair_lock_lock(&_verificationLock);
    NSDictionary* result = @{@"deferred_requests":@(_deferredRequests),
        @"max_prepare_ms":@(_maxPrepareSeconds * 1000), @"last_prepare_ms":@(_lastPrepareSeconds * 1000)};
    os_unfair_lock_unlock(&_verificationLock);
    return result;
}

- (void)waitForPendingLoads {
    dispatch_sync(_loadQueue, ^{});
}

- (void)waitForPendingVerification {
    dispatch_sync(self.verifyQueue, ^{});
}

- (NSArray<NSString*>*)usedSourceKeys {
    return [self.used.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray<NSString*>*)frameSourceKeys {
    return [self.frameUsed.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

- (void)beginFrame {
    [self.frameUsed removeAllObjects];
    self.frameWorkingSetBytes = 0;
    self.frameEncodedBytes = 0;
}

- (NSUInteger)trimToFrameWorkingSet {
    // Memory pressure: keep only textures the current frame used; everything
    // else reloads from the pack on demand. Returns bytes released.
    [_loadCondition lock];
    [_loadResults removeAllObjects];
    [_loadCondition unlock];
    const NSUInteger before = self.cacheBytes;
    for (NSString* key in self.cache.allKeys) {
        if ([self.frameUsed containsObject:key]) continue;
        self.cacheBytes -= self.cache[key].cost;
        self.cacheEncodedBytes -= self.cache[key].encodedCost;
        [self.cache removeObjectForKey:key];
    }
    return before - self.cacheBytes;
}

- (NSUInteger)residentBudgetBytes { return ProtectorPackResidentBudget; }
- (NSUInteger)encodedBudgetBytes { return ProtectorPackBudget; }
- (NSString*)memoryAccountingPolicy {
#if TARGET_OS_SIMULATOR
    return @"simulator-emulated-allocation-with-encoded-mip-guard";
#else
    return @"native-device-allocation-with-encoded-mip-guard";
#endif
}

- (BOOL)admitFrameCost:(NSUInteger)cost encodedCost:(NSUInteger)encodedCost
             sourceKey:(NSString*)key error:(NSError**)error {
    const BOOL residentFits = PackFitsBudget(self.frameWorkingSetBytes, cost, ProtectorPackResidentBudget);
    const BOOL encodedFits = PackFitsBudget(self.frameEncodedBytes, encodedCost, ProtectorPackBudget);
    if (residentFits && encodedFits) return YES;
    if (error) *error = [NSError errorWithDomain:@"ProtectorTexturePack" code:residentFits ? 3 : 2 userInfo:@{
        NSLocalizedDescriptionKey:residentFits ?
            @"Restored artwork exceeds the 256 MiB encoded-mip frame budget; use a smaller pack." :
            [NSString stringWithFormat:@"Restored textures exceed the %lu MiB allocation frame budget; use a smaller pack.",
                (unsigned long)(ProtectorPackResidentBudget / (1024u * 1024u))],
        @"frame_bytes":@(self.frameWorkingSetBytes), @"requested_bytes":@(cost),
        @"frame_encoded_bytes":@(self.frameEncodedBytes), @"requested_encoded_bytes":@(encodedCost),
        @"allocation_budget_bytes":@(ProtectorPackResidentBudget), @"encoded_budget_bytes":@(ProtectorPackBudget),
        @"memory_accounting":self.memoryAccountingPolicy,
        @"source_key":key, @"frame_sources":self.frameSourceKeys}];
    return NO;
}

- (nullable id<MTLTexture>)textureForRGBA:(const void*)bytes
                                 length:(NSUInteger)length
                                  width:(NSUInteger)width
                                 height:(NSUInteger)height
                                  error:(NSError**)error {
    if (!bytes || width == 0 || height == 0 || width > 1024 || height > 1024 ||
        length != width * height * 4) {
        if (error) *error = PackError(@"Invalid source pixels for texture replacement.");
        return nil;
    }
    NSString* key = [self sourceKeyForRGBA:bytes length:length width:width height:height];
    return key ? [self textureForSourceKey:key error:error] : nil;
}

- (nullable NSString*)sourceKeyForRGBA:(const void*)bytes length:(NSUInteger)length
                                 width:(NSUInteger)width height:(NSUInteger)height {
    if (!bytes || width == 0 || height == 0 || width > 1024 || height > 1024 ||
        length != width * height * 4) return nil;
    NSString* size = [NSString stringWithFormat:@"%lux%lu", (unsigned long)width, (unsigned long)height];
    if (![self.sourceSizes containsObject:size]) return nil;
    NSString* key = [NSString stringWithFormat:@"%@-%@", size, PackSHA256(bytes, length)];
    if (!self.entries[key]) return nil;
    if (![self.entries[key][@"_straight_alpha"] boolValue]) {
        const unsigned char* pixels = (const unsigned char*)bytes;
        for (NSUInteger offset = 3; offset < length; offset += 4)
            if (pixels[offset] != 255) return nil;
    }
    return key;
}

- (nullable id<MTLTexture>)textureForSourceKey:(NSString*)key error:(NSError**)error {
    return [self textureForSourceKey:key mipTail:nullptr error:error];
}

- (nullable id<MTLTexture>)textureForSourceKey:(NSString*)key
                                     mipTail:(id<MTLTexture> _Nullable* _Nullable)mipTail
                                       error:(NSError**)error {
    return [self textureForSourceKey:key companionSource:nil mipTail:mipTail error:error];
}

- (NSArray<NSString*>*)requiredCompanionsForSourceKey:(NSString*)key {
    NSArray* required = self.entries[key][@"_required_companion_sources"];
    return required ? required : @[];
}

- (BOOL)sourceKey:(NSString*)key allowsCompanion:(nullable NSString*)companion {
    if ([self replacementRejected:key]) return NO;
    return [self manifestKey:key allowsCompanion:companion];
}

- (BOOL)manifestKey:(NSString*)key allowsCompanion:(nullable NSString*)companion {
    if (!self.entries[key]) return NO;
    NSArray* required = [self requiredCompanionsForSourceKey:key];
    return required.count == 0 || (companion && [required containsObject:companion]);
}

- (nullable ProtectorPackTexture*)prepareReplacement:(NSDictionary*)replacement key:(NSString*)key
                                               error:(NSError**)error {
    // Everything here is independent of the cache and budget state, so it can
    // run on the loader queue: file access, validation, allocation and upload.
    const double started = NSProcessInfo.processInfo.systemUptime;
    // Resolve again at use time: replacing a directory with a symlink must
    // not redirect a manifest that was admitted earlier.
    NSURL* path = [self.directory URLByAppendingPathComponent:replacement[@"path"]];
    if (![path.URLByResolvingSymlinksInPath.path hasPrefix:
            [self.directory.path stringByAppendingString:@"/"]]) {
        if (error) *error = PackError(@"Texture replacement path changed outside its pack.");
        return nil;
    }
    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path.path error:error];
    if (!attributes) return nil;
    if ([attributes[NSFileSize] unsignedLongLongValue] != [replacement[@"byte_length"] unsignedLongLongValue]) {
        if (error) *error = PackError(@"Texture replacement size no longer matches its manifest.");
        return nil;
    }
    NSData* payload = [NSData dataWithContentsOfURL:path options:NSDataReadingMappedIfSafe error:error];
    if (!payload) return nil;
    os_unfair_lock_lock(&_verificationLock);
    const BOOL verified = [_verified containsObject:key];
    os_unfair_lock_unlock(&_verificationLock);
    if (!verified) {
        // Hashing a 4K chain (~22 MB) here stalled presentation on first
        // use. The import already verified every payload; this re-check
        // runs in the background and withdraws the key on mismatch.
        NSString* expected = replacement[@"sha256"];
        NSData* bytes = payload;
        __weak ProtectorTexturePack* weakSelf = self;
        dispatch_async(self.verifyQueue, ^{
            ProtectorTexturePack* pack = weakSelf;
            if (!pack) return;
            const BOOL valid = [PackSHA256(bytes.bytes, bytes.length) isEqual:expected];
            os_unfair_lock_lock(&pack->_verificationLock);
            [valid ? pack->_verified : pack->_rejected addObject:key];
            os_unfair_lock_unlock(&pack->_verificationLock);
        });
    }
    const NSUInteger block = [replacement[@"_astc_block"] unsignedIntegerValue];
    const BOOL straight = [replacement[@"_straight_alpha"] boolValue];
    const NSUInteger rawTail = [replacement[@"_raw_tail_first_level"] unsignedIntegerValue];
    if (!block && !straight) {
        const unsigned char* pixels = (const unsigned char*)payload.bytes;
        for (NSUInteger offset = 3; offset < payload.length; offset += 4) {
            if (pixels[offset] != 255) {
                if (error) *error = PackError(@"This candidate pack admits only opaque replacement artwork.");
                return nil;
            }
        }
    }
    NSUInteger rw = [replacement[@"width"] unsignedIntegerValue];
    NSUInteger rh = [replacement[@"height"] unsignedIntegerValue];
    NSUInteger cost = block ? payload.length : 0;
    if (!block) {
        for (NSUInteger w = rw, h = rh;; w = w > 1 ? w / 2 : 1, h = h > 1 ? h / 2 : 1) {
            cost += w * h * 4;
            if (w == 1 && h == 1) break;
        }
    }
    NSUInteger encodedCost = PackPageAligned(cost);
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:block == 4 ? MTLPixelFormatASTC_4x4_LDR :
            (block == 6 ? MTLPixelFormatASTC_6x6_LDR : MTLPixelFormatRGBA8Unorm)
        width:rw height:rh mipmapped:YES];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;
    MTLTextureDescriptor* tailDescriptor = nil;
    NSUInteger tailCost = 0;
    if (rawTail) {
        descriptor.mipmapLevelCount = rawTail;
        const NSUInteger prefixBytes = [replacement[@"mip_levels"][rawTail][@"offset"] unsignedIntegerValue];
        cost = prefixBytes;
        encodedCost = PackPageAligned(prefixBytes) + PackPageAligned(payload.length - prefixBytes);
        tailDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:std::max((NSUInteger)1, rw >> rawTail) height:std::max((NSUInteger)1, rh >> rawTail)
            mipmapped:YES];
        tailDescriptor.storageMode = MTLStorageModeShared;
        tailDescriptor.usage = MTLTextureUsageShaderRead;
        tailCost = std::max(payload.length - prefixBytes,
            [self.device heapTextureSizeAndAlignWithDescriptor:tailDescriptor].size);
        tailCost = PackPageAligned(tailCost);
    }
    // GPU padding is real memory too; don't call compressed payload bytes
    // the whole allocation. Use the device's prospective allocation cost.
    const NSUInteger allocation = [self.device heapTextureSizeAndAlignWithDescriptor:descriptor].size;
    if (allocation > cost) cost = allocation;
    // Standalone shared textures are page-backed; the heap estimate can
    // omit the last page's padding (observed for the full 4096 ASTC chain).
    cost = PackPageAligned(cost);
    cost += tailCost;
    id<MTLTexture> texture = [self.device newTextureWithDescriptor:descriptor];
    id<MTLTexture> tailTexture = tailDescriptor ? [self.device newTextureWithDescriptor:tailDescriptor] : nil;
    if (!texture || (tailDescriptor && !tailTexture)) {
        if (error) *error = PackError(@"Restored texture allocation failed.");
        return nil;
    }
    if (texture.allocatedSize + tailTexture.allocatedSize > cost) {
        if (error) *error = PackError([NSString stringWithFormat:
            @"Texture allocation exceeded the device's declared memory cost (%lu actual, %lu estimated).",
            (unsigned long)(texture.allocatedSize + tailTexture.allocatedSize), (unsigned long)cost]);
        return nil;
    }
    if (block) {
        const unsigned char* bytes = (const unsigned char*)payload.bytes;
        for (NSDictionary* mip in replacement[@"mip_levels"]) {
            const NSUInteger width = [mip[@"width"] unsignedIntegerValue];
            const NSUInteger height = [mip[@"height"] unsignedIntegerValue];
            const NSUInteger level = [mip[@"level"] unsignedIntegerValue];
            const BOOL raw = rawTail && level >= rawTail;
            id<MTLTexture> target = raw ? tailTexture : texture;
            [target replaceRegion:MTLRegionMake2D(0, 0, width, height)
                mipmapLevel:raw ? level - rawTail : level
                withBytes:bytes + [mip[@"offset"] unsignedIntegerValue]
                bytesPerRow:raw ? width * 4 : ((width + block - 1) / block) * 16];
        }
    } else if (straight) {
        NSData* level = payload;
        NSUInteger width = rw, height = rh, mip = 0;
        for (;;) {
            [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:mip
                withBytes:level.bytes bytesPerRow:width * 4];
            if (width == 1 && height == 1) break;
            level = PackStraightMip(level, width, height);
            width = width > 1 ? width / 2 : 1;
            height = height > 1 ? height / 2 : 1;
            ++mip;
        }
    } else {
        [texture replaceRegion:MTLRegionMake2D(0, 0, rw, rh) mipmapLevel:0
            withBytes:payload.bytes bytesPerRow:rw * 4];
        id<MTLCommandBuffer> buffer = [self.uploadQueue commandBuffer];
        id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
        if (!buffer || !encoder) {
            if (error) *error = PackError(@"Restored texture mip generation could not start.");
            return nil;
        }
        [encoder generateMipmapsForTexture:texture];
        [encoder endEncoding];
        [buffer commit];
        [buffer waitUntilCompleted];
        if (buffer.status == MTLCommandBufferStatusError) {
            if (error) *error = buffer.error ? buffer.error : PackError(@"Restored texture mip generation failed.");
            return nil;
        }
    }
    ProtectorPackTexture* prepared = [[ProtectorPackTexture alloc] init];
    prepared.texture = texture;
    prepared.mipTail = tailTexture;
    prepared.cost = cost;
    prepared.encodedCost = encodedCost;
    const double elapsed = NSProcessInfo.processInfo.systemUptime - started;
    os_unfair_lock_lock(&_verificationLock);
    _maxPrepareSeconds = std::max(_maxPrepareSeconds, elapsed);
    _lastPrepareSeconds = elapsed;
    os_unfair_lock_unlock(&_verificationLock);
    return prepared;
}

- (BOOL)commitPrepared:(ProtectorPackTexture*)prepared key:(NSString*)key error:(NSError**)error {
    // Render thread only: frame budget, eviction and the cache.
    const NSUInteger cost = prepared.cost, encodedCost = prepared.encodedCost;
    if (![self admitFrameCost:cost encodedCost:encodedCost sourceKey:key error:error]) return NO;
    while (self.cache.count && (!PackFitsBudget(self.cacheBytes, cost, ProtectorPackResidentBudget) ||
            !PackFitsBudget(self.cacheEncodedBytes, encodedCost, ProtectorPackBudget))) {
        NSString* oldest = nil;
        for (NSString* candidate in self.cache) {
            // Textures already referenced by this frame remain retained
            // until submission; evicting them would undercount live GPU use.
            if ([self.frameUsed containsObject:candidate]) continue;
            if (!oldest || self.cache[candidate].lastUse < self.cache[oldest].lastUse)
                oldest = candidate;
        }
        if (!oldest) {
            if (error) *error = PackError(@"No inactive restored texture can be evicted.");
            return NO;
        }
        self.cacheBytes -= self.cache[oldest].cost;
        self.cacheEncodedBytes -= self.cache[oldest].encodedCost;
        [self.cache removeObjectForKey:oldest];
    }
    self.cache[key] = prepared;
    self.cacheBytes += cost;
    self.cacheEncodedBytes += encodedCost;
    ++self.replacementUploads;
    return YES;
}

- (nullable ProtectorPackTexture*)takePrepared:(NSString*)key replacement:(NSDictionary*)replacement
                                          wait:(double)seconds failed:(BOOL*)failed {
    [_loadCondition lock];
    id result = _loadResults[key];
    if (!result && ![_loading containsObject:key]) {
        [_loading addObject:key];
        __weak ProtectorTexturePack* weakSelf = self;
        dispatch_async(_loadQueue, ^{
            ProtectorTexturePack* pack = weakSelf;
            if (!pack) return;
            NSError* failure = nil;
            ProtectorPackTexture* prepared = [pack prepareReplacement:replacement key:key error:&failure];
            if (!prepared) NSLog(@"restored texture %@ withdrawn: %@", key, failure.localizedDescription);
            [pack->_loadCondition lock];
            pack->_loadResults[key] = prepared ? prepared : (id)NSNull.null;
            [pack->_loading removeObject:key];
            [pack->_loadCondition broadcast];
            [pack->_loadCondition unlock];
        });
    }
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!(result = _loadResults[key]) && [_loadCondition waitUntilDate:deadline]) {}
    if (result) [_loadResults removeObjectForKey:key];
    [_loadCondition unlock];
    if (result == NSNull.null) { if (failed) *failed = YES; return nil; }
    return result;
}

- (nullable id<MTLTexture>)textureForSourceKey:(NSString*)key
                             companionSource:(nullable NSString*)companion
                                     mipTail:(id<MTLTexture> _Nullable* _Nullable)mipTail
                                       error:(NSError**)error {
    return [self textureForSourceKey:key companionSource:companion mipTail:mipTail deferred:nullptr error:error];
}

- (nullable id<MTLTexture>)textureForSourceKey:(NSString*)key
                             companionSource:(nullable NSString*)companion
                                     mipTail:(id<MTLTexture> _Nullable* _Nullable)mipTail
                                    deferred:(BOOL* _Nullable)deferred
                                       error:(NSError**)error {
    if (mipTail) *mipTail = nil;
    if (deferred) *deferred = NO;
    // Recheck before both upload and cache hits; an alias in another material
    // must never inherit admission from an earlier matching draw.
    // Rejection is consulted at admission (sourceKey:allowsCompanion:), not
    // here, so a verification landing mid-frame cannot fail an admitted draw.
    if (![self manifestKey:key allowsCompanion:companion]) return nil;
    NSDictionary* replacement = self.entries[key];
    if (!replacement) return nil;
    ProtectorPackTexture* cached = self.cache[key];
    if (!cached) {
        ProtectorPackTexture* prepared = nil;
        if (!deferred) {
            prepared = [self prepareReplacement:replacement key:key error:error];
            if (!prepared) return nil;
        } else {
            // A large first-use load must not stall presentation: wait briefly
            // (small textures land in time), otherwise draw the original for
            // a frame or two. A preparation failure withdraws the replacement.
            BOOL failed = NO;
            prepared = [self takePrepared:key replacement:replacement wait:0.004 failed:&failed];
            if (!prepared) {
                if (failed) {
                    os_unfair_lock_lock(&_verificationLock);
                    [_rejected addObject:key];
                    os_unfair_lock_unlock(&_verificationLock);
                }
                ++_deferredRequests;
                *deferred = YES;
                return nil;
            }
        }
        if (![self commitPrepared:prepared key:key error:error]) return nil;
        cached = prepared;
    }
    if (![self.frameUsed containsObject:key]) {
        if (![self admitFrameCost:cached.cost encodedCost:cached.encodedCost sourceKey:key error:error]) return nil;
        self.frameWorkingSetBytes += cached.cost;
        self.frameEncodedBytes += cached.encodedCost;
        [self.frameUsed addObject:key];
    }
    cached.lastUse = ++self.serial;
    ++self.replacementHits;
    [self.used addObject:key];
    if (mipTail) *mipTail = cached.mipTail;
    return cached.texture;
}
@end
