#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// Isolated art visibility checks, not another campaign or timing qualification.
@interface ProtectorFoliageArtworkUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@end

@implementation ProtectorFoliageArtworkUITests
- (void)testDiagnoseRunningRedwoodLoading {
    self.continueAfterFailure=NO; self.executionTimeAllowance=60;
    NSString* container=NSProcessInfo.processInfo.environment[@"PROTECTOR_FOLIAGE_QA_CONTAINER"];
    XCTSkipIf(!container.length,@"Attach only to the isolated, already-running Redwood diagnostic");
    NSDictionary* metadata=[NSDictionary dictionaryWithContentsOfFile:
        [container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    NSString* identity=@"house.machine.ProtectorNative.FoliageRedwoodQA";
    XCTAssertEqualObjects(metadata[@"MCMMetadataIdentifier"],identity);
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    XCTAssertEqual(self.game.state,XCUIApplicationStateRunningForeground);
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:30];
    [self.game.buttons[@"game-action-2048"] tap];
    NSString* diagnostics=[container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    NSDictionary* state=[self freshState:diagnostics];
    state=[self freshState:diagnostics];
    [self capture:@"redwood-loading-diagnostic" state:state];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
}
- (NSDictionary*)json:(NSString*)path {
    NSData* data=[NSData dataWithContentsOfFile:path];
    id value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
- (NSString*)sha256:(NSString*)path {
    NSData* data=[NSData dataWithContentsOfFile:path];
    XCTAssertNotNil(data);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString* hash=[NSMutableString string];
    for(NSUInteger i=0;i<sizeof(digest);++i) [hash appendFormat:@"%02x",digest[i]];
    return hash;
}
- (void)waitForLabel:(NSString*)label timeout:(NSTimeInterval)timeout {
    XCTestExpectation* expected=[[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithFormat:@"label == %@",label]
        object:self.game.otherElements[@"translated-game-view"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expected] timeout:timeout],XCTWaiterResultCompleted);
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
    XCTAssertTrue(fresh,@"Require a new renderer readback after reaching the scene");
    return [self json:path];
}
- (void)waitForReadyWithoutLoadingGap {
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:60];
    BOOL sawLoading=NO,ready=NO;
    NSMutableArray* transitions=[NSMutableArray array];
    NSString* previous=nil;
    while([deadline timeIntervalSinceNow]>0) {
        NSString* label=self.game.otherElements[@"translated-game-view"].label;
        if(![label isEqualToString:previous]) { [transitions addObject:label ?: @""]; previous=label; }
        if([label isEqualToString:@"Game ready. Use Confirm to continue."]) { ready=YES; break; }
        if([label isEqualToString:@"Loading the game. Please wait."]) sawLoading=YES;
        if(sawLoading) XCTAssertEqualObjects(label,@"Loading the game. Please wait.");
        [NSThread sleepForTimeInterval:0.05];
    }
    XCTAttachment* evidence=[XCTAttachment attachmentWithString:[transitions componentsJoinedByString:@"\n"]];
    evidence.name=@"loading-to-ready-label-transitions";
    evidence.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:evidence];
    XCTAssertTrue(ready,@"Require the original ready prompt without a sampled loading-to-gameplay gap");
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
- (void)assertState:(NSDictionary*)state expected:(NSDictionary*)expected {
    XCTAssertEqualObjects(state[@"texture_pack_id"],expected[@"pack_id"]);
    XCTAssertEqualObjects(state[@"texture_pack_manifest_sha256"],expected[@"pack_sha256"]);
    NSUInteger expectedEntries=expected[@"pack_entries"] ? [expected[@"pack_entries"] unsignedIntegerValue] : 721u;
    XCTAssertGreaterThan(expectedEntries,0u);
    XCTAssertEqual([state[@"texture_pack_entries"] unsignedIntegerValue],expectedEntries);
    XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
    XCTAssertLessThanOrEqual([state[@"texture_pack_frame_bytes"] unsignedLongLongValue],
        [state[@"texture_pack_allocation_budget_bytes"] unsignedLongLongValue]);
    XCTAssertLessThanOrEqual([state[@"texture_pack_cache_bytes"] unsignedLongLongValue],
        [state[@"texture_pack_allocation_budget_bytes"] unsignedLongLongValue]);
    NSMutableSet* seen=[NSMutableSet setWithArray:state[@"texture_pack_frame_sources"] ?: @[]];
    [seen intersectSet:[NSSet setWithArray:expected[@"selected_planes"]]];
    XCTAssertGreaterThan(seen.count,0u,@"At least one selected artwork plane must actually render");
    if ([expected[@"require_all_selected_planes"] boolValue])
        XCTAssertEqual(seen.count,[expected[@"selected_planes"] count],@"The complete selected material family must render together");
    if (expected[@"finite_backdrop_draws"])
        XCTAssertEqualObjects(state[@"finite_backdrop_draws"],expected[@"finite_backdrop_draws"]);
    if (expected[@"finite_backdrop_extensions"])
        XCTAssertEqualObjects(state[@"finite_backdrop_extensions"],expected[@"finite_backdrop_extensions"]);
    if (expected[@"repeating_backdrop_extensions"])
        XCTAssertEqualObjects(state[@"repeating_backdrop_extensions"],expected[@"repeating_backdrop_extensions"]);
    if (expected[@"hill_backdrop_extensions"])
        XCTAssertEqualObjects(state[@"hill_backdrop_extensions"],expected[@"hill_backdrop_extensions"]);
}
- (void)testFoliageArtwork {
    self.continueAfterFailure=NO; self.executionTimeAllowance=180;
    NSDictionary* environment=NSProcessInfo.processInfo.environment;
    NSString* container=environment[@"PROTECTOR_FOLIAGE_QA_CONTAINER"];
    NSString* bundle=environment[@"PROTECTOR_FOLIAGE_QA_BUNDLE"];
    XCTSkipIf(!container.length,@"Select an isolated foliage QA container");
    NSDictionary* expected=[self json:environment[@"PROTECTOR_FOLIAGE_QA_EXPECTATIONS"]];
    XCTAssertEqualObjects(expected[@"schema"],@"protector-native.foliage-art-expectations/v1");
    NSString* identity=expected[@"identity"];
    XCTAssertTrue([identity hasPrefix:@"house.machine.ProtectorNative.Foliage"] ||
                  [identity hasPrefix:@"house.machine.ProtectorNative.Signs"] ||
                  [identity hasPrefix:@"house.machine.ProtectorNative.Backdrop"]);
    NSDictionary* metadata=[NSDictionary dictionaryWithContentsOfFile:
        [container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    XCTAssertEqualObjects(metadata[@"MCMMetadataIdentifier"],identity);
    NSDictionary* info=[NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
    XCTAssertEqualObjects(info[@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self sha256:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]],expected[@"startup_sha256"]);
    XCTAssertEqualObjects([self sha256:[bundle stringByAppendingPathComponent:@"RestoredArt/pack.json"]],expected[@"pack_sha256"]);
    NSString* diagnostics=[container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1",@"PROTECTOR_SCENE_EDGE_AUDIT":@"1"};
    [self.game launch];
    [self waitForReadyWithoutLoadingGap];
    [self.game.buttons[@"game-action-2048"] tap];
    NSString* playing=@"Game. Touch or drag to point. Attack confirms game menus.";
    [self waitForLabel:playing timeout:20];
    NSDictionary* live=[self freshState:diagnostics];
    [self assertState:live expected:expected];
    XCTAssertEqualObjects(self.game.otherElements[@"translated-game-view"].label,playing);
    [self capture:@"foliage-live-smooth" state:live];
    NSUInteger motionSeconds=[expected[@"motion_sample_seconds"] unsignedIntegerValue];
    XCTAssertLessThanOrEqual(motionSeconds,10u,@"Artwork motion sampling remains bounded");
    if (motionSeconds) {
        NSTimeInterval start=NSDate.date.timeIntervalSince1970;
        [NSThread sleepForTimeInterval:motionSeconds];
        NSDictionary* later=[self freshState:diagnostics];
        NSTimeInterval end=NSDate.date.timeIntervalSince1970;
        [self assertState:later expected:expected];
        XCTAssertGreaterThan([later[@"frame_index"] unsignedIntegerValue],[live[@"frame_index"] unsignedIntegerValue]);
        XCTAssertEqualObjects(self.game.otherElements[@"translated-game-view"].label,playing);
        [self capture:@"foliage-motion-end" state:later];
        NSDictionary* span=@{@"start_unix":@(start),@"end_unix":@(end),
            @"first_frame":live[@"frame_index"],@"last_frame":later[@"frame_index"],
            @"scope":@"Bounded animated-material observation only, not a performance or campaign pass"};
        NSData* spanData=[NSJSONSerialization dataWithJSONObject:span options:NSJSONWritingPrettyPrinted error:nil];
        XCTAssertTrue([spanData writeToFile:[diagnostics stringByAppendingPathComponent:@"artwork-motion-span.json"] atomically:YES]);
    }
    // Use the normal native setting to allow the bounded source-draw audit.
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    XCUIElement* motion=self.game.switches[@"render.motion"];
    for(NSUInteger i=0;i<12 && !motion.hittable;++i) [settings swipeUp];
    XCTAssertTrue(motion.hittable); XCTAssertEqualObjects(motion.value,@"1");
    [motion tap]; XCTAssertEqualObjects(motion.value,@"0");
    [self.game.buttons[@"Resume"] tap];
    [self waitForLabel:playing timeout:10];
    NSString* auditPath=[diagnostics stringByAppendingPathComponent:@"interface-source/scene-edges.json"];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    while(![NSFileManager.defaultManager fileExistsAtPath:auditPath] && [deadline timeIntervalSinceNow]>0)
        [NSThread sleepForTimeInterval:0.1];
    NSDictionary* audit=[self json:auditPath];
    XCTAssertEqualObjects(audit[@"schema"],@"protector-native.scene-edge-inspection/v1");
    XCTAssertEqualObjects(audit[@"source"],@"translated_execution_callback");
    XCTAssertTrue([audit[@"source_vertices_immutable"] boolValue]);
    XCTAssertEqual([audit[@"guest_updates_during_inspection"] unsignedIntegerValue],0u);
    NSUInteger expectedSamples=expected[@"scene_edge_samples"] ? [expected[@"scene_edge_samples"] unsignedIntegerValue] : 5u;
    XCTAssertEqual([audit[@"samples"] count],expectedSamples);
    if (expected[@"finite_backdrop_draws"]) {
        NSUInteger admitted=0;
        for (NSDictionary* draw in audit[@"identities"]) admitted += [draw[@"finite_backdrop_identity"] unsignedIntegerValue] != 0;
        XCTAssertEqual(admitted,[expected[@"finite_backdrop_draws"] unsignedIntegerValue]);
        NSDictionary* baseline=nil;
        for (NSDictionary* sample in audit[@"samples"])
            if ([sample[@"image"] isEqualToString:@"scene-finite-backdrop-baseline.png"]) baseline=sample;
        XCTAssertNotNil(baseline);
        XCTAssertEqualObjects(baseline[@"image"],@"scene-finite-backdrop-baseline.png");
        XCTAssertEqual([baseline[@"state"][@"finite_backdrop_draws"] unsignedIntegerValue],0u);
        XCTAssertEqual([baseline[@"state"][@"finite_backdrop_extensions"] unsignedIntegerValue],0u);
    }
    if (expected[@"repeating_backdrop_draws"]) {
        NSUInteger admitted=0;
        for (NSDictionary* draw in audit[@"identities"]) admitted += [draw[@"repeating_backdrop_identity"] unsignedIntegerValue] != 0;
        XCTAssertEqual(admitted,[expected[@"repeating_backdrop_draws"] unsignedIntegerValue]);
        NSDictionary* baseline=nil;
        for (NSDictionary* sample in audit[@"samples"])
            if ([sample[@"image"] isEqualToString:@"scene-repeating-backdrop-baseline.png"]) baseline=sample;
        XCTAssertEqualObjects(baseline[@"image"],@"scene-repeating-backdrop-baseline.png");
        XCTAssertEqual([baseline[@"state"][@"repeating_backdrop_extensions"] unsignedIntegerValue],0u);
        XCTAssertEqualObjects(baseline[@"state"][@"finite_backdrop_draws"],expected[@"finite_backdrop_draws"]);
        XCTAssertEqualObjects(baseline[@"state"][@"finite_backdrop_extensions"],expected[@"finite_backdrop_extensions"]);
        XCTAssertEqual([audit[@"samples"][0][@"state"][@"repeating_backdrop_extensions"] unsignedIntegerValue],2u);
    }
    if (expected[@"hill_backdrop_draws"]) {
        NSUInteger admitted=0;
        for (NSDictionary* draw in audit[@"identities"]) admitted += [draw[@"hill_backdrop_identity"] unsignedIntegerValue]!=0;
        XCTAssertEqual(admitted,[expected[@"hill_backdrop_draws"] unsignedIntegerValue]);
        NSDictionary* baseline=[audit[@"samples"] lastObject];
        XCTAssertEqualObjects(baseline[@"image"],@"scene-hill-backdrop-baseline.png");
        XCTAssertEqual([baseline[@"state"][@"hill_backdrop_extensions"] unsignedIntegerValue],0u);
        XCTAssertEqualObjects(baseline[@"state"][@"finite_backdrop_draws"],expected[@"finite_backdrop_draws"]);
        XCTAssertEqualObjects(baseline[@"state"][@"finite_backdrop_extensions"],expected[@"finite_backdrop_extensions"]);
        XCTAssertEqual([baseline[@"state"][@"repeating_backdrop_extensions"] unsignedIntegerValue],2u);
        XCTAssertEqual([audit[@"samples"][0][@"state"][@"hill_backdrop_extensions"] unsignedIntegerValue],2u);
    }
    NSDictionary* inspected=[self freshState:diagnostics];
    [self assertState:inspected expected:expected];
    XCTAssertEqualObjects(self.game.otherElements[@"translated-game-view"].label,playing);
    [self capture:@"foliage-source-audit" state:inspected];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
}
- (void)tearDown { [self.game terminate]; [super tearDown]; }
@end
