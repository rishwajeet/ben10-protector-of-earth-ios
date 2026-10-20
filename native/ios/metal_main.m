#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>

#include "protector/cpu.h"
#import "protector/metal_renderer.h"

@interface ProtectorMetalViewController : UIViewController <MTKViewDelegate>
@property(nonatomic, strong) ProtectorMetalRenderer* renderer;
@property(nonatomic) NSUInteger frameIndex;
@end

@implementation ProtectorMetalViewController

- (void)showFailure:(NSString*)message {
    self.view = [[UIView alloc] initWithFrame:CGRectZero];
    self.view.backgroundColor =
        [UIColor colorWithRed:0.025 green:0.035 blue:0.055 alpha:1.0];
    UILabel* label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = message;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont monospacedSystemFontOfSize:14.0
                                             weight:UIFontWeightMedium];
    [self.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [label.widthAnchor constraintLessThanOrEqualToAnchor:
            self.view.widthAnchor multiplier:0.8],
    ]];
}

- (void)loadView {
    CPUState cpu;
    BOOL runtimeReady = protector_cpu_init(&cpu);
    if (runtimeReady) {
        protector_prepare_wii_boot(&cpu);
        runtimeReady = cpu.stop_reason == PROTECTOR_STOP_NONE;
        protector_cpu_destroy(&cpu);
    }
    if (!runtimeReady) {
        [self showFailure:@"ARM64 runtime initialization failed"];
        return;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        [self showFailure:@"This device has no Metal implementation"];
        return;
    }
    NSURL* scenePackURL =
        [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Canyon"
                                                         isDirectory:YES];
    NSError* error = nil;
    self.renderer =
        [[ProtectorMetalRenderer alloc] initWithDevice:device
                                          scenePackURL:scenePackURL
                                                 error:&error];
    if (!self.renderer) {
        [self showFailure:[NSString stringWithFormat:
            @"GX scene load failed\n%@", error.localizedDescription]];
        return;
    }

    MTKView* metalView = [[MTKView alloc] initWithFrame:CGRectZero
                                                device:device];
    metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    metalView.framebufferOnly = YES;
    metalView.autoResizeDrawable = NO;
    metalView.drawableSize =
        CGSizeMake(self.renderer.width, self.renderer.height);
    metalView.preferredFramesPerSecond =
        (NSInteger)self.renderer.preferredFramesPerSecond;
    metalView.enableSetNeedsDisplay = NO;
    metalView.paused = NO;
    metalView.delegate = self;
    self.view = metalView;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (void)mtkView:(MTKView*)view
    drawableSizeWillChange:(CGSize)size {
    (void)size;
    view.drawableSize =
        CGSizeMake(self.renderer.width, self.renderer.height);
}

- (void)drawInMTKView:(MTKView*)view {
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable || !self.renderer) {
        return;
    }
    double time =
        (double)self.frameIndex /
        (double)self.renderer.preferredFramesPerSecond;
    NSError* error = nil;
    if (![self.renderer presentFrameAtTime:time
                                  drawable:drawable
                                     error:&error]) {
        view.paused = YES;
        NSLog(@"Protector Metal presentation failed: %@", error);
        return;
    }
    self.frameIndex += 1;
}

@end

@interface ProtectorMetalSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation ProtectorMetalSceneDelegate

- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions {
    (void)session;
    (void)connectionOptions;
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    self.window =
        [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    self.window.rootViewController =
        [[ProtectorMetalViewController alloc] init];
    [self.window makeKeyAndVisible];

    UIWindowSceneGeometryPreferencesIOS* landscape =
        [[UIWindowSceneGeometryPreferencesIOS alloc]
            initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
    [(UIWindowScene*)scene
        requestGeometryUpdateWithPreferences:landscape
                                errorHandler:^(NSError* error) {
        NSLog(@"Landscape geometry request failed: %@", error);
    }];
}

@end

@interface ProtectorMetalAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ProtectorMetalAppDelegate

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
            NSStringFromClass([ProtectorMetalAppDelegate class])
        );
    }
}
