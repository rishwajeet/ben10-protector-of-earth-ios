#import "save_backup.h"
#import "protector/save_store.h"
#import <CommonCrypto/CommonDigest.h>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static const NSUInteger MaxArchiveBytes = 48u * 1024u * 1024u;
static NSString* const Namespace = @"UpgradedSaves-RBNEG9-v1";
static BOOL Fail(NSError** error, NSString* message) {
    if (error) *error = [NSError errorWithDomain:@"ProtectorSaveBackup" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static NSDictionary* BackupMarker(void) {
    return @{@"schema":@"protector-native.save-edition/v1", @"edition":@"upgraded",
        @"title":@"RBNEG9", @"namespace_version":@1};
}
static BOOL Keys(id value, NSArray* keys) {
    return [value isKindOfClass:NSDictionary.class] &&
        [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static NSString* Hash(NSData* data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
#pragma clang diagnostic pop
    NSMutableString* value = [NSMutableString stringWithCapacity:64];
    for (unsigned i=0;i<CC_SHA256_DIGEST_LENGTH;++i) [value appendFormat:@"%02x",digest[i]];
    return value;
}
static NSData* Read(NSURL* url, NSUInteger limit, NSError** error) {
    if (!url.isFileURL) { Fail(error,@"Choose a local save backup file."); return nil; }
    const int fd=open(url.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    struct stat info;
    if (fd<0 || fstat(fd,&info)!=0 || !S_ISREG(info.st_mode) || info.st_size<0 ||
        (uint64_t)info.st_size>limit) {
        if (fd>=0) close(fd);
        Fail(error,@"The save file is missing, linked or too large. Choose an intact backup."); return nil;
    }
    NSMutableData* data=[NSMutableData dataWithLength:(NSUInteger)info.st_size];
    size_t offset=0;
    while (offset<data.length) {
        const ssize_t count=read(fd,(uint8_t*)data.mutableBytes+offset,data.length-offset);
        if (count<0 && errno==EINTR) continue;
        if (count<=0) { close(fd); Fail(error,@"The save file could not be read completely."); return nil; }
        offset+=(size_t)count;
    }
    uint8_t extra;
    ssize_t tail;
    do { tail=read(fd,&extra,1); } while (tail<0 && errno==EINTR);
    close(fd);
    if (tail!=0) { Fail(error,@"The save file changed while it was being read. Try again."); return nil; }
    return data;
}
static BOOL Write(NSURL* url, NSData* data, NSError** error) {
    const int fd=open(url.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (fd<0) return Fail(error,@"A new backup file could not be created. Existing files were not replaced.");
    size_t offset=0;
    BOOL okay=YES;
    while (offset<data.length) {
        const ssize_t count=write(fd,(const uint8_t*)data.bytes+offset,data.length-offset);
        if (count<0 && errno==EINTR) continue;
        if (count<=0) { okay=NO; break; }
        offset+=(size_t)count;
    }
    if (okay) okay=fsync(fd)==0;
    if (close(fd)!=0) okay=NO;
    if (!okay) return Fail(error,@"Storage could not finish writing the backup. Current progress was not replaced.");
    return YES;
}
static BOOL PlainDirectory(NSURL* directory, BOOL missingAllowed, NSError** error) {
    struct stat info;
    if (!directory.isFileURL) return Fail(error,@"Save storage must be local.");
    if (lstat(directory.fileSystemRepresentation,&info)!=0) {
        if (missingAllowed && errno==ENOENT) return YES;
        return Fail(error,@"Save storage is unavailable.");
    }
    if (!S_ISDIR(info.st_mode)) return Fail(error,@"Linked or invalid save storage cannot be used.");
    return YES;
}
static BOOL ValidateDirectory(NSURL* directory, BOOL missingAllowed, NSError** error) {
    if (![directory.lastPathComponent isEqual:Namespace])
        return Fail(error,@"Only this app's enhanced save storage can be backed up or restored.");
    if (!PlainDirectory(directory,missingAllowed,error)) return NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:directory.path]) return YES;
    NSData* data=Read([directory URLByAppendingPathComponent:@".protector-edition.json"],4096,error);
    if (!data) return NO;
    id marker=[NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![marker isEqual:BackupMarker()]) return Fail(error,@"Save storage belongs to another game or edition. It was not changed.");
    return YES;
}
static BOOL SyncDirectory(NSURL* directory) {
    const int fd=open(directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) return NO;
    const BOOL okay=fsync(fd)==0;
    close(fd);
    return okay;
}
static void TestStop(const char* phase) {
#if PROTECTOR_SAVE_BACKUP_TEST_FIXTURES
    const char* stop=getenv("PROTECTOR_SAVE_BACKUP_TEST_STOP");
    if (stop && strcmp(stop,phase)==0) _exit(23);
#else
    (void)phase;
#endif
}

@interface ProtectorSaveBackup ()
@property(nonatomic, readwrite) NSDate* createdAt;
@property(nonatomic, readwrite) NSUInteger totalBytes;
@property(nonatomic) NSDictionary<NSString*,NSData*>* payloads;
- (instancetype)initWithPayloads:(NSDictionary*)payloads date:(NSDate*)date;
@end

@implementation ProtectorSaveBackup
- (instancetype)initWithPayloads:(NSDictionary*)payloads date:(NSDate*)date {
    self=[super init];
    if (self) {
        _payloads=[payloads copy]; _createdAt=date; _totalBytes=0;
        for (NSData* data in payloads.allValues) _totalBytes+=data.length;
    }
    return self;
}
+ (instancetype)readFromURL:(NSURL*)url error:(NSError**)error {
    NSData* data=Read(url,MaxArchiveBytes,error);
    if (!data) return nil;
    id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!Keys(value,@[@"schema",@"title",@"edition",@"namespace_version",@"created_at",@"files"]) ||
        ![value[@"schema"] isEqual:@"protector-native.save-backup/v1"] ||
        ![value[@"title"] isEqual:@"RBNEG9"] || ![value[@"edition"] isEqual:@"upgraded"] ||
        ![value[@"namespace_version"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value[@"namespace_version"])==CFBooleanGetTypeID() ||
        ![value[@"namespace_version"] isEqual:@1]) {
        Fail(error,@"This is not a compatible Protector Native save backup."); return nil;
    }
    id timestamp=value[@"created_at"];
    NSDate* date=[timestamp isKindOfClass:NSString.class] && [timestamp length]<=64 ?
        [[[NSISO8601DateFormatter alloc] init] dateFromString:timestamp] : nil;
    id files=value[@"files"];
    if (!date || ![files isKindOfClass:NSDictionary.class] ||
        (!Keys(files,@[@"SavedGames"]) && !Keys(files,@[@"SavedGames",@"banner.bin"]))) {
        Fail(error,@"The backup's date or save-file list is invalid."); return nil;
    }
    NSMutableDictionary* payloads=[NSMutableDictionary dictionary];
    for (NSString* name in files) {
        id row=files[name];
        if (!Keys(row,@[@"bytes",@"sha256",@"base64"]) ||
            ![row[@"bytes"] isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)row[@"bytes"])==CFBooleanGetTypeID() ||
            [row[@"bytes"] doubleValue]<0 || [row[@"bytes"] doubleValue]>(double)PROTECTOR_SAVE_MAX_BYTES ||
            floor([row[@"bytes"] doubleValue])!=[row[@"bytes"] doubleValue] ||
            ![row[@"base64"] isKindOfClass:NSString.class] ||
            ![row[@"sha256"] isKindOfClass:NSString.class]) {
            Fail(error,@"The backup's save-file record is invalid."); return nil;
        }
        NSData* payload=[[NSData alloc] initWithBase64EncodedString:row[@"base64"] options:0];
        if (!payload || payload.length>PROTECTOR_SAVE_MAX_BYTES || payload.length!=[row[@"bytes"] unsignedIntegerValue] ||
            ![Hash(payload) isEqual:row[@"sha256"]] || ([name isEqual:@"SavedGames"] && !payload.length)) {
            Fail(error,@"The backup is incomplete or damaged. Current progress was not changed."); return nil;
        }
        payloads[name]=payload;
    }
    return [[self alloc] initWithPayloads:payloads date:date];
}
+ (BOOL)exportDirectory:(NSURL*)directory toURL:(NSURL*)url error:(NSError**)error {
    if (!ValidateDirectory(directory,YES,error)) return NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:directory.path])
        return Fail(error,@"No saved progress is available to back up yet. Play and save first, or restore an existing .pnsave backup.");
    NSMutableDictionary* files=[NSMutableDictionary dictionary];
    for (NSString* name in @[@"SavedGames",@"banner.bin"]) {
        NSURL* source=[directory URLByAppendingPathComponent:name];
        struct stat info;
        if (lstat(source.fileSystemRepresentation,&info)!=0 && errno==ENOENT && [name isEqual:@"banner.bin"]) continue;
        NSData* data=Read(source,PROTECTOR_SAVE_MAX_BYTES,error);
        if (!data) return NO;
        if ([name isEqual:@"SavedGames"] && !data.length)
            return Fail(error,@"No saved progress is available to back up yet.");
        files[name]=@{@"bytes":@(data.length),@"sha256":Hash(data),@"base64":[data base64EncodedStringWithOptions:0]};
    }
    NSDictionary* value=@{@"schema":@"protector-native.save-backup/v1",@"title":@"RBNEG9",@"edition":@"upgraded",
        @"namespace_version":@1,@"created_at":[[[NSISO8601DateFormatter alloc] init] stringFromDate:NSDate.date],@"files":files};
    NSData* data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:error];
    if (!data || !url.isFileURL) return NO;
    return Write(url,data,error);
}
- (NSDictionary*)restoreToDirectory:(NSURL*)directory recoveryDirectory:(NSURL*)recoveryDirectory error:(NSError**)error {
    if (!ValidateDirectory(directory,YES,error)) return nil;
    NSString* targetPath=directory.URLByStandardizingPath.path;
    NSString* recoveryPath=recoveryDirectory.URLByStandardizingPath.path;
    if ([recoveryPath isEqual:targetPath] || [recoveryPath hasPrefix:[targetPath stringByAppendingString:@"/"]]) {
        Fail(error,@"Recovery copies must be stored outside the active save directory."); return nil;
    }
    NSFileManager* manager=NSFileManager.defaultManager;
    NSURL* parent=directory.URLByDeletingLastPathComponent;
    if (![manager createDirectoryAtURL:parent withIntermediateDirectories:YES attributes:nil error:error] ||
        !PlainDirectory(parent,NO,error)) return nil;
    const BOOL existing=[manager fileExistsAtPath:directory.path];
    NSURL* recovery=nil;
    if (existing) {
        NSURL* current=[directory URLByAppendingPathComponent:@"SavedGames"];
        struct stat info={};
        const int found=lstat(current.fileSystemRepresentation,&info);
        const int lookupError=errno;
        if (found==0 && S_ISREG(info.st_mode) && info.st_size>0) {
            if (![manager createDirectoryAtURL:recoveryDirectory withIntermediateDirectories:YES attributes:nil error:error] ||
                !PlainDirectory(recoveryDirectory,NO,error)) return nil;
            recovery=[recoveryDirectory URLByAppendingPathComponent:
                [NSString stringWithFormat:@"Before-restore-%@.pnsave",NSUUID.UUID.UUIDString]];
            if (![ProtectorSaveBackup exportDirectory:directory toURL:recovery error:error] ||
                ![ProtectorSaveBackup readFromURL:recovery error:error] || !SyncDirectory(recoveryDirectory)) {
                if (error && !*error) Fail(error,@"The recovery copy could not be verified. Current progress was not changed.");
                return nil;
            }
        } else if ((found==0 && !S_ISREG(info.st_mode)) || (found!=0 && lookupError!=ENOENT)) {
            Fail(error,@"Current save storage could not be safely preserved."); return nil;
        }
    }
    NSURL* staged=[parent URLByAppendingPathComponent:[@".save-restore-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    if (![manager createDirectoryAtURL:staged withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
    NSData* marker=[NSJSONSerialization dataWithJSONObject:BackupMarker() options:NSJSONWritingSortedKeys error:error];
    if (!marker || !Write([staged URLByAppendingPathComponent:@".protector-edition.json"],marker,error)) return nil;
    for (NSString* name in self.payloads)
        if (!Write([staged URLByAppendingPathComponent:name],self.payloads[name],error)) return nil;
    if (!SyncDirectory(staged) || !SyncDirectory(parent)) {
        Fail(error,@"Storage could not finish preparing the restore. Current progress was not changed."); return nil;
    }
    TestStop("staged");
    if (renamex_np(staged.fileSystemRepresentation,directory.fileSystemRepresentation,
                   existing ? RENAME_SWAP : RENAME_EXCL)!=0) {
        Fail(error,@"The save replacement could not finish. Current progress was not changed."); return nil;
    }
    TestStop("committed");
    const BOOL durable=SyncDirectory(parent);
    NSMutableDictionary* result=[@{@"restored":@YES,@"durability_confirmed":@(durable)} mutableCopy];
    if (recovery) result[@"recovery_backup"]=recovery;
    if (existing) result[@"previous_directory"]=staged;
    return result;
}
@end
