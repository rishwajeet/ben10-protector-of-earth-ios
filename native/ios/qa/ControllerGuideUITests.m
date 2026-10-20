#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// Actual translated Options -> Controller route in an isolated application.
// The optional framework snapshot drives normal GameController input; it does
// not replace a source context, skip a script, or write game configuration.
@interface ProtectorControllerGuideUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* diagnostics;
@property(nonatomic) NSString* commandPath;
@end

@implementation ProtectorControllerGuideUITests
- (NSDictionary*)json:(NSString*)path {
    NSData* data = [NSData dataWithContentsOfFile:path];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
- (NSDictionary*)state:(NSString*)file {
    return [self json:[self.diagnostics stringByAppendingPathComponent:file]];
}
- (void)settle:(NSTimeInterval)seconds {
    XCTestExpectation* expectation = [self expectationWithDescription:@"native transition"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),
        dispatch_get_main_queue(),^{[expectation fulfill];});
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:seconds+3],XCTWaiterResultCompleted);
}
- (void)capture:(NSString*)name {
    XCTAttachment* screenshot = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    screenshot.name = name; screenshot.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:screenshot];
    XCTAttachment* hierarchy = [XCTAttachment attachmentWithString:self.game.debugDescription];
    hierarchy.name = [name stringByAppendingString:@"-accessibility"];
    hierarchy.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:hierarchy];
    NSDictionary* value = @{@"render":[self state:@"interactive-state.json"],@"controls":[self state:@"native-controls.json"]};
    XCTAttachment* receipt = [XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:value
        options:NSJSONWritingPrettyPrinted error:nil] uniformTypeIdentifier:@"public.json"];
    receipt.name = [name stringByAppendingString:@"-readback"];
    receipt.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:receipt];
}
- (void)controller:(NSString*)command {
    NSString* identifier = NSUUID.UUID.UUIDString;
    NSData* message = [NSJSONSerialization dataWithJSONObject:@{@"id":identifier,@"command":command} options:0 error:nil];
    XCTAssertTrue([message writeToFile:self.commandPath options:NSDataWritingAtomic error:nil]);
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while ([deadline timeIntervalSinceNow]>0) {
        if ([[self json:[self.commandPath stringByAppendingString:@".receipt.json"]][@"command_id"] isEqual:identifier]) {
            [self settle:.12]; return;
        }
        [NSThread sleepForTimeInterval:.05];
    }
    XCTFail(@"Framework snapshot command not received: %@",command);
}
- (void)pulse:(NSString*)command {
    [self controller:command]; [self controller:@"neutral"]; [self settle:.5];
}
- (void)waitForContext:(NSString*)context paused:(BOOL)paused {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while ([deadline timeIntervalSinceNow]>0) {
        NSDictionary* controls = [self state:@"native-controls.json"];
        NSDictionary* render = [self state:@"interactive-state.json"];
        if ([controls[@"control_context"] isEqual:context] &&
            [controls[@"manually_paused"] boolValue] == paused &&
            [render[@"host_paused"] boolValue] == paused) return;
        [NSThread sleepForTimeInterval:.1];
    }
    XCTFail(@"Expected %@ paused %d, observed %@",context,paused,[self state:@"native-controls.json"]);
}
- (void)testSourceControllerGuideEntryAndReturn {
    self.continueAfterFailure = NO; self.executionTimeAllowance = 240;
    NSDictionary* environment = NSProcessInfo.processInfo.environment;
    NSString* container = environment[@"PROTECTOR_GUIDE_QA_CONTAINER"];
    NSString* bundle = environment[@"PROTECTOR_GUIDE_QA_BUNDLE"];
    BOOL controller = [environment[@"PROTECTOR_GUIDE_QA_CONTROLLER"] isEqual:@"1"];
    BOOL large = [environment[@"PROTECTOR_GUIDE_QA_LARGE"] isEqual:@"1"];
    XCTSkipIf(!container.length,@"Select the isolated ControllerGuideQA bundle and container");
    NSString* identity = @"house.machine.ProtectorNative.ControllerGuideQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:
        @"Info.plist"]][@"CFBundleIdentifier"],identity);
    NSData* startup = [NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(startup.bytes,(CC_LONG)startup.length,digest);
    NSMutableString* hash = [NSMutableString string];
    for (NSUInteger i=0;i<sizeof(digest);++i) [hash appendFormat:@"%02x",digest[i]];
    XCTAssertEqualObjects(hash,@"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    NSString* save = [container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSData* saveBefore = [NSData dataWithContentsOfFile:save]; XCTAssertNotNil(saveBefore);
    self.diagnostics = [container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:self.diagnostics]);
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    self.game = [[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.game.launchArguments = @[@"-touch.hideWithController.v1",@"NO"];
    if (controller) {
        self.commandPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"source-guide-%@.json",NSUUID.UUID.UUIDString]];
        self.game.launchEnvironment = @{@"PROTECTOR_CONTROLLER_QA":@"1",
            @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1"};
    }
    [self.game launch];
    XCUIElement* view = self.game.otherElements[@"translated-game-view"];
    XCTestExpectation* title = [[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithFormat:@"label == 'Game title. Use Confirm to begin.'"] object:view];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[title] timeout:100],XCTWaiterResultCompleted);
    if (controller) { [self controller:@"neutral"]; [self pulse:@"a"]; }
    else [self.game.buttons[@"game-action-2048"] tap];
    [self settle:2];
    for (NSUInteger i=0;i<2;++i) {
        if (controller) [self pulse:@"down"]; else [self.game.buttons[@"game-action-4"] tap];
    }
    if (controller) [self pulse:@"a"]; else [self.game.buttons[@"game-action-2048"] tap];
    [self settle:2];
    [self waitForContext:@"menu" paused:NO];
    [self capture:@"guide-source-options-before"];
    if (controller) { [self pulse:@"down"]; [self pulse:@"a"]; }
    else { [self.game.buttons[@"game-action-4"] tap]; [self.game.buttons[@"game-action-2048"] tap]; }
    XCUIElement* guide = self.game.tables[@"native-controls-guide"];
    XCTAssertTrue([guide waitForExistenceWithTimeout:12]);
    XCTAssertTrue(self.game.buttons[@"native-guide-done"].hittable);
    XCTAssertFalse(self.game.buttons[@"Resume"].exists);
    [self waitForContext:@"controls-guide" paused:YES];
    NSDictionary* paused = [self state:@"interactive-state.json"];
    XCTAssertEqualObjects(paused[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(paused[@"runtime_error"],NSNull.null);
    XCTAssertTrue([[self state:@"native-controls.json"][@"source_controls_guide_visible"] boolValue]);
    // A real host controller may be visible in the simulator. The initial
    // production mode follows that connection; explicitly choose Touch for
    // this touch-reading scenario and assert the actual row wording.
    if (!controller) [guide.buttons[@"Touch"] tap];
    XCTAssertEqualObjects(guide.cells[@"controls-guide-0-0"].label,controller ?
        @"Move. Use the left stick." : @"Move. Drag the movement stick. Lift your thumb to stop.");
    [self capture:controller ? @"guide-controller" : @"guide-touch"];
    if (controller) [self pulse:@"left"];
    else [guide.buttons[@"Controller"] tap];
    [self settle:.5];
    XCTAssertEqualObjects(guide.cells[@"controls-guide-0-0"].label,controller ?
        @"Move. Drag the movement stick. Lift your thumb to stop." : @"Move. Use the left stick.");
    [self capture:controller ? @"guide-touch-alternate" : @"guide-controller-alternate"];
    if (large) {
        // Read the following portion at large Dynamic Type with an ordinary
        // scroll. This is capture coverage, not a full nonvisual-gameplay claim.
        [guide swipeUp]; [self settle:.5]; [self capture:@"guide-large-scrolled"];
    }
    [self settle:5.2];
    NSDictionary* stillPaused = [self state:@"interactive-state.json"];
    XCTAssertEqualObjects(stillPaused[@"timing"][@"guest_timebase"],paused[@"timing"][@"guest_timebase"]);
    XCTAssertEqualObjects(stillPaused[@"frame_index"],paused[@"frame_index"]);
    if (controller) [self pulse:@"b"]; else [self.game.buttons[@"native-guide-done"] tap];
    XCTestExpectation* closed = [[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithFormat:@"exists == NO"] object:guide];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[closed] timeout:10],XCTWaiterResultCompleted);
    [self waitForContext:@"menu" paused:NO];
    [self settle:5.2];
    NSDictionary* returned = [self state:@"interactive-state.json"];
    XCTAssertEqualObjects(returned[@"native_frontend_layout"][@"admission"],@"source-dna-secondary-panel");
    XCTAssertFalse([[self state:@"native-controls.json"][@"source_controls_guide_visible"] boolValue]);
    NSDictionary* guideReturn = [self state:@"native-controls.json"];
    XCTAssertGreaterThanOrEqual([guideReturn[@"source_guide_continue_sample"] unsignedLongLongValue],
        [guideReturn[@"source_guide_neutral_start"] unsignedLongLongValue] + 2);
    XCTAssertEqualObjects(returned[@"input_lifecycle"][@"input_samples"][@"last_hold"],@0);
    [self capture:@"guide-returned-options"];
    if (controller) {
        // Options retains its Controller selection. Reopen and qualify Menu
        // as the second source-safe return path, with neutral gating intact.
        [self pulse:@"a"]; XCTAssertTrue([guide waitForExistenceWithTimeout:12]);
        [self waitForContext:@"controls-guide" paused:YES];
        [self pulse:@"menu"];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:
            [NSPredicate predicateWithFormat:@"exists == NO"] object:guide]] timeout:10],XCTWaiterResultCompleted);
        [self waitForContext:@"menu" paused:NO];
        [self capture:@"guide-menu-returned-options"];
    }
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:save],saveBefore);
}
- (void)tearDown { [self.game terminate]; [super tearDown]; }
@end
