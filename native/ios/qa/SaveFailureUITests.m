#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// Real runtime startup against deliberately invalid storage in a separately
// installed app. No guest hook, failure injection, or production-save access.
@interface ProtectorSaveFailureUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* container;
@end

@implementation ProtectorSaveFailureUITests
- (NSDictionary*)state {
    NSData* data = [NSData dataWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @"Documents/Diagnostics/interactive-state.json"]];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : @{};
}
- (NSString*)hash:(NSString*)relative {
    NSData* bytes = [NSData dataWithContentsOfFile:[self.container stringByAppendingPathComponent:relative]];
    XCTAssertNotNil(bytes);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString* value = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); ++i) [value appendFormat:@"%02x", digest[i]];
    return value;
}
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    self.executionTimeAllowance = 120;
    self.container = NSProcessInfo.processInfo.environment[@"PROTECTOR_SAVE_FAILURE_QA_CONTAINER"];
    XCTSkipIf(!self.container.length, @"Requires an isolated SaveFailureQA container");
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],
        @"house.machine.ProtectorNative.SaveFailureQA");
    self.game = [[XCUIApplication alloc] initWithBundleIdentifier:@"house.machine.ProtectorNative.SaveFailureQA"];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
}
- (void)tearDown {
    [self.game terminate];
    [super tearDown];
}
- (void)capture:(NSString*)name extra:(NSDictionary*)extra {
    XCTAttachment* image = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    image.name = name; image.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:image];
    NSDictionary* evidence = @{@"state":[self state], @"checks":extra,
        @"accessibility_tree":self.game.debugDescription};
    XCTAttachment* data = [XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:evidence
        options:NSJSONWritingPrettyPrinted error:nil] uniformTypeIdentifier:@"public.json"];
    data.name = [name stringByAppendingString:@"-readback"];
    data.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:data];
}
- (void)testUnreadableSaveStopsWithoutChangingProgress {
    NSString* payload = @"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames/preserved-payload";
    NSString* previous = @"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames.previous";
    NSString* legacy = @"Library/Application Support/Original/RBNEG9/SavedGames";
    NSDictionary* before = @{@"payload":[self hash:payload], @"previous":[self hash:previous], @"legacy":[self hash:legacy]};
    [self.game launch];
    XCUIElement* status = self.game.staticTexts[@"native-runtime-status"];
    XCTAssertTrue([status waitForExistenceWithTimeout:30]);
    NSString* message = @"Saved progress could not be read. Your save files have not been changed. Reopen the app to try again. Keep the app installed to preserve its saves.";
    XCTNSPredicateExpectation* wait = [[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithFormat:@"label == %@", message] object:status];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[wait] timeout:30], XCTWaiterResultCompleted);
    XCTAssertFalse(self.game.buttons[@"native-pause"].exists);
    XCTAssertEqual(self.game.buttons.count, 0u);
    XCTAssertFalse(self.game.otherElements[@"translated-game-view"].exists);
    XCUIElement* scroll = self.game.scrollViews[@"native-runtime-status-scroll"];
    XCTAssertTrue(scroll.exists && scroll.hittable);
    CGRect viewport = scroll.frame, screen = self.game.frame;
    XCTAssertTrue(CGRectContainsRect(screen, viewport));
    [self capture:@"save-failure-message" extra:@{@"before":before,
        @"status_frame":NSStringFromCGRect(status.frame), @"viewport":NSStringFromCGRect(viewport)}];
    [scroll swipeUp];
    [self capture:@"save-failure-message-scrolled" extra:@{@"full_message":status.label}];
    NSDictionary* after = @{@"payload":[self hash:payload], @"previous":[self hash:previous], @"legacy":[self hash:legacy]};
    XCTAssertEqualObjects(before, after);
    XCTAssertEqualObjects([self state][@"boot_result"], @18);
    XCTAssertEqualObjects([self state][@"audio_output"], @"disabled");
    XCTAssertEqualObjects([self state][@"runtime_error"], message);
    [self capture:@"save-failure-preserved" extra:@{@"before":before, @"after":after}];
}
- (void)testReadableSaveColdRetryReachesTitle {
    NSString* current = @"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames";
    NSString* previous = @"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames.previous";
    NSString* legacy = @"Library/Application Support/Original/RBNEG9/SavedGames";
    NSDictionary* before = @{@"current":[self hash:current], @"previous":[self hash:previous], @"legacy":[self hash:legacy]};
    [self.game launch];
    XCTAssertTrue([self.game.buttons[@"native-pause"] waitForExistenceWithTimeout:30]);
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:85];
    BOOL title = NO;
    do {
        NSDictionary* state = [self state];
        if ([state[@"native_frontend_layout"][@"admission"] isEqual:@"source-dna-title"] &&
            [state[@"frame_index"] unsignedIntegerValue] > 1550) { title = YES; break; }
        [NSThread sleepForTimeInterval:.1];
    } while ([deadline timeIntervalSinceNow] > 0);
    XCTAssertTrue(title, @"Readable cold retry did not reach the original title");
    XCTAssertFalse(self.game.staticTexts[@"native-runtime-status"].exists);
    XCTAssertEqualObjects([self state][@"runtime_error"], NSNull.null);
    XCTAssertEqualObjects([self state][@"audio_output"], @"disabled");
    NSDictionary* after = @{@"current":[self hash:current], @"previous":[self hash:previous], @"legacy":[self hash:legacy]};
    XCTAssertEqualObjects(before, after);
    [self capture:@"save-readable-cold-retry-title" extra:@{@"before":before, @"after":after}];
}
@end
