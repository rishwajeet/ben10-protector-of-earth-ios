#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// Bounded access to the changed source tutorial, not a campaign replay.
// No actor relocation, save flags, script instruction pointers or unlocks.
@interface ProtectorFourArmsGrabUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* commands;
@property(nonatomic) NSString* trace;
@end

@implementation ProtectorFourArmsGrabUITests
- (NSDictionary*)json:(NSString*)path {
    NSData* data=[NSData dataWithContentsOfFile:path];
    id value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
- (void)command:(NSString*)command duration:(NSTimeInterval)seconds {
    NSString* commandID=NSUUID.UUID.UUIDString;
    NSData* data=[NSJSONSerialization dataWithJSONObject:@{@"id":commandID,@"command":command}
        options:0 error:nil];
    NSTimeInterval sent=NSProcessInfo.processInfo.systemUptime;
    XCTAssertTrue([data writeToFile:self.commands options:NSDataWritingAtomic error:nil]);
    BOOL received=NO;
    while(NSProcessInfo.processInfo.systemUptime-sent<3) {
        if([[self json:[self.commands stringByAppendingString:@".receipt.json"]][@"command_id"] isEqual:commandID]) {
            received=YES;break;
        }
        [NSThread sleepForTimeInterval:.01];
    }
    XCTAssertTrue(received,@"Controller command was not observed");
    // Receipt polling is part of the requested hold, not an extra second of
    // movement added by XCTest's predicate polling interval.
    NSTimeInterval remaining=seconds-(NSProcessInfo.processInfo.systemUptime-sent);
    if(remaining>0)[NSThread sleepForTimeInterval:remaining];
}
- (void)capture:(NSString*)name {
    XCTAttachment* shot=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    shot.name=name;shot.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:shot];
    NSDictionary* receipt=[self json:[self.commands stringByAppendingString:@".receipt.json"]];
    XCTAttachment* state=[XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:receipt
        options:NSJSONWritingPrettyPrinted error:nil] uniformTypeIdentifier:@"public.json"];
    state.name=[name stringByAppendingString:@"-input-state"];state.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:state];
}
- (void)waitFor:(NSString*)label timeout:(NSTimeInterval)timeout {
    XCTNSPredicateExpectation* wait=[[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithFormat:@"label == %@",label] object:self.game.otherElements[@"translated-game-view"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[wait] timeout:timeout],XCTWaiterResultCompleted);
}
- (void)testBoundedPushingTutorialRoute {
    self.continueAfterFailure=NO;self.executionTimeAllowance=150;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    NSString* container=env[@"PROTECTOR_GRAB_QA_CONTAINER"];
    NSString* bundle=env[@"PROTECTOR_GRAB_QA_BUNDLE"];
    NSString* identity=@"house.machine.ProtectorNative.FourArmsGrabQA";
    XCTSkipIf(!container.length || !bundle.length,@"Requires the separate direct-entry grab QA app");
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:
        @"Info.plist"]][@"CFBundleIdentifier"],identity);
    NSData* config=[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(config.bytes,(CC_LONG)config.length,digest);
    NSMutableString* hash=[NSMutableString string];
    for(NSUInteger i=0;i<sizeof(digest);i++)[hash appendFormat:@"%02x",digest[i]];
    XCTAssertEqualObjects(hash,@"6234ad03ece578bb36b30b1f75c2fb25d02724638d0a7fd92c89aa5610c4073f");
    NSString* diagnostics=[container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    self.trace=[container stringByAppendingPathComponent:@"Documents/grab-ui-text.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:self.trace]);
    self.commands=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"grab-controller-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commands,
        @"PROTECTOR_CONTROLLER_QA_READBACK":@"1",@"PROTECTOR_UI_TEXT_LOG":self.trace};
    [self.game launch];
    [self waitFor:@"Game ready. Use Confirm to continue." timeout:60];
    [self command:@"neutral" duration:.25];[self command:@"a" duration:.15];[self command:@"neutral" duration:.4];
    [self waitFor:@"Game. Touch or drag to point. Attack confirms game menus." timeout:15];
    [self capture:@"grab-scene-entry"];
    [self command:@"stickright" duration:1.0];[self command:@"neutral" duration:.2];
    BOOL instruction=NO;
    for(NSUInteger step=0;step<8;step++) {
        NSString* label=self.game.otherElements[@"translated-game-view"].label;
        if([label isEqual:@"Game instruction. Read the panel; Confirm will appear shortly."]) {
            [self command:@"neutral" duration:.2];
            [self waitFor:@"Game instruction. Use Confirm to continue." timeout:10];
            instruction=YES;break;
        }
        if([label isEqual:@"Game instruction. Use Confirm to continue."]) { instruction=YES;break; }
        XCTAssertEqualObjects(label,@"Game. Touch or drag to point. Attack confirms game menus.");
        [self command:@"stickright+y" duration:.8];
        [self capture:[NSString stringWithFormat:@"grab-route-jump-%lu",(unsigned long)step]];
        [self command:@"stickright" duration:.4];[self command:@"neutral" duration:.3];
    }
    [self command:@"neutral" duration:.25];
    [self capture:instruction ? @"grab-route-instruction" : @"grab-route-not-reached"];
    XCTAttachment* trace=[XCTAttachment attachmentWithString:
        [NSString stringWithContentsOfFile:self.trace encoding:NSUTF8StringEncoding error:nil] ?: @""];
    trace.name=@"grab-translated-text";trace.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:trace];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
    NSDictionary* state=[self json:[diagnostics stringByAppendingPathComponent:@"interactive-state.json"]];
    XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
    // Passing this diagnostic means bounded execution and retained evidence,
    // not that the requested instruction was reached. Review captures/trace.
}
- (void)tearDown { [self.game terminate];[super tearDown]; }
@end
