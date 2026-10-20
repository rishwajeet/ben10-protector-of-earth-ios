#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Independent of saves. Call import on a serial worker, never the main thread.
@interface ProtectorContentStore : NSObject
@property(nonatomic, readonly) NSURL* root;
- (instancetype)initWithRoot:(NSURL*)root;
- (nullable NSURL*)activeContent:(NSError**)error;
- (nullable NSURL*)importPackage:(NSURL*)package
    progress:(void (^)(double progress))progress
    cancelled:(BOOL (^)(void))cancelled error:(NSError**)error;
@end
NS_ASSUME_NONNULL_END
