#pragma once

// Included after the private GX draw/texture helpers. These are fingerprints
// of original 99_91.gcs layers, not replacement art or guest-script identities.
enum class FrontendRole { Unknown, Background, Bubble, Character, Logo, Subtitle,
                          MenuArt, Text, AuxiliaryText, PanelStrip, PanelCorner,
                          PanelFill, Heatblast, XLR8, SliderTrack, SliderKnob };

struct FrontendTextureProfile {
    const char* primary;
    const char* auxiliary;
    FrontendRole role;
    u32 blend = 13501;
};

static constexpr FrontendTextureProfile kFrontendTextures[] = {
    {"512x512-8759f5ad989e9147f2220101bf06f4c997d846e9d69ac125294adb131f9d7478", "", FrontendRole::Background},
    {"64x64-5e9b201eade40157f6aee8c79fbf81ceae63190db17cb8d11590cb0d31bffe7c", "64x64-224e68608e64e25463ce51ce20e61a54a87af1a96a1211cb281447e9c3dea85c", FrontendRole::Bubble},
    {"64x64-a7f6c14b223d35982ba3737efb50f13d93d1d4f10569d488e3544678ef007ee2", "64x64-72a02c91e8dd06a9cb523dc5769f1b750b23b8e4eec109531fc6feb7d4c0e70d", FrontendRole::Bubble, 13373},
    {"512x512-02daa7d49b71cd26a21e3c3829a260fdb851c6f2ce6567d72693e992a4fb5950", "512x512-43b453e7d01cfeb800018d6c74a7c40eb101cb519e6928dd1824f88cd483d220", FrontendRole::Character},
    {"512x512-5233dba0350f87dc7364167d558a5eeb93d16bca868690ce9d41bd2a97eab66d", "512x512-1001115d12aa56bc4f9265f8f2de6526f86cbddfaf18961a9583b6f3a8a7d2db", FrontendRole::Logo},
    {"256x32-c6fab3932d6cc4d51ddfc3ab9e7dff57b31eab42ddad32eb9043e4365e7073f7", "256x32-1febd63305b17e20a660cbde223ac86b2d26e9598f91525359559108b1e3d80c", FrontendRole::Subtitle},
    {"256x256-67facfa68ed56484e708ff5e0269e1109698fe249843fdfbb4d8e8b86abb86b1", "256x256-0c9baf589204fcf22ccad1cc3b53bc1dfe3382fb73d8526c3990ccd68004b39d", FrontendRole::MenuArt},
    {"256x256-f21f4326936b92c4c4d05be7147bcbcf595af337a625287d48826545293868fa", "", FrontendRole::MenuArt},
    {"64x256-155ed100ab19c1d7cf9335047cf2007c8875686a4c59636661d1c9d89d97e598", "", FrontendRole::MenuArt},
    {"256x256-2539c9ae885586d50875d12fb40d935fb38e7337082917129396fe5db5a23b80", "256x256-77e2160ee6f6d8fe5106d0ea3bdcfdbc8ffca9acb3558747141b731ba1b69f3d", FrontendRole::MenuArt},
    {"256x256-e6e4f5ecda178ef37476c6acaf25a2620aeb1f8df5f0ba17a9304526b631749c", "", FrontendRole::MenuArt},
    {"64x256-bac7996d7ec96cefbf6a6cb8531cc1fd569a65b9298f2e4ee566636f2b640f60", "", FrontendRole::MenuArt},
    {"256x256-71dfabc62c3d586fb148ba1bffe1d0fe1ed348452838ab30cdbd97d1f05da170", "256x256-4bc1def1187c25c083b0a00db0a0c777a541432bcdd8d516cdabbe06206f8eb6", FrontendRole::MenuArt},
    {"256x256-17b9a0999732323b0b506999836ac2816cdb05502c39d87151f202b4effa4551", "256x256-1a60fc92f0b4a86dfafe5b4c4402989099bca827ef9710bcc0b986366949bbe4", FrontendRole::MenuArt},
    {"256x256-8ea98c9dafee99525be8216df3501e464ae05dd08cd65f10a409ea5a3cd1bfe4", "256x256-16f0cfd703d694e02f7547af664ba269834ae4260d9a89079d01c4e81c3d4ca1", FrontendRole::MenuArt},
    {"256x256-98cdce5c39667a2f8ad66a35dbcb68743750861ae00cc42156737b705da75253", "256x256-d96824a6c17c33906bdb5baf3cae9f631120d5d87692f5a91aab91ecba7d1f48", FrontendRole::MenuArt},
    {"256x256-fa0fde7daf21ce60bb3fc09c1d18add2aa457828ad365bddff837745740f1f0a", "256x256-e72aeb87af8e67a3450d8eff9f3f473e81710b1a3e64b37c91aa82cbb61a1ecc", FrontendRole::MenuArt},
    {"256x256-18fc730bf251d29ca9b3ae6de5b3d45d8a578eb16e1f8b10869004f08e948a2f", "256x256-738283d522be778f98c1c656a41ec3a5fd795bc67844606232a0f518525cd230", FrontendRole::MenuArt},
    {"256x256-60b914805569d9c698db976b0c9be05e10eae65d55e1f441926732204b97ed1f", "256x256-530ce6ed50b3bd71bd7e22a63c90a5d4956400c7c6ebb0fb982ccda421a00299", FrontendRole::MenuArt},
    {"256x512-011e4572640c9b41459963c6c9884dc724e0bf94a9836ad76651755ab1edc05d", "", FrontendRole::Text},
    {"256x512-7f1c5d69d0069b594140d68077b3327041f518ef8af8975c07de443b1e421faa", "", FrontendRole::AuxiliaryText},
    {"32x32-cc8cc0ccb9814c04aff209dbe98bd02096afcb0a3d1b72e1e04515079b40d2a6", "32x32-26c39c006ca2b04b5904d804b7ade42fc01fa5032f54ea39a826297e77c9e6b7", FrontendRole::PanelStrip},
    {"64x64-3a3d14924439da7f58977f082d6eb1685c359ae31606be37cb874ede951a587d", "64x64-b09019a7d8f45578ad5f7961bacdd7ee7608898b859b7eedd363f4c1081cc103", FrontendRole::PanelCorner},
    {"8x8-2c893cd47b6757133987906e00c55e6dcce3c567b9df9e7f91ffecd3604cc6a6", "", FrontendRole::PanelFill},
    {"256x512-1ecbeb374361a510f9a906289f8a8df73a9babda86170e25973acf578d8f6a07", "256x512-f35e234afe523c67122944e7623d91a9a045d8ec3341ba21e93699065d62f3ce", FrontendRole::Heatblast},
    {"512x256-409a74453a99de4efb286fd6a5e696efb12b70347c250b7f09b61e557938404a", "512x256-9fc5c8e3ba50202a5d95e32f08c1008b6b21bfae7a5254d5b266a1c607498d64", FrontendRole::XLR8},
    {"256x32-d652d8ad3952e93bf636611074995f45dd320d99910f2429fb023a19d44c4845", "256x32-d93a02bde23340deb45975889cd17926f7fc2fef9fdd78a560f26643286e8a0b", FrontendRole::SliderTrack},
    {"32x64-c3db2a43ffab0b6e62dc0e9bd356ccaa97d78a679e944205b7b2bf4a00c7a832", "32x64-f85cb78c431ca001a0c720e20c492d4d859c7c287365ea1afa6a79d693e35b14", FrontendRole::SliderKnob},
};
static constexpr size_t kFrontendTextureCount = sizeof(kFrontendTextures)/sizeof(kFrontendTextures[0]);

static int FrontendProfileForKeys(NSString* primary, NSString* auxiliary) {
    for (size_t i = 0; i < kFrontendTextureCount; ++i) {
        const auto& profile = kFrontendTextures[i];
        if ([primary isEqualToString:@(profile.primary)] &&
            ((!profile.auxiliary[0] && !auxiliary) || [auxiliary isEqualToString:@(profile.auxiliary)]))
            return (int)i;
    }
    return -1;
}

static bool FrontendDrawStateMatches(const LiveDraw& draw, FrontendRole role, u32 blend = 13501) {
    constexpr std::array<u32,7> projection{994888909,2147483648,3146926373,0,3131299594,3212627148,1};
    const bool font = role == FrontendRole::Text || role == FrontendRole::AuxiliaryText;
    if (role == FrontendRole::Unknown || ClassifyWideDraw(draw) != WideDrawRole::SafeArea ||
        std::abs(draw.viewportHeight - 448) > 0.01 || draw.projectionWords != projection ||
        draw.depthMode != 15 || draw.fragment.alphaTest != 4128768 || draw.fragment.indirectCount ||
        draw.blendMode != blend ||
        draw.fragment.stageCount < 1 || draw.fragment.stageCount > (font ? 1u : 2u)) return false;
    const size_t corners = draw.indexed ? 4 : 6;
    if (draw.vertices.empty() || draw.vertices.size() % corners ||
        draw.vertices.size() > (font ? 1024u : corners)) return false;
    if (draw.indexed) {
        if (draw.indices.size() != draw.vertices.size() / 4 * 6) return false;
        constexpr u32 indices[] = {0,1,2,0,2,3};
        for (size_t i = 0; i < draw.indices.size(); ++i)
            if (draw.indices[i] != i / 6 * 4 + indices[i % 6]) return false;
    }
    for (const auto& vertex : draw.vertices) {
        for (float p : vertex.position) if (!std::isfinite(p) || std::abs(p) > 32) return false;
        if (std::abs(vertex.position[3] - 1) > 0.00001) return false;
        for (float color : vertex.color) if (!std::isfinite(color) || color < 0 || color > 1) return false;
        for (size_t stage = 0; stage < draw.fragment.stageCount; ++stage)
            for (float uv : vertex.uv[stage]) if (!std::isfinite(uv) || uv < -0.00001 || uv > 1.00001) return false;
    }
    for (size_t stage = 0; stage < draw.fragment.stageCount; ++stage) {
        if (draw.textureFormats[stage] != (font ? 9u : 14u) || draw.textureCoordinates[stage] ||
            draw.textureUnits[stage] != stage || draw.textureModes[stage] != (font ? 2162389u : 2097360u) ||
            draw.fragment.colorCombiners[stage] != (font ? 63535u : stage ? 589808u : 64143u) ||
            draw.fragment.alphaCombiners[stage] != (font ? 61680u : stage ? 63100u :
                draw.fragment.stageCount == 2 ? 65520u : 63088u)) return false;
    }
    if (role == FrontendRole::Background) {
        constexpr size_t expanded[] = {0,1,2,0,2,3};
        constexpr float uv[][2] = {{0,0},{1,0},{1,1},{0,1}};
        for (size_t i = 0; i < draw.vertices.size(); ++i) {
            const auto& v = draw.vertices[i];
            const size_t corner = draw.indexed ? i : expanded[i];
            if (std::abs(v.position[0] - (uv[corner][0] * 2 - 1)) > 0.00001 ||
                std::abs(v.position[1] - (corner < 2 ? 1.0669643879f : -1.0625f)) > 0.00001 ||
                std::abs(v.uv[0][0] - uv[corner][0]) > 0.00001 ||
                std::abs(v.uv[0][1] - uv[corner][1]) > 0.00001) return false;
        }
    }
    return true;
}

struct FrontendAdmission {
    std::vector<FrontendRole> roles;
    std::vector<int> observedProfiles;
    bool enabled = false;
    bool menu = false;
    bool secondary = false;
    size_t panelFill = SIZE_MAX;
    float panelCenter = 0;
    const char* reason = "not-source-frontend";
};

static FrontendAdmission AdmitFrontendProfiles(const std::vector<int>& profiles) {
    FrontendAdmission result;
    if (profiles.size() < 97 || profiles.size() > 192 || profiles[0] != 0) return result;
    unsigned background = 0, character = 0, logo = 0, subtitle = 0, menuMask = 0, secondaryCount = 0;
    for (size_t i = 0; i < profiles.size(); ++i) {
        const int profile = profiles[i];
        if (profile < 0 || (size_t)profile >= kFrontendTextureCount) return result;
        // The observed shared frontend begins with one DNA field and 48 pairs.
        if (i > 0 && i <= 96 && profile != (i % 2 ? 1 : 2)) return result;
        const auto role = kFrontendTextures[profile].role;
        if (i > 96 && (role == FrontendRole::Bubble || role == FrontendRole::Background)) return result;
        background += role == FrontendRole::Background;
        character += role == FrontendRole::Character;
        logo += role == FrontendRole::Logo;
        subtitle += role == FrontendRole::Subtitle;
        secondaryCount += role >= FrontendRole::PanelStrip;
        if (role == FrontendRole::MenuArt) menuMask |= 1u << (profile - 6);
        result.roles.push_back(role);
    }
    // The first title frame contains only the complete DNA field and its
    // 48 bubble pairs. Its foreground arrives later; retain the same cover
    // transform during that source-authored opening animation.
    if (profiles.size()==97) {
        result.enabled=true;
        result.reason="source-dna-background-transition";
        return result;
    }
    if (background != 1 || !logo || logo > 2 || !subtitle || subtitle > 2 || character > 1 ||
        (menuMask && menuMask != 0x1fffu) || (!menuMask && character != 1)) return result;
    if (secondaryCount) {
        // Complete observed source composition, not admission from a lone
        // character or panel key. The nineteen watch layers remain alive
        // behind secondary menus and retain their exact authored order.
        constexpr int watchPrefix[] = {6,7,8,9,10,11,12,13,14,15,16,17,17,17,17,
            18,18,18,18,4,5};
        if (profiles.size() < 120 || character || logo != 1 || subtitle != 1) return result;
        for (size_t i=0; i<sizeof(watchPrefix)/sizeof(watchPrefix[0]); ++i)
            if (profiles[97+i] != watchPrefix[i]) return result;
        size_t cursor = 118;
        // Source transitions hide the complete nine-piece panel and its
        // heading independently. Their absence is not a different coordinate
        // system. Partial/reordered panels and unknown layers still fail closed.
        if (profiles[cursor] == 21) {
            constexpr int panel[] = {21,21,21,21,23,22,22,22,22};
            if (profiles.size() < cursor+11) return result;
            for (size_t i=0; i<9; ++i) if (profiles[cursor+i] != panel[i]) return result;
            result.panelFill=cursor+4;
            cursor += 9;
        }
        if (profiles[cursor] != 24 && profiles[cursor] != 25) return result;
        const bool heatblast = profiles[cursor++] == 24;
        if (profiles[cursor] == 26) {
            if (heatblast || profiles.size() < cursor+10) return result;
            for (size_t i=0; i<8; ++i) if (profiles[cursor+i] != (i<4 ? 26 : 27)) return result;
            cursor += 8;
        }
        if (cursor >= profiles.size()) return result;
        for (; cursor<profiles.size(); ++cursor)
            if (profiles[cursor] != 19 && profiles[cursor] != 20) return result;
        result.secondary = true;
    }
    result.enabled = true;
    result.menu = menuMask != 0;
    result.reason = result.secondary ? "source-dna-secondary-panel" :
        result.menu ? "source-dna-watch-menu" : "source-dna-title";
    return result;
}

static FrontendAdmission IdentifyFrontend(const std::vector<LiveDraw>& draws,
    const std::vector<LiveEfbCopy>& copies) {
    if (draws.size() < 97 || draws.size() > 192 || copies.size() != 1 ||
        copies[0].drawIndex != draws.size() || copies[0].command != 18435 ||
        copies[0].sourceX || copies[0].sourceY || copies[0].width != 640 ||
        copies[0].height != 448 || copies[0].yScale != 256) return {};
    // Shape preflight prevents hashing ordinary gameplay. Per-frame pointer
    // memoization hashes shared immutable decoded pixels once, never across frames.
    if (!FrontendDrawStateMatches(draws[0], FrontendRole::Background)) return {};
    std::map<std::tuple<const u8*,size_t,u32,u32>,NSString*> keys;
    auto key = [&](const LiveDraw& draw, size_t stage) -> NSString* {
        const auto& pixels = TexturePixels(draw,stage);
        const auto identity = std::make_tuple(pixels.data(),pixels.size(),draw.textureWidths[stage],draw.textureHeights[stage]);
        auto found = keys.find(identity);
        if (found != keys.end()) return found->second;
        NSString* value = InterfaceTextureKey(pixels,draw.textureWidths[stage],draw.textureHeights[stage]);
        keys.emplace(identity,value);
        return value;
    };
    if (FrontendProfileForKeys(key(draws[0],0),draws[0].fragment.stageCount == 2 ? key(draws[0],1) : nil) != 0) return {};
    std::vector<int> profiles;
    for (const auto& draw : draws) {
        if (draw.fragment.stageCount < 1 || draw.fragment.stageCount > 2) return {};
        int profile = FrontendProfileForKeys(key(draw,0),draw.fragment.stageCount == 2 ? key(draw,1) : nil);
        if (profile < 0 || !FrontendDrawStateMatches(draw,kFrontendTextures[profile].role,
            kFrontendTextures[profile].blend)) {
            FrontendAdmission rejected;
            rejected.observedProfiles = profiles;
            rejected.observedProfiles.push_back(profile < 0 ? -1 : -2-profile);
            rejected.reason = "source-dna-draw-state-rejected";
            return rejected;
        }
        profiles.push_back(profile);
    }
    auto result = AdmitFrontendProfiles(profiles);
    result.observedProfiles = profiles;
    if (result.secondary && result.panelFill != SIZE_MAX) {
        // The admitted constant-fill quad gives the moving panel's centre.
        const auto& vertices = draws[result.panelFill].vertices;
        float left = vertices[0].position[0], right = left;
        for (const auto& vertex : vertices) {
            left = std::min(left,vertex.position[0]); right = std::max(right,vertex.position[0]);
        }
        result.panelCenter = (left+right)/2;
    }
    return result;
}

static void TransformFrontendVertex(LiveVertex* vertex, FrontendRole role,
    double aspect, float bubbleCenter, bool menu) {
    if (!std::isfinite(aspect) || aspect < 4.0/3.0 || aspect > 3.0) return;
    const float ratio = (float)((4.0/3.0)/aspect);
    if (ratio == 1) return;
    if (role == FrontendRole::Background) {
        // Uniform physical enlargement covers the wide frame; only the
        // decorative DNA's top/bottom crop. UVs and source pixels stay intact.
        vertex->position[1] /= ratio;
        return;
    }
    vertex->position[0] *= ratio;
    const float added = 1 - ratio;
    if (role == FrontendRole::Bubble) vertex->position[0] += bubbleCenter * added;
    if (role == FrontendRole::Logo || role == FrontendRole::Subtitle) {
        vertex->position[0] -= 0.55f * added;
        // Keep the registered mark above the phone's unchanged menu-up target.
        if (menu) vertex->position[1] += 0.26f * added;
    }
    if (role == FrontendRole::Character) vertex->position[0] += 0.8f * added;
    // Anchor the source watch's right edge outside the viewport. Its bezel
    // ends at source x=1.06875; a weaker offset exposes that hard tile boundary.
    if (role == FrontendRole::MenuArt || (role == FrontendRole::Text && menu)) vertex->position[0] += added;
}

static void TransformSecondaryFrontendVertex(LiveVertex* vertex, FrontendRole role,
    double aspect, float drawLeft, float drawRight, float panelCenter) {
    if (!std::isfinite(aspect) || aspect < 4.0/3.0 || aspect > 3.0) return;
    const float ratio = (float)((4.0/3.0)/aspect);
    if (ratio == 1) return;
    const float center = (drawLeft+drawRight)/2;
    if (role == FrontendRole::Background || role == FrontendRole::Bubble ||
        role == FrontendRole::MenuArt || role == FrontendRole::Logo || role == FrontendRole::Subtitle) {
        TransformFrontendVertex(vertex,role,aspect,center,true);
        return;
    }
    const float added = 1-ratio;
    const float sourceX = vertex->position[0];
    vertex->position[0] *= ratio;
    // Both source illustrations have a hard canvas cut on their outer edge.
    // Anchor that edge beyond the screen, not merely near it.
    if (role == FrontendRole::Heatblast) { vertex->position[0] += added; return; }
    if (role == FrontendRole::XLR8) { vertex->position[0] -= added; return; }
    // The source panels are offset for a cropped 4:3 character composition.
    // Bring their centre to the wide content field by 16:9. Copy and sliders
    // receive the same translation, never the watch menu's right-hand offset.
    vertex->position[0] -= panelCenter*ratio*std::min(1.0f,added/0.25f);
    const float span = 0.28f*added;
    if (role == FrontendRole::PanelCorner ||
        (role == FrontendRole::PanelStrip && drawRight-drawLeft < 0.2f)) {
        vertex->position[0] += center < panelCenter ? -span : span;
    } else if (role == FrontendRole::PanelStrip || role == FrontendRole::PanelFill) {
        // Nine-slice-like expansion: only the flat horizontal spans stretch;
        // corner art, vertical strokes, characters, lettering and sliders do not.
        if (drawRight > drawLeft) vertex->position[0] +=
            span*(2*(sourceX-drawLeft)/(drawRight-drawLeft)-1);
    }
}
