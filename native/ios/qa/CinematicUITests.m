#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

// Ordinary cold boot in a separately installed QA identity. No level jump,
// cinematic player or source-clock override is used by this test.
@interface ProtectorCinematicUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* auditPath;
@property(nonatomic) BOOL preparationOnly;
@property(nonatomic) BOOL disablePreparation;
@end

@implementation ProtectorCinematicUITests
- (NSArray<NSDictionary*>*)rows {
    NSString* content = [NSString stringWithContentsOfFile:self.auditPath
        encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray* rows = [NSMutableArray array];
    for (NSString* line in [content componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        id row = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
            options:0 error:nil];
        if ([row isKindOfClass:NSDictionary.class]) [rows addObject:row];
    }
    return rows;
}
- (void)waitFor:(BOOL (^)(NSDictionary*))matches timeout:(NSTimeInterval)timeout {
    // XCTest predicates are normally polled about once a second. Movie capture
    // windows can be shorter than that; poll the read-only witness explicitly.
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSDictionary* last = @{};
    do {
        last = [self rows].lastObject ?: @{};
        if (matches(last)) return;
        [NSThread sleepForTimeInterval:0.05];
    } while ([deadline timeIntervalSinceNow] > 0);
    XCTFail(@"Movie witness did not reach the requested capture state; last source=%@",last[@"source"]);
}
- (void)capture:(NSString*)name {
    XCTAttachment* attachment = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    attachment.name = name; attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
}
- (void)testRestoredCinematicAndOriginalHandoff {
    [self checkRestoredMovie:@"D3.bik" auditFrame:90
        captures:@[@{@"first":@60,@"end":@110,@"name":@"restored-d3-native-presentation"}]
        minimumRestored:140];
}
- (void)testRestoredHVSIntroAndOriginalHandoff {
    [self checkRestoredMovie:@"HVSIntro.bik" auditFrame:270
        captures:@[@{@"first":@60,@"end":@85,@"name":@"restored-hvs-locker"},
                   @{@"first":@260,@"end":@290,@"name":@"restored-hvs-power-button"},
                   @{@"first":@600,@"end":@625,@"name":@"restored-hvs-final-attribution"}]
        minimumRestored:620];
}
- (void)testRestoredFirstStoryAndOriginalHandoff {
    [self checkRestoredMovie:@"11_intro.bik" auditFrame:1380
        captures:@[@{@"first":@60,@"end":@110,@"name":@"restored-story-opening"},
                   @{@"first":@1300,@"end":@1340,@"name":@"restored-story-max"},
                   @{@"first":@1800,@"end":@1850,@"name":@"restored-story-family"},
                   @{@"first":@2170,@"end":@2210,@"name":@"restored-story-ending"}]
        minimumRestored:2100];
}
- (void)testRestoredLibraryCNAndOriginalHandoff {
    // This title/region opens CN, D3 and HVSIntro. legal.bik is present in the
    // source library but is not part of this unmodified cold-boot sequence.
    [self checkRestoredMovie:@"CN.bik" auditFrame:90
        captures:@[@{@"first":@60,@"end":@110,@"name":@"restored-library-cn-native"}]
        minimumRestored:200];
}
- (void)testPreparedStoryOpening {
    self.preparationOnly = YES;
    [self checkRestoredMovie:@"11_intro.bik" auditFrame:60
        captures:@[@{@"first":@75,@"end":@110,@"name":@"prepared-story-opening"}]
        minimumRestored:40];
}
- (void)testUnpreparedStoryOpeningBaseline {
    self.preparationOnly = YES;
    self.disablePreparation = YES;
    [self checkRestoredMovie:@"11_intro.bik" auditFrame:60
        captures:@[@{@"first":@75,@"end":@110,@"name":@"unprepared-story-opening-baseline"}]
        minimumRestored:40];
}
- (void)waitForGameLabel:(NSString*)label timeout:(NSTimeInterval)timeout {
    XCTNSPredicateExpectation* expected = [[XCTNSPredicateExpectation alloc]
        initWithPredicate:[NSPredicate predicateWithFormat:@"label == %@",label]
        object:self.game.otherElements[@"translated-game-view"]];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expected] timeout:timeout],
        XCTWaiterResultCompleted,@"Expected source context %@",label);
}
- (void)settleMenu {
    XCTestExpectation* delay = [self expectationWithDescription:@"source menu animation settles"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),
        dispatch_get_main_queue(),^{ [delay fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[delay] timeout:5],XCTWaiterResultCompleted);
}
- (void)beginFirstStory {
    [self waitForGameLabel:@"Game title. Use Confirm to begin." timeout:90];
    [self.game.buttons[@"game-action-2048"] tap];
    [self waitForGameLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:10];
    [self settleMenu];
    [self.game.buttons[@"game-action-2048"] tap]; // New Game
    [self settleMenu];
    [self.game.buttons[@"game-action-2048"] tap]; // original default difficulty
    [self settleMenu];
    [self.game.buttons[@"game-action-2048"] tap]; // verified empty isolated slot
}
- (void)checkRestoredMovie:(NSString*)movie auditFrame:(NSUInteger)auditFrame
    captures:(NSArray<NSDictionary*>*)captures minimumRestored:(NSUInteger)minimumRestored {
    self.continueAfterFailure = NO;
    BOOL firstStory = [movie isEqual:@"11_intro.bik"];
    BOOL libraryCN = [movie isEqual:@"CN.bik"];
    BOOL fullPicture = firstStory || libraryCN;
    NSString* expectedIdentity=self.preparationOnly ? @"house.machine.ProtectorNative.CinematicWarmQA" :
        libraryCN ? @"house.machine.ProtectorNative.FullLibraryQA" :
        @"house.machine.ProtectorNative.CinematicQA";
    self.executionTimeAllowance = firstStory ? 300 : 120;
    NSString* container = NSProcessInfo.processInfo.environment[@"PROTECTOR_CINEMATIC_QA_CONTAINER"];
    XCTSkipIf(!container.length, @"Requires a separately selected CinematicQA container");
    NSString* bundle = NSProcessInfo.processInfo.environment[@"PROTECTOR_CINEMATIC_QA_BUNDLE"];
    XCTAssertTrue(bundle.length > 0, @"Select the installed CinematicQA bundle for startup preflight");
    NSDictionary* bundleInfo = [NSDictionary dictionaryWithContentsOfFile:
        [bundle stringByAppendingPathComponent:@"Info.plist"]];
    XCTAssertEqualObjects(bundleInfo[@"CFBundleIdentifier"],expectedIdentity);
    if(libraryCN || self.preparationOnly) {
        NSData* packData=[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"RestoredCinematics/cinematics.json"]];
        NSDictionary* pack=packData ? [NSJSONSerialization JSONObjectWithData:packData options:0 error:nil] : nil;
        XCTAssertEqual([pack[@"entries"] count],76u,@"Full-library integration must use all 76 source movies");
        XCTAssertEqualObjects(pack[@"pack_id"],@"cinematic-library-v1");
    }
    NSData* startup = [NSData dataWithContentsOfFile:
        [bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]];
    XCTAssertEqual(startup.length,2622u,@"Cinematic capture requires the original startup configuration");
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(startup.bytes,(CC_LONG)startup.length,digest);
    NSMutableString* startupHash = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); ++i) [startupHash appendFormat:@"%02x",digest[i]];
    XCTAssertEqualObjects(startupHash,@"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919",
        @"A prepared level-sample bundle bypasses the intro; do not compensate with game input");
    NSDictionary* identity = [NSDictionary dictionaryWithContentsOfFile:[container
        stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    XCTAssertEqualObjects(identity[@"MCMMetadataIdentifier"],expectedIdentity);
    if (firstStory) {
        NSData* save = [NSData dataWithContentsOfFile:[container stringByAppendingPathComponent:
            @"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"]];
        if (save) {
            CC_SHA256(save.bytes,(CC_LONG)save.length,digest);
            NSMutableString* saveHash = [NSMutableString string];
            for (NSUInteger i = 0; i < sizeof(digest); ++i) [saveHash appendFormat:@"%02x",digest[i]];
            XCTAssertEqualObjects(saveHash,@"1f042e294eae3f669e5bad7e0a63b56b7f7da19d88beeacc6a3426ba4fa7d273",
                @"Refuse New Game over a nonempty isolated QA save");
        }
    }
    self.auditPath = [container stringByAppendingPathComponent:@"Documents/Diagnostics/cinematic-presentation.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[container
        stringByAppendingPathComponent:@"Documents/Diagnostics/cinematic-source"]],
        @"Use a fresh isolated audit container or preserve the previous diagnostic directory first");
    XCUIDevice.sharedDevice.orientation = UIDeviceOrientationLandscapeLeft;
    self.game = [[XCUIApplication alloc] initWithBundleIdentifier:expectedIdentity];
    self.game.launchArguments = @[@"-touch.hideWithController.v1",@"NO"];
    self.game.launchEnvironment = @{@"PROTECTOR_CINEMATIC_AUDIT_MOVIE":movie,
        @"PROTECTOR_CINEMATIC_AUDIT_FRAME":[NSString stringWithFormat:@"%lu",(unsigned long)auditFrame],
        @"PROTECTOR_CINEMATIC_PREPARATION_DISABLED":self.disablePreparation ? @"1" : @"0"};
    [self.game launch];
    if (firstStory) [self beginFirstStory];
    NSMutableArray* captureBounds = [NSMutableArray array];
    for (NSDictionary* capture in captures) {
        [self waitFor:^BOOL(NSDictionary* row) {
            return [row[@"source"][@"replacement_active"] boolValue] &&
                [row[@"source"][@"movie"] isEqual:movie] &&
                [row[@"source"][@"decoded_frame_zero_based"] unsignedIntValue] >= [capture[@"first"] unsignedIntValue] &&
                [row[@"source"][@"decoded_frame_zero_based"] unsignedIntValue] <= [capture[@"end"] unsignedIntValue];
        } timeout:90];
        NSDictionary* before = [self rows].lastObject;
        [self capture:capture[@"name"]];
        NSDictionary* after = [self rows].lastObject;
        XCTAssertEqualObjects(before[@"source"][@"movie"],movie);
        XCTAssertEqualObjects(after[@"source"][@"movie"],movie);
        XCTAssertTrue([before[@"source"][@"replacement_active"] boolValue]);
        XCTAssertTrue([after[@"source"][@"replacement_active"] boolValue]);
        [captureBounds addObject:@{@"name":capture[@"name"],@"before":before,@"after":after}];
    }
    NSData* bounds = [NSJSONSerialization dataWithJSONObject:captureBounds
        options:NSJSONWritingPrettyPrinted error:nil];
    XCTAttachment* metadata = [XCTAttachment attachmentWithData:bounds uniformTypeIdentifier:@"public.json"];
    metadata.name = @"native-capture-source-frame-bounds";
    metadata.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:metadata];
    if (self.preparationOnly) {
        [self waitFor:^BOOL(NSDictionary* row) {
            return [row[@"source"][@"decoded_frame_zero_based"] unsignedIntValue] >= 120;
        } timeout:10];
        [self.game.buttons[@"native-pause"] tap];
        XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:10]);
        NSArray<NSDictionary*>* rows = [self rows];
        NSUInteger restored = 0;
        for (NSDictionary* row in rows) {
            NSDictionary* source = row[@"source"];
            NSDictionary* pack = row[@"replacement_pack"];
            XCTAssertEqualObjects(source[@"movie"],movie);
            XCTAssertEqualObjects(row[@"audio_output"],@"disabled");
            XCTAssertEqualObjects(pack[@"failure"],NSNull.null);
            XCTAssertLessThanOrEqual([pack[@"cached_frames"] count],7u);
            XCTAssertEqual([pack[@"prepared_source_open"] boolValue],!self.disablePreparation);
            if (!self.disablePreparation) XCTAssertGreaterThan([pack[@"source_open_lead_ms"] doubleValue],0.0);
            if ([source[@"replacement_active"] boolValue]) {
                ++restored;
                XCTAssertEqualObjects(source[@"replacement_frame_zero_based"],source[@"decoded_frame_zero_based"]);
                XCTAssertEqualObjects(source[@"replacement_dimensions"],(@[@2880,@2160]));
            }
        }
        XCTAssertGreaterThan(restored,minimumRestored);
        XCTAttachment* log = [XCTAttachment attachmentWithString:[NSString stringWithContentsOfFile:
            self.auditPath encoding:NSUTF8StringEncoding error:nil]];
        log.name = @"cinematic-source-frame-readback"; log.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:log];
        // Deliberately ends in native Pause near the opening, not a repeated
        // full-film handoff or campaign/performance sample.
        return;
    }
    [self waitFor:^BOOL(NSDictionary* row) { return [row[@"handoff"] boolValue]; } timeout:20];
    NSArray<NSDictionary*>* rows = [self rows];
    NSUInteger restored = 0;
    for (NSDictionary* row in rows) {
        NSDictionary* source = row[@"source"];
        XCTAssertEqualObjects(row[@"audio_output"],@"disabled");
        XCTAssertEqualObjects(row[@"replacement_pack"][@"failure"],NSNull.null);
        XCTAssertLessThanOrEqual([row[@"replacement_pack"][@"cached_frames"] count],7u);
        if ([source[@"replacement_active"] boolValue]) {
            ++restored;
            XCTAssertEqualObjects(source[@"replacement_frame_zero_based"],source[@"decoded_frame_zero_based"]);
            XCTAssertEqualObjects(source[@"movie"],movie);
            XCTAssertEqualObjects(source[@"replacement_dimensions"],
                (fullPicture ? @[@2880,@2160] : @[@3840,@2160]));
        }
    }
    XCTAssertGreaterThan(restored,minimumRestored);
    XCTAssertFalse([rows.lastObject[@"source"][@"replacement_active"] boolValue]);
    XCTAssertEqual([rows.lastObject[@"replacement_pack"][@"cached_frames"] count],0u);
    if (firstStory) {
        [self waitForGameLabel:@"Game ready. Use Confirm to continue." timeout:45];
        [self capture:@"original-story-ready-handoff"];
    } else if (libraryCN) {
        // Source ownership has returned, but the next movie starts on black.
        // The visible proof is the settled original title, not that transition.
        [self waitForGameLabel:@"Game title. Use Confirm to begin." timeout:60];
        [self capture:@"original-title-handoff"];
    } else if ([movie isEqual:@"HVSIntro.bik"]) {
        // The source handoff includes a short black transition. Capture the
        // actual title readiness, not that transient blank screen.
        XCUIElement* confirm = self.game.buttons[@"game-action-2048"];
        XCTNSPredicateExpectation* title = [[XCTNSPredicateExpectation alloc]
            initWithPredicate:[NSPredicate predicateWithFormat:@"label == 'Confirm' AND hittable == YES"]
            object:confirm];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[title] timeout:15],XCTWaiterResultCompleted);
        [self capture:@"original-title-handoff"];
    } else {
        [self capture:@"original-cinematic-handoff"];
    }
    XCTAttachment* log = [XCTAttachment attachmentWithString:[NSString stringWithContentsOfFile:
        self.auditPath encoding:NSUTF8StringEncoding error:nil]];
    log.name = @"cinematic-source-frame-readback"; log.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:log];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:10]);
    XCTAssertTrue(self.game.navigationBars[@"Paused"].exists);
    XCTestExpectation* settled = [self expectationWithDescription:@"native sheet transition finished"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [settled fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[settled] timeout:3],XCTWaiterResultCompleted);
    [self capture:@"cinematic-final-native-settings"];
}
- (void)tearDown {
    [self.game terminate]; // process termination, not clean-stop acceptance
    [super tearDown];
}
@end
