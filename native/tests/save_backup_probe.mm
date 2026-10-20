#import "../apple/save_backup.h"
#include <cstdio>

int main(int argc, const char** argv) {
    @autoreleasepool {
        if (argc<3) return 2;
        NSString* action=@(argv[1]);
        NSURL* input=[NSURL fileURLWithPath:@(argv[2])];
        NSError* error=nil;
        id result=nil;
        if ([action isEqual:@"export"] && argc==4) {
            if ([ProtectorSaveBackup exportDirectory:input toURL:[NSURL fileURLWithPath:@(argv[3])] error:&error])
                result=@{@"exported":@YES};
        } else {
            ProtectorSaveBackup* backup=[ProtectorSaveBackup readFromURL:input error:&error];
            if (backup && [action isEqual:@"validate"]) result=@{@"bytes":@(backup.totalBytes)};
            if (backup && [action isEqual:@"restore"] && argc==5) {
                NSDictionary* restored=[backup restoreToDirectory:[NSURL fileURLWithPath:@(argv[3])]
                    recoveryDirectory:[NSURL fileURLWithPath:@(argv[4])] error:&error];
                if (restored) {
                    NSMutableDictionary* record=[restored mutableCopy];
                    for (NSString* key in @[@"recovery_backup",@"previous_directory"])
                        if (record[key]) record[key]=[record[key] path];
                    result=record;
                }
            }
        }
        if (!result) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1; }
        NSData* data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        fwrite(data.bytes,1,data.length,stdout);
        return 0;
    }
}
