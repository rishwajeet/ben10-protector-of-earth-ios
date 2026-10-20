#pragma once

// Exact 41_04 terminal-room provenance; no original geometry is embedded.
// A room boundary is not a backdrop to extrude. Keep the source 4:3 field and
// the existing 3:1 static-render envelope while biasing extra phone space inward.
struct FiniteRoomFrame {
    bool enabled = false;
    float bias = 0, anchorX = 0;
    const char* reason = "not-source-terminal-room";
};

static size_t FiniteRoomSourceCount(u8 identity) {
    return identity == 1 ? 86 : identity == 2 ? 1080 : identity == 3 ? 174 : 0;
}

static u8 FiniteRoomSourceIdentity(const char* digest) {
    static const char* const hashes[] = {
        "367398081abdfd218b7543ca5b0254535ac50e13979938b25325981c2a8c1c2a",
        "1c27a7a4192ce4f29b12b11e81d5658c961e349fe3e79cee0402281d2b5d99e0",
        "3cbc757622e214728165d6c35e154816c03bf8ff0a4d7cc1464b40a5463a327f",
    };
    if (digest) for (size_t i = 0; i < 3; ++i)
        if (!strcmp(digest, hashes[i])) return (u8)(i + 1);
    return 0;
}

static bool FiniteRoomMaterialMatches(const LiveDraw& draw) {
    return ClassifyWideDraw(draw) == WideDrawRole::Scene && draw.displayListDepth == 1 &&
        (draw.sourceVertexCount == 86 || draw.sourceVertexCount == 1080 || draw.sourceVertexCount == 174) &&
        draw.fragment.stageCount == 1 &&
        !draw.fragment.indirectCount && !(draw.blendMode & 1u) && (draw.depthMode & 1u) &&
        draw.cullMode == 2 && draw.fragment.alphaTest == 0x3F0000u &&
        draw.textureWidths[0] == 128 && draw.textureHeights[0] == 128 &&
        draw.textureFormats[0] == 14 && draw.textureCoordinates[0] == 0;
}

static bool FiniteRoomTextureMatches(const LiveDraw& draw, u8 identity) {
    static NSString* const keys[] = {
        @"128x128-86f26066cf76016cee6e78340b669b1980834792fa35a20265321379acb712f3",
        @"128x128-42d13b10e38c76b45b8356206987c7a75edca4cf1e8bba92a49effb22ae5a21d",
        @"128x128-699d1a36877677bf16fa4e9e46294bbf22a5bd00bcf10694aa6b3fa582fb5446",
    };
    return identity >= 1 && identity <= 3 &&
        [InterfaceTextureKey(TexturePixels(draw, 0), 128, 128) isEqualToString:keys[identity-1]];
}

static bool FiniteRoomSourceUVMatches(u8 identity, const std::vector<LiveVertex>& vertices) {
    static const char* const hashes[] = {
        "517941ea455773996eaedbbb1dbbfe4c6de701d8fb93854bbf9707c57d2c9a40",
        "b963b58e1ca82f0a8046a9527f955584790b73d5a3a5b052422a27431498a030",
        "280e234a2ffa63fb81a9d252d79059c35eda60f3bf390c74eff8c92f5c38e439",
    };
    if (!FiniteRoomSourceCount(identity) || vertices.size() != FiniteRoomSourceCount(identity)) return false;
    std::vector<u8> bytes;
    bytes.reserve(vertices.size()*8);
    for (const auto& vertex : vertices) for (float value : vertex.uv[0]) {
        if (!std::isfinite(value)) return false;
        u32 word = 0; memcpy(&word, &value, sizeof(word));
        for (int shift : {24,16,8,0}) bytes.push_back((u8)(word >> shift));
    }
    std::array<u8,CC_SHA256_DIGEST_LENGTH> hash{};
    CC_SHA256(bytes.data(), (CC_LONG)bytes.size(), hash.data());
    char digest[65]{};
    for (size_t i=0; i<hash.size(); ++i) snprintf(digest+i*2,3,"%02x",hash[i]);
    return !strcmp(digest, hashes[identity-1]);
}

static const LiveVertex& FiniteRoomSourceVertex(const LiveDraw& draw, size_t index) {
    return draw.vertices[draw.indexed || index < 3 ? index : (index-2)*3+2];
}

static bool FiniteRoomTopologyMatches(const LiveDraw& draw) {
    const size_t count = FiniteRoomSourceCount(draw.finiteRoomIdentity);
    if (!count || draw.sourceVertexCount != count) return false;
    const size_t expanded = (count-2)*3;
    if (draw.indexed ? (draw.vertices.size()!=count || draw.indices.size()!=expanded) :
        (draw.vertices.size()!=expanded || !draw.indices.empty())) return false;
    for (size_t i=2; i<count; ++i) {
        const size_t corners[] = {i-(i%2 ? 1u : 2u),i-(i%2 ? 2u : 1u),i};
        for (size_t j=0; j<3; ++j) {
            const size_t slot = (i-2)*3+j;
            if (draw.indexed ? draw.indices[slot]!=corners[j] :
                memcmp(&draw.vertices[slot],&FiniteRoomSourceVertex(draw,corners[j]),sizeof(LiveVertex))!=0)
                return false;
        }
    }
    for (const auto& vertex : draw.vertices) {
        for (float value : vertex.position) if (!std::isfinite(value) || std::abs(value)>100000) return false;
        if (vertex.position[3]<=0) return false;
    }
    return true;
}

static FiniteRoomFrame IdentifyFiniteRoomFrame(const std::vector<LiveDraw>& draws, double aspect) {
    FiniteRoomFrame result;
    if (!std::isfinite(aspect) || aspect <= 4.0/3.0+1e-6 || aspect > PROTECTOR_MAX_PRESENTATION_ASPECT) {
        result.reason="source-or-unsupported-aspect"; return result;
    }
    const LiveDraw* source[3]{};
    for (const auto& draw : draws) if (draw.finiteRoomIdentity) {
        const u8 id=draw.finiteRoomIdentity;
        if (id>3 || source[id-1] || !FiniteRoomTopologyMatches(draw)) {
            result.reason="duplicate-or-invalid-room-source"; return result;
        }
        source[id-1]=&draw;
    }
    if (!source[0] || !source[1] || !source[2]) return result;
    const auto& wall=*source[1];
    for (const auto& draw : draws) if (ClassifyWideDraw(draw)==WideDrawRole::Scene && !draw.vertices.empty()) {
        if (draw.projectionWords!=wall.projectionWords || draw.viewportX!=wall.viewportX ||
            draw.viewportY!=wall.viewportY || draw.viewportWidth!=wall.viewportWidth ||
            draw.viewportHeight!=wall.viewportHeight) {
            result.reason="mixed-scene-projection"; return result;
        }
    }
    for (const auto pair : {std::array<size_t,2>{20,202},std::array<size_t,2>{21,319}})
        if (memcmp(FiniteRoomSourceVertex(*source[0],pair[0]).position,
            FiniteRoomSourceVertex(wall,pair[1]).position,sizeof(LiveVertex::position))) {
            result.reason="disconnected-wall-seam"; return result;
        }
    const auto& corner=FiniteRoomSourceVertex(wall,562);
    const float y=corner.position[1]/corner.position[3];
    if (y<=-1 || y>=1) { result.reason="terminal-corner-offscreen"; return result; }
    const float ratio=(float)((4.0/3.0)/aspect);
    result.anchorX=corner.position[0]/corner.position[3]*ratio;
    const float requested=-1.0f-2.0f/640.0f-result.anchorX;
    if (requested>=0) { result.reason="terminal-boundary-already-outside"; return result; }
    // Keep all original 4:3 content, and never reveal static geometry outside
    // the existing CPU render-culling envelope. This changes no culling policy.
    const float minimum=std::max({ratio-1.0f,
        1.0f-(float)(PROTECTOR_MAX_PRESENTATION_ASPECT/(4.0/3.0))*ratio,-0.25f});
    if (requested<minimum) { result.reason="off-axis-envelope-exceeded"; return result; }
    result.enabled=true; result.bias=requested; result.reason="source-terminal-room-inward-framing";
    return result;
}
