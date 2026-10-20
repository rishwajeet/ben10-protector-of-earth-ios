#pragma once

// Source 05_07 / 05_11 menus share this complete panel-and-character
// component over a perspective room, not the 99_91 DNA frontend. Admission
// never changes gallery images or locks; only the admitted panel/copy and
// its departing character receive host-upload transforms.
struct GalleryLayoutAdmission {
    size_t first = 0;
    bool enabled = false;
    bool gallery = false;
    bool extrasBrowser = false;
    bool extrasFullView = false;
    bool extrasMovie = false;
    bool extrasOptions = false;
    size_t extrasItems = 0;
    float panelCenter = 0;
    const char* reason = "not-source-scene-menu";
    FrontendRole role(size_t index) const {
        if (!enabled || index < first) return FrontendRole::Unknown;
        const size_t offset = index-first;
        if (offset < 4) return FrontendRole::PanelStrip;
        if (offset == 4) return FrontendRole::PanelFill;
        if (offset < 9) return FrontendRole::PanelCorner;
        if (offset == 9) return FrontendRole::XLR8;
        if (!gallery && !extrasBrowser && !extrasOptions && offset < 20)
            return offset == 10 ? FrontendRole::Text : FrontendRole::AuxiliaryText;
        return FrontendRole::Unknown;
    }
};

static bool GalleryQuadBounds(const LiveDraw& draw, float left, float right, float bottom, float top) {
    if (!draw.indexed || draw.vertices.size() != 4) return false;
    float actualLeft = draw.vertices[0].position[0], actualRight = actualLeft;
    float actualBottom = draw.vertices[0].position[1], actualTop = actualBottom;
    unsigned corners = 0;
    for (const auto& vertex : draw.vertices) {
        actualLeft = std::min(actualLeft,vertex.position[0]);
        actualRight = std::max(actualRight,vertex.position[0]);
        actualBottom = std::min(actualBottom,vertex.position[1]);
        actualTop = std::max(actualTop,vertex.position[1]);
        if (std::abs(vertex.position[2]-0.00625002384f) > 0.00001f) return false;
        const bool atLeft = std::abs(vertex.position[0]-left) < 0.00001f;
        const bool atRight = std::abs(vertex.position[0]-right) < 0.00001f;
        const bool atBottom = std::abs(vertex.position[1]-bottom) < 0.00001f;
        const bool atTop = std::abs(vertex.position[1]-top) < 0.00001f;
        if ((!atLeft && !atRight) || (!atBottom && !atTop)) return false;
        corners |= 1u << ((atRight ? 1u : 0u)+(atTop ? 2u : 0u));
    }
    return corners == 15 && std::abs(actualLeft-left) < 0.00001f && std::abs(actualRight-right) < 0.00001f &&
        std::abs(actualBottom-bottom) < 0.00001f && std::abs(actualTop-top) < 0.00001f;
}

static GalleryLayoutAdmission IdentifyGalleryLayout(const std::vector<LiveDraw>& draws,
    const std::vector<LiveEfbCopy>& copies, s32 cinematicDraw = -1) {
    GalleryLayoutAdmission result;
    if (draws.size() < 21 || draws.size() > 4096 || copies.size() != 1 ||
        copies[0].drawIndex != draws.size() || copies[0].command != 18435 ||
        copies[0].sourceX || copies[0].sourceY || copies[0].width != 640 ||
        copies[0].height != 448 || copies[0].yScale != 256) return result;
    // The renderer has already validated the exact movie quad and its live
    // source clock. Extras playback replaces the room with that one draw;
    // its hidden panels, selector and all fourteen items remain afterward.
    const bool movie = cinematicDraw == 0;
    if (cinematicDraw > 0) return result;
    if (movie && (draws[0].projectionWords[6] != 1 || draws[0].fragment.stageCount != 4 ||
        !draws[0].indexed || draws[0].vertices.size() != 4)) return result;
    size_t first = movie ? 1 : 0;
    while (first < draws.size() && ClassifyWideDraw(draws[first]) == WideDrawRole::Scene) ++first;
    const size_t componentCount = draws.size()-first;
    // Secrets and Code share the departing Extras component, but own every
    // list, symbol and instruction after it. Geometry identifies the variant
    // before font preflight; full source tuples below admit the composition.
    const bool secrets = componentCount >= 37 && componentCount <= 56 &&
        GalleryQuadBounds(draws[first+19],-.84375f,.059375f,-.683035731f,.687500060f);
    const bool code = componentCount == 29 &&
        GalleryQuadBounds(draws[first+10],-.7625f,.759375f,-.383928597f,.366071433f);
    const bool options = secrets || code;
    // The four source browser grids have a distinct complete second
    // panel. Identify that geometry before the font preflight; their counts
    // overlap Concept Art, and the selection glow is not always drawn first.
    struct BrowserPanel { size_t items, fonts; float bounds[9][4]; };
    constexpr BrowserPanel browserPanels[] = {
        {14,3,{
            {-.8625f,.859375f,.46875f,.602678597f},
            {.89375f,.965625f,-.508928597f,.508928597f},
            {-.8625f,.859375f,-.598214328f,-.464285731f},
            {-.96875f,-.896875f,-.508928597f,.508928597f},
            {-.90625f,.90625f,-.5f,.5f},
            {-.96875f,-.76875f,-.575892866f,-.3125f},
            {.76875f,.96875f,-.575892866f,-.3125f},
            {-.96875f,-.76875f,.3125f,.580357194f},
            {.76875f,.96875f,.3125f,.580357194f},
        }},
        {20,3,{
            {-.890625f,.890625f,.633928597f,.767857194f},
            {.925f,.996875f,-.678571463f,.678571463f},
            {-.890625f,.890625f,-.763392866f,-.629464328f},
            {-1.f,-.928125f,-.678571463f,.678571463f},
            {-.9375f,.9375f,-.665178597f,.669642866f},
            {-1.f,-.8f,-.745535731f,-.477678597f},
            {.8f,1.f,-.745535731f,-.477678597f},
            {-1.f,-.8f,.482142866f,.750000060f},
            {.8f,1.f,.482142866f,.750000060f},
        }},
        {30,4,{
            {-.890625f,.890625f,.65625f,.790178597f},
            {.925f,.996875f,-.696428597f,.700892866f},
            {-.890625f,.890625f,-.785714328f,-.651785731f},
            {-1.f,-.928125f,-.696428597f,.700892866f},
            {-.9375f,.9375f,-.687500060f,.687500060f},
            {-1.f,-.8f,-.763392866f,-.5f},
            {.8f,1.f,-.763392866f,-.5f},
            {-1.f,-.8f,.5f,.767857194f},
            {.8f,1.f,.5f,.767857194f},
        }},
        {11,3,{
            {-.890625f,.890625f,.366071433f,.5f},
            {.925f,.996875f,-.401785731f,.406250030f},
            {-.890625f,.890625f,-.495535731f,-.361607164f},
            {-1.f,-.928125f,-.401785731f,.406250030f},
            {-.9375f,.9375f,-.392857164f,.397321433f},
            {-1.f,-.8f,-.473214298f,-.205357149f},
            {.8f,1.f,-.473214298f,-.205357149f},
            {-1.f,-.8f,.209821433f,.477678597f},
            {.8f,1.f,.209821433f,.477678597f},
        }},
    };
    const BrowserPanel* browser = nullptr;
    bool browserFullView = false;
    for (const auto& candidate : browserPanels) {
        if (options) break;
        const size_t base=20+candidate.items;
        const bool playback=movie && candidate.items==14 && componentCount==base;
        // EnemyViewer retains two offscreen body-font draws plus Back;
        // HeroViewer and BossViewer retain one offscreen draw plus Back.
        const size_t fullViewFonts=candidate.items==30 ? 3 : 2;
        const bool fullView=!movie && componentCount==base+fullViewFonts && candidate.items!=14;
        const bool browserGrid=componentCount>=base+candidate.fonts &&
            componentCount<=base+candidate.fonts+candidate.items+1 && !movie;
        if (!playback && !fullView && !browserGrid) continue;
        const auto& b = candidate.bounds[0];
        if (GalleryQuadBounds(draws[first+10],b[0],b[1],b[2],b[3])) {
            browser=&candidate;browserFullView=fullView;break;
        }
    }
    if (movie && (first != 1 || !browser || options)) return result;
    // Browsing adds source-owned "new" labels and an Open Art hint as items
    // unlock; viewing art keeps only Back and the offscreen source text draw.
    // Counts bound the preflight, but the complete panels, frame geometry and
    // font profiles below still identify the composition, not the count alone.
    const bool fullArt = componentCount == 36;
    const bool grid = componentCount >= 39 && componentCount <= 52;
    if (!first || (componentCount != 20 && !fullArt && !grid && !browser && !options)) return result;
    const bool gallery = !options && !browser && (fullArt || grid);
    const size_t fontStart = secrets ? 25 : code ? 23 : browser ? 20+browser->items : gallery ? 34 : 10;
    // Cheap complete state/shape preflight runs before any texture hashing.
    for (size_t i=first; i<draws.size(); ++i) {
        const size_t offset = i-first;
        const bool font = offset >= fontStart;
        const auto& draw = draws[i];
        if (draw.viewportX != 0 || draw.viewportY != 0 || draw.viewportWidth != 640 ||
            !FrontendDrawStateMatches(draw,font ? FrontendRole::AuxiliaryText : FrontendRole::MenuArt,
                movie ? 1213u : 13501u)) return result;
    }
    // Stable panel geometry and full ordered source texture tuples anchor the
    // composition. The character may slide horizontally during its transition.
    constexpr float panelBounds[][4] = {
        {-1.325f,.721875f,.59375f,.727678597f},
        {.765625f,.8375f,-.633928597f,.638392866f},
        {-1.325f,.721875f,-.723214328f,-.589285731f},
        {-1.440625f,-1.36875f,-.633928597f,.638392866f},
        {-1.378125f,.778125f,-.625f,.625f},
        {-1.440625f,-1.240625f,-.700892866f,-.4375f},
        {.640625f,.840625f,-.700892866f,-.4375f},
        {-1.440625f,-1.240625f,.4375f,.705357194f},
        {.640625f,.840625f,.4375f,.705357194f},
    };
    for (size_t i=0; i<9; ++i)
        if (!GalleryQuadBounds(draws[first+i],panelBounds[i][0],panelBounds[i][1],
            panelBounds[i][2],panelBounds[i][3])) return result;
    const auto& character = draws[first+9];
    float characterLeft = character.vertices[0].position[0];
    for (const auto& vertex : character.vertices) characterLeft = std::min(characterLeft,vertex.position[0]);
    if (characterLeft < -3 || characterLeft > -0.99f ||
        !GalleryQuadBounds(character,characterLeft,characterLeft+1.6f,-.625f,.441964298f)) return result;
    std::map<std::tuple<const u8*,size_t,u32,u32>,NSString*> keys;
    auto key = [&](const LiveDraw& draw, size_t stage) -> NSString* {
        const auto& pixels = TexturePixels(draw,stage);
        const auto identity = std::make_tuple(pixels.data(),pixels.size(),draw.textureWidths[stage],draw.textureHeights[stage]);
        auto found = keys.find(identity);
        if (found != keys.end()) return found->second;
        NSString* value = InterfaceTextureKey(pixels,draw.textureWidths[stage],draw.textureHeights[stage]);
        keys.emplace(identity,value); return value;
    };
    auto profile = [&](size_t offset, int expected) {
        const auto& draw = draws[first+offset];
        return FrontendProfileForKeys(key(draw,0),draw.fragment.stageCount == 2 ? key(draw,1) : nil) == expected;
    };
    constexpr int panelProfiles[] = {21,21,21,21,23,22,22,22,22,25};
    for (size_t i=0; i<10; ++i) if (!profile(i,panelProfiles[i])) return result;
    auto tuple = [&](size_t offset, NSString* primary, NSString* alpha) {
        const auto& draw = draws[first+offset];
        return draw.fragment.stageCount == (alpha ? 2u : 1u) &&
            [key(draw,0) isEqualToString:primary] && (!alpha || [key(draw,1) isEqualToString:alpha]);
    };
    if (secrets) {
        for (size_t i=0; i<9; ++i) {
            const auto& b = browserPanels[1].bounds[i];
            if (!profile(10+i,panelProfiles[i]) ||
                !GalleryQuadBounds(draws[first+10+i],b[0],b[1],b[2],b[3])) return result;
        }
        constexpr float columns[][2] = {{-.84375f,.059375f},{-.928125f,-.828125f},
            {.046875f,.146875f},{.25f,.840625f},{.165625f,.265625f},{.828125f,.928125f}};
        for (size_t i=0; i<6; ++i) {
            const bool fill = i%3 == 0;
            if (!GalleryQuadBounds(draws[first+19+i],columns[i][0],columns[i][1],-.683035731f,.687500060f) ||
                !tuple(19+i,fill ? @"32x256-0ca2d693b7a7fc467b0015bdda48f9dcc1e1639ebd37c1ae974f63048a4a5237" :
                    @"32x256-030790dabdeb2edc8e35f0cbf93a4eed82b0d3e89451b647191f79bcfe1c085a",
                    fill ? @"32x256-dedfecf983b21d4ba1a31588469409fb86cdf920ae2512cb9731952d3dbae2a4" :
                    @"32x256-5eeb0118b7a6a714d30ce5b494873a9368d92c58e5a44993c3122e6feabe7858")) return result;
        }
    } else if (code) {
        constexpr float fixedBounds[][4] = {
            {-.7625f,.759375f,-.383928597f,.366071433f},
            {-.85f,-.75f,-.383928597f,.366071433f},{.75f,.85f,-.383928597f,.366071433f},
            {-.625f,.625f,-.129464298f,.133928582f},
            {-.803125f,-.603125f,-.129464298f,.133928582f},{.603125f,.803125f,-.129464298f,.133928582f},
        };
        for (size_t i=0; i<6; ++i) {
            const auto& b = fixedBounds[i];
            if (!GalleryQuadBounds(draws[first+10+i],b[0],b[1],b[2],b[3])) return result;
        }
        if (!tuple(10,@"32x128-74f1d8612646f3bd9c52055471f33d653f4c6bcb096b7e2383be7eaa36ccb709",
            @"32x128-0681afac96b231ada3934ed19a29d1f8e7cbfc6400713da65434ed4f949f42dd")) return result;
        for (size_t i : {11u,12u}) if (!tuple(i,
            @"32x128-67ae129af7de5970b64949de1f1aebb62246da783475cfd56d355d63d70e0ada",
            @"32x128-4ac73086e12bfdab155e6b4b3e25341e72f2e103db96a8eb0b61d34f6a06627f")) return result;
        if (!tuple(13,@"32x64-dba10d084a084e7826164c5435f94786d4d27d69509bdfe02aa9515a6a9afbaa",nil)) return result;
        for (size_t i : {14u,15u}) if (!tuple(i,
            @"64x64-c8c6ffd8a2c5d83e907799a24ec8afd909e7c9c57b6029c58e4bf83c94693572",
            @"64x64-4411e76351163897a5b84c051200953c6173cc1fbbf78df296d83e1ca07398e7")) return result;
        for (size_t i : {16u,17u}) if (!tuple(i,
            @"32x16-fb59bf7e4c00676b20a73c7c3528eb156c868f5d1b3d780008d1e8b20d7e3581",
            @"32x16-ae473876dab68898cfe19a7b21c337ee4d3d97eaa6ac93f29bd92ba7369693c5")) return result;
        // The green/yellow selection material is fixed, but its alpha follows
        // the selected alien's silhouette (Cannonbolt and Four Arms verified
        // from actual source draws). That mask is content, not a screen key.
        const auto& glow = draws[first+18];
        if (glow.fragment.stageCount != 2 ||
            ![key(glow,0) isEqualToString:@"128x64-cb64bdc4ecfc072d21df1ed5e6817dc977af79727cec0626b54b40d2a36d0c7b"] ||
            glow.textureWidths[1] != 128 || glow.textureHeights[1] != 64) return result;
        bool selected = false;
        for (size_t column=0; column<4; ++column) {
            const float center = -.46875f+.3125f*column;
            selected |= GalleryQuadBounds(draws[first+16],center-.0375f,center+.0375f,.178571433f,.245535731f) &&
                GalleryQuadBounds(draws[first+17],center-.0375f,center+.0375f,-.241071433f,-.174107149f) &&
                GalleryQuadBounds(draws[first+18],center-.15f,center+.15f,-.129464298f,.133928582f);
            const auto& symbol = draws[first+19+column];
            if (!GalleryQuadBounds(symbol,center-.15f,center+.15f,-.129464298f,.133928582f) ||
                symbol.fragment.stageCount != 2 || symbol.textureWidths[0] != 128 || symbol.textureHeights[0] != 64 ||
                symbol.textureWidths[1] != 128 || symbol.textureHeights[1] != 64) return result;
        }
        if (!selected) return result;
    }
    if (options) {
        for (size_t i=fontStart; i<componentCount; ++i)
            if (!profile(i,i == fontStart ? 19 : 20)) return result;
    } else if (browser) {
        for (size_t i=0; i<9; ++i) {
            const auto& b = browser->bounds[i];
            if (!profile(10+i,panelProfiles[i]) ||
                !GalleryQuadBounds(draws[first+10+i],b[0],b[1],b[2],b[3])) return result;
        }
        size_t selectors = 0;
        for (size_t i=19; i<fontStart; ++i) {
            const auto& draw = draws[first+i];
            if (draw.fragment.stageCount == 2 &&
                [key(draw,0) isEqualToString:@"64x64-282b4fb9a89612a84eef5e9f37d05cbf7defe7809d5190c706b274c0d92de922"] &&
                [key(draw,1) isEqualToString:@"64x64-6044107167d8405f0654b7948a5371a5f178c03ff32323ac5ba69babd112ec80"]) ++selectors;
        }
        if (selectors != 1) return result;
        if ((browser->items == 20 || browser->items == 11) && !browserFullView) {
            // HeroViewer and BossViewer use the headline font for each
            // three-glyph "new" tag. Complete unlocked source groups place those
            // tags after the heading and before two or three body-font rows.
            // Movies and EnemyViewer retain their body-font tag sequence.
            if (!profile(fontStart,19)) return result;
            size_t cursor = fontStart+1, tags = 0;
            while (cursor < componentCount && profile(cursor,19)) {
                const auto& tag = draws[first+cursor];
                if (tag.vertices.size() != (tag.indexed ? 12u : 18u) || ++tags > browser->items) return result;
                ++cursor;
            }
            const size_t bodyRows = componentCount-cursor;
            if (bodyRows < browser->fonts-1 || bodyRows > browser->fonts) return result;
            for (; cursor<componentCount; ++cursor) if (!profile(cursor,20)) return result;
        } else {
            for (size_t i=fontStart; i<componentCount; ++i)
                if (!profile(i,i == fontStart && !browserFullView ? 19 : 20)) return result;
        }
    } else if (!gallery) {
        for (size_t i=10; i<20; ++i) if (!profile(i,i == 10 ? 19 : 20)) return result;
    } else {
        // The second complete panel and one of the two observed source-frame
        // geometries identify the gallery. Neither receives a transform. Art,
        // thumbnails and labels remain unmodified source-owned data; no unlock
        // state is required and hidden art is never made visible.
        constexpr float gridBounds[][4] = {
            {-.8625f,.859375f,-.165178582f,-.03125f},
            {.89375f,.965625f,-.754464328f,-.125f},
            {-.8625f,.859375f,-.848214328f,-.714285731f},
            {-.96875f,-.896875f,-.754464328f,-.125f},
            {-.90625f,.90625f,-.750000060f,-.129464298f},
            {-.96875f,-.76875f,-.825892866f,-.5625f},
            {.76875f,.96875f,-.825892866f,-.5625f},
            {-.96875f,-.76875f,-.316964298f,-.053571433f},
            {.76875f,.96875f,-.316964298f,-.053571433f},
        };
        for (size_t i=0; i<9; ++i)
            if (!profile(10+i,panelProfiles[i]) ||
                !GalleryQuadBounds(draws[first+10+i],gridBounds[i][0],gridBounds[i][1],
                    gridBounds[i][2],gridBounds[i][3])) return result;
        const auto& frame = draws[first+19];
        if (frame.fragment.stageCount != 1 ||
            ![key(frame,0) isEqualToString:@"256x256-57dfe660e7608e075a7d02395f7647398953cad0cd396b297007d86510340e06"]) return result;
        if (fullArt ? !GalleryQuadBounds(frame,-1.5f,1.5f,-1.397321463f,1.401785731f) :
            !GalleryQuadBounds(frame,-.3625f,.359375f,-.0625f,.897321463f)) return result;
        for (size_t i=34; i<componentCount; ++i) if (!profile(i,20)) return result;
    }
    result.first = first; result.enabled = true; result.gallery = gallery;
    result.extrasBrowser = browser != nullptr;
    result.extrasItems = browser ? browser->items : 0;
    result.extrasFullView = browserFullView;
    result.extrasMovie = movie;
    result.extrasOptions = options;
    result.panelCenter = -.3f;
    result.reason = movie ? "source-movie-extras-browser-component" :
        options ? "source-room-extras-options-component" : browserFullView ? "source-room-character-view-component" :
        browser ? "source-room-extras-browser-component" :
        gallery ? "source-room-gallery-component" : "source-room-extras-panel";
    return result;
}

static void TransformGalleryLayoutVertex(LiveVertex* vertex, FrontendRole role, double aspect,
    float drawLeft, float drawRight, float panelCenter) {
    if (role == FrontendRole::Unknown || !std::isfinite(aspect) || aspect < 4.0/3.0 || aspect > 3.0) return;
    TransformSecondaryFrontendVertex(vertex,role,aspect,drawLeft,drawRight,panelCenter);
    if (role == FrontendRole::XLR8) {
        // Preserve the source's normalized slide distance instead of damping
        // it inside a 4:3 strip. At rest left=-1 keeps the canvas edge outside;
        // on exit the whole illustration continues beyond the wide viewport.
        const float added = 1-(float)((4.0/3.0)/aspect);
        vertex->position[0] += (drawLeft+1)*added;
    }
}
