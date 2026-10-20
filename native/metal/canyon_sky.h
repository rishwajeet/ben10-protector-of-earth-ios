// Exact source-bound continuation of Canyon's terminal repeating sky edge.
// Included after LiveDraw and the source-texture identity helpers. Fingerprints
// are provenance metadata; original game positions and pixels stay external.
static u8 CanyonSkySourceIdentity(const char* digest) {
    static const char* const identities[] = {
        "99d012d1caf85808dd590d7abac608111ee32aa664784fa3ab784361c576766b",
        "bc88bbfe894fb9549d56b2e8659da9bc8886fec3a653fb48576bbbc02569c214",
    };
    if (digest) for (size_t i = 0; i < 2; ++i)
        if (!strcmp(digest, identities[i])) return (u8)(i + 1);
    return 0;
}

static bool CanyonSkyMaterialMatches(const LiveDraw& draw) {
    return FiniteBackdropMaterialMatches(draw) && draw.sourceVertexCount == 3 &&
        draw.textureCoordinates[0] == 0 && draw.textureModes[0] == 2206901;
}

static bool CanyonSkySourceUVMatches(u8 identity, const std::vector<LiveVertex>& vertices) {
    // U moves continuously in the original material animation. Admit its
    // source-relative topology, never a frozen phase or a guessed UV reset.
    static const float relativeU[2][3] = {{0, 1, 1}, {0, -1, -1}};
    static const int sourceV[2][3] = {{28, 987, 28}, {987, 28, 987}};
    if (!identity || identity > 2 || vertices.size() != 3) return false;
    const float phase = vertices[0].uv[0][0];
    if (!std::isfinite(phase)) return false;
    for (size_t i = 0; i < 3; ++i) {
        const auto& v = vertices[i];
        if (!std::isfinite(v.uv[0][0]) ||
            std::abs(v.uv[0][0] - phase - relativeU[identity-1][i]) > 1e-6f ||
            v.uv[0][1] != sourceV[identity-1][i]/1024.0f) return false;
    }
    return true;
}

static bool CanyonSkyTextureMatches(const LiveDraw& draw) {
    return [InterfaceTextureKey(TexturePixels(draw, 0), 64, 64) isEqualToString:
        @"64x64-09d3a6e075dd339ac53635d99c942a723a2c5c56899fc6dab86e53c4f8e8592f"];
}

static bool CanyonSkyCohort(const std::vector<LiveDraw>& draws) {
    const LiveDraw* pair[2] = {};
    for (const auto& draw : draws) if (draw.canyonSkyIdentity) {
        const u8 identity = draw.canyonSkyIdentity;
        if (identity > 2 || pair[identity-1] ||
            !CanyonSkySourceUVMatches(identity, draw.vertices)) return false;
        for (const auto& vertex : draw.vertices) {
            for (float value : vertex.position) if (!std::isfinite(value)) return false;
            for (float value : vertex.color) if (!std::isfinite(value)) return false;
            if (vertex.position[3] <= 0) return false;
        }
        if (draw.indexed && (draw.indices.size() != 3 || draw.indices[0] >= 3 ||
            draw.indices[1] >= 3 || draw.indices[2] >= 3 || draw.indices[0] == draw.indices[1] ||
            draw.indices[0] == draw.indices[2] || draw.indices[1] == draw.indices[2])) return false;
        pair[identity-1] = &draw;
    }
    if (!pair[0] || !pair[1]) return false;
    const auto& a = *pair[0]; const auto& b = *pair[1];
    if (a.projectionWords != b.projectionWords || a.viewportX != b.viewportX ||
        a.viewportY != b.viewportY || a.viewportWidth != b.viewportWidth ||
        a.viewportHeight != b.viewportHeight) return false;
    // Both triangles must still share their original edge after transforms and
    // any Smooth Motion interpolation. Draw order alone proves nothing.
    for (size_t i = 0; i < 2; ++i) {
        const auto& x = a.vertices[i]; const auto& y = b.vertices[1-i];
        if (memcmp(x.position, y.position, sizeof(x.position)) ||
            memcmp(x.color, y.color, sizeof(x.color)) ||
            memcmp(x.uv[0], y.uv[0], sizeof(x.uv[0]))) return false;
    }
    return true;
}

static bool CanyonSkyExtension(const LiveDraw& draw, std::array<LiveVertex, 6>* output) {
    if (!output || draw.canyonSkyIdentity != 1 ||
        !CanyonSkySourceUVMatches(1, draw.vertices)) return false;
    if (draw.indexed && (draw.indices.size() != 3 ||
        std::any_of(draw.indices.begin(), draw.indices.end(), [](u32 index) { return index >= 3; }))) return false;
    for (const auto& vertex : draw.vertices) {
        for (float value : vertex.position) if (!std::isfinite(value)) return false;
        for (float value : vertex.color) if (!std::isfinite(value)) return false;
        if (vertex.position[3] <= 0) return false;
    }
    const auto& a = draw.vertices[0];
    const auto& bottom = draw.vertices[1]; const auto& top = draw.vertices[2];
    auto outerBottom = bottom, outerTop = top;
    // Top and inner-top have the same source V and differ by one U-repeat.
    // The affine clip derivative therefore preserves projected texture density,
    // animated phase and depth without modifying any original source vertex.
    for (size_t component = 0; component < 4; ++component) {
        const float continuation = 2.0f*(top.position[component] - a.position[component]);
        outerBottom.position[component] += continuation;
        outerTop.position[component] += continuation;
        if (!std::isfinite(outerBottom.position[component]) ||
            !std::isfinite(outerTop.position[component])) return false;
    }
    if (outerBottom.position[3] <= 0 || outerTop.position[3] <= 0) return false;
    if (outerBottom.position[0]/outerBottom.position[3] <= bottom.position[0]/bottom.position[3] ||
        outerTop.position[0]/outerTop.position[3] <= top.position[0]/top.position[3]) return false;
    outerBottom.uv[0][0] += 2; outerTop.uv[0][0] += 2;
    auto area = [](const LiveVertex& x, const LiveVertex& y, const LiveVertex& z) {
        return (y.position[0]/y.position[3] - x.position[0]/x.position[3]) *
            (z.position[1]/z.position[3] - x.position[1]/x.position[3]) -
            (y.position[1]/y.position[3] - x.position[1]/x.position[3]) *
            (z.position[0]/z.position[3] - x.position[0]/x.position[3]);
    };
    const float winding = draw.indexed ? area(draw.vertices[draw.indices[0]],
        draw.vertices[draw.indices[1]], draw.vertices[draw.indices[2]]) : area(a, bottom, top);
    if (!std::isfinite(winding) || std::abs(winding) < 1e-8f) return false;
    *output = {bottom, outerBottom, outerTop, bottom, outerTop, top};
    for (size_t i = 0; i < output->size(); i += 3) {
        const float triangle = area((*output)[i], (*output)[i+1], (*output)[i+2]);
        if (!std::isfinite(triangle) || std::abs(triangle) < 1e-8f) return false;
        if (triangle*winding < 0) std::swap((*output)[i+1], (*output)[i+2]);
    }
    return true;
}
