#import <XCTest/XCTest.h>
#import "../touch_settings.h"

/* UIKit component tests for failures and disabled/bounded controls. These use
 * the production settings class but not the translated runtime or hardware. */
@interface ProtectorSettingsControllerTests : XCTestCase
@property(nonatomic) ProtectorTouchSettingsController* settings;
@property(nonatomic) UINavigationController* navigation;
@property(nonatomic) UIWindow* window;
@end
@implementation ProtectorSettingsControllerTests
- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    ProtectorRegisterTouchDefaults();
    self.window = [(id)UIApplication.sharedApplication.delegate window];
    self.settings = [[ProtectorTouchSettingsController alloc] init];
    self.settings.controllerNavigationActive = YES;
    self.settings.renderScale = 3;
    self.settings.hasSmoothMotion = YES;
    self.settings.smoothMotion = YES;
    self.navigation = [[UINavigationController alloc] initWithRootViewController:self.settings];
    self.window.rootViewController = self.navigation;
    [self.window makeKeyAndVisible];
    [self.window layoutIfNeeded];
}
- (void)waitForPresentation {
    XCTestExpectation* pause = [self expectationWithDescription:@"UIKit presentation settles"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [pause fulfill]; });
    [self waitForExpectations:@[pause] timeout:3];
}
- (void)selectDisplayRow:(NSInteger)row {
    self.settings.controllerSelection = [NSIndexPath indexPathForRow:row inSection:2];
    [self.settings.tableView scrollToRowAtIndexPath:self.settings.controllerSelection atScrollPosition:UITableViewScrollPositionTop animated:NO];
    [self.settings.tableView layoutIfNeeded];
}
- (void)testRenderingFailureRollsBackAndControllerAcknowledges {
    [self waitForPresentation];
    __block NSUInteger attempts = 0;
    self.settings.selectRendering = ^NSString*(NSString* key, NSUInteger value) {
        XCTAssertEqualObjects(key, @"scale"); XCTAssertEqual(value, 2u); attempts += 1;
        return @"The test renderer declined this scale.";
    };
    [self selectDisplayRow:0];
    [self.settings handleControllerCommand:PROTECTOR_MENU_LEFT];
    XCTAssertEqual(attempts, 1u);
    XCTAssertEqual(self.settings.renderScale, 3u);
    [self waitForPresentation];
    XCTAssertTrue([self.settings.presentedViewController isKindOfClass:UIAlertController.class]);
    [self.settings handleControllerCommand:PROTECTOR_MENU_LEFT];
    XCTAssertEqual(attempts, 1u, @"An alert consumes navigation instead of changing its underlying row");
    [self.settings handleControllerCommand:PROTECTOR_MENU_CONFIRM];
    [self waitForPresentation];
    XCTAssertNil(self.settings.presentedViewController);
    XCTAssertEqual(self.settings.controllerSelection.section, 2);
    XCTAssertEqual(self.settings.controllerSelection.row, 0);
}
- (void)testDisabledMotionAndRenderBoundaries {
    [self waitForPresentation];
    __block NSUInteger attempts = 0;
    self.settings.selectRendering = ^NSString*(NSString* key, NSUInteger value) {
        (void)key; (void)value; attempts += 1; return nil;
    };
    self.settings.hasSmoothMotion = NO;
    [self.settings.tableView reloadData];
    [self selectDisplayRow:1];
    [self.settings handleControllerCommand:PROTECTOR_MENU_CONFIRM];
    XCTAssertEqual(attempts, 0u);
    XCTAssertTrue(self.settings.smoothMotion);
    self.settings.renderScale = 1;
    [self.settings.tableView reloadData];
    [self selectDisplayRow:0];
    [self.settings handleControllerCommand:PROTECTOR_MENU_LEFT];
    XCTAssertEqual(attempts, 0u);
    [self.settings handleControllerCommand:PROTECTOR_MENU_RIGHT];
    XCTAssertEqual(attempts, 1u);
    XCTAssertEqual(self.settings.renderScale, 2u);
}
- (void)testNativeResolutionSelectionAndFailureRollback {
    [self waitForPresentation];
    __block NSMutableArray* values = [NSMutableArray array];
    self.settings.selectRendering = ^NSString*(NSString* key, NSUInteger value) {
        XCTAssertEqualObjects(key, @"scale");
        [values addObject:@(value)];
        return value == 6 ? @"The test renderer declined this scale." : nil;
    };
    [self selectDisplayRow:0];
    [self.settings handleControllerCommand:PROTECTOR_MENU_RIGHT];
    XCTAssertEqual(self.settings.renderScale, 0u);
    [self.settings.tableView reloadData];
    [self selectDisplayRow:0];
    [self.settings handleControllerCommand:PROTECTOR_MENU_RIGHT];
    XCTAssertEqual(self.settings.renderScale, 0u);
    [self waitForPresentation];
    [self.settings handleControllerCommand:PROTECTOR_MENU_CONFIRM];
    [self waitForPresentation];
    [self.settings handleControllerCommand:PROTECTOR_MENU_LEFT];
    XCTAssertEqual(self.settings.renderScale, 3u);
    XCTAssertEqualObjects(values, (@[@0, @6, @3]));
}
- (void)testBackResumesRootAndReturnsFromGuide {
    [self waitForPresentation];
    __block NSUInteger resumes = 0;
    self.settings.resumeGame = ^{ resumes += 1; };
    [self.settings handleControllerCommand:PROTECTOR_MENU_DOWN];
    [self.settings handleControllerCommand:PROTECTOR_MENU_CONFIRM];
    [self waitForPresentation];
    XCTAssertEqual(self.navigation.viewControllers.count, 2u);
    [(ProtectorControllerTableController*)self.navigation.topViewController handleControllerCommand:PROTECTOR_MENU_BACK];
    [self waitForPresentation];
    XCTAssertEqual(self.navigation.viewControllers.count, 1u);
    XCTAssertEqual(resumes, 0u);
    [self.settings handleControllerCommand:PROTECTOR_MENU_BACK];
    XCTAssertEqual(resumes, 1u);
}
- (void)testSourceGuideDoneAndBusyState {
    ProtectorControlsGuideController* guide = [[ProtectorControlsGuideController alloc] init];
    guide.fromGameMenu = YES;
    __block NSUInteger returns = 0;
    guide.resumeGame = ^{ returns += 1; };
    [self.navigation setViewControllers:@[guide] animated:NO];
    [self waitForPresentation];
    XCTAssertEqualObjects(guide.navigationItem.rightBarButtonItem.accessibilityIdentifier,@"native-guide-done");
    XCTAssertTrue(guide.navigationItem.rightBarButtonItem.enabled);
    [guide handleControllerCommand:PROTECTOR_MENU_RIGHT];
    XCTAssertTrue(guide.controllerMode);
    [guide setReturnInProgress:YES];
    XCTAssertFalse(guide.navigationItem.rightBarButtonItem.enabled);
    XCTAssertFalse(guide.tableView.userInteractionEnabled);
    [guide handleControllerCommand:PROTECTOR_MENU_BACK];
    [guide handleControllerCommand:PROTECTOR_MENU_LEFT];
    XCTAssertTrue(guide.controllerMode);
    XCTAssertEqual(returns,0u);
    [guide setReturnInProgress:NO];
    [guide handleControllerCommand:PROTECTOR_MENU_LEFT];
    XCTAssertFalse(guide.controllerMode);
    [guide handleControllerCommand:PROTECTOR_MENU_BACK];
    XCTAssertEqual(returns,1u);
}
- (void)testCameraRowRequiresGameplayCallbackAndUsesNativeControllerSelection {
    [self waitForPresentation];
    XCTAssertEqual([self.settings tableView:self.settings.tableView numberOfRowsInSection:0],2);
    __block NSUInteger changes=0;
    self.settings.changeCamera=^{ changes++; };
    [self.settings.tableView reloadData];
    XCTAssertEqual([self.settings tableView:self.settings.tableView numberOfRowsInSection:0],3);
    NSIndexPath* camera=[NSIndexPath indexPathForRow:2 inSection:0];
    UITableViewCell* cell=[self.settings tableView:self.settings.tableView cellForRowAtIndexPath:camera];
    XCTAssertEqualObjects(cell.accessibilityIdentifier,@"change-game-camera");
    UIListContentConfiguration* content=(UIListContentConfiguration*)cell.contentConfiguration;
    XCTAssertEqualObjects(content.text,@"Camera");
    XCTAssertTrue([content.secondaryText containsString:@"Secrets first"]);
    self.settings.controllerSelection=camera;
    [self.settings handleControllerCommand:PROTECTOR_MENU_CONFIRM];
    XCTAssertEqual(changes,1u);
    self.settings.changeCamera=nil;
    [self.settings tableView:self.settings.tableView didSelectRowAtIndexPath:camera];
    XCTAssertEqual(changes,1u);
}
- (void)testPauseGuideRetainsResume {
    ProtectorControlsGuideController* guide = [[ProtectorControlsGuideController alloc] init];
    [self.navigation setViewControllers:@[guide] animated:NO];
    [self waitForPresentation];
    XCTAssertEqualObjects(guide.navigationItem.rightBarButtonItem.title,@"Resume");
    XCTAssertFalse(guide.fromGameMenu);
}
- (void)tearDown {
    self.window.rootViewController = [[UIViewController alloc] init];
    self.navigation = nil; self.settings = nil;
    [super tearDown];
}
@end
