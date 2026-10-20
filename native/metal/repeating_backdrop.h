// Source-bound continuation of the existing repeating Yellowstone forest.
// Included after LiveDraw and the source-texture identity helpers.
// Fingerprints are provenance metadata, never packaged game geometry/pixels.
static u8 RepeatingBackdropSourceIdentity(const char* digest) {
    static const char* const keys[] = {
        "8f56d6148837c51e3f29de3a0667c85be077392529e1f295c96effce69cd9b94",
        "8f87b77e07610c469f72a58c2f9b54fcaa0fbcd800cf6e7d625600f2361c5463",
        "9eba27700e6b56c30ee2f3adfb06770f6d2b1851e35137e96198cc71338d1935",
        "e8725bb6c3853efb445ac842a22405962e4bbfa1e7aa9814c1257adcd92fc821",
    };
    if (digest) for (size_t i = 0; i < 4; ++i)
        if (!strcmp(digest, keys[i])) return (u8)(i + 1);
    return 0;
}

static bool RepeatingBackdropMaterialMatches(const LiveDraw& draw) {
    if (ClassifyWideDraw(draw) != WideDrawRole::Scene || draw.displayListDepth != 1 ||
        draw.sourceVertexCount != 3 || draw.blendMode != 13501 || draw.depthMode != 23 ||
        draw.cullMode != 2 || draw.fragment.stageCount != 2 || draw.fragment.indirectCount != 0 ||
        draw.fragment.colorCombiners[0] != 587951 || draw.fragment.alphaCombiners[0] != 65520 ||
        draw.fragment.colorCombiners[1] != 589808 || draw.fragment.alphaCombiners[1] != 586492) return false;
    for (size_t stage = 0; stage < 2; ++stage)
        if (draw.textureWidths[stage] != 256 || draw.textureHeights[stage] != 128 ||
            draw.textureFormats[stage] != 14 || draw.textureCoordinates[stage] != 0 ||
            draw.textureModes[stage] != 2206901) return false;
    return true;
}

static bool RepeatingBackdropSourceUVMatches(u8 identity, const std::vector<LiveVertex>& vertices) {
    static const s16 uv[4][3][2] = {
        {{-24,1007},{-1628,10},{-1628,1007}},
        {{-24,10},{1743,1007},{1743,10}},
        {{1743,1007},{-24,10},{-24,1007}},
        {{-1628,10},{-24,1007},{-24,10}},
    };
    if (!identity || identity > 4 || vertices.size() != 3) return false;
    for (size_t i = 0; i < 3; ++i) for (size_t stage = 0; stage < 2; ++stage)
        for (size_t component = 0; component < 2; ++component)
            if (vertices[i].uv[stage][component] != uv[identity-1][i][component]/1024.0f) return false;
    return true;
}

static bool RepeatingBackdropTexturesMatch(const LiveDraw& draw) {
    return [InterfaceTextureKey(TexturePixels(draw,0),256,128) isEqualToString:
        @"256x128-8572a969a4ab906ee00e39764dec06b6b4faf351a606a9b7245534cc3fb3436b"] &&
        [InterfaceTextureKey(TexturePixels(draw,1),256,128) isEqualToString:
        @"256x128-dc4ab731eb6c0a59ba01e89eaf80dd1dbd75446ef599921b84e5a304aad5c049"];
}

static bool RepeatingBackdropCohort(const std::vector<LiveDraw>& draws) {
    unsigned seen = 0;
    const LiveDraw* first = nullptr;
    for (const auto& draw : draws) if (draw.repeatingBackdropIdentity) {
        const u8 identity = draw.repeatingBackdropIdentity;
        if (identity > 4 || (seen & (1u << identity)) || draw.vertices.size() != 3) return false;
        if (first && (draw.projectionWords != first->projectionWords ||
            draw.viewportX != first->viewportX || draw.viewportY != first->viewportY ||
            draw.viewportWidth != first->viewportWidth || draw.viewportHeight != first->viewportHeight)) return false;
        first = &draw;
        seen |= 1u << identity;
    }
    return seen == 30;
}

static bool RepeatingBackdropExtension(const LiveDraw& draw, std::array<LiveVertex,12>* output) {
    // Only the two outer triangles contain complete outer edges. The two
    // adjoining triangles are cohort anchors and never receive extra geometry.
    if (!output || (draw.repeatingBackdropIdentity != 1 && draw.repeatingBackdropIdentity != 2) ||
        draw.vertices.size() != 3) return false;
    const auto& a = draw.vertices[0];
    const auto& b = draw.vertices[1];
    const auto& c = draw.vertices[2];
    for (const auto& vertex : draw.vertices) {
        for (float value : vertex.position) if (!std::isfinite(value)) return false;
        for (size_t stage = 0; stage < 2; ++stage) for (float value : vertex.uv[stage])
            if (!std::isfinite(value)) return false;
        if (vertex.position[3] <= 0) return false;
    }
    const float outerU = draw.repeatingBackdropIdentity == 1 ? -1628.0f/1024.0f : 1743.0f/1024.0f;
    std::array<LiveVertex,2> edge{};
    size_t edgeCount = 0;
    for (const auto& vertex : draw.vertices) if (vertex.uv[0][0] == outerU) {
        if (edgeCount == 2) return false;
        edge[edgeCount++] = vertex;
    }
    if (edgeCount != 2) return false;
    const float du1 = b.uv[0][0]-a.uv[0][0], dv1 = b.uv[0][1]-a.uv[0][1];
    const float du2 = c.uv[0][0]-a.uv[0][0], dv2 = c.uv[0][1]-a.uv[0][1];
    const float determinant = du1*dv2-du2*dv1;
    if (!std::isfinite(determinant) || std::abs(determinant) < 1e-8f) return false;
    const float distance = draw.repeatingBackdropIdentity == 1 ? -2.0f : 2.0f;
    auto outer = edge;
    for (size_t component = 0; component < 4; ++component) {
        const float derivative = ((b.position[component]-a.position[component])*dv2 -
            (c.position[component]-a.position[component])*dv1)/determinant;
        for (auto& vertex : outer) {
            vertex.position[component] += distance*derivative;
            if (!std::isfinite(vertex.position[component])) return false;
        }
    }
    for (auto& vertex : outer) {
        if (vertex.position[3] <= 0) return false;
        for (size_t stage = 0; stage < 2; ++stage) vertex.uv[stage][0] += distance;
    }
    auto area = [](const LiveVertex& x, const LiveVertex& y, const LiveVertex& z) {
        return (y.position[0]/y.position[3]-x.position[0]/x.position[3]) *
            (z.position[1]/z.position[3]-x.position[1]/x.position[3]) -
            (y.position[1]/y.position[3]-x.position[1]/x.position[3]) *
            (z.position[0]/z.position[3]-x.position[0]/x.position[3]);
    };
    if (draw.indexed && (draw.indices.size() != 3 || std::any_of(draw.indices.begin(),draw.indices.end(),
            [](u32 index) { return index >= 3; }))) return false;
    const float winding = draw.indexed ? area(draw.vertices[draw.indices[0]],draw.vertices[draw.indices[1]],
        draw.vertices[draw.indices[2]]) : area(a,b,c);
    if (!std::isfinite(winding) || std::abs(winding) < 1e-8f) return false;
    // The new side strip can extend past the finite terrain silhouette. Keep
    // its exact bottom-edge sample behind that terrain instead of exposing a
    // sky slit. Only these additional vertices move down; trees stay unscaled.
    const size_t bottom = edge[0].uv[0][1] > edge[1].uv[0][1] ? 0 : 1;
    auto lowerInner = edge[bottom], lowerOuter = outer[bottom];
    lowerInner.position[1] = std::min(lowerInner.position[1],-lowerInner.position[3]);
    lowerOuter.position[1] = std::min(lowerOuter.position[1],-lowerOuter.position[3]);
    *output = {edge[0],outer[0],outer[1],edge[0],outer[1],edge[1],
        edge[bottom],lowerInner,lowerOuter,edge[bottom],lowerOuter,outer[bottom]};
    for (size_t i = 0; i < 12; i += 3) {
        const float triangle = area((*output)[i],(*output)[i+1],(*output)[i+2]);
        if (!std::isfinite(triangle) || (i < 6 && std::abs(triangle) < 1e-8f)) return false;
        if (triangle*winding < 0) std::swap((*output)[i+1],(*output)[i+2]);
    }
    return true;
}
