#import <UIKit/UIKit.h>

// Present only from the pre-Play utility screen, never over a running session.
@interface ProtectorSaveBackupController : UITableViewController
- (instancetype)initWithSaveDirectory:(NSURL*)directory;
@end
