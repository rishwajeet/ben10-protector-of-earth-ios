#import <UIKit/UIKit.h>

#include "protector/cpu.h"

static UIViewController* MakeRootViewController(void) {
    CPUState cpu;
    BOOL runtimeReady = protector_cpu_init(&cpu);
    if (runtimeReady) {
        protector_prepare_wii_boot(&cpu);
        runtimeReady = cpu.stop_reason == PROTECTOR_STOP_NONE;
        protector_cpu_destroy(&cpu);
    }

    UIViewController* controller = [[UIViewController alloc] init];
    controller.view.backgroundColor =
        [UIColor colorWithRed:0.025 green:0.035 blue:0.055 alpha:1.0];

    UILabel* title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"BEN 10\nPROTECTOR NATIVE";
    title.numberOfLines = 2;
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor colorWithRed:0.45
                                     green:1.0
                                      blue:0.32
                                     alpha:1.0];
    title.font = [UIFont systemFontOfSize:31.0
                                  weight:UIFontWeightBlack];

    UILabel* status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text = runtimeReady
        ? @"ARM64 runtime online\nAwaiting translated game bundle"
        : @"Runtime initialization failed";
    status.numberOfLines = 2;
    status.textAlignment = NSTextAlignmentCenter;
    status.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    status.font = [UIFont monospacedSystemFontOfSize:14.0
                                             weight:UIFontWeightMedium];

    [controller.view addSubview:title];
    [controller.view addSubview:status];
    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor
            constraintEqualToAnchor:controller.view.centerXAnchor],
        [title.centerYAnchor
            constraintEqualToAnchor:controller.view.centerYAnchor
                           constant:-28.0],
        [title.leadingAnchor
            constraintGreaterThanOrEqualToAnchor:
                controller.view.leadingAnchor
                                       constant:24.0],
        [status.topAnchor constraintEqualToAnchor:title.bottomAnchor
                                         constant:20.0],
        [status.centerXAnchor
            constraintEqualToAnchor:controller.view.centerXAnchor],
    ]];
    return controller;
}

@interface ProtectorSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation ProtectorSceneDelegate

- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions {
    (void)session;
    (void)connectionOptions;
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }

    self.window = [[UIWindow alloc]
        initWithWindowScene:(UIWindowScene*)scene];
    self.window.rootViewController = MakeRootViewController();
    [self.window makeKeyAndVisible];
}

@end

@interface ProtectorAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ProtectorAppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    (void)application;
    (void)launchOptions;
    return YES;
}

@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        return UIApplicationMain(
            argc,
            argv,
            nil,
            NSStringFromClass([ProtectorAppDelegate class])
        );
    }
}
