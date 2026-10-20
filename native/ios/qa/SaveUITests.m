#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// A separately installed SaveQA bundle uses the ordinary, unmodified source
// startup configuration. Never redirect or overwrite the controls QA saves.
@interface ProtectorSaveUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* textLogPath;
@property(nonatomic) NSString* containerPath;
@property(nonatomic) NSString* savePath;
@property(nonatomic) NSMutableArray<NSDictionary*>* saveStages;
@property(nonatomic) NSString* controllerPath;
@property(nonatomic) NSMutableArray<NSDictionary*>* controllerReceipts;
@end

@implementation ProtectorSaveUITests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    self.executionTimeAllowance = 600;
    const BOOL writeFailure = [self.name containsString:@"testObserveSaveWriteFailure"];
    NSString* identityExpected = writeFailure ? @"house.machine.ProtectorNative.SaveWriteFailureQA" :
        @"house.machine.ProtectorNative.SaveQA";
    self.containerPath = NSProcessInfo.processInfo.environment[writeFailure ?
        @"PROTECTOR_SAVE_WRITE_QA_CONTAINER" : @"PROTECTOR_SAVE_QA_CONTAINER"];
    XCTSkipIf(!self.containerPath.length, @"Save flow requires an explicitly selected isolated SaveQA container");
    XCTAssertTrue([self.containerPath hasPrefix:@"/"]);
    NSDictionary* identity = [NSDictionary dictionaryWithContentsOfFile:
        [self.containerPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    XCTAssertEqualObjects(identity[@"MCMMetadataIdentifier"], identityExpected);
    self.savePath = [self.containerPath stringByAppendingPathComponent:
        @"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    if (writeFailure || [self.name containsString:@"testCreateSaveViaReturnToMap"]) {
        NSData* prior = [NSData dataWithContentsOfFile:self.savePath];
        if (prior) XCTAssertEqualObjects([self hash:prior],
            @"1f042e294eae3f669e5bad7e0a63b56b7f7da19d88beeacc6a3426ba4fa7d273",
            @"Refuse to start New Game over an existing nonempty QA save");
    }
    self.saveStages = [NSMutableArray array];
    self.controllerReceipts = [NSMutableArray array];
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    self.game = [[XCUIApplication alloc] initWithBundleIdentifier:identityExpected];
    self.textLogPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"save-ui-text-%@.jsonl", NSUUID.UUID.UUIDString]];
    self.game.launchArguments = @[@"-touch.hideWithController.v1", @"NO"];
    self.game.launchEnvironment = @{@"PROTECTOR_UI_TEXT_LOG":self.textLogPath};
    if (writeFailure && [NSProcessInfo.processInfo.environment[@"PROTECTOR_SAVE_WRITE_QA_CONTROLLER"] isEqual:@"1"]) {
        self.controllerPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"save-write-controller-%@.json", NSUUID.UUID.UUIDString]];
        self.game.launchArguments = @[@"-touch.hideWithController.v1", @"YES"];
        self.game.launchEnvironment = @{@"PROTECTOR_UI_TEXT_LOG":self.textLogPath,
            @"PROTECTOR_CONTROLLER_QA":@"1", @"PROTECTOR_CONTROLLER_QA_PATH":self.controllerPath,
            @"PROTECTOR_CONTROLLER_QA_READBACK":@"1"};
    }
    [self.game launch];
    XCTAssertTrue([self.game.buttons[@"native-pause"] waitForExistenceWithTimeout:30]);
}
- (void)tearDown {
    // A rejected/moved container fails setup before the app is assigned. Keep
    // that primary diagnostic instead of adding a nil-attachment assertion.
    if (!self.game || !self.saveStages || !self.savePath.length) {
        [super tearDown];
        return;
    }
    [self capture:@"save-final-state"];
    [self recordSave:@"before-final-termination"];
    // Process termination is deliberate cold-reload setup, never clean-stop
    // proof. The save must already be durable before this happens.
    [self.game terminate];
    [self recordSave:@"after-final-termination"];
    NSData* stages = [NSJSONSerialization dataWithJSONObject:self.saveStages
        options:NSJSONWritingPrettyPrinted error:nil];
    XCTAttachment* receipt = [XCTAttachment attachmentWithData:stages uniformTypeIdentifier:@"public.json"];
    receipt.name = @"save-persistence-stages";
    receipt.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:receipt];
    if (self.controllerReceipts.count) {
        NSData* commands = [NSJSONSerialization dataWithJSONObject:self.controllerReceipts
            options:NSJSONWritingPrettyPrinted error:nil];
        XCTAttachment* inputs = [XCTAttachment attachmentWithData:commands uniformTypeIdentifier:@"public.json"];
        inputs.name = @"save-controller-input-readback";
        inputs.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:inputs];
    }
    NSString* trace = [NSString stringWithContentsOfFile:self.textLogPath
        encoding:NSUTF8StringEncoding error:nil];
    if (trace.length) {
        XCTAttachment* attachment = [XCTAttachment attachmentWithString:trace];
        attachment.name = @"save-translated-ui-text";
        attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:attachment];
    }
    [super tearDown];
}
- (NSString*)hash:(NSData*)data {
    if (!data) return @"missing";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString* value = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); ++i) [value appendFormat:@"%02x", digest[i]];
    return value;
}
- (NSData*)recordSave:(NSString*)stage {
    NSData* current = [NSData dataWithContentsOfFile:self.savePath];
    NSData* previous = [NSData dataWithContentsOfFile:[self.savePath stringByAppendingString:@".previous"]];
    NSData* stateData = [NSData dataWithContentsOfFile:[self.containerPath
        stringByAppendingPathComponent:@"Documents/Diagnostics/interactive-state.json"]];
    NSDictionary* state = stateData ? [NSJSONSerialization JSONObjectWithData:stateData options:0 error:nil] : @{};
    [self.saveStages addObject:@{@"stage":stage, @"saved_bytes":@(current.length),
        @"saved_sha256":[self hash:current], @"previous_bytes":@(previous.length),
        @"previous_sha256":[self hash:previous], @"diagnostic_snapshot":state ?: @{},
        @"observed_at":@([NSDate.date timeIntervalSince1970])}];
    if (current) {
        XCTAttachment* file = [XCTAttachment attachmentWithData:current uniformTypeIdentifier:@"public.data"];
        file.name = [stage stringByAppendingString:@"-SavedGames"];
        file.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:file];
    }
    return current;
}
- (void)capture:(NSString*)name {
    XCTAttachment* picture = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    picture.name = name;
    picture.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:picture];
    XCTAttachment* hierarchy = [XCTAttachment attachmentWithString:self.game.debugDescription];
    hierarchy.name = [name stringByAppendingString:@"-accessibility"];
    hierarchy.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:hierarchy];
}
- (void)settle:(NSTimeInterval)seconds {
    XCTestExpectation* delay = [self expectationWithDescription:@"source animation settles"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ [delay fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[delay] timeout:seconds + 3], XCTWaiterResultCompleted);
}
- (void)waitForGameLabel:(NSString*)label timeout:(NSTimeInterval)timeout {
    XCTNSPredicateExpectation* expected = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"label == %@", label]
        object:self.game.otherElements[@"translated-game-view"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expected] timeout:timeout], XCTWaiterResultCompleted,
        @"Expected source context %@; got %@", label, self.game.debugDescription);
}
- (void)controllerCommand:(NSString*)command {
    NSString* identifier = NSUUID.UUID.UUIDString;
    NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"id":identifier,@"command":command} options:0 error:nil];
    XCTAssertTrue([data writeToFile:self.controllerPath options:NSDataWritingAtomic error:nil]);
    // XCTest's predicate waiter polls too slowly for a held direction: it
    // prolonged a pulse into source-menu repeat and selected Keep Playing.
    // Match the existing controller QA transport's bounded fast receipt poll.
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (deadline.timeIntervalSinceNow > 0) {
        NSData* receipt = [NSData dataWithContentsOfFile:[self.controllerPath stringByAppendingString:@".receipt.json"]];
        NSDictionary* value = receipt ? [NSJSONSerialization JSONObjectWithData:receipt options:0 error:nil] : nil;
        if ([value[@"command_id"] isEqual:identifier]) {
            [self.controllerReceipts addObject:@{@"phase":@"received", @"snapshot":value}];
            [self settle:.12];
            NSData* settledData = [NSData dataWithContentsOfFile:
                [self.controllerPath stringByAppendingString:@".receipt.json"]];
            NSDictionary* settled = settledData ? [NSJSONSerialization JSONObjectWithData:settledData options:0 error:nil] : nil;
            if (settled) [self.controllerReceipts addObject:@{@"phase":@"settled", @"snapshot":settled}];
            return;
        }
        [NSThread sleepForTimeInterval:.02];
    }
    XCTFail(@"Controller snapshot command was not received: %@", command);
}
- (void)sourceAction:(NSString*)identifier {
    if (!self.controllerPath) { [self.game.buttons[identifier] tap]; return; }
    NSString* command = [identifier isEqual:@"game-action-2048"] ? @"a" :
        [identifier isEqual:@"game-action-4"] ? @"down" : nil;
    XCTAssertNotNil(command);
    [self controllerCommand:@"neutral"];
    // UIKit gestures can briefly deactivate the app. A received snapshot is
    // not delivered guest input: reactivation deliberately requires neutral.
    // Wait for a fresh, active neutral guest sample before starting the pulse.
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    BOOL ready = NO;
    while (deadline.timeIntervalSinceNow > 0) {
        NSData* data = [NSData dataWithContentsOfFile:[self.controllerPath stringByAppendingString:@".receipt.json"]];
        NSDictionary* value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        ready = [value[@"command"] isEqual:@"neutral"] && value[@"application_state"] &&
            [value[@"application_state"] integerValue] == 0 &&
            ![value[@"host_paused"] boolValue] && ![value[@"controller_needs_neutral"] boolValue] &&
            [value[@"input_samples"][@"last_hold"] unsignedIntValue] == 0;
        if (ready) {
            [self.controllerReceipts addObject:@{@"phase":@"ready-for-source-action", @"snapshot":value}];
            break;
        }
        [NSThread sleepForTimeInterval:.02];
    }
    XCTAssertTrue(ready, @"Require active, resumed, neutral controller input before a source action");
    [self controllerCommand:command];
    [self controllerCommand:@"neutral"];
}
- (void)beginNewGame {
    [self waitForGameLabel:@"Game title. Use Confirm to begin." timeout:90];
    [self capture:@"save-title"];
    [self sourceAction:@"game-action-2048"];
    [self waitForGameLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:10];
    [self settle:2];
    [self capture:@"save-main-new-game-selected"];
    [self sourceAction:@"game-action-2048"];
    [self settle:2];
    [self capture:@"save-difficulty"];
    [self sourceAction:@"game-action-2048"];
    [self settle:2];
    [self capture:@"save-fresh-slots"];
    [self sourceAction:@"game-action-2048"];
    [self settle:5];
    [self capture:@"save-selected-fresh-slot"];
}
- (void)testCreateSaveViaReturnToMap {
    [self beginNewGame];
    NSData* empty = [self recordSave:@"new-game-selected-before-save"];
    XCTAssertEqual(empty.length, 24504u);
    XCTAssertEqualObjects([self hash:empty], @"1f042e294eae3f669e5bad7e0a63b56b7f7da19d88beeacc6a3426ba4fa7d273");
    // Preserve the actual new-game cinematic. No level-selection shortcut,
    // time acceleration or guest-memory change is part of this test.
    [self waitForGameLabel:@"Game ready. Use Confirm to continue." timeout:160];
    [self capture:@"save-new-game-ready"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForGameLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:15];
    [self settle:1];
    [self capture:@"save-new-game-canyon"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
    [self.game.cells[@"open-game-menu"] tap];
    [self waitForGameLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:10];
    [self settle:1];
    [self.game.buttons[@"game-action-4"] tap];
    [self settle:.3];
    [self.game.buttons[@"game-action-4"] tap];
    [self settle:.3];
    [self capture:@"save-return-map-selected"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self settle:2];
    [self capture:@"save-return-map-confirmation"];
    [self.game.buttons[@"game-back"] tap];
    [self settle:1];
    [self capture:@"save-return-map-cancelled"];
    XCTAssertEqualObjects([self recordSave:@"cancel-does-not-save"], empty);
    [self.game.buttons[@"game-action-2048"] tap];
    [self settle:1];
    [self capture:@"save-return-map-confirmation-again"];
    [self.game.buttons[@"game-action-2048"] tap];
    NSPredicate* changed = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary* bindings) {
        (void)object; (void)bindings;
        NSData* current = [NSData dataWithContentsOfFile:self.savePath];
        return current.length == empty.length && ![current isEqualToData:empty];
    }];
    XCTNSPredicateExpectation* committed = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:changed object:self];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[committed] timeout:45], XCTWaiterResultCompleted,
        @"Return to Map must durably write a guest-authored save before process termination");
    NSData* saved = [self recordSave:@"return-map-committed-before-termination"];
    XCTAssertNotEqualObjects(saved, empty);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:[self.savePath stringByAppendingString:@".previous"]], empty);
    [self settle:5];
    [self capture:@"save-returned-to-map"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
}
- (void)testObserveSaveWriteFailure {
    [self beginNewGame];
    NSData* baseline = [self recordSave:@"write-failure-before-gameplay"];
    XCTAssertEqualObjects([self hash:baseline],
        @"1f042e294eae3f669e5bad7e0a63b56b7f7da19d88beeacc6a3426ba4fa7d273");
    [self waitForGameLabel:@"Game ready. Use Confirm to continue." timeout:160];
    [self sourceAction:@"game-action-2048"];
    [self waitForGameLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:15];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
    [self.game.cells[@"open-game-menu"] tap];
    [self waitForGameLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:10];
    [self settle:1];
    [self sourceAction:@"game-action-4"]; [self settle:.3];
    [self sourceAction:@"game-action-4"]; [self settle:.3];
    [self sourceAction:@"game-action-2048"]; [self settle:1];
    [self capture:@"write-failure-before-return-map-confirm"];
    [self waitForGameLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:5];

    // A real host-side commit failure after gameplay has loaded. Only this
    // separate QA container is modified, and the existing backup is retained.
    NSFileManager* manager = NSFileManager.defaultManager;
    NSString* previous = [self.savePath stringByAppendingString:@".previous"];
    NSString* retained = [self.savePath stringByAppendingString:@".previous-preserved-for-write-qa"];
    XCTAssertFalse([manager fileExistsAtPath:retained]);
    NSData* previousBytes = [NSData dataWithContentsOfFile:previous];
    if (previousBytes) XCTAssertTrue([manager moveItemAtPath:previous toPath:retained error:nil]);
    XCTAssertTrue([manager createDirectoryAtPath:previous withIntermediateDirectories:NO attributes:nil error:nil]);
    XCTAssertTrue([baseline writeToFile:[previous stringByAppendingPathComponent:@"preserved-payload"] atomically:YES]);
    [self sourceAction:@"game-action-2048"];

    __block NSDictionary* status = nil;
    NSPredicate* failed = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary* bindings) {
        (void)object; (void)bindings;
        NSData* data = [NSData dataWithContentsOfFile:[self.containerPath stringByAppendingPathComponent:
            @"Documents/Diagnostics/interactive-state.json"]];
        NSDictionary* state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        status = state[@"save_status"];
        return ([status[@"pending_failure_mask"] unsignedIntValue] & 1u) != 0;
    }];
    XCTNSPredicateExpectation* observed = [[XCTNSPredicateExpectation alloc] initWithPredicate:failed object:self];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[observed] timeout:30], XCTWaiterResultCompleted);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:self.savePath], baseline);
    if (previousBytes) XCTAssertEqualObjects([NSData dataWithContentsOfFile:retained], previousBytes);
    [self waitForGameLabel:@"Game message. Use Continue to acknowledge." timeout:10];
    if (self.controllerPath) {
        XCTAssertFalse(self.game.buttons[@"game-action-2048"].exists);
        XCUIElement* cue = [[self.game descendantsMatchingType:XCUIElementTypeAny]
            matchingIdentifier:@"controller-continue-cue"].firstMatch;
        XCTAssertTrue(cue.exists);
        XCTAssertTrue([cue.label containsString:@"to continue"]);
    } else {
        XCTAssertEqualObjects(self.game.buttons[@"game-action-2048"].label, @"Continue");
        XCTAssertTrue(self.game.buttons[@"game-action-2048"].hittable);
    }
    XCTAssertFalse(self.game.otherElements[@"game-move"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-1024"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-16384"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-8192"].exists);
    XCTAssertFalse(self.game.buttons[@"game-back"].exists);
    XCTAssertTrue(self.game.staticTexts[@"native-runtime-status"].exists);
    XCTAssertTrue([self.game.staticTexts[@"native-runtime-status"].label containsString:@"Save failed"]);
    [self settle:2];
    [self capture:@"write-failure-original-flow"];
    XCUIElement* warning = self.game.scrollViews[@"native-runtime-status-scroll"];
    if (self.game.staticTexts[@"native-runtime-status"].frame.size.height > warning.frame.size.height) {
        [warning swipeUp];
        [self capture:@"write-failure-warning-scrolled"];
        // The first and final text are now captured. Do not swipe from this
        // top-edge viewport again: XCTest's generic downward swipe can invoke
        // the system notification gesture rather than just scroll the label.
    }
    [self recordSave:@"write-failure-original-flow-readback"];
    XCTAttachment* text = [XCTAttachment attachmentWithString:self.game.debugDescription];
    text.name = @"write-failure-original-accessibility";
    text.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:text];
    [self sourceAction:@"game-action-2048"];
    [self waitForGameLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:45];
    XCTAssertTrue(self.game.staticTexts[@"native-runtime-status"].exists,
        @"Acknowledging the game dialog must not clear an uncommitted-save warning");
    XCTAssertEqualObjects([self recordSave:@"write-failure-continued-unsaved"], baseline);
    [self capture:@"write-failure-continued-map"];
    // Restore only this known injected obstruction after observing Continue.
    NSString* obstruction = [previous stringByAppendingString:@"-write-qa-obstruction"];
    XCTAssertFalse([manager fileExistsAtPath:obstruction]);
    XCTAssertTrue([manager moveItemAtPath:previous toPath:obstruction error:nil]);
    if (previousBytes) XCTAssertTrue([manager moveItemAtPath:retained toPath:previous error:nil]);
    // Re-enter and leave via the original menu: the game itself issues the
    // next save. No host retry, RAM edit, save injection or campaign sample.
    [self sourceAction:@"game-action-2048"]; [self settle:2];
    [self sourceAction:@"game-action-2048"];
    XCUIElement* gameView = self.game.otherElements[@"translated-game-view"];
    NSPredicate* entered = [NSPredicate predicateWithFormat:@"label IN %@", @[
        @"Game cinematic. Use Skip to continue.", @"Game ready. Use Confirm to continue.",
        @"Game. Touch or drag to point. Attack confirms game menus."]];
    XCTNSPredicateExpectation* entering = [[XCTNSPredicateExpectation alloc] initWithPredicate:entered object:gameView];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[entering] timeout:160], XCTWaiterResultCompleted);
    if ([gameView.label isEqual:@"Game cinematic. Use Skip to continue."]) {
        [self sourceAction:@"game-action-2048"];
        [self waitForGameLabel:@"Game ready. Use Confirm to continue." timeout:120];
    }
    if ([gameView.label isEqual:@"Game ready. Use Confirm to continue."])
        [self sourceAction:@"game-action-2048"];
    [self waitForGameLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:15];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
    [self.game.cells[@"open-game-menu"] tap];
    [self waitForGameLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:10];
    [self settle:1];
    [self sourceAction:@"game-action-4"]; [self settle:.3];
    [self sourceAction:@"game-action-4"]; [self settle:.3];
    [self sourceAction:@"game-action-2048"]; [self settle:1];
    [self sourceAction:@"game-action-2048"];
    [self waitForGameLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:45];
    [self settle:6];
    XCTAssertFalse(self.game.staticTexts[@"native-runtime-status"].exists,
        @"A successful save must clear the live warning");
    NSData* recovered = [self recordSave:@"write-failure-recovered-save"];
    XCTAssertEqual(recovered.length, baseline.length);
    XCTAssertNotEqualObjects(recovered, baseline);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:previous], baseline);
    NSDictionary* recoveredStatus = self.saveStages.lastObject[@"diagnostic_snapshot"][@"save_status"];
    XCTAssertEqual([recoveredStatus[@"pending_failure_mask"] unsignedIntValue], 0u);
    XCTAssertEqual([recoveredStatus[@"failures"][0] unsignedLongLongValue], 1u);
    XCTAssertGreaterThanOrEqual([recoveredStatus[@"commits"][0] unsignedLongLongValue], 1u);
    [self capture:@"write-failure-recovered-map"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
}
- (NSDictionary*)waitForMapOceanDimmed:(BOOL)dimmed {
    __block NSDictionary* snapshot = nil;
    NSPredicate* predicate = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary* bindings) {
        (void)object; (void)bindings;
        NSData* data = [NSData dataWithContentsOfFile:[self.containerPath
            stringByAppendingPathComponent:@"Documents/Diagnostics/interactive-state.json"]];
        snapshot = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray* rgba = snapshot[@"world_map_ocean_rgba"];
        if (![snapshot[@"world_map_ocean_underlay"] boolValue] || rgba.count != 4) return NO;
        const double blue = [rgba[2] doubleValue];
        return dimmed ? blue > 0.48 && blue < 0.52 : blue > 0.99;
    }];
    XCTNSPredicateExpectation* expected = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:predicate object:self];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expected] timeout:15], XCTWaiterResultCompleted,
        @"Fresh map diagnostics must confirm the source-bound ocean and guest-owned zoom tint");
    return snapshot;
}
- (void)testWorldMapArtworkPresentation {
    NSString* manifestPath = NSProcessInfo.processInfo.environment[@"PROTECTOR_MAP_QA_MANIFEST"];
    NSString* expectedPack = NSProcessInfo.processInfo.environment[@"PROTECTOR_MAP_QA_PACK_ID"];
    XCTSkipIf(!manifestPath.length || !expectedPack.length,
        @"Map-art QA requires an explicit twenty-tile manifest and composed pack identity");
    NSData* manifestBytes = [NSData dataWithContentsOfFile:manifestPath];
    NSDictionary* manifest = manifestBytes ? [NSJSONSerialization JSONObjectWithData:manifestBytes options:0 error:nil] : nil;
    XCTAssertEqualObjects(manifest[@"schema"], @"protector-native.texture-pack/v2");
    NSArray* entries = manifest[@"entries"];
    XCTAssertEqual(entries.count, 20u);
    NSMutableSet<NSString*>* mapSources = [NSMutableSet set];
    for (NSDictionary* entry in entries) {
        NSDictionary* source = entry[@"source"];
        [mapSources addObject:[NSString stringWithFormat:@"%@x%@-%@", source[@"width"], source[@"height"], source[@"rgba8_sha256"]]];
    }
    XCTAssertEqual(mapSources.count, 20u);
    NSData* saved = [self recordSave:@"map-art-existing-save"];
    XCTAssertEqual(saved.length, 24504u);
    XCTAssertNotEqualObjects([self hash:saved], @"1f042e294eae3f669e5bad7e0a63b56b7f7da19d88beeacc6a3426ba4fa7d273");
    [self waitForGameLabel:@"Game title. Use Confirm to begin." timeout:90];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForGameLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:10];
    [self settle:2];
    [self.game.buttons[@"game-action-4"] tap];
    [self settle:.3];
    [self.game.buttons[@"game-action-2048"] tap];
    [self settle:2];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForGameLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:45];
    [self settle:2];
    XCTAssertTrue(self.game.buttons[@"game-action-2048"].hittable);
    XCTAssertTrue(self.game.buttons[@"game-back"].hittable);
    [self waitForMapOceanDimmed:NO];
    [self capture:@"map-art-overview"];
    [self recordSave:@"map-art-overview-state"];
    NSDictionary* state = self.saveStages.lastObject[@"diagnostic_snapshot"];
    XCTAssertEqualObjects(state[@"texture_pack_id"], expectedPack);
    XCTAssertEqualObjects(state[@"audio_output"], @"disabled");
    XCTAssertEqualObjects(state[@"restored_artwork_enabled"], @YES);
    XCTAssertTrue([mapSources isSubsetOfSet:[NSSet setWithArray:state[@"texture_pack_frame_sources"] ?: @[]]],
        @"The live translated map must use every newly restored tile");
    [self.game.buttons[@"game-action-2048"] tap];
    [self settle:2];
    [self waitForMapOceanDimmed:YES];
    [self capture:@"map-art-zoomed"];
    [self recordSave:@"map-art-zoomed-state"];
    [self.game.buttons[@"game-back"] tap];
    [self settle:2];
    [self waitForMapOceanDimmed:NO];
    [self capture:@"map-art-returned-overview"];
    XCTAssertEqualObjects([self recordSave:@"map-art-save-unchanged"], saved);
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
}
- (void)testColdContinueExistingSaveThroughMap {
    // Run only after testCreateSaveViaReturnToMap against the same isolated
    // container. This launch is a new process, not an in-memory load or reset.
    NSData* saved = [self recordSave:@"cold-launch-existing-save"];
    XCTAssertEqual(saved.length, 24504u);
    XCTAssertNotEqualObjects([self hash:saved], @"1f042e294eae3f669e5bad7e0a63b56b7f7da19d88beeacc6a3426ba4fa7d273");
    [self waitForGameLabel:@"Game title. Use Confirm to begin." timeout:90];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForGameLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:10];
    [self settle:2];
    [self.game.buttons[@"game-action-4"] tap];
    [self settle:.3];
    [self capture:@"cold-continue-selected"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self settle:2];
    [self capture:@"cold-continue-save-slot"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForGameLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:45];
    XCTAssertTrue(self.game.buttons[@"game-action-2048"].hittable);
    XCTAssertTrue(self.game.buttons[@"game-back"].hittable);
    XCTAssertTrue(self.game.otherElements[@"game-move"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-1024"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-16384"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-8192"].exists);
    [self settle:2];
    [self capture:@"cold-continue-world-map"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self settle:2];
    [self capture:@"cold-continue-map-zoomed"];
    [self.game.buttons[@"game-back"] tap];
    [self settle:2];
    [self capture:@"cold-continue-map-back"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self settle:2];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForGameLabel:@"Game cinematic. Use Skip to continue." timeout:20];
    XCTAssertEqualObjects(self.game.buttons[@"game-action-2048"].label, @"Skip cinematic");
    XCTAssertFalse(self.game.buttons[@"game-back"].exists);
    XCTAssertFalse(self.game.otherElements[@"game-move"].exists);
    [self capture:@"cold-continue-cinematic-native-skip"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForGameLabel:@"Game ready. Use Confirm to continue." timeout:90];
    [self capture:@"cold-continue-canyon-ready"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForGameLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:15];
    [self.game.buttons[@"game-action-8192"] tap];
    [self settle:.2];
    [self capture:@"cold-continue-canyon-jump"];
    XCTAssertEqualObjects([self recordSave:@"cold-continue-gameplay-save-unchanged"], saved);
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
}
@end
