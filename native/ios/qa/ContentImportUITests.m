#import <XCTest/XCTest.h>

@interface ProtectorContentImportUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@end
@implementation ProtectorContentImportUITests
- (void)setUp {
    self.continueAfterFailure=NO;
    self.executionTimeAllowance=180;
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:@"house.machine.ProtectorNative.PersonalQA"];
    self.game.launchEnvironment=@{@"PROTECTOR_FORCE_SILENT":@"1"};
    [self.game launch];
    XCTAssertTrue([self.game.buttons[@"choose-content-package"] waitForExistenceWithTimeout:20]);
}
- (void)capture:(NSString*)name {
    XCTAttachment* capture=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    capture.name=name;
    capture.lifetime=XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:capture];
}
- (void)reveal:(XCUIElement*)element {
    for (unsigned i=0;i<8 && !element.hittable;++i) [self.game.scrollViews.firstMatch swipeUp];
    XCTAssertTrue(element.hittable);
}
- (void)testMissingContentAndPicker {
    XCUIElement* choose=self.game.buttons[@"choose-content-package"];
    [self capture:@"import-top"];
    // XCTest may report unrotated frames for a landscape accessibility window.
    // Explicitly exercise scrolling instead of treating hittability as proof
    // that the complete control is visible in the screenshot.
    XCUICoordinate* start=[self.game.scrollViews.firstMatch coordinateWithNormalizedOffset:CGVectorMake(.5,.75)];
    XCUICoordinate* end=[self.game.scrollViews.firstMatch coordinateWithNormalizedOffset:CGVectorMake(.5,.50)];
    [start pressForDuration:.2 thenDragToCoordinate:end];
    XCTAssertTrue(choose.hittable);
    [self capture:@"import-action"];
    XCTAssertFalse(self.game.buttons[@"play-imported-content"].exists);
    [choose tap];
    XCUIElement* cancel=self.game.buttons[@"Cancel"];
    XCTAssertTrue([cancel waitForExistenceWithTimeout:15]);
    [self capture:@"system-picker"];
    [cancel tap];
    XCTAssertTrue([choose waitForExistenceWithTimeout:10]);
    XCTAssertTrue(choose.enabled);
}
- (void)testImportedContentPlay {
    XCUIElement* play=self.game.buttons[@"play-imported-content"];
    XCTAssertTrue([play waitForExistenceWithTimeout:20]);
    [self reveal:play];
    [self capture:@"import-ready"];
    [play tap];
    XCTAssertTrue([self.game.buttons[@"native-pause"] waitForExistenceWithTimeout:45]);
    [self capture:@"import-game-started"];
    [self.game.buttons[@"native-pause"] tap];
    [self capture:@"import-game-paused"];
}
- (void)testFullPackageImportAndStart {
    self.executionTimeAllowance=600;
    XCUIElement* choose=self.game.buttons[@"choose-content-package"];
    [self reveal:choose];
    [choose tap];
    [self capture:@"full-import-picker"];
    NSPredicate* name=[NSPredicate predicateWithFormat:@"label BEGINSWITH %@",@"Protector-personal-delivery"];
    XCUIElement* file=[self.game.cells matchingPredicate:name].firstMatch;
    if (![file waitForExistenceWithTimeout:10])
        file=[self.game.staticTexts matchingPredicate:name].firstMatch;
    XCTAssertTrue([file waitForExistenceWithTimeout:10],@"%@",self.game.debugDescription);
    [file tap];
    XCUIElement* play=self.game.buttons[@"play-imported-content"];
    XCTAssertTrue([play waitForExistenceWithTimeout:360],@"%@",self.game.debugDescription);
    [self capture:@"full-import-verified"];
    [self reveal:play];
    [play tap];
    XCTAssertTrue([self.game.buttons[@"native-pause"] waitForExistenceWithTimeout:45]);
    XCTestExpectation* interval=[self expectationWithDescription:@"bounded source boot"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{ [interval fulfill]; });
    XCTAssertEqual([XCTWaiter waitForExpectations:@[interval] timeout:25],XCTWaiterResultCompleted);
    [self capture:@"full-import-source-boot"];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:10]);
    [self capture:@"full-import-source-paused"];
}
@end
