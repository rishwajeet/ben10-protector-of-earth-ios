#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// Diagnostic source discovery, not another campaign or performance pass.
@interface ProtectorDialogueSourceUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@end

@implementation ProtectorDialogueSourceUITests
- (NSDictionary*)json:(NSString*)path {
    NSData* data=[NSData dataWithContentsOfFile:path];
    id value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
- (void)waitForLabel:(NSString*)label timeout:(NSTimeInterval)timeout {
    XCTestExpectation* expected=[[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithFormat:@"label == %@",label] object:self.game.otherElements[@"translated-game-view"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expected] timeout:timeout],XCTWaiterResultCompleted);
}
- (void)testBoundedDialogueSourceDiscovery {
    self.continueAfterFailure=NO; self.executionTimeAllowance=150;
    NSDictionary* environment=NSProcessInfo.processInfo.environment;
    NSString* container=environment[@"PROTECTOR_DIALOGUE_QA_CONTAINER"];
    NSString* bundle=environment[@"PROTECTOR_DIALOGUE_QA_BUNDLE"];
    NSString* identity=@"house.machine.ProtectorNative.DialogueArtQA";
    XCTSkipIf(!container.length,@"Use only the isolated DialogueArtQA clone");
    NSDictionary* metadata=[NSDictionary dictionaryWithContentsOfFile:
        [container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    XCTAssertEqualObjects(metadata[@"MCMMetadataIdentifier"],identity);
    NSDictionary* info=[NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
    XCTAssertEqualObjects(info[@"CFBundleIdentifier"],identity);
    NSData* startup=[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(startup.bytes,(CC_LONG)startup.length,digest);
    NSMutableString* hash=[NSMutableString string];
    for(NSUInteger i=0;i<sizeof(digest);++i) [hash appendFormat:@"%02x",digest[i]];
    XCTAssertEqualObjects(hash,@"6cd7db1b525b698782376f067c3c508163c119f5ce82a1f9662c4fab35340a95");
    NSString* diagnostics=[container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    NSString* key=@"512x128-8ef4a2b86c4d0d1e7346a4b3e5c5df5da069de4b6fb3e0bedb78d9e7bdd121a4";
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1",@"PROTECTOR_INTERFACE_AUDIT_SOURCE_KEY":key};
    [self.game launch];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:60];
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    XCUIElement* motion=self.game.switches[@"render.motion"];
    for(NSUInteger i=0;i<12 && !motion.hittable;++i) [settings swipeUp];
    XCTAssertTrue(motion.hittable);
    if([motion.value isEqual:@"1"]) [motion tap];
    XCTAssertEqualObjects(motion.value,@"0");
    [self.game.buttons[@"Resume"] tap];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:10];
    NSString* auditPath=[diagnostics stringByAppendingPathComponent:@"interface-source/audit.json"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:auditPath],@"Loading is not the exact dialogue source");
    [self.game.buttons[@"game-action-2048"] tap];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:25];
    NSUInteger movements=0, confirmations=0;
    NSMutableArray* labels=[NSMutableArray array];
    while([deadline timeIntervalSinceNow]>0 && ![NSFileManager.defaultManager fileExistsAtPath:auditPath]) {
        NSString* label=self.game.otherElements[@"translated-game-view"].label;
        if(![labels.lastObject isEqual:label]) [labels addObject:label ?: @""];
        if([label isEqual:@"Game instruction. Use Confirm to continue."] && confirmations<4) {
            [self.game.buttons[@"game-action-2048"] tap]; ++confirmations;
            // The next instruction can replace gameplay immediately after Confirm.
            // Let that transition settle before asking for another movement control.
            [NSThread sleepForTimeInterval:1.5];
        } else if([label isEqual:@"Game. Touch or drag to point. Attack confirms game menus."] && movements<12) {
            XCUIElement* move=self.game.otherElements[@"game-move"];
            if(move.exists && move.hittable) {
                CGRect frame=move.frame;
                if(CGRectIsEmpty(frame)) continue;
                // Resolve the point now: an asynchronous tutorial may hide the
                // stick before XCTest synthesizes this bounded touch.
                XCUICoordinate* origin=[self.game coordinateWithNormalizedOffset:CGVectorMake(0,0)];
                XCUICoordinate* right=[origin coordinateWithOffset:CGVectorMake(
                    CGRectGetMinX(frame)+CGRectGetWidth(frame)*.85,
                    CGRectGetMidY(frame))];
                [right pressForDuration:.25]; ++movements;
            } else [NSThread sleepForTimeInterval:.2];
        } else [NSThread sleepForTimeInterval:.2];
    }
    NSDictionary* audit=[self json:auditPath];
    BOOL found=[audit[@"capture_source_key"] isEqual:key];
    if(audit.count) {
        XCTAssertTrue(found);
        XCTAssertEqualObjects(audit[@"source"],@"translated_execution_callback");
    }
    NSDictionary* discovery=@{@"scope":@"Bounded artwork-source discovery, no campaign/performance acceptance",
        @"dialogue_source_observed":@(found),@"movement_pulses":@(movements),
        @"movement_seconds_per_pulse":@.25,@"instruction_confirms":@(confirmations),@"labels":labels};
    XCTAttachment* record=[XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:discovery
        options:NSJSONWritingPrettyPrinted error:nil] uniformTypeIdentifier:@"public.json"];
    record.name=@"dialogue-source-discovery";record.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:record];
    XCTAttachment* shot=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    shot.name=found ? @"dialogue-source-observed-end" : @"dialogue-source-not-reached-end";
    shot.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:shot];
    XCTAttachment* hierarchy=[XCTAttachment attachmentWithString:self.game.debugDescription];
    hierarchy.name=@"dialogue-source-end-accessibility";hierarchy.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:hierarchy];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    NSDictionary* state=[self json:[diagnostics stringByAppendingPathComponent:@"interactive-state.json"]];
    XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
}
- (void)tearDown { [self.game terminate]; [super tearDown]; }
@end
