#import "content_import.h"
#import "../apple/content_store.h"
#import "save_backup_controller.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface ProtectorContentImportController () <UIDocumentPickerDelegate>
@property(nonatomic) ProtectorContentStore* store;
@property(nonatomic) NSURL* activeRoot;
@property(nonatomic) UILabel* status;
@property(nonatomic) UIProgressView* progress;
@property(nonatomic) UIButton* importButton;
@property(nonatomic) UIButton* playButton;
@property(nonatomic) UIButton* cancelButton;
@property(nonatomic) UIButton* savesButton;
@property(nonatomic) UIButton* aboutButton;
@property(atomic) BOOL cancelRequested;
@property(nonatomic) BOOL importing;
@property(nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@end

@implementation ProtectorContentImportController
- (UILabel*)label:(NSString*)text style:(UIFontTextStyle)style {
    UILabel* label=[[UILabel alloc] init];
    label.text=text;
    label.font=[UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory=YES;
    label.numberOfLines=0;
    label.textColor=UIColor.labelColor;
    return label;
}
- (UIButton*)button:(NSString*)title action:(SEL)action prominent:(BOOL)prominent {
    UIButtonConfiguration* config=prominent ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.plainButtonConfiguration;
    config.title=title;
    config.buttonSize=UIButtonConfigurationSizeLarge;
    config.titleLineBreakMode=NSLineBreakByWordWrapping;
    if (prominent) {
        config.baseBackgroundColor=[UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
            return traits.userInterfaceStyle==UIUserInterfaceStyleDark ?
                [UIColor colorWithRed:.12 green:.50 blue:.12 alpha:1] :
                [UIColor colorWithRed:.10 green:.45 blue:.10 alpha:1];
        }];
        config.baseForegroundColor=UIColor.whiteColor;
    }
    UIButton* button=[UIButton buttonWithConfiguration:config primaryAction:nil];
    button.titleLabel.adjustsFontForContentSizeCategory=YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.backgroundTask=UIBackgroundTaskInvalid;
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    self.view.tintColor=[UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
        return traits.userInterfaceStyle==UIUserInterfaceStyleDark ?
            [UIColor colorWithRed:.30 green:.68 blue:.20 alpha:1] :
            [UIColor colorWithRed:.10 green:.45 blue:.10 alpha:1];
    }];
    NSURL* support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    self.store=[[ProtectorContentStore alloc] initWithRoot:[support URLByAppendingPathComponent:@"PersonalContent" isDirectory:YES]];
    // Make the Finder File Sharing inbox visible before the first import.
    NSURL* documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [NSFileManager.defaultManager createDirectoryAtURL:documents withIntermediateDirectories:YES attributes:nil error:nil];
    UIScrollView* scroll=[[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:scroll];
    UIStackView* stack=[[UIStackView alloc] init];
    stack.axis=UILayoutConstraintAxisVertical;
    stack.spacing=12;
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    [scroll addSubview:stack];
    UILabel* title=[self label:@"Bring your game" style:UIFontTextStyleTitle1];
    title.accessibilityTraits|=UIAccessibilityTraitHeader;
    [stack addArrangedSubview:title];
    [stack addArrangedSubview:[self label:@"Choose your Mac-built .pnc content package." style:UIFontTextStyleBody]];
    self.status=[self label:@"Checking imported content…" style:UIFontTextStyleBody];
    self.status.accessibilityIdentifier=@"content-import-status";
    [stack addArrangedSubview:self.status];
    self.progress=[[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progress.hidden=YES;
    self.progress.accessibilityLabel=@"Content import progress";
    [stack addArrangedSubview:self.progress];
    self.importButton=[self button:@"Choose content package" action:@selector(choosePackage) prominent:YES];
    self.importButton.accessibilityIdentifier=@"choose-content-package";
    self.importButton.enabled=NO;
    [stack addArrangedSubview:self.importButton];
    self.playButton=[self button:@"Play" action:@selector(play) prominent:NO];
    self.playButton.accessibilityIdentifier=@"play-imported-content";
    self.playButton.hidden=YES;
    [stack addArrangedSubview:self.playButton];
    self.cancelButton=[self button:@"Cancel import" action:@selector(cancelImport) prominent:NO];
    self.cancelButton.hidden=YES;
    [stack addArrangedSubview:self.cancelButton];
    self.savesButton=[self button:@"Save backups" action:@selector(manageSaves) prominent:NO];
    self.savesButton.accessibilityIdentifier=@"manage-save-backups";
    [stack addArrangedSubview:self.savesButton];
    self.aboutButton=[self button:@"About and licences" action:@selector(showAbout) prominent:NO];
    self.aboutButton.accessibilityIdentifier=@"about-and-licences";
    [stack addArrangedSubview:self.aboutButton];
    [stack addArrangedSubview:[self label:@"Built from your own supported game copy. To transfer by USB, open Finder → your iPhone or iPad → Files → Protector Native, then drag the package into the app." style:UIFontTextStyleBody]];
    UILabel* footer=[self label:@"Importing does not change your saves. Keep this screen open until verification finishes." style:UIFontTextStyleFootnote];
    [stack addArrangedSubview:footer];
    UILayoutGuide* safe=self.view.safeAreaLayoutGuide;
    NSLayoutConstraint* preferred=[stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40];
    preferred.priority=UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:640], preferred]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError* error=nil;
        NSURL* active=[self.store activeContent:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.activeRoot=active;
            self.playButton.hidden=!active;
            self.importButton.enabled=YES;
            self.status.text=error ? error.localizedDescription : active ? @"Your content is ready to play." : @"No content imported yet.";
        });
    });
}
- (void)choosePackage {
    if (self.importing) return;
    UTType* type=[UTType typeWithFilenameExtension:@"pnc"];
    if (!type) type=UTTypeData;
    UIDocumentPickerViewController* picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[type] asCopy:NO];
    picker.delegate=self;
    picker.allowsMultipleSelection=NO;
    picker.directoryURL=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    (void)controller;
    if (self.importing || !urls.count) return;
    NSURL* url=urls.firstObject;
    BOOL scoped=[url startAccessingSecurityScopedResource];
    self.importing=YES;
    self.cancelRequested=NO;
    self.importButton.enabled=NO;
    self.playButton.enabled=NO;
    self.savesButton.enabled=NO;
    self.aboutButton.enabled=NO;
    self.cancelButton.hidden=NO;
    self.cancelButton.enabled=YES;
    self.progress.hidden=NO;
    self.progress.progress=0;
    self.status.text=@"Verifying and importing your content…";
    UIApplication.sharedApplication.idleTimerDisabled=YES;
    __weak ProtectorContentImportController* weakSelf=self;
    self.backgroundTask=[UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{ weakSelf.cancelRequested=YES; }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        __block NSError* error=nil;
        __block NSURL* result=nil;
        __block NSInteger lastPercent=-1;
        NSFileCoordinator* coordinator=[[NSFileCoordinator alloc] init];
        [coordinator coordinateReadingItemAtURL:url options:0 error:&error byAccessor:^(NSURL* readable) {
            result=[self.store importPackage:readable progress:^(double fraction) {
                NSInteger percent=(NSInteger)(fraction*100);
                if (percent==lastPercent) return;
                lastPercent=percent;
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.progress.progress=(float)fraction;
                    self.status.text=[NSString stringWithFormat:@"Verifying and importing… %ld%%",(long)percent];
                });
            } cancelled:^BOOL { return self.cancelRequested; } error:&error];
        }];
        if (scoped) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.importing=NO;
            UIApplication.sharedApplication.idleTimerDisabled=NO;
            if (self.backgroundTask!=UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];
                self.backgroundTask=UIBackgroundTaskInvalid;
            }
            self.cancelButton.hidden=YES;
            self.progress.hidden=YES;
            self.importButton.enabled=YES;
            self.playButton.enabled=YES;
            self.savesButton.enabled=YES;
    self.aboutButton.enabled=YES;
            if (result) self.activeRoot=result;
            self.playButton.hidden=!self.activeRoot;
            self.status.text=result ? @"Content verified. Ready to play. The transferred .pnc file is still in Files; you can remove that copy to free space." :
                (error ? error.localizedDescription : @"Import could not finish. Choose the package to try again.");
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,self.status.text);
        });
    });
}
- (void)cancelImport {
    self.cancelRequested=YES;
    self.cancelButton.enabled=NO;
    self.status.text=@"Cancelling import…";
}
- (void)play {
    if (!self.importing && self.activeRoot && self.playContent) self.playContent(self.activeRoot);
}
- (void)manageSaves {
    if (self.importing || self.presentedViewController) return;
    NSURL* support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    // Matches SessionSaveDirectory's enhanced sibling of Original/RBNEG9.
    NSURL* saves=[support URLByAppendingPathComponent:@"Original/UpgradedSaves-RBNEG9-v1" isDirectory:YES];
    ProtectorSaveBackupController* controller=[[ProtectorSaveBackupController alloc] initWithSaveDirectory:saves];
    UINavigationController* navigation=[[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle=UIModalPresentationPageSheet;
    navigation.view.tintColor=self.view.tintColor;
    navigation.sheetPresentationController.detents=@[UISheetPresentationControllerDetent.largeDetent];
    navigation.sheetPresentationController.prefersGrabberVisible=YES;
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)showAbout {
    if (self.importing || self.presentedViewController) return;
    UIViewController* controller=[[UIViewController alloc] init];
    controller.title=@"About and licences";
    controller.view.backgroundColor=UIColor.systemBackgroundColor;
    UITextView* text=[[UITextView alloc] init];
    text.editable=NO;
    text.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    text.adjustsFontForContentSizeCategory=YES;
    text.textContainerInset=UIEdgeInsetsMake(16,16,24,16);
    text.dataDetectorTypes=UIDataDetectorTypeLink;
    text.accessibilityIdentifier=@"about-text";
    text.text=@"Protector Native is an unofficial, fan-made native iPhone port of the Wii game Ben 10: Protector of Earth (USA, RBNEG9). "
        "It is not affiliated with, endorsed or sponsored by Warner Bros. Discovery, Cartoon Network, the game's publisher or its developer. "
        "Ben 10 and related names and characters are trademarks of their respective owners.\n\n"
        "This app contains no game. It runs only with content you convert yourself, on your own Mac, from a copy of the original disc that you own.\n\n"
        "Software licence\n"
        "The original Protector Native software is free software under the GNU General Public License, version 3 or (at your option) any later version. "
        "It comes with ABSOLUTELY NO WARRANTY. The complete source code, licence text and build instructions are published at "
        "https://github.com/rishwajeet/protector-native-kit\n\n"
        "This licence covers the project's own software only. It grants no rights in Ben 10, the original game, its code, audio, movies, textures or models, "
        "or in content converted from your disc.\n\n"
        "Third-party notices\n"
        "Dolphin (https://dolphin-emu.org): portions of the audio engine and floating-point estimate tables are derived from Dolphin, "
        "Copyright Dolphin Emulator Project, licensed GPL-2.0-or-later.\n"
        "DolRecomp: the CPU interface and reset sequence follow DolRecomp, Copyright (C) 2026 ExpansionPak, licensed GPL-3.0-or-later. "
        "DolRecomp itself translates your game on your Mac and is not included in this app.\n"
        "Scene antialiasing follows the method described in Timothy Lottes' 2011 FXAA paper (NVIDIA).\n\n"
        "Enhanced artwork is reconstructed on your Mac with separately downloaded models: 4x-PBRify UpscalerV4 (Kim2091, CC0), "
        "ArtCNN (Artoriuz, MIT), HDcube 3 (Venomalia, its own terms), and Real-ESRGAN (Xintao Wang, BSD-3-Clause). No model weights are included in this app.";
    text.translatesAutoresizingMaskIntoConstraints=NO;
    [controller.view addSubview:text];
    [NSLayoutConstraint activateConstraints:@[
        [text.leadingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.leadingAnchor],
        [text.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor],
        [text.topAnchor constraintEqualToAnchor:controller.view.topAnchor],
        [text.bottomAnchor constraintEqualToAnchor:controller.view.bottomAnchor]]];
    controller.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        primaryAction:[UIAction actionWithHandler:^(UIAction* action) { (void)action; [controller dismissViewControllerAnimated:YES completion:nil]; }]];
    UINavigationController* navigation=[[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle=UIModalPresentationPageSheet;
    navigation.view.tintColor=self.view.tintColor;
    navigation.sheetPresentationController.detents=@[UISheetPresentationControllerDetent.largeDetent];
    navigation.sheetPresentationController.prefersGrabberVisible=YES;
    [self presentViewController:navigation animated:YES completion:nil];
}
@end
