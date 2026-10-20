#import <XCTest/XCTest.h>
#include <math.h>
#include <string.h>

// This observer does not change guest state. Its separately compiled, external
// simulator fixture only admits a source-bound pre-QTE entry. All target input
// below uses UIKit or GameController snapshots; motion uses the complementary
// native input path. Neither route changes source windows or results.
@interface ProtectorExtrasViewersSourceUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* container;
@property(nonatomic) NSString* commandPath;
- (NSString*)hash:(NSData*)data;
- (NSDictionary*)json:(NSString*)path;
- (void)waitForLabel:(NSString*)label timeout:(NSTimeInterval)timeout;
- (void)controller:(NSString*)command;
- (void)pulse:(NSString*)command;
- (void)attach:(NSDictionary*)data name:(NSString*)name;
@end

@implementation ProtectorExtrasViewersSourceUITests (QTESource)
- (void)testNativeStorageErrorFlowRevision5 {
    self.continueAfterFailure=NO;self.executionTimeAllowance=300;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_STORAGE_FLOW_REVISION"],@"storage-flow-5");
    self.container=env[@"PROTECTOR_AUTHORIZED_ARTWORK_CONTAINER"];
    NSString* bundle=env[@"PROTECTOR_AUTHORIZED_ARTWORK_BUNDLE"];
    NSString* identity=@"house.machine.ProtectorNative.MaterialArtworkQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],env[@"PROTECTOR_STORAGE_CONFIG_SHA256"]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSString* before=[self hash:[NSData dataWithContentsOfFile:save]];
    for(NSString* variant in @[@"fatal-touch",@"fatal-controller",@"busy-retry"]) {
        const BOOL busy=[variant hasPrefix:@"busy"];
        const BOOL controller=[variant hasSuffix:@"controller"];
        self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
        self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"storage-controller-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString* trace=[self.container stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/%@-fixture.jsonl",variant]];
        self.game.launchArguments=@[@"-touch.hideWithController.v1",controller?@"YES":@"NO",@"-touch.scale.v1",@"1",@"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
        self.game.launchEnvironment=@{
            @"PROTECTOR_STORAGE_FIXTURE":busy?@"busy":@"fatal",@"PROTECTOR_STORAGE_FIXTURE_LOG":trace,
            @"PROTECTOR_UI_TEXT_LOG":[self.container stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/%@-ui-text.jsonl",variant]],
            @"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,
            @"PROTECTOR_CONTROLLER_QA_READBACK":@"1",@"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1"};
        [self.game launch];
        // The source-matched startup loader executes before title. The retained
        // v3 trace proves injection at frame 48 in 99_99.gcs, so do not wait
        // for a title screen that fatal storage prevents from appearing.
        [self waitForLabel:busy?@"Game message. Use the direction controls to choose, then Confirm.":
            @"Save storage could not be read. Use End Game to stop. Reopen the app to try again." timeout:90];
        [self controller:@"neutral"];
        XCTAssertFalse(self.game.buttons[@"game-back"].exists);
        if(busy) {
            XCTAssertEqualObjects(self.game.buttons[@"game-action-2048"].label,@"Confirm");
            [self.game.buttons[@"Menu right"] tap];
            [self qteCapture:@"storage-busy-touch-second-choice"];
            [self pulse:@"left"];
            [self qteCapture:@"storage-busy-controller-retry"];
            [self pulse:@"a"];
            NSPredicate* recovered=[NSPredicate predicateWithFormat:@"label IN %@",
                @[@"Game ready. Use Confirm to continue.",@"Game title. Use Confirm to begin.",@"Game menu. Use the menu controls to choose and confirm."]];
            XCTestExpectation* ready=[self expectationForPredicate:recovered
                evaluatedWithObject:self.game.otherElements[@"translated-game-view"] handler:nil];
            [self waitForExpectations:@[ready] timeout:90];
            [self qteCapture:@"storage-busy-retry-recovered"];
        } else {
            if(controller) {
                XCUIElement* cue=[self.game descendantsMatchingType:XCUIElementTypeAny][@"controller-continue-cue"];
                XCTAssertTrue(cue.exists);XCTAssertTrue([cue.label containsString:@"end the game"]);
            } else XCTAssertEqualObjects(self.game.buttons[@"game-action-2048"].label,@"End Game");
            [self qteCapture:variant];
            if(controller)[self pulse:@"a"];else[self.game.buttons[@"game-action-2048"] tap];
            XCUIElement* stopped=self.game.staticTexts[@"The game stopped. Reopen the app to try again. Progress after the last successful save may be lost."];
            XCTAssertTrue([stopped waitForExistenceWithTimeout:15]);
            XCTAssertFalse(self.game.buttons[@"game-action-2048"].exists);
            // A completed stop removes the game view. Capture the stopped
            // shell directly instead of asking the gameplay helper for it.
            XCTAttachment* screenshot=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
            screenshot.name=[variant stringByAppendingString:@"-stopped"];
            screenshot.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:screenshot];
            [self attach:@{@"message":stopped.label,@"primary_control_hidden":@YES,
                @"game_view_removed":@(!self.game.otherElements[@"translated-game-view"].exists)}
                name:[variant stringByAppendingString:@"-stop-proof"]];
        }
        NSString* evidence=[NSString stringWithContentsOfFile:trace encoding:NSUTF8StringEncoding error:nil];
        XCTAssertTrue([evidence containsString:@"status_injected"]);
        if(busy) {
            XCTAssertTrue([evidence containsString:@"choice_accepted"]);
            XCTAssertTrue([evidence containsString:@"\"selected\":1"]);
            XCTAssertTrue([evidence containsString:@"\"selected\":0"]);
        }
        [self attach:@{@"variant":variant,@"source_trace":evidence?:@"",@"save_sha256":before}
            name:[variant stringByAppendingString:@"-source-proof"]];
        [self.game terminate];
        XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],before);
    }
}
- (void)testNativeHardwareWarningRetirementRevision1 {
    self.continueAfterFailure=NO;self.executionTimeAllowance=180;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_HARDWARE_FLOW_REVISION"],@"hardware-flow-1");
    self.container=env[@"PROTECTOR_AUTHORIZED_ARTWORK_CONTAINER"];
    NSString* bundle=env[@"PROTECTOR_AUTHORIZED_ARTWORK_BUNDLE"];
    NSString* identity=@"house.machine.ProtectorNative.MaterialArtworkQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],env[@"PROTECTOR_HARDWARE_CONFIG_SHA256"]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"hardware-controller-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"YES",@"-touch.scale.v1",@"1",@"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{
        @"PROTECTOR_UI_TEXT_LOG":[self.container stringByAppendingPathComponent:@"Documents/hardware-ui-text.jsonl"],
        @"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,
        @"PROTECTOR_CONTROLLER_QA_READBACK":@"1",@"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:90];
    [self controller:@"neutral"];[self pulse:@"a"];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:40];BOOL gameplay=NO;NSUInteger tutorials=0;
    while([deadline timeIntervalSinceNow]>0) {
        NSString* label=self.game.otherElements[@"translated-game-view"].label;
        if([label isEqual:@"Game. Touch or drag to point. Attack confirms game menus."]){gameplay=YES;break;}
        if([label isEqual:@"Game instruction. Use Confirm to continue."]){XCTAssertLessThan(tutorials,6u);[self pulse:@"a"];tutorials++;}
        [NSThread sleepForTimeInterval:.1];
    }
    XCTAssertTrue(gameplay);
    [self qteCapture:@"hardware-retired-native-controller"];
    [self controller:@"disconnect"];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
    [self qteCapture:@"hardware-retired-disconnect-native-pause"];
    [self.game.buttons[@"Resume"] tap];[self qteWaitForGameplay];
    XCTAssertTrue([self.game.buttons[@"game-action-2048"] waitForExistenceWithTimeout:5]);
    [self qteCapture:@"hardware-retired-touch-fallback"];
    [self attach:@{@"revision":@"hardware-flow-1",@"source_startup":@YES,
        @"controller_disconnect_native_pause":@YES,@"touch_resume":@YES,
        @"tutorial_confirmations":@(tutorials),@"script_fixture":@NO}
        name:@"hardware-retirement-native-proof"];
}
- (void)testSourceOwnedInteractionPromptRevision1 {
    [self observeSourceOwnedInteractionPromptCompositionOnly:NO];
}
- (void)testSourceOwnedInteractionPromptCompositionRevision1 {
    [self observeSourceOwnedInteractionPromptCompositionOnly:YES];
}
- (void)observeSourceOwnedInteractionPromptCompositionOnly:(BOOL)compositionOnly {
    self.continueAfterFailure=NO;self.executionTimeAllowance=240;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_INTERACTION_OBSERVER_REVISION"],@"interaction-observer-1");
    self.container=env[@"PROTECTOR_AUTHORIZED_ARTWORK_CONTAINER"];
    NSString* bundle=env[@"PROTECTOR_AUTHORIZED_ARTWORK_BUNDLE"];
    NSString* identity=@"house.machine.ProtectorNative.MaterialArtworkQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],env[@"PROTECTOR_INTERACTION_CONFIG_SHA256"]);
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/interaction-fixture.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    BOOL controller=[env[@"PROTECTOR_INTERACTION_CONTROLLER"] isEqual:@"1"];
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"interaction-controller-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",controller?@"YES":@"NO",@"-touch.scale.v1",@"1",@"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_INTERACTION_FIXTURE":@"ben-source-prompt-v1",@"PROTECTOR_INTERACTION_FIXTURE_LOG":trace,
        @"PROTECTOR_UI_TEXT_LOG":[self.container stringByAppendingPathComponent:@"Documents/interaction-ui-text.jsonl"],
        @"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,
        @"PROTECTOR_CONTROLLER_QA_READBACK":@"1",@"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:90];
    [self controller:@"neutral"];[self pulse:@"a"];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:40];BOOL gameplay=NO;NSUInteger tutorials=0;
    while([deadline timeIntervalSinceNow]>0) {
        NSString* label=self.game.otherElements[@"translated-game-view"].label;
        if([label isEqual:@"Game. Touch or drag to point. Attack confirms game menus."]){gameplay=YES;break;}
        if([label isEqual:@"Game instruction. Use Confirm to continue."]){XCTAssertLessThan(tutorials,6u);[self pulse:@"a"];tutorials++;}
        [NSThread sleepForTimeInterval:.1];
    }
    XCTAssertTrue(gameplay);
    if(!controller) {
        [self controller:@"disconnect"];
        XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
        [self.game.buttons[@"Resume"] tap];[self qteWaitForGameplay];
    }
    XCUIElement* cue=[self.game descendantsMatchingType:XCUIElementTypeAny][@"native-qte-instruction"];
    XCTAssertTrue([cue waitForExistenceWithTimeout:80]);
    XCTAssertEqualObjects(cue.label,controller?@"Special: D-pad Down":@"Use Special");
    [self qteCapture:compositionOnly?@"interaction-controller-layout-ready":controller?@"interaction-controller-ready":@"interaction-touch-ready"];
    if(compositionOnly) {
        XCTAssertTrue(controller);
        XCTAssertGreaterThan(cue.frame.size.width,320);
        XCTAssertLessThanOrEqual(cue.frame.size.width,480);
        XCTAssertLessThan(cue.frame.size.height,118);
        [self attach:@{@"composition_only":@YES,@"input_proof_reused":@YES,
            @"cue_frame":NSStringFromCGRect(cue.frame),@"cue_label":cue.label}
            name:@"interaction-composition-proof"];
        return;
    }
    if(controller)[self pulse:@"x"];
    else [self.game.buttons[@"game-action-16384"] pressForDuration:.35];
    deadline=[NSDate dateWithTimeIntervalSinceNow:4];BOOL wrongRejected=NO;
    while([deadline timeIntervalSinceNow]>0) {
        for(NSDictionary* row in [self qteRows:trace])
            if([row[@"event"] isEqual:@"source_predicate"] &&
                ([row[@"push"] unsignedIntValue]&4) && ![row[@"accepted"] boolValue])wrongRejected=YES;
        if(wrongRejected)break;[NSThread sleepForTimeInterval:.1];
    }
    XCTAssertTrue(wrongRejected,@"Source predicate did not observe and reject native Block");
    // Block legitimately suspends the actor's idle prompt path while held.
    // A source-owned cue must disappear on those frames, then return when the
    // original actor reaches the unchanged draw again after release.
    XCTAssertTrue([cue waitForExistenceWithTimeout:5]);
    XCTAssertEqualObjects(cue.label,controller?@"Special: D-pad Down":@"Use Special");
    if(controller)[self pulse:@"down"];
    else [self.game.buttons[@"game-action-4"] pressForDuration:.35];
    deadline=[NSDate dateWithTimeIntervalSinceNow:8];BOOL accepted=NO;
    while([deadline timeIntervalSinceNow]>0) {
        for(NSDictionary* row in [self qteRows:trace])
            if([row[@"event"] isEqual:@"fixture_departed"] && [row[@"accepted"] boolValue])accepted=YES;
        if(accepted)break;[NSThread sleepForTimeInterval:.1];
    }
    XCTAssertTrue(accepted,@"Source predicate did not accept native Special");
    NSPredicate* hidden=[NSPredicate predicateWithFormat:@"exists == NO"];
    XCTNSPredicateExpectation* cleared=[[XCTNSPredicateExpectation alloc] initWithPredicate:hidden object:cue];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[cleared] timeout:5],XCTWaiterResultCompleted);
    [self qteCapture:@"interaction-source-departure"];
    [self attach:@{@"revision":@"interaction-observer-1",@"controller":@(controller),
        @"source_rejected_block":@(wrongRejected),@"source_accepted_special":@(accepted),
        @"cue_cleared":@(!cue.exists),@"controlled_draw_not_earned_encounter":@YES}
        name:@"interaction-input-proof"];
}
- (void)testSourceOwnedResultsContinueRevision2 {
    [self observeSourceOwnedResultsCompositionOnly:NO];
}
- (void)testSourceOwnedResultsSettledCompositionRevision1 {
    [self observeSourceOwnedResultsCompositionOnly:YES];
}
- (void)observeSourceOwnedResultsCompositionOnly:(BOOL)compositionOnly {
    self.continueAfterFailure=NO;self.executionTimeAllowance=240;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_RESULTS_OBSERVER_REVISION"],
        compositionOnly?@"results-composition-1":@"results-observer-2");
    self.container=env[@"PROTECTOR_AUTHORIZED_ARTWORK_CONTAINER"];
    NSString* bundle=env[@"PROTECTOR_AUTHORIZED_ARTWORK_BUNDLE"];
    NSString* identity=@"house.machine.ProtectorNative.MaterialArtworkQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],env[@"PROTECTOR_RESULTS_CONFIG_SHA256"]);
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/results-fixture.jsonl"];
    NSString* text=[self.container stringByAppendingPathComponent:@"Documents/results-ui-text.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    BOOL controller=[env[@"PROTECTOR_RESULTS_CONTROLLER"] isEqual:@"1"];
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"results-controller-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",controller?@"YES":@"NO",@"-touch.scale.v1",@"1",@"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_RESULTS_FIXTURE":@"ben-completion-request-v3",@"PROTECTOR_RESULTS_FIXTURE_LOG":trace,
        @"PROTECTOR_UI_TEXT_LOG":text,@"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,
        @"PROTECTOR_CONTROLLER_QA_READBACK":@"1",@"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:90];
    [self controller:@"neutral"];[self pulse:@"a"];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:80];
    BOOL ready=NO;NSUInteger tutorials=0;
    while([deadline timeIntervalSinceNow]>0) {
        NSString* label=self.game.otherElements[@"translated-game-view"].label;
        if([label isEqual:@"Game message. Use Continue to acknowledge."]){ready=YES;break;}
        if([label isEqual:@"Game instruction. Use Confirm to continue."]) {
            XCTAssertLessThan(tutorials,6u);[self pulse:@"a"];tutorials++;
        }
        [NSThread sleepForTimeInterval:.2];
    }
    XCTAssertTrue(ready,@"Original results screen did not offer Continue");
    NSArray* rows=[self qteRows:trace];
    XCTAssertEqual([[rows filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"event == 'completion_request_seed'"]] count],1u);
    XCTAssertEqual([[rows filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"event == 'results_admitted'"]] count],1u);
    if(compositionOnly) {
        // Context is published before the corresponding rendered frame. Wait
        // for source-loop progress, then capture without repeating input QA.
        NSDictionary* admission=[[rows filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"event == 'results_admitted'"]] firstObject];
        const unsigned long long target=[admission[@"frame"] unsignedLongLongValue]+20;
        deadline=[NSDate dateWithTimeIntervalSinceNow:8];BOOL settled=NO;
        while([deadline timeIntervalSinceNow]>0) {
            for(NSDictionary* row in [self qteRows:trace])
                if([row[@"event"] isEqual:@"results_dispatch"] &&
                    [row[@"frame"] unsignedLongLongValue]>=target &&
                    [row[@"exit_local"] unsignedIntValue]==0)settled=YES;
            if(settled)break;
            [NSThread sleepForTimeInterval:.1];
        }
        XCTAssertTrue(settled);[NSThread sleepForTimeInterval:.3];
        XCTAssertEqualObjects(self.game.otherElements[@"translated-game-view"].label,@"Game message. Use Continue to acknowledge.");
        [self qteCapture:@"results-settled-controller-ready"];
        XCTAssertFalse(self.game.buttons[@"game-action-2048"].exists && self.game.buttons[@"game-action-2048"].hittable);
        [self attach:@{@"revision":@"results-composition-1",@"controller":@(controller),
            @"source_loop_settled":@(settled),@"no_continue_input":@YES,
            @"fixture_is_not_earned_progress":@YES} name:@"results-composition-proof"];
        return;
    }
    [self qteCapture:controller?@"results-controller-ready":@"results-touch-ready"];
    XCUIElement* confirm=self.game.buttons[@"game-action-2048"];
    if(controller)XCTAssertFalse(confirm.exists && confirm.hittable);
    else {XCTAssertTrue(confirm.hittable);XCTAssertEqualObjects(confirm.label,@"Continue");}
    // Holding neutral does not advance the source results loop.
    [NSThread sleepForTimeInterval:1];
    XCTAssertEqualObjects(self.game.otherElements[@"translated-game-view"].label,@"Game message. Use Continue to acknowledge.");
    if(controller)[self pulse:@"a"];else [confirm tap];
    deadline=[NSDate dateWithTimeIntervalSinceNow:20];BOOL departed=NO;
    while([deadline timeIntervalSinceNow]>0) {
        for(NSDictionary* row in [self qteRows:trace])
            if([row[@"relative_offset"] unsignedIntValue]==0xbec)departed=YES;
        if(departed)break;
        [NSThread sleepForTimeInterval:.1];
    }
    XCTAssertTrue(departed,@"Native Continue did not reach original results cleanup");
    [self qteCapture:@"results-continue-departure"];
    XCTAssertNotEqualObjects(self.game.otherElements[@"translated-game-view"].label,@"Game message. Use Continue to acknowledge.");
    [self attach:@{@"revision":@"results-observer-2",@"controller":@(controller),@"tutorial_confirmations":@(tutorials),
        @"original_results_cleanup":@(departed),@"fixture_is_not_earned_progress":@YES} name:@"results-input-proof"];
}
- (NSUInteger)qteWaitForGameplay {
    NSUInteger confirmations=0;
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:12];
    while([deadline timeIntervalSinceNow]>0) {
        NSString* label=self.game.otherElements[@"translated-game-view"].label;
        if([label isEqual:@"Game. Touch or drag to point. Attack confirms game menus."])return confirmations;
        if([label isEqual:@"Game instruction. Use Confirm to continue."]) {
            XCTAssertLessThan(confirmations,3u);
            [self qteCapture:@"qte-handoff-tutorial"];
            [self.game.buttons[@"game-action-2048"] tap];confirmations++;
        }
        [NSThread sleepForTimeInterval:.1];
    }
    XCTFail(@"Native handoff did not return to actionable gameplay");return confirmations;
}
- (NSArray<NSDictionary*>*)qteRows:(NSString*)path {
    NSString* text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray* rows=[NSMutableArray array];
    for(NSString* line in [text componentsSeparatedByString:@"\n"]) {
        if(!line.length)continue;
        id row=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if([row isKindOfClass:NSDictionary.class])[rows addObject:row];
    }
    return rows;
}
- (void)qteCapture:(NSString*)name {
    if([name hasPrefix:@"qte-pointer-"]) {
        // Source trace publication precedes UIKit's next presentation turn.
        // Capture the composition only after the device caption has appeared.
        XCUIElement* cue=[self.game descendantsMatchingType:XCUIElementTypeAny][@"native-qte-instruction"];
        XCTAssertTrue([cue waitForExistenceWithTimeout:3]);
        [NSThread sleepForTimeInterval:.2];
    }
    XCTAttachment* shot=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    shot.name=name;shot.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:shot];
    NSDictionary* input=[self json:[self.commandPath stringByAppendingString:@".receipt.json"]];
    [self attach:input name:[name stringByAppendingString:@"-input"]];
    XCUIElement* cue=[self.game descendantsMatchingType:XCUIElementTypeAny][@"native-qte-instruction"];
    const CGRect normalized=CGRectFromString(input[@"qte_target_rect"]?:@"");
    const CGRect gameFrame=self.game.otherElements[@"translated-game-view"].frame;
    const CGRect target=CGRectMake(gameFrame.origin.x+normalized.origin.x*gameFrame.size.width,
        gameFrame.origin.y+normalized.origin.y*gameFrame.size.height,
        normalized.size.width*gameFrame.size.width,normalized.size.height*gameFrame.size.height);
    const BOOL hasTarget=!CGRectIsNull(normalized) && !CGRectIsEmpty(normalized);
    if(cue.exists && hasTarget)XCTAssertFalse(CGRectIntersectsRect(cue.frame,target));
    [self attach:@{@"cue_exists":@(cue.exists),@"cue_label":cue.exists?cue.label:@"",
        @"cue_frame":cue.exists?NSStringFromCGRect(cue.frame):@"",
        @"target_frame":hasTarget?NSStringFromCGRect(target):@"",
        @"game_label":self.game.otherElements[@"translated-game-view"].label,
        @"unix":@(NSDate.date.timeIntervalSince1970)} name:[name stringByAppendingString:@"-native-ui"]];
}
- (void)testSourceOwnedQTEPresentationRevision15 {
    self.continueAfterFailure=NO;self.executionTimeAllowance=300;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    // A distinct selector and an emitted revision make stale Simulator test
    // code observable before it can be mistaken for the rebuilt observer.
    XCTAssertEqualObjects(env[@"PROTECTOR_QTE_OBSERVER_REVISION"],@"qte-observer-15");
    [self attach:@{@"revision":@"qte-observer-15"} name:@"qte-observer-revision"];
    const BOOL compositionOnly=[env[@"PROTECTOR_QTE_COMPOSITION_ONLY"] isEqual:@"1"];
    const BOOL controllerPoint=[env[@"PROTECTOR_QTE_INPUT_VARIANT"] isEqual:@"controller-point-touch-motion"];
    XCTAssertEqualObjects(env[@"PROTECTOR_QTE_OBSERVER"],@"source-owned-qte-v1");
    self.container=env[@"PROTECTOR_AUTHORIZED_ARTWORK_CONTAINER"];
    NSString* bundle=env[@"PROTECTOR_AUTHORIZED_ARTWORK_BUNDLE"];
    NSString* identity=@"house.machine.ProtectorNative.MaterialArtworkQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],env[@"PROTECTOR_QTE_CONFIG_SHA256"]);
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/qte-fixture.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"qte-controller-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",@"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_QTE_FIXTURE":@"giant-final-entry-v1",@"PROTECTOR_QTE_FIXTURE_LOG":trace,
        @"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",
        @"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1",@"PROTECTOR_INTERFACE_AUDIT_SOURCE_KEY":@"128x128-660f0b83d40b017d60cf5ea9241b3b00924f7c943200db490d3a80bb29b199a4"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:90];
    [self controller:@"neutral"];[self pulse:@"a"];
    NSPredicate* ready=[NSPredicate predicateWithFormat:@"label IN %@",@[
        @"Game. Touch or drag to point. Attack confirms game menus.",@"Game instruction. Use Confirm to continue."]];
    XCTNSPredicateExpectation* arrived=[[XCTNSPredicateExpectation alloc] initWithPredicate:ready
        object:self.game.otherElements[@"translated-game-view"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[arrived] timeout:40],XCTWaiterResultCompleted);
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:180];
    NSMutableArray* attempts=[NSMutableArray array];
    NSMutableSet* targets=[NSMutableSet set];
    BOOL pointerCaptured=NO,motionCaptured=NO,touchMotionReady=NO;
    NSUInteger tutorialConfirmations=0;
    unsigned long long lastTargetFrame=0;
    while([deadline timeIntervalSinceNow]>0) {
        NSDictionary* input=[self json:[self.commandPath stringByAppendingString:@".receipt.json"]];
        if([input[@"control_context"] isEqual:@"instruction-ready"]) {
            XCTAssertLessThan(tutorialConfirmations,4u);
            XCUIElement* confirm=self.game.buttons[@"game-action-2048"];
            XCTAssertTrue(confirm.hittable);XCTAssertEqualObjects(confirm.label,@"Confirm");
            [self qteCapture:[NSString stringWithFormat:@"qte-source-tutorial-%lu",(unsigned long)tutorialConfirmations]];
            [confirm tap];tutorialConfirmations++;
            [NSThread sleepForTimeInterval:.5];continue;
        }
        NSArray* rows=[self qteRows:trace];
        NSDictionary* current=rows.lastObject;
        // Finish controller loss/resume while the original post-target
        // animation runs, not after its two-second motion-entry window begins.
        // The old observer spent that window on its own UI handoff/captures.
        NSUInteger completedTargets=0;
        for(NSDictionary* row in rows)
            if([row[@"ip"] unsignedIntValue]==0x23c864)completedTargets++;
        if(controllerPoint && completedTargets==3 && !touchMotionReady) {
            [self controller:@"neutral"];[self controller:@"disconnect"];
            XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
            [self.game.buttons[@"Resume"] tap];
            tutorialConfirmations += [self qteWaitForGameplay];
            touchMotionReady=YES;
        }
        NSDictionary* target=nil;
        for(NSDictionary* row in rows.reverseObjectEnumerator) {
            if([row[@"ip"] unsignedIntValue]==0x23c854){target=row;break;}
        }
        BOOL inMotion=NO;
        for(NSDictionary* row in rows)
            if([row[@"ip"] unsignedIntValue]==0x23f638 || [row[@"ip"] unsignedIntValue]==0x23f680)inMotion=YES;
        if(inMotion && !motionCaptured) {
            if(compositionOnly) {
                [self qteCapture:@"qte-motion-composition"];
                motionCaptured=YES;break;
            }
            if(controllerPoint) {
                XCTAssertTrue(touchMotionReady);
                // The preceding v2 capture already proves this unchanged UI.
                // Do not spend the source reaction deadline exporting another
                // screenshot/hierarchy before the actual touch-down.
                [self attach:input name:@"qte-motion-touch-entry-input"];
                for(NSUInteger holdRound=0;holdRound<3;holdRound++) {
                    // A first-use source tutorial may interrupt an ongoing
                    // hold. Acknowledge it, then perform a fresh UIKit hold;
                    // native instruction context correctly cancels old input.
                    if(holdRound) tutorialConfirmations += [self qteWaitForGameplay];
                    XCUIElement* interact=self.game.buttons[@"game-motion-interaction"];
                    XCTAssertTrue(interact.hittable);
                    [interact pressForDuration:7];
                    NSDictionary* latest=[self qteRows:trace].lastObject;
                    if([latest[@"bank0"] count]==256 &&
                        [latest[@"bank0"][0x9c] unsignedIntValue]==0)break;
                }
                [self qteCapture:@"qte-motion-touch-released"];
            } else {
                [self qteCapture:@"qte-motion-controller-before-input"];
                [self controller:@"triggers"];
                [NSThread sleepForTimeInterval:2];[self qteCapture:@"qte-motion-controller-held"];
                [NSThread sleepForTimeInterval:5];[self controller:@"neutral"];
                [self qteCapture:@"qte-motion-controller-released"];
            }
            motionCaptured=YES;break;
        }
        if(target && [target[@"frame"] unsignedLongLongValue]>lastTargetFrame &&
            [current[@"frame"] unsignedLongLongValue]-[target[@"frame"] unsignedLongLongValue]<5) {
            // A source tutorial can overlay the running encounter. Dismiss it
            // with the actual native Confirm action before delivering a pointer;
            // instruction context deliberately does not forward pointer input.
            XCUIElement* gameView=self.game.otherElements[@"translated-game-view"];
            if(![gameView.label isEqual:@"Game. Touch or drag to point. Attack confirms game menus."])
                continue;
            NSArray* bank=target[@"bank1"];XCTAssertEqual(bank.count,256u);
            uint32_t xb=[bank[0xa1] unsignedIntValue],yb=[bank[0xa2] unsignedIntValue];
            float x,y;memcpy(&x,&xb,4);memcpy(&y,&yb,4);
            XCTAssertTrue(isfinite(x) && isfinite(y) && fabsf(x)<=1 && fabsf(y)<=1);
            NSString* key=[NSString stringWithFormat:@"%u-%u",xb,yb];
            if(![targets containsObject:key]) {
                if(!pointerCaptured) {
                    [self qteCapture:@"qte-pointer-controller-cue"];
                    if(!controllerPoint) {
                        [self controller:@"disconnect"];
                    // Losing a controller deliberately opens native Pause.
                    // Complete that real lifecycle handoff before testing touch.
                    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
                    [self.game.buttons[@"Resume"] tap];
                    tutorialConfirmations += [self qteWaitForGameplay];
                        [self qteCapture:@"qte-pointer-touch-cue"];
                    }
                    pointerCaptured=YES;
                }
                XCUIElement* view=self.game.otherElements[@"translated-game-view"];
                CGRect frame=view.frame;
                CGFloat width=frame.size.width,height=frame.size.height;
                // Source target positions use the whole 640x480 dimensions,
                // centred at zero, not clip coordinates. The native landscape
                // renderer preserves that 4:3 UI inside the expanded scene.
                CGFloat sourceWidth=height*4.0/3.0;
                CGPoint offset=CGPointMake(width/2+x*sourceWidth,height/2+y*height);
                XCUICoordinate* coordinate=[[view coordinateWithNormalizedOffset:CGVectorMake(0,0)] coordinateWithOffset:CGVectorMake(offset.x,offset.y)];
                if(controllerPoint) {
                    float axisX=x*2,axisY=-y*2;
                    // The native stick's unchanged activation dead zone is
                    // .15. Its nearest active point still lies inside the
                    // source's .1-radius target for a near-centre target.
                    if(fabsf(axisX)<=.15f && fabsf(axisY)<=.15f)
                        axisX=copysignf(.16f,axisX==0?1:axisX);
                    [self controller:[NSString stringWithFormat:@"aim=%.8f,%.8f",axisX,axisY]];
                    [NSThread sleepForTimeInterval:.3];[self controller:@"neutral"];
                } else [coordinate pressForDuration:.3];
                [attempts addObject:@{@"frame":target[@"frame"],@"pointer_x":@(x),@"pointer_y":@(y),@"native_offset_x":@(offset.x),@"native_offset_y":@(offset.y),@"entry_gate_bypassed":@YES}];
                [targets addObject:key];
                if(targets.count==3 && !controllerPoint)[self controller:@"connect"];
            }
            lastTargetFrame=[target[@"frame"] unsignedLongLongValue];
        }
        [NSThread sleepForTimeInterval:.05];
    }
    [self qteCapture:@"qte-route-final"];
    NSArray* rows=[self qteRows:trace];
    NSUInteger admitted=0,phase=0,entryInput=0,entryForm=0,accepted=0;
    BOOL motionSpawned=NO,healthCleared=NO;
    NSUInteger motionCount=0;
    for(NSDictionary* row in rows) {
        if([row[@"event"] isEqual:@"admitted"])admitted++;
        if([row[@"event"] isEqual:@"phase_seed"])phase++;
        if([row[@"event"] isEqual:@"entry_input_fixture"])entryInput++;
        if([row[@"event"] isEqual:@"entry_form_fixture"])entryForm++;
        if([row[@"ip"] unsignedIntValue]==0x23c864)accepted++;
        if([row[@"ip"] unsignedIntValue]==0x23f638)motionSpawned=YES;
        if(motionSpawned && [row[@"bank0"] count]==256 && [row[@"bank1"] count]==256) {
            motionCount=MAX(motionCount,[row[@"bank1"][0x7b] unsignedIntegerValue]);
            healthCleared|=[row[@"bank0"][0x9c] unsignedIntValue]==0;
        }
    }
    [self attach:@{@"admitted":@(admitted),@"phase_seeds":@(phase),@"entry_input_seeds":@(entryInput),
        @"observer_revision":@"qte-observer-15",@"composition_only":@(compositionOnly),
        @"entry_form_seeds":@(entryForm),@"pointer_attempts":attempts,@"pointer_acceptances":@(accepted),
        @"tutorial_confirmations":@(tutorialConfirmations),
        @"motion_counter":@(motionCount),@"source_health_cleared_after_motion":@(healthCleared),
        @"input_variant":controllerPoint?@"controller-point-touch-motion":@"touch-point-controller-motion",
        @"motion_prompt_seen":@(motionCaptured),@"pointer_seen":@(pointerCaptured),
        @"scope":@"Disposable encounter entry only; subsequent touch/controller targets and paired motion use original source rules. Milestones and renders require review."}
        name:@"qte-route-summary"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:5]);
    NSDictionary* state=[self json:[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/interactive-state.json"]];
    XCTAssertEqualObjects(state[@"audio_output"],@"disabled");XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
    XCTAssertEqual(admitted,1u);XCTAssertEqual(phase,1u);
    // A route that has not reached a QTE is retained as failed evidence.
    XCTAssertTrue(pointerCaptured);XCTAssertEqual(accepted,3u);XCTAssertTrue(motionCaptured);
    if(!compositionOnly) { XCTAssertGreaterThan(motionCount,3u);XCTAssertTrue(healthCleared); }
}
@end
