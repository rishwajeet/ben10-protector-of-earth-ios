#import <XCTest/XCTest.h>

@interface ProtectorControlUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* controllerCommandPath;
@property(nonatomic) NSString* uiTextLogPath;
@property(nonatomic) NSMutableArray<NSDictionary*>* controllerReadbackStages;
@end

@implementation ProtectorControlUITests
- (void)setUp {
    self.continueAfterFailure = NO;
    self.executionTimeAllowance = 90;
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    self.game = [[XCUIApplication alloc] initWithBundleIdentifier:@"house.machine.ProtectorNative.V1ControlsQA"];
    self.game.launchEnvironment = [self.name containsString:@"testMotionPresentationLifecycle"]
        ? @{@"PROTECTOR_EDITION":@"upgraded", @"PROTECTOR_MOTION_PRESENTATION":@"1"}
        : ([self.name containsString:@"testSingleEnhancedExperience"] ? @{@"PROTECTOR_EDITION":@"original"} : @{});
    // Simulator may inherit a host controller. This case explicitly qualifies
    // the touch surface; controller visibility is a separate test condition.
    self.game.launchArguments = @[@"-touch.hideWithController.v1", @"NO", @"-game.nextEdition.v1", @"0"];
    if ([self.name containsString:@"ControllerSnapshot"]) {
        self.controllerCommandPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"controller-qa-%@.json", NSUUID.UUID.UUIDString]];
        self.game.launchEnvironment = @{@"PROTECTOR_CONTROLLER_QA":@"1", @"PROTECTOR_CONTROLLER_QA_PATH":self.controllerCommandPath};
        self.game.launchArguments = @[@"-game.nextEdition.v1", @"0"];
        if ([self.name containsString:@"GameplayMappings"] || [self.name containsString:@"BackgroundLifecycle"]) {
            NSMutableDictionary* environment = [self.game.launchEnvironment mutableCopy];
            environment[@"PROTECTOR_CONTROLLER_QA_READBACK"] = @"1";
            self.game.launchEnvironment = environment;
            self.controllerReadbackStages = [NSMutableArray array];
            self.executionTimeAllowance = 180;
        }
    }
    if ([self.name containsString:@"testControllerSnapshotLoadingPrompt"] ||
        [self.name containsString:@"testControllerSnapshotNativeTutorialPrompt"])
        self.game.launchArguments = [self.game.launchArguments arrayByAddingObjectsFromArray:
            @[@"-touch.hideWithController.v1", @"YES"]];
    if ([self.name containsString:@"testFontArtworkTutorialAndPauseMenu"] ||
        [self.name containsString:@"LoadingPrompt"] || [self.name containsString:@"NativeTutorialPrompt"]) {
        self.uiTextLogPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"ui-text-qa-%@.jsonl", NSUUID.UUID.UUIDString]];
        NSMutableDictionary* environment = [self.game.launchEnvironment mutableCopy];
        environment[@"PROTECTOR_UI_TEXT_LOG"] = self.uiTextLogPath;
        self.game.launchEnvironment = environment;
    }
    [self.game launch];
    XCTAssertTrue([self.game.buttons[@"native-pause"] waitForExistenceWithTimeout:30]);
    [self capture:@"launch"];
}
- (void)tearDown {
    if (self.controllerReadbackStages) {
        [self recordControllerReadback:@"teardown"];
        NSData* data = [NSJSONSerialization dataWithJSONObject:self.controllerReadbackStages
            options:NSJSONWritingPrettyPrinted error:nil];
        XCTAttachment* attachment = [XCTAttachment attachmentWithData:data uniformTypeIdentifier:@"public.json"];
        attachment.name = @"controller-input-lifecycle-readback";
        attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:attachment];
    }
    // XCTest termination is explicitly not a clean-stop/runtime acceptance.
    [self.game terminate];
    if (self.uiTextLogPath) {
        NSString* trace = [NSString stringWithContentsOfFile:self.uiTextLogPath
            encoding:NSUTF8StringEncoding error:nil];
        if (trace.length) {
            XCTAttachment* attachment = [XCTAttachment attachmentWithString:trace];
            attachment.name = @"translated-ui-text-trace";
            attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
            [self addAttachment:attachment];
        }
    }
}
- (void)capture:(NSString*)name {
    // Application screenshot cropping is wrong for landscape on this
    // SDK/runtime combination. Capture the full display, as simctl io does.
    XCTAttachment* attachment = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    attachment.name = name;
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
    XCTAttachment* hierarchy = [XCTAttachment attachmentWithString:self.game.debugDescription];
    hierarchy.name = [name stringByAppendingString:@"-accessibility"];
    hierarchy.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:hierarchy];
}
- (void)controllerState:(NSString*)state {
    NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"id":NSUUID.UUID.UUIDString, @"command":state} options:0 error:nil];
    XCTAssertTrue([data writeToFile:self.controllerCommandPath options:NSDataWritingAtomic error:nil]);
}
- (NSDictionary*)controllerReadback {
    NSData* data = [NSData dataWithContentsOfFile:[self.controllerCommandPath stringByAppendingString:@".receipt.json"]];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
- (NSDictionary*)waitControllerReadback:(BOOL (^)(NSDictionary*))matches
        timeout:(NSTimeInterval)timeout label:(NSString*)label {
    NSPredicate* predicate = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary* bindings) {
        (void)object; (void)bindings;
        return matches([self controllerReadback]);
    }];
    XCTNSPredicateExpectation* expected = [[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:self];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expected] timeout:timeout], XCTWaiterResultCompleted,
        @"%@: %@", label, [self controllerReadback]);
    [self recordControllerReadback:label];
    return [self controllerReadback];
}
- (void)recordControllerReadback:(NSString*)stage {
    NSMutableDictionary* receipt = [[self controllerReadback] mutableCopy];
    receipt[@"stage"] = stage;
    [self.controllerReadbackStages addObject:receipt];
}
- (void)enterControllerGameplay {
    // Original source contexts govern readiness; no guest state is patched.
    for (NSUInteger i = 0; i < 5; ++i) {
        NSDictionary* state = [self waitControllerReadback:^BOOL(NSDictionary* value) {
            return [@[@"full-controls", @"confirm-prompt", @"instruction-ready", @"title"] containsObject:value[@"control_context"] ?: @""];
        } timeout:35 label:@"source-ready"];
        if ([state[@"control_context"] isEqual:@"full-controls"]) return;
        [self controllerPress:@"a"];
        [self waitForMotionObservation:.3];
    }
    XCTFail(@"Source did not enter gameplay: %@", [self controllerReadback]);
}
- (NSDictionary*)controllerCommand:(NSString*)command expectMask:(unsigned)mask {
    unsigned long long before = [[self controllerReadback][@"input_samples"][@"count"] unsignedLongLongValue];
    [self controllerState:command];
    return [self waitControllerReadback:^BOOL(NSDictionary* state) {
        NSDictionary* input = state[@"input_samples"];
        return [state[@"command"] isEqual:command] &&
            [input[@"count"] unsignedLongLongValue] > before + 1 &&
            [input[@"last_hold"] unsignedIntValue] == mask;
    } timeout:5 label:[@"delivered-" stringByAppendingString:command]];
}
- (void)controllerGameplayCommand:(NSString*)command expectMask:(unsigned)mask {
    // A source tutorial can arrive after readiness was observed. Preserve and
    // prove that interruption, release the held input, then dismiss the actual
    // source prompt. This is not a retry of an unexplained delivery failure.
    for (NSUInteger sourceTransition = 0; sourceTransition < 2; ++sourceTransition) {
        [self enterControllerGameplay];
        unsigned long long before = [[self controllerReadback][@"input_samples"][@"count"] unsignedLongLongValue];
        [self controllerState:command];
        NSDictionary* receipt = [self waitControllerReadback:^BOOL(NSDictionary* state) {
            NSDictionary* input = state[@"input_samples"];
            BOOL arrived = [state[@"command"] isEqual:command] &&
                [input[@"count"] unsignedLongLongValue] > before + 1;
            BOOL sourceInstruction = [state[@"control_context"] isEqual:@"instruction-ready"] &&
                [state[@"controller_needs_neutral"] boolValue] && [input[@"last_hold"] unsignedIntValue] == 0;
            return arrived && ([input[@"last_hold"] unsignedIntValue] == mask || sourceInstruction);
        } timeout:5 label:[@"mapping-or-source-interruption-" stringByAppendingString:command]];
        if ([receipt[@"input_samples"][@"last_hold"] unsignedIntValue] == mask) return;
        XCTAssertEqual(sourceTransition, 0u, @"More than one source interruption for %@", command);
        [self capture:[@"controller-mapping-source-interruption-" stringByAppendingString:command]];
        [self controllerCommand:@"neutral" expectMask:0];
    }
    XCTFail(@"Source interruption did not resolve for %@", command);
}
- (void)testControllerSnapshotGameplayMappings {
    [self enterControllerGameplay];
    [self capture:@"controller-map-gameplay"];
    NSArray* actions = @[@[@"a", @2048], @[@"b", @1024], @[@"x", @16384],
        @[@"y", @8192], @[@"lshoulder", @8192], @[@"left", @1],
        @[@"right", @2], @[@"down", @4], @[@"up", @8], @[@"options", @4096]];
    for (NSArray* action in actions) {
        [self controllerGameplayCommand:action[0] expectMask:[action[1] unsignedIntValue]];
        if ([action[0] isEqual:@"x"] || [action[0] isEqual:@"y"] || [action[0] isEqual:@"up"])
            [self capture:[@"controller-map-held-" stringByAppendingString:action[0]]];
        [self controllerCommand:@"neutral" expectMask:0];
    }
    [self enterControllerGameplay];
    for (NSString* command in @[@"rtrigger", @"ltrigger", @"triggers"]) {
        NSDictionary* initial = [self controllerReadback][@"input_samples"];
        [self controllerState:command];
        [self waitControllerReadback:^BOOL(NSDictionary* state) {
            NSDictionary* input = state[@"input_samples"];
            BOOL remote = [input[@"wiimote_motion_count"] unsignedLongLongValue] >
                [initial[@"wiimote_motion_count"] unsignedLongLongValue];
            BOOL extension = [input[@"nunchuk_motion_count"] unsignedLongLongValue] >
                [initial[@"nunchuk_motion_count"] unsignedLongLongValue];
            return [state[@"command"] isEqual:command] &&
                remote == ![command isEqual:@"ltrigger"] && extension == ![command isEqual:@"rtrigger"];
        } timeout:5 label:[@"motion-" stringByAppendingString:command]];
        [self controllerCommand:@"neutral" expectMask:0];
    }
    for (NSString* command in @[@"aimright", @"rshoulder"]) {
        [self controllerState:command];
        [self waitControllerReadback:^BOOL(NSDictionary* state) {
            NSDictionary* input = state[@"input_samples"];
            NSArray* pointer = input[@"last_pointer"];
            return [state[@"command"] isEqual:command] && [input[@"last_pointer_valid"] boolValue] &&
                fabs([pointer[0] doubleValue] - ([command isEqual:@"aimright"] ? .75 : 0)) < .01 &&
                fabs([pointer[1] doubleValue] - ([command isEqual:@"aimright"] ? -.5 : 0)) < .01;
        } timeout:5 label:[@"pointer-" stringByAppendingString:command]];
        [self controllerCommand:@"neutral" expectMask:0];
    }
    [self controllerState:@"stickleft"];
    [self waitControllerReadback:^BOOL(NSDictionary* state) {
        return [state[@"command"] isEqual:@"stickleft"] &&
            [state[@"input_samples"][@"last_stick"][0] doubleValue] < -.99;
    } timeout:5 label:@"movement-left"];
    [self controllerCommand:@"neutral" expectMask:0];
    [self capture:@"controller-map-final-gameplay"];
    [self controllerPress:@"menu"];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
}
- (void)testControllerSnapshotBackgroundLifecycle {
    [self enterControllerGameplay];
    NSString* held = @"x+stickleft+aimright+triggers";
    [self controllerCommand:held expectMask:16384];
    [self waitControllerReadback:^BOOL(NSDictionary* state) {
        NSDictionary* input = state[@"input_samples"];
        return [input[@"last_pointer_valid"] boolValue] &&
            [input[@"last_stick"][0] doubleValue] < -.99 &&
            [input[@"wiimote_motion_count"] unsignedLongLongValue] > 0 &&
            [input[@"nunchuk_motion_count"] unsignedLongLongValue] > 0;
    } timeout:5 label:@"held-before-background"];
    [self capture:@"lifecycle-held-before-home"];
    [XCUIDevice.sharedDevice pressButton:XCUIDeviceButtonHome];
    XCTAssertTrue([self.game waitForState:XCUIApplicationStateRunningBackground timeout:5]);
    [self waitForMotionObservation:2];
    [self.game activate];
    NSDictionary* returned = [self waitControllerReadback:^BOOL(NSDictionary* state) {
        NSDictionary* input = state[@"input_samples"];
        return [state[@"command"] isEqual:held] && [state[@"controller_needs_neutral"] boolValue] &&
            ![state[@"host_paused"] boolValue] && [input[@"last_hold"] unsignedIntValue] == 0 &&
            ![input[@"last_pointer_valid"] boolValue] &&
            [input[@"last_stick"][0] doubleValue] == 0 && [input[@"last_stick"][1] doubleValue] == 0;
    } timeout:5 label:@"foreground-held-input-blocked"];
    NSArray* transitions = returned[@"pause_transitions"];
    XCTAssertGreaterThanOrEqual(transitions.count, 2u);
    NSDictionary* paused = transitions[transitions.count - 2];
    NSDictionary* resumed = transitions.lastObject;
    XCTAssertTrue([paused[@"paused"] boolValue]);
    XCTAssertFalse([resumed[@"paused"] boolValue]);
    XCTAssertNotEqualObjects(paused[@"frame_index"], NSNull.null);
    XCTAssertEqualObjects(paused[@"frame_index"], resumed[@"frame_index"]);
    XCTAssertEqualObjects(paused[@"guest_timebase"], resumed[@"guest_timebase"]);
    XCTAssertGreaterThan([resumed[@"host_monotonic_seconds"] doubleValue] -
        [paused[@"host_monotonic_seconds"] doubleValue], 2.0);
    [self waitForMotionObservation:1];
    NSDictionary* guarded = [self controllerReadback];
    XCTAssertGreaterThan([guarded[@"input_samples"][@"count"] unsignedLongLongValue],
        [returned[@"input_samples"][@"count"] unsignedLongLongValue]);
    for (NSString* key in @[@"wiimote_motion_count", @"nunchuk_motion_count"])
        XCTAssertEqualObjects(guarded[@"input_samples"][key], returned[@"input_samples"][key]);
    [self recordControllerReadback:@"foreground-guard-stays-neutral"];
    [self capture:@"lifecycle-foreground-held-blocked"];
    [self controllerCommand:@"neutral" expectMask:0];
    [self controllerCommand:@"x" expectMask:16384];
    [self controllerCommand:@"neutral" expectMask:0];
    [self controllerPress:@"menu"];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    NSDictionary* sheet = [self waitControllerReadback:^BOOL(NSDictionary* state) {
        return [state[@"manually_paused"] boolValue] && [state[@"host_paused"] boolValue];
    } timeout:5 label:@"manual-pause-before-background"];
    [XCUIDevice.sharedDevice pressButton:XCUIDeviceButtonHome];
    XCTAssertTrue([self.game waitForState:XCUIApplicationStateRunningBackground timeout:5]);
    [self waitForMotionObservation:2];
    [self.game activate];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self waitForMotionObservation:1];
    NSDictionary* sheetReturn = [self controllerReadback];
    XCTAssertTrue([sheetReturn[@"host_paused"] boolValue]);
    XCTAssertTrue([sheetReturn[@"manually_paused"] boolValue]);
    XCTAssertEqualObjects(sheetReturn[@"timing"][@"frame_index"], sheet[@"timing"][@"frame_index"]);
    [self recordControllerReadback:@"manual-pause-preserved-after-background"];
    [self capture:@"lifecycle-settings-preserved"];
    [self controllerPress:@"menu"];
    [self waitForControllerSheetToClose:settings];
    [self waitControllerReadback:^BOOL(NSDictionary* state) {
        return ![state[@"host_paused"] boolValue] &&
            [state[@"timing"][@"frame_index"] unsignedLongLongValue] >
            [sheet[@"timing"][@"frame_index"] unsignedLongLongValue];
    } timeout:5 label:@"manual-resume-guest-advances"];
    [self capture:@"lifecycle-final-gameplay"];
    [self controllerPress:@"menu"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
}
- (void)controllerPress:(NSString*)button {
    [self controllerState:button];
    [self waitForMotionObservation:.16];
    [self controllerState:@"neutral"];
    [self waitForMotionObservation:.16];
}
- (void)controllerMove:(NSString*)button count:(NSUInteger)count {
    for (NSUInteger i = 0; i < count; ++i) [self controllerPress:button];
}
- (void)waitForControllerSheetToClose:(XCUIElement*)sheet {
    XCTNSPredicateExpectation* closed = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"exists == NO"] object:sheet];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[closed] timeout:5], XCTWaiterResultCompleted);
}
- (void)testControllerSnapshotNavigation {
    self.executionTimeAllowance = 150;
    [self waitForMotionObservation:20];
    [self controllerPress:@"a"];
    [self waitForMotionObservation:3];
    [self capture:@"controller-translated-gameplay"];
    [self controllerState:@"menu"];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self waitForMotionObservation:.7];
    XCTAssertTrue(settings.exists, @"Holding Menu must not immediately resume");
    [self controllerState:@"neutral"];
    [self waitForMotionObservation:.2];
    XCTAssertTrue(self.game.cells[@"open-game-menu"].isSelected);
    [self capture:@"controller-settings-focused"];
    [self controllerMove:@"down" count:8];
    XCTAssertTrue(self.game.cells[@"reset-touch-controls"].isSelected);
    [self controllerPress:@"a"];
    [self controllerMove:@"up" count:8];
    [self controllerPress:@"down"];
    XCTAssertTrue(self.game.cells[@"open-controls-guide"].isSelected);
    [self controllerPress:@"a"];
    XCUIElement* guide = self.game.tables[@"native-controls-guide"];
    XCTAssertTrue([guide waitForExistenceWithTimeout:5]);
    XCTAssertTrue([self.game.cells[@"controls-guide-0-0"].label containsString:@"Use the left stick."]);
    [self capture:@"controller-guide-focused"];
    [self controllerPress:@"left"];
    XCTAssertTrue([self.game.cells[@"controls-guide-0-0"].label containsString:@"Drag the movement stick."]);
    [self controllerPress:@"right"];
    [self controllerMove:@"down" count:12];
    XCTAssertTrue(self.game.cells[@"controls-guide-2-4"].isSelected);
    [self capture:@"controller-guide-last-row"];
    [self controllerPress:@"b"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    XCTAssertTrue(self.game.cells[@"open-controls-guide"].isSelected);
    // Left-stick navigation and adjustment use the same production poller.
    [self controllerPress:@"stickdown"];
    XCUIElement* size = self.game.sliders[@"touch.scale.v1"];
    NSString* originalSize = [size.value description];
    [self controllerPress:@"stickright"];
    XCTAssertNotEqualObjects(size.value, originalSize);
    [self controllerPress:@"left"];
    XCTAssertEqualObjects(size.value, originalSize);
    [self controllerMove:@"down" count:2];
    XCUIElement* labels = self.game.switches[@"touch.labels.v1"];
    NSString* originalLabels = [labels.value description];
    [self controllerState:@"a"];
    [self waitForMotionObservation:1];
    XCTAssertNotEqualObjects(labels.value, originalLabels);
    [self waitForMotionObservation:.4];
    XCTAssertNotEqualObjects(labels.value, originalLabels, @"Confirm is edge-triggered, not repeated");
    [self controllerState:@"neutral"];
    [self waitForMotionObservation:.2];
    [self controllerPress:@"a"];
    XCTAssertEqualObjects(labels.value, originalLabels);
    [self controllerMove:@"down" count:5];
    XCUIElement* scale = self.game.segmentedControls[@"render.scale"];
    XCTAssertTrue(self.game.cells[@"render.scale-row"].isSelected);
    XCTAssertTrue(scale.buttons[@"Native"].isSelected);
    [self controllerPress:@"left"];
    XCTAssertTrue(scale.buttons[@"3×"].isSelected);
    [self controllerPress:@"right"];
    XCTAssertTrue(scale.buttons[@"Native"].isSelected);
    [self controllerPress:@"down"];
    XCUIElement* motion = self.game.switches[@"render.motion"];
    XCTAssertEqualObjects(motion.value, @"1");
    [self controllerPress:@"left"];
    XCTAssertEqualObjects(motion.value, @"0");
    [self controllerPress:@"right"];
    XCTAssertEqualObjects(motion.value, @"1");
    [self capture:@"controller-display-focused"];
    [self controllerState:@"disconnect"];
    [self waitForMotionObservation:.3];
    XCTAssertTrue(settings.exists);
    XCTAssertFalse(self.game.cells[@"render.motion-row"].isSelected);
    // Reconnect with Confirm held: a held button must not toggle the row.
    [self controllerState:@"a"];
    [self waitForMotionObservation:.2];
    [self controllerState:@"connect"];
    [self waitForMotionObservation:.5];
    XCTAssertEqualObjects(motion.value, @"1");
    [self controllerState:@"neutral"];
    [self waitForMotionObservation:.2];
    [self controllerPress:@"menu"];
    [self waitForControllerSheetToClose:settings];
    [self waitForMotionObservation:1];
    [self capture:@"controller-resumed"];
    [self controllerPress:@"menu"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    XCTAssertTrue(self.game.cells[@"open-game-menu"].isSelected);
    [self controllerState:@"a"];
    [self waitForControllerSheetToClose:settings];
    [self waitForMotionObservation:1];
    [self capture:@"controller-opened-source-game-menu-confirm-held"];
    [self controllerState:@"neutral"];
    [self waitForMotionObservation:.2];
    [self controllerPress:@"a"];
    [self waitForMotionObservation:1];
    [self capture:@"controller-keep-playing-from-source-game-menu"];
    [self controllerState:@"disconnect"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5], @"Losing the last controller pauses gameplay");
    [self capture:@"controller-disconnected-touch-fallback"];
}
- (void)testControllerSnapshotLargeTextTraversal {
    [self controllerPress:@"menu"];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self capture:@"controller-dark-large-top"];
    [self controllerPress:@"down"];
    [self controllerPress:@"a"];
    XCUIElement* guide = self.game.tables[@"native-controls-guide"];
    XCTAssertTrue([guide waitForExistenceWithTimeout:5]);
    for (NSUInteger i = 0; i < 40 && !self.game.cells[@"controls-guide-2-2"].isSelected; ++i)
        [self controllerPress:@"down"];
    XCTAssertTrue(self.game.cells[@"controls-guide-2-2"].isSelected);
    [self capture:@"controller-dark-large-guide-long-row"];
    [self controllerPress:@"down"];
    [self capture:@"controller-dark-large-guide-continued"];
    [self controllerPress:@"b"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    for (NSUInteger i = 0; i < 30 && !self.game.cells[@"render.scale-row"].isSelected; ++i)
        [self controllerPress:@"down"];
    XCTAssertTrue(self.game.cells[@"render.scale-row"].isSelected);
    [self capture:@"controller-dark-large-scale"];
    [self controllerPress:@"down"];
    XCTAssertTrue(self.game.cells[@"render.motion-row"].isSelected);
    [self capture:@"controller-dark-large-motion"];
    [self controllerPress:@"down"];
    [self capture:@"controller-dark-large-motion-continued"];
    [self controllerPress:@"b"];
    [self waitForControllerSheetToClose:settings];
}
- (void)testControllerSnapshotSourceMenuReturn {
    // Narrow confirmation of the original root menu's Keep Playing route.
    // The original game draws these pixels; compare the retained captures.
    [self waitForMotionObservation:20];
    [self controllerPress:@"a"];
    [self waitForMotionObservation:3];
    [self capture:@"source-return-translated-gameplay"];
    [self controllerPress:@"menu"];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self controllerState:@"a"];
    [self waitForControllerSheetToClose:settings];
    [self waitForMotionObservation:1];
    [self capture:@"source-return-game-menu-confirm-held"];
    [self controllerState:@"neutral"];
    [self waitForMotionObservation:.2];
    [self controllerPress:@"a"];
    [self waitForMotionObservation:1];
    [self capture:@"source-return-keep-playing-confirmed"];
}
- (void)testSingleEnhancedExperience {
    // This case uses the explicitly prepared Canyon QA configuration. It is
    // a single-experience check, not normal campaign progression evidence.
    // A stale Original preference/environment must not restore a second mode.
    XCTestExpectation* loading = [self expectationWithDescription:@"isolated Canyon loads"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ [loading fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[loading] timeout:25], XCTWaiterResultCompleted);
    [self.game.buttons[@"game-action-2048"] tap];
    XCTestExpectation* entered = [self expectationWithDescription:@"Canyon confirm transition"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ [entered fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[entered] timeout:6], XCTWaiterResultCompleted);
    [self capture:@"enhanced-default-gameplay"];
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    [self capture:@"enhanced-settings-top"];
    XCTAssertFalse(self.game.segmentedControls[@"game.nextEdition.v1"].exists);
    for (NSString* key in @[@"render.widescreen", @"render.artwork", @"render.models"])
        XCTAssertFalse(self.game.switches[key].exists);
    [self scrollTable:settings toCell:@"render.scale-row"];
    XCUIElement* scale = self.game.segmentedControls[@"render.scale"];
    XCTAssertTrue(scale.buttons[@"Native"].isSelected);
    [scale.buttons[@"2×"] tap];
    XCTAssertTrue(scale.buttons[@"2×"].isSelected);
    [scale.buttons[@"Native"] tap];
    [self scrollTable:settings toCell:@"render.motion-row"];
    XCUIElement* motion = self.game.switches[@"render.motion"];
    XCTAssertTrue(motion.isEnabled && motion.isHittable);
    XCTAssertEqualObjects(motion.value, @"1");
    [self capture:@"enhanced-display-defaults"];
    [motion tap];
    XCTAssertEqualObjects(motion.value, @"0");
    [motion tap];
    XCTAssertEqualObjects(motion.value, @"1");
    [self.game.navigationBars.buttons[@"Resume"] tap];
    XCTAssertFalse(settings.exists);
    XCTAssertTrue(self.game.buttons[@"native-pause"].isHittable);
    [self capture:@"enhanced-resumed"];
}
- (void)waitForMotionObservation:(NSTimeInterval)seconds {
    XCTestExpectation* interval = [self expectationWithDescription:@"bounded motion observation"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [interval fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[interval] timeout:seconds + 3], XCTWaiterResultCompleted);
}
- (void)testMotionPresentationLifecycle {
    // Prepared isolated Canyon DATA only. The external geometry/phase log is
    // required evidence; an XCTest pass alone does not prove interpolation or fps.
    [self waitForMotionObservation:20];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForMotionObservation:3];
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    [self.game.cells[@"render.scale-row"] tap];
    [self.game.segmentedControls[@"render.scale"].buttons[@"3×"] tap];
    [self capture:@"motion-settings"];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    // The first startup confirm can expose a second Omnitrix tutorial. Clear
    // that panel before asking for gameplay movement/attack evidence.
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForMotionObservation:1];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForMotionObservation:1];
    [self capture:@"motion-gameplay-before-input"];
    XCUIElement* stick = self.game.otherElements[@"game-move"];
    XCTAssertTrue(stick.isHittable);
    [[stick coordinateWithNormalizedOffset:CGVectorMake(.8, .5)] pressForDuration:1];
    [self capture:@"motion-moved-right"];
    // Crossing the first movement trigger exposes the Omnitrix panel even
    // after earlier confirms. Its source-owned input delay must expire before
    // confirming; the early tap in the first receipts was correctly ignored.
    [self waitForMotionObservation:4];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForMotionObservation:1];
    [[stick coordinateWithNormalizedOffset:CGVectorMake(.2, .5)] pressForDuration:1];
    [self capture:@"motion-moved-back"];
    [self.game.buttons[@"game-action-1024"] pressForDuration:1.2];
    [self waitForMotionObservation:2];
    [self capture:@"motion-active"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self waitForMotionObservation:2];
    [self capture:@"motion-paused"];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self.game.buttons[@"game-action-2048"] pressForDuration:1];
    [self waitForMotionObservation:2];
    [self capture:@"motion-resumed"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self capture:@"motion-final-paused"];
}
- (void)testSmoothMotionPreviewControl {
    // No developer motion environment: prove the player-facing setting works
    // on the prepared translated-game QA scene. Not a campaign/fps gate.
    [self waitForMotionObservation:20];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForMotionObservation:3];
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    [self scrollTable:settings toCell:@"render.motion-row"];
    XCUIElement* motion = self.game.switches[@"render.motion"];
    XCTAssertTrue(motion.isEnabled && motion.isHittable);
    XCTAssertEqualObjects(motion.value, @"1");
    [self capture:@"smooth-motion-default-on"];
    [motion tap];
    XCTAssertEqualObjects(motion.value, @"0");
    [motion tap];
    XCTAssertEqualObjects(motion.value, @"1");
    [self capture:@"smooth-motion-enabled"];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self waitForMotionObservation:3];
    [self capture:@"smooth-motion-gameplay"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self scrollTable:settings toCell:@"render.motion-row"];
    XCTAssertEqualObjects(motion.value, @"1");
    [motion tap];
    XCTAssertEqualObjects(motion.value, @"0");
    [self capture:@"smooth-motion-lower-delay"];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self waitForMotionObservation:1];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self scrollTable:settings toCell:@"render.motion-row"];
    XCTAssertEqualObjects(motion.value, @"0");
    [self capture:@"smooth-motion-final-off"];
}
- (void)testFontArtworkTutorialAndPauseMenu {
    self.executionTimeAllowance = 100;
    // The isolated Canyon entry shows a real source TIP with both shared
    // display/body atlases. Keep the text visible for artwork inspection.
    [self waitForMotionObservation:20];
    [self capture:@"font-tutorial"];
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self capture:@"font-native-settings"];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForMotionObservation:3];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self.game.cells[@"open-game-menu"] tap];
    [self waitForMotionObservation:2];
    XCTAssertEqualObjects(self.game.buttons[@"game-action-2048"].label, @"Confirm");
    XCTAssertTrue(self.game.buttons[@"game-back"].isHittable);
    XCTAssertEqualObjects(self.game.buttons[@"game-action-8"].label, @"Menu up");
    XCTAssertEqualObjects(self.game.buttons[@"game-action-4"].label, @"Menu down");
    [self capture:@"font-game-menu"];
    // Source Keep Playing is confirmed without changing a save or setting.
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForMotionObservation:2];
    XCTAssertEqualObjects(self.game.buttons[@"game-action-2048"].label, @"Attack or confirm");
    XCTAssertEqualObjects(self.game.buttons[@"game-action-8"].label, @"Transform or up");
    [self capture:@"font-gameplay-return"];
}
- (void)waitForGameLabel:(NSString*)label timeout:(NSTimeInterval)timeout {
    XCTNSPredicateExpectation* expectation = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"label == %@", label]
        object:self.game.otherElements[@"translated-game-view"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:timeout], XCTWaiterResultCompleted);
}
- (void)assertInstructionControls:(NSString*)captureName {
    [self waitForGameLabel:@"Game instruction. Use Confirm to continue." timeout:30];
    XCTAssertTrue(self.game.buttons[@"game-action-2048"].isHittable);
    XCTAssertEqualObjects(self.game.buttons[@"game-action-2048"].label, @"Confirm");
    XCTAssertTrue(self.game.buttons[@"native-pause"].isHittable);
    XCTAssertFalse(self.game.otherElements[@"game-move"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-8192"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-8"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-4"].exists);
    XCTAssertFalse(self.game.buttons[@"game-back"].exists);
    XCTAssertFalse(self.game.buttons[@"game-motion-interaction"].exists);
    [self capture:captureName];
}
- (void)testNativeTutorialPromptFlow {
    self.executionTimeAllowance = 160;
    [self waitForGameLabel:@"Game ready. Use Confirm to continue." timeout:45];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForGameLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:10];
    [self waitForMotionObservation:1];
    XCUICoordinate* right = [self.game.otherElements[@"game-move"]
        coordinateWithNormalizedOffset:CGVectorMake(.85, .5)];
    [right pressForDuration:1.5];
    [self assertInstructionControls:@"tutorial-omnitrix-native-confirm"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
    [self capture:@"tutorial-native-paused"];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self assertInstructionControls:@"tutorial-omnitrix-resumed"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForGameLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:10];
    [self waitForMotionObservation:1];
    right = [self.game.otherElements[@"game-move"] coordinateWithNormalizedOffset:CGVectorMake(.85, .5)];
    [right pressForDuration:1.5];
    [self assertInstructionControls:@"tutorial-enemy-native-confirm"];
    [self.game.buttons[@"game-action-2048"] tap];
    // Readback of the rewritten body, not its earlier SetWordWrapText load.
    NSPredicate* combatReadback = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary* bindings) {
        (void)object; (void)bindings;
        NSString* contents = [NSString stringWithContentsOfFile:self.uiTextLogPath encoding:NSUTF8StringEncoding error:nil];
        for (NSString* line in [contents componentsSeparatedByString:@"\n"]) {
            NSDictionary* row = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([row[@"key"] isEqual:@"Platform-PC-103"] && !row[@"replacement_latin1"] &&
                [row[@"text_latin1"] isEqual:@"Use Attack for light attacks, Heavy for heavy attacks, and Special."])
                return YES;
        }
        return NO;
    }];
    XCTNSPredicateExpectation* combat = [[XCTNSPredicateExpectation alloc] initWithPredicate:combatReadback object:self.game];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[combat] timeout:15], XCTWaiterResultCompleted);
    [self assertInstructionControls:@"tutorial-combat-native-confirm"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForGameLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:10];
    [self waitForMotionObservation:1];
    XCTAssertTrue(self.game.otherElements[@"game-move"].isHittable);
    XCTAssertEqualObjects(self.game.buttons[@"game-action-2048"].label, @"Attack or confirm");
    [self capture:@"tutorial-gameplay-return"];
    // No combat/campaign sampling; stop on native pause after the changed path.
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
}
- (void)testControllerSnapshotNativeTutorialPrompt {
    self.executionTimeAllowance = 100;
    [self waitForGameLabel:@"Game ready. Use Confirm to continue." timeout:45];
    XCUIElement* cue = [[self.game descendantsMatchingType:XCUIElementTypeAny]
        matchingIdentifier:@"controller-continue-cue"].firstMatch;
    XCTAssertTrue(cue.exists);
    XCTAssertTrue([cue.label hasPrefix:@"Controller: press "]);
    XCTAssertFalse(self.game.buttons[@"controller-continue-cue"].exists);
    [self controllerPress:@"a"];
    [self waitForGameLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:10];
    XCTAssertFalse(cue.exists);
    [self waitForMotionObservation:1];
    [self controllerState:@"stickright"];
    [self waitForMotionObservation:1.5];
    [self controllerState:@"neutral"];
    [self waitForGameLabel:@"Game instruction. Use Confirm to continue." timeout:15];
    XCTAssertFalse(self.game.buttons[@"game-action-2048"].isHittable);
    XCTAssertFalse(self.game.otherElements[@"game-move"].exists);
    XCTAssertTrue(self.game.buttons[@"native-pause"].isHittable);
    XCTAssertTrue(cue.exists);
    XCTAssertTrue([cue.label hasSuffix:@" to confirm."]);
    [self capture:@"tutorial-controller-instruction"];
    [self controllerPress:@"menu"];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self capture:@"tutorial-controller-native-pause"];
    [self controllerPress:@"menu"];
    [self waitForControllerSheetToClose:settings];
    [self waitForGameLabel:@"Game instruction. Use Confirm to continue." timeout:5];
    XCTAssertTrue(cue.exists);
    [self controllerPress:@"a"];
    [self waitForGameLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:10];
    XCTAssertFalse(cue.exists);
    [self capture:@"tutorial-controller-gameplay-return"];
    [self controllerPress:@"menu"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
}
- (void)testLoadingPromptTouchFlow {
    self.executionTimeAllowance = 110;
    XCUIElement* gameView = self.game.otherElements[@"translated-game-view"];
    XCUIElement* confirm = self.game.buttons[@"game-action-2048"];
    XCTNSPredicateExpectation* loading = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"label == 'Loading the game. Please wait.'"] object:gameView];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[loading] timeout:15], XCTWaiterResultCompleted);
    [self capture:@"loading-wait"];
    XCTAssertFalse(confirm.exists);
    XCTAssertFalse(self.game.otherElements[@"game-move"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-8"].exists);
    XCTAssertFalse(self.game.buttons[@"game-motion-interaction"].exists);
    __block BOOL combatControlsBetweenStages = NO;
    NSPredicate* loadingToReady = [NSPredicate predicateWithBlock:^BOOL(XCUIElement* element, NSDictionary* bindings) {
        (void)bindings;
        NSString* label = element.label;
        BOOL isReady = [label isEqual:@"Game ready. Use Confirm to continue."];
        if (!isReady && ![label isEqual:@"Loading the game. Please wait."])
            combatControlsBetweenStages = YES;
        return isReady;
    }];
    XCTNSPredicateExpectation* ready = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:loadingToReady object:gameView];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[ready] timeout:30], XCTWaiterResultCompleted);
    XCTAssertFalse(combatControlsBetweenStages, @"The silent source gap stays Loading, never combat controls");
    XCTAssertEqualObjects(confirm.label, @"Confirm");
    XCTAssertTrue(confirm.isHittable);
    XCTAssertFalse(self.game.buttons[@"game-back"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-8192"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-8"].exists);
    XCTAssertFalse(self.game.buttons[@"game-action-4"].exists);
    [self capture:@"loading-ready"];
    // Retain the prompt over the real native settings interruption; existing
    // handedness/scale controls apply to this single contextual action too.
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self capture:@"loading-settings"];
    [self scrollTable:settings toCell:@"touch.scale.v1-row"];
    [self.game.sliders[@"touch.scale.v1"] adjustToNormalizedSliderPosition:1];
    [self scrollTable:settings toCell:@"touch.swapped.v1-row"];
    XCUIElement* swapped = self.game.switches[@"touch.swapped.v1"];
    if (![swapped.value isEqual:@"1"]) [swapped tap];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self waitForMotionObservation:1];
    XCTAssertEqualObjects(gameView.label, @"Game ready. Use Confirm to continue.");
    XCTAssertLessThan(CGRectGetMidX(confirm.frame), self.game.frame.size.width * 0.5);
    XCTAssertGreaterThan(confirm.frame.size.width, 100);
    [self capture:@"loading-ready-swapped-large"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self scrollTable:settings toCell:@"reset-touch-controls"];
    [self.game.cells[@"reset-touch-controls"] tap];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    XCTAssertEqualObjects(confirm.label, @"Confirm");
    XCTAssertGreaterThan(CGRectGetMidX(confirm.frame), self.game.frame.size.width * 0.5);
    [self capture:@"loading-ready-reset"];
    [confirm tap];
    XCTNSPredicateExpectation* gameplay = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"label == 'Attack or confirm' AND hittable == YES"] object:confirm];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[gameplay] timeout:10], XCTWaiterResultCompleted);
    [self waitForMotionObservation:2];
    XCTAssertEqualObjects(self.game.buttons[@"game-action-8"].label, @"Transform or up");
    XCTAssertTrue(self.game.otherElements[@"game-move"].isHittable);
    [self capture:@"loading-gameplay"];
}
- (void)testControllerSnapshotLoadingPrompt {
    self.executionTimeAllowance = 75;
    XCUIElement* gameView = self.game.otherElements[@"translated-game-view"];
    XCTNSPredicateExpectation* loading = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"label == 'Loading the game. Please wait.'"] object:gameView];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[loading] timeout:15], XCTWaiterResultCompleted);
    [self controllerState:@"a"];
    XCTNSPredicateExpectation* ready = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"label == 'Game ready. Use Confirm to continue.'"] object:gameView];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[ready] timeout:30], XCTWaiterResultCompleted);
    [self waitForMotionObservation:1];
    XCTAssertEqualObjects(gameView.label, @"Game ready. Use Confirm to continue.");
    XCTAssertFalse(self.game.buttons[@"game-action-2048"].isHittable);
    [self capture:@"loading-controller-held-ready"];
    [self controllerState:@"neutral"];
    [self waitForMotionObservation:.3];
    [self controllerPress:@"a"];
    XCTNSPredicateExpectation* gameplay = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"label == 'Game. Touch or drag to point. Attack confirms game menus.'"] object:gameView];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[gameplay] timeout:10], XCTWaiterResultCompleted);
    [self waitForMotionObservation:2];
    [self capture:@"loading-controller-gameplay"];
}
- (void)testHUDArtworkSelectionAndTransformation {
    self.executionTimeAllowance = 120;
    // New-artwork acceptance only. Source gameplay, mask selection and
    // animation remain real; these captures do not unlock or mutate forms.
    [self waitForMotionObservation:20];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForMotionObservation:3];
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self scrollTable:settings toCell:@"reset-touch-controls"];
    [self.game.cells[@"reset-touch-controls"] tap];
    [self scrollTable:settings toCell:@"render.scale-row"];
    [self.game.segmentedControls[@"render.scale"].buttons[@"3×"] tap];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self waitForMotionObservation:1];
    [self capture:@"hud-artwork-default"];
    XCUIElement* next = self.game.buttons[@"game-action-2"];
    XCUIElement* transform = self.game.buttons[@"game-action-8"];
    XCTAssertTrue(next.isHittable && transform.isHittable);
    for (NSUInteger index = 1; index <= 5; ++index) {
        [next tap];
        [self waitForMotionObservation:.8];
        [self capture:[NSString stringWithFormat:@"hud-artwork-selection-%lu", (unsigned long)index]];
    }
    [transform tap];
    [self waitForMotionObservation:2];
    [self capture:@"hud-artwork-transformed"];
    [self.game.buttons[@"game-action-2048"] pressForDuration:1];
    [self waitForMotionObservation:.6];
    [self capture:@"hud-artwork-after-action"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self waitForMotionObservation:1];
    [self capture:@"hud-artwork-resumed"];
}
- (void)testNativeHudLayout {
    self.executionTimeAllowance = 180;
    // The isolated Canyon configuration is a source-HUD/layout sample only.
    // No combat progression or whole-campaign gate is repeated here.
    [self waitForMotionObservation:20];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForMotionObservation:3];
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    [self scrollTable:settings toCell:@"reset-touch-controls"];
    [self.game.cells[@"reset-touch-controls"] tap];
    [self scrollTable:settings toCell:@"render.scale-row"];
    [self.game.segmentedControls[@"render.scale"].buttons[@"3×"] tap];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self waitForMotionObservation:2];
    [self capture:@"native-hud-default"];
    XCUIElement* menu = self.game.buttons[@"game-action-16"];
    XCUIElement* back = self.game.buttons[@"game-back"];
    XCTAssertFalse(menu.isHittable || back.isHittable);
    XCTAssertTrue(self.game.buttons[@"game-motion-interaction"].isHittable);
    XCTAssertGreaterThanOrEqual(self.game.buttons[@"native-pause"].frame.size.width, 44);
    // The run's simulator recording supplies the intermediate held pixels.
    // No test-only visual state is injected into the production overlay.
    [self.game.buttons[@"game-action-2048"] pressForDuration:2];
    [self.game.buttons[@"game-action-16384"] pressForDuration:2];
    XCTAssertNotEqualObjects(self.game.buttons[@"game-action-2048"].value, @"Held");
    XCTAssertNotEqualObjects(self.game.buttons[@"game-action-16384"].value, @"Held");
    [self capture:@"icon-controls-released"];
    // Select a different icon; the secondary-plane identity must follow it.
    [self.game.buttons[@"game-action-2"] tap];
    [self waitForMotionObservation:1];
    [self capture:@"native-hud-next-form"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self scrollTable:settings toCell:@"touch.labels.v1-row"];
    XCUIElement* labels = self.game.switches[@"touch.labels.v1"];
    XCTAssertEqualObjects(labels.value, @"0");
    [labels tap];
    XCTAssertEqualObjects(labels.value, @"1");
    [self capture:@"icon-controls-label-setting"];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self capture:@"icon-controls-labels-on"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self scrollTable:settings toCell:@"touch.scale.v1-row"];
    [self.game.sliders[@"touch.scale.v1"] adjustToNormalizedSliderPosition:1];
    [self scrollTable:settings toCell:@"touch.swapped.v1-row"];
    XCUIElement* swapped = self.game.switches[@"touch.swapped.v1"];
    if (![swapped.value isEqual:@"1"]) [swapped tap];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self waitForMotionObservation:1];
    [self capture:@"icon-controls-labels-large-swapped"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self scrollTable:settings toCell:@"touch.labels.v1-row"];
    XCTAssertEqualObjects(labels.value, @"1");
    [labels tap];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self capture:@"native-hud-large-swapped"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self waitForMotionObservation:2];
    [self capture:@"native-hud-final"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:5]);
}
- (void)testSmoothMotionExplanationScroll {
    // Supplement the largest-text first viewport with the row's lower copy.
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    [self scrollTable:settings toCell:@"render.motion-row"];
    const CGRect row = self.game.cells[@"render.motion-row"].frame;
    const CGFloat bottom = MIN(CGRectGetMaxY(settings.frame), CGRectGetMaxY(self.game.frame)) - 12;
    const CGFloat distance = fmax(0, CGRectGetMaxY(row) - bottom);
    if (distance > 0) {
        XCUICoordinate* start = [settings coordinateWithNormalizedOffset:CGVectorMake(.5, .8)];
        [start pressForDuration:.1 thenDragToCoordinate:[start coordinateWithOffset:CGVectorMake(0, -distance)]
            withVelocity:XCUIGestureVelocitySlow thenHoldForDuration:.2];
    }
    [self capture:@"smooth-motion-explanation-lower"];
}
- (void)testNativePauseSettingsAndTouchDelivery {
    XCUIElement* attack = self.game.buttons[@"game-action-2048"];
    XCUIElement* jump = self.game.buttons[@"game-action-8192"];
    XCTAssertTrue(attack.isHittable);
    XCTAssertTrue(jump.isHittable);
    XCTAssertGreaterThanOrEqual(attack.frame.size.width, 44);
    XCTAssertGreaterThanOrEqual(jump.frame.size.height, 44);
    const BOOL initiallySwapped = CGRectGetMidX(attack.frame) < self.game.frame.size.width * 0.5;
    [attack pressForDuration:0.2];
    [jump pressForDuration:0.2];
    [self capture:@"overlay"];

    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* table = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([table waitForExistenceWithTimeout:10]);
    XCTAssertTrue(self.game.navigationBars[@"Paused"].exists);
    [self capture:@"settings-top"];

    XCUIElement* scale = self.game.sliders[@"touch.scale.v1"];
    [self.game.cells[@"touch.scale.v1-row"] tap];
    XCTAssertTrue(scale.exists);
    [scale adjustToNormalizedSliderPosition:0.9];
    XCUIElement* swapped = self.game.switches[@"touch.swapped.v1"];
    [self.game.cells[@"touch.swapped.v1-row"] tap];
    XCTAssertTrue(swapped.exists);
    // Scrolling to the row may also activate its switch. Set a desired value
    // explicitly rather than blindly toggling whatever state that tap left.
    NSString* desiredSwap = initiallySwapped ? @"0" : @"1";
    if (![swapped.value isEqual:desiredSwap]) [swapped tap];
    XCTAssertEqualObjects(swapped.value, desiredSwap);
    [self.game.navigationBars.buttons[@"Resume"] tap];
    XCTAssertFalse(table.exists);
    XCTAssertTrue([self.game.buttons[@"native-pause"] waitForExistenceWithTimeout:5]);
    // Confirm reuses this button if the intro reaches its title while testing.
    // Jump correctly disappears in that context and must not be queried here.
    XCTAssertNotEqual(CGRectGetMidX(attack.frame) < self.game.frame.size.width * 0.5, initiallySwapped);
    [self capture:@"overlay-swapped-large"];

    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([table waitForExistenceWithTimeout:10]);
    XCUIElement* reset = self.game.cells[@"reset-touch-controls"];
    XCTAssertTrue(reset.exists);
    // XCTest scrolls this exact cell into view. Another blind upward swipe
    // can move it farther above a compact landscape sheet's viewport.
    [reset tap];
    [self capture:@"settings-presentation"];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    XCTAssertGreaterThan(attack.frame.origin.x, self.game.frame.size.width * 0.5);
}
- (void)testNativeAppearanceReadability {
    [self capture:@"appearance-overlay"];
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* table = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([table waitForExistenceWithTimeout:10]);
    [self capture:@"appearance-settings-top"];
    [table swipeUp];
    [self capture:@"appearance-settings-controls"];
    // The largest accessibility text needs more scrolling than normal text.
    // Reach the actual section instead of naming an arbitrary second swipe.
    XCUIElement* quality = self.game.segmentedControls[@"render.scale"];
    [self scrollTable:table toCell:@"render.scale-row"];
    XCTAssertTrue(quality.isHittable);
    [self capture:@"appearance-settings-presentation"];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    XCTAssertTrue(self.game.buttons[@"native-pause"].exists);
}
- (void)scrollTable:(XCUIElement*)table toCell:(NSString*)identifier {
    XCUIElement* cell = self.game.cells[identifier];
    // UIKit's accessibility scroll-to-element keeps a short landscape viewport
    // from flinging straight past the requested row. These guide rows are inert.
    if ([identifier isEqual:@"render.motion-row"])
        [cell.staticTexts[@"Smooth motion"] tap];
    else if ([identifier isEqual:@"touch.labels.v1-row"])
        [cell.staticTexts[@"Show button labels"] tap];
    else [cell tap];
    // A sliver of a tall row can count as hittable. Put its actual text in
    // the viewport before capturing, rather than trusting hittable alone.
    for (NSUInteger attempt = 0; attempt < 6; ++attempt) {
        CGRect frame = cell.frame;
        CGFloat top = MAX(CGRectGetMinY(table.frame), CGRectGetMaxY(self.game.navigationBars.firstMatch.frame)) + 8;
        CGFloat bottom = MIN(CGRectGetMaxY(table.frame), CGRectGetMaxY(self.game.frame)) - 12;
        CGFloat available = bottom - top;
        CGFloat delta = 0;
        if (frame.size.height > available) {
            if (CGRectGetMinY(frame) > top + 8) delta = CGRectGetMinY(frame) - top;
        } else if (CGRectGetMaxY(frame) > bottom) delta = CGRectGetMaxY(frame) - bottom;
        else if (CGRectGetMinY(frame) < top) delta = CGRectGetMinY(frame) - top;
        if (fabs(delta) < 2) break;
        delta = fmax(-available * 0.5, fmin(available * 0.5, delta));
        XCUICoordinate* start = [table coordinateWithNormalizedOffset:CGVectorMake(0.8, delta > 0 ? 0.8 : 0.3)];
        [start pressForDuration:0.1 thenDragToCoordinate:[start coordinateWithOffset:CGVectorMake(0, -delta)]
            withVelocity:XCUIGestureVelocitySlow thenHoldForDuration:0.2];
    }
    XCTAssertTrue(cell.isHittable);
}
- (void)testNativeControlsGuide {
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    [self.game.cells[@"open-controls-guide"] tap];
    XCUIElement* guide = self.game.tables[@"native-controls-guide"];
    XCTAssertTrue([guide waitForExistenceWithTimeout:10]);
    XCTAssertTrue(self.game.navigationBars[@"Controls"].exists);
    // A Simulator can inherit a host controller, making Controller the initial
    // guide mode. Select Touch explicitly before naming the capture as touch.
    [guide.buttons[@"Touch"] tap];
    XCTAssertTrue([self.game.cells[@"controls-guide-0-0"].label containsString:@"Drag the movement stick"]);
    [self capture:@"guide-touch-top"];
    [self scrollTable:guide toCell:@"controls-guide-1-1"];
    [self capture:@"guide-touch-omnitrix"];
    [self scrollTable:guide toCell:@"controls-guide-2-4"];
    [self capture:@"guide-touch-interactions"];
    // Return through the native navigation stack, not a second custom modal.
    [self.game.navigationBars.buttons[@"Paused"] tap];
    XCTAssertTrue(settings.exists);
    [self.game.cells[@"open-controls-guide"] tap];
    XCTAssertTrue([guide waitForExistenceWithTimeout:10]);
    // UITableView's header exposes the segments as direct buttons in this SDK.
    [guide.buttons[@"Controller"] tap];
    [self capture:@"guide-controller-top"];
    [self scrollTable:guide toCell:@"controls-guide-2-4"];
    [self capture:@"guide-controller-interactions"];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    XCTAssertFalse(guide.exists);
    XCTAssertFalse(settings.exists);
    XCTAssertTrue(self.game.buttons[@"native-pause"].isHittable);
    [self capture:@"guide-resumed"];
}
- (void)testEnhancedStartupObservation {
    // No game input before these captures. Preserve the normal logos and
    // opening movie rather than adding a test-only fast-forward. Pixel review
    // determines whether title/menu are visible; button existence alone does not.
    self.executionTimeAllowance = 110;
    XCTestExpectation* intro = [self expectationWithDescription:@"normal intro elapses"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 75 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ [intro fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[intro] timeout:80], XCTWaiterResultCompleted);
    [self capture:@"startup-no-input-title"];
    [self.game.buttons[@"game-action-2048"] tap];
    XCTestExpectation* menu = [self expectationWithDescription:@"title input transition"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ [menu fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[menu] timeout:5], XCTWaiterResultCompleted);
    [self capture:@"startup-responsive-menu"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:10]);
    [self capture:@"startup-native-pause"];
}
- (void)testContextualMenuGuideInstructions {
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    [self.game.cells[@"open-controls-guide"] tap];
    XCUIElement* guide = self.game.tables[@"native-controls-guide"];
    XCTAssertTrue([guide waitForExistenceWithTimeout:10]);
    [self scrollTable:guide toCell:@"controls-guide-2-0"];
    XCTAssertTrue([self.game.cells[@"controls-guide-2-0"].label containsString:@"Tap Confirm when shown"]);
    [self capture:@"context-guide-confirm"];
    [self scrollTable:guide toCell:@"controls-guide-2-1"];
    XCTAssertTrue([self.game.cells[@"controls-guide-2-1"].label containsString:@"Use the menu arrows"]);
    [self capture:@"context-guide-directions"];
    XCUIElement* directions = self.game.cells[@"controls-guide-2-1"];
    CGFloat overflow = CGRectGetMaxY(directions.frame) - CGRectGetMaxY(guide.frame) + 12;
    if (overflow > 2) {
        XCUICoordinate* start = [guide coordinateWithNormalizedOffset:CGVectorMake(0.8, 0.8)];
        [start pressForDuration:0.1 thenDragToCoordinate:[start coordinateWithOffset:CGVectorMake(0, -overflow)]
            withVelocity:XCUIGestureVelocitySlow thenHoldForDuration:0.2];
        [self capture:@"context-guide-directions-end"];
    }
    [self.game.navigationBars.buttons[@"Resume"] tap];
    XCTAssertFalse(guide.exists);
    XCTAssertTrue(self.game.buttons[@"native-pause"].isHittable);
}
- (void)captureSettledMenu:(NSString*)name {
    // All these source-owned front-end transitions animate. Context kind alone
    // cannot identify which MENU is visible: preserve pixels for scene review.
    XCTestExpectation* transition = [self expectationWithDescription:name];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ [transition fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[transition] timeout:5], XCTWaiterResultCompleted);
    XCTAssertEqualObjects(self.game.buttons[@"game-action-2048"].label, @"Confirm");
    XCTAssertTrue(self.game.buttons[@"game-action-8"].isHittable);
    XCTAssertTrue(self.game.buttons[@"game-back"].isHittable);
    XCTAssertFalse(self.game.buttons[@"game-action-8192"].isHittable);
    XCTAssertFalse(self.game.buttons[@"game-motion-interaction"].isHittable);
    [self capture:name];
}
- (void)testSecondaryMenuNavigation {
    self.executionTimeAllowance = 160;
    XCUIElement* confirm = self.game.buttons[@"game-action-2048"];
    XCTNSPredicateExpectation* title = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"label == 'Confirm' AND hittable == YES"] object:confirm];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[title] timeout:90], XCTWaiterResultCompleted);
    [confirm tap];
    [self captureSettledMenu:@"secondary-main"];
    // Difficulty selection is inspected only: do not confirm a difficulty,
    // create a slot, load a game, accept settings, or alter a volume value.
    [confirm tap];
    [self captureSettledMenu:@"secondary-difficulty"];
    [self.game.buttons[@"game-back"] tap];
    [self captureSettledMenu:@"secondary-main-after-difficulty"];
    [self.game.buttons[@"game-action-4"] tap];
    [confirm tap];
    [self captureSettledMenu:@"secondary-continue"];
    [self.game.buttons[@"game-back"] tap];
    [self captureSettledMenu:@"secondary-main-after-continue"];
    [self.game.buttons[@"game-action-4"] tap];
    [confirm tap];
    [self captureSettledMenu:@"secondary-options"];
    [confirm tap];
    [self captureSettledMenu:@"secondary-audio"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:10]);
    [self capture:@"secondary-audio-paused"];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self captureSettledMenu:@"secondary-audio-resumed"];
    [self.game.buttons[@"game-back"] tap];
    [self captureSettledMenu:@"secondary-options-return"];
    [self.game.buttons[@"game-back"] tap];
    [self captureSettledMenu:@"secondary-main-return"];
}
- (void)testContextualTitleAndMenuControls {
    self.executionTimeAllowance = 150;
    XCUIElement* confirm = self.game.buttons[@"game-action-2048"];
    NSPredicate* titleReady = [NSPredicate predicateWithFormat:@"label == 'Confirm' AND hittable == YES"];
    XCTNSPredicateExpectation* title = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:titleReady object:confirm];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[title] timeout:90], XCTWaiterResultCompleted);
    // Earlier gameplay variants intentionally leave swapped/large preferences.
    // Start this context-only capture from the actual Reset action.
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* initialSettings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([initialSettings waitForExistenceWithTimeout:10]);
    [self scrollTable:initialSettings toCell:@"reset-touch-controls"];
    [self.game.cells[@"reset-touch-controls"] tap];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    XCTAssertFalse(self.game.buttons[@"game-action-8192"].isHittable);
    XCTAssertFalse(self.game.buttons[@"game-action-8"].isHittable);
    XCTAssertFalse(self.game.buttons[@"game-back"].isHittable);
    [self capture:@"context-title"];
    // The original prompt blinks; host controls must remain stable across it.
    XCTestExpectation* blink = [self expectationWithDescription:@"title blink interval"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ [blink fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[blink] timeout:5], XCTWaiterResultCompleted);
    XCTAssertEqualObjects(confirm.label, @"Confirm");
    [confirm tap];
    XCUIElement* up = self.game.buttons[@"game-action-8"];
    XCTNSPredicateExpectation* menu = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"label == 'Menu up' AND hittable == YES"] object:up];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[menu] timeout:10], XCTWaiterResultCompleted);
    XCTAssertTrue(self.game.buttons[@"game-back"].isHittable);
    XCTAssertFalse(self.game.buttons[@"game-action-8192"].isHittable);
    XCTAssertFalse(self.game.buttons[@"game-motion-interaction"].isHittable);
    [self.game.buttons[@"game-action-4"] tap];
    [up tap];
    [self capture:@"context-menu"];
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings = self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    // Large Dynamic Type moves this row below the viewport. Scroll to the
    // inert row before asking XCTest to operate its lazily exposed slider.
    XCUIElement* sizeCell = self.game.cells[@"touch.scale.v1-row"];
    [sizeCell tap];
    XCUIElement* scale = self.game.sliders[@"touch.scale.v1"];
    XCTAssertTrue(scale.isHittable);
    [scale adjustToNormalizedSliderPosition:1];
    XCUIElement* swapCell = self.game.cells[@"touch.swapped.v1-row"];
    [swapCell tap];
    XCUIElement* swapped = self.game.switches[@"touch.swapped.v1"];
    XCTAssertTrue(swapped.isHittable);
    if (![swapped.value isEqual:@"1"]) [swapped tap];
    XCTAssertEqualObjects(swapped.value, @"1");
    [self.game.navigationBars.buttons[@"Resume"] tap];
    XCTAssertEqualObjects(confirm.label, @"Confirm");
    XCTAssertLessThan(CGRectGetMidX(confirm.frame), self.game.frame.size.width * 0.5);
    XCTAssertGreaterThan(confirm.frame.size.width, 100);
    [self capture:@"context-menu-swapped-large"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
    XCUIElement* reset = self.game.cells[@"reset-touch-controls"];
    [reset tap];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    XCTAssertEqualObjects(confirm.label, @"Confirm");
    XCTAssertGreaterThan(CGRectGetMidX(confirm.frame), self.game.frame.size.width * 0.5);
    XCTAssertEqualWithAccuracy(confirm.frame.size.width, 88, 1);
    [self capture:@"context-menu-reset"];
}
@end
