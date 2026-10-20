#pragma once

// English Panel-Combos records in original 99_93/94/95, matched to 99_99
// display-font UV runs. Hashes/quad counts only; no extracted text or pixels.
// See NATIVE_COMBAT_MOVE_LABELS.md and the external source-binding receipt.
struct CombatMoveRun { u64 signature; size_t quads; unsigned kind; };
static constexpr CombatMoveRun kCombatMoveRuns[] = {
    {0x047a2d09a0627c09ull,9,2},
    {0x086484f37bdf2f1dull,10,2},
    {0x091c80dbe77feb1dull,4,2},
    {0x0a65a9605d2e8169ull,10,2},
    {0x0a8adf4553e474b1ull,15,1},
    {0x0fb2b7ade9ebff71ull,14,2},
    {0x10187995952b5045ull,8,2},
    {0x102c16d29857ba69ull,9,2},
    {0x15bbd34e25421a2dull,10,1},
    {0x165f06726bbca151ull,11,2},
    {0x170ab3892ed4c291ull,9,2},
    {0x1c1a491bf2247c71ull,7,2},
    {0x24d61a87ea1c99e9ull,10,2},
    {0x27b007ea4fe95f81ull,8,2},
    {0x2c0c5dcb5488b6cdull,8,2},
    {0x2eea4f50438aef69ull,8,2},
    {0x31ce257480e0a831ull,8,2},
    {0x340f8ad81d438989ull,11,2},
    {0x34ae6a5a78228025ull,11,1},
    {0x395484a6f33f5a95ull,9,1},
    {0x3c5a865d7dfda9b1ull,9,2},
    {0x3d0d6836a24c32f5ull,9,2},
    {0x3d7c4bda38250455ull,5,2},
    {0x400509eb3f325eddull,10,2},
    {0x41d1b2ffff6a43adull,15,2},
    {0x43725081ea931339ull,15,2},
    {0x43a6822264330351ull,8,2},
    {0x44a2ad09c6549df1ull,9,2},
    {0x473374992ba42ac9ull,5,1},
    {0x479a5acb34b2f7b5ull,9,2},
    {0x489d39474a781c81ull,7,2},
    {0x4ce323ec59afd485ull,16,2},
    {0x4e4892d36bf780b1ull,7,2},
    {0x501c09fc3dac8bd9ull,10,2},
    {0x50a37c70783d6d69ull,9,2},
    {0x564e2a9d455435fdull,6,2},
    {0x568a689947e5e4adull,10,2},
    {0x5d17c086f8a44b0dull,10,1},
    {0x5d838c8625199a51ull,15,1},
    {0x60260c4a77a702a5ull,13,2},
    {0x60e01dcbeb7e89f9ull,9,2},
    {0x62446de3f39bac01ull,16,2},
    {0x658aabca4acd8375ull,11,2},
    {0x6602d7039c1823b5ull,5,2},
    {0x66825ae03b2e6e91ull,17,1},
    {0x67ab067c33f0fd6dull,10,1},
    {0x69013292842af931ull,12,2},
    {0x690d923f0f989b8dull,10,1},
    {0x6ce71e56e5c690edull,8,2},
    {0x6e81b60af47bbec9ull,10,2},
    {0x733df9a9bd34fa79ull,10,2},
    {0x741931aa47cdd6d5ull,10,2},
    {0x75795c453f1e4549ull,7,1},
    {0x7725f0ebb6640851ull,13,2},
    {0x7957f5dc784895a1ull,7,2},
    {0x7cb0da3c7eb4d38dull,12,1},
    {0x81cf88107c060ab5ull,8,2},
    {0x81e34fa7ee0257e9ull,10,2},
    {0x8313996b48432d11ull,15,1},
    {0x85ac3b14395be519ull,8,2},
    {0x879e2b07504f0009ull,10,2},
    {0x8b102183e01a5b7dull,14,1},
    {0x8cde0ab31e032d91ull,12,2},
    {0x8ea58a50e160294dull,10,2},
    {0x90da34ec1d9b5ecdull,10,2},
    {0x91f35d2e3ddbce41ull,9,2},
    {0x9257c847b0db2ae1ull,12,2},
    {0x93972b046cd08c15ull,9,1},
    {0x940f13c2b3b20b85ull,12,2},
    {0x9517ba346e50eb95ull,12,2},
    {0x95ba66a32aecd341ull,11,1},
    {0x97e4d1a3293030c5ull,7,2},
    {0x9f796bf03794ee05ull,12,2},
    {0xa1f588c94d548a65ull,8,2},
    {0xa206b8785cef579dull,8,2},
    {0xa330e84191dff301ull,10,2},
    {0xa421d0c29e38ee39ull,7,2},
    {0xa6485a5873d9513dull,11,2},
    {0xa6b87fd5f1c41b25ull,9,2},
    {0xa6f6bfd994a9ea81ull,9,2},
    {0xa8ade2c3d8cd5421ull,9,2},
    {0xabf17b40fb54e4a9ull,11,2},
    {0xacac0f34dd66a5e5ull,4,2},
    {0xad624941c969865dull,8,2},
    {0xaef68b96cab4f831ull,8,2},
    {0xafd97fbd1bc2d4adull,12,1},
    {0xafdd3ca4bc2c7b05ull,5,2},
    {0xb1cfc3d0d6db3341ull,11,2},
    {0xb9cbd4b496e3ee01ull,10,2},
    {0xbaacf89f07768c35ull,11,2},
    {0xbc6609a505932cd5ull,6,2},
    {0xbf4ba0332f7eaaadull,10,2},
    {0xc1a79b3248f8e6f5ull,8,2},
    {0xc27dad317bb7a621ull,11,2},
    {0xc86b0bc52a14c7c1ull,7,2},
    {0xcbc21e20837b5951ull,17,1},
    {0xcd88ecb8bb63b8a9ull,8,2},
    {0xced0235e5e4d1165ull,9,2},
    {0xd411f6c99d3ab369ull,8,2},
    {0xd4292400d55f05c5ull,10,2},
    {0xd5941184f384a30dull,10,2},
    {0xd5b21937bb734fa9ull,5,1},
    {0xd67ed30b0b3a9a89ull,9,2},
    {0xd717c00d3c36cf95ull,9,2},
    {0xdade8c7edcccf285ull,10,2},
    {0xdea950687d360fc1ull,9,2},
    {0xec35c9147e9e0d89ull,13,2},
    {0xf06d7bd5df77d279ull,12,2},
    {0xf2066e7e52647ff1ull,6,2},
    {0xf29cd1d8107afb55ull,12,2},
    {0xf50fc088698151a5ull,8,2},
    {0xf9cf759c3ef4eed9ull,7,2},
    {0xfa7e985949fcbaf1ull,9,2},
    {0xfaef072d3f18ab0dull,10,2},
    {0xfb8a61de625313b9ull,10,2},
};

struct CombatMoveAdmission {
    std::array<size_t,2> indices{};
    size_t count=0;
    const char* reason="source-move-label-absent";
    bool contains(size_t index) const {
        for(size_t i=0;i<count;++i)if(indices[i]==index)return true;
        return false;
    }
};

static unsigned CombatMoveKind(const LiveDraw& draw) {
    if(draw.comboScheme || !draw.indexed || draw.vertices.empty() ||
        draw.vertices.size()>256 || draw.vertices.size()%4 ||
        draw.viewportX || draw.viewportY || draw.viewportWidth!=640 ||
        !FrontendDrawStateMatches(draw,FrontendRole::AuxiliaryText) ||
        draw.textureWidths[0]!=256 || draw.textureHeights[0]!=512)return 0;
    u64 signature=14695981039346656037ull;
    for(const auto& v:draw.vertices) {
        for(size_t axis=0;axis<2;++axis) {
            if(!std::isfinite(v.uv[0][axis]))return 0;
            u32 bits;memcpy(&bits,&v.uv[0][axis],sizeof(bits));
            for(unsigned byte=0;byte<4;++byte) {
                signature^=(bits>>(byte*8))&255;signature*=1099511628211ull;
            }
        }
    }
    unsigned kind=0;
    for(const auto& run:kCombatMoveRuns)
        if(run.signature==signature && run.quads==draw.vertices.size()/4)kind=run.kind;
    if(!kind)return 0;
    // Source left-player action sequence above the bar; named move below.
    // Unknown animation envelopes/locales stay at source placement.
    const double top=kind==1?48:100,bottom=kind==1?76:142;
    for(size_t q=0;q<draw.vertices.size()/4;++q) {
        const auto* v=draw.vertices.data()+q*4;
        if(v[0].position[0]>=v[2].position[0] || v[0].position[1]>=v[1].position[1] ||
            v[0].position[0]!=v[1].position[0] || v[2].position[0]!=v[3].position[0] ||
            v[0].position[1]!=v[3].position[1] || v[1].position[1]!=v[2].position[1])return 0;
        for(size_t c=0;c<4;++c) {
            const double x=(v[c].position[0]+1)*320,y=(1-v[c].position[1])*224;
            if(std::abs(v[c].position[2]-.00625002384f)>1e-5f ||
                x< -32 || x>320 || y<top || y>bottom)return 0;
            for(size_t channel=0;channel<3;++channel)
                if(v[c].color[channel]!=1)return 0;
            if(!std::isfinite(v[c].color[3]) || v[c].color[3]<0 || v[c].color[3]>1)return 0;
        }
    }
    return [InterfaceTextureKey(TexturePixels(draw,0),256,512)
        isEqualToString:kCombatFeedbackFont]?kind:0;
}

static CombatMoveAdmission IdentifyCombatMoves(const std::vector<LiveDraw>& draws,
    const std::vector<LiveEfbCopy>& copies,const NativeHudAdmission& hud) {
    CombatMoveAdmission result;
    if(!hud.count || hud.draws.size()!=draws.size() || draws.size()>4096 || copies.empty())return result;
    const auto& display=copies.back();
    if(display.drawIndex!=draws.size() || display.command!=18435 || display.sourceX || display.sourceY ||
        display.width!=640 || display.height!=448 || display.yScale!=256)return result;
    size_t lastHud=0;
    for(size_t i=0;i<draws.size();++i)if(hud.draws[i])lastHud=i;
    std::array<bool,3> seen{};
    // This source family is submitted just after the player HUD cluster.
    for(size_t i=lastHud+1;i<std::min(draws.size(),lastHud+13);++i) {
        const unsigned kind=CombatMoveKind(draws[i]);
        if(!kind)continue;
        if(seen[kind] || result.count==2) {
            result.count=0;result.reason="ambiguous-source-move-label";return result;
        }
        seen[kind]=true;result.indices[result.count++]=i;
    }
    if(result.count)result.reason="source-bound-move-labels";
    return result;
}

