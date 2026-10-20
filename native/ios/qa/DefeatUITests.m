#import <XCTest/XCTest.h>

// Source-owned defeat and retry, reached by ordinary idle damage. No guest
// health/state writes, no campaign replay, and no hardware-controller claim.
@interface ProtectorDefeatUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* diagnostics;
@property(nonatomic) NSString* commandPath;
@end

@implementation ProtectorDefeatUITests
- (NSDictionary*)json:(NSString*)path {
    NSData* data=[NSData dataWithContentsOfFile:path];
    id value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
- (void)waitForLabel:(NSString*)label timeout:(NSTimeInterval)timeout {
    XCTestExpectation* expected=[[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithFormat:@"label == %@",label]
        object:self.game.otherElements[@"translated-game-view"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expected] timeout:timeout],XCTWaiterResultCompleted);
}
- (NSDictionary*)fresh:(NSString*)file {
    NSString* path=[self.diagnostics stringByAppendingPathComponent:file];
    NSDate* after=NSDate.date;
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:12];
    while([deadline timeIntervalSinceNow]>0) {
        NSDate* modified=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if(modified && [modified compare:after]==NSOrderedDescending) return [self json:path];
        [NSThread sleepForTimeInterval:.1];
    }
    XCTFail(@"No fresh readback for %@",file); return @{};
}
- (void)capture:(NSString*)name {
    NSDictionary* controls=[self fresh:@"native-controls.json"];
    NSDictionary* render=[self json:[self.diagnostics stringByAppendingPathComponent:@"interactive-state.json"]];
    XCTAssertEqualObjects(render[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(render[@"runtime_error"],NSNull.null);
    XCTAssertEqual([render[@"texture_pack_entries"] unsignedIntegerValue],727u);
    XCTAttachment* image=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    image.name=name; image.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:image];
    XCTAttachment* hierarchy=[XCTAttachment attachmentWithString:self.game.debugDescription];
    hierarchy.name=[name stringByAppendingString:@"-accessibility"];
    hierarchy.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:hierarchy];
    XCTAttachment* state=[XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:
        @{@"controls":controls,@"render":render} options:NSJSONWritingPrettyPrinted error:nil]
        uniformTypeIdentifier:@"public.json"];
    state.name=[name stringByAppendingString:@"-readback"];
    state.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:state];
}
- (void)assertDefeatControlsHidden:(BOOL)hidden {
    XCTAssertEqualObjects(self.game.otherElements[@"translated-game-view"].label,@"Defeated. Use Confirm to continue.");
    XCTAssertTrue(self.game.buttons[@"native-pause"].hittable);
    XCTAssertEqual(self.game.buttons[@"game-action-2048"].exists,!hidden);
    XCTAssertFalse(self.game.otherElements[@"game-move"].exists);
    for(NSString* identifier in @[@"game-action-1",@"game-action-4",@"game-action-2",@"game-action-8",
        @"game-action-1024",@"game-action-4096",@"game-action-8192",@"game-action-16384",
        @"game-action-32768",@"game-action-32",@"game-action-16",@"game-action-512",
        @"game-back",@"game-motion-interaction"])
        XCTAssertFalse(self.game.buttons[identifier].exists,@"Unexpected action: %@",identifier);
    NSDictionary* controls=[self fresh:@"native-controls.json"];
    XCTAssertEqualObjects(controls[@"control_context"],@"defeat-ready");
    for(NSDictionary* action in controls[@"controls"])
        XCTAssertEqual([action[@"hidden"] boolValue],hidden || ![action[@"id"] isEqual:@"game-action-2048"]);
    XCTAssertEqual([controls[@"controller_continue_cue_visible"] boolValue],hidden);
    XCTAssertEqual([controls[@"touch_held"] unsignedIntegerValue],0u);
}
- (void)controller:(NSString*)command {
    NSString* identifier=NSUUID.UUID.UUIDString;
    NSData* data=[NSJSONSerialization dataWithJSONObject:@{@"id":identifier,@"command":command} options:0 error:nil];
    XCTAssertTrue([data writeToFile:self.commandPath options:NSDataWritingAtomic error:nil]);
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while([deadline timeIntervalSinceNow]>0) {
        if([[self json:[self.commandPath stringByAppendingString:@".receipt.json"]][@"command_id"] isEqual:identifier]) {
            [NSThread sleepForTimeInterval:.2]; return;
        }
        [NSThread sleepForTimeInterval:.05];
    }
    XCTFail(@"Controller snapshot command not received");
}
- (void)testDefeatAndSourceRetry {
    self.continueAfterFailure=NO; self.executionTimeAllowance=220;
    NSDictionary* environment=NSProcessInfo.processInfo.environment;
    NSString* container=environment[@"PROTECTOR_DEFEAT_QA_CONTAINER"];
    XCTSkipIf(!container.length,@"Select the isolated DefeatQA container");
    NSString* identity=@"house.machine.ProtectorNative.DefeatQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    self.diagnostics=[container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:self.diagnostics]);
    BOOL controller=[environment[@"PROTECTOR_DEFEAT_QA_CONTROLLER"] isEqual:@"1"];
    BOOL large=[environment[@"PROTECTOR_DEFEAT_QA_LARGE"] isEqual:@"1"];
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.game.launchArguments=controller ? @[@"-touch.hideWithController.v1",@"YES",@"-touch.scale.v1",@"1",
        @"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"] : large ? @[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1.25",
        @"-touch.swapped.v1",@"YES",@"-touch.labels.v1",@"NO"] :
        @[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",@"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    NSString* trace=[container stringByAppendingPathComponent:@"Documents/defeat-ui-text.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    NSMutableDictionary* launch=[@{@"PROTECTOR_UI_TEXT_LOG":trace} mutableCopy];
    if(controller) {
        self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"defeat-%@.json",NSUUID.UUID.UUIDString]];
        launch[@"PROTECTOR_CONTROLLER_QA"]=@"1";
        launch[@"PROTECTOR_CONTROLLER_QA_PATH"]=self.commandPath;
        launch[@"PROTECTOR_CONTROLLER_QA_READBACK"]=@"1";
    }
    self.game.launchEnvironment=launch;
    [self.game launch];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:60];
    if(controller) { [self controller:@"neutral"]; [self controller:@"a"]; [self controller:@"neutral"]; }
    else [self.game.buttons[@"game-action-2048"] tap];
    NSString* playing=@"Game. Touch or drag to point. Attack confirms game menus.";
    [self waitForLabel:playing timeout:20];
    [self waitForLabel:@"Defeated. Use Confirm to continue." timeout:80];
    [self assertDefeatControlsHidden:controller];
    [self capture:controller ? @"defeat-controller-cue" : @"defeat-touch-confirm"];
    // Native Pause/Resume must preserve the source prompt, without using its
    // Continue action. The controller scenario also checks the hidden-touch cue.
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:6]);
    [self capture:@"defeat-native-paused"];
    [self.game.buttons[@"Resume"] tap];
    [self assertDefeatControlsHidden:controller];
    [self capture:controller ? @"defeat-controller-resumed" : @"defeat-resumed"];
    if(controller) { [self controller:@"a"]; [self controller:@"neutral"]; }
    else [self.game.buttons[@"game-action-2048"] tap];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:60];
    NSDate* playingSince=nil;
    NSMutableArray* transitions=[NSMutableArray array]; NSString* previous=nil; BOOL recovered=NO;
    while([deadline timeIntervalSinceNow]>0) {
        NSString* label=self.game.otherElements[@"translated-game-view"].label;
        if(![label isEqual:previous]) { [transitions addObject:label ?: @""]; previous=label; }
        if([label isEqual:@"Game ready. Use Confirm to continue."]) {
            if(controller) { [self controller:@"a"]; [self controller:@"neutral"]; }
            else [self.game.buttons[@"game-action-2048"] tap];
        }
        if([label isEqual:playing]) {
            if(!playingSince) playingSince=NSDate.date;
            if(-playingSince.timeIntervalSinceNow>=2) { recovered=YES; break; }
        } else playingSince=nil;
        [NSThread sleepForTimeInterval:.1];
    }
    XCTAttachment* sequence=[XCTAttachment attachmentWithString:[transitions componentsJoinedByString:@"\n"]];
    sequence.name=@"source-retry-label-transitions"; sequence.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:sequence];
    XCTAssertTrue(recovered,@"Source Continue must return to the live scene");
    XCTAssertFalse(self.game.staticTexts[@"controller-continue-cue"].exists);
    [self capture:@"defeat-recovered-gameplay"];
    XCTAssertEqualObjects(self.game.otherElements[@"translated-game-view"].label,playing);
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
}
- (void)tearDown { [self.game terminate]; [super tearDown]; }
@end
