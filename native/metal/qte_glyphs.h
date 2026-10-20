#pragma once
#include "../apple/action_glyphs.h"
#include "protector/qte_presentation.h"

// Exact complete source objects, not one representative plane per resource.
// Platform-32 resource selection and all occurrences are pinned externally in
// complete-qte-objects-v3.json. Every object has RGB + green-channel coverage.
enum class QTEObjectRole { None, Motion, Cursor, LockedCursor, Target, Success };
struct QTEObjectIdentity { const char* primary; const char* coverage; QTEObjectRole role; };
static constexpr QTEObjectIdentity kQTEObjects[] = {
    {"128x128-b4b7a383b02cc496a0cb84ab06c51ab9d9506065ef3235f24f99d87b19a8537e", "128x128-371be005e65b009036c03135c16d273a62247f73465db3260ba490f76fd7ab2c", QTEObjectRole::Motion},
    {"128x128-5d332c80c50f34057bce24be996d1f648a9de00d311fcb515626e3e7c598da68", "128x128-f19d779bea9a610896c3c2a41945007f4d73abcc7165a4eaa7df7b5d79266ab0", QTEObjectRole::Motion},
    {"128x128-be276f3971b902968b0480c15cb70283e55bfa9f6cc1bbde634cc1c80ec251d2", "128x128-09838c0fa754adb1c8155bd91043cedcc995b29f96a09fa699ad89727dbeafe4", QTEObjectRole::Motion},
    {"128x128-f8b1419c21847f7d6cf95679938b945196222e745d16f22c904e8eca952885f4", "128x128-0c449b59047b486b6dc9f74c3104b44b6646c18fed0172b5ee04900dbdae83de", QTEObjectRole::Motion},
    {"128x128-308c8037067e8abeed0fff9bc5b20a7ac5a65d8a6982c1c76f0bf2267f90ecb8", "128x128-71a1a992f9cfb5945cad5d3baac661dab5ecab6e9da46fdceb81b3795bce4035", QTEObjectRole::Motion},
    {"128x128-b2df6f8ee7c44536ea52b4be30918f594ab407679b71a886e0fcd3c7731488e8", "128x128-ec50357f97ef543af7406e54d0b3f28a4edd1aeb663e0fbe9e25c1d5cc6c3c3e", QTEObjectRole::Motion},
    {"128x128-d13c3b5939e7ec7a120c403c53bee0b677aa66d0fdb9a4d5b06fe17763ba9d20", "128x128-1e893415373fe44c9546b397a1fc25047b239cddef0035c9b4ed50b921149766", QTEObjectRole::Cursor},
    {"256x256-807fa791f1f57b85b7b69929106ed2152da916b8e831dea9ba365ecffe76e230", "256x256-58ee0b9ba4e3bfc16d0ef716c7c3f3aadc58d34142ec50d37a0a71477f32ad2b", QTEObjectRole::LockedCursor},
    {"128x128-660f0b83d40b017d60cf5ea9241b3b00924f7c943200db490d3a80bb29b199a4", "128x128-f150f3b7d7a2014f781607a10ae0cd92033ac2628e49e7c10bb7f23ae6c99b0c", QTEObjectRole::Target},
    {"256x256-5f23e4b29d759dc4ff3171cede10d13e07e1ec2f8dcc782f1282f1aea37aa46d", "256x256-d581193149d9d94e90a75809a4e891cddcaac89d842a2129fdcac08ed08a4f7a", QTEObjectRole::Success},
};

static QTEObjectRole QTERoleForPair(NSString* primary, NSString* coverage) {
    if (!primary || !coverage) return QTEObjectRole::None;
    for (const auto& object : kQTEObjects)
        if ([primary isEqualToString:@(object.primary)] && [coverage isEqualToString:@(object.coverage)])
            return object.role;
    return QTEObjectRole::None;
}

static bool QTEPictureState(const LiveDraw& draw) {
    // The original two-stage picture shader: primary RGB multiplied by vertex
    // color, then coverage green multiplied by vertex alpha. Unknown programs
    // retain their source textures. No guessed alpha-plane reinterpretation.
    if (draw.projectionWords[6] != 1 || draw.blendMode != 13501 || draw.depthMode != 15 ||
        draw.fragment.stageCount != 2 || draw.fragment.indirectCount || draw.fragment.alphaTest != 4128768 ||
        draw.fragment.colorCombiners[0] != 64143 || draw.fragment.colorCombiners[1] != 589808 ||
        draw.fragment.alphaCombiners[0] != 65520 || draw.fragment.alphaCombiners[1] != 63100 ||
        draw.fragment.textureAlphaChannels[1] != 1 || draw.fragment.rasterAlphaChannels[1] != 3 ||
        draw.textureFormats[0] != 14 || draw.textureFormats[1] != 14 ||
        draw.textureCoordinates[0] || draw.textureCoordinates[1] ||
        draw.textureUnits[0] != 0 || draw.textureUnits[1] != 1 ||
        draw.textureWidths[0] != draw.textureHeights[0] ||
        (draw.textureWidths[0] != 128 && draw.textureWidths[0] != 256) ||
        draw.textureWidths[1] != draw.textureWidths[0] || draw.textureHeights[1] != draw.textureHeights[0]) return false;
    const size_t corners = draw.indexed ? 4 : 6;
    if (draw.vertices.size() != corners) return false;
    if (draw.indexed) {
        constexpr u32 indices[] = {0,1,2,0,2,3};
        if (draw.indices.size() != 6) return false;
        for (size_t i=0; i<6; ++i) if (draw.indices[i] != indices[i]) return false;
    }
    bool visible = false;
    float left=INFINITY, right=-INFINITY, bottom=INFINITY, top=-INFINITY;
    for (const auto& vertex : draw.vertices) {
        for (float value : vertex.position) if (!std::isfinite(value)) return false;
        if (std::abs(vertex.position[3]-1) > 1e-5f) return false;
        for (float value : vertex.color) if (!std::isfinite(value) || value<0 || value>1) return false;
        visible |= vertex.color[3] > 0;
        left=std::min(left,vertex.position[0]); right=std::max(right,vertex.position[0]);
        bottom=std::min(bottom,vertex.position[1]); top=std::max(top,vertex.position[1]);
        for (size_t axis=0; axis<2; ++axis) {
            const float value=vertex.uv[0][axis];
            if (!std::isfinite(value) || value < -1e-5f || value > 1.00001f ||
                !std::isfinite(vertex.uv[1][axis]) || std::abs(value-vertex.uv[1][axis]) > 1e-5f) return false;
        }
    }
    return visible && left<right && bottom<top && left<1 && right>-1 && bottom<1 && top>-1;
}

struct QTEAdmission {
    unsigned prompts=0;
    size_t motionDraws=0, targetDraws=0, cursorDraws=0, feedbackDraws=0;
    std::vector<QTEObjectRole> roles;
    CGRect targetClipRect=CGRectNull;
    CGRect motionClipRect=CGRectNull;
    bool replaces(size_t index) const { return index<roles.size() && roles[index]==QTEObjectRole::Motion; }
};

static QTEAdmission IdentifyQTE(const std::vector<LiveDraw>& draws) {
    QTEAdmission result;
    if (draws.size()>8192) return result;
    result.roles.resize(draws.size(),QTEObjectRole::None);
    std::map<std::tuple<const u8*,size_t,u32,u32>,NSString*> keys;
    auto key=[&](const LiveDraw& draw,size_t stage) {
        const auto& pixels=TexturePixels(draw,stage);
        const auto identity=std::make_tuple(pixels.data(),pixels.size(),draw.textureWidths[stage],draw.textureHeights[stage]);
        auto found=keys.find(identity); if(found!=keys.end())return found->second;
        NSString* value=InterfaceTextureKey(pixels,draw.textureWidths[stage],draw.textureHeights[stage]);
        keys.emplace(identity,value);return value;
    };
    for(size_t i=0;i<draws.size();++i) {
        const auto& draw=draws[i]; if(!QTEPictureState(draw))continue;
        const auto role=QTERoleForPair(key(draw,0),key(draw,1));result.roles[i]=role;
        switch(role) {
            case QTEObjectRole::Motion: {
                result.prompts|=PROTECTOR_QTE_PAIRED_MOTION; ++result.motionDraws;
                float left=INFINITY,right=-INFINITY,bottom=INFINITY,top=-INFINITY;
                for(const auto& v:draw.vertices) {
                    left=std::min(left,v.position[0]);right=std::max(right,v.position[0]);
                    bottom=std::min(bottom,v.position[1]);top=std::max(top,v.position[1]);
                }
                result.motionClipRect=CGRectUnion(result.motionClipRect,CGRectMake(left,bottom,right-left,top-bottom));
                break;
            }
            case QTEObjectRole::Target: {
                result.prompts|=PROTECTOR_QTE_POINTER_TARGET; ++result.targetDraws;
                float left=INFINITY,right=-INFINITY,bottom=INFINITY,top=-INFINITY;
                for(const auto& v:draw.vertices) {
                    left=std::min(left,v.position[0]);right=std::max(right,v.position[0]);
                    bottom=std::min(bottom,v.position[1]);top=std::max(top,v.position[1]);
                }
                result.targetClipRect=CGRectUnion(result.targetClipRect,
                    CGRectMake(left,bottom,right-left,top-bottom));
                break;
            }
            case QTEObjectRole::Cursor: ++result.cursorDraws; break;
            case QTEObjectRole::LockedCursor: case QTEObjectRole::Success: ++result.feedbackDraws; break;
            case QTEObjectRole::None: break;
        }
    }
    return result;
}

static CGRect QTENativeTargetRect(const QTEAdmission& qte,double aspect) {
    if(CGRectIsNull(qte.targetClipRect) || !std::isfinite(aspect) || aspect<4.0/3.0 || aspect>3)
        return CGRectNull;
    const double ratio=(4.0/3.0)/aspect;
    const CGRect source=qte.targetClipRect;
    return CGRectMake(.5+source.origin.x*.5*ratio,.5-CGRectGetMaxY(source)*.5,
        source.size.width*.5*ratio,source.size.height*.5);
}

// Applied after ordinary widescreen placement to a frame-local vertex upload.
// Translate the complete pair together; shrink uniformly only if necessary.
// Target/cursor geometry, snapshots, hit regions and source time never change.
static void FitQTEMotionVertex(LiveVertex* vertex,const QTEAdmission& qte,double aspect,CGRect safe) {
    if(CGRectIsNull(qte.motionClipRect) || !std::isfinite(aspect) || aspect<4.0/3.0 || aspect>3 ||
        !std::isfinite(safe.origin.x) || !std::isfinite(safe.size.width) ||
        safe.origin.x<0 || safe.size.width<=0 || CGRectGetMaxX(safe)>1) return;
    const double ratio=(4.0/3.0)/aspect;
    const double left=.5+qte.motionClipRect.origin.x*.5*ratio;
    const double width=qte.motionClipRect.size.width*.5*ratio;
    if(!(width>0))return;
    const double scale=std::min(1.0,(double)safe.size.width/width);
    const double fittedWidth=width*scale;
    const double destination=std::max((double)safe.origin.x,std::min(left,(double)CGRectGetMaxX(safe)-fittedWidth));
    const double x=.5+vertex->position[0]*.5;
    vertex->position[0]=(float)(2*(destination+(x-left)*scale)-1);
    const double centerY=CGRectGetMidY(qte.motionClipRect);
    vertex->position[1]=(float)(centerY+(vertex->position[1]-centerY)*scale);
}

static std::array<id<MTLTexture>,2> CreateQTEGlyphTextures(id<MTLDevice> device) {
    constexpr size_t side=512;
    std::vector<u8> pixels(side*side*4),coverage(pixels.size());
    std::array<id<MTLTexture>,2> textures{};
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(pixels.data(),side,side,8,side*4,space,
        kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    if(!context){CGColorSpaceRelease(space);return textures;}
    CGContextTranslateCTM(context,0,side);CGContextScaleCTM(context,1,-1);
    const CGRect box=CGRectMake(40,40,side-80,side-80);
    CGAffineTransform placement=ProtectorActionGlyphPlacement(box,ProtectorActionGlyphInteract);
    CGPathRef unit=ProtectorActionCopyPath(ProtectorActionGlyphInteract),detail=ProtectorActionCopyDetail(ProtectorActionGlyphInteract);
    CGPathRef path=CGPathCreateCopyByTransformingPath(unit,&placement),lines=CGPathCreateCopyByTransformingPath(detail,&placement);
    CGContextSetRGBStrokeColor(context,.035,.035,.035,1);CGContextSetLineJoin(context,kCGLineJoinRound);
    CGContextSetLineCap(context,kCGLineCapRound);CGContextSetLineWidth(context,box.size.width*.10);
    CGContextAddPath(context,path);CGContextStrokePath(context);
    CGContextSaveGState(context);CGContextAddPath(context,path);CGContextClip(context);
    const CGFloat colors[]={1,1,1,1,.82,.87,.85,1};
    CGGradientRef gradient=CGGradientCreateWithColorComponents(space,colors,NULL,2);
    CGContextDrawLinearGradient(context,gradient,CGPointMake(side/2,40),CGPointMake(side/2,side-40),0);
    CGGradientRelease(gradient);CGContextRestoreGState(context);
    CGContextSetLineWidth(context,box.size.width*.035);CGContextAddPath(context,lines);CGContextStrokePath(context);
    CGPathRelease(unit);CGPathRelease(detail);CGPathRelease(path);CGPathRelease(lines);
    CGContextRelease(context);CGColorSpaceRelease(space);
    for(size_t p=0;p<pixels.size();p+=4) {
        const unsigned alpha=pixels[p+3];
        for(size_t c=0;c<3;++c) {
            pixels[p+c]=alpha?(u8)std::min(255u,((unsigned)pixels[p+c]*255u+alpha/2)/alpha):0;
            coverage[p+c]=(u8)alpha;
        }
        pixels[p+3]=coverage[p+3]=255;
    }
    for(size_t stage=0;stage<2;++stage) {
        MTLTextureDescriptor* descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:side height:side mipmapped:NO];
        descriptor.storageMode=MTLStorageModeShared;descriptor.usage=MTLTextureUsageShaderRead;
        textures[stage]=[device newTextureWithDescriptor:descriptor];
        if(textures[stage])[textures[stage] replaceRegion:MTLRegionMake2D(0,0,side,side) mipmapLevel:0
            withBytes:(stage?coverage:pixels).data() bytesPerRow:side*4];
    }
    return textures;
}
