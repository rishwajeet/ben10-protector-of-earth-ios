#import <XCTest/XCTest.h>

// Reuse the already-qualified isolated cold-boot/interaction route. Add exact
// artwork identity, per-frame source coverage and both texture-budget checks.
// The original layout test remains unchanged and independently selectable.
@interface ProtectorFrontendUITests : XCTestCase
- (NSDictionary*)state:(NSString*)name;
- (void)waitForLayout:(NSString*)admission afterFrame:(NSUInteger)frame timeout:(NSTimeInterval)timeout;
@end

@interface ProtectorFrontendArtworkUITests : ProtectorFrontendUITests
@end

@implementation ProtectorFrontendArtworkUITests
- (void)waitForLayout:(NSString*)admission afterFrame:(NSUInteger)frame timeout:(NSTimeInterval)timeout {
    [super waitForLayout:admission afterFrame:frame timeout:timeout];
    NSString* path = NSProcessInfo.processInfo.environment[@"PROTECTOR_FRONTEND_ART_EXPECTATIONS"];
    XCTAssertTrue(path.length > 0, @"Pin source-derived artwork expectations for this dedicated run");
    NSData* data = [NSData dataWithContentsOfFile:path];
    XCTAssertNotNil(data);
    NSDictionary* expected = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    XCTAssertEqualObjects(expected[@"schema"],@"protector-native.frontend-art-expectations/v1");
    NSDictionary* render = [self state:@"interactive-state.json"];
    XCTAssertEqualObjects(render[@"texture_pack_id"],expected[@"pack_id"]);
    XCTAssertEqualObjects(render[@"texture_pack_manifest_sha256"],expected[@"pack_sha256"]);
    XCTAssertTrue([render[@"restored_artwork_enabled"] boolValue]);
    NSString* mode = [admission isEqual:@"source-dna-title"] ? @"title" : @"menu";
    NSSet* sourceKeys = [NSSet setWithArray:expected[mode]];
    NSSet* observed = [NSSet setWithArray:render[@"texture_pack_frame_sources"]];
    XCTAssertGreaterThan(sourceKeys.count,10u);
    XCTAssertEqualObjects(observed,sourceKeys,@"Every source color, coverage and font plane must use its pinned replacement");
    XCTAssertGreaterThan([render[@"texture_pack_frame_bytes"] unsignedLongLongValue],0ull);
    XCTAssertLessThanOrEqual([render[@"texture_pack_frame_bytes"] unsignedLongLongValue],
        [render[@"texture_pack_allocation_budget_bytes"] unsignedLongLongValue]);
    XCTAssertLessThanOrEqual([render[@"texture_pack_cache_bytes"] unsignedLongLongValue],
        [render[@"texture_pack_allocation_budget_bytes"] unsignedLongLongValue]);
    XCTAssertLessThanOrEqual([render[@"texture_pack_frame_encoded_bytes"] unsignedLongLongValue],
        [render[@"texture_pack_encoded_budget_bytes"] unsignedLongLongValue]);
    XCTAssertLessThanOrEqual([render[@"texture_pack_cache_encoded_bytes"] unsignedLongLongValue],
        [render[@"texture_pack_encoded_budget_bytes"] unsignedLongLongValue]);
}
@end
