#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import "protector/game_session.h"
#import "protector/live_input.h"
#import "protector/live_gx.h"
#import "protector/ui_context.h"
#import "protector/save_store.h"
#import "protector/motion_clock.h"
#import "protector/runtime_result.h"
#import "protector/touch_layout.h"
#import "touch_settings.h"
#import "control_art.h"
#import "qa/controller_snapshot_qa.h"
#if PROTECTOR_IOS_EXTERNAL_CONTENT
#import "content_import.h"
// Same build flag that links the native audio output into the game session.
#import "../apple/audio_output.h"
#endif
#include <math.h>

// Status text is not a control face. Its plate keeps a contrast floor that is
// independent of game pixels, system appearance and the opacity preference.
static UIColor* ProtectorControlBacking(void) {
    const CGFloat opacity = fmin(1, fmax(0.72,
        [NSUserDefaults.standardUserDefaults doubleForKey:ProtectorTouchOpacityKey]));
    return [UIColor colorWithWhite:0.04 alpha:opacity];
}
// The controls are hardware from the game's own watch: black cel ink,
// gunmetal bezels and Omnitrix glass. Ink, glyphs and captions keep full
// strength; the opacity preference fades only bezel and glass.
static CGFloat ProtectorMaterialOpacity(void) {
    return fmin(1, fmax(0.5, [NSUserDefaults.standardUserDefaults doubleForKey:ProtectorTouchOpacityKey]));
}

// Set while a fixed render scale is still unproven this launch; see viewDidLoad.
static NSString* const ProtectorRenderScaleTrialKey = @"render.scale.trial.v1";

// Player copy for runtime failures. The full description goes to the log (and
// the diagnostics snapshot) where support can read it; the player gets a plain
// sentence, what to do next and a short reference code to quote.
static NSString* ProtectorErrorReference(NSError* error) {
    NSString* domain = error.domain ? error.domain : @"";
    NSString* letter = [domain isEqual:@"ProtectorSession"] ? @"S"
        : [domain containsString:@"LiveMetal"] ? @"R" : [domain isEqual:@"ProtectorShell"] ? @"A" : @"E";
    return [NSString stringWithFormat:@"%@-%ld", letter, (long)error.code];
}
static void ProtectorLogFailure(NSError* error) {
    static NSString* last;  // updateDiagnostics repeats the same failure every few seconds
    NSString* detail = [NSString stringWithFormat:@"%@ %ld: %@", error.domain, (long)error.code, error.localizedDescription];
    if ([detail isEqual:last]) return;
    last = detail;
    NSLog(@"Protector failure %@", detail);
}
static NSString* ProtectorPlayerErrorText(NSError* error) {
    ProtectorLogFailure(error);
    NSString* reference = [NSString stringWithFormat:@"\n\nRef %@", ProtectorErrorReference(error)];
    const NSInteger code = error.code;
    const BOOL session = [error.domain isEqual:@"ProtectorSession"];
    // Save-storage failures are already written for players, with the save advice.
    if (session && (code == (NSInteger)PROTECTOR_RUNTIME_SAVE_COMMIT_FAILED ||
            code == (NSInteger)PROTECTOR_RUNTIME_SAVE_DIRECTORY_FAILED ||
            code == (NSInteger)PROTECTOR_RUNTIME_SAVE_LOAD_FAILED) && error.localizedDescription.length)
        return [error.localizedDescription stringByAppendingString:reference];
    // Content and setup problems are found before the game runs, so nothing was written.
    if ((session && (code == 1 || code == 2 || code == 3 || code == 20)) || [error.domain isEqual:@"ProtectorShell"])
        return [@"Protector couldn’t start.\nClose and reopen Protector to try again. Your saved progress hasn’t been changed."
            stringByAppendingString:reference];
    // The graphics side never touches the save files.
    if ([error.domain containsString:@"LiveMetal"])
        return [@"Something went wrong and the game had to stop.\nClose and reopen Protector to continue. Your saved progress is safe."
            stringByAppendingString:reference];
    return [@"Something went wrong and the game had to stop.\nClose and reopen Protector to continue. Progress after your last successful save may be lost."
        stringByAppendingString:reference];
}
// QA-only direct room start for device playtests. Launching with
// PROTECTOR_QA_START_LEVEL=NN_NN rebuilds a disposable data root whose
// CDGame.txt uses the original START_LEVEL/LOAD_TO_START_LEVEL settings (same
// file length, so the FST is unchanged) and symlinks every other file. Saves go
// to a separate QA namespace; the player's saves and content are never opened.
static NSError* ProtectorQAStartError(NSString* message) {
    return [NSError errorWithDomain:@"ProtectorShell" code:40 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSData* ProtectorQAStartConfig(NSData* source, NSString* level, NSError** error) {
    NSString* text = [[NSString alloc] initWithData:source encoding:NSASCIIStringEncoding];
    if (!text) { if (error) *error = ProtectorQAStartError(@"CDGame.txt is not ASCII"); return nil; }
    NSDictionary* changes = @{@"LEVEL_SELECT":@"OFF", @"LOAD_TO_START_LEVEL":@"ON", @"START_LEVEL":level};
    NSMutableSet* found = [NSMutableSet set];
    NSMutableArray* records = [NSMutableArray array];
    for (NSString* raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange comment = [raw rangeOfString:@"//"];
        NSString* line = [(comment.location == NSNotFound ? raw : [raw substringToIndex:comment.location])
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) continue;
        NSArray* parts = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString* key = parts.firstObject;
        if (changes[key]) {
            if ([found containsObject:key] || parts.count < 2) {
                if (error) *error = ProtectorQAStartError(@"CDGame.txt has a malformed level setting");
                return nil;
            }
            [found addObject:key];
            line = [NSString stringWithFormat:@"%@\t%@", key, changes[key]];
        }
        [records addObject:line];
    }
    if (![found containsObject:@"LEVEL_SELECT"] || ![found containsObject:@"START_LEVEL"]) {
        if (error) *error = ProtectorQAStartError(@"CDGame.txt lacks level settings");
        return nil;
    }
    if (![found containsObject:@"LOAD_TO_START_LEVEL"]) [records addObject:@"LOAD_TO_START_LEVEL\tON"];
    NSMutableData* result = [[[[records componentsJoinedByString:@"\r\n"] stringByAppendingString:@"\r\n"]
        dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    if (source.length < result.length + 4) {
        if (error) *error = ProtectorQAStartError(@"QA configuration exceeds the original file length");
        return nil;
    }
    // The original line reader needs a terminated final line.
    const NSUInteger padding = source.length - result.length;
    [result appendBytes:"//" length:2];
    for (NSUInteger i = 4; i < padding; ++i) [result appendBytes:" " length:1];
    [result appendBytes:"\r\n" length:2];
    return result.length == source.length ? result : nil;
}
static NSURL* ProtectorQAStartRoot(NSURL* game, NSString* level, NSError** error) {
    NSFileManager* manager = NSFileManager.defaultManager;
    NSString* levels = [NSString stringWithContentsOfURL:[game URLByAppendingPathComponent:@"files/levels.txt"]
        encoding:NSASCIIStringEncoding error:error];
    if (!levels) return nil;
    BOOL listed = NO;
    for (NSString* line in [levels componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
        if ([[line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].firstObject isEqual:level])
            listed = YES;
    if (!listed) { if (error) *error = ProtectorQAStartError(@"QA start scene is not in levels.txt"); return nil; }
    NSData* source = [NSData dataWithContentsOfURL:[game URLByAppendingPathComponent:@"files/CDGame.txt"]
        options:0 error:error];
    NSData* config = source ? ProtectorQAStartConfig(source, level, error) : nil;
    if (!config) { if (error && !*error) *error = ProtectorQAStartError(@"QA configuration failed"); return nil; }
    NSURL* root = [[[manager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
        URLByAppendingPathComponent:@"QAStart" isDirectory:YES] URLByAppendingPathComponent:@"Game" isDirectory:YES];
    [manager removeItemAtURL:root.URLByDeletingLastPathComponent error:nil];
    NSURL* files = [root URLByAppendingPathComponent:@"files" isDirectory:YES];
    if (![manager createDirectoryAtURL:files withIntermediateDirectories:YES attributes:nil error:error] ||
        ![manager createSymbolicLinkAtURL:[root URLByAppendingPathComponent:@"sys"]
            withDestinationURL:[game URLByAppendingPathComponent:@"sys"] error:error]) return nil;
    NSArray* names = [manager contentsOfDirectoryAtPath:[game URLByAppendingPathComponent:@"files"].path error:error];
    if (!names) return nil;
    for (NSString* name in names) {
        if ([name isEqual:@"CDGame.txt"]) continue;
        if (![manager createSymbolicLinkAtURL:[files URLByAppendingPathComponent:name]
                withDestinationURL:[[game URLByAppendingPathComponent:@"files"] URLByAppendingPathComponent:name] error:error])
            return nil;
    }
    if (![config writeToURL:[files URLByAppendingPathComponent:@"CDGame.txt"] options:NSDataWritingWithoutOverwriting error:error])
        return nil;
    NSLog(@"Protector QA direct start %@", level);
    return root;
}
// Layout problems leave the game running, so they get their own, calmer copy.
static NSString* ProtectorLayoutErrorText(NSError* error) {
    ProtectorLogFailure(error);
    return [NSString stringWithFormat:@"Part of the screen couldn’t be laid out. If the picture looks wrong, rotate your iPhone or close and reopen Protector.\n\nRef %@",
        ProtectorErrorReference(error)];
}

// True while the pad is being touched or pushed: the signal that a controller
// player is back after using the touch controls.
static BOOL ProtectorPadHasInput(GCExtendedGamepad* pad) {
    return pad.buttonA.isPressed || pad.buttonB.isPressed || pad.buttonX.isPressed ||
        pad.buttonY.isPressed || pad.leftShoulder.isPressed || pad.rightShoulder.isPressed ||
        pad.leftTrigger.isPressed || pad.rightTrigger.isPressed || pad.buttonMenu.isPressed ||
        pad.buttonOptions.isPressed || pad.rightThumbstickButton.isPressed ||
        fabsf(pad.leftThumbstick.xAxis.value) > 0.15f || fabsf(pad.leftThumbstick.yAxis.value) > 0.15f ||
        fabsf(pad.rightThumbstick.xAxis.value) > 0.15f || fabsf(pad.rightThumbstick.yAxis.value) > 0.15f ||
        pad.dpad.left.isPressed || pad.dpad.right.isPressed || pad.dpad.up.isPressed || pad.dpad.down.isPressed;
}

typedef NS_ENUM(NSInteger, ProtectorFaceShape) {
    ProtectorFaceDisc,  // combat moves
    ProtectorFaceDial,  // Transform: marked watch bezel around a glass well
    ProtectorFaceArc,   // alien wings and menu directions: segments of one dial
    ProtectorFacePill,  // contextual Confirm and Back
    ProtectorFaceTab,   // top-edge Pause, Interact and Menu
};
typedef NS_ENUM(NSInteger, ProtectorGlassKind) {
    ProtectorGlassGreen,  // Omnitrix glass: the primary action
    ProtectorGlassSmoke,  // dark glass: other moves and secondary actions
    ProtectorGlassSteel,  // lighter gunmetal well: wings, directions, Pause
};

static UIColor* ProtectorRGB(CGFloat red, CGFloat green, CGFloat blue) {
    return [UIColor colorWithRed:red green:green blue:blue alpha:1];
}
static NSArray* ProtectorCGColors(NSArray<UIColor*>* colors) {
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:colors.count];
    for (UIColor* color in colors) [result addObject:(__bridge id)color.CGColor];
    return result;
}
static NSArray* ProtectorBezelColors(void) {
    return ProtectorCGColors(@[ProtectorRGB(.76, .80, .82), ProtectorRGB(.42, .46, .49), ProtectorRGB(.15, .17, .19)]);
}
static NSArray<UIColor*>* ProtectorGlassColors(ProtectorGlassKind kind, BOOL held) {
    // Held is the same bright glass on every control, so a press reads at once.
    if (held) return @[ProtectorRGB(.24, .68, .13), ProtectorRGB(.44, .90, .24), ProtectorArtHeldGreen()];
    switch (kind) {
        case ProtectorGlassGreen:
            return @[ProtectorRGB(.03, .29, .07), ProtectorRGB(.10, .50, .12), ProtectorArtGreen()];
        case ProtectorGlassSteel:
            return @[ProtectorRGB(.16, .18, .20), ProtectorRGB(.24, .27, .29), ProtectorRGB(.36, .40, .42)];
        case ProtectorGlassSmoke:
            break;
    }
    return @[ProtectorRGB(.04, .06, .05), ProtectorRGB(.09, .12, .10), ProtectorRGB(.19, .25, .21)];
}

// Captions echo the game's condensed, forward-leaning lettering with system
// type: San Francisco condensed heavy, uppercase, a synthesized oblique and a
// cel-ink outline instead of a backing plate. Dynamic Type scales the start
// size; fitting never goes below 11 points.
static UIFont* ProtectorCaptionFont(void) {
    UIFont* base = [UIFont systemFontOfSize:13 weight:UIFontWeightHeavy width:UIFontWidthCondensed];
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:base];
}
static NSDictionary<NSAttributedStringKey, id>* ProtectorCaptionAttributes(UIFont* font, BOOL ink) {
    NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    NSMutableDictionary<NSAttributedStringKey, id>* attributes = [@{NSFontAttributeName:font,
        NSKernAttributeName:@0.4, NSObliquenessAttributeName:@0.16,
        NSParagraphStyleAttributeName:paragraph, NSForegroundColorAttributeName:UIColor.whiteColor} mutableCopy];
    if (ink) {
        // A stroke-only copy behind the fill leaves about 1.6pt of outer ink.
        attributes[NSStrokeColorAttributeName] = ProtectorArtInk();
        attributes[NSStrokeWidthAttributeName] = @(320.0 / font.pointSize);
    }
    return attributes;
}
static CGFloat ProtectorCaptionWidth(NSString* text, UIFont* font) {
    return ceil([[NSAttributedString alloc] initWithString:text
        attributes:ProtectorCaptionAttributes(font, NO)].size.width) + 3;
}
static UIFont* ProtectorFitCaption(NSString* text, CGFloat width, CGFloat height) {
    UIFont* preferred = ProtectorCaptionFont();
    CGFloat size = fmax(11, preferred.pointSize);
    UIFont* font = [preferred fontWithSize:size];
    while (size > 11 && (ProtectorCaptionWidth(text, font) > width || ceil(font.lineHeight) > height)) {
        size = fmax(11, size - .5);
        font = [preferred fontWithSize:size];
    }
    return font;
}
static UILabel* ProtectorCaptionLabel(UIView* parent) {
    UILabel* label = [[UILabel alloc] init];
    label.textAlignment = NSTextAlignmentCenter;
    label.userInteractionEnabled = NO;
    label.isAccessibilityElement = NO;
    [parent addSubview:label];
    return label;
}
static void ProtectorSetCaption(UILabel* fill, UILabel* ink, NSString* text, UIFont* font, CGRect frame) {
    fill.font = font;
    ink.font = font;
    fill.attributedText = [[NSAttributedString alloc] initWithString:text attributes:ProtectorCaptionAttributes(font, NO)];
    ink.attributedText = [[NSAttributedString alloc] initWithString:text attributes:ProtectorCaptionAttributes(font, YES)];
    for (UILabel* label in @[ink, fill]) {
        label.frame = frame;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = fmin(1, 11.0 / font.pointSize);
    }
}

static void ProtectorFitGradient(CAGradientLayer* layer, UIBezierPath* path) {
    const CGRect box = path ? CGPathGetPathBoundingBox(path.CGPath) : CGRectNull;
    layer.hidden = CGRectIsNull(box) || CGRectIsEmpty(box);
    if (layer.hidden) return;
    layer.frame = box;
    CAShapeLayer* mask = (CAShapeLayer*)layer.mask;
    mask.frame = layer.bounds;
    UIBezierPath* local = [path copy];
    [local applyTransform:CGAffineTransformMakeTranslation(-box.origin.x, -box.origin.y)];
    mask.path = local.CGPath;
}
static UIBezierPath* ProtectorArcPath(CGPoint centre, CGFloat inner, CGFloat outer, CGFloat angle, CGFloat sweep) {
    UIBezierPath* path = [UIBezierPath bezierPathWithArcCenter:centre radius:outer
        startAngle:angle - sweep endAngle:angle + sweep clockwise:YES];
    [path addArcWithCenter:centre radius:fmax(1, inner) startAngle:angle + sweep endAngle:angle - sweep clockwise:NO];
    [path closePath];
    return path;
}

// One painter for every control face: halo, outer ink, bezel, glass, rim,
// markers, specular arc, then the glyph's ink edge, fill and inner lines.
@interface ProtectorFaceLayers : NSObject
@property(nonatomic, weak) CALayer* host;
@property(nonatomic) CAShapeLayer* halo;
@property(nonatomic) CAShapeLayer* ink;
@property(nonatomic) CAGradientLayer* bezel;
@property(nonatomic) CAGradientLayer* glass;
@property(nonatomic) CAShapeLayer* rim;
@property(nonatomic) CAShapeLayer* notches;
@property(nonatomic) CAShapeLayer* specular;
@property(nonatomic) CAShapeLayer* glyphInk;
@property(nonatomic) CAGradientLayer* glyphFill;
@property(nonatomic) CAShapeLayer* glyphDetail;
@property(nonatomic) ProtectorGlassKind kind;
@property(nonatomic) CGFloat scale;
@property(nonatomic) BOOL held;
- (instancetype)initWithHost:(CALayer*)host;
- (void)paintFace:(UIBezierPath*)face glass:(UIBezierPath*)glass halo:(UIBezierPath*)halo
         specular:(UIBezierPath*)specular notches:(UIBezierPath*)notches;
- (void)paintGlyph:(ProtectorGlyph)glyph inRect:(CGRect)rect;
- (void)applyHeld:(BOOL)held;
@end

@implementation ProtectorFaceLayers
- (instancetype)initWithHost:(CALayer*)host {
    self = [super init];
    if (self) {
        _host = host;
        _kind = ProtectorGlassSmoke;
        _halo = [self shapeLayer];
        _ink = [self shapeLayer];
        _bezel = [self maskedGradient];
        _bezel.colors = ProtectorBezelColors();
        _bezel.locations = @[@0, @.45, @1];
        _glass = [self maskedGradient];
        _glass.type = kCAGradientLayerRadial;
        _glass.startPoint = CGPointMake(.5, .5);
        _glass.endPoint = CGPointMake(1, 1);
        _glass.locations = @[@0, @.6, @1];
        _rim = [self shapeLayer];
        _notches = [self shapeLayer];
        _notches.lineCap = kCALineCapButt;
        _specular = [self shapeLayer];
        _glyphInk = [self shapeLayer];
        _glyphFill = [self maskedGradient];
        _glyphDetail = [self shapeLayer];
        _halo.hidden = YES;
        for (CALayer* layer in @[_halo, _ink, _bezel, _glass, _rim, _notches, _specular,
                _glyphInk, _glyphFill, _glyphDetail])
            [host addSublayer:layer];
    }
    return self;
}
- (CAShapeLayer*)shapeLayer {
    CAShapeLayer* layer = [CAShapeLayer layer];
    layer.fillColor = UIColor.clearColor.CGColor;
    layer.lineJoin = kCALineJoinRound;
    layer.lineCap = kCALineCapRound;
    return layer;
}
- (CAGradientLayer*)maskedGradient {
    CAGradientLayer* layer = [CAGradientLayer layer];
    layer.mask = [CAShapeLayer layer];
    return layer;
}
- (void)setScale:(CGFloat)scale {
    if (_scale == scale) return;
    _scale = scale;
    for (CALayer* layer in @[_halo, _ink, _bezel, _bezel.mask, _glass, _glass.mask, _rim, _notches,
            _specular, _glyphInk, _glyphFill, _glyphFill.mask, _glyphDetail])
        layer.contentsScale = scale;
}
- (void)paintFace:(UIBezierPath*)face glass:(UIBezierPath*)glass halo:(UIBezierPath*)halo
         specular:(UIBezierPath*)specular notches:(UIBezierPath*)notches {
    const CGRect bounds = self.host.bounds;
    const CGFloat alpha = ProtectorMaterialOpacity();
    for (CALayer* layer in @[self.halo, self.ink, self.rim, self.notches, self.specular]) layer.frame = bounds;
    // Outer cel ink, the same weight at every size; the scene stays visible
    // through the face when the user lowers opacity.
    self.ink.path = face.CGPath;
    self.ink.strokeColor = ProtectorArtInk().CGColor;
    self.ink.lineWidth = 5;
    self.ink.opacity = (float)fmax(0.88, alpha);
    ProtectorFitGradient(self.bezel, face);
    self.bezel.opacity = (float)alpha;
    ProtectorFitGradient(self.glass, glass);
    self.rim.path = glass.CGPath;
    self.rim.lineWidth = 1;
    self.rim.opacity = (float)alpha;
    self.notches.path = notches.CGPath;
    self.notches.lineWidth = notches.lineWidth;
    self.notches.strokeColor = ProtectorArtGreen().CGColor;
    self.notches.opacity = (float)alpha;
    self.specular.path = specular.CGPath;
    self.specular.lineWidth = specular.lineWidth;
    self.specular.strokeColor = [UIColor colorWithWhite:1 alpha:.6].CGColor;
    self.specular.opacity = (float)alpha;
    self.halo.path = halo.CGPath;
    self.halo.strokeColor = ProtectorArtHalo().CGColor;
    self.halo.lineWidth = 3;
    self.halo.shadowColor = ProtectorArtHalo().CGColor;
    self.halo.shadowOffset = CGSizeZero;
    self.halo.shadowRadius = 5;
    self.halo.shadowOpacity = .9;
    CGPathRef glow = halo ? CGPathCreateCopyByStrokingPath(halo.CGPath, NULL, 3,
        kCGLineCapRound, kCGLineJoinRound, 4) : NULL;
    self.halo.shadowPath = glow;
    if (glow) CGPathRelease(glow);
    [self applyHeld:self.held];
}
- (void)paintGlyph:(ProtectorGlyph)glyph inRect:(CGRect)rect {
    UIBezierPath* path = CGRectIsEmpty(rect) ? nil : ProtectorGlyphPath(glyph, rect);
    self.glyphInk.hidden = self.glyphDetail.hidden = path == nil;
    if (!path) { self.glyphFill.hidden = YES; return; }
    for (CALayer* layer in @[self.glyphInk, self.glyphDetail]) layer.frame = self.host.bounds;
    const CGFloat edge = fmax(1.4, rect.size.width * .07);
    self.glyphInk.path = path.CGPath;
    self.glyphInk.lineWidth = edge * 2;
    self.glyphInk.fillColor = self.glyphInk.strokeColor = ProtectorArtInk().CGColor;
    ProtectorFitGradient(self.glyphFill, path);
    self.glyphFill.colors = ProtectorCGColors(ProtectorGlyphGradient(glyph));
    self.glyphDetail.path = ProtectorGlyphDetailPath(glyph, rect).CGPath;
    self.glyphDetail.lineWidth = fmax(1, rect.size.width * .045);
    self.glyphDetail.strokeColor = ProtectorArtInk().CGColor;
}
- (void)applyHeld:(BOOL)held {
    self.held = held;
    self.glass.colors = ProtectorCGColors(ProtectorGlassColors(self.kind, held));
    self.glass.opacity = held ? 1 : (float)ProtectorMaterialOpacity();
    UIColor* rim = held ? [UIColor colorWithRed:.86 green:1 blue:.62 alpha:.95]
        : self.kind == ProtectorGlassGreen ? [UIColor colorWithRed:.70 green:1 blue:.45 alpha:.85]
        : self.kind == ProtectorGlassSmoke ? [UIColor colorWithRed:.36 green:.80 blue:.22 alpha:.55]
        : [UIColor colorWithWhite:1 alpha:.18];
    self.rim.strokeColor = rim.CGColor;
    // The halo sits outside the face, where a covering thumb cannot hide it.
    self.halo.hidden = !held;
}
@end

@interface ProtectorActionButton : UIButton
@property(nonatomic) UIView* actionFace;
@property(nonatomic) UILabel* actionLabel;
@property(nonatomic) UILabel* actionInk;
@property(nonatomic) ProtectorFaceLayers* art;
@property(nonatomic, copy) NSString* actionTitle;
@property(nonatomic) ProtectorGlyph glyph;
@property(nonatomic) ProtectorFaceShape faceShape;
@property(nonatomic) CGPoint arcCenter;
@property(nonatomic) CGRect faceFrame;
@property(nonatomic) CGFloat baseTargetSize;
@property(nonatomic) CGFloat baseFaceSize;
@property(nonatomic) BOOL primaryAction;
@property(nonatomic) BOOL menuControl;
@property(nonatomic) BOOL actionHeld;
- (void)setActionTitle:(NSString*)title glyph:(ProtectorGlyph)glyph;
- (void)setActionTitle:(NSString*)title symbol:(NSString*)symbol;
- (void)setFace:(ProtectorFaceShape)shape glass:(ProtectorGlassKind)glass;
@end

@implementation ProtectorActionButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.baseTargetSize = 56;
        self.baseFaceSize = 42;
        self.arcCenter = CGPointMake(NAN, NAN);
        self.actionFace = [[UIView alloc] init];
        self.actionFace.userInteractionEnabled = NO;
        self.actionFace.isAccessibilityElement = NO;
        [self addSubview:self.actionFace];
        self.art = [[ProtectorFaceLayers alloc] initWithHost:self.actionFace.layer];
        self.actionInk = ProtectorCaptionLabel(self);
        self.actionLabel = ProtectorCaptionLabel(self);
        self.actionLabel.hidden = self.actionInk.hidden = YES;
    }
    return self;
}
- (void)setActionTitle:(NSString*)title glyph:(ProtectorGlyph)glyph {
    self.actionTitle = title;
    self.glyph = glyph;
    [self setNeedsLayout];
}
// Pause/resume callers in the lifecycle path keep their historical keys. Both
// resolve to authored glyphs; no system image is loaded.
- (void)setActionTitle:(NSString*)title symbol:(NSString*)symbol {
    [self setActionTitle:title glyph:[symbol isEqual:@"play.fill"] ? ProtectorGlyphResume : ProtectorGlyphPause];
}
- (void)setFace:(ProtectorFaceShape)shape glass:(ProtectorGlassKind)glass {
    self.faceShape = shape;
    self.art.kind = glass;
    [self setNeedsLayout];
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.art applyHeld:highlighted || self.actionHeld];
    [CATransaction commit];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    if (width <= 0 || height <= 0) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.actionFace.frame = self.bounds;
    self.art.scale = self.traitCollection.displayScale > 0 ? self.traitCollection.displayScale : 2;
    const CGFloat scale = fmin(width, height) / self.baseTargetSize;
    NSString* caption = self.actionTitle.localizedUppercaseString;
    const BOOL labels = caption.length > 0 && (self.menuControl ||
        [NSUserDefaults.standardUserDefaults boolForKey:ProtectorTouchLabelsKey]);
    self.actionLabel.hidden = self.actionInk.hidden = !labels;
    switch (self.faceShape) {
        case ProtectorFaceArc: [self layoutArc:scale]; break;
        case ProtectorFacePill: [self layoutPill:caption labels:labels]; break;
        case ProtectorFaceTab: [self layoutTab:caption labels:labels]; break;
        case ProtectorFaceDisc:
        case ProtectorFaceDial: [self layoutDisc:caption labels:labels scale:scale]; break;
    }
    [self.art applyHeld:self.actionHeld || self.highlighted];
    [CATransaction commit];
}
- (void)layoutDisc:(NSString*)caption labels:(BOOL)labels scale:(CGFloat)scale {
    const CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    UIFont* font = labels ? ProtectorFitCaption(caption, width + 6, height * .4) : nil;
    const CGFloat captionHeight = labels ? ceil(font.lineHeight) : 0;
    CGFloat diameter = self.baseFaceSize * scale;
    if (labels) diameter = fmin(diameter, height - captionHeight - 2);
    diameter = fmax(22, fmin(diameter, fmin(width, height) - 4));
    const CGFloat top = labels ? (height - diameter - 2 - captionHeight) / 2 : (height - diameter) / 2;
    const CGRect face = CGRectMake((width - diameter) / 2, top, diameter, diameter);
    const BOOL dial = self.faceShape == ProtectorFaceDial;
    const CGFloat bezel = fmax(3, diameter * (dial ? .13 : .085));
    const CGRect well = CGRectInset(face, bezel, bezel);
    const CGPoint centre = CGPointMake(CGRectGetMidX(face), CGRectGetMidY(face));
    UIBezierPath* specular = [UIBezierPath bezierPathWithArcCenter:centre radius:well.size.width * .36
        startAngle:M_PI * 1.12 endAngle:M_PI * 1.38 clockwise:YES];
    specular.lineWidth = fmax(1.5, diameter * .045);
    UIBezierPath* notches = nil;
    if (dial) {
        // Four green markers on the bezel, as on the game's watch HUD.
        notches = [UIBezierPath bezierPath];
        for (int i = 0; i < 4; ++i) {
            const CGFloat angle = M_PI_4 + i * M_PI_2;
            [notches appendPath:[UIBezierPath bezierPathWithArcCenter:centre radius:diameter / 2 - bezel / 2
                startAngle:angle - .17 endAngle:angle + .17 clockwise:YES]];
        }
        notches.lineWidth = bezel * .6;
    }
    self.faceFrame = face;
    [self.art paintFace:[UIBezierPath bezierPathWithOvalInRect:face]
        glass:[UIBezierPath bezierPathWithOvalInRect:well]
        halo:[UIBezierPath bezierPathWithOvalInRect:CGRectInset(face, -5.5, -5.5)]
        specular:specular notches:notches];
    const CGFloat glyph = well.size.width * (dial ? .82 : .66);
    [self.art paintGlyph:self.glyph inRect:CGRectMake(centre.x - glyph / 2, centre.y - glyph / 2, glyph, glyph)];
    if (labels) ProtectorSetCaption(self.actionLabel, self.actionInk, caption, font,
        CGRectMake(-3, CGRectGetMaxY(face) + 2, width + 6, captionHeight));
}
- (void)layoutPill:(NSString*)caption labels:(BOOL)labels {
    const CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    CGFloat faceHeight = fmin(height - 6, fmax(40, height * .74));
    CGFloat glyph = faceHeight * .48;
    UIFont* font = nil;
    CGFloat captionWidth = 0;
    BOOL stacked = NO;
    if (labels) {
        // Prefer one row, glyph then caption. A narrow target stacks the
        // caption under the glyph rather than shrinking it below 11 points.
        const CGFloat available = width - 6 - faceHeight * .62 - glyph - 4;
        font = ProtectorFitCaption(caption, available, faceHeight - 10);
        captionWidth = ProtectorCaptionWidth(caption, font);
        stacked = captionWidth > available;
        if (stacked) {
            font = ProtectorFitCaption(caption, width - 10, height * .42);
            captionWidth = ProtectorCaptionWidth(caption, font);
        }
    }
    const CGFloat captionHeight = labels ? ceil(font.lineHeight) : 0;
    CGRect face = CGRectZero, glyphRect = CGRectZero, captionRect = CGRectZero;
    if (self.glyph == ProtectorGlyphNone && labels) {
        // Optional map actions use words, not invented glyphs. Keep the same
        // bezel/glass recipe and caption floor without reserving an empty icon.
        font = ProtectorFitCaption(caption, width - 20, faceHeight - 10);
        const CGFloat textHeight = ceil(font.lineHeight);
        face = CGRectMake(2, (height - faceHeight) / 2, width - 4, faceHeight);
        captionRect = CGRectMake(8, (height - textHeight) / 2, width - 16, textHeight);
        stacked = NO;
    } else if (stacked) {
        glyph = fmax(14, fmin(width * .38, height - captionHeight - 20));
        faceHeight = fmin(height - 4, glyph + captionHeight + 15);
        face = CGRectMake(2, (height - faceHeight) / 2, width - 4, faceHeight);
        glyphRect = CGRectMake((width - glyph) / 2, face.origin.y + 7, glyph, glyph);
        captionRect = CGRectMake(3, CGRectGetMaxY(glyphRect) + 1, width - 6, captionHeight);
    } else {
        const CGFloat content = labels ? glyph + 4 + captionWidth : glyph;
        const CGFloat faceWidth = fmin(width - 4, labels ? content + faceHeight * .62 : faceHeight);
        face = CGRectMake((width - faceWidth) / 2, (height - faceHeight) / 2, faceWidth, faceHeight);
        glyphRect = CGRectMake(CGRectGetMidX(face) - content / 2, CGRectGetMidY(face) - glyph / 2, glyph, glyph);
        if (labels) captionRect = CGRectMake(CGRectGetMaxX(glyphRect) + 4,
            CGRectGetMidY(face) - captionHeight / 2, captionWidth, captionHeight);
    }
    const CGFloat radius = fmin(stacked ? 16 : faceHeight / 2, face.size.height / 2);
    const CGRect well = CGRectInset(face, 3, 3);
    UIBezierPath* specular = [UIBezierPath bezierPath];
    [specular moveToPoint:CGPointMake(well.origin.x + radius * .6, well.origin.y + 3)];
    [specular addLineToPoint:CGPointMake(well.origin.x + well.size.width * .45, well.origin.y + 3)];
    specular.lineWidth = 1.6;
    self.faceFrame = face;
    [self.art paintFace:[UIBezierPath bezierPathWithRoundedRect:face cornerRadius:radius]
        glass:[UIBezierPath bezierPathWithRoundedRect:well cornerRadius:fmax(2, radius - 3)]
        halo:[UIBezierPath bezierPathWithRoundedRect:CGRectInset(face, -5.5, -5.5) cornerRadius:radius + 5.5]
        specular:specular notches:nil];
    [self.art paintGlyph:self.glyph inRect:glyphRect];
    if (labels) ProtectorSetCaption(self.actionLabel, self.actionInk, caption, font, captionRect);
}
- (void)layoutTab:(NSString*)caption labels:(BOOL)labels {
    const CGFloat width = self.bounds.size.width;
    const CGRect face = CGRectInset(self.bounds, 3, 3);
    UIFont* font = labels ? ProtectorFitCaption(caption, face.size.width + 2, face.size.height * .42) : nil;
    const CGFloat captionHeight = labels ? ceil(font.lineHeight) : 0;
    const CGFloat glyph = labels ? fmax(12, fmin(face.size.width * .5, face.size.height - captionHeight - 7))
        : fmin(face.size.width, face.size.height) * .52;
    const CGFloat top = CGRectGetMidY(face) - (glyph + captionHeight) / 2;
    const CGRect glyphRect = CGRectMake(CGRectGetMidX(face) - glyph / 2, top, glyph, glyph);
    self.faceFrame = face;
    [self.art paintFace:[UIBezierPath bezierPathWithRoundedRect:face cornerRadius:9]
        glass:[UIBezierPath bezierPathWithRoundedRect:CGRectInset(face, 2.5, 2.5) cornerRadius:6.5]
        halo:[UIBezierPath bezierPathWithRoundedRect:CGRectInset(face, -5, -5) cornerRadius:14]
        specular:nil notches:nil];
    [self.art paintGlyph:self.glyph inRect:glyphRect];
    if (labels) ProtectorSetCaption(self.actionLabel, self.actionInk, caption, font,
        CGRectMake(-4, CGRectGetMaxY(glyphRect), width + 8, captionHeight));
}
- (void)layoutArc:(CGFloat)scale {
    const CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    const CGPoint centre = self.arcCenter;
    const CGFloat dx = width / 2 - centre.x, dy = height / 2 - centre.y;
    const CGFloat distance = hypot(dx, dy);
    if (!isfinite(distance) || distance < 1) {
        self.faceFrame = CGRectZero;
        [self.art paintFace:nil glass:nil halo:nil specular:nil notches:nil];
        [self.art paintGlyph:ProtectorGlyphNone inRect:CGRectZero];
        return;
    }
    // Inner and outer radii and the sweep are clipped to this button's own
    // rectangle, so the drawn segment is exactly a tappable one.
    const CGFloat angle = atan2(dy, dx);
    const CGFloat radial = fabs(cos(angle)) * width / 2 + fabs(sin(angle)) * height / 2;
    const CGFloat tangent = fabs(sin(angle)) * width / 2 + fabs(cos(angle)) * height / 2;
    const CGFloat inner = distance - radial + 3;
    const CGFloat thickness = fmin(2 * radial - 8, 24 * fmax(1, scale));
    const CGFloat outer = inner + thickness;
    const CGFloat sweep = fmin(.52, asin(fmin(.95, (tangent - 3) / outer)));
    UIBezierPath* face = ProtectorArcPath(centre, inner, outer, angle, sweep);
    self.faceFrame = CGPathGetPathBoundingBox(face.CGPath);
    [self.art paintFace:face glass:ProtectorArcPath(centre, inner + 2.5, outer - 2.5, angle, sweep - 2.5 / outer)
        halo:ProtectorArcPath(centre, inner - 5.5, outer + 5.5, angle, sweep + 5.5 / outer)
        specular:nil notches:nil];
    const CGFloat glyph = fmin(thickness * .66, 22 * fmax(1, scale));
    const CGFloat middle = (inner + outer) / 2;
    [self.art paintGlyph:self.glyph inRect:CGRectMake(centre.x + cos(angle) * middle - glyph / 2,
        centre.y + sin(angle) * middle - glyph / 2, glyph, glyph)];
}
- (BOOL)accessibilityActivate {
    if (!self.enabled) return NO;
    [self sendActionsForControlEvents:UIControlEventTouchDown];
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
    return YES;
}
@end

static void ProtectorSetButtonHeld(UIButton* button, BOOL held) {
    if ([button isKindOfClass:ProtectorActionButton.class]) {
        ProtectorActionButton* action = (ProtectorActionButton*)button;
        action.actionHeld = held;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [action.art applyHeld:held];
        [CATransaction commit];
        action.accessibilityValue = held ? @"Held" : nil;
    }
}

// A visible controller continuation hint for source instructions while touch
// controls are hidden. It is never an input target: the controller's own
// neutral-gated press still reaches the game unchanged.
@interface ProtectorContinueCue : UIView
@property(nonatomic) UIView* plate;
@property(nonatomic) ProtectorFaceLayers* art;
@property(nonatomic) ProtectorFaceLayers* buttonArt;
@property(nonatomic) UIImageView* controllerGlyph;
@property(nonatomic) UILabel* caption;
@property(nonatomic) UILabel* captionInk;
@property(nonatomic) BOOL skipsCinematic;
@property(nonatomic) BOOL unlocksMove;
@property(nonatomic) BOOL acknowledgesDialog;
@property(nonatomic) BOOL endsGame;
- (void)showForController:(GCController*)controller;
@end

@implementation ProtectorContinueCue
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.hidden = YES;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitStaticText;
        self.accessibilityIdentifier = @"controller-continue-cue";
        self.plate = [[UIView alloc] init];
        self.plate.userInteractionEnabled = NO;
        [self addSubview:self.plate];
        self.art = [[ProtectorFaceLayers alloc] initWithHost:self.plate.layer];
        self.art.kind = ProtectorGlassSmoke;
        self.buttonArt = [[ProtectorFaceLayers alloc] initWithHost:self.plate.layer];
        self.buttonArt.kind = ProtectorGlassGreen;
        self.controllerGlyph = [[UIImageView alloc] init];
        self.controllerGlyph.contentMode = UIViewContentModeScaleAspectFit;
        self.controllerGlyph.tintColor = UIColor.whiteColor;
        self.controllerGlyph.isAccessibilityElement = NO;
        [self addSubview:self.controllerGlyph];
        self.captionInk = ProtectorCaptionLabel(self);
        self.caption = ProtectorCaptionLabel(self);
    }
    return self;
}
- (void)showForController:(GCController*)controller {
    GCControllerButtonInput* primary = controller.extendedGamepad.buttonA;
    if (!primary) { self.hidden = YES; return; }
    // The connected controller names its own bottom face button (A, cross and
    // so on). Without a symbol, the authored face-button diagram stands in.
    NSString* symbol = primary.sfSymbolsName;
    UIImage* image = nil;
    if (symbol.length) {
        image = [UIImage systemImageNamed:[symbol stringByAppendingString:@".fill"]];
        if (!image) image = [UIImage systemImageNamed:symbol];
    }
    self.controllerGlyph.image = image;
    self.controllerGlyph.hidden = image == nil;
    NSString* name = primary.localizedName;
    self.accessibilityLabel = self.endsGame
        ? (name.length ? [NSString stringWithFormat:@"Controller: press %@ to end the game.", name]
                       : @"Controller: press the bottom face button to end the game.")
        : self.unlocksMove
        ? (name.length ? [NSString stringWithFormat:@"Controller: press %@ to unlock the move.", name]
                       : @"Controller: press the bottom face button to unlock the move.")
        : self.skipsCinematic
        ? (name.length ? [NSString stringWithFormat:@"Controller: press %@ to skip the cinematic.", name]
                       : @"Controller: press the bottom face button to skip the cinematic.")
        : self.acknowledgesDialog
        ? (name.length ? [NSString stringWithFormat:@"Controller: press %@ to continue.", name]
                       : @"Controller: press the bottom face button to continue.")
        : (name.length ? [NSString stringWithFormat:@"Controller: press %@ to confirm.", name]
                       : @"Controller: press the bottom face button to confirm.");
    self.hidden = NO;
    [self setNeedsLayout];
}
- (CGSize)sizeThatFits:(CGSize)size {
    if (self.unlocksMove) return CGSizeMake(fmax(88,size.width),fmax(64,size.height));
    const CGFloat height = fmin(52, fmax(44, size.height * .72));
    NSString* text = (self.endsGame ? @"End Game" : self.acknowledgesDialog ? @"Continue" : self.skipsCinematic ? @"Skip" : @"Confirm").localizedUppercaseString;
    UIFont* font = ProtectorFitCaption(text, 240, height - 14);
    return CGSizeMake(ceil(height + 6 + ProtectorCaptionWidth(text, font) + height * .45), height);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    if (width <= 0 || height <= 0) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.plate.frame = self.bounds;
    self.art.scale = self.buttonArt.scale =
        self.traitCollection.displayScale > 0 ? self.traitCollection.displayScale : 2;
    const CGRect face = CGRectInset(self.bounds, 2.5, 2.5);
    const CGFloat radius = self.unlocksMove ? 16 : face.size.height / 2;
    [self.art paintFace:[UIBezierPath bezierPathWithRoundedRect:face cornerRadius:radius]
        glass:[UIBezierPath bezierPathWithRoundedRect:CGRectInset(face, 3, 3) cornerRadius:radius - 3]
        halo:nil specular:nil notches:nil];
    [self.art paintGlyph:ProtectorGlyphNone inRect:CGRectZero];
    const CGFloat disc = self.unlocksMove ? fmin(34,face.size.height*.5) : face.size.height - 8;
    const CGRect button = CGRectMake(self.unlocksMove ? CGRectGetMidX(face)-disc/2 : face.origin.x+4,
        face.origin.y+4,disc,disc);
    const CGRect well = CGRectInset(button, 2.5, 2.5);
    UIBezierPath* specular = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(well), CGRectGetMidY(well))
        radius:well.size.width * .36 startAngle:M_PI * 1.12 endAngle:M_PI * 1.38 clockwise:YES];
    specular.lineWidth = 1.5;
    [self.buttonArt paintFace:[UIBezierPath bezierPathWithOvalInRect:button]
        glass:[UIBezierPath bezierPathWithOvalInRect:well] halo:nil specular:specular notches:nil];
    const CGFloat glyph = well.size.width * .78;
    const CGRect glyphRect = CGRectMake(CGRectGetMidX(well) - glyph / 2, CGRectGetMidY(well) - glyph / 2, glyph, glyph);
    [self.buttonArt paintGlyph:self.controllerGlyph.hidden ? ProtectorGlyphBottomFaceButton : ProtectorGlyphNone
        inRect:glyphRect];
    self.controllerGlyph.frame = glyphRect;
    self.controllerGlyph.preferredSymbolConfiguration = [UIImageSymbolConfiguration
        configurationWithPointSize:glyph * .82 weight:UIImageSymbolWeightBold];
    NSString* text = (self.endsGame ? @"End Game" : self.acknowledgesDialog ? @"Continue" : self.unlocksMove ? @"Unlock Move" : self.skipsCinematic ? @"Skip" : @"Confirm").localizedUppercaseString;
    const CGFloat left = self.unlocksMove ? face.origin.x+4 : CGRectGetMaxX(button)+6;
    const CGFloat available = self.unlocksMove ? face.size.width-8 : CGRectGetMaxX(face)-left-radius*.4;
    UIFont* font = ProtectorFitCaption(text,available,self.unlocksMove ? face.size.height-disc-10 : face.size.height-12);
    const CGFloat captionHeight = ceil(font.lineHeight);
    ProtectorSetCaption(self.caption, self.captionInk, text, font,
        CGRectMake(left,self.unlocksMove ? CGRectGetMaxY(face)-captionHeight-4 : CGRectGetMidY(face)-captionHeight/2,
            available,captionHeight));
    [self.art applyHeld:NO];
    [self.buttonArt applyHeld:NO];
    [CATransaction commit];
}
@end

// Source-owned boss cue, not another input control. It deliberately passes all
// touches through to the pointer view and never synthesizes an input or result.
@interface ProtectorQTECue : UIView
@property(nonatomic) ProtectorFaceLayers* art;
@property(nonatomic) UILabel* caption;
@property(nonatomic) UILabel* captionInk;
@property(nonatomic, copy) NSString* instruction;
// The connected controller's own name for the button bound to Transform
// (View, Create, −, ...). Nil falls back to the generic wording.
@property(nonatomic, copy) NSString* transformButtonName;
- (void)showPrompts:(unsigned)prompts controller:(BOOL)controller;
@end

@implementation ProtectorQTECue
- (instancetype)initWithFrame:(CGRect)frame {
    self=[super initWithFrame:frame];
    if(self) {
        self.userInteractionEnabled=NO;self.hidden=YES;
        self.isAccessibilityElement=YES;self.accessibilityTraits=UIAccessibilityTraitStaticText;
        self.accessibilityIdentifier=@"native-qte-instruction";
        self.art=[[ProtectorFaceLayers alloc] initWithHost:self.layer];self.art.kind=ProtectorGlassSmoke;
        self.captionInk=ProtectorCaptionLabel(self);self.caption=ProtectorCaptionLabel(self);
        self.caption.numberOfLines=self.captionInk.numberOfLines=2;
    }
    return self;
}
- (void)showPrompts:(unsigned)prompts controller:(BOOL)controller {
    NSString* text=@(protector_qte_instruction(prompts,controller,NO));
    if(controller && self.transformButtonName.length && [text hasPrefix:@"Transform: "])
        text=[@"Transform: " stringByAppendingString:self.transformButtonName];
    if([self.instruction isEqual:text] && self.hidden==!text.length)return;
    self.instruction=text;self.accessibilityLabel=text;self.hidden=!text.length;
    [self setNeedsLayout];[self.superview setNeedsLayout];
}
- (CGSize)sizeThatFits:(CGSize)size {
    NSString* text=self.instruction ? self.instruction.localizedUppercaseString : @"";
    UIFont* font=ProtectorCaptionFont();
    const CGFloat width=fmax(1,size.width-28);
    CGRect bounds=[text boundingRectWithSize:CGSizeMake(width,CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
        attributes:ProtectorCaptionAttributes(font,NO) context:nil];
    return CGSizeMake(fmin(size.width,ceil(bounds.size.width)+28),
        fmax(40,fmin(ceil(bounds.size.height),ceil(font.lineHeight)*2)+20));
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if(self.bounds.size.width<=0 || self.bounds.size.height<=0)return;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.art.scale=self.traitCollection.displayScale>0?self.traitCollection.displayScale:2;
    CGRect face=CGRectInset(self.bounds,2.5,2.5);
    [self.art paintFace:[UIBezierPath bezierPathWithRoundedRect:face cornerRadius:12]
        glass:[UIBezierPath bezierPathWithRoundedRect:CGRectInset(face,3,3) cornerRadius:9]
        halo:nil specular:nil notches:nil];
    [self.art paintGlyph:ProtectorGlyphNone inRect:CGRectZero];[self.art applyHeld:NO];
    ProtectorSetCaption(self.caption,self.captionInk,self.instruction ? self.instruction.localizedUppercaseString : @"",
        ProtectorCaptionFont(),CGRectInset(self.bounds,14,10));
    [CATransaction commit];
}
@end

@interface ProtectorPointerView : MTKView
@property(nonatomic) UITouch* pointerTouch;
@property(nonatomic) BOOL widescreen;
@property(nonatomic) float presentationAspect;
@property(nonatomic) BOOL qtePointer;
@property(nonatomic) BOOL pointerUsesQTEDomain;
// Called on every touch-down, so a controller player who picks up the phone gets touch controls back.
@property(nonatomic, copy) void (^touchHandler)(void);
- (void)cancelPointer;
@end

@implementation ProtectorPointerView
- (void)publishPointer {
    if (!self.pointerTouch) return;
    const CGPoint point = [self.pointerTouch locationInView:self];
    float x = 0, y = 0;
    const float aspect = self.presentationAspect > 0 ? self.presentationAspect : 4.0f / 3.0f;
    const auto map=self.pointerUsesQTEDomain?protector_live_input_map_qte_pointer_for_aspect:
        protector_live_input_map_pointer_for_aspect;
    if (map((float)point.x, (float)point.y,
            (float)self.bounds.size.width, (float)self.bounds.size.height, aspect, &x, &y))
        protector_live_input_pointer(true, x, y);
    else protector_live_input_clear_pointer();
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if (self.touchHandler) self.touchHandler();
    if (!self.pointerTouch) {
        self.pointerTouch = touches.anyObject;
        self.pointerUsesQTEDomain=self.qtePointer;
    }
    [self publishPointer];
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)touches; (void)event; [self publishPointer];
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if (![touches containsObject:self.pointerTouch]) return;
    [self publishPointer];
    self.pointerTouch = nil;
    self.pointerUsesQTEDomain=NO;
    protector_live_input_pointer(false, 0, 0);
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)touches; (void)event; [self cancelPointer];
}
- (void)cancelPointer {
    self.pointerTouch = nil;
    self.pointerUsesQTEDomain=NO;
    protector_live_input_clear_pointer();
}
@end

@interface ProtectorStick : UIControl
@property(nonatomic) CGPoint value;
@property(nonatomic) UIView* thumb;
@property(nonatomic) ProtectorFaceLayers* puck;
@property(nonatomic) CAShapeLayer* ringInk;
@property(nonatomic) CAGradientLayer* ringMetal;
@property(nonatomic) CAShapeLayer* ringTicks;
@property(nonatomic) CAShapeLayer* heading;
@property(nonatomic) UITouch* activeTouch;
@property(nonatomic) BOOL rotatesCharacter;
@property(nonatomic) UILabel* caption;
@property(nonatomic) UILabel* captionInk;
- (void)reset;
@end

@implementation ProtectorStick
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        // A watch-bezel ring with an open centre, so the scene stays visible
        // behind the stick. Only the ring and a green-glass puck are drawn.
        self.ringInk = [CAShapeLayer layer];
        self.ringMetal = [CAGradientLayer layer];
        self.ringMetal.mask = [CAShapeLayer layer];
        self.ringMetal.colors = ProtectorBezelColors();
        self.ringMetal.locations = @[@0, @.45, @1];
        self.ringTicks = [CAShapeLayer layer];
        self.heading = [CAShapeLayer layer];
        for (CAShapeLayer* layer in @[self.ringInk, self.ringMetal.mask, self.ringTicks, self.heading]) {
            layer.fillColor = UIColor.clearColor.CGColor;
            layer.lineCap = kCALineCapRound;
        }
        [self.layer addSublayer:self.ringInk];
        [self.layer addSublayer:self.ringMetal];
        [self.layer addSublayer:self.ringTicks];
        [self.layer addSublayer:self.heading];
        self.heading.hidden = YES;
        self.thumb = [[UIView alloc] init];
        self.thumb.userInteractionEnabled = NO;
        [self addSubview:self.thumb];
        self.puck = [[ProtectorFaceLayers alloc] initWithHost:self.thumb.layer];
        self.puck.kind = ProtectorGlassGreen;
        self.accessibilityLabel = @"Move";
        self.isAccessibilityElement = YES;
        self.accessibilityHint = @"Drag in any direction. Lift to stop.";
        self.accessibilityIdentifier = @"game-move";
        self.captionInk = ProtectorCaptionLabel(self);
        self.caption = ProtectorCaptionLabel(self);
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat size = CGRectGetWidth(self.bounds);
    if (size <= 0) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    const CGFloat displayScale = self.traitCollection.displayScale > 0 ? self.traitCollection.displayScale : 2;
    const CGFloat alpha = ProtectorMaterialOpacity();
    const BOOL active = self.activeTouch != nil;
    const CGPoint middle = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    const CGFloat band = fmax(6, size * .065);
    const CGFloat ring = size * .42 - band / 2;
    UIBezierPath* circle = [UIBezierPath bezierPathWithArcCenter:middle radius:ring
        startAngle:0 endAngle:2 * M_PI clockwise:YES];
    CAShapeLayer* metalMask = (CAShapeLayer*)self.ringMetal.mask;
    for (CALayer* layer in @[self.ringInk, self.ringMetal, metalMask, self.ringTicks, self.heading]) {
        layer.frame = self.bounds;
        layer.contentsScale = displayScale;
    }
    // Quieter at rest; full strength while the thumb is down.
    const CGFloat rest = active ? 1 : .72;
    self.ringInk.path = circle.CGPath;
    self.ringInk.lineWidth = band + 5;
    self.ringInk.strokeColor = ProtectorArtInk().CGColor;
    self.ringInk.opacity = (float)(fmax(0.88, alpha) * rest);
    metalMask.path = circle.CGPath;
    metalMask.lineWidth = band;
    metalMask.strokeColor = UIColor.blackColor.CGColor;
    self.ringMetal.opacity = (float)(alpha * rest);
    UIBezierPath* ticks = [UIBezierPath bezierPath];
    for (int i = 0; i < 8; ++i) {
        const CGFloat angle = i * M_PI_4, near = ring - band / 2 + 1, far = ring + band / 2 - 1;
        [ticks moveToPoint:CGPointMake(middle.x + cos(angle) * near, middle.y + sin(angle) * near)];
        [ticks addLineToPoint:CGPointMake(middle.x + cos(angle) * far, middle.y + sin(angle) * far)];
    }
    self.ringTicks.path = ticks.CGPath;
    self.ringTicks.lineWidth = 1.5;
    self.ringTicks.strokeColor = ProtectorArtInk().CGColor;
    self.ringTicks.opacity = self.ringInk.opacity;
    // The heading lights the ring where the thumb pushes, beyond the thumb.
    const CGFloat push = fmin(1, hypot(self.value.x, self.value.y));
    self.heading.hidden = !active || push < .12;
    if (!self.heading.hidden) {
        const CGFloat angle = atan2(-self.value.y, self.value.x), spread = .22 + .3 * push;
        self.heading.path = [UIBezierPath bezierPathWithArcCenter:middle radius:ring
            startAngle:angle - spread endAngle:angle + spread clockwise:YES].CGPath;
        self.heading.lineWidth = band + 1;
        self.heading.strokeColor = ProtectorArtHalo().CGColor;
        self.heading.shadowColor = ProtectorArtHalo().CGColor;
        self.heading.shadowOffset = CGSizeZero;
        self.heading.shadowRadius = 5;
        self.heading.shadowOpacity = .85;
    }
    const CGFloat handle = fmin(40, fmax(30, size * .29));
    self.thumb.bounds = CGRectMake(0, 0, handle, handle);
    const CGRect face = CGRectInset(self.thumb.bounds, 2.5, 2.5);
    const CGRect well = CGRectInset(face, 3, 3);
    UIBezierPath* specular = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(well), CGRectGetMidY(well))
        radius:well.size.width * .34 startAngle:M_PI * 1.12 endAngle:M_PI * 1.38 clockwise:YES];
    specular.lineWidth = 1.6;
    self.puck.scale = displayScale;
    [self.puck paintFace:[UIBezierPath bezierPathWithOvalInRect:face]
        glass:[UIBezierPath bezierPathWithOvalInRect:well]
        halo:[UIBezierPath bezierPathWithOvalInRect:CGRectInset(face, -5, -5)] specular:specular notches:nil];
    [self.puck paintGlyph:ProtectorGlyphNone inRect:CGRectZero];
    [self.puck applyHeld:active];
    const CGFloat radius = CGRectGetWidth(self.bounds) * 0.32;
    self.thumb.center = CGPointMake(CGRectGetMidX(self.bounds) + self.value.x * radius,
        CGRectGetMidY(self.bounds) - self.value.y * radius);
    self.caption.hidden=self.captionInk.hidden=!self.rotatesCharacter;
    if (self.rotatesCharacter) {
        NSString* text=@"Rotate".localizedUppercaseString;
        UIFont* font=ProtectorFitCaption(text,size-12,22);
        const CGFloat captionHeight=ceil(font.lineHeight);
        ProtectorSetCaption(self.caption,self.captionInk,text,font,
            CGRectMake(6,size-captionHeight,size-12,captionHeight));
    }
    [CATransaction commit];
}
- (void)updateTouch:(UITouch*)touch {
    CGPoint position = [touch locationInView:self];
    CGFloat x = (position.x - CGRectGetMidX(self.bounds)) / (self.bounds.size.width * 0.32);
    CGFloat y = (CGRectGetMidY(self.bounds) - position.y) / (self.bounds.size.height * 0.32);
    const CGFloat length = hypot(x, y);
    if (length > 1) { x /= length; y /= length; }
    self.value = CGPointMake(x, y);
    [self setNeedsLayout];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if (!self.activeTouch) self.activeTouch = touches.anyObject;
    [self updateTouch:self.activeTouch];
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    if ([touches containsObject:self.activeTouch]) [self updateTouch:self.activeTouch];
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)touches; (void)event; [self reset];
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)touches; (void)event; [self reset];
}
- (void)reset {
    self.activeTouch = nil;
    self.value = CGPointZero;
    [self setNeedsLayout];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
@end

@interface ProtectorInteractiveController : UIViewController <MTKViewDelegate, UIAdaptivePresentationControllerDelegate> {
    ProtectorMenuInput _menuInput;
    bool _observedStartupScreen;
    ProtectorPresentationPacing _pacing;
}
@property(nonatomic) BOOL hasModelCandidate;
@property(nonatomic) NSURL* contentRoot;
@property(nonatomic) ProtectorPointerView* gameView;
@property(nonatomic) ProtectorGameSession* session;
@property(nonatomic) ProtectorStick* stick;
@property(nonatomic) NSMutableArray<UIButton*>* buttons;
@property(nonatomic) UILabel* status;
@property(nonatomic) UIScrollView* statusScroll;
@property(nonatomic) BOOL saveWarningVisible;
@property(nonatomic) unsigned saveFailureMask;
@property(nonatomic) UIButton* pauseButton;
@property(nonatomic) UIButton* openingLogoSkip;
@property(nonatomic) UIButton* storySkipButton;
@property(nonatomic) UIButton* shakeButton;
@property(nonatomic) uint32_t held;
@property(nonatomic) BOOL shakeHeld;
@property(nonatomic) BOOL controllerAimActive;
@property(nonatomic) BOOL manuallyPaused;
@property(nonatomic) CFTimeInterval scaleTrialStart;
@property(nonatomic) CFTimeInterval resignedAt;
@property(nonatomic) BOOL enteredBackground;
@property(nonatomic, copy) NSString* pauseReason;
@property(nonatomic) CFTimeInterval lastHapticTime;
@property(nonatomic) BOOL touchWokeControls;
@property(nonatomic) NSMutableSet<UIButton*>* pressedButtons;
@property(nonatomic) UIImpactFeedbackGenerator* buttonHaptics;
@property(nonatomic) GCController* activeController;
@property(nonatomic) BOOL controllerMenuHeld;
@property(nonatomic) BOOL controllerNeedsNeutral;
@property(nonatomic) BOOL menuPulsePending;
@property(nonatomic) BOOL cameraPulsePending;
@property(nonatomic) BOOL clearingControls;
@property(nonatomic) NSTimer* diagnosticTimer;
@property(nonatomic) CADisplayLink* controllerDisplayLink;
@property(nonatomic) ProtectorControllerSnapshotQA* controllerQA;
@property(nonatomic) ProtectorControlsGuideController* sourceControlsGuide;
@property(nonatomic) BOOL sourceGuideReturning;
@property(nonatomic) BOOL sourceGuideContinuePending;
@property(nonatomic) uint64_t sourceGuideNeutralStart;
@property(nonatomic) uint64_t sourceGuideContinueSample;
@property(nonatomic) CFTimeInterval sourceGuideReturnDeadline;
@property(nonatomic) NSUInteger controllerTickCount;
@property(nonatomic) ProtectorUIContext controlContext;
@property(nonatomic) uint32_t mapActions;
@property(nonatomic) ProtectorContinueCue* continueCue;
@property(nonatomic) ProtectorQTECue* qteCue;
@property(nonatomic) CGRect displayedQTETargetRect;
@end

@implementation ProtectorInteractiveController
- (UIButton*)gameButton:(NSString*)title glyph:(ProtectorGlyph)glyph label:(NSString*)label mask:(uint32_t)mask {
    ProtectorActionButton* button = [[ProtectorActionButton alloc] initWithFrame:CGRectZero];
    button.tag = mask;
    ProtectorSetButtonHeld(button, NO);
    [button setActionTitle:title glyph:glyph];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.accessibilityLabel = label;
    button.accessibilityIdentifier = [NSString stringWithFormat:@"game-action-%u", mask];
    [button addTarget:self action:@selector(buttonDown:)
        forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(buttonUp:) forControlEvents:
        UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.view addSubview:button];
    [self.buttons addObject:button];
    return button;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    ProtectorRegisterTouchDefaults();
    self.controlContext = PROTECTOR_UI_LOADING;
    self.view.backgroundColor = UIColor.blackColor;
    self.buttons = [NSMutableArray array];
    self.pressedButtons = [NSMutableSet set];
    self.buttonHaptics = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [self.buttonHaptics prepare];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self.gameView = [[ProtectorPointerView alloc] initWithFrame:self.view.bounds device:device];
    self.gameView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.gameView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.gameView.clearColor = MTLClearColorMake(0, 0, 0, 1);
    self.gameView.preferredFramesPerSecond = 60;
    protector_pacing_init(&_pacing);
    self.gameView.userInteractionEnabled = YES;
    self.gameView.multipleTouchEnabled = YES;
    self.gameView.accessibilityLabel = @"Game. Touch or drag to point. Attack confirms game menus.";
    self.gameView.accessibilityIdentifier = @"translated-game-view";
    self.gameView.delegate = self;
    __weak ProtectorInteractiveController* touchOwner = self;
    self.gameView.touchHandler = ^{ [touchOwner touchedGameView]; };
    [self.view addSubview:self.gameView];
    self.openingLogoSkip=[UIButton buttonWithType:UIButtonTypeCustom];
    self.openingLogoSkip.frame=self.view.bounds;
    self.openingLogoSkip.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.openingLogoSkip.accessibilityIdentifier=@"skip-opening-logo";
    self.openingLogoSkip.accessibilityLabel=@"Skip opening logo";
    self.openingLogoSkip.hidden=YES;
    [self.openingLogoSkip addTarget:self action:@selector(skipOpeningLogo) forControlEvents:UIControlEventTouchDown];
    [self.view addSubview:self.openingLogoSkip];
    self.stick = [[ProtectorStick alloc] initWithFrame:CGRectZero];
    [self.stick addTarget:self action:@selector(publishControls)
        forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.stick];
    [self gameButton:@"Attack" glyph:ProtectorGlyphAttack label:@"Attack or confirm" mask:PROTECTOR_BUTTON_A];
    [self gameButton:@"Heavy" glyph:ProtectorGlyphHeavy label:@"Heavy attack or back" mask:PROTECTOR_BUTTON_B];
    [self gameButton:@"Block" glyph:ProtectorGlyphBlock label:@"Block" mask:PROTECTOR_BUTTON_C];
    [self gameButton:@"Jump" glyph:ProtectorGlyphJump label:@"Jump" mask:PROTECTOR_BUTTON_Z];
    [self gameButton:@"Menu" glyph:ProtectorGlyphMenu label:@"Game menu" mask:PROTECTOR_BUTTON_PLUS];
    [self gameButton:@"Back" glyph:ProtectorGlyphBack label:@"Back in game menus" mask:PROTECTOR_BUTTON_B];
    [self gameButton:@"" glyph:ProtectorGlyphPrevious label:@"Previous alien or left" mask:PROTECTOR_BUTTON_LEFT];
    [self gameButton:@"Transform" glyph:ProtectorGlyphTransform label:@"Transform or up" mask:PROTECTOR_BUTTON_UP];
    [self gameButton:@"" glyph:ProtectorGlyphNext label:@"Next alien or right" mask:PROTECTOR_BUTTON_RIGHT];
    [self gameButton:@"Special" glyph:ProtectorGlyphSpecial label:@"Special attack or down" mask:PROTECTOR_BUTTON_DOWN];
    self.shakeButton = [self gameButton:@"Interact" glyph:ProtectorGlyphInteract label:@"Hold for motion interaction" mask:0];
    self.shakeButton.accessibilityIdentifier = @"game-motion-interaction";
    self.shakeButton.accessibilityHint = @"Hold when a special interaction asks for repeated physical motion.";
    self.buttons[5].accessibilityIdentifier = @"game-back";
    // Visible faces stay smaller than the established hit targets. Green
    // Omnitrix glass marks Attack, smoked glass the other moves; the
    // Transform dial and its wings are watch hardware; top actions are tabs.
    const CGFloat targets[] = {72, 56, 56, 64, 44, 56, 44, 56, 44, 56, 44};
    const CGFloat faces[] = {62, 42, 42, 54, 36, 44, 30, 50, 30, 42, 38};
    const ProtectorFaceShape shapes[] = {ProtectorFaceDisc, ProtectorFaceDisc, ProtectorFaceDisc,
        ProtectorFaceDisc, ProtectorFaceTab, ProtectorFacePill, ProtectorFaceArc, ProtectorFaceDial,
        ProtectorFaceArc, ProtectorFaceDisc, ProtectorFaceTab};
    const ProtectorGlassKind glasses[] = {ProtectorGlassGreen, ProtectorGlassSmoke, ProtectorGlassSmoke,
        ProtectorGlassSmoke, ProtectorGlassSteel, ProtectorGlassSmoke, ProtectorGlassSteel, ProtectorGlassSmoke,
        ProtectorGlassSteel, ProtectorGlassSmoke, ProtectorGlassSmoke};
    for (NSUInteger i = 0; i < self.buttons.count; ++i) {
        ProtectorActionButton* button = (ProtectorActionButton*)self.buttons[i];
        button.baseTargetSize = targets[i];
        button.baseFaceSize = faces[i];
        button.primaryAction = i == 0;
        [button setFace:shapes[i] glass:glasses[i]];
    }
    ProtectorActionButton* pause = [[ProtectorActionButton alloc] initWithFrame:CGRectZero];
    pause.baseTargetSize = 44;
    pause.baseFaceSize = 36;
    [pause setFace:ProtectorFaceTab glass:ProtectorGlassSteel];
    [pause setActionTitle:@"Pause" glyph:ProtectorGlyphPause];
    self.pauseButton = pause;
    self.pauseButton.accessibilityLabel = @"Pause and settings";
    self.pauseButton.accessibilityIdentifier = @"native-pause";
    ProtectorSetButtonHeld(self.pauseButton, NO);
    [self.pauseButton addTarget:self action:@selector(togglePause)
        forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.pauseButton];
    ProtectorActionButton* storySkip=[[ProtectorActionButton alloc] initWithFrame:CGRectZero];
    storySkip.baseTargetSize=52;
    storySkip.baseFaceSize=44;
    [storySkip setFace:ProtectorFacePill glass:ProtectorGlassSmoke];
    [storySkip setActionTitle:@"Skip" glyph:ProtectorGlyphConfirm];
    storySkip.accessibilityLabel=@"Skip cutscene";
    storySkip.accessibilityIdentifier=@"skip-story-cinematic";
    storySkip.hidden=YES;
    [storySkip addTarget:self action:@selector(skipStoryCinematic) forControlEvents:UIControlEventTouchUpInside];
    self.storySkipButton=storySkip;
    [self.view addSubview:storySkip];
    self.continueCue = [[ProtectorContinueCue alloc] initWithFrame:CGRectZero];
    [self.view addSubview:self.continueCue];
    self.qteCue=[[ProtectorQTECue alloc] initWithFrame:CGRectZero];
    [self.view addSubview:self.qteCue];
    self.status = [[UILabel alloc] init];
    self.status.text = @"Loading game…";
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.status.adjustsFontForContentSizeCategory = YES;
    self.status.textColor = [UIColor colorWithWhite:1 alpha:0.8];
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.numberOfLines = 0;
    self.status.accessibilityIdentifier = @"native-runtime-status";
    self.statusScroll = [[UIScrollView alloc] init];
    self.statusScroll.backgroundColor = ProtectorControlBacking();
    self.statusScroll.layer.cornerRadius = 8;
    self.statusScroll.clipsToBounds = YES;
    self.statusScroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    self.statusScroll.showsHorizontalScrollIndicator = NO;
    self.statusScroll.directionalLockEnabled = YES;
    self.statusScroll.accessibilityIdentifier = @"native-runtime-status-scroll";
    [self.statusScroll addSubview:self.status];
    [self.view addSubview:self.statusScroll];
    // Hide gameplay controls before resource loading/first presentation. Boot
    // frames have no source UI owner yet, so zero is not proof of gameplay.
    [self controlsPreferenceChanged];
    NSURL* resources = self.contentRoot ? self.contentRoot : NSBundle.mainBundle.resourceURL;
    NSURL* coefficients = [NSBundle.mainBundle URLForResource:@"ax-coefficients" withExtension:@"bin"];
    if (!coefficients) {
        [self showStatus:ProtectorPlayerErrorText([NSError errorWithDomain:@"ProtectorShell" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"Missing original audio coefficient resource"}])];
        return;
    }
    NSURL* output = [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
        inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Diagnostics"];
    NSURL* saves = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Original/RBNEG9"];
    NSURL* game = [resources URLByAppendingPathComponent:@"Game"];
    const char* qaStart = getenv("PROTECTOR_QA_START_LEVEL");
    if (qaStart && qaStart[0]) {
        NSString* level = @(qaStart);
        NSError* qaError = nil;
        NSRegularExpression* scene = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{2}_[0-9]{2}$" options:0 error:nil];
        game = [scene numberOfMatchesInString:level options:0 range:NSMakeRange(0, level.length)] == 1
            ? ProtectorQAStartRoot(game, level, &qaError) : nil;
        if (!game) {
            [self showStatus:ProtectorPlayerErrorText(qaError ? qaError : ProtectorQAStartError(@"Invalid QA start scene"))];
            return;
        }
        saves = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
            inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"QAStart/RBNEG9"];
    }
    // V1 is one enhanced game. Old preview preferences cannot select another
    // edition; the legacy save path above remains only a protected namespace.
    NSURL* pack = [resources URLByAppendingPathComponent:@"RestoredArt/pack.json"];
    if (pack && ![NSFileManager.defaultManager fileExistsAtPath:pack.path]) pack = nil;
    NSError* error = nil;
    self.session = [[ProtectorGameSession alloc] initWithDevice:device
        dataRoot:game
        kpadReference:[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"kpad-reference.json"]
        audioCoefficients:coefficients
        outputDirectory:output originalSaveDirectory:saves
        edition:ProtectorGameEditionUpgraded
        texturePackManifest:pack error:&error];
    if (!self.session) {
        [self showStatus:ProtectorPlayerErrorText(error)];
        self.gameView.paused = YES;
        return;
    }
    NSURL* geometry = [resources URLByAppendingPathComponent:@"EnhancedModels/geometry.json"];
    NSURL* cinematic = [resources URLByAppendingPathComponent:@"RestoredCinematics/cinematics.json"];
    if ([NSFileManager.defaultManager fileExistsAtPath:cinematic.path] &&
        ![self.session.renderer loadCinematicPack:cinematic
            sourceDirectory:[resources URLByAppendingPathComponent:@"Game"] error:&error]) {
        [self showStatus:ProtectorPlayerErrorText(error)];
        self.gameView.paused = YES;
        self.session = nil;
        return;
    }
    if (geometry && [NSFileManager.defaultManager fileExistsAtPath:geometry.path]) {
        if (![self.session.renderer loadGeometryPack:geometry error:&error]) {
            [self showStatus:ProtectorPlayerErrorText(error)];
            self.gameView.paused = YES;
            self.session = nil;
            return;
        }
        self.hasModelCandidate = YES;
    }
    // Quality choices are remembered between launches. Native resolution with
    // Smooth motion (selectSmoothMotion:YES via the registered default) is the
    // default, and a stored scale that cannot be applied falls back to Native
    // rather than failing the launch.
    NSUserDefaults* quality = NSUserDefaults.standardUserDefaults;
    if (![self.session.renderer selectNativeRenderSize:self.gameView.drawableSize error:&error] ||
        ![self.session.renderer selectWidescreen:YES error:&error] ||
        ![self.session.renderer selectSmoothMotion:[quality boolForKey:ProtectorRenderSmoothMotionKey] error:&error]) {
        [self showStatus:ProtectorPlayerErrorText(error)];
        self.gameView.paused = YES;
        self.session = nil;
        return;
    }
    NSInteger savedScale = [quality integerForKey:ProtectorRenderScaleKey];
    if ([quality boolForKey:ProtectorRenderScaleTrialKey]) {
        // The last launch never proved this scale healthy (it crashed, or the
        // system ended it). Never make the game unopenable: go back to Native.
        NSLog(@"Protector: render scale %ld did not survive its trial; using Native.", (long)savedScale);
        savedScale = 0;
        [quality setInteger:0 forKey:ProtectorRenderScaleKey];
        [quality setBool:NO forKey:ProtectorRenderScaleTrialKey];
    }
    if (savedScale == 1 || savedScale == 2 || savedScale == 3 || savedScale == 6) {
        NSError* scaleError = nil;
        if (![self.session.renderer selectRenderScale:(NSUInteger)savedScale error:&scaleError]) {
            NSLog(@"Protector: saved render scale %ld could not be applied, using Native: %@",
                (long)savedScale, scaleError.localizedDescription);
            [quality setInteger:0 forKey:ProtectorRenderScaleKey];
            if (![self.session.renderer selectNativeRenderSize:self.gameView.drawableSize error:&error]) {
                [self showStatus:ProtectorPlayerErrorText(error)];
                self.gameView.paused = YES;
                self.session = nil;
                return;
            }
        } else {
            [quality setBool:YES forKey:ProtectorRenderScaleTrialKey];
            self.scaleTrialStart = CACurrentMediaTime();
        }
    }
    self.gameView.widescreen = YES;
    [self.view setNeedsLayout];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(suspendGame)
        name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resumeGame)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didEnterBackground)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
#if PROTECTOR_IOS_EXTERNAL_CONTENT
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(audioRouteLost:)
        name:ProtectorAudioRouteLostNotification object:nil];
#endif
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerChanged:)
        name:GCControllerDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerChanged:)
        name:GCControllerDidDisconnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerChanged:)
        name:GCControllerDidBecomeCurrentNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controlsPreferenceChanged)
        name:UIContentSizeCategoryDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sessionFinished:)
        name:ProtectorGameSessionDidFinish object:self.session];
    [self controllerChanged:nil];
    // Input must keep flowing when a sheet covers the Metal view. Its draw
    // callbacks are not a reliable menu-input clock.
    self.controllerDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(controllerTick:)];
    [self.controllerDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    // Diagnostic launches only: a three-finger tap captures the current frame
    // (picture plus a renderer audit) without consuming the game's touches.
    if (getenv("PROTECTOR_HUD_TRANSITION_AUDIT") && !strcmp(getenv("PROTECTOR_HUD_TRANSITION_AUDIT"), "1")) {
        UITapGestureRecognizer* capture = [[UITapGestureRecognizer alloc] initWithTarget:self
            action:@selector(manualFrameCapture:)];
        capture.numberOfTouchesRequired = 3;
        capture.cancelsTouchesInView = NO;
        capture.delaysTouchesBegan = NO;
        capture.delaysTouchesEnded = NO;
        [self.view addGestureRecognizer:capture];
    }
    __weak ProtectorInteractiveController* controllerOwner = self;
    self.controllerQA = [ProtectorControllerSnapshotQA startIfRequested:^(GCController* controller) {
        ProtectorInteractiveController* owner = controllerOwner;
        [owner adoptController:controller pauseOnDisconnect:YES];
    }];
    self.controllerQA.captureHandler = ^{
        ProtectorInteractiveController* owner = controllerOwner;
        if (!owner.session || ![owner.session.renderer requestManualFrameAudit]) return;
        ProtectorGameSession* session = owner.session;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [session saveDiagnosticSnapshot]; });
    };
    self.controllerQA.stateReader = ^NSDictionary* {
        ProtectorInteractiveController* owner = controllerOwner;
        if (!owner) return @{};
        NSMutableDictionary* state = [[owner.session inputLifecycleDiagnostics] mutableCopy];
        state[@"controller_needs_neutral"] = @(owner.controllerNeedsNeutral);
        state[@"manually_paused"] = @(owner.manuallyPaused);
        state[@"control_context"] = @(protector_ui_context_name(owner.controlContext));
        state[@"map_actions"] = @(owner.mapActions);
        state[@"application_state"] = @(UIApplication.sharedApplication.applicationState);
        state[@"qte_target_rect"] = NSStringFromCGRect(owner.session.renderer.qteTargetRect);
        state[@"qte_cue_frame"] = NSStringFromCGRect(owner.qteCue.frame);
        // Opt-in read-only telemetry for short geometry observations. The QA
        // driver exists only in allowlisted simulator bundles; normal app
        // diagnostics retain their five-second cadence and gameplay is untouched.
        if ([NSProcessInfo.processInfo.environment[@"PROTECTOR_GEOMETRY_QA_READBACK"] isEqual:@"1"]) {
            NSDictionary* renderer = owner.session.renderer.stateCapture;
            NSString* failure = owner.session.failure.localizedDescription;
            state[@"renderer"] = renderer ? renderer : @{};
            state[@"runtime_error"] = failure ? (id)failure : NSNull.null;
        }
        return state;
    };
    [self.session start];
    [self showStatus:nil];
    self.diagnosticTimer = [NSTimer scheduledTimerWithTimeInterval:5 target:self
        selector:@selector(updateDiagnostics:) userInfo:nil repeats:YES];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    const UIEdgeInsets insets = self.view.safeAreaInsets;
    ProtectorTouchLayout layout;
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    if (protector_touch_layout(self.view.bounds.size.width, self.view.bounds.size.height,
            {insets.top, insets.left, insets.bottom, insets.right},
            [defaults doubleForKey:ProtectorTouchScaleKey],
            [defaults boolForKey:ProtectorTouchSwappedKey], &layout)) {
        if (self.session) {
            ProtectorTouchLayout nativeLayout;
            ProtectorTouchRect hud;
            if (protector_touch_native_hud_layout(self.view.bounds.size.width, self.view.bounds.size.height,
                    {insets.top, insets.left, insets.bottom, insets.right},
                    [defaults doubleForKey:ProtectorTouchScaleKey],
                    [defaults boolForKey:ProtectorTouchSwappedKey], &nativeLayout, &hud)) {
                NSError* error = nil;
                if (![self.session.renderer configureNativePresentationSize:self.view.bounds.size
                        hudFrame:CGRectMake(hud.x, hud.y, hud.width, hud.height) error:&error]) {
                    [self showStatus:ProtectorLayoutErrorText(error)];
                } else if (self.session.renderer.widescreenEnabled && self.controlContext == PROTECTOR_UI_GAMEPLAY) {
                    layout = nativeLayout;
                }
            }
        }
        ProtectorTouchLayout comboLayout;
        ProtectorTouchRect combatFeedback;
        if (self.session && protector_touch_combat_feedback_layout(self.view.bounds.size.width,self.view.bounds.size.height,
                {insets.top,insets.left,insets.bottom,insets.right},
                [defaults doubleForKey:ProtectorTouchScaleKey],[defaults boolForKey:ProtectorTouchSwappedKey],&combatFeedback)) {
            NSError* error=nil;
            if (![self.session.renderer configureNativeCombatFeedbackFrame:
                    CGRectMake(combatFeedback.x,combatFeedback.y,combatFeedback.width,combatFeedback.height) error:&error]) {
                [self showStatus:ProtectorLayoutErrorText(error)];
            }
        }
        ProtectorTouchRect comboContent;
        const BOOL comboFits = protector_touch_combo_layout(self.view.bounds.size.width, self.view.bounds.size.height,
            {insets.top, insets.left, insets.bottom, insets.right},
            [defaults doubleForKey:ProtectorTouchScaleKey], [defaults boolForKey:ProtectorTouchSwappedKey],
            &comboLayout, &comboContent);
        if (comboFits && self.session) {
            NSError* error = nil;
            if (![self.session.renderer configureNativeComboFrame:
                    CGRectMake(comboContent.x, comboContent.y, comboContent.width, comboContent.height) error:&error]) {
                [self showStatus:ProtectorLayoutErrorText(error)];
            }
        }
        ProtectorTouchLayout upgradeLayout;
        ProtectorTouchRect upgradeContent;
        const BOOL upgradeFits=protector_touch_upgrade_layout(self.view.bounds.size.width,self.view.bounds.size.height,
            {insets.top,insets.left,insets.bottom,insets.right},
            [defaults doubleForKey:ProtectorTouchScaleKey],[defaults boolForKey:ProtectorTouchSwappedKey],
            &upgradeLayout,&upgradeContent);
        if (upgradeFits && self.session) {
            NSError* error=nil;
            if (![self.session.renderer configureNativeUpgradeFrame:
                    CGRectMake(upgradeContent.x,upgradeContent.y,upgradeContent.width,upgradeContent.height) error:&error]) {
                [self showStatus:ProtectorLayoutErrorText(error)];
            }
        }
        ProtectorMapContentLayout mapContent;
        if(self.session&&protector_touch_map_content_layout(self.view.bounds.size.width,self.view.bounds.size.height,
            {insets.top,insets.left,insets.bottom,insets.right},
            [defaults doubleForKey:ProtectorTouchScaleKey],[defaults boolForKey:ProtectorTouchSwappedKey],&mapContent)) {
            auto frame=[](ProtectorTouchRect r){return CGRectMake(r.x,r.y,r.width,r.height);};
            NSError* error=nil;
            if(![self.session.renderer configureNativeMapTitle:frame(mapContent.title) cards:frame(mapContent.cards)
                hints:frame(mapContent.hints) error:&error])[self showStatus:ProtectorLayoutErrorText(error)];
        }
        if ((self.controlContext==PROTECTOR_UI_UPGRADE_MENU || self.controlContext==PROTECTOR_UI_UPGRADE_READY) && upgradeFits)
            layout=upgradeLayout;
        else if (self.controlContext==PROTECTOR_UI_EXTRAS_VIEWER)
            protector_touch_viewer_layout(self.view.bounds.size.width,self.view.bounds.size.height,
                {insets.top,insets.left,insets.bottom,insets.right},
                [defaults doubleForKey:ProtectorTouchScaleKey],[defaults boolForKey:ProtectorTouchSwappedKey],&layout);
        else if (self.controlContext == PROTECTOR_UI_COMBO_LIST && comboFits)
            layout = comboLayout;
        else if (self.controlContext == PROTECTOR_UI_MAP)
            protector_touch_map_layout(self.view.bounds.size.width, self.view.bounds.size.height,
                {insets.top, insets.left, insets.bottom, insets.right},
                [defaults doubleForKey:ProtectorTouchScaleKey],
                [defaults boolForKey:ProtectorTouchSwappedKey], &layout);
        else if (self.controlContext == PROTECTOR_UI_EXTRAS_BROWSER ||
                 self.controlContext == PROTECTOR_UI_EXTRAS_OPTIONS ||
                 self.controlContext == PROTECTOR_UI_EXTRAS_ROOT)
            protector_touch_extras_layout(self.view.bounds.size.width, self.view.bounds.size.height,
                {insets.top, insets.left, insets.bottom, insets.right},
                [defaults doubleForKey:ProtectorTouchScaleKey],
                [defaults boolForKey:ProtectorTouchSwappedKey], &layout);
        else if (self.controlContext == PROTECTOR_UI_GALLERY)
            protector_touch_gallery_layout(self.view.bounds.size.width, self.view.bounds.size.height,
                {insets.top, insets.left, insets.bottom, insets.right},
                [defaults doubleForKey:ProtectorTouchScaleKey],
                [defaults boolForKey:ProtectorTouchSwappedKey], &layout);
        else if (self.controlContext != PROTECTOR_UI_GAMEPLAY)
            protector_touch_menu_layout(self.view.bounds.size.width, self.view.bounds.size.height,
                {insets.top, insets.left, insets.bottom, insets.right},
                [defaults doubleForKey:ProtectorTouchScaleKey],
                [defaults boolForKey:ProtectorTouchSwappedKey], &layout);
        self.stick.frame = CGRectMake(layout.stick.x, layout.stick.y, layout.stick.width, layout.stick.height);
        for (NSUInteger i = 0; i < self.buttons.count; ++i) {
            const ProtectorTouchRect rect = layout.actions[i];
            self.buttons[i].frame = CGRectMake(rect.x, rect.y, rect.width, rect.height);
        }
        self.pauseButton.frame = CGRectMake(layout.pause.x, layout.pause.y, layout.pause.width, layout.pause.height);
        [self composeOmnitrixControls];
        // Reserve the actual control columns, including resized/swapped alien
        // wings. Move only the admitted visual motion pair, never hit regions.
        CGFloat qteLeft=insets.left+8,qteRight=self.view.bounds.size.width-insets.right-8;
        for(UIView* control in [(NSArray<UIView*>*)self.buttons arrayByAddingObject:self.stick]) {
            const CGRect box=control.frame;
            if(CGRectGetMidX(box)<CGRectGetMidX(self.view.bounds))qteLeft=fmax(qteLeft,CGRectGetMaxX(box)+8);
            else qteRight=fmin(qteRight,CGRectGetMinX(box)-8);
        }
        self.session.renderer.qteMotionSafeRect=qteRight>qteLeft ?
            CGRectMake(qteLeft/self.view.bounds.size.width,0,(qteRight-qteLeft)/self.view.bounds.size.width,1):CGRectZero;
        // The controller hint sits where touch Confirm would, growing toward
        // the screen centre.
        const CGRect confirm = self.buttons[0].frame;
        const CGSize cue = [self.continueCue sizeThatFits:confirm.size];
        const BOOL trailing = CGRectGetMidX(confirm) > CGRectGetMidX(self.view.bounds);
        self.continueCue.frame = CGRectMake(trailing ? CGRectGetMaxX(confirm) - cue.width : confirm.origin.x,
            CGRectGetMaxY(confirm) - cue.height, cue.width, cue.height);
    }
    const CGRect safe = UIEdgeInsetsInsetRect(self.view.bounds, insets);
    self.storySkipButton.frame=CGRectMake(CGRectGetMaxX(safe)-104,CGRectGetMaxY(safe)-60,96,52);
    // The source chooses targets throughout the image. Keep the cue at a safe
    // edge that leaves the complete target unobscured, including its glow.
    // Action/binding phrases need more room at accessibility text sizes when
    // no touch columns are visible. Keep boss target/motion cues and all touch
    // layouts at their already-qualified width.
    const unsigned prompts=self.session.renderer.qtePrompts;
    const BOOL controllerAction=self.activeController && !self.touchWokeControls &&
        [defaults boolForKey:ProtectorTouchHideWithControllerKey] &&
        (prompts & (PROTECTOR_QTE_SPECIAL|PROTECTOR_QTE_BLOCK|PROTECTOR_QTE_JUMP|PROTECTOR_QTE_TRANSFORM)) &&
        !(prompts & (PROTECTOR_QTE_PAIRED_MOTION|PROTECTOR_QTE_POINTER_TARGET));
    const CGFloat cueWidth=fmin(controllerAction?480:320,
        fmax(1,CGRectGetWidth(safe)*(controllerAction?.70:.44)));
    const CGSize qteSize=[self.qteCue sizeThatFits:CGSizeMake(cueWidth,CGFLOAT_MAX)];
    const CGRect target=self.session.renderer.qteTargetRect;
    const CGSize viewSize=self.view.bounds.size;
    const ProtectorQTERect targetPoints=CGRectIsNull(target)?ProtectorQTERect{}:
        ProtectorQTERect{(float)(target.origin.x*viewSize.width),(float)(target.origin.y*viewSize.height),
            (float)(target.size.width*viewSize.width),(float)(target.size.height*viewSize.height)};
    ProtectorQTERect cueFrame;
    if(protector_qte_cue_rect({(float)safe.origin.x,(float)safe.origin.y,
            (float)safe.size.width,(float)safe.size.height},(float)qteSize.width,(float)qteSize.height,
            targetPoints,&cueFrame))
        self.qteCue.frame=CGRectMake(cueFrame.x,cueFrame.y,cueFrame.width,cueFrame.height);
    else self.qteCue.hidden=YES;
    // A running-save warning leaves both top-right action targets and the
    // source dialog's centre free, even at the largest accessibility size.
    const CGFloat width = fmax(1, fmin(600, CGRectGetWidth(safe) - (self.saveWarningVisible ? 248 : 48)));
    const CGFloat textWidth = fmax(1, width - 24);
    const CGFloat textHeight = ceil([self.status sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height);
    const CGFloat contentHeight = textHeight + 24;
    const CGFloat maximumHeight = self.saveWarningVisible ? CGRectGetHeight(safe) * .25 : CGRectGetHeight(safe) - 48;
    const CGFloat height = fmin(fmax(44, contentHeight), fmax(44, maximumHeight));
    self.statusScroll.frame = CGRectMake(CGRectGetMidX(safe) - width * 0.5,
        self.saveWarningVisible ? CGRectGetMinY(safe) + 8 : CGRectGetMidY(safe) - height * 0.5, width, height);
    self.status.frame = CGRectMake(12, 12, textWidth, textHeight);
    self.statusScroll.contentSize = CGSizeMake(width, contentHeight);
}
// The alien wings and the menu directions are arcs of one dial: around the
// Transform dial in play, around the centre of the direction cross in menus.
- (void)composeOmnitrixControls {
    const BOOL contextual = self.controlContext != PROTECTOR_UI_GAMEPLAY;
    CGPoint hub = self.buttons[7].center;
    if (contextual)
        hub = CGPointMake((self.buttons[6].center.x + self.buttons[8].center.x) / 2,
            (self.buttons[7].center.y + self.buttons[9].center.y) / 2);
    for (NSUInteger i = 6; i <= 9; ++i) {
        ProtectorActionButton* button = (ProtectorActionButton*)self.buttons[i];
        if (button.faceShape != ProtectorFaceArc) continue;
        button.arcCenter = [self.view convertPoint:hub toView:button];
        [button setNeedsLayout];
    }
}
- (void)buttonDown:(UIButton*)button {
    if (button.hidden || self.manuallyPaused || self.session.finished || !self.session) return;
    [self.pressedButtons addObject:button];
    ProtectorSetButtonHeld(button, YES);
    // Throttled and re-primed: a mashed Attack must tick, not buzz continuously.
    const CFTimeInterval now = CACurrentMediaTime();
    if ([NSUserDefaults.standardUserDefaults boolForKey:ProtectorTouchHapticsKey] && now - self.lastHapticTime >= 0.08) {
        self.lastHapticTime = now;
        [self.buttonHaptics impactOccurredWithIntensity:0.45];
        [self.buttonHaptics prepare];
    }
    [self publishControls];
}
- (void)skipOpeningLogo {
    if (self.manuallyPaused || self.session.finished || self.controlContext != PROTECTOR_UI_LOADING) return;
    ProtectorCinematicFrame frame=self.session.renderer.cinematicFrame;
    protector_cinematic_request_logo_skip(&frame);
}
- (void)skipStoryCinematic {
    if (self.manuallyPaused || self.session.finished || self.presentedViewController) return;
    const ProtectorCinematicFrame frame=self.session.renderer.cinematicFrame;
    if (!protector_cinematic_is_opening_logo(&frame)) protector_cinematic_request_skip(&frame);
}
- (void)buttonUp:(UIButton*)button {
    [self.pressedButtons removeObject:button];
    ProtectorSetButtonHeld(button, NO);
    [self publishControls];
}
- (void)publishControls {
    if (self.clearingControls || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        protector_live_input_cancel();
        return;
    }
    if (self.sourceGuideReturning) {
        // Only the source-offered Continue is delivered while the native page
        // still covers the obsolete diagram. No physical/touch input leaks.
        ProtectorLiveInputDiagnostics input;
        protector_live_input_diagnostics(&input);
        // The guide may open during the same source update that accepted
        // Options' Confirm. Let the guest observe its release and finish one
        // neutral update before delivering a distinct Continue press.
        if (self.sourceGuideContinuePending &&
            input.samples >= self.sourceGuideNeutralStart + 2 && input.last.hold == 0) {
            self.sourceGuideContinuePending = NO;
            self.sourceGuideContinueSample = input.samples;
            protector_live_input_update(PROTECTOR_BUTTON_A, 0, 0);
            protector_live_input_update(0, 0, 0); // Latched until a guest poll.
        }
        if (CACurrentMediaTime() >= self.sourceGuideReturnDeadline) {
            self.sourceGuideReturning = NO;
            self.manuallyPaused = YES;
            [self clearControls];
            [self.session setPaused:YES];
            [self.sourceControlsGuide setReturnInProgress:NO];
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Couldn't return to Options"
                message:@"The game is still paused. Close this message and try Done again."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self.sourceControlsGuide presentViewController:alert animated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
        }
        return;
    }
    GCExtendedGamepad* pad = self.activeController.extendedGamepad;
    if (self.touchWokeControls && pad && ProtectorPadHasInput(pad)) {
        // The controller is in use again; touch controls hide as the setting says.
        self.touchWokeControls = NO;
        [self controlsPreferenceChanged];
    }
    if (pad && self.controllerNeedsNeutral) {
        const BOOL active = pad.buttonA.isPressed || pad.buttonB.isPressed || pad.buttonX.isPressed ||
            pad.buttonY.isPressed || pad.leftShoulder.isPressed || pad.rightShoulder.isPressed ||
            pad.leftTrigger.isPressed || pad.rightTrigger.isPressed || pad.buttonMenu.isPressed ||
            pad.buttonOptions.isPressed || pad.rightThumbstickButton.isPressed ||
            fabsf(pad.leftThumbstick.xAxis.value) > 0.15f ||
            fabsf(pad.leftThumbstick.yAxis.value) > 0.15f || fabsf(pad.rightThumbstick.xAxis.value) > 0.15f ||
            fabsf(pad.rightThumbstick.yAxis.value) > 0.15f || pad.dpad.left.isPressed ||
            pad.dpad.right.isPressed || pad.dpad.up.isPressed || pad.dpad.down.isPressed;
        if (!active) self.controllerNeedsNeutral = NO;
        pad = nil;
    }
    const BOOL menuPressed = pad.buttonMenu.isPressed;
    if (menuPressed && !self.controllerMenuHeld && !self.controllerNeedsNeutral) {
        self.controllerMenuHeld = YES;
        [self togglePause];
        protector_live_input_cancel();
        return;
    }
    self.controllerMenuHeld = menuPressed;
    if (self.manuallyPaused) {
        protector_live_input_cancel();
        float x = pad.dpad.xAxis.value, y = pad.dpad.yAxis.value;
        if (fabsf(x) < .15f && fabsf(y) < .15f) {
            x = pad.leftThumbstick.xAxis.value; y = pad.leftThumbstick.yAxis.value;
        }
        ProtectorMenuCommand command = protector_menu_input_sample(&_menuInput,
            x, y, pad.buttonA.isPressed, pad.buttonB.isPressed, CACurrentMediaTime());
        UINavigationController* navigation = (UINavigationController*)self.presentedViewController;
        if ([navigation isKindOfClass:UINavigationController.class] &&
            [navigation.topViewController isKindOfClass:ProtectorControllerTableController.class])
            [(ProtectorControllerTableController*)navigation.topViewController handleControllerCommand:command];
        return;
    }
    if (self.controlContext == PROTECTOR_UI_FATAL_DIALOG) {
        // The source waits for Wii hardware recovery and has no Confirm path.
        // Native stop preserves failure precedence and performs no save repair.
        protector_live_input_cancel();
        if (pad.buttonA.isPressed || [self.pressedButtons containsObject:self.buttons[0]]) {
            [self clearControls];
            [self.session requestStop];
        }
        return;
    }
    if (self.controlContext == PROTECTOR_UI_LOADING || self.controlContext == PROTECTOR_UI_READING ||
        self.controlContext == PROTECTOR_UI_CINEMATIC) {
        // Native Pause still works, but a held face button during loading must
        // not become an early source Confirm. Readiness clears inputs again.
        self.held = 0;
        self.shakeHeld = NO;
        self.menuPulsePending = NO;
        self.cameraPulsePending = NO;
        self.controllerAimActive = NO;
        protector_live_input_cancel();
        return;
    }
    uint32_t held = 0;
    for (UIButton* button in self.pressedButtons) held |= (uint32_t)button.tag;
    self.held = held;
    self.shakeHeld = [self.pressedButtons containsObject:self.shakeButton];
    if (self.menuPulsePending) { held |= PROTECTOR_BUTTON_PLUS; self.menuPulsePending = NO; }
    if (self.cameraPulsePending) {
        if (self.controlContext == PROTECTOR_UI_GAMEPLAY) held |= PROTECTOR_BUTTON_ONE;
        self.cameraPulsePending = NO;
    }
    float x = (float)self.stick.value.x;
    float y = (float)self.stick.value.y;
    uint32_t motion = self.shakeHeld
        ? PROTECTOR_MOTION_WIIMOTE | PROTECTOR_MOTION_NUNCHUK : 0;
    BOOL controllerAim = NO;
    if (pad) {
        if (pad.buttonA.isPressed) held |= PROTECTOR_BUTTON_A;
        if (pad.buttonB.isPressed) held |= PROTECTOR_BUTTON_B;
        if (pad.buttonX.isPressed) held |= PROTECTOR_BUTTON_C;
        if (pad.buttonY.isPressed || pad.leftShoulder.isPressed) held |= PROTECTOR_BUTTON_Z;
        // Menu belongs to native pause/settings. The original in-game menu is
        // available from that sheet and the touch Menu control.
        if (pad.buttonOptions.isPressed) held |= PROTECTOR_BUTTON_MINUS;
        if (self.controlContext == PROTECTOR_UI_GAMEPLAY && pad.rightThumbstickButton.isPressed)
            held |= PROTECTOR_BUTTON_ONE;
        if (pad.dpad.left.isPressed) held |= PROTECTOR_BUTTON_LEFT;
        if (pad.dpad.right.isPressed) held |= PROTECTOR_BUTTON_RIGHT;
        if (pad.dpad.down.isPressed) held |= PROTECTOR_BUTTON_DOWN;
        if (pad.dpad.up.isPressed) held |= PROTECTOR_BUTTON_UP;
        if (fabsf(pad.leftThumbstick.xAxis.value) > 0.15f) x = pad.leftThumbstick.xAxis.value;
        if (fabsf(pad.leftThumbstick.yAxis.value) > 0.15f) y = pad.leftThumbstick.yAxis.value;
        const float aimX = pad.rightThumbstick.xAxis.value;
        const float aimY = -pad.rightThumbstick.yAxis.value;
        controllerAim = pad.rightShoulder.isPressed || fabsf(aimX) > 0.15f || fabsf(aimY) > 0.15f;
        if (controllerAim && !self.gameView.pointerTouch) {
            const float scale=self.gameView.qtePointer?.5f:1.f;
            protector_live_input_pointer(true, aimX*scale, aimY*scale);
        }
        if (pad.rightTrigger.isPressed) motion |= PROTECTOR_MOTION_WIIMOTE;
        if (pad.leftTrigger.isPressed) motion |= PROTECTOR_MOTION_NUNCHUK;
    }
    if (!controllerAim && self.controllerAimActive && !self.gameView.pointerTouch)
        protector_live_input_clear_pointer();
    self.controllerAimActive = controllerAim;
    protector_live_input_update(held, x, y);
    protector_live_input_motion(motion);
}
- (void)clearControls {
    self.clearingControls = YES;
    [self.pressedButtons removeAllObjects];
    self.held = 0;
    self.shakeHeld = NO;
    self.controllerAimActive = NO;
    self.menuPulsePending = NO;
    self.cameraPulsePending = NO;
    self.controllerNeedsNeutral = self.activeController != nil;
    protector_menu_input_reset(&_menuInput);
    [self.gameView cancelPointer];
    [self.stick reset];
    for (UIButton* button in self.buttons)
        ProtectorSetButtonHeld(button, NO);
    protector_live_input_cancel();
    self.clearingControls = NO;
}
- (void)togglePause {
    if (!self.session || self.session.finished) return;
    if (self.sourceGuideReturning) return;
    if (self.manuallyPaused) { [self resumeFromSettings]; return; }
    self.manuallyPaused = YES;
    [self clearControls];
    [self.session setPaused:YES];
    [(ProtectorActionButton*)self.pauseButton setActionTitle:@"Resume" symbol:@"play.fill"];
    self.pauseButton.accessibilityLabel = @"Resume game";
    ProtectorTouchSettingsController* settings = [[ProtectorTouchSettingsController alloc] init];
    settings.controllerNavigationActive = self.activeController != nil;
    settings.pauseReason = self.pauseReason;
    settings.hasSmoothMotion = self.session.renderer.smoothMotionAvailable;
    settings.smoothMotion = self.session.renderer.smoothMotionEnabled;
    settings.renderScale = self.session.renderer.nativeResolutionEnabled ? 0 : self.session.renderer.renderScale;
    __weak ProtectorInteractiveController* weakSelf = self;
    settings.preferencesChanged = ^{ [weakSelf controlsPreferenceChanged]; };
    settings.resumeGame = ^{ [weakSelf resumeFromSettings]; };
    settings.openGameMenu = ^{
        [weakSelf resumeFromSettings];
        weakSelf.menuPulsePending = YES;
    };
    if (self.controlContext == PROTECTOR_UI_GAMEPLAY) settings.changeCamera = ^{
        ProtectorInteractiveController* owner = weakSelf;
        if (!owner || !owner.manuallyPaused || owner.controlContext != PROTECTOR_UI_GAMEPLAY) return;
        [owner resumeFromSettings];
        // The original game consumes a single camera-button press. Secret
        // state stays game-owned; no save or guest field is changed here.
        owner.cameraPulsePending = YES;
    };
    settings.selectRendering = ^NSString*(NSString* key, NSUInteger value) {
        ProtectorInteractiveController* owner = weakSelf;
        if (!owner || !owner.manuallyPaused) return @"Pause the game before changing presentation.";
        NSError* error = nil;
        BOOL success = NO;
        if ([key isEqual:@"scale"]) success = value
            ? [owner.session.renderer selectRenderScale:value error:&error]
            : [owner.session.renderer selectNativeRenderSize:owner.gameView.drawableSize error:&error];
        else if ([key isEqual:@"motion"]) success = [owner.session.renderer selectSmoothMotion:value != 0 error:&error];
        if (!success) {
            if (error) ProtectorLogFailure(error);
            return error ? [NSString stringWithFormat:@"That setting couldn’t be applied, so nothing changed. Try another setting. (Ref %@)",
                ProtectorErrorReference(error)] : @"This presentation setting is unavailable.";
        }
        // Remember the choice. A fixed scale stays on trial until it has run
        // for a while without the app dying (see viewDidLoad).
        NSUserDefaults* quality = NSUserDefaults.standardUserDefaults;
        if ([key isEqual:@"scale"]) {
            [quality setInteger:(NSInteger)value forKey:ProtectorRenderScaleKey];
            [quality setBool:value != 0 forKey:ProtectorRenderScaleTrialKey];
            owner.scaleTrialStart = CACurrentMediaTime();
        } else if ([key isEqual:@"motion"]) [quality setBool:value != 0 forKey:ProtectorRenderSmoothMotionKey];
        owner.gameView.widescreen = owner.session.renderer.widescreenEnabled;
        [owner.view setNeedsLayout];
        [owner.view layoutIfNeeded];
        owner.gameView.presentationAspect = (float)owner.session.renderer.presentationAspect;
        [owner.session saveDiagnosticSnapshot];
        return nil;
    };
    UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:settings];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent largeDetent]];
    navigation.sheetPresentationController.prefersGrabberVisible = YES;
    navigation.presentationController.delegate = self;
    [self presentViewController:navigation animated:!UIAccessibilityIsReduceMotionEnabled() completion:^{
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    }];
}
- (void)resumeFromSettings {
    if (self.sourceControlsGuide) { [self returnFromSourceControlsGuide]; return; }
    [self clearControls];
    self.manuallyPaused = NO;
    [(ProtectorActionButton*)self.pauseButton setActionTitle:@"Pause" symbol:@"pause.fill"];
    self.pauseButton.accessibilityLabel = @"Pause and settings";
    [self dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled() completion:^{
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    }];
    [self.session setPaused:UIApplication.sharedApplication.applicationState != UIApplicationStateActive];
}
- (void)presentationControllerDidDismiss:(UIPresentationController*)presentationController {
    (void)presentationController; [self resumeFromSettings];
}
- (void)showSourceControlsGuide {
    self.manuallyPaused = YES;
    [self clearControls];
    [self.session setPaused:YES];
    ProtectorControlsGuideController* guide = [[ProtectorControlsGuideController alloc] init];
    guide.fromGameMenu = YES;
    guide.controllerMode = self.activeController != nil;
    guide.controllerNavigationActive = self.activeController != nil;
    __weak ProtectorInteractiveController* weakSelf = self;
    guide.resumeGame = ^{ [weakSelf returnFromSourceControlsGuide]; };
    self.sourceControlsGuide = guide;
    UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:guide];
    // This replaces a full game screen, not a second sheet over Wii diagrams.
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:NO completion:nil];
}
- (void)returnFromSourceControlsGuide {
    if (!self.sourceControlsGuide || self.sourceGuideReturning) return;
    [self clearControls];
    self.sourceGuideReturning = YES;
    self.sourceGuideContinuePending = YES;
    ProtectorLiveInputDiagnostics input;
    protector_live_input_diagnostics(&input);
    self.sourceGuideNeutralStart = input.samples;
    self.sourceGuideContinueSample = 0;
    self.sourceGuideReturnDeadline = CACurrentMediaTime() + 3;
    [self.sourceControlsGuide setReturnInProgress:YES];
    self.manuallyPaused = NO;
    // setPaused clears old inputs. Continue waits for neutral guest samples
    // after that boundary, never merely for a host display-link tick.
    [self.session setPaused:UIApplication.sharedApplication.applicationState != UIApplicationStateActive];
}
- (void)finishSourceControlsGuideReturn {
    [self clearControls];
    self.sourceGuideReturning = NO;
    self.sourceGuideContinuePending = NO;
    self.sourceControlsGuide = nil;
    [self dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled() completion:^{
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    }];
}
- (void)manualFrameCapture:(UITapGestureRecognizer*)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized || !self.session) return;
    if (![self.session.renderer requestManualFrameAudit]) return;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    ProtectorGameSession* session = self.session;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [session saveDiagnosticSnapshot]; });
    NSLog(@"Protector manual frame capture requested");
}

- (void)controlsPreferenceChanged {
    if (self.session.finished) {
        self.stick.hidden = YES;
        self.pauseButton.hidden = YES;
        self.continueCue.hidden = YES;
        self.qteCue.hidden = YES;
        self.gameView.userInteractionEnabled = NO;
        self.gameView.isAccessibilityElement = NO;
        self.gameView.accessibilityElementsHidden = YES;
        for (UIButton* button in self.buttons) button.hidden = YES;
        [self.view setNeedsLayout];
        return;
    }
    [self.stick setNeedsLayout];
    [self.pauseButton setNeedsLayout];
    [self.continueCue setNeedsLayout];
    [self.qteCue setNeedsLayout];
    for (UIButton* button in self.buttons) {
        ProtectorSetButtonHeld(button, [self.pressedButtons containsObject:button]);
        [button setNeedsLayout];
    }
    // A touch on the game wakes the controls until the next controller input.
    const BOOL hidden = self.activeController && !self.touchWokeControls &&
        [NSUserDefaults.standardUserDefaults boolForKey:ProtectorTouchHideWithControllerKey];
    const BOOL contextual = self.controlContext != PROTECTOR_UI_GAMEPLAY;
    const BOOL combo = self.controlContext == PROTECTOR_UI_COMBO_LIST;
    const BOOL upgradeReady=self.controlContext==PROTECTOR_UI_UPGRADE_READY;
    const BOOL upgrade=upgradeReady || self.controlContext==PROTECTOR_UI_UPGRADE_MENU;
    const BOOL viewer=self.controlContext==PROTECTOR_UI_EXTRAS_VIEWER;
    const BOOL menu = self.controlContext == PROTECTOR_UI_MENU || self.controlContext == PROTECTOR_UI_GALLERY ||
        self.controlContext == PROTECTOR_UI_EXTRAS_BROWSER || self.controlContext == PROTECTOR_UI_EXTRAS_OPTIONS ||
        self.controlContext == PROTECTOR_UI_EXTRAS_ROOT;
    const BOOL map = self.controlContext == PROTECTOR_UI_MAP;
    const BOOL loading = self.controlContext == PROTECTOR_UI_LOADING;
    const BOOL reading = self.controlContext == PROTECTOR_UI_READING;
    const BOOL cinematic = self.controlContext == PROTECTOR_UI_CINEMATIC;
    const BOOL skip = self.controlContext == PROTECTOR_UI_CINEMATIC_READY;
    const BOOL guiding = self.controlContext == PROTECTOR_UI_CONTROLS_GUIDE;
    const BOOL defeated = self.controlContext == PROTECTOR_UI_DEFEAT;
    const BOOL continueDialog = self.controlContext == PROTECTOR_UI_CONTINUE_DIALOG;
    const BOOL choiceDialog = self.controlContext == PROTECTOR_UI_CHOICE_DIALOG;
    const BOOL fatalDialog = self.controlContext == PROTECTOR_UI_FATAL_DIALOG;
    self.gameView.userInteractionEnabled = !upgrade && !viewer && !loading && !reading && !cinematic && !skip && !guiding &&
        !defeated && !continueDialog && !choiceDialog && !fatalDialog && self.controlContext != PROTECTOR_UI_PROMPT && self.controlContext != PROTECTOR_UI_INSTRUCTION;
    self.stick.hidden = hidden || (contextual && !map && !viewer);
    self.stick.rotatesCharacter=viewer;
    self.stick.accessibilityLabel = viewer ? @"Rotate character" : map ? @"Choose location" : @"Move";
    self.stick.accessibilityHint = viewer ? @"Drag to rotate the original camera. Lift to stop." : @"Drag in any direction. Lift to stop.";
    for (NSUInteger i = 0; i < self.buttons.count; ++i) {
        const BOOL mapAction = map && (i == 5 ||
            (i == 2 && (self.mapActions & PROTECTOR_UI_MAP_REPLAY)) ||
            (i == 3 && (self.mapActions & PROTECTOR_UI_MAP_CHALLENGE)));
        const BOOL relevant = choiceDialog ? (i==0 || (i>=6 && i<=9)) : viewer ? i==5 : upgrade ? (i==6 || i==8 || (i==0 && upgradeReady)) : combo ? (i == 5 || i == 6 || i == 8) : contextual ? (!loading && !reading && !cinematic && !guiding && (i == 0 || mapAction || (menu && (i == 5 || (i >= 6 && i <= 9)))))
            : (i != 4 && i != 5);
        self.buttons[i].hidden = hidden || !relevant;
        ((ProtectorActionButton*)self.buttons[i]).menuControl = contextual;
    }
    ((ProtectorActionButton*)self.pauseButton).menuControl = contextual;
    ProtectorActionButton* confirm = (ProtectorActionButton*)self.buttons[0];
    [confirm setFace:contextual ? ProtectorFacePill : ProtectorFaceDisc glass:ProtectorGlassGreen];
    [confirm setActionTitle:fatalDialog ? @"End Game" : continueDialog ? @"Continue" : upgrade ? @"Unlock Move" : skip ? @"Skip" : contextual ? @"Confirm" : @"Attack"
        glyph:contextual ? ProtectorGlyphConfirm : ProtectorGlyphAttack];
    self.buttons[0].accessibilityLabel = fatalDialog ? @"End Game" : continueDialog ? @"Continue" : upgrade ? @"Unlock Move" : skip ? @"Skip cinematic" : contextual ? @"Confirm" : @"Attack or confirm";
    ProtectorActionButton* replay = (ProtectorActionButton*)self.buttons[2];
    [replay setFace:map ? ProtectorFacePill : ProtectorFaceDisc glass:ProtectorGlassSmoke];
    [replay setActionTitle:map ? @"Replay" : @"Block" glyph:map ? ProtectorGlyphNone : ProtectorGlyphBlock];
    replay.accessibilityLabel = map ? @"Replay location" : @"Block";
    ProtectorActionButton* challenge = (ProtectorActionButton*)self.buttons[3];
    [challenge setFace:map ? ProtectorFacePill : ProtectorFaceDisc glass:ProtectorGlassSmoke];
    [challenge setActionTitle:map ? @"Challenge" : @"Jump" glyph:map ? ProtectorGlyphNone : ProtectorGlyphJump];
    challenge.accessibilityLabel = map ? @"Play secret challenge" : @"Jump";
    // In menus the Omnitrix dial and Special become arcs of one direction ring.
    ProtectorActionButton* transform = (ProtectorActionButton*)self.buttons[7];
    [transform setFace:contextual ? ProtectorFaceArc : ProtectorFaceDial
        glass:contextual ? ProtectorGlassSteel : ProtectorGlassSmoke];
    [transform setActionTitle:contextual ? @"" : @"Transform"
        glyph:contextual ? ProtectorGlyphUp : ProtectorGlyphTransform];
    ProtectorActionButton* special = (ProtectorActionButton*)self.buttons[9];
    [special setFace:contextual ? ProtectorFaceArc : ProtectorFaceDisc
        glass:contextual ? ProtectorGlassSteel : ProtectorGlassSmoke];
    [special setActionTitle:contextual ? @"" : @"Special"
        glyph:contextual ? ProtectorGlyphDown : ProtectorGlyphSpecial];
    self.buttons[6].accessibilityLabel = contextual ? @"Menu left" : @"Previous alien or left";
    self.buttons[7].accessibilityLabel = contextual ? @"Menu up" : @"Transform or up";
    self.buttons[8].accessibilityLabel = contextual ? @"Menu right" : @"Next alien or right";
    self.buttons[9].accessibilityLabel = contextual ? @"Menu down" : @"Special attack or down";
    for (NSUInteger i : {6u, 8u}) {
        ProtectorActionButton* direction = (ProtectorActionButton*)self.buttons[i];
        [direction setFace:combo || upgrade ? ProtectorFaceTab : ProtectorFaceArc glass:ProtectorGlassSteel];
        if (combo) direction.accessibilityLabel = i == 6 ? @"Previous combo list alien" : @"Next combo list alien";
        if (upgrade) direction.accessibilityLabel = i == 6 ? @"Previous upgrade alien" : @"Next upgrade alien";
    }
    self.gameView.accessibilityLabel = loading ? @"Loading the game. Please wait."
        : fatalDialog ? @"Save storage could not be read. Use End Game to stop. Reopen the app to try again."
        : choiceDialog ? @"Game message. Use the direction controls to choose, then Confirm."
        : continueDialog ? @"Game message. Use Continue to acknowledge."
        : upgradeReady ? @"Upgrade Menu. Choose an alien with left or right. Unlock Move accepts the offered upgrade."
        : upgrade ? @"Upgrade Menu. Choose an alien with left or right. No upgrade is offered for this selection."
        : viewer ? @"Character viewer. Drag Rotate to move the camera. Back returns to the collection."
        : combo ? @"Combo List. Choose an alien with left or right. Action icons match the native controls. Back returns to play."
        : guiding ? @"Native controls guide. Done returns to Options."
        : cinematic ? @"Game cinematic. Skip will appear when available."
        : skip ? @"Game cinematic. Use Skip to continue."
        : reading ? @"Game instruction. Read the panel; Confirm will appear shortly."
        : self.controlContext == PROTECTOR_UI_INSTRUCTION ? @"Game instruction. Use Confirm to continue."
        : self.controlContext == PROTECTOR_UI_PROMPT ? @"Game ready. Use Confirm to continue."
        : defeated ? @"Defeated. Use Confirm to continue."
        : self.controlContext == PROTECTOR_UI_TITLE ? @"Game title. Use Confirm to begin."
        : map ? @"Game map. Move to choose a location. Use Confirm or Back."
        : menu ? @"Game menu. Use the menu controls to choose and confirm."
        : @"Game. Touch or drag to point. Attack confirms game menus.";
    // Controller play hides touch controls, but a ready source instruction
    // still needs a visible way on. Reading and loading show nothing.
    const BOOL continuation = hidden && (self.controlContext == PROTECTOR_UI_INSTRUCTION ||
        self.controlContext == PROTECTOR_UI_PROMPT || self.controlContext == PROTECTOR_UI_TITLE || continueDialog || choiceDialog || fatalDialog || defeated || skip || upgradeReady);
    self.continueCue.skipsCinematic = skip;
    self.continueCue.unlocksMove = upgradeReady;
    self.continueCue.acknowledgesDialog = continueDialog;
    self.continueCue.endsGame = fatalDialog;
    [self.continueCue showForController:continuation ? self.activeController : nil];
    [self updateQTECue];
    [self.view setNeedsLayout];
}
- (void)updateQTECue {
    const CGRect target=self.session.renderer.qteTargetRect;
    if(!CGRectEqualToRect(target,self.displayedQTETargetRect)) {
        self.displayedQTETargetRect=target;[self.view setNeedsLayout];
    }
    const BOOL active=self.session && !self.session.finished && !self.manuallyPaused &&
        !self.presentedViewController && !self.sourceControlsGuide &&
        self.controlContext==PROTECTOR_UI_GAMEPLAY &&
        UIApplication.sharedApplication.applicationState==UIApplicationStateActive;
    self.qteCue.transformButtonName=self.activeController.extendedGamepad.buttonOptions.localizedName;
    [self.qteCue showPrompts:active?self.session.renderer.qtePrompts:0 controller:self.activeController!=nil];
}
- (void)updateControlContext {
    [self updateQTECue];
    ProtectorCinematicFrame opening=self.session.renderer.cinematicFrame;
    self.openingLogoSkip.hidden=self.session.finished || self.manuallyPaused ||
        self.controlContext!=PROTECTOR_UI_LOADING || !protector_cinematic_is_opening_logo(&opening);
    // CINEMATIC_READY already offers the source Skip (Confirm pill or controller
    // cue) in the same corner; showing both would be two Skip pills.
    self.storySkipButton.hidden=self.session.finished || self.manuallyPaused || self.presentedViewController ||
        self.controlContext==PROTECTOR_UI_CINEMATIC_READY ||
        !protector_cinematic_can_skip(&opening) || protector_cinematic_is_opening_logo(&opening);
    if (self.session.finished) return;
    ProtectorSaveStatus saveStatus;
    protector_save_status_read(&saveStatus);
    const BOOL saveWarning = saveStatus.enabled && saveStatus.pending_failure_mask != 0;
    const unsigned saveFailureMask = saveStatus.enabled ? saveStatus.pending_failure_mask : 0;
    if (saveFailureMask != self.saveFailureMask) {
        self.saveFailureMask = saveFailureMask;
        self.saveWarningVisible = saveWarning;
        [self showStatus:!saveWarning ? nil : (saveFailureMask & (1u << PROTECTOR_SAVE_GAME)) ?
            @"Save failed. New progress isn’t saved yet. Keep the game open until a save succeeds." :
            @"Save information couldn’t be updated. Keep the game open until a save succeeds."];
    }
    const ProtectorUIContextSnapshot snapshot = protector_ui_context_startup_snapshot(
        protector_ui_context_snapshot(), &_observedStartupScreen);
    const ProtectorUIContext context = snapshot.context;
    if (context != self.controlContext || snapshot.map_actions != self.mapActions) {
        [self clearControls];
        self.controlContext = context;
        self.mapActions = snapshot.map_actions;
        [self controlsPreferenceChanged];
    }
    if (self.sourceGuideReturning && context != PROTECTOR_UI_CONTROLS_GUIDE)
        [self finishSourceControlsGuideReturn];
    if (context == PROTECTOR_UI_CONTROLS_GUIDE && !self.sourceControlsGuide &&
        !self.manuallyPaused && !self.presentedViewController && self.view.window &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
        self.session && !self.session.finished)
        [self showSourceControlsGuide];
}
- (void)controllerChanged:(NSNotification*)notification {
    // An explicitly requested simulator snapshot is the QA input source.
    // Host controller discovery must not silently replace it mid-scenario.
    if (self.controllerQA) return;
    GCController* selected = GCController.current;
    if (!selected.extendedGamepad || ![GCController.controllers containsObject:selected]) selected = nil;
    if (!selected) for (GCController* candidate in GCController.controllers)
        if (candidate.extendedGamepad) { selected = candidate; break; }
    [self adoptController:selected pauseOnDisconnect:[notification.name isEqual:GCControllerDidDisconnectNotification]];
}
- (void)adoptController:(GCController*)selected pauseOnDisconnect:(BOOL)pauseOnDisconnect {
    GCController* previous = self.activeController;
    if (selected != previous) {
        self.activeController = selected;
        self.touchWokeControls = NO;
        [self clearControls];
        self.controllerMenuHeld = selected.extendedGamepad.buttonMenu.isPressed;
    }
    [self controlsPreferenceChanged];
    [self refreshSettingsControllerConnection];
    if (previous && !selected && pauseOnDisconnect &&
        !self.manuallyPaused && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        // A pad that sleeps mid-cutscene must not look like a spontaneous pause.
        self.pauseReason = @"Controller disconnected.";
        [self togglePause];
        self.pauseReason = nil;
    }
}
- (void)controllerTick:(CADisplayLink*)displayLink {
    self.controllerTickCount += 1;
    // Keep the screen awake only during active play (controller-only play
    // produces no touches to reset the idle timer).
    const BOOL keepAwake = self.session && !self.session.finished && !self.manuallyPaused &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    if (UIApplication.sharedApplication.idleTimerDisabled != keepAwake)
        UIApplication.sharedApplication.idleTimerDisabled = keepAwake;
    // A full-screen reading page can suspend MTKView callbacks. Source return
    // reconciliation must keep running independently of visible game pixels.
    [self updateControlContext];
    [self publishControls];
}
- (void)refreshSettingsControllerConnection {
    UINavigationController* navigation = (UINavigationController*)self.presentedViewController;
    if (![navigation isKindOfClass:UINavigationController.class]) return;
    for (UIViewController* controller in navigation.viewControllers)
        if ([controller isKindOfClass:ProtectorControllerTableController.class]) {
            ProtectorControllerTableController* settings = (ProtectorControllerTableController*)controller;
            settings.controllerNavigationActive = self.activeController != nil;
            if (settings.isViewLoaded) [settings.tableView reloadData];
        }
}
- (void)suspendGame {
    if (self.resignedAt == 0) self.resignedAt = CACurrentMediaTime();
    [self clearControls];
    [self.session setPaused:YES];
}
- (void)didEnterBackground {
    self.enteredBackground = YES;
    // A suspended app holding hundreds of MB of rebuildable textures is an
    // early jetsam target; release them while the game is paused.
    [self.session.renderer trimCachesForMemoryPressure];
}
- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    const NSUInteger released = [self.session.renderer trimCachesForMemoryPressure];
    NSLog(@"memory warning: released %lu bytes of rebuildable caches", (unsigned long)released);
}
- (void)resumeGame {
    [self clearControls];
    // Leaving the app, or being inactive for over a second (a call, Control
    // Center, the app switcher), comes back to the Pause sheet instead of live
    // play. A shorter blip, such as touching a notification banner, resumes.
    const BOOL interrupted = self.enteredBackground ||
        (self.resignedAt > 0 && CACurrentMediaTime() - self.resignedAt > 1.0);
    self.enteredBackground = NO;
    self.resignedAt = 0;
    if (interrupted && !self.sourceGuideReturning && !self.manuallyPaused && !self.presentedViewController &&
        self.session && !self.session.finished) {
        [self togglePause];  // keeps the session paused and runs the usual neutral-input gate
        return;
    }
    if (self.sourceGuideReturning) {
        self.sourceGuideContinuePending = YES;
        ProtectorLiveInputDiagnostics input;
        protector_live_input_diagnostics(&input);
        self.sourceGuideNeutralStart = input.samples;
        self.sourceGuideContinueSample = 0;
        self.sourceGuideReturnDeadline = CACurrentMediaTime() + 3;
    }
    [self.session setPaused:self.manuallyPaused];
}
- (void)showStatus:(NSString*)message {
    const BOOL changed = ![self.status.text isEqualToString:message ? message : @""];
    self.status.text = message;
    self.statusScroll.hidden = message.length == 0;
    if (changed) {
        self.statusScroll.contentOffset = CGPointZero;
        [self.view setNeedsLayout];
        if (message.length && self.view.window)
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
    }
}
- (void)sessionFinished:(NSNotification*)notification {
    (void)notification;
    // The runtime posts from its worker. UIKit changes belong to the main queue.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self clearControls];
        [self controlsPreferenceChanged];
        [self updateDiagnostics:nil];
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    });
}
- (void)updateDiagnostics:(NSTimer*)timer {
    (void)timer;
    if (self.session.finished) self.saveWarningVisible = NO;
    if (!self.session.finished && !self.session.failure && self.scaleTrialStart > 0 &&
        CACurrentMediaTime() - self.scaleTrialStart >= 30) {
        // Thirty seconds of healthy play proves the chosen scale on this device.
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:ProtectorRenderScaleTrialKey];
        self.scaleTrialStart = 0;
    }
    if (self.session.failure) [self showStatus:ProtectorPlayerErrorText(self.session.failure)];
    else if (self.session.finished) [self showStatus:@"The game stopped. Reopen the app to try again. Progress after the last successful save may be lost."];
    if (timer) [self.session requestDiagnosticSnapshot];
    else [self.session saveDiagnosticSnapshot];
    NSMutableArray<NSDictionary*>* controls = [NSMutableArray array];
    for (UIButton* button in self.buttons) {
        CGRect frame = button.frame;
        ProtectorActionButton* action = (ProtectorActionButton*)button;
        [controls addObject:@{@"id":button.accessibilityIdentifier, @"label":button.accessibilityLabel,
            @"hidden":@(button.hidden), @"frame":@[@(frame.origin.x), @(frame.origin.y),
                @(frame.size.width), @(frame.size.height)],
            @"face_frame":NSStringFromCGRect(action.faceFrame),
            @"caption_visible":@(!action.actionLabel.hidden),
            @"caption_font_size":@(action.actionLabel.font.pointSize),
            @"held":@(action.actionHeld)}];
    }
    NSDictionary* receipt = @{@"schema":@"protector-native.ios-controls/v1",
        @"view_bounds":NSStringFromCGRect(self.view.bounds),
        @"safe_area":NSStringFromUIEdgeInsets(self.view.safeAreaInsets),
        @"controller_connected":@(self.activeController != nil),
        @"controller_input_source":self.controllerQA ? @"simulator-framework-snapshot" : @"hardware",
        @"controller_qa_commands":@(self.controllerQA.commandCount),
        @"controller_qa_last_command":self.controllerQA.lastCommand ? self.controllerQA.lastCommand : @"",
        @"controller_tick_count":@(self.controllerTickCount),
        @"controller_is_snapshot":@(self.activeController.isSnapshot),
        @"controller_menu_value":@(self.activeController.extendedGamepad.buttonMenu.value),
        @"controller_menu_pressed":@(self.activeController.extendedGamepad.buttonMenu.isPressed),
        @"controller_menu_element_available":@(self.activeController.extendedGamepad.buttonMenu != nil),
        @"controller_vendor":self.activeController.vendorName ? self.activeController.vendorName : @"",
        @"controller_category":self.activeController.productCategory ? self.activeController.productCategory : @"",
        @"controller_needs_neutral":@(self.controllerNeedsNeutral),
        @"manually_paused":@(self.manuallyPaused), @"touch_held":@(self.held),
        @"source_controls_guide_visible":@(self.sourceControlsGuide != nil),
        @"source_controls_guide_returning":@(self.sourceGuideReturning),
        @"source_guide_neutral_start":@(self.sourceGuideNeutralStart),
        @"source_guide_continue_sample":@(self.sourceGuideContinueSample),
        @"show_button_labels":@([NSUserDefaults.standardUserDefaults boolForKey:ProtectorTouchLabelsKey]),
        @"control_context":@(protector_ui_context_name(self.controlContext)),
        @"map_actions":@(self.mapActions),
        @"controller_continue_cue_visible":@(!self.continueCue.hidden),
        @"qte_prompts":@(self.session.renderer.qtePrompts),
        @"qte_pointer_domain":@(self.gameView.qtePointer),
        @"qte_cue_visible":@(!self.qteCue.hidden),
        @"qte_instruction":self.qteCue.instruction ? self.qteCue.instruction : @"",
        @"qte_cue_frame":NSStringFromCGRect(self.qteCue.frame),
        @"controls":controls};
    NSData* json = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:nil];
    if (json) [json writeToURL:[self.session.outputDirectory URLByAppendingPathComponent:@"native-controls.json"]
        options:NSDataWritingAtomic error:nil];
}
- (void)drawInMTKView:(MTKView*)view {
    if (!self.session) return;
    [self updateControlContext];
    if (self.sourceControlsGuide) return;
    self.gameView.presentationAspect = (float)self.session.renderer.presentationAspect;
    self.gameView.qtePointer=self.session.renderer.qtePointerActive;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable) return;
    NSError* error = nil;
    // Steady cadence: 60 while the GPU has headroom, otherwise a steady 30,
    // never a mix of the two. Display cadence only; guest timing is unchanged.
    const double now = CACurrentMediaTime();
    const int paced = protector_pacing_update(&_pacing, now, self.session.renderer.smoothedGPUSeconds,
        (int)NSProcessInfo.processInfo.thermalState);
    if (view.preferredFramesPerSecond != paced) view.preferredFramesPerSecond = paced;
    const NSInteger rate = view.preferredFramesPerSecond;
    const CFTimeInterval duration = rate > 0 ? 1.0 / rate : 0;
    if (![self.session.renderer presentLatestDrawable:drawable minimumDuration:duration error:&error]) {
        [self showStatus:ProtectorPlayerErrorText(error)];
        [self.session requestStop];
    }
}
- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    [self.session.renderer resetMotionHistory];
    if (self.session.renderer.nativeResolutionEnabled && size.width > 0 && size.height > 0) {
        NSError* error = nil;
        if (![self.session.renderer selectNativeRenderSize:size error:&error]) {
            [self showStatus:ProtectorPlayerErrorText(error)];
            [self.session requestStop];
        }
    }
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
// While playing, the screen edges belong to the game: a thumb that slides off
// a control must not open Control Center or go Home (the first swipe shows the
// system UI, a second one takes it). Pause, sheets and a finished session give
// the edges back to the system.
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    UIViewController* presented = self.presentedViewController;
    const BOOL playing = self.session && !self.session.finished && !self.manuallyPaused &&
        !(presented && !presented.isBeingDismissed);
    return playing ? UIRectEdgeAll : UIRectEdgeNone;
}
- (void)setManuallyPaused:(BOOL)manuallyPaused {
    _manuallyPaused = manuallyPaused;
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
}
// A touch on the game while a pad is connected brings the touch controls back,
// until the pad is used again; the settings switch stays the override.
- (void)touchedGameView {
    if (!self.activeController || self.touchWokeControls ||
        ![NSUserDefaults.standardUserDefaults boolForKey:ProtectorTouchHideWithControllerKey]) return;
    self.touchWokeControls = YES;
    [self controlsPreferenceChanged];
}
// Headphones or another external output went away: pause, as Apple's guidance
// asks of games, so the soundtrack does not suddenly play from the speaker.
- (void)audioRouteLost:(NSNotification*)notification {
    (void)notification;
    if (!self.session || self.session.finished || self.manuallyPaused || self.sourceGuideReturning ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.pauseReason = @"Audio device disconnected.";
    [self togglePause];
    self.pauseReason = nil;
}
@end

@interface ProtectorInteractiveSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic) UIWindow* window;
@end
@implementation ProtectorInteractiveSceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session
      options:(UISceneConnectionOptions*)options {
    (void)session; (void)options;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
#if PROTECTOR_IOS_EXTERNAL_CONTENT
    ProtectorContentImportController* importer=[[ProtectorContentImportController alloc] init];
    __weak ProtectorInteractiveSceneDelegate* weakSelf=self;
    importer.playContent=^(NSURL* root) {
        ProtectorInteractiveController* game=[[ProtectorInteractiveController alloc] init];
        game.contentRoot=root;
        weakSelf.window.rootViewController=game;
    };
    self.window.rootViewController=importer;
#else
    self.window.rootViewController = [[ProtectorInteractiveController alloc] init];
#endif
    [self.window makeKeyAndVisible];
}
@end

@interface ProtectorInteractiveAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ProtectorInteractiveAppDelegate
@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
            NSStringFromClass(ProtectorInteractiveAppDelegate.class));
    }
}
