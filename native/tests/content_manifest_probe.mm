// Exercise the real production manifest gate, including the bundle source lock.
// No fixture bypass, payload import, game execution, renderer or audio.
#import "../apple/content_store.mm"
int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSError* error = nil;
        NSData* data = [NSData dataWithContentsOfFile:@(argv[1]) options:0 error:&error];
        id manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if (manifest && Validate(manifest, &error)) {
            puts("Production manifest admission passed");
            return 0;
        }
        fprintf(stderr, "%s\n", error ? error.localizedDescription.UTF8String : "Unreadable manifest");
        return 1;
    }
}
