#pragma once

// Source-bound framing for the two oversized Boss Viewer objects observed in
// 05_08. Complete gallery UI admission and every perspective material tuple
// separate the selected model (including outline/alpha passes) from the room.
// This is a fixed host-upload projection, not a per-frame bounding-box zoom.
struct GalleryModelFrame {
    bool enabled = false;
    unsigned profile = 0;
    float scale = 1, centerY = 0;
    size_t modelDraws = 0, roomDraws = 0;
    std::vector<bool> models;
    const char* reason = "not-source-boss-full-view";
    bool contains(size_t index) const {
        return enabled && index < models.size() && models[index];
    }
};

struct GalleryModelTuple {
    unsigned family, stages;
    bool normal;
    u32 blend, depth, cull, alphaTest;
    NSString* keys[4];
    u32 colors[4], alphas[4];
};

// Family zero is the source viewing room, one is the shared ink silhouette.
// Entries are exact observed source states, not replacement-artwork identities.
static const GalleryModelTuple kGalleryModelTuples[] = {
    {0,1,false,13500,23,2,4128768,
        {@"128x128-976633182d465666d65b27c15065d1463f869e83e458b146d74e6ff73d983959"},
        {587951},{586480}},
    {0,1,false,13500,23,2,4128768,
        {@"128x128-4782c8fe7a5ed17145565832071fba497e879b3ebf437f5b054d858af21311e7"},
        {587951},{586480}},
    {0,1,false,13500,23,2,4128768,
        {@"128x128-91f6cb3e5b963a1861301d22fd90164b0b15922701d68447157868208054b571"},
        {587951},{586480}},
    {0,1,false,13500,23,2,4128768,
        {@"64x64-2702b0e96694ab7bc0073c2a89ae6cf43bec52c7c231946b87d84b1b58d1671e"},
        {587951},{586480}},
    {0,1,false,13500,23,2,4128768,
        {@"64x128-15e956e9f54faeb202485b4d72f9de4fa20124cedb60a602dda85b7ebd98d380"},
        {587951},{586480}},
    {0,4,false,13500,23,2,4128768,
        {@"64x64-a687a0d6becd9830823a63dff5e73ee238f1f1eb6661b5f962dcfa8ea5b7fdd3",@"256x128-5c4ca29ac8ee013656e4414de3b427863dee5b5ef9e08e816c0275b5369cb014",@"256x128-0404ca734a51505763de6abec3c78dbf4d3a8b72413def26a9b739899071cfb9",@"1x1-ad95131bc0b799c0b1af477fb14fcf26a6a9f76079e48bf090acb7e8367bfd0e"},
        {587951,4782255,4784114,524863},{586480,65408,589708,589696}},
    {0,1,false,13500,23,2,4128768,
        {@"64x128-f2defd71b7fc5f705fc0baf1f0b0200a9c0091d90f1bf6cf3381933fea47545c"},
        {587951},{586480}},
    {0,1,false,13500,23,2,4128768,
        {@"128x128-6a74a7455f0fef18a78a389d2c6f6c4e2d820c0847721643376436fa55f3298b"},
        {587951},{586480}},
    {0,1,false,13500,23,2,4128768,
        {@"128x128-710e4cbf54addd9232f78cb5c41c8d91707143283e2cedfb9f9773c1641651e8"},
        {587951},{586480}},
    {51,1,true,13500,23,2,4128768,
        {@"128x128-4b554836e6c9eab552bef8ec8e0a9a1be658ec24a108e4a687836001458845d8"},
        {587951},{586480}},
    {1,1,false,13500,23,2,4128768,
        {@"1x1-ad95131bc0b799c0b1af477fb14fcf26a6a9f76079e48bf090acb7e8367bfd0e"},
        {589818},{589776}},
    {51,1,true,13500,23,2,4128768,
        {@"128x128-cb333582ea3ddc568894451680b3e9a9273b8715f082d0cc5da73ec25100327f"},
        {587951},{586480}},
    {51,1,true,13500,23,2,4128768,
        {@"64x64-119448c5699a92a1dc2a5579b2e159ebaae2c4d6e3f9af7c27b3baaa0f28a3ff"},
        {587951},{586480}},
    {51,1,true,13500,23,2,4128768,
        {@"128x128-4b6c3367247e6f4139a4f65345077709ccc2d6b367d0a515039235c1bd376173"},
        {587951},{586480}},
    {0,1,false,13373,7,2,4128768,
        {@"32x16-a1580f15c847fe30353a01bd13c338a8654ff08cfa8a943248c60a3de607e8da"},
        {587951},{586480}},
    {51,2,true,13477,23,0,3588288,
        {@"64x64-f945ac15ef522b8fb19a302436357cec26f5bbdbfcc2c493d83e4682e477304d",@"64x64-e01d17bf3ba22d2e1055386bc6b47afb8a6c6e8ca2539f1a4d6ace3572784333"},
        {587951,589808},{65520,586492}},
    {51,2,true,13501,7,0,4128768,
        {@"64x64-f945ac15ef522b8fb19a302436357cec26f5bbdbfcc2c493d83e4682e477304d",@"64x64-e01d17bf3ba22d2e1055386bc6b47afb8a6c6e8ca2539f1a4d6ace3572784333"},
        {587951,589808},{65520,586492}},
    {53,2,true,13500,23,2,4128768,
        {@"256x256-2f041197042a4cbb595076e9bf7879508ca7f1271c3a5c94f157720824853117",@"256x256-9951620274a8b6157a9b98a5c24b328d0402eeadc7e4d5a9e99a36149dba730b"},
        {587951,589808},{65520,586492}},
    {53,2,true,13500,23,2,4128768,
        {@"64x64-6cb00f69f222cf7e2396b5962410c5e7c1969cb9adf9bbc2547fba4c5825f565",@"64x64-3e23d903f580814b7f18140d59cfe6fe1a4d37545210cfafa46ddb28aa3f807a"},
        {587951,589808},{65520,586492}},
    {53,2,true,13500,23,2,4128768,
        {@"16x16-5a25ce1e0e40f3bbacc41479d3f9b14ec424ff4fc25a49434ed99a699a080bd0",@"16x16-d1afe286278b5aee5991666b8dbcba0bd8ba82a9d2f704aead0c2dfb973db391"},
        {587951,589808},{65520,586492}},
    {53,2,true,13500,23,2,4128768,
        {@"64x64-4b89a531f28846bcad27b658b25de796f3885ac3b19d7dd6c8ce763b1e57a33d",@"64x64-0ea22a256fb7f12a4cb9470f413ead29fc6241be26456983b76d213ed07db044"},
        {587951,589808},{65520,586492}},
    {53,1,true,13500,23,2,4128768,
        {@"128x128-f8b3a43bcd4832fcbe7f43f3762814fa079f5339ef53f7e8ea77a9806d4f0475"},
        {587951},{586480}},
    {53,2,true,13477,23,2,3588288,
        {@"256x256-2f041197042a4cbb595076e9bf7879508ca7f1271c3a5c94f157720824853117",@"256x256-9951620274a8b6157a9b98a5c24b328d0402eeadc7e4d5a9e99a36149dba730b"},
        {587951,589808},{65520,586492}},
    {53,2,true,13501,7,2,4128768,
        {@"256x256-2f041197042a4cbb595076e9bf7879508ca7f1271c3a5c94f157720824853117",@"256x256-9951620274a8b6157a9b98a5c24b328d0402eeadc7e4d5a9e99a36149dba730b"},
        {587951,589808},{65520,586492}},
    {53,1,true,13373,7,2,4128768,
        {@"16x16-9503245a0161a939de15c2414db2d336e761822fa6cff8136e4148f58f1f782e"},
        {587951},{586480}},
    {53,1,true,13373,7,2,4128768,
        {@"32x32-12674215db57203274c1537424df11de216d5f0c2082e19f92378a69c1cf6957"},
        {587951},{586480}},
    {53,2,true,13477,23,2,3588288,
        {@"64x64-013e9fb30d1a164252ddfc6dc3e08c9ffa4845a2127de53058c2d0c63c97cb04",@"64x64-4501956dd966bb52de84408793908841e0118be7ce9383fe70bcb7d8955c87c9"},
        {587951,589808},{65520,586492}},
    {53,2,true,13501,7,2,4128768,
        {@"64x64-013e9fb30d1a164252ddfc6dc3e08c9ffa4845a2127de53058c2d0c63c97cb04",@"64x64-4501956dd966bb52de84408793908841e0118be7ce9383fe70bcb7d8955c87c9"},
        {587951,589808},{65520,586492}},
    {53,2,true,13501,23,2,3588288,
        {@"256x256-2f041197042a4cbb595076e9bf7879508ca7f1271c3a5c94f157720824853117",@"256x256-9951620274a8b6157a9b98a5c24b328d0402eeadc7e4d5a9e99a36149dba730b"},
        {587951,589808},{65520,586492}},
    {53,2,true,13477,23,2,3588288,
        {@"128x128-6eb1db1be9f02593ca7ba33717174ec91d441f51fcc72f578c8f89b3ae540e90",@"128x128-b9808fbf0e099bf31ede89489407ec13b9a99343cc5599e9d4d0be70e0cb968a"},
        {587951,589808},{65520,586492}},
    {53,2,true,13501,7,2,4128768,
        {@"128x128-6eb1db1be9f02593ca7ba33717174ec91d441f51fcc72f578c8f89b3ae540e90",@"128x128-b9808fbf0e099bf31ede89489407ec13b9a99343cc5599e9d4d0be70e0cb968a"},
        {587951,589808},{65520,586492}},
};

template<class SourceKey>
static GalleryModelFrame IdentifyGalleryModelFrameWithKeys(
    const std::vector<LiveDraw>& draws, const GalleryLayoutAdmission& gallery, SourceKey key) {
    GalleryModelFrame result;
    if (!gallery.enabled || !gallery.extrasFullView || gallery.extrasMovie ||
        gallery.extrasItems != 11 || !gallery.first || gallery.first > 1024 ||
        gallery.first > draws.size()) return result;
    result.reason = "unrecognized-boss-perspective-component";
    constexpr std::array<u32,7> projection = {1071518207,0,1075748644,0,3131313033,3212847363,0};
    std::vector<bool> models(gallery.first,false);
    unsigned profile = 0, anchors = 0;
    size_t vertexCount = 0, roomCount = 0, modelCount = 0;
    bool floor = false, wall = false;
    for (size_t i=0; i<gallery.first; ++i) {
        const auto& draw = draws[i];
        vertexCount += draw.vertices.size();
        if (vertexCount > 65536 || draw.vertices.empty() ||
            draw.projectionWords != projection || draw.viewportX != 0 || draw.viewportY != 0 ||
            draw.viewportWidth != 640 || draw.viewportHeight != 448 || draw.displayListDepth != 1 ||
            draw.fragment.indirectCount || !draw.fragment.stageCount || draw.fragment.stageCount > 4)
            return result;
        const GalleryModelTuple* tuple = nullptr;
        for (const auto& candidate : kGalleryModelTuples) {
            if (draw.fragment.stageCount != candidate.stages || draw.hasNormal != candidate.normal ||
                draw.blendMode != candidate.blend || draw.depthMode != candidate.depth ||
                draw.cullMode != candidate.cull || draw.fragment.alphaTest != candidate.alphaTest) continue;
            bool matches = true;
            for (size_t stage=0; stage<candidate.stages && matches; ++stage) {
                matches = draw.fragment.colorCombiners[stage] == candidate.colors[stage] &&
                    draw.fragment.alphaCombiners[stage] == candidate.alphas[stage] &&
                    [key(i,stage) isEqualToString:candidate.keys[stage]];
            }
            if (matches) { tuple = &candidate; break; }
        }
        if (!tuple) return result;
        for (const auto& vertex : draw.vertices)
            for (float value : vertex.position)
                if (!std::isfinite(value) || std::abs(value) > 100000) return result;
        if (!tuple->family) {
            ++roomCount;
            floor |= [tuple->keys[0] isEqualToString:@"128x128-6a74a7455f0fef18a78a389d2c6f6c4e2d820c0847721643376436fa55f3298b"];
            wall |= [tuple->keys[0] isEqualToString:@"128x128-4782c8fe7a5ed17145565832071fba497e879b3ebf437f5b054d858af21311e7"];
            continue;
        }
        models[i] = true; ++modelCount;
        if (tuple->family == 1) continue;
        if (profile && profile != tuple->family) return result;
        profile = tuple->family;
        if ([tuple->keys[0] isEqualToString:@"128x128-4b554836e6c9eab552bef8ec8e0a9a1be658ec24a108e4a687836001458845d8"] ||
            [tuple->keys[0] isEqualToString:@"256x256-2f041197042a4cbb595076e9bf7879508ca7f1271c3a5c94f157720824853117"]) anchors |= 1;
        if ([tuple->keys[0] isEqualToString:@"64x64-119448c5699a92a1dc2a5579b2e159ebaae2c4d6e3f9af7c27b3baaa0f28a3ff"] ||
            [tuple->keys[0] isEqualToString:@"128x128-f8b3a43bcd4832fcbe7f43f3762814fa079f5339ef53f7e8ea77a9806d4f0475"]) anchors |= 2;
    }
    if ((profile != 51 && profile != 53) || anchors != 3 || !floor || !wall || !modelCount) return result;
    result.enabled = true; result.profile = profile; result.models = std::move(models);
    result.modelDraws = modelCount; result.roomDraws = roomCount;
    result.scale = profile == 51 ? .60f : .46f;
    result.centerY = profile == 51 ? -.03f : .23f;
    result.reason = "source-boss-model-fixed-fit";
    return result;
}

static GalleryModelFrame IdentifyGalleryModelFrame(const std::vector<LiveDraw>& draws,
    const GalleryLayoutAdmission& gallery) {
    // No hashing on ordinary gameplay, browser grids, movies or other viewers.
    if (!gallery.enabled || !gallery.extrasFullView || gallery.extrasItems != 11) return {};
    std::map<std::tuple<const u8*,size_t,u32,u32>,NSString*> keys;
    return IdentifyGalleryModelFrameWithKeys(draws,gallery,[&](size_t i,size_t stage) {
        const auto& draw = draws[i];
        const auto& pixels = TexturePixels(draw,stage);
        const auto identity = std::make_tuple(pixels.data(),pixels.size(),draw.textureWidths[stage],draw.textureHeights[stage]);
        auto found = keys.find(identity);
        if (found != keys.end()) return found->second;
        NSString* value = InterfaceTextureKey(pixels,draw.textureWidths[stage],draw.textureHeights[stage]);
        keys.emplace(identity,value);
        return value;
    });
}

static void TransformGalleryModelVertex(LiveVertex* vertex, const GalleryModelFrame& frame, double aspect) {
    if (!frame.enabled || !std::isfinite(aspect) || aspect < 4.0/3.0 || aspect > 3.0) return;
    vertex->position[0] *= frame.scale*(float)((4.0/3.0)/aspect);
    vertex->position[1] = frame.scale*vertex->position[1]+frame.centerY*vertex->position[3];
    // Preserve depth, W, normals, source animation, UVs, colors and topology.
}

// This bounded summary measures admitted source vertices, not occlusion,
// appearance or full motion proof. The live observer must inspect pixels too.
static NSDictionary* GalleryModelFrameReceipt(const std::vector<LiveDraw>& draws,
    const GalleryModelFrame& frame, double aspect) {
    if (!frame.enabled) return @{@"enabled":@NO,@"admission":@(frame.reason)};
    float left=INFINITY,right=-INFINITY,bottom=INFINITY,top=-INFINITY;
    size_t invalid=0,vertices=0,outside=0;
    for (size_t i=0;i<draws.size();++i) if (frame.contains(i)) {
        for (auto vertex : draws[i].vertices) {
            ++vertices;
            TransformGalleryModelVertex(&vertex,frame,aspect);
            const float w=vertex.position[3];
            if (w<=0) { ++invalid; continue; }
            const float x=vertex.position[0]/w,y=vertex.position[1]/w;
            left=std::min(left,x);right=std::max(right,x);
            bottom=std::min(bottom,y);top=std::max(top,y);
            outside += std::abs(x)>1 || std::abs(y)>1;
        }
    }
    id bounds = std::isfinite(left) ? (id)@[@(left),@(bottom),@(right),@(top)] : (id)NSNull.null;
    return @{@"enabled":@YES,@"admission":@(frame.reason),@"profile":@(frame.profile),
        @"scale":@(frame.scale),@"center_y":@(frame.centerY),@"model_draws":@(frame.modelDraws),
        @"room_draws":@(frame.roomDraws),@"source_vertices":@(vertices),@"ndc_bounds":bounds,
        @"behind_camera_vertices":@(invalid),@"outside_viewport_vertices":@(outside),
        @"source_vertices_immutable":@YES,@"room_projection_unchanged":@YES,
        @"framing_policy":@"fixed-source-model-profile-no-per-frame-zoom"};
}


// Opt-in diagnostic evidence, called only by the material observer after its
// readiness gate. This does not admit or transform gallery geometry. Keeping
// the complete bounded perspective sequence lets the framing work distinguish
// the viewing room from the selected model using actual source draws.
static NSDictionary* GalleryModelSourceAudit(const std::vector<LiveDraw>& draws,
    const std::vector<LiveEfbCopy>& copies) {
    const auto gallery = IdentifyGalleryLayout(draws, copies);
    if (!gallery.enabled || !gallery.extrasFullView || gallery.extrasMovie) return nil;
    size_t vertexCount = 0;
    for (size_t i = 0; i < gallery.first; ++i) {
        vertexCount += draws[i].vertices.size();
        if (vertexCount > 65536 || i >= 1024)
            return @{@"status":@"omitted-bounded-perspective-sequence",
                @"perspective_draws":@(gallery.first)};
    }
    NSMutableArray* records = [NSMutableArray array];
    const auto number = [](float value) -> id {
        return std::isfinite(value) ? @(value) : (id)NSNull.null;
    };
    for (size_t i = 0; i < gallery.first; ++i) {
        const auto& draw = draws[i];
        NSMutableArray* vertices = [NSMutableArray array];
        for (const auto& vertex : draw.vertices) {
            [vertices addObject:@[number(vertex.position[0]),number(vertex.position[1]),
                number(vertex.position[2]),number(vertex.position[3])]];
        }
        NSMutableArray* projection = [NSMutableArray array];
        for (u32 word : draw.projectionWords) [projection addObject:@(word)];
        NSMutableArray* arrays = [NSMutableArray array];
        for (u32 word : draw.motionSourceArrays) [arrays addObject:@(word)];
        NSMutableArray* stages = [NSMutableArray array];
        for (size_t stage = 0; stage < std::min<u32>(draw.fragment.stageCount,4); ++stage) {
            NSString* key = InterfaceTextureKey(TexturePixels(draw,stage),
                draw.textureWidths[stage],draw.textureHeights[stage]);
            [stages addObject:@{@"stage":@(stage),@"source_key":key ? (id)key : NSNull.null,
                @"color_combiner":@(draw.fragment.colorCombiners[stage]),
                @"alpha_combiner":@(draw.fragment.alphaCombiners[stage])}];
        }
        NSMutableString* identity = [NSMutableString string];
        for (u8 byte : draw.motionSourceKey) [identity appendFormat:@"%02x",byte];
        [records addObject:@{@"draw_index":@(i),@"clip_positions":vertices,
            @"projection_words":projection,@"source_arrays":arrays,
            @"motion_source_sha256":draw.hasMotionSourceKey ? (id)identity : NSNull.null,
            @"viewport":@[@(draw.viewportX),@(draw.viewportY),@(draw.viewportWidth),@(draw.viewportHeight)],
            @"vertex_count":@(draw.vertices.size()),@"source_vertex_count":@(draw.sourceVertexCount),
            @"index_count":@(draw.indices.size()),@"indexed":@(draw.indexed),
            @"display_list_depth":@(draw.displayListDepth),@"has_normal":@(draw.hasNormal),
            @"blend_mode":@(draw.blendMode),@"depth_mode":@(draw.depthMode),@"cull_mode":@(draw.cullMode),
            @"alpha_test":@(draw.fragment.alphaTest),@"stage_count":@(draw.fragment.stageCount),
            @"indirect_count":@(draw.fragment.indirectCount),@"stages":stages}];
    }
    return @{@"schema":@"protector-native.gallery-model-source-audit/v1",
        @"status":@"complete-perspective-sequence",@"source_vertices_immutable":@YES,
        @"source_vertex_sha256":MotionVertexDigest(draws),@"perspective_draws":@(gallery.first),
        @"perspective_vertices":@(vertexCount),@"draws":records,
        @"copy_layout":MotionCopyLayout(copies,draws.size()),
        @"limits":@"Diagnostic source clip positions only. No model owner, fit, motion or appearance approval is inferred."};
}
