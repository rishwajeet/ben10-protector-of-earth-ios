#pragma once
#include "protector/touch_layout.h"

// Exact 99_99.gcs display-font cells (resource 0xbe860, metrics 0x679e0).
// Used by the bounded source observer before admitting a placement transform.
// This table contains coordinates and identities, never proprietary pixels.
struct CombatFeedbackGlyph { char character; float left, right, bottom, top; };
static constexpr CombatFeedbackGlyph kCombatFeedbackGlyphs[] = {
    {'C',.4296875f,.484375f,.4375f,.5078125f},
    {'O',.4375f,.51171875f,.3671875f,.4375f},
    {'M',.2265625f,.33203125f,.3671875f,.4375f},
    {'B',.33984375f,.4140625f,.4375f,.5078125f},
    {'0',.7578125f,.828125f,.578125f,.6484375f},
    {'1',.84375f,.9140625f,.578125f,.6484375f},
    {'2',0,.0703125f,.5078125f,.578125f},
    {'3',.0859375f,.15625f,.5078125f,.578125f},
    {'4',.171875f,.2421875f,.5078125f,.578125f},
    {'5',.2578125f,.328125f,.5078125f,.578125f},
    {'6',.34375f,.4140625f,.5078125f,.578125f},
    {'7',.4296875f,.5f,.5078125f,.578125f},
    {'8',.515625f,.5859375f,.5078125f,.578125f},
    {'9',.6015625f,.671875f,.5078125f,.578125f},
    {',',.484375f,.53125f,.578125f,.6484375f},
};
static NSString* const kCombatFeedbackFont =
    @"256x512-011e4572640c9b41459963c6c9884dc724e0bf94a9836ad76651755ab1edc05d";

static char CombatFeedbackQuadGlyph(const LiveDraw& draw, size_t quad) {
    if (!draw.indexed || quad*4+4>draw.vertices.size()) return 0;
    for (const auto& cell:kCombatFeedbackGlyphs) {
        const float expected[][2]={{cell.left,cell.bottom},{cell.left,cell.top},
            {cell.right,cell.top},{cell.right,cell.bottom}};
        bool matches=true;
        for (size_t corner=0;corner<4;++corner) {
            const auto& vertex=draw.vertices[quad*4+corner];
            for (size_t axis=0;axis<2;++axis)
                if (!std::isfinite(vertex.uv[0][axis]) ||
                    std::abs(vertex.uv[0][axis]-expected[corner][axis])>1e-6f) matches=false;
        }
        if (matches) return cell.character;
    }
    return 0;
}

static bool CombatFeedbackAuditContainsLabel(const std::vector<LiveDraw>& draws) {
    // Diagnostic-only trigger; it does not authorize moving the draw. Limit
    // both traversal and font hashing before inspecting the exact glyph run.
    size_t orthographic=0;
    for (const auto& draw:draws) {
        if (!draw.projectionWords[6]) continue;
        if (++orthographic>256) break;
        if (!draw.indexed || draw.vertices.size()<20 || draw.vertices.size()>512 ||
            draw.vertices.size()%4 || draw.fragment.stageCount!=1 ||
            draw.textureFormats[0]!=9 || draw.textureWidths[0]!=256 || draw.textureHeights[0]!=512) continue;
        for (size_t quad=0;quad+5<=draw.vertices.size()/4;++quad) {
            bool matches=true;
            for (size_t i=0;i<5;++i)
                if (CombatFeedbackQuadGlyph(draw,quad+i)!="COMBO"[i]) matches=false;
            if (matches && [InterfaceTextureKey(TexturePixels(draw,0),256,512)
                    isEqualToString:kCombatFeedbackFont]) return true;
        }
    }
    return false;
}

struct CombatFeedbackAdmission {
    bool enabled=false;
    size_t label=0, number=0;
    u32 count=0;
    const char* reason="source-counter-absent";
    bool contains(size_t index) const { return enabled && (index==label || index==number); }
};

static std::string CombatFeedbackRun(const LiveDraw& draw) {
    if (!draw.indexed || draw.vertices.size()>52 || draw.viewportX || draw.viewportY ||
        draw.viewportWidth!=640 || !FrontendDrawStateMatches(draw,FrontendRole::AuxiliaryText) ||
        draw.textureWidths[0]!=256 || draw.textureHeights[0]!=512) return {};
    std::string result;
    for(size_t q=0;q<draw.vertices.size()/4;++q) {
        const char glyph=CombatFeedbackQuadGlyph(draw,q);
        if(!glyph)return {};
        const auto* v=draw.vertices.data()+q*4;
        if(v[0].position[0]>=v[2].position[0] || v[0].position[1]>=v[1].position[1] ||
            v[0].position[0]!=v[1].position[0] || v[2].position[0]!=v[3].position[0] ||
            v[0].position[1]!=v[3].position[1] || v[1].position[1]!=v[2].position[1]) return {};
        for(size_t c=0;c<4;++c) {
            const double x=(v[c].position[0]+1)*320, y=(1-v[c].position[1])*224;
            if(std::abs(v[c].position[2]-.00625002384f)>1e-5f ||
                x<PROTECTOR_COMBAT_FEEDBACK_LEFT-.001 ||
                x>PROTECTOR_COMBAT_FEEDBACK_LEFT+PROTECTOR_COMBAT_FEEDBACK_WIDTH+.001 ||
                y<PROTECTOR_COMBAT_FEEDBACK_TOP-.001 ||
                y>PROTECTOR_COMBAT_FEEDBACK_TOP+PROTECTOR_COMBAT_FEEDBACK_HEIGHT+.001) return {};
        }
        result+=glyph;
    }
    return result;
}

static u32 CombatFeedbackCount(const std::string& text) {
    // Original DisplayTextI formats positive signed integers in groups of
    // three (DOL 0x80044510; ',' / '%03i' / '%i' at 0x801e6042/44/49).
    u64 value=0;std::string digits;
    for(char c:text) {
        if(c==',')continue;
        if(c<'0' || c>'9')return 0;
        digits+=c;value=value*10+(c-'0');
        if(value>INT32_MAX)return 0;
    }
    if(!value || digits.empty() || digits[0]=='0')return 0;
    std::string formatted;
    for(size_t i=0;i<digits.size();++i) {
        if(i && (digits.size()-i)%3==0)formatted+=',';
        formatted+=digits[i];
    }
    return formatted==text ? (u32)value : 0;
}

static CombatFeedbackAdmission IdentifyCombatFeedback(const std::vector<LiveDraw>& draws,
    const std::vector<LiveEfbCopy>& copies, const NativeHudAdmission* existingHud=nullptr) {
    CombatFeedbackAdmission result;
    if(draws.size()<2 || draws.size()>4096 || copies.empty())return result;
    // Rendering has already identified this frame's upper HUD. Reuse that
    // result without repeating every source-texture hash when no counter is
    // present. Standalone diagnostics and tests still identify their own HUD.
    if(!(existingHud ? existingHud->count : IdentifyNativeHud(draws).count))return result;
    const auto& display=copies.back();
    if(display.drawIndex!=draws.size() || display.command!=18435 || display.sourceX || display.sourceY ||
        display.width!=640 || display.height!=448 || display.yScale!=256) return result;
    for(size_t i=1;i<draws.size();++i) {
        if(draws[i].comboScheme || CombatFeedbackRun(draws[i])!="COMBO")continue;
        const u32 count=CombatFeedbackCount(CombatFeedbackRun(draws[i-1]));
        if(!count)continue;
        const auto& label=draws[i];const auto& number=draws[i-1];
        auto bounds=[](const LiveDraw& draw) {
            double left=1e6,right=-1e6,top=1e6,bottom=-1e6;
            for(const auto& v:draw.vertices) {
                const double x=(v.position[0]+1)*320,y=(1-v.position[1])*224;
                left=std::min(left,x);right=std::max(right,x);top=std::min(top,y);bottom=std::max(bottom,y);
            }
            return CGRectMake(left,top,right-left,bottom-top);
        };
        const CGRect l=bounds(label),n=bounds(number);
        // Source left-player anchor, adjacent number-before-label order, and
        // the same baseline relationship. The right-player branch stays out.
        const double vertical=CGRectGetMidY(n)-CGRectGetMidY(l);
        if(CGRectGetMidX(l)<20 || CGRectGetMidX(l)>84 ||
            std::abs(CGRectGetMidX(n)-CGRectGetMidX(l))>12 || vertical<8 || vertical>60 ||
            CGRectGetHeight(l)>48 || CGRectGetHeight(n)>48 ||
            ![InterfaceTextureKey(TexturePixels(label,0),256,512) isEqualToString:kCombatFeedbackFont] ||
            ![InterfaceTextureKey(TexturePixels(number,0),256,512) isEqualToString:kCombatFeedbackFont])continue;
        if(result.enabled) { result.enabled=false;result.reason="ambiguous-source-counter";return result; }
        result.enabled=true;result.label=i;result.number=i-1;result.count=count;result.reason="source-combo-label-and-count";
    }
    return result;
}

static void TransformCombatFeedbackVertex(LiveVertex* vertex,CGSize size,CGRect destination) {
    const double x=(vertex->position[0]+1)*320,y=(1-vertex->position[1])*224;
    const double px=destination.origin.x+(x-PROTECTOR_COMBAT_FEEDBACK_LEFT)*destination.size.width/PROTECTOR_COMBAT_FEEDBACK_WIDTH;
    const double py=destination.origin.y+(y-PROTECTOR_COMBAT_FEEDBACK_TOP)*destination.size.height/PROTECTOR_COMBAT_FEEDBACK_HEIGHT;
    vertex->position[0]=(float)(2*px/size.width-1);
    vertex->position[1]=(float)(1-2*py/size.height);
}
