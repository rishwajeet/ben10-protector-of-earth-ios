#pragma once
#include "../apple/action_glyphs.h"

// This bridge sees only a frame admitted by the complete Ben10MoveList script.
// It additionally matches the source panel, font bytes, render state and quads.
// Guest textures/vertices are immutable; replacements affect the host upload.
struct ComboGlyphAdmission {
    bool enabled = false;
    size_t first = 0;
    u32 scheme = 0;
    size_t glyphCount = 0;
    std::vector<std::vector<unsigned>> actions;
    const char* reason = "not-source-combo-list";
    bool contains(size_t index) const { return enabled && index >= first; }
};

static bool ComboQuadUV(const LiveDraw& draw, size_t quad, float left, float right,
    float bottom, float top) {
    if (!draw.indexed || quad*4+4 > draw.vertices.size()) return false;
    const float expected[][2] = {{left,bottom},{left,top},{right,top},{right,bottom}};
    const auto* vertices = draw.vertices.data()+quad*4;
    for (size_t i=0;i<4;++i) {
        if (std::abs(vertices[i].uv[0][0]-expected[i][0]) > 1e-6f ||
            std::abs(vertices[i].uv[0][1]-expected[i][1]) > 1e-6f ||
            std::abs(vertices[i].position[2]-.00625002384f) > 1e-5f) return false;
    }
    return vertices[0].position[0] < vertices[2].position[0] &&
        vertices[0].position[1] < vertices[1].position[1] &&
        vertices[0].position[0] == vertices[1].position[0] &&
        vertices[2].position[0] == vertices[3].position[0] &&
        vertices[0].position[1] == vertices[3].position[1] &&
        vertices[1].position[1] == vertices[2].position[1];
}

static unsigned ComboQuadAction(const LiveDraw& draw, size_t quad, u32 scheme) {
    // Exact source-coordinate glyph cells observed in the body-font draw audit.
    // Unknown cells are rejected, never inferred from their rendered appearance.
    // Body font table 99_99.gcs at 0x68920, 28-byte indexed metrics. The
    // renderer inverts table V. Glyph 9 is a double-width source cell.
    constexpr unsigned glyphs[] = {1,2,4,6,9};
    constexpr float cells[][4] = {{0,.125f,.9375f,1},{.140625f,.265625f,.9375f,1},
        {.421875f,.546875f,.9375f,1},{.703125f,.828125f,.9375f,1},
        {.140625f,.390625f,.875f,.9375f}};
    for (size_t i=0;i<5;++i)
        if (ComboQuadUV(draw,quad,cells[i][0],cells[i][1],cells[i][2],cells[i][3]))
            return protector_combo_action_for_glyph(scheme,(u8)glyphs[i]);
    return 0;
}

static ComboGlyphAdmission IdentifyComboGlyphs(const std::vector<LiveDraw>& draws,
    const std::vector<LiveEfbCopy>& copies) {
    ComboGlyphAdmission result;
    if (draws.empty() || draws.size()>4096 || draws.front().comboScheme<1 ||
        draws.front().comboScheme>3 || copies.empty()) return result;
    const auto& display=copies.back();
    if (display.drawIndex!=draws.size() || display.command!=18435 || display.sourceX ||
        display.sourceY || display.width!=640 || display.height!=448 || display.yScale!=256) return result;
    const u32 scheme=draws.front().comboScheme;
    for (const auto& draw:draws) if (draw.comboScheme!=scheme) return result;
    constexpr float bounds[][4] = {
        {-.9375f,.9375f,-.830357194f,.834821463f},
        {-1,-.8f,-.910714328f,-.642857194f},{.8f,1,-.910714328f,-.642857194f},
        {-1,-.8f,.647321463f,.915178597f},{.8f,1,.647321463f,.915178597f},
        {-.625f,.625f,.352678597f,.883928597f},
        {-.725f,-.625f,.352678597f,.883928597f},{.625f,.725f,.352678597f,.883928597f},
        {.109375f,.828125f,-.883928597f,.486607164f},
        {.009375f,.109375f,-.883928597f,.486607164f},{.828125f,.928125f,-.883928597f,.486607164f},
        {-.828125f,-.109375f,-.883928597f,.486607164f},
        {-.928125f,-.828125f,-.883928597f,.486607164f},{-.109375f,-.009375f,-.883928597f,.486607164f},
        {-.8f,.8f,.361607164f,.892857194f},
    };
    size_t first=draws.size();
    for (size_t i=0;i+35<draws.size();++i) {
        if (!GalleryQuadBounds(draws[i],bounds[0][0],bounds[0][1],bounds[0][2],bounds[0][3])) continue;
        if (first!=draws.size()) return result;
        first=i;
    }
    if (first==draws.size() || first<4 || draws.size()-first>90) return result;
    // Four source border strips precede the fill. Keep them in the same
    // admitted component so tablet containment cannot detach its frame.
    const size_t panelStart=first-4;
    constexpr float strips[][4] = {
        {-.890625f,.890625f,.803571463f,.937500060f},
        {.925f,.996875f,-.848214328f,.848214328f},
        {-.890625f,.890625f,-.933035731f,-.799107194f},
        {-1,-.928125f,-.848214328f,.848214328f},
    };
    size_t fontStart=first+15;
    while (fontStart<draws.size() && draws[fontStart].textureFormats[0]!=9) ++fontStart;
    if (fontStart<first+20 || fontStart>first+27 || draws.size()-fontStart<20) return result;
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
    for(size_t i=0;i<4;++i) {
        const auto& strip=draws[panelStart+i];
        if(!GalleryQuadBounds(strip,strips[i][0],strips[i][1],strips[i][2],strips[i][3]) ||
            strip.fragment.stageCount!=2 ||
            ![key(strip,0) isEqualToString:@(kFrontendTextures[21].primary)] ||
            ![key(strip,1) isEqualToString:@(kFrontendTextures[21].auxiliary)])return result;
        constexpr float uv[][2]={{0,0},{1,0},{1,1},{0,1}};
        for(size_t corner=0;corner<4;++corner)for(size_t stage=0;stage<2;++stage)
            for(size_t axis=0;axis<2;++axis)
                if(std::abs(strip.vertices[corner].uv[stage][axis]-uv[corner][axis])>1e-6f)return result;
    }
    for (size_t i=0;i<15;++i) if (!GalleryQuadBounds(draws[first+i],bounds[i][0],bounds[i][1],bounds[i][2],bounds[i][3])) return result;
    if(!tuple(0,@(kFrontendTextures[23].primary),nil))return result;
    for(size_t i=1;i<5;++i)if(!tuple(i,@(kFrontendTextures[22].primary),@(kFrontendTextures[22].auxiliary)))return result;
    if(!tuple(5,@"32x128-74f1d8612646f3bd9c52055471f33d653f4c6bcb096b7e2383be7eaa36ccb709",
        @"32x128-df38508fc683288e8ab60fbfaf22e590a48b1ff8c86bf62fa223c45348e1728b"))return result;
    for(size_t i:{6u,7u})if(!tuple(i,@"32x128-67ae129af7de5970b64949de1f1aebb62246da783475cfd56d355d63d70e0ada",
        @"32x128-1dd42aed72272b62113d5ad1ddeaa6926a1a5f2f2f9b78ae598ec0e30a702f83"))return result;
    for(size_t i=8;i<14;++i) {
        const bool fill=i==8 || i==11;
        if(!tuple(i,fill?@"32x256-0ca2d693b7a7fc467b0015bdda48f9dcc1e1639ebd37c1ae974f63048a4a5237":
            @"32x256-030790dabdeb2edc8e35f0cbf93a4eed82b0d3e89451b647191f79bcfe1c085a",
            fill?@"32x256-dedfecf983b21d4ba1a31588469409fb86cdf920ae2512cb9731952d3dbae2a4":
            @"32x256-5eeb0118b7a6a714d30ce5b494873a9368d92c58e5a44993c3122e6feabe7858"))return result;
    }
    if(!tuple(14,@"512x128-6c9c43c0430fed764b3e702c9036b63a2c024e9aeb4dec4b6ef09cc6367bb7f7",
        @"512x128-34ad8056608d95cc91ff24db3193ce646a608df0e8dfe00b6817a9a6305e2364"))return result;
    for(size_t i=fontStart;i<draws.size();++i)
        if(![key(draws[i],0) isEqualToString:@(kFrontendTextures[i<fontStart+3?19:20].primary)])return result;
    result.actions.resize(draws.size());
    // Copy-normalized source pager marks. Their complete quads distinguish
    // these from letters and preserve the source's alien selection behavior.
    if(!ComboQuadUV(draws[fontStart],0,0,.04296875f,.4375f,.5078125f) ||
        !GalleryQuadBounds(draws[fontStart],.728125f,.753125f,.464285731f,.625f) ||
        !ComboQuadUV(draws[fontStart+1],0,.8046875f,.90625f,.5078125f,.578125f) ||
        !GalleryQuadBounds(draws[fontStart+1],-.765625f,-.696875f,.446428597f,.625f))return ComboGlyphAdmission{};
    result.actions[fontStart]={ProtectorActionGlyphNext};
    result.actions[fontStart+1]={ProtectorActionGlyphPrevious};
    for(size_t i=fontStart+4;i<draws.size();++i) {
        const auto& draw=draws[i];
        bool hasControl=false;
        for(const auto& v:draw.vertices) hasControl|=v.uv[0][1]>.93f;
        if(!hasControl)continue;
        if(draw.vertices.size()>12)return ComboGlyphAdmission{};
        for(size_t quad=0;quad<draw.vertices.size()/4;++quad) {
            const unsigned action=ComboQuadAction(draw,quad,scheme);
            if(!action)return ComboGlyphAdmission{};
            result.actions[i].push_back(action);++result.glyphCount;
        }
    }
    result.enabled=true;result.first=panelStart;result.scheme=scheme;
    result.reason="source-combo-panel-and-exact-action-quads";
    return result;
}

static void TransformComboVertex(LiveVertex* vertex,CGSize presentation,CGRect frame) {
    vertex->position[0]=(float)((frame.origin.x+(vertex->position[0]+1)*.5*frame.size.width)*2/presentation.width-1);
    vertex->position[1]=(float)(1-(frame.origin.y+(1-vertex->position[1])*.5*frame.size.height)*2/presentation.height);
}

static void UploadComboGlyphs(LiveVertex* vertices,const std::vector<unsigned>& actions,
    float navigationTop=.625f,float navigationBottom=.464285731f) {
    for(size_t q=0;q<actions.size();++q) {
        auto* v=vertices+q*4;
        if(actions[q]<=ProtectorActionGlyphSpecial && v[2].uv[0][0]-v[0].uv[0][0]>.20f) {
            const float center=(v[0].position[0]+v[2].position[0])*.5f;
            const float half=(v[2].position[0]-v[0].position[0])*.25f;
            v[0].position[0]=v[1].position[0]=center-half;
            v[2].position[0]=v[3].position[0]=center+half;
        }
        if(actions[q]>=ProtectorActionGlyphPrevious) {
            // Original textual < and > have unequal advance widths. Keep the
            // source centres, with equal authored navigation glyph boxes.
            const float center=(v[0].position[0]+v[2].position[0])*.5f;
            const float top=navigationTop,bottom=navigationBottom,half=.047f;
            v[0].position[0]=v[1].position[0]=center-half;
            v[2].position[0]=v[3].position[0]=center+half;
            v[0].position[1]=v[3].position[1]=bottom;v[1].position[1]=v[2].position[1]=top;
        }
        const float left=(actions[q]-1)/6.f,right=actions[q]/6.f;
        const float uv[][2]={{left,1},{left,0},{right,0},{right,1}};
        for(size_t i=0;i<4;++i)memcpy(v[i].uv[0],uv[i],sizeof(uv[i]));
    }
}

static id<MTLTexture> CreateComboGlyphTexture(id<MTLDevice> device) {
    constexpr size_t side=128,width=6*side;
    std::vector<u8> pixels(width*side*4);
    CGColorSpaceRef colorSpace=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(pixels.data(),width,side,8,width*4,colorSpace,
        kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);if(!context)return nil;
    CGContextTranslateCTM(context,0,side);CGContextScaleCTM(context,1,-1);
    for(unsigned action=1;action<=6;++action) {
        CGRect box=CGRectMake((action-1)*side+13,19,side-26,side-38);
        CGAffineTransform placement=ProtectorActionGlyphPlacement(box,action);
        CGPathRef unit=ProtectorActionCopyPath(action),detail=ProtectorActionCopyDetail(action);
        CGPathRef path=CGPathCreateCopyByTransformingPath(unit,&placement);
        CGPathRef lines=CGPathCreateCopyByTransformingPath(detail,&placement);
        CGContextSetRGBStrokeColor(context,.035,.035,.035,1);CGContextSetLineJoin(context,kCGLineJoinRound);
        CGContextSetLineCap(context,kCGLineCapRound);CGContextSetLineWidth(context,box.size.width*.14);
        CGContextAddPath(context,path);CGContextStrokePath(context);
        CGContextSaveGState(context);CGContextAddPath(context,path);CGContextClip(context);
        const CGFloat white[]={1,1,1,1,.82,.87,.85,1},green[]={.96,1,.62,1,.58,.93,.16,1};
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGGradientRef gradient=CGGradientCreateWithColorComponents(space,action==4?green:white,NULL,2);
        CGContextDrawLinearGradient(context,gradient,CGPointMake(CGRectGetMidX(box),CGRectGetMinY(box)),
            CGPointMake(CGRectGetMidX(box),CGRectGetMaxY(box)),0);
        CGGradientRelease(gradient);CGColorSpaceRelease(space);CGContextRestoreGState(context);
        CGContextSetLineWidth(context,box.size.width*.045);CGContextAddPath(context,lines);CGContextStrokePath(context);
        CGPathRelease(unit);CGPathRelease(detail);CGPathRelease(path);CGPathRelease(lines);
    }
    CGContextRelease(context);
    // GX's source-alpha blend expects straight RGBA, unlike CoreGraphics.
    for(size_t p=0;p<pixels.size();p+=4)if(pixels[p+3])for(size_t c=0;c<3;++c)
        pixels[p+c]=(u8)std::min(255u,((unsigned)pixels[p+c]*255u+pixels[p+3]/2)/pixels[p+3]);
    MTLTextureDescriptor* descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:width height:side mipmapped:NO];
    descriptor.storageMode=MTLStorageModeShared;descriptor.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> texture=[device newTextureWithDescriptor:descriptor];
    if(texture)[texture replaceRegion:MTLRegionMake2D(0,0,width,side) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:width*4];
    return texture;
}
