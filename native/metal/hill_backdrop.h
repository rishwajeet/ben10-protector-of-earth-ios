// Exact source-bound left hill edges. Included after LiveDraw and texture-key
// helpers. Fingerprints/UV profiles are provenance, not packaged game geometry.
static u8 HillBackdropSourceIdentity(const char* digest) {
    static const char* const keys[] = {
        "f26f343c83fb17636859687d8c84f0c275cf92999446f9ab5d5b85bc1abee1ac",
        "e6cd4b69752db4009811d1dbfc57f97fc22aab24c812f5006bd424bf25d5376a",
    };
    if (digest) for (size_t i=0; i<2; ++i) if (!strcmp(digest,keys[i])) return (u8)(i+1);
    return 0;
}

static size_t HillBackdropSourceCount(u8 identity) {
    return identity == 1 ? 10 : identity == 2 ? 16 : 0;
}

static bool HillBackdropMaterialMatches(const LiveDraw& draw) {
    return ClassifyWideDraw(draw) == WideDrawRole::Scene && draw.displayListDepth == 1 &&
        (draw.sourceVertexCount == 10 || draw.sourceVertexCount == 16) &&
        draw.blendMode == 13500 && draw.depthMode == 23 && draw.cullMode == 2 &&
        draw.fragment.stageCount == 1 && draw.fragment.indirectCount == 0 &&
        draw.fragment.colorCombiners[0] == 587951 && draw.fragment.alphaCombiners[0] == 586480 &&
        draw.textureWidths[0] == 256 && draw.textureHeights[0] == 256 &&
        draw.textureFormats[0] == 14 && draw.textureCoordinates[0] == 0 &&
        draw.textureModes[0] == 2206901;
}

static bool HillBackdropSourceUVMatches(u8 identity, const std::vector<LiveVertex>& vertices) {
    static const s16 uv[2][16][2] = {
        {{279,-1062},{279,-1096},{-1974,-750},{-1974,-785},{-1974,-785},
         {-187,977},{-187,977},{279,-1062},{-1974,977},{-1974,-750}},
        {{505,964},{340,706},{-1990,967},{-1990,967},{-1989,375},{-1989,375},
         {-1989,375},{-1990,967},{-156,-65},{340,706},{340,706},{-156,-65},
         {-156,-65},{-156,-113},{-1989,375},{-1989,327}},
    };
    const size_t count = HillBackdropSourceCount(identity);
    if (!count || vertices.size() != count) return false;
    for (size_t i=0;i<count;++i) for (size_t component=0;component<2;++component)
        if (vertices[i].uv[0][component] != uv[identity-1][i][component]/1024.0f) return false;
    return true;
}

static bool HillBackdropTexturesMatch(const LiveDraw& draw) {
    return [InterfaceTextureKey(TexturePixels(draw,0),256,256) isEqualToString:
        @"256x256-41a99ce3a48c467ef8f7f1d4b74b409ef8e6a1ac0bd6af8ee6136fb734742d8f"];
}

static bool HillBackdropTopologyMatches(const LiveDraw& draw) {
    const size_t count = HillBackdropSourceCount(draw.hillBackdropIdentity);
    if (!count || draw.sourceVertexCount != count) return false;
    const size_t expanded = (count-2)*3;
    if (!draw.indexed) return draw.vertices.size() == expanded && draw.indices.empty();
    if (draw.vertices.size() != count || draw.indices.size() != expanded) return false;
    for (size_t i=2;i<count;++i) {
        const u32 expected[] = {(u32)(i-(i%2 ? 1 : 2)),(u32)(i-(i%2 ? 2 : 1)),(u32)i};
        for (size_t j=0;j<3;++j) if (draw.indices[(i-2)*3+j] != expected[j]) return false;
    }
    return true;
}

static const LiveVertex& HillBackdropSourceVertex(const LiveDraw& draw, size_t sourceIndex) {
    if (draw.indexed) return draw.vertices[sourceIndex];
    // Admission binds triangle-strip topology, including the original connector
    // degenerates. Keep distinct source corners even when positions/UVs coincide:
    // their vertex colors distinguish the thin ink ridge from the painted body.
    if (sourceIndex < 3) return draw.vertices[sourceIndex];
    return draw.vertices[(sourceIndex-2)*3+2];
}

static bool HillBackdropCohort(const std::vector<LiveDraw>& draws) {
    unsigned seen = 0;
    const LiveDraw* first = nullptr;
    for (const auto& draw : draws) if (draw.hillBackdropIdentity) {
        const u8 id = draw.hillBackdropIdentity;
        if (id > 2 || (seen & (1u<<id)) || !HillBackdropTopologyMatches(draw)) return false;
        if (first && (draw.projectionWords != first->projectionWords ||
            draw.viewportX != first->viewportX || draw.viewportY != first->viewportY ||
            draw.viewportWidth != first->viewportWidth || draw.viewportHeight != first->viewportHeight)) return false;
        first = &draw; seen |= 1u<<id;
    }
    return seen == 6;
}

static bool HillBackdropExtension(const LiveDraw& draw, std::array<LiveVertex,12>* output) {
    if (!output || !HillBackdropTopologyMatches(draw)) return false;
    for (const auto& vertex : draw.vertices) {
        for (float value : vertex.position) if (!std::isfinite(value)) return false;
        for (float value : vertex.uv[0]) if (!std::isfinite(value)) return false;
        for (float value : vertex.color) if (!std::isfinite(value)) return false;
        if (vertex.position[3] <= 0) return false;
    }
    const bool first = draw.hillBackdropIdentity == 1;
    const size_t mapping[3] = {first ? 8u : 6u, 7u, first ? 9u : 8u};
    const auto& a = HillBackdropSourceVertex(draw,mapping[0]);
    const auto& b = HillBackdropSourceVertex(draw,mapping[1]);
    const auto& c = HillBackdropSourceVertex(draw,mapping[2]);
    const float du1=b.uv[0][0]-a.uv[0][0], dv1=b.uv[0][1]-a.uv[0][1];
    const float du2=c.uv[0][0]-a.uv[0][0], dv2=c.uv[0][1]-a.uv[0][1];
    const float determinant=du1*dv2-du2*dv1;
    if (!std::isfinite(determinant) || std::abs(determinant)<1e-8f) return false;
    auto area = [](const LiveVertex& x,const LiveVertex& y,const LiveVertex& z) {
        return (y.position[0]/y.position[3]-x.position[0]/x.position[3]) *
            (z.position[1]/z.position[3]-x.position[1]/x.position[3]) -
            (y.position[1]/y.position[3]-x.position[1]/x.position[3]) *
            (z.position[0]/z.position[3]-x.position[0]/x.position[3]);
    };
    const float winding=area(a,b,c);
    if (!std::isfinite(winding) || std::abs(winding)<1e-8f) return false;
    std::array<float,4> displacement{};
    for (size_t component=0;component<4;++component)
        displacement[component]=-8.0f*((b.position[component]-a.position[component])*dv2-
            (c.position[component]-a.position[component])*dv1)/determinant;
    const size_t edges[2][2] = {{first ? 8u : 7u,first ? 9u : 6u},{first ? 2u : 14u,first ? 3u : 15u}};
    std::array<LiveVertex,12> result{};
    for (size_t edge=0;edge<2;++edge) {
        const auto& inner0=HillBackdropSourceVertex(draw,edges[edge][0]);
        const auto& inner1=HillBackdropSourceVertex(draw,edges[edge][1]);
        auto outer0=inner0, outer1=inner1;
        for (auto* vertex : {&outer0,&outer1}) {
            for (size_t component=0;component<4;++component) {
                vertex->position[component]+=displacement[component];
                if (!std::isfinite(vertex->position[component])) return false;
            }
            if (vertex->position[3]<=0) return false;
            vertex->uv[0][0]-=8.0f;
        }
        // An unusual camera/invalid mapping must not send a left-edge addition
        // into the scene's interior. Both edge endpoints must extend leftward.
        if (outer0.position[0]/outer0.position[3] >= inner0.position[0]/inner0.position[3] ||
            outer1.position[0]/outer1.position[3] >= inner1.position[0]/inner1.position[3]) return false;
        const LiveVertex quad[] = {inner0,outer0,outer1,inner0,outer1,inner1};
        std::copy(std::begin(quad),std::end(quad),result.begin()+edge*6);
    }
    for (size_t i=0;i<12;i+=3) {
        const float triangle=area(result[i],result[i+1],result[i+2]);
        if (!std::isfinite(triangle) || std::abs(triangle)<1e-8f) return false;
        if (triangle*winding<0) std::swap(result[i+1],result[i+2]);
    }
    *output=result;
    return true;
}
