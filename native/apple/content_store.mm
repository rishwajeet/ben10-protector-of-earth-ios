#import "content_store.h"
#import <CommonCrypto/CommonDigest.h>
#include <cstdio>
#include <cmath>
#include <vector>
#include <unistd.h>

#ifndef PROTECTOR_CONTENT_DOL_HASH
#define PROTECTOR_CONTENT_DOL_HASH "03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566"
#endif
static const uint64_t MaxPayload = 64ULL * 1024 * 1024 * 1024;
static NSArray<NSString*>* Required(void) {
    return @[@"Game/sys/main.dol", @"Game/sys/fst.bin", @"RestoredArt/pack.json",
        @"EnhancedModels/geometry.json", @"RestoredCinematics/cinematics.json"];
}
static BOOL Fail(NSError** error, NSString* message) {
    if (error) *error = [NSError errorWithDomain:@"ProtectorContent" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static NSString* Hex(const unsigned char* bytes) {
    NSMutableString* result = [NSMutableString stringWithCapacity:64];
    for (unsigned i=0; i<CC_SHA256_DIGEST_LENGTH; ++i) [result appendFormat:@"%02x",bytes[i]];
    return result;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSString* Hash(NSData* data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return Hex(digest);
}
static BOOL Integer(id value, uint64_t limit) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        [value doubleValue] >= 0 && [value doubleValue] <= (double)limit &&
        floor([value doubleValue]) == [value doubleValue];
}
static BOOL SafePath(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 1024) return NO;
    NSArray* parts = [value componentsSeparatedByString:@"/"];
    if (parts.count < 2 || ![@[@"Game",@"RestoredArt",@"EnhancedModels",@"RestoredCinematics"] containsObject:parts[0]]) return NO;
    for (NSString* part in parts)
        if (!part.length || part.length > 255 || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    for (NSUInteger i=0; i<[value length]; ++i) {
        unichar c = [value characterAtIndex:i];
        if (c<32 || c>126 || c=='\\' || c==':') return NO;
    }
    return YES;
}
static BOOL ValidHash(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
    NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}
static BOOL Validate(id value, NSError** error) {
    if (![value isKindOfClass:NSDictionary.class] ||
        ![value[@"schema"] isEqual:@"protector-native.personal-content/v1"] ||
        ![value[@"source_dol_sha256"] isEqual:@PROTECTOR_CONTENT_DOL_HASH] ||
        !Integer(value[@"runtime_version"],1) || [value[@"runtime_version"] unsignedIntValue]!=1)
        return Fail(error,@"This package is not compatible with this version of Protector Native.");
    NSArray* files = value[@"files"];
    if (![files isKindOfClass:NSArray.class] || !files.count || files.count>100000)
        return Fail(error,@"The content file list is invalid.");
    NSMutableSet* seen = [NSMutableSet set];
    NSMutableSet* exact = [NSMutableSet set];
    uint64_t total=0;
    for (id record in files) {
        if (![record isKindOfClass:NSDictionary.class] || [record count]!=3 ||
            !SafePath(record[@"path"]) || !Integer(record[@"bytes"],MaxPayload) || !ValidHash(record[@"sha256"]))
            return Fail(error,@"The package contains an unsafe file record.");
        NSString* name=record[@"path"];
        if ([seen containsObject:name.lowercaseString]) return Fail(error,@"The package contains duplicate file paths.");
        [seen addObject:name.lowercaseString]; [exact addObject:name];
        total += [record[@"bytes"] unsignedLongLongValue];
        if (total>MaxPayload) return Fail(error,@"This package exceeds the supported content size.");
        if ([name isEqual:Required()[0]] && ![record[@"sha256"] isEqual:@PROTECTOR_CONTENT_DOL_HASH])
            return Fail(error,@"The original game revision is not supported.");
    }
    for (NSString* name in seen) {
        NSString* parent = name.stringByDeletingLastPathComponent;
        while (parent.length) {
            if ([seen containsObject:parent]) return Fail(error,@"A content file conflicts with a directory.");
            parent=parent.stringByDeletingLastPathComponent;
        }
    }
    for (NSString* name in Required())
        if (![exact containsObject:name]) return Fail(error,@"The package is missing required enhanced content.");
#ifndef PROTECTOR_CONTENT_TEST_FIXTURES
    NSURL* admission=[NSBundle.mainBundle URLForResource:@"personal-build-inputs" withExtension:@"json"];
    NSData* admissionData=admission ? [NSData dataWithContentsOfURL:admission options:0 error:error] : nil;
    id lock=admissionData ? [NSJSONSerialization JSONObjectWithData:admissionData options:0 error:error] : nil;
    id game=[lock isKindOfClass:NSDictionary.class] ? lock[@"game"] : nil;
    if (![game isKindOfClass:NSDictionary.class]) return Fail(error,@"The app's source-revision record is missing. Reinstall the app without deleting its data.");
    NSMutableDictionary* actualGame=[NSMutableDictionary dictionary];
    for (NSDictionary* record in files) {
        NSString* name=record[@"path"];
        if ([name hasPrefix:@"Game/"]) actualGame[[name substringFromIndex:5]]=@{@"bytes":record[@"bytes"],@"sha256":record[@"sha256"]};
    }
    NSMutableDictionary* expectedGame=[NSMutableDictionary dictionary];
    for (NSString* name in game)
        if ([name hasPrefix:@"sys/"] || [name hasPrefix:@"files/"]) expectedGame[name]=game[name];
    // Personal builds may package the complete pinned extractor output or the
    // older runtime-only projection. Both are exact tables; partial/unknown
    // metadata and any changed source identity still reject.
    if (![actualGame isEqual:expectedGame] && ![actualGame isEqual:game])
        return Fail(error,@"The original game files do not match the supported revision. Rebuild from an unmodified supported copy.");
#endif
    if (!Integer(value[@"payload_bytes"],MaxPayload) || [value[@"payload_bytes"] unsignedLongLongValue]!=total)
        return Fail(error,@"The declared content size does not match its files.");
    NSData* canonical=[NSJSONSerialization dataWithJSONObject:files
        options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:error];
    if (!canonical || ![Hash(canonical) isEqual:value[@"content_id"]])
        return Fail(error,@"The content manifest identity is invalid.");
    return YES;
}
static BOOL Regular(NSURL* url) {
    NSDictionary* a=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    return [a[NSFileType] isEqual:NSFileTypeRegular];
}
static BOOL Directory(NSURL* url) {
    NSDictionary* a=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    return [a[NSFileType] isEqual:NSFileTypeDirectory];
}
static BOOL SafeParents(NSURL* root, NSString* relative, BOOL create, NSError** error) {
    NSURL* current=root;
    for (NSString* part in relative.stringByDeletingLastPathComponent.pathComponents) {
        current=[current URLByAppendingPathComponent:part isDirectory:YES];
        if (create && ![NSFileManager.defaultManager fileExistsAtPath:current.path] &&
            ![NSFileManager.defaultManager createDirectoryAtURL:current withIntermediateDirectories:NO
                attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
        if (!Directory(current)) return Fail(error,@"An imported content folder is unsafe or missing. Choose the package to repair it.");
    }
    return YES;
}
static BOOL MatchesFile(NSURL* file, NSDictionary* item, BOOL (^cancelled)(void)) {
    if (!Regular(file)) return NO;
    NSDictionary* attrs=[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
    if (![attrs[NSFileSize] isEqual:item[@"bytes"]]) return NO;
    FILE* input=fopen(file.fileSystemRepresentation,"rb");
    if (!input) return NO;
    CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
    std::vector<unsigned char> buffer(1024*1024);
    size_t count;
    BOOL okay=YES;
    while ((count=fread(buffer.data(),1,buffer.size(),input))) {
        if (cancelled && cancelled()) { okay=NO; break; }
        CC_SHA256_Update(&hash,buffer.data(),(CC_LONG)count);
    }
    if (ferror(input)) okay=NO;
    fclose(input);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest,&hash);
    return okay && [Hex(digest) isEqual:item[@"sha256"]];
}
static BOOL EnhancedContent(NSURL* root, NSDictionary* manifest, NSError** error) {
#ifdef PROTECTOR_CONTENT_TEST_FIXTURES
    (void)root; (void)manifest; (void)error;
    return YES;
#else
    NSArray* contracts=@[
        @[@"RestoredArt",@"pack.json",@"protector-native.texture-pack/v6",@2221],
        @[@"EnhancedModels",@"geometry.json",@"protector-native.geometry-pack/v1",@194],
        @[@"RestoredCinematics",@"cinematics.json",@"protector-native.cinematic-pack/v2",@76]];
    NSMutableDictionary* files=[NSMutableDictionary dictionary];
    for (NSDictionary* item in manifest[@"files"]) files[item[@"path"]]=item;
    for (NSArray* contract in contracts) {
        NSString* name=[contract[0] stringByAppendingPathComponent:contract[1]];
        if ([files[name][@"bytes"] unsignedLongLongValue]>32*1024*1024)
            return Fail(error,@"An enhanced-content manifest is too large.");
        NSData* data=[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:name] options:0 error:error];
        id pack=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
        if (![pack isKindOfClass:NSDictionary.class] || ![pack[@"schema"] isEqual:contract[2]] ||
            ![pack[@"title_dol_sha256"] isEqual:@PROTECTOR_CONTENT_DOL_HASH] ||
            ![pack[@"entries"] isKindOfClass:NSArray.class] || [pack[@"entries"] count]!=[contract[3] unsignedIntegerValue])
            return Fail(error,@"The enhanced content is incomplete or incompatible. Rebuild the complete package on your Mac.");
        for (id entry in pack[@"entries"]) {
            if (![entry isKindOfClass:NSDictionary.class]) return Fail(error,@"An enhanced content entry is invalid.");
            if ([contract[0] isEqual:@"EnhancedModels"]) continue;
            BOOL art=[contract[0] isEqual:@"RestoredArt"];
            id resource=art ? entry[@"replacement"] : entry;
            if (![resource isKindOfClass:NSDictionary.class]) return Fail(error,@"An enhanced asset reference is invalid.");
            id relative=resource[art ? @"path" : @"video"];
            if (![relative isKindOfClass:NSString.class]) return Fail(error,@"An enhanced asset filename is invalid.");
            NSString* path=[NSString stringWithFormat:@"%@/%@",contract[0],relative];
            NSDictionary* file=files[path];
            if (!SafePath(path) || !file || ![file[@"sha256"] isEqual:resource[art ? @"sha256" : @"video_sha256"]] ||
                ![file[@"bytes"] isEqual:resource[art ? @"byte_length" : @"video_bytes"]])
                return Fail(error,@"The package is missing an enhanced texture or movie. Rebuild the complete package on your Mac.");
        }
    }
    return YES;
#endif
}

@implementation ProtectorContentStore
- (instancetype)initWithRoot:(NSURL*)root {
    if ((self=[super init])) _root=root;
    return self;
}
- (NSURL*)activeContent:(NSError**)error {
    NSURL* marker=[self.root URLByAppendingPathComponent:@"active.json"];
    if (![NSFileManager.defaultManager fileExistsAtPath:marker.path]) return nil;
    if (!Directory(self.root) || !Regular(marker)) { Fail(error,@"The content directory needs repair."); return nil; }
    NSData* data=[NSData dataWithContentsOfURL:marker options:0 error:error];
    id active=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    NSString* name=[active isKindOfClass:NSDictionary.class] ? active[@"directory"] : nil;
    NSString* token=[name isKindOfClass:NSString.class] && [name hasPrefix:@"content-"] ? [name substringFromIndex:8] : nil;
    if (!token || ![[NSUUID alloc] initWithUUIDString:token]) { Fail(error,@"The content activation record needs repair."); return nil; }
    NSURL* folder=[self.root URLByAppendingPathComponent:name isDirectory:YES];
    NSURL* receipt=[folder URLByAppendingPathComponent:@"receipt.json"];
    if (!Directory(folder) || !Regular(receipt)) { Fail(error,@"Imported content is missing. Import your package again."); return nil; }
    data=[NSData dataWithContentsOfURL:receipt options:0 error:error];
    id manifest=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if (!Validate(manifest,error) || ![manifest[@"content_id"] isEqual:active[@"content_id"]]) return nil;
    // Transport was fully hashed before activation. Check every file's presence
    // and size at launch; don't reread 20 GB on every foreground transition.
    for (NSDictionary* item in manifest[@"files"]) {
        if (!SafeParents(folder,item[@"path"],NO,error)) return nil;
        NSURL* file=[folder URLByAppendingPathComponent:item[@"path"]];
        NSDictionary* attrs=[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
        if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || ![attrs[NSFileSize] isEqual:item[@"bytes"]]) {
            Fail(error,@"Imported content is incomplete. Import your package again; saves are unchanged."); return nil;
        }
    }
    return EnhancedContent(folder,manifest,error) ? folder : nil;
}
- (NSURL*)importPackage:(NSURL*)package progress:(void (^)(double))progress
    cancelled:(BOOL (^)(void))cancelled error:(NSError**)error {
    NSFileManager* fm=NSFileManager.defaultManager;
    if (!Regular(package)) { Fail(error,@"Select a regular .pnc content file."); return nil; }
    FILE* input=fopen(package.fileSystemRepresentation,"rb");
    if (!input) { Fail(error,@"The content file could not be opened."); return nil; }
    NSURL* stage=nil;
    NSURL* result=nil;
    do {
        unsigned char header[16];
        if (fread(header,1,16,input)!=16 || memcmp(header,"PNCONT1\n",8)) { Fail(error,@"This is not a Protector content package."); break; }
        uint64_t length=0;
        for (unsigned i=0;i<8;++i) length|=(uint64_t)header[8+i]<<(8*i);
        if (!length || length>32*1024*1024) { Fail(error,@"The content manifest is too large or invalid."); break; }
        NSMutableData* bytes=[NSMutableData dataWithLength:(NSUInteger)length];
        if (fread(bytes.mutableBytes,1,(size_t)length,input)!=length) { Fail(error,@"The content manifest is incomplete."); break; }
        id manifest=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:error];
        if (!Validate(manifest,error)) break;
        uint64_t payload=[manifest[@"payload_bytes"] unsignedLongLongValue];
        NSDictionary* attrs=[fm attributesOfItemAtPath:package.path error:error];
        if ([attrs[NSFileSize] unsignedLongLongValue]!=16+length+payload) { Fail(error,@"The package length is incorrect. Transfer the complete file again."); break; }
        if (![fm createDirectoryAtURL:self.root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error] || !Directory(self.root)) break;
        [self.root setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        // A manifest-owned staging folder survives cancellation/process death.
        // Rehash completed files before reusing them; never trust a progress count.
        stage=[self.root URLByAppendingPathComponent:[@"pending-" stringByAppendingString:manifest[@"content_id"]] isDirectory:YES];
        NSURL* pending=[stage URLByAppendingPathComponent:@"pending.json"];
        if ([fm fileExistsAtPath:stage.path]) {
            if (!Directory(stage) || !Regular(pending) ||
                ![[NSData dataWithContentsOfURL:pending] isEqual:bytes]) {
                Fail(error,@"The partial import does not match this package. Your previous active content and saves are unchanged."); break;
            }
        } else {
            if (![fm createDirectoryAtURL:stage withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error] ||
                ![bytes writeToURL:pending options:NSDataWritingAtomic error:error]) break;
        }
        NSMutableSet* reusable=[NSMutableSet set];
        uint64_t reused=0;
        BOOL safe=YES;
        for (NSDictionary* item in manifest[@"files"]) {
            if (!SafeParents(stage,item[@"path"],YES,error)) { safe=NO; break; }
            NSURL* file=[stage URLByAppendingPathComponent:item[@"path"]];
            if (MatchesFile(file,item,cancelled)) {
                [reusable addObject:item[@"path"]]; reused+=[item[@"bytes"] unsignedLongLongValue];
            }
            if (cancelled && cancelled()) { safe=Fail(error,@"Import paused. Choose the same package to resume; existing content and saves are unchanged."); break; }
        }
        if (!safe) break;
        uint64_t needed=payload-reused+128*1024*1024;
        NSDictionary* disk=[fm attributesOfFileSystemForPath:self.root.path error:error];
        if (!disk || [disk[NSFileSystemFreeSize] unsignedLongLongValue]<needed) {
            Fail(error,[NSString stringWithFormat:@"Import needs %@ of free space, including its safety reserve. Existing content and saves are unchanged. Free space, then choose the same package to resume.",
                [NSByteCountFormatter stringFromByteCount:(long long)needed countStyle:NSByteCountFormatterCountStyleFile]]); break;
        }
        std::vector<unsigned char> buffer(1024*1024);
        uint64_t completed=0;
        BOOL okay=YES;
        for (NSDictionary* item in manifest[@"files"]) {
            NSURL* destination=[stage URLByAppendingPathComponent:item[@"path"]];
            if ([reusable containsObject:item[@"path"]]) {
                if (fseeko(input,(off_t)[item[@"bytes"] unsignedLongLongValue],SEEK_CUR)) { okay=Fail(error,@"The package could not be read for resume."); break; }
                completed+=[item[@"bytes"] unsignedLongLongValue];
                if (progress) progress(payload ? (double)completed/payload : 1);
                continue;
            }
            if ([fm fileExistsAtPath:destination.path]) {
                if (!Regular(destination) || ![fm removeItemAtURL:destination error:error]) { okay=Fail(error,@"An incomplete imported file could not be repaired."); break; }
            }
            FILE* output=fopen(destination.fileSystemRepresentation,"wbx");
            if (!output) { okay=Fail(error,@"Could not create an imported content file."); break; }
            CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
            uint64_t remaining=[item[@"bytes"] unsignedLongLongValue];
            while (remaining) {
                if (cancelled && cancelled()) { okay=Fail(error,@"Import paused. Choose the same package to resume; existing content and saves are unchanged."); break; }
                size_t count=(size_t)(remaining<buffer.size() ? remaining : buffer.size());
                if (fread(buffer.data(),1,count,input)!=count || fwrite(buffer.data(),1,count,output)!=count) {
                    okay=Fail(error,@"A file could not be read or saved. Check storage and transfer the package again."); break;
                }
                CC_SHA256_Update(&hash,buffer.data(),(CC_LONG)count);
                remaining-=count; completed+=count;
                if (progress) progress(payload ? (double)completed/payload : 1);
            }
            if (fflush(output)!=0 || fsync(fileno(output))!=0) okay=Fail(error,@"The imported file could not be saved.");
            if (fclose(output)!=0) okay=Fail(error,@"The imported file could not be saved.");
            if (!okay) break;
            unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest,&hash);
            if (![Hex(digest) isEqual:item[@"sha256"]]) { okay=Fail(error,[NSString stringWithFormat:@"%@ is damaged. Transfer your package again.",item[@"path"]]); break; }
        }
        if (!okay) break;
        if (!EnhancedContent(stage,manifest,error)) break;
        if (cancelled && cancelled()) { Fail(error,@"Import cancelled. Existing content and saves are unchanged."); break; }
        if (![bytes writeToURL:[stage URLByAppendingPathComponent:@"receipt.json"] options:NSDataWritingAtomic error:error]) break;
        NSString* directory=[@"content-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSURL* complete=[self.root URLByAppendingPathComponent:directory isDirectory:YES];
        if (![fm moveItemAtURL:stage toURL:complete error:error]) break;
        stage=complete;
        NSData* active=[NSJSONSerialization dataWithJSONObject:@{@"directory":directory,@"content_id":manifest[@"content_id"]} options:0 error:error];
        if (!active || ![active writeToURL:[self.root URLByAppendingPathComponent:@"active.json"] options:NSDataWritingAtomic error:error]) break;
        result=stage;
    } while (false);
    fclose(input);
    // Keep manifest-owned partial files for selective retry. Never touch saves
    // or remove the previous active content as part of importing/replacing it.
    return result;
}
@end
#pragma clang diagnostic pop
