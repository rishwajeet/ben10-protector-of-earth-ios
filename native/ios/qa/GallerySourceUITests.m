#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// Read-only route discovery from a copied, guest-authored QA save. No unlocks,
// cheat-code entry, source script writes or proprietary content in this file.
@interface ProtectorGallerySourceUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* container;
@property(nonatomic) NSString* commandPath;
@property(nonatomic) BOOL useController;
@end

@implementation ProtectorGallerySourceUITests
- (NSDictionary*)json:(NSString*)path {
    NSData* data=[NSData dataWithContentsOfFile:path];
    id value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
- (NSString*)hash:(NSData*)data {
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
    XCTestExpectation* settled=[self expectationWithDescription:@"source transition"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{[settled fulfill];});
    XCTAssertEqual([XCTWaiter waitForExpectations:@[settled] timeout:5],XCTWaiterResultCompleted);
}
- (void)capture:(NSString*)name {
    NSString* path=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/interactive-state.json"];
    NSDate* after=NSDate.date; NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:12]; BOOL fresh=NO;
    while([deadline timeIntervalSinceNow]>0) {
        NSDate* modified=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if(modified && [modified compare:after]==NSOrderedDescending) { fresh=YES; break; }
        [NSThread sleepForTimeInterval:.1];
    }
    XCTAssertTrue(fresh);
    NSDictionary* state=[self json:path];
    XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
    XCTAssertEqual([state[@"texture_pack_entries"] unsignedIntegerValue],727u);
    if([NSProcessInfo.processInfo.environment[@"PROTECTOR_GALLERY_LAYOUT_QA"] isEqual:@"1"]) {
        BOOL extras=[name isEqual:@"gallery-context-extras"] || [name isEqual:@"gallery-context-extras-return"];
        BOOL gallery=[name isEqual:@"gallery-context-grid"] || [name isEqual:@"gallery-context-grid-right"] ||
            [name isEqual:@"gallery-context-locked-confirm"];
        NSDictionary* layout=state[@"native_gallery_layout"];
        XCTAssertNotNil(layout);XCTAssertEqual([layout[@"enabled"] boolValue],extras || gallery);
        if(extras || gallery) {
            XCTAssertEqual([layout[@"gallery"] boolValue],gallery);
            XCTAssertEqualObjects(layout[@"source_vertices_immutable"],@YES);
            XCTAssertEqualObjects(layout[@"art_canvases_unchanged"],@YES);
        }
    }
    XCTAttachment* picture=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    picture.name=name;picture.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:picture];
    XCTAttachment* hierarchy=[XCTAttachment attachmentWithString:self.game.debugDescription];
    hierarchy.name=[name stringByAppendingString:@"-hierarchy"];hierarchy.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:hierarchy];
    XCTAttachment* snapshot=[XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil]
        uniformTypeIdentifier:@"public.json"];
    snapshot.name=[name stringByAppendingString:@"-renderer"];snapshot.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:snapshot];
    NSDictionary* controls=[self json:[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/native-controls.json"]];
    XCTAttachment* controlSnapshot=[XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:controls options:NSJSONWritingPrettyPrinted error:nil]
        uniformTypeIdentifier:@"public.json"];
    controlSnapshot.name=[name stringByAppendingString:@"-controls"];controlSnapshot.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:controlSnapshot];
}
- (void)controller:(NSString*)command {
    NSString* token=NSUUID.UUID.UUIDString;
    NSData* data=[NSJSONSerialization dataWithJSONObject:@{@"id":token,@"command":command} options:0 error:nil];
    XCTAssertTrue([data writeToFile:self.commandPath options:NSDataWritingAtomic error:nil]);
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while([deadline timeIntervalSinceNow]>0) {
        if([[self json:[self.commandPath stringByAppendingString:@".receipt.json"]][@"command_id"] isEqual:token]) {
            [NSThread sleepForTimeInterval:.2];return;
        }
        [NSThread sleepForTimeInterval:.05];
    }
    XCTFail(@"Controller snapshot was not consumed");
}
- (void)observeRoute:(BOOL)gallery {
    self.continueAfterFailure=NO;self.executionTimeAllowance=170;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_GALLERY_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires an isolated GallerySourceQA container");
    NSString* identity=@"house.machine.ProtectorNative.GallerySourceQA";
    NSDictionary* metadata=[NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]];
    XCTAssertEqualObjects(metadata[@"MCMMetadataIdentifier"],identity);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSString* bundle=env[@"PROTECTOR_GALLERY_SOURCE_BUNDLE"];
    XCTAssertTrue(bundle.length>0);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        @"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"]]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO"];
    NSMutableDictionary* launch=[@{@"PROTECTOR_UI_TEXT_LOG":[self.container stringByAppendingPathComponent:@"Documents/gallery-ui-text.jsonl"]} mutableCopy];
    if(gallery) {
        self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"gallery-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        launch[@"PROTECTOR_CONTROLLER_QA"]=@"1";launch[@"PROTECTOR_CONTROLLER_QA_PATH"]=self.commandPath;
        launch[@"PROTECTOR_CONTROLLER_QA_READBACK"]=@"1";
    }
    self.game.launchEnvironment=launch;
    [self.game launch];
    [self waitForLabel:@"Game title. Use Confirm to begin." timeout:90];
    [self.game.buttons[@"game-action-2048"] tap];[self settle];
    [self.game.buttons[@"game-action-4"] tap];[self.game.buttons[@"game-action-2048"] tap];[self settle];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:40];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:6]);
    [self.game.cells[@"open-game-menu"] tap];[self settle];
    if(gallery) {
        // The preceding source inspection observed Keep Playing, Options,
        // Extras, Quit Game in this exact order. Use only ordinary d-pad/A.
        [self controller:@"neutral"];
        for(NSUInteger i=0;i<2;i++) { [self controller:@"down"];[self controller:@"neutral"]; }
        [self controller:@"a"];[self controller:@"neutral"];[self settle];
        [self capture:@"gallery-source-extras"];
        [self controller:@"a"];[self controller:@"neutral"];[self settle];
        [self capture:@"gallery-source-concept-grid"];
        [self controller:@"a"];[self controller:@"neutral"];[self settle];
        [self capture:@"gallery-source-first-item-confirm"];
        [self controller:@"b"];[self controller:@"neutral"];[self settle];
        [self capture:@"gallery-source-back"];
    } else [self capture:@"gallery-source-map-menu"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
}
- (void)testReadOnlyMapMenu { [self observeRoute:NO]; }
- (void)testReadOnlyGallery { [self observeRoute:YES]; }
- (void)pulse:(NSString*)command {
    if(self.useController) { [self controller:command];[self controller:@"neutral"]; }
    else {
        NSDictionary* identifiers=@{@"a":@"game-action-2048",@"b":@"game-back",@"up":@"game-action-8",
            @"down":@"game-action-4",@"left":@"game-action-1",@"right":@"game-action-2"};
        XCTAssertNotNil(identifiers[command]);
        [self.game.buttons[identifiers[command]] tap];
    }
}
- (void)waitForSourceKey:(NSString*)key replacement:(NSString*)replacement {
    NSString* path=[self.container stringByAppendingPathComponent:@"Documents/gallery-ui-text.jsonl"];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:30];
    while([deadline timeIntervalSinceNow]>0) {
        NSString* text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        for(NSString* line in [text componentsSeparatedByString:@"\n"]) {
            NSDictionary* row=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if([row[@"key"] isEqual:key] && (!replacement || [row[@"replacement_latin1"] isEqual:replacement])) return;
        }
        [NSThread sleepForTimeInterval:.1];
    }
    XCTFail(@"Source key %@ with replacement %@ was not observed",key,replacement);
}
- (void)assertMenu {
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
    XCTAssertTrue(self.game.buttons[@"native-pause"].hittable);
    XCTAssertFalse(self.game.otherElements[@"game-move"].exists);
    for(NSString* identifier in @[@"game-action-1024",@"game-action-4096",@"game-action-8192",@"game-action-16384",
        @"game-action-32768",@"game-action-32",@"game-action-16",@"game-action-512",@"game-motion-interaction"])
        XCTAssertFalse(self.game.buttons[identifier].exists,@"Unexpected gameplay action: %@",identifier);
    NSDictionary* labels=@{@"game-action-2048":@"Confirm",@"game-back":@"Back in game menus",@"game-action-8":@"Menu up",
        @"game-action-4":@"Menu down",@"game-action-1":@"Menu left",@"game-action-2":@"Menu right"};
    for(NSString* identifier in labels) {
        XCUIElement* action=self.game.buttons[identifier];
        XCTAssertEqual(action.exists,!self.useController);
        if(!self.useController) { XCTAssertTrue(action.hittable);XCTAssertEqualObjects(action.label,labels[identifier]); }
    }
}
- (void)captureGeometrySource:(NSString*)route {
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    NSString* auditPath=[diagnostics stringByAppendingPathComponent:@"interface-source/audit.json"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:auditPath]);
    // The one-shot audit is dormant while smooth presentation is enabled.
    // Toggle it only after ordinary input reaches the exact settled screen.
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    XCUIElement* motion=self.game.switches[@"render.motion"];
    for(NSUInteger i=0;i<12 && !motion.hittable;++i) [settings swipeUp];
    XCTAssertTrue(motion.hittable);XCTAssertEqualObjects(motion.value,@"1");
    [motion tap];XCTAssertEqualObjects(motion.value,@"0");
    [self.game.buttons[@"Resume"] tap];[self assertMenu];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:15];
    while(![NSFileManager.defaultManager fileExistsAtPath:auditPath] && [deadline timeIntervalSinceNow]>0)
        [NSThread sleepForTimeInterval:.1];
    NSDictionary* audit=[self json:auditPath];
    XCTAssertEqualObjects(audit[@"schema"],@"protector-native.interface-source-audit/v1");
    XCTAssertEqualObjects(audit[@"source"],@"translated_execution_callback");
    XCTAssertGreaterThan([audit[@"draws"] count],0u);
    XCTAssertEqualObjects(audit[@"omitted_orthographic_draws"],@0);
    XCTAssertEqualObjects(audit[@"omitted_vertices"],@0);
    [self capture:[@"gallery-geometry-source-" stringByAppendingString:route]];
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
}
- (void)testQualifiedGalleryContext { [self runGalleryRoute:nil]; }
- (void)testGalleryGeometrySource {
    NSString* route=NSProcessInfo.processInfo.environment[@"PROTECTOR_GALLERY_GEOMETRY_ROUTE"];
    XCTSkipIf(!route.length,@"Select a bounded source geometry route");
    NSArray* routes=@[@"extras",@"grid"];
    XCTAssertTrue([routes containsObject:route]);
    [self runGalleryRoute:route];
}
- (void)runGalleryRoute:(NSString*)geometryRoute {
    self.continueAfterFailure=NO;self.executionTimeAllowance=220;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_GALLERY_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires the isolated GallerySourceQA container");
    NSString* identity=@"house.machine.ProtectorNative.GallerySourceQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSString* bundle=env[@"PROTECTOR_GALLERY_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        @"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"]]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.container stringByAppendingPathComponent:@"Documents/gallery-ui-text.jsonl"]]);
    self.useController=[env[@"PROTECTOR_GALLERY_SOURCE_CONTROLLER"] isEqual:@"1"];
    BOOL large=[env[@"PROTECTOR_GALLERY_SOURCE_LARGE"] isEqual:@"1"];
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",self.useController ? @"YES" : @"NO",
        @"-touch.scale.v1",large ? @"1.25" : @"1",@"-touch.swapped.v1",large ? @"YES" : @"NO",@"-touch.labels.v1",@"NO"];
    NSMutableDictionary* launch=[@{@"PROTECTOR_UI_TEXT_LOG":[self.container stringByAppendingPathComponent:@"Documents/gallery-ui-text.jsonl"]} mutableCopy];
    if(geometryRoute) launch[@"PROTECTOR_INTERFACE_AUDIT_FRAME"]=@"1";
    if(self.useController) {
        self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"gallery-context-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        launch[@"PROTECTOR_CONTROLLER_QA"]=@"1";launch[@"PROTECTOR_CONTROLLER_QA_PATH"]=self.commandPath;
        launch[@"PROTECTOR_CONTROLLER_QA_READBACK"]=@"1";
    }
    self.game.launchEnvironment=launch;[self.game launch];
    [self waitForLabel:@"Game title. Use Confirm to begin." timeout:90];
    if(self.useController) [self controller:@"neutral"];
    [self pulse:@"a"];[self settle];[self pulse:@"down"];[self pulse:@"a"];
    [self waitForSourceKey:@"Panel-LoadGame-3" replacement:nil];[self settle];[self pulse:@"a"];
    [self waitForLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:40];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:6]);
    [self.game.cells[@"open-game-menu"] tap];[self assertMenu];
    if(!geometryRoute) [self capture:@"gallery-context-map-menu"];
    [self pulse:@"down"];[self pulse:@"down"];[self pulse:@"a"];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:30];[self pulse:@"a"];
    [self waitForSourceKey:@"Panel-ExtrasScreen-1" replacement:nil];[self assertMenu];
    if([geometryRoute isEqual:@"extras"]) { [self settle];[self captureGeometrySource:geometryRoute];return; }
    if(!geometryRoute) [self capture:@"gallery-context-extras"];
    [self pulse:@"a"];[self waitForSourceKey:@"panel-UnlockableScreen-3" replacement:@"Back"];
    if([env[@"PROTECTOR_GALLERY_PAGE_SYMBOLS_QA"] isEqual:@"1"]) {
        [self waitForSourceKey:@"Panel-Buttons-7" replacement:@"<"];
        [self waitForSourceKey:@"Panel-Buttons-8" replacement:@">"];
    }
    [self assertMenu];
    if([geometryRoute isEqual:@"grid"]) { [self settle];[self captureGeometrySource:geometryRoute];return; }
    [self capture:@"gallery-context-grid"];
    [self pulse:@"right"];[self settle];[self assertMenu];[self capture:@"gallery-context-grid-right"];
    // This copied save exposes locked items. Confirm must not invent an unlock.
    [self pulse:@"a"];[self settle];[self assertMenu];[self capture:@"gallery-context-locked-confirm"];
    [self pulse:@"b"];[self settle];[self assertMenu];[self capture:@"gallery-context-extras-return"];
    [self pulse:@"b"];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:35];BOOL returned=NO;
    while([deadline timeIntervalSinceNow]>0) {
        NSString* label=self.game.otherElements[@"translated-game-view"].label;
        if([label isEqual:@"Game ready. Use Confirm to continue."]) [self pulse:@"a"];
        if([label isEqual:@"Game map. Move to choose a location. Use Confirm or Back."]) { returned=YES;break; }
        [NSThread sleepForTimeInterval:.1];
    }
    XCTAssertTrue(returned,@"Source Back must retire the gallery menu context and return to the map");
    [self capture:@"gallery-context-map-return"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
}
- (void)tearDown { [self.game terminate];[super tearDown]; }
@end
