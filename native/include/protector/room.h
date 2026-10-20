#ifndef PROTECTOR_ROOM_H
#define PROTECTOR_ROOM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define PROTECTOR_ROOM_TICK_RATE 30u
#define PROTECTOR_ROOM_MAX_ENEMIES 16u
#define PROTECTOR_ROOM_MAX_CAMERA_PATH_POINTS 16u
#define PROTECTOR_ROOM_AUDIO_EVENT_CAPACITY 32u
#define PROTECTOR_ROOM_SAVE_VERSION 2u
#define PROTECTOR_ROOM_TARGET_ACQUIRE_RANGE 9.0f
#define PROTECTOR_ROOM_TARGET_ACQUIRE_ANGLE_RADIANS 1.309f
#define PROTECTOR_ROOM_CAMERA_ARM_OFFSET 6.0f
#define PROTECTOR_ROOM_REFERENCE_VERTICAL_FOV_DEGREES 43.94577f
#define PROTECTOR_ROOM_PLAYER_COLLISION_RADIUS 0.48f
#define PROTECTOR_ROOM_PLAYER_COLLISION_HEIGHT 1.75f
#define PROTECTOR_ROOM_ENEMY_COLLISION_RADIUS 0.42f
#define PROTECTOR_ROOM_ENEMY_COLLISION_HEIGHT 1.55f
#define PROTECTOR_ROOM_ENEMY_ATTACK_WINDUP_TICKS 15u
#define PROTECTOR_ROOM_ENEMY_ATTACK_COOLDOWN_TICKS 45u

typedef struct {
    float x;
    float y;
    float z;
} ProtectorVec3;

typedef enum {
    PROTECTOR_ROOM_COLD = 0,
    PROTECTOR_ROOM_RUNNING = 1,
    PROTECTOR_ROOM_PAUSED = 2,
    PROTECTOR_ROOM_COMPLETED = 3,
    PROTECTOR_ROOM_FAILED = 4,
} ProtectorRoomState;

typedef enum {
    PROTECTOR_FORM_BEN = 0,
    PROTECTOR_FORM_FOUR_ARMS = 1,
    PROTECTOR_FORM_HEATBLAST = 2,
} ProtectorPlayerForm;

typedef enum {
    PROTECTOR_AUDIO_NONE = 0,
    PROTECTOR_AUDIO_MUSIC_START = 1,
    PROTECTOR_AUDIO_JUMP = 2,
    PROTECTOR_AUDIO_ATTACK = 3,
    PROTECTOR_AUDIO_TRANSFORM = 4,
    PROTECTOR_AUDIO_ENEMY_HIT = 5,
    PROTECTOR_AUDIO_ENEMY_DEFEATED = 6,
    PROTECTOR_AUDIO_PAUSE = 7,
    PROTECTOR_AUDIO_RESUME = 8,
    PROTECTOR_AUDIO_SAVE = 9,
    PROTECTOR_AUDIO_ROOM_COMPLETE = 10,
    PROTECTOR_AUDIO_ENCOUNTER_START = 11,
    PROTECTOR_AUDIO_ENEMY_ATTACK = 12,
    PROTECTOR_AUDIO_PLAYER_HURT = 13,
} ProtectorAudioCue;

typedef enum {
    PROTECTOR_ACTION_JUMP = 1u << 0,
    PROTECTOR_ACTION_ATTACK_LIGHT = 1u << 1,
    PROTECTOR_ACTION_ATTACK_HEAVY = 1u << 2,
    PROTECTOR_ACTION_TRANSFORM = 1u << 3,
    PROTECTOR_ACTION_PAUSE = 1u << 4,
} ProtectorAction;

typedef enum {
    PROTECTOR_GATE_MOVED = 1u << 0,
    PROTECTOR_GATE_JUMPED = 1u << 1,
    PROTECTOR_GATE_ATTACKED = 1u << 2,
    PROTECTOR_GATE_TRANSFORMED = 1u << 3,
    PROTECTOR_GATE_ENCOUNTER_DEFEATED = 1u << 4,
    PROTECTOR_GATE_AUDIO_TRIGGERED = 1u << 5,
    PROTECTOR_GATE_PAUSED = 1u << 6,
    PROTECTOR_GATE_SAVED = 1u << 7,
    PROTECTOR_GATE_RESUMED = 1u << 8,
} ProtectorRoomGate;

typedef struct {
    float move_x;
    float move_z;
    float camera_x;
    uint32_t pressed;
} ProtectorRoomInput;

typedef struct {
    ProtectorVec3 position;
    float facing_radians;
    uint32_t source_instance_index;
} ProtectorEnemySpawn;

typedef struct {
    ProtectorVec3 a;
    ProtectorVec3 b;
    ProtectorVec3 c;
} ProtectorCollisionTriangle;

typedef struct {
    ProtectorVec3 position;
    float rotation_y_units;
    float tilt_units;
    float distance;
    float height;
} ProtectorCameraPathPoint;

typedef struct {
    ProtectorVec3 eye;
    ProtectorVec3 target;
    float yaw_radians;
    uint32_t segment_index;
} ProtectorCameraPose;

typedef struct {
    uint32_t enemy_index;
    float distance;
    float signed_angle_radians;
    bool within_light_range;
    bool within_heavy_range;
} ProtectorTargetInfo;

typedef struct {
    ProtectorVec3 player_spawn;
    ProtectorVec3 encounter_center;
    float encounter_radius;
    ProtectorVec3 exit_center;
    float exit_radius;
    ProtectorVec3 world_minimum;
    ProtectorVec3 world_maximum;
    float ground_height;
    uint32_t source_scene_instance_count;
    uint32_t enemy_count;
    ProtectorEnemySpawn enemies[PROTECTOR_ROOM_MAX_ENEMIES];
    uint32_t camera_path_point_count;
    ProtectorCameraPathPoint
        camera_path_points[PROTECTOR_ROOM_MAX_CAMERA_PATH_POINTS];
    const ProtectorCollisionTriangle* walkable_triangles;
    uint32_t walkable_triangle_count;
    const ProtectorCollisionTriangle* barrier_triangles;
    uint32_t barrier_triangle_count;
    const ProtectorCollisionTriangle* gate_barrier_triangles;
    uint32_t gate_barrier_triangle_count;
} ProtectorRoomDefinition;

typedef struct {
    ProtectorVec3 position;
    ProtectorVec3 velocity;
    float facing_radians;
    float health;
    float transform_energy;
    ProtectorPlayerForm form;
    bool grounded;
} ProtectorPlayerState;

typedef struct {
    ProtectorVec3 position;
    ProtectorVec3 velocity;
    float health;
    float facing_radians;
    uint32_t source_instance_index;
    uint32_t attack_cooldown_ticks;
    uint32_t attack_windup_ticks;
    bool active;
    bool alive;
} ProtectorEnemyState;

typedef struct {
    uint32_t serial;
    ProtectorAudioCue cue;
} ProtectorAudioEvent;

typedef struct {
    uint64_t tick;
    ProtectorRoomState state;
    ProtectorPlayerState player;
    ProtectorEnemyState enemies[PROTECTOR_ROOM_MAX_ENEMIES];
    uint32_t enemy_count;
    uint32_t living_enemy_count;
    uint32_t required_gate_mask;
    uint32_t achieved_gate_mask;
    uint32_t state_transition_count;
    uint32_t audio_event_count;
    ProtectorAudioCue audio_cue;
    uint32_t audio_cue_serial;
    ProtectorAudioEvent
        audio_events[PROTECTOR_ROOM_AUDIO_EVENT_CAPACITY];
    uint32_t player_attack_cooldown_ticks;
    uint32_t player_invulnerability_ticks;
    uint32_t allocation_count;
    uint32_t save_count;
    uint32_t resume_count;
    uint64_t measured_frame_count;
    uint64_t frame_time_total_microseconds;
    uint32_t frame_time_min_microseconds;
    uint32_t frame_time_max_microseconds;
    uint64_t collision_query_count;
    uint64_t collision_contact_count;
    uint64_t barrier_query_count;
    uint64_t barrier_contact_count;
    bool encounter_started;
} ProtectorRoom;

typedef enum {
    PROTECTOR_SAVE_OK = 0,
    PROTECTOR_SAVE_INVALID_ARGUMENT = 1,
    PROTECTOR_SAVE_IO_ERROR = 2,
    PROTECTOR_SAVE_CORRUPT = 3,
    PROTECTOR_SAVE_INCOMPATIBLE = 4,
} ProtectorSaveResult;

void protector_room_definition_init(ProtectorRoomDefinition* definition);

bool protector_room_init(
    ProtectorRoom* room,
    const ProtectorRoomDefinition* definition
);

void protector_room_step(
    ProtectorRoom* room,
    const ProtectorRoomDefinition* definition,
    ProtectorRoomInput input
);

bool protector_room_camera_pose(
    const ProtectorRoomDefinition* definition,
    ProtectorVec3 player_position,
    ProtectorCameraPose* pose
);

ProtectorRoomInput protector_room_camera_relative_input(
    ProtectorRoomInput input,
    const ProtectorCameraPose* pose
);

bool protector_room_target_info(
    const ProtectorRoom* room,
    ProtectorTargetInfo* target
);

void protector_room_record_frame_time(
    ProtectorRoom* room,
    uint32_t elapsed_microseconds
);

bool protector_room_resume(ProtectorRoom* room);

bool protector_room_ready_to_complete(const ProtectorRoom* room);

ProtectorSaveResult protector_room_save(
    ProtectorRoom* room,
    const char* path,
    char* error,
    size_t error_size
);

ProtectorSaveResult protector_room_load(
    ProtectorRoom* room,
    const ProtectorRoomDefinition* definition,
    const char* path,
    char* error,
    size_t error_size
);

const char* protector_room_state_name(ProtectorRoomState state);
const char* protector_audio_cue_name(ProtectorAudioCue cue);
ProtectorAudioCue protector_room_audio_cue_for_serial(
    const ProtectorRoom* room,
    uint32_t serial
);

#endif
