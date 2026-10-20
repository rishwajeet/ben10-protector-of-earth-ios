#import <Foundation/Foundation.h>

/* Posted on the main queue when an external output (headphones, Bluetooth, AirPlay)
 * goes away, so the game can pause as Apple's guidelines ask. */
FOUNDATION_EXPORT NSNotificationName const ProtectorAudioRouteLostNotification;

@interface ProtectorNativeAudioOutput : NSObject
@property(nonatomic, readonly) NSError* lastError;
@property(nonatomic, readonly) NSDictionary* diagnostics;
- (BOOL)start;
- (void)setPaused:(BOOL)paused;
- (void)stop;
@end
