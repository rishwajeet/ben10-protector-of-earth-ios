#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>

#import "protector/live_metal_renderer.h"

#include <stdio.h>
#include <stdlib.h>

extern "C" int protector_translated_ios_live_metal_main(
    int argc,
    char** argv
);

static NSString* const ProtectorTitlePulses =
    @"700:0x0800,"
    "1250:0x2000,"
    "1300:0x0800,"
    "1350:0x0800,"
    "1400:0x0800,"
    "1450:0x0800,"
    "1500:0x0800,"
    "1550:0x0800,"
    "1600:0x0800,"
    "2050:0x0800";

static ProtectorLiveGXResult ReceiveLiveGX(
    u32 frameIndex,
    const u8* fifo,
    size_t fifoSize,
    CPUState* cpu,
    void* userData
) {
    ProtectorLiveMetalRenderer* renderer =
        (__bridge ProtectorLiveMetalRenderer*)userData;
    return [renderer consumeFrame:frameIndex
                             fifo:fifo
                             size:fifoSize
                              cpu:cpu];
}

static BOOL WriteJSON(
    NSDictionary* value,
    NSURL* destination,
    NSError** error
) {
    NSData* data = [NSJSONSerialization
        dataWithJSONObject:value
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
        error:error
    ];
    if (!data) {
        return NO;
    }
    NSMutableData* terminated = [data mutableCopy];
    const u8 newline = '\n';
    [terminated appendBytes:&newline length:1u];
    return [terminated writeToURL:destination
                          options:NSDataWritingAtomic
                            error:error];
}

static NSString* ConnectedKPADTemplate(NSError** error) {
    NSURL* reference = [
        NSBundle.mainBundle URLForResource:@"r2-kpad"
                            withExtension:@"json"
    ];
    if (!reference) {
        if (error) {
            *error = [NSError
                errorWithDomain:@"house.machine.ProtectorNative.R2Title"
                code:1
                userInfo:@{
                    NSLocalizedDescriptionKey :
                        @"the signed app has no source-bound KPAD reference"
                }
            ];
        }
        return nil;
    }
    NSData* data = [NSData dataWithContentsOfURL:reference
                                         options:0
                                           error:error];
    if (!data) {
        return nil;
    }
    NSDictionary* value = [NSJSONSerialization
        JSONObjectWithData:data
        options:0
        error:error
    ];
    if (![value[@"schema"]
        isEqual:@"protector-native.dolphin-kpad-status/v1"]) {
        if (error) {
            *error = [NSError
                errorWithDomain:@"house.machine.ProtectorNative.R2Title"
                code:2
                userInfo:@{
                    NSLocalizedDescriptionKey :
                        @"the KPAD reference has the wrong schema"
                }
            ];
        }
        return nil;
    }
    for (NSDictionary* poll in value[@"polls"]) {
        NSDictionary* status = poll[@"status"];
        NSString* raw = status[@"raw_hex"];
        if (
            [status[@"device_type"] unsignedIntegerValue] == 1u &&
            [status[@"wpad_error"] integerValue] == 0 &&
            [raw isKindOfClass:[NSString class]] &&
            raw.length == 264u
        ) {
            return raw;
        }
    }
    if (error) {
        *error = [NSError
            errorWithDomain:@"house.machine.ProtectorNative.R2Title"
            code:3
            userInfo:@{
                NSLocalizedDescriptionKey :
                    @"the KPAD reference has no connected Nunchuk sample"
            }
        ];
    }
    return nil;
}

@interface ProtectorLiveTitleController
    : UIViewController <MTKViewDelegate>
@property(nonatomic, strong) MTKView* metalView;
@property(nonatomic, strong) UILabel* statusLabel;
@property(nonatomic, strong) ProtectorLiveMetalRenderer* renderer;
@property(nonatomic, strong) NSURL* outputDirectory;
@end

@implementation ProtectorLiveTitleController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self.metalView = [[MTKView alloc] initWithFrame:CGRectZero
                                            device:device];
    self.metalView.translatesAutoresizingMaskIntoConstraints = NO;
    self.metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.metalView.clearColor = MTLClearColorMake(0, 0, 0, 1);
    self.metalView.preferredFramesPerSecond = 30;
    self.metalView.delegate = self;
    [self.view addSubview:self.metalView];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Running translated original…";
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font =
        [UIFont monospacedSystemFontOfSize:14.0
                                   weight:UIFontWeightMedium];
    [self.view addSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.metalView.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor],
        [self.metalView.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor],
        [self.metalView.topAnchor
            constraintEqualToAnchor:self.view.topAnchor],
        [self.metalView.bottomAnchor
            constraintEqualToAnchor:self.view.bottomAnchor],
        [self.statusLabel.centerXAnchor
            constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.centerYAnchor
            constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    self.outputDirectory = [[
        NSFileManager.defaultManager
        URLsForDirectory:NSDocumentDirectory
        inDomains:NSUserDomainMask
    ].firstObject URLByAppendingPathComponent:@"r2-live-metal"
                                  isDirectory:YES];
    NSError* error = nil;
    self.renderer = [[ProtectorLiveMetalRenderer alloc]
        initWithDevice:device
        outputDirectory:self.outputDirectory
        targetFrames:@[@2000, @2200]
        error:&error
    ];
    if (!self.renderer) {
        self.statusLabel.text = error.localizedDescription;
        return;
    }
    for (NSString* name in @[
        @"state.json",
        @"frame-2000.png",
        @"frame-2200.png",
        @"stdout.log",
        @"stderr.log",
    ]) {
        [NSFileManager.defaultManager
            removeItemAtURL:[
                self.outputDirectory URLByAppendingPathComponent:name
            ]
            error:NULL
        ];
    }
    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^{
            [self runTranslatedTitle];
        }
    );
}

- (void)runTranslatedTitle {
    @autoreleasepool {
        NSError* error = nil;
        NSString* kpadTemplate = ConnectedKPADTemplate(&error);
        NSString* resourceRoot = [
            NSBundle.mainBundle.resourcePath
            stringByAppendingPathComponent:@"Source"
        ];
        NSString* dataRoot = [
            resourceRoot stringByAppendingPathComponent:@"DATA"
        ];
        NSString* dolPath = [
            dataRoot stringByAppendingPathComponent:@"sys/main.dol"
        ];
        NSFileManager* files = NSFileManager.defaultManager;
        if (
            !kpadTemplate ||
            ![files fileExistsAtPath:dolPath] ||
            ![files fileExistsAtPath:[
                dataRoot stringByAppendingPathComponent:@"sys/fst.bin"
            ]]
        ) {
            NSString* message = error.localizedDescription
                ? error.localizedDescription
                : @"the signed app has no complete title source slice";
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.text = message;
            });
            return;
        }

        NSString* stdoutPath = [
            self.outputDirectory.path
            stringByAppendingPathComponent:@"stdout.log"
        ];
        NSString* stderrPath = [
            self.outputDirectory.path
            stringByAppendingPathComponent:@"stderr.log"
        ];
        if (
            !freopen(stdoutPath.fileSystemRepresentation, "w", stdout) ||
            !freopen(stderrPath.fileSystemRepresentation, "w", stderr)
        ) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.text = @"Could not open proof logs";
            });
            return;
        }

        (void)setenv("PROTECTOR_MAX_BLOCKS", "80000000", 1);
        (void)setenv("PROTECTOR_WUD_STATUS", "3", 1);
        (void)setenv("PROTECTOR_CONTROLLER_CONNECTED", "1", 1);
        (void)setenv(
            "PROTECTOR_KPAD_TEMPLATE_HEX",
            kpadTemplate.UTF8String,
            1
        );
        (void)setenv(
            "PROTECTOR_KPAD_PULSES",
            ProtectorTitlePulses.UTF8String,
            1
        );
        (void)setenv("PROTECTOR_ALLOW_SOURCE_PREFIX_FILES", "1", 1);

        protector_live_gx_set_sink(
            ReceiveLiveGX,
            (__bridge void*)self.renderer
        );
        char* arguments[] = {
            (char*)"protector_ios_live_metal",
            (char*)"--dol",
            (char*)dolPath.fileSystemRepresentation,
            (char*)"--data-root",
            (char*)dataRoot.fileSystemRepresentation,
            NULL,
        };
        const int bootResult =
            protector_translated_ios_live_metal_main(5, arguments);
        protector_live_gx_set_sink(NULL, NULL);

        NSMutableDictionary* state =
            [self.renderer.stateCapture mutableCopy];
        state[@"platform"] = @"iphoneos";
        state[@"bundle_identifier"] =
            NSBundle.mainBundle.bundleIdentifier
                ? NSBundle.mainBundle.bundleIdentifier
                : @"";
        state[@"boot_result"] = @(bootResult);
        state[@"audio_enabled"] = @NO;
        state[@"screen_submission"] = @"in_process_metal_drawable";
        NSURL* stateURL = [
            self.outputDirectory URLByAppendingPathComponent:@"state.json"
        ];
        if (!WriteJSON(state, stateURL, &error)) {
            fprintf(
                stderr,
                "state_write_error=%s\n",
                error.localizedDescription.UTF8String
            );
        }
        fflush(stdout);
        fflush(stderr);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (
                self.renderer.complete &&
                !self.renderer.failure &&
                bootResult == 0
            ) {
                self.statusLabel.hidden = YES;
            } else {
                self.statusLabel.text =
                    self.renderer.failure.localizedDescription
                        ? self.renderer.failure.localizedDescription
                        : [NSString stringWithFormat:
                            @"Translated execution stopped (%d)",
                            bootResult
                        ];
            }
        });
    }
}

- (void)mtkView:(MTKView*)view
    drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
}

- (void)drawInMTKView:(MTKView*)view {
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable || !self.renderer) {
        return;
    }
    NSError* error = nil;
    if (![self.renderer presentLatestDrawable:drawable error:&error]) {
        self.statusLabel.hidden = NO;
        self.statusLabel.text = error.localizedDescription;
    } else if ([self.renderer.stateCapture[@"submissions"] count] > 0u) {
        self.statusLabel.hidden = YES;
    }
}

@end

@interface ProtectorLiveTitleSceneDelegate
    : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation ProtectorLiveTitleSceneDelegate

- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions {
    (void)session;
    (void)connectionOptions;
    if (![scene isKindOfClass:UIWindowScene.class]) {
        return;
    }
    self.window = [[UIWindow alloc]
        initWithWindowScene:(UIWindowScene*)scene];
    self.window.rootViewController =
        [[ProtectorLiveTitleController alloc] init];
    [self.window makeKeyAndVisible];
}

@end

@interface ProtectorLiveTitleAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ProtectorLiveTitleAppDelegate

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
            NSStringFromClass(ProtectorLiveTitleAppDelegate.class)
        );
    }
}
