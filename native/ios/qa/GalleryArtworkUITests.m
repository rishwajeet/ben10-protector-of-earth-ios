#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// Runs only against the explicitly authorized disposable gallery save and a
// distinct app identity. No guest memory, script, unlock rule or save writes.
@interface ProtectorGalleryArtworkUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* container;
@property(nonatomic) NSDictionary* sourceKeys;
@end

@implementation ProtectorGalleryArtworkUITests
- (NSDictionary*)json:(NSString*)path {
    NSData* data=[NSData dataWithContentsOfFile:path];
    id object=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}
- (NSString*)hash:(NSString*)path {
    NSData* data=[NSData dataWithContentsOfFile:path];
    if(!data) return @"missing";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString* result=[NSMutableString string];
    for(NSUInteger i=0;i<sizeof(digest);i++) [result appendFormat:@"%02x",digest[i]];
    return result;
}
- (void)waitForLabel:(NSString*)label timeout:(NSTimeInterval)timeout {
    XCTNSPredicateExpectation* expected=[[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithFormat:@"label == %@",label] object:self.game.otherElements[@"translated-game-view"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expected] timeout:timeout],XCTWaiterResultCompleted);
}
- (void)settle {
    XCTestExpectation* expected=[self expectationWithDescription:@"settled source animation"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{[expected fulfill];});
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expected] timeout:5],XCTWaiterResultCompleted);
}
- (void)pulse:(NSString*)command {
    NSDictionary* identifiers=@{@"a":@"game-action-2048",@"b":@"game-back",@"up":@"game-action-8",
        @"down":@"game-action-4",@"left":@"game-action-1",@"right":@"game-action-2"};
    XCUIElement* action=self.game.buttons[identifiers[command]];
    XCTAssertTrue(action.hittable);[action tap];
}
- (void)sourceKey:(NSString*)key {
    NSString* path=[self.container stringByAppendingPathComponent:@"Documents/gallery-art-ui-text.jsonl"];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:30];
    while([deadline timeIntervalSinceNow]>0) {
        NSString* text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        for(NSString* line in [text componentsSeparatedByString:@"\n"]) {
            NSDictionary* row=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if([row[@"key"] isEqual:key]) return;
        }
        [NSThread sleepForTimeInterval:.1];
    }
    XCTFail(@"Source key not observed: %@",key);
}
- (NSDictionary*)capture:(NSString*)name art:(NSNumber*)ordinal {
    NSString* path=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/interactive-state.json"];
    NSDate* after=NSDate.date;NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:12];BOOL fresh=NO;
    while([deadline timeIntervalSinceNow]>0) {
        NSDate* modified=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if(modified && [modified compare:after]==NSOrderedDescending) {fresh=YES;break;}
        [NSThread sleepForTimeInterval:.1];
    }
    XCTAssertTrue(fresh);
    NSDictionary* state=[self json:path];
    XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
    XCTAssertEqualObjects(state[@"texture_pack_id"],@"gallery-only-combined-v1");
    XCTAssertEqualObjects(state[@"texture_pack_manifest_sha256"],@"2aa6b0374107523d9fe4c3a543c3b11df1d2d1ac0a6b99c1c0f0b1adb558feac");
    XCTAssertEqual([state[@"texture_pack_entries"] unsignedIntegerValue],795u);
    XCTAssertTrue([state[@"native_gallery_layout"][@"enabled"] boolValue],@"Source menu component must retain its native layout");
    if(ordinal) {
        NSString* key=self.sourceKeys[ordinal.stringValue];XCTAssertNotNil(key);
        XCTAssertTrue([state[@"texture_pack_frame_sources"] containsObject:key],@"Expected art %@ (%@) in this frame",ordinal,key);
    }
    XCTAttachment* picture=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    picture.name=name;picture.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:picture];
    XCTAttachment* hierarchy=[XCTAttachment attachmentWithString:self.game.debugDescription];
    hierarchy.name=[name stringByAppendingString:@"-hierarchy"];hierarchy.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:hierarchy];
    for(NSString* suffix in @[@"renderer",@"controls"]) {
        NSDictionary* payload=[suffix isEqual:@"renderer"] ? state : [self json:
            [self.container stringByAppendingPathComponent:@"Documents/Diagnostics/native-controls.json"]];
        XCTAttachment* attachment=[XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:nil]
            uniformTypeIdentifier:@"public.json"];
        attachment.name=[name stringByAppendingFormat:@"-%@",suffix];attachment.lifetime=XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:attachment];
    }
    return state;
}
- (void)openArt:(NSUInteger)ordinal name:(NSString*)name {
    [self pulse:@"a"];[self settle];
    [self capture:name art:@(ordinal)];
    [self pulse:@"b"];[self settle];
}
- (void)setSmoothMotion:(BOOL)enabled {
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    XCUIElement* motion=self.game.switches[@"render.motion"];
    for(NSUInteger i=0;i<12 && !motion.hittable;i++) [settings swipeUp];
    XCTAssertTrue(motion.hittable);
    NSString* expected=enabled ? @"1" : @"0";
    if(![motion.value isEqual:expected]) [motion tap];
    XCTAssertEqualObjects(motion.value,expected);
    [self.game.buttons[@"Resume"] tap];
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
}
- (void)captureGeometry:(NSString*)route {
    NSString* path=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/interface-source/audit.json"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
    // The source audit is dormant under smooth presentation. Only enable it
    // after ordinary navigation reaches the exact unlocked grid/full-art state.
    [self setSmoothMotion:NO];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:15];
    while(![NSFileManager.defaultManager fileExistsAtPath:path] && [deadline timeIntervalSinceNow]>0)
        [NSThread sleepForTimeInterval:.1];
    NSDictionary* audit=[self json:path];
    XCTAssertEqualObjects(audit[@"schema"],@"protector-native.interface-source-audit/v1");
    XCTAssertEqualObjects(audit[@"source"],@"translated_execution_callback");
    XCTAssertGreaterThan([audit[@"draws"] count],0u);
    XCTAssertEqualObjects(audit[@"omitted_orthographic_draws"],@0);
    XCTAssertEqualObjects(audit[@"omitted_vertices"],@0);
    [self capture:[@"gallery-art-geometry-" stringByAppendingString:route] art:@0];
    [self setSmoothMotion:YES];
}
- (void)testAuthorizedGalleryArtwork { [self runGallery:nil]; }
- (void)testAuthorizedGalleryGeometry {
    NSString* route=NSProcessInfo.processInfo.environment[@"PROTECTOR_GALLERY_ART_GEOMETRY"];
    XCTSkipIf(!route.length,@"Requires an exact source diagnostic route");
    NSArray* routes=@[@"grid",@"full"];
    XCTAssertTrue([routes containsObject:route]);
    [self runGallery:route];
}
- (void)runGallery:(NSString*)geometryRoute {
    self.continueAfterFailure=NO;self.executionTimeAllowance=400;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_GALLERY_ART_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires a new GalleryArtworkQA identity and authorized save fixture");
    NSString* identity=@"house.machine.ProtectorNative.GalleryArtworkQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    XCTAssertEqualObjects([self hash:save],@"1bb719756c0361a602b2744193f6beec28c7a9ccb1dd046c268eb1ba513f4886");
    NSString* bundle=env[@"PROTECTOR_GALLERY_ART_BUNDLE"];
    XCTAssertEqualObjects([self hash:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]],
        @"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"]]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.container stringByAppendingPathComponent:@"Documents/gallery-art-ui-text.jsonl"]]);
    self.sourceKeys=[NSJSONSerialization JSONObjectWithData:[env[@"PROTECTOR_GALLERY_ART_KEYS"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    XCTAssertEqual(self.sourceKeys.count,48u);
    BOOL large=[env[@"PROTECTOR_GALLERY_ART_LARGE"] isEqual:@"1"];
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",large ? @"1.25" : @"1",
        @"-touch.swapped.v1",large ? @"YES" : @"NO",@"-touch.labels.v1",@"NO"];
    NSMutableDictionary* launch=[@{@"PROTECTOR_UI_TEXT_LOG":[self.container stringByAppendingPathComponent:@"Documents/gallery-art-ui-text.jsonl"]} mutableCopy];
    if(geometryRoute) launch[@"PROTECTOR_INTERFACE_AUDIT_FRAME"]=@"1";
    self.game.launchEnvironment=launch;
    [self.game launch];
    [self waitForLabel:@"Game title. Use Confirm to begin." timeout:90];
    [self pulse:@"a"];[self settle];[self pulse:@"down"];[self pulse:@"a"];
    [self sourceKey:@"Panel-LoadGame-3"];[self settle];[self pulse:@"a"];
    [self waitForLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:40];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
    [self.game.cells[@"open-game-menu"] tap];
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
    [self pulse:@"down"];[self pulse:@"down"];[self pulse:@"a"];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:30];[self pulse:@"a"];
    [self sourceKey:@"Panel-ExtrasScreen-1"];[self settle];[self pulse:@"a"];
    [self sourceKey:@"panel-UnlockableScreen-3"];[self settle];
    if(geometryRoute) {
        if([geometryRoute isEqual:@"full"]) { [self pulse:@"a"];[self settle]; }
        [self captureGeometry:geometryRoute];
        XCTAssertEqualObjects([self hash:save],@"1bb719756c0361a602b2744193f6beec28c7a9ccb1dd046c268eb1ba513f4886");
        return;
    }
    [self capture:@"gallery-art-grid-page1" art:nil];
    [self openArt:0 name:@"gallery-art-full-00"];
    for(NSUInteger i=0;i<3;i++) [self pulse:@"right"];
    [self openArt:3 name:@"gallery-art-full-03"];
    for(NSUInteger i=0;i<3;i++) [self pulse:@"right"];
    [self settle];[self capture:@"gallery-art-grid-page2" art:nil];
    for(NSUInteger i=0;i<4;i++) [self pulse:@"right"];
    [self pulse:@"down"];[self openArt:22 name:@"gallery-art-full-22"];
    [self pulse:@"up"];for(NSUInteger i=0;i<2;i++) [self pulse:@"right"];
    [self settle];[self capture:@"gallery-art-grid-page3" art:nil];
    for(NSUInteger i=0;i<4;i++) [self pulse:@"right"];
    [self openArt:28 name:@"gallery-art-full-28"];
    for(NSUInteger i=0;i<2;i++) [self pulse:@"right"];
    [self settle];[self capture:@"gallery-art-grid-page4" art:nil];
    [self pulse:@"right"];[self pulse:@"down"];
    [self openArt:43 name:@"gallery-art-full-43"];
    for(NSUInteger i=0;i<3;i++) [self pulse:@"right"];
    [self openArt:46 name:@"gallery-art-full-46"];
    [self pulse:@"right"];[self openArt:47 name:@"gallery-art-full-47"];
    [self capture:@"gallery-art-grid-final" art:nil];
    [self pulse:@"b"];[self settle];[self capture:@"gallery-art-extras-return" art:nil];
    XCTAssertEqualObjects([self hash:save],@"1bb719756c0361a602b2744193f6beec28c7a9ccb1dd046c268eb1ba513f4886");
}
- (void)tearDown { [self.game terminate];[super tearDown]; }
@end
