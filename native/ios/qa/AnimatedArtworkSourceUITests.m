#import <XCTest/XCTest.h>

// Observe one existing form's materials in the isolated Canyon fixture. This
// is artwork discovery, not a repeated gameplay or performance acceptance pass.
@interface ProtectorExtrasViewersSourceUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* container;
@property(nonatomic) NSString* commandPath;
- (NSString*)hash:(NSData*)data;
- (NSDictionary*)json:(NSString*)path;
- (void)settle;
- (void)waitForLabel:(NSString*)label timeout:(NSTimeInterval)timeout;
- (void)controller:(NSString*)command;
- (void)pulse:(NSString*)command;
- (void)capture:(NSString*)name;
@end

@implementation ProtectorExtrasViewersSourceUITests (AnimatedArtworkSource)
- (void)testObserveCommonEffectMaterialsLiveContext {
    self.continueAfterFailure=NO;self.executionTimeAllowance=300;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    NSString* observerVersion=@"common-effects-live-context-v4";
    XCTAssertEqualObjects(env[@"PROTECTOR_COMMON_EFFECT_OBSERVER_VERSION"],observerVersion);
    self.container=env[@"PROTECTOR_ANIMATED_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires isolated common-effect source fixture");
    NSString* identity=@"house.machine.ProtectorNative.ExtrasViewersQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* bundle=env[@"PROTECTOR_ANIMATED_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        env[@"PROTECTOR_ANIMATED_SOURCE_CONFIG_SHA256"]);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"RestoredArt/pack.json"]]],
        env[@"PROTECTOR_ANIMATED_PACK_SHA256"]);
    NSArray* keys=[env[@"PROTECTOR_ANIMATED_COLOR_KEYS"] componentsSeparatedByString:@","];
    XCTAssertTrue(keys.count>0 && keys.count<=8);
    XCTAssertEqual([NSSet setWithArray:keys].count,keys.count);
    NSInteger steps=[env[@"PROTECTOR_COMMON_EFFECT_SELECTION_STEPS"] integerValue];
    XCTAssertTrue(steps>=1 && steps<=2);
    BOOL requireRestored=[env[@"PROTECTOR_COMMON_EFFECT_REQUIRE_RESTORED"] isEqual:@"1"];
    NSArray* addedKeys=requireRestored ? [env[@"PROTECTOR_COMMON_EFFECT_ADDED_KEYS"] componentsSeparatedByString:@","] : @[];
    if(requireRestored) {
        XCTAssertEqual(keys.count,3u);XCTAssertEqual(addedKeys.count,5u);
        XCTAssertEqualObjects(env[@"PROTECTOR_ANIMATED_PACK_ENTRIES"],@"812");
    }
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSString* before=[self hash:[NSData dataWithContentsOfFile:save]];
    XCTAssertEqualObjects(before,@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"common-effect-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",
        @"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",
        @"PROTECTOR_MATERIAL_AUDIT_KEYS":env[@"PROTECTOR_ANIMATED_COLOR_KEYS"]};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:120];
    [self controller:@"neutral"];[self pulse:@"a"];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:25];
    [self settle];[self capture:@"common-effect-before"];
    NSMutableArray* actions=[NSMutableArray arrayWithObject:@{@"id":@"game-action-8192",@"seconds":@0,@"name":@"initial-jump"}];
    for(NSInteger i=0;i<steps;i++)[actions addObject:@{@"id":@"game-action-2",@"seconds":@0,@"name":@"select-next"}];
    [actions addObjectsFromArray:@[
        @{@"id":@"game-action-8",@"seconds":@0,@"name":@"transform"},
        @{@"id":@"game-action-2048",@"seconds":@0,@"name":@"attack"},
        @{@"id":@"game-action-1024",@"seconds":@0,@"name":@"heavy"},
        @{@"id":@"game-action-16384",@"seconds":@1,@"name":@"block"},
        @{@"id":@"game-action-8192",@"seconds":@0,@"name":@"jump"},
        @{@"id":@"game-action-4",@"seconds":@1,@"name":@"special"},
        @{@"id":@"game-move",@"seconds":@.35,@"name":@"short-right"}]];
    NSMutableArray* inputs=[NSMutableArray array];
    for(NSUInteger i=0;i<actions.count;i++) {
        for(NSUInteger prompt=0;prompt<2;prompt++) {
            // The periodic JSON can still describe the just-dismissed lesson.
            // Re-read the live UI before deciding to issue another Confirm.
            NSString* liveLabel=self.game.otherElements[@"translated-game-view"].label;
            if(![liveLabel isEqual:@"Game instruction. Use Confirm to continue."])break;
            XCUIElement* confirm=self.game.buttons[@"game-action-2048"];
            if(![confirm.label isEqual:@"Confirm"]) {
                [self settle];continue;
            }
            XCTAssertTrue(confirm.hittable);
            [inputs addObject:@{@"name":@"tutorial-confirm",@"unix":@(NSDate.date.timeIntervalSince1970)}];
            [confirm tap];[self settle];
        }
        NSDictionary* action=actions[i];
        NSMutableDictionary* input=[action mutableCopy];input[@"unix"]=@(NSDate.date.timeIntervalSince1970);
        NSDictionary* pre=[self json:[diagnostics stringByAppendingPathComponent:@"native-controls.json"]];
        input[@"control_context_before"]=pre[@"control_context"] ?: NSNull.null;
        input[@"frame_before"]=[self json:[diagnostics stringByAppendingPathComponent:@"interactive-state.json"]][@"frame_index"] ?: NSNull.null;
        [inputs addObject:input];
        if([action[@"id"] isEqual:@"game-move"]) {
            XCUIElement* move=self.game.otherElements[@"game-move"];
            XCTAssertTrue(move.exists && move.hittable);CGRect frame=move.frame;
            XCTAssertFalse(CGRectIsEmpty(frame));
            XCUICoordinate* origin=[self.game coordinateWithNormalizedOffset:CGVectorMake(0,0)];
            XCUICoordinate* right=[origin coordinateWithOffset:CGVectorMake(CGRectGetMinX(frame)+CGRectGetWidth(frame)*.85,CGRectGetMidY(frame))];
            [right pressForDuration:[action[@"seconds"] doubleValue]];
        } else {
            XCUIElement* button=self.game.buttons[action[@"id"]];XCTAssertTrue(button.hittable);
            input[@"actual_label"]=button.label ?: @"";
            if([action[@"seconds"] doubleValue]>0)[button pressForDuration:[action[@"seconds"] doubleValue]];
            else [button tap];
        }
        input[@"end_unix"]=@(NSDate.date.timeIntervalSince1970);
        [self settle];[self capture:[NSString stringWithFormat:@"common-effect-%02lu-%@",(unsigned long)i,action[@"name"]]];
    }
    NSMutableArray* found=[NSMutableArray array];
    for(NSUInteger i=0;i<keys.count;i++) {
        NSString* path=[diagnostics stringByAppendingPathComponent:[NSString stringWithFormat:@"material-source-%02lu/inspection.json",(unsigned long)i]];
        if(![NSFileManager.defaultManager fileExistsAtPath:path])continue;
        NSDictionary* report=[self json:path];
        XCTAssertEqualObjects(report[@"source_key"],keys[i]);
        XCTAssertEqualObjects(report[@"source_vertices_immutable"],@YES);
        XCTAssertEqualObjects(report[@"guest_updates_during_inspection"],@0);
        XCTAssertEqual([report[@"samples"] count],2u);[found addObject:keys[i]];
        if(requireRestored) {
            NSDictionary* source=report[@"samples"][0][@"state"];
            NSDictionary* restored=report[@"samples"][1][@"state"];
            XCTAssertEqualObjects(source[@"restored_artwork_enabled"],@NO);
            XCTAssertEqualObjects(restored[@"restored_artwork_enabled"],@YES);
            XCTAssertEqualObjects(restored[@"texture_pack_entries"],@812);
            XCTAssertEqualObjects(restored[@"texture_pack_manifest_sha256"],env[@"PROTECTOR_ANIMATED_PACK_SHA256"]);
            XCTAssertEqualObjects(restored[@"smooth_motion_enabled"],@YES);
            XCTAssertEqualObjects(restored[@"audio_output"],@"disabled");
            NSMutableSet* materialKeys=[NSMutableSet set];
            for(NSDictionary* draw in report[@"draws"])
                for(NSDictionary* stage in draw[@"stages"])
                    if([addedKeys containsObject:stage[@"source_key"]])[materialKeys addObject:stage[@"source_key"]];
            XCTAssertTrue([materialKeys containsObject:keys[i]]);
            NSSet* replaced=[NSSet setWithArray:restored[@"texture_pack_frame_sources"]];
            XCTAssertTrue([materialKeys isSubsetOfSet:replaced],@"Every selected plane in the observed material must use the candidate.");
        }
    }
    if(requireRestored)XCTAssertEqualObjects([NSSet setWithArray:found],[NSSet setWithArray:keys]);
    NSDictionary* record=@{@"observer_version":observerVersion,@"requested_keys":keys,@"observed_keys":found,@"inputs":inputs,@"selection_steps":@(steps),
        @"scope":@"Bounded source discovery only; missing effects remain unobserved. No new artwork, unlock, purchase, combat objective or campaign acceptance."};
    XCTAttachment* receipt=[XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:record
        options:NSJSONWritingPrettyPrinted error:nil] uniformTypeIdentifier:@"public.json"];
    receipt.name=@"common-effect-source-observation";receipt.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:receipt];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],before);
}
- (void)testVerifyCombatFeedbackLayout {
    self.continueAfterFailure=NO;self.executionTimeAllowance=240;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_ANIMATED_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires isolated combat feedback fixture");
    NSString* identity=@"house.machine.ProtectorNative.ExtrasViewersQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* bundle=env[@"PROTECTOR_ANIMATED_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        env[@"PROTECTOR_ANIMATED_SOURCE_CONFIG_SHA256"]);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"RestoredArt/pack.json"]]],
        env[@"PROTECTOR_ANIMATED_PACK_SHA256"]);
    XCTAssertEqualObjects(env[@"PROTECTOR_ANIMATED_PACK_ENTRIES"],@"807");
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSString* before=[self hash:[NSData dataWithContentsOfFile:save]];
    XCTAssertEqualObjects(before,@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"combat-feedback-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    BOOL swapped=[env[@"PROTECTOR_COMBAT_FEEDBACK_SWAPPED"] isEqual:@"1"];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",swapped ? @"1.25" : @"1",
        @"-touch.swapped.v1",swapped ? @"YES" : @"NO",@"-touch.labels.v1",swapped ? @"YES" : @"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",
        @"PROTECTOR_COMBAT_FEEDBACK_PROOF":@"1"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:120];
    [self controller:@"neutral"];[self pulse:@"a"];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:25];
    [self settle];[self capture:@"combat-feedback-before"];
    [self.game.buttons[@"game-action-2"] tap];[self settle];
    [self.game.buttons[@"game-action-8"] tap];[self settle];
    NSMutableArray* inputs=[NSMutableArray array];
    for(NSString* action in @[@"game-action-1024",@"game-action-4"]) {
        NSDictionary* state=[self json:[diagnostics stringByAppendingPathComponent:@"native-controls.json"]];
        if([state[@"control_context"] isEqual:@"instruction-ready"]) {
            XCUIElement* confirm=self.game.buttons[@"game-action-2048"];
            XCTAssertEqualObjects(confirm.label,@"Confirm");[confirm tap];[self settle];
        }
        XCUIElement* button=self.game.buttons[action];XCTAssertTrue(button.hittable);
        NSMutableDictionary* input=[@{@"action":action,@"unix":@(NSDate.date.timeIntervalSince1970)} mutableCopy];
        [inputs addObject:input];
        if([action isEqual:@"game-action-4"])[button pressForDuration:2];else [button tap];
        input[@"end_unix"]=@(NSDate.date.timeIntervalSince1970);
        [self settle];
    }
    NSDictionary* proof=[self json:[diagnostics stringByAppendingPathComponent:@"combat-feedback/inspection.json"]];
    XCTAssertEqualObjects(proof[@"source"],@"translated_execution_callback");
    XCTAssertEqualObjects(proof[@"source_vertices_immutable"],@YES);
    XCTAssertEqualObjects(proof[@"guest_updates_during_inspection"],@0);
    XCTAssertEqual([proof[@"samples"] count],3u);
    for(NSUInteger i=0;i<3;++i) {
        NSDictionary* state=proof[@"samples"][i][@"state"];
        XCTAssertEqualObjects(state[@"native_combat_feedback"][@"enabled"],@YES);
        XCTAssertEqualObjects(state[@"native_combat_feedback"][@"layout_enabled"],@(i!=1));
        XCTAssertEqualObjects(state[@"smooth_motion_enabled"],@YES);
        XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
    }
    [self capture:@"combat-feedback-after"];
    XCTAttachment* receipt=[XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:
        @{@"inputs":inputs,@"swapped":@(swapped),@"scope":@"Native layout observation; no campaign or performance rerun"}
        options:NSJSONWritingPrettyPrinted error:nil] uniformTypeIdentifier:@"public.json"];
    receipt.name=@"combat-feedback-inputs";receipt.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:receipt];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],before);
}
- (void)testObserveCombatFeedbackSource {
    self.continueAfterFailure=NO;self.executionTimeAllowance=240;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_ANIMATED_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires isolated combat feedback source fixture");
    NSString* identity=@"house.machine.ProtectorNative.ExtrasViewersQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* bundle=env[@"PROTECTOR_ANIMATED_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        env[@"PROTECTOR_ANIMATED_SOURCE_CONFIG_SHA256"]);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"RestoredArt/pack.json"]]],
        env[@"PROTECTOR_ANIMATED_PACK_SHA256"]);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSString* before=[self hash:[NSData dataWithContentsOfFile:save]];
    XCTAssertEqualObjects(before,@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"combat-feedback-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",
        @"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",
        @"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1",@"PROTECTOR_INTERFACE_AUDIT_COMBAT_FEEDBACK":@"1"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:120];
    [self controller:@"neutral"];[self pulse:@"a"];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:25];
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* table=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([table waitForExistenceWithTimeout:8]);
    XCUIElement* motion=self.game.switches[@"render.motion"];
    for(NSUInteger i=0;i<12 && !motion.hittable;i++)[table swipeUp];
    XCTAssertTrue(motion.hittable);XCTAssertEqualObjects(motion.value,@"1");[motion tap];
    [self.game.buttons[@"Resume"] tap];[self settle];
    [self capture:@"combat-feedback-before"];
    [self.game.buttons[@"game-action-2"] tap];[self settle];
    [self.game.buttons[@"game-action-8"] tap];[self settle];
    NSArray* actions=@[@"game-action-1024",@"game-action-4"];
    for(NSString* action in actions) {
        NSDictionary* state=[self json:[diagnostics stringByAppendingPathComponent:@"native-controls.json"]];
        if([state[@"control_context"] isEqual:@"instruction-ready"]) {
            XCUIElement* confirm=self.game.buttons[@"game-action-2048"];
            XCTAssertEqualObjects(confirm.label,@"Confirm");[confirm tap];[self settle];
        }
        XCUIElement* button=self.game.buttons[action];XCTAssertTrue(button.hittable);
        if([action isEqual:@"game-action-4"])[button pressForDuration:2];else [button tap];
        [self settle];
    }
    NSString* audit=[diagnostics stringByAppendingPathComponent:@"interface-source/audit.json"];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:audit]);
    NSDictionary* source=[self json:audit];
    XCTAssertEqualObjects(source[@"source"],@"translated_execution_callback");
    XCTAssertEqualObjects(source[@"capture_combat_feedback"],@YES);
    [self capture:@"combat-feedback-after"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],before);
}
- (void)testObserveHeatblastAttackMaterials {
    [self observeHeatblastAttackMaterialsRequiringRestoration:NO];
}
- (void)testVerifyRestoredHeatblastAttackMaterials {
    [self observeHeatblastAttackMaterialsRequiringRestoration:YES];
}
- (void)observeHeatblastAttackMaterialsRequiringRestoration:(BOOL)requireRestoration {
    self.continueAfterFailure=NO;self.executionTimeAllowance=240;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_ANIMATED_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires isolated attack-material source fixture");
    NSString* identity=@"house.machine.ProtectorNative.ExtrasViewersQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* bundle=env[@"PROTECTOR_ANIMATED_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        env[@"PROTECTOR_ANIMATED_SOURCE_CONFIG_SHA256"]);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"RestoredArt/pack.json"]]],
        env[@"PROTECTOR_ANIMATED_PACK_SHA256"]);
    NSArray* keys=[env[@"PROTECTOR_ANIMATED_COLOR_KEYS"] componentsSeparatedByString:@","];
    XCTAssertEqual(keys.count,3u);
    NSString* waveMask=env[@"PROTECTOR_ANIMATED_WAVE_MASK_KEY"];
    if(requireRestoration) {
        XCTAssertEqualObjects(env[@"PROTECTOR_ANIMATED_PACK_ENTRIES"],@"807");
        XCTAssertTrue(waveMask.length>0);
    }
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSString* before=[self hash:[NSData dataWithContentsOfFile:save]];
    XCTAssertEqualObjects(before,@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"attack-material-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",
        @"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",
        @"PROTECTOR_MATERIAL_AUDIT_KEYS":env[@"PROTECTOR_ANIMATED_COLOR_KEYS"]};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:120];
    [self controller:@"neutral"];[self pulse:@"a"];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:25];
    [self settle];[self capture:@"attack-source-before"];
    [self.game.buttons[@"game-action-2"] tap];[self settle];
    [self.game.buttons[@"game-action-8"] tap];[self settle];[self capture:@"attack-source-heatblast"];
    // Bounded effect discovery. No movement, enemy objective, unlock, purchase,
    // combo acceptance or campaign progression is part of this observer.
    NSArray* actions=@[@"game-action-1024",@"game-action-4"];
    NSMutableArray* inputs=[NSMutableArray array];
    for(NSUInteger i=0;i<actions.count;i++) {
        for(NSUInteger prompt=0;prompt<2;prompt++) {
            NSDictionary* state=[self json:[diagnostics stringByAppendingPathComponent:@"native-controls.json"]];
            if(![state[@"control_context"] isEqual:@"instruction-ready"])break;
            XCUIElement* confirm=self.game.buttons[@"game-action-2048"];
            XCTAssertEqualObjects(confirm.label,@"Confirm");XCTAssertTrue(confirm.hittable);
            [self capture:[NSString stringWithFormat:@"attack-source-tutorial-%lu-%lu",(unsigned long)i,(unsigned long)prompt]];
            [inputs addObject:@{@"action":@"tutorial-confirm",@"unix":@(NSDate.date.timeIntervalSince1970)}];
            [confirm tap];[self settle];
        }
        XCUIElement* button=self.game.buttons[actions[i]];XCTAssertTrue(button.hittable);
        NSTimeInterval duration=i==1 ? (requireRestoration ? 2 : 1) : 0;
        NSMutableDictionary* input=[@{@"action":actions[i],@"unix":@(NSDate.date.timeIntervalSince1970),@"hold_seconds":@(duration)} mutableCopy];
        [inputs addObject:input];
        if(i==1)[button pressForDuration:duration];else [button tap];
        input[@"end_unix"]=@(NSDate.date.timeIntervalSince1970);
        [self settle];
        [self capture:[NSString stringWithFormat:@"attack-source-action-%lu",(unsigned long)i]];
    }
    NSMutableArray* found=[NSMutableArray array];
    for(NSUInteger i=0;i<keys.count;i++) {
        NSString* path=[diagnostics stringByAppendingPathComponent:[NSString stringWithFormat:@"material-source-%02lu/inspection.json",(unsigned long)i]];
        if(![NSFileManager.defaultManager fileExistsAtPath:path])continue;
        NSDictionary* report=[self json:path];
        XCTAssertEqualObjects(report[@"source_key"],keys[i]);
        XCTAssertEqualObjects(report[@"source_vertices_immutable"],@YES);
        XCTAssertEqualObjects(report[@"guest_updates_during_inspection"],@0);
        XCTAssertEqual([report[@"samples"] count],2u);
        if(requireRestoration) {
            NSDictionary* original=report[@"samples"][0][@"state"];
            NSDictionary* restored=report[@"samples"][1][@"state"];
            XCTAssertEqualObjects(original[@"restored_artwork_enabled"],@NO);
            XCTAssertEqualObjects(restored[@"restored_artwork_enabled"],@YES);
            XCTAssertEqual([restored[@"texture_pack_entries"] unsignedIntegerValue],807u);
            XCTAssertTrue([restored[@"texture_pack_frame_sources"] containsObject:keys[i]]);
            if(i==1) {
                BOOL paired=NO;
                for(NSDictionary* draw in report[@"draws"]) {
                    NSMutableSet* actual=[NSMutableSet set];
                    for(NSDictionary* stage in draw[@"stages"])
                        if([stage[@"source_key"] isKindOfClass:NSString.class])[actual addObject:stage[@"source_key"]];
                    if([actual containsObject:keys[i]] && [actual containsObject:waveMask])paired=YES;
                }
                XCTAssertTrue(paired,@"Wave color and soft mask must belong to the same material draw");
                XCTAssertTrue([restored[@"texture_pack_frame_sources"] containsObject:waveMask]);
            }
        }
        [found addObject:keys[i]];
    }
    if(requireRestoration)XCTAssertEqualObjects(found,keys);
    // A completed observation can legitimately find none of these source
    // materials. The record states that outcome; test success is not an art pass.
    NSDictionary* record=@{@"requested_keys":keys,@"observed_keys":found,@"inputs":inputs,
        @"scope":requireRestoration ? @"Three hand-flame materials and paired soft mask present and restored; visual review remains separate" :
            @"Source-material discovery only; no replacement or combat acceptance"};
    XCTAttachment* receipt=[XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:record
        options:NSJSONWritingPrettyPrinted error:nil] uniformTypeIdentifier:@"public.json"];
    receipt.name=@"attack-source-observation";receipt.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:receipt];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],before);
}
- (void)testObserveSelectedFormMaterials {
    self.continueAfterFailure=NO;self.executionTimeAllowance=240;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_ANIMATED_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires isolated animated-art source fixture");
    NSString* identity=@"house.machine.ProtectorNative.ExtrasViewersQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* bundle=env[@"PROTECTOR_ANIMATED_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        env[@"PROTECTOR_ANIMATED_SOURCE_CONFIG_SHA256"]);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSString* before=[self hash:[NSData dataWithContentsOfFile:save]];
    XCTAssertEqualObjects(before,@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"animated-source-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",
        @"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",
        @"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1",@"PROTECTOR_SCENE_EDGE_AUDIT":@"1"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:120];
    [self controller:@"neutral"];[self pulse:@"a"];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:25];
    [self settle];[self capture:@"animated-source-before"];
    XCUIElement* next=self.game.buttons[@"game-action-2"];
    XCUIElement* transform=self.game.buttons[@"game-action-8"];
    XCTAssertTrue(next.hittable && transform.hittable);
    [next tap];[self settle];[self capture:@"animated-source-selected"];
    [transform tap];[self settle];[self capture:@"animated-source-transformed"];
    NSString* audit=[diagnostics stringByAppendingPathComponent:@"interface-source/scene-edges.json"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:audit]);
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* table=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([table waitForExistenceWithTimeout:8]);
    XCUIElement* motion=self.game.switches[@"render.motion"];
    for(NSUInteger i=0;i<12 && !motion.hittable;i++)[table swipeUp];
    XCTAssertTrue(motion.hittable);XCTAssertEqualObjects(motion.value,@"1");[motion tap];
    [self.game.buttons[@"Resume"] tap];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    while(![NSFileManager.defaultManager fileExistsAtPath:audit] && [deadline timeIntervalSinceNow]>0)[NSThread sleepForTimeInterval:.1];
    NSDictionary* source=[self json:audit];
    XCTAssertEqualObjects(source[@"source"],@"translated_execution_callback");
    XCTAssertEqualObjects(source[@"source_vertices_immutable"],@YES);
    XCTAssertEqualObjects(source[@"guest_updates_during_inspection"],@0);
    BOOL canyonSkyQA=[env[@"PROTECTOR_CANYON_SKY_QA"] isEqual:@"1"];
    if(canyonSkyQA) {
        NSMutableSet* identities=[NSMutableSet set];
        for(NSDictionary* draw in source[@"identities"])
            if([draw[@"canyon_sky_identity"] unsignedIntegerValue])[identities addObject:draw[@"canyon_sky_identity"]];
        NSSet* expectedIdentities=[NSSet setWithArray:@[@1,@2]];
        XCTAssertEqualObjects(identities,expectedIdentities);
        XCTAssertEqual([source[@"samples"] count],6u);
        XCTAssertEqualObjects(source[@"samples"][0][@"state"][@"canyon_sky_extensions"],@1);
        XCTAssertEqualObjects(source[@"samples"][5][@"image"],@"scene-canyon-sky-baseline.png");
        XCTAssertEqualObjects(source[@"samples"][5][@"state"][@"canyon_sky_extensions"],@0);
    }
    [self settle];[self capture:@"animated-source-audit"];
    [self.game.buttons[@"native-pause"] tap];
    if(canyonSkyQA) {
        XCTAssertTrue([table waitForExistenceWithTimeout:8]);
        motion=self.game.switches[@"render.motion"];
        for(NSUInteger i=0;i<12 && !motion.hittable;i++)[table swipeUp];
        XCTAssertTrue(motion.hittable);XCTAssertEqualObjects(motion.value,@"0");[motion tap];
        [self.game.buttons[@"Resume"] tap];[self settle];
        [NSThread sleepForTimeInterval:2];
        [self capture:@"canyon-sky-live-smooth"];
        NSDictionary* live=[self json:[diagnostics stringByAppendingPathComponent:@"interactive-state.json"]];
        XCTAssertEqualObjects(live[@"smooth_motion_enabled"],@YES);
        double aspect=[live[@"presentation_aspect_ratio"] doubleValue];
        XCTAssertEqual([live[@"canyon_sky_extensions"] unsignedIntegerValue],aspect>4.0/3.0+1e-6 ? 1u : 0u);
        [self.game.buttons[@"native-pause"] tap];
    }
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],before);
}
- (void)testObservePairedFlameMaterials {
    self.continueAfterFailure=NO;self.executionTimeAllowance=240;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_ANIMATED_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires isolated flame-material fixture");
    NSString* identity=@"house.machine.ProtectorNative.ExtrasViewersQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* bundle=env[@"PROTECTOR_ANIMATED_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        env[@"PROTECTOR_ANIMATED_SOURCE_CONFIG_SHA256"]);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"RestoredArt/pack.json"]]],
        env[@"PROTECTOR_ANIMATED_PACK_SHA256"]);
    XCTAssertEqualObjects(env[@"PROTECTOR_ANIMATED_PACK_ENTRIES"],@"803");
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSString* before=[self hash:[NSData dataWithContentsOfFile:save]];
    XCTAssertEqualObjects(before,@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSArray* keys=[env[@"PROTECTOR_ANIMATED_COLOR_KEYS"] componentsSeparatedByString:@","];
    NSArray* masks=[env[@"PROTECTOR_ANIMATED_MASK_KEYS"] componentsSeparatedByString:@","];
    XCTAssertEqual(keys.count,4u);XCTAssertEqual(masks.count,4u);
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"flame-material-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",
        @"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",
        @"PROTECTOR_MATERIAL_AUDIT_KEYS":env[@"PROTECTOR_ANIMATED_COLOR_KEYS"]};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:120];
    [self controller:@"neutral"];[self pulse:@"a"];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:25];
    [self settle];[self capture:@"flame-material-before"];
    [self.game.buttons[@"game-action-2"] tap];[self settle];
    [self.game.buttons[@"game-action-8"] tap];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    for(NSUInteger i=0;i<4;i++) {
        NSString* path=[diagnostics stringByAppendingPathComponent:[NSString stringWithFormat:@"material-source-%02lu/inspection.json",(unsigned long)i]];
        while(![NSFileManager.defaultManager fileExistsAtPath:path] && [deadline timeIntervalSinceNow]>0)[NSThread sleepForTimeInterval:.1];
        NSDictionary* report=[self json:path];
        XCTAssertEqualObjects(report[@"source_key"],keys[i]);
        XCTAssertEqualObjects(report[@"source_vertices_immutable"],@YES);
        XCTAssertEqualObjects(report[@"guest_updates_during_inspection"],@0);
        XCTAssertEqual([report[@"samples"] count],2u);
        BOOL paired=NO;
        for(NSDictionary* draw in report[@"draws"]) {
            NSMutableSet* actual=[NSMutableSet set];
            for(NSDictionary* stage in draw[@"stages"]) if([stage[@"source_key"] isKindOfClass:NSString.class]) [actual addObject:stage[@"source_key"]];
            if([actual containsObject:keys[i]] && [actual containsObject:masks[i]]) paired=YES;
        }
        XCTAssertTrue(paired,@"Frame %lu must retain its paired color and coverage material",(unsigned long)i);
        NSDictionary* restored=report[@"samples"][1][@"state"];
        XCTAssertEqual([restored[@"texture_pack_entries"] unsignedIntegerValue],803u);
        XCTAssertEqualObjects(restored[@"restored_artwork_enabled"],@YES);
        XCTAssertEqualObjects(report[@"samples"][0][@"state"][@"restored_artwork_enabled"],@NO);
        XCTAssertTrue([restored[@"texture_pack_frame_sources"] containsObject:keys[i]]);
        XCTAssertTrue([restored[@"texture_pack_frame_sources"] containsObject:masks[i]]);
    }
    [self settle];[self capture:@"flame-material-transformed"];
    NSDictionary* start=[self json:[diagnostics stringByAppendingPathComponent:@"interactive-state.json"]];
    NSDate* motionStart=NSDate.date;
    XCTestExpectation* motion=[self expectationWithDescription:@"Bounded native flame animation"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,6*NSEC_PER_SEC),dispatch_get_main_queue(),^{[motion fulfill];});
    XCTAssertEqual([XCTWaiter waitForExpectations:@[motion] timeout:9],XCTWaiterResultCompleted);
    [self capture:@"flame-material-motion-end"];
    NSDictionary* end=[self json:[diagnostics stringByAppendingPathComponent:@"interactive-state.json"]];
    XCTAssertEqualObjects(start[@"smooth_motion_enabled"],@YES);
    XCTAssertEqualObjects(end[@"smooth_motion_enabled"],@YES);
    XCTAttachment* interval=[XCTAttachment attachmentWithData:[NSJSONSerialization dataWithJSONObject:
        @{@"start":start,@"end":end,@"start_unix":@([motionStart timeIntervalSince1970]),@"end_unix":@(NSDate.date.timeIntervalSince1970),
          @"scope":@"Idle flame-animation readback, not a 60 fps performance qualification"} options:NSJSONWritingPrettyPrinted error:nil]
        uniformTypeIdentifier:@"public.json"];
    interval.name=@"flame-material-motion-interval";interval.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:interval];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],before);
}
@end
