#import <AVFoundation/AVFoundation.h>
#import <CoreHaptics/CoreHaptics.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <sys/utsname.h>

#include "protector/room.h"
#import "protector/metal_renderer.h"

static uint64_t ResidentMemoryBytes(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    const kern_return_t result = task_info(
        mach_task_self(),
        MACH_TASK_BASIC_INFO,
        (task_info_t)&info,
        &count
    );
    return result == KERN_SUCCESS ? info.resident_size : 0;
}

static NSString* ThermalStateName(NSProcessInfoThermalState state) {
    switch (state) {
    case NSProcessInfoThermalStateNominal:
        return @"nominal";
    case NSProcessInfoThermalStateFair:
        return @"fair";
    case NSProcessInfoThermalStateSerious:
        return @"serious";
    case NSProcessInfoThermalStateCritical:
        return @"critical";
    }
    return @"unknown";
}

static NSString* DeviceModelIdentifier(void) {
    struct utsname systemInfo = {0};
    if (uname(&systemInfo) != 0) {
        return @"unknown";
    }
    return [NSString stringWithUTF8String:systemInfo.machine];
}

static NSString* InterfaceOrientationName(UIInterfaceOrientation orientation) {
    switch (orientation) {
    case UIInterfaceOrientationLandscapeLeft:
        return @"landscape_left";
    case UIInterfaceOrientationLandscapeRight:
        return @"landscape_right";
    case UIInterfaceOrientationPortrait:
        return @"portrait";
    case UIInterfaceOrientationPortraitUpsideDown:
        return @"portrait_upside_down";
    case UIInterfaceOrientationUnknown:
        return @"unknown";
    }
    return @"unknown";
}

static BOOL IsPhysicalIOSDevice(void) {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    return YES;
#endif
}

static BOOL FillVector(NSArray* value, ProtectorVec3* output) {
    if (![value isKindOfClass:[NSArray class]] || value.count != 3 || !output) {
        return NO;
    }
    output->x = [value[0] floatValue];
    output->y = [value[1] floatValue];
    output->z = [value[2] floatValue];
    return isfinite(output->x) && isfinite(output->y) && isfinite(output->z);
}

static BOOL LoadRoomDefinition(
    NSURL* roomPackURL,
    ProtectorRoomDefinition* definition,
    NSData** collisionData,
    NSData** barrierData,
    NSData** gateBarrierData,
    NSError** error
) {
    NSURL* manifestURL =
        [roomPackURL URLByAppendingPathComponent:@"room.json"];
    NSData* data = [NSData dataWithContentsOfURL:manifestURL
                                         options:0
                                           error:error];
    if (!data) {
        return NO;
    }
    NSDictionary* manifest =
        [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!manifest ||
        ![manifest[@"schema"] isEqualToString:@"protector-native.room/v1"] ||
        [manifest[@"simulation"][@"tick_rate"] unsignedIntegerValue] !=
            PROTECTOR_ROOM_TICK_RATE) {
        if (error) {
            *error = [NSError
                errorWithDomain:@"house.machine.ProtectorNative.Room"
                           code:1
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Unsupported or invalid Canyon room manifest"
                       }];
        }
        return NO;
    }
    protector_room_definition_init(definition);
    NSDictionary* source = manifest[@"definition"];
    NSDictionary* encounter = source[@"encounter"];
    NSDictionary* exit = source[@"exit"];
    NSDictionary* bounds = source[@"world_bounds"];
    NSArray* enemies = source[@"enemies"];
    if (!FillVector(source[@"player_spawn"], &definition->player_spawn) ||
        !FillVector(encounter[@"center"], &definition->encounter_center) ||
        !FillVector(exit[@"center"], &definition->exit_center) ||
        !FillVector(bounds[@"minimum"], &definition->world_minimum) ||
        !FillVector(bounds[@"maximum"], &definition->world_maximum) ||
        ![enemies isKindOfClass:[NSArray class]] || enemies.count == 0 ||
        enemies.count > PROTECTOR_ROOM_MAX_ENEMIES) {
        if (error) {
            *error = [NSError
                errorWithDomain:@"house.machine.ProtectorNative.Room"
                           code:2
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Canyon room definition is incomplete"
                       }];
        }
        return NO;
    }
    definition->encounter_radius = [encounter[@"radius"] floatValue];
    definition->exit_radius = [exit[@"radius"] floatValue];
    definition->ground_height = [source[@"ground_height"] floatValue];
    definition->source_scene_instance_count =
        [source[@"source_scene_instance_count"] unsignedIntValue];
    NSDictionary* cameraPath = source[@"camera_path"];
    if (cameraPath) {
        NSArray* points = cameraPath[@"points"];
        const NSUInteger declaredCount =
            [cameraPath[@"point_count"] unsignedIntegerValue];
        if (![points isKindOfClass:[NSArray class]] ||
            points.count != declaredCount ||
            points.count < 2 ||
            points.count > PROTECTOR_ROOM_MAX_CAMERA_PATH_POINTS) {
            if (error) {
                *error = [NSError
                    errorWithDomain:@"house.machine.ProtectorNative.Room"
                               code:3
                           userInfo:@{
                               NSLocalizedDescriptionKey :
                                   @"Canyon source camera rail is invalid"
                           }];
            }
            return NO;
        }
        definition->camera_path_point_count = (uint32_t)points.count;
        for (NSUInteger index = 0; index < points.count; ++index) {
            NSDictionary* point = points[index];
            ProtectorCameraPathPoint* destination =
                &definition->camera_path_points[index];
            if (![point isKindOfClass:[NSDictionary class]] ||
                !FillVector(point[@"position"], &destination->position)) {
                if (error) {
                    *error = [NSError
                        errorWithDomain:@"house.machine.ProtectorNative.Room"
                                   code:4
                               userInfo:@{
                                   NSLocalizedDescriptionKey :
                                       @"Canyon source camera point is invalid"
                               }];
                }
                return NO;
            }
            destination->rotation_y_units =
                [point[@"rotation_y_units"] floatValue];
            destination->tilt_units = [point[@"tilt_units"] floatValue];
            destination->distance = [point[@"distance"] floatValue];
            destination->height = [point[@"height"] floatValue];
            if (!isfinite(destination->rotation_y_units) ||
                !isfinite(destination->tilt_units) ||
                !isfinite(destination->distance) ||
                !isfinite(destination->height) ||
                destination->distance <= 0.0f ||
                destination->height <= 0.0f) {
                if (error) {
                    *error = [NSError
                        errorWithDomain:@"house.machine.ProtectorNative.Room"
                                   code:5
                               userInfo:@{
                                   NSLocalizedDescriptionKey :
                                       @"Canyon source camera fields are invalid"
                               }];
                }
                return NO;
            }
        }
    }
    definition->enemy_count = (uint32_t)enemies.count;
    for (NSUInteger index = 0; index < enemies.count; ++index) {
        NSDictionary* enemy = enemies[index];
        if (!FillVector(
                enemy[@"position"],
                &definition->enemies[index].position
            )) {
            if (error) {
                *error = [NSError
                    errorWithDomain:@"house.machine.ProtectorNative.Room"
                               code:6
                           userInfo:@{
                               NSLocalizedDescriptionKey :
                                   @"Canyon enemy position is invalid"
                           }];
            }
            return NO;
        }
        definition->enemies[index].facing_radians =
            [enemy[@"facing_radians"] floatValue];
        definition->enemies[index].source_instance_index =
            [enemy[@"source_instance_index"] unsignedIntValue];
    }
    NSDictionary* collision = manifest[@"assets"][@"walkable_collision"];
    NSString* collisionPath = collision[@"path"];
    const NSUInteger triangleCount = [collision[@"count"] unsignedIntegerValue];
    const NSUInteger triangleStride = [collision[@"stride"] unsignedIntegerValue];
    if (![collisionPath isKindOfClass:[NSString class]] ||
        triangleCount == 0 ||
        triangleCount > UINT32_MAX ||
        triangleStride != sizeof(ProtectorCollisionTriangle)) {
        if (error) {
            *error = [NSError
                errorWithDomain:@"house.machine.ProtectorNative.Room"
                           code:7
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Canyon walkable collision manifest is invalid"
                       }];
        }
        return NO;
    }
    NSURL* collisionURL =
        [roomPackURL URLByAppendingPathComponent:collisionPath];
    NSData* loadedCollision =
        [NSData dataWithContentsOfURL:collisionURL options:0 error:error];
    if (!loadedCollision ||
        loadedCollision.length !=
            triangleCount * sizeof(ProtectorCollisionTriangle)) {
        if (error && !*error) {
            *error = [NSError
                errorWithDomain:@"house.machine.ProtectorNative.Room"
                           code:8
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Canyon walkable collision payload is invalid"
                       }];
        }
        return NO;
    }
    *collisionData = loadedCollision;
    definition->walkable_triangles =
        (const ProtectorCollisionTriangle*)loadedCollision.bytes;
    definition->walkable_triangle_count = (uint32_t)triangleCount;

    NSDictionary* barriers = manifest[@"assets"][@"barrier_collision"];
    NSString* barrierPath = barriers[@"path"];
    const NSUInteger barrierCount = [barriers[@"count"] unsignedIntegerValue];
    const NSUInteger barrierStride = [barriers[@"stride"] unsignedIntegerValue];
    if (![barrierPath isKindOfClass:[NSString class]] ||
        barrierCount == 0 ||
        barrierCount > UINT32_MAX ||
        barrierStride != sizeof(ProtectorCollisionTriangle)) {
        if (error) {
            *error = [NSError
                errorWithDomain:@"house.machine.ProtectorNative.Room"
                           code:9
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Canyon barrier collision manifest is invalid"
                       }];
        }
        return NO;
    }
    NSURL* barrierURL =
        [roomPackURL URLByAppendingPathComponent:barrierPath];
    NSData* loadedBarriers =
        [NSData dataWithContentsOfURL:barrierURL options:0 error:error];
    if (!loadedBarriers ||
        loadedBarriers.length !=
            barrierCount * sizeof(ProtectorCollisionTriangle)) {
        if (error && !*error) {
            *error = [NSError
                errorWithDomain:@"house.machine.ProtectorNative.Room"
                           code:10
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Canyon barrier collision payload is invalid"
                       }];
        }
        return NO;
    }
    *barrierData = loadedBarriers;
    definition->barrier_triangles =
        (const ProtectorCollisionTriangle*)loadedBarriers.bytes;
    definition->barrier_triangle_count = (uint32_t)barrierCount;

    NSDictionary* gateBarriers =
        manifest[@"assets"][@"gate_barrier_collision"];
    NSString* gateBarrierPath = gateBarriers[@"path"];
    const NSUInteger gateBarrierCount =
        [gateBarriers[@"count"] unsignedIntegerValue];
    const NSUInteger gateBarrierStride =
        [gateBarriers[@"stride"] unsignedIntegerValue];
    if (![gateBarrierPath isKindOfClass:[NSString class]] ||
        gateBarrierCount == 0 ||
        gateBarrierCount > UINT32_MAX ||
        gateBarrierStride != sizeof(ProtectorCollisionTriangle)) {
        if (error) {
            *error = [NSError
                errorWithDomain:@"house.machine.ProtectorNative.Room"
                           code:11
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Canyon gate collision manifest is invalid"
                       }];
        }
        return NO;
    }
    NSURL* gateBarrierURL =
        [roomPackURL URLByAppendingPathComponent:gateBarrierPath];
    NSData* loadedGateBarriers =
        [NSData dataWithContentsOfURL:gateBarrierURL options:0 error:error];
    if (!loadedGateBarriers ||
        loadedGateBarriers.length !=
            gateBarrierCount * sizeof(ProtectorCollisionTriangle)) {
        if (error && !*error) {
            *error = [NSError
                errorWithDomain:@"house.machine.ProtectorNative.Room"
                           code:12
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Canyon gate collision payload is invalid"
                       }];
        }
        return NO;
    }
    *gateBarrierData = loadedGateBarriers;
    definition->gate_barrier_triangles =
        (const ProtectorCollisionTriangle*)loadedGateBarriers.bytes;
    definition->gate_barrier_triangle_count = (uint32_t)gateBarrierCount;
    return YES;
}

@interface ProtectorAudioSystem : NSObject <AVAudioPlayerDelegate>
@property(nonatomic, strong) NSDictionary<NSString*, NSURL*>* cueURLs;
@property(nonatomic, strong) AVAudioPlayer* music;
@property(nonatomic, strong) AVAudioPlayer* dialogue;
@property(nonatomic, strong) NSMutableArray<AVAudioPlayer*>* effects;
@property(nonatomic) BOOL musicEnabled;
@property(nonatomic) BOOL effectsEnabled;
@property(nonatomic) BOOL dialogueEnabled;
@property(nonatomic) float outputGain;
- (instancetype)initWithRoomPack:(NSURL*)roomPackURL
                        manifest:(NSDictionary*)manifest
                           error:(NSError**)error;
- (void)playRoomCue:(ProtectorAudioCue)cue
               form:(ProtectorPlayerForm)form;
- (void)setMusicEnabledAndPersist:(BOOL)enabled;
- (void)setEffectsEnabledAndPersist:(BOOL)enabled;
- (void)setDialogueEnabledAndPersist:(BOOL)enabled;
@end

@implementation ProtectorAudioSystem

- (instancetype)initWithRoomPack:(NSURL*)roomPackURL
                        manifest:(NSDictionary*)manifest
                           error:(NSError**)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    NSDictionary* cueManifest = manifest[@"assets"][@"audio"][@"cues"];
    if (![cueManifest isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError
                errorWithDomain:@"house.machine.ProtectorNative.Audio"
                           code:1
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Canyon audio cue manifest is missing"
                       }];
        }
        return nil;
    }
    NSMutableDictionary<NSString*, NSURL*>* URLs =
        [NSMutableDictionary dictionary];
    for (NSString* key in cueManifest) {
        NSString* path = cueManifest[key][@"path"];
        if (![path isKindOfClass:[NSString class]]) {
            continue;
        }
        NSURL* URL = [roomPackURL URLByAppendingPathComponent:path];
        if (![[NSFileManager defaultManager] fileExistsAtPath:URL.path]) {
            if (error) {
                *error = [NSError
                    errorWithDomain:@"house.machine.ProtectorNative.Audio"
                               code:2
                           userInfo:@{
                               NSLocalizedDescriptionKey :
                                   [NSString stringWithFormat:
                                       @"Bundled Canyon audio is missing: %@", path]
                           }];
            }
            return nil;
        }
        URLs[key] = URL;
    }
    self.cueURLs = URLs;
    self.effects = [NSMutableArray array];
    self.outputGain = 1.0f;
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    self.musicEnabled = [defaults boolForKey:@"ProtectorMusicEnabled"];
    self.effectsEnabled = [defaults boolForKey:@"ProtectorEffectsEnabled"];
    self.dialogueEnabled = [defaults boolForKey:@"ProtectorDialogueEnabled"];
    AVAudioSession* session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategorySoloAmbient
                         mode:AVAudioSessionModeDefault
                      options:0
                        error:error] ||
        ![session setActive:YES error:error]) {
        return nil;
    }
    return self;
}

- (AVAudioPlayer*)playerForCue:(NSString*)cue error:(NSError**)error {
    NSURL* URL = self.cueURLs[cue];
    if (!URL) {
        return nil;
    }
    AVAudioPlayer* player =
        [[AVAudioPlayer alloc] initWithContentsOfURL:URL error:error];
    player.delegate = self;
    [player prepareToPlay];
    return player;
}

- (void)playEffect:(NSString*)cue volume:(float)volume {
    if (!self.effectsEnabled) {
        return;
    }
    NSError* error = nil;
    AVAudioPlayer* player = [self playerForCue:cue error:&error];
    if (!player) {
        return;
    }
    player.volume = volume * self.outputGain;
    [self.effects filterUsingPredicate:
        [NSPredicate predicateWithBlock:
            ^BOOL(AVAudioPlayer* candidate, NSDictionary* bindings) {
                (void)bindings;
                return candidate.isPlaying;
            }]];
    [self.effects addObject:player];
    [player play];
}

- (void)startMusic {
    if (!self.musicEnabled) {
        [self.music stop];
        return;
    }
    if (!self.music) {
        NSError* error = nil;
        self.music = [self playerForCue:@"music" error:&error];
        self.music.numberOfLoops = -1;
        self.music.volume = 0.17f * self.outputGain;
    }
    [self.music play];
}

- (void)playDialogue:(NSString*)cue {
    if (!self.dialogueEnabled) {
        return;
    }
    NSError* error = nil;
    self.dialogue = [self playerForCue:cue error:&error];
    self.dialogue.volume = 0.88f * self.outputGain;
    [self.dialogue play];
}

- (void)setMusicEnabledAndPersist:(BOOL)enabled {
    self.musicEnabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled
                                          forKey:@"ProtectorMusicEnabled"];
    if (!enabled) {
        [self.music stop];
    }
}

- (void)setEffectsEnabledAndPersist:(BOOL)enabled {
    self.effectsEnabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled
                                          forKey:@"ProtectorEffectsEnabled"];
    if (!enabled) {
        for (AVAudioPlayer* player in self.effects) {
            [player stop];
        }
        [self.effects removeAllObjects];
    }
}

- (void)setDialogueEnabledAndPersist:(BOOL)enabled {
    self.dialogueEnabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled
                                          forKey:@"ProtectorDialogueEnabled"];
    if (!enabled) {
        [self.dialogue stop];
    }
}

- (void)playRoomCue:(ProtectorAudioCue)cue
               form:(ProtectorPlayerForm)form {
    switch (cue) {
    case PROTECTOR_AUDIO_NONE:
        break;
    case PROTECTOR_AUDIO_MUSIC_START:
        [self startMusic];
        break;
    case PROTECTOR_AUDIO_JUMP:
        [self
            playEffect:
                form == PROTECTOR_FORM_FOUR_ARMS
                    ? @"jump_four_arms"
                    : @"jump_ben"
               volume:0.75f];
        break;
    case PROTECTOR_AUDIO_ATTACK:
        [self
            playEffect:
                form == PROTECTOR_FORM_FOUR_ARMS
                    ? @"attack_four_arms"
                    : @"attack_ben"
               volume:0.72f];
        break;
    case PROTECTOR_AUDIO_TRANSFORM:
        [self playEffect:@"transform" volume:0.95f];
        break;
    case PROTECTOR_AUDIO_ENEMY_HIT:
        [self playEffect:@"enemy_hit" volume:0.82f];
        break;
    case PROTECTOR_AUDIO_ENEMY_DEFEATED:
        [self playEffect:@"enemy_defeated" volume:0.92f];
        break;
    case PROTECTOR_AUDIO_PAUSE:
        [self playEffect:@"pause" volume:0.85f];
        [self.music pause];
        [self.dialogue pause];
        break;
    case PROTECTOR_AUDIO_RESUME:
        [self startMusic];
        if (self.dialogueEnabled) {
            [self.dialogue play];
        }
        [self playEffect:@"pause" volume:0.72f];
        break;
    case PROTECTOR_AUDIO_SAVE:
        [self playEffect:@"save" volume:0.82f];
        break;
    case PROTECTOR_AUDIO_ROOM_COMPLETE:
        [self playEffect:@"save" volume:1.0f];
        break;
    case PROTECTOR_AUDIO_ENCOUNTER_START:
        [self playEffect:@"enemy_enter" volume:0.88f];
        [self playDialogue:@"dialogue_intro"];
        break;
    case PROTECTOR_AUDIO_ENEMY_ATTACK:
        [self playEffect:@"enemy_attack" volume:0.76f];
        break;
    case PROTECTOR_AUDIO_PLAYER_HURT:
        [self playEffect:@"player_hurt" volume:0.78f];
        break;
    }
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer*)player
                       successfully:(BOOL)flag {
    (void)flag;
    [self.effects removeObject:player];
}

@end

@interface ProtectorHaptics : NSObject
@property(nonatomic, strong) CHHapticEngine* engine;
@property(nonatomic) BOOL supportsHaptics;
@property(nonatomic) uint32_t requestedCount;
@property(nonatomic) uint32_t playedCount;
- (void)playNamed:(NSString*)name;
- (void)stop;
@end

@implementation ProtectorHaptics

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    self.supportsHaptics =
        CHHapticEngine.capabilitiesForHardware.supportsHaptics;
    if (!self.supportsHaptics) {
        return self;
    }
    NSError* error = nil;
    self.engine = [[CHHapticEngine alloc] initAndReturnError:&error];
    if (!self.engine || error) {
        self.supportsHaptics = NO;
        self.engine = nil;
        return self;
    }
    __weak ProtectorHaptics* weakSelf = self;
    self.engine.resetHandler = ^{
        NSError* startError = nil;
        if (![weakSelf.engine startAndReturnError:&startError]) {
            weakSelf.supportsHaptics = NO;
        }
    };
    self.engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        (void)reason;
    };
    return self;
}

- (void)playNamed:(NSString*)name {
    self.requestedCount++;
    if (!self.supportsHaptics || !self.engine) {
        return;
    }
    float intensity = 0.55f;
    float sharpness = 0.50f;
    NSArray<NSNumber*>* times = @[@0.0];
    if ([name isEqualToString:@"transform"]) {
        intensity = 0.92f;
        sharpness = 0.42f;
        times = @[@0.0, @0.075, @0.15];
    } else if ([name isEqualToString:@"heavy_attack"]) {
        intensity = 1.0f;
        sharpness = 0.72f;
    } else if ([name isEqualToString:@"damage"]) {
        intensity = 0.82f;
        sharpness = 0.90f;
    } else if ([name isEqualToString:@"low_energy"]) {
        intensity = 0.42f;
        sharpness = 0.25f;
        times = @[@0.0, @0.12];
    }
    NSMutableArray<CHHapticEvent*>* events = [NSMutableArray array];
    for (NSNumber* time in times) {
        NSArray<CHHapticEventParameter*>* parameters = @[
            [[CHHapticEventParameter alloc]
                initWithParameterID:CHHapticEventParameterIDHapticIntensity
                             value:intensity],
            [[CHHapticEventParameter alloc]
                initWithParameterID:CHHapticEventParameterIDHapticSharpness
                             value:sharpness],
        ];
        [events addObject:[[CHHapticEvent alloc]
            initWithEventType:CHHapticEventTypeHapticTransient
                   parameters:parameters
                 relativeTime:time.doubleValue]];
    }
    NSError* error = nil;
    if (![self.engine startAndReturnError:&error]) {
        return;
    }
    CHHapticPattern* pattern =
        [[CHHapticPattern alloc] initWithEvents:events
                                    parameters:@[]
                                         error:&error];
    id<CHHapticPatternPlayer> player =
        pattern ? [self.engine createPlayerWithPattern:pattern error:&error] : nil;
    if (player && [player startAtTime:CHHapticTimeImmediate error:&error]) {
        self.playedCount++;
    }
}

- (void)stop {
    [self.engine stopWithCompletionHandler:nil];
}

@end

@interface ProtectorMovePad : UIView
@property(nonatomic, copy) void (^movementChanged)(float x, float z);
@property(nonatomic, strong) UIView* knob;
@property(nonatomic, strong) NSArray<UIButton*>* directionButtons;
@end

@implementation ProtectorMovePad

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (!self) {
        return nil;
    }
    self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.38];
    self.layer.cornerRadius = 72.0;
    self.layer.borderColor =
        [UIColor colorWithRed:0.30 green:0.95 blue:0.45 alpha:0.65].CGColor;
    self.layer.borderWidth = 2.0;
    _knob = [[UIView alloc] initWithFrame:CGRectZero];
    _knob.backgroundColor =
        [UIColor colorWithRed:0.30 green:0.95 blue:0.45 alpha:0.70];
    _knob.layer.cornerRadius = 28.0;
    _knob.userInteractionEnabled = NO;
    [self addSubview:_knob];
    UIPanGestureRecognizer* pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(panned:)];
    pan.cancelsTouchesInView = NO;
    [self addGestureRecognizer:pan];
    UITapGestureRecognizer* tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(tapped:)];
    tap.cancelsTouchesInView = NO;
    [self addGestureRecognizer:tap];
    NSMutableArray<UIButton*>* directions = [NSMutableArray array];
    NSArray<NSString*>* labels = @[@"FORWARD", @"RIGHT", @"BACK", @"LEFT"];
    NSArray<NSString*>* glyphs = @[@"▲", @"▶", @"▼", @"◀"];
    for (NSInteger index = 0; index < 4; ++index) {
        UIButton* direction = [UIButton buttonWithType:UIButtonTypeSystem];
        [direction setTitle:glyphs[index] forState:UIControlStateNormal];
        [direction setTitleColor:
            [UIColor colorWithWhite:1.0 alpha:0.66]
                          forState:UIControlStateNormal];
        direction.titleLabel.font =
            [UIFont systemFontOfSize:13.0 weight:UIFontWeightBlack];
        direction.tag = index;
        direction.accessibilityLabel =
            [NSString stringWithFormat:@"Move %@", labels[index].lowercaseString];
        direction.accessibilityIdentifier =
            [NSString stringWithFormat:
                @"room.move.%@",
                labels[index].lowercaseString];
        [direction addTarget:self
                      action:@selector(directionPressed:)
            forControlEvents:UIControlEventTouchDown];
        [direction addTarget:self
                      action:@selector(directionReleased:)
            forControlEvents:
                UIControlEventTouchUpInside |
                UIControlEventTouchUpOutside |
                UIControlEventTouchCancel];
        [direction addTarget:self
                      action:@selector(directionReleased:)
            forControlEvents:UIControlEventPrimaryActionTriggered];
        [self addSubview:direction];
        [directions addObject:direction];
    }
    self.directionButtons = directions;
    self.isAccessibilityElement = NO;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (CGPointEqualToPoint(self.knob.center, CGPointZero)) {
        self.knob.bounds = CGRectMake(0, 0, 56, 56);
        self.knob.center =
            CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    }
    const CGPoint center =
        CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    const CGPoint centers[] = {
        {center.x, center.y - 54.0},
        {center.x + 54.0, center.y},
        {center.x, center.y + 54.0},
        {center.x - 54.0, center.y},
    };
    for (NSUInteger index = 0; index < self.directionButtons.count; ++index) {
        self.directionButtons[index].bounds = CGRectMake(0, 0, 36, 36);
        self.directionButtons[index].center = centers[index];
    }
}

- (void)directionPressed:(UIButton*)sender {
    static const float directions[][2] = {
        {0.0f, 1.0f},
        {1.0f, 0.0f},
        {0.0f, -1.0f},
        {-1.0f, 0.0f},
    };
    if (self.movementChanged && sender.tag >= 0 && sender.tag < 4) {
        self.movementChanged(
            directions[sender.tag][0],
            directions[sender.tag][1]
        );
    }
}

- (void)directionReleased:(UIButton*)sender {
    [self directionPressed:sender];
    __weak ProtectorMovePad* weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.24 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            if (weakSelf.movementChanged) {
                weakSelf.movementChanged(0.0f, 0.0f);
            }
        }
    );
}

- (void)panned:(UIPanGestureRecognizer*)gesture {
    CGPoint point = [gesture locationInView:self];
    CGPoint center =
        CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGFloat x = point.x - center.x;
    CGFloat y = point.y - center.y;
    const CGFloat maximum = 48.0;
    CGFloat length = hypot(x, y);
    if (length > maximum) {
        x *= maximum / length;
        y *= maximum / length;
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        x = 0.0;
        y = 0.0;
    }
    self.knob.center = CGPointMake(center.x + x, center.y + y);
    if (self.movementChanged) {
        self.movementChanged((float)(x / maximum), (float)(-y / maximum));
    }
}

- (void)tapped:(UITapGestureRecognizer*)gesture {
    CGPoint point = [gesture locationInView:self];
    CGPoint center =
        CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    float x = (float)((point.x - center.x) / 48.0);
    float z = (float)(-(point.y - center.y) / 48.0);
    const float length = hypotf(x, z);
    if (length > 1.0f) {
        x /= length;
        z /= length;
    }
    if (length < 0.15f) {
        z = 1.0f;
    }
    if (self.movementChanged) {
        self.movementChanged(x, z);
    }
    self.knob.center = CGPointMake(
        center.x + x * 48.0f,
        center.y - z * 48.0f
    );
    __weak ProtectorMovePad* weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.24 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            ProtectorMovePad* strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            strongSelf.knob.center = center;
            if (strongSelf.movementChanged) {
                strongSelf.movementChanged(0.0f, 0.0f);
            }
        }
    );
}

- (BOOL)accessibilityActivate {
    if (self.movementChanged) {
        self.movementChanged(0.0f, 1.0f);
    }
    __weak ProtectorMovePad* weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.24 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            if (weakSelf.movementChanged) {
                weakSelf.movementChanged(0.0f, 0.0f);
            }
        }
    );
    return YES;
}

@end

@interface ProtectorRoomViewController : UIViewController <MTKViewDelegate>
@property(nonatomic, strong) ProtectorMetalRenderer* renderer;
@property(nonatomic, strong) MTKView* metalView;
@property(nonatomic, strong) UILabel* diagnostics;
@property(nonatomic, strong) UIButton* saveResumeButton;
@property(nonatomic, strong) UIProgressView* healthBar;
@property(nonatomic, strong) UIProgressView* omnitrixBar;
@property(nonatomic, strong) UILabel* missionLabel;
@property(nonatomic, strong) UIStackView* settingsPanel;
@property(nonatomic, strong) UISwitch* musicSwitch;
@property(nonatomic, strong) UISwitch* effectsSwitch;
@property(nonatomic, strong) NSArray<UIView*>* touchControls;
@property(nonatomic, strong) ProtectorHaptics* haptics;
@property(nonatomic, strong) NSData* collisionData;
@property(nonatomic, strong) NSData* barrierData;
@property(nonatomic, strong) NSData* gateBarrierData;
@property(nonatomic, strong) ProtectorAudioSystem* audio;
@property(nonatomic, strong) NSDictionary* roomManifest;
@property(nonatomic) ProtectorRoom room;
@property(nonatomic) ProtectorRoomDefinition definition;
@property(nonatomic) ProtectorRoomInput touchInput;
@property(nonatomic) uint32_t pendingPressed;
@property(nonatomic) CFTimeInterval previousFrameTime;
@property(nonatomic) double accumulator;
@property(nonatomic) BOOL controllerA;
@property(nonatomic) BOOL controllerB;
@property(nonatomic) BOOL controllerX;
@property(nonatomic) BOOL controllerY;
@property(nonatomic) BOOL controllerMenu;
@property(nonatomic) uint32_t lastAudioSerial;
@property(nonatomic) ProtectorPlayerForm renderedForm;
@property(nonatomic) uint64_t transformationEffectUntilTick;
@property(nonatomic) BOOL autoplayEnabled;
@property(nonatomic) BOOL soakEnabled;
@property(nonatomic) BOOL playthroughProofWritten;
@property(nonatomic) BOOL soakProofWritten;
@property(nonatomic) CFTimeInterval soakStartTime;
@property(nonatomic) uint64_t soakStartFrameCount;
@property(nonatomic) uint32_t soakStartTransitionCount;
@property(nonatomic) uint64_t soakStartMemoryBytes;
@property(nonatomic) uint64_t soakMinimumMemoryBytes;
@property(nonatomic) uint64_t soakMaximumMemoryBytes;
@property(nonatomic) float droneRunCycleSeconds;
@property(nonatomic) float droneIdleCycleSeconds;
@property(nonatomic) BOOL sourceCameraActive;
@property(nonatomic) uint32_t sourceCameraSegment;
@property(nonatomic) BOOL deviceProofEnabled;
@property(nonatomic) BOOL touchGuidanceEnabled;
@property(nonatomic) BOOL roomRestoredOnLaunch;
@property(nonatomic) BOOL pausedForInterruption;
@property(nonatomic) BOOL controlsWithinSafeArea;
@property(nonatomic) BOOL touchOverlayHiddenForController;
@property(nonatomic) UIEdgeInsets latestSafeAreaInsets;
@property(nonatomic) NSUInteger layoutPassCount;
@property(nonatomic) uint32_t touchInputEventCount;
@property(nonatomic) uint32_t controllerInputEventCount;
@property(nonatomic) uint32_t controllerConnectionCount;
@property(nonatomic) uint32_t controllerDisconnectionCount;
@property(nonatomic) uint32_t controllerOverlayHiddenCount;
@property(nonatomic) uint32_t willResignActiveCount;
@property(nonatomic) uint32_t didEnterBackgroundCount;
@property(nonatomic) uint32_t willEnterForegroundCount;
@property(nonatomic) uint32_t didBecomeActiveCount;
@property(nonatomic) uint32_t audioInterruptionBeginCount;
@property(nonatomic) uint32_t audioInterruptionEndCount;
@property(nonatomic) uint32_t backgroundSaveCount;
@property(nonatomic) uint32_t memoryWarningCount;
@property(nonatomic) uint32_t thermalSampleCount;
@property(nonatomic) uint32_t seriousThermalSampleCount;
@property(nonatomic) NSProcessInfoThermalState worstThermalState;
@property(nonatomic) uint64_t deviceProofStartMemoryBytes;
@property(nonatomic) uint64_t deviceProofMaximumMemoryBytes;
@property(nonatomic) CFTimeInterval deviceProofStartTime;
@property(nonatomic) float previousPlayerHealth;
@property(nonatomic) float previousTransformEnergy;
@property(nonatomic) CFTimeInterval lastDeviceProofWriteTime;
@property(nonatomic, copy) NSString* connectedControllerName;
- (NSString*)savePath;
- (BOOL)writeProof:(NSDictionary*)proof filename:(NSString*)filename;
- (void)writeDeviceProofIfNeeded:(BOOL)force;
- (void)updateControllerPresentation;
- (void)pauseForSystemEvent;
- (NSDictionary*)touchGuidance;
@end

@implementation ProtectorRoomViewController

- (void)showFailure:(NSString*)message {
    self.view = [[UIView alloc] initWithFrame:CGRectZero];
    self.view.backgroundColor =
        [UIColor colorWithRed:0.025 green:0.035 blue:0.055 alpha:1.0];
    UILabel* label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = message;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont monospacedSystemFontOfSize:14.0
                                             weight:UIFontWeightMedium];
    [self.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [label.widthAnchor constraintLessThanOrEqualToAnchor:
            self.view.widthAnchor multiplier:0.8],
    ]];
}

- (UIButton*)actionButton:(NSString*)title
                   action:(ProtectorAction)action
                    color:(UIColor*)color {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font =
        [UIFont systemFontOfSize:12.0 weight:UIFontWeightHeavy];
    button.backgroundColor = [color colorWithAlphaComponent:0.72];
    button.layer.cornerRadius = 31.0;
    button.tag = (NSInteger)action;
    button.accessibilityIdentifier =
        [NSString stringWithFormat:@"room.action.%@", title.lowercaseString];
    [button addTarget:self
               action:@selector(actionPressed:)
     forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:62.0],
        [button.heightAnchor constraintEqualToConstant:62.0],
    ]];
    return button;
}

- (void)loadView {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        [self showFailure:@"This device has no Metal implementation"];
        return;
    }
    NSURL* roomPackURL =
        [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Canyon"
                                                         isDirectory:YES];
    NSError* error = nil;
    NSData* collisionData = nil;
    NSData* barrierData = nil;
    NSData* gateBarrierData = nil;
    if (!LoadRoomDefinition(
            roomPackURL,
            &_definition,
            &collisionData,
            &barrierData,
            &gateBarrierData,
            &error
        )) {
        [self showFailure:[NSString stringWithFormat:
            @"Room-pack load failed\n%@", error.localizedDescription]];
        return;
    }
    self.collisionData = collisionData;
    self.barrierData = barrierData;
    self.gateBarrierData = gateBarrierData;
    if (!protector_room_init(&_room, &_definition)) {
        [self showFailure:@"Native Canyon room initialization failed"];
        return;
    }
    NSData* manifestData = [NSData
        dataWithContentsOfURL:
            [roomPackURL URLByAppendingPathComponent:@"room.json"]
                     options:0
                       error:&error];
    NSDictionary* roomManifest = manifestData
        ? [NSJSONSerialization JSONObjectWithData:manifestData
                                          options:0
                                            error:&error]
        : nil;
    self.roomManifest = roomManifest;
    self.droneRunCycleSeconds = 0.7894737f;
    self.droneIdleCycleSeconds = 2.1428571f;
    for (NSDictionary* clip in
         roomManifest[@"assets"][@"animation"][@"selected_clips"]) {
        if ([clip[@"name"] isEqualToString:@"run_f"]) {
            self.droneRunCycleSeconds = [clip[@"duration_seconds"] floatValue];
        } else if ([clip[@"name"] isEqualToString:@"idle_combat"]) {
            self.droneIdleCycleSeconds =
                [clip[@"duration_seconds"] floatValue];
        }
    }
    NSArray<NSString*>* arguments = NSProcessInfo.processInfo.arguments;
    self.soakEnabled = [arguments containsObject:@"--m5-soak-proof"];
    self.deviceProofEnabled =
        IsPhysicalIOSDevice() ||
        [arguments containsObject:@"--m6-device-proof"] ||
        [arguments containsObject:@"--m6-device-autoplay-proof"];
    self.touchGuidanceEnabled =
        IsPhysicalIOSDevice() ||
        [arguments containsObject:@"--m6-touch-mirroring-proof"];
    self.autoplayEnabled =
        self.soakEnabled ||
        [arguments containsObject:@"--m5-autoplay-proof"] ||
        [arguments containsObject:@"--m6-device-autoplay-proof"];
    if ([arguments containsObject:@"--m6-reset-progress"]) {
        (void)[[NSFileManager defaultManager]
            removeItemAtPath:self.savePath
                       error:nil];
    }
    if (self.deviceProofEnabled && !self.autoplayEnabled &&
        [[NSFileManager defaultManager] fileExistsAtPath:self.savePath]) {
        char loadError[256] = {0};
        self.roomRestoredOnLaunch =
            protector_room_load(
                &_room,
                &_definition,
                self.savePath.UTF8String,
                loadError,
                sizeof(loadError)
            ) == PROTECTOR_SAVE_OK;
        if (self.roomRestoredOnLaunch) {
            NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
            NSInteger total =
                [defaults integerForKey:@"ProtectorM6RestoreTotal"];
            [defaults setInteger:total + 1
                          forKey:@"ProtectorM6RestoreTotal"];
        }
    }
    self.audio = roomManifest
        ? [[ProtectorAudioSystem alloc] initWithRoomPack:roomPackURL
                                                manifest:roomManifest
                                                   error:&error]
        : nil;
    if (!self.audio) {
        [self showFailure:[NSString stringWithFormat:
            @"Audio initialization failed\n%@", error.localizedDescription]];
        return;
    }
    self.audio.outputGain = self.soakEnabled ? 0.08f : 1.0f;
    self.haptics = [[ProtectorHaptics alloc] init];
    self.deviceProofStartTime = CACurrentMediaTime();
    self.deviceProofStartMemoryBytes = ResidentMemoryBytes();
    self.deviceProofMaximumMemoryBytes = self.deviceProofStartMemoryBytes;
    self.worstThermalState = NSProcessInfo.processInfo.thermalState;
    self.previousPlayerHealth = self.room.player.health;
    self.previousTransformEnergy = self.room.player.transform_energy;
    NSURL* staticSceneURL =
        [roomPackURL URLByAppendingPathComponent:@"StaticScene"
                                     isDirectory:YES];
    self.renderer =
        [[ProtectorMetalRenderer alloc] initWithDevice:device
                                          scenePackURL:staticSceneURL
                                                 error:&error];
    if (!self.renderer) {
        [self showFailure:[NSString stringWithFormat:
            @"Metal scene load failed\n%@", error.localizedDescription]];
        return;
    }
    [self.renderer
        setGameplayVerticalFovDegrees:
            PROTECTOR_ROOM_REFERENCE_VERTICAL_FOV_DEGREES];

    UIView* root = [[UIView alloc] initWithFrame:CGRectZero];
    root.backgroundColor = UIColor.blackColor;
    self.metalView = [[MTKView alloc] initWithFrame:CGRectZero device:device];
    self.metalView.translatesAutoresizingMaskIntoConstraints = NO;
    self.metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    self.metalView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    self.metalView.framebufferOnly = YES;
    self.metalView.autoResizeDrawable = NO;
    self.metalView.drawableSize =
        CGSizeMake(self.renderer.width, self.renderer.height);
    self.metalView.preferredFramesPerSecond = PROTECTOR_ROOM_TICK_RATE;
    self.metalView.delegate = self;
    [root addSubview:self.metalView];
    [NSLayoutConstraint activateConstraints:@[
        [self.metalView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.metalView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.metalView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [self.metalView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    ProtectorMovePad* movePad = [[ProtectorMovePad alloc] init];
    movePad.translatesAutoresizingMaskIntoConstraints = NO;
    __weak ProtectorRoomViewController* weakSelf = self;
    movePad.movementChanged = ^(float x, float z) {
        ProtectorRoomInput input = weakSelf.touchInput;
        input.move_x = x;
        input.move_z = z;
        weakSelf.touchInput = input;
        if (fabsf(x) + fabsf(z) > 0.05f) {
            weakSelf.touchInputEventCount++;
        }
    };
    [root addSubview:movePad];

    UIButton* attack = [self actionButton:@"ATTACK"
                                   action:PROTECTOR_ACTION_ATTACK_LIGHT
                                    color:[UIColor systemRedColor]];
    UIButton* jump = [self actionButton:@"JUMP"
                                 action:PROTECTOR_ACTION_JUMP
                                  color:[UIColor systemBlueColor]];
    UIButton* transform = [self actionButton:@"OMNITRIX"
                                      action:PROTECTOR_ACTION_TRANSFORM
                                       color:[UIColor systemGreenColor]];
    UIButton* pause = [self actionButton:@"PAUSE"
                                  action:PROTECTOR_ACTION_PAUSE
                                   color:[UIColor systemGrayColor]];
    UILongPressGestureRecognizer* heavyAttack =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(heavyAttackPressed:)];
    heavyAttack.minimumPressDuration = 0.32;
    heavyAttack.cancelsTouchesInView = YES;
    [attack addGestureRecognizer:heavyAttack];
    [root addSubview:attack];
    [root addSubview:jump];
    [root addSubview:transform];
    [root addSubview:pause];
    self.touchControls = @[movePad, attack, jump, transform, pause];

    self.diagnostics = [[UILabel alloc] init];
    self.diagnostics.translatesAutoresizingMaskIntoConstraints = NO;
    self.diagnostics.numberOfLines = 0;
    self.diagnostics.textColor = UIColor.whiteColor;
    self.diagnostics.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.48];
    self.diagnostics.font = [UIFont monospacedSystemFontOfSize:10.5
                                                       weight:UIFontWeightMedium];
    self.diagnostics.layer.cornerRadius = 7.0;
    self.diagnostics.layer.masksToBounds = YES;
    [root addSubview:self.diagnostics];

    self.missionLabel = [[UILabel alloc] init];
    self.missionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.missionLabel.textColor = UIColor.whiteColor;
    self.missionLabel.backgroundColor =
        [UIColor colorWithWhite:0.02 alpha:0.62];
    self.missionLabel.font =
        [UIFont systemFontOfSize:13.0 weight:UIFontWeightBlack];
    self.missionLabel.textAlignment = NSTextAlignmentCenter;
    self.missionLabel.layer.cornerRadius = 10.0;
    self.missionLabel.layer.masksToBounds = YES;
    [root addSubview:self.missionLabel];

    self.healthBar =
        [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.healthBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.healthBar.progressTintColor = UIColor.systemGreenColor;
    self.healthBar.trackTintColor =
        [UIColor colorWithWhite:0.08 alpha:0.78];
    self.healthBar.layer.cornerRadius = 4.0;
    self.healthBar.layer.masksToBounds = YES;
    [root addSubview:self.healthBar];

    self.omnitrixBar =
        [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.omnitrixBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.omnitrixBar.progressTintColor =
        [UIColor colorWithRed:0.20 green:1.0 blue:0.42 alpha:1.0];
    self.omnitrixBar.trackTintColor =
        [UIColor colorWithWhite:0.08 alpha:0.78];
    self.omnitrixBar.layer.cornerRadius = 4.0;
    self.omnitrixBar.layer.masksToBounds = YES;
    [root addSubview:self.omnitrixBar];

    self.saveResumeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.saveResumeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.saveResumeButton setTitle:@"SAVE + RESUME"
                           forState:UIControlStateNormal];
    [self.saveResumeButton setTitleColor:UIColor.whiteColor
                                forState:UIControlStateNormal];
    self.saveResumeButton.titleLabel.font =
        [UIFont systemFontOfSize:18.0 weight:UIFontWeightBlack];
    self.saveResumeButton.backgroundColor =
        [UIColor colorWithRed:0.05 green:0.55 blue:0.20 alpha:0.92];
    self.saveResumeButton.layer.cornerRadius = 12.0;
    self.saveResumeButton.accessibilityIdentifier = @"room.save_resume";
    self.saveResumeButton.hidden = YES;
    [self.saveResumeButton addTarget:self
                              action:@selector(saveAndResume)
                    forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:self.saveResumeButton];

    UILabel* musicLabel = [[UILabel alloc] init];
    musicLabel.text = @"MUSIC";
    musicLabel.textColor = UIColor.whiteColor;
    musicLabel.font = [UIFont systemFontOfSize:12.0
                                       weight:UIFontWeightBold];
    self.musicSwitch = [[UISwitch alloc] init];
    self.musicSwitch.accessibilityLabel = @"Music";
    self.musicSwitch.accessibilityIdentifier = @"room.setting.music";
    self.musicSwitch.on =
        [NSUserDefaults.standardUserDefaults boolForKey:@"ProtectorMusicEnabled"];
    [self.musicSwitch addTarget:self
                         action:@selector(musicSettingChanged:)
               forControlEvents:UIControlEventValueChanged];
    UIStackView* musicRow =
        [[UIStackView alloc] initWithArrangedSubviews:@[
            musicLabel,
            self.musicSwitch,
        ]];
    musicRow.axis = UILayoutConstraintAxisHorizontal;
    musicRow.distribution = UIStackViewDistributionEqualSpacing;

    UILabel* effectsLabel = [[UILabel alloc] init];
    effectsLabel.text = @"EFFECTS + VO";
    effectsLabel.textColor = UIColor.whiteColor;
    effectsLabel.font = [UIFont systemFontOfSize:12.0
                                         weight:UIFontWeightBold];
    self.effectsSwitch = [[UISwitch alloc] init];
    self.effectsSwitch.accessibilityLabel = @"Effects and dialogue";
    self.effectsSwitch.accessibilityIdentifier = @"room.setting.effects";
    self.effectsSwitch.on =
        [NSUserDefaults.standardUserDefaults boolForKey:@"ProtectorEffectsEnabled"];
    [self.effectsSwitch addTarget:self
                           action:@selector(effectsSettingChanged:)
                 forControlEvents:UIControlEventValueChanged];
    UIStackView* effectsRow =
        [[UIStackView alloc] initWithArrangedSubviews:@[
            effectsLabel,
            self.effectsSwitch,
        ]];
    effectsRow.axis = UILayoutConstraintAxisHorizontal;
    effectsRow.distribution = UIStackViewDistributionEqualSpacing;

    self.settingsPanel =
        [[UIStackView alloc] initWithArrangedSubviews:@[musicRow, effectsRow]];
    self.settingsPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.settingsPanel.axis = UILayoutConstraintAxisVertical;
    self.settingsPanel.spacing = 5.0;
    self.settingsPanel.layoutMargins =
        UIEdgeInsetsMake(8.0, 12.0, 8.0, 12.0);
    self.settingsPanel.layoutMarginsRelativeArrangement = YES;
    self.settingsPanel.backgroundColor =
        [UIColor colorWithWhite:0.03 alpha:0.86];
    self.settingsPanel.layer.cornerRadius = 10.0;
    self.settingsPanel.hidden = YES;
    [root addSubview:self.settingsPanel];

    [NSLayoutConstraint activateConstraints:@[
        [movePad.leadingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.leadingAnchor
                                             constant:22.0],
        [movePad.bottomAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.bottomAnchor
                                            constant:-18.0],
        [movePad.widthAnchor constraintEqualToConstant:144.0],
        [movePad.heightAnchor constraintEqualToConstant:144.0],
        [attack.trailingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor
                                              constant:-24.0],
        [attack.bottomAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.bottomAnchor
                                            constant:-20.0],
        [jump.trailingAnchor constraintEqualToAnchor:attack.leadingAnchor constant:-16.0],
        [jump.bottomAnchor constraintEqualToAnchor:attack.bottomAnchor constant:-34.0],
        [transform.trailingAnchor constraintEqualToAnchor:attack.trailingAnchor],
        [transform.bottomAnchor constraintEqualToAnchor:attack.topAnchor constant:-14.0],
        [pause.trailingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor
                                             constant:-18.0],
        [pause.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor
                                       constant:14.0],
        [self.diagnostics.leadingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.leadingAnchor
                                                        constant:12.0],
        [self.diagnostics.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor
                                                    constant:10.0],
        [self.missionLabel.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [self.missionLabel.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor
                                                     constant:12.0],
        [self.missionLabel.widthAnchor constraintEqualToConstant:270.0],
        [self.missionLabel.heightAnchor constraintEqualToConstant:32.0],
        [self.healthBar.centerXAnchor constraintEqualToAnchor:self.missionLabel.centerXAnchor],
        [self.healthBar.topAnchor constraintEqualToAnchor:self.missionLabel.bottomAnchor
                                                  constant:5.0],
        [self.healthBar.widthAnchor constraintEqualToConstant:210.0],
        [self.healthBar.heightAnchor constraintEqualToConstant:8.0],
        [self.omnitrixBar.centerXAnchor constraintEqualToAnchor:self.missionLabel.centerXAnchor],
        [self.omnitrixBar.topAnchor constraintEqualToAnchor:self.healthBar.bottomAnchor
                                                    constant:4.0],
        [self.omnitrixBar.widthAnchor constraintEqualToConstant:210.0],
        [self.omnitrixBar.heightAnchor constraintEqualToConstant:6.0],
        [self.saveResumeButton.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [self.saveResumeButton.centerYAnchor constraintEqualToAnchor:root.centerYAnchor],
        [self.saveResumeButton.widthAnchor constraintEqualToConstant:220.0],
        [self.saveResumeButton.heightAnchor constraintEqualToConstant:58.0],
        [self.settingsPanel.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [self.settingsPanel.topAnchor constraintEqualToAnchor:self.saveResumeButton.bottomAnchor
                                                     constant:10.0],
        [self.settingsPanel.widthAnchor constraintEqualToConstant:220.0],
    ]];
    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(systemWillResignActive:)
                   name:UIApplicationWillResignActiveNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(systemDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(systemWillEnterForeground:)
                   name:UIApplicationWillEnterForegroundNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(systemDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(audioSessionInterrupted:)
                   name:AVAudioSessionInterruptionNotification
                 object:AVAudioSession.sharedInstance];
    [center addObserver:self
               selector:@selector(thermalStateChanged:)
                   name:NSProcessInfoThermalStateDidChangeNotification
                 object:NSProcessInfo.processInfo];
    [center addObserver:self
               selector:@selector(memoryWarningReceived:)
                   name:UIApplicationDidReceiveMemoryWarningNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(controllerConnected:)
                   name:GCControllerDidConnectNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(controllerDisconnected:)
                   name:GCControllerDidDisconnectNotification
                 object:nil];
    self.thermalSampleCount = 1;
    [self updateControllerPresentation];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.haptics stop];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.layoutPassCount++;
    self.latestSafeAreaInsets = self.view.safeAreaInsets;
    CGRect safeFrame = CGRectInset(
        self.view.safeAreaLayoutGuide.layoutFrame,
        -0.5,
        -0.5
    );
    BOOL controlsWithinSafeArea = !CGRectIsEmpty(safeFrame);
    for (UIView* control in self.touchControls) {
        if (!control.hidden &&
            !CGRectContainsRect(safeFrame, control.frame)) {
            controlsWithinSafeArea = NO;
            break;
        }
    }
    self.controlsWithinSafeArea = controlsWithinSafeArea;
    [self writeDeviceProofIfNeeded:YES];
}

- (void)pauseForSystemEvent {
    if (self.room.state != PROTECTOR_ROOM_RUNNING) {
        return;
    }
    ProtectorRoomInput input = {0};
    input.pressed = PROTECTOR_ACTION_PAUSE;
    protector_room_step(&_room, &_definition, input);
}

- (void)systemWillResignActive:(NSNotification*)notification {
    (void)notification;
    self.willResignActiveCount++;
    [self pauseForSystemEvent];
    [self writeDeviceProofIfNeeded:YES];
}

- (void)systemDidEnterBackground:(NSNotification*)notification {
    (void)notification;
    self.didEnterBackgroundCount++;
    self.metalView.paused = YES;
    [self.audio.music pause];
    [self.audio.dialogue pause];
    [self.haptics stop];
    char error[256] = {0};
    if (protector_room_save(
            &_room,
            self.savePath.UTF8String,
            error,
            sizeof(error)
        ) == PROTECTOR_SAVE_OK) {
        self.backgroundSaveCount++;
        NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
        NSInteger total =
            [defaults integerForKey:@"ProtectorM6BackgroundSaveTotal"];
        [defaults setInteger:total + 1
                      forKey:@"ProtectorM6BackgroundSaveTotal"];
    }
    [self writeDeviceProofIfNeeded:YES];
}

- (void)systemWillEnterForeground:(NSNotification*)notification {
    (void)notification;
    self.willEnterForegroundCount++;
    self.previousFrameTime = 0.0;
    self.accumulator = 0.0;
    [self writeDeviceProofIfNeeded:YES];
}

- (void)systemDidBecomeActive:(NSNotification*)notification {
    (void)notification;
    self.didBecomeActiveCount++;
    NSError* error = nil;
    (void)[AVAudioSession.sharedInstance setActive:YES error:&error];
    self.metalView.paused = NO;
    self.previousFrameTime = 0.0;
    [self writeDeviceProofIfNeeded:YES];
}

- (void)audioSessionInterrupted:(NSNotification*)notification {
    NSNumber* typeValue =
        notification.userInfo[AVAudioSessionInterruptionTypeKey];
    AVAudioSessionInterruptionType type =
        (AVAudioSessionInterruptionType)typeValue.unsignedIntegerValue;
    if (type == AVAudioSessionInterruptionTypeBegan) {
        self.audioInterruptionBeginCount++;
        self.pausedForInterruption =
            self.room.state == PROTECTOR_ROOM_RUNNING;
        [self pauseForSystemEvent];
        [self.haptics stop];
    } else {
        self.audioInterruptionEndCount++;
        NSError* error = nil;
        (void)[AVAudioSession.sharedInstance setActive:YES error:&error];
        if (self.pausedForInterruption) {
            (void)protector_room_resume(&_room);
            self.pausedForInterruption = NO;
        }
        self.previousFrameTime = 0.0;
    }
    [self writeDeviceProofIfNeeded:YES];
}

- (void)thermalStateChanged:(NSNotification*)notification {
    (void)notification;
    NSProcessInfoThermalState state = NSProcessInfo.processInfo.thermalState;
    self.thermalSampleCount++;
    if (state > self.worstThermalState) {
        self.worstThermalState = state;
    }
    if (state >= NSProcessInfoThermalStateSerious) {
        self.seriousThermalSampleCount++;
        self.metalView.preferredFramesPerSecond = PROTECTOR_ROOM_TICK_RATE;
    }
    if (state == NSProcessInfoThermalStateCritical) {
        [self.haptics stop];
    }
    [self writeDeviceProofIfNeeded:YES];
}

- (void)memoryWarningReceived:(NSNotification*)notification {
    (void)notification;
    self.memoryWarningCount++;
    for (AVAudioPlayer* player in self.audio.effects) {
        [player stop];
    }
    [self.audio.effects removeAllObjects];
    [self writeDeviceProofIfNeeded:YES];
}

- (void)controllerConnected:(NSNotification*)notification {
    GCController* controller = notification.object;
    self.controllerConnectionCount++;
    self.connectedControllerName =
        controller.vendorName ? controller.vendorName : @"controller";
    [self updateControllerPresentation];
    [self writeDeviceProofIfNeeded:YES];
}

- (void)controllerDisconnected:(NSNotification*)notification {
    (void)notification;
    self.controllerDisconnectionCount++;
    self.connectedControllerName = nil;
    [self updateControllerPresentation];
    [self writeDeviceProofIfNeeded:YES];
}

- (void)updateControllerPresentation {
    GCController* controller = GCController.controllers.firstObject;
    BOOL hide = controller.extendedGamepad != nil;
    if (hide && !self.touchOverlayHiddenForController) {
        self.controllerOverlayHiddenCount++;
    }
    self.touchOverlayHiddenForController = hide;
    self.connectedControllerName =
        hide
        ? (controller.vendorName ? controller.vendorName : @"controller")
        : nil;
    for (UIView* control in self.touchControls) {
        control.hidden = hide;
    }
}

- (void)actionPressed:(UIButton*)sender {
    self.pendingPressed |= (uint32_t)sender.tag;
    self.touchInputEventCount++;
    if ((uint32_t)sender.tag == PROTECTOR_ACTION_TRANSFORM) {
        [self.haptics playNamed:@"transform"];
    }
}

- (void)heavyAttackPressed:(UILongPressGestureRecognizer*)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    self.pendingPressed |= PROTECTOR_ACTION_ATTACK_HEAVY;
    self.touchInputEventCount++;
    [self.haptics playNamed:@"heavy_attack"];
}

- (void)musicSettingChanged:(UISwitch*)sender {
    [self.audio setMusicEnabledAndPersist:sender.isOn];
}

- (void)effectsSettingChanged:(UISwitch*)sender {
    [self.audio setEffectsEnabledAndPersist:sender.isOn];
    [self.audio setDialogueEnabledAndPersist:sender.isOn];
}

- (NSString*)savePath {
    NSURL* directory = [[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory
               inDomains:NSUserDomainMask].firstObject;
    return [[directory URLByAppendingPathComponent:@"canyon-room-v2.save"] path];
}

- (void)saveAndResume {
    if (self.room.state == PROTECTOR_ROOM_COMPLETED ||
        self.room.state == PROTECTOR_ROOM_FAILED) {
        (void)[[NSFileManager defaultManager]
            removeItemAtPath:self.savePath
                       error:nil];
        if (protector_room_init(&_room, &_definition)) {
            self.touchInput = (ProtectorRoomInput){0};
            self.pendingPressed = 0;
            self.lastAudioSerial = 0;
            self.previousPlayerHealth = self.room.player.health;
            self.previousTransformEnergy =
                self.room.player.transform_energy;
            self.roomRestoredOnLaunch = NO;
            self.touchInputEventCount++;
            [self writeDeviceProofIfNeeded:YES];
        }
        return;
    }
    char error[256] = {0};
    ProtectorSaveResult result = protector_room_save(
        &_room,
        self.savePath.UTF8String,
        error,
        sizeof(error)
    );
    if (result == PROTECTOR_SAVE_OK) {
        result = protector_room_load(
            &_room,
            &_definition,
            self.savePath.UTF8String,
            error,
            sizeof(error)
        );
    }
    if (result == PROTECTOR_SAVE_OK && protector_room_resume(&_room)) {
        self.saveResumeButton.hidden = YES;
        return;
    }
    self.diagnostics.text =
        [NSString stringWithFormat:@"SAVE ERROR\n%s", error];
}

- (ProtectorRoomInput)autoplayInput {
    ProtectorRoomInput input = {0};
    if (!self.autoplayEnabled) {
        return input;
    }
    if (self.room.state == PROTECTOR_ROOM_PAUSED) {
        if (!(self.room.achieved_gate_mask & PROTECTOR_GATE_SAVED)) {
            [self saveAndResume];
        } else if (!(self.room.achieved_gate_mask & PROTECTOR_GATE_RESUMED)) {
            (void)protector_room_resume(&_room);
        }
        return input;
    }
    if (self.room.state != PROTECTOR_ROOM_RUNNING) {
        return input;
    }
    if (!(self.room.achieved_gate_mask & PROTECTOR_GATE_JUMPED)) {
        input.pressed |= PROTECTOR_ACTION_JUMP;
    }
    if (!(self.room.achieved_gate_mask & PROTECTOR_GATE_TRANSFORMED)) {
        input.pressed |= PROTECTOR_ACTION_TRANSFORM;
    }
    ProtectorVec3 target = self.definition.encounter_center;
    if (self.room.encounter_started && self.room.living_enemy_count > 0) {
        float bestDistance = INFINITY;
        for (uint32_t index = 0; index < self.room.enemy_count; ++index) {
            const ProtectorEnemyState enemy = self.room.enemies[index];
            if (!enemy.alive) {
                continue;
            }
            const float x = enemy.position.x - self.room.player.position.x;
            const float z = enemy.position.z - self.room.player.position.z;
            const float distance = x * x + z * z;
            if (distance < bestDistance) {
                bestDistance = distance;
                target = enemy.position;
            }
        }
        if (bestDistance <= 2.85f * 2.85f &&
            self.room.player_attack_cooldown_ticks == 0) {
            input.pressed |= PROTECTOR_ACTION_ATTACK_HEAVY;
        }
    } else if (self.room.living_enemy_count == 0) {
        if (!(self.room.achieved_gate_mask & PROTECTOR_GATE_PAUSED)) {
            input.pressed |= PROTECTOR_ACTION_PAUSE;
            return input;
        }
        target = self.definition.exit_center;
    } else if (!(self.room.achieved_gate_mask & PROTECTOR_GATE_ATTACKED)) {
        input.pressed |= PROTECTOR_ACTION_ATTACK_LIGHT;
    }

    float x = target.x - self.room.player.position.x;
    float z = target.z - self.room.player.position.z;
    const float length = hypotf(x, z);
    if (length > 0.15f) {
        input.move_x = x / length;
        input.move_z = z / length;
    }
    return input;
}

- (NSString*)proofPath:(NSString*)filename {
    NSURL* directory = [[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory
               inDomains:NSUserDomainMask].firstObject;
    return [[directory URLByAppendingPathComponent:filename] path];
}

- (BOOL)writeProof:(NSDictionary*)proof filename:(NSString*)filename {
    NSError* error = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:proof
                                                   options:NSJSONWritingPrettyPrinted |
                                                           NSJSONWritingSortedKeys
                                                     error:&error];
    return data &&
        [data writeToFile:[self proofPath:filename]
                  options:NSDataWritingAtomic
                    error:&error];
}

- (NSDictionary*)touchGuidance {
    NSString* action = @"move";
    ProtectorVec3 target = self.definition.encounter_center;
    if (self.room.state == PROTECTOR_ROOM_PAUSED) {
        action = @"save_resume";
        target = self.room.player.position;
    } else if (self.room.state == PROTECTOR_ROOM_COMPLETED) {
        action = @"complete";
        target = self.room.player.position;
    } else if (!(self.room.achieved_gate_mask & PROTECTOR_GATE_JUMPED)) {
        action = @"jump";
    } else if (!(self.room.achieved_gate_mask & PROTECTOR_GATE_TRANSFORMED)) {
        action = @"transform";
    } else if (self.room.encounter_started &&
               self.room.living_enemy_count > 0) {
        float nearestSquared = INFINITY;
        for (uint32_t index = 0; index < self.room.enemy_count; ++index) {
            ProtectorEnemyState enemy = self.room.enemies[index];
            if (!enemy.alive) {
                continue;
            }
            const float x =
                enemy.position.x - self.room.player.position.x;
            const float z =
                enemy.position.z - self.room.player.position.z;
            const float squared = x * x + z * z;
            if (squared < nearestSquared) {
                nearestSquared = squared;
                target = enemy.position;
            }
        }
        if (nearestSquared <= 2.85f * 2.85f &&
            self.room.player_attack_cooldown_ticks == 0) {
            action = @"heavy_attack";
        }
    } else if (self.room.living_enemy_count == 0) {
        if (!(self.room.achieved_gate_mask & PROTECTOR_GATE_PAUSED)) {
            action = @"pause";
            target = self.room.player.position;
        } else {
            target = self.definition.exit_center;
        }
    } else if (!(self.room.achieved_gate_mask & PROTECTOR_GATE_ATTACKED)) {
        action = @"light_attack";
    }
    float x = target.x - self.room.player.position.x;
    float z = target.z - self.room.player.position.z;
    const float distance = hypotf(x, z);
    if (distance > 0.001f) {
        x /= distance;
        z /= distance;
    }
    return @{
        @"enabled" : @(self.touchGuidanceEnabled),
        @"action" : action,
        @"move_x" : @(x),
        @"move_z" : @(z),
        @"distance" : @(distance),
    };
}

- (void)writeDeviceProofIfNeeded:(BOOL)force {
    if (!self.deviceProofEnabled) {
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (!force && now - self.lastDeviceProofWriteTime < 1.0) {
        return;
    }
    self.lastDeviceProofWriteTime = now;
    uint64_t memory = ResidentMemoryBytes();
    self.deviceProofMaximumMemoryBytes =
        MAX(self.deviceProofMaximumMemoryBytes, memory);
    NSProcessInfoThermalState thermal =
        NSProcessInfo.processInfo.thermalState;
    self.thermalSampleCount++;
    if (thermal > self.worstThermalState) {
        self.worstThermalState = thermal;
    }
    if (thermal >= NSProcessInfoThermalStateSerious) {
        self.seriousThermalSampleCount++;
    }
    UIWindowScene* scene = self.view.window.windowScene;
    UIInterfaceOrientation orientation =
        scene
        ? scene.effectiveGeometry.interfaceOrientation
        : UIInterfaceOrientationUnknown;
    UIScreen* screen = scene ? scene.screen : nil;
    CGSize drawable = self.metalView.drawableSize;
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.latestSafeAreaInsets;
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    const double average = self.room.measured_frame_count
        ? (double)self.room.frame_time_total_microseconds /
            (double)self.room.measured_frame_count / 1000.0
        : 0.0;
    NSMutableArray<NSDictionary*>* enemyState =
        [NSMutableArray arrayWithCapacity:self.room.enemy_count];
    for (uint32_t index = 0; index < self.room.enemy_count; ++index) {
        const ProtectorEnemyState enemy = self.room.enemies[index];
        [enemyState addObject:@{
            @"index" : @(index),
            @"position" : @[
                @(enemy.position.x),
                @(enemy.position.y),
                @(enemy.position.z),
            ],
            @"health" : @(enemy.health),
            @"alive" : @(enemy.alive),
            @"active" : @(enemy.active),
            @"attack_windup_ticks" : @(enemy.attack_windup_ticks),
            @"attack_cooldown_ticks" : @(enemy.attack_cooldown_ticks),
        }];
    }
    ProtectorTargetInfo selectedTarget = {0};
    const BOOL hasSelectedTarget =
        protector_room_target_info(&_room, &selectedTarget);
    NSDictionary* proof = @{
        @"schema" : @"protector-native.device-proof/v1",
        @"status" : self.room.state == PROTECTOR_ROOM_COMPLETED
            ? @"completed"
            : @"running",
        @"target" : @{
            @"physical_device" : @(IsPhysicalIOSDevice()),
            @"simulator" :
                [NSNumber numberWithBool:!IsPhysicalIOSDevice()],
            @"architecture" : @"arm64",
            @"jit" : @NO,
            @"streaming" : @NO,
            @"emulator_frontend" : @NO,
            @"device_model" : DeviceModelIdentifier(),
            @"system_name" : UIDevice.currentDevice.systemName,
            @"system_version" : UIDevice.currentDevice.systemVersion,
            @"bundle_identifier" :
                NSBundle.mainBundle.bundleIdentifier
                ? NSBundle.mainBundle.bundleIdentifier
                : @"unknown",
            @"launch_count" :
                @([defaults integerForKey:@"ProtectorM6LaunchCount"]),
        },
        @"render" : @{
            @"drawable_width_pixels" : @(drawable.width),
            @"drawable_height_pixels" : @(drawable.height),
            @"view_width_points" : @(bounds.size.width),
            @"view_height_points" : @(bounds.size.height),
            @"screen_native_width_pixels" :
                @(screen ? screen.nativeBounds.size.width : 0.0),
            @"screen_native_height_pixels" :
                @(screen ? screen.nativeBounds.size.height : 0.0),
            @"screen_native_scale" :
                @(screen ? screen.nativeScale : 0.0),
            @"orientation" : InterfaceOrientationName(orientation),
            @"layout_pass_count" : @(self.layoutPassCount),
            @"safe_area_insets" : @{
                @"top" : @(safe.top),
                @"left" : @(safe.left),
                @"bottom" : @(safe.bottom),
                @"right" : @(safe.right),
            },
            @"controls_within_safe_area" :
                @(self.controlsWithinSafeArea),
        },
        @"input" : @{
            @"touch_event_count" : @(self.touchInputEventCount),
            @"controller_event_count" : @(self.controllerInputEventCount),
            @"controller_connected" :
                @(GCController.controllers.firstObject.extendedGamepad != nil),
            @"controller_name" :
                self.connectedControllerName
                ? self.connectedControllerName
                : @"none",
            @"controller_connection_count" :
                @(self.controllerConnectionCount),
            @"controller_disconnection_count" :
                @(self.controllerDisconnectionCount),
            @"touch_overlay_hidden_for_controller" :
                @(self.touchOverlayHiddenForController),
            @"controller_overlay_hidden_count" :
                @(self.controllerOverlayHiddenCount),
            @"heavy_attack_long_press_seconds" : @0.32,
            @"touch_guidance" : [self touchGuidance],
        },
        @"haptics" : @{
            @"core_haptics_supported" :
                @(self.haptics.supportsHaptics),
            @"requested_count" : @(self.haptics.requestedCount),
            @"played_count" : @(self.haptics.playedCount),
        },
        @"lifecycle" : @{
            @"will_resign_active_count" :
                @(self.willResignActiveCount),
            @"did_enter_background_count" :
                @(self.didEnterBackgroundCount),
            @"will_enter_foreground_count" :
                @(self.willEnterForegroundCount),
            @"did_become_active_count" :
                @(self.didBecomeActiveCount),
            @"audio_interruption_begin_count" :
                @(self.audioInterruptionBeginCount),
            @"audio_interruption_end_count" :
                @(self.audioInterruptionEndCount),
            @"background_save_count" : @(self.backgroundSaveCount),
            @"background_save_total" :
                @([defaults integerForKey:@"ProtectorM6BackgroundSaveTotal"]),
            @"restored_save_on_launch" :
                @(self.roomRestoredOnLaunch),
            @"restore_total" :
                @([defaults integerForKey:@"ProtectorM6RestoreTotal"]),
        },
        @"thermal" : @{
            @"current" : ThermalStateName(thermal),
            @"worst" : ThermalStateName(self.worstThermalState),
            @"elapsed_seconds" :
                @(MAX(0.0, now - self.deviceProofStartTime)),
            @"sample_count" : @(self.thermalSampleCount),
            @"serious_or_critical_sample_count" :
                @(self.seriousThermalSampleCount),
        },
        @"memory" : @{
            @"resident_start_bytes" :
                @(self.deviceProofStartMemoryBytes),
            @"resident_current_bytes" : @(memory),
            @"resident_maximum_bytes" :
                @(self.deviceProofMaximumMemoryBytes),
            @"warning_count" : @(self.memoryWarningCount),
        },
        @"room" : @{
            @"state" :
                [NSString stringWithUTF8String:
                    protector_room_state_name(self.room.state)],
            @"tick_rate" : @(PROTECTOR_ROOM_TICK_RATE),
            @"tick" : @(self.room.tick),
            @"required_gate_mask" : @(self.room.required_gate_mask),
            @"achieved_gate_mask" : @(self.room.achieved_gate_mask),
            @"living_enemy_count" : @(self.room.living_enemy_count),
            @"player_health" : @(self.room.player.health),
            @"player_position" : @[
                @(self.room.player.position.x),
                @(self.room.player.position.y),
                @(self.room.player.position.z),
            ],
            @"player_facing_radians" :
                @(self.room.player.facing_radians),
            @"selected_target" : hasSelectedTarget
                ? @{
                    @"enemy_index" : @(selectedTarget.enemy_index),
                    @"distance" : @(selectedTarget.distance),
                    @"signed_angle_radians" :
                        @(selectedTarget.signed_angle_radians),
                }
                : (id)NSNull.null,
            @"enemies" : enemyState,
            @"save_count" : @(self.room.save_count),
            @"resume_count" : @(self.room.resume_count),
            @"save_file_exists" :
                @([[NSFileManager defaultManager]
                    fileExistsAtPath:self.savePath]),
            @"core_allocation_count" : @(self.room.allocation_count),
            @"barrier_query_count" : @(self.room.barrier_query_count),
            @"barrier_contact_count" : @(self.room.barrier_contact_count),
        },
        @"frame_time" : @{
            @"measured_frame_count" :
                @(self.room.measured_frame_count),
            @"average_milliseconds" : @(average),
            @"maximum_microseconds" :
                @(self.room.frame_time_max_microseconds),
        },
    };
    (void)[self writeProof:proof filename:@"m6-device-proof.json"];
}

- (void)updateProofStateAtTime:(CFTimeInterval)now {
    if (!self.autoplayEnabled ||
        (self.room.state != PROTECTOR_ROOM_COMPLETED &&
         self.room.state != PROTECTOR_ROOM_FAILED)) {
        return;
    }
    if (!self.playthroughProofWritten) {
        const NSDictionary* source = self.roomManifest[@"source"];
        const NSDictionary* assets = self.roomManifest[@"assets"];
        NSDictionary* proof = @{
            @"schema" : @"protector-native.playthrough-proof/v1",
            @"status" : self.room.state == PROTECTOR_ROOM_COMPLETED
                ? @"completed"
                : @"failed",
            @"architecture" : @"arm64",
            @"jit" : @NO,
            @"tick_rate" : @(PROTECTOR_ROOM_TICK_RATE),
            @"tick" : @(self.room.tick),
            @"required_gate_mask" : @(self.room.required_gate_mask),
            @"achieved_gate_mask" : @(self.room.achieved_gate_mask),
            @"living_enemy_count" : @(self.room.living_enemy_count),
            @"state_transition_count" : @(self.room.state_transition_count),
            @"audio_event_count" : @(self.room.audio_event_count),
            @"audio_output_gain" : @(self.audio.outputGain),
            @"collision_query_count" : @(self.room.collision_query_count),
            @"collision_contact_count" : @(self.room.collision_contact_count),
            @"barrier_query_count" : @(self.room.barrier_query_count),
            @"barrier_contact_count" : @(self.room.barrier_contact_count),
            @"save_count" : @(self.room.save_count),
            @"resume_count" : @(self.room.resume_count),
            @"player_health" : @(self.room.player.health),
            @"core_allocation_count" : @(self.room.allocation_count),
            @"measured_frame_count" : @(self.room.measured_frame_count),
            @"frame_time_min_microseconds" :
                @(self.room.frame_time_min_microseconds),
            @"frame_time_max_microseconds" :
                @(self.room.frame_time_max_microseconds),
            @"source" : @{
                @"scene_sha256" : source[@"scene"][@"sha256"],
                @"map_sha256" : source[@"map"][@"sha256"],
                @"walkable_triangle_count" :
                    assets[@"walkable_collision"][@"count"],
                @"barrier_triangle_count" :
                    assets[@"barrier_collision"][@"count"],
                @"gate_barrier_triangle_count" :
                    assets[@"gate_barrier_collision"][@"count"],
                @"audio_cue_count" : assets[@"audio"][@"cue_count"],
                @"source_animation_clip_count" :
                    assets[@"animation"][@"source_clip_count"],
                @"selected_animation_clip_count" :
                    assets[@"animation"][@"selected_clip_count"],
                @"articulated_animation_clip_count" :
                    assets[@"animation"][@"articulated_clip_count"],
            },
            @"settings" : @{
                @"version" : @([NSUserDefaults.standardUserDefaults
                    integerForKey:@"ProtectorSettingsVersion"]),
                @"music_enabled" : @([NSUserDefaults.standardUserDefaults
                    boolForKey:@"ProtectorMusicEnabled"]),
                @"effects_enabled" : @([NSUserDefaults.standardUserDefaults
                    boolForKey:@"ProtectorEffectsEnabled"]),
                @"dialogue_enabled" : @([NSUserDefaults.standardUserDefaults
                    boolForKey:@"ProtectorDialogueEnabled"]),
            },
            @"save_file_exists" :
                @([[NSFileManager defaultManager]
                    fileExistsAtPath:self.savePath]),
        };
        self.playthroughProofWritten =
            [self writeProof:proof filename:@"m5-playthrough-proof.json"];
    }
    if (!self.soakEnabled ||
        self.room.state != PROTECTOR_ROOM_COMPLETED ||
        self.soakProofWritten) {
        return;
    }
    const uint64_t memory = ResidentMemoryBytes();
    if (self.soakStartTime == 0.0) {
        self.soakStartTime = now;
        self.soakStartFrameCount = self.room.measured_frame_count;
        self.soakStartTransitionCount = self.room.state_transition_count;
        self.soakStartMemoryBytes = memory;
        self.soakMinimumMemoryBytes = memory;
        self.soakMaximumMemoryBytes = memory;
        return;
    }
    self.soakMinimumMemoryBytes =
        MIN(self.soakMinimumMemoryBytes, memory);
    self.soakMaximumMemoryBytes =
        MAX(self.soakMaximumMemoryBytes, memory);
    const double elapsed = now - self.soakStartTime;
    if (elapsed < 600.0) {
        return;
    }
    NSDictionary* proof = @{
        @"schema" : @"protector-native.soak-proof/v1",
        @"status" : @"passed",
        @"duration_seconds" : @(elapsed),
        @"state" : @"completed",
        @"tick_rate" : @(PROTECTOR_ROOM_TICK_RATE),
        @"frames_presented" :
            @(self.room.measured_frame_count - self.soakStartFrameCount),
        @"state_transition_count_start" :
            @(self.soakStartTransitionCount),
        @"state_transition_count_end" :
            @(self.room.state_transition_count),
        @"core_allocation_count" : @(self.room.allocation_count),
        @"resident_memory_start_bytes" : @(self.soakStartMemoryBytes),
        @"resident_memory_end_bytes" : @(memory),
        @"resident_memory_minimum_bytes" :
            @(self.soakMinimumMemoryBytes),
        @"resident_memory_maximum_bytes" :
            @(self.soakMaximumMemoryBytes),
        @"frame_time_max_microseconds" :
            @(self.room.frame_time_max_microseconds),
        @"collision_query_count" : @(self.room.collision_query_count),
        @"audio_event_count" : @(self.room.audio_event_count),
    };
    self.soakProofWritten =
        [self writeProof:proof filename:@"m5-soak-proof.json"];
}

- (void)pollController:(ProtectorRoomInput*)input {
    GCController* controller = GCController.controllers.firstObject;
    GCExtendedGamepad* pad = controller.extendedGamepad;
    if (!pad) {
        return;
    }
    const float controllerX = pad.leftThumbstick.xAxis.value;
    const float controllerZ = pad.leftThumbstick.yAxis.value;
    if (hypotf(controllerX, controllerZ) >= 0.12f) {
        input->move_x = controllerX;
        input->move_z = controllerZ;
        self.controllerInputEventCount++;
    }
    const BOOL currentA = pad.buttonA.isPressed;
    const BOOL currentB = pad.buttonB.isPressed;
    const BOOL currentX = pad.buttonX.isPressed;
    const BOOL currentY = pad.buttonY.isPressed;
    const BOOL currentMenu = pad.buttonMenu.isPressed;
    if (currentA && !self.controllerA) {
        input->pressed |= PROTECTOR_ACTION_JUMP;
        self.controllerInputEventCount++;
    }
    if (currentB && !self.controllerB) {
        input->pressed |= PROTECTOR_ACTION_ATTACK_LIGHT;
        self.controllerInputEventCount++;
    }
    if (currentX && !self.controllerX) {
        input->pressed |= PROTECTOR_ACTION_TRANSFORM;
        self.controllerInputEventCount++;
        [self.haptics playNamed:@"transform"];
    }
    if (currentY && !self.controllerY) {
        input->pressed |= PROTECTOR_ACTION_ATTACK_HEAVY;
        self.controllerInputEventCount++;
        [self.haptics playNamed:@"heavy_attack"];
    }
    if (currentMenu && !self.controllerMenu) {
        input->pressed |= PROTECTOR_ACTION_PAUSE;
        self.controllerInputEventCount++;
    }
    self.controllerA = currentA;
    self.controllerB = currentB;
    self.controllerX = currentX;
    self.controllerY = currentY;
    self.controllerMenu = currentMenu;
}

- (void)addPart:(NSMutableArray<NSDictionary*>*)actors
           base:(ProtectorVec3)base
         facing:(float)facing
         offset:(simd_float3)offset
          scale:(simd_float3)scale
       rotation:(simd_float3)rotation
          color:(NSArray<NSNumber*>*)color
          blend:(BOOL)blend {
    const float cosine = cosf(facing);
    const float sine = sinf(facing);
    const simd_float3 position = {
        base.x + offset.x * cosine + offset.z * sine,
        base.y + offset.y,
        base.z - offset.x * sine + offset.z * cosine,
    };
    [actors addObject:@{
        @"position" : @[@(position.x), @(position.y), @(position.z)],
        @"scale" : @[@(scale.x), @(scale.y), @(scale.z)],
        @"rotation" : @[
            @(rotation.x),
            @(rotation.y + facing),
            @(rotation.z),
        ],
        @"color" : color,
        @"blend" : blend ? @"source_alpha" : @"opaque",
    }];
}

- (void)addBen:(NSMutableArray<NSDictionary*>*)actors {
    const ProtectorPlayerState player = self.room.player;
    const BOOL moving =
        fabsf(player.velocity.x) + fabsf(player.velocity.z) > 0.1f;
    const float cycle = (float)self.room.tick * 0.55f;
    const float bob = moving ? fabsf(sinf(cycle)) * 0.08f : 0.0f;
    const float legSwing = moving ? sinf(cycle) * 0.28f : 0.0f;
    const float attack =
        self.room.player_attack_cooldown_ticks > 0
            ? sinf(
                (10.0f - (float)self.room.player_attack_cooldown_ticks) *
                (float)M_PI / 10.0f
            )
            : 0.0f;
    const ProtectorVec3 base = {
        player.position.x,
        player.position.y + bob,
        player.position.z,
    };
    NSArray<NSNumber*>* black = @[@0.025, @0.035, @0.04, @1.0];
    NSArray<NSNumber*>* green = @[@0.08, @0.72, @0.20, @1.0];
    NSArray<NSNumber*>* white = @[@0.82, @0.86, @0.80, @1.0];
    NSArray<NSNumber*>* skin = @[@0.94, @0.62, @0.42, @1.0];
    NSArray<NSNumber*>* hair = @[@0.10, @0.05, @0.025, @1.0];
    NSArray<NSNumber*>* omni = @[@0.25, @1.0, @0.45, @1.0];
    const float facing = player.facing_radians;
    [self addPart:actors base:base facing:facing
           offset:(simd_float3){-0.24f, 0.0f, 0.0f}
            scale:(simd_float3){0.30f, 0.90f, 0.34f}
         rotation:(simd_float3){legSwing, 0.0f, 0.0f}
            color:black blend:NO];
    [self addPart:actors base:base facing:facing
           offset:(simd_float3){0.24f, 0.0f, 0.0f}
            scale:(simd_float3){0.30f, 0.90f, 0.34f}
         rotation:(simd_float3){-legSwing, 0.0f, 0.0f}
            color:black blend:NO];
    [self addPart:actors base:base facing:facing
           offset:(simd_float3){0.0f, 0.82f, 0.0f}
            scale:(simd_float3){0.92f, 1.05f, 0.56f}
         rotation:(simd_float3){0.0f, 0.0f, 0.0f}
            color:green blend:NO];
    [self addPart:actors base:base facing:facing
           offset:(simd_float3){0.0f, 1.02f, 0.30f}
            scale:(simd_float3){0.24f, 0.24f, 0.08f}
         rotation:(simd_float3){0.0f, 0.0f, 0.0f}
            color:omni blend:NO];
    for (int side = -1; side <= 1; side += 2) {
        [self addPart:actors base:base facing:facing
               offset:(simd_float3){0.51f * side, 1.55f, 0.0f}
                scale:(simd_float3){0.24f, 0.82f, 0.26f}
             rotation:(simd_float3){
                 0.0f,
                 0.0f,
                 0.18f * side - attack * 0.85f * side,
             }
                color:white blend:NO];
        [self addPart:actors base:base facing:facing
               offset:(simd_float3){0.55f * side, 1.28f, 0.0f}
                scale:(simd_float3){0.26f, 0.34f, 0.28f}
             rotation:(simd_float3){0.0f, 0.0f, 0.0f}
                color:skin blend:NO];
    }
    [self addPart:actors base:base facing:facing
           offset:(simd_float3){0.0f, 1.84f, 0.0f}
            scale:(simd_float3){0.62f, 0.58f, 0.55f}
         rotation:(simd_float3){0.0f, 0.0f, 0.0f}
            color:skin blend:NO];
    [self addPart:actors base:base facing:facing
           offset:(simd_float3){0.0f, 2.34f, -0.02f}
            scale:(simd_float3){0.66f, 0.18f, 0.58f}
         rotation:(simd_float3){0.0f, 0.0f, -0.08f}
            color:hair blend:NO];
}

- (void)addFourArms:(NSMutableArray<NSDictionary*>*)actors {
    const ProtectorPlayerState player = self.room.player;
    const float cycle = (float)self.room.tick * 0.42f;
    const float bob =
        (fabsf(player.velocity.x) + fabsf(player.velocity.z) > 0.1f)
            ? fabsf(sinf(cycle)) * 0.06f
            : 0.0f;
    const float attack =
        self.room.player_attack_cooldown_ticks > 0
            ? sinf(
                (10.0f - (float)self.room.player_attack_cooldown_ticks) *
                (float)M_PI / 10.0f
            )
            : 0.0f;
    const ProtectorVec3 base = {
        player.position.x,
        player.position.y + bob,
        player.position.z,
    };
    NSArray<NSNumber*>* red = @[@0.72, @0.055, @0.025, @1.0];
    NSArray<NSNumber*>* darkRed = @[@0.38, @0.018, @0.012, @1.0];
    NSArray<NSNumber*>* black = @[@0.025, @0.025, @0.03, @1.0];
    NSArray<NSNumber*>* white = @[@0.88, @0.84, @0.75, @1.0];
    NSArray<NSNumber*>* omni = @[@0.22, @1.0, @0.42, @1.0];
    const float facing = player.facing_radians;
    for (int side = -1; side <= 1; side += 2) {
        [self addPart:actors base:base facing:facing
               offset:(simd_float3){0.34f * side, 0.0f, 0.0f}
                scale:(simd_float3){0.48f, 1.10f, 0.48f}
             rotation:(simd_float3){0.0f, 0.0f, 0.04f * side}
                color:black blend:NO];
    }
    [self addPart:actors base:base facing:facing
           offset:(simd_float3){0.0f, 0.98f, 0.0f}
            scale:(simd_float3){1.35f, 1.55f, 0.82f}
         rotation:(simd_float3){0.0f, 0.0f, 0.0f}
            color:red blend:NO];
    [self addPart:actors base:base facing:facing
           offset:(simd_float3){0.0f, 1.35f, 0.44f}
            scale:(simd_float3){0.34f, 0.34f, 0.10f}
         rotation:(simd_float3){0.0f, 0.0f, 0.0f}
            color:omni blend:NO];
    for (int tier = 0; tier < 2; ++tier) {
        for (int side = -1; side <= 1; side += 2) {
            const float y = tier == 0 ? 1.42f : 2.05f;
            const float swing =
                (tier == 0 ? -0.18f : 0.14f) * side -
                attack * (tier == 0 ? 0.95f : -0.75f) * side;
            [self addPart:actors base:base facing:facing
                   offset:(simd_float3){0.79f * side, y, 0.0f}
                    scale:(simd_float3){0.42f, 1.12f, 0.44f}
                 rotation:(simd_float3){0.0f, 0.0f, swing}
                    color:red blend:NO];
            [self addPart:actors base:base facing:facing
                   offset:(simd_float3){0.83f * side, y - 0.28f, 0.0f}
                    scale:(simd_float3){0.46f, 0.22f, 0.48f}
                 rotation:(simd_float3){0.0f, 0.0f, 0.0f}
                    color:white blend:NO];
        }
    }
    [self addPart:actors base:base facing:facing
           offset:(simd_float3){0.0f, 2.38f, 0.0f}
            scale:(simd_float3){0.84f, 0.72f, 0.70f}
         rotation:(simd_float3){0.0f, 0.0f, 0.0f}
            color:darkRed blend:NO];
}

- (void)addDrone:(ProtectorEnemyState)enemy
           index:(uint32_t)index
          actors:(NSMutableArray<NSDictionary*>*)actors {
    const BOOL moving =
        fabsf(enemy.velocity.x) + fabsf(enemy.velocity.z) > 0.1f;
    const float cycleSeconds = moving
        ? self.droneRunCycleSeconds
        : self.droneIdleCycleSeconds;
    const float phase =
        (float)self.room.tick / (float)PROTECTOR_ROOM_TICK_RATE *
            (float)M_PI * 2.0f / fmaxf(cycleSeconds, 0.05f) +
        (float)index;
    ProtectorVec3 base = enemy.position;
    base.y += 0.20f + sinf(phase) * 0.12f;
    const float facing = enemy.facing_radians;
    const BOOL windingUp = enemy.attack_windup_ticks > 0;
    NSArray<NSNumber*>* armor = windingUp
        ? @[@0.82, @0.42, @0.04, @1.0]
        : enemy.active
            ? @[@0.10, @0.27, @0.50, @1.0]
            : @[@0.22, @0.24, @0.28, @1.0];
    NSArray<NSNumber*>* steel = @[@0.34, @0.40, @0.48, @1.0];
    NSArray<NSNumber*>* eye = windingUp
        ? @[@1.0, @0.92, @0.18, @1.0]
        : enemy.active
            ? @[@1.0, @0.08, @0.025, @1.0]
            : @[@0.20, @0.04, @0.025, @1.0];
    [self addPart:actors base:base facing:facing
           offset:(simd_float3){0.0f, 0.70f, 0.0f}
            scale:(simd_float3){1.05f, 1.25f, 0.78f}
         rotation:(simd_float3){0.0f, 0.0f, 0.0f}
            color:armor blend:NO];
    [self addPart:actors base:base facing:facing
           offset:(simd_float3){0.0f, 1.75f, 0.0f}
            scale:(simd_float3){0.82f, 0.58f, 0.72f}
         rotation:(simd_float3){0.0f, 0.0f, 0.0f}
            color:steel blend:NO];
    [self addPart:actors base:base facing:facing
           offset:(simd_float3){0.0f, 1.93f, 0.38f}
            scale:(simd_float3){0.46f, 0.14f, 0.08f}
         rotation:(simd_float3){0.0f, 0.0f, 0.0f}
            color:eye blend:NO];
    for (int side = -1; side <= 1; side += 2) {
        [self addPart:actors base:base facing:facing
               offset:(simd_float3){0.58f * side, 1.28f, 0.0f}
                scale:(simd_float3){0.25f, 0.90f, 0.28f}
             rotation:(simd_float3){
                 0.0f,
                 0.0f,
                 0.32f * side + sinf(phase) * 0.12f,
             }
                color:steel blend:NO];
        [self addPart:actors base:base facing:facing
               offset:(simd_float3){0.30f * side, 0.0f, 0.0f}
                scale:(simd_float3){0.28f, 0.78f, 0.30f}
             rotation:(simd_float3){0.0f, 0.0f, 0.08f * side}
                color:steel blend:NO];
    }
}

- (void)addGameplayParticles:(NSMutableArray<NSDictionary*>*)actors {
    if (self.renderedForm != self.room.player.form) {
        self.renderedForm = self.room.player.form;
        self.transformationEffectUntilTick = self.room.tick + 20u;
    }
    const BOOL transformBurst =
        self.room.tick < self.transformationEffectUntilTick;
    const BOOL attackBurst = self.room.player_attack_cooldown_ticks > 0;
    if (!transformBurst && !attackBurst) {
        return;
    }
    const float radius = transformBurst
        ? 0.7f +
            1.4f *
                (1.0f -
                 (float)(self.transformationEffectUntilTick - self.room.tick) /
                     20.0f)
        : 1.2f;
    for (uint32_t index = 0; index < 10; ++index) {
        const float angle =
            (float)index * (float)M_PI * 0.2f +
            (float)self.room.tick * 0.22f;
        [self addPart:actors
                 base:self.room.player.position
               facing:0.0f
               offset:(simd_float3){
                   cosf(angle) * radius,
                   0.45f + (float)(index % 3) * 0.42f,
                   sinf(angle) * radius,
               }
                scale:(simd_float3){0.16f, 0.24f, 0.16f}
             rotation:(simd_float3){angle, angle, angle}
                color:transformBurst
                    ? @[@0.10, @1.0, @0.35, @0.72]
                    : @[@1.0, @0.38, @0.04, @0.72]
                blend:YES];
    }
}

- (void)addCombatGuidance:(NSMutableArray<NSDictionary*>*)actors {
    if (!self.room.encounter_started || self.room.living_enemy_count == 0) {
        return;
    }
    [self addPart:actors
             base:self.room.player.position
           facing:self.room.player.facing_radians
           offset:(simd_float3){0.0f, 0.10f, 1.15f}
            scale:(simd_float3){0.10f, 0.035f, 0.90f}
         rotation:(simd_float3){0.0f, 0.0f, 0.0f}
            color:@[@0.16, @1.0, @0.42, @0.72]
            blend:YES];

    ProtectorTargetInfo target = {0};
    if (!protector_room_target_info(&_room, &target)) {
        return;
    }
    const ProtectorEnemyState enemy = self.room.enemies[target.enemy_index];
    const BOOL inRange =
        target.within_light_range || target.within_heavy_range;
    NSArray<NSNumber*>* color = inRange
        ? @[@0.12, @1.0, @0.38, @0.90]
        : @[@1.0, @0.58, @0.08, @0.88];
    const float pulse =
        1.0f + 0.12f * sinf((float)self.room.tick * 0.22f);
    for (int side = -1; side <= 1; side += 2) {
        [self addPart:actors
                 base:enemy.position
               facing:0.0f
               offset:(simd_float3){0.82f * side, 2.05f, 0.0f}
                scale:(simd_float3){0.11f, 0.55f * pulse, 0.11f}
             rotation:(simd_float3){0.0f, 0.0f, 0.30f * side}
                color:color
                blend:YES];
        [self addPart:actors
                 base:enemy.position
               facing:0.0f
               offset:(simd_float3){0.0f, 2.05f, 0.82f * side}
                scale:(simd_float3){0.55f * pulse, 0.11f, 0.11f}
             rotation:(simd_float3){0.0f, 0.30f * side, 0.0f}
                color:color
                blend:YES];
    }
}

- (void)updateRendererState {
    const ProtectorVec3 player = self.room.player.position;
    ProtectorCameraPose cameraPose = {0};
    self.sourceCameraActive =
        protector_room_camera_pose(&_definition, player, &cameraPose);
    simd_float3 eye;
    simd_float3 target;
    if (self.sourceCameraActive) {
        eye = (simd_float3){
            cameraPose.eye.x,
            cameraPose.eye.y,
            cameraPose.eye.z,
        };
        target = (simd_float3){
            cameraPose.target.x,
            cameraPose.target.y,
            cameraPose.target.z,
        };
        self.sourceCameraSegment = cameraPose.segment_index;
    } else {
        const float facing = self.room.player.facing_radians;
        const simd_float3 forward = {sinf(facing), 0.0f, cosf(facing)};
        eye = (simd_float3){
            player.x - forward.x * 15.0f - 3.0f,
            player.y + 7.0f,
            player.z - forward.z * 15.0f,
        };
        target = (simd_float3){
            player.x + forward.x * 5.0f,
            player.y + 1.6f,
            player.z + forward.z * 5.0f,
        };
        self.sourceCameraSegment = 0;
    }
    [self.renderer setGameplayCameraEye:eye target:target];
    NSMutableArray<NSDictionary*>* actors = [NSMutableArray arrayWithCapacity:80];
    if (self.room.player.form == PROTECTOR_FORM_FOUR_ARMS) {
        [self addFourArms:actors];
    } else {
        [self addBen:actors];
    }
    for (uint32_t index = 0; index < self.room.enemy_count; ++index) {
        const ProtectorEnemyState enemy = self.room.enemies[index];
        if (enemy.alive) {
            [self addDrone:enemy index:index actors:actors];
        }
    }
    [self addCombatGuidance:actors];
    [self addGameplayParticles:actors];
    [self.renderer setGameplayActors:actors];
}

- (void)updateDiagnostics {
    const double average = self.room.measured_frame_count
        ? (double)self.room.frame_time_total_microseconds /
            (double)self.room.measured_frame_count / 1000.0
        : 0.0;
    const CGSize drawable = self.metalView.drawableSize;
    const double memoryMiB =
        (double)ResidentMemoryBytes() / (1024.0 * 1024.0);
    self.diagnostics.text = [NSString stringWithFormat:
        @" NATIVE ARM64 · NO JIT\n %@ · tick %llu · %.2f ms\n"
         " HP %.0f · drones %u/%u · form %@\n"
         " pos %.2f %.2f · gates %03x\n"
         " collision %llu/%llu · audio %u\n"
         " %.0fx%.0f · %.1f MiB · thermal %@\n"
         " safe %@ · input %@ · cam %@%u ",
        [NSString stringWithUTF8String:protector_room_state_name(self.room.state)],
        self.room.tick,
        average,
        self.room.player.health,
        self.room.living_enemy_count,
        self.room.enemy_count,
        self.room.player.form == PROTECTOR_FORM_FOUR_ARMS
            ? @"FOUR ARMS"
            : @"BEN",
        self.room.player.position.x,
        self.room.player.position.z,
        self.room.achieved_gate_mask,
        self.room.collision_contact_count,
        self.room.collision_query_count,
        self.room.audio_event_count,
        drawable.width,
        drawable.height,
        memoryMiB,
        ThermalStateName(NSProcessInfo.processInfo.thermalState),
        self.controlsWithinSafeArea ? @"YES" : @"NO",
        self.touchOverlayHiddenForController ? @"CONTROLLER" : @"TOUCH",
        self.sourceCameraActive ? @"SRC-" : @"FALLBACK-",
        self.sourceCameraSegment];
    self.saveResumeButton.hidden =
        self.room.state != PROTECTOR_ROOM_PAUSED &&
        self.room.state != PROTECTOR_ROOM_COMPLETED &&
        self.room.state != PROTECTOR_ROOM_FAILED;
    [self.saveResumeButton
        setTitle:
            self.room.state == PROTECTOR_ROOM_COMPLETED
                ? @"REPLAY ROOM"
                : self.room.state == PROTECTOR_ROOM_FAILED
                    ? @"RETRY ROOM"
                    : @"SAVE + RESUME"
        forState:UIControlStateNormal];
    self.settingsPanel.hidden =
        self.room.state != PROTECTOR_ROOM_PAUSED;
    self.healthBar.progress = self.room.player.health / 100.0f;
    self.omnitrixBar.progress =
        self.room.player.transform_energy / 100.0f;
    if (self.room.state == PROTECTOR_ROOM_COMPLETED) {
        self.missionLabel.text = @"  CANYON LOOKOUT COMPLETE  ";
    } else if (self.room.state == PROTECTOR_ROOM_FAILED) {
        self.missionLabel.text = @"  MISSION FAILED · RETRY  ";
    } else if (self.room.state == PROTECTOR_ROOM_PAUSED) {
        self.missionLabel.text = @"  PAUSED · SAVE TO CONTINUE  ";
    } else if (!self.room.encounter_started) {
        self.missionLabel.text = @"  REACH THE VILGAX DRONES  ";
    } else if (self.room.living_enemy_count > 0) {
        self.missionLabel.text = [NSString stringWithFormat:
            @"  DEFEAT THE DRONES · %u LEFT  ",
            self.room.living_enemy_count];
    } else {
        self.missionLabel.text = @"  ENCOUNTER CLEAR · REACH THE EXIT  ";
    }
}

- (void)playPendingAudio {
    const uint32_t newest = self.room.audio_cue_serial;
    uint32_t serial = self.lastAudioSerial + 1u;
    if (newest >= PROTECTOR_ROOM_AUDIO_EVENT_CAPACITY &&
        serial <= newest - PROTECTOR_ROOM_AUDIO_EVENT_CAPACITY) {
        serial = newest - PROTECTOR_ROOM_AUDIO_EVENT_CAPACITY + 1u;
    }
    for (; serial <= newest; ++serial) {
        const ProtectorAudioCue cue =
            protector_room_audio_cue_for_serial(&_room, serial);
        [self.audio playRoomCue:cue form:self.room.player.form];
    }
    self.lastAudioSerial = newest;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (void)mtkView:(MTKView*)view
    drawableSizeWillChange:(CGSize)size {
    (void)size;
    view.drawableSize = CGSizeMake(self.renderer.width, self.renderer.height);
}

- (void)drawInMTKView:(MTKView*)view {
    const CFTimeInterval now = CACurrentMediaTime();
    if (self.previousFrameTime == 0.0) {
        self.previousFrameTime = now - 1.0 / PROTECTOR_ROOM_TICK_RATE;
    }
    const double elapsed = fmin(0.25, now - self.previousFrameTime);
    self.previousFrameTime = now;
    self.accumulator += elapsed;
    ProtectorRoomInput input = {0};
    if (self.autoplayEnabled) {
        input = [self autoplayInput];
        self.pendingPressed = 0;
    } else {
        input = self.touchInput;
        input.pressed = self.pendingPressed;
        self.pendingPressed = 0;
        [self pollController:&input];
        ProtectorCameraPose cameraPose = {0};
        if (protector_room_camera_pose(
                &_definition,
                self.room.player.position,
                &cameraPose
            )) {
            input = protector_room_camera_relative_input(input, &cameraPose);
        }
    }
    const double timestep = 1.0 / PROTECTOR_ROOM_TICK_RATE;
    NSUInteger catchup = 0;
    while (self.accumulator >= timestep && catchup < 4) {
        protector_room_step(&_room, &_definition, input);
        input.pressed = 0;
        self.accumulator -= timestep;
        catchup++;
    }
    if (self.room.player.health < self.previousPlayerHealth) {
        [self.haptics playNamed:@"damage"];
    }
    if (self.previousTransformEnergy >= 25.0f &&
        self.room.player.transform_energy < 25.0f) {
        [self.haptics playNamed:@"low_energy"];
    }
    self.previousPlayerHealth = self.room.player.health;
    self.previousTransformEnergy = self.room.player.transform_energy;
    [self playPendingAudio];
    [self updateRendererState];
    [self updateDiagnostics];

    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable) {
        return;
    }
    NSError* error = nil;
    if (![self.renderer presentFrameAtTime:(double)self.room.tick / 30.0
                                  drawable:drawable
                                     error:&error]) {
        view.paused = YES;
        self.diagnostics.text = [NSString stringWithFormat:
            @"RENDER FAILURE\n%@", error.localizedDescription];
        return;
    }
    const uint32_t frameMicroseconds =
        (uint32_t)llround((CACurrentMediaTime() - now) * 1000000.0);
    protector_room_record_frame_time(&_room, frameMicroseconds);
    [self updateProofStateAtTime:CACurrentMediaTime()];
    [self writeDeviceProofIfNeeded:NO];
}

@end

@interface ProtectorRoomSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation ProtectorRoomSceneDelegate

- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions {
    (void)session;
    (void)connectionOptions;
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    self.window =
        [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    self.window.rootViewController =
        [[ProtectorRoomViewController alloc] init];
    [self.window makeKeyAndVisible];
}

@end

@interface ProtectorRoomAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ProtectorRoomAppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    (void)application;
    (void)launchOptions;
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        @"ProtectorSettingsVersion" : @1,
        @"ProtectorMusicEnabled" : @YES,
        @"ProtectorEffectsEnabled" : @YES,
        @"ProtectorDialogueEnabled" : @YES,
        @"ProtectorM6LaunchCount" : @0,
        @"ProtectorM6BackgroundSaveTotal" : @0,
        @"ProtectorM6RestoreTotal" : @0,
    }];
    NSInteger launchCount =
        [NSUserDefaults.standardUserDefaults
            integerForKey:@"ProtectorM6LaunchCount"];
    [NSUserDefaults.standardUserDefaults
        setInteger:launchCount + 1
            forKey:@"ProtectorM6LaunchCount"];
    return YES;
}

@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        return UIApplicationMain(
            argc,
            argv,
            nil,
            NSStringFromClass([ProtectorRoomAppDelegate class])
        );
    }
}
