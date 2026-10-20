#import "controller_snapshot_qa.h"
#import <TargetConditionals.h>
#include <math.h>

@interface ProtectorControllerSnapshotQA ()
@property(nonatomic, readwrite) NSUInteger commandCount;
@property(nonatomic, readwrite) NSString* lastCommand;
#if TARGET_OS_SIMULATOR
@property(nonatomic) GCController* controller;
@property(nonatomic, copy) void (^connectionChanged)(GCController*);
@property(nonatomic) NSTimer* inputTimer;
@property(nonatomic) NSString* commandPath;
@property(nonatomic) NSString* commandID;
@property(nonatomic) BOOL readbackEnabled;
@property(nonatomic) NSTimeInterval lastReadbackTime;
- (void)receive:(NSString*)name;
#endif
@end

@implementation ProtectorControllerSnapshotQA
+ (instancetype)startIfRequested:(void (^)(GCController*))connectionChanged {
#if TARGET_OS_SIMULATOR
    NSString* identity = NSBundle.mainBundle.bundleIdentifier;
    if ((! [identity isEqual:@"house.machine.ProtectorNative.V1ControlsQA"] &&
         ! [identity isEqual:@"house.machine.ProtectorNative.ControllerGuideQA"] &&
         ! [identity isEqual:@"house.machine.ProtectorNative.DefeatQA"] &&
         ! [identity isEqual:@"house.machine.ProtectorNative.GallerySourceQA"] &&
         ! [identity isEqual:@"house.machine.ProtectorNative.MaterialArtworkQA"] &&
         ! [identity isEqual:@"house.machine.ProtectorNative.StartupQA"] &&
         ! [identity isEqual:@"house.machine.ProtectorNative.FourArmsGrabQA"] &&
         ! [identity isEqual:@"house.machine.ProtectorNative.SaveWriteFailureQA"] &&
         ! [identity isEqual:@"house.machine.ProtectorNative.ExtrasUnlockedQA"] &&
         ! [identity isEqual:@"house.machine.ProtectorNative.ExtrasViewersQA"]) ||
        ![NSProcessInfo.processInfo.environment[@"PROTECTOR_CONTROLLER_QA"] isEqual:@"1"]) return nil;
    ProtectorControllerSnapshotQA* driver = [[self alloc] init];
    driver.controller = [GCController controllerWithExtendedGamepad];
    driver.connectionChanged = connectionChanged;
    driver.commandPath = NSProcessInfo.processInfo.environment[@"PROTECTOR_CONTROLLER_QA_PATH"];
    if (!driver.commandPath.isAbsolutePath) return nil;
    driver.readbackEnabled = [NSProcessInfo.processInfo.environment[@"PROTECTOR_CONTROLLER_QA_READBACK"] isEqual:@"1"];
    driver.lastCommand = @"none";
    __weak ProtectorControllerSnapshotQA* weakDriver = driver;
    driver.inputTimer = [NSTimer timerWithTimeInterval:.016 repeats:YES block:^(NSTimer* timer) {
        (void)timer;
        ProtectorControllerSnapshotQA* receiver = weakDriver;
        NSData* data = [NSData dataWithContentsOfFile:receiver.commandPath];
        NSDictionary* message = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([message isKindOfClass:NSDictionary.class] && [message[@"id"] isKindOfClass:NSString.class] &&
            [message[@"command"] isKindOfClass:NSString.class] && ![message[@"id"] isEqual:receiver.commandID]) {
            receiver.commandID = message[@"id"];
            [receiver receive:message[@"command"]];
        }
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (receiver.readbackEnabled && receiver.stateReader && now - receiver.lastReadbackTime >= .1) {
            receiver.lastReadbackTime = now;
            NSMutableDictionary* receipt = [receiver.stateReader() mutableCopy];
            receipt[@"command"] = receiver.lastCommand;
            receipt[@"command_id"] = receiver.commandID ? receiver.commandID : @"";
            receipt[@"observed_uptime"] = @(now);
            NSData* json = [NSJSONSerialization dataWithJSONObject:receipt options:0 error:nil];
            [json writeToFile:[receiver.commandPath stringByAppendingString:@".receipt.json"]
                options:NSDataWritingAtomic error:nil];
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:driver.inputTimer forMode:NSRunLoopCommonModes];
    connectionChanged(driver.controller);
    return driver;
#else
    (void)connectionChanged;
    return nil;
#endif
}
#if TARGET_OS_SIMULATOR
- (void)dealloc {
    [self.inputTimer invalidate];
}
- (void)receive:(NSString*)command {
    self.lastCommand = command;
    self.commandCount += 1;
    if ([command isEqual:@"disconnect"]) { self.connectionChanged(nil); return; }
    if ([command isEqual:@"connect"]) { self.connectionChanged(self.controller); return; }
    if ([command isEqual:@"capture"]) { if (self.captureHandler) self.captureHandler(); return; }
    GCExtendedGamepad* pad = self.controller.extendedGamepad;
    [pad.dpad setValueForXAxis:0 yAxis:0];
    [pad.leftThumbstick setValueForXAxis:0 yAxis:0];
    [pad.rightThumbstick setValueForXAxis:0 yAxis:0];
    [pad.buttonA setValue:0]; [pad.buttonB setValue:0]; [pad.buttonMenu setValue:0];
    [pad.buttonX setValue:0]; [pad.buttonY setValue:0]; [pad.buttonOptions setValue:0];
    [pad.leftShoulder setValue:0]; [pad.rightShoulder setValue:0];
    [pad.leftTrigger setValue:0]; [pad.rightTrigger setValue:0];
    [pad.rightThumbstickButton setValue:0];
    for (NSString* token in [command componentsSeparatedByString:@"+"]) {
        if ([token isEqual:@"up"]) [pad.dpad setValueForXAxis:0 yAxis:1];
        if ([token isEqual:@"down"]) [pad.dpad setValueForXAxis:0 yAxis:-1];
        if ([token isEqual:@"left"]) [pad.dpad setValueForXAxis:-1 yAxis:0];
        if ([token isEqual:@"right"]) [pad.dpad setValueForXAxis:1 yAxis:0];
        if ([token isEqual:@"stickup"]) [pad.leftThumbstick setValueForXAxis:0 yAxis:1];
        if ([token isEqual:@"stickdown"]) [pad.leftThumbstick setValueForXAxis:0 yAxis:-1];
        if ([token isEqual:@"stickleft"]) [pad.leftThumbstick setValueForXAxis:-1 yAxis:0];
        if ([token isEqual:@"stickright"]) [pad.leftThumbstick setValueForXAxis:1 yAxis:0];
        if ([token isEqual:@"aimright"]) [pad.rightThumbstick setValueForXAxis:.75 yAxis:.5];
        // QA-only analog delivery through GameController, not a guest pointer
        // write. Enables source-positioned targets with the production mapper.
        if ([token hasPrefix:@"aim="]) {
            NSArray<NSString*>* axes=[[token substringFromIndex:4] componentsSeparatedByString:@","];
            if(axes.count==2) {
                NSScanner* sx=[NSScanner scannerWithString:axes[0]];
                NSScanner* sy=[NSScanner scannerWithString:axes[1]];
                float x=0,y=0;
                if([sx scanFloat:&x] && sx.isAtEnd && [sy scanFloat:&y] && sy.isAtEnd &&
                    isfinite(x) && isfinite(y) && fabsf(x)<=1 && fabsf(y)<=1)
                    [pad.rightThumbstick setValueForXAxis:x yAxis:y];
            }
        }
        if ([token isEqual:@"a"]) [pad.buttonA setValue:1];
        if ([token isEqual:@"b"]) [pad.buttonB setValue:1];
        if ([token isEqual:@"x"]) [pad.buttonX setValue:1];
        if ([token isEqual:@"y"]) [pad.buttonY setValue:1];
        if ([token isEqual:@"options"]) [pad.buttonOptions setValue:1];
        if ([token isEqual:@"lshoulder"]) [pad.leftShoulder setValue:1];
        if ([token isEqual:@"rshoulder"]) [pad.rightShoulder setValue:1];
        if ([token isEqual:@"rstickpress"]) [pad.rightThumbstickButton setValue:1];
        if ([token isEqual:@"ltrigger"] || [token isEqual:@"triggers"]) [pad.leftTrigger setValue:1];
        if ([token isEqual:@"rtrigger"] || [token isEqual:@"triggers"]) [pad.rightTrigger setValue:1];
        if ([token isEqual:@"menu"]) [pad.buttonMenu setValue:1];
    }
}
#endif
@end
