#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// Ordinary cold boot and actual touch input in a dedicated identity. No guest
// menu-state injection, source-clock override or campaign progress is needed.
@interface ProtectorFrontendUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* diagnostics;
@end

@implementation ProtectorFrontendUITests
- (NSDictionary*)state:(NSString*)name {
    NSData* data = [NSData dataWithContentsOfFile:[self.diagnostics stringByAppendingPathComponent:name]];
    id state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [state isKindOfClass:NSDictionary.class] ? state : @{};
}
- (void)waitForLayout:(NSString*)admission afterFrame:(NSUInteger)frame timeout:(NSTimeInterval)timeout {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSDictionary* state;
    do {
        state = [self state:@"interactive-state.json"];
        if ([state[@"native_frontend_layout"][@"enabled"] boolValue] &&
            [state[@"native_frontend_layout"][@"admission"] isEqual:admission] &&
            [state[@"frame_index"] unsignedIntegerValue] > frame) {
            XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
            XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
            XCTAssertEqualObjects(state[@"edition"],@"upgraded");
            return;
        }
        [NSThread sleepForTimeInterval:0.05];
    } while ([deadline timeIntervalSinceNow] > 0);
    XCTFail(@"Source-qualified frontend did not appear: %@",state);
}
- (void)capture:(NSString*)name {
    XCTAttachment* image = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    image.name = name; image.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:image];
    NSDictionary* receipt = @{@"render":[self state:@"interactive-state.json"],
        @"controls":[self state:@"native-controls.json"]};
    XCTAttachment* data = [XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:receipt
        options:NSJSONWritingPrettyPrinted error:nil] uniformTypeIdentifier:@"public.json"];
    data.name = [name stringByAppendingString:@"-readback"];
    data.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:data];
}
- (void)testSourceTitleMainMenuAndNativePause {
    self.continueAfterFailure = NO; self.executionTimeAllowance = 150;
    NSString* container = NSProcessInfo.processInfo.environment[@"PROTECTOR_FRONTEND_QA_CONTAINER"];
    NSString* bundle = NSProcessInfo.processInfo.environment[@"PROTECTOR_FRONTEND_QA_BUNDLE"];
    XCTSkipIf(!container.length, @"Select the isolated FrontendQA container and bundle");
    XCTAssertTrue(bundle.length > 0);
    NSString* identifier = @"house.machine.ProtectorNative.FrontendQA";
    NSDictionary* metadata = [NSDictionary dictionaryWithContentsOfFile:[container
        stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    XCTAssertEqualObjects(metadata[@"MCMMetadataIdentifier"],identifier);
    NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
    XCTAssertEqualObjects(info[@"CFBundleIdentifier"],identifier);
    NSData* startup = [NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]];
    XCTAssertEqual(startup.length,2622u);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(startup.bytes,(CC_LONG)startup.length,digest);
    NSMutableString* hash = [NSMutableString string];
    for (NSUInteger i=0; i<sizeof(digest); ++i) [hash appendFormat:@"%02x",digest[i]];
    XCTAssertEqualObjects(hash,@"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    self.diagnostics = [container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:
        [self.diagnostics stringByAppendingPathComponent:@"interactive-state.json"]],
        @"Preserve previous diagnostics before a new attempt");
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    self.game = [[XCUIApplication alloc] initWithBundleIdentifier:identifier];
    self.game.launchArguments = @[@"-touch.hideWithController.v1",@"NO"];
    [self.game launch];
    [self waitForLayout:@"source-dna-title" afterFrame:1550 timeout:90];
    XCUIElement* confirm = self.game.buttons[@"game-action-2048"];
    XCTAssertTrue(confirm.hittable); XCTAssertEqualObjects(confirm.label,@"Confirm");
    [self capture:@"frontend-title"];
    NSUInteger titleFrame = [[self state:@"interactive-state.json"][@"frame_index"] unsignedIntegerValue];
    [confirm tap];
    [self waitForLayout:@"source-dna-watch-menu" afterFrame:titleFrame+60 timeout:20];
    XCTAssertEqualObjects(self.game.buttons[@"game-action-4"].label,@"Menu down");
    [self capture:@"frontend-main-menu"];
    NSUInteger menuFrame = [[self state:@"interactive-state.json"][@"frame_index"] unsignedIntegerValue];
    [self.game.buttons[@"game-action-4"] tap];
    [self waitForLayout:@"source-dna-watch-menu" afterFrame:menuFrame+20 timeout:10];
    [self capture:@"frontend-continue-selected"];
    [self.game.buttons[@"game-action-8"] tap];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:10]);
    XCTAssertTrue(self.game.navigationBars[@"Paused"].exists);
    XCTestExpectation* settled = [self expectationWithDescription:@"native sheet transition"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.75*NSEC_PER_SEC)),
        dispatch_get_main_queue(),^{ [settled fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[settled] timeout:3],XCTWaiterResultCompleted);
    [self capture:@"frontend-native-settings"];
    [self.game.buttons[@"Resume"] tap];
    [self waitForLayout:@"source-dna-watch-menu" afterFrame:menuFrame+80 timeout:15];
    [self capture:@"frontend-resumed-menu"];
}
- (void)tearDown {
    [self.game terminate]; // Process termination, not clean guest save-flush evidence.
    [super tearDown];
}
@end
