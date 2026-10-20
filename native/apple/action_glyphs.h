// Shared authored action geometry for UIKit controls and source-bound Metal
// notation. CoreGraphics paths in a 100-unit box; no game art or raster payload.
#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>

enum ProtectorActionGlyphID {
    ProtectorActionGlyphAttack = 1, ProtectorActionGlyphHeavy = 2,
    ProtectorActionGlyphJump = 3, ProtectorActionGlyphSpecial = 4,
    ProtectorActionGlyphPrevious = 5, ProtectorActionGlyphNext = 6,
    ProtectorActionGlyphInteract = 7,
};

static inline void ProtectorActionRoundRect(CGMutablePathRef path, CGRect rect, CGFloat radius) {
    CGPathAddRoundedRect(path, NULL, rect, radius, radius);
}

static inline CGPathRef ProtectorActionCopyFist(void) {
    CGMutablePathRef path = CGPathCreateMutable();
    for (int i = 0; i < 4; ++i)
        ProtectorActionRoundRect(path, CGRectMake(24 + 15 * i, 13, 16, 32), 8);
    ProtectorActionRoundRect(path, CGRectMake(20, 31, 64, 44), 12);
    ProtectorActionRoundRect(path, CGRectMake(16, 49, 50, 16), 8);
    ProtectorActionRoundRect(path, CGRectMake(34, 71, 36, 16), 5);
    return path;
}

static inline CGPathRef ProtectorActionCopyPolygon(const CGFloat* points, size_t count) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, points[0], points[1]);
    for (size_t i = 1; i < count; ++i) CGPathAddLineToPoint(path, NULL, points[2*i], points[2*i+1]);
    CGPathCloseSubpath(path);
    return path;
}

static inline CGAffineTransform ProtectorActionHeavyTransform(void) {
    return CGAffineTransformConcat(CGAffineTransformMakeScale(.74, .74), CGAffineTransformMakeTranslation(-4, 28));
}

static inline CGAffineTransform ProtectorActionInteractTransform(void) {
    return CGAffineTransformConcat(CGAffineTransformMakeScale(.56, .56), CGAffineTransformMakeTranslation(21.7, 24));
}

static inline CGPathRef ProtectorActionCopyPath(unsigned action) {
    if (action == ProtectorActionGlyphAttack) return ProtectorActionCopyFist();
    CGMutablePathRef path = CGPathCreateMutable();
    if (action == ProtectorActionGlyphHeavy) {
        CGPathRef fist = ProtectorActionCopyFist();
        CGAffineTransform transform = ProtectorActionHeavyTransform();
        CGPathAddPath(path, &transform, fist); CGPathRelease(fist);
        static const CGFloat strokes[] = {64,32,80,16,70,44,89,39,55,26,59,9};
        for (unsigned i = 0; i < 3; ++i) {
            CGMutablePathRef line = CGPathCreateMutable();
            CGPathMoveToPoint(line, NULL, strokes[4*i], strokes[4*i+1]);
            CGPathAddLineToPoint(line, NULL, strokes[4*i+2], strokes[4*i+3]);
            CGPathRef outline = CGPathCreateCopyByStrokingPath(line, NULL, 7.5, kCGLineCapRound, kCGLineJoinRound, 4);
            if (outline) { CGPathAddPath(path, NULL, outline); CGPathRelease(outline); }
            CGPathRelease(line);
        }
    } else if (action == ProtectorActionGlyphInteract) {
        // The existing touch-control gripping fist and paired motion arcs.
        // Native QTE notation means Hold Interact, never a console peripheral.
        CGPathRef fist = ProtectorActionCopyFist();
        CGAffineTransform transform = ProtectorActionInteractTransform();
        CGPathAddPath(path, &transform, fist); CGPathRelease(fist);
        for (unsigned side = 0; side < 2; ++side) {
            const CGFloat facing = side ? 0 : M_PI;
            for (unsigned ring = 0; ring < 2; ++ring) {
                const CGFloat radius = ring ? 44 : 33, extent = ring ? .36 : .55;
                CGMutablePathRef arc = CGPathCreateMutable();
                CGPathAddArc(arc, NULL, 50, 52, radius, facing-extent, facing+extent, false);
                CGPathRef outline = CGPathCreateCopyByStrokingPath(arc, NULL,
                    ring ? 6 : 6.5, kCGLineCapRound, kCGLineJoinRound, 4);
                if (outline) { CGPathAddPath(path, NULL, outline); CGPathRelease(outline); }
                CGPathRelease(arc);
            }
        }
    } else if (action == ProtectorActionGlyphJump) {
        static const CGFloat points[] = {50,6,84,38,70,50,50,30,30,50,16,38};
        CGPathRef rise = ProtectorActionCopyPolygon(points, 6);
        CGPathAddPath(path, NULL, rise);
        CGAffineTransform lower = CGAffineTransformMakeTranslation(0, 30);
        CGPathAddPath(path, &lower, rise); CGPathRelease(rise);
        ProtectorActionRoundRect(path, CGRectMake(24,85,52,9), 4.5);
    } else if (action == ProtectorActionGlyphSpecial) {
        static const CGFloat points[] = {60,2,72,2,57,40,82,40,34,98,46,56,20,56};
        CGPathRef bolt = ProtectorActionCopyPolygon(points, 7);
        CGPathAddPath(path, NULL, bolt); CGPathRelease(bolt);
    } else if (action == ProtectorActionGlyphPrevious || action == ProtectorActionGlyphNext) {
        static const CGFloat points[] = {62,12,76,26,52,50,76,74,62,88,24,50};
        CGPathRef arrow = ProtectorActionCopyPolygon(points, 6);
        CGAffineTransform flip = CGAffineTransformMake(-1,0,0,1,100,0);
        CGPathAddPath(path, action == ProtectorActionGlyphNext ? &flip : NULL, arrow);
        CGPathRelease(arrow);
    }
    return path;
}

static inline CGPathRef ProtectorActionCopyDetail(unsigned action) {
    CGMutablePathRef path = CGPathCreateMutable();
    if (action != ProtectorActionGlyphAttack && action != ProtectorActionGlyphHeavy &&
        action != ProtectorActionGlyphInteract) return path;
    for (int i = 1; i < 4; ++i) {
        CGPathMoveToPoint(path, NULL, 24.5 + 15*i, 17);
        CGPathAddLineToPoint(path, NULL, 24.5 + 15*i, 39);
    }
    CGPathMoveToPoint(path, NULL, 24,49.5); CGPathAddLineToPoint(path, NULL, 58,49.5);
    CGPathAddArc(path, NULL, 58,57,7.5,-M_PI_2,M_PI_2,false);
    CGPathMoveToPoint(path, NULL, 36,75); CGPathAddLineToPoint(path, NULL, 68,75);
    if (action == ProtectorActionGlyphAttack) return path;
    CGAffineTransform transform = action == ProtectorActionGlyphInteract
        ? ProtectorActionInteractTransform() : ProtectorActionHeavyTransform();
    CGPathRef heavy = CGPathCreateCopyByTransformingPath(path, &transform);
    CGPathRelease(path); return heavy;
}

static inline CGAffineTransform ProtectorActionGlyphPlacement(CGRect box, unsigned action) {
    const CGFloat slant = action <= ProtectorActionGlyphSpecial || action == ProtectorActionGlyphInteract ? .12 : 0;
    const CGFloat scale = fmin(box.size.width, box.size.height) / (100 * (1 + slant * .6));
    CGAffineTransform transform = CGAffineTransformMakeTranslation(-50,-50);
    transform = CGAffineTransformConcat(transform, CGAffineTransformMake(1,0,-slant,1,0,0));
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(scale,scale));
    return CGAffineTransformConcat(transform, CGAffineTransformMakeTranslation(CGRectGetMidX(box),CGRectGetMidY(box)));
}
