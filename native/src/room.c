#include "protector/room.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#define PROTECTOR_ROOM_REQUIRED_GATES                                        \
    (PROTECTOR_GATE_MOVED | PROTECTOR_GATE_JUMPED |                         \
     PROTECTOR_GATE_ATTACKED | PROTECTOR_GATE_TRANSFORMED |                 \
     PROTECTOR_GATE_ENCOUNTER_DEFEATED | PROTECTOR_GATE_AUDIO_TRIGGERED |   \
     PROTECTOR_GATE_PAUSED | PROTECTOR_GATE_SAVED | PROTECTOR_GATE_RESUMED)

#define PROTECTOR_ROOM_COMPLETION_GATES PROTECTOR_GATE_ENCOUNTER_DEFEATED

#define PROTECTOR_SAVE_MAGIC 0x50524F35u

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint64_t tick;
    uint32_t state;
    uint32_t achieved_gate_mask;
    ProtectorPlayerState player;
    ProtectorEnemyState enemies[PROTECTOR_ROOM_MAX_ENEMIES];
    uint32_t enemy_count;
    uint32_t living_enemy_count;
    uint32_t state_transition_count;
    uint32_t audio_event_count;
    uint32_t audio_cue_serial;
    uint32_t player_attack_cooldown_ticks;
    uint32_t player_invulnerability_ticks;
    uint32_t save_count;
    uint32_t resume_count;
    bool encounter_started;
    uint8_t reserved[7];
    uint32_t checksum;
} ProtectorRoomSaveV2;

static float clampf(float value, float minimum, float maximum) {
    return fminf(maximum, fmaxf(minimum, value));
}

static float horizontal_distance_squared(ProtectorVec3 a, ProtectorVec3 b) {
    const float x = a.x - b.x;
    const float z = a.z - b.z;
    return x * x + z * z;
}

static float vector_length_squared(float x, float z) {
    return x * x + z * z;
}

static void normalize_horizontal(float* x, float* z) {
    const float length_squared = vector_length_squared(*x, *z);
    if (length_squared <= 1.0f) {
        return;
    }
    const float inverse_length = 1.0f / sqrtf(length_squared);
    *x *= inverse_length;
    *z *= inverse_length;
}

static void emit_audio(ProtectorRoom* room, ProtectorAudioCue cue) {
    room->audio_cue = cue;
    room->audio_cue_serial++;
    ProtectorAudioEvent* event =
        &room->audio_events[
            room->audio_cue_serial % PROTECTOR_ROOM_AUDIO_EVENT_CAPACITY
        ];
    event->serial = room->audio_cue_serial;
    event->cue = cue;
    room->audio_event_count++;
    room->achieved_gate_mask |= PROTECTOR_GATE_AUDIO_TRIGGERED;
}

static void transition_to(ProtectorRoom* room, ProtectorRoomState state) {
    if (room->state == state) {
        return;
    }
    room->state = state;
    room->state_transition_count++;
}

static void set_error(char* error, size_t error_size, const char* message) {
    if (!error || error_size == 0) {
        return;
    }
    snprintf(error, error_size, "%s", message);
}

static uint32_t checksum_bytes(const void* data, size_t size) {
    const uint8_t* bytes = (const uint8_t*)data;
    uint32_t hash = 2166136261u;
    for (size_t index = 0; index < size; ++index) {
        hash ^= bytes[index];
        hash *= 16777619u;
    }
    return hash;
}

static uint32_t save_checksum(const ProtectorRoomSaveV2* save) {
    return checksum_bytes(save, offsetof(ProtectorRoomSaveV2, checksum));
}

static bool valid_definition(const ProtectorRoomDefinition* definition) {
    return definition && definition->enemy_count > 0 &&
        definition->enemy_count <= PROTECTOR_ROOM_MAX_ENEMIES &&
        definition->encounter_radius > 0.0f && definition->exit_radius > 0.0f &&
        definition->world_minimum.x < definition->world_maximum.x &&
        definition->world_minimum.y < definition->world_maximum.y &&
        definition->world_minimum.z < definition->world_maximum.z &&
        (definition->camera_path_point_count == 0 ||
         (definition->camera_path_point_count >= 2 &&
          definition->camera_path_point_count <=
              PROTECTOR_ROOM_MAX_CAMERA_PATH_POINTS)) &&
        ((definition->walkable_triangle_count == 0 &&
          definition->walkable_triangles == NULL) ||
         (definition->walkable_triangle_count > 0 &&
          definition->walkable_triangles != NULL)) &&
        ((definition->barrier_triangle_count == 0 &&
          definition->barrier_triangles == NULL) ||
         (definition->barrier_triangle_count > 0 &&
          definition->barrier_triangles != NULL)) &&
        ((definition->gate_barrier_triangle_count == 0 &&
          definition->gate_barrier_triangles == NULL) ||
         (definition->gate_barrier_triangle_count > 0 &&
          definition->gate_barrier_triangles != NULL));
}

void protector_room_definition_init(ProtectorRoomDefinition* definition) {
    if (!definition) {
        return;
    }
    memset(definition, 0, sizeof(*definition));
    definition->encounter_radius = 8.0f;
    definition->exit_radius = 1.5f;
    definition->world_minimum =
        (ProtectorVec3){-100.0f, -100.0f, -100.0f};
    definition->world_maximum =
        (ProtectorVec3){100.0f, 100.0f, 100.0f};
}

bool protector_room_init(
    ProtectorRoom* room,
    const ProtectorRoomDefinition* definition
) {
    if (!room || !valid_definition(definition)) {
        return false;
    }
    memset(room, 0, sizeof(*room));
    room->state = PROTECTOR_ROOM_RUNNING;
    room->state_transition_count = 1;
    room->required_gate_mask = PROTECTOR_ROOM_REQUIRED_GATES;
    room->player.position = definition->player_spawn;
    room->player.health = 100.0f;
    room->player.transform_energy = 100.0f;
    room->player.form = PROTECTOR_FORM_BEN;
    room->player.grounded = true;
    room->enemy_count = definition->enemy_count;
    room->living_enemy_count = definition->enemy_count;
    room->frame_time_min_microseconds = UINT32_MAX;
    for (uint32_t index = 0; index < definition->enemy_count; ++index) {
        room->enemies[index].position = definition->enemies[index].position;
        room->enemies[index].facing_radians =
            definition->enemies[index].facing_radians;
        room->enemies[index].source_instance_index =
            definition->enemies[index].source_instance_index;
        room->enemies[index].health = 3.0f;
        room->enemies[index].alive = true;
    }
    emit_audio(room, PROTECTOR_AUDIO_MUSIC_START);
    return true;
}

bool protector_room_camera_pose(
    const ProtectorRoomDefinition* definition,
    ProtectorVec3 player_position,
    ProtectorCameraPose* pose
) {
    if (!definition || !pose || definition->camera_path_point_count < 2 ||
        definition->camera_path_point_count >
            PROTECTOR_ROOM_MAX_CAMERA_PATH_POINTS) {
        return false;
    }
    float best_distance_squared = INFINITY;
    float best_fraction = 0.0f;
    uint32_t best_segment = 0;
    for (uint32_t index = 0;
         index + 1 < definition->camera_path_point_count;
         ++index) {
        const ProtectorVec3 a = definition->camera_path_points[index].position;
        const ProtectorVec3 b =
            definition->camera_path_points[index + 1].position;
        const float delta_x = b.x - a.x;
        const float delta_z = b.z - a.z;
        const float length_squared =
            delta_x * delta_x + delta_z * delta_z;
        if (length_squared <= 0.000001f) {
            continue;
        }
        const float fraction = clampf(
            ((player_position.x - a.x) * delta_x +
             (player_position.z - a.z) * delta_z) /
                length_squared,
            0.0f,
            1.0f
        );
        const float nearest_x = a.x + delta_x * fraction;
        const float nearest_z = a.z + delta_z * fraction;
        const float difference_x = player_position.x - nearest_x;
        const float difference_z = player_position.z - nearest_z;
        const float distance_squared =
            difference_x * difference_x + difference_z * difference_z;
        if (distance_squared < best_distance_squared) {
            best_distance_squared = distance_squared;
            best_fraction = fraction;
            best_segment = index;
        }
    }
    if (!isfinite(best_distance_squared)) {
        return false;
    }
    const ProtectorCameraPathPoint a =
        definition->camera_path_points[best_segment];
    const ProtectorCameraPathPoint b =
        definition->camera_path_points[best_segment + 1];
    const float rotation_units =
        a.rotation_y_units +
        (b.rotation_y_units - a.rotation_y_units) * best_fraction;
    const float yaw =
        rotation_units * (2.0f * (float)M_PI / 4096.0f);
    const float source_distance =
        a.distance + (b.distance - a.distance) * best_fraction;
    const float pitch_degrees =
        a.height + (b.height - a.height) * best_fraction;
    const float pitch = pitch_degrees * ((float)M_PI / 180.0f);
    const float arm_length =
        source_distance + PROTECTOR_ROOM_CAMERA_ARM_OFFSET;
    const float horizontal_arm = arm_length * cosf(pitch);
    pose->target = player_position;
    pose->eye = (ProtectorVec3){
        player_position.x - sinf(yaw) * horizontal_arm,
        player_position.y + sinf(pitch) * arm_length,
        player_position.z + cosf(yaw) * horizontal_arm,
    };
    pose->yaw_radians = atan2f(
        pose->target.x - pose->eye.x,
        pose->target.z - pose->eye.z
    );
    pose->segment_index = best_segment;
    return isfinite(pose->eye.x) && isfinite(pose->eye.y) &&
        isfinite(pose->eye.z) && isfinite(pose->yaw_radians);
}

ProtectorRoomInput protector_room_camera_relative_input(
    ProtectorRoomInput input,
    const ProtectorCameraPose* pose
) {
    if (!pose) {
        return input;
    }
    const float forward_x = sinf(pose->yaw_radians);
    const float forward_z = cosf(pose->yaw_radians);
    const float right_x = -forward_z;
    const float right_z = forward_x;
    const float local_x = input.move_x;
    const float local_z = input.move_z;
    input.move_x = right_x * local_x + forward_x * local_z;
    input.move_z = right_z * local_x + forward_z * local_z;
    normalize_horizontal(&input.move_x, &input.move_z);
    return input;
}

static bool select_target(
    const ProtectorRoom* room,
    float maximum_range,
    float maximum_angle_radians,
    ProtectorTargetInfo* target
) {
    if (!room || !target || maximum_range <= 0.0f ||
        maximum_angle_radians <= 0.0f) {
        return false;
    }
    const float forward_x = sinf(room->player.facing_radians);
    const float forward_z = cosf(room->player.facing_radians);
    float best_distance = INFINITY;
    uint32_t best_index = PROTECTOR_ROOM_MAX_ENEMIES;
    float best_angle = 0.0f;
    for (uint32_t index = 0; index < room->enemy_count; ++index) {
        const ProtectorEnemyState* enemy = &room->enemies[index];
        if (!enemy->alive || !enemy->active) {
            continue;
        }
        const float delta_x = enemy->position.x - room->player.position.x;
        const float delta_z = enemy->position.z - room->player.position.z;
        const float distance = hypotf(delta_x, delta_z);
        if (distance > maximum_range) {
            continue;
        }
        const float inverse_distance =
            distance > 0.000001f ? 1.0f / distance : 0.0f;
        const float direction_x = delta_x * inverse_distance;
        const float direction_z = delta_z * inverse_distance;
        const float contact_range =
            PROTECTOR_ROOM_PLAYER_COLLISION_RADIUS +
            PROTECTOR_ROOM_ENEMY_COLLISION_RADIUS;
        const float signed_angle = distance > contact_range
            ? atan2f(
                forward_z * direction_x - forward_x * direction_z,
                forward_x * direction_x + forward_z * direction_z
            )
            : 0.0f;
        if (fabsf(signed_angle) > maximum_angle_radians ||
            distance >= best_distance) {
            continue;
        }
        best_distance = distance;
        best_index = index;
        best_angle = signed_angle;
    }
    if (best_index == PROTECTOR_ROOM_MAX_ENEMIES) {
        return false;
    }
    target->enemy_index = best_index;
    target->distance = best_distance;
    target->signed_angle_radians = best_angle;
    target->within_light_range = best_distance <= 2.4f;
    target->within_heavy_range = best_distance <= 3.1f;
    return true;
}

bool protector_room_target_info(
    const ProtectorRoom* room,
    ProtectorTargetInfo* target
) {
    return select_target(
        room,
        PROTECTOR_ROOM_TARGET_ACQUIRE_RANGE,
        PROTECTOR_ROOM_TARGET_ACQUIRE_ANGLE_RADIANS,
        target
    );
}

static bool horizontal_barycentric_height(
    const ProtectorCollisionTriangle* triangle,
    float x,
    float z,
    float* height
) {
    const float denominator =
        (triangle->b.z - triangle->c.z) *
            (triangle->a.x - triangle->c.x) +
        (triangle->c.x - triangle->b.x) *
            (triangle->a.z - triangle->c.z);
    if (fabsf(denominator) < 0.000001f) {
        return false;
    }
    const float a_weight =
        ((triangle->b.z - triangle->c.z) * (x - triangle->c.x) +
         (triangle->c.x - triangle->b.x) * (z - triangle->c.z)) /
        denominator;
    const float b_weight =
        ((triangle->c.z - triangle->a.z) * (x - triangle->c.x) +
         (triangle->a.x - triangle->c.x) * (z - triangle->c.z)) /
        denominator;
    const float c_weight = 1.0f - a_weight - b_weight;
    const float tolerance = -0.0001f;
    if (a_weight < tolerance || b_weight < tolerance ||
        c_weight < tolerance) {
        return false;
    }
    *height =
        a_weight * triangle->a.y +
        b_weight * triangle->b.y +
        c_weight * triangle->c.y;
    return isfinite(*height);
}

static float collision_ground_height(
    ProtectorRoom* room,
    const ProtectorRoomDefinition* definition,
    float x,
    float z,
    float maximum_height,
    bool* source_contact
) {
    room->collision_query_count++;
    float best = -INFINITY;
    for (uint32_t index = 0;
         index < definition->walkable_triangle_count;
         ++index) {
        float height = 0.0f;
        if (!horizontal_barycentric_height(
                &definition->walkable_triangles[index],
                x,
                z,
                &height
            ) ||
            height > maximum_height ||
            height <= best) {
            continue;
        }
        best = height;
    }
    if (isfinite(best)) {
        room->collision_contact_count++;
        *source_contact = true;
        return best;
    }
    *source_contact = false;
    return definition->ground_height;
}

static float closest_segment_parameter(
    float point_x,
    float point_z,
    ProtectorVec3 start,
    ProtectorVec3 end
) {
    const float edge_x = end.x - start.x;
    const float edge_z = end.z - start.z;
    const float length_squared = vector_length_squared(edge_x, edge_z);
    if (length_squared <= 0.000001f) {
        return 0.0f;
    }
    return clampf(
        ((point_x - start.x) * edge_x +
         (point_z - start.z) * edge_z) /
            length_squared,
        0.0f,
        1.0f
    );
}

static bool point_inside_triangle_xz(
    float x,
    float z,
    const ProtectorCollisionTriangle* triangle
) {
    const float d1 =
        (x - triangle->b.x) * (triangle->a.z - triangle->b.z) -
        (triangle->a.x - triangle->b.x) * (z - triangle->b.z);
    const float d2 =
        (x - triangle->c.x) * (triangle->b.z - triangle->c.z) -
        (triangle->b.x - triangle->c.x) * (z - triangle->c.z);
    const float d3 =
        (x - triangle->a.x) * (triangle->c.z - triangle->a.z) -
        (triangle->c.x - triangle->a.x) * (z - triangle->a.z);
    const bool negative = d1 < -0.0001f || d2 < -0.0001f || d3 < -0.0001f;
    const bool positive = d1 > 0.0001f || d2 > 0.0001f || d3 > 0.0001f;
    return !(negative && positive);
}

static bool barrier_contact(
    const ProtectorCollisionTriangle* triangle,
    ProtectorVec3 previous,
    ProtectorVec3 position,
    float radius,
    float height,
    float* push_x,
    float* push_z
) {
    const float minimum_y =
        fminf(triangle->a.y, fminf(triangle->b.y, triangle->c.y));
    const float maximum_y =
        fmaxf(triangle->a.y, fmaxf(triangle->b.y, triangle->c.y));
    if (maximum_y < position.y + 0.05f ||
        minimum_y > position.y + height) {
        return false;
    }

    const ProtectorVec3 starts[3] = {
        triangle->a,
        triangle->b,
        triangle->c,
    };
    const ProtectorVec3 ends[3] = {
        triangle->b,
        triangle->c,
        triangle->a,
    };
    float closest_x = triangle->a.x;
    float closest_z = triangle->a.z;
    float closest_distance_squared = INFINITY;
    for (uint32_t edge = 0; edge < 3u; ++edge) {
        const float parameter = closest_segment_parameter(
            position.x,
            position.z,
            starts[edge],
            ends[edge]
        );
        const float candidate_x =
            starts[edge].x + (ends[edge].x - starts[edge].x) * parameter;
        const float candidate_z =
            starts[edge].z + (ends[edge].z - starts[edge].z) * parameter;
        const float delta_x = position.x - candidate_x;
        const float delta_z = position.z - candidate_z;
        const float distance_squared =
            vector_length_squared(delta_x, delta_z);
        if (distance_squared < closest_distance_squared) {
            closest_distance_squared = distance_squared;
            closest_x = candidate_x;
            closest_z = candidate_z;
        }
    }
    if (point_inside_triangle_xz(position.x, position.z, triangle)) {
        closest_distance_squared = 0.0f;
    }
    if (closest_distance_squared >= radius * radius) {
        return false;
    }

    float normal_x = position.x - closest_x;
    float normal_z = position.z - closest_z;
    float distance = sqrtf(fmaxf(closest_distance_squared, 0.0f));
    if (distance <= 0.0001f) {
        const float edge_ab_x = triangle->b.x - triangle->a.x;
        const float edge_ab_y = triangle->b.y - triangle->a.y;
        const float edge_ab_z = triangle->b.z - triangle->a.z;
        const float edge_ac_x = triangle->c.x - triangle->a.x;
        const float edge_ac_y = triangle->c.y - triangle->a.y;
        const float edge_ac_z = triangle->c.z - triangle->a.z;
        normal_x = edge_ab_y * edge_ac_z - edge_ab_z * edge_ac_y;
        normal_z = edge_ab_x * edge_ac_y - edge_ab_y * edge_ac_x;
        const float normal_length =
            sqrtf(vector_length_squared(normal_x, normal_z));
        if (normal_length <= 0.0001f) {
            return false;
        }
        normal_x /= normal_length;
        normal_z /= normal_length;
        const float previous_side =
            (previous.x - triangle->a.x) * normal_x +
            (previous.z - triangle->a.z) * normal_z;
        if (previous_side < 0.0f) {
            normal_x = -normal_x;
            normal_z = -normal_z;
        }
        distance = 0.0f;
    } else {
        normal_x /= distance;
        normal_z /= distance;
    }
    const float depth = radius - distance;
    *push_x = normal_x * depth;
    *push_z = normal_z * depth;
    return true;
}

static void resolve_barrier_collision(
    ProtectorRoom* room,
    const ProtectorRoomDefinition* definition,
    ProtectorVec3 previous,
    float radius,
    float height,
    ProtectorVec3* position,
    ProtectorVec3* velocity
) {
    const uint32_t gate_count = room->living_enemy_count > 0
        ? definition->gate_barrier_triangle_count
        : 0u;
    const uint32_t total_count =
        definition->barrier_triangle_count + gate_count;
    if (total_count == 0) {
        return;
    }
    room->barrier_query_count++;
    bool contacted = false;
    for (uint32_t pass = 0; pass < 3u; ++pass) {
        bool pushed = false;
        for (uint32_t index = 0; index < total_count; ++index) {
            const ProtectorCollisionTriangle* triangle =
                index < definition->barrier_triangle_count
                ? &definition->barrier_triangles[index]
                : &definition->gate_barrier_triangles[
                    index - definition->barrier_triangle_count
                ];
            float push_x = 0.0f;
            float push_z = 0.0f;
            if (!barrier_contact(
                    triangle,
                    previous,
                    *position,
                    radius,
                    height,
                    &push_x,
                    &push_z
                )) {
                continue;
            }
            position->x += push_x;
            position->z += push_z;
            const float push_length =
                sqrtf(vector_length_squared(push_x, push_z));
            if (push_length > 0.0001f) {
                const float normal_x = push_x / push_length;
                const float normal_z = push_z / push_length;
                const float inward =
                    velocity->x * normal_x + velocity->z * normal_z;
                if (inward < 0.0f) {
                    velocity->x -= inward * normal_x;
                    velocity->z -= inward * normal_z;
                }
            }
            pushed = true;
            contacted = true;
        }
        if (!pushed) {
            break;
        }
    }
    if (contacted) {
        room->barrier_contact_count++;
    }
}

static void update_player(
    ProtectorRoom* room,
    const ProtectorRoomDefinition* definition,
    ProtectorRoomInput input
) {
    const float timestep = 1.0f / (float)PROTECTOR_ROOM_TICK_RATE;
    float move_x = clampf(input.move_x, -1.0f, 1.0f);
    float move_z = clampf(input.move_z, -1.0f, 1.0f);
    normalize_horizontal(&move_x, &move_z);
    const float move_length_squared = vector_length_squared(move_x, move_z);
    const float speed = room->player.form == PROTECTOR_FORM_FOUR_ARMS
        ? 5.2f
        : 6.0f;
    if (move_length_squared > 0.0001f) {
        room->player.velocity.x = move_x * speed;
        room->player.velocity.z = move_z * speed;
        room->player.facing_radians = atan2f(move_x, move_z);
        room->achieved_gate_mask |= PROTECTOR_GATE_MOVED;
    } else {
        room->player.velocity.x = 0.0f;
        room->player.velocity.z = 0.0f;
    }

    if ((input.pressed & PROTECTOR_ACTION_JUMP) && room->player.grounded) {
        room->player.velocity.y = 6.5f;
        room->player.grounded = false;
        room->achieved_gate_mask |= PROTECTOR_GATE_JUMPED;
        emit_audio(room, PROTECTOR_AUDIO_JUMP);
    }
    if (!room->player.grounded) {
        room->player.velocity.y -= 18.0f * timestep;
    }

    const ProtectorVec3 previous_position = room->player.position;
    room->player.position.x += room->player.velocity.x * timestep;
    room->player.position.y += room->player.velocity.y * timestep;
    room->player.position.z += room->player.velocity.z * timestep;
    room->player.position.x = clampf(
        room->player.position.x,
        definition->world_minimum.x,
        definition->world_maximum.x
    );
    room->player.position.z = clampf(
        room->player.position.z,
        definition->world_minimum.z,
        definition->world_maximum.z
    );
    resolve_barrier_collision(
        room,
        definition,
        previous_position,
        PROTECTOR_ROOM_PLAYER_COLLISION_RADIUS,
        PROTECTOR_ROOM_PLAYER_COLLISION_HEIGHT,
        &room->player.position,
        &room->player.velocity
    );
    bool source_contact = false;
    const float ground_height = collision_ground_height(
        room,
        definition,
        room->player.position.x,
        room->player.position.z,
        room->player.position.y + (room->player.grounded ? 0.85f : 0.20f),
        &source_contact
    );
    if (room->player.position.y <= ground_height ||
        (room->player.grounded && source_contact)) {
        room->player.position.y = ground_height;
        room->player.velocity.y = 0.0f;
        room->player.grounded = true;
    }

    if ((input.pressed & PROTECTOR_ACTION_TRANSFORM) &&
        room->player.transform_energy >= 20.0f) {
        room->player.form = room->player.form == PROTECTOR_FORM_BEN
            ? PROTECTOR_FORM_FOUR_ARMS
            : PROTECTOR_FORM_BEN;
        room->player.transform_energy -= 20.0f;
        room->achieved_gate_mask |= PROTECTOR_GATE_TRANSFORMED;
        emit_audio(room, PROTECTOR_AUDIO_TRANSFORM);
    }
    room->player.transform_energy =
        fminf(100.0f, room->player.transform_energy + 2.0f * timestep);
}

static void apply_player_attack(ProtectorRoom* room, bool heavy) {
    if (room->player_attack_cooldown_ticks != 0) {
        return;
    }
    room->achieved_gate_mask |= PROTECTOR_GATE_ATTACKED;
    room->player_attack_cooldown_ticks = heavy ? 18u : 10u;
    emit_audio(room, PROTECTOR_AUDIO_ATTACK);

    const float damage =
        heavy || room->player.form == PROTECTOR_FORM_FOUR_ARMS ? 2.0f : 1.0f;
    ProtectorTargetInfo target = {0};
    if (!protector_room_target_info(room, &target) ||
        (heavy ? !target.within_heavy_range : !target.within_light_range)) {
        return;
    }
    ProtectorEnemyState* enemy = &room->enemies[target.enemy_index];
    const float delta_x = enemy->position.x - room->player.position.x;
    const float delta_z = enemy->position.z - room->player.position.z;
    room->player.facing_radians = atan2f(delta_x, delta_z);
    enemy->health -= damage;
    emit_audio(room, PROTECTOR_AUDIO_ENEMY_HIT);
    if (enemy->health > 0.0f) {
        return;
    }
    enemy->health = 0.0f;
    enemy->alive = false;
    enemy->active = false;
    room->living_enemy_count--;
    emit_audio(room, PROTECTOR_AUDIO_ENEMY_DEFEATED);
    if (room->living_enemy_count == 0) {
        room->achieved_gate_mask |= PROTECTOR_GATE_ENCOUNTER_DEFEATED;
    }
}

static void update_enemies(
    ProtectorRoom* room,
    const ProtectorRoomDefinition* definition
) {
    const float timestep = 1.0f / (float)PROTECTOR_ROOM_TICK_RATE;
    if (!room->encounter_started &&
        horizontal_distance_squared(
            room->player.position,
            definition->encounter_center
        ) <= definition->encounter_radius * definition->encounter_radius) {
        room->encounter_started = true;
        emit_audio(room, PROTECTOR_AUDIO_ENCOUNTER_START);
        for (uint32_t index = 0; index < room->enemy_count; ++index) {
            room->enemies[index].active = true;
        }
    }

    uint32_t attack_slot = UINT32_MAX;
    float attack_slot_distance = INFINITY;
    for (uint32_t index = 0; index < room->enemy_count; ++index) {
        ProtectorEnemyState* enemy = &room->enemies[index];
        if (!enemy->active || !enemy->alive) {
            continue;
        }
        const float distance_squared =
            horizontal_distance_squared(enemy->position, room->player.position);
        if (distance_squared > 2.4f * 2.4f) {
            enemy->attack_windup_ticks = 0;
            continue;
        }
        if (enemy->attack_windup_ticks > 0) {
            attack_slot = index;
            break;
        }
        if (distance_squared < attack_slot_distance) {
            attack_slot = index;
            attack_slot_distance = distance_squared;
        }
    }

    for (uint32_t index = 0; index < room->enemy_count; ++index) {
        ProtectorEnemyState* enemy = &room->enemies[index];
        if (!enemy->active || !enemy->alive) {
            continue;
        }
        if (enemy->attack_cooldown_ticks > 0) {
            enemy->attack_cooldown_ticks--;
        }
        float delta_x = room->player.position.x - enemy->position.x;
        float delta_z = room->player.position.z - enemy->position.z;
        const float distance_squared = vector_length_squared(delta_x, delta_z);
        enemy->facing_radians = atan2f(delta_x, delta_z);
        if (distance_squared > 2.2f * 2.2f) {
            const float inverse_distance =
                1.0f / sqrtf(fmaxf(distance_squared, 0.0001f));
            enemy->velocity.x = delta_x * inverse_distance * 2.25f;
            enemy->velocity.z = delta_z * inverse_distance * 2.25f;
            const ProtectorVec3 previous_position = enemy->position;
            enemy->position.x += enemy->velocity.x * timestep;
            enemy->position.z += enemy->velocity.z * timestep;
            resolve_barrier_collision(
                room,
                definition,
                previous_position,
                PROTECTOR_ROOM_ENEMY_COLLISION_RADIUS,
                PROTECTOR_ROOM_ENEMY_COLLISION_HEIGHT,
                &enemy->position,
                &enemy->velocity
            );
            bool source_contact = false;
            enemy->position.y = collision_ground_height(
                room,
                definition,
                enemy->position.x,
                enemy->position.z,
                enemy->position.y + 0.85f,
                &source_contact
            );
        } else {
            enemy->velocity.x = 0.0f;
            enemy->velocity.z = 0.0f;
            if (index != attack_slot) {
                enemy->attack_windup_ticks = 0;
                continue;
            }
            if (enemy->attack_cooldown_ticks != 0) {
                continue;
            }
            if (enemy->attack_windup_ticks == 0) {
                enemy->attack_windup_ticks =
                    PROTECTOR_ROOM_ENEMY_ATTACK_WINDUP_TICKS;
                continue;
            }
            enemy->attack_windup_ticks--;
            if (enemy->attack_windup_ticks == 0 &&
                room->player_invulnerability_ticks == 0) {
                room->player.health -=
                    room->player.form == PROTECTOR_FORM_FOUR_ARMS
                        ? 4.0f
                        : 8.0f;
                enemy->attack_cooldown_ticks =
                    PROTECTOR_ROOM_ENEMY_ATTACK_COOLDOWN_TICKS;
                room->player_invulnerability_ticks = 18u;
                emit_audio(room, PROTECTOR_AUDIO_ENEMY_ATTACK);
                emit_audio(room, PROTECTOR_AUDIO_PLAYER_HURT);
                if (room->player.health <= 0.0f) {
                    room->player.health = 0.0f;
                    transition_to(room, PROTECTOR_ROOM_FAILED);
                    return;
                }
            }
        }
    }
}

void protector_room_step(
    ProtectorRoom* room,
    const ProtectorRoomDefinition* definition,
    ProtectorRoomInput input
) {
    if (!room || !valid_definition(definition)) {
        return;
    }
    room->audio_cue = PROTECTOR_AUDIO_NONE;
    if (room->state == PROTECTOR_ROOM_PAUSED) {
        if (input.pressed & PROTECTOR_ACTION_PAUSE) {
            (void)protector_room_resume(room);
        }
        return;
    }
    if (room->state != PROTECTOR_ROOM_RUNNING) {
        return;
    }
    if (input.pressed & PROTECTOR_ACTION_PAUSE) {
        transition_to(room, PROTECTOR_ROOM_PAUSED);
        room->achieved_gate_mask |= PROTECTOR_GATE_PAUSED;
        emit_audio(room, PROTECTOR_AUDIO_PAUSE);
        return;
    }

    room->tick++;
    if (room->player_attack_cooldown_ticks > 0) {
        room->player_attack_cooldown_ticks--;
    }
    if (room->player_invulnerability_ticks > 0) {
        room->player_invulnerability_ticks--;
    }
    update_player(room, definition, input);
    if (input.pressed &
        (PROTECTOR_ACTION_ATTACK_LIGHT | PROTECTOR_ACTION_ATTACK_HEAVY)) {
        apply_player_attack(
            room,
            (input.pressed & PROTECTOR_ACTION_ATTACK_HEAVY) != 0
        );
    }
    update_enemies(room, definition);

    if (protector_room_ready_to_complete(room) &&
        horizontal_distance_squared(
            room->player.position,
            definition->exit_center
        ) <= definition->exit_radius * definition->exit_radius) {
        transition_to(room, PROTECTOR_ROOM_COMPLETED);
        emit_audio(room, PROTECTOR_AUDIO_ROOM_COMPLETE);
    }
}

void protector_room_record_frame_time(
    ProtectorRoom* room,
    uint32_t elapsed_microseconds
) {
    if (!room) {
        return;
    }
    room->measured_frame_count++;
    room->frame_time_total_microseconds += elapsed_microseconds;
    room->frame_time_min_microseconds =
        elapsed_microseconds < room->frame_time_min_microseconds
        ? elapsed_microseconds
        : room->frame_time_min_microseconds;
    room->frame_time_max_microseconds =
        elapsed_microseconds > room->frame_time_max_microseconds
        ? elapsed_microseconds
        : room->frame_time_max_microseconds;
}

bool protector_room_resume(ProtectorRoom* room) {
    if (!room || room->state != PROTECTOR_ROOM_PAUSED) {
        return false;
    }
    transition_to(room, PROTECTOR_ROOM_RUNNING);
    room->resume_count++;
    room->achieved_gate_mask |= PROTECTOR_GATE_RESUMED;
    emit_audio(room, PROTECTOR_AUDIO_RESUME);
    return true;
}

bool protector_room_ready_to_complete(const ProtectorRoom* room) {
    return room &&
        (room->achieved_gate_mask & PROTECTOR_ROOM_COMPLETION_GATES) ==
        PROTECTOR_ROOM_COMPLETION_GATES;
}

ProtectorSaveResult protector_room_save(
    ProtectorRoom* room,
    const char* path,
    char* error,
    size_t error_size
) {
    if (!room || !path || !path[0]) {
        set_error(error, error_size, "invalid room save arguments");
        return PROTECTOR_SAVE_INVALID_ARGUMENT;
    }
    ProtectorRoomSaveV2 save;
    memset(&save, 0, sizeof(save));
    save.magic = PROTECTOR_SAVE_MAGIC;
    save.version = PROTECTOR_ROOM_SAVE_VERSION;
    save.tick = room->tick;
    save.state = (uint32_t)room->state;
    save.achieved_gate_mask =
        room->achieved_gate_mask | PROTECTOR_GATE_SAVED;
    save.player = room->player;
    memcpy(save.enemies, room->enemies, sizeof(save.enemies));
    save.enemy_count = room->enemy_count;
    save.living_enemy_count = room->living_enemy_count;
    save.state_transition_count = room->state_transition_count;
    save.audio_event_count = room->audio_event_count;
    save.audio_cue_serial = room->audio_cue_serial;
    save.player_attack_cooldown_ticks = room->player_attack_cooldown_ticks;
    save.player_invulnerability_ticks = room->player_invulnerability_ticks;
    save.save_count = room->save_count + 1u;
    save.resume_count = room->resume_count;
    save.encounter_started = room->encounter_started;
    save.checksum = save_checksum(&save);

    FILE* file = fopen(path, "wb");
    if (!file) {
        char message[256];
        snprintf(message, sizeof(message), "open save failed: %s", strerror(errno));
        set_error(error, error_size, message);
        return PROTECTOR_SAVE_IO_ERROR;
    }
    const bool written = fwrite(&save, 1, sizeof(save), file) == sizeof(save);
    const bool closed = fclose(file) == 0;
    if (!written || !closed) {
        set_error(error, error_size, "write save failed");
        return PROTECTOR_SAVE_IO_ERROR;
    }
    room->save_count++;
    room->achieved_gate_mask |= PROTECTOR_GATE_SAVED;
    emit_audio(room, PROTECTOR_AUDIO_SAVE);
    return PROTECTOR_SAVE_OK;
}

ProtectorSaveResult protector_room_load(
    ProtectorRoom* room,
    const ProtectorRoomDefinition* definition,
    const char* path,
    char* error,
    size_t error_size
) {
    if (!room || !valid_definition(definition) || !path || !path[0]) {
        set_error(error, error_size, "invalid room load arguments");
        return PROTECTOR_SAVE_INVALID_ARGUMENT;
    }
    FILE* file = fopen(path, "rb");
    if (!file) {
        char message[256];
        snprintf(message, sizeof(message), "open save failed: %s", strerror(errno));
        set_error(error, error_size, message);
        return PROTECTOR_SAVE_IO_ERROR;
    }
    ProtectorRoomSaveV2 save;
    memset(&save, 0, sizeof(save));
    const size_t bytes_read = fread(&save, 1, sizeof(save), file);
    const bool read = bytes_read == sizeof(save);
    const bool has_trailing_byte = read && fgetc(file) != EOF;
    const bool stream_failed = ferror(file) != 0;
    const bool closed = fclose(file) == 0;
    if (!read || has_trailing_byte || stream_failed || !closed) {
        set_error(error, error_size, "save file has an invalid length");
        return PROTECTOR_SAVE_CORRUPT;
    }
    if (save.magic != PROTECTOR_SAVE_MAGIC ||
        save.version != PROTECTOR_ROOM_SAVE_VERSION) {
        set_error(error, error_size, "save file is incompatible");
        return PROTECTOR_SAVE_INCOMPATIBLE;
    }
    if (save.checksum != save_checksum(&save) ||
        save.enemy_count != definition->enemy_count ||
        save.enemy_count > PROTECTOR_ROOM_MAX_ENEMIES ||
        save.living_enemy_count > save.enemy_count ||
        save.state > PROTECTOR_ROOM_FAILED) {
        set_error(error, error_size, "save file checksum or state is invalid");
        return PROTECTOR_SAVE_CORRUPT;
    }

    const uint64_t measured_frame_count = room->measured_frame_count;
    const uint64_t frame_time_total_microseconds =
        room->frame_time_total_microseconds;
    const uint32_t frame_time_min_microseconds =
        room->frame_time_min_microseconds;
    const uint32_t frame_time_max_microseconds =
        room->frame_time_max_microseconds;
    const uint64_t collision_query_count = room->collision_query_count;
    const uint64_t collision_contact_count = room->collision_contact_count;
    const uint64_t barrier_query_count = room->barrier_query_count;
    const uint64_t barrier_contact_count = room->barrier_contact_count;
    memset(room, 0, sizeof(*room));
    room->tick = save.tick;
    room->state = (ProtectorRoomState)save.state;
    room->player = save.player;
    memcpy(room->enemies, save.enemies, sizeof(room->enemies));
    room->enemy_count = save.enemy_count;
    room->living_enemy_count = save.living_enemy_count;
    room->required_gate_mask = PROTECTOR_ROOM_REQUIRED_GATES;
    room->achieved_gate_mask = save.achieved_gate_mask;
    room->state_transition_count = save.state_transition_count;
    room->audio_event_count = save.audio_event_count;
    room->audio_cue_serial = save.audio_cue_serial;
    room->player_attack_cooldown_ticks =
        save.player_attack_cooldown_ticks;
    room->player_invulnerability_ticks =
        save.player_invulnerability_ticks;
    room->save_count = save.save_count;
    room->resume_count = save.resume_count;
    room->encounter_started = save.encounter_started;
    room->measured_frame_count = measured_frame_count;
    room->frame_time_total_microseconds = frame_time_total_microseconds;
    room->frame_time_min_microseconds = frame_time_min_microseconds;
    room->frame_time_max_microseconds = frame_time_max_microseconds;
    room->collision_query_count = collision_query_count;
    room->collision_contact_count = collision_contact_count;
    room->barrier_query_count = barrier_query_count;
    room->barrier_contact_count = barrier_contact_count;
    return PROTECTOR_SAVE_OK;
}

const char* protector_room_state_name(ProtectorRoomState state) {
    switch (state) {
    case PROTECTOR_ROOM_COLD:
        return "cold";
    case PROTECTOR_ROOM_RUNNING:
        return "running";
    case PROTECTOR_ROOM_PAUSED:
        return "paused";
    case PROTECTOR_ROOM_COMPLETED:
        return "completed";
    case PROTECTOR_ROOM_FAILED:
        return "failed";
    }
    return "invalid";
}

const char* protector_audio_cue_name(ProtectorAudioCue cue) {
    switch (cue) {
    case PROTECTOR_AUDIO_NONE:
        return "none";
    case PROTECTOR_AUDIO_MUSIC_START:
        return "music_start";
    case PROTECTOR_AUDIO_JUMP:
        return "jump";
    case PROTECTOR_AUDIO_ATTACK:
        return "attack";
    case PROTECTOR_AUDIO_TRANSFORM:
        return "transform";
    case PROTECTOR_AUDIO_ENEMY_HIT:
        return "enemy_hit";
    case PROTECTOR_AUDIO_ENEMY_DEFEATED:
        return "enemy_defeated";
    case PROTECTOR_AUDIO_PAUSE:
        return "pause";
    case PROTECTOR_AUDIO_RESUME:
        return "resume";
    case PROTECTOR_AUDIO_SAVE:
        return "save";
    case PROTECTOR_AUDIO_ROOM_COMPLETE:
        return "room_complete";
    case PROTECTOR_AUDIO_ENCOUNTER_START:
        return "encounter_start";
    case PROTECTOR_AUDIO_ENEMY_ATTACK:
        return "enemy_attack";
    case PROTECTOR_AUDIO_PLAYER_HURT:
        return "player_hurt";
    }
    return "invalid";
}

ProtectorAudioCue protector_room_audio_cue_for_serial(
    const ProtectorRoom* room,
    uint32_t serial
) {
    if (!room || serial == 0 || serial > room->audio_cue_serial ||
        room->audio_cue_serial - serial >=
            PROTECTOR_ROOM_AUDIO_EVENT_CAPACITY) {
        return PROTECTOR_AUDIO_NONE;
    }
    const ProtectorAudioEvent event =
        room->audio_events[serial % PROTECTOR_ROOM_AUDIO_EVENT_CAPACITY];
    return event.serial == serial ? event.cue : PROTECTOR_AUDIO_NONE;
}
