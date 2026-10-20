#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// Source observation through ordinary input. The locked-browser case keeps an
// unmodified save. The separate unlocked observer requires the explicitly
// authorized disposable fixture; it never changes an existing save or script.
@interface ProtectorExtrasViewersSourceUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* container;
@property(nonatomic) NSString* commandPath;
@end

@implementation ProtectorExtrasViewersSourceUITests
- (NSDictionary*)json:(NSString*)path {
    NSData* data=[NSData dataWithContentsOfFile:path];
    id value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
- (NSString*)hash:(NSData*)data {
    if(!data) return @"missing";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString* value=[NSMutableString string];
    for(NSUInteger i=0;i<sizeof(digest);i++) [value appendFormat:@"%02x",digest[i]];
    return value;
}
- (void)settle {
    XCTestExpectation* settled=[self expectationWithDescription:@"source transition"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{[settled fulfill];});
    XCTAssertEqual([XCTWaiter waitForExpectations:@[settled] timeout:5],XCTWaiterResultCompleted);
}
- (void)waitForLabel:(NSString*)label timeout:(NSTimeInterval)timeout {
    XCTNSPredicateExpectation* expected=[[XCTNSPredicateExpectation alloc] initWithPredicate:
        [NSPredicate predicateWithFormat:@"label == %@",label] object:self.game.otherElements[@"translated-game-view"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expected] timeout:timeout],XCTWaiterResultCompleted);
}
- (void)waitForKey:(NSString*)key {
    NSString* path=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:30];
    while([deadline timeIntervalSinceNow]>0) {
        NSString* text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        for(NSString* line in [text componentsSeparatedByString:@"\n"]) {
            NSDictionary* row=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if([row[@"key"] isEqual:key]) return;
        }
        [NSThread sleepForTimeInterval:.1];
    }
    XCTFail(@"Source key %@ was not observed",key);
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
- (void)pulse:(NSString*)command { [self controller:command];[self controller:@"neutral"]; }
- (void)waitForContext:(NSString*)context {
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:30];
    while([deadline timeIntervalSinceNow]>0) {
        NSDictionary* receipt=[self json:[self.commandPath stringByAppendingString:@".receipt.json"]];
        if([receipt[@"control_context"] isEqual:context]) return;
        [NSThread sleepForTimeInterval:.1];
    }
    XCTFail(@"Expected live source context %@",context);
}
- (void)attach:(NSDictionary*)data name:(NSString*)name {
    XCTAttachment* attachment=[XCTAttachment attachmentWithData:
        [NSJSONSerialization dataWithJSONObject:data options:NSJSONWritingPrettyPrinted error:nil] uniformTypeIdentifier:@"public.json"];
    attachment.name=name;attachment.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:attachment];
}
- (void)capture:(NSString*)name {
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    NSString* path=[diagnostics stringByAppendingPathComponent:@"interactive-state.json"];
    NSDate* after=NSDate.date;NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:12];BOOL fresh=NO;
    // A short source film can end during a second five-second diagnostic wait.
    // The caller has just obtained a current active cinematic receipt here.
    if([name hasSuffix:@"-playback-native"]) fresh=YES;
    while(!fresh && [deadline timeIntervalSinceNow]>0) {
        NSDate* modified=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if(modified && [modified compare:after]==NSOrderedDescending) { fresh=YES;break; }
        [NSThread sleepForTimeInterval:.1];
    }
    XCTAssertTrue(fresh);
    NSDictionary* state=[self json:path];
    XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
    NSUInteger expectedEntries=(NSUInteger)[NSProcessInfo.processInfo.environment[@"PROTECTOR_ANIMATED_PACK_ENTRIES"] integerValue];
    XCTAssertEqual([state[@"texture_pack_entries"] unsignedIntegerValue],expectedEntries ? expectedEntries : 795u);
    NSDictionary* controls=[self json:[diagnostics stringByAppendingPathComponent:@"native-controls.json"]];
    if([NSProcessInfo.processInfo.environment[@"PROTECTOR_EXTRAS_NATIVE_QA"] boolValue]) {
        BOOL playback=[name hasSuffix:@"-playback-native"];
        BOOL viewer=[name hasSuffix:@"-full-view"] || [name hasSuffix:@"-left"];
        BOOL root=[name hasSuffix:@"-return"] && ![name hasSuffix:@"-grid-return"];
        XCTAssertEqualObjects(controls[@"control_context"],playback ? @"cinematic-ready" : viewer ? @"extras-viewer" : root ? @"extras-root" : @"extras-browser");
        if(!playback) {
            XCTAssertEqualObjects(state[@"native_gallery_layout"][@"enabled"],@YES);
            XCTAssertEqualObjects(state[@"native_gallery_layout"][@"extras_full_view"],@(viewer));
        } else {
            XCTAssertEqualObjects(state[@"source_cinematic"][@"active"],@YES);
            XCTAssertEqualObjects(state[@"native_gallery_layout"][@"enabled"],@YES);
            XCTAssertEqualObjects(state[@"native_gallery_layout"][@"extras_movie"],@YES);
            XCTAssertEqualObjects(state[@"native_gallery_layout"][@"art_canvases_unchanged"],@YES);
        }
        BOOL controller=[NSProcessInfo.processInfo.environment[@"PROTECTOR_NATIVE_QA_CONTROLLER"] boolValue];
        NSMutableArray* visible=[NSMutableArray array];
        for(NSDictionary* control in controls[@"controls"]) if(![control[@"hidden"] boolValue]) [visible addObject:control[@"id"]];
        if(controller) XCTAssertEqual(visible.count,0u);
        else if(viewer) XCTAssertEqualObjects(visible,(@[@"game-back"]));
        else if(playback) XCTAssertEqualObjects(visible,(@[@"game-action-2048"]));
        XCTAssertEqualObjects(controls[@"touch_held"],@0);
        XCTAssertEqualObjects(controls[@"manually_paused"],@NO);
    }
    if([NSProcessInfo.processInfo.environment[@"PROTECTOR_UPGRADE_NATIVE_QA"] boolValue] && [name hasPrefix:@"upgrade-native"]) {
        NSString* context=controls[@"control_context"];
        XCTAssertTrue([context isEqual:@"upgrade-menu"] || [context isEqual:@"upgrade-ready"]);
        BOOL ready=[context isEqual:@"upgrade-ready"];
        XCTAssertEqualObjects(state[@"native_upgrade_menu"][@"enabled"],@YES);
        XCTAssertEqualObjects(state[@"native_upgrade_menu"][@"layout_enabled"],@YES);
        XCTAssertEqualObjects(state[@"native_upgrade_menu"][@"ready"],@(ready));
        BOOL controller=[NSProcessInfo.processInfo.environment[@"PROTECTOR_NATIVE_QA_CONTROLLER"] boolValue];
        NSMutableArray* visible=[NSMutableArray array];
        for(NSDictionary* control in controls[@"controls"]) if(![control[@"hidden"] boolValue]) [visible addObject:control[@"id"]];
        NSArray* expected=controller ? @[] : ready ? @[@"game-action-2048",@"game-action-1",@"game-action-2"] : @[@"game-action-1",@"game-action-2"];
        XCTAssertEqualObjects(visible,expected);
        XCTAssertEqualObjects(controls[@"controller_continue_cue_visible"],@(controller && ready));
        XCTAssertEqualObjects(controls[@"touch_held"],@0);
    }
    if([NSProcessInfo.processInfo.environment[@"PROTECTOR_SECRETS_NATIVE_QA"] boolValue]) {
        BOOL options=![name hasSuffix:@"-return"] || [name hasSuffix:@"camera-return"] || [name hasSuffix:@"friendly-return"];
        XCTAssertEqualObjects(controls[@"control_context"],options ? @"extras-options" : @"extras-root");
        NSDictionary* layout=state[@"native_gallery_layout"];
        XCTAssertEqualObjects(layout[@"enabled"],@YES);
        XCTAssertEqualObjects(layout[@"extras_options"],@(options));
        XCTAssertEqualObjects(layout[@"source_vertices_immutable"],@YES);
        XCTAssertEqualObjects(layout[@"art_canvases_unchanged"],@YES);
        XCTAssertEqualObjects(controls[@"touch_held"],@0);
        XCTAssertEqualObjects(controls[@"manually_paused"],@NO);
    }
    if([NSProcessInfo.processInfo.environment[@"PROTECTOR_EXTRAS_BROWSER_MATRIX"] boolValue]) {
        BOOL browser=![name hasSuffix:@"-return"];
        XCTAssertEqualObjects(controls[@"control_context"],browser ? @"extras-browser" : @"extras-root");
        NSDictionary* layout=state[@"native_gallery_layout"];
        XCTAssertEqualObjects(layout[@"enabled"],@YES);
        XCTAssertEqualObjects(layout[@"extras_browser"],@(browser));
        XCTAssertEqualObjects(layout[@"source_vertices_immutable"],@YES);
        XCTAssertEqualObjects(layout[@"art_canvases_unchanged"],@YES);
        XCTAssertEqualObjects(controls[@"touch_held"],@0);
        XCTAssertEqualObjects(controls[@"manually_paused"],@NO);
    }
    XCTAttachment* picture=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    picture.name=name;picture.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:picture];
    XCTAttachment* hierarchy=[XCTAttachment attachmentWithString:self.game.debugDescription];
    hierarchy.name=[name stringByAppendingString:@"-hierarchy"];hierarchy.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:hierarchy];
    [self attach:state name:[name stringByAppendingString:@"-renderer"]];
    [self attach:controls name:[name stringByAppendingString:@"-controls"]];
}
- (void)testObserveSelectedExtrasScreen {
    self.continueAfterFailure=NO;self.executionTimeAllowance=300;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_EXTRAS_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires isolated ExtrasViewersQA container");
    BOOL matrix=[env[@"PROTECTOR_EXTRAS_BROWSER_MATRIX"] boolValue];
    NSString* route=matrix ? @"movies" : env[@"PROTECTOR_EXTRAS_SOURCE_ROUTE"];
    NSArray* routes=@[@"movies",@"hero",@"enemy",@"boss"];
    NSUInteger selection=[routes indexOfObject:route];XCTAssertNotEqual(selection,NSNotFound);
    NSString* identity=@"house.machine.ProtectorNative.ExtrasViewersQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSString* bundle=env[@"PROTECTOR_EXTRAS_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        @"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"extras-source-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    BOOL swapped=[env[@"PROTECTOR_EXTRAS_BROWSER_SWAPPED"] boolValue];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",swapped ? @"1.35" : @"1",
        @"-touch.swapped.v1",swapped ? @"YES" : @"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",@"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1"};
    [self.game launch];[self waitForLabel:@"Game title. Use Confirm to begin." timeout:180];
    [self controller:@"neutral"];[self pulse:@"a"];[self settle];[self pulse:@"down"];[self pulse:@"a"];
    [self waitForKey:@"Panel-LoadGame-3"];[self settle];[self pulse:@"a"];
    [self waitForLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:40];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:6]);
    [self.game.cells[@"open-game-menu"] tap];
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
    [self pulse:@"down"];[self pulse:@"down"];[self pulse:@"a"];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:30];[self pulse:@"a"];
    [self waitForKey:@"Panel-ExtrasScreen-1"];[self settle];
    if(matrix) {
        NSArray* headers=@[@"Panel-UnlockableScreen-19",@"Panel-ExtrasScreen-7",@"Panel-ExtrasScreen-8",@"Panel-ExtrasScreen-4"];
        NSDictionary* touch=@{@"right":@"game-action-2",@"a":@"game-action-2048",@"b":@"game-back"};
        for(NSUInteger index=0;index<routes.count;index++) {
            NSString* prefix=[@"extras-browser-" stringByAppendingString:routes[index]];
            [self pulse:@"down"];[self pulse:@"a"];[self waitForKey:headers[index]];[self settle];
            [self capture:[prefix stringByAppendingString:@"-grid"]];
            for(NSString* command in @[@"right",@"a"]) {
                // The ordinary phone case uses real touch targets; tablet and
                // swapped cases additionally exercise the controller path.
                if([env[@"PROTECTOR_EXTRAS_BROWSER_CONTROLLER"] boolValue]) [self pulse:command];
                else { XCTAssertTrue(self.game.buttons[touch[command]].hittable);[self.game.buttons[touch[command]] tap]; }
                [self settle];
                [self capture:[prefix stringByAppendingString:[command isEqual:@"right"] ? @"-right" : @"-locked-confirm"]];
            }
            if([env[@"PROTECTOR_EXTRAS_BROWSER_CONTROLLER"] boolValue]) [self pulse:@"b"];
            else { XCTAssertTrue(self.game.buttons[touch[@"b"]].hittable);[self.game.buttons[touch[@"b"]] tap]; }
            [self settle];[self capture:[prefix stringByAppendingString:@"-return"]];
        }
        XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
        return;
    }
    for(NSUInteger i=0;i<=selection;i++) [self pulse:@"down"];
    [self pulse:@"a"];
    [self waitForKey:@"Panel-UnlockableScreen-3"];[self settle];
    [self capture:[@"extras-source-grid-" stringByAppendingString:route]];
    // Export the exact settled source overlay after the baseline native capture.
    NSString* audit=[diagnostics stringByAppendingPathComponent:@"interface-source/audit.json"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:audit]);
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:8]);
    XCUIElement* motion=self.game.switches[@"render.motion"];
    for(NSUInteger i=0;i<12 && !motion.hittable;i++) [settings swipeUp];
    XCTAssertTrue(motion.hittable);XCTAssertEqualObjects(motion.value,@"1");[motion tap];
    [self.game.buttons[@"Resume"] tap];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:15];
    while(![NSFileManager.defaultManager fileExistsAtPath:audit] && [deadline timeIntervalSinceNow]>0) [NSThread sleepForTimeInterval:.1];
    NSDictionary* source=[self json:audit];
    XCTAssertEqualObjects(source[@"schema"],@"protector-native.interface-source-audit/v1");
    XCTAssertEqualObjects(source[@"source"],@"translated_execution_callback");
    XCTAssertEqualObjects(source[@"omitted_orthographic_draws"],@0);
    XCTAssertEqualObjects(source[@"omitted_vertices"],@0);
    [self capture:[@"extras-source-audit-" stringByAppendingString:route]];
    [self pulse:@"b"];[self settle];
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
    [self capture:[@"extras-source-return-" stringByAppendingString:route]];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
}
- (NSDictionary*)waitForCinematic:(BOOL)active minimumFrame:(NSUInteger)frame {
    NSString* path=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/interactive-state.json"];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:40];
    while([deadline timeIntervalSinceNow]>0) {
        NSDictionary* state=[self json:path];NSDictionary* cinematic=state[@"source_cinematic"];
        if([cinematic isKindOfClass:NSDictionary.class] &&
           [cinematic[@"active"] boolValue]==active &&
           (!active || [cinematic[@"decoded_frame_zero_based"] unsignedIntegerValue]>=frame)) return cinematic;
        [NSThread sleepForTimeInterval:.1];
    }
    XCTFail(@"Expected cinematic active=%d at minimum frame %lu",active,(unsigned long)frame);
    return @{};
}
- (void)testObserveAuthorizedUnlockedExtras {
    self.continueAfterFailure=NO;self.executionTimeAllowance=600;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_EXTRAS_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires separate authorized ExtrasUnlockedQA container");
    NSString* identity=@"house.machine.ProtectorNative.ExtrasUnlockedQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],@"02c4c462a1308cf28281ec7f7ec45543eafb95b04dc3fcdb581a71f9584b72fe");
    NSString* bundle=env[@"PROTECTOR_EXTRAS_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        @"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"extras-unlocked-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    BOOL native=[env[@"PROTECTOR_EXTRAS_NATIVE_QA"] boolValue];
    BOOL controller=native && [env[@"PROTECTOR_NATIVE_QA_CONTROLLER"] boolValue];
    BOOL swapped=native && [env[@"PROTECTOR_NATIVE_QA_SWAPPED"] boolValue];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",controller ? @"YES" : @"NO",
        @"-touch.scale.v1",swapped ? @"1.25" : @"1",@"-touch.swapped.v1",swapped ? @"YES" : @"NO",@"-touch.labels.v1",@"NO"];
    NSMutableDictionary* launch=[@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1"} mutableCopy];
    BOOL fullAudit=[env[@"PROTECTOR_EXTRAS_SOURCE_AUDIT_FULL"] boolValue];
    if(fullAudit) launch[@"PROTECTOR_INTERFACE_AUDIT_FRAME"]=@"1";
    self.game.launchEnvironment=launch;
    [self.game launch];[self waitForLabel:@"Game title. Use Confirm to begin." timeout:180];
    [self controller:@"neutral"];[self pulse:@"a"];[self settle];[self pulse:@"down"];[self pulse:@"a"];
    [self waitForKey:@"Panel-LoadGame-3"];[self settle];[self pulse:@"a"];
    [self waitForLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:40];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:6]);
    [self.game.cells[@"open-game-menu"] tap];
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
    [self pulse:@"down"];[self pulse:@"down"];[self pulse:@"a"];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:30];[self pulse:@"a"];
    [self waitForKey:@"Panel-ExtrasScreen-1"];[self settle];
    NSArray* routes=@[@"movies",@"hero",@"enemy",@"boss"];
    NSArray* headers=@[@"Panel-UnlockableScreen-19",@"Panel-ExtrasScreen-7",@"Panel-ExtrasScreen-8",@"Panel-ExtrasScreen-4"];
    NSUInteger firstRoute=(NSUInteger)[env[@"PROTECTOR_EXTRAS_SOURCE_START"] integerValue];
    XCTAssertTrue(firstRoute==0 || firstRoute==1 || (firstRoute==2 && native) || (firstRoute==3 && fullAudit));
    // An unfinished movie observation must not prevent the separate character
    // source states from being captured, or force replay of its known frames.
    // Likewise native Enemy/Boss checks can retain completed Movie/Hero cases.
    for(NSUInteger i=0;i<firstRoute;i++) [self pulse:@"down"];
    for(NSUInteger index=firstRoute;index<routes.count;index++) {
        NSString* prefix=[@"extras-unlocked-" stringByAppendingString:routes[index]];
        [self pulse:@"down"];[self pulse:@"a"];[self waitForKey:headers[index]];
        // Root menu labels reuse these keys; seeing one in the accumulated
        // text trace does not mean a directly entered collection has loaded.
        if(native) [self waitForContext:@"extras-browser"];
        [self settle];
        [self capture:[prefix stringByAppendingString:@"-grid"]];
        [self pulse:@"a"];
        if(index==0) {
            if(native) {
                [self waitForLabel:@"Game cinematic. Use Skip to continue." timeout:20];
                // Capture the recognizable latter half, not the source's
                // bright transformation flash. This does not delay readiness.
                NSDictionary* first=[self waitForCinematic:YES minimumFrame:180];
                [self attach:first name:@"extras-native-movie-active"];
                [self capture:[prefix stringByAppendingString:@"-playback-native"]];
                if(controller) [self pulse:@"a"];
                else { XCTAssertTrue(self.game.buttons[@"game-action-2048"].hittable);[self.game.buttons[@"game-action-2048"] tap]; }
                [self waitForCinematic:NO minimumFrame:0];[self settle];
            } else {
            NSDictionary* first=[self waitForCinematic:YES minimumFrame:60];
            [self attach:first name:@"extras-unlocked-movie-first-state"];
            [self capture:[prefix stringByAppendingString:@"-playback-first"]];
            [self settle];
            NSDictionary* second=[self waitForCinematic:YES minimumFrame:[first[@"decoded_frame_zero_based"] unsignedIntegerValue]+1];
            XCTAssertEqualObjects(first[@"movie"],second[@"movie"]);
            [self attach:second name:@"extras-unlocked-movie-second-state"];
            [self capture:[prefix stringByAppendingString:@"-playback-later"]];
            [self waitForLabel:@"Game cinematic. Use Skip to continue." timeout:20];
            [self pulse:@"a"];[self waitForCinematic:NO minimumFrame:0];[self settle];
            }
        } else {
            if(native) [self waitForLabel:@"Character viewer. Drag Rotate to move the camera. Back returns to the collection." timeout:12];
            [self settle];[self capture:[prefix stringByAppendingString:@"-full-view"]];
            if(fullAudit) {
                NSString* audit=[diagnostics stringByAppendingPathComponent:@"interface-source/audit.json"];
                XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:audit]);
                [self.game.buttons[@"native-pause"] tap];
                XCUIElement* settings=self.game.tables[@"native-game-settings"];
                XCTAssertTrue([settings waitForExistenceWithTimeout:8]);
                XCUIElement* motion=self.game.switches[@"render.motion"];
                for(NSUInteger i=0;i<12 && !motion.hittable;i++) [settings swipeUp];
                XCTAssertTrue(motion.hittable);XCTAssertEqualObjects(motion.value,@"1");[motion tap];
                [self.game.buttons[@"Resume"] tap];
                NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:15];
                while(![NSFileManager.defaultManager fileExistsAtPath:audit] && [deadline timeIntervalSinceNow]>0)
                    [NSThread sleepForTimeInterval:.1];
                NSDictionary* source=[self json:audit];
                XCTAssertEqualObjects(source[@"source"],@"translated_execution_callback");
                XCTAssertEqualObjects(source[@"omitted_orthographic_draws"],@0);
                XCTAssertEqualObjects(source[@"omitted_vertices"],@0);
                [self capture:[prefix stringByAppendingString:@"-geometry-audit"]];
            } else {
                // CharacterViewerCamera reads the analogue axes, not grid d-pad.
                if(native && !controller) {
                    XCUIElement* stick=[self.game descendantsMatchingType:XCUIElementTypeAny][@"game-move"];
                    XCTAssertTrue(stick.hittable);XCTAssertEqualObjects(stick.label,@"Rotate character");
                    XCUICoordinate* start=[stick coordinateWithNormalizedOffset:CGVectorMake(.5,.5)];
                    XCUICoordinate* end=[stick coordinateWithNormalizedOffset:CGVectorMake(.12,.5)];
                    [start pressForDuration:.1 thenDragToCoordinate:end withVelocity:XCUIGestureVelocitySlow thenHoldForDuration:.6];
                } else { [self controller:@"stickleft"];[self settle];[self controller:@"neutral"]; }
                [self settle];[self capture:[prefix stringByAppendingString:@"-left"]];
            }
            if(native && !controller) { XCTAssertTrue(self.game.buttons[@"game-back"].hittable);[self.game.buttons[@"game-back"] tap]; }
            else [self pulse:@"b"];
            [self settle];
        }
        [self capture:[prefix stringByAppendingString:@"-grid-return"]];
        [self pulse:@"b"];[self settle];[self capture:[prefix stringByAppendingString:@"-return"]];
    }
    [self attach:@{@"save_sha256":[self hash:[NSData dataWithContentsOfFile:save]],
        @"boundary":@"Only the separately authorized disposable QA save may reflect ordinary source-owned viewing."}
        name:@"extras-unlocked-source-save-after"];
}
- (void)tearDown { [self.game terminate];[super tearDown]; }
@end
