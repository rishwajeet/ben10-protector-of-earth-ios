#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import "protector/game_session.h"
#import "protector/motion_clock.h"
#import "protector/live_input.h"
#import "protector/ui_context.h"

@interface ProtectorGameView : MTKView
@property(nonatomic) NSMutableIndexSet* keys;
@property(nonatomic) NSTrackingArea* pointerTracking;
@property(nonatomic) BOOL mouseA;
@property(nonatomic) float presentationAspect;
@property(nonatomic) BOOL qtePointer;
- (void)clearInput;
@end

@implementation ProtectorGameView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)publishInput {
    uint32_t held = self.mouseA ? PROTECTOR_BUTTON_A : 0;
    const unsigned short codes[] = {6, 49, 7, 8, 56, 36, 27, 123, 124, 125, 126};
    const uint32_t masks[] = {PROTECTOR_BUTTON_A, PROTECTOR_BUTTON_A,
        PROTECTOR_BUTTON_B, PROTECTOR_BUTTON_C, PROTECTOR_BUTTON_Z,
        PROTECTOR_BUTTON_PLUS, PROTECTOR_BUTTON_MINUS, PROTECTOR_BUTTON_LEFT,
        PROTECTOR_BUTTON_RIGHT, PROTECTOR_BUTTON_DOWN, PROTECTOR_BUTTON_UP};
    for (size_t i = 0; i < sizeof(codes) / sizeof(*codes); ++i)
        if ([self.keys containsIndex:codes[i]]) held |= masks[i];
    if (protector_ui_context_current() == PROTECTOR_UI_GAMEPLAY && [self.keys containsIndex:9])
        held |= PROTECTOR_BUTTON_ONE; // V: original closeup-camera input.
    const float x = ([self.keys containsIndex:2] ? 1.0f : 0.0f) -
        ([self.keys containsIndex:0] ? 1.0f : 0.0f);
    const float y = ([self.keys containsIndex:13] ? 1.0f : 0.0f) -
        ([self.keys containsIndex:1] ? 1.0f : 0.0f);
    protector_live_input_update(held, x, y);
    protector_live_input_motion([self.keys containsIndex:46]
        ? PROTECTOR_MOTION_WIIMOTE | PROTECTOR_MOTION_NUNCHUK : 0);
}
- (void)keyDown:(NSEvent*)event {
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        [super keyDown:event];
        return;
    }
    // Keep deliberate keyboard navigation independent from the last mouse
    // hover. M is the shake input and may be used while pointing at a QTE.
    if (event.keyCode != 46) protector_live_input_clear_pointer();
    [self.keys addIndex:event.keyCode];
    [self publishInput];
}
- (void)keyUp:(NSEvent*)event {
    [self.keys removeIndex:event.keyCode];
    [self publishInput];
}
- (void)flagsChanged:(NSEvent*)event {
    if (event.modifierFlags & NSEventModifierFlagShift) [self.keys addIndex:56];
    else [self.keys removeIndex:56];
    [self publishInput];
}
- (void)clearInput {
    [self.keys removeAllIndexes];
    self.mouseA = NO;
    protector_live_input_cancel();
}
- (void)updateTrackingAreas {
    if (self.pointerTracking) [self removeTrackingArea:self.pointerTracking];
    self.pointerTracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:self.pointerTracking];
    [super updateTrackingAreas];
}
- (void)pointWithEvent:(NSEvent*)event {
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    float x = 0, y = 0;
    const auto map=self.qtePointer?protector_live_input_map_qte_pointer_for_aspect:
        protector_live_input_map_pointer_for_aspect;
    const BOOL valid = map((float)point.x,
        (float)(self.isFlipped ? point.y : self.bounds.size.height - point.y),
        (float)self.bounds.size.width, (float)self.bounds.size.height,
        self.presentationAspect>0?self.presentationAspect:4.f/3.f, &x, &y);
    if (valid) protector_live_input_pointer(true, x, y);
    else protector_live_input_clear_pointer();
}
- (void)mouseMoved:(NSEvent*)event { [self pointWithEvent:event]; }
- (void)mouseDragged:(NSEvent*)event { [self pointWithEvent:event]; }
- (void)mouseDown:(NSEvent*)event {
    [self.window makeFirstResponder:self];
    [self pointWithEvent:event];
    self.mouseA = YES;
    [self publishInput];
}
- (void)mouseUp:(NSEvent*)event {
    [self pointWithEvent:event];
    self.mouseA = NO;
    [self publishInput];
}
- (void)mouseExited:(NSEvent*)event {
    (void)event;
    protector_live_input_clear_pointer();
}
@end

@interface ProtectorAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate,
                                           MTKViewDelegate>
@property(nonatomic) NSWindow* window;
@property(nonatomic) ProtectorGameView* gameView;
@property(nonatomic) ProtectorGameSession* session;
@property(nonatomic) NSTextField* status;
@property(nonatomic) NSTimer* statusTimer;
@property(nonatomic) BOOL terminating;
@property(nonatomic) BOOL manuallyPaused;
@property(nonatomic) BOOL hasModelCandidate;
@property(nonatomic) unsigned displayedQTEPrompts;
@end

@implementation ProtectorAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    NSArray<NSString*>* arguments = NSProcessInfo.processInfo.arguments;
    if (arguments.count != 4 && arguments.count != 5) {
        fprintf(stderr, "usage: protector_interactive DATA_ROOT KPAD_JSON OUTPUT_DIR [SAVE_DIR]\n");
        [NSApp terminate:nil];
        return;
    }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSError* error = nil;
    NSURL* output = [NSURL fileURLWithPath:arguments[3] isDirectory:YES];
    NSURL* saves = arguments.count == 5
        ? [NSURL fileURLWithPath:arguments[4] isDirectory:YES]
        : [output URLByAppendingPathComponent:@"OriginalSaves" isDirectory:YES];
    NSDictionary<NSString*, NSString*>* environment = NSProcessInfo.processInfo.environment;
    const ProtectorGameEdition edition = ProtectorGameEditionUpgraded;
    NSString* packPath = environment[@"PROTECTOR_TEXTURE_PACK"];
    if (packPath && !packPath.isAbsolutePath) {
        fprintf(stderr, "PROTECTOR_TEXTURE_PACK requires an absolute pack.json path.\n");
        [NSApp terminate:nil];
        return;
    }
    NSURL* pack = packPath ? [NSURL fileURLWithPath:packPath] : nil;
    NSString* geometryPath = environment[@"PROTECTOR_GEOMETRY_PACK"];
    NSString* cinematicPath = environment[@"PROTECTOR_CINEMATIC_PACK"];
    if (cinematicPath && !cinematicPath.isAbsolutePath) {
        fprintf(stderr, "PROTECTOR_CINEMATIC_PACK requires an absolute cinematics.json path.\n");
        [NSApp terminate:nil];
        return;
    }
    if (geometryPath && !geometryPath.isAbsolutePath) {
        fprintf(stderr, "PROTECTOR_GEOMETRY_PACK requires an absolute geometry.json path.\n");
        [NSApp terminate:nil];
        return;
    }
    const char* coefficientOverride = getenv("PROTECTOR_AX_COEFFICIENTS_PATH");
    NSURL* coefficients = coefficientOverride
        ? [NSURL fileURLWithPath:@(coefficientOverride)]
        : [NSBundle.mainBundle URLForResource:@"ax-coefficients" withExtension:@"bin"];
    if (!coefficients) {
        fprintf(stderr, "The app is missing its admitted DSP coefficient resource.\n");
        [NSApp terminate:nil];
        return;
    }
    self.session = [[ProtectorGameSession alloc] initWithDevice:device
        dataRoot:[NSURL fileURLWithPath:arguments[1] isDirectory:YES]
        kpadReference:[NSURL fileURLWithPath:arguments[2]]
        audioCoefficients:coefficients
        outputDirectory:output originalSaveDirectory:saves edition:edition texturePackManifest:pack
        error:&error];
    if (!self.session) {
        fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        [NSApp terminate:nil];
        return;
    }
    if (cinematicPath && ![self.session.renderer loadCinematicPack:[NSURL fileURLWithPath:cinematicPath]
            sourceDirectory:[NSURL fileURLWithPath:arguments[1] isDirectory:YES] error:&error]) {
        fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        [NSApp terminate:nil];
        return;
    }
    if (geometryPath) {
        if (![self.session.renderer loadGeometryPack:[NSURL fileURLWithPath:geometryPath] error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            [NSApp terminate:nil];
            return;
        }
        self.hasModelCandidate = YES;
    }
    if (![self.session.renderer selectRenderScale:3 error:&error] ||
        ![self.session.renderer selectWidescreen:YES error:&error] ||
        ![self.session.renderer selectSmoothMotion:YES error:&error]) {
        fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        [NSApp terminate:nil];
        return;
    }
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1120, 700)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Protector of Earth Enhanced · audio off";
    self.window.delegate = self;
    self.window.acceptsMouseMovedEvents = YES;
    self.window.contentMinSize = NSMakeSize(640, 510);
    self.gameView = [[ProtectorGameView alloc] initWithFrame:NSZeroRect device:device];
    self.gameView.keys = [NSMutableIndexSet indexSet];
    self.gameView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.gameView.clearColor = MTLClearColorMake(0, 0, 0, 1);
    self.gameView.preferredFramesPerSecond = 60;
    self.gameView.delegate = self;
    self.gameView.translatesAutoresizingMaskIntoConstraints = NO;
    self.status = [NSTextField labelWithString:
        @"WASD move   Z / Space attack / confirm   X heavy / back   C block   Shift jump\nReturn game menu   Arrows Omnitrix / menu navigation   Mouse point   Hold M interact"];
    self.status.maximumNumberOfLines = 2;
    self.status.font = [NSFont systemFontOfSize:12];
    self.status.textColor = NSColor.secondaryLabelColor;
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    NSView* content = self.window.contentView;
    [content addSubview:self.gameView];
    [content addSubview:self.status];
    [NSLayoutConstraint activateConstraints:@[
        [self.gameView.topAnchor constraintEqualToAnchor:content.topAnchor],
        [self.gameView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.gameView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.gameView.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-8],
        [self.status.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [self.status.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [self.status.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-8],
    ]];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.gameView];
    [self updateDisplayCadence];
    [NSApp activateIgnoringOtherApps:YES];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sessionDidFinish:)
        name:ProtectorGameSessionDidFinish object:self.session];
    [self.session start];
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self
        selector:@selector(updateStatus:) userInfo:nil repeats:YES];
}
- (void)updateStatus:(NSTimer*)timer {
    (void)timer;
    NSDictionary* state = self.session.renderer.stateCapture;
    self.window.title = [NSString stringWithFormat:
        @"Protector of Earth Enhanced · %lu× render · frame %@ · audio off%@%@",
        (unsigned long)self.session.renderer.renderScale,
        state[@"frame_index"] ? state[@"frame_index"] : @0,
        self.manuallyPaused ? @" · paused" : @"",
        self.session.finished ? @" · stopped" : @""];
    if (self.session.failure) {
        self.status.stringValue = self.session.failure.localizedDescription;
    }
    if (timer) [self.session requestDiagnosticSnapshot];
    else [self.session saveDiagnosticSnapshot];
}
- (void)updateQTEInstruction {
    const unsigned prompts=!self.manuallyPaused && !self.session.finished && NSApp.active &&
        protector_ui_context_current()==PROTECTOR_UI_GAMEPLAY
        ? self.session.renderer.qtePrompts : 0;
    if(prompts==self.displayedQTEPrompts)return;
    self.displayedQTEPrompts=prompts;
    if(self.session.failure)return;
    self.status.stringValue=prompts ? @(protector_qte_instruction(prompts,NO,YES)) :
        @"WASD move   Z / Space attack / confirm   X heavy / back   C block   Shift jump\nReturn game menu   Arrows Omnitrix / menu navigation   Mouse point   Hold M interact";
}
- (void)togglePause:(id)sender {
    (void)sender;
    self.manuallyPaused = !self.manuallyPaused;
    [self.gameView clearInput];
    [self.session setPaused:self.manuallyPaused];
    [self updateStatus:nil];
}
- (void)selectResolution:(NSMenuItem*)sender {
    if (self.session.edition != ProtectorGameEditionUpgraded) return;
    NSError* error = nil;
    if (![self.session.renderer selectRenderScale:(NSUInteger)sender.tag error:&error]) {
        self.status.stringValue = error.localizedDescription;
        return;
    }
    [self updateStatus:nil];
}
- (void)selectSmoothMotion:(NSMenuItem*)sender {
    (void)sender;
    NSError* error = nil;
    [self.gameView clearInput];
    if (![self.session.renderer selectSmoothMotion:!self.session.renderer.smoothMotionEnabled error:&error]) {
        self.status.stringValue = error.localizedDescription;
        return;
    }
    [self updateDisplayCadence];
    [self updateStatus:nil];
}
- (BOOL)validateMenuItem:(NSMenuItem*)item {
    if (item.action == @selector(togglePause:)) {
        item.title = self.manuallyPaused ? @"Resume" : @"Pause";
        return self.session && !self.session.finished;
    }
    if (item.action == @selector(selectResolution:)) {
        item.state = self.session.renderer.renderScale == (NSUInteger)item.tag
            ? NSControlStateValueOn : NSControlStateValueOff;
        return self.session.edition == ProtectorGameEditionUpgraded && !self.session.finished;
    }
    if (item.action == @selector(selectSmoothMotion:)) {
        item.state = self.session.renderer.smoothMotionEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        return self.session.renderer.smoothMotionAvailable && !self.session.finished;
    }
    return YES;
}
- (void)sessionDidFinish:(NSNotification*)notification {
    (void)notification;
    // Default-mode timers do not fire while AppKit waits for a delayed quit.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.terminating) {
            self.terminating = NO;
            [NSApp replyToApplicationShouldTerminate:YES];
        }
    });
}
- (void)drawInMTKView:(MTKView*)view {
    self.gameView.presentationAspect=(float)self.session.renderer.presentationAspect;
    self.gameView.qtePointer=self.session.renderer.qtePointerActive;
    [self updateQTEInstruction];
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable) return;
    NSError* error = nil;
    const NSInteger rate = view.preferredFramesPerSecond;
    const CFTimeInterval duration = rate > 0 ? 1.0 / rate : 0;
    if (![self.session.renderer presentLatestDrawable:drawable minimumDuration:duration error:&error]) {
        self.status.stringValue = error.localizedDescription;
        [self.session requestStop];
    }
}
- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
    (void)view; (void)size;
    [self.session.renderer resetMotionHistory];
}
- (void)updateDisplayCadence {
    const NSInteger maximum = self.window.screen.maximumFramesPerSecond;
    self.gameView.preferredFramesPerSecond = self.session.renderer.smoothMotionEnabled
        ? protector_motion_display_rate((int)maximum) : 60;
    [self.session.renderer resetMotionHistory];
}
- (void)windowDidChangeScreen:(NSNotification*)notification {
    (void)notification;
    [self updateDisplayCadence];
}
- (void)applicationDidResignActive:(NSNotification*)notification {
    (void)notification;
    [self.gameView clearInput];
    [self.session setPaused:YES];
    [self updateQTEInstruction];
}
- (void)applicationDidBecomeActive:(NSNotification*)notification {
    (void)notification;
    [self.session setPaused:self.manuallyPaused];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender; return YES;
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {
    (void)sender;
    if (!self.session || self.session.finished) return NSTerminateNow;
    self.terminating = YES;
    [self.gameView clearInput];
    [self.session requestStop];
    return NSTerminateLater;
}
@end

int main(int argc, const char* argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        ProtectorAppDelegate* delegate = [[ProtectorAppDelegate alloc] init];
        NSApp.delegate = delegate;
        NSMenu* menu = [[NSMenu alloc] init];
        NSMenuItem* application = [[NSMenuItem alloc] init];
        NSMenu* items = [[NSMenu alloc] init];
        [items addItemWithTitle:@"Quit Protector Native" action:@selector(terminate:)
            keyEquivalent:@"q"];
        application.submenu = items;
        [menu addItem:application];
        NSMenuItem* game = [[NSMenuItem alloc] init];
        NSMenu* gameItems = [[NSMenu alloc] initWithTitle:@"Game"];
        [gameItems addItemWithTitle:@"Pause" action:@selector(togglePause:) keyEquivalent:@"p"].target = delegate;
        [gameItems addItem:NSMenuItem.separatorItem];
        NSMenuItem* resolution = [[NSMenuItem alloc] initWithTitle:@"Render resolution"
            action:nil keyEquivalent:@""];
        NSMenu* resolutions = [[NSMenu alloc] initWithTitle:@"Render resolution"];
        NSUInteger shortcut = 3;
        for (NSUInteger scale : {1u, 2u, 3u, 6u}) {
            NSString* title = [NSString stringWithFormat:@"%lu× — %lu px wide",
                (unsigned long)scale, (unsigned long)(640u * scale)];
            NSMenuItem* item = [resolutions addItemWithTitle:title
                action:@selector(selectResolution:)
                keyEquivalent:[NSString stringWithFormat:@"%lu", (unsigned long)shortcut++]];
            item.target = delegate;
            item.tag = (NSInteger)scale;
        }
        resolution.submenu = resolutions;
        [gameItems addItem:resolution];
        NSMenuItem* motion = [gameItems addItemWithTitle:@"Smooth motion"
            action:@selector(selectSmoothMotion:) keyEquivalent:@""];
        motion.target = delegate;
        motion.toolTip = @"Adds in-between frames where safe, with about 33 ms of display delay. Turn off for lower input delay.";
        game.submenu = gameItems;
        [menu addItem:game];
        NSApp.mainMenu = menu;
        [NSApp run];
    }
    return 0;
}
