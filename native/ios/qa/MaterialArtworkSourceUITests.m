#import <XCTest/XCTest.h>

// A bounded material observation in a separately identified, direct-entry QA
// app. It does not unlock progression or repeat campaign/performance acceptance.
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
- (void)attach:(NSDictionary*)data name:(NSString*)name;
@end

@implementation ProtectorExtrasViewersSourceUITests (MaterialArtworkSource)
- (NSDictionary*)liveGeometryState {
    NSDictionary* receipt=[self json:[self.commandPath stringByAppendingString:@".receipt.json"]];
    NSTimeInterval age=NSProcessInfo.processInfo.systemUptime-[receipt[@"observed_uptime"] doubleValue];
    XCTAssertGreaterThanOrEqual(age,0.0);XCTAssertLessThan(age,.5);
    NSMutableDictionary* state=[receipt[@"renderer"] mutableCopy];
    XCTAssertNotNil(state);XCTAssertNotNil(state[@"frame_index"]);
    state[@"runtime_error"]=receipt[@"runtime_error"] ?: @"missing";
    state[@"host_paused"]=receipt[@"host_paused"] ?: @"missing";
    state[@"qa_readback_age_seconds"]=@(age);
    state[@"qa_readback_source"]=@"allowlisted-simulator-live-renderer";
    return state;
}
- (NSDictionary*)captureLiveGeometry:(NSString*)name {
    NSDictionary* state=[self liveGeometryState];
    XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
    XCTAssertEqualObjects(state[@"texture_pack_entries"],@2221);
    XCTAttachment* picture=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    picture.name=name;picture.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:picture];
    [self attach:state name:[name stringByAppendingString:@"-renderer"]];
    NSDictionary* after=[self liveGeometryState];
    [self attach:after name:[name stringByAppendingString:@"-renderer-after-screenshot"]];
    // Bound screenshot/readback separation without claiming a frozen frame.
    XCTAssertLessThanOrEqual([after[@"frame_index"] unsignedIntegerValue]-[state[@"frame_index"] unsignedIntegerValue],30u);
    XCTAttachment* hierarchy=[XCTAttachment attachmentWithString:self.game.debugDescription];
    hierarchy.name=[name stringByAppendingString:@"-hierarchy"];hierarchy.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:hierarchy];
    return state;
}
- (void)testObserveCombinedNormalStartup {
    [self observeNormalStartupWithSubtitles:NO];
}
- (void)testObserveSourceSubtitles {
    [self observeNormalStartupWithSubtitles:YES];
}
- (void)observeNormalStartupWithSubtitles:(BOOL)subtitles {
    // The current delivered renderer/assets together through the ordinary
    // startup configuration. Reuses a retained guest-authored QA save; no
    // unlock, entry shortcut, game-script change or campaign replay.
    self.continueAfterFailure=NO;self.executionTimeAllowance=360;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    BOOL afterContinue=subtitles && [env[@"PROTECTOR_SUBTITLES_AFTER_CONTINUE"] boolValue];
    XCTAssertEqualObjects(env[@"PROTECTOR_COMBINED_NORMAL_QA"],@"normal-startup-v1");
    self.container=env[@"PROTECTOR_AUTHORIZED_ARTWORK_CONTAINER"];
    NSString* bundle=env[@"PROTECTOR_AUTHORIZED_ARTWORK_BUNDLE"];
    NSString* identity=@"house.machine.ProtectorNative.MaterialArtworkQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        @"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSData* saved=[NSData dataWithContentsOfFile:save];
    XCTAssertEqualObjects([self hash:saved],@"657ea835924acc5ae231e464a119a75450873f84ef0aca83e9ee0c465626afa0");
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    NSString* statePath=[diagnostics stringByAppendingPathComponent:@"interactive-state.json"];
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",
        @"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    NSMutableDictionary* launch=[@{@"PROTECTOR_CINEMATIC_AUDIT_MOVIE":@"11_intro.bik"} mutableCopy];
    if(subtitles)launch[@"PROTECTOR_UI_TEXT_LOG"]=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    self.game.launchEnvironment=launch;
    [self.game launch];
    [self waitForLabel:@"Game title. Use Confirm to begin." timeout:120];
    [self capture:@"combined-title"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
    [self settle];[self.game.buttons[@"game-action-4"] tap];[self settle];
    if(subtitles && !afterContinue) {
        // Options follows Continue; source row order is Audio, Controller,
        // Rumble, Subtitles, Accept Settings. Mutate only the disposable QA
        // settings; the runner preserves/restores the complete Library.
        [self.game.buttons[@"game-action-4"] tap];[self settle];
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
        [self capture:@"subtitles-options-before"];
        for(NSUInteger row=0;row<3;row++) {
            [self.game.buttons[@"game-action-4"] tap];[self settle];
        }
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
        [self waitForKey:@"Panel-OptionsScreen-24"];
        [self capture:@"subtitles-options-enabled"];
        [self.game.buttons[@"game-action-4"] tap];[self settle];
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
        [self capture:@"subtitles-main-after-accept"];
        [self.game.buttons[@"game-action-8"] tap];[self settle];
    }
    [self capture:@"combined-continue-menu"];
    [self.game.buttons[@"game-action-2048"] tap];[self settle];
    [self capture:@"combined-save-slot"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:45];
    [self capture:@"combined-world-map"];
    if(afterContinue) {
        // Isolate the effect of loading an original saved slot on its options.
        // The initial title-menu route above remains an independent observation.
        [self.game.buttons[@"native-pause"] tap];
        XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
        [self.game.cells[@"open-game-menu"] tap];
        [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
        [self settle];[self.game.buttons[@"game-action-4"] tap];[self settle];
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
        [self waitForKey:@"Panel-OptionsScreen-25"];
        [self capture:@"subtitles-loaded-options-before"];
        [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:8];
        XCTAssertTrue(self.game.buttons[@"game-action-4"].hittable);
        // Cover the sibling settings branches in this same normal-boot pass.
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
        [self waitForKey:@"Panel-OptionsScreen-12"];
        [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:8];
        [self capture:@"loaded-audio-menu"];
        [self.game.buttons[@"game-back"] tap];[self settle];
        [self.game.buttons[@"game-action-4"] tap];[self settle];
        [self.game.buttons[@"game-action-2048"] tap];
        XCUIElement* guide=self.game.tables[@"native-controls-guide"];
        XCTAssertTrue([guide waitForExistenceWithTimeout:12]);
        [guide.buttons[@"Touch"] tap];
        XCTAssertEqualObjects(guide.cells[@"controls-guide-0-0"].label,
            @"Move. Drag the movement stick. Lift your thumb to stop.");
        [self capture:@"loaded-native-controls-guide"];
        [self.game.buttons[@"native-guide-done"] tap];
        [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
        [self settle];[self.game.buttons[@"game-action-8"] tap];[self settle];
        // Loaded-game Options includes Difficulty before Subtitles.
        for(NSUInteger row=0;row<4;row++) {
            [self.game.buttons[@"game-action-4"] tap];[self settle];
        }
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
        [self waitForKey:@"Panel-OptionsScreen-24"];
        [self capture:@"subtitles-loaded-options-enabled"];
        [self.game.buttons[@"game-action-4"] tap];[self settle];
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
        [self.game.buttons[@"game-back"] tap];
        [self waitForLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:12];
        [self settle];
    }
    XCTAssertTrue(self.game.buttons[@"game-back"].hittable);
    XCTAssertFalse(self.game.buttons[@"game-action-8192"].exists);
    [self.game.buttons[@"game-action-2048"] tap];[self settle];
    [self.game.buttons[@"game-back"] tap];[self settle];
    [self.game.buttons[@"game-action-2048"] tap];[self settle];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForLabel:@"Game cinematic. Use Skip to continue." timeout:30];
    XCTAssertEqualObjects(self.game.buttons[@"game-action-2048"].label,@"Skip cinematic");
    if([env[@"PROTECTOR_CINEMATIC_OPENING_ONLY"] boolValue]) {
        // One short changed-boundary observation; do not replay subtitles or
        // campaign checks. The audit retains every initial source presentation.
        [NSThread sleepForTimeInterval:3.0];
        [self capture:@"opening-restored-story"];
        NSString* audit=[diagnostics stringByAppendingPathComponent:@"cinematic-presentation.jsonl"];
        NSString* lines=[NSString stringWithContentsOfFile:audit encoding:NSUTF8StringEncoding error:nil];
        NSMutableArray* visible=[NSMutableArray array];
        for(NSString* line in [lines componentsSeparatedByString:@"\n"]) {
            if(!line.length)continue;
            NSDictionary* row=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            NSDictionary* source=row[@"source"];
            if([source[@"movie"] isEqual:@"11_intro.bik"] && [source[@"active"] boolValue] &&
               [row[@"draw_index"] integerValue]>=0) {
                XCTAssertEqualObjects(source[@"replacement_active"],@YES);
                XCTAssertEqualObjects(source[@"decoded_frame_zero_based"],source[@"replacement_frame_zero_based"]);
                XCTAssertLessThanOrEqual([row[@"replacement_pack"][@"cached_frames"] count],7u);
                [visible addObject:row];
            }
        }
        XCTAssertGreaterThan(visible.count,60u);
        XCTAssertLessThanOrEqual([visible.firstObject[@"source"][@"decoded_frame_zero_based"] unsignedIntegerValue],1u);
        [self attach:@{@"first":visible.firstObject,@"last":visible.lastObject,@"visible_count":@(visible.count)} name:@"opening-frame-witness"];
        NSDictionary* state=[self json:statePath];
        XCTAssertEqualObjects(state[@"cinematic_opening"][@"outcome"],@"ready");
        [self.game.buttons[@"native-pause"] tap];
        XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
        [self capture:@"opening-paused"];
        [self.game.navigationBars.buttons[@"Resume"] tap];
        [self waitForLabel:@"Game cinematic. Use Skip to continue." timeout:12];
        [self.game.buttons[@"game-action-2048"] tap];
        [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:100];
        [self capture:@"opening-source-skip-handoff"];
        return;
    }
    if(subtitles) {
        NSString* audit=[diagnostics stringByAppendingPathComponent:@"cinematic-presentation.jsonl"];
        for(NSNumber* target in @[@1300,@1800]) {
            NSDate* limit=[NSDate dateWithTimeIntervalSinceNow:95];NSDictionary* witness=nil;
            while(limit.timeIntervalSinceNow>0) {
                NSString* lines=[NSString stringWithContentsOfFile:audit encoding:NSUTF8StringEncoding error:nil];
                for(NSString* line in [[lines componentsSeparatedByString:@"\n"] reverseObjectEnumerator]) {
                    if(!line.length)continue;
                    NSDictionary* latest=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                    if(latest) {witness=latest;break;}
                }
                NSDictionary* source=witness[@"source"];
                if([source[@"movie"] isEqual:@"11_intro.bik"] && [source[@"decoded_frame_zero_based"] unsignedIntegerValue]>=target.unsignedIntegerValue)break;
                [NSThread sleepForTimeInterval:.05];
            }
            NSDictionary* source=witness[@"source"];
            XCTAssertEqualObjects(source[@"active"],@YES);
            XCTAssertEqualObjects(source[@"replacement_active"],@YES);
            XCTAssertGreaterThanOrEqual([source[@"decoded_frame_zero_based"] unsignedIntegerValue],target.unsignedIntegerValue);
            XCTAssertLessThan([source[@"decoded_frame_zero_based"] unsignedIntegerValue],target.unsignedIntegerValue+120);
            [self attach:witness name:[NSString stringWithFormat:@"subtitles-source-%@",target]];
            // Preserve the exact current screen without the helper's diagnostic
            // refresh wait, which can advance the dialogue by several seconds.
            XCTAttachment* screen=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
            screen.name=[NSString stringWithFormat:@"subtitles-story-%@",target];
            screen.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:screen];
        }
        [self.game.buttons[@"native-pause"] tap];
        XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
        [self capture:@"subtitles-story-paused"];
        return; // No repeated combat or campaign sampling.
    }
    [self capture:@"combined-cinematic"];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:100];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:20];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:30];NSDate* stable=nil;BOOL ready=NO;
    while(deadline.timeIntervalSinceNow>0) {
        NSString* label=self.game.otherElements[@"translated-game-view"].label;
        if([label isEqual:@"Game instruction. Use Confirm to continue."]) {
            stable=nil;[self.game.buttons[@"game-action-2048"] tap];
        } else if([label isEqual:@"Game. Touch or drag to point. Attack confirms game menus."]) {
            if(!stable)stable=NSDate.date;
            if(-stable.timeIntervalSinceNow>=6) {ready=YES;break;}
        } else stable=nil;
        [NSThread sleepForTimeInterval:.2];
    }
    XCTAssertTrue(ready);[self capture:@"combined-gameplay"];
    NSDictionary* entry=[self json:statePath];
    XCTAssertEqualObjects(entry[@"native_resolution_enabled"],@YES);
    XCTAssertEqualObjects(entry[@"render_scale"],@5);
    XCTAssertEqualObjects(entry[@"geometry_pack_entries"],@176);
    XCTAssertEqualObjects(entry[@"presentation_aspect"],@"native-landscape");
    [self.game.buttons[@"game-action-2"] tap];[self settle];
    [self.game.buttons[@"game-action-8"] tap];[self settle];
    [self.game.buttons[@"game-action-2048"] pressForDuration:.8];
    [self capture:@"combined-transformed-action"];
    NSDictionary* action=[self json:statePath];
    XCTAssertNotEqualObjects(action[@"geometry_used_profiles"],entry[@"geometry_used_profiles"]);
    XCTAssertEqualObjects([self json:[diagnostics stringByAppendingPathComponent:@"native-controls.json"]][@"control_context"],@"full-controls");
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
    [self capture:@"combined-paused"];
    NSDictionary* paused=[self json:statePath];
    [self settle];XCTAssertEqualObjects([self json:statePath][@"timing"],paused[@"timing"]);
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:12];
    [self capture:@"combined-resumed"];
    NSDictionary* resumed=[self json:statePath];
    XCTAssertGreaterThan([resumed[@"frame_index"] unsignedIntegerValue],[paused[@"frame_index"] unsignedIntegerValue]);
    XCTAssertEqualObjects(resumed[@"native_resolution_enabled"],@YES);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:save],saved);
    [self attach:@{@"entry":entry,@"action":action,@"paused":paused,@"resumed":resumed,
        @"save_sha256":[self hash:saved],@"normal_boot":@YES,@"observer_revision":@1}
        name:@"combined-observations"];
}
- (void)testObserveNativeResolution {
    self.continueAfterFailure=NO;self.executionTimeAllowance=180;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    self.container=env[@"PROTECTOR_AUTHORIZED_ARTWORK_CONTAINER"];
    NSString* bundle=env[@"PROTECTOR_AUTHORIZED_ARTWORK_BUNDLE"];
    NSString* identity=@"house.machine.ProtectorNative.MaterialArtworkQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],env[@"PROTECTOR_RIGID_CONFIG_SHA256"]);
    NSString* statePath=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/interactive-state.json"];
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"native-resolution-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",@"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:100];
    [self controller:@"neutral"];[self pulse:@"a"];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:40];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:30];NSDate* stable=nil;BOOL ready=NO;
    while([deadline timeIntervalSinceNow]>0) {
        NSString* label=self.game.otherElements[@"translated-game-view"].label;
        if([label isEqual:@"Game instruction. Use Confirm to continue."]) {
            stable=nil;[self.game.buttons[@"game-action-2048"] tap];
        } else if([label isEqual:@"Game. Touch or drag to point. Attack confirms game menus."]) {
            if(!stable)stable=NSDate.date;
            if(-[stable timeIntervalSinceNow]>=6) {ready=YES;break;}
        } else stable=nil;
        [NSThread sleepForTimeInterval:.2];
    }
    XCTAssertTrue(ready);
    [self capture:@"native-resolution-gameplay"];
    NSDictionary* initial=[self json:statePath];
    NSArray* pixels=initial[@"native_render_pixel_size"];
    XCTAssertEqualObjects(initial[@"native_resolution_enabled"],@YES);
    XCTAssertGreaterThanOrEqual([initial[@"presentation_width"] doubleValue],[pixels[0] doubleValue]);
    XCTAssertGreaterThanOrEqual([initial[@"presentation_height"] doubleValue],[pixels[1] doubleValue]);
    XCTAssertEqualObjects(initial[@"render_scale"],@5);
    XCTAssertEqualObjects(initial[@"geometry_pack_entries"],@176);
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* table=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([table waitForExistenceWithTimeout:8]);
    XCUIElement* scale=self.game.segmentedControls[@"render.scale"];
    XCUIElement* row=self.game.cells[@"render.scale-row"];
    // Reuse the settings suite's precise row navigation: a swipe can jump
    // entirely over this row in a largest-text landscape phone viewport.
    // Tap only the inert label to let XCTest scroll the row into view. A cell
    // centre tap lands on 3× at the standard phone text size and changes the
    // very Native selection this test is meant to observe.
    [self.game.staticTexts[@"Render resolution"] tap];
    for(NSUInteger attempt=0;attempt<6;attempt++) {
        CGRect frame=row.frame;
        CGFloat top=MAX(CGRectGetMinY(table.frame),CGRectGetMaxY(self.game.navigationBars.firstMatch.frame))+8;
        CGFloat bottom=MIN(CGRectGetMaxY(table.frame),CGRectGetMaxY(self.game.frame))-12;
        CGFloat available=bottom-top,delta=0;
        if(frame.size.height>available) {
            if(CGRectGetMinY(frame)>top+8)delta=CGRectGetMinY(frame)-top;
        } else if(CGRectGetMaxY(frame)>bottom)delta=CGRectGetMaxY(frame)-bottom;
        else if(CGRectGetMinY(frame)<top)delta=CGRectGetMinY(frame)-top;
        if(fabs(delta)<2)break;
        delta=fmax(-available*.5,fmin(available*.5,delta));
        XCUICoordinate* start=[table coordinateWithNormalizedOffset:CGVectorMake(.8,delta>0?.8:.3)];
        [start pressForDuration:.1 thenDragToCoordinate:[start coordinateWithOffset:CGVectorMake(0,-delta)]
            withVelocity:XCUIGestureVelocitySlow thenHoldForDuration:.2];
    }
    XCTAssertTrue(scale.hittable);
    XCTAssertTrue(scale.buttons[@"Native"].isSelected);
    [scale.buttons[@"3×"] tap];[self settle];
    NSDictionary* fixed=[self json:statePath];
    XCTAssertEqualObjects(fixed[@"render_scale"],@3);
    XCTAssertEqualObjects(fixed[@"native_resolution_enabled"],@NO);
    [scale.buttons[@"Native"] tap];[self settle];
    NSDictionary* restored=[self json:statePath];
    XCTAssertEqualObjects(restored[@"render_scale"],@5);
    XCTAssertEqualObjects(restored[@"native_resolution_enabled"],@YES);
    XCTAssertEqualObjects(restored[@"frame_index"],fixed[@"frame_index"]);
    XCTAssertEqualObjects(restored[@"host_paused"],@YES);
    XCTAssertEqualObjects(restored[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(restored[@"runtime_error"],NSNull.null);
    [self attach:@{@"initial":initial,@"fixed":fixed,@"restored":restored} name:@"native-resolution-observations"];
    // Application screenshots can return a portrait-sized clipped canvas for
    // this landscape sheet; capture the composited screen, as gameplay does.
    XCTAttachment* screenshot=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    screenshot.name=@"native-resolution-settings";screenshot.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:screenshot];
    [table swipeUp];[self settle];
    XCTAttachment* detail=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    detail.name=@"native-resolution-settings-detail";detail.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:detail];
    XCTAttachment* hierarchy=[XCTAttachment attachmentWithString:self.game.debugDescription];
    hierarchy.name=@"native-resolution-settings-hierarchy";hierarchy.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:hierarchy];
    [self.game.navigationBars.buttons[@"Resume"] tap];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:8];
    [self capture:@"native-resolution-resumed"];
    NSDictionary* resumed=[self json:statePath];
    XCTAssertGreaterThan([resumed[@"frame_index"] unsignedIntegerValue],[restored[@"frame_index"] unsignedIntegerValue]);
    XCTAssertEqualObjects(resumed[@"native_resolution_enabled"],@YES);
}
- (void)testObserveRemainingHeroGeometry {
    self.continueAfterFailure=NO;self.executionTimeAllowance=180;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_REMAINING_HERO_QA"],@"attachments-v1");
    const BOOL capsOnly=[env[@"PROTECTOR_HEATBLAST_CAPS_ONLY"] isEqual:@"1"];
    const NSUInteger packEntries=capsOnly ? 180 : 176;
    self.container=env[@"PROTECTOR_AUTHORIZED_ARTWORK_CONTAINER"];
    NSString* bundle=env[@"PROTECTOR_AUTHORIZED_ARTWORK_BUNDLE"];
    NSString* identity=@"house.machine.ProtectorNative.MaterialArtworkQA";
    NSString* packHash=env[@"PROTECTOR_RIGID_PACK_SHA256"];
    XCTAssertEqual(packHash.length,64u);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],env[@"PROTECTOR_RIGID_CONFIG_SHA256"]);
    NSString* packPath=[bundle stringByAppendingPathComponent:@"EnhancedModels/geometry.json"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:packPath]],packHash);
    NSDictionary* pack=[self json:packPath];
    XCTAssertEqual([pack[@"entries"] count],packEntries);
    NSArray* names=@[@"ben",@"heatblast",@"xlr8",@"cannonbolt",@"wildvine"];
    NSArray* models=@[@"0x002d6da0",@"0x00278280",@"0x00245fc0",@"0x002bd800",@"0x0025d320"];
    NSArray* counts=@[@23,(capsOnly ? @43 : @39),@20,@24,@23];
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    NSString* statePath=[diagnostics stringByAppendingPathComponent:@"interactive-state.json"];
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"remaining-heroes-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",@"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,
        @"PROTECTOR_CONTROLLER_QA_READBACK":@"1",@"PROTECTOR_MOTION_PRESENTATION":@"1",@"PROTECTOR_MOTION_PRESENTATION_MIN_FRAME":@"300"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:100];
    [self controller:@"neutral"];[self pulse:@"a"];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:40];
    // A level tutorial can arrive after the first gameplay-ready frame. Drain
    // it through the real Confirm control and require stable gameplay before
    // using an Attack tap as animation evidence.
    NSDate* readyDeadline=[NSDate dateWithTimeIntervalSinceNow:30];
    NSDate* stableSince=nil;BOOL stableGameplay=NO;
    while([readyDeadline timeIntervalSinceNow]>0) {
        NSString* label=self.game.otherElements[@"translated-game-view"].label;
        if([label isEqual:@"Game instruction. Use Confirm to continue."]) {
            stableSince=nil;[self.game.buttons[@"game-action-2048"] tap];
        } else if([label isEqual:@"Game. Touch or drag to point. Attack confirms game menus."]) {
            if(!stableSince)stableSince=NSDate.date;
            if(-[stableSince timeIntervalSinceNow]>=6) { stableGameplay=YES;break; }
        } else stableSince=nil;
        [NSThread sleepForTimeInterval:.2];
    }
    XCTAssertTrue(stableGameplay);
    const NSUInteger heroCount=capsOnly ? 2 : ([env[@"PROTECTOR_REMAINING_HERO_BEN_ONLY"] isEqual:@"1"] ? 1 : names.count);
    NSMutableArray* observations=[NSMutableArray array];
    for(NSUInteger index=capsOnly ? 1 : 0;index<heroCount;index++) {
        NSMutableArray* expected=[NSMutableArray array];
        for(NSDictionary* entry in pack[@"entries"])
            if([entry[@"source"][@"model_offset"] isEqual:models[index]])[expected addObject:entry[@"id"]];
        XCTAssertEqual(expected.count,[counts[index] unsignedIntegerValue]);
        if(index>0) {
            // Returning to Ben preserves the current original alien selection.
            // Each next step chooses the following original unlocked alien.
            if(index>1) {
                [self.game.buttons[@"game-action-8"] tap];
                NSPredicate* ben=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary* bindings) {
                    (void)object;(void)bindings;
                    return [[self json:statePath][@"geometry_used_profiles"] containsObject:@"99_95-002d6da0-rigid-draw-28"];
                }];
                XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:ben object:self.game]] timeout:10],XCTWaiterResultCompleted);
            }
            [self.game.buttons[@"game-action-2"] tap];[self settle];
            [self.game.buttons[@"game-action-8"] tap];
        }
        NSPredicate* visible=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary* bindings) {
            (void)object;(void)bindings;
            NSArray* used=[self json:statePath][@"geometry_used_profiles"];
            return used && [[NSSet setWithArray:expected] isSubsetOfSet:[NSSet setWithArray:used]];
        }];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:visible object:self.game]] timeout:12],XCTWaiterResultCompleted);
        NSString* prefix=[@"remaining-hero-" stringByAppendingString:names[index]];
        [self settle];[self capture:[prefix stringByAppendingString:@"-entry"]];
        XCTAssertEqualObjects([self json:[diagnostics stringByAppendingPathComponent:@"native-controls.json"]][@"control_context"],@"full-controls");
        NSDictionary* first=[self json:statePath];
        XCTAssertTrue(self.game.buttons[@"game-action-2048"].hittable);
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
        [self capture:[prefix stringByAppendingString:@"-action"]];
        XCTAssertEqualObjects([self json:[diagnostics stringByAppendingPathComponent:@"native-controls.json"]][@"control_context"],@"full-controls");
        NSDictionary* after=[self json:statePath];
        for(NSDictionary* state in @[first,after]) {
            XCTAssertEqualObjects(state[@"geometry_pack_manifest_sha256"],packHash);
            XCTAssertEqualObjects(state[@"geometry_pack_entries"],@(packEntries));
            XCTAssertEqualObjects(state[@"enhanced_models_enabled"],@YES);
            for(NSString* profile in expected)XCTAssertTrue([state[@"geometry_used_profiles"] containsObject:profile]);
            XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
            XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
            XCTAssertEqualObjects(state[@"presentation_aspect"],@"native-landscape");
            XCTAssertGreaterThan([state[@"native_hud_draws"] unsignedIntegerValue],0u);
            XCTAssertEqualObjects(state[@"host_paused"],@NO);
            XCTAssertEqualObjects(state[@"motion_presentation"][@"simulation_clock_modified"],@NO);
        }
        XCTAssertGreaterThan([after[@"frame_index"] unsignedIntegerValue],[first[@"frame_index"] unsignedIntegerValue]);
        [observations addObject:@{@"hero":names[index],@"expected_profiles":expected,
            @"initial_frame":first[@"frame_index"],@"action_frame":after[@"frame_index"]}];
    }
    [self attach:@{@"scope":@"Selected changed hero models in translated gameplay, native touch selection and attack inputs; not campaign, exhaustive animation or display-rate acceptance.",
        @"heroes":observations,@"geometry_manifest_sha256":packHash} name:@"remaining-hero-observations"];
}
- (void)testObserveProminentPropGeometry {
    self.continueAfterFailure=NO;self.executionTimeAllowance=180;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_PROMINENT_PROP_QA"],@"prominent-props-v1");
    NSString* caseName=env[@"PROTECTOR_PROMINENT_PROP_CASE"];
    XCTAssertTrue(([@[@"vehicle",@"terminal",@"fourarms",@"vdrone"] containsObject:caseName]));
    NSArray* expected=[caseName isEqual:@"vehicle"] ?
        @[@"13_02-00086860-rigid-draw-0",@"13_02-00086860-rigid-draw-1",@"13_02-0009de40-rigid-draw-0",@"99_95-002f5480-draw-1"] :
        @[@"32_01-0010ba20-rigid-draw-0",@"99_95-002f5480-draw-1"];
    const BOOL hero=[caseName isEqual:@"fourarms"];
    const BOOL drone=[caseName isEqual:@"vdrone"];
    if(hero) {
        NSMutableArray* profiles=[NSMutableArray arrayWithArray:@[@"99_95-002f54e0-draw-0",@"99_95-002f54e0-draw-1",@"99_95-002f54e0-draw-2"]];
        for(NSUInteger i=3;i<=40;i++)[profiles addObject:[NSString stringWithFormat:@"99_95-00292960-rigid-draw-%lu",(unsigned long)i]];
        expected=profiles;
    }
    if(drone) {
        NSMutableArray* profiles=[NSMutableArray arrayWithObject:@"99_95-002f5480-draw-1"];
        for(NSNumber* index in @[@4,@5,@10,@11,@16,@17,@18,@19,@20,@21,@22,@23,@24,@25])
            [profiles addObject:[NSString stringWithFormat:@"32_01-00096a60-rigid-draw-%@",index]];
        expected=profiles;
    }
    self.container=env[@"PROTECTOR_AUTHORIZED_ARTWORK_CONTAINER"];
    NSString* bundle=env[@"PROTECTOR_AUTHORIZED_ARTWORK_BUNDLE"];
    NSString* identity=@"house.machine.ProtectorNative.MaterialArtworkQA";
    NSString* packHash=env[@"PROTECTOR_RIGID_PACK_SHA256"];
    XCTAssertEqual(packHash.length,64u);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],env[@"PROTECTOR_RIGID_CONFIG_SHA256"]);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"EnhancedModels/geometry.json"]]],packHash);
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"prominent-prop-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",@"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1"};
    if(hero || drone) self.game.launchEnvironment=@{@"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,
        @"PROTECTOR_CONTROLLER_QA_READBACK":@"1",@"PROTECTOR_MOTION_PRESENTATION":@"1",@"PROTECTOR_MOTION_PRESENTATION_MIN_FRAME":@"450",
        @"PROTECTOR_GEOMETRY_QA_READBACK":drone ? @"1" : @"0"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:100];
    [self controller:@"neutral"];[self pulse:@"a"];
    NSPredicate* ready=[NSPredicate predicateWithFormat:@"label IN %@",@[@"Game. Touch or drag to point. Attack confirms game menus.",@"Game instruction. Use Confirm to continue."]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:ready object:self.game.otherElements[@"translated-game-view"]]] timeout:40],XCTWaiterResultCompleted);
    for(NSUInteger i=0;i<4 && [self.game.otherElements[@"translated-game-view"].label isEqual:@"Game instruction. Use Confirm to continue."];i++) {
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
    }
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:25];
    NSString* statePath=[diagnostics stringByAppendingPathComponent:@"interactive-state.json"];
    if(drone) {
        XCUIElement* move=self.game.otherElements[@"game-move"];
        XCTAssertTrue(move.exists && move.hittable);
        CGRect frame=move.frame;XCTAssertFalse(CGRectIsEmpty(frame));
        XCUICoordinate* origin=[self.game coordinateWithNormalizedOffset:CGVectorMake(0,0)];
        XCUICoordinate* right=[origin coordinateWithOffset:CGVectorMake(CGRectGetMinX(frame)+CGRectGetWidth(frame)*.95,CGRectGetMidY(frame))];
        NSString* key=@"32_01-00096a60-rigid-draw-10";
        // The original encounter activates through a short ordinary walk.
        // Do not patch enemy state, replay the level or stop on invisible spawn draws.
        for(NSUInteger i=0;i<4 && ![[self liveGeometryState][@"geometry_used_profiles"] containsObject:key];i++)
            [right pressForDuration:1.5];
        NSDictionary* spawned=[self liveGeometryState];
        XCTAssertTrue([spawned[@"geometry_used_profiles"] containsObject:key]);
        const NSUInteger visibleFrame=[spawned[@"frame_index"] unsignedIntegerValue]+45;
        NSPredicate* visible=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary* bindings) {
            (void)object;(void)bindings;
            NSDictionary* state=[self liveGeometryState];
            return [state[@"frame_index"] unsignedIntegerValue]>=visibleFrame && [state[@"geometry_used_profiles"] containsObject:key];
        }];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:visible object:self.game]] timeout:12],XCTWaiterResultCompleted);
    }
    if(hero) {
        XCTAssertTrue(self.game.buttons[@"game-action-8"].hittable);
        [self.game.buttons[@"game-action-8"] tap];
        NSPredicate* transformed=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary* bindings) {
            (void)object;(void)bindings;
            NSDictionary* state=[self json:statePath];
            return [state[@"geometry_used_profiles"] containsObject:@"99_95-00292960-rigid-draw-40"];
        }];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:transformed object:self.game]] timeout:12],XCTWaiterResultCompleted);
    }
    NSString* prefix=[@"prominent-prop-" stringByAppendingString:caseName];
    NSDictionary* first;
    if(drone) first=[self captureLiveGeometry:[prefix stringByAppendingString:@"-entry"]];
    else { [self settle];[self capture:[prefix stringByAppendingString:@"-entry"]];first=[self json:statePath]; }
    // Check the changed model composition across one ordinary original action.
    // Reuse the prior pause/lifecycle/controller checks; do not replay them here.
    XCTAssertTrue(self.game.buttons[@"game-action-2048"].hittable);
    [self.game.buttons[@"game-action-2048"] tap];
    NSDictionary* after;
    if([env[@"PROTECTOR_MOVE_LABEL_QA"] boolValue]) {
        // XCTest's predicate waiter first sampled over a second after the
        // tap, missing this short source label. Read the existing diagnostic
        // receipt immediately, without an accessibility snapshot/idle wait.
        const NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+3;
        BOOL visible=NO;
        do {
            visible=[[self liveGeometryState][@"native_move_labels"][@"count"] unsignedIntegerValue]==2;
            if(visible)break;
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
        } while(NSProcessInfo.processInfo.systemUptime<deadline);
        XCTAssertTrue(visible);
    }
    if(drone) after=[self captureLiveGeometry:[prefix stringByAppendingString:@"-action"]];
    else { [self capture:[prefix stringByAppendingString:@"-action"]];after=[self json:statePath]; }
    if([env[@"PROTECTOR_MOVE_LABEL_QA"] boolValue])
        XCTAssertEqualObjects(after[@"native_move_labels"][@"count"],@2);
    for(NSDictionary* state in @[first,after]) {
        XCTAssertEqualObjects(state[@"geometry_pack_manifest_sha256"],packHash);
        XCTAssertEqualObjects(state[@"geometry_pack_entries"],drone ? @194 : hero ? @61 : @23);
        XCTAssertEqualObjects(state[@"enhanced_models_enabled"],@YES);
        for(NSString* profile in expected)XCTAssertTrue([state[@"geometry_used_profiles"] containsObject:profile]);
        XCTAssertGreaterThanOrEqual([state[@"geometry_refined_draws"] unsignedIntegerValue],expected.count);
        XCTAssertEqualObjects(state[@"presentation_aspect"],@"native-landscape");
        XCTAssertGreaterThan([state[@"native_hud_draws"] unsignedIntegerValue],0u);
        XCTAssertEqualObjects(state[@"host_paused"],@NO);
        XCTAssertEqualObjects(state[@"motion_presentation"][@"simulation_clock_modified"],@NO);
    }
    XCTAssertGreaterThan([after[@"frame_index"] unsignedIntegerValue],[first[@"frame_index"] unsignedIntegerValue]);
    [self attach:@{@"scope":@"One changed prominent-prop view in translated gameplay with a touch action; not campaign, full-model, lifecycle, controller-hardware or performance acceptance.",
        @"case":caseName,@"geometry_manifest_sha256":packHash,@"initial_frame":first[@"frame_index"],@"action_frame":after[@"frame_index"]}
        name:[prefix stringByAppendingString:@"-observation"]];
}
- (void)testObserveRigidPropGeometry {
    self.continueAfterFailure=NO;self.executionTimeAllowance=180;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_RIGID_PROP_QA"],@"visible-drum-v2");
    self.container=env[@"PROTECTOR_AUTHORIZED_ARTWORK_CONTAINER"];
    NSString* bundle=env[@"PROTECTOR_AUTHORIZED_ARTWORK_BUNDLE"];
    NSString* identity=@"house.machine.ProtectorNative.MaterialArtworkQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],env[@"PROTECTOR_RIGID_CONFIG_SHA256"]);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"EnhancedModels/geometry.json"]]],env[@"PROTECTOR_RIGID_PACK_SHA256"]);
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"rigid-prop-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",@"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:100];
    [self controller:@"neutral"];[self pulse:@"a"];
    NSPredicate* ready=[NSPredicate predicateWithFormat:@"label IN %@",@[@"Game. Touch or drag to point. Attack confirms game menus.",@"Game instruction. Use Confirm to continue."]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:ready object:self.game.otherElements[@"translated-game-view"]]] timeout:40],XCTWaiterResultCompleted);
    for(NSUInteger i=0;i<4 && [self.game.otherElements[@"translated-game-view"].label isEqual:@"Game instruction. Use Confirm to continue."];i++) {
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
    }
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:25];
    [self settle];[self capture:@"rigid-prop-native-entry"];
    NSString* statePath=[diagnostics stringByAppendingPathComponent:@"interactive-state.json"];
    NSDictionary* first=[self json:statePath];
    XCTAssertEqualObjects(first[@"geometry_pack_manifest_sha256"],env[@"PROTECTOR_RIGID_PACK_SHA256"]);
    XCTAssertEqualObjects(first[@"geometry_pack_entries"],@20);
    XCTAssertEqualObjects(first[@"enhanced_models_enabled"],@YES);
    XCTAssertTrue([first[@"geometry_used_profiles"] containsObject:@"13_02-0009de40-rigid-draw-0"]);
    XCTAssertTrue([first[@"geometry_used_profiles"] containsObject:@"99_95-002f5480-draw-1"]);
    XCTAssertGreaterThanOrEqual([first[@"geometry_refined_draws"] unsignedIntegerValue],5u);
    XCTAssertEqualObjects(first[@"presentation_aspect"],@"native-landscape");
    XCTAssertGreaterThan([first[@"native_hud_draws"] unsignedIntegerValue],0u);
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
    [self capture:@"rigid-prop-native-paused"];
    XCTAssertEqualObjects([self json:statePath][@"host_paused"],@YES);
    [self.game.buttons[@"Resume"] tap];
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:8];
    // One bounded original action after resume; no progression or destruction route.
    XCTAssertTrue(self.game.buttons[@"game-action-2048"].hittable);
    [self.game.buttons[@"game-action-2048"] tap];
    [self capture:@"rigid-prop-native-resumed"];
    NSDictionary* resumed=[self json:statePath];
    XCTAssertGreaterThan([resumed[@"frame_index"] unsignedIntegerValue],[first[@"frame_index"] unsignedIntegerValue]);
    XCTAssertEqualObjects(resumed[@"host_paused"],@NO);
    XCTAssertTrue([resumed[@"geometry_used_profiles"] containsObject:@"13_02-0009de40-rigid-draw-0"]);
    [self attach:@{@"scope":@"One actual iPhone-simulator prop integration view, native pause/resume and original action. Not campaign, full-model, controller-hardware or performance acceptance.",
        @"geometry_manifest_sha256":env[@"PROTECTOR_RIGID_PACK_SHA256"],@"initial_frame":first[@"frame_index"],@"resumed_frame":resumed[@"frame_index"]}
        name:@"rigid-prop-native-observation"];
}
- (void)testObserveSceneFraming {
    self.continueAfterFailure=NO;self.executionTimeAllowance=240;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_SCENE_OBSERVER_VERSION"],@"source-scene-framing-v1");
    self.container=env[@"PROTECTOR_ANIMATED_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires isolated source-framing fixture");
    NSString* identity=@"house.machine.ProtectorNative.MaterialArtworkQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* bundle=env[@"PROTECTOR_ANIMATED_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],env[@"PROTECTOR_ANIMATED_SOURCE_CONFIG_SHA256"]);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"RestoredArt/pack.json"]]],env[@"PROTECTOR_ANIMATED_PACK_SHA256"]);
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"scene-framing-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",@"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    self.game.launchEnvironment=@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",@"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",@"PROTECTOR_INTERFACE_AUDIT_FRAME":@"1",@"PROTECTOR_SCENE_EDGE_AUDIT":@"1"};
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:120];
    [self controller:@"neutral"];[self pulse:@"a"];
    NSPredicate* ready=[NSPredicate predicateWithFormat:@"label IN %@",@[@"Game. Touch or drag to point. Attack confirms game menus.",@"Game instruction. Use Confirm to continue."]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:ready object:self.game.otherElements[@"translated-game-view"]]] timeout:40],XCTWaiterResultCompleted);
    for(NSUInteger i=0;i<4;i++) {
        if(![self.game.otherElements[@"translated-game-view"].label isEqual:@"Game instruction. Use Confirm to continue."])break;
        XCUIElement* confirm=self.game.buttons[@"game-action-2048"];XCTAssertTrue(confirm.hittable);[confirm tap];[self settle];
    }
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:25];
    [self settle];[self capture:@"scene-framing-entry"];
    NSString* audit=[diagnostics stringByAppendingPathComponent:@"interface-source/scene-edges.json"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:audit]);
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* table=self.game.tables[@"native-game-settings"];XCTAssertTrue([table waitForExistenceWithTimeout:8]);
    XCUIElement* motion=self.game.switches[@"render.motion"];
    for(NSUInteger i=0;i<12 && !motion.hittable;i++)[table swipeUp];
    XCTAssertTrue(motion.hittable);XCTAssertEqualObjects(motion.value,@"1");[motion tap];
    [self.game.buttons[@"Resume"] tap];
    NSPredicate* exists=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary* bindings){return [NSFileManager.defaultManager fileExistsAtPath:audit];}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc] initWithPredicate:exists object:self.game]] timeout:40],XCTWaiterResultCompleted);
    NSDictionary* report=[self json:audit];
    XCTAssertEqualObjects(report[@"source"],@"translated_execution_callback");
    XCTAssertEqualObjects(report[@"source_vertices_immutable"],@YES);
    XCTAssertEqualObjects(report[@"guest_updates_during_inspection"],@0);
    XCTAssertGreaterThan([report[@"identities"] count],0u);
    NSMutableSet* names=[NSMutableSet set];
    for(NSDictionary* sample in report[@"samples"]) {
        [names addObject:sample[@"image"]];NSDictionary* state=sample[@"state"];
        XCTAssertEqualObjects(state[@"frame_index"],report[@"frame_index"]);
        XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
        XCTAssertEqualObjects(state[@"texture_pack_manifest_sha256"],env[@"PROTECTOR_ANIMATED_PACK_SHA256"]);
        XCTAssertEqualObjects(state[@"texture_pack_entries"],@([env[@"PROTECTOR_ANIMATED_PACK_ENTRIES"] integerValue]));
    }
    NSSet* expectedNames=[NSSet setWithArray:@[@"scene-native.png",@"scene-native-no-cull.png",@"scene-draw-identifiers.png",@"scene-draw-identifiers-no-cull.png",@"scene-source-artwork.png"]];
    XCTAssertTrue([expectedNames isSubsetOfSet:names]);
    [self capture:@"scene-framing-diagnostic"];
    [self attach:@{@"scene":env[@"PROTECTOR_MATERIAL_SCENE"],@"variants":names.allObjects,@"frame":report[@"frame_index"],@"scope":@"Frozen scene diagnosis only. No movement, campaign, appearance or framing correction acceptance."} name:@"scene-framing-observation"];
    [self.game.buttons[@"native-pause"] tap];
}
- (void)testObserveEnvironmentMaterials {
    self.continueAfterFailure=NO;self.executionTimeAllowance=240;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    NSString* version=@"environment-material-isolation-v5";
    XCTAssertEqualObjects(env[@"PROTECTOR_MATERIAL_OBSERVER_VERSION"],version);
    self.container=env[@"PROTECTOR_ANIMATED_SOURCE_CONTAINER"];
    XCTSkipIf(!self.container.length,@"Requires a separate material-artwork QA app");
    NSString* identity=@"house.machine.ProtectorNative.MaterialArtworkQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* bundle=env[@"PROTECTOR_ANIMATED_SOURCE_BUNDLE"];
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        env[@"PROTECTOR_ANIMATED_SOURCE_CONFIG_SHA256"]);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"RestoredArt/pack.json"]]],
        env[@"PROTECTOR_ANIMATED_PACK_SHA256"]);
    NSArray* keys=[env[@"PROTECTOR_ANIMATED_COLOR_KEYS"] componentsSeparatedByString:@","];
    XCTAssertTrue(keys.count>0 && keys.count<=8);
    XCTAssertEqual([NSSet setWithArray:keys].count,keys.count);
    BOOL requireRestored=[env[@"PROTECTOR_MATERIAL_REQUIRE_RESTORED"] isEqual:@"1"];
    BOOL isolate=[env[@"PROTECTOR_MATERIAL_ISOLATE"] isEqual:@"1"];
    BOOL inspectionOnly=[env[@"PROTECTOR_MATERIAL_INSPECTION_ONLY"] isEqual:@"1"];
    if(env[@"PROTECTOR_MATERIAL_INSPECTION_ONLY"]) {
        XCTAssertTrue(inspectionOnly && isolate && requireRestored);
    }
    if(env[@"PROTECTOR_MATERIAL_ISOLATE"]) {
        XCTAssertTrue(isolate && requireRestored);
    }
    NSArray* added=requireRestored ? [env[@"PROTECTOR_MATERIAL_ADDED_KEYS"] componentsSeparatedByString:@","] : @[];
    NSUInteger entries=[env[@"PROTECTOR_ANIMATED_PACK_ENTRIES"] integerValue];
    // The integration pack can grow without changing the selected-material
    // observation. Runtime byte budgets, not the old 874-entry fixture, bound it.
    XCTAssertTrue(entries>=812 && entries<=4096);
    if(requireRestored) {
        XCTAssertTrue(added.count>=keys.count && added.count<=16);
        XCTAssertEqual([NSSet setWithArray:added].count,added.count);
        XCTAssertTrue([[NSSet setWithArray:keys] isSubsetOfSet:[NSSet setWithArray:added]]);
    }
    NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:diagnostics]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"material-source-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString* materialReadyPath=[self.commandPath stringByAppendingString:@".materials-ready"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:materialReadyPath]);
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",
        @"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    NSMutableDictionary* launch=[@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",
        @"PROTECTOR_MATERIAL_AUDIT_KEYS":env[@"PROTECTOR_ANIMATED_COLOR_KEYS"],
        @"PROTECTOR_MATERIAL_AUDIT_READY_PATH":materialReadyPath} mutableCopy];
    if(isolate)launch[@"PROTECTOR_MATERIAL_AUDIT_ISOLATE"]=@"1";
    self.game.launchEnvironment=launch;
    [self.game launch];[self waitForLabel:@"Game ready. Use Confirm to continue." timeout:120];
    [self controller:@"neutral"];[self pulse:@"a"];
    NSPredicate* ready=[NSPredicate predicateWithFormat:@"label IN %@",@[
        @"Game. Touch or drag to point. Attack confirms game menus.",@"Game instruction. Use Confirm to continue."]];
    XCTNSPredicateExpectation* arrived=[[XCTNSPredicateExpectation alloc] initWithPredicate:ready
        object:self.game.otherElements[@"translated-game-view"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[arrived] timeout:40],XCTWaiterResultCompleted);
    NSMutableArray* inputs=[NSMutableArray array];
    for(NSUInteger prompt=0;prompt<4;prompt++) {
        if(![self.game.otherElements[@"translated-game-view"].label isEqual:@"Game instruction. Use Confirm to continue."])break;
        XCUIElement* confirm=self.game.buttons[@"game-action-2048"];
        XCTAssertTrue(confirm.hittable);XCTAssertEqualObjects(confirm.label,@"Confirm");
        [inputs addObject:@{@"name":@"tutorial-confirm",@"unix":@(NSDate.date.timeIntervalSince1970)}];
        [confirm tap];[self settle];
    }
    [self waitForLabel:@"Game. Touch or drag to point. Attack confirms game menus." timeout:25];
    [self settle];[self capture:@"material-entry"];
    NSDictionary* entryControls=[self json:[diagnostics stringByAppendingPathComponent:@"native-controls.json"]];
    XCTAssertEqualObjects(entryControls[@"control_context"],@"full-controls");
    XCTAssertEqualObjects(entryControls[@"manually_paused"],@NO);
    for(NSUInteger i=0;i<keys.count;i++) {
        NSString* captureDirectory=[diagnostics stringByAppendingPathComponent:
            [NSString stringWithFormat:@"material-source-%02lu",(unsigned long)i]];
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:captureDirectory]);
    }
    XCTAssertTrue([[@"ready\n" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:materialReadyPath
        options:NSDataWritingWithoutOverwriting error:nil]);
    if(inspectionOnly) {
        // Material qualification does not require movement. In 13_04 that input
        // opens a new-enemy introduction, correctly hiding the Jump control.
        NSPredicate* inspectionsReady=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary* bindings) {
            for(NSUInteger i=0;i<keys.count;i++) {
                NSString* path=[diagnostics stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"material-source-%02lu/inspection.json",(unsigned long)i]];
                if(![NSFileManager.defaultManager fileExistsAtPath:path])return NO;
            }
            return YES;
        }];
        XCTNSPredicateExpectation* inspected=[[XCTNSPredicateExpectation alloc]
            initWithPredicate:inspectionsReady object:self.game];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[inspected] timeout:40],XCTWaiterResultCompleted);
        [self capture:@"material-isolation-ready"];
    } else {
    XCUIElement* move=self.game.otherElements[@"game-move"];
    XCTAssertTrue(move.exists && move.hittable);CGRect frame=move.frame;XCTAssertFalse(CGRectIsEmpty(frame));
    XCUICoordinate* origin=[self.game coordinateWithNormalizedOffset:CGVectorMake(0,0)];
    XCUICoordinate* right=[origin coordinateWithOffset:CGVectorMake(CGRectGetMinX(frame)+CGRectGetWidth(frame)*.85,CGRectGetMidY(frame))];
    [inputs addObject:@{@"name":@"short-right",@"seconds":@.35,@"unix":@(NSDate.date.timeIntervalSince1970)}];
    [right pressForDuration:.35];[self settle];[self capture:@"material-short-right"];
    XCUIElement* jump=self.game.buttons[@"game-action-8192"];XCTAssertTrue(jump.hittable);
    [inputs addObject:@{@"name":@"jump",@"unix":@(NSDate.date.timeIntervalSince1970)}];
    [jump tap];[self settle];[self capture:@"material-jump"];
    }
    NSMutableArray* found=[NSMutableArray array];
    for(NSUInteger i=0;i<keys.count;i++) {
        NSString* path=[diagnostics stringByAppendingPathComponent:[NSString stringWithFormat:@"material-source-%02lu/inspection.json",(unsigned long)i]];
        if(![NSFileManager.defaultManager fileExistsAtPath:path])continue;
        NSDictionary* report=[self json:path];
        XCTAssertEqualObjects(report[@"source_key"],keys[i]);
        XCTAssertEqualObjects(report[@"source_vertices_immutable"],@YES);
        XCTAssertEqualObjects(report[@"guest_updates_during_inspection"],@0);
        XCTAssertEqualObjects(report[@"readiness_gate_configured"],@YES);
        XCTAssertEqualObjects(report[@"readiness_gate_released"],@YES);
        XCTAssertEqual([report[@"samples"] count],2u);[found addObject:keys[i]];
        NSDictionary* source=report[@"samples"][0][@"state"];
        NSDictionary* restored=report[@"samples"][1][@"state"];
        XCTAssertEqualObjects(source[@"restored_artwork_enabled"],@NO);
        XCTAssertEqualObjects(restored[@"restored_artwork_enabled"],@YES);
        XCTAssertEqualObjects(restored[@"texture_pack_entries"],@(entries));
        XCTAssertEqualObjects(restored[@"texture_pack_manifest_sha256"],env[@"PROTECTOR_ANIMATED_PACK_SHA256"]);
        XCTAssertEqualObjects(restored[@"audio_output"],@"disabled");
        XCTAssertLessThanOrEqual([restored[@"texture_pack_frame_bytes"] unsignedLongLongValue],
            [restored[@"texture_pack_allocation_budget_bytes"] unsignedLongLongValue]);
        XCTAssertLessThanOrEqual([restored[@"texture_pack_frame_encoded_bytes"] unsignedLongLongValue],
            [restored[@"texture_pack_encoded_budget_bytes"] unsignedLongLongValue]);
        XCTAssertEqualObjects(report[@"isolation_enabled"],@(isolate));
        XCTAssertEqual([report[@"isolation_samples"] count],isolate ? 3u : 0u);
        if(isolate) {
            NSArray* variants=report[@"isolation_samples"];
            NSSet* baseline=[NSSet setWithArray:variants[0][@"state"][@"texture_pack_frame_sources"]];
            XCTAssertTrue([baseline containsObject:keys[i]]);
            for(NSUInteger variant=0;variant<3;variant++) {
                NSDictionary* state=variants[variant][@"state"];
                XCTAssertEqualObjects(state[@"restored_artwork_enabled"],@YES);
                XCTAssertEqualObjects(state[@"material_audit_source_only_key"],variant==1 ? keys[i] : NSNull.null);
                XCTAssertEqualObjects(state[@"frame_index"],restored[@"frame_index"]);
                XCTAssertEqualObjects(state[@"texture_pack_manifest_sha256"],env[@"PROTECTOR_ANIMATED_PACK_SHA256"]);
                XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
                NSSet* used=[NSSet setWithArray:state[@"texture_pack_frame_sources"]];
                if(variant==1) {
                    XCTAssertFalse([used containsObject:keys[i]]);
                    XCTAssertTrue([used isSubsetOfSet:baseline]);
                } else XCTAssertEqualObjects(used,baseline);
            }
        }
        // These frozen samples contain renderer state, not session status.
        // capture: already checks the session's runtime_error for every capture.
        if(requireRestored) {
            NSMutableSet* materialKeys=[NSMutableSet set];
            for(NSDictionary* draw in report[@"draws"])
                for(NSDictionary* stage in draw[@"stages"])
                    if([added containsObject:stage[@"source_key"]])[materialKeys addObject:stage[@"source_key"]];
            XCTAssertTrue([materialKeys containsObject:keys[i]]);
            XCTAssertTrue([materialKeys isSubsetOfSet:[NSSet setWithArray:restored[@"texture_pack_frame_sources"]]]);
        }
    }
    if(requireRestored)XCTAssertEqualObjects([NSSet setWithArray:found],[NSSet setWithArray:keys]);
    [self attach:@{@"observer_version":version,@"requested_keys":keys,@"observed_keys":found,@"inputs":inputs,
        @"scene":env[@"PROTECTOR_MATERIAL_SCENE"] ?: @"unspecified",@"require_restored":@(requireRestored),
        @"isolation_enabled":@(isolate),
        @"inspection_only":@(inspectionOnly),
        @"scope":inspectionOnly ? @"One direct-entry frozen artwork observation without movement; not campaign, gameplay, all-consumer or performance acceptance."
            : @"One direct-entry artwork observation and bounded inputs, not campaign, combat, all-consumer or performance acceptance."}
        name:@"environment-material-source-observation"];
    [self.game.buttons[@"native-pause"] tap];
}
@end
