// Authored art for the native Omnitrix-family touch controls. The game
// overlay and the native Controls guide draw these same vector glyphs. Each
// is an original drawing in a 100-unit box: no system symbols, Unicode
// pictograms, raster assets or copied game artwork. Transform is a plain
// diamond, deliberately not the show's trademark mark.
#pragma once
#import <UIKit/UIKit.h>
#include <math.h>
#include "../apple/action_glyphs.h"

typedef NS_ENUM(NSInteger, ProtectorGlyph) {
    ProtectorGlyphNone = 0,
    ProtectorGlyphAttack,
    ProtectorGlyphHeavy,
    ProtectorGlyphBlock,
    ProtectorGlyphJump,
    ProtectorGlyphSpecial,
    ProtectorGlyphInteract,
    ProtectorGlyphTransform,
    ProtectorGlyphPrevious,
    ProtectorGlyphNext,
    ProtectorGlyphUp,
    ProtectorGlyphDown,
    ProtectorGlyphConfirm,
    ProtectorGlyphBack,
    ProtectorGlyphMenu,
    ProtectorGlyphPause,
    ProtectorGlyphResume,
    ProtectorGlyphMove,
    ProtectorGlyphChooseAlien,
    ProtectorGlyphNavigate,
    ProtectorGlyphAim,
    ProtectorGlyphBottomFaceButton,
};

// Palette shared with the watch HUD family: cel ink, Omnitrix green and the
// brighter held state. Ink is the contrast floor between glyphs and any pixel.
static inline CGFloat ProtectorArtInkShade(void) { return 0.035; }
static inline UIColor* ProtectorArtInk(void) {
    return [UIColor colorWithWhite:ProtectorArtInkShade() alpha:1];
}
static inline UIColor* ProtectorArtGreen(void) {
    return [UIColor colorWithRed:0.42 green:0.86 blue:0.20 alpha:1];
}
static inline UIColor* ProtectorArtHeldGreen(void) {
    return [UIColor colorWithRed:0.72 green:1.0 blue:0.45 alpha:1];
}
static inline UIColor* ProtectorArtHalo(void) {
    return [UIColor colorWithRed:0.56 green:1.0 blue:0.32 alpha:1];
}
// Native sheet tint. Light: about 6:1 against white and under white text.
// Dark: about 6:1 for tinted text on the dark grouped background.
static inline UIColor* ProtectorSettingsTint(void) {
    return [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.30 green:0.68 blue:0.20 alpha:1]
            : [UIColor colorWithRed:0.10 green:0.45 blue:0.10 alpha:1];
    }];
}
// Fill for the iOS 26+ prominent Resume pill under a white title: about 6:1
// in light and 5:1 in dark. Deeper than the dark sheet tint, which is tuned
// for tinted text and would leave a white title near 3:1.
static inline UIColor* ProtectorSettingsProminentTint(void) {
    return [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.12 green:0.50 blue:0.12 alpha:1]
            : [UIColor colorWithRed:0.10 green:0.45 blue:0.10 alpha:1];
    }];
}

#define PROTECTOR_ART_POINTS(array) (sizeof(array) / sizeof((array)[0]) / 2)

static inline UIBezierPath* ProtectorArtPolygon(const CGFloat* xy, size_t points) {
    UIBezierPath* path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(xy[0], xy[1])];
    for (size_t i = 1; i < points; ++i) [path addLineToPoint:CGPointMake(xy[2 * i], xy[2 * i + 1])];
    [path closePath];
    return path;
}
static inline UIBezierPath* ProtectorArtTransformed(UIBezierPath* source, CGAffineTransform transform) {
    UIBezierPath* copy = [source copy];
    [copy applyTransform:transform];
    return copy;
}
static inline CGAffineTransform ProtectorArtScaleAbout(CGFloat scale, CGFloat x, CGFloat y) {
    return CGAffineTransformConcat(CGAffineTransformConcat(CGAffineTransformMakeTranslation(-x, -y),
        CGAffineTransformMakeScale(scale, scale)), CGAffineTransformMakeTranslation(x, y));
}
static inline CGAffineTransform ProtectorArtRotateAbout(CGFloat angle) {
    return CGAffineTransformConcat(CGAffineTransformConcat(CGAffineTransformMakeTranslation(-50, -50),
        CGAffineTransformMakeRotation(angle)), CGAffineTransformMakeTranslation(50, 50));
}
// Outlines a stroke so it joins the glyph's single fill path.
static inline void ProtectorArtAppendStroke(UIBezierPath* target, UIBezierPath* line, CGFloat width) {
    CGPathRef outline = CGPathCreateCopyByStrokingPath(line.CGPath, NULL, width,
        kCGLineCapRound, kCGLineJoinRound, 4);
    if (!outline) return;
    [target appendPath:[UIBezierPath bezierPathWithCGPath:outline]];
    CGPathRelease(outline);
}

// A clenched fist, knuckles forward, in chunky cartoon proportion. All parts
// are clockwise rounded rectangles, so the nonzero fill is their union.
static inline UIBezierPath* ProtectorArtFist(void) {
    UIBezierPath* path = [UIBezierPath bezierPath];
    for (int i = 0; i < 4; ++i)
        [path appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(24 + 15 * i, 13, 16, 32) cornerRadius:8]];
    [path appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(20, 31, 64, 44) cornerRadius:12]];
    [path appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(16, 49, 50, 16) cornerRadius:8]];
    [path appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(34, 71, 36, 16) cornerRadius:5]];
    return path;
}
static inline UIBezierPath* ProtectorArtFistDetail(void) {
    UIBezierPath* path = [UIBezierPath bezierPath];
    for (int i = 1; i < 4; ++i) {
        [path moveToPoint:CGPointMake(24.5 + 15 * i, 17)];
        [path addLineToPoint:CGPointMake(24.5 + 15 * i, 39)];
    }
    [path moveToPoint:CGPointMake(24, 49.5)];
    [path addLineToPoint:CGPointMake(58, 49.5)];
    [path addArcWithCenter:CGPointMake(58, 57) radius:7.5 startAngle:-M_PI_2 endAngle:M_PI_2 clockwise:YES];
    [path moveToPoint:CGPointMake(36, 75)];
    [path addLineToPoint:CGPointMake(68, 75)];
    return path;
}
static inline CGAffineTransform ProtectorArtHeavyFist(void) {
    return CGAffineTransformConcat(CGAffineTransformMakeScale(.74, .74), CGAffineTransformMakeTranslation(-4, 28));
}
static inline CGAffineTransform ProtectorArtInteractFist(void) {
    return CGAffineTransformConcat(CGAffineTransformMakeScale(.56, .56), CGAffineTransformMakeTranslation(21.7, 24));
}
static inline UIBezierPath* ProtectorArtChevron(void) {  // points left
    static const CGFloat points[] = {62, 12, 76, 26, 52, 50, 76, 74, 62, 88, 24, 50};
    return ProtectorArtPolygon(points, PROTECTOR_ART_POINTS(points));
}
static inline UIBezierPath* ProtectorArtShield(void) {
    static const CGFloat points[] = {50, 5, 63, 13, 86, 13, 83, 50, 72, 72, 50, 95, 28, 72, 17, 50, 14, 13, 37, 13};
    return ProtectorArtPolygon(points, PROTECTOR_ART_POINTS(points));
}
static inline UIBezierPath* ProtectorArtDiamond(void) {
    static const CGFloat points[] = {50, 6, 94, 50, 50, 94, 6, 50};
    return ProtectorArtPolygon(points, PROTECTOR_ART_POINTS(points));
}

static inline UIBezierPath* ProtectorGlyphUnitPath(ProtectorGlyph glyph) {
    const unsigned sharedAction = glyph == ProtectorGlyphAttack ? ProtectorActionGlyphAttack :
        glyph == ProtectorGlyphHeavy ? ProtectorActionGlyphHeavy : glyph == ProtectorGlyphJump ? ProtectorActionGlyphJump :
        glyph == ProtectorGlyphSpecial ? ProtectorActionGlyphSpecial :
        glyph == ProtectorGlyphInteract ? ProtectorActionGlyphInteract : 0;
    if (sharedAction) {
        CGPathRef shared = ProtectorActionCopyPath(sharedAction);
        UIBezierPath* result = [UIBezierPath bezierPathWithCGPath:shared];
        CGPathRelease(shared);
        return result;
    }
    switch (glyph) {
        case ProtectorGlyphAttack:
        case ProtectorGlyphHeavy:
        case ProtectorGlyphJump:
        case ProtectorGlyphSpecial:
        case ProtectorGlyphInteract:
            break; // Returned by the shared CoreGraphics geometry above.
        case ProtectorGlyphBlock:
            return ProtectorArtShield();
        case ProtectorGlyphTransform:
            return ProtectorArtDiamond();
        case ProtectorGlyphPrevious:
            return ProtectorArtChevron();
        case ProtectorGlyphNext:
            return ProtectorArtTransformed(ProtectorArtChevron(), CGAffineTransformMake(-1, 0, 0, 1, 100, 0));
        case ProtectorGlyphUp:
            return ProtectorArtTransformed(ProtectorArtChevron(), ProtectorArtRotateAbout(M_PI_2));
        case ProtectorGlyphDown:
            return ProtectorArtTransformed(ProtectorArtChevron(), ProtectorArtRotateAbout(-M_PI_2));
        case ProtectorGlyphConfirm: {
            static const CGFloat check[] = {14, 52, 28, 38, 42, 52, 76, 18, 90, 32, 42, 80};
            return ProtectorArtPolygon(check, PROTECTOR_ART_POINTS(check));
        }
        case ProtectorGlyphBack: {
            UIBezierPath* line = [UIBezierPath bezierPath];
            [line moveToPoint:CGPointMake(38, 20)];
            [line addLineToPoint:CGPointMake(18, 40)];
            [line addLineToPoint:CGPointMake(38, 60)];
            [line moveToPoint:CGPointMake(20, 40)];
            [line addLineToPoint:CGPointMake(58, 40)];
            [line addArcWithCenter:CGPointMake(58, 60) radius:20 startAngle:-M_PI_2 endAngle:M_PI_2 clockwise:YES];
            [line addLineToPoint:CGPointMake(34, 80)];
            UIBezierPath* path = [UIBezierPath bezierPath];
            ProtectorArtAppendStroke(path, line, 12);
            return path;
        }
        case ProtectorGlyphMenu: {
            UIBezierPath* path = [UIBezierPath bezierPath];
            for (int i = 0; i < 3; ++i)
                [path appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(16, 20 + 24 * i, 68, 13) cornerRadius:6.5]];
            return path;
        }
        case ProtectorGlyphPause: {
            UIBezierPath* path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(24, 14, 19, 72) cornerRadius:6];
            [path appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(57, 14, 19, 72) cornerRadius:6]];
            return path;
        }
        case ProtectorGlyphResume: {
            static const CGFloat play[] = {28, 12, 84, 50, 28, 88};
            return ProtectorArtPolygon(play, PROTECTOR_ART_POINTS(play));
        }
        case ProtectorGlyphMove: {
            UIBezierPath* path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(40, 40, 20, 20)];
            static const CGFloat arrow[] = {50, 4, 64, 22, 36, 22};
            for (int i = 0; i < 4; ++i)
                [path appendPath:ProtectorArtTransformed(ProtectorArtPolygon(arrow, PROTECTOR_ART_POINTS(arrow)),
                    ProtectorArtRotateAbout(i * M_PI_2))];
            return path;
        }
        case ProtectorGlyphChooseAlien: {
            UIBezierPath* path = ProtectorArtTransformed(ProtectorArtChevron(),
                CGAffineTransformConcat(ProtectorArtScaleAbout(.55, 50, 50), CGAffineTransformMakeTranslation(-20, 0)));
            [path appendPath:ProtectorArtTransformed(ProtectorArtChevron(), CGAffineTransformConcat(
                CGAffineTransformMake(-.55, 0, 0, .55, 77.5, 22.5), CGAffineTransformMakeTranslation(20, 0)))];
            static const CGFloat gem[] = {50, 30, 70, 50, 50, 70, 30, 50};
            [path appendPath:ProtectorArtPolygon(gem, PROTECTOR_ART_POINTS(gem))];
            return path;
        }
        case ProtectorGlyphNavigate: {
            UIBezierPath* path = ProtectorArtTransformed(ProtectorArtChevron(), CGAffineTransformConcat(
                CGAffineTransformConcat(ProtectorArtRotateAbout(M_PI_2), ProtectorArtScaleAbout(.55, 50, 50)),
                CGAffineTransformMakeTranslation(0, -20)));
            [path appendPath:ProtectorArtTransformed(ProtectorArtChevron(), CGAffineTransformConcat(
                CGAffineTransformConcat(ProtectorArtRotateAbout(-M_PI_2), ProtectorArtScaleAbout(.55, 50, 50)),
                CGAffineTransformMakeTranslation(0, 20)))];
            return path;
        }
        case ProtectorGlyphAim: {
            UIBezierPath* path = [UIBezierPath bezierPath];
            ProtectorArtAppendStroke(path, [UIBezierPath bezierPathWithOvalInRect:CGRectMake(24, 24, 52, 52)], 8);
            for (int i = 0; i < 4; ++i) {
                const CGFloat angle = i * M_PI_2;
                UIBezierPath* tick = [UIBezierPath bezierPath];
                [tick moveToPoint:CGPointMake(50 + cos(angle) * 38, 50 + sin(angle) * 38)];
                [tick addLineToPoint:CGPointMake(50 + cos(angle) * 45, 50 + sin(angle) * 45)];
                ProtectorArtAppendStroke(path, tick, 8);
            }
            [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(43, 43, 14, 14)]];
            return path;
        }
        case ProtectorGlyphBottomFaceButton: {
            // Four face buttons in a diamond with the bottom one filled: the
            // truthful generic for "bottom face button" on any controller.
            UIBezierPath* path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(36, 64, 28, 28)];
            static const CGFloat centres[] = {50, 20, 80, 50, 20, 50};
            for (size_t i = 0; i < 3; ++i)
                ProtectorArtAppendStroke(path, [UIBezierPath bezierPathWithOvalInRect:
                    CGRectMake(centres[2 * i] - 11, centres[2 * i + 1] - 11, 22, 22)], 5);
            return path;
        }
        case ProtectorGlyphNone:
            break;
    }
    return nil;
}

// Inner ink lines drawn over the fill: finger breaks, crest bevel, gem facet.
static inline UIBezierPath* ProtectorGlyphUnitDetail(ProtectorGlyph glyph) {
    switch (glyph) {
        case ProtectorGlyphAttack:
            return ProtectorArtFistDetail();
        case ProtectorGlyphHeavy:
            return ProtectorArtTransformed(ProtectorArtFistDetail(), ProtectorArtHeavyFist());
        case ProtectorGlyphInteract:
            return ProtectorArtTransformed(ProtectorArtFistDetail(), ProtectorArtInteractFist());
        case ProtectorGlyphBlock:
            return ProtectorArtTransformed(ProtectorArtShield(), ProtectorArtScaleAbout(.58, 50, 48));
        case ProtectorGlyphTransform:
            return ProtectorArtTransformed(ProtectorArtDiamond(), ProtectorArtScaleAbout(.56, 50, 50));
        default:
            return nil;
    }
}

// Action glyphs lean forward like the game's own display lettering.
static inline CGFloat ProtectorGlyphSlant(ProtectorGlyph glyph) {
    switch (glyph) {
        case ProtectorGlyphAttack: case ProtectorGlyphHeavy: case ProtectorGlyphBlock:
        case ProtectorGlyphJump: case ProtectorGlyphSpecial: case ProtectorGlyphInteract:
        case ProtectorGlyphConfirm: case ProtectorGlyphBack: case ProtectorGlyphMenu:
        case ProtectorGlyphPause:
            return 0.12;
        default:
            return 0;
    }
}

// Top-to-bottom cel shading for the glyph fill.
static inline NSArray<UIColor*>* ProtectorGlyphGradient(ProtectorGlyph glyph) {
    if (glyph == ProtectorGlyphSpecial)
        return @[[UIColor colorWithRed:.96 green:1 blue:.62 alpha:1], [UIColor colorWithRed:.58 green:.93 blue:.16 alpha:1]];
    if (glyph == ProtectorGlyphTransform)
        return @[[UIColor colorWithRed:.66 green:1 blue:.40 alpha:1], [UIColor colorWithRed:.08 green:.52 blue:.12 alpha:1]];
    return @[UIColor.whiteColor, [UIColor colorWithRed:.82 green:.87 blue:.85 alpha:1]];
}

static inline CGAffineTransform ProtectorGlyphPlacement(CGRect box, CGFloat slant) {
    const CGFloat scale = fmin(box.size.width, box.size.height) / (100 * (1 + slant * .6));
    CGAffineTransform transform = CGAffineTransformMakeTranslation(-50, -50);
    transform = CGAffineTransformConcat(transform, CGAffineTransformMake(1, 0, -slant, 1, 0, 0));
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(scale, scale));
    return CGAffineTransformConcat(transform,
        CGAffineTransformMakeTranslation(CGRectGetMidX(box), CGRectGetMidY(box)));
}
static inline UIBezierPath* ProtectorGlyphPath(ProtectorGlyph glyph, CGRect box) {
    UIBezierPath* path = ProtectorGlyphUnitPath(glyph);
    [path applyTransform:ProtectorGlyphPlacement(box, ProtectorGlyphSlant(glyph))];
    return path;
}
static inline UIBezierPath* ProtectorGlyphDetailPath(ProtectorGlyph glyph, CGRect box) {
    UIBezierPath* path = ProtectorGlyphUnitDetail(glyph);
    [path applyTransform:ProtectorGlyphPlacement(box, ProtectorGlyphSlant(glyph))];
    return path;
}
// Tintable list image of the same drawing for native settings rows.
static inline UIImage* ProtectorGlyphTemplateImage(ProtectorGlyph glyph, CGFloat side) {
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage* image = [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        const CGRect box = CGRectInset(CGRectMake(0, 0, side, side), side * .04, side * .04);
        [UIColor.blackColor setFill];
        [ProtectorGlyphPath(glyph, box) fill];
        UIBezierPath* detail = ProtectorGlyphDetailPath(glyph, box);
        if (!detail) return;
        // Inner lines are cut out so the tinted template keeps its drawing.
        CGContextSetBlendMode(context.CGContext, kCGBlendModeClear);
        detail.lineWidth = fmax(1, side * .06);
        detail.lineCapStyle = kCGLineCapRound;
        detail.lineJoinStyle = kCGLineJoinRound;
        [detail stroke];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}
