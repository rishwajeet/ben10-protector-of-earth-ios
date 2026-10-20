#import "protector/game_session.h"
#import "protector/live_input.h"
#import "protector/ui_context.h"
#import "protector/ax_diagnostics.h"
#import "protector/guest_pacer.h"
#import "protector/runtime_result.h"
#import "protector/save_store.h"
#if PROTECTOR_NATIVE_AUDIO_OUTPUT
#import "audio_output.h"
#endif

extern "C" int protector_translated_live_metal_main(int argc, char** argv);
NSNotificationName const ProtectorGameSessionDidFinish = @"ProtectorGameSessionDidFinish";

@interface ProtectorGameSession ()
@property(nonatomic, readwrite) ProtectorLiveMetalRenderer* renderer;
@property(nonatomic, readwrite) NSURL* outputDirectory;
@property(nonatomic, readwrite) NSURL* saveDirectory;
@property(nonatomic, readwrite) ProtectorGameEdition edition;
@property(nonatomic, readwrite) BOOL hasRestoredArtwork;
@property(nonatomic) NSURL* dataRoot;
@property(nonatomic) NSURL* audioCoefficients;
@property(nonatomic) NSString* kpadTemplate;
#if PROTECTOR_NATIVE_AUDIO_OUTPUT
@property(nonatomic) ProtectorNativeAudioOutput* nativeAudio;
#endif
@property(nonatomic) NSCondition* condition;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL started;
@property(nonatomic) ProtectorGuestPacer guestPacer;
@property(nonatomic) u64 hostPauseCount;
@property(nonatomic) NSError* timingFailure;
@property(nonatomic) NSDictionary* timingSnapshot;
@property(nonatomic) NSDictionary* cinematicOpeningSnapshot;
@property(nonatomic) NSMutableArray<NSDictionary*>* pauseTransitions;
@property(nonatomic) NSObject* snapshotWriteLock;
@property(nonatomic) BOOL diagnosticSnapshotPending;
- (void)saveDiagnosticStatus;
- (void)writeDiagnosticSnapshotCapturingPicture:(BOOL)capturePicture;
@property(atomic, readwrite) BOOL finished;
@property(atomic, readwrite) int bootResult;
- (ProtectorLiveGXResult)receiveFrame:(u32)frame fifo:(const u8*)fifo
                                size:(size_t)size cpu:(CPUState*)cpu;
- (void)prepareCinematicOpening:(ProtectorCinematicOpening)opening timeout:(NSTimeInterval)timeout;
@end

static ProtectorLiveGXResult SessionFrame(u32 frame, const u8* fifo,
                                         size_t size, CPUState* cpu,
                                         void* context) {
    @autoreleasepool {
        ProtectorGameSession* session = (__bridge ProtectorGameSession*)context;
        return [session receiveFrame:frame fifo:fifo size:size cpu:cpu];
    }
}

static void SessionCinematicOpening(ProtectorCinematicOpening opening, void* context) {
    @autoreleasepool {
        // Explicit diagnostic A/B switch; never a persisted/player setting.
        const char* disabled = getenv("PROTECTOR_CINEMATIC_PREPARATION_DISABLED");
        if (disabled && !strcmp(disabled,"1")) return;
        ProtectorGameSession* session = (__bridge ProtectorGameSession*)context;
        [session prepareCinematicOpening:opening timeout:2.0];
    }
}

static NSError* EditionError(NSString* message) {
    return [NSError errorWithDomain:@"ProtectorSession" code:20
        userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSURL* SessionSaveDirectory(NSURL* original, ProtectorGameEdition edition,
                                  NSError** error) {
    if (!original.isFileURL ||
        (edition != ProtectorGameEditionOriginal && edition != ProtectorGameEditionUpgraded)) {
        if (error) *error = EditionError(@"Choose a valid edition and local original-save directory.");
        return nil;
    }
    NSURL* resolvedOriginal = original.URLByStandardizingPath.URLByResolvingSymlinksInPath;
    NSURL* selected = edition == ProtectorGameEditionOriginal ? resolvedOriginal :
        [[resolvedOriginal.URLByDeletingLastPathComponent
            URLByAppendingPathComponent:@"UpgradedSaves-RBNEG9-v1" isDirectory:YES]
            URLByResolvingSymlinksInPath];
    if (edition == ProtectorGameEditionUpgraded &&
        ([selected.path isEqual:resolvedOriginal.path] ||
         [selected.path hasPrefix:[resolvedOriginal.path stringByAppendingString:@"/"]] ||
         [resolvedOriginal.path hasPrefix:[selected.path stringByAppendingString:@"/"]])) {
        if (error) *error = EditionError(@"Original and upgraded progress must be in separate save directories.");
        return nil;
    }
    NSFileManager* manager = NSFileManager.defaultManager;
    NSURL* markerURL = [selected URLByAppendingPathComponent:@".protector-edition.json"];
    NSString* name = edition == ProtectorGameEditionOriginal ? @"original" : @"upgraded";
    NSDictionary* expected = @{@"schema":@"protector-native.save-edition/v1",
        @"edition":name, @"title":@"RBNEG9", @"namespace_version":@1};
    if ([manager fileExistsAtPath:markerURL.path]) {
        NSData* data = [NSData dataWithContentsOfURL:markerURL options:0 error:error];
        if (!data) return nil;
        id marker = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
        if (![marker isEqual:expected]) {
            if (error) *error = EditionError(@"The selected save directory belongs to a different edition.");
            return nil;
        }
    } else if (edition == ProtectorGameEditionUpgraded) {
        BOOL directory = NO;
        if ([manager fileExistsAtPath:selected.path isDirectory:&directory]) {
            NSArray* contents = directory ? [manager contentsOfDirectoryAtURL:selected
                includingPropertiesForKeys:nil options:0 error:error] : nil;
            if (!contents || contents.count) {
                if (error) *error = EditionError(@"Upgraded save storage already contains unmarked files. Choose a separate original-save parent.");
                return nil;
            }
        }
        if (![manager createDirectoryAtURL:selected withIntermediateDirectories:YES
                attributes:nil error:error]) return nil;
        NSData* data = [NSJSONSerialization dataWithJSONObject:expected options:NSJSONWritingSortedKeys error:error];
        if (!data || ![data writeToURL:markerURL options:NSDataWritingAtomic error:error]) return nil;
    }
    if (![manager createDirectoryAtURL:selected withIntermediateDirectories:YES
            attributes:nil error:error]) return nil;
    return selected;
}

@implementation ProtectorGameSession

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                               dataRoot:(NSURL*)dataRoot
                          kpadReference:(NSURL*)kpadReference
                      audioCoefficients:(NSURL*)audioCoefficients
                        outputDirectory:(NSURL*)outputDirectory
                          saveDirectory:(NSURL*)saveDirectory
                                  error:(NSError**)error {
    return [self initWithDevice:device dataRoot:dataRoot kpadReference:kpadReference
        audioCoefficients:audioCoefficients outputDirectory:outputDirectory
        originalSaveDirectory:saveDirectory edition:ProtectorGameEditionOriginal
        texturePackManifest:nil error:error];
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                               dataRoot:(NSURL*)dataRoot
                          kpadReference:(NSURL*)kpadReference
                      audioCoefficients:(NSURL*)audioCoefficients
                        outputDirectory:(NSURL*)outputDirectory
                  originalSaveDirectory:(NSURL*)originalSaveDirectory
                                edition:(ProtectorGameEdition)edition
                    texturePackManifest:(nullable NSURL*)texturePackManifest
                                  error:(NSError**)error {
    self = [super init];
    if (!self) return nil;
    if ((edition != ProtectorGameEditionOriginal && edition != ProtectorGameEditionUpgraded) ||
        (edition == ProtectorGameEditionOriginal && texturePackManifest)) {
        if (error) *error = EditionError(@"Restored artwork requires the upgraded edition.");
        return nil;
    }
    NSData* data = [NSData dataWithContentsOfURL:kpadReference options:0 error:error];
    if (!data) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    NSString* raw = nil;
    if ([value isKindOfClass:NSDictionary.class] &&
        [value[@"schema"] isEqual:@"protector-native.neutral-kpad/v1"]) {
        // Native input supplies buttons, sticks, pointer and motion each poll.
        // Only the extension type/error bytes are a persistent device contract.
        // No captured controller state is needed in a personal build.
        uint8_t neutral[132] = {};
        neutral[0x5C] = 1;
        NSMutableString* hex = [NSMutableString stringWithCapacity:264];
        for (unsigned i=0;i<sizeof(neutral);++i) [hex appendFormat:@"%02x",neutral[i]];
        raw = hex;
    }
    if ([value isKindOfClass:NSDictionary.class] &&
        [value[@"schema"] isEqual:@"protector-native.dolphin-kpad-status/v1"] &&
        [value[@"polls"] isKindOfClass:NSArray.class]) {
        for (id poll in value[@"polls"]) {
            if (![poll isKindOfClass:NSDictionary.class]) continue;
            id status = poll[@"status"];
            if (![status isKindOfClass:NSDictionary.class]) continue;
            if ([status[@"device_type"] isEqual:@1] &&
                [status[@"wpad_error"] isEqual:@0] &&
                [status[@"raw_hex"] isKindOfClass:NSString.class]) {
                NSString* candidate = status[@"raw_hex"];
                NSCharacterSet* invalid = [[NSCharacterSet
                    characterSetWithCharactersInString:@"0123456789abcdefABCDEF"]
                    invertedSet];
                if (candidate.length == 264 &&
                    [candidate rangeOfCharacterFromSet:invalid].location == NSNotFound &&
                    [[candidate substringWithRange:NSMakeRange(0x5C * 2, 4)] isEqual:@"0100"]) {
                    raw = candidate;
                    break;
                }
            }
        }
    }
    if (!raw) {
        if (error) *error = [NSError errorWithDomain:@"ProtectorSession" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                @"A source-bound connected Nunchuk reference is required."}];
        return nil;
    }
    for (NSString* relative in @[@"sys/main.dol", @"sys/fst.bin", @"files"]) {
        if (![NSFileManager.defaultManager fileExistsAtPath:
                [dataRoot URLByAppendingPathComponent:relative].path]) {
            if (error) *error = [NSError errorWithDomain:@"ProtectorSession" code:2
                userInfo:@{NSLocalizedDescriptionKey:
                    [@"Missing original game content: " stringByAppendingString:relative]}];
            return nil;
        }
    }
    // The app bundle's table is hash-admitted by CMake. An explicit developer
    // override still has to pass the same runtime size check as offline capture.
    NSData* coefficientData = [NSData dataWithContentsOfURL:audioCoefficients options:0 error:error];
    if (!coefficientData) return nil;
    if (coefficientData.length != 4096) {
        if (error) *error = [NSError errorWithDomain:@"ProtectorSession" code:3
            userInfo:@{NSLocalizedDescriptionKey:
                @"The original audio mixer requires a 4096-byte DSP coefficient table."}];
        return nil;
    }
    _renderer = [[ProtectorLiveMetalRenderer alloc] initContinuousWithDevice:device
        outputDirectory:outputDirectory texturePackManifest:texturePackManifest
        presentationUpgrades:edition == ProtectorGameEditionUpgraded error:error];
    if (!_renderer) return nil;
    NSURL* saveDirectory = SessionSaveDirectory(originalSaveDirectory, edition, error);
    if (!saveDirectory) return nil;
    _outputDirectory = outputDirectory;
    _saveDirectory = saveDirectory;
    _edition = edition;
    _hasRestoredArtwork = texturePackManifest != nil;
    _dataRoot = dataRoot;
    _audioCoefficients = audioCoefficients;
    _kpadTemplate = raw;
    _condition = [[NSCondition alloc] init];
    _snapshotWriteLock = [[NSObject alloc] init];
    return self;
}

- (void)start {
    if (self.started) return;
    self.started = YES;
    protector_cinematic_clear_logo_skip();
    setenv("PROTECTOR_KPAD_TEMPLATE_HEX", self.kpadTemplate.UTF8String, 1);
    // Interactive play ends on an explicit stop or runtime failure, not the
    // short diagnostic budget. The boot counter and parser are both 64-bit.
    setenv("PROTECTOR_MAX_BLOCKS", "18446744073709551615", 1);
    setenv("PROTECTOR_SAVE_ROOT", self.saveDirectory.path.UTF8String, 1);
    // The edition is immutable for this session. In particular, an inherited
    // developer environment must never enable replacement in Original.
    setenv("PROTECTOR_NATIVE_UI_TEXT",
        self.edition == ProtectorGameEditionUpgraded ? "1" : "0", 1);
    setenv("PROTECTOR_NATIVE_STARTUP",
        self.edition == ProtectorGameEditionUpgraded ? "1" : "0", 1);
    setenv("PROTECTOR_ENHANCED_STATIC_VISIBILITY",
        self.edition == ProtectorGameEditionUpgraded ? "1" : "0", 1);
    // Every normal session runs the real mixer, including muted development.
    // An explicit PCM capture can also observe it; neither path opens speakers.
    setenv("PROTECTOR_AX_MIX_SILENT", "1", 1);
    setenv("PROTECTOR_AX_COEFFICIENTS_PATH", self.audioCoefficients.path.UTF8String, 1);
    ProtectorAXDiagnostics initialAudio = {};
    protector_ax_diagnostics_init(&initialAudio, PROTECTOR_AX_OUTPUT_DISABLED);
    protector_ax_diagnostics_publish(&initialAudio);
#if PROTECTOR_NATIVE_AUDIO_OUTPUT
    // Developer/test launches must set FORCE_SILENT=1. No audio device is
    // created in that mode, even if a caller also requests native output.
    const char* forceSilent=getenv("PROTECTOR_FORCE_SILENT");
    if (!forceSilent || strcmp(forceSilent,"1")) {
        self.nativeAudio=[[ProtectorNativeAudioOutput alloc] init];
        [self.nativeAudio start];
    }
#endif
    protector_live_input_enable(true);
    protector_ui_context_publish(PROTECTOR_UI_GAMEPLAY);
    protector_live_gx_set_sink(SessionFrame, (__bridge void*)self);
    protector_live_gx_set_cinematic_open_sink(SessionCinematicOpening, (__bridge void*)self);
    NSThread* worker = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            NSString* dol = [self.dataRoot URLByAppendingPathComponent:@"sys/main.dol"].path;
            char* arguments[] = {(char*)"Protector Native", (char*)"--dol",
                (char*)dol.UTF8String, (char*)"--data-root",
                (char*)self.dataRoot.path.UTF8String, NULL};
            self.bootResult = protector_translated_live_metal_main(5, arguments);
            protector_live_gx_set_sink(NULL, NULL);
            protector_live_input_enable(false);
            self.finished = YES;
#if PROTECTOR_NATIVE_AUDIO_OUTPUT
            dispatch_async(dispatch_get_main_queue(), ^{ [self.nativeAudio stop]; });
#endif
            [self saveDiagnosticSnapshot];
            [NSNotificationCenter.defaultCenter postNotificationName:ProtectorGameSessionDidFinish
                object:self];
        }
    }];
    /* Boot diagnostics plus generated C need more than a dispatch worker's
     * roughly 512 KiB stack. This is a reserved stack, not guest RAM. */
    worker.stackSize = 8u * 1024u * 1024u;
    worker.name = @"Protector translated runtime";
    worker.qualityOfService = NSQualityOfServiceUserInitiated;
    [worker start];
}

- (void)setPaused:(BOOL)paused {
    [self.condition lock];
    if (_paused != paused) {
        protector_guest_pacer_reset(&_guestPacer);
        if (paused) ++_hostPauseCount;
        if (!self.pauseTransitions) self.pauseTransitions = [NSMutableArray array];
        [self.pauseTransitions addObject:@{@"paused":@(paused),
            @"host_monotonic_seconds":@(CACurrentMediaTime()),
            @"frame_index":self.timingSnapshot[@"frame_index"] ? self.timingSnapshot[@"frame_index"] : (id)NSNull.null,
            @"guest_timebase":self.timingSnapshot[@"guest_timebase"] ? self.timingSnapshot[@"guest_timebase"] : (id)NSNull.null}];
        if (self.pauseTransitions.count > 8) [self.pauseTransitions removeObjectAtIndex:0];
    }
    _paused = paused;
    protector_live_input_cancel();
    [self.condition broadcast];
    [self.condition unlock];
    [self.renderer setPresentationPaused:paused];
#if PROTECTOR_NATIVE_AUDIO_OUTPUT
    [self.nativeAudio setPaused:paused];
#endif
}

- (void)prepareCinematicOpening:(ProtectorCinematicOpening)opening timeout:(NSTimeInterval)timeout {
    // Called by the translated worker before original BinkOpen executes. Guest
    // time, source decode and audio mixing remain stationary. UIKit and Metal's
    // presentation thread never wait here; no renderer lock spans a wait.
    [self.renderer prepareCinematicOpening:opening];
    const double started = CACurrentMediaTime();
    NSString* outcome = @"unavailable";
    BOOL waited = NO;
    [self.condition lock];
    for (;;) {
        while (_paused && !self.stopping) [self.condition wait];
        if (self.stopping) {
            [self.renderer abandonCinematicOpening:opening];
            outcome = @"stopped";
            break;
        }
        const ProtectorCinematicOpeningStatus status = [self.renderer statusForCinematicOpening:opening];
        if (status != ProtectorCinematicOpeningPending) {
            if (status == ProtectorCinematicOpeningReady) outcome = @"ready";
            break;
        }
        const double remaining = started + timeout - CACurrentMediaTime();
        if (remaining <= 0) {
            [self.renderer abandonCinematicOpening:opening];
            outcome = @"timeout-source-fallback";
            break;
        }
        waited = YES;
        [self.condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:remaining < 0.01 ? remaining : 0.01]];
    }
    // Loading time must not turn into a burst of catch-up guest frames.
    if (waited) protector_guest_pacer_reset(&_guestPacer);
    self.cinematicOpeningSnapshot = @{@"open_serial":@(opening.open_serial),
        @"outcome":outcome, @"loading_ms":@((CACurrentMediaTime()-started)*1000),
        @"budget_ms":@(timeout*1000)};
    [self.condition unlock];
}

- (void)requestStop {
    [self.condition lock];
    self.stopping = YES;
    protector_live_gx_request_stop();
    [self.condition broadcast];
    [self.condition unlock];
}

- (ProtectorLiveGXResult)receiveFrame:(u32)frame fifo:(const u8*)fifo
                                size:(size_t)size cpu:(CPUState*)cpu {
    [self.condition lock];
    double deadline = 0;
    for (;;) {
        while (_paused && !self.stopping) [self.condition wait];
        if (self.stopping) {
            [self.condition unlock];
            return PROTECTOR_LIVE_GX_COMPLETE;
        }
        CFTimeInterval now = CACurrentMediaTime();
        if (!protector_guest_pacer_deadline(&_guestPacer, cpu->timebase,
                now, &deadline)) {
            self.timingFailure = [NSError errorWithDomain:@"ProtectorSession" code:14
                userInfo:@{NSLocalizedDescriptionKey: @"An invalid or backwards pacing clock was observed."}];
            [self.condition unlock];
            return PROTECTOR_LIVE_GX_ERROR;
        }
        if (deadline <= now) break;
        [self.condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:
            deadline - now]];
        // A pause/stop notification can wake the pacing wait before its deadline.
        // Recheck both conditions before admitting another guest frame.
    }
    CFTimeInterval admitted = CACurrentMediaTime();
    self.timingSnapshot = @{
        @"mode": @"guest_timebase",
        @"frame_index": @(frame),
        @"guest_timebase": @(cpu->timebase),
        @"guest_timebase_hz": @(PROTECTOR_WII_TIMEBASE_HZ),
        @"host_monotonic_seconds": @(admitted),
        @"deadline_seconds": @(deadline),
        @"late_rebases": @(_guestPacer.late_rebases),
        @"host_pause_count": @(_hostPauseCount),
    };
    [self.condition unlock];
    return [self.renderer consumeFrame:frame fifo:fifo size:size cpu:cpu hostDeadline:deadline];
}

- (nullable NSError*)failure {
    if (self.renderer.failure) return self.renderer.failure;
    [self.condition lock];
    NSError* timingFailure = self.timingFailure;
    [self.condition unlock];
    if (timingFailure) return timingFailure;
    ProtectorAXDiagnostics audio = {};
    protector_ax_diagnostics_read(&audio);
    if (audio.failed && audio.error[0]) {
        return [NSError errorWithDomain:@"ProtectorSession" code:13
            userInfo:@{NSLocalizedDescriptionKey: [@"Original audio mixer: "
                stringByAppendingString:@(audio.error)]}];
    }
    if (self.finished && self.bootResult != 0) {
        NSString* saveMessage = nil;
        switch (self.bootResult) {
            case PROTECTOR_RUNTIME_SAVE_DIRECTORY_FAILED:
                saveMessage = @"Save storage is unavailable. Reopen the app to try again. Keep the app installed to preserve its saves.";
                break;
            case PROTECTOR_RUNTIME_SAVE_LOAD_FAILED:
                saveMessage = @"Saved progress could not be read. Your save files have not been changed. Reopen the app to try again. Keep the app installed to preserve its saves.";
                break;
            case PROTECTOR_RUNTIME_SAVE_COMMIT_FAILED:
                saveMessage = @"Progress could not be saved reliably. Your latest changes may not be available after reopening. Keep the app installed to preserve its saves.";
                break;
        }
        if (saveMessage) return [NSError errorWithDomain:@"ProtectorSession" code:self.bootResult
            userInfo:@{NSLocalizedDescriptionKey:saveMessage}];
        return [NSError errorWithDomain:@"ProtectorSession" code:self.bootResult
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"The translated runtime stopped with error %d. See the runtime log.",
                self.bootResult]}];
    }
    return nil;
}

- (void)saveDiagnosticSnapshot {
    @synchronized(self.snapshotWriteLock) {
        [self writeDiagnosticSnapshotCapturingPicture:YES];
    }
}
- (void)saveDiagnosticStatus {
    @synchronized(self.snapshotWriteLock) {
        [self writeDiagnosticSnapshotCapturingPicture:NO];
    }
}

- (void)requestDiagnosticSnapshot {
    @synchronized(self) {
        if (self.diagnosticSnapshotPending) return;
        self.diagnosticSnapshotPending = YES;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            [self saveDiagnosticStatus];
            @synchronized(self) { self.diagnosticSnapshotPending = NO; }
        }
    });
}

- (NSDictionary*)inputLifecycleDiagnostics {
    [self.condition lock];
    NSDictionary* timing = self.timingSnapshot ? self.timingSnapshot : @{};
    NSArray* transitions = self.pauseTransitions ? [self.pauseTransitions copy] : @[];
    BOOL paused = _paused;
    [self.condition unlock];
    ProtectorLiveInputDiagnostics input = {};
    protector_live_input_diagnostics(&input);
    return @{@"schema":@"protector-native.input-lifecycle/v1",
        @"host_paused":@(paused), @"timing":timing, @"pause_transitions":transitions,
        @"input_samples":@{@"count":@(input.samples), @"last_hold":@(input.last.hold),
            @"camera_count":@(input.camera_samples), @"camera_trigger_count":@(input.camera_trigger_samples),
            @"last_stick":@[@(input.last.stick_x), @(input.last.stick_y)],
            @"last_pointer_valid":@(input.last.pointer_valid),
            @"last_pointer":@[@(input.last.pointer_x), @(input.last.pointer_y)],
            @"pointer_count":@(input.pointer_samples),
            @"wiimote_motion_count":@(input.wiimote_motion_samples),
            @"nunchuk_motion_count":@(input.nunchuk_motion_samples)}};
}

- (void)writeDiagnosticSnapshotCapturingPicture:(BOOL)capturePicture {
    NSError* error = nil;
    NSURL* picture = [self.outputDirectory URLByAppendingPathComponent:@"latest-frame.png"];
    // Periodic status must not read back and PNG-encode a multi-megapixel GPU
    // image every five seconds during play. Explicit/final captures still can.
    NSDictionary* captured = capturePicture ?
        [self.renderer writeLatestDiagnosticFrameToURL:picture error:&error] : nil;
    NSMutableDictionary* report = [(captured ? captured : self.renderer.stateCapture) mutableCopy];
    report[@"session_finished"] = @(self.finished);
    report[@"boot_result"] = @(self.bootResult);
    report[@"input_source"] = @"live_host_controls";
    report[@"input_lifecycle"] = [self inputLifecycleDiagnostics];
    ProtectorLiveInputDiagnostics input = {};
    protector_live_input_diagnostics(&input);
    report[@"input_samples"] = @{
        @"count": @(input.samples), @"pointer_count": @(input.pointer_samples),
        @"camera_count": @(input.camera_samples), @"camera_trigger_count": @(input.camera_trigger_samples),
        @"wiimote_motion_count": @(input.wiimote_motion_samples),
        @"nunchuk_motion_count": @(input.nunchuk_motion_samples),
        @"last_hold": @(input.last.hold),
        @"last_stick": @[@(input.last.stick_x), @(input.last.stick_y)],
        @"last_pointer_valid": @(input.last.pointer_valid),
        @"last_pointer": @[@(input.last.pointer_x), @(input.last.pointer_y)],
        @"last_wiimote_motion": @[@(input.last.wiimote_motion[0]),
            @(input.last.wiimote_motion[1]), @(input.last.wiimote_motion[2]),
            @(input.last.wiimote_motion[3]), @(input.last.wiimote_motion[4])],
        @"last_nunchuk_motion": @[@(input.last.nunchuk_motion[0]),
            @(input.last.nunchuk_motion[1]), @(input.last.nunchuk_motion[2]),
            @(input.last.nunchuk_motion[3]), @(input.last.nunchuk_motion[4])],
    };
    report[@"audio_output"] = @"disabled";
#if PROTECTOR_NATIVE_AUDIO_OUTPUT
    report[@"native_audio"] = self.nativeAudio ? self.nativeAudio.diagnostics :
        @{@"created":@NO, @"forced_silent":@([NSProcessInfo.processInfo.environment[@"PROTECTOR_FORCE_SILENT"] isEqual:@"1"])};
    if (self.nativeAudio) report[@"audio_output"] = self.nativeAudio.lastError ? @"failed" : @"native";
#endif
    [self.condition lock];
    report[@"timing"] = self.timingSnapshot ? self.timingSnapshot : @{};
    report[@"cinematic_opening"] = self.cinematicOpeningSnapshot ? self.cinematicOpeningSnapshot : @{};
    report[@"host_paused"] = @(_paused);
    [self.condition unlock];
    ProtectorAXDiagnostics audio = {};
    protector_ax_diagnostics_read(&audio);
    report[@"audio_mixer"] = @{
        @"mode": audio.mode == PROTECTOR_AX_OUTPUT_CAPTURE ? @"capture" :
            audio.mode == PROTECTOR_AX_OUTPUT_SILENT ? @"silent" : @"disabled",
        @"running": @(audio.running), @"configured": @(audio.configured),
        @"failed": @(audio.failed), @"sample_rate": @32000, @"channels": @2,
        @"frames": @(audio.frames), @"command_lists": @(audio.command_lists),
        @"voices_processed": @(audio.voices_processed),
        @"command_mask": @(audio.command_mask), @"ucode_hash": @(audio.ucode_hash),
        @"pcm_fnv1a64": [NSString stringWithFormat:@"%016llx", (unsigned long long)audio.pcm_fnv1a64],
        @"nonzero_samples": @[@(audio.nonzero[0]), @(audio.nonzero[1])],
        @"peak_absolute": @[@(audio.peak_absolute[0]), @(audio.peak_absolute[1])],
        @"full_scale_samples": @[@(audio.full_scale[0]), @(audio.full_scale[1])],
        @"error": audio.error[0] ? (id)@(audio.error) : NSNull.null,
    };
    report[@"save_directory"] = self.saveDirectory.path;
    ProtectorSaveStatus saveStatus = {};
    protector_save_status_read(&saveStatus);
    report[@"save_status"] = @{
        @"enabled":@(saveStatus.enabled),
        @"pending_failure_mask":@(saveStatus.pending_failure_mask),
        @"attempts":@[@(saveStatus.attempts[0]), @(saveStatus.attempts[1])],
        @"commits":@[@(saveStatus.commits[0]), @(saveStatus.commits[1])],
        @"failures":@[@(saveStatus.failures[0]), @(saveStatus.failures[1])],
    };
    report[@"edition"] = self.edition == ProtectorGameEditionOriginal ? @"original" : @"upgraded";
    report[@"save_policy"] = self.edition == ProtectorGameEditionOriginal ?
        @"original_rbneg9_atomic_with_previous_generation" : @"upgraded_rbneg9_v1_isolated_atomic_with_previous_generation";
    NSError* runtimeFailure = self.failure;
    NSString* failure = runtimeFailure.localizedDescription;
    report[@"session_outcome"] = !self.finished ? @"running" :
        (failure ? @"failed" : @"stopped_cleanly");
    report[@"runtime_error"] = failure ? (id)failure : NSNull.null;
    // Preserve bounded renderer diagnostics, not arbitrary NSError objects or
    // non-JSON userInfo. A saved failure must identify the allocation that
    // failed, rather than just the preceding successfully presented frame.
    NSMutableDictionary* failureDetails = runtimeFailure ? [@{
        @"domain":runtimeFailure.domain, @"code":@(runtimeFailure.code)} mutableCopy] : nil;
    for (NSString* key in @[@"frame_bytes", @"requested_bytes", @"source_key", @"frame_sources",
            @"frame_encoded_bytes", @"requested_encoded_bytes", @"allocation_budget_bytes",
            @"encoded_budget_bytes", @"memory_accounting"]) {
        id value = runtimeFailure.userInfo[key];
        if (value && [NSJSONSerialization isValidJSONObject:@[value]]) failureDetails[key] = value;
    }
    report[@"runtime_error_details"] = failureDetails ? (id)failureDetails : NSNull.null;
    NSData* json = [NSJSONSerialization dataWithJSONObject:report
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (json) [json writeToURL:[self.outputDirectory URLByAppendingPathComponent:
        @"interactive-state.json"] options:NSDataWritingAtomic error:&error];
    if (error) fprintf(stderr, "snapshot: %s\n", error.localizedDescription.UTF8String);
}
@end
