#import <XCTest/XCTest.h>

// Reuse the isolated Extras source-observation harness. This category supplies
// a separate test selector so the established four-browser matrix stays fixed.
@interface ProtectorExtrasViewersSourceUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* container;
@property(nonatomic) NSString* commandPath;
- (NSDictionary*)json:(NSString*)path;
- (NSString*)hash:(NSData*)data;
- (void)settle;
- (void)waitForLabel:(NSString*)label timeout:(NSTimeInterval)timeout;
- (void)waitForKey:(NSString*)key;
- (void)controller:(NSString*)command;
- (void)pulse:(NSString*)command;
- (void)capture:(NSString*)name;
- (void)attach:(NSDictionary*)data name:(NSString*)name;
@end

@implementation ProtectorExtrasViewersSourceUITests (SecretsSource)
- (void)testAuthorizedCloseupCameraEffect {
    self.continueAfterFailure=NO;self.executionTimeAllowance=540;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTSkipIf(![env[@"PROTECTOR_CAMERA_ACTIVATION_AUTHORIZED"] isEqual:@"closeup-only-restore"],
        @"Requires explicit Closeup Camera-only authorization and external save restoration");
    self.container=env[@"PROTECTOR_EXTRAS_SOURCE_CONTAINER"];
    NSString* identity=@"house.machine.ProtectorNative.ExtrasUnlockedQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],
        @"02c4c462a1308cf28281ec7f7ec45543eafb95b04dc3fcdb581a71f9584b72fe");
    NSString* bundle=env[@"PROTECTOR_EXTRAS_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        @"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"camera-authorized-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",
        @"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1"};
    [self.game launch];[self waitForLabel:@"Game title. Use Confirm to begin." timeout:180];
    [self controller:@"neutral"];[self pulse:@"a"];[self settle];[self pulse:@"down"];[self pulse:@"a"];
    [self waitForKey:@"Panel-LoadGame-3"];[self settle];[self pulse:@"a"];
    NSString* map=@"Game map. Move to choose a location. Use Confirm or Back.";
    [self waitForLabel:map timeout:40];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
    [self.game.cells[@"open-game-menu"] tap];
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
    [self pulse:@"down"];[self pulse:@"down"];[self pulse:@"a"];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:30];[self pulse:@"a"];
    [self waitForKey:@"Panel-ExtrasScreen-1"];[self settle];
    for(NSUInteger index=0;index<5;index++) [self pulse:@"down"];
    [self pulse:@"a"];[self waitForKey:@"Panel-UnlockableScreen-8"];[self settle];
    [self pulse:@"down"];[self settle];[self capture:@"camera-authorized-secret-before"];
    // Exactly one activation: the source-owned second row, Closeup Camera.
    // No code submission, other secret activation or move purchase follows.
    [self pulse:@"a"];[self settle];[self capture:@"camera-authorized-secret-enabled"];
    [self pulse:@"b"];[self settle];[self pulse:@"b"];
    [self waitForLabel:map timeout:45];[self settle];
    [self pulse:@"a"];[self settle];[self pulse:@"a"];
    [self waitForLabel:@"Game cinematic. Use Skip to continue." timeout:30];[self pulse:@"a"];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:90];[self pulse:@"a"];
    NSString* playing=@"Game. Touch or drag to point. Attack confirms game menus.";
    [self waitForLabel:playing timeout:25];[self settle];[self capture:@"camera-authorized-game-before"];
    NSUInteger (^triggers)(void)=^NSUInteger {
        return [[self json:[diagnostics stringByAppendingPathComponent:@"interactive-state.json"]]
            [@"input_samples"][@"camera_trigger_count"] unsignedIntegerValue];
    };
    XCTAssertEqual(triggers(),0u);
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:8]);
    XCUIElement* camera=self.game.cells[@"change-game-camera"];
    [self cameraBringElement:camera.staticTexts[@"Camera"] intoTable:settings upward:YES];
    XCTAssertTrue(camera.hittable);[camera tap];
    [self waitForLabel:playing timeout:8];[self settle];[self capture:@"camera-authorized-native-toggle"];
    XCTAssertEqual(triggers(),1u);
    [self pulse:@"rstickpress"];[self settle];[self capture:@"camera-authorized-controller-return"];
    XCTAssertEqual(triggers(),2u);
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:8]);
    [self attach:@{@"authorization":@"closeup-only-restore",@"activation_inputs":@1,
        @"gameplay_camera_inputs":@(triggers()),@"save_before_external_restore":[self hash:[NSData dataWithContentsOfFile:save]],
        @"restoration":@"External wrapper restores every QA save file after termination, including on failure"}
        name:@"camera-authorized-action-receipt"];
}
- (void)cameraScrollTable:(XCUIElement*)table upward:(BOOL)upward {
    // Short, slow drags avoid flinging past an accessibility-sized row.
    XCUICoordinate* start=[table coordinateWithNormalizedOffset:CGVectorMake(.5,upward ? .75 : .40)];
    XCUICoordinate* end=[table coordinateWithNormalizedOffset:CGVectorMake(.5,upward ? .40 : .75)];
    [start pressForDuration:.1 thenDragToCoordinate:end withVelocity:XCUIGestureVelocitySlow thenHoldForDuration:.2];
}
- (void)cameraBringElement:(XCUIElement*)element intoTable:(XCUIElement*)table upward:(BOOL)upward {
    BOOL (^visible)(void)=^BOOL {
        CGFloat middle=CGRectGetMidY(element.frame);
        CGFloat top=CGRectGetMaxY(self.game.navigationBars.firstMatch.frame)+8;
        return element.hittable && middle>=top && middle<=CGRectGetMaxY(table.frame)-28;
    };
    for(NSUInteger i=0;i<40 && !visible();i++) {
        // Direction follows this known route. UIKit reports local label frames
        // for unmaterialized off-screen rows, so those cannot choose direction.
        [self cameraScrollTable:table upward:upward];
    }
    XCTAssertTrue(visible());
}
- (void)testObserveSecretsWithoutActivation {
    self.continueAfterFailure=NO;self.executionTimeAllowance=300;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_EXTRAS_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires isolated ExtrasViewersQA container");
    NSString* route=env[@"PROTECTOR_SECRETS_SOURCE_ROUTE"];
    NSArray* routes=@[@"secrets",@"code"];
    XCTAssertTrue([routes containsObject:route]);
    XCTAssertFalse([env[@"PROTECTOR_EXTRAS_BROWSER_MATRIX"] boolValue]);
    BOOL code=[route isEqual:@"code"];
    BOOL native=[env[@"PROTECTOR_SECRETS_NATIVE_QA"] boolValue];
    BOOL swapped=[env[@"PROTECTOR_SECRETS_SWAPPED"] boolValue];
    NSString* identity=@"house.machine.ProtectorNative.ExtrasViewersQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSString* original=@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0";
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],original);
    NSString* bundle=env[@"PROTECTOR_EXTRAS_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        @"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"secrets-source-" stringByAppendingString:NSUUID.UUID.UUIDString]];
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
    for(NSUInteger index=0;index<(code ? 6u : 5u);index++) [self pulse:@"down"];
    [self pulse:@"a"];
    // From here onward there is deliberately no Confirm/A: no activation and
    // no code submission. The header key for code also occurs in its parent,
    // so require its own action hint as the source-entry evidence instead.
    [self waitForKey:code ? @"Panel-UnlockableScreen-15" : @"Panel-UnlockableScreen-8"];
    [self settle];
    if(native) {
        XCTAssertFalse(code,@"Native matrix begins at Secrets, then visits adjacent Code once");
        [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
        NSDictionary* touch=@{@"up":@"game-action-8",@"down":@"game-action-4",@"left":@"game-action-1",
            @"right":@"game-action-2",@"b":@"game-back"};
        for(NSUInteger pass=0;pass<2;pass++) {
            BOOL codeScreen=pass==1;
            if(codeScreen) { [self pulse:@"down"];[self pulse:@"a"];[self waitForKey:@"Panel-UnlockableScreen-15"];[self settle]; }
            NSString* prefix=codeScreen ? @"secrets-native-code" : @"secrets-native-secrets";
            [self capture:[prefix stringByAppendingString:@"-entry"]];
            NSArray* commands=codeScreen ? @[@"right",@"up",@"down",@"left",@"b"] : @[@"down",@"down",@"up",@"up",@"b"];
            NSArray* stages=codeScreen ? @[@"right",@"symbol-up",@"symbol-down",@"left",@"return"] :
                @[@"camera-description",@"wrap-first",@"camera-return",@"friendly-return",@"return"];
            for(NSUInteger i=0;i<commands.count;i++) {
                if([env[@"PROTECTOR_SECRETS_CONTROLLER"] boolValue]) [self pulse:commands[i]];
                else { XCTAssertTrue(self.game.buttons[touch[commands[i]]].hittable);[self.game.buttons[touch[commands[i]]] tap]; }
                [self settle];[self capture:[prefix stringByAppendingFormat:@"-%@",stages[i]]];
            }
        }
        [self.game.buttons[@"native-pause"] tap];
        XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
        XCTAssertFalse(self.game.cells[@"change-game-camera"].exists);
        [self.game.buttons[@"Resume"] tap];
        XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],original);
        return;
    }
    NSString* prefix=[@"secrets-source-" stringByAppendingString:route];
    [self capture:[prefix stringByAppendingString:@"-entry"]];
    [self pulse:code ? @"right" : @"down"];[self settle];
    if(code && [env[@"PROTECTOR_SECRETS_SOURCE_SYMBOL_UP"] boolValue]) { [self pulse:@"up"];[self settle]; }
    [self capture:[prefix stringByAppendingString:@"-navigation"]];
    NSString* audit=[diagnostics stringByAppendingPathComponent:@"interface-source/audit.json"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:audit]);
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:8]);
    XCUIElement* motion=self.game.switches[@"render.motion"];
    for(NSUInteger index=0;index<12 && !motion.hittable;index++) [settings swipeUp];
    XCTAssertTrue(motion.hittable);XCTAssertEqualObjects(motion.value,@"1");[motion tap];
    [self.game.buttons[@"Resume"] tap];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:15];
    while(![NSFileManager.defaultManager fileExistsAtPath:audit] && [deadline timeIntervalSinceNow]>0) [NSThread sleepForTimeInterval:.1];
    NSDictionary* source=[self json:audit];
    XCTAssertEqualObjects(source[@"schema"],@"protector-native.interface-source-audit/v1");
    XCTAssertEqualObjects(source[@"source"],@"translated_execution_callback");
    XCTAssertEqualObjects(source[@"omitted_orthographic_draws"],@0);
    XCTAssertEqualObjects(source[@"omitted_vertices"],@0);
    [self capture:[prefix stringByAppendingString:@"-audit"]];
    [self pulse:@"b"];[self settle];
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
    [self capture:[prefix stringByAppendingString:@"-return"]];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],original);
}
- (void)testCameraInputWithoutSecretActivation {
    self.continueAfterFailure=NO;self.executionTimeAllowance=360;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_CAMERA_QA_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires the isolated direct-scene Camera input fixture");
    NSString* identity=@"house.machine.ProtectorNative.ExtrasViewersQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* bundle=env[@"PROTECTOR_CAMERA_QA_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        env[@"PROTECTOR_CAMERA_QA_CONFIG_SHA256"]);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSString* before=[self hash:[NSData dataWithContentsOfFile:save]];
    XCTAssertEqualObjects(before,@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    BOOL large=[env[@"PROTECTOR_CAMERA_QA_LARGE"] boolValue];
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"camera-input-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",
        @"-touch.swapped.v1",large ? @"YES" : @"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,
        @"PROTECTOR_CONTROLLER_QA_READBACK":@"1"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:120];
    [self controller:@"neutral"];[self pulse:@"a"];
    NSString* playing=@"Game. Touch or drag to point. Attack confirms game menus.";
    [self waitForLabel:playing timeout:25];[self capture:@"camera-input-before"];
    NSUInteger (^triggers)(void)=^NSUInteger {
        return [[self json:[diagnostics stringByAppendingPathComponent:@"interactive-state.json"]]
            [@"input_samples"][@"camera_trigger_count"] unsignedIntegerValue];
    };
    XCTAssertEqual(triggers(),0u);
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:8]);
    XCUIElement* camera=self.game.cells[@"change-game-camera"];
    [self cameraBringElement:camera.staticTexts[@"Camera"] intoTable:settings upward:YES];
    XCTAssertTrue(camera.hittable);[self capture:@"camera-native-pause"];
    if(large) {
        [self cameraScrollTable:settings upward:YES];[self cameraScrollTable:settings upward:YES];
        [self capture:@"camera-native-pause-lower"];
    }
    XCUIElement* guideButton=self.game.cells[@"open-controls-guide"];
    [self cameraBringElement:guideButton.staticTexts[@"Controls guide"] intoTable:settings upward:NO];
    XCTAssertTrue(guideButton.hittable);[guideButton tap];
    XCUIElement* guide=self.game.tables[@"native-controls-guide"];
    XCTAssertTrue([guide waitForExistenceWithTimeout:8]);
    [guide.buttons[@"Touch"] tap];
    XCUIElement* cameraGuide=guide.cells[@"controls-guide-2-4"];
    [self cameraBringElement:cameraGuide.staticTexts[@"Closeup camera"] intoTable:guide upward:YES];
    XCTAssertTrue(cameraGuide.hittable);XCTAssertTrue([cameraGuide.label containsString:@"open Pause and choose Camera"]);
    [self capture:@"camera-guide-touch"];
    if(large) {
        [self cameraScrollTable:guide upward:YES];[self cameraScrollTable:guide upward:YES];
        [self capture:@"camera-guide-touch-lower"];
    }
    [self pulse:@"right"];
    [self cameraBringElement:cameraGuide.staticTexts[@"Closeup camera"] intoTable:guide upward:YES];
    XCTAssertTrue(cameraGuide.hittable);XCTAssertTrue([cameraGuide.label containsString:@"press the right stick"]);
    [self capture:@"camera-guide-controller"];
    if(large) {
        [self cameraScrollTable:guide upward:YES];[self cameraScrollTable:guide upward:YES];
        [self capture:@"camera-guide-controller-lower"];
    }
    [self pulse:@"b"];XCTAssertTrue([settings waitForExistenceWithTimeout:8]);
    [self cameraBringElement:camera.staticTexts[@"Camera"] intoTable:settings upward:YES];
    XCTAssertTrue(camera.hittable);[camera tap];
    [self waitForLabel:playing timeout:8];[self capture:@"camera-input-native-action"];
    XCTAssertEqual(triggers(),1u);
    [self controller:@"neutral"];[self pulse:@"rstickpress"];[self capture:@"camera-input-stick-press"];
    XCTAssertEqual(triggers(),2u);
    [self.game.buttons[@"native-pause"] tap];XCTAssertTrue([settings waitForExistenceWithTimeout:8]);
    [self controller:@"neutral"];
    for(NSUInteger i=0;i<12 && !camera.selected;i++) [self pulse:@"down"];
    XCTAssertTrue(camera.selected);[self pulse:@"a"];
    [self waitForLabel:playing timeout:8];[self capture:@"camera-input-controller-action"];
    XCTAssertEqual(triggers(),3u);
    // A stick click held across native Pause/Resume cannot leak into play.
    [self.game.buttons[@"native-pause"] tap];XCTAssertTrue([settings waitForExistenceWithTimeout:8]);
    [self controller:@"rstickpress"];[self.game.buttons[@"Resume"] tap];
    [self waitForLabel:playing timeout:8];[self capture:@"camera-input-held-resume"];
    XCTAssertEqual(triggers(),3u);[self controller:@"neutral"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],before);
}
@end
