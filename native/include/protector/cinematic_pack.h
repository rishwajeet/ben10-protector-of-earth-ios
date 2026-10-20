#ifndef PROTECTOR_CINEMATIC_PACK_H
#define PROTECTOR_CINEMATIC_PACK_H

#include "protector/cinematic.h"
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, ProtectorCinematicOpeningStatus) {
    ProtectorCinematicOpeningUnavailable = 0,
    ProtectorCinematicOpeningPending,
    ProtectorCinematicOpeningReady,
};

/* Immutable, exact source-frame replacement. The object retains its CoreVideo
 * surfaces; callers keep it alive until their Metal command buffer completes. */
@interface ProtectorCinematicImage : NSObject
@property(nonatomic, readonly) id<MTLTexture> luma;
@property(nonatomic, readonly) id<MTLTexture> chroma;
@property(nonatomic, readonly) NSUInteger frameIndex;
@property(nonatomic, readonly) uint64_t openSerial;
@property(nonatomic, readonly) NSString* movie;
@end

/* No player, audio output or wall clock. A private serial worker decodes a
 * bounded window ahead of the game. A render request only returns an exact
 * cached frame; nil means render the original source draw without waiting. */
@interface ProtectorCinematicPack : NSObject
@property(nonatomic, readonly) NSString* packID;
@property(nonatomic, readonly) NSString* manifestSHA256;
@property(nonatomic, readonly) NSUInteger entryCount;
- (nullable instancetype)initWithManifest:(NSURL*)manifest sourceDirectory:(NSURL*)source
    device:(id<MTLDevice>)device error:(NSError**)error;
/* Prepares at most the same bounded window before the first source picture.
 * This enqueue never waits; presentation still requires matching decoded-frame metadata. */
- (void)prepareOpening:(ProtectorCinematicOpening)opening;
/* Only the guest's pre-BinkOpen loading boundary may wait for readiness.
 * Ready means the entire bounded initial window, not merely frame zero. */
- (ProtectorCinematicOpeningStatus)statusForOpening:(ProtectorCinematicOpening)opening;
/* Pin this opening to source fallback after a loading timeout/cancellation.
 * A later decode must not cause a mid-film quality switch. */
- (void)abandonOpening:(ProtectorCinematicOpening)opening;
- (void)observeFrame:(ProtectorCinematicFrame)frame;
- (nullable ProtectorCinematicImage*)imageForFrame:(ProtectorCinematicFrame)frame;
- (NSDictionary*)diagnostics;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
#endif
#endif
