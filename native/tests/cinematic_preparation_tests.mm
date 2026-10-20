#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstring>
#include "../metal/cinematic_pack.mm"

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr,"cinematic-preparation check failed at %d: %s\n",__LINE__,#condition); return 1; } } while (0)

static ProtectorCinematicFrame Source(NSDictionary* entry, uint64_t serial) {
    ProtectorCinematicFrame frame{};
    frame.active = true; frame.open_serial = serial;
    frame.width = [entry[@"source_width"] unsignedIntValue]; frame.height = [entry[@"source_height"] unsignedIntValue];
    frame.frame_count = [entry[@"frame_count"] unsignedIntValue];
    frame.rate_numerator = [entry[@"rate_numerator"] unsignedIntValue]; frame.rate_denominator = [entry[@"rate_denominator"] unsignedIntValue];
    frame.decoded_frame_one_based = 1; frame.next_frame_one_based = 2;
    snprintf(frame.movie,sizeof(frame.movie),"%s",[entry[@"movie"] UTF8String]);
    return frame;
}
static ProtectorCinematicOpening Opening(NSDictionary* entry, uint64_t serial) {
    ProtectorCinematicOpening opening{};
    opening.open_serial = serial;
    snprintf(opening.movie,sizeof(opening.movie),"%s",[entry[@"movie"] UTF8String]);
    return opening;
}
static bool WaitPrepared(ProtectorCinematicPack* pack, ProtectorCinematicOpening opening) {
    for (unsigned attempt=0; attempt<2000; ++attempt) {
        NSDictionary* state = [pack diagnostics];
        if (state[@"failure"] != NSNull.null) return false;
        if ([pack statusForOpening:opening] == ProtectorCinematicOpeningReady) return true;
        [NSThread sleepForTimeInterval:0.005];
    }
    return false;
}
int main(int argc,const char* argv[]) { @autoreleasepool {
    if (argc < 3) {
        puts("cinematic preparation requires explicit local original assets; no runtime claim from synthetic data");
        return 0;
    }
    NSError* error = nil;
    NSURL* manifest = [NSURL fileURLWithPath:@(argv[1])];
    NSURL* source = [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
    NSDictionary* document = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:manifest] options:0 error:&error];
    NSDictionary* entry = nil;
    NSString* selected = argc>3 ? @(argv[3]) : @"CN.bik";
    for (NSDictionary* candidate in document[@"entries"]) if ([candidate[@"movie"] isEqual:selected]) entry=candidate;
    CHECK(entry);
    ProtectorCinematicPack* pack = [[ProtectorCinematicPack alloc] initWithManifest:manifest sourceDirectory:source
        device:MTLCreateSystemDefaultDevice() error:&error];
    CHECK(pack);
    const double before = CinematicMonotonicSeconds();
    [pack prepareOpening:Opening(entry,701)];
    const double enqueueMs = (CinematicMonotonicSeconds()-before)*1000;
    NSDictionary* scheduled = [pack diagnostics];
    CHECK([scheduled[@"awaiting_source_frame"] boolValue]);
    CHECK([scheduled[@"prepared_source_open"] boolValue]);
    CHECK([pack imageForFrame:Source(entry,701)] == nil); // no observed source picture yet
    [pack prepareOpening:Opening(entry,701)];
    CHECK([[pack diagnostics][@"generation"] isEqual:scheduled[@"generation"]]);
    CHECK([[pack diagnostics][@"prepared_openings"] unsignedLongLongValue] == 1);
    CHECK(WaitPrepared(pack,Opening(entry,701)));
    CHECK([pack statusForOpening:Opening(entry,700)] == ProtectorCinematicOpeningUnavailable);
    const double preparedMs = (CinematicMonotonicSeconds()-before)*1000;
    ProtectorCinematicFrame empty{};
    [pack observeFrame:empty];
    CHECK([[[pack diagnostics] objectForKey:@"cached_frames"] containsObject:@0]);
    CHECK([[pack diagnostics][@"cached_frames"] count] <= 5);
    CHECK([pack imageForFrame:Source(entry,701)] == nil);
    ProtectorCinematicFrame first = Source(entry,701);
    [pack observeFrame:first];
    ProtectorCinematicImage* image = [pack imageForFrame:first];
    CHECK(image && image.frameIndex == 0 && image.openSerial == 701);
    NSDictionary* bound = [pack diagnostics];
    CHECK(![bound[@"awaiting_source_frame"] boolValue]);
    CHECK([bound[@"source_open_lead_ms"] doubleValue] > 0);
    CHECK(![bound[@"audio_output"] boolValue]);
    CHECK([pack imageForFrame:Source(entry,700)] == nil);
    [pack observeFrame:empty];
    CHECK([[pack diagnostics][@"cached_frames"] count] == 0);
    CHECK([pack imageForFrame:first] == nil);
    [pack prepareOpening:Opening(entry,702)];
    CHECK(WaitPrepared(pack,Opening(entry,702)));
    ProtectorCinematicFrame wrong = Source(entry,702); ++wrong.width;
    [pack observeFrame:wrong];
    CHECK([[pack diagnostics][@"cached_frames"] count] == 0);
    CHECK([pack imageForFrame:Source(entry,702)] == nil);
    // An abandoned opening cannot switch to restored frames later, even when
    // the complete initial window was already cached when it was cancelled.
    [pack prepareOpening:Opening(entry,706)];
    CHECK(WaitPrepared(pack,Opening(entry,706)));
    [pack abandonOpening:Opening(entry,705)]; // a stale cancellation is inert
    CHECK([pack statusForOpening:Opening(entry,706)] == ProtectorCinematicOpeningReady);
    [pack abandonOpening:Opening(entry,706)];
    CHECK([pack statusForOpening:Opening(entry,706)] == ProtectorCinematicOpeningUnavailable);
    [pack observeFrame:Source(entry,706)];
    CHECK([pack imageForFrame:Source(entry,706)] == nil);
    CHECK([pack diagnostics][@"failure"] != NSNull.null);
    CHECK([[pack diagnostics][@"cached_frames"] count] == 0);
    [pack prepareOpening:Opening(entry,703)];
    ProtectorCinematicOpening unknown = Opening(entry,704);
    snprintf(unknown.movie,sizeof(unknown.movie),"Unknown.bik");
    [pack prepareOpening:unknown];
    CHECK([[pack diagnostics][@"cached_frames"] count] == 0);
    CHECK([pack diagnostics][@"active_movie"] == NSNull.null);
    ProtectorCinematicOpening invalid = Opening(entry,0);
    [pack prepareOpening:invalid];
    memset(invalid.movie,'a',sizeof(invalid.movie)); invalid.open_serial=705;
    [pack prepareOpening:invalid];
    CHECK([pack diagnostics][@"active_movie"] == NSNull.null);
    [pack invalidate];
    NSDictionary* result = @{@"schema":@"protector-native.cinematic-preparation-witness/v1",@"status":@"pass",
        @"movie":selected,@"manifest_sha256":pack.manifestSHA256,@"enqueue_ms":@(enqueueMs),
        @"initial_window_ready_ms":@(preparedMs),@"bound_state":bound,@"final_state":[pack diagnostics],
        @"scope":@"Actual original-asset initial-window readiness, no-frame-before-source-binding, exact index, wrong-metadata rejection, abandoned-opening fallback and invalidation; not translated-game latency improvement."};
    NSData* output = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
    CHECK(output); fwrite(output.bytes,1,output.length,stdout); puts("");
    return 0;
} }
