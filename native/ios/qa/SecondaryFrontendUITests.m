#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// Source inspection only. The original executable owns every menu transition;
// no save slot is chosen, audio value edited, or menu state injected.
@interface ProtectorSecondaryFrontendUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@end

@implementation ProtectorSecondaryFrontendUITests
- (void)settle {
    XCTestExpectation* transition = [self expectationWithDescription:@"source menu transition"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{[transition fulfill];});
    XCTAssertEqual([XCTWaiter waitForExpectations:@[transition] timeout:5],XCTWaiterResultCompleted);
}
- (NSDictionary*)json:(NSString*)path {
    NSData* data = [NSData dataWithContentsOfFile:path];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}
- (void)testSourceSecondaryMenu {
    [self checkSecondaryMenuRestored:NO];
}
- (void)testRestoredSecondaryMenu {
    [self checkSecondaryMenuRestored:YES];
}
- (void)capture:(NSString*)name {
    XCTAttachment* image = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    image.name = name; image.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:image];
}
- (void)checkSecondaryMenuRestored:(BOOL)restored {
    self.continueAfterFailure = NO; self.executionTimeAllowance = 180;
    NSDictionary* environment = NSProcessInfo.processInfo.environment;
    NSString* container = environment[@"PROTECTOR_SECONDARY_QA_CONTAINER"];
    NSString* bundle = environment[@"PROTECTOR_SECONDARY_QA_BUNDLE"];
    NSString* route = environment[@"PROTECTOR_SECONDARY_QA_ROUTE"];
    XCTSkipIf(!container.length,@"Select the isolated SecondarySourceQA container and bundle");
    XCTAssertTrue(bundle.length > 0);
    NSArray* routes = @[@"difficulty",@"continue",@"options",@"audio",@"controller"];
    XCTAssertTrue([routes containsObject:route]);
    NSString* identifier = restored ? @"house.machine.ProtectorNative.SecondaryRestoredQA" :
        @"house.machine.ProtectorNative.SecondarySourceQA";
    NSDictionary* expected = restored ? [self json:environment[@"PROTECTOR_SECONDARY_ART_EXPECTATIONS"]] : @{};
    if (restored) {
        XCTAssertEqualObjects(expected[@"schema"],@"protector-native.secondary-art-expectations/v1");
        XCTAssertNotNil(expected[@"routes"][route]);
    }
    NSDictionary* metadata = [NSDictionary dictionaryWithContentsOfFile:[container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    XCTAssertEqualObjects(metadata[@"MCMMetadataIdentifier"],identifier);
    NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
    XCTAssertEqualObjects(info[@"CFBundleIdentifier"],identifier);
    NSData* startup = [NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]];
    XCTAssertEqual(startup.length,2622u);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(startup.bytes,(CC_LONG)startup.length,digest);
    NSMutableString* hash = [NSMutableString string];
    for (NSUInteger i=0;i<sizeof(digest);++i) [hash appendFormat:@"%02x",digest[i]];
    XCTAssertEqualObjects(hash,@"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    NSString* diagnostics = [container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics],@"Preserve previous source diagnostics before each route");
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    self.game = [[XCUIApplication alloc] initWithBundleIdentifier:identifier];
    self.game.launchArguments = @[@"-touch.hideWithController.v1",@"NO"];
    // Smooth-motion startup keeps this existing one-shot source audit dormant.
    // It is enabled only after ordinary input reaches the selected menu.
    self.game.launchEnvironment = @{@"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1"};
    [self.game launch];
    XCUIElement* view = self.game.otherElements[@"translated-game-view"];
    XCTestExpectation* title = [[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithFormat:@"label == 'Game title. Use Confirm to begin.'"] object:view];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[title] timeout:100],XCTWaiterResultCompleted);
    XCUIElement* confirm = self.game.buttons[@"game-action-2048"];
    [confirm tap]; [self settle];
    if ([route isEqual:@"difficulty"]) { [confirm tap]; [self settle]; }
    else if ([route isEqual:@"continue"]) {
        [self.game.buttons[@"game-action-4"] tap]; [confirm tap]; [self settle];
    } else {
        [self.game.buttons[@"game-action-4"] tap];
        [self.game.buttons[@"game-action-4"] tap];
        [confirm tap]; [self settle];
        if ([route isEqual:@"controller"]) { [self.game.buttons[@"game-action-4"] tap]; }
        if (![route isEqual:@"options"]) { [confirm tap]; [self settle]; }
    }
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[diagnostics stringByAppendingPathComponent:@"interface-source"]]);
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    XCUIElement* motion = self.game.switches[@"render.motion"];
    // Use the table's native scrolling gesture. Long-press pans can be claimed
    // by its sliders; fixed-count swipes can overshoot. Check after each swipe.
    for (NSUInteger i=0; i<12 && !motion.hittable; ++i) [settings swipeUp];
    XCTAssertTrue(motion.hittable); XCTAssertEqualObjects(motion.value,@"1");
    [motion tap]; XCTAssertEqualObjects(motion.value,@"0");
    [self.game.buttons[@"Resume"] tap];
    NSString* auditPath = [diagnostics stringByAppendingPathComponent:@"interface-source/audit.json"];
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (![NSFileManager.defaultManager fileExistsAtPath:auditPath] && [deadline timeIntervalSinceNow]>0)
        [NSThread sleepForTimeInterval:0.1];
    NSDictionary* audit = [self json:auditPath];
    XCTAssertEqualObjects(audit[@"schema"],@"protector-native.interface-source-audit/v1");
    XCTAssertTrue([audit[@"draws"] count]>0);
    XCTAssertEqualObjects(audit[@"source"],@"translated_execution_callback");
    [self settle];
    XCTAttachment* image = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    image.name = [(restored ? @"secondary-restored-" : @"secondary-source-") stringByAppendingString:route];
    image.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:image];
    NSDictionary* state = [self json:[diagnostics stringByAppendingPathComponent:@"interactive-state.json"]];
    XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
    if (restored) {
        XCTAssertEqualObjects(state[@"native_frontend_layout"][@"admission"],@"source-dna-secondary-panel");
        XCTAssertTrue([state[@"native_frontend_layout"][@"enabled"] boolValue]);
        XCTAssertTrue([state[@"native_frontend_layout"][@"secondary"] boolValue]);
        XCTAssertEqualObjects(state[@"texture_pack_id"],expected[@"pack_id"]);
        XCTAssertEqualObjects(state[@"texture_pack_manifest_sha256"],expected[@"pack_sha256"]);
        XCTAssertTrue([state[@"restored_artwork_enabled"] boolValue]);
        NSSet* observed = [NSSet setWithArray:state[@"texture_pack_frame_sources"]];
        NSSet* sources = [NSSet setWithArray:expected[@"routes"][route]];
        XCTAssertGreaterThan(sources.count,20u); XCTAssertEqualObjects(observed,sources);
        XCTAssertLessThanOrEqual([state[@"texture_pack_frame_bytes"] unsignedLongLongValue],
            [state[@"texture_pack_allocation_budget_bytes"] unsignedLongLongValue]);
        XCTAssertLessThanOrEqual([state[@"texture_pack_cache_bytes"] unsignedLongLongValue],
            [state[@"texture_pack_allocation_budget_bytes"] unsignedLongLongValue]);
        XCTAssertLessThanOrEqual([state[@"texture_pack_frame_encoded_bytes"] unsignedLongLongValue],
            [state[@"texture_pack_encoded_budget_bytes"] unsignedLongLongValue]);
        XCTAssertLessThanOrEqual([state[@"texture_pack_cache_encoded_bytes"] unsignedLongLongValue],
            [state[@"texture_pack_encoded_budget_bytes"] unsignedLongLongValue]);
    }
    XCTAttachment* data = [XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:state
        options:NSJSONWritingPrettyPrinted error:nil] uniformTypeIdentifier:@"public.json"];
    data.name = [(restored ? @"secondary-restored-state-" : @"secondary-source-state-") stringByAppendingString:route];
    data.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:data];
    if (restored) {
        // Selection input only: no new-game/slot confirmation or Audio change.
        [self.game.buttons[@"game-action-4"] tap]; [self settle];
        [self capture:[@"secondary-restored-selection-" stringByAppendingString:route]];
        [self.game.buttons[@"game-action-8"] tap];
        [self.game.buttons[@"game-back"] tap]; [self settle];
        // Production writes diagnostics every five seconds. A two-second UI
        // settle can show the correct parent while retaining the child JSON.
        // Require a snapshot newer than this settled screen before asserting.
        NSString* statePath = [diagnostics stringByAppendingPathComponent:@"interactive-state.json"];
        NSDate* settled = [NSDate date];
        NSDate* freshDeadline = [NSDate dateWithTimeIntervalSinceNow:12];
        BOOL fresh = NO;
        while ([freshDeadline timeIntervalSinceNow] > 0) {
            NSDate* modified = [NSFileManager.defaultManager attributesOfItemAtPath:statePath error:nil][NSFileModificationDate];
            if (modified && [modified compare:settled] == NSOrderedDescending) { fresh = YES; break; }
            [NSThread sleepForTimeInterval:0.1];
        }
        XCTAssertTrue(fresh,@"Wait for a new production diagnostic after Back");
        NSDictionary* returned = [self json:statePath];
        NSString* parent = [route isEqual:@"audio"] ? @"source-dna-secondary-panel" : @"source-dna-watch-menu";
        XCTAssertEqualObjects(returned[@"native_frontend_layout"][@"admission"],parent);
        XCTAssertEqualObjects(returned[@"audio_output"],@"disabled");
        XCTAssertEqualObjects(returned[@"runtime_error"],NSNull.null);
        [self capture:[@"secondary-restored-return-" stringByAppendingString:route]];
    }
}
- (void)tearDown { [self.game terminate]; [super tearDown]; }
@end
