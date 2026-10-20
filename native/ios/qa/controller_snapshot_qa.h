#import <GameController/GameController.h>
/* Test transport only: off on devices, off outside the exact simulator QA
 * bundle, and opt-in per launch. It drives real framework snapshot elements
 * through the production input poller; it is not hardware qualification. */
@interface ProtectorControllerSnapshotQA : NSObject
@property(nonatomic, readonly) NSUInteger commandCount;
@property(nonatomic, readonly) NSString* lastCommand;
/* Optional read-only receipts, separately opted in by simulator tests. */
@property(nonatomic, copy) NSDictionary* (^stateReader)(void);
/* Optional "capture" command: audits the current frame without changing input. */
@property(nonatomic, copy) void (^captureHandler)(void);
+ (instancetype)startIfRequested:(void (^)(GCController*))connectionChanged;
@end
