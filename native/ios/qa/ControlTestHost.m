// Empty UI-test host. Tests address the separately built translated-game app
// by exact QA bundle ID. This contains no gameplay fixture or game resources.
#import <UIKit/UIKit.h>
@interface ProtectorControlTestHost : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow* window;
@end
@implementation ProtectorControlTestHost
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UIViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char** argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProtectorControlTestHost.class)); }
}
