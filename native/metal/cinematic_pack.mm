#import "protector/cinematic_pack.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <chrono>

NS_ASSUME_NONNULL_BEGIN

static NSError* CinematicError(NSString* message) {
    return [NSError errorWithDomain:@"ProtectorCinematicPack" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
}

// Diagnostics only: this timestamp never selects or advances a movie frame.
static double CinematicMonotonicSeconds() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

static NSString* _Nullable CinematicHash(NSData* _Nullable bytes) {
    if (!bytes || bytes.length > UINT32_MAX) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString* result = [NSMutableString stringWithCapacity:64];
    for (unsigned char value : digest) [result appendFormat:@"%02x", value];
    return result;
}

static bool CinematicHashValid(id value) {
    return [value isKindOfClass:NSString.class] && [value length] == 64 &&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
            @"0123456789abcdef"] invertedSet]].location == NSNotFound;
}

static bool CinematicInteger(id value, uint64_t low, uint64_t high) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return false;
    const double n = [value doubleValue];
    return std::isfinite(n) && std::floor(n) == n && n >= low && n <= high;
}

static bool CinematicDimensions(id width, id height, bool fullPicture) {
    return CinematicInteger(height,2160,2160) &&
        (CinematicInteger(width,3840,3840) || (fullPicture && CinematicInteger(width,2880,2880)));
}

static bool CinematicName(id name, NSString* extension) {
    if (![name isKindOfClass:NSString.class] || [name length] < 5 || [name length] > 95 ||
        ![[name pathExtension] isEqual:extension]) return false;
    NSString* stem = [name stringByDeletingPathExtension];
    return stem.length && [stem rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet]].location == NSNotFound;
}

static bool CinematicMatches(NSDictionary* _Nullable entry, const ProtectorCinematicFrame& frame) {
    return entry && frame.active && frame.open_serial && frame.decoded_frame_one_based &&
        frame.decoded_frame_one_based <= frame.frame_count &&
        [entry[@"source_width"] unsignedIntValue] == frame.width &&
        [entry[@"source_height"] unsignedIntValue] == frame.height &&
        [entry[@"frame_count"] unsignedIntValue] == frame.frame_count &&
        [entry[@"rate_numerator"] unsignedIntValue] == frame.rate_numerator &&
        [entry[@"rate_denominator"] unsignedIntValue] == frame.rate_denominator;
}

static NSString* _Nullable CinematicFrameName(const ProtectorCinematicFrame& frame) {
    return frame.active && strnlen(frame.movie,sizeof(frame.movie)) < sizeof(frame.movie)
        ? [NSString stringWithUTF8String:frame.movie] : nil;
}

@interface ProtectorCinematicImage () {
    CVMetalTextureRef _lumaSurface;
    CVMetalTextureRef _chromaSurface;
    CVPixelBufferRef _pixels;
}
@property(nonatomic, readwrite) id<MTLTexture> luma;
@property(nonatomic, readwrite) id<MTLTexture> chroma;
@property(nonatomic, readwrite) NSUInteger frameIndex;
@property(nonatomic, readwrite) uint64_t openSerial;
@property(nonatomic, readwrite) NSString* movie;
- (nullable instancetype)initWithPixels:(CVPixelBufferRef)pixels cache:(CVMetalTextureCacheRef)cache
    frameIndex:(NSUInteger)index movie:(NSString*)movie serial:(uint64_t)serial
    width:(NSUInteger)width height:(NSUInteger)height;
@end

@implementation ProtectorCinematicImage
- (nullable instancetype)initWithPixels:(CVPixelBufferRef)pixels cache:(CVMetalTextureCacheRef)cache
    frameIndex:(NSUInteger)index movie:(NSString*)movie serial:(uint64_t)serial
    width:(NSUInteger)width height:(NSUInteger)height {
    self = [super init];
    if (!self) return nil;
    if (!CinematicDimensions(@(width),@(height),true) ||
        CVPixelBufferGetPixelFormatType(pixels) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        CVPixelBufferGetPlaneCount(pixels) != 2 || CVPixelBufferGetWidth(pixels) != width ||
        CVPixelBufferGetHeight(pixels) != height ||
        CVPixelBufferGetWidthOfPlane(pixels,0) != width || CVPixelBufferGetHeightOfPlane(pixels,0) != height ||
        CVPixelBufferGetWidthOfPlane(pixels,1) != width/2 || CVPixelBufferGetHeightOfPlane(pixels,1) != height/2) return nil;
    CFTypeRef matrix = CVBufferCopyAttachment(pixels, kCVImageBufferYCbCrMatrixKey, NULL);
    const BOOL correctMatrix = matrix && CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    if (matrix) CFRelease(matrix);
    if (!correctMatrix) return nil;
    _pixels = CVPixelBufferRetain(pixels);
    if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixels, NULL,
            MTLPixelFormatR8Unorm, width,height,0,&_lumaSurface) != kCVReturnSuccess ||
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixels, NULL,
            MTLPixelFormatRG8Unorm, width/2,height/2,1,&_chromaSurface) != kCVReturnSuccess) return nil;
    _luma = CVMetalTextureGetTexture(_lumaSurface);
    _chroma = CVMetalTextureGetTexture(_chromaSurface);
    if (!_luma || !_chroma) return nil;
    _frameIndex = index;
    _movie = [movie copy];
    _openSerial = serial;
    return self;
}
- (void)dealloc {
    if (_lumaSurface) CFRelease(_lumaSurface);
    if (_chromaSurface) CFRelease(_chromaSurface);
    if (_pixels) CVPixelBufferRelease(_pixels);
}
@end

@interface ProtectorCinematicPack () {
    // Every state variable below is protected by _lock except the queue-owned
    // reader/output/textureCache and readerGeneration/nextFrame pair.
    NSLock* _lock;
    dispatch_queue_t _queue;
    NSDictionary<NSString*, NSDictionary*>* _entries;
    NSMutableDictionary<NSNumber*, ProtectorCinematicImage*>* _images;
    NSString* _activeMovie;
    uint64_t _serial, _generation, _readerGeneration;
    NSUInteger _wantedFrame, _nextFrame;
    BOOL _workerRunning;
    BOOL _awaitingSourceFrame, _preparedOpening;
    double _preparationStarted, _preparationLeadMs;
    uint64_t _preparedOpenings;
    NSString* _decodeFailure;
    uint64_t _decodedFrames, _cacheHits, _cacheMisses, _readerRestarts;
    AVAssetReader* _reader;
    AVAssetReaderTrackOutput* _output;
    CVMetalTextureCacheRef _textureCache;
}
@property(nonatomic, readwrite) NSString* packID;
@property(nonatomic, readwrite) NSString* manifestSHA256;
@property(nonatomic, readwrite) NSUInteger entryCount;
- (void)pump;
@end

@implementation ProtectorCinematicPack
- (nullable instancetype)initWithManifest:(NSURL*)manifest sourceDirectory:(NSURL*)source
    device:(id<MTLDevice>)device error:(NSError**)error {
    self = [super init];
    if (!self) return nil;
    if (!manifest.isFileURL || !source.isFileURL ||
        ![source.URLByStandardizingPath.path isEqual:source.URLByResolvingSymlinksInPath.path] ||
        ![manifest.URLByStandardizingPath.path isEqual:manifest.URLByResolvingSymlinksInPath.path]) {
        if (error) *error = CinematicError(@"Cinematic packs must be local, non-symlink files.");
        return nil;
    }
    NSURL* dol = [source URLByAppendingPathComponent:@"sys/main.dol"];
    NSDictionary* executable = [NSFileManager.defaultManager attributesOfItemAtPath:dol.path error:error];
    if (![executable[NSFileType] isEqual:NSFileTypeRegular] || [executable[NSFileSize] unsignedLongLongValue] > 16*1024*1024 ||
        ![dol.URLByStandardizingPath.path isEqual:dol.URLByResolvingSymlinksInPath.path] ||
        ![CinematicHash([NSData dataWithContentsOfURL:dol options:NSDataReadingMappedIfSafe error:error])
            isEqual:@"03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566"]) {
        if (error) *error = CinematicError(@"Cinematic replacement requires the exact original executable.");
        return nil;
    }
    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:manifest.path error:error];
    if (!attributes) return nil;
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] > 2*1024*1024) {
        if (error) *error = CinematicError(@"Cinematic manifest exceeds its bounded regular-file contract.");
        return nil;
    }
    NSData* data = [NSData dataWithContentsOfURL:manifest options:0 error:error];
    if (!data || data.length > 2*1024*1024) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![root isKindOfClass:NSDictionary.class] ||
        (![root[@"schema"] isEqual:@"protector-native.cinematic-pack/v1"] &&
         ![root[@"schema"] isEqual:@"protector-native.cinematic-pack/v2"]) ||
        ![root[@"title_dol_sha256"] isEqual:@"03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566"] ||
        ![root[@"pack_id"] isKindOfClass:NSString.class] || ![root[@"pack_id"] length] ||
        [root[@"pack_id"] length] > 128 || ![root[@"entries"] isKindOfClass:NSArray.class] ||
        [root[@"entries"] count] < 1 || [root[@"entries"] count] > 76) {
        if (error) *error = CinematicError(@"Cinematic manifest identity or movie count is invalid.");
        return nil;
    }
    const bool fullPicture = [root[@"schema"] isEqual:@"protector-native.cinematic-pack/v2"];
    NSMutableDictionary* entries = [NSMutableDictionary dictionary];
    NSMutableSet* videoNames = [NSMutableSet set];
    for (id entry in root[@"entries"]) {
        if (![entry isKindOfClass:NSDictionary.class] || !CinematicName(entry[@"movie"], @"bik") ||
            !CinematicName(entry[@"video"], @"mp4") || !CinematicHashValid(entry[@"source_sha256"]) ||
            !CinematicHashValid(entry[@"video_sha256"]) ||
            !CinematicInteger(entry[@"source_width"], 32,7680) || !CinematicInteger(entry[@"source_height"],32,4800) ||
            !CinematicInteger(entry[@"frame_count"],1,1000000) ||
            !CinematicInteger(entry[@"rate_numerator"],1,INT32_MAX) ||
            !CinematicInteger(entry[@"rate_denominator"],1,10000000) ||
            !CinematicDimensions(entry[@"width"],entry[@"height"],fullPicture) ||
            !CinematicInteger(entry[@"video_bytes"],1,2ULL*1024*1024*1024) ||
            ![entry[@"provenance"] isKindOfClass:NSDictionary.class] ||
            entries[entry[@"movie"]] || [videoNames containsObject:entry[@"video"]]) {
            if (error) *error = CinematicError(@"Cinematic entry has invalid source, timing, media or provenance fields.");
            return nil;
        }
        const double rate = [entry[@"rate_numerator"] doubleValue]/[entry[@"rate_denominator"] doubleValue];
        NSURL* url = [manifest.URLByDeletingLastPathComponent URLByAppendingPathComponent:entry[@"video"]];
        NSDictionary* media = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:error];
        if (rate < 1 || rate > 120 || ![url.URLByStandardizingPath.path isEqual:url.URLByResolvingSymlinksInPath.path] ||
            ![media[NSFileType] isEqual:NSFileTypeRegular] ||
            [media[NSFileSize] unsignedLongLongValue] != [entry[@"video_bytes"] unsignedLongLongValue]) {
            if (error) *error = CinematicError(@"Cinematic media path, size or rate differs from its manifest.");
            return nil;
        }
        NSMutableDictionary* resolved = [entry mutableCopy];
        resolved[@"url"] = url;
        NSURL* original = [source URLByAppendingPathComponent:[@"files/Movies/" stringByAppendingString:entry[@"movie"]]];
        NSDictionary* originalFile = [NSFileManager.defaultManager attributesOfItemAtPath:original.path error:error];
        if (![originalFile[NSFileType] isEqual:NSFileTypeRegular] ||
            !CinematicInteger(originalFile[NSFileSize],44,2ULL*1024*1024*1024) ||
            ![original.URLByStandardizingPath.path isEqual:original.URLByResolvingSymlinksInPath.path]) {
            if (error) *error = CinematicError(@"Cinematic original source is missing or outside its source root.");
            return nil;
        }
        resolved[@"source_url"] = original;
        entries[entry[@"movie"]] = [resolved copy];
        [videoNames addObject:entry[@"video"]];
    }
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_textureCache) != kCVReturnSuccess) {
        if (error) *error = CinematicError(@"Could not allocate the cinematic Metal texture cache.");
        return nil;
    }
    _packID = [root[@"pack_id"] copy];
    _manifestSHA256 = CinematicHash(data);
    _entryCount = entries.count;
    _entries = [entries copy];
    _images = [NSMutableDictionary dictionary];
    _lock = [[NSLock alloc] init];
    _queue = dispatch_queue_create("house.machine.ProtectorNative.cinematic-decode", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)invalidate {
    [_lock lock];
    ++_generation;
    _activeMovie = nil;
    _serial = 0;
    _decodeFailure = nil;
    _awaitingSourceFrame = NO;
    _preparedOpening = NO;
    _preparationStarted = _preparationLeadMs = 0;
    [_images removeAllObjects];
    [_lock unlock];
    // Reader cancellation stays on its serial queue, never racing a decode.
    __weak ProtectorCinematicPack* weakSelf = self;
    dispatch_async(_queue, ^{
        ProtectorCinematicPack* owner = weakSelf;
        if (!owner) return;
        [owner->_lock lock];
        const bool stale = owner->_readerGeneration != owner->_generation;
        [owner->_lock unlock];
        if (stale) {
            [owner->_reader cancelReading]; owner->_reader = nil; owner->_output = nil;
            CVMetalTextureCacheFlush(owner->_textureCache, 0);
        }
    });
}

- (void)prepareOpening:(ProtectorCinematicOpening)opening {
    NSString* movie = opening.open_serial &&
        strnlen(opening.movie,sizeof(opening.movie)) < sizeof(opening.movie)
        ? [NSString stringWithUTF8String:opening.movie] : nil;
    if (!movie || !_entries[movie]) { [self invalidate]; return; }
    [_lock lock];
    if ([_activeMovie isEqual:movie] && _serial == opening.open_serial) {
        [_lock unlock];
        return;
    }
    ++_generation;
    _activeMovie = movie;
    _serial = opening.open_serial;
    _wantedFrame = 0;
    _decodeFailure = nil;
    _awaitingSourceFrame = YES;
    _preparedOpening = YES;
    _preparationStarted = CinematicMonotonicSeconds();
    _preparationLeadMs = 0;
    ++_preparedOpenings;
    [_images removeAllObjects];
    const BOOL startWorker = !_workerRunning;
    if (startWorker) _workerRunning = YES;
    [_lock unlock];
    if (startWorker) {
        __weak ProtectorCinematicPack* weakSelf = self;
        dispatch_async(_queue, ^{ [weakSelf pump]; });
    }
}

- (ProtectorCinematicOpeningStatus)statusForOpening:(ProtectorCinematicOpening)opening {
    if (!opening.open_serial || strnlen(opening.movie,sizeof(opening.movie)) == sizeof(opening.movie))
        return ProtectorCinematicOpeningUnavailable;
    NSString* movie = [NSString stringWithUTF8String:opening.movie];
    [_lock lock];
    ProtectorCinematicOpeningStatus status = ProtectorCinematicOpeningUnavailable;
    if (movie && [_activeMovie isEqual:movie] && _serial == opening.open_serial &&
        _awaitingSourceFrame && !_decodeFailure) {
        status = ProtectorCinematicOpeningReady;
        const NSUInteger count = std::min<NSUInteger>(5,[_entries[movie][@"frame_count"] unsignedIntegerValue]);
        for (NSUInteger index=0; index<count; ++index)
            if (!_images[@(index)]) { status = ProtectorCinematicOpeningPending; break; }
    }
    [_lock unlock];
    return status;
}

- (void)abandonOpening:(ProtectorCinematicOpening)opening {
    if (!opening.open_serial || strnlen(opening.movie,sizeof(opening.movie)) == sizeof(opening.movie)) return;
    NSString* movie = [NSString stringWithUTF8String:opening.movie];
    [_lock lock];
    if (movie && [_activeMovie isEqual:movie] && _serial == opening.open_serial && _awaitingSourceFrame) {
        ++_generation;
        _decodeFailure = @"Opening preparation was cancelled or exceeded its loading budget; original frames retained for this opening.";
        [_images removeAllObjects];
    }
    [_lock unlock];
}

- (void)observeFrame:(ProtectorCinematicFrame)frame {
    NSString* movie = CinematicFrameName(frame);
    NSDictionary* entry = movie ? _entries[movie] : nil;
    [_lock lock];
    if (!CinematicMatches(entry, frame)) {
        // Opening can precede several non-cinematic GX frames. Do not discard
        // that bounded work until a decoded source frame binds it. A wrong
        // active frame still rejects it immediately; it can never be displayed.
        const BOOL wasActive = _activeMovie != nil && (frame.active || !_awaitingSourceFrame);
        [_lock unlock];
        if (wasActive) [self invalidate];
        return;
    }
    const NSUInteger index = frame.decoded_frame_one_based - 1;
    if (![_activeMovie isEqual:movie] || _serial != frame.open_serial || index+8 < _wantedFrame) {
        ++_generation;
        _activeMovie = movie;
        _serial = frame.open_serial;
        _wantedFrame = index;
        _decodeFailure = nil;
        _awaitingSourceFrame = NO;
        _preparedOpening = NO;
        _preparationStarted = _preparationLeadMs = 0;
        [_images removeAllObjects];
    } else {
        _wantedFrame = std::max(_wantedFrame, index);
        if (_awaitingSourceFrame) {
            _preparationLeadMs = (CinematicMonotonicSeconds()-_preparationStarted)*1000;
            _awaitingSourceFrame = NO;
        }
    }
    for (NSNumber* key in _images.allKeys) {
        if (key.unsignedIntegerValue+2 < _wantedFrame || key.unsignedIntegerValue > _wantedFrame+4)
            [_images removeObjectForKey:key];
    }
    const NSUInteger future = std::min<NSUInteger>(frame.frame_count-1, _wantedFrame+4);
    const BOOL startWorker = !_workerRunning && !_decodeFailure && !_images[@(future)];
    if (startWorker) _workerRunning = YES;
    [_lock unlock];
    if (startWorker) {
        __weak ProtectorCinematicPack* weakSelf = self;
        dispatch_async(_queue, ^{ [weakSelf pump]; });
    }
}

- (nullable ProtectorCinematicImage*)imageForFrame:(ProtectorCinematicFrame)frame {
    NSString* movie = CinematicFrameName(frame);
    [_lock lock];
    ProtectorCinematicImage* result = nil;
    if (!_awaitingSourceFrame && movie && [_activeMovie isEqual:movie] && _serial == frame.open_serial &&
        CinematicMatches(_entries[movie],frame)) result = _images[@(frame.decoded_frame_one_based-1)];
    if (result) ++_cacheHits; else if (movie && _entries[movie]) ++_cacheMisses;
    [_lock unlock];
    return result;
}

- (NSDictionary*)diagnostics {
    [_lock lock];
    NSArray* keys = [_images.allKeys sortedArrayUsingSelector:@selector(compare:)];
    uint64_t pixelBytes = 0;
    for (ProtectorCinematicImage* image in _images.allValues)
        pixelBytes += image.luma.width*image.luma.height + image.chroma.width*image.chroma.height*2;
    NSDictionary* report = @{@"pack_id":self.packID, @"manifest_sha256":self.manifestSHA256,
        @"entry_count":@(self.entryCount), @"active_movie":_activeMovie ? _activeMovie : NSNull.null,
        @"open_serial":@(_serial), @"wanted_frame":@(_wantedFrame), @"generation":@(_generation),
        @"cached_frames":keys, @"cache_frame_limit":@7,
        @"cached_pixel_bytes":@(pixelBytes),
        @"decoded_frames":@(_decodedFrames), @"cache_hits":@(_cacheHits), @"cache_misses":@(_cacheMisses),
        @"reader_restarts":@(_readerRestarts), @"worker_running":@(_workerRunning),
        @"prepared_openings":@(_preparedOpenings), @"prepared_source_open":@(_preparedOpening),
        @"awaiting_source_frame":@(_awaitingSourceFrame), @"source_open_lead_ms":@(_preparationLeadMs),
        @"failure":_decodeFailure ? _decodeFailure : NSNull.null, @"audio_output":@NO, @"clock":@"original-decoded-frame"};
    [_lock unlock];
    return report;
}

/* This helper and pump run only on the private queue. Track loading can wait
 * there without holding the renderer or state lock. Generation changes cancel
 * stale work; no AVAssetReader call races cancelReading. */
- (BOOL)startReader:(NSDictionary*)entry generation:(uint64_t)generation
    firstFrame:(NSUInteger)first error:(NSError**)error {
    [_reader cancelReading]; _reader = nil; _output = nil;
    CVMetalTextureCacheFlush(_textureCache,0);
    NSURL* url = entry[@"url"];
    NSData* bytes = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
    if (!bytes || bytes.length != [entry[@"video_bytes"] unsignedLongLongValue] ||
        ![CinematicHash(bytes) isEqual:entry[@"video_sha256"]]) {
        if (error && !*error) *error = CinematicError(@"Cinematic media changed after manifest admission.");
        return NO;
    }
    bytes = nil;
    NSData* original = [NSData dataWithContentsOfURL:entry[@"source_url"] options:NSDataReadingMappedIfSafe error:error];
    if (!original || ![CinematicHash(original) isEqual:entry[@"source_sha256"]]) {
        if (error && !*error) *error = CinematicError(@"Original cinematic differs from the restoration source.");
        return NO;
    }
    original = nil;
    AVURLAsset* asset = [[AVURLAsset alloc] initWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    __block NSArray<AVAssetTrack*>* tracks = nil;
    __block NSError* trackError = nil;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack*>* result, NSError* failure) {
        tracks = result; trackError = failure;
        dispatch_semaphore_signal(loaded);
    }];
    BOOL completed = NO;
    for (NSUInteger poll=0; poll<100; ++poll) {
        if (dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC)) == 0) {
            completed = YES; break;
        }
        [_lock lock]; const BOOL stale = generation != _generation; [_lock unlock];
        if (stale) return NO;
    }
    if (!completed || tracks.count != 1 || trackError) {
        if (error) *error = trackError ? trackError : CinematicError(@"Cinematic video track did not load as one bounded stream.");
        return NO;
    }
    AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:asset error:error];
    if (!reader) return NO;
    AVAssetReaderTrackOutput* output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks[0]
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferMetalCompatibilityKey:@YES, (id)kCVPixelBufferIOSurfacePropertiesKey:@{}}];
    output.alwaysCopiesSampleData = NO;
    const int32_t numerator = [entry[@"rate_numerator"] intValue];
    const int64_t denominator = [entry[@"rate_denominator"] longLongValue];
    const int64_t count = [entry[@"frame_count"] longLongValue];
    reader.timeRange = CMTimeRangeMake(CMTimeMake(first*denominator,numerator),
        CMTimeMake((count-first)*denominator,numerator));
    if (![reader canAddOutput:output]) {
        if (error) *error = CinematicError(@"Cinematic video output could not be configured.");
        return NO;
    }
    [reader addOutput:output];
    if (![reader startReading]) {
        if (error) *error = reader.error ? reader.error : CinematicError(@"Cinematic decode could not start.");
        return NO;
    }
    [_lock lock];
    const BOOL stale = generation != _generation;
    if (!stale) ++_readerRestarts;
    [_lock unlock];
    if (stale) { [reader cancelReading]; return NO; }
    _reader = reader; _output = output;
    _readerGeneration = generation;
    _nextFrame = first;
    return YES;
}

- (void)failGeneration:(uint64_t)generation message:(NSString*)message {
    [_lock lock];
    if (generation == _generation) {
        _decodeFailure = message;
        [_images removeAllObjects];
    }
    [_lock unlock];
    [_reader cancelReading]; _reader = nil; _output = nil;
}

- (void)pump {
    while (true) { @autoreleasepool {
        [_lock lock];
        const uint64_t generation = _generation, serial = _serial;
        NSString* movie = _activeMovie;
        NSDictionary* entry = movie ? _entries[movie] : nil;
        NSUInteger wanted = _wantedFrame;
        if (!entry || _decodeFailure) {
            _workerRunning = NO;
            [_lock unlock];
            [_reader cancelReading]; _reader = nil; _output = nil;
            return;
        }
        [_lock unlock];
        if (!_reader || _readerGeneration != generation || _nextFrame+16 < wanted) {
            NSError* failure = nil;
            if (![self startReader:entry generation:generation firstFrame:wanted > 2 ? wanted-2 : 0 error:&failure]) {
                [_lock lock]; const BOOL stale = generation != _generation; [_lock unlock];
                if (!stale) [self failGeneration:generation message:failure.localizedDescription ? failure.localizedDescription : @"Cinematic reader failed."];
                continue;
            }
        }
        [_lock lock];
        wanted = _wantedFrame;
        const BOOL stale = generation != _generation;
        const NSUInteger future = std::min<NSUInteger>([entry[@"frame_count"] unsignedIntegerValue]-1,wanted+4);
        if (!stale && _nextFrame > future) {
            _workerRunning = NO;
            [_lock unlock];
            return;
        }
        [_lock unlock];
        if (stale) continue;
        CMSampleBufferRef sample = [_output copyNextSampleBuffer];
        if (!sample) {
            [self failGeneration:generation message:_reader.error.localizedDescription ? _reader.error.localizedDescription : @"Cinematic ended before its source frame count."];
            continue;
        }
        const int32_t numerator = [entry[@"rate_numerator"] intValue];
        const int64_t denominator = [entry[@"rate_denominator"] longLongValue];
        const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
        const CMTime ticks = CMTimeConvertScale(pts,numerator,kCMTimeRoundingMethod_RoundTowardZero);
        const CMTime duration = CMSampleBufferGetDuration(sample);
        BOOL exact = CMSampleBufferGetNumSamples(sample) == 1 && CMTIME_IS_NUMERIC(pts) &&
            CMTIME_IS_NUMERIC(ticks) && ticks.value >= 0 && ticks.value % denominator == 0 &&
            CMTimeCompare(pts,ticks) == 0 &&
            // AVAssetReader's decoded HEVC buffers have exact PTS but may
            // legitimately omit duration. The source game owns cadence; the
            // offline full-packet check already pins every encoded duration.
            // A supplied, contradictory duration is still rejected.
            (CMTIME_IS_INVALID(duration) || (CMTIME_IS_NUMERIC(duration) &&
                CMTimeCompare(duration,CMTimeMake(denominator,numerator)) == 0));
        const NSUInteger index = exact ? (NSUInteger)(ticks.value/denominator) : NSUIntegerMax;
        // A range seek may include an earlier partial sample. Never relabel it
        // as the requested frame; only exact integer source PTS can be used.
        if (exact && index < _nextFrame) { CFRelease(sample); continue; }
        exact = exact && index == _nextFrame;
        CVPixelBufferRef pixels = exact ? CMSampleBufferGetImageBuffer(sample) : NULL;
        ProtectorCinematicImage* image = pixels ? [[ProtectorCinematicImage alloc] initWithPixels:pixels
            cache:_textureCache frameIndex:index movie:movie serial:serial
            width:[entry[@"width"] unsignedIntegerValue] height:[entry[@"height"] unsignedIntegerValue]] : nil;
        CFRelease(sample);
        if (!image) {
            [self failGeneration:generation message:exact ? @"Cinematic pixel format, size, color or Metal surface differs."
                : [NSString stringWithFormat:@"Cinematic sample timestamps differ: pts=%lld/%d flags=%u duration=%lld/%d flags=%u expected=%lu at %lld/%d.",
                    (long long)pts.value,pts.timescale,pts.flags,(long long)duration.value,duration.timescale,duration.flags,
                    (unsigned long)_nextFrame,(long long)denominator,numerator]];
            continue;
        }
        ++_nextFrame;
        [_lock lock];
        ++_decodedFrames;
        if (generation == _generation && index+2 >= _wantedFrame && index <= _wantedFrame+4) {
            _images[@(index)] = image;
            for (NSNumber* key in _images.allKeys)
                if (key.unsignedIntegerValue+2 < _wantedFrame || key.unsignedIntegerValue > _wantedFrame+4)
                    [_images removeObjectForKey:key];
        }
        [_lock unlock];
    } }
}

- (void)dealloc {
    [_reader cancelReading];
    if (_textureCache) CFRelease(_textureCache);
}
@end

NS_ASSUME_NONNULL_END
