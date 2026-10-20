#import <UIKit/UIKit.h>
#import "protector/menu_input.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString* const ProtectorTouchScaleKey;
FOUNDATION_EXPORT NSString* const ProtectorTouchOpacityKey;
FOUNDATION_EXPORT NSString* const ProtectorTouchLabelsKey;
FOUNDATION_EXPORT NSString* const ProtectorTouchSwappedKey;
FOUNDATION_EXPORT NSString* const ProtectorTouchHapticsKey;
FOUNDATION_EXPORT NSString* const ProtectorTouchHideWithControllerKey;
/* Remembered presentation choices. Scale 0 is Native; fixed choices are 1, 2, 3 and 6. */
FOUNDATION_EXPORT NSString* const ProtectorRenderScaleKey;
FOUNDATION_EXPORT NSString* const ProtectorRenderSmoothMotionKey;
FOUNDATION_EXPORT void ProtectorRegisterTouchDefaults(void);

/* Shared controller focus for the native settings and its reading guide. */
@interface ProtectorControllerTableController : UITableViewController
@property(nonatomic) BOOL controllerNavigationActive;
@property(nonatomic, nullable) NSIndexPath* controllerSelection;
- (void)handleControllerCommand:(ProtectorMenuCommand)command;
@end

/* The same reading guide is reachable from Pause or the admitted game menu. */
@interface ProtectorControlsGuideController : ProtectorControllerTableController
@property(nonatomic, copy) void (^resumeGame)(void);
@property(nonatomic) BOOL controllerMode;
@property(nonatomic) BOOL fromGameMenu;
- (void)setReturnInProgress:(BOOL)returning;
@end

@interface ProtectorTouchSettingsController : ProtectorControllerTableController
@property(nonatomic, copy) void (^preferencesChanged)(void);
@property(nonatomic, copy) void (^resumeGame)(void);
@property(nonatomic, copy) void (^openGameMenu)(void);
/* Why the game paused by itself (controller or headphones disconnected). Shown above the sheet's notes. */
@property(nonatomic, copy, nullable) NSString* pauseReason;
/* Present only during gameplay. It sends input; it never enables a secret. */
@property(nonatomic, copy, nullable) void (^changeCamera)(void);
@property(nonatomic) BOOL hasSmoothMotion;
@property(nonatomic) BOOL smoothMotion;
/* Zero is Native; fixed choices are 1, 2, 3 and 6. */
@property(nonatomic) NSUInteger renderScale;
/* A non-nil string is a visible failure; the control retains its old value. */
@property(nonatomic, copy) NSString* _Nullable (^selectRendering)(NSString* key, NSUInteger value);
@end
NS_ASSUME_NONNULL_END
