// Asset-free tests of the production Apple lifecycle boundary. The fake guest
// entry below tests worker completion; it is not original-gameplay evidence.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#include "../apple/game_session.mm"
#pragma clang diagnostic pop
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <thread>

static std::atomic<unsigned> bootCalls{0};
static std::atomic<int> fakeBootResult{0};
static std::atomic<bool> observedNativeCopy{false};
static std::atomic<bool> observedNativeStartup{false};
static std::atomic<bool> observedStaticVisibility{false};
static std::atomic<unsigned> diagnosticCalls{0};
static std::atomic<bool> releaseDiagnostic{false};
static std::atomic<bool> diagnosticOnMainThread{false};
static std::atomic<bool> diagnosticCapturesPicture{true};

@interface OpeningTestRenderer : ProtectorLiveMetalRenderer
@property(atomic) ProtectorCinematicOpeningStatus openingStatus;
@property(atomic) BOOL openingPrepared;
@property(atomic) BOOL openingAbandoned;
@end
@implementation OpeningTestRenderer
- (void)prepareCinematicOpening:(ProtectorCinematicOpening)opening { (void)opening; self.openingPrepared = YES; }
- (ProtectorCinematicOpeningStatus)statusForCinematicOpening:(ProtectorCinematicOpening)opening {
    (void)opening; return self.openingStatus;
}
- (void)abandonCinematicOpening:(ProtectorCinematicOpening)opening { (void)opening; self.openingAbandoned = YES; }
- (void)setPresentationPaused:(BOOL)paused { (void)paused; }
@end

@interface BoundedDiagnosticSession : ProtectorGameSession
@end
@implementation BoundedDiagnosticSession
- (void)writeDiagnosticSnapshotCapturingPicture:(BOOL)capturePicture {
    diagnosticOnMainThread = NSThread.isMainThread;
    diagnosticCapturesPicture = capturePicture;
    ++diagnosticCalls;
    while (!releaseDiagnostic.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
}
@end

extern "C" int protector_translated_live_metal_main(int argc, char** argv) {
    assert(argc == 5 && argv && argv[4]);
    observedNativeCopy = getenv("PROTECTOR_NATIVE_UI_TEXT") &&
        !strcmp(getenv("PROTECTOR_NATIVE_UI_TEXT"), "1");
    observedNativeStartup = getenv("PROTECTOR_NATIVE_STARTUP") &&
        !strcmp(getenv("PROTECTOR_NATIVE_STARTUP"), "1");
    observedStaticVisibility = getenv("PROTECTOR_ENHANCED_STATIC_VISIBILITY") &&
        !strcmp(getenv("PROTECTOR_ENHANCED_STATIC_VISIBILITY"), "1");
    ++bootCalls;
    return fakeBootResult.load();
}

template<typename Predicate> static void WaitFor(Predicate predicate) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (!predicate()) {
        assert(std::chrono::steady_clock::now() < deadline);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

static void TestCinematicLoadingBoundary() {
    for (unsigned scenario=0; scenario<5; ++scenario) {
        ProtectorGameSession* session = [[ProtectorGameSession alloc] init];
        session.condition = [[NSCondition alloc] init];
        OpeningTestRenderer* renderer = [[OpeningTestRenderer alloc] init];
        renderer.openingStatus = scenario == 4 ? ProtectorCinematicOpeningUnavailable : ProtectorCinematicOpeningPending;
        session.renderer = renderer;
        ProtectorGuestPacer pacer = {}; pacer.anchored = true;
        session.guestPacer = pacer;
        ProtectorCinematicOpening opening = {}; opening.open_serial = 902;
        std::atomic<bool> returned{false};
        std::thread worker([&] { @autoreleasepool {
            [session prepareCinematicOpening:opening timeout:scenario == 1 ? 0.03 : 1.0];
            returned = true;
        }});
        WaitFor([&] { return renderer.openingPrepared; });
        if (scenario == 0 || scenario == 3) {
            if (scenario == 3) [session setPaused:YES];
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
            assert(!returned);
            renderer.openingStatus = ProtectorCinematicOpeningReady;
            if (scenario == 3) {
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
                assert(!returned); // decoding readiness cannot override pause
                [session setPaused:NO];
            }
        } else if (scenario == 2) {
            [session requestStop];
        }
        WaitFor([&] { return returned.load(); });
        worker.join();
        NSString* expected = scenario == 1 ? @"timeout-source-fallback" : scenario == 2 ? @"stopped" :
            scenario == 4 ? @"unavailable" : @"ready";
        assert([session.cinematicOpeningSnapshot[@"outcome"] isEqual:expected]);
        assert(renderer.openingAbandoned == (scenario == 1 || scenario == 2));
        if (scenario == 0 || scenario == 1 || scenario == 3) assert(!session.guestPacer.anchored);
        if (scenario == 4) assert(session.guestPacer.anchored); // no pack: no pacing mutation
    }
}

static ProtectorGameSession* Session(NSURL* root, NSString* name) {
    NSURL* directory = [root URLByAppendingPathComponent:name isDirectory:YES];
    NSError* error = nil;
    ProtectorGameSession* session = [[ProtectorGameSession alloc]
        initWithDevice:MTLCreateSystemDefaultDevice() dataRoot:root
        kpadReference:[root URLByAppendingPathComponent:@"kpad.json"]
        audioCoefficients:[root URLByAppendingPathComponent:@"coefficients.bin"]
        outputDirectory:directory
        saveDirectory:[directory URLByAppendingPathComponent:@"OriginalSaves"] error:&error];
    assert(session && !error);
    return session;
}

static void TestPauseDuringPacing(NSURL* root) {
    ProtectorGameSession* session = Session(root, @"pause-pacing");
    CPUState cpu;
    assert(protector_cpu_init(&cpu));
    protector_live_input_enable(true);
    protector_live_input_update(PROTECTOR_BUTTON_A, 1, -1);
    ProtectorGuestPacer pacer = {};
    double deadline = 0;
    assert(protector_guest_pacer_deadline(&pacer, 0, CACurrentMediaTime(), &deadline));
    session.guestPacer = pacer;
    cpu.timebase = PROTECTOR_WII_TIMEBASE_HZ;
    std::atomic<bool> entered{false}, returned{false};
    ProtectorLiveGXResult result = PROTECTOR_LIVE_GX_ERROR;
    std::thread worker([&] {
        @autoreleasepool {
            entered = true;
            const u8 nop = 0;
            result = [session receiveFrame:0 fifo:&nop size:1 cpu:&cpu];
            returned = true;
        }
    });
    WaitFor([&] { return entered.load(); });
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    assert(!returned);
    [session setPaused:YES];
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    // Before the fix, the pause signal released the pacing wait and admitted
    // a frame despite _paused being true.
    assert(!returned);
    ProtectorLiveInputSample input;
    assert(protector_live_input_sample(&input));
    assert(input.hold == 0 && input.stick_x == 0 && input.stick_y == 0);
    [session setPaused:NO];
    WaitFor([&] { return returned.load(); });
    worker.join();
    assert(result == PROTECTOR_LIVE_GX_CONTINUE && !session.failure);
    assert([session.renderer.stateCapture[@"rendered_frame_count"] unsignedIntValue] == 1);
    protector_live_input_enable(false);
    protector_cpu_destroy(&cpu);
}

static void TestReadOnlyLifecycleDiagnostics(NSURL* root) {
    ProtectorGameSession* session = Session(root, @"lifecycle-diagnostics");
    session.timingSnapshot = @{@"frame_index":@42, @"guest_timebase":@9000};
    protector_live_input_enable(true);
    protector_live_input_update(PROTECTOR_BUTTON_C, -.75f, .25f);
    NSDictionary* before = [session inputLifecycleDiagnostics];
    assert([before[@"input_samples"][@"count"] unsignedIntValue] == 0);
    ProtectorLiveInputSample sample = {};
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == PROTECTOR_BUTTON_C && sample.trigger == PROTECTOR_BUTTON_C);
    NSDictionary* observed = [session inputLifecycleDiagnostics];
    assert([observed[@"input_samples"][@"count"] unsignedIntValue] == 1);
    assert([observed[@"input_samples"][@"last_hold"] unsignedIntValue] == PROTECTOR_BUTTON_C);
    [session setPaused:YES];
    NSDictionary* paused = [session inputLifecycleDiagnostics];
    [session setPaused:YES]; // Repeated notifications are not new transitions.
    assert([[session inputLifecycleDiagnostics][@"pause_transitions"] count] == 1);
    [session setPaused:NO];
    NSArray* transitions = [session inputLifecycleDiagnostics][@"pause_transitions"];
    assert(transitions.count == 2 && [transitions[0][@"paused"] boolValue]);
    assert(![transitions[1][@"paused"] boolValue]);
    assert([transitions[0][@"frame_index"] isEqual:@42]);
    assert([transitions[1][@"guest_timebase"] isEqual:@9000]);
    for (unsigned i = 0; i < 10; ++i) [session setPaused:i % 2 == 0];
    assert([[session inputLifecycleDiagnostics][@"pause_transitions"] count] == 8);
    assert([paused[@"pause_transitions"] count] == 1); // Returned history is immutable.
    assert([paused[@"host_paused"] boolValue]);
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == 0 && sample.release == PROTECTOR_BUTTON_C);
    protector_live_input_enable(false);
}

static void TestStopWakesWait(NSURL* root, bool paused) {
    ProtectorGameSession* session = Session(root, paused ? @"stop-paused" : @"stop-pacing");
    CPUState cpu;
    assert(protector_cpu_init(&cpu));
    [session setPaused:paused];
    if (!paused) {
        ProtectorGuestPacer pacer = {};
        double deadline = 0;
        assert(protector_guest_pacer_deadline(&pacer, 0, CACurrentMediaTime(), &deadline));
        session.guestPacer = pacer;
        cpu.timebase = PROTECTOR_WII_TIMEBASE_HZ * 2u;
    }
    std::atomic<bool> entered{false}, returned{false};
    ProtectorLiveGXResult result = PROTECTOR_LIVE_GX_ERROR;
    std::thread worker([&] {
        @autoreleasepool {
            entered = true;
            const u8 nop = 0;
            result = [session receiveFrame:0 fifo:&nop size:1 cpu:&cpu];
            returned = true;
        }
    });
    WaitFor([&] { return entered.load(); });
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    assert(!returned);
    [session requestStop];
    WaitFor([&] { return returned.load(); });
    worker.join();
    assert(result == PROTECTOR_LIVE_GX_COMPLETE);
    assert(protector_live_gx_stop_requested());
    assert(!session.renderer.stateCapture[@"rendered_frame_count"]);
    protector_live_gx_set_sink(NULL, NULL);
    protector_cpu_destroy(&cpu);
}

static void TestWorkerCompletion(NSURL* root, int result,
                                ProtectorGameEdition edition = ProtectorGameEditionOriginal) {
    ProtectorGameSession* session = nil;
    if (edition == ProtectorGameEditionOriginal)
        session = Session(root, result ? @"worker-error" : @"worker-success");
    else {
        NSURL* directory = [root URLByAppendingPathComponent:@"worker-enhanced"];
        NSError* error = nil;
        session = [[ProtectorGameSession alloc] initWithDevice:MTLCreateSystemDefaultDevice()
            dataRoot:root kpadReference:[root URLByAppendingPathComponent:@"kpad.json"]
            audioCoefficients:[root URLByAppendingPathComponent:@"coefficients.bin"]
            outputDirectory:directory originalSaveDirectory:[directory URLByAppendingPathComponent:@"OriginalSaves"]
            edition:edition texturePackManifest:nil error:&error];
        assert(session && !error);
    }
    // A conflicting inherited environment cannot enable native copy in Original
    // or disable it in Enhanced. Observe the actual worker-entry boundary.
    setenv("PROTECTOR_NATIVE_UI_TEXT", edition == ProtectorGameEditionOriginal ? "1" : "0", 1);
    setenv("PROTECTOR_NATIVE_STARTUP", edition == ProtectorGameEditionOriginal ? "1" : "0", 1);
    setenv("PROTECTOR_ENHANCED_STATIC_VISIBILITY", edition == ProtectorGameEditionOriginal ? "1" : "0", 1);
    fakeBootResult = result;
    bootCalls = 0;
    std::atomic<bool> notified{false};
    auto* notifiedPointer = &notified;
    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:ProtectorGameSessionDidFinish object:session queue:nil
        usingBlock:^(NSNotification* notification) {
            assert(notification.object == session);
            notifiedPointer->store(true);
        }];
    [session start];
    [session start];
    WaitFor([&] { return notified.load(); });
    assert(bootCalls == 1 && session.finished && session.bootResult == result);
    assert(observedNativeCopy == (edition == ProtectorGameEditionUpgraded));
    assert(observedNativeStartup == (edition == ProtectorGameEditionUpgraded));
    assert(observedStaticVisibility == (edition == ProtectorGameEditionUpgraded));
    assert(strcmp(getenv("PROTECTOR_AX_MIX_SILENT"), "1") == 0);
    assert(strcmp(getenv("PROTECTOR_AX_COEFFICIENTS_PATH"),
        [root URLByAppendingPathComponent:@"coefficients.bin"].path.UTF8String) == 0);
    assert(!protector_live_input_enabled() && !protector_live_gx_has_sink());
    assert((session.failure != nil) == (result != 0));
    if (result == PROTECTOR_RUNTIME_SAVE_LOAD_FAILED) {
        assert([session.failure.localizedDescription containsString:@"Saved progress could not be read"]);
        assert([session.failure.localizedDescription containsString:@"have not been changed"]);
    } else if (result == PROTECTOR_RUNTIME_SAVE_DIRECTORY_FAILED) {
        assert([session.failure.localizedDescription containsString:@"Save storage is unavailable"]);
    } else if (result == PROTECTOR_RUNTIME_SAVE_COMMIT_FAILED) {
        assert([session.failure.localizedDescription containsString:@"could not be saved reliably"]);
        assert(![session.failure.localizedDescription containsString:@"have not been changed"]);
    }
    NSData* bytes = [NSData dataWithContentsOfURL:[session.outputDirectory
        URLByAppendingPathComponent:@"interactive-state.json"]];
    NSDictionary* state = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    assert([state[@"session_outcome"] isEqual:(result ? @"failed" : @"stopped_cleanly")]);
    assert((state[@"runtime_error"] != NSNull.null) == (result != 0));
    assert((state[@"runtime_error_details"] != NSNull.null) == (result != 0));
    assert([state[@"audio_output"] isEqual:@"disabled"]);
    assert([state[@"audio_mixer"] isKindOfClass:NSDictionary.class]);
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}

static void TestAudioSnapshotConcurrency(void) {
    ProtectorAXDiagnostics initial = {};
    protector_ax_diagnostics_init(&initial, PROTECTOR_AX_OUTPUT_SILENT);
    protector_ax_diagnostics_publish(&initial);
    std::atomic<bool> finished{false};
    std::thread writer([&] {
        ProtectorAXDiagnostics d = initial;
        for (u64 i = 1; i <= 10000; ++i) {
            d.frames = i * 96;
            d.command_lists = i;
            d.voices_processed = i * 3;
            protector_ax_diagnostics_publish(&d);
        }
        finished = true;
    });
    do {
        ProtectorAXDiagnostics d = {};
        protector_ax_diagnostics_read(&d);
        assert(d.frames == d.command_lists * 96);
        assert(d.voices_processed == d.command_lists * 3);
    } while (!finished.load());
    writer.join();
    initial.running = false;
    protector_ax_diagnostics_publish(&initial);
}

static void TestSaveStatusConcurrency(void) {
    protector_save_status_reset(true);
    std::atomic<bool> finished{false};
    std::thread writer([&] {
        for (unsigned i = 0; i < 10000; ++i)
            protector_save_status_record(i % 2, i % 3 == 0);
        finished = true;
    });
    do {
        ProtectorSaveStatus snapshot = {};
        protector_save_status_read(&snapshot);
        assert(snapshot.enabled);
        assert(snapshot.pending_failure_mask <= 3u);
        for (unsigned slot = 0; slot < 2; ++slot)
            assert(snapshot.attempts[slot] == snapshot.commits[slot] + snapshot.failures[slot]);
    } while (!finished.load());
    writer.join();
    ProtectorSaveStatus first = {}, second = {};
    protector_save_status_read(&first);
    protector_save_status_read(&second);
    assert(first.attempts[0] == 5000 && first.attempts[1] == 5000);
    assert(first.pending_failure_mask == second.pending_failure_mask);
    assert(first.attempts[0] == second.attempts[0] && first.attempts[1] == second.attempts[1]);
    protector_save_status_reset(false);
}

static void TestInvalidAudioCoefficients(NSURL* root) {
    NSError* error = nil;
    ProtectorGameSession* session = [[ProtectorGameSession alloc]
        initWithDevice:MTLCreateSystemDefaultDevice() dataRoot:root
        kpadReference:[root URLByAppendingPathComponent:@"kpad.json"]
        audioCoefficients:[root URLByAppendingPathComponent:@"sys/main.dol"]
        outputDirectory:[root URLByAppendingPathComponent:@"invalid-audio"]
        saveDirectory:[root URLByAppendingPathComponent:@"invalid-audio-saves"] error:&error];
    assert(!session && error && error.code == 3);
}

static void TestEditionSaveIsolation(NSURL* root) {
    NSError* error = nil;
    NSURL* original = [root URLByAppendingPathComponent:@"edition/OriginalSaves"];
    NSURL* originalResolved = SessionSaveDirectory(original, ProtectorGameEditionOriginal, &error);
    assert(originalResolved && !error);
    NSData* sentinel = [@"original progress must not change" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL* originalFile = [originalResolved URLByAppendingPathComponent:@"SavedGames"];
    assert([sentinel writeToURL:originalFile atomically:YES]);
    NSURL* upgraded = SessionSaveDirectory(original, ProtectorGameEditionUpgraded, &error);
    assert(upgraded && !error && ![upgraded.path isEqual:originalResolved.path]);
    assert([upgraded.lastPathComponent isEqual:@"UpgradedSaves-RBNEG9-v1"]);
    assert(![NSFileManager.defaultManager fileExistsAtPath:
        [upgraded URLByAppendingPathComponent:@"SavedGames"].path]);
    assert([[NSData dataWithContentsOfURL:originalFile] isEqual:sentinel]);
    assert(SessionSaveDirectory(original, ProtectorGameEditionUpgraded, &error));
    assert(!SessionSaveDirectory(upgraded, ProtectorGameEditionOriginal, &error));
    assert(error.code == 20);
    error = nil;
    assert(!SessionSaveDirectory(upgraded, ProtectorGameEditionUpgraded, &error));
    assert(error.code == 20);

    // A user-created or old unmarked directory must not be adopted as an
    // upgraded save namespace merely because its name happens to match.
    NSURL* foreign = [root URLByAppendingPathComponent:@"foreign/UpgradedSaves-RBNEG9-v1"];
    assert([NSFileManager.defaultManager createDirectoryAtURL:foreign
        withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([sentinel writeToURL:[foreign URLByAppendingPathComponent:@"keep-me"] atomically:YES]);
    error = nil;
    assert(!SessionSaveDirectory([root URLByAppendingPathComponent:@"foreign/OriginalSaves"],
        ProtectorGameEditionUpgraded, &error));
    assert(error.code == 20 && [[NSData dataWithContentsOfURL:
        [foreign URLByAppendingPathComponent:@"keep-me"]] isEqual:sentinel]);

    NSURL* linked = [root URLByAppendingPathComponent:@"linked/OriginalSaves"];
    assert(SessionSaveDirectory(linked, ProtectorGameEditionOriginal, &error));
    NSURL* badSibling = [root URLByAppendingPathComponent:@"linked/UpgradedSaves-RBNEG9-v1"];
    assert([NSFileManager.defaultManager createSymbolicLinkAtURL:badSibling
        withDestinationURL:linked error:nil]);
    error = nil;
    assert(!SessionSaveDirectory(linked, ProtectorGameEditionUpgraded, &error));
    assert(error.code == 20);
    error = nil;
    assert(!SessionSaveDirectory([NSURL URLWithString:@"https://example.invalid/saves"],
        ProtectorGameEditionOriginal, &error));
    assert(error.code == 20);
}

static void TestBoundedDiagnosticRequests() {
    BoundedDiagnosticSession* session = [[BoundedDiagnosticSession alloc] init];
    diagnosticCalls = 0; releaseDiagnostic = false;
    [session requestDiagnosticSnapshot];
    WaitFor([&] { return diagnosticCalls.load() == 1; });
    for (unsigned i = 0; i < 100; ++i) [session requestDiagnosticSnapshot];
    assert(diagnosticCalls == 1 && !diagnosticOnMainThread);
    assert(!diagnosticCapturesPicture);
    releaseDiagnostic = true;
    WaitFor([&] { @synchronized(session) { return !session.diagnosticSnapshotPending; } });
    [session requestDiagnosticSnapshot];
    WaitFor([&] { @synchronized(session) { return !session.diagnosticSnapshotPending; } });
    assert(diagnosticCalls == 2);
    assert(!diagnosticCapturesPicture);
    [session saveDiagnosticSnapshot];
    assert(diagnosticCalls == 3 && diagnosticCapturesPicture);
}

static void TestRendererFailureDetails(NSURL* root) {
    ProtectorGameSession* session = Session(root, @"allocation-failure-details");
    session.finished = YES;
    session.timingFailure = [NSError errorWithDomain:@"ProtectorTexturePack" code:2 userInfo:@{
        NSLocalizedDescriptionKey:@"Synthetic frame allocation failure",
        @"frame_bytes":@230000000, @"requested_bytes":@45000000,
        @"source_key":@"synthetic-source", @"frame_sources":@[@"existing-source"],
        @"private_object":[NSObject new]}];
    [session saveDiagnosticSnapshot];
    NSData* bytes = [NSData dataWithContentsOfURL:[session.outputDirectory
        URLByAppendingPathComponent:@"interactive-state.json"]];
    NSDictionary* state = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    assert([state[@"session_outcome"] isEqual:@"failed"]);
    assert(([state[@"runtime_error_details"] isEqual:@{
        @"domain":@"ProtectorTexturePack", @"code":@2, @"frame_bytes":@230000000,
        @"requested_bytes":@45000000, @"source_key":@"synthetic-source",
        @"frame_sources":@[@"existing-source"]}]));
}

int main() {
    @autoreleasepool {
        char temporary[] = "/tmp/protector-session-test-XXXXXX";
        assert(mkdtemp(temporary));
        NSURL* root = [NSURL fileURLWithPath:@(temporary) isDirectory:YES];
        NSFileManager* manager = NSFileManager.defaultManager;
        for (NSString* path in @[@"sys", @"files"])
            assert([manager createDirectoryAtURL:[root URLByAppendingPathComponent:path]
                withIntermediateDirectories:YES attributes:nil error:nil]);
        for (NSString* path in @[@"sys/main.dol", @"sys/fst.bin"])
            assert([NSData.data writeToURL:[root URLByAppendingPathComponent:path] atomically:YES]);
        NSMutableString* raw = [NSMutableString stringWithCapacity:264];
        for (unsigned i = 0; i < 132; ++i) [raw appendString:i == 0x5C ? @"01" : @"00"];
        NSDictionary* reference = @{@"schema": @"protector-native.dolphin-kpad-status/v1",
            @"polls": @[@{@"status": @{@"device_type": @1, @"wpad_error": @0, @"raw_hex": raw}}]};
        NSData* json = [NSJSONSerialization dataWithJSONObject:reference options:0 error:nil];
        assert([json writeToURL:[root URLByAppendingPathComponent:@"kpad.json"] atomically:YES]);
        // Synthetic data tests the shell boundary; it is never a game-audio proof.
        assert([[NSMutableData dataWithLength:4096]
            writeToURL:[root URLByAppendingPathComponent:@"coefficients.bin"] atomically:YES]);
        TestPauseDuringPacing(root);
        TestCinematicLoadingBoundary();
        TestReadOnlyLifecycleDiagnostics(root);
        TestInvalidAudioCoefficients(root);
        TestEditionSaveIsolation(root);
        TestStopWakesWait(root, true);
        TestStopWakesWait(root, false);
        TestWorkerCompletion(root, 0);
        TestWorkerCompletion(root, 13);
        TestWorkerCompletion(root, PROTECTOR_RUNTIME_SAVE_DIRECTORY_FAILED);
        TestWorkerCompletion(root, PROTECTOR_RUNTIME_SAVE_LOAD_FAILED);
        TestWorkerCompletion(root, PROTECTOR_RUNTIME_SAVE_COMMIT_FAILED);
        TestWorkerCompletion(root, 0, ProtectorGameEditionUpgraded);
        TestAudioSnapshotConcurrency();
        TestSaveStatusConcurrency();
        TestBoundedDiagnosticRequests();
        TestRendererFailureDetails(root);
        assert([manager removeItemAtURL:root error:nil]);
        std::puts("Apple session: pacing pause, resume, stop wakeup, input reset, and error reporting passed");
    }
    return 0;
}
