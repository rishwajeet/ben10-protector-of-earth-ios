#import <UIKit/UIKit.h>

@interface ProtectorContentImportController : UIViewController
@property(nonatomic, copy) void (^playContent)(NSURL* contentRoot);
@end
