#ifndef PROTECTOR_TEXTURE_PACK_H
#define PROTECTOR_TEXTURE_PACK_H

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/* Immutable content-addressed candidate artwork. Never rewrites guest memory.
 * Original mode does not construct a pack. A match includes dimensions and
 * every decoded source RGBA byte, not its transient guest address. */
@interface ProtectorTexturePack : NSObject
@property(nonatomic, readonly) NSString* packID;
@property(nonatomic, readonly) NSString* manifestSHA256;
@property(nonatomic, readonly) NSUInteger entryCount;
@property(nonatomic, readonly) NSUInteger cacheBytes;
@property(nonatomic, readonly) NSUInteger frameWorkingSetBytes;
/* Resident accounting follows the actual Metal device estimate; Simulator is
 * explicitly not device-memory evidence. Encoded mips remain bounded there. */
@property(nonatomic, readonly) NSUInteger cacheEncodedBytes;
@property(nonatomic, readonly) NSUInteger frameEncodedBytes;
@property(nonatomic, readonly) NSUInteger residentBudgetBytes;
@property(nonatomic, readonly) NSUInteger encodedBudgetBytes;
@property(nonatomic, readonly) NSString* memoryAccountingPolicy;
@property(nonatomic, readonly) uint64_t replacementHits;
@property(nonatomic, readonly) uint64_t replacementUploads;
@property(nonatomic, readonly) NSArray<NSString*>* usedSourceKeys;
@property(nonatomic, readonly) NSArray<NSString*>* frameSourceKeys;
- (nullable instancetype)initWithManifest:(NSURL*)manifest
                                   device:(id<MTLDevice>)device
                                    error:(NSError**)error;
- (void)beginFrame;
/* Drops cached textures the current frame did not use; returns bytes freed. */
- (NSUInteger)trimToFrameWorkingSet;
/* Background payload verification (diagnostics/tests). */
- (NSUInteger)rejectedReplacementCount;
- (void)waitForPendingVerification;
/* First-use loading that never stalls presentation: waits ~4 ms, otherwise
 * returns nil with *deferred = YES (draw the original; ask again next frame).
 * A preparation failure withdraws that replacement. */
- (nullable id<MTLTexture>)textureForSourceKey:(NSString*)key
                             companionSource:(nullable NSString*)companion
                                     mipTail:(id<MTLTexture> _Nullable* _Nullable)mipTail
                                    deferred:(BOOL* _Nullable)deferred
                                       error:(NSError**)error;
- (NSDictionary*)loadingDiagnostics;
- (void)waitForPendingLoads;
/* Source lookup is split from GPU admission so the renderer can cache the
 * validated identity without retaining a second, unbounded GPU texture cache. */
- (nullable NSString*)sourceKeyForRGBA:(const void*)bytes length:(NSUInteger)length
                                 width:(NSUInteger)width height:(NSUInteger)height;
- (nullable id<MTLTexture>)textureForSourceKey:(NSString*)key error:(NSError**)error;
/* v6 pairs are admitted only alongside another exact decoded source in the
 * same direct material. The list is OR, reciprocal, and bounded to eight.
 * Context-free entry points deliberately return nil for these scoped entries. */
- (NSArray<NSString*>*)requiredCompanionsForSourceKey:(NSString*)key;
- (BOOL)sourceKey:(NSString*)key allowsCompanion:(nullable NSString*)companion;
- (nullable id<MTLTexture>)textureForSourceKey:(NSString*)key
                             companionSource:(nullable NSString*)companion
                                     mipTail:(id<MTLTexture> _Nullable* _Nullable)mipTail
                                       error:(NSError**)error;
/* A hybrid entry has an ASTC prefix and an exact RGBA8 tail. Both allocations
 * belong to this same budgeted cache entry. The tail's logical first level is
 * the returned prefix's mipmapLevelCount; sampling must blend across that seam. */
- (nullable id<MTLTexture>)textureForSourceKey:(NSString*)key
                                     mipTail:(id<MTLTexture> _Nullable* _Nullable)mipTail
                                       error:(NSError**)error;
/* nil without error means the original artwork has no candidate. */
- (nullable id<MTLTexture>)textureForRGBA:(const void*)bytes
                                 length:(NSUInteger)length
                                  width:(NSUInteger)width
                                 height:(NSUInteger)height
                                  error:(NSError**)error;
@end

NS_ASSUME_NONNULL_END
#endif
