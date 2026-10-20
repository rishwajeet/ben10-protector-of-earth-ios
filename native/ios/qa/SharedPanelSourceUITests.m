#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// A bounded art-source capture, not a gameplay/campaign acceptance rerun.
// The isolated bundle reuses the already-qualified Canyon startup resource.
@interface ProtectorSharedPanelSourceUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@end

@implementation ProtectorSharedPanelSourceUITests
- (NSDictionary*)json:(NSString*)path {
    NSData* data = [NSData dataWithContentsOfFile:path];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
- (void)waitForLabel:(NSString*)label timeout:(NSTimeInterval)timeout {
    XCTestExpectation* expected = [[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithFormat:@"label == %@",label]
        object:self.game.otherElements[@"translated-game-view"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expected] timeout:timeout],XCTWaiterResultCompleted);
}
- (void)testSharedPanelSource {
    [self checkSharedPanel:NO];
}
- (void)testRestoredSharedPanel {
    [self checkSharedPanel:YES];
}
- (NSDictionary*)freshState:(NSString*)diagnostics {
    NSString* path=[diagnostics stringByAppendingPathComponent:@"interactive-state.json"];
    NSDate* after=[NSDate date];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:12];
    BOOL fresh=NO;
    while([deadline timeIntervalSinceNow]>0) {
        NSDate* modified=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if(modified && [modified compare:after]==NSOrderedDescending) { fresh=YES; break; }
        [NSThread sleepForTimeInterval:0.1];
    }
    XCTAssertTrue(fresh,@"Require a new periodic renderer readback for this stable screen");
    return [self json:path];
}
- (void)capture:(NSString*)name state:(NSDictionary*)state {
    XCTAttachment* image=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    image.name=name; image.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:image];
    XCTAttachment* hierarchy=[XCTAttachment attachmentWithString:self.game.debugDescription];
    hierarchy.name=[name stringByAppendingString:@"-accessibility"];
    hierarchy.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:hierarchy];
    XCTAttachment* data=[XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:state
        options:NSJSONWritingPrettyPrinted error:nil] uniformTypeIdentifier:@"public.json"];
    data.name=[name stringByAppendingString:@"-state"]; data.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:data];
}
- (void)assertRestored:(NSDictionary*)state expected:(NSDictionary*)expected route:(NSString*)route {
    XCTAssertEqualObjects(state[@"texture_pack_id"],expected[@"pack_id"]);
    XCTAssertEqualObjects(state[@"texture_pack_manifest_sha256"],expected[@"pack_sha256"]);
    XCTAssertEqual([state[@"texture_pack_entries"] unsignedIntegerValue],704u);
    XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
    NSSet* observed=[NSSet setWithArray:state[@"texture_pack_frame_sources"]];
    NSSet* wanted=[NSSet setWithArray:expected[@"routes"][route]];
    XCTAssertTrue([wanted isSubsetOfSet:observed]);
    BOOL loading=[route isEqual:@"loading"];
    XCTAssertEqual([state[@"native_shared_panel_layout"][@"enabled"] boolValue],loading);
    if(loading) XCTAssertEqualObjects(state[@"native_shared_panel_layout"][@"admission"],@"source-three-piece-loading-panel");
    XCTAssertLessThanOrEqual([state[@"texture_pack_frame_bytes"] unsignedLongLongValue],
        [state[@"texture_pack_allocation_budget_bytes"] unsignedLongLongValue]);
    XCTAssertLessThanOrEqual([state[@"texture_pack_cache_bytes"] unsignedLongLongValue],
        [state[@"texture_pack_allocation_budget_bytes"] unsignedLongLongValue]);
}
- (void)checkSharedPanel:(BOOL)restored {
    self.continueAfterFailure = NO; self.executionTimeAllowance = 150;
    NSDictionary* environment = NSProcessInfo.processInfo.environment;
    NSString* container = environment[@"PROTECTOR_SHARED_QA_CONTAINER"];
    NSString* bundle = environment[@"PROTECTOR_SHARED_QA_BUNDLE"];
    NSString* route = environment[@"PROTECTOR_SHARED_QA_ROUTE"];
    XCTSkipIf(!container.length,@"Select the isolated SharedPanelsQA container");
    NSArray* routes = @[@"loading",@"tutorial"];
    XCTAssertTrue([routes containsObject:route]);
    NSString* identity = restored ? @"house.machine.ProtectorNative.SharedPanelsRestoredQA" :
        @"house.machine.ProtectorNative.SharedPanelsQA";
    NSDictionary* expected = restored ? [self json:environment[@"PROTECTOR_SHARED_ART_EXPECTATIONS"]] : @{};
    if(restored) XCTAssertEqualObjects(expected[@"schema"],@"protector-native.shared-panel-art-expectations/v1");
    NSDictionary* metadata = [NSDictionary dictionaryWithContentsOfFile:
        [container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    XCTAssertEqualObjects(metadata[@"MCMMetadataIdentifier"],identity);
    NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
    XCTAssertEqualObjects(info[@"CFBundleIdentifier"],identity);
    NSData* startup = [NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(startup.bytes,(CC_LONG)startup.length,digest);
    NSMutableString* hash = [NSMutableString string];
    for(NSUInteger i=0;i<sizeof(digest);++i) [hash appendFormat:@"%02x",digest[i]];
    XCTAssertEqualObjects(hash,@"6cd7db1b525b698782376f067c3c508163c119f5ce82a1f9662c4fab35340a95");
    NSString* diagnostics = [container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    self.game = [[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.game.launchArguments = @[@"-touch.hideWithController.v1",@"NO"];
    self.game.launchEnvironment = @{@"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1"};
    [self.game launch];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:60];
    NSString* expectedLabel = @"Game ready. Use Confirm to continue.";
    if ([route isEqual:@"tutorial"]) {
        [self.game.buttons[@"game-action-2048"] tap];
        [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:15];
        XCUICoordinate* right = [self.game.otherElements[@"game-move"]
            coordinateWithNormalizedOffset:CGVectorMake(.85,.5)];
        [right pressForDuration:1.5];
        expectedLabel = @"Game instruction. Use Confirm to continue.";
        [self waitForLabel:expectedLabel timeout:15];
    }
    if(restored) {
        NSDictionary* state=[self freshState:diagnostics];
        [self assertRestored:state expected:expected route:route];
        [self capture:[@"shared-restored-smooth-" stringByAppendingString:route] state:state];
    }
    // Capture the existing translated draw only after the chosen screen is
    // reached by real touch. No scene/context/CPU state is injected.
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:
        [diagnostics stringByAppendingPathComponent:@"interface-source"]]);
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    XCUIElement* motion = self.game.switches[@"render.motion"];
    for(NSUInteger i=0;i<12 && !motion.hittable;++i) [settings swipeUp];
    XCTAssertTrue(motion.hittable); XCTAssertEqualObjects(motion.value,@"1");
    [motion tap]; XCTAssertEqualObjects(motion.value,@"0");
    [self.game.buttons[@"Resume"] tap];
    [self waitForLabel:expectedLabel timeout:10];
    NSString* auditPath = [diagnostics stringByAppendingPathComponent:@"interface-source/audit.json"];
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while(![NSFileManager.defaultManager fileExistsAtPath:auditPath] && [deadline timeIntervalSinceNow]>0)
        [NSThread sleepForTimeInterval:0.1];
    NSDictionary* audit = [self json:auditPath];
    XCTAssertEqualObjects(audit[@"schema"],@"protector-native.interface-source-audit/v1");
    XCTAssertEqualObjects(audit[@"source"],@"translated_execution_callback");
    XCTAssertTrue([audit[@"draws"] count]>0);
    NSDictionary* state = restored ? [self freshState:diagnostics] :
        [self json:[diagnostics stringByAppendingPathComponent:@"interactive-state.json"]];
    if(restored) [self assertRestored:state expected:expected route:route];
    [self capture:[(restored ? @"shared-restored-" : @"shared-source-") stringByAppendingString:route] state:state];
    XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
    if(restored) {
        [self.game.buttons[@"game-action-2048"] tap];
        [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:15];
        NSDictionary* returned=[self freshState:diagnostics];
        XCTAssertFalse([returned[@"native_shared_panel_layout"][@"enabled"] boolValue]);
        XCTAssertEqualObjects(returned[@"audio_output"],@"disabled");
        XCTAssertEqualObjects(returned[@"runtime_error"],NSNull.null);
        [self capture:[@"shared-restored-return-" stringByAppendingString:route] state:returned];
    }
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
}
- (void)tearDown { [self.game terminate]; [super tearDown]; }
@end
