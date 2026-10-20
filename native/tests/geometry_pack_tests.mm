#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#include "../metal/geometry_pack.mm"
#pragma clang diagnostic pop
#include "geometry_fixture.h"
#include <cstdio>

static void TestGeometryPack() {
    NSError* error = nil;
    ProtectorGeometryPack* pack = [[ProtectorGeometryPack alloc]
        initWithManifest:WriteGeometryFixture(GeometryFixture()) error:&error];
    assert(pack && !error && pack.entryCount == 1);
    assert(pack.manifestSHA256.length == 64 && [pack.packID isEqual:@"synthetic-tests"]);
    const auto* profile = [pack profileForPrimitive:GeometryFixtureCommand.data() length:GeometryFixtureCommand.size()];
    assert(profile && profile->sourceVertexCount == 3 && profile->addedVertices.size() == 3);
    assert(profile->indices.size() == 12 && profile->hasNormals);
    assert([pack matchesUVs:GeometryFixtureUV.data() length:GeometryFixtureUV.size() profile:profile]);
    std::vector<u8> wrong = GeometryFixtureCommand;
    wrong[3] = 1;
    assert(![pack profileForPrimitive:wrong.data() length:wrong.size()]);
    assert(![pack profileForPrimitive:GeometryFixtureCommand.data() length:GeometryFixtureCommand.size() - 1]);
    assert(![pack matchesUVs:wrong.data() length:4 profile:profile]);
    assert(![pack matchesUVs:GeometryFixtureUV.data() length:3 profile:profile]);

    assert(![pack matchesSourceAnchor:GeometryFixtureAnchor.data() length:GeometryFixtureAnchor.size() profile:profile]);
    ProtectorGeometryPack* anchored = [[ProtectorGeometryPack alloc]
        initWithManifest:WriteGeometryFixture(GeometryFixture(true)) error:&error];
    assert(anchored && !error);
    const auto* anchoredProfile = [anchored profileForPrimitive:GeometryFixtureCommand.data() length:GeometryFixtureCommand.size()];
    assert(anchoredProfile && anchoredProfile->sourceAnchorPrefixBytes == 4);
    assert([anchored matchesSourceAnchor:GeometryFixtureAnchor.data() length:GeometryFixtureAnchor.size() profile:anchoredProfile]);
    auto wrongAnchor = GeometryFixtureAnchor;
    wrongAnchor[0] ^= 1;
    assert(![anchored matchesSourceAnchor:wrongAnchor.data() length:wrongAnchor.size() profile:anchoredProfile]);
    assert(![anchored matchesSourceAnchor:GeometryFixtureAnchor.data() length:GeometryFixtureAnchor.size() - 1 profile:anchoredProfile]);
    assert(![anchored matchesSourceAnchor:nullptr length:GeometryFixtureAnchor.size() profile:anchoredProfile]);

    // A complete roster includes separately submitted rigid limbs and shells,
    // not just weighted torsos. Keep a bounded count and the 24 MiB byte cap.
    for (NSUInteger count : {NSUInteger(256), NSUInteger(257)}) {
        auto* document = GeometryFixture();
        auto* entries = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; ++i) {
            NSMutableDictionary* entry = [document[@"entries"][0] mutableCopy];
            entry[@"id"] = [NSString stringWithFormat:@"profile-%lu", (unsigned long)i];
            entry[@"source_display_list_sha256"] = [NSString stringWithFormat:@"%064lx", (unsigned long)i];
            [entries addObject:entry];
        }
        document[@"entries"] = entries;
        error = nil;
        auto* bounded = [[ProtectorGeometryPack alloc] initWithManifest:WriteGeometryFixture(document) error:&error];
        assert(count == 256 ? (bounded && !error && bounded.entryCount == 256) : (!bounded && error));
    }

    for (NSUInteger mutation = 0; mutation < 31; ++mutation) {
        NSMutableDictionary* document = GeometryFixture();
        NSMutableDictionary* entry = document[@"entries"][0];
        switch (mutation) {
            case 0: document[@"schema"] = @"unknown"; break;
            case 1: document[@"title_dol_sha256"] = @"bad"; break;
            case 2: document[@"entries"] = @[]; break;
            case 3: document[@"entries"] = @[entry, entry]; break;
            case 4: entry[@"source_vertex_count"] = @YES; break;
            case 5: entry[@"source_vertex_count"] = @2; break;
            case 6: entry[@"source_vertex_count"] = @3.5; break;
            case 7: entry[@"source_display_list_sha256"] = @"bad"; break;
            case 8: entry[@"source_uvs_sha256"] = @[]; break;
            case 9: entry[@"source_uv_bytes"] = @5; break;
            case 10: entry[@"source_display_list_bytes"] = @13; break;
            case 11: entry[@"index_widths"] = @[@1,@1,@0]; break;
            case 12: entry[@"indices"] = @[@0,@1,@2,@3,@4,@6,@0,@1,@2,@3,@4,@5]; break;
            case 13: entry[@"indices"] = @[@0,@1,@2,@3,@4,@5,@0,@1,@2,@3,@4,@5,@0]; break;
            case 14: entry[@"middle_attribute"] = @"guessed-normal"; break;
            case 15: entry[@"added_vertices"] = @[]; break;
            case 16: entry[@"added_vertices"] = @[@{@"attributes":@[@0,@3],@"position_stencil":@[@[@0,@0.5],@[@1,@0.5]]}]; break;
            case 17: entry[@"added_vertices"] = @[@{@"attributes":@[@0,@1],@"position_stencil":@[@[@0,@0.5],@[@3,@0.5]]}]; break;
            case 18: entry[@"added_vertices"] = @[@{@"attributes":@[@0,@1],@"position_stencil":@[@[@0,@0.5],@[@0,@0.5]]}]; break;
            case 19: entry[@"added_vertices"] = @[@{@"attributes":@[@0,@1],@"position_stencil":@[@[@0,@0.5],@[@1,@0.6]]}]; break;
            case 20: entry[@"added_vertices"] = @[@{@"attributes":@[@0,@1],@"position_stencil":@[@[@0,@(-1)],@[@1,@1],@[@2,@1]]}]; break;
            case 21: entry[@"added_vertices"] = @[@{@"attributes":@[@0,@1],@"position_stencil":@[@[@0,@(-1.1)],@[@1,@1]]}]; break;
            case 22: entry[@"source_vertex_count"] = @65536; break;
            case 23: document[@"entries"] = @[@[]]; break;
            case 24: entry[@"source_anchor_prefix_bytes"] = @4; break;
            case 25: entry[@"source_anchor_sha256"] = GeometryFixtureHash(GeometryFixtureAnchor); break;
            case 26: entry[@"source_anchor_prefix_bytes"] = @YES; entry[@"source_anchor_sha256"] = GeometryFixtureHash(GeometryFixtureAnchor); break;
            case 27: entry[@"source_anchor_prefix_bytes"] = @5; entry[@"source_anchor_sha256"] = GeometryFixtureHash(GeometryFixtureAnchor); break;
            case 28: entry[@"source_anchor_prefix_bytes"] = @2097156; entry[@"source_anchor_sha256"] = GeometryFixtureHash(GeometryFixtureAnchor); break;
            case 29: entry[@"source_anchor_prefix_bytes"] = @4; entry[@"source_anchor_sha256"] = @"bad"; break;
            case 30: entry[@"source_anchor_prefix_bytes"] = @0; entry[@"source_anchor_sha256"] = GeometryFixtureHash(GeometryFixtureAnchor); break;
        }
        error = nil;
        assert(![[ProtectorGeometryPack alloc] initWithManifest:WriteGeometryFixture(document) error:&error]);
        assert(error);
    }
}

static void TestRigidGeometryPack() {
    for (bool color : {false, true}) {
        NSError* error = nil;
        auto* pack = [[ProtectorGeometryPack alloc]
            initWithManifest:WriteGeometryFixture(RigidGeometryFixture(color)) error:&error];
        assert(pack && !error);
        const auto* profile = [pack profileForPrimitive:GeometryFixtureCommand.data() length:GeometryFixtureCommand.size()];
        assert(profile && profile->rigidSourceArrays && profile->rigidPositionBytes == 36);
        assert(profile->rigidMiddleBytes == (color ? 12 : 9));
        const auto anchor = RigidGeometryFixtureAnchor(color);
        assert([pack matchesSourceAnchor:anchor.data() length:anchor.size() profile:profile]);
    }
    for (NSUInteger mutation = 0; mutation < 12; ++mutation) {
        auto* document = RigidGeometryFixture();
        NSMutableDictionary* entry = document[@"entries"][0];
        switch (mutation) {
            case 0: entry[@"source_rigid_arrays"] = @YES; break;
            case 1: entry[@"source_rigid_arrays"] = @{}; break;
            case 2: entry[@"source_rigid_arrays"] = @{@"position_bytes":@YES,@"middle_bytes":@9}; break;
            case 3: entry[@"source_rigid_arrays"] = @{@"position_bytes":@35,@"middle_bytes":@9}; break;
            case 4: entry[@"source_rigid_arrays"] = @{@"position_bytes":@36,@"middle_bytes":@10}; break;
            case 5: entry[@"source_rigid_arrays"] = @{@"position_bytes":@24,@"middle_bytes":@9}; break;
            case 6: entry[@"source_rigid_arrays"] = @{@"position_bytes":@36,@"middle_bytes":@0}; break;
            case 7: entry[@"source_rigid_arrays"] = @{@"position_bytes":@36,@"middle_bytes":@9,@"unknown":@1}; break;
            case 8: [entry removeObjectForKey:@"source_anchor_prefix_bytes"];[entry removeObjectForKey:@"source_anchor_sha256"]; break;
            case 9: entry[@"middle_attribute"] = @"color0"; break;
            case 10: entry[@"source_rigid_arrays"] = @{@"position_bytes":@(65536u*12u),@"middle_bytes":@9}; break;
            case 11: entry[@"source_rigid_arrays"] = @{@"position_bytes":@36,@"middle_bytes":@(65536u*3u)}; break;
        }
        NSError* error = nil;
        assert(![[ProtectorGeometryPack alloc] initWithManifest:WriteGeometryFixture(document) error:&error]);
        assert(error);
    }
}

static void TestRigidTopologyVariants() {
    for (bool color : {false,true}) for (bool reverse : {false,true}) {
        NSError* error = nil;
        auto* pack = [[ProtectorGeometryPack alloc]
            initWithManifest:WriteGeometryFixture(RigidGeometryVariantsFixture(color,reverse)) error:&error];
        assert(pack && !error && pack.entryCount == 2);
        assert(![pack profileForPrimitive:GeometryFixtureCommand.data() length:GeometryFixtureCommand.size()]);
        const auto profiles = [pack profilesForPrimitive:GeometryFixtureCommand.data() length:GeometryFixtureCommand.size()];
        assert(profiles.size() == 2);
        for (bool right : {false,true}) {
            auto bytes = RigidGeometryFixtureAnchor(color);
            if (right) bytes[0] ^= 0x40;
            unsigned matches = 0;
            for (const auto* profile : profiles) {
                if (![pack matchesSourceAnchor:bytes.data() length:bytes.size() profile:profile]) continue;
                ++matches;
                assert(profile->identity == (right ? "rigid-right" : "rigid-left"));
            }
            assert(matches == 1);
        }
    }
    for (unsigned mutation=0;mutation<6;++mutation) {
        auto* document = RigidGeometryVariantsFixture();
        NSMutableDictionary* first = document[@"entries"][0];
        NSMutableDictionary* second = document[@"entries"][1];
        switch (mutation) {
            case 0: second[@"source_anchor_sha256"] = first[@"source_anchor_sha256"]; break;
            case 1: [first removeObjectForKey:@"source_rigid_arrays"]; break;
            case 2: [second removeObjectForKey:@"source_rigid_arrays"]; break;
            case 3: second[@"source_uv_bytes"] = @8; break;
            case 4: second[@"source_anchor_prefix_bytes"] = @60;
                second[@"source_rigid_arrays"] = @{@"position_bytes":@48,@"middle_bytes":@9}; break;
            case 5: second[@"id"] = first[@"id"]; break;
        }
        NSError* error = nil;
        assert(![[ProtectorGeometryPack alloc] initWithManifest:WriteGeometryFixture(document) error:&error] && error);
    }
}

int main(int argc, char** argv) {
    @autoreleasepool {
        TestGeometryPack();
        TestRigidGeometryPack();
        TestRigidTopologyVariants();
        if (argc == 3 && strcmp(argv[1], "--manifest") == 0) {
            NSError* error = nil;
            ProtectorGeometryPack* pack = [[ProtectorGeometryPack alloc]
                initWithManifest:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]] error:&error];
            if (!pack) { std::fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
            std::printf("source geometry pack validated: entries=%lu sha256=%s\n",
                (unsigned long)pack.entryCount, pack.manifestSHA256.UTF8String);
        } else assert(argc == 1);
        std::puts("geometry pack tests passed (31 existing and 12 rigid invalid-manifest cases rejected)");
    }
    return 0;
}
