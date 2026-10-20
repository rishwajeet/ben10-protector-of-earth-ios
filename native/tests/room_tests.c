#include "protector/room.h"

#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int failures = 0;

#define CHECK(expression)                                                      \
    do {                                                                       \
        if (!(expression)) {                                                   \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #expression); \
            failures++;                                                        \
        }                                                                      \
    } while (0)

static ProtectorRoomDefinition fixture_definition(void) {
    ProtectorRoomDefinition definition;
    protector_room_definition_init(&definition);
    definition.player_spawn = (ProtectorVec3){0.0f, 0.0f, 0.0f};
    definition.encounter_center = (ProtectorVec3){4.0f, 0.0f, 0.0f};
    definition.encounter_radius = 3.0f;
    definition.exit_center = (ProtectorVec3){8.0f, 0.0f, 0.0f};
    definition.exit_radius = 1.0f;
    definition.world_minimum = (ProtectorVec3){-10.0f, -5.0f, -10.0f};
    definition.world_maximum = (ProtectorVec3){10.0f, 10.0f, 10.0f};
    definition.ground_height = 0.0f;
    definition.source_scene_instance_count = 4;
    definition.enemy_count = 2;
    definition.enemies[0] = (ProtectorEnemySpawn){
        .position = {3.5f, 0.0f, 0.3f},
        .source_instance_index = 21,
    };
    definition.enemies[1] = (ProtectorEnemySpawn){
        .position = {4.5f, 0.0f, -0.3f},
        .source_instance_index = 22,
    };
    return definition;
}

static void advance(
    ProtectorRoom* room,
    const ProtectorRoomDefinition* definition,
    ProtectorRoomInput input,
    uint32_t ticks
) {
    for (uint32_t tick = 0; tick < ticks; ++tick) {
        protector_room_step(room, definition, input);
        input.pressed = 0;
    }
}

static void test_fixed_step_player_actions(void) {
    const ProtectorRoomDefinition definition = fixture_definition();
    ProtectorRoom room;
    CHECK(protector_room_init(&room, &definition));
    CHECK(room.state == PROTECTOR_ROOM_RUNNING);
    CHECK(room.audio_cue == PROTECTOR_AUDIO_MUSIC_START);
    CHECK(room.allocation_count == 0);

    advance(
        &room,
        &definition,
        (ProtectorRoomInput){.move_x = 1.0f},
        PROTECTOR_ROOM_TICK_RATE
    );
    CHECK(room.tick == PROTECTOR_ROOM_TICK_RATE);
    CHECK(fabsf(room.player.position.x - 6.0f) < 0.001f);
    CHECK(room.achieved_gate_mask & PROTECTOR_GATE_MOVED);

    protector_room_step(
        &room,
        &definition,
        (ProtectorRoomInput){.pressed = PROTECTOR_ACTION_JUMP}
    );
    CHECK(!room.player.grounded);
    CHECK(room.player.position.y > 0.0f);
    CHECK(room.achieved_gate_mask & PROTECTOR_GATE_JUMPED);

    protector_room_step(
        &room,
        &definition,
        (ProtectorRoomInput){.pressed = PROTECTOR_ACTION_TRANSFORM}
    );
    CHECK(room.player.form == PROTECTOR_FORM_FOUR_ARMS);
    CHECK(room.achieved_gate_mask & PROTECTOR_GATE_TRANSFORMED);
}

static void test_pause_save_load_resume(void) {
    const ProtectorRoomDefinition definition = fixture_definition();
    ProtectorRoom room;
    CHECK(protector_room_init(&room, &definition));
    advance(
        &room,
        &definition,
        (ProtectorRoomInput){.move_x = 1.0f},
        10
    );
    const ProtectorVec3 saved_position = room.player.position;
    protector_room_step(
        &room,
        &definition,
        (ProtectorRoomInput){.pressed = PROTECTOR_ACTION_PAUSE}
    );
    CHECK(room.state == PROTECTOR_ROOM_PAUSED);
    CHECK(room.achieved_gate_mask & PROTECTOR_GATE_PAUSED);

    char path[160];
    snprintf(path, sizeof(path), "/tmp/protector-room-%ld.save", (long)getpid());
    char error[256] = {0};
    CHECK(
        protector_room_save(&room, path, error, sizeof(error)) ==
        PROTECTOR_SAVE_OK
    );
    CHECK(room.achieved_gate_mask & PROTECTOR_GATE_SAVED);
    CHECK(room.save_count == 1);

    room.player.position.x = -9.0f;
    CHECK(
        protector_room_load(&room, &definition, path, error, sizeof(error)) ==
        PROTECTOR_SAVE_OK
    );
    CHECK(fabsf(room.player.position.x - saved_position.x) < 0.0001f);
    CHECK(room.state == PROTECTOR_ROOM_PAUSED);
    CHECK(protector_room_resume(&room));
    CHECK(room.state == PROTECTOR_ROOM_RUNNING);
    CHECK(room.achieved_gate_mask & PROTECTOR_GATE_RESUMED);
    CHECK(room.resume_count == 1);

    FILE* trailing = fopen(path, "ab");
    CHECK(trailing != NULL);
    if (trailing) {
        CHECK(fputc(0, trailing) != EOF);
        CHECK(fclose(trailing) == 0);
        CHECK(
            protector_room_load(
                &room,
                &definition,
                path,
                error,
                sizeof(error)
            ) == PROTECTOR_SAVE_CORRUPT
        );
    }
    CHECK(unlink(path) == 0);
}

static void test_encounter_and_full_gate(void) {
    const ProtectorRoomDefinition definition = fixture_definition();
    ProtectorRoom room;
    CHECK(protector_room_init(&room, &definition));

    protector_room_step(
        &room,
        &definition,
        (ProtectorRoomInput){
            .move_x = 1.0f,
            .pressed = PROTECTOR_ACTION_JUMP,
        }
    );
    protector_room_step(
        &room,
        &definition,
        (ProtectorRoomInput){.pressed = PROTECTOR_ACTION_TRANSFORM}
    );
    advance(
        &room,
        &definition,
        (ProtectorRoomInput){.move_x = 1.0f},
        15
    );
    CHECK(room.encounter_started);

    for (uint32_t attempt = 0; attempt < 20 && room.living_enemy_count; ++attempt) {
        protector_room_step(
            &room,
            &definition,
            (ProtectorRoomInput){.pressed = PROTECTOR_ACTION_ATTACK_HEAVY}
        );
        advance(&room, &definition, (ProtectorRoomInput){0}, 18);
    }
    CHECK(room.living_enemy_count == 0);
    CHECK(room.achieved_gate_mask & PROTECTOR_GATE_ENCOUNTER_DEFEATED);
    CHECK(!(room.achieved_gate_mask & PROTECTOR_GATE_PAUSED));
    CHECK(!(room.achieved_gate_mask & PROTECTOR_GATE_SAVED));
    CHECK(!(room.achieved_gate_mask & PROTECTOR_GATE_RESUMED));
    CHECK(protector_room_ready_to_complete(&room));

    protector_room_step(
        &room,
        &definition,
        (ProtectorRoomInput){.pressed = PROTECTOR_ACTION_PAUSE}
    );
    char path[160];
    snprintf(
        path,
        sizeof(path),
        "/tmp/protector-room-gate-%ld.save",
        (long)getpid()
    );
    char error[256] = {0};
    CHECK(
        protector_room_save(&room, path, error, sizeof(error)) ==
        PROTECTOR_SAVE_OK
    );
    CHECK(protector_room_resume(&room));
    CHECK(protector_room_ready_to_complete(&room));

    for (uint32_t tick = 0;
         tick < PROTECTOR_ROOM_TICK_RATE * 5u &&
         room.state == PROTECTOR_ROOM_RUNNING;
         ++tick) {
        protector_room_step(
            &room,
            &definition,
            (ProtectorRoomInput){.move_x = 1.0f}
        );
    }
    CHECK(room.state == PROTECTOR_ROOM_COMPLETED);
    CHECK(room.audio_cue == PROTECTOR_AUDIO_ROOM_COMPLETE);
    CHECK(unlink(path) == 0);
}

static void test_frame_metrics_and_ten_minute_idle_soak(void) {
    const ProtectorRoomDefinition definition = fixture_definition();
    ProtectorRoom room;
    CHECK(protector_room_init(&room, &definition));
    const uint32_t soak_ticks = PROTECTOR_ROOM_TICK_RATE * 60u * 10u;
    for (uint32_t tick = 0; tick < soak_ticks; ++tick) {
        protector_room_record_frame_time(&room, 33333u);
        if (tick % 120u == 0) {
            room.player.position = definition.player_spawn;
        }
        protector_room_step(&room, &definition, (ProtectorRoomInput){0});
    }
    CHECK(room.tick == soak_ticks);
    CHECK(room.state == PROTECTOR_ROOM_RUNNING);
    CHECK(room.measured_frame_count == soak_ticks);
    CHECK(room.frame_time_min_microseconds == 33333u);
    CHECK(room.frame_time_max_microseconds == 33333u);
    CHECK(
        room.frame_time_total_microseconds ==
        (uint64_t)soak_ticks * 33333u
    );
    CHECK(room.allocation_count == 0);
}

static void test_source_walkable_collision_and_audio_queue(void) {
    static const ProtectorCollisionTriangle triangles[] = {
        {
            .a = {-2.0f, 1.0f, -2.0f},
            .b = {2.0f, 1.0f, -2.0f},
            .c = {-2.0f, 1.0f, 2.0f},
        },
        {
            .a = {2.0f, 1.0f, -2.0f},
            .b = {2.0f, 1.0f, 2.0f},
            .c = {-2.0f, 1.0f, 2.0f},
        },
    };
    ProtectorRoomDefinition definition = fixture_definition();
    definition.player_spawn.y = 0.25f;
    definition.walkable_triangles = triangles;
    definition.walkable_triangle_count =
        (uint32_t)(sizeof(triangles) / sizeof(triangles[0]));
    ProtectorRoom room;
    CHECK(protector_room_init(&room, &definition));
    protector_room_step(&room, &definition, (ProtectorRoomInput){0});
    CHECK(fabsf(room.player.position.y - 1.0f) < 0.0001f);
    CHECK(room.collision_query_count > 0);
    CHECK(room.collision_contact_count > 0);
    CHECK(
        protector_room_audio_cue_for_serial(&room, 1u) ==
        PROTECTOR_AUDIO_MUSIC_START
    );
    protector_room_step(
        &room,
        &definition,
        (ProtectorRoomInput){.pressed = PROTECTOR_ACTION_JUMP}
    );
    CHECK(
        protector_room_audio_cue_for_serial(&room, 2u) ==
        PROTECTOR_AUDIO_JUMP
    );

    const uint32_t first_serial = room.audio_cue_serial;
    for (uint32_t cycle = 0;
         cycle < PROTECTOR_ROOM_AUDIO_EVENT_CAPACITY;
         ++cycle) {
        protector_room_step(
            &room,
            &definition,
            (ProtectorRoomInput){.pressed = PROTECTOR_ACTION_PAUSE}
        );
        CHECK(protector_room_resume(&room));
    }
    CHECK(
        protector_room_audio_cue_for_serial(&room, first_serial) ==
        PROTECTOR_AUDIO_NONE
    );
    CHECK(
        protector_room_audio_cue_for_serial(&room, room.audio_cue_serial) ==
        PROTECTOR_AUDIO_RESUME
    );
}

static void test_source_barrier_collision_blocks_and_slides(void) {
    static const ProtectorCollisionTriangle barriers[] = {
        {
            .a = {1.0f, 0.0f, -2.0f},
            .b = {1.0f, 3.0f, -2.0f},
            .c = {1.0f, 0.0f, 2.0f},
        },
        {
            .a = {1.0f, 3.0f, -2.0f},
            .b = {1.0f, 3.0f, 2.0f},
            .c = {1.0f, 0.0f, 2.0f},
        },
    };
    ProtectorRoomDefinition definition = fixture_definition();
    definition.encounter_center = (ProtectorVec3){8.0f, 0.0f, 8.0f};
    definition.encounter_radius = 1.0f;
    definition.barrier_triangles = barriers;
    definition.barrier_triangle_count =
        (uint32_t)(sizeof(barriers) / sizeof(barriers[0]));
    ProtectorRoom room;
    CHECK(protector_room_init(&room, &definition));

    advance(
        &room,
        &definition,
        (ProtectorRoomInput){.move_x = 1.0f, .move_z = 0.5f},
        20u
    );
    CHECK(
        room.player.position.x <=
        1.0f - PROTECTOR_ROOM_PLAYER_COLLISION_RADIUS + 0.001f
    );
    CHECK(room.player.position.z > 1.0f);
    CHECK(room.barrier_query_count == 20u);
    CHECK(room.barrier_contact_count > 0u);
}

static void test_enemy_attack_slot_has_visible_windup(void) {
    const ProtectorRoomDefinition definition = fixture_definition();
    ProtectorRoom room;
    CHECK(protector_room_init(&room, &definition));
    room.encounter_started = true;
    room.player.position = (ProtectorVec3){4.0f, 0.0f, 0.0f};
    for (uint32_t index = 0; index < room.enemy_count; ++index) {
        room.enemies[index].position =
            (ProtectorVec3){4.5f + 0.2f * (float)index, 0.0f, 0.0f};
        room.enemies[index].active = true;
    }

    protector_room_step(&room, &definition, (ProtectorRoomInput){0});
    CHECK(fabsf(room.player.health - 100.0f) < 0.0001f);
    CHECK(
        room.enemies[0].attack_windup_ticks ==
        PROTECTOR_ROOM_ENEMY_ATTACK_WINDUP_TICKS
    );
    CHECK(room.enemies[1].attack_windup_ticks == 0u);

    advance(
        &room,
        &definition,
        (ProtectorRoomInput){0},
        PROTECTOR_ROOM_ENEMY_ATTACK_WINDUP_TICKS
    );
    CHECK(fabsf(room.player.health - 92.0f) < 0.0001f);
    CHECK(
        room.enemies[0].attack_cooldown_ticks ==
        PROTECTOR_ROOM_ENEMY_ATTACK_COOLDOWN_TICKS
    );
    CHECK(room.enemies[1].attack_cooldown_ticks == 0u);
}

static void test_progression_gate_releases_after_encounter_clear(void) {
    static const ProtectorCollisionTriangle gate[] = {
        {
            .a = {1.0f, 0.0f, -2.0f},
            .b = {1.0f, 3.0f, -2.0f},
            .c = {1.0f, 0.0f, 2.0f},
        },
        {
            .a = {1.0f, 3.0f, -2.0f},
            .b = {1.0f, 3.0f, 2.0f},
            .c = {1.0f, 0.0f, 2.0f},
        },
    };
    ProtectorRoomDefinition definition = fixture_definition();
    definition.encounter_center = (ProtectorVec3){8.0f, 0.0f, 8.0f};
    definition.encounter_radius = 1.0f;
    definition.gate_barrier_triangles = gate;
    definition.gate_barrier_triangle_count =
        (uint32_t)(sizeof(gate) / sizeof(gate[0]));
    ProtectorRoom room;
    CHECK(protector_room_init(&room, &definition));

    advance(
        &room,
        &definition,
        (ProtectorRoomInput){.move_x = 1.0f},
        10u
    );
    CHECK(
        room.player.position.x <=
        1.0f - PROTECTOR_ROOM_PLAYER_COLLISION_RADIUS + 0.001f
    );
    room.living_enemy_count = 0u;
    advance(
        &room,
        &definition,
        (ProtectorRoomInput){.move_x = 1.0f},
        10u
    );
    CHECK(room.player.position.x > 1.0f);
}

static void test_deterministic_input_replay(void) {
    const ProtectorRoomDefinition definition = fixture_definition();
    ProtectorRoom first;
    ProtectorRoom second;
    CHECK(protector_room_init(&first, &definition));
    CHECK(protector_room_init(&second, &definition));

    for (uint32_t tick = 0; tick < PROTECTOR_ROOM_TICK_RATE * 20u; ++tick) {
        ProtectorRoomInput input = {
            .move_x = tick % 90u < 45u ? 0.8f : -0.4f,
            .move_z = tick % 120u < 60u ? 0.25f : -0.35f,
        };
        if (tick == 1u) {
            input.pressed |= PROTECTOR_ACTION_JUMP;
        }
        if (tick == 2u) {
            input.pressed |= PROTECTOR_ACTION_TRANSFORM;
        }
        if (tick % 30u == 0u) {
            input.pressed |= PROTECTOR_ACTION_ATTACK_HEAVY;
        }
        protector_room_step(&first, &definition, input);
        protector_room_step(&second, &definition, input);
        protector_room_record_frame_time(&first, 2100u + tick % 7u);
        protector_room_record_frame_time(&second, 2100u + tick % 7u);
    }
    CHECK(memcmp(&first, &second, sizeof(first)) == 0);
}

static void test_source_camera_pose_and_camera_relative_input(void) {
    ProtectorRoomDefinition definition = fixture_definition();
    definition.camera_path_point_count = 2;
    definition.camera_path_points[0] = (ProtectorCameraPathPoint){
        .position = {0.0f, 0.0f, -4.0f},
        .distance = 16.0f,
        .height = 20.0f,
    };
    definition.camera_path_points[1] = (ProtectorCameraPathPoint){
        .position = {10.0f, 0.0f, -4.0f},
        .distance = 16.0f,
        .height = 20.0f,
    };
    ProtectorCameraPose pose = {0};
    CHECK(
        protector_room_camera_pose(
            &definition,
            (ProtectorVec3){2.0f, 0.0f, 0.0f},
            &pose
        )
    );
    CHECK(fabsf(pose.eye.x - 2.0f) < 0.0001f);
    CHECK(fabsf(pose.eye.y - 7.52444f) < 0.0001f);
    CHECK(fabsf(pose.eye.z - 20.67324f) < 0.0001f);
    CHECK(fabsf(pose.target.x - 2.0f) < 0.0001f);
    CHECK(fabsf(pose.target.y) < 0.0001f);
    CHECK(fabsf(pose.target.z) < 0.0001f);
    CHECK(fabsf(fabsf(pose.yaw_radians) - (float)M_PI) < 0.0001f);
    CHECK(pose.segment_index == 0);

    const ProtectorRoomInput up = protector_room_camera_relative_input(
        (ProtectorRoomInput){.move_z = 1.0f},
        &pose
    );
    CHECK(fabsf(up.move_x) < 0.0001f);
    CHECK(fabsf(up.move_z + 1.0f) < 0.0001f);
    const ProtectorRoomInput right = protector_room_camera_relative_input(
        (ProtectorRoomInput){.move_x = 1.0f},
        &pose
    );
    CHECK(fabsf(right.move_x - 1.0f) < 0.0001f);
    CHECK(fabsf(right.move_z) < 0.0001f);
}

static void test_directional_targeting_rejects_enemy_behind_player(void) {
    const ProtectorRoomDefinition definition = fixture_definition();
    ProtectorRoom room;
    CHECK(protector_room_init(&room, &definition));
    room.encounter_started = true;
    room.player.position = (ProtectorVec3){0.0f, 0.0f, 0.0f};
    room.player.facing_radians = 0.0f;
    room.enemies[0].position = (ProtectorVec3){0.2f, 0.0f, 2.2f};
    room.enemies[0].active = true;
    room.enemies[1].position = (ProtectorVec3){0.0f, 0.0f, -1.0f};
    room.enemies[1].active = true;

    ProtectorTargetInfo target = {0};
    CHECK(protector_room_target_info(&room, &target));
    CHECK(target.enemy_index == 0);
    CHECK(target.within_light_range);
    CHECK(target.within_heavy_range);
    CHECK(fabsf(target.signed_angle_radians) < 0.1f);

    protector_room_step(
        &room,
        &definition,
        (ProtectorRoomInput){.pressed = PROTECTOR_ACTION_ATTACK_LIGHT}
    );
    CHECK(fabsf(room.enemies[0].health - 2.0f) < 0.0001f);
    CHECK(fabsf(room.enemies[1].health - 3.0f) < 0.0001f);
    CHECK(room.player.facing_radians > 0.0f);
    CHECK(room.player.facing_radians < 0.2f);

    room.enemies[0].alive = false;
    room.enemies[1].position = (ProtectorVec3){0.0f, 0.0f, -0.2f};
    CHECK(protector_room_target_info(&room, &target));
    CHECK(target.enemy_index == 1u);
    CHECK(fabsf(target.signed_angle_radians) < 0.0001f);
}

int main(void) {
    test_fixed_step_player_actions();
    test_pause_save_load_resume();
    test_encounter_and_full_gate();
    test_frame_metrics_and_ten_minute_idle_soak();
    test_source_walkable_collision_and_audio_queue();
    test_source_barrier_collision_blocks_and_slides();
    test_enemy_attack_slot_has_visible_windup();
    test_progression_gate_releases_after_encounter_clear();
    test_deterministic_input_replay();
    test_source_camera_pose_and_camera_relative_input();
    test_directional_targeting_rejects_enemy_behind_player();

    if (failures) {
        fprintf(stderr, "%d room runtime tests failed\n", failures);
        return 1;
    }
    puts("protector room runtime tests passed");
    return 0;
}
