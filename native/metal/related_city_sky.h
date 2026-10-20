// Exact finite-sky continuations for original 33_01 and 33_05. Source XYZ and
// pixels remain external; hashes, UV topology and edge indices are metadata.
static u8 RelatedCitySkySourceIdentity(const char* digest) {
    static const char* const hashes[] = {
        "ac9153b4946f6e38ffd502a631a84f6caed62ef07ad40da7861059ae501b5961",
        "0cd22e54a294857c11cdc393b7ce948d98e250d8e86af3297cb3294a204769d0",
        "6420a97ac92ba9e9ce4576a83b966c82c33addb86ae7b53a43de08bc7928a90a",
        "5facb82de19f15db1023a71ec05a21b690f5335ee1a0e12b659473c7bbcffb95",
    };
    if (digest) for (size_t i = 0; i < 4; ++i)
        if (!strcmp(digest, hashes[i])) return (u8)(i + 1);
    return 0;
}

static size_t RelatedCitySkySourceCount(u8 identity) {
    static const size_t counts[] = {9, 9, 7, 3};
    return identity >= 1 && identity <= 4 ? counts[identity-1] : 0;
}

static bool RelatedCitySkyMaterialMatches(const LiveDraw& draw) {
    return ClassifyWideDraw(draw) == WideDrawRole::Scene && draw.displayListDepth == 1 &&
        (draw.sourceVertexCount == 9 || draw.sourceVertexCount == 7 || draw.sourceVertexCount == 3) &&
        draw.blendMode == 13500 && draw.depthMode == 23 && draw.cullMode == 2 &&
        draw.fragment.stageCount == 1 && draw.fragment.indirectCount == 0 &&
        draw.fragment.colorCombiners[0] == 587951 && draw.fragment.alphaCombiners[0] == 586480 &&
        draw.fragment.alphaTest == 4128768 && draw.textureWidths[0] == 128 &&
        draw.textureHeights[0] == 128 && draw.textureFormats[0] == 14 &&
        draw.textureCoordinates[0] == 0 && draw.textureModes[0] == 2206901;
}

static bool RelatedCitySkyUVMatches(u8 identity, const LiveVertex* vertices, size_t count) {
    static const s16 relativeU[4][9] = {
        {0,-953,-953,-953,0,0,0,-953,-953},
        {0,-953,-953,-953,0,0,0,-953,-953},
        {0,346,346,346,346,684,684},
        {0,338,338},
    };
    static const s16 sourceV[4][9] = {
        {713,476,713,713,476,476,476,30,476},
        {845,713,845,845,993,993,993,845,993},
        {560,12,560,560,560,12,560},
        {1014,560,1014},
    };
    if (!vertices || !RelatedCitySkySourceCount(identity) ||
        count != RelatedCitySkySourceCount(identity)) return false;
    const float phase = vertices[0].uv[0][0];
    if (!std::isfinite(phase)) return false;
    for (size_t i = 0; i < count; ++i)
        if (!std::isfinite(vertices[i].uv[0][0]) ||
            std::abs(vertices[i].uv[0][0]-phase-relativeU[identity-1][i]/1024.0f) > 1e-6f ||
            vertices[i].uv[0][1] != sourceV[identity-1][i]/1024.0f) return false;
    return true;
}

static bool RelatedCitySkyVertices(const LiveDraw& draw, std::array<LiveVertex,9>* output) {
    const size_t count = RelatedCitySkySourceCount(draw.relatedCitySkyIdentity);
    if (!output || !count || draw.sourceVertexCount != count) return false;
    const size_t expanded = (count-2)*3;
    if (draw.indexed) {
        if (draw.vertices.size() != count || draw.indices.size() != expanded) return false;
        std::copy(draw.vertices.begin(), draw.vertices.end(), output->begin());
    } else {
        if (draw.vertices.size() != expanded || !draw.indices.empty()) return false;
        for (size_t i = 0; i < count; ++i) (*output)[i] = draw.vertices[i < 3 ? i : (i-2)*3+2];
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
        for (float value : (*output)[i].position) if (!std::isfinite(value)) return false;
        for (float value : (*output)[i].color) if (!std::isfinite(value)) return false;
        if ((*output)[i].position[3] <= 0) return false;
    }
    return RelatedCitySkyUVMatches(draw.relatedCitySkyIdentity, output->data(), count);
}

// Build a complete pair atomically. Sharing one tangent keeps its extrapolated
// seam byte-identical even when independent source rows round by a few ULPs.
// A null output validates the same complete continuation for diagnostic gating.
static u8 RelatedCitySkyContinuation(const std::vector<LiveDraw>& draws,
                                     std::vector<std::vector<LiveVertex>>* output) {
    const LiveDraw* pieces[4]{};
    size_t indices[4]{};
    std::array<LiveVertex,9> source[4]{};
    unsigned mask = 0;
    for (size_t i = 0; i < draws.size(); ++i) {
        const auto& draw = draws[i]; const u8 id = draw.relatedCitySkyIdentity;
        if (!id) continue;
        if (id > 4 || pieces[id-1] || !RelatedCitySkyVertices(draw, &source[id-1])) return 0;
        pieces[id-1] = &draw; indices[id-1] = i; mask |= 1u << (id-1);
    }
    if (mask != 3 && mask != 12) return 0;
    const bool lake = mask == 3;
    const size_t first = lake ? 0 : 2;
    const auto& a = *pieces[first]; const auto& b = *pieces[first+1];
    if (a.projectionWords != b.projectionWords || a.viewportX != b.viewportX ||
        a.viewportY != b.viewportY || a.viewportWidth != b.viewportWidth ||
        a.viewportHeight != b.viewportHeight) return 0;
    const auto& upper = source[first]; const auto& lower = source[first+1];
    const auto& seamA = upper[lake ? 2 : 6]; const auto& seamB = lower[1];
    if (memcmp(seamA.position, seamB.position, sizeof(seamA.position)) ||
        memcmp(seamA.color, seamB.color, sizeof(seamA.color)) ||
        memcmp(seamA.uv[0], seamB.uv[0], sizeof(seamA.uv[0]))) return 0;
    const auto& edge = upper[lake ? 1 : 5]; const auto& inner = upper[lake ? 4 : 1];
    const float du = edge.uv[0][0]-inner.uv[0][0];
    const float lowerDU = lower[2].uv[0][0]-lower[0].uv[0][0];
    if (std::abs(du) < 1e-6f || std::abs(lowerDU) < 1e-6f ||
        edge.uv[0][1] != inner.uv[0][1] || lower[2].uv[0][1] != lower[0].uv[0][1]) return 0;
    std::array<float,4> tangent{};
    for (size_t k = 0; k < 4; ++k) {
        tangent[k] = (edge.position[k]-inner.position[k])/du;
        const float lowerTangent = (lower[2].position[k]-lower[0].position[k])/lowerDU;
        if (!std::isfinite(tangent[k]) || !std::isfinite(lowerTangent) ||
            std::abs(tangent[k]-lowerTangent) > 1e-4f + 1e-5f*std::max(std::abs(tangent[k]),std::abs(lowerTangent))) return 0;
    }
    const size_t lakeChains[2][3] = {{7,1,2},{1,2,8}};
    const size_t craneChains[2][3] = {{5,6,0},{1,2,0}};
    const size_t rows = lake ? 3 : 2;
    const float deltaU = lake ? -2.0f : 2.0f;
    auto area = [](const LiveVertex& x, const LiveVertex& y, const LiveVertex& z) {
        return (y.position[0]/y.position[3]-x.position[0]/x.position[3]) *
            (z.position[1]/z.position[3]-x.position[1]/x.position[3]) -
            (z.position[0]/z.position[3]-x.position[0]/x.position[3]) *
            (y.position[1]/y.position[3]-x.position[1]/x.position[3]);
    };
    std::vector<std::vector<LiveVertex>> result(draws.size());
    for (size_t piece = 0; piece < 2; ++piece) {
        const auto& s = source[first+piece];
        const size_t* chain = lake ? lakeChains[piece] : craneChains[piece];
        std::array<LiveVertex,3> outer{};
        const float winding = area(s[0],s[1],s[2]);
        if (!std::isfinite(winding) || std::abs(winding) < 1e-8f) return 0;
        for (size_t row = 0; row < rows; ++row) {
            const auto& v = s[chain[row]]; outer[row] = v;
            for (size_t k = 0; k < 4; ++k) {
                outer[row].position[k] += deltaU*tangent[k];
                if (!std::isfinite(outer[row].position[k])) return 0;
            }
            if (outer[row].position[3] <= 0 ||
                outer[row].position[0]/outer[row].position[3] >= v.position[0]/v.position[3]) return 0;
            outer[row].uv[0][0] += deltaU;
        }
        auto& vertices = result[indices[first+piece]];
        for (size_t row = 0; row+1 < rows; ++row) {
            LiveVertex quad[] = {s[chain[row]],outer[row],outer[row+1],
                                 s[chain[row]],outer[row+1],s[chain[row+1]]};
            for (size_t triangle = 0; triangle < 6; triangle += 3) {
                const float direction = area(quad[triangle],quad[triangle+1],quad[triangle+2]);
                if (!std::isfinite(direction) || std::abs(direction) < 1e-8f) return 0;
                if (direction*winding < 0) std::swap(quad[triangle+1],quad[triangle+2]);
            }
            vertices.insert(vertices.end(),std::begin(quad),std::end(quad));
        }
    }
    if (output) *output = std::move(result);
    return lake ? 1 : 2;
}
