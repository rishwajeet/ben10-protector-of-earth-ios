#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstring>
#include <vector>
#include "../metal/cinematic_pack.mm"

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr,"cinematic-pack check failed at %d: %s\n",__LINE__,#condition); return 1; } } while (0)

static ProtectorCinematicFrame SourceFrame(NSDictionary* entry, uint64_t serial, NSUInteger index) {
    ProtectorCinematicFrame result{};
    result.active = true;
    result.open_serial = serial;
    result.width = [entry[@"source_width"] unsignedIntValue];
    result.height = [entry[@"source_height"] unsignedIntValue];
    result.frame_count = [entry[@"frame_count"] unsignedIntValue];
    result.rate_numerator = [entry[@"rate_numerator"] unsignedIntValue];
    result.rate_denominator = [entry[@"rate_denominator"] unsignedIntValue];
    result.decoded_frame_one_based = (u32)index+1;
    result.next_frame_one_based = (u32)index+2;
    snprintf(result.movie,sizeof(result.movie),"%s",[entry[@"movie"] UTF8String]);
    return result;
}

static ProtectorCinematicImage* WaitImage(ProtectorCinematicPack* pack, ProtectorCinematicFrame frame) {
    [pack observeFrame:frame];
    for (unsigned i=0; i<1500; ++i) {
        ProtectorCinematicImage* image = [pack imageForFrame:frame];
        if (image) return image;
        if ([pack diagnostics][@"failure"] != NSNull.null) {
            fprintf(stderr,"decode failure: %s\n",[[pack diagnostics].description UTF8String]);
            return nil;
        }
        [NSThread sleepForTimeInterval:0.005];
    }
    fprintf(stderr,"timed out: %s\n",[[pack diagnostics].description UTF8String]);
    return nil;
}

int main(int argc, const char* argv[]) { @autoreleasepool {
    CHECK(CinematicName(@"D3.bik",@"bik"));
    CHECK(CinematicName(@"55_outro_B.bik",@"bik"));
    for (id invalid in @[@"../D3.bik",@"/D3.bik",@"Movies/D3.bik",@"D3.BIK",@"a b.bik",@".bik",@42,NSNull.null])
        CHECK(!CinematicName(invalid,@"bik"));
    CHECK(CinematicInteger(@3840,32,4096));
    for (id invalid in @[@YES,@NO,@3.5,@(-1),@8192,@"3840",NSNull.null]) CHECK(!CinematicInteger(invalid,32,4096));
    CHECK(CinematicDimensions(@3840,@2160,false));
    CHECK(CinematicDimensions(@3840,@2160,true));
    CHECK(CinematicDimensions(@2880,@2160,true));
    CHECK(!CinematicDimensions(@2880,@2160,false));
    for (id invalid in @[@YES,@2881,@1920,@2880.5,@"2880",NSNull.null])
        CHECK(!CinematicDimensions(invalid,@2160,true));
    CHECK(!CinematicDimensions(@2880,@1080,true));
    CHECK(CinematicHashValid(@"03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566"));
    CHECK(!CinematicHashValid(@"03D2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566"));
    NSDictionary* synthetic = @{@"movie":@"D3.bik",@"source_width":@640,@"source_height":@480,
        @"frame_count":@156,@"rate_numerator":@30,@"rate_denominator":@1};
    ProtectorCinematicFrame frame = SourceFrame(synthetic,1,0);
    CHECK(CinematicMatches(synthetic,frame));
    for (int field=0; field<8; ++field) {
        ProtectorCinematicFrame wrong=frame;
        switch(field) {
            case 0: wrong.width++; break;
            case 1: wrong.height++; break;
            case 2: wrong.frame_count++; break;
            case 3: wrong.rate_numerator++; break;
            case 4: wrong.rate_denominator++; break;
            case 5: wrong.open_serial=0; break;
            case 6: wrong.decoded_frame_one_based=0; break;
            case 7: wrong.decoded_frame_one_based=157; break;
        }
        CHECK(!CinematicMatches(synthetic,wrong));
    }
    memset(frame.movie,'x',sizeof(frame.movie));
    CHECK(CinematicFrameName(frame)==nil);
    if (argc < 3) {
        puts("cinematic-pack pure admission checks passed; actual decode not requested");
        return 0;
    }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    CHECK(device != nil);
    NSURL* manifest = [NSURL fileURLWithPath:@(argv[1])];
    NSURL* source = [NSURL fileURLWithPath:@(argv[2]) isDirectory:YES];
    NSError* error=nil;
    ProtectorCinematicPack* pack = [[ProtectorCinematicPack alloc] initWithManifest:manifest
        sourceDirectory:source device:device error:&error];
    if (!pack) fprintf(stderr,"pack error: %s\n",error.localizedDescription.UTF8String);
    CHECK(pack != nil);
    NSDictionary* document = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:manifest] options:0 error:&error];
    NSDictionary* entry = document[@"entries"][0];
    if (argc > 4) {
        NSString* selected = @(argv[4]);
        NSArray* matches = [document[@"entries"] filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"movie == %@", selected]];
        CHECK(matches.count == 1);
        entry = matches[0];
    }
    const NSUInteger count = [entry[@"frame_count"] unsignedIntegerValue];
    const NSUInteger width = [entry[@"width"] unsignedIntegerValue], height = [entry[@"height"] unsignedIntegerValue];
    CHECK(count <= 10000);
    NSURL* proof = argc > 3 ? [NSURL fileURLWithPath:@(argv[3]) isDirectory:YES] : nil;
    if (proof) {
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:proof.path]);
        CHECK([NSFileManager.defaultManager createDirectoryAtURL:proof withIntermediateDirectories:YES attributes:nil error:&error]);
    }
    NSMutableArray* samples = [NSMutableArray array];
    for (NSUInteger index=0; index<count; ++index) { @autoreleasepool {
        frame = SourceFrame(entry,41,index);
        ProtectorCinematicImage* picture = WaitImage(pack,frame);
        CHECK(picture != nil && picture.frameIndex==index && picture.openSerial==41);
        CHECK([picture.movie isEqual:entry[@"movie"]]);
        CHECK(picture.luma.width==width && picture.luma.height==height && picture.chroma.width==width/2 && picture.chroma.height==height/2);
        NSDictionary* state=[pack diagnostics];
        CHECK([state[@"cached_frames"] count] <= 7);
        CHECK([state[@"cached_pixel_bytes"] unsignedLongLongValue] == [state[@"cached_frames"] count]*width*height*3/2);
        CHECK(state[@"failure"] == NSNull.null);
        CHECK(![state[@"audio_output"] boolValue]);
        if (proof && (index==0 || index==count/3 || index==count*2/3 || index==count-1)) {
            NSMutableData* y=[NSMutableData dataWithLength:width*height];
            NSMutableData* uv=[NSMutableData dataWithLength:width*height/2];
            [picture.luma getBytes:y.mutableBytes bytesPerRow:width fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];
            [picture.chroma getBytes:uv.mutableBytes bytesPerRow:width fromRegion:MTLRegionMake2D(0,0,width/2,height/2) mipmapLevel:0];
            NSString* yName=[NSString stringWithFormat:@"frame-%06lu.y",(unsigned long)index];
            NSString* uvName=[NSString stringWithFormat:@"frame-%06lu.uv",(unsigned long)index];
            CHECK([y writeToURL:[proof URLByAppendingPathComponent:yName] options:NSDataWritingWithoutOverwriting error:&error]);
            CHECK([uv writeToURL:[proof URLByAppendingPathComponent:uvName] options:NSDataWritingWithoutOverwriting error:&error]);
            [samples addObject:@{@"frame":@(index),@"y":yName,@"uv":uvName,
                @"y_sha256":CinematicHash(y),@"uv_sha256":CinematicHash(uv)}];
        }
    } }
    ProtectorCinematicFrame old = frame;
    ProtectorCinematicFrame restarted = SourceFrame(entry,42,std::min<NSUInteger>(40,count-1));
    CHECK(WaitImage(pack,restarted) != nil);
    CHECK([pack imageForFrame:old] == nil); // A previous opening cannot resurrect.
    restarted.decoded_frame_one_based=1;
    ProtectorCinematicImage* rewound = WaitImage(pack,restarted);
    CHECK(rewound != nil && rewound.frameIndex == 0); // Seek/rewind still uses exact PTS.
    ProtectorCinematicFrame wrong = restarted;
    wrong.rate_numerator++;
    [pack observeFrame:wrong];
    CHECK([pack imageForFrame:restarted] == nil);
    CHECK([[pack diagnostics][@"cached_frames"] count]==0);
    restarted.open_serial=43;
    CHECK(WaitImage(pack,restarted)!=nil);
    [pack invalidate];
    CHECK([pack imageForFrame:restarted] == nil);
    CHECK([[pack diagnostics][@"cached_frames"] count]==0);
    if (proof) {
        NSDictionary* result=@{@"schema":@"protector-native.cinematic-decoder-witness/v1",@"status":@"pass",
            @"manifest":manifest.path,@"manifest_sha256":pack.manifestSHA256,@"movie":entry[@"movie"],
            @"every_source_frame_requested":@(count),@"samples":samples,@"final_state":[pack diagnostics],
            @"scope":@"native HEVC frame/cache/timestamp checks; not translated-game playback or visual acceptance"};
        NSData* bytes=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
        CHECK([bytes writeToURL:[proof URLByAppendingPathComponent:@"receipt.json"] options:NSDataWritingWithoutOverwriting error:&error]);
    }
    printf("cinematic-pack checks passed, including %lu actual decoded frames and skip/rewind/invalidation\n",(unsigned long)count);
    return 0;
} }
