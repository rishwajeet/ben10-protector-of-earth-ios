#ifndef PROTECTOR_GAME_SESSION_H
#define PROTECTOR_GAME_SESSION_H

#import "protector/live_metal_renderer.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const ProtectorGameSessionDidFinish;
typedef NS_ENUM(NSInteger, ProtectorGameEdition) {
    ProtectorGameEditionOriginal = 0,
    ProtectorGameEditionUpgraded = 1,
};

/* Shared macOS/iOS shell. Executes translated original code, never a scene
 * fixture. One session per process until the guest runtime is re-entrant. */
@interface ProtectorGameSession : NSObject
@property(nonatomic, readonly) ProtectorLiveMetalRenderer* renderer;
@property(atomic, readonly) BOOL finished;
@property(atomic, readonly) int bootResult;
@property(nonatomic, readonly, nullable) NSError* failure;
@property(nonatomic, readonly) NSURL* outputDirectory;
@property(nonatomic, readonly) NSURL* saveDirectory;
@property(nonatomic, readonly) ProtectorGameEdition edition;
@property(nonatomic, readonly) BOOL hasRestoredArtwork;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                               dataRoot:(NSURL*)dataRoot
                          kpadReference:(NSURL*)kpadReference
                      audioCoefficients:(NSURL*)audioCoefficients
                        outputDirectory:(NSURL*)outputDirectory
                          saveDirectory:(NSURL*)saveDirectory
                                  error:(NSError**)error;
/* originalSaveDirectory always names the original progress. Upgraded saves
 * are derived as a separate, marked sibling; toggling artwork never changes
 * the session edition or save namespace. */
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                               dataRoot:(NSURL*)dataRoot
                          kpadReference:(NSURL*)kpadReference
                      audioCoefficients:(NSURL*)audioCoefficients
                        outputDirectory:(NSURL*)outputDirectory
                  originalSaveDirectory:(NSURL*)originalSaveDirectory
                                edition:(ProtectorGameEdition)edition
                    texturePackManifest:(nullable NSURL*)texturePackManifest
                                  error:(NSError**)error;
- (void)start;
- (void)setPaused:(BOOL)paused;
- (void)requestStop;
- (void)saveDiagnosticSnapshot;
/* Coalesced status-only background I/O (no GPU readback/PNG) for periodic telemetry; explicit/final captures
 * retain synchronous saveDiagnosticSnapshot semantics. */
- (void)requestDiagnosticSnapshot;
/* Read-only, bounded lifecycle/input evidence. Frame/timebase values identify
 * admitted guest frames, not display fps. Reading never consumes input edges. */
- (NSDictionary*)inputLifecycleDiagnostics;
@end

NS_ASSUME_NONNULL_END
#endif
