#pragma once

// Original 99_99.gcs loading panel, observed as three consecutive complete
// quads. This is component admission, not a loading-state/gameplay override.
enum class SharedPanelRole { None, Center, LeftCap, RightCap };
struct SharedPanelAdmission {
    size_t first = 0;
    bool enabled = false;
    const char* reason = "not-source-loading-panel";
    SharedPanelRole role(size_t index) const {
        if (!enabled || index < first || index-first >= 3) return SharedPanelRole::None;
        return (SharedPanelRole)(1+index-first);
    }
};

static bool SharedPanelGeometryMatches(const LiveDraw& draw, SharedPanelRole role) {
    if (role == SharedPanelRole::None || !draw.indexed || draw.vertices.size() != 4 ||
        draw.fragment.stageCount != 2 || draw.viewportX != 0 || draw.viewportY != 0 ||
        draw.viewportWidth != 640 || !FrontendDrawStateMatches(draw,FrontendRole::MenuArt)) return false;
    const float left = role == SharedPanelRole::Center ? -0.625f :
        role == SharedPanelRole::LeftCap ? -0.725f : 0.725f;
    const float right = role == SharedPanelRole::LeftCap ? -0.625f : 0.625f;
    const float xs[] = {left,right,right,left};
    const float ys[] = {0.5357143283f,0.5357143283f,-0.6294643283f,-0.6294643283f};
    constexpr float uv[][2] = {{0,0},{1,0},{1,1},{0,1}};
    for (size_t stage=0;stage<2;++stage)
        if (draw.textureWidths[stage] != 32 || draw.textureHeights[stage] != 128) return false;
    for (size_t i=0;i<4;++i) {
        const auto& vertex = draw.vertices[i];
        if (std::abs(vertex.position[0]-xs[i]) > 0.00001f ||
            std::abs(vertex.position[1]-ys[i]) > 0.00001f ||
            std::abs(vertex.position[2]-0.00625002384f) > 0.00001f) return false;
        for (size_t color=0;color<4;++color)
            if (vertex.color[color] != draw.vertices[0].color[color]) return false;
        if (vertex.color[0] != vertex.color[1] || vertex.color[1] != vertex.color[2]) return false;
        for (size_t stage=0;stage<2;++stage)
            for (size_t axis=0;axis<2;++axis)
                if (std::abs(vertex.uv[stage][axis]-uv[i][axis]) > 0.00001f) return false;
    }
    return true;
}

static SharedPanelAdmission IdentifySharedPanel(const std::vector<LiveDraw>& draws) {
    SharedPanelAdmission result;
    if (draws.size() < 3 || draws.size() > 4096) return result;
    constexpr const char* keys[][2] = {
        {"32x128-74f1d8612646f3bd9c52055471f33d653f4c6bcb096b7e2383be7eaa36ccb709",
         "32x128-df38508fc683288e8ab60fbfaf22e590a48b1ff8c86bf62fa223c45348e1728b"},
        {"32x128-67ae129af7de5970b64949de1f1aebb62246da783475cfd56d355d63d70e0ada",
         "32x128-1dd42aed72272b62113d5ad1ddeaa6926a1a5f2f2f9b78ae598ec0e30a702f83"}};
    for (size_t i=0;i+2<draws.size();++i) {
        if (!SharedPanelGeometryMatches(draws[i],SharedPanelRole::Center) ||
            !SharedPanelGeometryMatches(draws[i+1],SharedPanelRole::LeftCap) ||
            !SharedPanelGeometryMatches(draws[i+2],SharedPanelRole::RightCap)) continue;
        bool match = true;
        for (size_t piece=0;piece<3 && match;++piece) {
            const auto& draw = draws[i+piece];
            for (size_t color=0;color<4;++color)
                match &= draw.vertices[0].color[color] == draws[i].vertices[0].color[color];
            for (size_t stage=0;stage<2 && match;++stage)
                match = [InterfaceTextureKey(TexturePixels(draw,stage),32,128)
                    isEqualToString:@(keys[piece ? 1 : 0][stage])];
        }
        if (!match) continue;
        if (result.enabled) return {}; // Ambiguous repeated composition fails closed.
        result = {i,true,"source-three-piece-loading-panel"};
    }
    return result;
}

static void TransformSharedPanelVertex(LiveVertex* vertex, SharedPanelRole role, double aspect) {
    if (role == SharedPanelRole::None || !std::isfinite(aspect) || aspect < 4.0/3.0 || aspect > 3.0) return;
    const float ratio = (float)((4.0/3.0)/aspect);
    if (ratio == 1) return;
    const float sourceX = vertex->position[0];
    vertex->position[0] *= ratio;
    // Widen only the flat centre. End caps translate without changing their
    // physical aspect; the original letter geometry and input stay untouched.
    const float added = 0.65f*(1-ratio);
    vertex->position[0] += role == SharedPanelRole::Center ? added*sourceX/0.625f :
        role == SharedPanelRole::LeftCap ? -added : added;
}
