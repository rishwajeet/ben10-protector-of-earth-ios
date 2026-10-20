#import "touch_settings.h"
#import "control_art.h"

NSString* const ProtectorTouchScaleKey = @"touch.scale.v1";
NSString* const ProtectorTouchOpacityKey = @"touch.opacity.v1";
NSString* const ProtectorTouchLabelsKey = @"touch.labels.v1";
NSString* const ProtectorTouchSwappedKey = @"touch.swapped.v1";
NSString* const ProtectorTouchHapticsKey = @"touch.haptics.v1";
NSString* const ProtectorTouchHideWithControllerKey = @"touch.hideWithController.v1";
NSString* const ProtectorRenderScaleKey = @"render.scale.v1";
NSString* const ProtectorRenderSmoothMotionKey = @"render.motion.v1";

void ProtectorRegisterTouchDefaults(void) {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        ProtectorTouchScaleKey:@1.0, ProtectorTouchOpacityKey:@0.85,
        ProtectorTouchLabelsKey:@NO,
        ProtectorTouchSwappedKey:@NO, ProtectorTouchHapticsKey:@YES,
        ProtectorTouchHideWithControllerKey:@YES,
        // Native resolution with Smooth motion is the shipped default.
        ProtectorRenderScaleKey:@0, ProtectorRenderSmoothMotionKey:@YES}];
}

static UIControl* ProtectorRowControl(UIView* view) {
    if ([view isKindOfClass:UIControl.class]) return (UIControl*)view;
    for (UIView* child in view.subviews) {
        UIControl* found = ProtectorRowControl(child);
        if (found) return found;
    }
    return nil;
}

// Resume is UIKit's prominent bar item. From iOS 26 it is a filled glass pill
// that takes its fill from the item's own tint rather than the inherited view
// tint, so it carries a deep green fill under a white title. Earlier systems
// draw it as bold tinted text, where white would vanish; keep the sheet tint.
static UIBarButtonItem* ProtectorResumeItem(id target, SEL action) {
    UIBarButtonItem* item = [[UIBarButtonItem alloc]
        initWithTitle:@"Resume" style:UIBarButtonItemStyleDone target:target action:action];
    if (@available(iOS 26.0, *)) {
        item.tintColor = ProtectorSettingsProminentTint();
        for (NSNumber* state in @[@(UIControlStateNormal), @(UIControlStateHighlighted)])
            [item setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor}
                forState:(UIControlState)state.unsignedIntegerValue];
    } else item.tintColor = ProtectorSettingsTint();
    return item;
}

@interface ProtectorControllerFocusOutline : UIView
@end
@implementation ProtectorControllerFocusOutline
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.isAccessibilityElement = NO;
        self.contentMode = UIViewContentModeRedraw;
        [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class, UITraitAccessibilityContrast.class]
            withAction:@selector(setNeedsDisplay)];
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    (void)rect;
    [UIColor.labelColor setStroke];
    UIBezierPath* outline = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 1, 1) cornerRadius:10];
    outline.lineWidth = 2;
    [outline stroke];
}
@end

@implementation ProtectorControllerTableController
- (void)decorateControllerCell:(UITableViewCell*)cell path:(NSIndexPath*)path {
    BOOL focused = self.controllerNavigationActive && [path isEqual:self.controllerSelection];
    ProtectorControllerFocusOutline* outline = [cell viewWithTag:19417];
    if (focused && !outline) {
        // Keep the focus outline above the grouped background's edge mask;
        // UIKit otherwise drops interior borders between adjacent rows.
        outline = [[ProtectorControllerFocusOutline alloc] initWithFrame:CGRectInset(cell.bounds, 4, 4)];
        outline.tag = 19417;
        outline.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cell addSubview:outline];
    }
    outline.hidden = !focused;
    if (focused) cell.accessibilityTraits |= UIAccessibilityTraitSelected;
    else cell.accessibilityTraits &= ~UIAccessibilityTraitSelected;
}
- (void)refreshControllerSelection {
    for (NSIndexPath* path in self.tableView.indexPathsForVisibleRows)
        [self decorateControllerCell:[self.tableView cellForRowAtIndexPath:path] path:path];
}
- (void)setControllerNavigationActive:(BOOL)active {
    _controllerNavigationActive = active;
    if (active && !self.controllerSelection)
        self.controllerSelection = [NSIndexPath indexPathForRow:0 inSection:0];
    if (self.isViewLoaded) [self refreshControllerSelection];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // One game-green tint for the sheet's switches, sliders and guide glyphs;
    // the bar's own tint carries the native back chevron. Resume sets its own
    // fill. UIKit structure and semantic text colors stay native.
    self.navigationController.view.tintColor = ProtectorSettingsTint();
    self.navigationController.navigationBar.tintColor = ProtectorSettingsTint();
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshControllerSelection];
}
- (void)tableView:(UITableView*)tableView willDisplayCell:(UITableViewCell*)cell forRowAtIndexPath:(NSIndexPath*)path {
    (void)tableView;
    [self decorateControllerCell:cell path:path];
}
- (void)tableView:(UITableView*)tableView willDisplayFooterView:(UIView*)view forSection:(NSInteger)section {
    (void)tableView; (void)section;
    if ([view isKindOfClass:UITableViewHeaderFooterView.class])
        ((UITableViewHeaderFooterView*)view).textLabel.textColor = UIColor.labelColor;
}
- (void)selectControllerRow:(NSIndexPath*)path {
    BOOL changed = ![path isEqual:self.controllerSelection];
    self.controllerSelection = path;
    UIEdgeInsets insets = self.tableView.adjustedContentInset;
    CGFloat available = self.tableView.bounds.size.height - insets.top - insets.bottom;
    BOOL oversized = [self.tableView rectForRowAtIndexPath:path].size.height > available;
    if (!oversized || changed)
        [self.tableView scrollToRowAtIndexPath:path atScrollPosition:oversized
            ? UITableViewScrollPositionTop : UITableViewScrollPositionNone animated:NO];
    [self.tableView layoutIfNeeded];
    [self refreshControllerSelection];
}
- (BOOL)scrollInsideSelectedRow:(ProtectorMenuCommand)command {
    if (!self.controllerSelection || (command != PROTECTOR_MENU_DOWN && command != PROTECTOR_MENU_UP)) return NO;
    CGRect row = [self.tableView rectForRowAtIndexPath:self.controllerSelection];
    UIEdgeInsets insets = self.tableView.adjustedContentInset;
    CGFloat height = self.tableView.bounds.size.height - insets.top - insets.bottom;
    if (height <= 0 || row.size.height <= height) return NO;
    CGFloat top = self.tableView.contentOffset.y + insets.top;
    CGFloat remaining = command == PROTECTOR_MENU_DOWN ? CGRectGetMaxY(row) - (top + height) : top - row.origin.y;
    if (remaining <= 1) return NO;
    CGFloat delta = fmin(remaining, height * .65) * (command == PROTECTOR_MENU_DOWN ? 1 : -1);
    [self.tableView setContentOffset:CGPointMake(self.tableView.contentOffset.x,
        self.tableView.contentOffset.y + delta) animated:NO];
    return YES;
}
- (void)handleControllerCommand:(ProtectorMenuCommand)command {
    if (command == PROTECTOR_MENU_NONE) return;
    if ([self.presentedViewController isKindOfClass:UIAlertController.class]) {
        // Presentation failures have one acknowledgement action. Back/Confirm
        // dismiss only the alert; neither can leak into the row underneath.
        if (command == PROTECTOR_MENU_CONFIRM || command == PROTECTOR_MENU_BACK)
            [self dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
        return;
    }
    if (self.navigationController.transitionCoordinator) return;
    self.controllerNavigationActive = YES;
    if (command == PROTECTOR_MENU_BACK) {
        if (self.navigationController.viewControllers.count > 1)
            [self.navigationController popViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled()];
        else if ([self respondsToSelector:@selector(resume)]) [self performSelector:@selector(resume)];
        return;
    }
    // At accessibility text sizes a single instruction may exceed the entire
    // landscape sheet. Read through that row before advancing past it.
    if ([self scrollInsideSelectedRow:command]) return;
    NSMutableArray<NSIndexPath*>* paths = [NSMutableArray array];
    for (NSInteger section = 0; section < self.tableView.numberOfSections; ++section)
        for (NSInteger row = 0; row < [self.tableView numberOfRowsInSection:section]; ++row)
            [paths addObject:[NSIndexPath indexPathForRow:row inSection:section]];
    if (!paths.count) return;
    NSUInteger index = [paths indexOfObject:self.controllerSelection];
    if (index == NSNotFound) index = 0;
    if (command == PROTECTOR_MENU_UP && index > 0) --index;
    if (command == PROTECTOR_MENU_DOWN && index + 1 < paths.count) ++index;
    [self selectControllerRow:paths[index]];
    if (command == PROTECTOR_MENU_UP || command == PROTECTOR_MENU_DOWN) return;
    UITableViewCell* cell = [self.tableView cellForRowAtIndexPath:self.controllerSelection];
    UIControl* control = ProtectorRowControl(cell.accessoryView);
    if (!control) control = ProtectorRowControl(cell.contentView);
    if (!control) {
        if (command == PROTECTOR_MENU_CONFIRM &&
            [self respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)])
            [self tableView:self.tableView didSelectRowAtIndexPath:self.controllerSelection];
        return;
    }
    if (!control.enabled) return;
    const NSInteger direction = command == PROTECTOR_MENU_LEFT ? -1 :
        (command == PROTECTOR_MENU_RIGHT ? 1 : 0);
    BOOL changed = NO;
    if ([control isKindOfClass:UISwitch.class]) {
        UISwitch* toggle = (UISwitch*)control;
        const BOOL value = direction ? direction > 0 : !toggle.on;
        changed = value != toggle.on;
        [toggle setOn:value animated:!UIAccessibilityIsReduceMotionEnabled()];
    } else if ([control isKindOfClass:UISlider.class] && direction) {
        UISlider* slider = (UISlider*)control;
        float step = [control.accessibilityIdentifier isEqual:ProtectorTouchScaleKey] ? .05f : .10f;
        float value = fminf(slider.maximumValue, fmaxf(slider.minimumValue, slider.value + direction * step));
        changed = value != slider.value;
        [slider setValue:value animated:!UIAccessibilityIsReduceMotionEnabled()];
    } else if ([control isKindOfClass:UISegmentedControl.class] && direction) {
        UISegmentedControl* segments = (UISegmentedControl*)control;
        NSInteger value = segments.selectedSegmentIndex + direction;
        if (value < 0) value = 0;
        if (value >= (NSInteger)segments.numberOfSegments) value = (NSInteger)segments.numberOfSegments - 1;
        changed = value != segments.selectedSegmentIndex && [segments isEnabledForSegmentAtIndex:value];
        if (changed) segments.selectedSegmentIndex = value;
    }
    if (changed) [control sendActionsForControlEvents:UIControlEventValueChanged];
    [self refreshControllerSelection];
}
@end

@interface ProtectorControlsGuideController ()
@property(nonatomic) UISegmentedControl* modeControl;
@property(nonatomic) BOOL returnInProgress;
@end

@implementation ProtectorControlsGuideController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Controls";
    self.navigationItem.rightBarButtonItem = self.fromGameMenu ?
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(resume)] :
        ProtectorResumeItem(self, @selector(resume));
    if (self.fromGameMenu) {
        UIBarButtonItem* done = self.navigationItem.rightBarButtonItem;
        done.accessibilityIdentifier = @"native-guide-done";
        // System Done keeps its native check presentation, but its prominent
        // fill needs the item's own tint just like the incumbent Resume pill.
        if (@available(iOS 26.0, *)) done.tintColor = ProtectorSettingsProminentTint();
        else done.tintColor = ProtectorSettingsTint();
    }
    self.tableView.accessibilityIdentifier = @"native-controls-guide";
    self.tableView.estimatedRowHeight = 88;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    UISegmentedControl* mode = [[UISegmentedControl alloc] initWithItems:@[@"Touch", @"Controller"]];
    mode.selectedSegmentIndex = self.controllerMode ? 1 : 0;
    self.modeControl = mode;
    mode.accessibilityLabel = @"Controls guide input type";
    mode.accessibilityIdentifier = @"controls-guide-mode";
    [mode addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    UIView* header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 68)];
    mode.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:mode];
    [NSLayoutConstraint activateConstraints:@[
        [mode.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor],
        [mode.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor],
        [mode.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [mode.heightAnchor constraintEqualToConstant:44]]];
    self.tableView.tableHeaderView = header;
}
- (void)resume { if (!self.returnInProgress && self.resumeGame) self.resumeGame(); }
- (void)setReturnInProgress:(BOOL)returning {
    _returnInProgress = returning;
    self.navigationItem.rightBarButtonItem.enabled = !returning;
    self.tableView.userInteractionEnabled = !returning;
}
- (void)modeChanged:(UISegmentedControl*)control {
    self.controllerMode = control.selectedSegmentIndex == 1;
    [self.tableView reloadData];
}
- (void)handleControllerCommand:(ProtectorMenuCommand)command {
    if (self.returnInProgress) return;
    if (command == PROTECTOR_MENU_LEFT || command == PROTECTOR_MENU_RIGHT) {
        if (self.navigationController.transitionCoordinator) return;
        self.modeControl.selectedSegmentIndex = command == PROTECTOR_MENU_RIGHT ? 1 : 0;
        [self modeChanged:self.modeControl];
        [self selectControllerRow:self.controllerSelection ? self.controllerSelection : [NSIndexPath indexPathForRow:0 inSection:0]];
        return;
    }
    [super handleControllerCommand:command];
}
- (NSArray<NSArray*>*)rowsForSection:(NSInteger)section {
    // Action, the overlay's authored glyph, touch instruction, controller
    // instruction. Face-button positions stay truthful across Xbox,
    // PlayStation and MFi label families.
    if (section == 0) return @[
        @[@"Move", @(ProtectorGlyphMove), @"Drag the movement stick. Lift your thumb to stop.", @"Use the left stick."],
        @[@"Attack", @(ProtectorGlyphAttack), @"Tap Attack for a light attack.", @"Press the bottom face button (A / cross)."],
        @[@"Heavy attack", @(ProtectorGlyphHeavy), @"Tap Heavy.", @"Press the right face button (B / circle)."],
        @[@"Block", @(ProtectorGlyphBlock), @"Hold the shield button to block.", @"Hold the left face button (X / square)."],
        @[@"Jump", @(ProtectorGlyphJump), @"Tap Jump.", @"Press the top face button (Y / triangle) or the left shoulder button."]];
    if (section == 1) return @[
        @[@"Choose an alien", @(ProtectorGlyphChooseAlien), @"Use the curved arrows on either side of the Omnitrix dial.", @"Press left or right on the directional pad."],
        @[@"Transform", @(ProtectorGlyphTransform), @"Tap the Omnitrix dial between the alien-selection arrows to transform.", @"Press up on the directional pad."],
        @[@"Special attack", @(ProtectorGlyphSpecial), @"Tap the lightning-bolt button.", @"Press down on the directional pad."]];
    return @[
        @[@"Confirm and go back", @(ProtectorGlyphConfirm), @"Tap Confirm when shown, or Attack on screens with the full controls. Back or Heavy goes back. In the game's root pause menu, choose Keep Playing to return.", @"The bottom face button confirms; the right face button goes back. When touch controls are hidden, a Confirm hint shows which button to press. In the game's root pause menu, choose Keep Playing to return."],
        @[@"Move through game menus", @(ProtectorGlyphNavigate), @"Use the menu arrows. On screens with the full controls, Transform moves up and Special moves down.", @"Use the directional pad."],
        @[@"Pause and settings", @(ProtectorGlyphPause), @"Tap Pause. Use Open game menu for the game's own menu.", @"Menu opens Pause or resumes. Use the directional pad or left stick to choose a row; left and right adjust it. The bottom face button selects or toggles; the right face button goes back."],
        @[@"Aim and point", @(ProtectorGlyphAim), @"Touch or drag on the game image when an interaction uses a pointer.", @"Use the right stick. Hold the right shoulder button to keep the pointer active at the centre."],
        @[@"Closeup camera", @(ProtectorGlyphAim), @"Enable Closeup Camera in Extras, then Secrets. During play, open Pause and choose Camera to resume and toggle the view.", @"Enable Closeup Camera in Extras, then Secrets. During play, press the right stick, or choose Camera in Pause. This input does not enable the secret."],
        @[@"Motion interactions", @(ProtectorGlyphInteract), @"Hold Interact when the game asks for shaking. You do not need to move your phone.", @"Hold the right trigger for the primary motion action, the left trigger for the secondary action, or both when prompted."],
        @[@"Boss transform prompts", @(ProtectorGlyphTransform), @"Tap the Omnitrix dial when a boss prompt asks you to transform.", @"Press the View button (Xbox), Create button (PlayStation) or − button (Switch). This is not the Menu button, which opens Pause."]];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return [self rowsForSection:section].count;
}
- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return @[@"Move and fight", @"The Omnitrix", @"Menus and interactions"][section];
}
- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 2 && self.fromGameMenu)
        return @"The game stays paused while you read. Done returns to Options. With a controller, up and down move through this guide; left and right switch Touch and Controller. The right face button or Menu returns to Options. Reading this guide does not change your control configuration.";
    return section == 2 ? @"The game stays paused while you read. With a controller, up and down move through this guide; left and right switch Touch and Controller. Some game screens still show original controller symbols; use these native controls instead." : nil;
}
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
    (void)tableView;
    NSArray* row = [self rowsForSection:path.section][path.row];
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration* content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = row[0];
    content.secondaryText = row[self.controllerMode ? 3 : 2];
    content.textProperties.numberOfLines = 0;
    content.secondaryTextProperties.numberOfLines = 0;
    // These instructions are essential reading, not muted metadata. The
    // default subtitle tint falls below normal-text contrast in light mode.
    content.secondaryTextProperties.color = UIColor.labelColor;
    // The overlay's own authored glyphs, tinted by the sheet.
    content.image = ProtectorGlyphTemplateImage((ProtectorGlyph)[row[1] integerValue], 28);
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessibilityIdentifier = [NSString stringWithFormat:@"controls-guide-%ld-%ld", (long)path.section, (long)path.row];
    // Read the action and instruction together; decorative glyph images are
    // not additional VoiceOver stops.
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", row[0], row[self.controllerMode ? 3 : 2]];
    return cell;
}
@end

@implementation ProtectorTouchSettingsController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Paused";
    self.navigationItem.rightBarButtonItem = ProtectorResumeItem(self, @selector(resume));
    self.tableView.estimatedRowHeight = 64;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.accessibilityIdentifier = @"native-game-settings";
}
- (void)resume { if (self.resumeGame) self.resumeGame(); }
- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? (self.changeCamera ? 3 : 2) : (section == 1 ? 7 : 2);
}
- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"Game" : (section == 1 ? @"Touch controls" : @"Display");
}
- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        // The reason a pause began on its own comes first, so it is the first thing read.
        NSString* reason = self.pauseReason.length ? [self.pauseReason stringByAppendingString:@" "] : @"";
        return [reason stringByAppendingString:self.controllerNavigationActive
            ? @"Up/down chooses a row. Left/right adjusts it. Bottom face button selects; right face button goes back. Menu resumes. The game stays paused. In the game, sound follows your iPhone’s Silent switch."
            : @"The game stays paused while you adjust settings. In the game, sound follows your iPhone’s Silent switch."];
    }
    if (section == 1) return @"Button labels are optional during play and stay visible in menus. Labels keep a dark outline for contrast. Open Controls guide for all touch and controller actions.";
    return @"Native matches your screen and is recommended. Lower scales use less graphics memory. 6× renders up to 4K width, runs hotter and uses more battery. Your choices are remembered. These settings do not change game speed.";
}
- (UITableViewCell*)textCell:(NSString*)title symbol:(NSString*)symbol {
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration* content = cell.defaultContentConfiguration;
    content.text = title;
    content.textProperties.numberOfLines = 0;
    content.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    cell.contentConfiguration = content;
    return cell;
}
- (UITableViewCell*)controlCell:(NSString*)title control:(UIControl*)control {
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.accessibilityIdentifier = [control.accessibilityIdentifier stringByAppendingString:@"-row"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UILabel* label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    control.accessibilityLabel = title;
    UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, control]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12],
        [control.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
    return cell;
}
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
    (void)tableView;
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    if (path.section == 0) {
        if (path.row == 2 && self.changeCamera) {
            UITableViewCell* cell = [self textCell:@"Camera" symbol:@"viewfinder"];
            UIListContentConfiguration* content = (UIListContentConfiguration*)cell.contentConfiguration;
            content.secondaryText = @"Resume and toggle the closeup view. Enable Closeup Camera in Secrets first.";
            content.secondaryTextProperties.numberOfLines = 0;
            content.secondaryTextProperties.color = UIColor.labelColor;
            cell.contentConfiguration = content;
            cell.accessibilityIdentifier = @"change-game-camera";
            return cell;
        }
        UITableViewCell* cell = [self textCell:path.row == 0 ? @"Open game menu" : @"Controls guide"
            symbol:path.row == 0 ? @"line.3.horizontal" : @"gamecontroller"];
        cell.accessibilityIdentifier = @"open-game-menu";
        if (path.row == 1) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.accessibilityIdentifier = @"open-controls-guide";
        }
        return cell;
    }
    if (path.section == 1 && path.row < 2) {
        UISlider* slider = [[UISlider alloc] init];
        slider.accessibilityIdentifier = path.row == 0 ? ProtectorTouchScaleKey : ProtectorTouchOpacityKey;
        slider.minimumValue = path.row == 0 ? 0.85f : 0.50f;
        slider.maximumValue = path.row == 0 ? 1.25f : 1.0f;
        slider.value = [defaults floatForKey:slider.accessibilityIdentifier];
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        return [self controlCell:path.row == 0 ? @"Control size" : @"Control opacity" control:slider];
    }
    if (path.section == 1 && path.row < 6) {
        NSArray<NSString*>* titles = @[@"Show button labels", @"Swap thumb sides", @"Button haptics", @"Hide touch controls with a controller"];
        NSArray<NSString*>* keys = @[ProtectorTouchLabelsKey, ProtectorTouchSwappedKey, ProtectorTouchHapticsKey, ProtectorTouchHideWithControllerKey];
        UISwitch* toggle = [[UISwitch alloc] init];
        toggle.accessibilityIdentifier = keys[path.row - 2];
        toggle.accessibilityLabel = titles[path.row - 2];
        toggle.on = [defaults boolForKey:toggle.accessibilityIdentifier];
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        UITableViewCell* cell = [self textCell:titles[path.row - 2] symbol:nil];
        cell.accessibilityIdentifier = [toggle.accessibilityIdentifier stringByAppendingString:@"-row"];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (path.section == 1) {
        UITableViewCell* cell = [self textCell:@"Reset touch controls" symbol:@"arrow.counterclockwise"];
        cell.accessibilityIdentifier = @"reset-touch-controls";
        return cell;
    }
    if (path.row == 0) {
        UISegmentedControl* quality = [[UISegmentedControl alloc] initWithItems:@[@"1×", @"2×", @"3×", @"Native", @"6×"]];
        quality.accessibilityIdentifier = @"render.scale";
        quality.selectedSegmentIndex = self.renderScale == 0 ? 3 : self.renderScale == 6 ? 4 : (NSInteger)self.renderScale - 1;
        quality.accessibilityHint = @"Native matches the screen and is recommended. Lower scales use less graphics memory. 6 times runs hotter and uses more battery.";
        [quality addTarget:self action:@selector(qualityChanged:) forControlEvents:UIControlEventValueChanged];
        return [self controlCell:@"Render resolution" control:quality];
    }
    if (path.row == 1) {
        UISwitch* toggle = [[UISwitch alloc] init];
        toggle.accessibilityIdentifier = @"render.motion";
        toggle.accessibilityLabel = @"Smooth motion";
        toggle.on = self.smoothMotion;
        toggle.enabled = self.hasSmoothMotion;
        NSString* explanation = @"Adds in-between frames where safe, with about 33 ms of display delay. Turn off for lower input delay.";
        toggle.accessibilityHint = explanation;
        [toggle addTarget:self action:@selector(renderToggleChanged:) forControlEvents:UIControlEventValueChanged];
        UITableViewCell* cell = [self textCell:toggle.accessibilityLabel symbol:nil];
        UIListContentConfiguration* content = [UIListContentConfiguration subtitleCellConfiguration];
        content.text = toggle.accessibilityLabel;
        content.secondaryText = explanation;
        content.textProperties.numberOfLines = 0;
        content.secondaryTextProperties.numberOfLines = 0;
        content.secondaryTextProperties.color = UIColor.labelColor;
        cell.contentConfiguration = content;
        cell.accessibilityIdentifier = @"render.motion-row";
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}
- (void)sliderChanged:(UISlider*)slider {
    [NSUserDefaults.standardUserDefaults setFloat:slider.value forKey:slider.accessibilityIdentifier];
    if (self.preferencesChanged) self.preferencesChanged();
}
- (void)toggleChanged:(UISwitch*)toggle {
    [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:toggle.accessibilityIdentifier];
    if (self.preferencesChanged) self.preferencesChanged();
}
- (void)showFailure:(NSString*)message {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Presentation unchanged"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)qualityChanged:(UISegmentedControl*)control {
    const NSUInteger scales[] = {1, 2, 3, 0, 6};
    if (control.selectedSegmentIndex < 0 || control.selectedSegmentIndex >= 5) return;
    NSString* failure = self.selectRendering ? self.selectRendering(@"scale", scales[control.selectedSegmentIndex]) : @"The game is not available.";
    if (failure) {
        control.selectedSegmentIndex = self.renderScale == 0 ? 3 : self.renderScale == 6 ? 4 : (NSInteger)self.renderScale - 1;
        [self showFailure:failure];
    } else self.renderScale = scales[control.selectedSegmentIndex];
}
- (void)renderToggleChanged:(UISwitch*)toggle {
    NSString* failure = self.selectRendering ? self.selectRendering(@"motion", toggle.on) : @"The game is not available.";
    if (failure) { toggle.on = !toggle.on; [self showFailure:failure]; }
    else self.smoothMotion = toggle.on;
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0 && path.row == 0) { if (self.openGameMenu) self.openGameMenu(); }
    else if (path.section == 0 && path.row == 2) { if (self.changeCamera) self.changeCamera(); }
    else if (path.section == 0 && path.row == 1) {
        ProtectorControlsGuideController* guide = [[ProtectorControlsGuideController alloc] init];
        guide.resumeGame = self.resumeGame;
        guide.controllerMode = self.controllerNavigationActive;
        guide.controllerNavigationActive = self.controllerNavigationActive;
        [self.navigationController pushViewController:guide animated:!UIAccessibilityIsReduceMotionEnabled()];
    }
    else if (path.section == 1 && path.row == 6) {
        for (NSString* key in @[ProtectorTouchScaleKey, ProtectorTouchOpacityKey,
                ProtectorTouchLabelsKey, ProtectorTouchSwappedKey, ProtectorTouchHapticsKey, ProtectorTouchHideWithControllerKey])
            [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        if (self.preferencesChanged) self.preferencesChanged();
        [self.tableView reloadData];
    }
}
@end
