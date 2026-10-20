// Exact source-bound continuation of the original 33_02 city sky's left edge.
// Provenance hashes and UV topology are metadata; original XYZ/pixels stay external.
static u8 CitySkySourceIdentity(const char* digest) {
    static const char* const hashes[] = {
        "b5f3360c0774217ff96fae18db04656f2a21e516d5aab49a122d802e092ace49",
        "910c3a2ff90fe14dc6c67044b359503a58c51380e667ee982832cd8e68730d09",
    };
    if (digest) for (size_t i = 0; i < 2; ++i)
        if (!strcmp(digest, hashes[i])) return (u8)(i + 1);
    return 0;
}

static size_t CitySkySourceCount(u8 identity) {
    return identity == 1 ? 21 : identity == 2 ? 5 : 0;
}

static bool CitySkyMaterialMatches(const LiveDraw& draw) {
    return ClassifyWideDraw(draw) == WideDrawRole::Scene && draw.displayListDepth == 1 &&
        (draw.sourceVertexCount == 21 || draw.sourceVertexCount == 5) &&
        draw.blendMode == 13500 && draw.depthMode == 23 && draw.cullMode == 2 &&
        draw.fragment.stageCount == 1 && draw.fragment.indirectCount == 0 &&
        draw.fragment.colorCombiners[0] == 587951 && draw.fragment.alphaCombiners[0] == 586480 &&
        draw.fragment.alphaTest == 4128768 && draw.textureWidths[0] == 128 &&
        draw.textureHeights[0] == 128 && draw.textureFormats[0] == 14 &&
        draw.textureCoordinates[0] == 0 && draw.textureModes[0] == 2206901;
}

static bool CitySkyTextureMatches(const LiveDraw& draw) {
    return [InterfaceTextureKey(TexturePixels(draw, 0), 128, 128) isEqualToString:
        @"128x128-4fa436419184e34a487869d38f944dd734959a5a27fa691ddf00ea2c57be976e"];
}

static bool CitySkySourceUVMatches(u8 identity, const LiveVertex* vertices, size_t count) {
    static const s16 relativeU[21] = {0,-450,-450,-1351,-1351,-1351,0,0,0,-450,-450,
                                      -1351,-1351,-1351,0,0,0,-450,-450,-1351,-1351};
    static const s16 sourceV[2][21] = {
        {710,483,710,483,710,710,846,846,846,710,846,710,846,846,993,993,993,846,993,846,993},
        {483,30,483,30,483},
    };
    if (!vertices || !CitySkySourceCount(identity) || count != CitySkySourceCount(identity)) return false;
    const float phase = vertices[0].uv[0][0];
    if (!std::isfinite(phase)) return false;
    for (size_t i = 0; i < count; ++i)
        if (!std::isfinite(vertices[i].uv[0][0]) ||
            std::abs(vertices[i].uv[0][0] - phase - relativeU[i]/1024.0f) > 1e-6f ||
            vertices[i].uv[0][1] != sourceV[identity-1][i]/1024.0f) return false;
    return true;
}

static bool CitySkySourceVertices(const LiveDraw& draw, std::array<LiveVertex,21>* output) {
    const size_t count = CitySkySourceCount(draw.citySkyIdentity);
    if (!output || !count || draw.sourceVertexCount != count) return false;
    const size_t expanded = (count-2)*3;
    if (draw.indexed) {
        if (draw.vertices.size() != count || draw.indices.size() != expanded) return false;
        std::copy(draw.vertices.begin(), draw.vertices.end(), output->begin());
    } else {
        if (draw.vertices.size() != expanded || !draw.indices.empty()) return false;
        for (size_t i = 0; i < count; ++i)
            (*output)[i] = draw.vertices[i < 3 ? i : (i-2)*3+2];
    }
    for (size_t i = 2; i < count; ++i) {
        const size_t expected[] = {i-(i%2 ? 1u : 2u), i-(i%2 ? 2u : 1u), i};
        for (size_t j = 0; j < 3; ++j) {
            const size_t slot = (i-2)*3+j;
            if (draw.indexed ? draw.indices[slot] != expected[j] :
                memcmp(&draw.vertices[slot], &(*output)[expected[j]], sizeof(LiveVertex)) != 0) return false;
        }
    }
    for (size_t i = 0; i < count; ++i) {
        const auto& vertex = (*output)[i];
        for (float value : vertex.position) if (!std::isfinite(value)) return false;
        for (float value : vertex.color) if (!std::isfinite(value)) return false;
        if (vertex.position[3] <= 0) return false;
    }
    return CitySkySourceUVMatches(draw.citySkyIdentity, output->data(), count);
}

static bool CitySkyCohort(const std::vector<LiveDraw>& draws) {
    const LiveDraw* pair[2] = {};
    std::array<LiveVertex,21> source[2]{};
    for (const auto& draw : draws) if (draw.citySkyIdentity) {
        const u8 identity = draw.citySkyIdentity;
        if (identity > 2 || pair[identity-1] || !CitySkySourceVertices(draw, &source[identity-1])) return false;
        pair[identity-1] = &draw;
    }
    if (!pair[0] || !pair[1]) return false;
    const auto& a = *pair[0]; const auto& b = *pair[1];
    if (a.projectionWords != b.projectionWords || a.viewportX != b.viewportX ||
        a.viewportY != b.viewportY || a.viewportWidth != b.viewportWidth ||
        a.viewportHeight != b.viewportHeight) return false;
    // Both source pieces must retain their shared top seam, also after motion
    // interpolation. Merely sharing a texture, name or draw order is insufficient.
    for (size_t i = 0; i < 2; ++i) {
        const auto& x = source[0][i ? 3 : 1]; const auto& y = source[1][i ? 4 : 2];
        if (memcmp(x.position, y.position, sizeof(x.position)) ||
            memcmp(x.color, y.color, sizeof(x.color)) ||
            memcmp(x.uv[0], y.uv[0], sizeof(x.uv[0]))) return false;
    }
    return true;
}

static bool CitySkyExtension(const LiveDraw& draw, std::array<LiveVertex,18>* output) {
    std::array<LiveVertex,21> source{};
    if (!output || draw.citySkyIdentity != 1 || !CitySkySourceVertices(draw, &source)) return false;
    const size_t edge[] = {3,4,12,20}, inner[] = {1,2,10,18};
    std::array<LiveVertex,4> outer{};
    for (size_t i = 0; i < 4; ++i) {
        const auto& a = source[edge[i]]; const auto& b = source[inner[i]];
        const float du = a.uv[0][0] - b.uv[0][0];
        if (std::abs(du) < 1e-6f || a.uv[0][1] != b.uv[0][1]) return false;
        outer[i] = a;
        for (size_t component = 0; component < 4; ++component) {
            outer[i].position[component] -= 2.0f*(a.position[component]-b.position[component])/du;
            if (!std::isfinite(outer[i].position[component])) return false;
        }
        if (outer[i].position[3] <= 0 ||
            outer[i].position[0]/outer[i].position[3] >= a.position[0]/a.position[3]) return false;
        outer[i].uv[0][0] -= 2.0f;
    }
    auto area = [](const LiveVertex& a, const LiveVertex& b, const LiveVertex& c) {
        return (b.position[0]/b.position[3]-a.position[0]/a.position[3]) *
            (c.position[1]/c.position[3]-a.position[1]/a.position[3]) -
            (c.position[0]/c.position[3]-a.position[0]/a.position[3]) *
            (b.position[1]/b.position[3]-a.position[1]/a.position[3]);
    };
    std::array<LiveVertex,18> result{};
    for (size_t i = 0; i < 3; ++i) {
        const auto& top = source[edge[i]]; const auto& bottom = source[edge[i+1]];
        const float winding = area(source[inner[i+1]], top, bottom);
        if (!std::isfinite(winding) || std::abs(winding) < 1e-8f) return false;
        const LiveVertex quad[] = {top, outer[i], outer[i+1], top, outer[i+1], bottom};
        std::copy(std::begin(quad), std::end(quad), result.begin()+i*6);
        for (size_t j = i*6; j < i*6+6; j += 3) {
            const float triangle = area(result[j], result[j+1], result[j+2]);
            if (!std::isfinite(triangle) || std::abs(triangle) < 1e-8f) return false;
            if (triangle*winding < 0) std::swap(result[j+1], result[j+2]);
        }
    }
    *output = result;
    return true;
}
