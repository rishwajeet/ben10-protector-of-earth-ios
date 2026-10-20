#ifndef PROTECTOR_LIVE_METAL_RENDERER_H
#define PROTECTOR_LIVE_METAL_RENDERER_H

#include "protector/live_gx.h"
#include "protector/qte_presentation.h"
#include "protector/cinematic_pack.h"

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "protector/cinematic.h"
#import <QuartzCore/CAMetalLayer.h>

NS_ASSUME_NONNULL_BEGIN

@interface ProtectorLiveMetalRenderer : NSObject

@property(atomic, readonly) BOOL complete;
// Published across the guest/render and UIKit threads. The GX accessor itself
// is thread-local and must not be used to inspect playback from UIKit.
@property(atomic, readonly) ProtectorCinematicFrame cinematicFrame;
@property(atomic, readonly, nullable) NSError* failure;
@property(atomic, readonly)
    NSDictionary<NSString*, id>* stateCapture;
/* Diagnostic launches only: audit the next source frame into a transition
 * slot, including every draw that samples a same-frame EFB copy. */
- (BOOL)requestManualFrameAudit;

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                         outputDirectory:(NSURL*)outputDirectory
                            targetFrames:(NSArray<NSNumber*>*)targetFrames
                                   error:(NSError**)error;

/* Interactive mode renders every submitted frame, retains bounded telemetry,
 * and never reports a capture-proof completion or writes per-frame PNGs. */
- (nullable instancetype)initContinuousWithDevice:(id<MTLDevice>)device
                                  outputDirectory:(NSURL*)outputDirectory
                                            error:(NSError**)error;

/* Explicit upgraded-art lane. Capture and default interactive initializers
 * remain original-only. Artwork can be toggled for same-session comparisons. */
- (nullable instancetype)initContinuousWithDevice:(id<MTLDevice>)device
                                  outputDirectory:(NSURL*)outputDirectory
                              texturePackManifest:(nullable NSURL*)manifest
                                            error:(NSError**)error;
/* Presentation upgrades are independent of whether an artwork pack is loaded.
 * Default/capture initializers leave this disabled and stay at original scale. */
- (nullable instancetype)initContinuousWithDevice:(id<MTLDevice>)device
                                  outputDirectory:(NSURL*)outputDirectory
                              texturePackManifest:(nullable NSURL*)manifest
                             presentationUpgrades:(BOOL)enabled
                                            error:(NSError**)error;
@property(atomic) BOOL restoredArtworkEnabled;
@property(atomic, readonly) NSUInteger renderScale;
- (BOOL)selectRenderScale:(NSUInteger)scale error:(NSError**)error;
/* Native mode resolves a 1–6 scale from drawable pixels and each frame's actual
 * display rectangle. Explicit scale selection leaves Native mode. */
@property(atomic, readonly) BOOL nativeResolutionEnabled;
- (BOOL)selectNativeRenderSize:(CGSize)pixels error:(NSError**)error;
/* Preview: widen the main scene horizontally, retain a centred 4:3 HUD/menu
 * safe area, and leave offscreen/shadow projections at their original aspect.
 * Render-target pixels remain anamorphic, as in the original TV presentation. */
@property(atomic, readonly) BOOL widescreenEnabled;
- (BOOL)selectWidescreen:(BOOL)enabled error:(NSError**)error;
/* Enhanced native shell supplies logical-point bounds and a noninteractive
 * HUD destination. Only widescreen presentation uses them; Original stays 4:3.
 * Unknown UI draws retain their centred source layout. No guest state changes. */
- (BOOL)configureNativePresentationSize:(CGSize)size hudFrame:(CGRect)hud error:(NSError**)error;
- (BOOL)configureNativeComboFrame:(CGRect)frame error:(NSError**)error;
- (BOOL)configureNativeUpgradeFrame:(CGRect)frame error:(NSError**)error;
- (BOOL)configureNativeCombatFeedbackFrame:(CGRect)frame error:(NSError**)error;
/* Complete map postcard units, original title and source help text. Invalid or
 * unknown/transitioning source compositions retain their original layout. */
- (BOOL)configureNativeMapTitle:(CGRect)title cards:(CGRect)cards hints:(CGRect)hints error:(NSError**)error;
@property(atomic, readonly) double presentationAspect;
/* Exact active source pictures in the latest completed render. Presentation
 * hints only; original scripts continue to own success, failure and timing. */
@property(atomic, readonly) unsigned qtePrompts;
/* Pointer coordinates stay in the QTE domain while its cursor/feedback is
 * visible between targets; a hidden instruction is not a coordinate reset. */
@property(atomic, readonly) BOOL qtePointerActive;
/* Union of admitted target bounds in normalized, top-left native coordinates.
 * CGRectNull when absent; host captions avoid it without moving source art. */
@property(atomic, readonly) CGRect qteTargetRect;
/* Normalized horizontal space between the current native thumb controls.
 * Empty means retain source placement. Only admitted motion art uses it. */
@property(atomic) CGRect qteMotionSafeRect;
/* Re-render the retained immutable draw snapshot without advancing guest code.
 * Only upgraded interactive sessions retain a frame. Calls serialize against
 * normal decode/render work, making paused same-camera comparisons safe. */
- (BOOL)selectRestoredArtwork:(BOOL)enabled error:(NSError**)error;
/* Explicit source-bound model candidate. Load before the first submitted frame
 * in an upgraded session. The independent toggle retains original geometry. */
@property(atomic, readonly) BOOL enhancedModelsEnabled;
- (BOOL)loadGeometryPack:(NSURL*)manifest error:(NSError**)error;
- (BOOL)loadCinematicPack:(NSURL*)manifest sourceDirectory:(NSURL*)source error:(NSError**)error;
- (void)prepareCinematicOpening:(ProtectorCinematicOpening)opening;
- (ProtectorCinematicOpeningStatus)statusForCinematicOpening:(ProtectorCinematicOpening)opening;
- (void)abandonCinematicOpening:(ProtectorCinematicOpening)opening;
- (BOOL)selectEnhancedModels:(BOOL)enabled error:(NSError**)error;

- (BOOL)writeLatestFrameToURL:(NSURL*)destination error:(NSError**)error;
/* Pins a completed immutable texture and its matching renderer state briefly
 * under the render lock, then compresses/writes after releasing the lock. */
- (nullable NSDictionary*)writeLatestDiagnosticFrameToURL:(NSURL*)destination error:(NSError**)error;

- (ProtectorLiveGXResult)consumeFrame:(u32)frameIndex
                                 fifo:(const u8*)fifo
                                 size:(size_t)fifoSize
                                  cpu:(CPUState*)cpu;
/* Original guest-pacer deadline, never a newly invented simulation timestamp.
 * The no-deadline entry remains suitable for offline capture and original mode. */
- (ProtectorLiveGXResult)consumeFrame:(u32)frameIndex
                                 fifo:(const u8*)fifo size:(size_t)fifoSize
                                  cpu:(CPUState*)cpu hostDeadline:(double)deadline;
/* Smooth motion is an opt-in Enhanced presentation preview. It leaves guest
 * timing unchanged and adds approximately one source frame of display delay. */
@property(atomic, readonly) BOOL smoothMotionAvailable;
@property(atomic, readonly) BOOL smoothMotionEnabled;
- (BOOL)selectSmoothMotion:(BOOL)enabled error:(NSError**)error;
/* Clears interpolation history at lifecycle/configuration boundaries. */
- (void)setPresentationPaused:(BOOL)paused;
- (void)resetMotionHistory;
@property(atomic, readonly) BOOL motionPresentationPrototypeEnabled;

- (BOOL)presentLatestDrawable:(id<CAMetalDrawable>)drawable
                        error:(NSError**)error;
/* Host display cadence only; never changes the translated simulation clock.
 * A zero/invalid duration preserves immediate presentation for diagnostics. */
- (BOOL)presentLatestDrawable:(id<CAMetalDrawable>)drawable
             minimumDuration:(CFTimeInterval)duration
                        error:(NSError**)error;
/* Exponentially smoothed GPU duration of live presentation commands (seconds;
 * zero until measured). Drives the host presentation cadence. */
@property(atomic, readonly) double smoothedGPUSeconds;
/* Memory pressure: release rebuildable caches (restored textures outside the
 * current frame, uploaded source textures, decoded texture cache). Returns an
 * approximate byte count released. Safe from the main thread during play. */
- (NSUInteger)trimCachesForMemoryPressure;

@end

NS_ASSUME_NONNULL_END
#endif

#endif
