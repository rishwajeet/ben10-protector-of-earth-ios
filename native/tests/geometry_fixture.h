#ifndef PROTECTOR_GEOMETRY_FIXTURE_H
#define PROTECTOR_GEOMETRY_FIXTURE_H
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <cassert>
#include <algorithm>
#include <vector>

static const std::vector<u8> GeometryFixtureCommand{0x9e,0,3,0,0,0,1,1,0,2,2,0};
static const std::vector<u8> GeometryFixtureUV{0,0,0,0};
static const std::vector<u8> GeometryFixtureAnchor{1,2,3,4,0,0,0,0};

static NSString* GeometryFixtureHash(const std::vector<u8>& bytes) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.data(), (CC_LONG)bytes.size(), hash);
    NSMutableString* value = [NSMutableString string];
    for (unsigned char byte : hash) [value appendFormat:@"%02x", byte];
    return value;
}

static NSMutableDictionary* GeometryFixture(bool anchored = false) {
    NSMutableDictionary* entry = [@{@"id":@"synthetic-geometry", @"source_vertex_count":@3,
        @"source_display_list_sha256":GeometryFixtureHash(GeometryFixtureCommand),
        @"source_display_list_bytes":@(GeometryFixtureCommand.size()),
        @"source_uvs_sha256":GeometryFixtureHash(GeometryFixtureUV), @"source_uv_bytes":@4,
        @"middle_attribute":@"normal", @"index_widths":@[@1,@1,@1],
        @"added_vertices":@[
            @{@"attributes":@[@0,@1],@"position_stencil":@[@[@0,@0.6],@[@1,@0.6],@[@2,@(-0.2)]]},
            @{@"attributes":@[@1,@2],@"position_stencil":@[@[@1,@0.5],@[@2,@0.5]]},
            @{@"attributes":@[@2,@0],@"position_stencil":@[@[@2,@0.5],@[@0,@0.5]]}],
        @"indices":@[@0,@3,@5,@3,@1,@4,@5,@4,@2,@3,@4,@5]} mutableCopy];
    if (anchored) {
        entry[@"source_anchor_prefix_bytes"] = @4;
        entry[@"source_anchor_sha256"] = GeometryFixtureHash(GeometryFixtureAnchor);
    }
    return [@{@"schema":@"protector-native.geometry-pack/v1", @"pack_id":@"synthetic-tests",
        @"title_dol_sha256":@"03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566",
        @"entries":[NSMutableArray arrayWithObject:entry]} mutableCopy];
}

static NSURL* WriteGeometryFixture(NSDictionary* document) {
    NSError* error = nil;
    NSURL* url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"protector-geometry-%@.json", NSUUID.UUID.UUIDString]]];
    NSData* data = [NSJSONSerialization dataWithJSONObject:document options:0 error:&error];
    assert(data && !error && [data writeToURL:url options:NSDataWritingWithoutOverwriting error:&error]);
    return url;
}

static std::vector<u8> RigidGeometryFixtureAnchor(bool color = false) {
    std::vector<u8> bytes(48u + GeometryFixtureUV.size());
    for (size_t i = 0; i < 36; ++i) bytes[i] = (u8)(i + 1);
    for (size_t i = 36; i < (color ? 48u : 45u); ++i) bytes[i] = 64;
    std::copy(GeometryFixtureUV.begin(), GeometryFixtureUV.end(), bytes.begin() + 48);
    return bytes;
}

static NSMutableDictionary* RigidGeometryFixture(bool color = false) {
    NSMutableDictionary* document = GeometryFixture();
    NSMutableDictionary* entry = document[@"entries"][0];
    entry[@"middle_attribute"] = color ? @"color0" : @"normal";
    entry[@"source_anchor_prefix_bytes"] = @48;
    entry[@"source_anchor_sha256"] = GeometryFixtureHash(RigidGeometryFixtureAnchor(color));
    entry[@"source_rigid_arrays"] = @{@"position_bytes":@36, @"middle_bytes":color ? @12 : @9};
    return document;
}

static NSMutableDictionary* RigidGeometryVariantsFixture(bool color = false, bool reverse = false) {
    auto* document = RigidGeometryFixture(color);
    NSMutableDictionary* first = document[@"entries"][0];
    NSMutableDictionary* second = [first mutableCopy];
    first[@"id"] = @"rigid-left";
    second[@"id"] = @"rigid-right";
    auto bytes = RigidGeometryFixtureAnchor(color);
    bytes[0] ^= 0x40;
    second[@"source_anchor_sha256"] = GeometryFixtureHash(bytes);
    document[@"entries"] = reverse ? @[second,first] : @[first,second];
    return document;
}
#endif
