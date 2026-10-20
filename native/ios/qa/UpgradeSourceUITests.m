#import <XCTest/XCTest.h>

// Read-only route observation in a copied QA save. No purchase input is sent.
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

@implementation ProtectorExtrasViewersSourceUITests (UpgradeSource)
- (void)testAuthorizedUpgradeAvailabilityWithoutPurchase {
    self.continueAfterFailure=NO;self.executionTimeAllowance=330;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTSkipIf(![env[@"PROTECTOR_UPGRADE_AVAILABILITY_AUTHORIZED"] isEqual:@"disposable-no-purchase"],
        @"Requires the explicit disposable Upgrade fixture and external save restoration");
    self.container=env[@"PROTECTOR_EXTRAS_SOURCE_CONTAINER"];
    NSString* identity=@"house.machine.ProtectorNative.ExtrasUnlockedQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    BOOL allForms=[env[@"PROTECTOR_UPGRADE_ALL_FORMS_QA"] boolValue];
    NSString* expected=allForms ? @"4f4da9d330d103af27f80f9aaec53b50cefc4060a821436395c304e0349d643e" :
        @"52af916c7dc2130b40cf61d5032e156cab7df604c53d586f8da8afdacaf365c7";
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],expected);
    NSString* bundle=env[@"PROTECTOR_EXTRAS_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        @"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"upgrade-authorized-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    BOOL native=[env[@"PROTECTOR_UPGRADE_NATIVE_QA"] boolValue];
    BOOL controller=native && [env[@"PROTECTOR_NATIVE_QA_CONTROLLER"] boolValue];
    BOOL swapped=native && [env[@"PROTECTOR_NATIVE_QA_SWAPPED"] boolValue];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",controller ? @"YES" : @"NO",
        @"-touch.scale.v1",swapped ? @"1.25" : @"1",@"-touch.swapped.v1",swapped ? @"YES" : @"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",
        @"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1"};
    [self.game launch];[self waitForLabel:@"Game title. Use Confirm to begin." timeout:180];
    [self controller:@"neutral"];[self pulse:@"a"];[self settle];[self pulse:@"down"];[self pulse:@"a"];
    [self waitForKey:@"Panel-LoadGame-3"];[self settle];[self pulse:@"a"];
    [self waitForLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:40];
    [self settle];[self pulse:@"a"];[self settle];[self pulse:@"a"];
    [self waitForLabel:@"Game cinematic. Use Skip to continue." timeout:30];[self pulse:@"a"];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:90];[self pulse:@"a"];
    // No more source game input after Ready. The original overlay decides
    // whether this save satisfies its Upgrade availability condition.
    [self waitForKey:@"Panel-UpgradeScreen-7"];[self settle];
    if(native) {
        [self capture:@"upgrade-native-entry"];
        NSMutableSet* availability=[NSMutableSet set];
        NSString* controls=[diagnostics stringByAppendingPathComponent:@"native-controls.json"];
        [availability addObject:[self json:controls][@"control_context"]];
        // Cycle source-available portraits: two in v2, all five plus an
        // unavailable Four Arms state in the separately pinned v3 fixture.
        // Never send A or a tap to
        // Unlock Move after Ready; the save is restored by the outer runner.
        for(NSUInteger i=0;i<5;++i) {
            if(controller) [self pulse:@"right"];
            else { XCTAssertTrue(self.game.buttons[@"game-action-2"].hittable);[self.game.buttons[@"game-action-2"] tap]; }
            [self settle];
            [self capture:[NSString stringWithFormat:@"upgrade-native-selection-%lu",(unsigned long)i+1]];
            [availability addObject:[self json:controls][@"control_context"]];
        }
        if(allForms) {
            [self waitForKey:@"Panel-UpgradeScreen-3"];
            XCTAssertTrue([availability containsObject:@"upgrade-menu"]);
            XCTAssertTrue([availability containsObject:@"upgrade-ready"]);
        }
        [self.game.buttons[@"native-pause"] tap];
        XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
        [self.game.buttons[@"Resume"] tap];[self settle];
        [self capture:@"upgrade-native-resumed"];
        XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],expected);
        return;
    }
    [self capture:@"upgrade-authorized-entry"];
    NSString* audit=[diagnostics stringByAppendingPathComponent:@"interface-source/audit.json"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:audit]);
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* table=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([table waitForExistenceWithTimeout:8]);
    XCUIElement* motion=self.game.switches[@"render.motion"];
    for(NSUInteger i=0;i<12 && !motion.hittable;i++)[table swipeUp];
    XCTAssertTrue(motion.hittable);XCTAssertEqualObjects(motion.value,@"1");[motion tap];
    [self.game.buttons[@"Resume"] tap];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:15];
    while(![NSFileManager.defaultManager fileExistsAtPath:audit] && [deadline timeIntervalSinceNow]>0)
        [NSThread sleepForTimeInterval:.1];
    NSDictionary* source=[self json:audit];
    XCTAssertEqualObjects(source[@"source"],@"translated_execution_callback");
    XCTAssertEqualObjects(source[@"omitted_orthographic_draws"],@0);
    XCTAssertEqualObjects(source[@"omitted_vertices"],@0);
    [self capture:@"upgrade-authorized-geometry-audit"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([table waitForExistenceWithTimeout:8]);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],expected);
}
- (void)testObserveUpgradeMenuWithoutPurchase {
    self.continueAfterFailure=NO;self.executionTimeAllowance=240;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_UPGRADE_QA_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires isolated Upgrade source observation");
    NSString* identity=@"house.machine.ProtectorNative.ExtrasViewersQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* bundle=env[@"PROTECTOR_UPGRADE_QA_BUNDLE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        env[@"PROTECTOR_UPGRADE_QA_CONFIG_SHA256"]);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSString* before=[self hash:[NSData dataWithContentsOfFile:save]];
    XCTAssertEqualObjects(before,@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"upgrade-source-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",
        @"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",@"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:120];
    [self controller:@"neutral"];[self pulse:@"a"];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:25];
    [self settle];[self capture:@"upgrade-route-before"];
    // The current native mapping sends the source Minus action from Options.
    // One observed pulse tests GameOverlay's source reference; no A follows it.
    [self pulse:@"options"];[self settle];[self capture:@"upgrade-route-options"];
    [self waitForKey:@"Panel-UpgradeScreen-7"];
    NSString* audit=[diagnostics stringByAppendingPathComponent:@"interface-source/audit.json"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:audit]);
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* table=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([table waitForExistenceWithTimeout:8]);
    XCUIElement* motion=self.game.switches[@"render.motion"];
    for(NSUInteger i=0;i<12 && !motion.hittable;i++)[table swipeUp];
    XCTAssertTrue(motion.hittable);XCTAssertEqualObjects(motion.value,@"1");[motion tap];
    [self.game.buttons[@"Resume"] tap];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:15];
    while(![NSFileManager.defaultManager fileExistsAtPath:audit] && [deadline timeIntervalSinceNow]>0)[NSThread sleepForTimeInterval:.1];
    NSDictionary* source=[self json:audit];
    XCTAssertEqualObjects(source[@"source"],@"translated_execution_callback");
    XCTAssertEqualObjects(source[@"omitted_orthographic_draws"],@0);
    XCTAssertEqualObjects(source[@"omitted_vertices"],@0);
    [self settle];[self capture:@"upgrade-source-audit"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],before);
}
@end
