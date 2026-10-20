#pragma once

// Ben10UpgradeMenu is a different script and composition from MoveList. Its
// frame-scoped owner is required even for an empty (no available move) state.
struct UpgradeGlyphAdmission : ComboGlyphAdmission {
    bool ready=false;
    UpgradeGlyphAdmission() { reason="not-source-upgrade-menu"; }
};

static UpgradeGlyphAdmission IdentifyUpgradeGlyphs(const std::vector<LiveDraw>& draws,
    const std::vector<LiveEfbCopy>& copies) {
    UpgradeGlyphAdmission result;
    if (draws.empty() || draws.size()>4096 || !draws.front().upgradeActive ||
        draws.front().upgradeScheme>3 || copies.empty()) return result;
    const auto& display=copies.back();
    if (display.drawIndex!=draws.size() || display.command!=18435 || display.sourceX ||
        display.sourceY || display.width!=640 || display.height!=448 || display.yScale!=256) return result;
    const u32 scheme=draws.front().upgradeScheme;
    const bool ready=draws.front().upgradeReady;
    for (const auto& draw:draws)
        if (!draw.upgradeActive || draw.upgradeScheme!=scheme || draw.upgradeReady!=ready) return result;
    constexpr float bounds[][4]={
        {-.9375f,.9375f,-.625f,.625f},
        {-1,-.8f,-.700892866f,-.4375f},{.8f,1,-.700892866f,-.4375f},
        {-1,-.8f,.4375f,.705357194f},{.8f,1,.4375f,.705357194f},
        {-.625f,.625f,.040178571f,.571428597f},
        {-.725f,-.625f,.040178571f,.571428597f},{.625f,.725f,.040178571f,.571428597f},
        {-.546875f,.546875f,-.566964328f,.035714287f},
        {-.646875f,-.546875f,-.566964328f,.035714287f},{.546875f,.646875f,-.566964328f,.035714287f},
        {-.8f,.8f,.066964291f,.602678597f},
    };
    size_t first=draws.size();
    for (size_t i=4;i+20<draws.size();++i) {
        if (!GalleryQuadBounds(draws[i],bounds[0][0],bounds[0][1],bounds[0][2],bounds[0][3])) continue;
        if (first!=draws.size()) return result;
        first=i;
    }
    if (first==draws.size() || draws.size()-first>40) return result;
    const size_t panelStart=first-4;
    size_t fontStart=first+12;
    while (fontStart<draws.size() && draws[fontStart].textureFormats[0]!=9) ++fontStart;
    if (fontStart<first+17 || fontStart>first+24 || draws.size()-fontStart<4 || draws.size()-fontStart>10) return result;
    for (size_t i=panelStart;i<draws.size();++i) {
        const auto& draw=draws[i];
        if (draw.viewportX || draw.viewportY || draw.viewportWidth!=640 ||
            !FrontendDrawStateMatches(draw,i>=fontStart ? FrontendRole::AuxiliaryText : FrontendRole::MenuArt)) return result;
    }
    std::map<std::tuple<const u8*,size_t,u32,u32>,NSString*> keys;
    auto key=[&](const LiveDraw& draw,size_t stage)->NSString* {
        const auto& pixels=TexturePixels(draw,stage);
        const auto identity=std::make_tuple(pixels.data(),pixels.size(),draw.textureWidths[stage],draw.textureHeights[stage]);
        auto found=keys.find(identity);if(found!=keys.end())return found->second;
        NSString* value=InterfaceTextureKey(pixels,draw.textureWidths[stage],draw.textureHeights[stage]);
        keys.emplace(identity,value);return value;
    };
    auto tuple=[&](size_t offset,NSString* primary,NSString* alpha) {
        const auto& draw=draws[first+offset];
        return draw.fragment.stageCount==(alpha?2u:1u) && [key(draw,0) isEqualToString:primary] &&
            (!alpha || [key(draw,1) isEqualToString:alpha]);
    };
    constexpr float strips[][4]={
        {-.890625f,.890625f,.59375f,.727678597f},{.925f,.996875f,-.633928597f,.638392866f},
        {-.890625f,.890625f,-.723214328f,-.589285731f},{-1,-.928125f,-.633928597f,.638392866f},
    };
    for (size_t i=0;i<4;++i) {
        const auto& draw=draws[panelStart+i];
        if (!GalleryQuadBounds(draw,strips[i][0],strips[i][1],strips[i][2],strips[i][3]) ||
            draw.fragment.stageCount!=2 || ![key(draw,0) isEqualToString:@(kFrontendTextures[21].primary)] ||
            ![key(draw,1) isEqualToString:@(kFrontendTextures[21].auxiliary)]) return result;
        constexpr float uv[][2]={{0,0},{1,0},{1,1},{0,1}};
        for (size_t corner=0;corner<4;++corner) for (size_t stage=0;stage<2;++stage) for (size_t axis=0;axis<2;++axis)
            if (std::abs(draw.vertices[corner].uv[stage][axis]-uv[corner][axis])>1e-6f) return result;
    }
    for (size_t i=0;i<12;++i)
        if (!GalleryQuadBounds(draws[first+i],bounds[i][0],bounds[i][1],bounds[i][2],bounds[i][3])) return result;
    if (!tuple(0,@(kFrontendTextures[23].primary),nil)) return result;
    for (size_t i=1;i<5;++i) if (!tuple(i,@(kFrontendTextures[22].primary),@(kFrontendTextures[22].auxiliary))) return result;
    if (!tuple(5,@"32x128-74f1d8612646f3bd9c52055471f33d653f4c6bcb096b7e2383be7eaa36ccb709",
        @"32x128-df38508fc683288e8ab60fbfaf22e590a48b1ff8c86bf62fa223c45348e1728b")) return result;
    for (size_t i:{6u,7u}) if (!tuple(i,@"32x128-67ae129af7de5970b64949de1f1aebb62246da783475cfd56d355d63d70e0ada",
        @"32x128-1dd42aed72272b62113d5ad1ddeaa6926a1a5f2f2f9b78ae598ec0e30a702f83")) return result;
    for (size_t i=8;i<11;++i) {
        const bool fill=i==8;
        if (!tuple(i,fill?@"32x256-0ca2d693b7a7fc467b0015bdda48f9dcc1e1639ebd37c1ae974f63048a4a5237":
            @"32x256-030790dabdeb2edc8e35f0cbf93a4eed82b0d3e89451b647191f79bcfe1c085a",
            fill?@"32x256-dedfecf983b21d4ba1a31588469409fb86cdf920ae2512cb9731952d3dbae2a4":
            @"32x256-5eeb0118b7a6a714d30ce5b494873a9368d92c58e5a44993c3122e6feabe7858")) return result;
    }
    if (!tuple(11,@"512x128-6c9c43c0430fed764b3e702c9036b63a2c024e9aeb4dec4b6ef09cc6367bb7f7",
        @"512x128-34ad8056608d95cc91ff24db3193ce646a608df0e8dfe00b6817a9a6305e2364")) return result;
    size_t bodyStart=fontStart;
    while (bodyStart<draws.size() && [key(draws[bodyStart],0) isEqualToString:@(kFrontendTextures[19].primary)]) ++bodyStart;
    if (bodyStart-fontStart<4 || bodyStart-fontStart>6) return result;
    for (size_t i=bodyStart;i<draws.size();++i)
        if (![key(draws[i],0) isEqualToString:@(kFrontendTextures[20].primary)]) return result;
    result.actions.resize(draws.size());
    unsigned previous=0,next=0;
    for (size_t i=fontStart;i<bodyStart;++i) {
        const auto& draw=draws[i];
        if (GalleryQuadBounds(draw,.728125f,.753125f,.169642866f,.330357164f) &&
            ComboQuadUV(draw,0,0,.04296875f,.4375f,.5078125f)) {
            result.actions[i]={ProtectorActionGlyphNext};++next;
        } else if (GalleryQuadBounds(draw,-.7625f,-.7f,.169642866f,.330357164f) &&
            ComboQuadUV(draw,0,.8046875f,.90625f,.5078125f,.578125f)) {
            result.actions[i]={ProtectorActionGlyphPrevious};++previous;
        }
    }
    if (previous!=1 || next!=1) return UpgradeGlyphAdmission{};
    for (size_t i=bodyStart;i<draws.size();++i) {
        const auto& draw=draws[i];
        bool hasControl=false;
        for (const auto& vertex:draw.vertices) hasControl|=vertex.uv[0][1]>.93f;
        if (!hasControl) continue;
        if (!scheme || draw.vertices.empty() || draw.vertices.size()>12 || draw.vertices.size()%4) return UpgradeGlyphAdmission{};
        for (size_t quad=0;quad<draw.vertices.size()/4;++quad) {
            const unsigned action=ComboQuadAction(draw,quad,scheme);
            if (!action) return UpgradeGlyphAdmission{};
            result.actions[i].push_back(action);++result.glyphCount;
        }
    }
    result.enabled=true;result.first=panelStart;result.scheme=scheme;result.ready=ready;
    result.reason="source-upgrade-panel-and-exact-action-quads";
    return result;
}
