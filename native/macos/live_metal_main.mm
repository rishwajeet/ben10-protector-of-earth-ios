#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>

#import "protector/live_metal_renderer.h"
#include "protector/touch_layout.h"

extern "C" int protector_translated_live_metal_main(
    int argc,
    char** argv
);

static ProtectorLiveGXResult ReceiveLiveGX(
    u32 frameIndex,
    const u8* fifo,
    size_t fifoSize,
    CPUState* cpu,
    void* userData
) {
    ProtectorLiveMetalRenderer* renderer =
        (__bridge ProtectorLiveMetalRenderer*)userData;
    return [renderer consumeFrame:frameIndex
                             fifo:fifo
                             size:fifoSize
                              cpu:cpu];
}

static BOOL WriteJSON(
    NSDictionary* value,
    NSURL* destination,
    NSError** error
) {
    NSData* data = [NSJSONSerialization
        dataWithJSONObject:value
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
        error:error
    ];
    if (!data) {
        return NO;
    }
    NSMutableData* terminated = [data mutableCopy];
    const u8 newline = '\n';
    [terminated appendBytes:&newline length:1u];
    return [terminated writeToURL:destination
                          options:NSDataWritingAtomic
                            error:error];
}

// Internal, non-app artwork acceptance path. It never exposes an Original
// switch to players and never advances guest execution between comparisons.
@interface ProtectorInterfaceArtQA : NSObject
@property(nonatomic) ProtectorLiveMetalRenderer* renderer;
@property(nonatomic) NSURL* output;
@property(nonatomic) u32 target;
@property(nonatomic) BOOL captured;
@property(nonatomic) NSError* error;
@property(nonatomic) NSMutableArray* sourceFrames;
@property(nonatomic) BOOL fontMode;
@end
@implementation ProtectorInterfaceArtQA
@end

static ProtectorLiveGXResult ReceiveInterfaceArtQA(u32 frame, const u8* fifo,
        size_t size, CPUState* cpu, void* opaque) {
    ProtectorInterfaceArtQA* qa = (__bridge ProtectorInterfaceArtQA*)opaque;
    ProtectorLiveGXResult result = [qa.renderer consumeFrame:frame fifo:fifo size:size cpu:cpu];
    if (frame + 600 >= qa.target) {
        NSDictionary* state = qa.renderer.stateCapture;
        [qa.sourceFrames addObject:@{@"source_frame":@(frame),
            @"native_hud_draws":state[@"native_hud_draws"] ? state[@"native_hud_draws"] : @0,
            @"admission":state[@"native_hud_admission"] ? state[@"native_hud_admission"] : @"unreported"}];
    }
    if (result != PROTECTOR_LIVE_GX_CONTINUE || frame < qa.target) return result;
    NSError* error = nil;
    const NSUInteger hudDraws = [qa.renderer.stateCapture[@"native_hud_draws"] unsignedIntegerValue];
    // The open watch includes a silhouette (18 draws); the closed hourglass
    // after transformation has no silhouette (17). Both require the renderer's
    // complete source-bound cluster admission, never a partial-layer count.
    if (!qa.fontMode && ((hudDraws != 17 && hudDraws != 18) ||
            ![qa.renderer.stateCapture[@"native_hud_admission"] isEqual:@"source-bound-cluster"])) {
        qa.error = [NSError errorWithDomain:@"ProtectorInterfaceArtQA" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"Target frame does not contain the complete source-admitted gameplay HUD."}];
        return PROTECTOR_LIVE_GX_ERROR;
    }
    if (qa.fontMode) {
        NSArray* used = qa.renderer.stateCapture[@"texture_pack_frame_sources"];
        for (NSString* key in @[@"256x512-011e4572640c9b41459963c6c9884dc724e0bf94a9836ad76651755ab1edc05d",
                @"256x512-7f1c5d69d0069b594140d68077b3327041f518ef8af8975c07de443b1e421faa"]) {
            if (![used containsObject:key]) {
                qa.error = [NSError errorWithDomain:@"ProtectorInterfaceArtQA" code:2
                    userInfo:@{NSLocalizedDescriptionKey:@"Font frame lacks an exact display/body atlas replacement."}];
                return PROTECTOR_LIVE_GX_ERROR;
            }
        }
        if (![qa.renderer.stateCapture[@"texture_pack_frame_bytes"] unsignedLongLongValue])
            return PROTECTOR_LIVE_GX_ERROR;
    }
    const uint64_t ticks = cpu->timebase;
    const u32 pc = cpu->pc;
    if (![qa.renderer selectRenderScale:6 error:&error]) {
        qa.error = error;
        return PROTECTOR_LIVE_GX_ERROR;
    }
    for (NSString* name in @[@"vector", @"source", @"vector-again"]) {
        if (![name isEqual:@"vector"] && ![qa.renderer selectRestoredArtwork:
                ![name isEqual:@"source"] error:&error]) break;
        NSURL* png = [qa.output URLByAppendingPathComponent:[name stringByAppendingString:@".png"]];
        NSDictionary* state = [qa.renderer writeLatestDiagnosticFrameToURL:png error:&error];
        if (!state) break;
        NSMutableDictionary* receipt = [state mutableCopy];
        receipt[@"qa_mode"] = qa.fontMode ? @"frozen-font-art" : @"frozen-interface-art";
        receipt[@"guest_timebase"] = @(cpu->timebase);
        receipt[@"guest_pc"] = @(cpu->pc);
        receipt[@"audio_output"] = @"disabled";
        receipt[@"scope"] = qa.fontMode ? @"one translated text frame; not all strings or complete UI acceptance" :
            @"one translated gameplay frame; not animation or complete UI acceptance";
        if (cpu->timebase != ticks || cpu->pc != pc || !WriteJSON(receipt,
                [qa.output URLByAppendingPathComponent:[name stringByAppendingString:@".json"]], &error)) break;
        if ([name isEqual:@"vector-again"]) qa.captured = YES;
    }
    qa.error = error;
    if (qa.captured && !WriteJSON(@{@"source_frames":qa.sourceFrames,
            @"scope":@"last 601 original frames; counts prove cluster admission, not animation fidelity"},
            [qa.output URLByAppendingPathComponent:@"hud-admission.json"], &error)) {
        qa.error = error;
        qa.captured = NO;
    }
    return qa.captured ? PROTECTOR_LIVE_GX_COMPLETE : PROTECTOR_LIVE_GX_ERROR;
}

static int RunInterfaceArtQA(int argc, const char* argv[]) {
    if (argc != 7 || !getenv("PROTECTOR_KPAD_TEMPLATE_HEX")) {
        fprintf(stderr, "usage: --interface-art-qa MAIN.DOL DATA_ROOT NEW_OUTPUT_DIR HUD_PACK_JSON FRAME; requires a source-bound KPAD template\n");
        return 2;
    }
    char* end = nullptr;
    unsigned long frame = strtoul(argv[6], &end, 10);
    if (!*argv[6] || *end || frame < 1 || frame > 10000) return 2;
    NSURL* output = [NSURL fileURLWithPath:@(argv[4]) isDirectory:YES];
    if ([NSFileManager.defaultManager fileExistsAtPath:output.path]) {
        fprintf(stderr, "Interface comparison output must be new.\n");
        return 2;
    }
    // Never accepts persistent-save paths or a motion-interpolation experiment.
    if (getenv("PROTECTOR_SAVE_ROOT") || getenv("PROTECTOR_MOTION_PRESENTATION")) return 2;
    NSError* error = nil;
    ProtectorInterfaceArtQA* qa = [[ProtectorInterfaceArtQA alloc] init];
    qa.output = output;
    qa.target = (u32)frame;
    qa.fontMode = strcmp(argv[1], "--font-art-qa") == 0;
    qa.sourceFrames = [NSMutableArray array];
    qa.renderer = [[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:MTLCreateSystemDefaultDevice()
        outputDirectory:output texturePackManifest:[NSURL fileURLWithPath:@(argv[5])]
        presentationUpgrades:YES error:&error];
    ProtectorTouchLayout controls = {};
    ProtectorTouchRect hud = {};
    if (!qa.renderer || !protector_touch_native_hud_layout(852, 393, {0, 59, 21, 59}, 1, false, &controls, &hud) ||
            ![qa.renderer selectWidescreen:YES error:&error] ||
            ![qa.renderer configureNativePresentationSize:CGSizeMake(852, 393)
                hudFrame:CGRectMake(hud.x, hud.y, hud.width, hud.height) error:&error]) {
        fprintf(stderr, "Interface renderer: %s\n", error.localizedDescription.UTF8String);
        return 3;
    }
    setenv("PROTECTOR_NATIVE_UI_TEXT", "1", 1);
    setenv("PROTECTOR_NATIVE_STARTUP", "1", 1);
    setenv("PROTECTOR_ENHANCED_STATIC_VISIBILITY", "1", 1);
    protector_live_gx_set_sink(ReceiveInterfaceArtQA, (__bridge void*)qa);
    char* boot[] = {(char*)"interface-art-qa", (char*)"--dol", (char*)argv[2],
        (char*)"--data-root", (char*)argv[3], nullptr};
    int bootResult = protector_translated_live_metal_main(5, boot);
    protector_live_gx_set_sink(nullptr, nullptr);
    if (!qa.captured || qa.error || qa.renderer.failure || bootResult) {
        fprintf(stderr, "Interface capture failed: captured=%d boot=%d error=%s\n", qa.captured,
            bootResult, (qa.error ? qa.error : qa.renderer.failure).localizedDescription.UTF8String);
        return 4;
    }
    puts("Frozen translated interface-art comparison captured; visual acceptance remains separate.");
    return 0;
}

@interface ProtectorGeometryQA : NSObject
@property(nonatomic) BOOL antialiasMode;
@property(nonatomic) ProtectorLiveMetalRenderer* renderer;
@property(nonatomic) NSURL* output;
@property(nonatomic) u32 minimumFrame;
@property(nonatomic) u32 maximumFrame;
@property(nonatomic) BOOL captured;
@property(nonatomic) NSError* error;
@end
@implementation ProtectorGeometryQA
@end

static NSString* GeometryQAMemoryHash(const u8* bytes, size_t size) {
    if (!bytes || size > UINT32_MAX) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)size, hash);
    NSMutableString* value = [NSMutableString string];
    for (unsigned char byte : hash) [value appendFormat:@"%02x", byte];
    return value;
}

static ProtectorLiveGXResult ReceiveGeometryQA(u32 frame, const u8* fifo, size_t size,
        CPUState* cpu, void* opaque) {
    ProtectorGeometryQA* qa = (__bridge ProtectorGeometryQA*)opaque;
    const auto result = [qa.renderer consumeFrame:frame fifo:fifo size:size cpu:cpu];
    if (result != PROTECTOR_LIVE_GX_CONTINUE) return result;
    NSDictionary* state = qa.renderer.stateCapture;
    const NSUInteger matches = [state[@"geometry_refined_draws"] unsignedIntegerValue];
    if (frame >= qa.maximumFrame && (!matches || frame < qa.minimumFrame)) {
        NSError* error = nil;
        [qa.renderer writeLatestDiagnosticFrameToURL:[qa.output URLByAppendingPathComponent:@"unmatched.png"] error:&error];
        qa.error = error;
        fprintf(stderr, "No admitted geometry before bounded frame %u.\n", frame);
        return PROTECTOR_LIVE_GX_ERROR;
    }
    if (frame < qa.minimumFrame || !matches) return PROTECTOR_LIVE_GX_CONTINUE;
    // This is a render-only freeze inside the original frame callback. No
    // simulator/app controls, save paths, game variables or camera are changed.
    const u64 ticks = cpu->timebase;
    const u32 pc = cpu->pc;
    NSString* ram = GeometryQAMemoryHash(cpu->ram, cpu->ram_size);
    NSString* mem2 = GeometryQAMemoryHash(cpu->mem2, cpu->mem2_size);
    NSError* error = nil;
    NSArray<NSString*>* phases = qa.antialiasMode ? @[@"unfiltered",@"edge-filtered",@"unfiltered-again"]
                                                : @[@"original",@"enhanced",@"original-again"];
    for (NSString* name in phases) {
        if (qa.antialiasMode) {
            [qa.renderer setValue:@([name isEqual:@"edge-filtered"]) forKey:@"sceneAntialiasEnabled"];
            if (![qa.renderer selectRestoredArtwork:YES error:&error]) break;
        } else if (![qa.renderer selectEnhancedModels:[name isEqual:@"enhanced"] error:&error]) break;
        NSDictionary* snapshot = [qa.renderer writeLatestDiagnosticFrameToURL:
            [qa.output URLByAppendingPathComponent:[name stringByAppendingString:@".png"]] error:&error];
        if (!snapshot || cpu->timebase != ticks || cpu->pc != pc ||
            ![ram isEqual:GeometryQAMemoryHash(cpu->ram, cpu->ram_size)] ||
            ![mem2 isEqual:GeometryQAMemoryHash(cpu->mem2, cpu->mem2_size)]) break;
        NSMutableDictionary* receipt = [snapshot mutableCopy];
        receipt[@"qa_mode"] = qa.antialiasMode ? @"frozen-translated-scene-aa/v1" : @"frozen-translated-geometry/v1";
        receipt[@"guest_timebase"] = @(ticks); receipt[@"guest_pc"] = @(pc);
        receipt[@"guest_ram_sha256"] = ram; receipt[@"guest_mem2_sha256"] = mem2;
        receipt[@"audio_output"] = @"disabled"; receipt[@"persistent_saves_enabled"] = @NO;
        receipt[@"scope"] = qa.antialiasMode ? @"One fixed enhanced translated frame, edge filter off/on/off; not native app or cadence acceptance"
            : @"One translated frame, original/enhanced/original; art, motion and performance acceptance remain separate";
        if (!WriteJSON(receipt, [qa.output URLByAppendingPathComponent:[name stringByAppendingString:@".json"]], &error)) break;
        if ([name isEqual:phases.lastObject]) qa.captured = YES;
    }
    if (qa.captured && qa.antialiasMode && getenv("PROTECTOR_SCENE_AA_COST")) {
        NSMutableArray* samples = [NSMutableArray array];
        // Render this retained source frame only. Alternating AB/BA pairs avoid
        // attributing warm-up or GPU-clock drift to the new pass. This is not
        // gameplay pacing evidence and never advances the guest.
        for (NSNumber* scale in @[@3,@5,@6]) {
            if (![qa.renderer selectRenderScale:scale.unsignedIntegerValue error:&error]) break;
            for (NSUInteger pair=0; pair<14 && !error; ++pair) {
                for (NSUInteger member=0; member<2; ++member) {
                    const BOOL enabled = (pair+member)%2;
                    [qa.renderer setValue:@(enabled) forKey:@"sceneAntialiasEnabled"];
                    const double start = CFAbsoluteTimeGetCurrent();
                    if (![qa.renderer selectRestoredArtwork:YES error:&error]) break;
                    id<MTLCommandBuffer> command = [qa.renderer valueForKey:@"latestRenderCommand"];
                    [command waitUntilCompleted];
                    if (command.error) { error=command.error; break; }
                    [samples addObject:@{@"scale":scale,@"pair":@(pair),@"enabled":@(enabled),
                        @"warmup":@(pair<2),@"host_seconds":@(CFAbsoluteTimeGetCurrent()-start),
                        @"gpu_seconds":@(command.GPUEndTime-command.GPUStartTime),
                        @"admission":qa.renderer.stateCapture[@"scene_antialias"]}];
                }
            }
        }
        const BOOL fixed = cpu->timebase==ticks && cpu->pc==pc &&
            [ram isEqual:GeometryQAMemoryHash(cpu->ram,cpu->ram_size)] &&
            [mem2 isEqual:GeometryQAMemoryHash(cpu->mem2,cpu->mem2_size)];
        if (!error && fixed) WriteJSON(@{@"samples":samples,@"guest_unchanged":@YES,
            @"scope":@"Fixed translated scene, paired complete render cost; not display cadence"},
            [qa.output URLByAppendingPathComponent:@"paired-render-cost.json"],&error);
        else qa.captured=NO;
    }
    qa.error = error;
    return qa.captured ? PROTECTOR_LIVE_GX_COMPLETE : PROTECTOR_LIVE_GX_ERROR;
}

static int RunGeometryQA(int argc, const char* argv[]) {
    if (argc != 9 || !getenv("PROTECTOR_KPAD_TEMPLATE_HEX") ||
        getenv("PROTECTOR_SAVE_ROOT") || getenv("PROTECTOR_MOTION_PRESENTATION") ||
        getenv("PROTECTOR_AX_PCM_CAPTURE_PATH")) {
        fprintf(stderr, "usage: --geometry-qa MAIN.DOL DATA_ROOT NEW_OUTPUT_DIR TEXTURE_PACK GEOMETRY_PACK MIN_FRAME MAX_FRAME; no persistent save/motion/capture overrides\n");
        return 2;
    }
    char* end = nullptr;
    const unsigned long minimum = strtoul(argv[7], &end, 10);
    if (!*argv[7] || *end || minimum < 1 || minimum > 10000) return 2;
    const unsigned long maximum = strtoul(argv[8], &end, 10);
    if (!*argv[8] || *end || maximum < minimum || maximum > 10000) return 2;
    NSURL* output = [NSURL fileURLWithPath:@(argv[4]) isDirectory:YES];
    if ([NSFileManager.defaultManager fileExistsAtPath:output.path]) return 2;
    NSError* error = nil;
    ProtectorGeometryQA* qa = [ProtectorGeometryQA new];
    qa.antialiasMode = strcmp(argv[1],"--scene-aa-qa") == 0;
    qa.output = output; qa.minimumFrame = (u32)minimum; qa.maximumFrame = (u32)maximum;
    qa.renderer = [[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:MTLCreateSystemDefaultDevice()
        outputDirectory:output texturePackManifest:[NSURL fileURLWithPath:@(argv[5])]
        presentationUpgrades:YES error:&error];
    if (!qa.renderer || ![qa.renderer loadGeometryPack:[NSURL fileURLWithPath:@(argv[6])] error:&error] ||
        ![qa.renderer selectWidescreen:YES error:&error] || ![qa.renderer selectRenderScale:3 error:&error]) {
        fprintf(stderr, "Geometry renderer: %s\n", error.localizedDescription.UTF8String);
        return 3;
    }
    setenv("PROTECTOR_NATIVE_UI_TEXT", "1", 1);
    setenv("PROTECTOR_NATIVE_STARTUP", "1", 1);
    setenv("PROTECTOR_ENHANCED_STATIC_VISIBILITY", "1", 1);
    protector_live_gx_set_sink(ReceiveGeometryQA, (__bridge void*)qa);
    char* boot[] = {(char*)"geometry-qa", (char*)"--dol", (char*)argv[2], (char*)"--data-root", (char*)argv[3], nullptr};
    const int bootResult = protector_translated_live_metal_main(5, boot);
    protector_live_gx_set_sink(nullptr, nullptr);
    if (!qa.captured || qa.error || qa.renderer.failure || bootResult) {
        fprintf(stderr, "Geometry capture failed: captured=%d boot=%d error=%s\n", qa.captured,
            bootResult, (qa.error ? qa.error : qa.renderer.failure).localizedDescription.UTF8String);
        return 4;
    }
    puts("Frozen translated geometry comparison captured; visual acceptance remains separate.");
    return 0;
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc > 1 && (strcmp(argv[1], "--geometry-qa") == 0 || strcmp(argv[1],"--scene-aa-qa") == 0))
            return RunGeometryQA(argc, argv);
        if (argc > 1 && (strcmp(argv[1], "--interface-art-qa") == 0 || strcmp(argv[1], "--font-art-qa") == 0))
            return RunInterfaceArtQA(argc, argv);
        if (argc < 5) {
            fprintf(
                stderr,
                "usage: protector_live_metal_harness "
                "MAIN.DOL DATA_ROOT OUTPUT_DIR FRAME [FRAME ...]\n"
            );
            return 2;
        }
        NSMutableArray<NSNumber*>* targetFrames =
            [NSMutableArray arrayWithCapacity:(NSUInteger)argc - 4u];
        for (int index = 4; index < argc; ++index) {
            char* end = NULL;
            unsigned long frame = strtoul(argv[index], &end, 10);
            if (
                end == argv[index] ||
                *end != '\0' ||
                frame > UINT32_MAX
            ) {
                fprintf(stderr, "invalid target frame: %s\n", argv[index]);
                return 2;
            }
            [targetFrames addObject:@(frame)];
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "no Metal device\n");
            return 3;
        }
        NSURL* outputDirectory = [NSURL fileURLWithPath:
            [NSString stringWithUTF8String:argv[3]]
            isDirectory:YES
        ];
        NSError* error = nil;
        ProtectorLiveMetalRenderer* renderer = [
            [ProtectorLiveMetalRenderer alloc]
            initWithDevice:device
            outputDirectory:outputDirectory
            targetFrames:targetFrames
            error:&error
        ];
        if (!renderer) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 4;
        }

        protector_live_gx_set_sink(
            ReceiveLiveGX,
            (__bridge void*)renderer
        );
        char* bootArguments[] = {
            (char*)"protector_live_metal_harness",
            (char*)"--dol",
            (char*)argv[1],
            (char*)"--data-root",
            (char*)argv[2],
            NULL,
        };
        const int bootResult =
            protector_translated_live_metal_main(5, bootArguments);
        protector_live_gx_set_sink(NULL, NULL);

        NSURL* stateURL = [
            outputDirectory URLByAppendingPathComponent:@"state.json"
        ];
        if (!WriteJSON(renderer.stateCapture, stateURL, &error)) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 5;
        }
        if (renderer.failure) {
            fprintf(
                stderr,
                "%s\n",
                renderer.failure.localizedDescription.UTF8String
            );
            return 6;
        }
        if (!renderer.complete) {
            fprintf(
                stderr,
                "translated execution ended before every target frame "
                "(boot_result=%d)\n",
                bootResult
            );
            return 7;
        }
        printf(
            "live_metal_source=translated_execution_callback "
            "external_scene_pack=0 target_frames=%lu "
            "submissions=%lu boot_result=%d device=%s\n",
            (unsigned long)targetFrames.count,
            (unsigned long)[
                renderer.stateCapture[@"submissions"] count
            ],
            bootResult,
            device.name.UTF8String
        );
        return 0;
    }
}
