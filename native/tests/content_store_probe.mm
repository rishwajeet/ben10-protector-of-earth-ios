// Synthetic offline interoperability probe. No renderer, game or audio output.
#import "../apple/content_store.h"
#include <cstdio>
#include <cstring>
#include <unistd.h>
int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc<3) return 2;
        ProtectorContentStore* store=[[ProtectorContentStore alloc] initWithRoot:
            [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES]];
        NSError* error=nil;
        NSURL* result=nil;
        __block BOOL progressed=NO;
        if (!strcmp(argv[1],"active")) result=[store activeContent:&error];
        else if (argc>=4) result=[store importPackage:[NSURL fileURLWithPath:@(argv[3])]
            progress:^(double value) {
                progressed=value>0;
                if (argc>=5 && !strcmp(argv[4],"crash")) _exit(23);
            }
            cancelled:^BOOL { return argc>=5 && (!strcmp(argv[4],"cancel") ||
                (!strcmp(argv[4],"pause") && progressed)); } error:&error];
        if (result) { puts(result.path.UTF8String); return 0; }
        fprintf(stderr,"%s\n",error ? error.localizedDescription.UTF8String : "No active content");
        return 1;
    }
}
