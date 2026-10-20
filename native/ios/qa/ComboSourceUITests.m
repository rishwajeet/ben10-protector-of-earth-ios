#import <XCTest/XCTest.h>

// Source-only reconnaissance of the in-game menu. The isolated direct-scene
// fixture changes startup configuration, never progression or unlock state.
@interface ProtectorExtrasViewersSourceUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* container;
@property(nonatomic) NSString* commandPath;
- (NSString*)hash:(NSData*)data;
- (NSDictionary*)json:(NSString*)path;
- (void)settle;
- (void)waitForLabel:(NSString*)label timeout:(NSTimeInterval)timeout;
- (void)waitForKey:(NSString*)key;
- (void)controller:(NSString*)command;
- (void)pulse:(NSString*)command;
- (void)capture:(NSString*)name;
@end

@implementation ProtectorExtrasViewersSourceUITests (ComboSource)
- (void)captureNativeCombo:(NSString*)name {
    [self capture:name];
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    NSDictionary* state=[self json:[diagnostics stringByAppendingPathComponent:@"interactive-state.json"]];
    NSDictionary* controls=[self json:[diagnostics stringByAppendingPathComponent:@"native-controls.json"]];
    BOOL menu=![name hasSuffix:@"-return"];
    XCTAssertEqualObjects(controls[@"control_context"],menu ? @"combo-list" : @"full-controls");
    XCTAssertEqualObjects(state[@"native_combo_list"][@"enabled"],@(menu));
    XCTAssertEqualObjects(state[@"native_combo_list"][@"layout_enabled"],@(menu));
    XCTAssertEqualObjects(controls[@"touch_held"],@0);
    if(menu) {
        XCTAssertEqualObjects(state[@"native_combo_list"][@"scheme"],@1);
        XCTAssertGreaterThan([state[@"native_combo_list"][@"glyphs"] unsignedIntegerValue],0u);
        XCTAssertEqualObjects(state[@"native_combo_list"][@"navigation_glyphs"],@2);
        NSMutableSet* labels=[NSMutableSet set];
        for(NSDictionary* control in controls[@"controls"])if(![control[@"hidden"] boolValue]) {
            [labels addObject:control[@"label"]];
            XCTAssertGreaterThanOrEqual([control[@"frame"][2] doubleValue],44.);
            XCTAssertGreaterThanOrEqual([control[@"frame"][3] doubleValue],44.);
        }
        XCTAssertEqualObjects(labels,([NSSet setWithArray:@[@"Previous combo list alien",@"Next combo list alien",@"Back in game menus"]]));
    }
}
- (void)testObserveGameplayMenuForComboRoute {
    self.continueAfterFailure=NO;self.executionTimeAllowance=240;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    BOOL native=[env[@"PROTECTOR_COMBO_NATIVE_QA"] boolValue];
    BOOL swapped=[env[@"PROTECTOR_COMBO_SWAPPED"] boolValue];
    BOOL controller=[env[@"PROTECTOR_COMBO_CONTROLLER"] boolValue];
    self.container=env[@"PROTECTOR_COMBO_QA_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires isolated Combo source fixture");
    NSString* identity=@"house.machine.ProtectorNative.ExtrasViewersQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* bundle=env[@"PROTECTOR_COMBO_QA_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        env[@"PROTECTOR_COMBO_QA_CONFIG_SHA256"]);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSString* before=[self hash:[NSData dataWithContentsOfFile:save]];
    XCTAssertEqualObjects(before,@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"]]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"combo-source-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",swapped?@"1.25":@"1",
        @"-touch.swapped.v1",swapped?@"YES":@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",@"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:120];
    [self controller:@"neutral"];[self pulse:@"a"];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:25];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
    [self.game.cells[@"open-game-menu"] tap];
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
    [self settle];if(!native)[self capture:@"combo-route-gameplay-menu"];
    if(native) {
        [self pulse:@"down"];[self pulse:@"a"];
        [self waitForLabel:@"Combo List. Choose an alien with left or right. Action icons match the native controls. Back returns to play." timeout:20];
        [self settle];[self captureNativeCombo:@"combo-native-entry"];
        NSArray* commands=@[@"right",@"right",@"left",@"left",@"b"];
        NSArray* stages=@[@"next",@"next-again",@"previous",@"previous-again",@"return"];
        NSDictionary* touch=@{@"right":@"game-action-2",@"left":@"game-action-1",@"b":@"game-back"};
        for(NSUInteger i=0;i<commands.count;++i) {
            if(controller)[self pulse:commands[i]];
            else {XCUIElement* button=self.game.buttons[touch[commands[i]]];XCTAssertTrue(button.hittable);[button tap];}
            [self settle];[self captureNativeCombo:[@"combo-native-" stringByAppendingString:stages[i]]];
        }
        [self.game.buttons[@"native-pause"] tap];
        XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
        XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],before);
        return;
    }
    if([env[@"PROTECTOR_COMBO_QA_OPEN"] boolValue]) {
        // The preceding source-route receipt and screenshot establish Combo
        // List as the second row. It is a read-only list, not the Upgrade Menu.
        [self pulse:@"down"];[self pulse:@"a"];
        [self waitForKey:@"Panel-UpgradeScreen-8"];[self settle];[self capture:@"combo-source-entry"];
        [self pulse:@"down"];[self settle];[self capture:@"combo-source-down"];
        [self pulse:@"right"];[self settle];[self capture:@"combo-source-right"];
        NSString* audit=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/interface-source/audit.json"];
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:audit]);
        [self.game.buttons[@"native-pause"] tap];
        XCUIElement* table=self.game.tables[@"native-game-settings"];
        XCTAssertTrue([table waitForExistenceWithTimeout:8]);
        XCUIElement* motion=self.game.switches[@"render.motion"];
        for(NSUInteger i=0;i<12 && !motion.hittable;i++) [table swipeUp];
        XCTAssertTrue(motion.hittable);XCTAssertEqualObjects(motion.value,@"1");[motion tap];
        [self.game.buttons[@"Resume"] tap];
        NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:15];
        while(![NSFileManager.defaultManager fileExistsAtPath:audit] && [deadline timeIntervalSinceNow]>0) [NSThread sleepForTimeInterval:.1];
        NSDictionary* source=[self json:audit];
        XCTAssertEqualObjects(source[@"source"],@"translated_execution_callback");
        XCTAssertEqualObjects(source[@"omitted_orthographic_draws"],@0);
        XCTAssertEqualObjects(source[@"omitted_vertices"],@0);
        [self capture:@"combo-source-audit"];
        [self pulse:@"b"];[self settle];[self capture:@"combo-source-return"];
    }
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],before);
}
@end
