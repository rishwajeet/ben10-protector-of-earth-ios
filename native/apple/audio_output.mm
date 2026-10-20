#import "audio_output.h"
#import "protector/audio_output.h"
#import <AVFoundation/AVFoundation.h>

NSNotificationName const ProtectorAudioRouteLostNotification = @"ProtectorAudioRouteLostNotification";

@interface ProtectorNativeAudioOutput ()
@property(nonatomic) AVAudioEngine* engine;
@property(nonatomic) AVAudioSourceNode* source;
@property(nonatomic) BOOL paused;
@property(nonatomic) BOOL interrupted;
@property(nonatomic) BOOL stopped;
@property(nonatomic, readwrite) NSError* lastError;
@end

@implementation ProtectorNativeAudioOutput
- (NSDictionary*)diagnostics {
    AVAudioSession* session=AVAudioSession.sharedInstance;
    NSMutableArray* routes=[NSMutableArray array];
    for (AVAudioSessionPortDescription* port in session.currentRoute.outputs)
        [routes addObject:@{@"type":port.portType, @"name":port.portName}];
    return @{@"engine_running":@(self.engine.isRunning),
        @"transport_enabled":@(protector_audio_output_enabled()),
        @"frames_pushed":@(protector_audio_output_pushed()),
        @"frames_pulled":@(protector_audio_output_pulled()),
        @"frames_dropped":@(protector_audio_output_dropped()),
        @"frames_underrun":@(protector_audio_output_underrun()),
        @"paused":@(self.paused), @"interrupted":@(self.interrupted),
        @"category":session.category, @"sample_rate":@(session.sampleRate),
        @"output_volume":@(session.outputVolume), @"routes":routes,
        @"error":self.lastError ? self.lastError.description : (id)NSNull.null};
}
- (BOOL)start {
    NSAssert(NSThread.isMainThread,@"Audio lifecycle belongs on the main thread");
    protector_audio_output_reset();
    [self configureEngine];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(interruption:)
        name:AVAudioSessionInterruptionNotification object:AVAudioSession.sharedInstance];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(routeChanged:)
        name:AVAudioSessionRouteChangeNotification object:AVAudioSession.sharedInstance];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(mediaReset:)
        name:AVAudioSessionMediaServicesWereResetNotification object:AVAudioSession.sharedInstance];
    [self update];
    return self.lastError==nil;
}
- (void)configureEngine {
    if (self.engine) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVAudioEngineConfigurationChangeNotification object:self.engine];
        [self.engine stop];
    }
    self.engine=[[AVAudioEngine alloc] init];
    AVAudioFormat* format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:32000 channels:2];
    self.source=[[AVAudioSourceNode alloc] initWithFormat:format renderBlock:
        ^OSStatus(BOOL* silence,const AudioTimeStamp* timestamp,AVAudioFrameCount count,AudioBufferList* output) {
            (void)timestamp;
            if (output->mNumberBuffers!=2) return kAudio_ParamError;
            size_t copied=protector_audio_output_pull((float*)output->mBuffers[0].mData,
                (float*)output->mBuffers[1].mData,count);
            *silence=copied==0;
            return noErr;
        }];
    [self.engine attachNode:self.source];
    [self.engine connect:self.source to:self.engine.mainMixerNode format:format];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(routeChanged:)
        name:AVAudioEngineConfigurationChangeNotification object:self.engine];
}
- (void)update {
    protector_audio_output_enable(false);
    [self.engine pause];
    if (self.paused || self.interrupted || self.stopped) {
        [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        return;
    }
    NSError* error=nil;
    AVAudioSession* session=AVAudioSession.sharedInstance;
    // Respect the user's silent switch and coexist with other audio.
    if (![session setCategory:AVAudioSessionCategoryAmbient error:&error] ||
        ![session setActive:YES error:&error] || ![self.engine startAndReturnError:&error]) {
        self.lastError=error;
        return;
    }
    self.lastError=nil;
    protector_audio_output_enable(true);
}
- (void)setPaused:(BOOL)paused {
    if (_paused==paused) return;
    _paused=paused;
    [self update];
}
- (void)interruption:(NSNotification*)notification {
    NSDictionary* info=notification.userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.interrupted=[info[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]==AVAudioSessionInterruptionTypeBegan;
        // update honours the game's own pause state. An ended interruption with
        // no ShouldResume used to latch the output off until a manual pause
        // cycle; a game that is still running must get its sound back, and one
        // that is paused (including while inactive) stays silent as before.
        [self update];
    });
}
- (void)mediaReset:(NSNotification*)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stopped) return;
        protector_audio_output_enable(false);
        [self configureEngine];
        [self update];
    });
}
- (void)routeChanged:(NSNotification*)notification {
    BOOL configuration=[notification.name isEqual:AVAudioEngineConfigurationChangeNotification];
    // Unplugged headphones or a lost Bluetooth/AirPlay output must not leave
    // the game playing out loud. Built-in speaker/receiver changes do not count.
    BOOL externalOutputLost=NO;
    if (!configuration &&
        [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue]==AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        AVAudioSessionRouteDescription* previous=notification.userInfo[AVAudioSessionRouteChangePreviousRouteKey];
        for (AVAudioSessionPortDescription* port in previous.outputs)
            if (![port.portType isEqual:AVAudioSessionPortBuiltInSpeaker] &&
                ![port.portType isEqual:AVAudioSessionPortBuiltInReceiver]) externalOutputLost=YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.stopped && (!configuration || !self.engine.isRunning)) [self update];
        if (!self.stopped && externalOutputLost)
            [NSNotificationCenter.defaultCenter postNotificationName:ProtectorAudioRouteLostNotification object:self];
    });
}
- (void)stop {
    self.stopped=YES;
    protector_audio_output_enable(false);
    [self.engine stop];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
