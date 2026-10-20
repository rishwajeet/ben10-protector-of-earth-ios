#import <UIKit/UIKit.h>

#include <stdio.h>
#include <stdlib.h>
#include <sys/utsname.h>

int protector_translated_boot_main(int argc, char** argv);

static void RunTranslatedPerformanceProbe(void) {
    @autoreleasepool {
        NSURL* documents = [
            [NSFileManager defaultManager]
            URLsForDirectory:NSDocumentDirectory
            inDomains:NSUserDomainMask
        ].firstObject;
        NSString* stdoutPath = [
            documents.path
            stringByAppendingPathComponent:@"r1-s2-performance.log"
        ];
        NSString* stderrPath = [
            documents.path
            stringByAppendingPathComponent:@"r1-s2-diagnostics.log"
        ];
        if (
            !freopen(stdoutPath.fileSystemRepresentation, "w", stdout) ||
            !freopen(stderrPath.fileSystemRepresentation, "w", stderr)
        ) {
            exit(21);
        }

        NSString* sourceRoot = [
            [NSBundle mainBundle].resourcePath
            stringByAppendingPathComponent:@"Source"
        ];
        NSString* dataRoot = [
            sourceRoot stringByAppendingPathComponent:@"DATA"
        ];
        NSString* dolPath = [
            dataRoot stringByAppendingPathComponent:@"sys/main.dol"
        ];
        NSFileManager* files = [NSFileManager defaultManager];
        if (
            ![files fileExistsAtPath:dolPath] ||
            ![files fileExistsAtPath:[
                dataRoot stringByAppendingPathComponent:@"sys/fst.bin"
            ]]
        ) {
            fprintf(stderr, "protector_perf_error=missing_source_slice\n");
            fflush(stderr);
            exit(20);
        }

        if (!getenv("PROTECTOR_MAX_BLOCKS")) {
            (void)setenv("PROTECTOR_MAX_BLOCKS", "2000000", 1);
        }
        if (!getenv("PROTECTOR_WUD_STATUS")) {
            (void)setenv("PROTECTOR_WUD_STATUS", "3", 1);
        }
        if (!getenv("PROTECTOR_CONTROLLER_CONNECTED")) {
            (void)setenv("PROTECTOR_CONTROLLER_CONNECTED", "1", 1);
        }
        (void)setenv("PROTECTOR_ALLOW_SOURCE_PREFIX_FILES", "1", 1);

        struct utsname systemInfo;
        const char* machine = "unknown";
        if (uname(&systemInfo) == 0) {
            machine = systemInfo.machine;
        }
        printf(
            "protector_perf_start platform=iphoneos machine=%s "
            "thermal_state=%ld low_power_mode=%u\n",
            machine,
            (long)[NSProcessInfo processInfo].thermalState,
            [NSProcessInfo processInfo].lowPowerModeEnabled ? 1u : 0u
        );
        fflush(stdout);

        char* arguments[] = {
            "protector_ios_perf",
            "--dol",
            (char*)dolPath.fileSystemRepresentation,
            "--data-root",
            (char*)dataRoot.fileSystemRepresentation,
            NULL,
        };
        int result = protector_translated_boot_main(5, arguments);
        printf("protector_perf_exit boot_result=%d\n", result);
        fflush(stdout);
        fflush(stderr);

        /*
         * Exhausting the requested block window is the expected performance
         * runner stop. The detailed status line still carries the guest stop
         * and exception state for the host-side verifier.
         */
        exit(result == 10 ? 0 : result);
    }
}

@interface ProtectorPerfSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation ProtectorPerfSceneDelegate

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
    UIViewController* controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = [UIColor blackColor];

    UILabel* label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"Measuring translated original…";
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont monospacedSystemFontOfSize:15.0
                                             weight:UIFontWeightMedium];
    [controller.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor
            constraintEqualToAnchor:controller.view.centerXAnchor],
        [label.centerYAnchor
            constraintEqualToAnchor:controller.view.centerYAnchor],
    ]];

    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^{
            RunTranslatedPerformanceProbe();
        }
    );
}

@end

@interface ProtectorPerfAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ProtectorPerfAppDelegate

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
            NSStringFromClass([ProtectorPerfAppDelegate class])
        );
    }
}
