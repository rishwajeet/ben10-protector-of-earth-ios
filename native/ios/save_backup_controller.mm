#import "save_backup_controller.h"
#import "../apple/save_backup.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface ProtectorSaveBackupController () <UIDocumentPickerDelegate>
@property(nonatomic) NSURL* saveDirectory;
@property(nonatomic) NSURL* temporaryExport;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL exporting;
@property(nonatomic) NSString* statusText;
@end

@implementation ProtectorSaveBackupController
- (instancetype)initWithSaveDirectory:(NSURL*)directory {
    self=[super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _saveDirectory=directory;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"Save backups";
    self.tableView.accessibilityIdentifier=@"save-backup-table";
    self.tableView.rowHeight=UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight=72;
    self.statusText=@"Backups contain saved progress only—not game content.";
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(done)];
}
- (void)done { if (!self.busy) [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)setWorking:(BOOL)working message:(NSString*)message {
    self.busy=working;
    self.statusText=message;
    self.navigationController.modalInPresentation=working;
    self.navigationItem.rightBarButtonItem.enabled=!working;
    [self.tableView reloadData];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,message);
}
- (void)showMessage:(NSString*)title detail:(NSString*)detail {
    UIAlertController* alert=[UIAlertController alertControllerWithTitle:title message:detail preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section; return 2;
}
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
    UITableViewCell* cell=[tableView dequeueReusableCellWithIdentifier:@"save-action"];
    if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"save-action"];
    UIListContentConfiguration* content=[UIListContentConfiguration subtitleCellConfiguration];
    content.text=path.row==0 ? @"Back up saved progress" : @"Restore saved progress";
    content.secondaryText=path.row==0 ? @"Choose a location in Files" : @"Choose a .pnsave backup";
    content.textProperties.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    content.textProperties.adjustsFontForContentSizeCategory=YES;
    content.textProperties.numberOfLines=0;
    content.textProperties.color=self.busy ? UIColor.secondaryLabelColor : self.view.tintColor;
    content.secondaryTextProperties.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    content.secondaryTextProperties.adjustsFontForContentSizeCategory=YES;
    content.secondaryTextProperties.numberOfLines=0;
    content.secondaryTextProperties.color=UIColor.labelColor;
    content.image=[UIImage systemImageNamed:path.row==0 ? @"square.and.arrow.up" : @"arrow.down.doc"];
    cell.contentConfiguration=content;
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    cell.userInteractionEnabled=!self.busy;
    cell.accessibilityTraits=UIAccessibilityTraitButton | (self.busy ? UIAccessibilityTraitNotEnabled : 0);
    cell.accessibilityIdentifier=path.row==0 ? @"backup-saved-progress" : @"restore-saved-progress";
    return cell;
}
- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return [NSString stringWithFormat:@"%@\n\nKeep your backup outside Protector Native, such as in iCloud Drive or on your Mac. Deleting the app also deletes files kept inside it.\n\nRestoring replaces saved progress. Before replacement, any current progress is copied to Files → Protector Native → Save Recovery.",self.statusText];
}
- (void)tableView:(UITableView*)tableView willDisplayFooterView:(UIView*)view forSection:(NSInteger)section {
    (void)tableView; (void)section;
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        // These instructions protect progress; do not use the system's faint
        // secondary footer treatment for the uninstall and recovery warnings.
        UITableViewHeaderFooterView* footer=(UITableViewHeaderFooterView*)view;
        footer.textLabel.textColor=UIColor.labelColor;
        footer.textLabel.adjustsFontForContentSizeCategory=YES;
    }
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.busy || self.presentedViewController) return;
    if (path.row==0) [self backUp]; else [self chooseRestore];
}
- (void)clearTemporaryExport {
    if (self.temporaryExport) {
        // This is the one UUID directory created by backUp, never a selected
        // destination or user-supplied file. The exported copy is unaffected.
        [NSFileManager.defaultManager removeItemAtURL:self.temporaryExport.URLByDeletingLastPathComponent error:nil];
        self.temporaryExport=nil;
    }
}
- (void)backUp {
    [self setWorking:YES message:@"Preparing your save backup…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError* error=nil;
        NSURL* parent=[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:[@"ProtectorSaveExport-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        BOOL created=[NSFileManager.defaultManager createDirectoryAtURL:parent withIntermediateDirectories:NO attributes:nil error:&error];
        NSURL* file=[parent URLByAppendingPathComponent:@"Protector-saved-progress.pnsave"];
        BOOL okay=created && [ProtectorSaveBackup exportDirectory:self.saveDirectory toURL:file error:&error] &&
            [ProtectorSaveBackup readFromURL:file error:&error]!=nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.temporaryExport=created ? file : nil;
            [self setWorking:NO message:okay ? @"Choose a location outside Protector Native." : @"Backup was not exported."];
            if (!okay) {
                [self clearTemporaryExport];
                NSString* detail=error.localizedDescription;
                [self showMessage:@"Couldn’t prepare a backup" detail:detail ? detail : @"No saved progress is available yet."];
                return;
            }
            self.exporting=YES;
            UIDocumentPickerViewController* picker=[[UIDocumentPickerViewController alloc] initForExportingURLs:@[file] asCopy:YES];
            picker.delegate=self;
            [self presentViewController:picker animated:YES completion:nil];
        });
    });
}
- (void)chooseRestore {
    self.exporting=NO;
    UTType* type=[UTType typeWithFilenameExtension:@"pnsave"];
    if (!type) type=UTTypeData;
    UIDocumentPickerViewController* picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[type] asCopy:NO];
    picker.allowsMultipleSelection=NO;
    picker.delegate=self;
    picker.directoryURL=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
    (void)controller;
    [self clearTemporaryExport];
    [self setWorking:NO message:@"Cancelled. Saved progress is unchanged."];
}
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if (!urls.count) return;
    if (self.exporting) {
        [self clearTemporaryExport];
        [self setWorking:NO message:@"Backup exported. Keep the file outside this app before deleting it."];
        [controller dismissViewControllerAnimated:YES completion:^{
            [self showMessage:@"Backup exported" detail:@"Keep the .pnsave file in a location outside Protector Native. The app cannot confirm whether a cloud provider has finished syncing it."];
        }];
        return;
    }
    NSURL* url=urls.firstObject;
    BOOL scoped=[url startAccessingSecurityScopedResource];
    [self setWorking:YES message:@"Verifying the selected backup…"];
    [controller dismissViewControllerAnimated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            __block NSError* error=nil;
            __block ProtectorSaveBackup* backup=nil;
            [[[NSFileCoordinator alloc] init] coordinateReadingItemAtURL:url options:0 error:&error byAccessor:^(NSURL* readable) {
                backup=[ProtectorSaveBackup readFromURL:readable error:&error];
            }];
            if (scoped) [url stopAccessingSecurityScopedResource];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setWorking:NO message:backup ? @"Backup verified. Confirm before replacing progress." : @"Saved progress is unchanged."];
                NSString* detail=error.localizedDescription;
                if (!backup) [self showMessage:@"Couldn’t read this backup" detail:detail ? detail : @"Choose an intact .pnsave file."];
                else [self confirmRestore:backup];
            });
        });
    }];
}
- (void)confirmRestore:(ProtectorSaveBackup*)backup {
    NSString* date=[NSDateFormatter localizedStringFromDate:backup.createdAt dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
    NSString* message=[NSString stringWithFormat:@"Backup created %@.\n\nThis replaces saved progress on this device. Any current progress will be copied to Save Recovery first. Game content is not changed.",date];
    UIAlertController* alert=[UIAlertController alertControllerWithTitle:@"Restore this backup?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action) {
        (void)action; [self setWorking:NO message:@"Restore cancelled. Saved progress is unchanged."];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore progress" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        (void)action; [self restore:backup];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)restore:(ProtectorSaveBackup*)backup {
    [self setWorking:YES message:@"Preserving current progress and restoring…"];
    NSURL* documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL* recovery=[documents URLByAppendingPathComponent:@"Save Recovery" isDirectory:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError* error=nil;
        NSDictionary* result=[backup restoreToDirectory:self.saveDirectory recoveryDirectory:recovery error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!result) {
                [self setWorking:NO message:@"Restore did not replace your progress."];
                NSString* detail=error.localizedDescription;
                [self showMessage:@"Couldn’t restore progress" detail:detail ? detail : @"Keep your backup and try again."];
                return;
            }
            const BOOL durable=[result[@"durability_confirmed"] boolValue];
            [self setWorking:NO message:durable ? @"Progress restored. Return to Play when you’re ready." : @"Progress replaced; storage reported a sync warning."];
            NSString* detail=durable ? (result[@"recovery_backup"] ?
                @"Your previous progress is kept in Files → Protector Native → Save Recovery. You can choose that .pnsave file to restore it later." :
                @"The backup is ready for the next game session. Your imported game content was not changed.") :
                @"The new progress is in place, but storage did not confirm the final sync. Keep your external backup and check available storage.";
            [self showMessage:durable ? @"Progress restored" : @"Storage sync warning" detail:detail];
        });
    });
}
@end
