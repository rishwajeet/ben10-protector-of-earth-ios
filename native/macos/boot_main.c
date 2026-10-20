#include "protector/ax.h"
#include "protector/ax_engine.h"
#include "protector/ax_diagnostics.h"
#include "protector/cpu.h"
#include "protector/full_state.h"
#include "protector/live_gx.h"
#include "protector/motion_identity.h"
#include "protector/visibility.h"
#include "protector/live_input.h"
#include "protector/platform.h"
#include "protector/save_store.h"
#include "protector/runtime_result.h"
#include "protector/ui_text.h"
#include "protector/ui_context.h"
#include "protector/tutorial_context.h"
#include "protector/interaction_context.h"
#include "protector/ui_copy.h"
#include "protector/script_flow.h"
#if !defined(PROTECTOR_BOOT_DISPATCH_TEST)
#include "RBNEG9.h"
#endif

#include <inttypes.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define RBNEG9_ENTRY 0x8000403Cu
#define FIRST_ASSET_REQUEST 0x800169C4u
#define GAME_FRAME_LOOP_BACKEDGE 0x80039868u
#define GAME_LOGICAL_UPDATE_POST_STORE 0x800372E0u
#define GAME_FRAME_TIMING_FINALIZED 0x800396E8u
#define GAME_LOGICAL_UPDATE_ENTRY 0x800396ECu
#define GAME_LOGICAL_UPDATE_CHECKPOINT 0x80039774u
#define GX_END_FRAME_WRITE 0x800E61A8u
#define GAME_CONTROLLER_MANAGER_CALL 0x8000E3FCu
#define GAME_CONTROLLER_MANAGER_UPDATE 0x8000F910u
#define GAME_CONTROLLER_MANAGER 0x80446F20u
#define GAME_CONTROLLER_OBJECT 0x80446FB0u
#define GAME_CONTROLLER_RECONCILE 0x8000F9B8u
#define GAME_CONTROLLER_UPDATE 0x800B5A44u
#define GAME_CONTROLLER_UPDATE_CALL 0x8000F988u
#define GAME_CONTROLLER_POST_KPAD 0x800B5ACCu
#define GAME_SAVE_PACKAGED_ASSET_LOAD 0x800B8BC8u
#define GAME_SAVE_METADATA_INIT 0x800B8D38u
#define GAME_SAVE_OBJECT_CONSTRUCTOR 0x800B917Cu
#define GAME_SAVE_MANAGER_INIT 0x800B91D8u
#define GAME_SAVE_ASYNC_LOAD 0x800B9264u
#define GAME_SAVE_SCRIPT_LOAD 0x800B493Cu
#define GAME_SAVE_SCRIPT_SAVE 0x800B4928u
#define GAME_SAVE_SCRIPT_LOAD_SLOT 0x800B4994u
#define GAME_SAVE_SCRIPT_SAVE_SLOT 0x800B4950u
#define GAME_SCRIPT_VM_DISPATCH 0x800A74E4u
#define GAME_SCRIPT_BUILTIN_CALL_1 0x800A92D0u
#define GAME_SCRIPT_BUILTIN_CALL_2 0x800A92ECu
#define GAME_SCRIPT_BUILTIN_CALL_3 0x800A9308u
#define GAME_SCRIPT_BUILTIN_CALL_4 0x800A933Cu
#define GAME_ANIM_LOOPED 0x8003E5ECu
#define GAME_ANIM_BLEND_WEIGHT 0x8003E62Cu
#define GAME_ANIM_BLEND 0x8003E74Cu
#define GAME_ANIM_LENGTH 0x8003E7B4u
#define GAME_ANIMATING_NEXT_FRAME 0x8003E814u
#define GAME_ANIM_BLENDING_OUT 0x8003E850u
#define GAME_ANIM_PLAYING 0x8003E8FCu
#define GAME_ANIM_PLAYING_RESULT 0x8003E91Cu
#define GAME_ANIM_TIME 0x8003E934u
#define GAME_ANIM_TIME_RESULT 0x8003E960u
#define GAME_ANIM_WEIGHT 0x8003E988u
#define GAME_SCRIPT_PROPERTY_QUERY 0x80094688u
#define GAME_SCRIPT_PROPERTY_QUERY_RETURN 0x8004A76Cu
#define GAME_SCRIPT_GLOBAL_WRITE 0x800A858Cu
#define GAME_SCRIPT_EVENT_DISPATCH 0x8009D1DCu
#define GAME_SCRIPT_EVENT_NODE_CREATE 0x800A1150u
#define GAME_SCRIPT_EVENT_NODE_CREATE_RETURN 0x8009D298u
#define GAME_COLLISION_EVENT_SCAN 0x8009D10Cu
#define GAME_COLLISION_EVENT_NODE_CREATE 0x800A130Cu
#define GAME_COLLISION_EVENT_HEAD_STORE 0x8009D1B4u
#define GAME_COLLISION_EVENT_HANDLER_ATTACK 0x92EC0F84u
#define GAME_RANDOM_NEXT 0x800ADBD4u
#define GAME_RANDOM_VECTOR 0x80057DFCu
#define GAME_RANDOM_STREAM_COUNT 0x8030D4F0u
#define GAME_RANDOM_STREAM_TABLE_POINTER 0x8030D4FCu
#define GAME_RANDOM_STREAM_STRIDE 0x24u
#define GAME_RANDOM_REPLAY_STATE_COUNT 8u
#define GAME_STREAM_LOADER 0x804527D0u
#define GAME_SCRIPT_SPAWN_RETURN 0x800492E8u
#define GAME_DVD_STREAM_READ_CALLBACK 0x80011834u
#define GAME_RESOURCE_MANAGER_POLL 0x8017EF44u
#define GAME_RESOURCE_DESCRIPTOR_BASE 0x808C1B54u
#define GAME_RESOURCE_DESCRIPTOR_STRIDE 0x34u
#define GAME_RESOURCE_DESCRIPTOR_COUNT 8u
#define GAME_VOICE_MANAGER 0x8083C43Cu
#define GAME_VOICE_SLOT_BASE (GAME_VOICE_MANAGER + 148u)
#define GAME_AX_CPU_PB_POOL 0x8029A6E0u
#define GAME_AX_CPU_PB_SIZE 0x168u
#define GAME_AX_DSP_PB_POOL 0x802916E0u
#define GAME_AX_DSP_PB_SIZE 0x140u
#define GAME_AX_DIAGNOSTIC_SLOT 85u
#define GAME_SOUND_PLAY_RESULT 0x80067E14u
#define GAME_SOUND_MANAGER_PLAY 0x8006DB68u
#define GAME_SOUND_MANAGER_ALLOCATION_RESULT 0x8006DF9Cu
#define GAME_IS_PLAYER_BIND 0x80049B20u
#define GAME_IS_CAMERA_BIND 0x80049B2Cu
#define GAME_ROTATION_APPLY 0x8004B874u
#define GAME_ROTATION_BLEND 0x800A700Cu
#define GAME_SAVE_OBJECT_POINTER 0x8025699Cu
#define GAME_INPUT_STATE_POINTER 0x80256990u
#define GAME_SCRIPT_MANAGER_POINTER 0x8030D140u
#define GAME_SCRIPT_MANAGER_PLAYER_OFFSET 0x201Cu
#define GAME_SCRIPT_MANAGER_CAMERA_OFFSET 0x2020u
#define GAME_SCRIPT_UPDATE_ENABLED 0x80309FC0u
#define GAME_STRAT_POSITION_OFFSET 0x180u
#define GAME_STRAT_TRANSFORM_SIZE 0x30u
#define GAME_STRAT_OBJECT_SNAPSHOT_SIZE 0x200u
#define GAME_STRAT_OBJECT_BLOCK_SIZE 0x20u
#define GAME_STRAT_OBJECT_BLOCK_COUNT \
    (GAME_STRAT_OBJECT_SNAPSHOT_SIZE / GAME_STRAT_OBJECT_BLOCK_SIZE)
#define GAME_STRAT_OBJECT_PROBE_BLOCK_COUNT 5u
#define GAME_STRATEGY_CONTEXT_POOL_START 0x80770000u
#define GAME_STRATEGY_CONTEXT_POOL_END 0x80790000u
#define GAME_FRAME_DELTA_MICROSECONDS 0x80256A14u
#define GAME_GLOBAL_UPDATE_COUNTER 0x80256A28u
#define GAME_ROOT_SCRIPT_VARIABLES 0x9041ECE0u
#define GAME_TITLE_SCRIPT_CONTEXT 0x80780790u
#define GAME_TITLE_SCRIPT_VARIABLES 0x90420B50u
#define GAME_TRANSITION_SCRIPT_CONTEXT 0x80780420u
#define GAME_TRANSITION_SCRIPT_LOOP 0x9038F6E0u
#define GAME_SCRIPT_CONTEXT_IP_OFFSET 464u
#define GAME_WII_STRAP_SCRIPT_START 0x92F1DA80u
#define GAME_WII_STRAP_SCRIPT_SIZE 0x898u
#define GAME_WII_STRAP_LOOP_START 0x92F1E170u
#define WII_SDK_DISABLE_WRITE_GATHER_PIPE 0x800C1D00u
#define WII_SDK_OS_INIT_STM 0x800CA404u
#define WII_SDK_OS_INIT_PLAY_TIME 0x800CAD98u
#define WII_SDK_OS_INIT_NET 0x800CB1E0u
#define WII_SDK_DVD_READ_PRIO 0x800CCBC0u
#define WII_SDK_DVD_READ_ASYNC_PRIO 0x800CCAD8u
#define WII_SDK_DVD_SEEK_ASYNC_PRIO 0x800CCCF0u
#define WII_SDK_DVD_COMMAND_BLOCK_CALLBACK 0x800CCBA8u
#define WII_SDK_DVD_SEEK_BLOCK_CALLBACK 0x800CCD90u
#define WII_SDK_DVD_INIT 0x800CCE60u
#define WII_SDK_DVD_CLEAR_WAITING_QUEUE 0x800D15A0u
#define WII_SDK_VI_WAIT_FOR_RETRACE 0x800D49A4u
#define WII_SDK_AX_OUT_NEW_FRAME 0x800DB83Cu
#define WII_SDK_AX_SYNC_PBS 0x800DC9A0u
#define WII_SDK_DSP_ADD_TASK 0x800E2BE4u
#define WII_SDK_SC_INIT 0x8010AB8Cu
#define WII_SDK_SC_CHECK_STATUS 0x8010AC2Cu
#define WII_SDK_SC_GET_ASPECT_RATIO 0x8010C4F0u
#define WII_SDK_NAND_GET_STATUS 0x801090A8u
#define WII_SDK_NAND_OPEN 0x801095D4u
#define WII_SDK_NAND_CLOSE 0x80109854u
#define WII_SDK_NAND_INIT 0x80109EC4u
#define WII_SDK_OS_INIT_PLAY_TIME_AFTER_NAND_INIT 0x800CADA8u
#define GAME_SAVE_ASYNC_LOAD_AFTER_NAND_OPEN 0x800B92B4u
#define GAME_SAVE_ASYNC_LOAD_AFTER_NAND_GET_STATUS 0x800B9364u
#define WII_SDK_KPAD_READ 0x8010F540u
#define WII_SDK_WPAD_PROBE 0x801134E0u
#define WII_SDK_WPAD_READ 0x8011356Cu
#define WII_SDK_WUD_INIT 0x8014CCCCu
#define WII_SDK_WUD_GET_STATUS 0x8014CF9Cu
#define WII_SDK_IUSB_OPEN_DEVICE_IDS 0x8014FF88u
#define WII_SDK_BINK_OPEN 0x80182AE0u
#define WII_OS_DECREMENTER_HANDLER 0x800C1624u
#define WII_OS_LOAD_CONTEXT 0x800C26C8u
#define WII_OS_RESCHEDULE 0x800C8EE8u
#define WII_OS_SLEEP_THREAD 0x800C99D0u
#define WII_OS_CURRENT_CONTEXT 0x800000D4u
#define WII_OS_IDLE_WAIT 0x800C8E0Cu
#define WII_OS_INTERRUPT_TABLE 0x80003040u
#define WII_VI_RETRACE_HANDLER 0x800D38ACu
#define WII_TIMEBASE_HZ 60750000u
#define WII_AX_FRAME_TIMEBASE_TICKS (WII_TIMEBASE_HZ * 3u / 1000u)
#define RBNEG9_AX_DSP_TASK 0x802915C0u
#define RBNEG9_AX_TIMEBASE_PHASE 477u
#define GX_FIFO_REGISTER 0x008000u
#define GX_PE_INTERRUPT_CONTROL 0x00100Au
#define GX_PE_FINISH_COMMAND 0x45000002u
#define GX_PE_FINISH_INTERRUPT 19u
#define VI_INTERRUPT_REGISTER_0 0x002030u
#define VI_INTERRUPT_REGISTER_1 0x002034u
#define VI_INTERRUPT_REGISTER_2 0x002038u
#define VI_INTERRUPT_REGISTER_3 0x00203Cu
#define AI_CONTROL_REGISTER 0x006C00u
#define AI_VOLUME_REGISTER 0x006C04u
#define AI_SAMPLE_COUNTER 0x006C08u
#define AI_INTERRUPT_TIMING 0x006C0Cu
#define DSP_MAIL_TO_DSP_HI 0x005000u
#define DSP_MAIL_TO_DSP_LO 0x005002u
#define DSP_MAIL_FROM_DSP_HI 0x005004u
#define DSP_MAIL_FROM_DSP_LO 0x005006u
#define IPC_PPC_MESSAGE 0x000000u
#define IPC_PPC_CONTROL 0x000004u
#define IPC_ARM_MESSAGE 0x000008u
#define IPC_PPC_IRQ_FLAG 0x000030u
#define IPC_INTERRUPT 27u
#define TRACE_RING_SIZE 64u
#define DISPATCH_BREADCRUMB_SIZE 256u
#define KPAD_STATUS_SIZE 132u
#define FNV1A64_OFFSET UINT64_C(14695981039346656037)
#define FNV1A64_PRIME UINT64_C(1099511628211)
#define GX_CAPTURE_MAGIC "PGXF"
#define GX_MEMORY_MAGIC "PGXM"
#define SYNC_MEMORY_MAGIC "PSXM"
#define CHECKPOINT_MEMORY_MAGIC "PCMR"
#define CHECKPOINT_MEMORY_VERSION 1u
#define CHECKPOINT_MEMORY_REGION_CAPACITY 1024u
#define GX_MEMORY_VERSION 1u
#define DVD_ASYNC_STACK_SIZE 32u
#define DVD_ASYNC_CALLBACK_QUEUE_SIZE 64u
#define DVD_COMPLETION_REPLAY_CAPACITY 2048u
#define STRATEGY_VM_REPLAY_CAPACITY 512u
#define DVD_ASYNC_STARTUP_LATENCY_FRAMES 5u
#define DVD_STREAM_NEAR_SEEK_WORDS 0x00002000u
#define DVD_STREAM_MEDIUM_SEEK_WORDS 0x00200000u
#define DVD_STREAM_FAR_SEEK_WORDS 0x04000000u
#define DVD_STREAM_MOVIE_HANDOFF_FRAMES 3u
#define PERF_FRAME_SAMPLE_CAPACITY 2048u
#define SYNC_INPUT_SAMPLE_CAPACITY 8192u
#define SCRIPT_VM_RING_SIZE 32u
#define SCRIPT_SPAWN_VM_FRAME_SIZE 128u
#define SCRIPT_TRANSITION_PROBE_RING_SIZE 1024u
#define SCRIPT_LOOP_RING_SIZE 16u
#define KPAD_SCHEDULED_PULSE_CAPACITY 64u
#define GAMEPLAY_OBSERVABLE_COUNT 35u
#define GAMEPLAY_OBSERVABLE_GROUND_COLLISION 0u
#define GAMEPLAY_OBSERVABLE_WALL_COLLISION 2u
#define GAMEPLAY_OBSERVABLE_SET_SKELETON 25u
#define GAMEPLAY_OBSERVABLE_SET_POSITION 18u
#define GAMEPLAY_OBSERVABLE_RESET_POSITION 19u
#define GAMEPLAY_OBSERVABLE_CREATE_TRIGGER 20u
#define GAMEPLAY_OBSERVABLE_SPAWN_AFTER 26u
#define GAMEPLAY_OBSERVABLE_SPAWN_AFTER_S 27u
#define GAMEPLAY_SPAWN_AFTER_RETURN 0x80049414u
#define GAMEPLAY_VM_OWNER_POINTER_ASSIGN 0x8009E774u
#define GAMEPLAY_VM_OWNER_POINTER_CLEAR 0x8009E4ECu
#define GAMEPLAY_SPAWN_OUTPUT_CAPACITY 64u
#define GAMEPLAY_SCRIPT_VM_STATE_SIZE 0x400u
#define GAMEPLAY_OBJECT_CURRENT_TRANSFORM_OFFSET 0x180u
#define GAMEPLAY_OBJECT_SAVED_TRANSFORM_OFFSET 0x1F0u
#define GAMEPLAY_OBJECT_TRANSFORM_SIZE 0x30u
#define IOS_COMMAND_OPEN 1u
#define IOS_COMMAND_CLOSE 2u
#define IOS_COMMAND_READ 3u
#define IOS_COMMAND_WRITE 4u
#define IOS_COMMAND_SEEK 5u
#define IOS_COMMAND_IOCTL 6u
#define IOS_COMMAND_IOCTLV 7u
#define IOS_FS_GET_ATTR 6u
#define IOS_FS_CREATE_FILE 9u
#define IOS_FS_GET_FILE_STATS 11u
#define IOS_ERROR_NO_ENTRY (-106)
#define SAVED_GAMES_PATH "/SavedGames"
#define SAVE_BANNER_PATH "/banner.bin"
#define NATIVE_NAND_FILE_COUNT 2u

typedef struct SyncInputSample {
    u32 hold;
    u32 trigger;
    u32 release;
    u32 nunchuk_stick_x_bits;
    u32 nunchuk_stick_y_bits;
    u32 motion_bits[10];
    u8 device_type;
    u8 wpad_error;
    u8 dpd_valid;
    u8 data_format;
    bool has_nunchuk_stick;
    bool has_motion;
} SyncInputSample;

typedef struct ScheduledKpadPulse {
    u64 checkpoint;
    u32 mask;
} ScheduledKpadPulse;

static const u32 GAMEPLAY_OBSERVABLE_ADDRESSES[
    GAMEPLAY_OBSERVABLE_COUNT
] = {
    0x80040C78u, 0x80040C34u, 0x80040C2Cu, 0x80040C24u,
    0x80040C1Cu, 0x8004073Cu, 0x80059DE8u, 0x8004B96Cu,
    0x8004B874u, 0x80048E4Cu, 0x80048D50u, 0x80048C48u,
    0x80056D8Cu, 0x80057048u, 0x800565C8u, 0x8004A620u,
    0x8004A8A0u, 0x8004A800u, 0x8004A060u, 0x80049FE4u,
    0x80049FCCu, 0x80049FB4u, 0x8003F128u, 0x8003EE90u,
    0x8003EE84u, 0x8003E5CCu, 0x800493CCu, 0x80049294u,
    0x80046248u, 0x80067AD0u, 0x8004911Cu, 0x8005B1B4u,
    0x8005AFF0u, 0x8005B2B8u, 0x8005B2A4u,
};
static const char* const GAMEPLAY_OBSERVABLE_NAMES[
    GAMEPLAY_OBSERVABLE_COUNT
] = {
    "ground_collision",
    "ground_collision_v",
    "wall_collision",
    "wall_collision_xz",
    "wall_collision_y_factor",
    "ray_cast_to",
    "collision_radius",
    "turn_to_strat_y",
    "turn_to_angle_y",
    "first_strat_range_f",
    "next_strat_range_f",
    "first_strat_n",
    "angle_to",
    "angle_diff",
    "distance_strat",
    "inside_region_ss",
    "get_strat_region",
    "force_inside_region",
    "set_position",
    "reset_position",
    "create_trigger",
    "remove_trigger",
    "anim_play",
    "anim_play_loop",
    "anim_stop",
    "set_skeleton",
    "spawn_after",
    "spawn_after_s",
    "send_by_strat_ptr",
    "sound_play_1",
    "remove",
    "stream_wad",
    "remove_wad",
    "wad_layer",
    "wad_layer_this",
};

typedef struct NativeNandFile {
    bool exists;
    bool open;
    bool dirty;
    u8* data;
    size_t size;
    size_t capacity;
    size_t offset;
} NativeNandFile;

typedef struct DvdAsyncCallbackEvent {
    u32 callback;
    u32 result;
    u32 file_info;
    u32 destination;
    u32 request_user_data;
    u32 request_r30;
    u64 request_serial;
    u64 ready_frame;
    u64 ready_order;
    bool payload_started;
    bool sync_trace_anchor_completion;
    ProtectorFileRead file_read;
} DvdAsyncCallbackEvent;

typedef struct DvdCompletionReplayEntry {
    u64 request_serial;
    u64 requested_frame;
    u64 ready_frame;
    u64 path_fnv1a64;
    u32 file_offset;
    u32 requested_length;
    bool consumed;
} DvdCompletionReplayEntry;

typedef struct StrategyVmReplayEntry {
    u32 context;
    u32 script_base;
    u32 instruction_pointer;
    u32 register_0;
} StrategyVmReplayEntry;

typedef struct MmioEvent {
    u32 pc;
    u32 address;
    u32 value;
    u8 size;
    bool write;
} MmioEvent;

typedef struct DispatchBreadcrumb {
    u32 address;
    u32 lr;
    u32 r1;
    u32 r3;
    u32 r4;
} DispatchBreadcrumb;

typedef struct ContextLoadEvent {
    u32 context;
    u32 resume_pc;
    u32 stack_pointer;
} ContextLoadEvent;

typedef struct ContextSummary {
    u32 context;
    u32 last_resume_pc;
    u32 last_stack_pointer;
    u64 load_count;
} ContextSummary;

typedef struct SleepEvent {
    u32 context;
    u32 queue;
    u32 caller;
} SleepEvent;

typedef struct ScriptVmEvent {
    u32 instruction_pointer;
    u32 instruction;
    u32 context;
    u32 base29;
    u32 base30;
    u32 base31;
} ScriptVmEvent;

typedef struct ScriptLoopEvent {
    u64 completed_frame;
    u32 values[11];
} ScriptLoopEvent;

typedef struct ScriptTransitionProbeEvent {
    u64 completed_frame;
    u32 instruction_pointer;
    u32 ui_manager;
    u8 ui_manager_flag;
    u32 values[16];
} ScriptTransitionProbeEvent;

typedef struct ScriptGlobalWriteEvent {
    u64 completed_frame;
    u32 context;
    u32 instruction_pointer;
    u32 value;
    u32 input_state;
    u32 input_hold;
    u32 input_trigger;
    u32 input_release;
    u32 script_manager;
    u32 script_input_hold;
    u32 script_input_trigger;
    u32 script_input_release;
    u32 root_input_hold;
    u32 root_input_trigger;
    u32 root_input_release;
} ScriptGlobalWriteEvent;

typedef struct SavedExecutionState {
    u32 gpr[32];
    f64 fpr[32];
    f64 ps1[32];
    u32 pc;
    u32 lr;
    u32 ctr;
    u32 cr;
    u32 xer;
    u32 fpscr;
    u32 msr;
    u32 srr0;
    u32 srr1;
    u32 ear;
    u32 hid2;
    u32 reservation_address;
    bool reservation_valid;
} SavedExecutionState;

typedef struct GameplayCallSignature {
    u32 gpr[32];
    u32 lr;
    u32 ctr;
    u64 object_transform_hash;
    u64 script_vm_state_hash;
    bool object_transform_valid;
    bool script_vm_state_valid;
    bool valid;
} GameplayCallSignature;

typedef struct BootTrace {
    jmp_buf dispatch_abort;
    bool dispatch_active;
    u64 host_call_count;
    u32 last_host_call;
    u32 host_call_ring[TRACE_RING_SIZE];
    u64 dispatch_breadcrumb_count;
    DispatchBreadcrumb
        dispatch_breadcrumbs[DISPATCH_BREADCRUMB_SIZE];
    u64 stub_count;
    u32 last_stub;
    u64 platform_stub_counts[12];
    u64 dsp_add_task_stub_count;
    u64 kpad_read_count;
    u64 kpad_neutral_sample_count;
    u64 kpad_non_neutral_sample_count;
    u64 kpad_pulse_sample_count;
    u32 kpad_last_channel;
    u32 kpad_last_buffer;
    u32 kpad_last_capacity;
    u32 kpad_last_hold;
    u32 kpad_last_trigger;
    u32 kpad_last_release;
    u8 kpad_status_template[KPAD_STATUS_SIZE];
    bool kpad_status_template_valid;
    u32 kpad_pulse_mask;
    u64 kpad_pulse_start;
    u64 kpad_pulse_interval;
    ScheduledKpadPulse
        kpad_scheduled_pulses[KPAD_SCHEDULED_PULSE_CAPACITY];
    u32 kpad_scheduled_pulse_count;
    u64 frame_loop_count;
    u64 dispatch_blocks_started;
    u64 guest_instructions_completed;
    bool perf_frame_started;
    u64 perf_previous_host_ns;
    u64 perf_previous_blocks;
    u64 perf_previous_guest_instructions;
    u32 perf_frame_sample_count;
    u64 perf_host_ns[PERF_FRAME_SAMPLE_CAPACITY];
    u64 perf_blocks[PERF_FRAME_SAMPLE_CAPACITY];
    u64 perf_guest_instructions[PERF_FRAME_SAMPLE_CAPACITY];
    u64 game_controller_manager_update_count;
    u64 game_controller_reconcile_count;
    u32 game_controller_manager;
    s32 game_controller_slot_states[8];
    s8 game_controller_connection_states[4];
    bool controller_connected;
    bool controller_connection_seeded;
    u64 controller_connection_seed_count;
    u64 game_controller_update_count;
    u64 game_controller_post_kpad_count;
    u32 game_controller_post_kpad_result;
    u64 game_controller_post_kpad_hash;
    u64 wpad_probe_count;
    u64 wpad_read_count;
    u64 bink_open_count;
    ProtectorCinematicTracker cinematic;
    u64 save_packaged_asset_load_count;
    u64 save_metadata_init_count;
    u64 save_object_constructor_count;
    u64 save_manager_init_count;
    u64 save_async_load_count;
    u32 save_async_load_last_caller;
    u32 save_async_load_last_object;
    u8 save_async_load_last_enabled;
    u64 save_script_load_count;
    u32 save_script_load_last_r3;
    u32 save_script_load_last_r4;
    u32 save_script_load_last_context;
    u32 save_script_load_last_instruction_pointer;
    u32 save_script_load_last_instruction;
    u32 save_script_load_last_base29;
    u32 save_script_load_last_base30;
    u32 save_script_load_last_base31;
    u64 save_script_save_count;
    u64 save_script_load_slot_count;
    u64 save_script_save_slot_count;
    u64 script_vm_dispatch_count;
    u64 script_vm_wii_strap_dispatch_count;
    u32 script_vm_last_instruction_pointer;
    u32 script_vm_last_instruction;
    u32 script_vm_last_context;
    u32 script_vm_last_base29;
    u32 script_vm_last_base30;
    u32 script_vm_last_base31;
    u32 script_vm_min_instruction_pointer;
    u32 script_vm_max_instruction_pointer;
    ScriptVmEvent script_vm_ring[SCRIPT_VM_RING_SIZE];
    u64 script_event_dispatch_count;
    u32 script_event_dispatch_object;
    u32 script_event_dispatch_id;
    u32 script_event_dispatch_kind;
    u32 script_event_dispatch_payload;
    u64 script_event_node_create_count;
    u32 script_event_node_list;
    u32 script_event_node_handler;
    u32 script_event_node_context;
    u32 script_event_node_owner;
    u32 script_event_node_result;
    u64 script_spawn_count;
    u32 script_spawn_object;
    u32 script_spawn_handle;
    u32 r2_root_wait_spawn_object;
    u32 sync_frame_script_spawn_vm_dispatch_count;
    u32 sync_frame_script_spawn_vm_first_instruction_pointer;
    u32 sync_frame_script_spawn_vm_last_instruction_pointer;
    u32 sync_frame_script_spawn_vm_last_instruction;
    ScriptVmEvent
        sync_frame_script_spawn_vm_events[SCRIPT_SPAWN_VM_FRAME_SIZE];
    u64 script_event_vm_dispatch_count;
    u32 sync_frame_script_event_vm_dispatch_count;
    u32 sync_frame_script_event_vm_last_instruction_pointer;
    u32 sync_frame_script_event_vm_last_instruction;
    u32 sync_frame_script_event_vm_last_base29;
    u32 sync_frame_script_event_vm_last_base30;
    u32 sync_frame_script_event_vm_last_base31;
    u64 script_wii_strap_loop_count;
    ScriptLoopEvent script_wii_strap_loop_ring[SCRIPT_LOOP_RING_SIZE];
    u64 script_transition_loop_count;
    ScriptLoopEvent script_transition_loop_ring[SCRIPT_LOOP_RING_SIZE];
    u64 script_transition_probe_count;
    ScriptTransitionProbeEvent
        script_transition_probe_ring[SCRIPT_TRANSITION_PROBE_RING_SIZE];
    u64 script_global_35_write_count;
    u64 script_global_35_nonzero_write_count;
    ScriptGlobalWriteEvent
        script_global_35_write_ring[SCRIPT_VM_RING_SIZE];
    ScriptGlobalWriteEvent
        script_global_35_nonzero_ring[SCRIPT_LOOP_RING_SIZE];
    u64 gx_fifo_write_count;
    ProtectorMotionIdentity motion_identity;
    u64 gx_fifo_byte_count;
    u64 gx_current_frame_write_count;
    u64 gx_current_frame_byte_count;
    u64 gx_current_frame_hash;
    u64 gx_completed_frame_count;
    u64 gx_last_frame_write_count;
    u64 gx_last_frame_byte_count;
    u64 gx_last_frame_hash;
    u64 gx_frame_hash_change_count;
    FILE* gx_capture_file;
    u8* gx_capture_frame;
    size_t gx_capture_frame_size;
    size_t gx_capture_frame_capacity;
    bool gx_capture_failed;
    bool live_gx_complete;
    const char* gx_memory_capture_path;
    u64 gx_memory_capture_frame;
    bool gx_memory_captured;
    bool gx_memory_capture_failed;
    const char* sync_memory_capture_path;
    u32 sync_memory_capture_frame;
    bool sync_memory_captured;
    bool sync_memory_capture_failed;
    FILE* sync_trace_file;
    u32 sync_trace_checkpoint_pc;
    u32 sync_trace_frame_limit;
    u32 sync_trace_frame_count;
    bool sync_trace_complete;
    bool sync_trace_failed;
    bool sync_trace_content_ready;
    bool imported_checkpoint;
    bool sync_trace_require_gameplay_bindings;
    bool sync_trace_gameplay_bindings_ready;
    bool sync_trace_binding_sample_valid;
    u64 sync_trace_binding_sample_gx_frame;
    u32 sync_trace_binding_sample_player;
    u32 sync_trace_binding_sample_camera;
    u64 sync_trace_binding_sample_player_hash;
    u64 sync_trace_binding_sample_camera_hash;
    bool motion_diagnostics;
    u32 frustum_audit_frame;
    bool enhanced_static_visibility;
    bool gameplay_call_diagnostics;
    bool dvd_async_diagnostics;
    u32 gameplay_call_state_context;
    u32 gameplay_call_state_start_frame;
    bool rng_checkpoint_diagnostics;
    u32 script_vm_diagnostic_context;
    FILE* ui_text_log;
    FILE* ui_context_log;
    u32 ui_context_log_count;
    bool ui_context_log_after_prompt;
    bool ui_context_log_prompt_seen;
    u64 ui_text_hashes[4096];
    u32 ui_text_count;
    u64 ui_text_rejected;
    bool ui_text_log_failed;
    bool native_ui_text;
    u64 native_ui_text_replacements;
    bool native_startup;
    ProtectorUIContextTracker ui_context;
    ProtectorTutorialTracker tutorial_context;
    ProtectorInteractionTracker interaction_context;
    const char* sync_trace_anchor_path;
    u64 sync_trace_start_gx_frame;
    u64 sync_frame_delta_start_gx_frame;
    SyncInputSample sync_input_samples[SYNC_INPUT_SAMPLE_CAPACITY];
    u32 sync_input_sample_count;
    u32 sync_frame_deltas[SYNC_INPUT_SAMPLE_CAPACITY];
    u32 sync_frame_delta_count;
    u32 sync_presentation_repeats[SYNC_INPUT_SAMPLE_CAPACITY];
    u32 sync_presentation_repeat_count;
    u32 sync_presentation_occurrence;
    bool sync_rng_replay_enabled;
    bool sync_rng_replay_applied;
    u32 sync_rng_replay_states[GAME_RANDOM_REPLAY_STATE_COUNT];
    bool sync_title_vm_register_0_replay_enabled;
    bool sync_title_vm_register_0_replay_applied;
    u32 sync_title_vm_register_0_replay_value;
    StrategyVmReplayEntry
        sync_strategy_vm_replay[STRATEGY_VM_REPLAY_CAPACITY];
    u32 sync_strategy_vm_replay_count;
    bool sync_strategy_vm_replay_applied;
    const char* sync_checkpoint_memory_replay_path;
    bool sync_checkpoint_memory_replay_applied;
    bool sync_checkpoint_memory_replay_failed;
    u32 sync_input_next_index;
    SyncInputSample sync_input_current;
    u32 sync_input_current_index;
    bool sync_input_current_valid;
    bool sync_input_has_non_neutral;
    u32 sync_frame_kpad_read_count;
    u32 sync_frame_kpad_first_caller;
    u32 sync_frame_kpad_last_caller;
    u32 sync_frame_controller_manager_call_count;
    u32 sync_frame_controller_manager_update_count;
    u32 sync_frame_controller_manager_update_callers[4];
    u32 sync_frame_controller_update_count;
    u32 sync_frame_controller_update_call_count;
    u32 sync_frame_controller_update_call_objects[4];
    u32 sync_frame_controller_update_call_slots[4];
    u32 sync_frame_controller_update_callers[4];
    u32 sync_frame_controller_update_objects[4];
    u32 sync_frame_controller_post_kpad_count;
    u32 sync_frame_controller_post_kpad_callers[4];
    u32 sync_frame_save_asset_load_count;
    u32 sync_frame_save_asset_load_caller;
    u32 sync_frame_save_metadata_init_count;
    u32 sync_frame_save_metadata_init_caller;
    u32 sync_frame_save_manager_init_count;
    u32 sync_frame_save_manager_init_caller;
    u32 sync_frame_save_script_load_count;
    u32 sync_frame_save_script_load_caller;
    u64 gameplay_observable_total[GAMEPLAY_OBSERVABLE_COUNT];
    u64 gameplay_observable_seen_total[GAMEPLAY_OBSERVABLE_COUNT];
    u32 sync_frame_gameplay_observable[GAMEPLAY_OBSERVABLE_COUNT];
    u64 sync_frame_gameplay_observable_hash[GAMEPLAY_OBSERVABLE_COUNT];
    GameplayCallSignature
        sync_frame_gameplay_last_signature[GAMEPLAY_OBSERVABLE_COUNT];
    u32 sync_frame_spawn_after_pending_count;
    u32 sync_frame_spawn_after_return_count;
    u32 sync_frame_spawn_after_return_values[GAMEPLAY_SPAWN_OUTPUT_CAPACITY];
    u32 sync_frame_spawn_output_count;
    u32 sync_frame_spawn_output_addresses[GAMEPLAY_SPAWN_OUTPUT_CAPACITY];
    s32 wud_status_result;
    u32 wud_status_first_caller;
    u32 wud_status_last_caller;
    u64 wud_status_caller_changes;
    u64 mmio_read_count;
    u64 mmio_write_count;
    u32 last_mmio_address;
    MmioEvent mmio_ring[TRACE_RING_SIZE];
    u64 mmio_event_count;
    u64 system_call_count;
    u32 last_system_call;
    u32 pi_interrupt_cause;
    u32 pi_interrupt_mask;
    u16 dsp_control;
    u32 dsp_mail_to_dsp;
    u32 dsp_mail_from_dsp;
    bool dsp_mail_to_dsp_pending;
    bool dsp_mail_from_dsp_pending;
    u64 dsp_boot_command_count;
    u32 dsp_task;
    u32 dsp_task_caller;
    u32 dsp_task_init_callback;
    u32 dsp_task_resume_callback;
    u32 dsp_task_done_callback;
    u32 dsp_task_request_callback;
    bool ax_emulation_enabled;
    bool ax_frame_armed;
    bool ax_frame_dispatch_active;
    u32 ax_dsp_pb_pool;
    u64 ax_next_frame_timebase;
    u64 ax_frame_interval_timebase;
    u64 ax_frame_count;
    u64 ax_fast_sync_frame_count;
    u64 ax_full_frame_count;
    u32 ax_last_running_voice_count;
    ProtectorAXEngine* ax_audio;
    FILE* ax_pcm_capture;
    ProtectorAXDiagnostics ax_diagnostics;
    bool ax_audio_failed;
    SavedExecutionState ax_interrupted_state;
    u32 ai_control;
    u32 ai_volume;
    u32 ai_sample_counter;
    u32 ai_interrupt_timing;
    u64 ai_counter_timebase;
    u64 ios_request_count;
    u64 nand_init_count;
    u64 nand_open_count;
    u64 nand_get_status_count;
    u64 nand_close_count;
    u32 nand_init_last_caller;
    u32 nand_open_last_caller;
    u32 nand_get_status_last_caller;
    u32 nand_close_last_caller;
    s32 nand_init_last_result;
    s32 nand_open_last_result;
    s32 nand_get_status_last_result;
    u32 last_ios_pc;
    u32 last_ios_request;
    u32 last_ios_command;
    u32 last_ios_fd;
    u32 last_ios_ioctl;
    u32 last_ios_input;
    u32 last_ios_input_length;
    u32 last_ios_output;
    u32 last_ios_output_length;
    u32 ipc_control;
    u32 ipc_arm_message;
    bool ipc_reply_pending;
    bool ipc_dispatch_active;
    u64 ipc_reply_count;
    u32 ipc_handler_address;
    SavedExecutionState ipc_interrupted_state;
    char last_ios_path[128];
    NativeNandFile nand_files[NATIVE_NAND_FILE_COUNT];
    ProtectorSaveStore save_store;
    bool save_store_enabled;
    bool save_store_failed;
    ProtectorDataMount* mount;
    u64 file_read_count;
    u64 file_read_completion_count;
    ProtectorFileRead last_file_read;
    ProtectorFileRead last_completed_file_read;
    u32 dvd_async_return_stack[DVD_ASYNC_STACK_SIZE];
    u32 dvd_async_seam_stack[DVD_ASYNC_STACK_SIZE];
    u32 dvd_async_stack_depth;
    u64 dvd_async_read_count;
    u64 dvd_async_callback_count;
    u64 dvd_async_cancelled_count;
    u64 dvd_async_last_completion_frame;
    bool dvd_async_callback_dispatch_active;
    DvdAsyncCallbackEvent dvd_async_active_event;
    DvdAsyncCallbackEvent
        dvd_async_callback_queue[DVD_ASYNC_CALLBACK_QUEUE_SIZE];
    u32 dvd_async_callback_queue_head;
    u32 dvd_async_callback_queue_count;
    DvdCompletionReplayEntry
        dvd_completion_replay[DVD_COMPLETION_REPLAY_CAPACITY];
    u32 dvd_completion_replay_count;
    SavedExecutionState dvd_async_interrupted_state;
    bool stop_after_first_content;
    u32 first_content_file_info;
    u32 first_content_disc_offset_words;
    u32 first_content_fst_entry_index;
    u32 first_content_destination;
    u32 first_content_callback;
    u64 first_content_hash;
    char platform_error[256];
    u64 deterministic_fast_forwards;
    u64 retrace_count;
    bool vi_retrace_armed;
    bool vi_dispatch_active;
    bool vi_reschedule_active;
    u64 next_vi_retrace_timebase;
    u16 vi_interrupt_registers[4];
    SavedExecutionState vi_interrupted_state;
    u16 pe_interrupt_control;
    bool pe_finish_pending;
    bool pe_dispatch_active;
    bool pe_reschedule_active;
    u64 pe_finish_count;
    u32 pe_finish_handler_address;
    u32 pe_scheduler_count_before;
    u32 pe_run_queue_hint_after;
    u32 pe_run_queue_bits_after;
    u32 pe_current_context_after;
    u32 pe_current_thread_after;
    SavedExecutionState pe_interrupted_state;
    u64 context_load_count;
    u32 last_context_address;
    u16 last_context_state;
    u32 last_context_gpr6;
    ContextLoadEvent context_load_ring[TRACE_RING_SIZE];
    ContextSummary context_summaries[16];
    u32 context_summary_count;
    SleepEvent sleep_ring[TRACE_RING_SIZE];
    u64 sleep_count;
    u64 hash_resume_count;
    u32 last_hash_resume_gpr3;
    u32 last_hash_resume_gpr6;
} BootTrace;

#include "protector/audio_output.h"
static bool consume_ax_pcm(void* context, const s16* samples, u32 frames) {
    BootTrace* trace = context;
    if (!samples || !frames || frames > 96u) return false;
    if (trace->ax_pcm_capture) {
        u8 bytes[384];
        for (u32 i = 0; i < frames * 2u; ++i) {
            const u16 sample = (u16)samples[i];
            bytes[i * 2] = (u8)sample;
            bytes[i * 2 + 1] = (u8)(sample >> 8);
        }
        if (fwrite(bytes, 4u, frames, trace->ax_pcm_capture) != frames) return false;
    }
    // The optional native endpoint is disabled by default. Muted development
    // still runs the real mixer but never opens an audio device.
    protector_audio_output_push(samples, frames);
    return protector_ax_diagnostics_pcm(&trace->ax_diagnostics, samples, frames);
}

static void stop_ax_audio(CPUState* cpu, BootTrace* trace, const char* message) {
    trace->ax_audio_failed = true;
    (void)snprintf(trace->platform_error, sizeof(trace->platform_error),
        "AX audio: %s", message);
    trace->ax_diagnostics.failed = true;
    trace->ax_diagnostics.running = false;
    (void)snprintf(trace->ax_diagnostics.error, sizeof(trace->ax_diagnostics.error),
        "%s", message);
    protector_ax_diagnostics_engine(&trace->ax_diagnostics, trace->ax_audio);
    protector_ax_diagnostics_publish(&trace->ax_diagnostics);
    protector_stop(cpu, PROTECTOR_STOP_PLATFORM_ERROR, cpu->pc, 0u,
        trace->ax_audio ? trace->ax_audio->error_address : 0u);
}

static void initialize_ax_audio(CPUState* cpu, BootTrace* trace) {
    const char* output = getenv("PROTECTOR_AX_PCM_CAPTURE_PATH");
    const char* silent = getenv("PROTECTOR_AX_MIX_SILENT");
    protector_ax_diagnostics_init(&trace->ax_diagnostics, output
        ? PROTECTOR_AX_OUTPUT_CAPTURE : silent
        ? PROTECTOR_AX_OUTPUT_SILENT : PROTECTOR_AX_OUTPUT_DISABLED);
    protector_ax_diagnostics_publish(&trace->ax_diagnostics);
    if (silent && strcmp(silent, "1") != 0) {
        stop_ax_audio(cpu, trace, "PROTECTOR_AX_MIX_SILENT must equal 1");
        return;
    }
    if (!output && !silent) return;
    const char* coefficients = getenv("PROTECTOR_AX_COEFFICIENTS_PATH");
    if ((output && !output[0]) || !coefficients || !coefficients[0] || trace->imported_checkpoint) {
        stop_ax_audio(cpu, trace, "AX mixer needs a coefficient file and a cold boot");
        return;
    }
    FILE* file = fopen(coefficients, "rb");
    if (!file) { stop_ax_audio(cpu, trace, "cannot open coefficient table"); return; }
    u8 bytes[4096];
    const bool valid = fread(bytes, 1, sizeof(bytes), file) == sizeof(bytes) &&
        fgetc(file) == EOF && !ferror(file);
    const int close_result = fclose(file);
    if (!valid || close_result) {
        stop_ax_audio(cpu, trace, "coefficient table must contain exactly 4096 bytes");
        return;
    }
    trace->ax_audio = calloc(1, sizeof(*trace->ax_audio));
    if (!trace->ax_audio) { stop_ax_audio(cpu, trace, "cannot allocate mixer"); return; }
    if (output) {
        /* x refuses replacement of an earlier capture. All output remains offline. */
        trace->ax_pcm_capture = fopen(output, "wbx");
        if (!trace->ax_pcm_capture) { stop_ax_audio(cpu, trace, "cannot create new PCM capture"); return; }
    }
    protector_ax_engine_init(trace->ax_audio, bytes, sizeof(bytes), consume_ax_pcm, trace);
}

static u64 fnv1a_guest_bytes_seed(
    CPUState* cpu, u32 address, u32 length, u64 hash
) {
    for (u32 offset = 0u; offset < length; ++offset) {
        hash ^= mem_read8(cpu, address + offset);
        hash *= UINT64_C(1099511628211);
        if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
            return 0u;
        }
    }
    return hash;
}

static u64 fnv1a_guest_bytes(
    CPUState* cpu, u32 address, u32 length
) {
    return fnv1a_guest_bytes_seed(
        cpu,
        address,
        length,
        UINT64_C(14695981039346656037)
    );
}

static void store_u32_be_bytes(u8* output, u32 value) {
    output[0] = (u8)(value >> 24);
    output[1] = (u8)(value >> 16);
    output[2] = (u8)(value >> 8);
    output[3] = (u8)value;
}

static u64 sync_input_sample_hash(
    const BootTrace* trace, const SyncInputSample* sample
) {
    u8 status[KPAD_STATUS_SIZE];
    if (trace->kpad_status_template_valid) {
        memcpy(status, trace->kpad_status_template, sizeof(status));
    } else {
        memset(status, 0, sizeof(status));
    }
    store_u32_be_bytes(status, sample->hold);
    store_u32_be_bytes(status + 4u, sample->trigger);
    store_u32_be_bytes(status + 8u, sample->release);
    status[0x5Cu] = sample->device_type;
    status[0x5Du] = sample->wpad_error;
    status[0x5Eu] = sample->dpd_valid;
    status[0x5Fu] = sample->data_format;
    if (sample->has_nunchuk_stick) {
        store_u32_be_bytes(status + 0x60u, sample->nunchuk_stick_x_bits);
        store_u32_be_bytes(status + 0x64u, sample->nunchuk_stick_y_bits);
    }
    if (sample->has_motion) {
        static const u32 motion_offsets[10] = {
            0x0Cu, 0x10u, 0x14u, 0x18u, 0x1Cu,
            0x68u, 0x6Cu, 0x70u, 0x74u, 0x78u,
        };
        for (u32 index = 0u; index < 10u; ++index) {
            store_u32_be_bytes(
                status + motion_offsets[index], sample->motion_bits[index]
            );
        }
    }
    u64 hash = FNV1A64_OFFSET;
    for (u32 index = 0u; index < KPAD_STATUS_SIZE; ++index) {
        hash ^= status[index];
        hash *= FNV1A64_PRIME;
    }
    return hash;
}

static u64 fnv1a_host_string(const char* value) {
    u64 hash = UINT64_C(14695981039346656037);
    while (value && *value) {
        hash ^= (u8)*value++;
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static u32 read_guest_instruction_if_valid(
    CPUState* cpu, u32 address
) {
    if (address < 0x80000000u || address >= 0x94000000u) {
        return 0u;
    }
    return mem_read32(cpu, address);
}

static bool guest_range_valid(
    const CPUState* cpu, u32 address, u32 length
) {
    const u64 end = (u64)address + length;
    if (
        address >= GC_RAM_BASE &&
        end <= (u64)GC_RAM_BASE + cpu->ram_size
    ) {
        return true;
    }
    if (
        address >= WII_MEM2_BASE &&
        end <= (u64)WII_MEM2_BASE + cpu->mem2_size
    ) {
        return true;
    }
    return false;
}

static f32 read_guest_float_if_valid(
    CPUState* cpu, u32 address
) {
    if (!guest_range_valid(cpu, address, sizeof(u32))) {
        return 0.0f;
    }
    const u32 bits = mem_read32(cpu, address);
    f32 result = 0.0f;
    memcpy(&result, &bits, sizeof(result));
    return result;
}

static u64 monotonic_nanoseconds(void) {
    struct timespec timestamp;
    if (clock_gettime(CLOCK_MONOTONIC, &timestamp) != 0) {
        return 0u;
    }
    return
        (u64)timestamp.tv_sec * UINT64_C(1000000000) +
        (u64)timestamp.tv_nsec;
}

static int hexadecimal_nibble(char value) {
    if (value >= '0' && value <= '9') {
        return value - '0';
    }
    if (value >= 'a' && value <= 'f') {
        return value - 'a' + 10;
    }
    if (value >= 'A' && value <= 'F') {
        return value - 'A' + 10;
    }
    return -1;
}

static u64 current_guest_instructions(
    const BootTrace* trace, const CPUState* cpu
) {
    u64 current_dispatch =
        cpu->downcount < 0
            ? (u64)(-(cpu->downcount + 1)) + 1u
            : 0u;
    return trace->guest_instructions_completed + current_dispatch;
}

static void capture_performance_frame(
    BootTrace* trace, const CPUState* cpu
) {
    u64 now = monotonic_nanoseconds();
    u64 guest_instructions = current_guest_instructions(trace, cpu);
    if (now == 0u) {
        return;
    }
    if (trace->perf_frame_started) {
        if (trace->perf_frame_sample_count < PERF_FRAME_SAMPLE_CAPACITY) {
            u32 index = trace->perf_frame_sample_count++;
            trace->perf_host_ns[index] =
                now - trace->perf_previous_host_ns;
            trace->perf_blocks[index] =
                trace->dispatch_blocks_started -
                trace->perf_previous_blocks;
            trace->perf_guest_instructions[index] =
                guest_instructions -
                trace->perf_previous_guest_instructions;
        }
    } else {
        trace->perf_frame_started = true;
    }
    trace->perf_previous_host_ns = now;
    trace->perf_previous_blocks = trace->dispatch_blocks_started;
    trace->perf_previous_guest_instructions = guest_instructions;
}

static void save_execution_state(
    SavedExecutionState* saved, const CPUState* cpu
) {
    memcpy(saved->gpr, cpu->gpr, sizeof(saved->gpr));
    memcpy(saved->fpr, cpu->fpr, sizeof(saved->fpr));
    memcpy(saved->ps1, cpu->ps1, sizeof(saved->ps1));
    saved->pc = cpu->pc;
    saved->lr = cpu->lr;
    saved->ctr = cpu->ctr;
    saved->cr = cpu->cr;
    saved->xer = cpu->xer;
    saved->fpscr = cpu->fpscr;
    saved->msr = cpu->msr;
    saved->srr0 = cpu->srr0;
    saved->srr1 = cpu->srr1;
    saved->ear = cpu->ear;
    saved->hid2 = cpu->hid2;
    saved->reservation_address = cpu->reservation_address;
    saved->reservation_valid = cpu->reservation_valid;
}

static void restore_execution_state(
    CPUState* cpu, const SavedExecutionState* saved
) {
    memcpy(cpu->gpr, saved->gpr, sizeof(saved->gpr));
    memcpy(cpu->fpr, saved->fpr, sizeof(saved->fpr));
    memcpy(cpu->ps1, saved->ps1, sizeof(saved->ps1));
    cpu->pc = saved->pc;
    cpu->lr = saved->lr;
    cpu->ctr = saved->ctr;
    cpu->cr = saved->cr;
    cpu->xer = saved->xer;
    cpu->fpscr = saved->fpscr;
    cpu->msr = saved->msr;
    cpu->srr0 = saved->srr0;
    cpu->srr1 = saved->srr1;
    cpu->ear = saved->ear;
    cpu->hid2 = saved->hid2;
    cpu->reservation_address = saved->reservation_address;
    cpu->reservation_valid = saved->reservation_valid;
}

static u32 current_ai_sample_counter(
    const BootTrace* trace,
    const CPUState* cpu
) {
    if ((trace->ai_control & 1u) == 0u) {
        return trace->ai_sample_counter;
    }
    u32 sample_rate =
        (trace->ai_control & 2u) != 0u ? 48000u : 32000u;
    u64 ticks_per_sample = WII_TIMEBASE_HZ / sample_rate;
    return trace->ai_sample_counter +
           (u32)((cpu->timebase - trace->ai_counter_timebase) /
                 ticks_per_sample);
}

static u32 mmio_register_offset(u32 address) {
    return address & 0x00FFFFFFu;
}

static bool is_gx_fifo_aperture(u32 address) {
    u32 offset = mmio_register_offset(address);
    return offset >= GX_FIFO_REGISTER && offset < 0x00C000u;
}

typedef struct PlatformStub {
    u32 address;
    const char* name;
    u32 result;
} PlatformStub;

static const PlatformStub PLATFORM_STUBS[] = {
    {
        WII_SDK_DISABLE_WRITE_GATHER_PIPE,
        "DisableWriteGatherPipe",
        0,
    },
    {WII_SDK_OS_INIT_STM, "__OSInitSTM", 0},
    {WII_SDK_OS_INIT_PLAY_TIME, "__OSInitPlayTime", 0},
    {WII_SDK_OS_INIT_NET, "__OSInitNet", 0},
    {WII_SDK_DVD_INIT, "DVDInit", 0},
    {WII_SDK_VI_WAIT_FOR_RETRACE, "VIWaitForRetrace", 0},
    {WII_SDK_SC_INIT, "SCInit", 0},
    {WII_SDK_SC_CHECK_STATUS, "SCCheckStatus", 0},
    {WII_SDK_WUD_INIT, "WUDInit", 1},
    {WII_SDK_WUD_GET_STATUS, "WUDGetStatus", 3},
    {
        WII_SDK_IUSB_OPEN_DEVICE_IDS,
        "IUSB_OpenDeviceIds",
        0xFFFFFFFAu,
    },
    {
        WII_SDK_SC_GET_ASPECT_RATIO,
        "SCGetAspectRatio",
        /* The formal isolated Dolphin profile exposes IPL.AR = widescreen. */
        1,
    },
};

static void abort_translated_dispatch(CPUState* cpu) {
    BootTrace* trace = (BootTrace*)cpu->external_user_data;
    if (trace && trace->dispatch_active) {
#if defined(__APPLE__)
        _longjmp(trace->dispatch_abort, 1);
#else
        longjmp(trace->dispatch_abort, 1);
#endif
    }
}

/* A guest stop is synchronous, never a signal handler. Darwin's setjmp also
 * saves the signal mask and alternate signal stack on every guest dispatch;
 * use its register/stack-only pair here. Keep the returns-twice boundary in
 * this small function: CPU/trace objects belong to its caller, so modified
 * automatic objects in that caller are not indeterminate after the jump. */
static bool run_translated_dispatch(CPUState* cpu, BootTrace* trace) {
    trace->dispatch_active = true;
#if defined(__APPLE__)
    if (_setjmp(trace->dispatch_abort) != 0) {
#else
    if (setjmp(trace->dispatch_abort) != 0) {
#endif
        trace->dispatch_active = false;
        return false;
    }
    if (!dolrecomp_call(cpu, cpu->pc)) {
        protector_stop(cpu, PROTECTOR_STOP_UNEXPECTED_DISPATCH,
                       cpu->pc, 0, cpu->pc);
    }
    trace->dispatch_active = false;
    return true;
}

static bool trace_system_call(CPUState* cpu, u32 address) {
    BootTrace* trace = (BootTrace*)cpu->external_user_data;
    trace->system_call_count++;
    trace->last_system_call = address;
    switch (address) {
        case 0x800BF9ECu:
        case 0x800C1FFCu:
        case 0x800C202Cu:
            ppc_memory_fence();
            cpu->pc = address + 4u;
            return true;
        default:
            return false;
    }
}

static void record_mmio(
    BootTrace* trace,
    CPUState* cpu,
    u32 address,
    u32 value,
    u8 size,
    bool write
) {
    MmioEvent* event =
        &trace->mmio_ring[trace->mmio_event_count % TRACE_RING_SIZE];
    event->pc = cpu->pc;
    event->address = address;
    event->value = value;
    event->size = size;
    event->write = write;
    trace->mmio_event_count++;
}

static void record_gx_fifo_write(
    BootTrace* trace, u64 value, u8 size
) {
    trace->gx_fifo_write_count++;
    trace->gx_fifo_byte_count += size;
    trace->gx_current_frame_write_count++;
    trace->gx_current_frame_byte_count += size;
    for (u8 index = 0u; index < size; ++index) {
        u8 shift = (u8)((size - index - 1u) * 8u);
        u8 byte = (u8)(value >> shift);
        trace->gx_current_frame_hash ^= byte;
        trace->gx_current_frame_hash *= FNV1A64_PRIME;
        if (
            (trace->gx_capture_file || protector_live_gx_has_sink()) &&
            !trace->gx_capture_failed
        ) {
            if (
                trace->gx_capture_frame_size ==
                trace->gx_capture_frame_capacity
            ) {
                size_t old_capacity = trace->gx_capture_frame_capacity;
                size_t new_capacity =
                    old_capacity == 0u ? 4096u : old_capacity * 2u;
                u8* resized = realloc(
                    trace->gx_capture_frame,
                    new_capacity
                );
                if (!resized) {
                    trace->gx_capture_failed = true;
                } else {
                    trace->gx_capture_frame = resized;
                    trace->gx_capture_frame_capacity = new_capacity;
                }
            }
            if (!trace->gx_capture_failed) {
                trace->gx_capture_frame[
                    trace->gx_capture_frame_size++
                ] = byte;
            }
        }
    }
}

static u64 fnv1a_u32_be(u64 hash, u32 value) {
    for (u32 shift = 24u;; shift -= 8u) {
        hash ^= (u8)(value >> shift);
        hash *= FNV1A64_PRIME;
        if (shift == 0u) {
            return hash;
        }
    }
}

static bool write_u32_be(FILE* output, u32 value) {
    const u8 bytes[4] = {
        (u8)(value >> 24),
        (u8)(value >> 16),
        (u8)(value >> 8),
        (u8)value,
    };
    return fwrite(bytes, 1u, sizeof(bytes), output) == sizeof(bytes);
}

static bool read_u32_be(FILE* input, u32* value) {
    u8 bytes[4];
    if (fread(bytes, 1u, sizeof(bytes), input) != sizeof(bytes)) {
        return false;
    }
    *value =
        ((u32)bytes[0] << 24) |
        ((u32)bytes[1] << 16) |
        ((u32)bytes[2] << 8) |
        (u32)bytes[3];
    return true;
}

static void capture_gx_memory(
    BootTrace* trace, CPUState* cpu
) {
    if (
        !trace->gx_memory_capture_path ||
        trace->gx_memory_captured ||
        trace->gx_memory_capture_failed ||
        trace->gx_completed_frame_count != trace->gx_memory_capture_frame
    ) {
        return;
    }
    FILE* output = fopen(trace->gx_memory_capture_path, "wb");
    if (!output) {
        trace->gx_memory_capture_failed = true;
        return;
    }
    bool capture_ok =
        fwrite(GX_MEMORY_MAGIC, 1u, 4u, output) == 4u &&
        write_u32_be(output, GX_MEMORY_VERSION) &&
        trace->gx_completed_frame_count <= UINT32_MAX &&
        write_u32_be(
            output,
            (u32)trace->gx_completed_frame_count
        ) &&
        write_u32_be(output, cpu->ram_size) &&
        write_u32_be(output, cpu->mem2_size) &&
        fwrite(cpu->ram, 1u, cpu->ram_size, output) == cpu->ram_size &&
        fwrite(cpu->mem2, 1u, cpu->mem2_size, output) == cpu->mem2_size;
    if (fclose(output) != 0) {
        capture_ok = false;
    }
    trace->gx_memory_captured = capture_ok;
    trace->gx_memory_capture_failed = !capture_ok;
}

static void capture_sync_memory(BootTrace* trace, CPUState* cpu) {
    if (
        !trace->sync_memory_capture_path ||
        trace->sync_memory_captured ||
        trace->sync_memory_capture_failed ||
        trace->sync_trace_frame_count != trace->sync_memory_capture_frame
    ) {
        return;
    }
    FILE* output = fopen(trace->sync_memory_capture_path, "wb");
    if (!output) {
        trace->sync_memory_capture_failed = true;
        return;
    }
    bool capture_ok =
        fwrite(SYNC_MEMORY_MAGIC, 1u, 4u, output) == 4u &&
        write_u32_be(output, GX_MEMORY_VERSION) &&
        write_u32_be(output, trace->sync_trace_frame_count) &&
        write_u32_be(output, cpu->ram_size) &&
        write_u32_be(output, cpu->mem2_size) &&
        fwrite(cpu->ram, 1u, cpu->ram_size, output) == cpu->ram_size &&
        fwrite(cpu->mem2, 1u, cpu->mem2_size, output) == cpu->mem2_size;
    if (fclose(output) != 0) {
        capture_ok = false;
    }
    trace->sync_memory_captured = capture_ok;
    trace->sync_memory_capture_failed = !capture_ok;
}

static void finish_gx_frame(BootTrace* trace, CPUState* cpu) {
    if (trace->gx_current_frame_byte_count == 0u) {
        return;
    }
    capture_performance_frame(trace, cpu);
    if (trace->gx_capture_file && !trace->gx_capture_failed) {
        bool capture_ok =
            trace->gx_capture_frame_size <= UINT32_MAX &&
            fwrite(
                GX_CAPTURE_MAGIC,
                1u,
                4u,
                trace->gx_capture_file
            ) == 4u &&
            write_u32_be(
                trace->gx_capture_file,
                (u32)trace->gx_completed_frame_count
            ) &&
            write_u32_be(
                trace->gx_capture_file,
                (u32)trace->gx_capture_frame_size
            ) &&
            fwrite(
                trace->gx_capture_frame,
                1u,
                trace->gx_capture_frame_size,
                trace->gx_capture_file
            ) == trace->gx_capture_frame_size;
        if (!capture_ok) {
            trace->gx_capture_failed = true;
        }
    }
    if (trace->native_ui_text) {
        ProtectorUIContext context = protector_ui_context_frame(
            &trace->ui_context, cpu->presented_frame_count);
        const ProtectorUIContext tutorial = protector_tutorial_frame(
            &trace->tutorial_context, cpu->presented_frame_count);
        /* A source menu/loading stage has priority over a suspended tutorial. */
        if (context == PROTECTOR_UI_GAMEPLAY) context = tutorial;
        if (context != protector_ui_context_current())
            fprintf(stderr, "native_ui_context frame=%" PRIu64 " context=%s owners=%u\n",
                cpu->presented_frame_count, protector_ui_context_name(context), trace->ui_context.count);
        protector_ui_context_publish_snapshot(context,
            protector_ui_context_map_actions(&trace->ui_context, cpu->presented_frame_count));
    }
    ProtectorLiveGXResult live_result = PROTECTOR_LIVE_GX_CONTINUE;
    if (protector_live_gx_has_sink() && !trace->gx_capture_failed) {
        const u32 combo_scheme = trace->native_ui_text && protector_ui_context_current() == PROTECTOR_UI_COMBO_LIST
            ? protector_ui_context_combo_scheme(&trace->ui_context, cpu->presented_frame_count) : 0;
        protector_live_gx_set_combo_frame((ProtectorLiveComboFrame){(u32)trace->gx_completed_frame_count, combo_scheme});
        protector_live_gx_set_interaction_frame((ProtectorLiveInteractionFrame){
            (u32)trace->gx_completed_frame_count,
            trace->native_ui_text && protector_ui_context_current()==PROTECTOR_UI_GAMEPLAY ?
                protector_interaction_frame(&trace->interaction_context,cpu->presented_frame_count) : 0});
        const ProtectorUIContext upgrade_context=protector_ui_context_current();
        const bool upgrade_active=trace->native_ui_text &&
            (upgrade_context==PROTECTOR_UI_UPGRADE_MENU || upgrade_context==PROTECTOR_UI_UPGRADE_READY);
        protector_live_gx_set_upgrade_frame((ProtectorLiveUpgradeFrame){
            .presentation_frame=(u32)trace->gx_completed_frame_count,
            .scheme=upgrade_active ? protector_ui_context_upgrade_scheme(&trace->ui_context,cpu->presented_frame_count) : 0,
            .active=upgrade_active,.ready=upgrade_active && upgrade_context==PROTECTOR_UI_UPGRADE_READY});
        protector_live_gx_set_cinematic_frame(protector_cinematic_observe_frame(
            &trace->cinematic, cpu, trace->gx_completed_frame_count));
        protector_motion_identity_publish(&trace->motion_identity, cpu,
            trace->gx_capture_frame, trace->gx_capture_frame_size);
        live_result = protector_live_gx_submit(
            (u32)trace->gx_completed_frame_count,
            trace->gx_capture_frame,
            trace->gx_capture_frame_size,
            cpu
        );
        protector_motion_identity_publish(NULL, NULL, NULL, 0);
        if (live_result == PROTECTOR_LIVE_GX_ERROR) {
            trace->gx_capture_failed = true;
            (void)snprintf(
                trace->platform_error,
                sizeof(trace->platform_error),
                "live GX sink rejected frame %" PRIu64,
                trace->gx_completed_frame_count
            );
        } else if (live_result == PROTECTOR_LIVE_GX_COMPLETE) {
            trace->live_gx_complete = true;
        }
    }
    capture_gx_memory(trace, cpu);
    if (
        trace->gx_completed_frame_count > 0u &&
        trace->gx_current_frame_hash != trace->gx_last_frame_hash
    ) {
        trace->gx_frame_hash_change_count++;
    }
    trace->gx_completed_frame_count++;
    cpu->presented_frame_count = trace->gx_completed_frame_count;
    if (trace->rng_checkpoint_diagnostics) {
        const u32 random_stream_table =
            mem_read32(cpu, GAME_RANDOM_STREAM_TABLE_POINTER);
        const u32 random_stream_5_address =
            random_stream_table + 5u * GAME_RANDOM_STREAM_STRIDE;
        const u32 script_manager = mem_read32(
            cpu, GAME_SCRIPT_MANAGER_POINTER
        );
        const u32 diagnostic_script_base =
            trace->script_vm_diagnostic_context != 0u
                ? mem_read32(
                      cpu, trace->script_vm_diagnostic_context + 472u
                  )
                : 0u;
        const bool diagnostic_script_locals_valid = guest_range_valid(
            cpu, diagnostic_script_base + 0x9Cu, 8u
        );
        fprintf(
            stderr,
            "rng_checkpoint checkpoint=%llu stream_5_state=%s0x%08X"
            " script_manager_count=%u"
            " script_manager_slot_27=0x%08X"
            " script_manager_slot_28=0x%08X"
            " script_manager_cursor=0x%08X"
            " script_update_enabled=%u"
            " script_context_flags=0x%08X"
            " script_context_ip=0x%08X"
            " script_context_stack=0x%08X"
            " script_context_base=0x%08X"
            " script_context_event_table=0x%08X"
            " script_context_active_event=0x%08X"
            " script_context_owner=0x%08X"
            " script_context_wait=%u"
            " script_context_local27=0x%08X"
            " script_context_local28=0x%08X"
            " loader_state=%u loader_file_index=%u loader_offset=%u"
            " loader_destination=0x%08X loader_length=%u"
            " loader_previous_offset=%u stream_flag=%u"
            " stream_active=%u stream_result=%u\n",
            (unsigned long long)trace->gx_completed_frame_count,
            guest_range_valid(cpu, random_stream_5_address, 4u)
                ? ""
                : "invalid-",
            guest_range_valid(cpu, random_stream_5_address, 4u)
                ? mem_read32(cpu, random_stream_5_address)
                : 0u,
            guest_range_valid(cpu, script_manager + 8196u, 4u)
                ? mem_read32(cpu, script_manager + 8196u)
                : 0u,
            guest_range_valid(cpu, script_manager + 0x13Cu, 4u)
                ? mem_read32(cpu, script_manager + 0x13Cu)
                : 0u,
            guest_range_valid(cpu, script_manager + 0x144u, 4u)
                ? mem_read32(cpu, script_manager + 0x144u)
                : 0u,
            guest_range_valid(cpu, script_manager + 0x2020u, 4u)
                ? mem_read32(cpu, script_manager + 0x2020u)
                : 0u,
            mem_read8(cpu, GAME_SCRIPT_UPDATE_ENABLED),
            trace->script_vm_diagnostic_context != 0u
                ? mem_read32(
                      cpu, trace->script_vm_diagnostic_context + 432u
                  )
                : 0u,
            trace->script_vm_diagnostic_context != 0u
                ? mem_read32(
                      cpu, trace->script_vm_diagnostic_context + 464u
                  )
                : 0u,
            trace->script_vm_diagnostic_context != 0u
                ? mem_read32(
                      cpu, trace->script_vm_diagnostic_context + 468u
                  )
                : 0u,
            diagnostic_script_base,
            trace->script_vm_diagnostic_context != 0u
                ? mem_read32(
                      cpu, trace->script_vm_diagnostic_context + 476u
                  )
                : 0u,
            trace->script_vm_diagnostic_context != 0u
                ? mem_read32(
                      cpu, trace->script_vm_diagnostic_context + 480u
                  )
                : 0u,
            trace->script_vm_diagnostic_context != 0u
                ? mem_read32(
                      cpu, trace->script_vm_diagnostic_context + 484u
                  )
                : 0u,
            trace->script_vm_diagnostic_context != 0u
                ? mem_read16(
                      cpu, trace->script_vm_diagnostic_context + 608u
                  )
                : 0u,
            diagnostic_script_locals_valid
                ? mem_read32(cpu, diagnostic_script_base + 0x9Cu)
                : 0u,
            diagnostic_script_locals_valid
                ? mem_read32(cpu, diagnostic_script_base + 0xA0u)
                : 0u,
            mem_read32(cpu, GAME_STREAM_LOADER + 3080u),
            mem_read32(cpu, GAME_STREAM_LOADER + 3076u),
            mem_read32(cpu, GAME_STREAM_LOADER + 3096u),
            mem_read32(cpu, GAME_STREAM_LOADER + 3104u),
            mem_read32(cpu, GAME_STREAM_LOADER + 3108u),
            mem_read32(cpu, GAME_STREAM_LOADER + 3112u),
            mem_read8(cpu, cpu->gpr[13] - 28915u),
            mem_read8(cpu, cpu->gpr[13] - 28914u),
            mem_read32(cpu, cpu->gpr[13] - 28912u)
        );
    }
    trace->gx_last_frame_write_count =
        trace->gx_current_frame_write_count;
    trace->gx_last_frame_byte_count =
        trace->gx_current_frame_byte_count;
    trace->gx_last_frame_hash = trace->gx_current_frame_hash;
    trace->gx_current_frame_write_count = 0u;
    trace->gx_current_frame_byte_count = 0u;
    trace->gx_current_frame_hash = FNV1A64_OFFSET;
    trace->gx_capture_frame_size = 0u;
    protector_motion_identity_next_frame(&trace->motion_identity);
    if (live_result == PROTECTOR_LIVE_GX_ERROR) {
        protector_stop(
            cpu,
            PROTECTOR_STOP_PLATFORM_ERROR,
            GAME_FRAME_LOOP_BACKEDGE,
            0u,
            (u32)(trace->gx_completed_frame_count - 1u)
        );
    } else if (live_result == PROTECTOR_LIVE_GX_COMPLETE) {
        protector_stop(
            cpu,
            PROTECTOR_STOP_HOST_SERVICE,
            GAME_FRAME_LOOP_BACKEDGE,
            0u,
            (u32)(trace->gx_completed_frame_count - 1u)
        );
    }
}

static bool sync_trace_replay_ready(
    BootTrace* trace, CPUState* cpu
) {
    if (
        !trace->sync_trace_file ||
        !trace->sync_trace_content_ready ||
        trace->gx_completed_frame_count <
            trace->sync_trace_start_gx_frame
    ) {
        return false;
    }
    if (!trace->sync_trace_require_gameplay_bindings) {
        return true;
    }
    if (trace->sync_trace_frame_count > 0u) {
        /*
         * Initial gameplay sampling still requires stable source bindings.
         * Once the synchronized window has begun, a null binding is itself
         * observable game state (death, stream, or progression transition)
         * and must be recorded instead of pausing the trace.
         */
        return true;
    }
    const u32 script_manager = mem_read32(
        cpu, GAME_SCRIPT_MANAGER_POINTER
    );
    if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
        return false;
    }
    const u32 player_object =
        guest_range_valid(
            cpu,
            script_manager + GAME_SCRIPT_MANAGER_PLAYER_OFFSET,
            sizeof(u32)
        )
            ? mem_read32(
                  cpu,
                  script_manager +
                      GAME_SCRIPT_MANAGER_PLAYER_OFFSET
              )
            : 0u;
    const u32 camera_object =
        guest_range_valid(
            cpu,
            script_manager + GAME_SCRIPT_MANAGER_CAMERA_OFFSET,
            sizeof(u32)
        )
            ? mem_read32(
                  cpu,
                  script_manager +
                      GAME_SCRIPT_MANAGER_CAMERA_OFFSET
              )
            : 0u;
    const bool bindings_valid =
        guest_range_valid(
            cpu,
            player_object + GAME_STRAT_POSITION_OFFSET,
            GAME_STRAT_TRANSFORM_SIZE
        ) &&
        guest_range_valid(
            cpu,
            camera_object + GAME_STRAT_POSITION_OFFSET,
            GAME_STRAT_TRANSFORM_SIZE
        );
    if (!bindings_valid) {
        trace->sync_trace_gameplay_bindings_ready = false;
        trace->sync_trace_binding_sample_valid = false;
        return false;
    }
    if (trace->imported_checkpoint) {
        /*
         * A full checkpoint already contains the settled source world.  It
         * has no native pre-roll history to satisfy the cold-boot observer
         * counts or two-frame stability test, so current mapped bindings are
         * the only honest readiness criterion at the import seam.
         */
        trace->sync_trace_gameplay_bindings_ready = true;
        return true;
    }
    if (
        trace->gameplay_observable_seen_total[
            GAMEPLAY_OBSERVABLE_GROUND_COLLISION
        ] == 0u ||
        trace->gameplay_observable_seen_total[
            GAMEPLAY_OBSERVABLE_WALL_COLLISION
        ] == 0u ||
        trace->gameplay_observable_seen_total[
            GAMEPLAY_OBSERVABLE_SET_SKELETON
        ] == 0u
    ) {
        return false;
    }
    if (trace->sync_trace_gameplay_bindings_ready) {
        return true;
    }
    if (
        trace->sync_trace_binding_sample_valid &&
        trace->sync_trace_binding_sample_gx_frame ==
            trace->gx_completed_frame_count
    ) {
        return false;
    }
    const u64 player_hash = fnv1a_guest_bytes(
        cpu,
        player_object + GAME_STRAT_POSITION_OFFSET,
        GAME_STRAT_TRANSFORM_SIZE
    );
    const u64 camera_hash = fnv1a_guest_bytes(
        cpu,
        camera_object + GAME_STRAT_POSITION_OFFSET,
        GAME_STRAT_TRANSFORM_SIZE
    );
    const bool consecutive_stable_sample =
        trace->sync_trace_binding_sample_valid &&
        trace->sync_trace_binding_sample_gx_frame + 1u ==
            trace->gx_completed_frame_count &&
        trace->sync_trace_binding_sample_player == player_object &&
        trace->sync_trace_binding_sample_camera == camera_object &&
        trace->sync_trace_binding_sample_player_hash == player_hash &&
        trace->sync_trace_binding_sample_camera_hash == camera_hash;
    trace->sync_trace_binding_sample_valid = true;
    trace->sync_trace_binding_sample_gx_frame =
        trace->gx_completed_frame_count;
    trace->sync_trace_binding_sample_player = player_object;
    trace->sync_trace_binding_sample_camera = camera_object;
    trace->sync_trace_binding_sample_player_hash = player_hash;
    trace->sync_trace_binding_sample_camera_hash = camera_hash;
    trace->sync_trace_gameplay_bindings_ready =
        consecutive_stable_sample;
    return consecutive_stable_sample;
}

static u8* checkpoint_memory_destination(
    CPUState* cpu, u32 address, u32 size
) {
    if (
        address >= GC_RAM_BASE &&
        size <= cpu->ram_size &&
        address - GC_RAM_BASE <= cpu->ram_size - size
    ) {
        return cpu->ram + (address - GC_RAM_BASE);
    }
    if (
        address >= WII_MEM2_BASE &&
        size <= cpu->mem2_size &&
        address - WII_MEM2_BASE <= cpu->mem2_size - size
    ) {
        return cpu->mem2 + (address - WII_MEM2_BASE);
    }
    return NULL;
}

static bool apply_sync_checkpoint_memory_replay(
    BootTrace* trace, CPUState* cpu
) {
    if (
        !trace->sync_checkpoint_memory_replay_path ||
        trace->sync_checkpoint_memory_replay_applied
    ) {
        return true;
    }
    FILE* input = fopen(
        trace->sync_checkpoint_memory_replay_path, "rb"
    );
    u8 magic[4];
    u32 version = 0u;
    u32 region_count = 0u;
    bool valid =
        input &&
        fread(magic, 1u, sizeof(magic), input) == sizeof(magic) &&
        memcmp(magic, CHECKPOINT_MEMORY_MAGIC, sizeof(magic)) == 0 &&
        read_u32_be(input, &version) &&
        version == CHECKPOINT_MEMORY_VERSION &&
        read_u32_be(input, &region_count) &&
        region_count > 0u &&
        region_count <= CHECKPOINT_MEMORY_REGION_CAPACITY;
    u32 previous_end = 0u;
    for (u32 index = 0u; valid && index < region_count; ++index) {
        u32 address = 0u;
        u32 size = 0u;
        valid =
            read_u32_be(input, &address) &&
            read_u32_be(input, &size) &&
            size > 0u &&
            size <= 0x00400000u &&
            (index == 0u || address > previous_end);
        u8* destination =
            valid
                ? checkpoint_memory_destination(cpu, address, size)
                : NULL;
        valid =
            valid &&
            destination &&
            fread(destination, 1u, size, input) == size;
        if (valid) {
            previous_end = address + size - 1u;
        }
    }
    if (valid) {
        valid = fgetc(input) == EOF && !ferror(input);
    }
    if (input && fclose(input) != 0) {
        valid = false;
    }
    trace->sync_checkpoint_memory_replay_applied = valid;
    trace->sync_checkpoint_memory_replay_failed = !valid;
    if (!valid) {
        trace->sync_trace_failed = true;
    }
    return valid;
}

static bool apply_sync_checkpoint_replay(
    BootTrace* trace, CPUState* cpu
) {
    if (trace->sync_trace_frame_count != 0u) {
        return true;
    }
    if (!apply_sync_checkpoint_memory_replay(trace, cpu)) {
        return false;
    }
    if (
        trace->sync_rng_replay_enabled &&
        !trace->sync_rng_replay_applied
    ) {
        const u32 table = mem_read32(
            cpu, GAME_RANDOM_STREAM_TABLE_POINTER
        );
        if (
            !guest_range_valid(
                cpu,
                table,
                GAME_RANDOM_REPLAY_STATE_COUNT *
                    GAME_RANDOM_STREAM_STRIDE
            )
        ) {
            trace->sync_trace_failed = true;
            return false;
        }
        for (
            u32 index = 0u;
            index < GAME_RANDOM_REPLAY_STATE_COUNT;
            ++index
        ) {
            mem_write32(
                cpu,
                table + index * GAME_RANDOM_STREAM_STRIDE,
                trace->sync_rng_replay_states[index]
            );
        }
        trace->sync_rng_replay_applied = true;
    }
    if (
        trace->sync_title_vm_register_0_replay_enabled &&
        !trace->sync_title_vm_register_0_replay_applied
    ) {
        const u32 script_base = mem_read32(
            cpu, GAME_TITLE_SCRIPT_CONTEXT + 472u
        );
        if (!guest_range_valid(cpu, script_base, sizeof(u32))) {
            trace->sync_trace_failed = true;
            return false;
        }
        mem_write32(
            cpu,
            script_base,
            trace->sync_title_vm_register_0_replay_value
        );
        trace->sync_title_vm_register_0_replay_applied = true;
    }
    if (
        trace->sync_strategy_vm_replay_count != 0u &&
        !trace->sync_strategy_vm_replay_applied
    ) {
        for (
            u32 index = 0u;
            index < trace->sync_strategy_vm_replay_count;
            ++index
        ) {
            const StrategyVmReplayEntry* entry =
                &trace->sync_strategy_vm_replay[index];
            if (
                !guest_range_valid(cpu, entry->context, 476u) ||
                !guest_range_valid(
                    cpu, entry->script_base, sizeof(u32)
                ) ||
                mem_read32(
                    cpu,
                    entry->context + GAME_SCRIPT_CONTEXT_IP_OFFSET
                ) != entry->instruction_pointer ||
                mem_read32(cpu, entry->context + 472u) !=
                    entry->script_base
            ) {
                trace->sync_trace_failed = true;
                return false;
            }
            mem_write32(
                cpu, entry->script_base, entry->register_0
            );
        }
        trace->sync_strategy_vm_replay_applied = true;
    }
    return true;
}

static void reset_sync_trace_gameplay_settle(BootTrace* trace) {
    if (
        !trace->sync_trace_require_gameplay_bindings ||
        !trace->sync_trace_content_ready ||
        trace->sync_trace_frame_count != 0u
    ) {
        return;
    }
    trace->sync_trace_gameplay_bindings_ready = false;
    trace->sync_trace_binding_sample_valid = false;
}

static bool sync_frame_delta_index(
    const BootTrace* trace, u32* index
) {
    if (
        trace->gx_completed_frame_count <
            trace->sync_frame_delta_start_gx_frame
    ) {
        return false;
    }
    const u64 candidate =
        trace->gx_completed_frame_count >=
                trace->sync_trace_start_gx_frame
            ? trace->sync_trace_start_gx_frame -
                    trace->sync_frame_delta_start_gx_frame +
                    trace->sync_trace_frame_count
            : trace->gx_completed_frame_count -
                    trace->sync_frame_delta_start_gx_frame;
    if (candidate >= trace->sync_frame_delta_count) {
        return false;
    }
    *index = (u32)candidate;
    return true;
}

static void apply_sync_frame_delta_after_timing(
    BootTrace* trace, CPUState* cpu
) {
    if (
        trace->motion_diagnostics &&
        trace->sync_frame_delta_count != 0u &&
        trace->sync_trace_content_ready &&
        trace->gx_completed_frame_count + 4u >=
            trace->sync_frame_delta_start_gx_frame
    ) {
        fprintf(
            stderr,
            "timing_replay_hook gx=%" PRIu64
            " start=%" PRIu64 " trace_frame=%u delta_count=%u"
            " r24=0x%08X r3=%u slot140=%u slot684=%u\n",
            trace->gx_completed_frame_count,
            trace->sync_trace_start_gx_frame,
            trace->sync_trace_frame_count,
            trace->sync_frame_delta_count,
            cpu->gpr[24],
            cpu->gpr[3],
            mem_read32(cpu, cpu->gpr[24] + 140u),
            mem_read32(cpu, cpu->gpr[24] + 684u)
        );
    }
    u32 delta_index = 0u;
    if (
        trace->sync_trace_file &&
        sync_frame_delta_index(trace, &delta_index)
    ) {
        /*
         * At the canonical GX checkpoint, source gameplay consumes this
         * frame's finalized delta.  Keep the replay and reporting paths on
         * that same source sample.
         */
        const u32 delta = trace->sync_frame_deltas[delta_index];
        /*
         * This hook runs immediately before the title's
         * `stw r3, 684(r24)` at 0x800396E8.  Updating the destination alone
         * is ineffective because the translated guest instruction then
         * overwrites it with the live host-timer value.  Replace r3 so the
         * original store commits the replayed source delta at its real seam.
         *
         * The same live value was already stored to 140(r24) at 0x800396E4,
         * and gameplay reloads that slot at 0x80039734.  Keep both mirrors in
         * sync; otherwise trace metadata reports the replayed delta while the
         * game continues to consume the live native timer.
         */
        cpu->gpr[3] = delta;
        mem_write32(cpu, cpu->gpr[24] + 140u, delta);
        mem_write32(
            cpu,
            GAME_FRAME_DELTA_MICROSECONDS,
            delta
        );
    }
}

static void format_gameplay_state_words_json(
    CPUState* cpu,
    bool available,
    u32 object,
    char* output,
    size_t output_capacity
) {
    if (!available) {
        (void)snprintf(
            output,
            output_capacity,
            ",\"state_words\":[]"
        );
        return;
    }
    const u32 transform =
        object + GAME_STRAT_POSITION_OFFSET;
    (void)snprintf(
        output,
        output_capacity,
        ",\"state_words\":["
        "\"0x%08X\",\"0x%08X\",\"0x%08X\","
        "\"0x%08X\",\"0x%08X\",\"0x%08X\","
        "\"0x%08X\",\"0x%08X\",\"0x%08X\"]",
        mem_read32(cpu, transform + 12u),
        mem_read32(cpu, transform + 16u),
        mem_read32(cpu, transform + 20u),
        mem_read32(cpu, transform + 24u),
        mem_read32(cpu, transform + 28u),
        mem_read32(cpu, transform + 32u),
        mem_read32(cpu, transform + 36u),
        mem_read32(cpu, transform + 40u),
        mem_read32(cpu, transform + 44u)
    );
}

static u32 gameplay_semantic_r3(CPUState* cpu, u32 target, u32 raw_r3) {
    if (
        target != 0x80049FCCu &&
        target != 0x80046248u &&
        target != 0x8004911Cu
    ) {
        return raw_r3;
    }
    if (
        raw_r3 < GAME_STRATEGY_CONTEXT_POOL_START ||
        raw_r3 > GAME_STRATEGY_CONTEXT_POOL_END - 0x1DCu
    ) {
        return raw_r3;
    }
    const u32 script_base = mem_read32(cpu, raw_r3 + 0x1D8u);
    return guest_range_valid(cpu, script_base, sizeof(u32)) &&
            script_base >= 0x90000000u
        ? script_base
        : raw_r3;
}

static void format_gameplay_object_hashes_json(
    CPUState* cpu,
    bool available,
    u32 object,
    char* output,
    size_t output_capacity
) {
    if (!available) {
        (void)snprintf(
            output,
            output_capacity,
            ",\"object_fnv1a64\":\"0000000000000000\","
            "\"object_block_fnv1a64\":[],"
            "\"object_probe_blocks\":[]"
        );
        return;
    }
    size_t used = (size_t)snprintf(
        output,
        output_capacity,
        ",\"object_fnv1a64\":\"%016" PRIX64 "\","
        "\"object_block_fnv1a64\":[",
        fnv1a_guest_bytes(
            cpu,
            object,
            GAME_STRAT_OBJECT_SNAPSHOT_SIZE
        )
    );
    for (
        u32 index = 0u;
        index < GAME_STRAT_OBJECT_BLOCK_COUNT && used < output_capacity;
        ++index
    ) {
        const int appended = snprintf(
            output + used,
            output_capacity - used,
            "%s\"%016" PRIX64 "\"",
            index == 0u ? "" : ",",
            fnv1a_guest_bytes(
                cpu,
                object + index * GAME_STRAT_OBJECT_BLOCK_SIZE,
                GAME_STRAT_OBJECT_BLOCK_SIZE
            )
        );
        if (appended < 0 || (size_t)appended >= output_capacity - used) {
            output[output_capacity - 1u] = '\0';
            return;
        }
        used += (size_t)appended;
    }
    if (used >= output_capacity) {
        return;
    }
    int appended = snprintf(
        output + used,
        output_capacity - used,
        "],\"object_probe_blocks\":["
    );
    if (appended < 0 || (size_t)appended >= output_capacity - used) {
        output[output_capacity - 1u] = '\0';
        return;
    }
    used += (size_t)appended;
    const u32 probe_blocks[GAME_STRAT_OBJECT_PROBE_BLOCK_COUNT] = {
        2u,
        8u,
        11u,
        12u,
        15u,
    };
    for (
        u32 probe_index = 0u;
        probe_index < GAME_STRAT_OBJECT_PROBE_BLOCK_COUNT;
        ++probe_index
    ) {
        const u32 byte_offset =
            probe_blocks[probe_index] * GAME_STRAT_OBJECT_BLOCK_SIZE;
        appended = snprintf(
            output + used,
            output_capacity - used,
            "%s{\"offset\":%u,\"words\":[",
            probe_index == 0u ? "" : ",",
            byte_offset
        );
        if (appended < 0 || (size_t)appended >= output_capacity - used) {
            output[output_capacity - 1u] = '\0';
            return;
        }
        used += (size_t)appended;
        for (u32 word_index = 0u; word_index < 8u; ++word_index) {
            appended = snprintf(
                output + used,
                output_capacity - used,
                "%s\"0x%08X\"",
                word_index == 0u ? "" : ",",
                mem_read32(
                    cpu,
                    object + byte_offset + word_index * sizeof(u32)
                )
            );
            if (
                appended < 0 ||
                (size_t)appended >= output_capacity - used
            ) {
                output[output_capacity - 1u] = '\0';
                return;
            }
            used += (size_t)appended;
        }
        appended = snprintf(
            output + used,
            output_capacity - used,
            "]}"
        );
        if (appended < 0 || (size_t)appended >= output_capacity - used) {
            output[output_capacity - 1u] = '\0';
            return;
        }
        used += (size_t)appended;
    }
    if (used >= output_capacity) {
        return;
    }
    appended = snprintf(
        output + used,
        output_capacity - used,
        "],\"physics_words\":["
    );
    if (appended < 0 || (size_t)appended >= output_capacity - used) {
        output[output_capacity - 1u] = '\0';
        return;
    }
    used += (size_t)appended;
    for (u32 word_index = 0u; word_index < 32u; ++word_index) {
        appended = snprintf(
            output + used,
            output_capacity - used,
            "%s\"0x%08X\"",
            word_index == 0u ? "" : ",",
            mem_read32(cpu, object + 0x280u + word_index * sizeof(u32))
        );
        if (appended < 0 || (size_t)appended >= output_capacity - used) {
            output[output_capacity - 1u] = '\0';
            return;
        }
        used += (size_t)appended;
    }
    const u32 script_event = mem_read32(cpu, object + 0x1E0u);
    appended = snprintf(
        output + used,
        output_capacity - used,
        "],\"script_event\":{\"pointer\":\"0x%08X\",\"words\":[",
        script_event
    );
    if (appended < 0 || (size_t)appended >= output_capacity - used) {
        output[output_capacity - 1u] = '\0';
        return;
    }
    used += (size_t)appended;
    if (guest_range_valid(cpu, script_event, 6u * sizeof(u32))) {
        for (u32 word_index = 0u; word_index < 6u; ++word_index) {
            appended = snprintf(
                output + used,
                output_capacity - used,
                "%s\"0x%08X\"",
                word_index == 0u ? "" : ",",
                mem_read32(cpu, script_event + word_index * sizeof(u32))
            );
            if (
                appended < 0 ||
                (size_t)appended >= output_capacity - used
            ) {
                output[output_capacity - 1u] = '\0';
                return;
            }
            used += (size_t)appended;
        }
    }
    if (used < output_capacity) {
        (void)snprintf(output + used, output_capacity - used, "]}");
    }
}

static void write_sync_trace_frame(
    BootTrace* trace, CPUState* cpu, u32 checkpoint_pc
) {
    const bool pre_update_sample =
        checkpoint_pc == GAME_LOGICAL_UPDATE_ENTRY;
    if (
        !sync_trace_replay_ready(trace, cpu) ||
        trace->sync_trace_complete ||
        (
            !pre_update_sample &&
            !trace->sync_input_current_valid
        )
    ) {
        return;
    }
    if (trace->sync_presentation_repeat_count != 0u) {
        if (
            trace->sync_trace_frame_count >=
            trace->sync_presentation_repeat_count
        ) {
            trace->sync_trace_failed = true;
            return;
        }
        const u32 required = trace->sync_presentation_repeats[
            trace->sync_trace_frame_count
        ];
        trace->sync_presentation_occurrence++;
        if (trace->sync_presentation_occurrence < required) {
            return;
        }
        if (trace->sync_presentation_occurrence != required) {
            trace->sync_trace_failed = true;
            return;
        }
        trace->sync_presentation_occurrence = 0u;
    }
    const u32 sample_index =
        pre_update_sample
            ? trace->sync_input_next_index
            : trace->sync_input_current_index;
    if (
        sample_index >= trace->sync_input_sample_count ||
        sample_index != trace->sync_trace_frame_count
    ) {
        trace->sync_trace_failed = true;
        return;
    }
    const bool gx_summary_from_completed_frame =
        trace->gx_current_frame_byte_count == 0u;
    if (
        checkpoint_pc == GX_END_FRAME_WRITE &&
        gx_summary_from_completed_frame
    ) {
        /*
         * The legacy GX checkpoint is the store that closes a non-empty
         * command interval. Keep that invariant strict. The logical-update
         * checkpoint intentionally runs before rendering, so it reuses the
         * most recently completed command summary instead.
         */
        trace->sync_trace_failed = true;
        return;
    }
    const u64 gx_summary_byte_count =
        gx_summary_from_completed_frame
            ? trace->gx_last_frame_byte_count
            : trace->gx_current_frame_byte_count;
    const u64 gx_summary_write_count =
        gx_summary_from_completed_frame
            ? trace->gx_last_frame_write_count
            : trace->gx_current_frame_write_count;
    const u64 gx_summary_hash =
        gx_summary_from_completed_frame
            ? trace->gx_last_frame_hash
            : trace->gx_current_frame_hash;
    capture_sync_memory(trace, cpu);
    if (trace->sync_memory_capture_failed) {
        trace->sync_trace_failed = true;
        return;
    }
    /*
     * 0x800396EC is the pre-update fencepost. Its first row must describe
     * the imported state before sample zero has reached KPADRead, while the
     * row's input identity names the sample that will drive the transition
     * beginning at that fencepost. Subsequent entry rows similarly bind the
     * next unconsumed sample. GX and 0x80039774 retain their consumed-sample
     * contract through sync_input_current.
     */
    const SyncInputSample* sample =
        pre_update_sample
            ? &trace->sync_input_samples[sample_index]
            : &trace->sync_input_current;
    const u64 sample_hash =
        pre_update_sample
            ? sync_input_sample_hash(trace, sample)
            : fnv1a_guest_bytes(
                  cpu,
                  trace->kpad_last_buffer,
                  KPAD_STATUS_SIZE
              );
    const u32 script_manager = mem_read32(
        cpu,
        GAME_SCRIPT_MANAGER_POINTER
    );
    const u32 player_object =
        guest_range_valid(
            cpu,
            script_manager + GAME_SCRIPT_MANAGER_PLAYER_OFFSET,
            sizeof(u32)
        )
            ? mem_read32(
                  cpu,
                  script_manager +
                      GAME_SCRIPT_MANAGER_PLAYER_OFFSET
              )
            : 0u;
    const u32 camera_object =
        guest_range_valid(
            cpu,
            script_manager + GAME_SCRIPT_MANAGER_CAMERA_OFFSET,
            sizeof(u32)
        )
            ? mem_read32(
                  cpu,
                  script_manager +
                      GAME_SCRIPT_MANAGER_CAMERA_OFFSET
              )
            : 0u;
    const bool player_available = guest_range_valid(
        cpu,
        player_object + GAME_STRAT_POSITION_OFFSET,
        GAME_STRAT_TRANSFORM_SIZE
    );
    const bool camera_available = guest_range_valid(
        cpu,
        camera_object + GAME_STRAT_POSITION_OFFSET,
        GAME_STRAT_TRANSFORM_SIZE
    );
    char player_state_words_json[192];
    char camera_state_words_json[192];
    char player_object_hashes_json[4096];
    char camera_object_hashes_json[4096];
    format_gameplay_state_words_json(
        cpu,
        player_available,
        player_object,
        player_state_words_json,
        sizeof(player_state_words_json)
    );
    format_gameplay_state_words_json(
        cpu,
        camera_available,
        camera_object,
        camera_state_words_json,
        sizeof(camera_state_words_json)
    );
    format_gameplay_object_hashes_json(
        cpu,
        player_available,
        player_object,
        player_object_hashes_json,
        sizeof(player_object_hashes_json)
    );
    format_gameplay_object_hashes_json(
        cpu,
        camera_available,
        camera_object,
        camera_object_hashes_json,
        sizeof(camera_object_hashes_json)
    );
    const u32 title_script_instruction_pointer = mem_read32(
        cpu,
        GAME_TITLE_SCRIPT_CONTEXT + GAME_SCRIPT_CONTEXT_IP_OFFSET
    );
    u32 delta_index = 0u;
    const u32 frame_delta_microseconds =
        sync_frame_delta_index(trace, &delta_index)
            ? trace->sync_frame_deltas[delta_index]
            : mem_read32(cpu, GAME_FRAME_DELTA_MICROSECONDS);
    bool wrote = fprintf(
        trace->sync_trace_file,
        "{\"frame_id\":%u,\"checkpoint_pc\":\"0x%08X\","
        "\"checkpoint_lr\":\"0x%08X\",\"input\":{"
        "\"poll_id\":%u,\"hold\":%u,\"trigger\":%u,"
        "\"release\":%u,\"kpad_fnv1a64\":\"%016" PRIX64 "\"},"
        "\"game_state\":\"%s\","
        "\"content\":{\"path\":\"%s\","
        "\"completed_request_count\":%" PRIu64 "},"
        "\"timing\":{\"frame_delta_microseconds\":%u,"
        "\"global_update_counter\":%u},"
        "\"player\":{\"available\":%s,"
        "\"binding\":\"ass_IsPlayer\","
        "\"pointer\":\"0x%08X\","
        "\"position\":[%.9g,%.9g,%.9g],"
        "\"transform_fnv1a64\":\"%016" PRIX64 "\"%s%s},"
        "\"camera\":{\"available\":%s,"
        "\"binding\":\"ass_IsCamera\","
        "\"pointer\":\"0x%08X\","
        "\"position\":[%.9g,%.9g,%.9g],"
        "\"transform_fnv1a64\":\"%016" PRIX64 "\"%s%s},"
        "\"diagnostics\":{\"kpad_reads\":%u,"
        "\"kpad_first_caller\":\"0x%08X\","
        "\"kpad_last_caller\":\"0x%08X\","
        "\"controller_manager_calls\":%u,"
        "\"controller_manager_updates\":%u,"
        "\"controller_manager_update_callers\":["
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\"],"
        "\"controller_updates\":%u,"
        "\"controller_update_calls\":%u,"
        "\"controller_update_call_objects\":["
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\"],"
        "\"controller_update_call_slots\":[%u,%u,%u,%u],"
        "\"controller_update_callers\":["
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\"],"
        "\"controller_update_objects\":["
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\"],"
        "\"controller_post_kpad\":%u,"
        "\"controller_post_kpad_callers\":["
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\"],"
        "\"controller_manager_fnv1a64\":\"%016" PRIX64 "\","
        "\"controller_input_state_fnv1a64\":\"%016" PRIX64 "\","
        "\"controller_slot_0\":%d,"
        "\"controller_connection_0\":%d,"
        "\"controller_channel\":%u,"
        "\"controller_history_index\":%u,"
        "\"controller_hold\":%u,"
        "\"controller_trigger\":%u,"
        "\"controller_release\":%u,"
        "\"save_asset_loads\":%u,"
        "\"save_asset_load_caller\":\"0x%08X\","
        "\"save_metadata_inits\":%u,"
        "\"save_metadata_init_caller\":\"0x%08X\","
        "\"save_manager_inits\":%u,"
        "\"save_manager_init_caller\":\"0x%08X\","
        "\"save_script_loads\":%u,"
        "\"save_script_load_caller\":\"0x%08X\","
        "\"save_asset_loads_total\":%" PRIu64 ","
        "\"save_metadata_inits_total\":%" PRIu64 ","
        "\"save_manager_inits_total\":%" PRIu64 ","
        "\"save_script_loads_total\":%" PRIu64 ","
        "\"title_script_instruction_pointer\":\"0x%08X\","
        "\"title_script_instruction\":\"0x%08X\","
        "\"title_script_flags\":\"0x%08X\","
        "\"title_script_wait\":%u,"
        "\"title_script_var5\":\"0x%08X\","
        "\"title_script_var15\":\"0x%08X\","
        "\"title_script_var16\":\"0x%08X\","
        "\"title_script_var17\":\"0x%08X\","
        "\"title_script_var18\":\"0x%08X\","
        "\"title_script_var19\":\"0x%08X\","
        "\"title_script_var20\":\"0x%08X\","
        "\"title_script_var21\":\"0x%08X\","
        "\"title_script_vm_register_0\":\"0x%08X\","
        "\"script_event_vm_dispatches\":%u,"
        "\"script_event_vm_last_instruction_pointer\":\"0x%08X\","
        "\"script_event_vm_last_instruction\":\"0x%08X\","
        "\"script_event_vm_last_base29\":\"0x%08X\","
        "\"script_event_vm_last_base30\":\"0x%08X\","
        "\"script_event_vm_last_base31\":\"0x%08X\","
        "\"script_spawn_count\":%" PRIu64 ","
        "\"script_spawn_object\":\"0x%08X\","
        "\"script_spawn_handle\":\"0x%08X\","
        "\"script_spawn_flags\":\"0x%08X\","
        "\"script_spawn_filter\":\"0x%08X\","
        "\"script_spawn_next\":\"0x%08X\","
        "\"script_spawn_previous\":\"0x%08X\","
        "\"script_spawn_vm_dispatches\":%u,"
        "\"script_spawn_vm_first_instruction_pointer\":\"0x%08X\","
        "\"script_spawn_vm_last_instruction_pointer\":\"0x%08X\","
        "\"script_spawn_vm_last_instruction\":\"0x%08X\","
        "\"script_spawn_instruction_pointer\":\"0x%08X\","
        "\"script_spawn_instruction\":\"0x%08X\","
        "\"script_spawn_stack\":\"0x%08X\","
        "\"script_spawn_base\":\"0x%08X\","
        "\"script_spawn_event_table\":\"0x%08X\","
        "\"script_spawn_active_event\":\"0x%08X\","
        "\"script_spawn_owner\":\"0x%08X\","
        "\"script_spawn_wait\":%u,"
        "\"script_spawn_window\":["
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\","
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\","
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\","
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\"],"
        "\"title_script_window\":["
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\","
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\","
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\","
        "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\"],"
        "\"title_script_context_fnv1a64\":\"%016" PRIX64 "\","
        "\"content_requests_total\":%" PRIu64 ","
        "\"last_requested_path\":\"%s\","
        "\"last_completed_path\":\"%s\","
        "\"dvd_callbacks_total\":%" PRIu64 ","
        "\"dvd_callbacks_pending\":%u,",
        trace->sync_trace_frame_count,
        checkpoint_pc,
        cpu->lr,
        sample_index,
        sample->hold,
        sample->trigger,
        sample->release,
        sample_hash,
        strcmp(trace->sync_trace_anchor_path, "99_99.gcs") == 0
            ? (
                  trace->sync_input_has_non_neutral
                      ? "title_content_loaded_input_replay"
                      : "title_content_loaded_neutral_input"
              )
            : (
                  trace->sync_input_has_non_neutral
                      ? "gameplay_input_replay"
                      : "gameplay_neutral_input"
              ),
        trace->sync_trace_anchor_path,
        trace->file_read_completion_count,
        frame_delta_microseconds,
        mem_read32(cpu, GAME_GLOBAL_UPDATE_COUNTER),
        player_available ? "true" : "false",
        player_object,
        player_available
            ? read_guest_float_if_valid(
                  cpu,
                  player_object + GAME_STRAT_POSITION_OFFSET
              )
            : 0.0f,
        player_available
            ? read_guest_float_if_valid(
                  cpu,
                  player_object + GAME_STRAT_POSITION_OFFSET + 4u
              )
            : 0.0f,
        player_available
            ? read_guest_float_if_valid(
                  cpu,
                  player_object + GAME_STRAT_POSITION_OFFSET + 8u
              )
            : 0.0f,
        player_available
            ? fnv1a_guest_bytes(
                  cpu,
                  player_object + GAME_STRAT_POSITION_OFFSET,
                  GAME_STRAT_TRANSFORM_SIZE
              )
            : 0u,
        player_state_words_json,
        player_object_hashes_json,
        camera_available ? "true" : "false",
        camera_object,
        camera_available
            ? read_guest_float_if_valid(
                  cpu,
                  camera_object + GAME_STRAT_POSITION_OFFSET
              )
            : 0.0f,
        camera_available
            ? read_guest_float_if_valid(
                  cpu,
                  camera_object + GAME_STRAT_POSITION_OFFSET + 4u
              )
            : 0.0f,
        camera_available
            ? read_guest_float_if_valid(
                  cpu,
                  camera_object + GAME_STRAT_POSITION_OFFSET + 8u
              )
            : 0.0f,
        camera_available
            ? fnv1a_guest_bytes(
                  cpu,
                  camera_object + GAME_STRAT_POSITION_OFFSET,
                  GAME_STRAT_TRANSFORM_SIZE
              )
            : 0u,
        camera_state_words_json,
        camera_object_hashes_json,
        trace->sync_frame_kpad_read_count,
        trace->sync_frame_kpad_first_caller,
        trace->sync_frame_kpad_last_caller,
        trace->sync_frame_controller_manager_call_count,
        trace->sync_frame_controller_manager_update_count,
        trace->sync_frame_controller_manager_update_callers[0],
        trace->sync_frame_controller_manager_update_callers[1],
        trace->sync_frame_controller_manager_update_callers[2],
        trace->sync_frame_controller_manager_update_callers[3],
        trace->sync_frame_controller_update_count,
        trace->sync_frame_controller_update_call_count,
        trace->sync_frame_controller_update_call_objects[0],
        trace->sync_frame_controller_update_call_objects[1],
        trace->sync_frame_controller_update_call_objects[2],
        trace->sync_frame_controller_update_call_objects[3],
        trace->sync_frame_controller_update_call_slots[0],
        trace->sync_frame_controller_update_call_slots[1],
        trace->sync_frame_controller_update_call_slots[2],
        trace->sync_frame_controller_update_call_slots[3],
        trace->sync_frame_controller_update_callers[0],
        trace->sync_frame_controller_update_callers[1],
        trace->sync_frame_controller_update_callers[2],
        trace->sync_frame_controller_update_callers[3],
        trace->sync_frame_controller_update_objects[0],
        trace->sync_frame_controller_update_objects[1],
        trace->sync_frame_controller_update_objects[2],
        trace->sync_frame_controller_update_objects[3],
        trace->sync_frame_controller_post_kpad_count,
        trace->sync_frame_controller_post_kpad_callers[0],
        trace->sync_frame_controller_post_kpad_callers[1],
        trace->sync_frame_controller_post_kpad_callers[2],
        trace->sync_frame_controller_post_kpad_callers[3],
        fnv1a_guest_bytes(cpu, GAME_CONTROLLER_MANAGER, 0x300u),
        fnv1a_guest_bytes(cpu, GAME_CONTROLLER_OBJECT + 2048u, 192u),
        trace->game_controller_slot_states[0],
        trace->game_controller_connection_states[0],
        mem_read32(cpu, GAME_CONTROLLER_OBJECT + 2048u),
        mem_read32(cpu, GAME_CONTROLLER_OBJECT + 2052u),
        mem_read32(cpu, GAME_CONTROLLER_OBJECT + 2108u),
        mem_read32(cpu, GAME_CONTROLLER_OBJECT + 2112u),
        mem_read32(cpu, GAME_CONTROLLER_OBJECT + 2116u),
        trace->sync_frame_save_asset_load_count,
        trace->sync_frame_save_asset_load_caller,
        trace->sync_frame_save_metadata_init_count,
        trace->sync_frame_save_metadata_init_caller,
        trace->sync_frame_save_manager_init_count,
        trace->sync_frame_save_manager_init_caller,
        trace->sync_frame_save_script_load_count,
        trace->sync_frame_save_script_load_caller,
        trace->save_packaged_asset_load_count,
        trace->save_metadata_init_count,
        trace->save_manager_init_count,
        trace->save_script_load_count,
        title_script_instruction_pointer,
        read_guest_instruction_if_valid(
            cpu,
            title_script_instruction_pointer
        ),
        mem_read32(cpu, GAME_TITLE_SCRIPT_CONTEXT + 432u),
        mem_read16(cpu, GAME_TITLE_SCRIPT_CONTEXT + 608u),
        mem_read32(cpu, GAME_TITLE_SCRIPT_VARIABLES + 5u * 4u),
        mem_read32(cpu, GAME_TITLE_SCRIPT_VARIABLES + 15u * 4u),
        mem_read32(cpu, GAME_TITLE_SCRIPT_VARIABLES + 16u * 4u),
        mem_read32(cpu, GAME_TITLE_SCRIPT_VARIABLES + 17u * 4u),
        mem_read32(cpu, GAME_TITLE_SCRIPT_VARIABLES + 18u * 4u),
        mem_read32(cpu, GAME_TITLE_SCRIPT_VARIABLES + 19u * 4u),
        mem_read32(cpu, GAME_TITLE_SCRIPT_VARIABLES + 20u * 4u),
        mem_read32(cpu, GAME_TITLE_SCRIPT_VARIABLES + 21u * 4u),
        mem_read32(
            cpu,
            mem_read32(cpu, GAME_TITLE_SCRIPT_CONTEXT + 472u)
        ),
        trace->sync_frame_script_event_vm_dispatch_count,
        trace->sync_frame_script_event_vm_last_instruction_pointer,
        trace->sync_frame_script_event_vm_last_instruction,
        trace->sync_frame_script_event_vm_last_base29,
        trace->sync_frame_script_event_vm_last_base30,
        trace->sync_frame_script_event_vm_last_base31,
        trace->script_spawn_count,
        trace->script_spawn_object,
        trace->script_spawn_handle,
        trace->script_spawn_object
            ? mem_read32(cpu, trace->script_spawn_object + 432u)
            : 0u,
        trace->script_spawn_object
            ? mem_read32(cpu, trace->script_spawn_object + 436u)
            : 0u,
        trace->script_spawn_object
            ? mem_read32(cpu, trace->script_spawn_object + 440u)
            : 0u,
        trace->script_spawn_object
            ? mem_read32(cpu, trace->script_spawn_object + 444u)
            : 0u,
        trace->sync_frame_script_spawn_vm_dispatch_count,
        trace->sync_frame_script_spawn_vm_first_instruction_pointer,
        trace->sync_frame_script_spawn_vm_last_instruction_pointer,
        trace->sync_frame_script_spawn_vm_last_instruction,
        trace->script_spawn_object
            ? mem_read32(cpu, trace->script_spawn_object + 464u)
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u)
              )
            : 0u,
        trace->script_spawn_object
            ? mem_read32(cpu, trace->script_spawn_object + 468u)
            : 0u,
        trace->script_spawn_object
            ? mem_read32(cpu, trace->script_spawn_object + 472u)
            : 0u,
        trace->script_spawn_object
            ? mem_read32(cpu, trace->script_spawn_object + 476u)
            : 0u,
        trace->script_spawn_object
            ? mem_read32(cpu, trace->script_spawn_object + 480u)
            : 0u,
        trace->script_spawn_object
            ? mem_read32(cpu, trace->script_spawn_object + 484u)
            : 0u,
        trace->script_spawn_object
            ? mem_read16(cpu, trace->script_spawn_object + 608u)
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) - 48u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) - 44u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) - 40u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) - 36u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) - 32u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) - 28u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) - 24u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) - 20u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) - 16u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) - 12u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) - 8u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) - 4u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u)
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) + 4u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) + 8u
              )
            : 0u,
        trace->script_spawn_object
            ? read_guest_instruction_if_valid(
                  cpu,
                  mem_read32(cpu, trace->script_spawn_object + 464u) + 12u
              )
            : 0u,
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer - 48u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer - 44u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer - 40u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer - 36u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer - 32u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer - 28u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer - 24u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer - 20u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer - 16u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer - 12u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer - 8u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer - 4u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer + 4u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer + 8u
        ),
        read_guest_instruction_if_valid(
            cpu, title_script_instruction_pointer + 12u
        ),
        fnv1a_guest_bytes(cpu, GAME_TITLE_SCRIPT_CONTEXT, 552u),
        trace->file_read_count,
        trace->last_file_read.relative_path[0]
            ? trace->last_file_read.relative_path
            : "-",
        trace->last_completed_file_read.relative_path[0]
            ? trace->last_completed_file_read.relative_path
            : "-",
        trace->dvd_async_callback_count,
        trace->dvd_async_callback_queue_count
    ) > 0;
    if (wrote) {
        wrote = fprintf(trace->sync_trace_file, "\"gameplay_calls\":{") > 0;
    }
    for (
        u32 index = 0u;
        wrote && index < GAMEPLAY_OBSERVABLE_COUNT;
        ++index
    ) {
        u64 event_hash =
            trace->sync_frame_gameplay_observable[index] == 0u
                ? FNV1A64_OFFSET
                : trace->sync_frame_gameplay_observable_hash[index];
        if (index == GAMEPLAY_OBSERVABLE_SPAWN_AFTER_S) {
            for (
                u32 output_index = 0u;
                output_index < trace->sync_frame_spawn_output_count;
                ++output_index
            ) {
                const u32 output_address =
                    trace->sync_frame_spawn_output_addresses[output_index];
                const u32 output_value =
                    guest_range_valid(cpu, output_address, sizeof(u32))
                        ? mem_read32(cpu, output_address)
                        : 0u;
                event_hash = fnv1a_u32_be(event_hash, output_address);
                event_hash = fnv1a_u32_be(event_hash, output_value);
                if (trace->gameplay_call_diagnostics) {
                    fprintf(
                        stderr,
                        "spawn_after_s_output frame=%u address=0x%08X "
                        "value=0x%08X\n",
                        trace->sync_trace_frame_count,
                        output_address,
                        output_value
                    );
                }
            }
        }
        if (index == GAMEPLAY_OBSERVABLE_SPAWN_AFTER) {
            for (
                u32 return_index = 0u;
                return_index < trace->sync_frame_spawn_after_return_count;
                ++return_index
            ) {
                const u32 return_value =
                    trace->sync_frame_spawn_after_return_values[return_index];
                event_hash = fnv1a_u32_be(event_hash, return_value);
                if (trace->gameplay_call_diagnostics) {
                    fprintf(
                        stderr,
                        "spawn_after_return frame=%u value=0x%08X\n",
                        trace->sync_trace_frame_count,
                        return_value
                    );
                }
            }
            if (
                trace->gameplay_call_diagnostics &&
                trace->sync_frame_spawn_after_pending_count !=
                    trace->sync_frame_spawn_after_return_count
            ) {
                fprintf(
                    stderr,
                    "spawn_after_return_unpaired frame=%u pending=%u "
                    "returned=%u\n",
                    trace->sync_trace_frame_count,
                    trace->sync_frame_spawn_after_pending_count,
                    trace->sync_frame_spawn_after_return_count
                );
            }
        }
        wrote = fprintf(
            trace->sync_trace_file,
            "%s\"%s\":{\"frame\":%u,\"total\":%" PRIu64
            ",\"event_fnv1a64\":\"%016" PRIX64 "\"}",
            index == 0u ? "" : ",",
            GAMEPLAY_OBSERVABLE_NAMES[index],
            trace->sync_frame_gameplay_observable[index],
            trace->gameplay_observable_total[index],
            event_hash
        ) > 0;
    }
    if (wrote) {
        const u32 random_stream_count =
            mem_read32(cpu, GAME_RANDOM_STREAM_COUNT);
        const u32 random_stream_table =
            mem_read32(cpu, GAME_RANDOM_STREAM_TABLE_POINTER);
        wrote = fprintf(
            trace->sync_trace_file,
            "}},\"rng\":{\"stream_count\":%u,"
            "\"table\":\"0x%08X\",\"states\":["
            "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\","
            "\"0x%08X\",\"0x%08X\",\"0x%08X\",\"0x%08X\"]},"
            "\"gx\":{\"submission_serial\":%u,"
            "\"checkpoint_kind\":\"translated_fifo_command_stream\","
            "\"summary_source\":\"%s\","
            "\"command_bytes\":%" PRIu64 ","
            "\"command_writes\":%" PRIu64 ","
            "\"implementation_hash\":\"%016" PRIX64 "\"}}\n",
            random_stream_count,
            random_stream_table,
            mem_read32(cpu, random_stream_table + 0u * GAME_RANDOM_STREAM_STRIDE),
            mem_read32(cpu, random_stream_table + 1u * GAME_RANDOM_STREAM_STRIDE),
            mem_read32(cpu, random_stream_table + 2u * GAME_RANDOM_STREAM_STRIDE),
            mem_read32(cpu, random_stream_table + 3u * GAME_RANDOM_STREAM_STRIDE),
            mem_read32(cpu, random_stream_table + 4u * GAME_RANDOM_STREAM_STRIDE),
            mem_read32(cpu, random_stream_table + 5u * GAME_RANDOM_STREAM_STRIDE),
            mem_read32(cpu, random_stream_table + 6u * GAME_RANDOM_STREAM_STRIDE),
            mem_read32(cpu, random_stream_table + 7u * GAME_RANDOM_STREAM_STRIDE),
            trace->sync_trace_frame_count,
            gx_summary_from_completed_frame
                ? "prior_completed_frame"
                : "current_command_interval",
            gx_summary_byte_count,
            gx_summary_write_count,
            gx_summary_hash
        ) > 0;
    }
    if (!wrote || fflush(trace->sync_trace_file) != 0) {
        trace->sync_trace_failed = true;
        return;
    }
    trace->sync_trace_frame_count++;
    trace->sync_input_current_valid = false;
    trace->sync_frame_kpad_read_count = 0u;
    trace->sync_frame_kpad_first_caller = 0u;
    trace->sync_frame_kpad_last_caller = 0u;
    trace->sync_frame_controller_manager_call_count = 0u;
    trace->sync_frame_controller_manager_update_count = 0u;
    memset(
        trace->sync_frame_controller_manager_update_callers,
        0,
        sizeof(trace->sync_frame_controller_manager_update_callers)
    );
    trace->sync_frame_controller_update_count = 0u;
    trace->sync_frame_controller_update_call_count = 0u;
    memset(
        trace->sync_frame_controller_update_call_objects,
        0,
        sizeof(trace->sync_frame_controller_update_call_objects)
    );
    memset(
        trace->sync_frame_controller_update_call_slots,
        0,
        sizeof(trace->sync_frame_controller_update_call_slots)
    );
    memset(
        trace->sync_frame_controller_update_callers,
        0,
        sizeof(trace->sync_frame_controller_update_callers)
    );
    memset(
        trace->sync_frame_controller_update_objects,
        0,
        sizeof(trace->sync_frame_controller_update_objects)
    );
    trace->sync_frame_controller_post_kpad_count = 0u;
    memset(
        trace->sync_frame_controller_post_kpad_callers,
        0,
        sizeof(trace->sync_frame_controller_post_kpad_callers)
    );
    trace->sync_frame_save_asset_load_count = 0u;
    trace->sync_frame_save_asset_load_caller = 0u;
    trace->sync_frame_save_metadata_init_count = 0u;
    trace->sync_frame_save_metadata_init_caller = 0u;
    trace->sync_frame_save_manager_init_count = 0u;
    trace->sync_frame_save_manager_init_caller = 0u;
    trace->sync_frame_save_script_load_count = 0u;
    trace->sync_frame_save_script_load_caller = 0u;
    memset(
        trace->sync_frame_gameplay_observable,
        0,
        sizeof(trace->sync_frame_gameplay_observable)
    );
    memset(
        trace->sync_frame_gameplay_observable_hash,
        0,
        sizeof(trace->sync_frame_gameplay_observable_hash)
    );
    memset(
        trace->sync_frame_gameplay_last_signature,
        0,
        sizeof(trace->sync_frame_gameplay_last_signature)
    );
    trace->sync_frame_spawn_output_count = 0u;
    trace->sync_frame_spawn_after_pending_count = 0u;
    trace->sync_frame_spawn_after_return_count = 0u;
    trace->sync_frame_script_event_vm_dispatch_count = 0u;
    trace->sync_frame_script_event_vm_last_instruction_pointer = 0u;
    trace->sync_frame_script_event_vm_last_instruction = 0u;
    trace->sync_frame_script_event_vm_last_base29 = 0u;
    trace->sync_frame_script_event_vm_last_base30 = 0u;
    trace->sync_frame_script_event_vm_last_base31 = 0u;
    trace->sync_frame_script_spawn_vm_dispatch_count = 0u;
    trace->sync_frame_script_spawn_vm_first_instruction_pointer = 0u;
    trace->sync_frame_script_spawn_vm_last_instruction_pointer = 0u;
    trace->sync_frame_script_spawn_vm_last_instruction = 0u;
    trace->sync_trace_complete =
        trace->sync_trace_frame_count >=
        trace->sync_trace_frame_limit;
}

static bool is_mmio_address(u32 address) {
    /*
     * Explicit Wii hardware windows used by Broadway software:
     *   0x0C000000: GameCube-compatible PI/VI/DSP/AI/PE/CP/FIFO registers
     *   0x0D000000: Hollywood IPC and peripheral registers
     *   0x0D800000: Hollywood ACR/GPIO/IPC register mirror
     * Anything outside these three 64 KiB windows is an unexpected access.
     */
    return
        (address >= 0xCC000000u && address < 0xCC010000u) ||
        (address >= 0xCD000000u && address < 0xCD010000u) ||
        (address >= 0xCD800000u && address < 0xCD810000u);
}

static u32 ios_physical_to_cached(u32 address) {
    return address == 0u ? 0u : address + 0x80000000u;
}

static void capture_ios_path(
    BootTrace* trace, CPUState* cpu, u32 physical_address
) {
    u32 path = ios_physical_to_cached(physical_address);
    trace->last_ios_path[0] = '\0';
    if (path == 0u) {
        return;
    }
    for (size_t index = 0;
         index + 1u < sizeof(trace->last_ios_path);
         ++index) {
        u8 value = mem_read8(cpu, path + (u32)index);
        if (cpu->stop_reason != PROTECTOR_STOP_NONE || value == 0u) {
            trace->last_ios_path[index] = '\0';
            return;
        }
        trace->last_ios_path[index] = (char)value;
    }
    trace->last_ios_path[sizeof(trace->last_ios_path) - 1u] = '\0';
}

static void capture_ios_request(
    BootTrace* trace, CPUState* cpu, u32 physical_address
) {
    u32 request = ios_physical_to_cached(physical_address);
    trace->ios_request_count++;
    trace->last_ios_pc = cpu->pc;
    trace->last_ios_request = request;
    trace->last_ios_command = mem_read32(cpu, request);
    trace->last_ios_fd = mem_read32(cpu, request + 8u);
    trace->last_ios_ioctl = mem_read32(cpu, request + 12u);
    trace->last_ios_input = mem_read32(cpu, request + 16u);
    trace->last_ios_input_length = mem_read32(cpu, request + 20u);
    trace->last_ios_output = mem_read32(cpu, request + 24u);
    trace->last_ios_output_length = mem_read32(cpu, request + 28u);
    trace->last_ios_path[0] = '\0';
    if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
        return;
    }
    if (trace->last_ios_command == IOS_COMMAND_OPEN) {
        capture_ios_path(
            trace,
            cpu,
            mem_read32(cpu, request + 12u)
        );
    } else if (trace->last_ios_command == IOS_COMMAND_IOCTL) {
        capture_ios_path(trace, cpu, trace->last_ios_input);
        if (
            trace->last_ios_ioctl == IOS_FS_CREATE_FILE &&
            trace->last_ios_input_length >= 7u
        ) {
            /*
             * NANDCreate's /dev/fs request stores the two permission bytes
             * before its relative pathname. The first word is a separate
             * workspace pointer, not the created file's path.
             */
            capture_ios_path(
                trace,
                cpu,
                trace->last_ios_input + 6u
            );
        }
        if (
            trace->last_ios_path[0] != '/' &&
            trace->last_ios_input != 0u
        ) {
            u32 input =
                ios_physical_to_cached(trace->last_ios_input);
            capture_ios_path(trace, cpu, mem_read32(cpu, input));
        }
    }
    if (getenv("PROTECTOR_R2_DIAGNOSTICS")) {
        printf(
            "r2_ios_request frame=%" PRIu64
            " request=0x%08X command=%u fd=%u ioctl=%u"
            " input=0x%08X/%u output=0x%08X/%u path=%s\n",
            trace->gx_completed_frame_count,
            request,
            trace->last_ios_command,
            trace->last_ios_fd,
            trace->last_ios_ioctl,
            trace->last_ios_input,
            trace->last_ios_input_length,
            trace->last_ios_output,
            trace->last_ios_output_length,
            trace->last_ios_path[0] ? trace->last_ios_path : "-"
        );
    }
}

static void zero_guest_bytes(
    CPUState* cpu, u32 physical_address, u32 length
) {
    u32 address = ios_physical_to_cached(physical_address);
    if (address == 0u) {
        return;
    }
    for (u32 offset = 0u; offset < length; ++offset) {
        mem_write8(cpu, address + offset, 0u);
    }
}

static void zero_ios_output_vectors(
    BootTrace* trace, CPUState* cpu
) {
    u32 input_count = trace->last_ios_input;
    u32 output_count = trace->last_ios_input_length;
    u32 vectors = ios_physical_to_cached(trace->last_ios_output);
    if (vectors == 0u) {
        return;
    }
    for (u32 index = input_count;
         index < input_count + output_count;
         ++index) {
        u32 address = mem_read32(cpu, vectors + index * 8u);
        u32 length = mem_read32(cpu, vectors + index * 8u + 4u);
        zero_guest_bytes(cpu, address, length);
    }
}

static NativeNandFile* native_nand_file_for_path(
    BootTrace* trace, const char* path
) {
    if (strcmp(path, SAVED_GAMES_PATH) == 0) {
        return &trace->nand_files[0];
    }
    if (strcmp(path, SAVE_BANNER_PATH) == 0) {
        return &trace->nand_files[1];
    }
    return NULL;
}

static NativeNandFile* native_nand_file_for_fd(
    BootTrace* trace, u32 fd
) {
    if (fd == 0u || fd > NATIVE_NAND_FILE_COUNT) {
        return NULL;
    }
    return &trace->nand_files[fd - 1u];
}

static bool ensure_native_nand_capacity(
    NativeNandFile* file, size_t required
) {
    if (required <= file->capacity) {
        return true;
    }
    size_t capacity =
        file->capacity == 0u
            ? 32768u
            : file->capacity;
    while (capacity < required) {
        if (capacity > SIZE_MAX / 2u) {
            return false;
        }
        capacity *= 2u;
    }
    u8* resized = realloc(file->data, capacity);
    if (!resized) {
        return false;
    }
    file->data = resized;
    file->capacity = capacity;
    return true;
}

static s32 complete_ios_request(BootTrace* trace, CPUState* cpu) {
    u32 request = trace->last_ios_request;
    switch (trace->last_ios_command) {
        case IOS_COMMAND_OPEN:
            {
                NativeNandFile* file = native_nand_file_for_path(
                    trace,
                    trace->last_ios_path
                );
                if (!file) {
                    return 0;
                }
                if (!file->exists) {
                    return IOS_ERROR_NO_ENTRY;
                }
                file->open = true;
                file->offset = 0u;
                return (s32)(file - trace->nand_files + 1u);
            }
        case IOS_COMMAND_CLOSE:
            {
                NativeNandFile* file = native_nand_file_for_fd(
                    trace,
                    trace->last_ios_fd
                );
                if (file) {
                    if (file->dirty && trace->save_store_enabled) {
                        char error[256];
                        const unsigned slot = (unsigned)(file - trace->nand_files);
                        const bool committed = protector_save_store_write(&trace->save_store,
                            slot, file->data, file->size, error, sizeof(error));
                        protector_save_status_record(slot, committed);
                        ProtectorSaveStatus status;
                        protector_save_status_read(&status);
                        trace->save_store_failed = status.pending_failure_mask != 0;
                        if (!committed) {
                            fprintf(stderr, "save commit failed: %s\n", error);
                            return -5;
                        }
                        fprintf(stderr, "save committed: slot=%u bytes=%zu\n",
                            (unsigned)(file - trace->nand_files), file->size);
                        file->dirty = false;
                    }
                    file->open = false;
                }
                return 0;
            }
        case IOS_COMMAND_READ:
            {
                NativeNandFile* file = native_nand_file_for_fd(
                    trace,
                    trace->last_ios_fd
                );
                if (!file || !file->open) {
                    return 0;
                }
                u32 destination =
                    ios_physical_to_cached(mem_read32(cpu, request + 12u));
                u32 requested = mem_read32(cpu, request + 16u);
                size_t available =
                    file->offset < file->size
                        ? file->size - file->offset
                        : 0u;
                size_t length =
                    available < requested ? available : requested;
                for (size_t index = 0u; index < length; ++index) {
                    mem_write8(
                        cpu,
                        destination + (u32)index,
                        file->data[file->offset + index]
                    );
                }
                file->offset += length;
                return (s32)length;
            }
        case IOS_COMMAND_WRITE:
            {
                NativeNandFile* file = native_nand_file_for_fd(
                    trace,
                    trace->last_ios_fd
                );
                if (!file || !file->open) {
                    return 0;
                }
                u32 source =
                    ios_physical_to_cached(mem_read32(cpu, request + 12u));
                u32 length = mem_read32(cpu, request + 16u);
                size_t end = file->offset + length;
                if (
                    end < file->offset ||
                    (trace->save_store_enabled && end > PROTECTOR_SAVE_MAX_BYTES) ||
                    !ensure_native_nand_capacity(file, end)
                ) {
                    return -22;
                }
                if (file->offset > file->size) {
                    memset(
                        file->data + file->size,
                        0,
                        file->offset - file->size
                    );
                }
                for (u32 index = 0u; index < length; ++index) {
                    file->data[file->offset + index] =
                        mem_read8(cpu, source + index);
                }
                file->offset = end;
                if (end > file->size) {
                    file->size = end;
                }
                file->dirty = true;
                return (s32)length;
            }
        case IOS_COMMAND_SEEK:
            {
                NativeNandFile* file = native_nand_file_for_fd(
                    trace,
                    trace->last_ios_fd
                );
                if (!file || !file->open) {
                    return 0;
                }
                s32 offset = (s32)mem_read32(cpu, request + 12u);
                u32 origin = mem_read32(cpu, request + 16u);
                s64 base = origin == 1u
                               ? (s64)file->offset
                               : origin == 2u
                                     ? (s64)file->size
                                     : 0;
                s64 position = base + offset;
                if (origin > 2u || position < 0) {
                    return -4;
                }
                file->offset = (size_t)position;
                return (s32)position;
            }
        case IOS_COMMAND_IOCTL:
            if (trace->last_ios_ioctl == IOS_FS_GET_FILE_STATS) {
                NativeNandFile* file = native_nand_file_for_fd(trace, trace->last_ios_fd);
                if (!file || !file->open || trace->last_ios_output_length < 8u ||
                    trace->last_ios_output == 0u || file->size > UINT32_MAX ||
                    file->offset > UINT32_MAX) {
                    return -101;
                }
                const u32 output = ios_physical_to_cached(trace->last_ios_output);
                mem_write32(cpu, output, (u32)file->size);
                mem_write32(cpu, output + 4u, (u32)file->offset);
                return 0;
            }
            zero_guest_bytes(
                cpu,
                trace->last_ios_output,
                trace->last_ios_output_length
            );
            {
                NativeNandFile* file = native_nand_file_for_path(
                    trace,
                    trace->last_ios_path
                );
                if (
                    trace->last_ios_ioctl == IOS_FS_GET_ATTR &&
                    file &&
                    !file->exists
                ) {
                    return IOS_ERROR_NO_ENTRY;
                }
                if (
                    trace->last_ios_ioctl == IOS_FS_CREATE_FILE &&
                    file
                ) {
                    file->exists = true;
                    file->open = false;
                    file->size = 0u;
                    file->offset = 0u;
                    file->dirty = true;
                }
            }
            return 0;
        case IOS_COMMAND_IOCTLV:
            zero_ios_output_vectors(trace, cpu);
            return 0;
        default:
            return 0;
    }
}

static u64 trace_external_read(CPUState* cpu, u32 address, u8 size) {
    BootTrace* trace = (BootTrace*)cpu->external_user_data;
    trace->mmio_read_count++;
    trace->last_mmio_address = address;
    if (!is_mmio_address(address) || size > 4) {
        fprintf(
            stderr,
            "unexpected external read pc=%08X address=%08X size=%u "
            "r1=%08X r3=%08X r6=%08X r11=%08X ctr=%08X\n",
            cpu->pc,
            address,
            size,
            cpu->gpr[1],
            cpu->gpr[3],
            cpu->gpr[6],
            cpu->gpr[11],
            cpu->ctr
        );
        protector_stop(
            cpu,
            PROTECTOR_STOP_UNMAPPED_MEMORY,
            cpu->pc,
            0,
            address
        );
        return 0;
    }
    if (address == 0xCC003000u) {
        record_mmio(
            trace, cpu, address, trace->pi_interrupt_cause, size, false
        );
        return trace->pi_interrupt_cause;
    }
    if (address == 0xCC003004u) {
        record_mmio(
            trace, cpu, address, trace->pi_interrupt_mask, size, false
        );
        return trace->pi_interrupt_mask;
    }
    if (
        address == 0xCD000004u &&
        size == 4u
    ) {
        record_mmio(
            trace, cpu, address, trace->ipc_control, size, false
        );
        return trace->ipc_control;
    }
    if (
        address == 0xCD000008u &&
        size == 4u
    ) {
        record_mmio(
            trace, cpu, address, trace->ipc_arm_message, size, false
        );
        return trace->ipc_arm_message;
    }
    if (address == 0xCC00500Au && size == 2u) {
        /*
         * DSP reset is asynchronous on hardware. The deterministic harness
         * completes it at the first status poll after software asserts it.
         */
        trace->dsp_control &= (u16)~0x0001u;
        record_mmio(
            trace, cpu, address, trace->dsp_control, size, false
        );
        return trace->dsp_control;
    }
    if (size == 2u) {
        u16 value = 0u;
        switch (mmio_register_offset(address)) {
            case VI_INTERRUPT_REGISTER_0:
                value = trace->vi_interrupt_registers[0];
                break;
            case VI_INTERRUPT_REGISTER_1:
                value = trace->vi_interrupt_registers[1];
                break;
            case VI_INTERRUPT_REGISTER_2:
                value = trace->vi_interrupt_registers[2];
                break;
            case VI_INTERRUPT_REGISTER_3:
                value = trace->vi_interrupt_registers[3];
                break;
            case GX_PE_INTERRUPT_CONTROL:
                value = trace->pe_interrupt_control;
                break;
            case DSP_MAIL_TO_DSP_HI:
                value = (u16)(trace->dsp_mail_to_dsp >> 16);
                value = trace->dsp_mail_to_dsp_pending
                            ? (u16)(value | 0x8000u)
                            : (u16)(value & 0x7FFFu);
                break;
            case DSP_MAIL_TO_DSP_LO:
                value = (u16)trace->dsp_mail_to_dsp;
                break;
            case DSP_MAIL_FROM_DSP_HI:
                value = (u16)(trace->dsp_mail_from_dsp >> 16);
                value = trace->dsp_mail_from_dsp_pending
                            ? (u16)(value | 0x8000u)
                            : (u16)(value & 0x7FFFu);
                break;
            case DSP_MAIL_FROM_DSP_LO:
                value = (u16)trace->dsp_mail_from_dsp;
                trace->dsp_mail_from_dsp_pending = false;
                break;
            default:
                record_mmio(trace, cpu, address, 0, size, false);
                return 0;
        }
        record_mmio(trace, cpu, address, value, size, false);
        return value;
    }
    if (size == 4u) {
        u32 value = 0u;
        switch (mmio_register_offset(address)) {
            case AI_CONTROL_REGISTER:
                value = trace->ai_control;
                break;
            case AI_VOLUME_REGISTER:
                value = trace->ai_volume;
                break;
            case AI_SAMPLE_COUNTER:
                value = current_ai_sample_counter(trace, cpu);
                break;
            case AI_INTERRUPT_TIMING:
                value = trace->ai_interrupt_timing;
                break;
            default:
                record_mmio(trace, cpu, address, 0, size, false);
                return 0;
        }
        record_mmio(trace, cpu, address, value, size, false);
        return value;
    }
    record_mmio(trace, cpu, address, 0, size, false);
    return 0;
}

static void trace_external_write(
    CPUState* cpu, u32 address, u64 value, u8 size
) {
    BootTrace* trace = (BootTrace*)cpu->external_user_data;
    trace->mmio_write_count++;
    trace->last_mmio_address = address;
    record_mmio(trace, cpu, address, (u32)value, size, true);
    if (!is_mmio_address(address) || size > 4) {
        fprintf(
            stderr,
            "unexpected external write pc=%08X address=%08X size=%u "
            "value=%08X r1=%08X r11=%08X\n",
            cpu->pc,
            address,
            size,
            (u32)value,
            cpu->gpr[1],
            cpu->gpr[11]
        );
        protector_stop(
            cpu,
            PROTECTOR_STOP_UNMAPPED_MEMORY,
            cpu->pc,
            0,
            address
        );
        return;
    }
    /*
     * Paired-single stores reach the write-gather aperture as two adjacent
     * 32-bit stores. Every byte in the 16 KiB aperture belongs to one FIFO
     * stream; limiting capture to the base address drops the second component
     * and corrupts XF matrix uploads and vertex payloads.
     */
    if (is_gx_fifo_aperture(address)) {
        if (cpu->pc == 0x800E9B20u && protector_live_gx_has_sink() && !trace->gx_capture_failed)
            protector_motion_identity_fifo(&trace->motion_identity, cpu, trace->gx_capture_frame_size, value, size);
        record_gx_fifo_write(trace, value, size);
    }
    if (address == 0xCC003000u) {
        trace->pi_interrupt_cause = (u32)value;
    } else if (address == 0xCC003004u) {
        trace->pi_interrupt_mask = (u32)value;
    } else if (address == 0xCD000000u && size == 4u) {
        capture_ios_request(trace, cpu, (u32)value);
    } else if (address == 0xCD000004u && size == 4u) {
        u32 written = (u32)value;
        trace->ipc_control =
            (trace->ipc_control & 0x0Fu) | (written & 0x30u);
        if ((written & 0x02u) != 0u) {
            trace->ipc_control &= ~0x02u;
        }
        if ((written & 0x04u) != 0u) {
            trace->ipc_control &= ~0x04u;
        }
        if ((written & 0x08u) != 0u) {
            trace->ipc_control &= ~0x08u;
        }
        if (
            (written & 0x01u) != 0u &&
            trace->last_ios_request != 0u
        ) {
            const s32 ios_result = complete_ios_request(trace, cpu);
            mem_write32(
                cpu,
                trace->last_ios_request + 4u,
                (u32)ios_result
            );
            trace->ipc_arm_message =
                trace->last_ios_request - GC_RAM_BASE;
            trace->ipc_control =
                (trace->ipc_control & 0x30u) | 0x06u;
            trace->ipc_reply_pending = true;
            trace->pi_interrupt_cause |= 0x00004000u;
        }
    } else if (
        address == 0xCD000030u &&
        size == 4u
    ) {
        if (((u32)value & 0x40000000u) != 0u) {
            trace->pi_interrupt_cause &= ~0x00004000u;
        }
    } else if (address == 0xCC00500Au && size == 2u) {
        if (((u16)value & 0x0008u) != 0u) {
            trace->dsp_control &= (u16)~0x0008u;
        }
        trace->dsp_control =
            (trace->dsp_control & 0x0008u) |
            ((u16)value & (u16)~0x0008u);
    } else if (size == 2u) {
        switch (mmio_register_offset(address)) {
            case VI_INTERRUPT_REGISTER_0:
                trace->vi_interrupt_registers[0] = (u16)value;
                break;
            case VI_INTERRUPT_REGISTER_1:
                trace->vi_interrupt_registers[1] = (u16)value;
                break;
            case VI_INTERRUPT_REGISTER_2:
                trace->vi_interrupt_registers[2] = (u16)value;
                break;
            case VI_INTERRUPT_REGISTER_3:
                trace->vi_interrupt_registers[3] = (u16)value;
                break;
            case GX_PE_INTERRUPT_CONTROL:
                /*
                 * The SDK writes one to the PE interrupt-clear bits.
                 * Preserve the enable bits and consume the clear strobes.
                 */
                trace->pe_interrupt_control =
                    (u16)value & (u16)~0x000Cu;
                break;
            case DSP_MAIL_TO_DSP_HI:
                trace->dsp_mail_to_dsp =
                    (trace->dsp_mail_to_dsp & 0x0000FFFFu) |
                    ((u32)(u16)value << 16);
                break;
            case DSP_MAIL_TO_DSP_LO:
                trace->dsp_mail_to_dsp =
                    (trace->dsp_mail_to_dsp & 0xFFFF0000u) |
                    (u16)value;
                trace->dsp_mail_to_dsp_pending = true;
                trace->dsp_boot_command_count++;
                if (trace->ax_audio && trace->ax_audio->configured) {
                    if (!protector_ax_engine_mail(trace->ax_audio, cpu, trace->dsp_mail_to_dsp))
                        stop_ax_audio(cpu, trace, trace->ax_audio->error);
                    protector_ax_diagnostics_engine(&trace->ax_diagnostics, trace->ax_audio);
                    protector_ax_diagnostics_publish(&trace->ax_diagnostics);
                }
                /*
                 * The early-boot DSP seam consumes each command
                 * synchronously; translated SDK code still observes the
                 * mailbox-full transition at the write boundary.
                 */
                trace->dsp_mail_to_dsp_pending = false;
                break;
            default:
                break;
        }
    } else if (size == 4u) {
        if (
            is_gx_fifo_aperture(address) &&
            (u32)value == GX_PE_FINISH_COMMAND
        ) {
            /*
             * GXSetDrawDone emits PE_FINISH(2, 0x45) into the graphics FIFO.
             * A renderer is outside this milestone, but command completion is
             * not: queue one deterministic PE-finish interrupt so the real
             * translated SDK handler sets DrawDone and wakes FinishQueue.
             */
            trace->pe_finish_pending = true;
            /*
             * Before the canonical game-loop backedge is reachable,
             * GXSetDrawDone is the only authoritative presentation
             * boundary. Commit startup frames here so frame-clocked DVD
             * callbacks can progress. Once the backedge has executed, it
             * owns frame submission and this fallback becomes inert.
             */
            if (
                cpu->pc == GX_END_FRAME_WRITE &&
                trace->sync_trace_checkpoint_pc == GX_END_FRAME_WRITE
            ) {
                write_sync_trace_frame(trace, cpu, GX_END_FRAME_WRITE);
            }
            if (trace->frame_loop_count == 0u) {
                finish_gx_frame(trace, cpu);
            }
        }
        switch (mmio_register_offset(address)) {
            case AI_CONTROL_REGISTER: {
                u32 counter = current_ai_sample_counter(trace, cpu);
                u32 old_interrupt = trace->ai_control & 0x00000008u;
                trace->ai_sample_counter =
                    ((u32)value & 0x00000020u) != 0u ? 0u : counter;
                trace->ai_counter_timebase = cpu->timebase;
                trace->ai_control =
                    ((u32)value & 0x00000057u) |
                    (((u32)value & 0x00000008u) != 0u
                         ? 0u
                         : old_interrupt);
                break;
            }
            case AI_VOLUME_REGISTER:
                trace->ai_volume = (u32)value;
                break;
            case AI_SAMPLE_COUNTER:
                trace->ai_sample_counter = (u32)value;
                trace->ai_counter_timebase = cpu->timebase;
                break;
            case AI_INTERRUPT_TIMING:
                trace->ai_interrupt_timing = (u32)value;
                break;
            default:
                break;
        }
    }
}

static bool path_has_suffix(
    const char* path,
    const char* suffix
) {
    const size_t path_length = strlen(path);
    const size_t suffix_length = strlen(suffix);
    return
        path_length >= suffix_length &&
        strcmp(
            path + path_length - suffix_length,
            suffix
        ) == 0;
}

static void trace_dvd_async_state(
    CPUState* cpu,
    const BootTrace* trace,
    const char* phase,
    const DvdAsyncCallbackEvent* event
) {
    if (
        (!trace->gameplay_call_diagnostics && !trace->dvd_async_diagnostics) ||
        !event->file_read.relative_path[0]
    ) {
        return;
    }
    const bool file_info_valid = guest_range_valid(
        cpu, event->file_info, 64u
    );
    const u32 user_data =
        strcmp(phase, "post_callback") == 0
            ? event->request_user_data
            : (
                file_info_valid
                    ? mem_read32(cpu, event->file_info + 44u)
                    : 0u
            );
    const bool user_data_valid = guest_range_valid(
        cpu, user_data, 64u
    );
    const bool destination_valid = guest_range_valid(
        cpu,
        event->destination,
        event->file_read.requested_length
    );
    const bool loader_valid = guest_range_valid(
        cpu, event->request_r30 + 3076u, 40u
    );
    char file_info_words[16u * 9u];
    char user_data_words[16u * 9u];
    size_t word_cursor = 0u;
    file_info_words[0] = '\0';
    for (u32 index = 0u; index < 16u; ++index) {
        const int wrote = snprintf(
            file_info_words + word_cursor,
            sizeof(file_info_words) - word_cursor,
            index == 0u ? "%08X" : ",%08X",
            file_info_valid
                ? mem_read32(cpu, event->file_info + index * 4u)
                : 0u
        );
        if (
            wrote < 0 ||
            (size_t)wrote >=
                sizeof(file_info_words) - word_cursor
        ) {
            break;
        }
        word_cursor += (size_t)wrote;
    }
    word_cursor = 0u;
    user_data_words[0] = '\0';
    for (u32 index = 0u; index < 16u; ++index) {
        const int wrote = snprintf(
            user_data_words + word_cursor,
            sizeof(user_data_words) - word_cursor,
            index == 0u ? "%08X" : ",%08X",
            user_data_valid
                ? mem_read32(cpu, user_data + index * 4u)
                : 0u
        );
        if (
            wrote < 0 ||
            (size_t)wrote >=
                sizeof(user_data_words) - word_cursor
        ) {
            break;
        }
        word_cursor += (size_t)wrote;
    }
    fprintf(
        stderr,
        "dvd_async_%s serial=%" PRIu64
        " gx=%" PRIu64 " ready=%" PRIu64
        " path=%s offset=%u length=%u callback=0x%08X"
        " file_info=0x%08X destination=0x%08X user_data=0x%08X"
        " file_info_hash=%016" PRIX64
        " user_data_hash=%016" PRIX64
        " payload_hash=%016" PRIX64
        " stream_flag=%u stream_active=%u stream_result=%u"
        " r13=0x%08X request_r30=0x%08X"
        " loader_state=%u loader_offset=%u loader_destination=0x%08X"
        " loader_length=%u"
        " file_info_words=%s user_data_words=%s\n",
        phase,
        event->request_serial,
        trace->gx_completed_frame_count,
        event->ready_frame,
        event->file_read.relative_path,
        event->file_read.file_offset,
        event->file_read.requested_length,
        event->callback,
        event->file_info,
        event->destination,
        user_data,
        file_info_valid
            ? fnv1a_guest_bytes(cpu, event->file_info, 64u)
            : 0u,
        user_data_valid
            ? fnv1a_guest_bytes(cpu, user_data, 64u)
            : 0u,
        destination_valid
            ? fnv1a_guest_bytes(
                  cpu,
                  event->destination,
                  event->file_read.requested_length
              )
            : 0u,
        mem_read8(cpu, cpu->gpr[13] - 28915u),
        mem_read8(cpu, cpu->gpr[13] - 28914u),
        mem_read32(cpu, cpu->gpr[13] - 28912u),
        cpu->gpr[13],
        event->request_r30,
        loader_valid ? mem_read32(cpu, event->request_r30 + 3080u) : 0u,
        loader_valid ? mem_read32(cpu, event->request_r30 + 3096u) : 0u,
        loader_valid ? mem_read32(cpu, event->request_r30 + 3104u) : 0u,
        loader_valid ? mem_read32(cpu, event->request_r30 + 3112u) : 0u,
        file_info_words,
        user_data_words
    );
}

static bool start_dvd_async_transfer(
    CPUState* cpu,
    BootTrace* trace,
    DvdAsyncCallbackEvent* event
) {
    if (
        event->payload_started ||
        !event->file_read.relative_path[0]
    ) {
        return true;
    }
    if (
        !trace->mount ||
        !protector_complete_wii_file_read(
            cpu,
            trace->mount,
            &event->file_read,
            event->destination,
            trace->platform_error,
            sizeof(trace->platform_error)
        )
    ) {
        protector_stop(
            cpu,
            PROTECTOR_STOP_PLATFORM_ERROR,
            WII_SDK_DVD_READ_ASYNC_PRIO,
            0,
            event->file_read.disc_offset_words
        );
        return false;
    }
    event->payload_started = true;
    if (
        trace->first_content_hash == 0u &&
        event->file_info == trace->first_content_file_info &&
        event->destination == trace->first_content_destination &&
        event->file_read.disc_offset_words ==
            trace->first_content_disc_offset_words
    ) {
        trace->first_content_hash = fnv1a_guest_bytes(
            cpu,
            event->destination,
            event->file_read.requested_length
        );
    }
    return true;
}

static void trace_resource_manager_state(
    CPUState* cpu,
    const BootTrace* trace,
    u32 address
) {
    if (
        !trace->gameplay_call_diagnostics ||
        !trace->sync_trace_content_ready ||
        address != GAME_RESOURCE_MANAGER_POLL
    ) {
        return;
    }
    const u32 manager = cpu->gpr[3];
    const bool manager_valid = guest_range_valid(cpu, manager, 132u);
    const bool descriptors_valid = guest_range_valid(
        cpu,
        GAME_RESOURCE_DESCRIPTOR_BASE,
        GAME_RESOURCE_DESCRIPTOR_STRIDE *
            GAME_RESOURCE_DESCRIPTOR_COUNT
    );
    const u32 voice_manager =
        manager_valid ? mem_read32(cpu, manager + 76u) : 0u;
    const u32 voice_index =
        manager_valid ? mem_read32(cpu, manager + 108u) : 0u;
    const bool voice_slot_valid = guest_range_valid(
        cpu,
        voice_manager + 148u + voice_index * sizeof(u32),
        sizeof(u32)
    );
    const u32 voice = voice_slot_valid
        ? mem_read32(
              cpu,
              voice_manager + 148u + voice_index * sizeof(u32)
          )
        : 0u;
    const bool voice_valid = guest_range_valid(cpu, voice, 360u);
    const u32 packed_voice_address =
        voice_valid ? mem_read32(cpu, voice + 162u) : 0u;
    char descriptor_states[GAME_RESOURCE_DESCRIPTOR_COUNT * 76u];
    char live_descriptors[4096u];
    size_t cursor = 0u;
    descriptor_states[0] = '\0';
    for (
        u32 index = 0u;
        index < GAME_RESOURCE_DESCRIPTOR_COUNT;
        ++index
    ) {
        const u32 descriptor =
            GAME_RESOURCE_DESCRIPTOR_BASE +
            index * GAME_RESOURCE_DESCRIPTOR_STRIDE;
        const int wrote = snprintf(
            descriptor_states + cursor,
            sizeof(descriptor_states) - cursor,
            index == 0u
                ? "%u:%08X:%08X:%08X:%08X:%08X:%08X"
                : ",%u:%08X:%08X:%08X:%08X:%08X:%08X",
            index,
            descriptors_valid ? mem_read32(cpu, descriptor + 0u) : 0u,
            descriptors_valid ? mem_read32(cpu, descriptor + 8u) : 0u,
            descriptors_valid ? mem_read32(cpu, descriptor + 16u) : 0u,
            descriptors_valid ? mem_read32(cpu, descriptor + 20u) : 0u,
            descriptors_valid ? mem_read32(cpu, descriptor + 24u) : 0u,
            descriptors_valid ? mem_read32(cpu, descriptor + 28u) : 0u
        );
        if (
            wrote < 0 ||
            (size_t)wrote >=
                sizeof(descriptor_states) - cursor
        ) {
            break;
        }
        cursor += (size_t)wrote;
    }
    cursor = 0u;
    live_descriptors[0] = '\0';
    const u32 sentinel = manager + 12u;
    u32 descriptor = manager_valid ? mem_read32(cpu, sentinel) : sentinel;
    for (
        u32 ordinal = 0u;
        descriptor != sentinel && ordinal < 32u;
        ++ordinal
    ) {
        if (!guest_range_valid(cpu, descriptor, 52u)) {
            (void)snprintf(
                live_descriptors + cursor,
                sizeof(live_descriptors) - cursor,
                "%sinvalid:%08X",
                ordinal == 0u ? "" : ",",
                descriptor
            );
            break;
        }
        const int wrote = snprintf(
            live_descriptors + cursor,
            sizeof(live_descriptors) - cursor,
            ordinal == 0u
                ? "%u:%08X:%08X:%08X:%08X:%08X:%08X:%08X:%08X:%08X:%08X:%08X:%016" PRIX64
                : ",%u:%08X:%08X:%08X:%08X:%08X:%08X:%08X:%08X:%08X:%08X:%08X:%016" PRIX64,
            ordinal,
            descriptor,
            mem_read32(cpu, descriptor + 0u),
            mem_read32(cpu, descriptor + 4u),
            mem_read32(cpu, descriptor + 8u),
            mem_read32(cpu, descriptor + 16u),
            mem_read32(cpu, descriptor + 20u),
            mem_read32(cpu, descriptor + 24u),
            mem_read32(cpu, descriptor + 28u),
            mem_read32(cpu, descriptor + 32u),
            mem_read32(cpu, descriptor + 44u),
            mem_read32(cpu, descriptor + 48u),
            fnv1a_guest_bytes(cpu, descriptor, 52u)
        );
        if (
            wrote < 0 ||
            (size_t)wrote >= sizeof(live_descriptors) - cursor
        ) {
            break;
        }
        cursor += (size_t)wrote;
        descriptor = mem_read32(cpu, descriptor);
    }
    fprintf(
        stderr,
        "resource_manager_poll frame=%u gx=%" PRIu64
        " lr=0x%08X manager=0x%08X"
        " manager_hash=%016" PRIX64
        " descriptors_hash=%016" PRIX64
        " list=0x%08X gate44=0x%08X source72=0x%08X"
        " voice_manager76=0x%08X size80=%u position92=%u"
        " consumed104=%u voice_index108=%u enabled113=%u"
        " voice=0x%08X voice_address=0x%08X voice_cursor=%u"
        " ax_index=%u ax_sync=0x%08X ax_dsp_pb=0x%08X"
        " ax_state=%u ax_loop=%u ax_format=%u"
        " ax_loop_address=0x%08X ax_end_address=0x%08X"
        " ax_src_ratio=0x%08X ax_src_fraction=%u"
        " sda_flag=%u sda_object=0x%08X sda_aux=0x%08X"
        " descriptors=%s live_descriptors=%s\n",
        trace->sync_trace_frame_count,
        trace->gx_completed_frame_count,
        cpu->lr,
        manager,
        manager_valid ? fnv1a_guest_bytes(cpu, manager, 132u) : 0u,
        descriptors_valid
            ? fnv1a_guest_bytes(
                  cpu,
                  GAME_RESOURCE_DESCRIPTOR_BASE,
                  GAME_RESOURCE_DESCRIPTOR_STRIDE *
                      GAME_RESOURCE_DESCRIPTOR_COUNT
              )
            : 0u,
        manager_valid ? mem_read32(cpu, manager + 12u) : 0u,
        manager_valid ? mem_read32(cpu, manager + 44u) : 0u,
        manager_valid ? mem_read32(cpu, manager + 72u) : 0u,
        voice_manager,
        manager_valid ? mem_read32(cpu, manager + 80u) : 0u,
        manager_valid ? mem_read32(cpu, manager + 92u) : 0u,
        manager_valid ? mem_read32(cpu, manager + 104u) : 0u,
        voice_index,
        manager_valid ? mem_read8(cpu, manager + 113u) : 0u,
        voice,
        packed_voice_address,
        packed_voice_address >> 1u,
        voice_valid ? mem_read32(cpu, voice + 24u) : 0u,
        voice_valid ? mem_read32(cpu, voice + 28u) : 0u,
        voice_valid ? mem_read32(cpu, voice + 44u) : 0u,
        voice_valid ? mem_read16(cpu, voice + 56u) : 0u,
        voice_valid ? mem_read16(cpu, voice + 150u) : 0u,
        voice_valid ? mem_read16(cpu, voice + 152u) : 0u,
        voice_valid ? mem_read32(cpu, voice + 154u) : 0u,
        voice_valid ? mem_read32(cpu, voice + 158u) : 0u,
        voice_valid ? mem_read32(cpu, voice + 206u) : 0u,
        voice_valid ? mem_read16(cpu, voice + 210u) : 0u,
        mem_read8(cpu, cpu->gpr[13] - 12992u),
        mem_read32(cpu, cpu->gpr[13] - 13000u),
        mem_read32(cpu, cpu->gpr[13] - 12996u),
        descriptor_states,
        live_descriptors
    );
}

static void trace_sound_lifecycle_state(
    CPUState* cpu,
    BootTrace* trace,
    u32 address
) {
    if (
        !trace->gameplay_call_diagnostics ||
        !sync_trace_replay_ready(trace, cpu) ||
        trace->sync_trace_frame_count < 225u ||
        trace->sync_trace_frame_count > 232u ||
        (
            address != 0x80067AD0u &&
            address != GAME_SOUND_PLAY_RESULT &&
            address != GAME_SOUND_MANAGER_PLAY &&
            address != GAME_SOUND_MANAGER_ALLOCATION_RESULT
        )
    ) {
        return;
    }
    const bool voice_slots_valid = guest_range_valid(
        cpu,
        GAME_VOICE_SLOT_BASE,
        96u * sizeof(u32)
    );
    u32 occupied_voice_count = 0u;
    for (u32 index = 0u; voice_slots_valid && index < 96u; ++index) {
        if (mem_read32(cpu, GAME_VOICE_SLOT_BASE + index * 4u) != 0u) {
            occupied_voice_count++;
        }
    }
    const u32 cpu_pb =
        GAME_AX_CPU_PB_POOL + GAME_AX_DIAGNOSTIC_SLOT * GAME_AX_CPU_PB_SIZE;
    const u32 dsp_pb =
        GAME_AX_DSP_PB_POOL + GAME_AX_DIAGNOSTIC_SLOT * GAME_AX_DSP_PB_SIZE;
    const bool cpu_pb_valid = guest_range_valid(
        cpu, cpu_pb, GAME_AX_CPU_PB_SIZE
    );
    const bool dsp_pb_valid = guest_range_valid(
        cpu, dsp_pb, GAME_AX_DSP_PB_SIZE
    );
    const u32 allocation_result =
        address == GAME_SOUND_MANAGER_ALLOCATION_RESULT &&
        guest_range_valid(cpu, cpu->gpr[1] + 12u, 4u)
            ? mem_read32(cpu, cpu->gpr[1] + 12u)
            : 0u;
    fprintf(
        stderr,
        "sound_lifecycle frame=%u gx=%" PRIu64
        " phase=0x%08X lr=0x%08X r3=0x%08X r4=0x%08X"
        " r5=0x%08X r6=0x%08X allocation_result=0x%08X"
        " occupied_voices=%u slot85=0x%08X"
        " cpu_pool_hash=%016" PRIX64 " dsp_pool_hash=%016" PRIX64
        " cpu85_next=0x%08X cpu85_index=%u cpu85_sync=0x%08X"
        " cpu85_lifecycle=0x%08X cpu85_dsp=0x%08X cpu85_state=%u"
        " dsp85_state=%u dsp85_address=0x%08X dsp85_ratio=0x%08X"
        " dsp85_fraction=%u\n",
        trace->sync_trace_frame_count,
        trace->gx_completed_frame_count,
        address,
        cpu->lr,
        cpu->gpr[3],
        cpu->gpr[4],
        cpu->gpr[5],
        cpu->gpr[6],
        allocation_result,
        occupied_voice_count,
        voice_slots_valid
            ? mem_read32(
                  cpu,
                  GAME_VOICE_SLOT_BASE + GAME_AX_DIAGNOSTIC_SLOT * 4u
              )
            : 0u,
        guest_range_valid(
            cpu,
            GAME_AX_CPU_PB_POOL,
            96u * GAME_AX_CPU_PB_SIZE
        )
            ? fnv1a_guest_bytes(
                  cpu,
                  GAME_AX_CPU_PB_POOL,
                  96u * GAME_AX_CPU_PB_SIZE
              )
            : 0u,
        guest_range_valid(
            cpu,
            GAME_AX_DSP_PB_POOL,
            96u * GAME_AX_DSP_PB_SIZE
        )
            ? fnv1a_guest_bytes(
                  cpu,
                  GAME_AX_DSP_PB_POOL,
                  96u * GAME_AX_DSP_PB_SIZE
              )
            : 0u,
        cpu_pb_valid ? mem_read32(cpu, cpu_pb + 0u) : 0u,
        cpu_pb_valid ? mem_read32(cpu, cpu_pb + 24u) : 0u,
        cpu_pb_valid ? mem_read32(cpu, cpu_pb + 28u) : 0u,
        cpu_pb_valid ? mem_read32(cpu, cpu_pb + 32u) : 0u,
        cpu_pb_valid ? mem_read32(cpu, cpu_pb + 36u) : 0u,
        cpu_pb_valid ? mem_read16(cpu, cpu_pb + 56u) : 0u,
        dsp_pb_valid ? mem_read16(cpu, dsp_pb + 16u) : 0u,
        dsp_pb_valid ? mem_read32(cpu, dsp_pb + 122u) : 0u,
        dsp_pb_valid ? mem_read32(cpu, dsp_pb + 166u) : 0u,
        dsp_pb_valid ? mem_read16(cpu, dsp_pb + 170u) : 0u
    );
}

static bool logical_update_trace_active(const BootTrace* trace) {
    return
        trace->sync_trace_file &&
        !trace->sync_trace_complete &&
        trace->sync_trace_checkpoint_pc ==
            GAME_LOGICAL_UPDATE_CHECKPOINT &&
        trace->gx_completed_frame_count >=
            trace->sync_trace_start_gx_frame;
}

static u64 current_logical_update_checkpoint(
    const BootTrace* trace
) {
    return
        trace->sync_trace_start_gx_frame +
        trace->sync_trace_frame_count + 1u;
}

static void bind_content_trace_clock(
    CPUState* cpu,
    const BootTrace* trace
) {
    cpu->content_trace_request_serial = trace->file_read_count;
    cpu->content_trace_logical_clock_valid =
        logical_update_trace_active(trace);
    if (cpu->content_trace_logical_clock_valid) {
        cpu->content_trace_logical_frame =
            trace->sync_trace_frame_count;
        cpu->content_trace_absolute_checkpoint =
            current_logical_update_checkpoint(trace);
    } else {
        cpu->content_trace_logical_frame = 0u;
        cpu->content_trace_absolute_checkpoint = 0u;
    }
}

static u64 current_dvd_frame_clock(const BootTrace* trace) {
    if (logical_update_trace_active(trace)) {
        return current_logical_update_checkpoint(trace);
    }
    if (
        trace->sync_trace_file &&
        trace->gx_completed_frame_count >=
            trace->sync_trace_start_gx_frame
    ) {
        return
            trace->sync_trace_start_gx_frame +
            trace->sync_trace_frame_count;
    }
    return trace->gx_completed_frame_count;
}

static void remove_dvd_async_callback(BootTrace* trace, u32 offset) {
    for (; offset + 1u < trace->dvd_async_callback_queue_count; ++offset) {
        const u32 destination = (trace->dvd_async_callback_queue_head + offset) %
            DVD_ASYNC_CALLBACK_QUEUE_SIZE;
        const u32 source = (trace->dvd_async_callback_queue_head + offset + 1u) %
            DVD_ASYNC_CALLBACK_QUEUE_SIZE;
        trace->dvd_async_callback_queue[destination] =
            trace->dvd_async_callback_queue[source];
    }
    --trace->dvd_async_callback_queue_count;
}

static void discard_cancelled_dvd_async_callbacks(CPUState* cpu, BootTrace* trace) {
    for (u32 offset = 0; offset < trace->dvd_async_callback_queue_count;) {
        const u32 index = (trace->dvd_async_callback_queue_head + offset) %
            DVD_ASYNC_CALLBACK_QUEUE_SIZE;
        const DvdAsyncCallbackEvent* event = &trace->dvd_async_callback_queue[index];
        if (guest_range_valid(cpu, event->file_info, 16u) &&
            mem_read32(cpu, event->file_info + 12u) == 10u) {
            /* The translated SDK owns cancellation and its -3 callback.
             * Retire only the host transfer: delivering a later successful
             * callback would use resources the guest has already released.
             * Check before the due-frame gate, including while the guest's
             * cancellation callback is still pending, so reuse cannot retain
             * a shadow request. Do not replace or skip the guest callback. */
            trace_dvd_async_state(cpu, trace, "cancelled", event);
            remove_dvd_async_callback(trace, offset);
            ++trace->dvd_async_cancelled_count;
        } else {
            ++offset;
        }
    }
}

static bool queue_dvd_async_callback(
    CPUState* cpu,
    BootTrace* trace,
    u32 callback,
    u32 result,
    u32 file_info,
    u32 destination,
    u32 source_address,
    bool frame_clocked,
    bool sync_trace_anchor_completion,
    const ProtectorFileRead* file_read
) {
    discard_cancelled_dvd_async_callbacks(cpu, trace);
    if (
        trace->dvd_async_callback_queue_count >=
        DVD_ASYNC_CALLBACK_QUEUE_SIZE
    ) {
        (void)snprintf(
            trace->platform_error,
            sizeof(trace->platform_error),
            "DVD async callback queue overflow"
        );
        protector_stop(
            cpu,
            PROTECTOR_STOP_PLATFORM_ERROR,
            source_address,
            0,
            callback
        );
        return false;
    }
    const u64 frame_clock = current_dvd_frame_clock(trace);
    const bool chained_read =
        frame_clocked && trace->dvd_async_callback_dispatch_active;
    const bool follows_same_frame_completion =
        frame_clocked &&
        trace->dvd_async_callback_count > 0u &&
        trace->dvd_async_last_completion_frame ==
            frame_clock;
    const bool immediate_stream_read =
        frame_clocked && callback == GAME_DVD_STREAM_READ_CALLBACK;
    u64 stream_read_latency = 0u;
    if (
        immediate_stream_read &&
        file_read &&
        trace->bink_open_count > 0u
    ) {
        const ProtectorFileRead* previous =
            &trace->last_completed_file_read;
        if (previous->relative_path[0]) {
            const u32 previous_end =
                previous->disc_offset_words +
                (previous->file_offset + previous->bytes_from_file) / 4u;
            const u32 next_start =
                file_read->disc_offset_words + file_read->file_offset / 4u;
            const u32 seek_words =
                previous_end >= next_start
                    ? previous_end - next_start
                    : next_start - previous_end;
            stream_read_latency =
                seek_words <= DVD_STREAM_NEAR_SEEK_WORDS
                    ? 0u
                    : (
                        seek_words <= DVD_STREAM_MEDIUM_SEEK_WORDS
                            ? 1u
                            : (
                                seek_words <= DVD_STREAM_FAR_SEEK_WORDS
                                    ? 2u
                                    : 3u
                            )
                    );
            if (
                path_has_suffix(previous->relative_path, ".bik") &&
                !path_has_suffix(file_read->relative_path, ".bik")
            ) {
                /*
                 * The source trace measures a three-presentation optical/media
                 * handoff after the final movie block.  Preserve that
                 * transition instead of treating the following game stream
                 * as an ordinary seek from the movie's last sector.
                 */
                stream_read_latency +=
                    DVD_STREAM_MOVIE_HANDOFF_FRAMES;
            }
        }
    }
    if (
        (chained_read || follows_same_frame_completion) &&
        stream_read_latency == 0u
    ) {
        /*
         * A read queued by the current completion callback cannot itself
         * complete in the same presentation.  The source DVD scheduler
         * exposes the new BUSY command block for one frame before delivering
         * the chained callback.
         */
        stream_read_latency = 1u;
    }
    const u64 request_serial =
        trace->file_read_count == 0u
            ? 0u
            : trace->file_read_count - 1u;
    u64 ready_frame =
        frame_clock +
        (
            frame_clocked
                ? (
                    immediate_stream_read
                        ? stream_read_latency
                        : (
                            chained_read
                                ? 1u
                                : DVD_ASYNC_STARTUP_LATENCY_FRAMES
                        )
                )
                : 0u
        );
    bool completion_replayed = false;
    u64 ready_order = request_serial;
    const u64 path_fnv1a64 =
        file_read ? fnv1a_host_string(file_read->relative_path) : 0u;
    const bool bink_callback_read =
        file_read && path_has_suffix(file_read->relative_path, ".bik");
    for (
        u32 replay_index = 0u;
        replay_index < trace->dvd_completion_replay_count;
        ++replay_index
    ) {
        DvdCompletionReplayEntry* replay =
            &trace->dvd_completion_replay[replay_index];
        if (
            file_read &&
            !replay->consumed &&
            /* Repeated stream offsets must not consume an older missed lap. */
            (
                bink_callback_read ||
                replay->ready_frame >= frame_clock
            ) &&
            replay->path_fnv1a64 == path_fnv1a64 &&
            replay->file_offset == file_read->file_offset &&
            replay->requested_length == file_read->requested_length
        ) {
            if (bink_callback_read) {
                /*
                 * Bink's source callback cadence is request-relative.  Using
                 * the source's absolute completion checkpoint when native is
                 * one presentation early leaves a shadow request pending;
                 * Bink then submits the same block again and corrupts its
                 * stream cursor when both callbacks arrive. Preserve the
                 * observed source latency while keeping native's local clock.
                 */
                ready_frame =
                    frame_clock +
                    (replay->ready_frame - replay->requested_frame);
            } else {
                ready_frame = replay->ready_frame;
            }
            ready_order = replay->request_serial;
            completion_replayed = true;
            replay->consumed = true;
            break;
        }
    }
    if (
        !completion_replayed &&
        frame_clocked &&
        trace->dvd_async_callback_queue_count > 0u
    ) {
        const u32 tail =
            (
                trace->dvd_async_callback_queue_head +
                trace->dvd_async_callback_queue_count - 1u
            ) %
            DVD_ASYNC_CALLBACK_QUEUE_SIZE;
        if (
            ready_frame <=
            trace->dvd_async_callback_queue[tail].ready_frame
        ) {
            ready_frame =
                trace->dvd_async_callback_queue[tail].ready_frame + 1u;
        }
    }
    const u32 index =
        (
            trace->dvd_async_callback_queue_head +
            trace->dvd_async_callback_queue_count
        ) %
        DVD_ASYNC_CALLBACK_QUEUE_SIZE;
    DvdAsyncCallbackEvent* event =
        &trace->dvd_async_callback_queue[index];
    event->callback = callback;
    event->result = result;
    event->file_info = file_info;
    event->destination = destination;
    event->request_user_data = guest_range_valid(cpu, file_info, 48u)
        ? mem_read32(cpu, file_info + 44u)
        : 0u;
    event->request_r30 = cpu->gpr[30];
    event->request_serial = request_serial;
    event->ready_frame = ready_frame;
    event->ready_order = ready_order;
    event->payload_started = false;
    event->sync_trace_anchor_completion =
        sync_trace_anchor_completion;
    if (file_read) {
        event->file_read = *file_read;
    } else {
        memset(&event->file_read, 0, sizeof(event->file_read));
    }
    /*
     * Keep the destination untouched while the command is in flight. The
     * real DMA payload becomes observable at completion, immediately before
     * the callback; deliver_dvd_async_callback performs that transfer.
     */
    trace_dvd_async_state(cpu, trace, "request", event);
    trace->dvd_async_callback_queue_count++;
    return true;
}

static void ui_log_string(FILE* output, const u8* bytes, size_t size) {
    fputc('"', output);
    for (size_t index = 0; index < size; ++index) {
        const u8 value = bytes[index];
        if (value == '"' || value == '\\') fprintf(output, "\\%c", value);
        else if (value < 32 || value >= 127) fprintf(output, "\\u%04x", value);
        else fputc(value, output);
    }
    fputc('"', output);
}

static void observe_ui_text(BootTrace* trace, CPUState* cpu, u32 target) {
    const bool logging = trace->ui_text_log && !trace->ui_text_log_failed && trace->ui_text_count < 4096;
    if (!logging && !trace->native_ui_text) return;
    if (target != 0x80041FF8u && target != 0x80041FC8u && target != 0x8004485Cu &&
        target != 0x80044278u && target != 0x80043CC4u) return;
    ProtectorUIText value;
    if (!protector_ui_text_read(cpu, target, cpu->gpr[4], &value)) {
        trace->ui_text_rejected++;
        if (trace->ui_text_rejected <= 4) fprintf(stderr,
            "ui_text_rejected target=0x%08X parameters=0x%08X frame=%" PRIu64 "\n",
            target, cpu->gpr[4], cpu->presented_frame_count);
        return;
    }
    if (trace->native_ui_text) {
        const u64 tutorial_admissions = trace->tutorial_context.admission_count;
        const u64 interaction_admissions=trace->interaction_context.admission_count;
        protector_interaction_observe(&trace->interaction_context,cpu,&value,
            target,cpu->gpr[24],cpu->gpr[26]);
        if(trace->interaction_context.admission_count!=interaction_admissions)
            fprintf(stderr,"native_interaction_admit frame=%" PRIu64 " context=0x%08X ip=0x%08X action=%u\n",
                cpu->presented_frame_count,cpu->gpr[24],cpu->gpr[26],trace->interaction_context.pending_action);
        protector_tutorial_observe(&trace->tutorial_context, cpu, &value,
            target, cpu->gpr[24], cpu->gpr[26]);
        if (trace->tutorial_context.admission_count != tutorial_admissions)
            fprintf(stderr, "native_tutorial_admit frame=%" PRIu64 " context=0x%08X ip=0x%08X\n",
                cpu->presented_frame_count, cpu->gpr[24], cpu->gpr[26]);
        const u64 admissions = trace->ui_context.admission_count;
        protector_ui_context_observe(&trace->ui_context, cpu, &value, cpu->gpr[24], cpu->gpr[26]);
        if (trace->ui_context.admission_count != admissions)
            fprintf(stderr, "native_ui_context_admit frame=%" PRIu64 " name=%s context=0x%08X ip=0x%08X\n",
                cpu->presented_frame_count, trace->ui_context.last_admission, cpu->gpr[24], cpu->gpr[26]);
    }
    const ProtectorUICopyRule* rule = trace->native_ui_text ? protector_ui_copy_match(&value) : NULL;
    const bool replaced = rule && protector_ui_text_replace(cpu, &value, rule->replacement);
    if (replaced) {
        trace->native_ui_text_replacements++;
        fprintf(stderr, "native_ui_text frame=%" PRIu64 " key=%s source_bytes=%u replacement_bytes=%zu\n",
            cpu->presented_frame_count, value.key, value.text_size, strlen(rule->replacement));
    }
    if (!logging) return;
    u64 hash = FNV1A64_OFFSET;
    for (const char* key = value.key; *key; ++key) hash = (hash ^ (u8)*key) * 1099511628211ull;
    for (u32 index = 0; index < value.text_size; ++index)
        hash = (hash ^ value.text[index]) * 1099511628211ull;
    hash = (hash ^ target) * 1099511628211ull;
    hash = (hash ^ cpu->gpr[24]) * 1099511628211ull;
    for (u32 index = 0; index < trace->ui_text_count; ++index)
        if (trace->ui_text_hashes[index] == hash) return;
    trace->ui_text_hashes[trace->ui_text_count++] = hash;
    FILE* output = trace->ui_text_log;
    fprintf(output, "{\"schema\":\"protector-native.ui-text-observation/v1\","
        "\"frame\":%" PRIu64 ",\"guest_timebase\":%" PRIu64 ","
        "\"builtin\":\"0x%08X\",\"context\":\"0x%08X\","
        "\"script_ip\":\"0x%08X\",\"language_table\":\"0x%08X\","
        "\"language_slot\":%u,\"text_address\":\"0x%08X\",\"key\":",
        cpu->presented_frame_count, cpu->timebase, target, cpu->gpr[24],
        cpu->gpr[26], value.table, value.language_slot, value.text_address);
    if (value.key_available) ui_log_string(output, (const u8*)value.key, strlen(value.key));
    else fputs("null", output);
    fputs(",\"text_latin1\":", output);
    ui_log_string(output, value.text, value.text_size);
    if (replaced) {
        fputs(",\"replacement_latin1\":", output);
        ui_log_string(output, (const u8*)rule->replacement, strlen(rule->replacement));
    }
    fputs("}\n", output);
    if (fflush(output) != 0 || ferror(output)) trace->ui_text_log_failed = true;
}

static bool request_native_menu_exit(BootTrace* trace, CPUState* cpu, u32 address) {
    /* Original ass_GCResetToIPL is a two-instruction wrapper around the Wii
     * system-menu teardown. In a live native session this means End Game,
     * not Return to Title, an automatic save, or process termination.
     * Keep noninteractive/original behavior and unknown executable revisions.
     * The normal outer-loop stop path releases host resources and preserves
     * an unresolved save failure; do not execute console reset code first. */
    if (address != 0x800b4438u || !trace->native_ui_text ||
        !protector_live_input_enabled() || !guest_range_valid(cpu, address, 8) ||
        mem_read32(cpu, address) != 0x806d9c14u ||
        mem_read32(cpu, address + 4u) != 0x4bf83ddcu) return false;
    fprintf(stderr, "native_menu_exit frame=%" PRIu64 " source=0x%08X\n",
        cpu->presented_frame_count, address);
    protector_live_gx_request_stop();
    return true;
}

static bool trace_host_call(CPUState* cpu, u32 address) {
    BootTrace* trace = (BootTrace*)cpu->external_user_data;
    if (address == 0x800BB8B8u && trace->native_startup) {
        protector_cinematic_apply_logo_skip(&trace->cinematic,cpu,address);
        return false;
    }
    if (address == 0x80072520u || address == 0x800723DCu || address == 0x8009E6C0u ||
        address == 0x8009E53Cu || address == 0x80039FE8u)
        protector_motion_identity_lifecycle(&trace->motion_identity, cpu, address);
    if (request_native_menu_exit(trace, cpu, address)) return true;
    if (address == 0x8004488cu && trace->native_ui_text) {
        if (protector_tutorial_redirect_glyph(&trace->tutorial_context, cpu, address) &&
            trace->tutorial_context.redirected_glyphs <= 4)
            fprintf(stderr, "native_tutorial_glyph_redirect frame=%" PRIu64
                " context=0x%08X ip=0x%08X\n", cpu->presented_frame_count,
                cpu->gpr[24], cpu->gpr[26]);
        if (protector_interaction_redirect_glyph(&trace->interaction_context,cpu,address) &&
            trace->interaction_context.redirected_glyphs<=4)
            fprintf(stderr,"native_interaction_glyph_redirect frame=%" PRIu64
                " context=0x%08X ip=0x%08X action=%u\n",cpu->presented_frame_count,
                cpu->gpr[24],cpu->gpr[26],trace->interaction_context.active_action);
        return false; /* Original DisplayText, reset epilogue and VM return. */
    }
    // The static-map and model-object render callers share this source sphere
    // test. Leaving object submission at 4:3 makes props/actors pop in the
    // widened wings. Near/far, vertical tests and the original camera stay on
    // their source path. Keep the historical 3:1 static-map envelope even when the
    // selected output is narrower: a paused aspect preview needs the already
    // submitted static geometry without advancing gameplay.
    if (address == 0x80017D2Cu && protector_visibility_render_caller(cpu->lr) &&
        trace->enhanced_static_visibility) {
        const double source_height = read_guest_float_if_valid(cpu, cpu->gpr[2] - 32608u);
        const double source_width = read_guest_float_if_valid(cpu, cpu->gpr[2] - 32604u);
        if (source_width > 0) cpu->fpr[9] = protector_static_visibility_half_width(
            cpu->fpr[9], cpu->fpr[4], source_height / source_width,
            cpu->fpr[8], cpu->lr==0x800233C4u ? PROTECTOR_MAX_PRESENTATION_ASPECT :
                protector_visibility_presentation_aspect());
    }
    // The one-frame diagnostic never changes the decision. The static-map
    // caller keeps its node in r30 and the render payload at +44.
    if ((address == 0x80017D2Cu || address == 0x800233C4u) &&
        trace->frustum_audit_frame != 0u &&
        cpu->presented_frame_count == trace->frustum_audit_frame &&
        (address == 0x800233C4u || cpu->lr == 0x800233C4u)) {
        const u32 node = cpu->gpr[30];
        const u32 payload = guest_range_valid(cpu, node + 44u, 4u)
            ? mem_read32(cpu, node + 44u) : 0u;
        char name[17] = {0};
        if (payload && guest_range_valid(cpu, payload + 32u, 16u)) {
            for (u32 i = 0; i < 16u; ++i) {
                const u8 byte = mem_read8(cpu, payload + 32u + i);
                name[i] = byte >= 32u && byte < 127u ? (char)byte : '.';
                if (byte == 0u) { name[i] = '\0'; break; }
            }
        }
        fprintf(stderr, "frustum_audit frame=%llu seam=0x%08X "
            "node=0x%08X name=%s payload=0x%08X visible=%u "
            "x=%.9g half_width=%.9g expanded_radius=%.9g "
            "half_height=%.9g\n",
            (unsigned long long)cpu->presented_frame_count, address,
            node, name, payload,
            address == 0x800233C4u ? cpu->gpr[3] : UINT32_MAX,
            cpu->fpr[2], cpu->fpr[9], cpu->fpr[8], cpu->fpr[4]);
    }
    if (address == 0x80017D2Cu || address == 0x800233C4u) return false;
    trace_resource_manager_state(cpu, trace, address);
    trace_sound_lifecycle_state(cpu, trace, address);
    trace->host_call_count++;
    trace->last_host_call = address;
    trace->host_call_ring[
        (trace->host_call_count - 1u) % TRACE_RING_SIZE
    ] = address;
    if (
        trace->gameplay_call_diagnostics &&
        sync_trace_replay_ready(trace, cpu) &&
        trace->sync_trace_frame_count >= 1138u &&
        trace->sync_trace_frame_count <= 1160u
    ) {
        const char* animation_query = NULL;
        switch (address) {
            case GAME_ANIM_LOOPED:
                animation_query = "anim_looped";
                break;
            case GAME_ANIM_BLEND_WEIGHT:
                animation_query = "anim_blend_weight";
                break;
            case GAME_ANIM_BLEND:
                animation_query = "anim_blend";
                break;
            case GAME_ANIM_LENGTH:
                animation_query = "anim_length";
                break;
            case GAME_ANIMATING_NEXT_FRAME:
                animation_query = "animating_next_frame";
                break;
            case GAME_ANIM_BLENDING_OUT:
                animation_query = "anim_blending_out";
                break;
            case GAME_ANIM_PLAYING:
                animation_query = "anim_playing";
                break;
            case GAME_ANIM_TIME:
                animation_query = "anim_time";
                break;
            case GAME_ANIM_WEIGHT:
                animation_query = "anim_weight";
                break;
            default:
                break;
        }
        if (animation_query) {
            fprintf(
                stderr,
                "animation_query frame=%u phase=entry name=%s "
                "script_ip=0x%08X context=0x%08X base=0x%08X "
                "r3=0x%08X r4=0x%08X r5=0x%08X r6=0x%08X\n",
                trace->sync_trace_frame_count,
                animation_query,
                cpu->gpr[26],
                cpu->gpr[24],
                cpu->gpr[29],
                cpu->gpr[3],
                cpu->gpr[4],
                cpu->gpr[5],
                cpu->gpr[6]
            );
        } else if (address == GAME_ANIM_PLAYING_RESULT) {
            fprintf(
                stderr,
                "animation_query frame=%u phase=result name=anim_playing "
                "script_ip=0x%08X context=0x%08X output=0x%08X "
                "result=0x%08X\n",
                trace->sync_trace_frame_count,
                cpu->gpr[26],
                cpu->gpr[24],
                cpu->gpr[31],
                cpu->gpr[3]
            );
        } else if (address == GAME_ANIM_TIME_RESULT) {
            fprintf(
                stderr,
                "animation_query frame=%u phase=result name=anim_time "
                "script_ip=0x%08X context=0x%08X output=0x%08X "
                "result=0x%08X\n",
                trace->sync_trace_frame_count,
                cpu->gpr[26],
                cpu->gpr[24],
                cpu->gpr[31],
                cpu->gpr[0]
            );
        }
    }
    if (
        (address == GAMEPLAY_VM_OWNER_POINTER_ASSIGN ||
         address == GAMEPLAY_VM_OWNER_POINTER_CLEAR) &&
        sync_trace_replay_ready(trace, cpu)
    ) {
        const bool assign = address == GAMEPLAY_VM_OWNER_POINTER_ASSIGN;
        const u32 owner = assign ? cpu->gpr[25] : cpu->gpr[30];
        const u32 old_pointer = guest_range_valid(cpu, owner + 0x1D8u, 4u)
            ? mem_read32(cpu, owner + 0x1D8u)
            : 0u;
        fprintf(
            stderr,
            "gameplay_vm_owner frame=%u operation=%s pc=0x%08X "
            "lr=0x%08X owner=0x%08X old=0x%08X new=0x%08X "
            "flags=0x%08X next=0x%08X previous=0x%08X "
            "constructor_caller=0x%08X constructor_r4=0x%08X "
            "script_definition=0x%08X script_arguments=0x%08X "
            "previous_owner=0x%08X "
            "callers=0x%08X,0x%08X,0x%08X\n",
            trace->sync_trace_frame_count,
            assign ? "assign" : "clear",
            address,
            cpu->lr,
            owner,
            old_pointer,
            assign ? cpu->gpr[3] : 0u,
            guest_range_valid(cpu, owner + 0x1B0u, 4u)
                ? mem_read32(cpu, owner + 0x1B0u) : 0u,
            guest_range_valid(cpu, owner + 0x1B8u, 4u)
                ? mem_read32(cpu, owner + 0x1B8u) : 0u,
            guest_range_valid(cpu, owner + 0x1BCu, 4u)
                ? mem_read32(cpu, owner + 0x1BCu) : 0u,
            assign && guest_range_valid(cpu, cpu->gpr[1], 4u) &&
                    guest_range_valid(
                        cpu,
                        mem_read32(cpu, cpu->gpr[1]) + 4u,
                        4u
                    )
                ? mem_read32(
                    cpu,
                    mem_read32(cpu, cpu->gpr[1]) + 4u
                ) : 0u,
            assign ? cpu->gpr[22] : 0u,
            assign ? cpu->gpr[26] : 0u,
            assign ? cpu->gpr[27] : 0u,
            assign ? cpu->gpr[31] : 0u,
            guest_range_valid(cpu, cpu->gpr[1] + 0x14u, 4u)
                ? mem_read32(cpu, cpu->gpr[1] + 0x14u) : 0u,
            guest_range_valid(cpu, cpu->gpr[1] + 0x34u, 4u)
                ? mem_read32(cpu, cpu->gpr[1] + 0x34u) : 0u,
            guest_range_valid(cpu, cpu->gpr[1] + 0x44u, 4u)
                ? mem_read32(cpu, cpu->gpr[1] + 0x44u) : 0u
        );
    }
    if (
        cpu->debug_memory_write_watch_address >= 0x1E0u &&
        cpu->presented_frame_count >=
            cpu->debug_memory_write_watch_start_frame
    ) {
        const u32 watched_owner =
            cpu->debug_memory_write_watch_address - 0x1E0u;
        if (
            address == GAME_COLLISION_EVENT_SCAN &&
            cpu->gpr[3] == watched_owner
        ) {
            const u32 counterpart = cpu->gpr[4];
            const u32 table = guest_range_valid(cpu, watched_owner + 456u, 4u)
                ? mem_read32(cpu, watched_owner + 456u)
                : 0u;
            const u32 rows = guest_range_valid(cpu, watched_owner + 476u, 4u)
                ? mem_read32(cpu, watched_owner + 476u)
                : 0u;
            fprintf(
                stderr,
                "collision_event_scan frame=%llu pc=0x%08X lr=0x%08X "
                "owner=0x%08X counterpart=0x%08X old_head=0x%08X "
                "owner_mask708=0x%08X owner_mask436=0x%08X "
                "counterpart_mask708=0x%08X counterpart_mask436=0x%08X "
                "owner_flags432=0x%08X owner_gate608=%u "
                "table=0x%08X rows=0x%08X row_count=%u\n",
                (unsigned long long)cpu->presented_frame_count,
                address,
                cpu->lr,
                watched_owner,
                counterpart,
                guest_range_valid(cpu, watched_owner + 480u, 4u)
                    ? mem_read32(cpu, watched_owner + 480u) : 0u,
                guest_range_valid(cpu, watched_owner + 708u, 4u)
                    ? mem_read32(cpu, watched_owner + 708u) : 0u,
                guest_range_valid(cpu, watched_owner + 436u, 4u)
                    ? mem_read32(cpu, watched_owner + 436u) : 0u,
                guest_range_valid(cpu, counterpart + 708u, 4u)
                    ? mem_read32(cpu, counterpart + 708u) : 0u,
                guest_range_valid(cpu, counterpart + 436u, 4u)
                    ? mem_read32(cpu, counterpart + 436u) : 0u,
                guest_range_valid(cpu, watched_owner + 432u, 4u)
                    ? mem_read32(cpu, watched_owner + 432u) : 0u,
                guest_range_valid(cpu, watched_owner + 608u, 2u)
                    ? mem_read16(cpu, watched_owner + 608u) : 0u,
                table,
                rows,
                guest_range_valid(cpu, table + 24u, 2u)
                    ? mem_read16(cpu, table + 24u) : 0u
            );
        } else if (
            address == GAME_COLLISION_EVENT_NODE_CREATE &&
            cpu->gpr[6] == GAME_COLLISION_EVENT_HANDLER_ATTACK
        ) {
            fprintf(
                stderr,
                "collision_event_create frame=%llu pc=0x%08X lr=0x%08X "
                "owner=0x%08X allocator=0x%08X old_head=0x%08X "
                "priority=0x%08X handler=0x%08X counterpart=0x%08X "
                "payload=0x%08X\n",
                (unsigned long long)cpu->presented_frame_count,
                address,
                cpu->lr,
                cpu->gpr[31],
                cpu->gpr[3],
                cpu->gpr[4],
                cpu->gpr[5],
                cpu->gpr[6],
                cpu->gpr[7],
                cpu->gpr[8]
            );
        } else if (
            address == GAME_COLLISION_EVENT_HEAD_STORE &&
            cpu->gpr[31] == watched_owner
        ) {
            const u32 node = cpu->gpr[3];
            fprintf(
                stderr,
                "collision_event_head_store frame=%llu pc=0x%08X "
                "lr=0x%08X owner=0x%08X old_head=0x%08X "
                "new_head=0x%08X node=0x%08X,0x%08X,0x%08X,0x%08X,"
                "0x%08X,0x%08X\n",
                (unsigned long long)cpu->presented_frame_count,
                address,
                cpu->lr,
                watched_owner,
                guest_range_valid(cpu, watched_owner + 480u, 4u)
                    ? mem_read32(cpu, watched_owner + 480u) : 0u,
                node,
                guest_range_valid(cpu, node, 24u)
                    ? mem_read32(cpu, node + 0u) : 0u,
                guest_range_valid(cpu, node, 24u)
                    ? mem_read32(cpu, node + 4u) : 0u,
                guest_range_valid(cpu, node, 24u)
                    ? mem_read32(cpu, node + 8u) : 0u,
                guest_range_valid(cpu, node, 24u)
                    ? mem_read32(cpu, node + 12u) : 0u,
                guest_range_valid(cpu, node, 24u)
                    ? mem_read32(cpu, node + 16u) : 0u,
                guest_range_valid(cpu, node, 24u)
                    ? mem_read32(cpu, node + 20u) : 0u
            );
        }
    }
    if (
        address == GAMEPLAY_SPAWN_AFTER_RETURN &&
        sync_trace_replay_ready(trace, cpu) &&
        trace->sync_frame_spawn_after_return_count <
            trace->sync_frame_spawn_after_pending_count &&
        trace->sync_frame_spawn_after_return_count <
            GAMEPLAY_SPAWN_OUTPUT_CAPACITY
    ) {
        trace->sync_frame_spawn_after_return_values[
            trace->sync_frame_spawn_after_return_count++
        ] = cpu->gpr[3];
    }
    if (
        (address == GAME_SCRIPT_PROPERTY_QUERY ||
         address == GAME_SCRIPT_PROPERTY_QUERY_RETURN) &&
        cpu->debug_memory_write_watch_address != 0u &&
        cpu->presented_frame_count >=
            cpu->debug_memory_write_watch_start_frame &&
        trace->script_vm_diagnostic_context != 0u &&
        cpu->gpr[24] == trace->script_vm_diagnostic_context
    ) {
        const bool query_entry = address == GAME_SCRIPT_PROPERTY_QUERY;
        const u32 query_object = cpu->gpr[3];
        const u32 query_descriptor = cpu->gpr[4];
        fprintf(
            stderr,
            "script_property_query frame=%llu phase=%s pc=0x%08X "
            "context=0x%08X r3=0x%08X r4=0x%08X r5=0x%08X "
            "r6=0x%08X r31=0x%08X "
            "object=0x%08X,0x%08X,0x%08X,0x%08X,0x%08X,0x%08X,"
            "0x%08X,0x%08X descriptor=0x%08X,0x%08X,0x%08X\n",
            (unsigned long long)cpu->presented_frame_count,
            address == GAME_SCRIPT_PROPERTY_QUERY ? "entry" : "return",
            address,
            cpu->gpr[24],
            cpu->gpr[3],
            cpu->gpr[4],
            cpu->gpr[5],
            cpu->gpr[6],
            cpu->gpr[31],
            query_entry && guest_range_valid(cpu, query_object, 32u)
                ? mem_read32(cpu, query_object + 0u) : 0u,
            query_entry && guest_range_valid(cpu, query_object, 32u)
                ? mem_read32(cpu, query_object + 4u) : 0u,
            query_entry && guest_range_valid(cpu, query_object, 32u)
                ? mem_read32(cpu, query_object + 8u) : 0u,
            query_entry && guest_range_valid(cpu, query_object, 32u)
                ? mem_read32(cpu, query_object + 12u) : 0u,
            query_entry && guest_range_valid(cpu, query_object, 32u)
                ? mem_read32(cpu, query_object + 16u) : 0u,
            query_entry && guest_range_valid(cpu, query_object, 32u)
                ? mem_read32(cpu, query_object + 20u) : 0u,
            query_entry && guest_range_valid(cpu, query_object, 32u)
                ? mem_read32(cpu, query_object + 24u) : 0u,
            query_entry && guest_range_valid(cpu, query_object, 32u)
                ? mem_read32(cpu, query_object + 28u) : 0u,
            query_entry && guest_range_valid(cpu, query_descriptor, 12u)
                ? mem_read32(cpu, query_descriptor + 0u) : 0u,
            query_entry && guest_range_valid(cpu, query_descriptor, 12u)
                ? mem_read32(cpu, query_descriptor + 4u) : 0u,
            query_entry && guest_range_valid(cpu, query_descriptor, 12u)
                ? mem_read32(cpu, query_descriptor + 8u) : 0u
        );
    }
    if (
        address == GAME_RANDOM_NEXT &&
        cpu->debug_memory_write_watch_address != 0u &&
        cpu->presented_frame_count >=
            cpu->debug_memory_write_watch_start_frame
    ) {
        const u32 stream = cpu->gpr[3];
        const u32 stream_count = mem_read32(cpu, GAME_RANDOM_STREAM_COUNT);
        const u32 table = mem_read32(cpu, GAME_RANDOM_STREAM_TABLE_POINTER);
        const u32 state_address =
            table + stream * GAME_RANDOM_STREAM_STRIDE;
        fprintf(
            stderr,
            "rng_entry frame=%llu lr=0x%08X caller_lr=0x%08X stream=%u "
            "stream_count=%u table=0x%08X state_address=0x%08X "
            "state=0x%08X r29=0x%08X r30=0x%08X\n",
            (unsigned long long)cpu->presented_frame_count,
            cpu->lr,
            guest_range_valid(cpu, cpu->gpr[1] + 52u, 4u)
                ? mem_read32(cpu, cpu->gpr[1] + 52u)
                : 0u,
            stream,
            stream_count,
            table,
            state_address,
            guest_range_valid(cpu, state_address, 4u)
                ? mem_read32(cpu, state_address)
                : 0u,
            cpu->gpr[29],
            cpu->gpr[30]
        );
    }
    if (
        address == GAME_ROTATION_APPLY &&
        trace->motion_diagnostics &&
        sync_trace_replay_ready(trace, cpu) &&
        trace->sync_trace_frame_count < 4u
    ) {
        fprintf(
            stderr,
            "motion_apply frame=%u lr=0x%08X "
            "object=0x%08X parameters=0x%08X "
            "target=%.9g step=%.9g\n",
            trace->sync_trace_frame_count,
            cpu->lr,
            cpu->gpr[3],
            cpu->gpr[4],
            read_guest_float_if_valid(cpu, cpu->gpr[4]),
            read_guest_float_if_valid(cpu, cpu->gpr[4] + 4u)
        );
    }
    if (
        address == GAME_ROTATION_BLEND &&
        trace->motion_diagnostics &&
        sync_trace_replay_ready(trace, cpu) &&
        trace->sync_trace_frame_count < 4u
    ) {
        fprintf(
            stderr,
            "motion_blend frame=%u lr=0x%08X "
            "object=0x%08X parameters=0x%08X "
            "f1=%.17g f2=%.17g f3=%.17g\n",
            trace->sync_trace_frame_count,
            cpu->lr,
            cpu->gpr[31],
            cpu->gpr[4],
            cpu->fpr[1],
            cpu->fpr[2],
            cpu->fpr[3]
        );
    }
    if (
        address == GAME_SCRIPT_BUILTIN_CALL_1 ||
        address == GAME_SCRIPT_BUILTIN_CALL_2 ||
        address == GAME_SCRIPT_BUILTIN_CALL_3 ||
        address == GAME_SCRIPT_BUILTIN_CALL_4
    ) {
        const u32 target = cpu->ctr & ~3u;
        observe_ui_text(trace, cpu, target);
        if (
            target == GAME_RANDOM_VECTOR &&
            cpu->debug_memory_write_watch_address != 0u &&
            cpu->presented_frame_count >=
                cpu->debug_memory_write_watch_start_frame
        ) {
            fprintf(
                stderr,
                "rng_vector_call frame=%llu dispatcher=0x%08X "
                "script_ip=0x%08X context=0x%08X "
                "base29=0x%08X base30=0x%08X base31=0x%08X "
                "r3=0x%08X r4=0x%08X r5=0x%08X\n",
                (unsigned long long)cpu->presented_frame_count,
                address,
                cpu->gpr[26],
                cpu->gpr[24],
                cpu->gpr[29],
                cpu->gpr[30],
                cpu->gpr[31],
                cpu->gpr[3],
                cpu->gpr[4],
                cpu->gpr[5]
            );
        }
        for (u32 index = 0u; index < GAMEPLAY_OBSERVABLE_COUNT; ++index) {
            if (target != GAMEPLAY_OBSERVABLE_ADDRESSES[index]) {
                continue;
            }
            if (trace->sync_trace_content_ready) {
                trace->gameplay_observable_seen_total[index]++;
            }
            if (sync_trace_replay_ready(trace, cpu)) {
                const bool hashes_object_transforms =
                    index == GAMEPLAY_OBSERVABLE_SET_POSITION ||
                    index == GAMEPLAY_OBSERVABLE_RESET_POSITION;
                const u32 object_transform_offset =
                    index == GAMEPLAY_OBSERVABLE_SET_POSITION
                        ? GAMEPLAY_OBJECT_CURRENT_TRANSFORM_OFFSET
                        : GAMEPLAY_OBJECT_SAVED_TRANSFORM_OFFSET;
                const bool object_transforms_valid =
                    hashes_object_transforms &&
                    guest_range_valid(
                        cpu,
                        cpu->gpr[3] + object_transform_offset,
                        GAMEPLAY_OBJECT_TRANSFORM_SIZE
                    );
                const u64 object_transform_payload_hash =
                    object_transforms_valid
                        ? fnv1a_guest_bytes(
                              cpu,
                              cpu->gpr[3] + object_transform_offset,
                              GAMEPLAY_OBJECT_TRANSFORM_SIZE
                          )
                        : 0u;
                const bool script_vm_state_valid = guest_range_valid(
                    cpu,
                    cpu->gpr[29],
                    GAMEPLAY_SCRIPT_VM_STATE_SIZE
                );
                const u64 script_vm_state_hash =
                    script_vm_state_valid
                        ? fnv1a_guest_bytes(
                              cpu,
                              cpu->gpr[29],
                              GAMEPLAY_SCRIPT_VM_STATE_SIZE
                          )
                        : 0u;
                GameplayCallSignature* const last_signature =
                    &trace->sync_frame_gameplay_last_signature[index];
                /*
                 * Dolphin's GDB stub can stop more than once on one unchanged
                 * breakpoint hit.  The source capture canonicalizes those
                 * identical per-observable stops within a frame, so apply the
                 * same projection here before updating proof counts/hashes.
                 */
                const bool duplicate_observation =
                    last_signature->valid &&
                    memcmp(
                        last_signature->gpr,
                        cpu->gpr,
                        sizeof(last_signature->gpr)
                    ) == 0 &&
                    last_signature->lr == cpu->lr &&
                    last_signature->ctr == cpu->ctr &&
                    last_signature->object_transform_valid ==
                        object_transforms_valid &&
                    last_signature->object_transform_hash ==
                        object_transform_payload_hash &&
                    last_signature->script_vm_state_valid ==
                        script_vm_state_valid &&
                    last_signature->script_vm_state_hash ==
                        script_vm_state_hash;
                if (duplicate_observation) {
                    break;
                }
                memcpy(
                    last_signature->gpr,
                    cpu->gpr,
                    sizeof(last_signature->gpr)
                );
                last_signature->lr = cpu->lr;
                last_signature->ctr = cpu->ctr;
                last_signature->object_transform_valid =
                    object_transforms_valid;
                last_signature->object_transform_hash =
                    object_transform_payload_hash;
                last_signature->script_vm_state_valid =
                    script_vm_state_valid;
                last_signature->script_vm_state_hash = script_vm_state_hash;
                last_signature->valid = true;

                u64 event_hash =
                    trace->sync_frame_gameplay_observable[index] == 0u
                        ? FNV1A64_OFFSET
                        : trace->sync_frame_gameplay_observable_hash[index];
                event_hash = fnv1a_u32_be(event_hash, target);
                event_hash = fnv1a_u32_be(event_hash, cpu->gpr[26]);
                /*
                 * Strategy objects are drawn from a recyclable pool.  The
                 * original runtime may choose a different physical slot
                 * without changing the live script actor; hash that actor's
                 * VM base when one exists.  r5/r6 remain caller scratch state.
                 */
                event_hash = fnv1a_u32_be(
                    event_hash,
                    gameplay_semantic_r3(cpu, target, cpu->gpr[3])
                );
                event_hash = fnv1a_u32_be(event_hash, cpu->gpr[4]);
                if (object_transforms_valid) {
                    event_hash = fnv1a_guest_bytes_seed(
                        cpu,
                        cpu->gpr[3] + object_transform_offset,
                        GAMEPLAY_OBJECT_TRANSFORM_SIZE,
                        event_hash
                    );
                }
                trace->sync_frame_gameplay_observable_hash[index] =
                    event_hash;
                trace->gameplay_observable_total[index]++;
                trace->sync_frame_gameplay_observable[index]++;
                if (
                    index == GAMEPLAY_OBSERVABLE_SPAWN_AFTER &&
                    trace->sync_frame_spawn_after_pending_count <
                        GAMEPLAY_SPAWN_OUTPUT_CAPACITY
                ) {
                    trace->sync_frame_spawn_after_pending_count++;
                }
                if (
                    index == GAMEPLAY_OBSERVABLE_SPAWN_AFTER_S &&
                    trace->sync_frame_spawn_output_count <
                        GAMEPLAY_SPAWN_OUTPUT_CAPACITY
                ) {
                    trace->sync_frame_spawn_output_addresses[
                        trace->sync_frame_spawn_output_count++
                    ] = cpu->gpr[4];
                }
                if (trace->gameplay_call_diagnostics) {
                    fprintf(
                        stderr,
                        "gameplay_call frame=%u name=%s "
                        "dispatcher=0x%08X target=0x%08X "
                        "script_ip=0x%08X "
                        "script_context=0x%08X "
                        "script_base29=0x%08X script_base30=0x%08X "
                        "script_base31=0x%08X "
                        "r3=0x%08X semantic_r3=0x%08X r4=0x%08X "
                        "r5=0x%08X r6=0x%08X "
                        "object_payload_valid=%u "
                        "object_payload_fnv1a64=%016" PRIX64 " "
                        "script_vm_state_valid=%u "
                        "script_vm_state_fnv1a64=%016" PRIX64 " "
                        "current_xyz=%08X,%08X,%08X "
                        "saved_xyz=%08X,%08X,%08X\n",
                        trace->sync_trace_frame_count,
                        GAMEPLAY_OBSERVABLE_NAMES[index],
                        address,
                        target,
                        cpu->gpr[26],
                        cpu->gpr[24],
                        cpu->gpr[29],
                        cpu->gpr[30],
                        cpu->gpr[31],
                        cpu->gpr[3],
                        gameplay_semantic_r3(cpu, target, cpu->gpr[3]),
                        cpu->gpr[4],
                        cpu->gpr[5],
                        cpu->gpr[6],
                        object_transforms_valid ? 1u : 0u,
                        object_transform_payload_hash,
                        script_vm_state_valid ? 1u : 0u,
                        script_vm_state_hash,
                        object_transforms_valid
                            ? mem_read32(
                                  cpu,
                                  cpu->gpr[3] +
                                      GAMEPLAY_OBJECT_CURRENT_TRANSFORM_OFFSET
                              )
                            : 0u,
                        object_transforms_valid
                            ? mem_read32(
                                  cpu,
                                  cpu->gpr[3] +
                                      GAMEPLAY_OBJECT_CURRENT_TRANSFORM_OFFSET +
                                      4u
                              )
                            : 0u,
                        object_transforms_valid
                            ? mem_read32(
                                  cpu,
                                  cpu->gpr[3] +
                                      GAMEPLAY_OBJECT_CURRENT_TRANSFORM_OFFSET +
                                      8u
                              )
                            : 0u,
                        object_transforms_valid
                            ? mem_read32(
                                  cpu,
                                  cpu->gpr[3] +
                                      GAMEPLAY_OBJECT_SAVED_TRANSFORM_OFFSET
                              )
                            : 0u,
                        object_transforms_valid
                            ? mem_read32(
                                  cpu,
                                  cpu->gpr[3] +
                                      GAMEPLAY_OBJECT_SAVED_TRANSFORM_OFFSET +
                                      4u
                              )
                            : 0u,
                        object_transforms_valid
                            ? mem_read32(
                                  cpu,
                                  cpu->gpr[3] +
                                      GAMEPLAY_OBJECT_SAVED_TRANSFORM_OFFSET +
                                      8u
                              )
                            : 0u
                    );
                    if (
                        script_vm_state_valid &&
                        (index == GAMEPLAY_OBSERVABLE_SPAWN_AFTER ||
                         index == GAMEPLAY_OBSERVABLE_SPAWN_AFTER_S ||
                         index == GAMEPLAY_OBSERVABLE_CREATE_TRIGGER)
                    ) {
                        fprintf(
                            stderr,
                            "gameplay_vm_state frame=%u name=%s "
                            "base=0x%08X words=",
                            trace->sync_trace_frame_count,
                            GAMEPLAY_OBSERVABLE_NAMES[index],
                            cpu->gpr[29]
                        );
                        for (
                            u32 word_index = 0u;
                            word_index < GAMEPLAY_SCRIPT_VM_STATE_SIZE / 4u;
                            ++word_index
                        ) {
                            fprintf(
                                stderr,
                                "%s%08X",
                                word_index == 0u ? "" : ",",
                                mem_read32(
                                    cpu,
                                    cpu->gpr[29] + word_index * 4u
                                )
                            );
                        }
                        fputc('\n', stderr);
                        if (
                            index == GAMEPLAY_OBSERVABLE_SPAWN_AFTER_S &&
                            guest_range_valid(
                                cpu,
                                cpu->gpr[29],
                                0x1000u
                            )
                        ) {
                            fprintf(
                                stderr,
                                "gameplay_vm_state_wide frame=%u name=%s "
                                "base=0x%08X words=",
                                trace->sync_trace_frame_count,
                                GAMEPLAY_OBSERVABLE_NAMES[index],
                                cpu->gpr[29]
                            );
                            for (u32 word_index = 0u; word_index < 1024u;
                                 ++word_index) {
                                fprintf(
                                    stderr,
                                    "%s%08X",
                                    word_index == 0u ? "" : ",",
                                    mem_read32(
                                        cpu,
                                        cpu->gpr[29] + word_index * 4u
                                    )
                                );
                            }
                            fputc('\n', stderr);
                        }
                        if (
                            index == GAMEPLAY_OBSERVABLE_SPAWN_AFTER_S &&
                            guest_range_valid(
                                cpu,
                                cpu->gpr[26] - 32u,
                                64u
                            )
                        ) {
                            fprintf(
                                stderr,
                                "gameplay_vm_code_window frame=%u name=%s "
                                "script_ip=0x%08X words=",
                                trace->sync_trace_frame_count,
                                GAMEPLAY_OBSERVABLE_NAMES[index],
                                cpu->gpr[26]
                            );
                            for (u32 word_index = 0u; word_index < 16u;
                                 ++word_index) {
                                fprintf(
                                    stderr,
                                    "%s%08X",
                                    word_index == 0u ? "" : ",",
                                    mem_read32(
                                        cpu,
                                        cpu->gpr[26] - 32u +
                                            word_index * 4u
                                    )
                                );
                            }
                            fputc('\n', stderr);
                        }
                    }
                }
                if (
                    trace->gameplay_call_state_context != 0u &&
                    trace->sync_trace_frame_count >=
                        trace->gameplay_call_state_start_frame &&
                    gameplay_semantic_r3(cpu, target, cpu->gpr[3]) ==
                        trace->gameplay_call_state_context &&
                    script_vm_state_valid
                ) {
                    fprintf(
                        stderr,
                        "gameplay_call_state frame=%u name=%s target=0x%08X "
                        "script_ip=0x%08X semantic_r3=0x%08X "
                        "script_base29=0x%08X words=",
                        trace->sync_trace_frame_count,
                        GAMEPLAY_OBSERVABLE_NAMES[index],
                        target,
                        cpu->gpr[26],
                        trace->gameplay_call_state_context,
                        cpu->gpr[29]
                    );
                    for (
                        u32 word_index = 0u;
                        word_index < GAMEPLAY_SCRIPT_VM_STATE_SIZE / 4u;
                        ++word_index
                    ) {
                        fprintf(
                            stderr,
                            "%s%08X",
                            word_index == 0u ? "" : ",",
                            mem_read32(
                                cpu,
                                cpu->gpr[29] + word_index * 4u
                            )
                        );
                    }
                    fputc('\n', stderr);
                }
            }
            break;
        }
    }
    if (address == GAME_SCRIPT_VM_DISPATCH) {
        u32 instruction_pointer = cpu->gpr[26];
        u32 instruction = mem_read32(cpu, instruction_pointer);
        if (trace->native_ui_text && trace->tutorial_context.count)
            protector_tutorial_dispatch(&trace->tutorial_context, cpu->gpr[24],
                instruction_pointer, instruction, cpu->presented_frame_count);
        if (trace->native_ui_text)
            protector_ui_context_admit_dispatch(&trace->ui_context, cpu, cpu->gpr[24],
                instruction_pointer, instruction);
        if (trace->native_ui_text && trace->ui_context.count) {
            const u32 previous_owners = trace->ui_context.count;
            /* Explicit, bounded developer observation of an admitted loading
             * owner. This does not infer readiness or alter guest execution. */
            if (trace->ui_context_log && trace->ui_context_log_count < 50000) {
                for (u32 i = 0; i < trace->ui_context.count; ++i) {
                    const ProtectorUIContextOwner* owner = &trace->ui_context.owners[i];
                    if (owner->context != cpu->gpr[24]) continue;
                    if (owner->kind == PROTECTOR_UI_PROMPT) trace->ui_context_log_prompt_seen = true;
                    if (owner->kind != PROTECTOR_UI_LOADING ||
                        (trace->ui_context_log_after_prompt && !trace->ui_context_log_prompt_seen)) continue;
                    fprintf(trace->ui_context_log,
                        "{\"frame\":%" PRIu64 ",\"context\":\"0x%08X\",\"ip\":\"0x%08X\","
                        "\"instruction\":\"0x%08X\",\"rule\":%u,\"begin\":\"0x%08X\","
                        "\"base29\":\"0x%08X\"}\n",
                        cpu->presented_frame_count, cpu->gpr[24], instruction_pointer,
                        instruction, owner->rule_index, owner->begin, cpu->gpr[29]);
                    ++trace->ui_context_log_count;
                    break;
                }
            }
            protector_ui_context_dispatch(&trace->ui_context, cpu->gpr[24], instruction_pointer,
                instruction, cpu->presented_frame_count);
            if (trace->ui_context.count < previous_owners)
                fprintf(stderr, "native_ui_context_depart frame=%" PRIu64
                    " context=0x%08X ip=0x%08X instruction=0x%08X owners=%u\n",
                    cpu->presented_frame_count, cpu->gpr[24], instruction_pointer,
                    instruction, trace->ui_context.count);
        }
        if (trace->native_startup &&
            (instruction == 0x80ff0000u || instruction == 0x321cff0eu)) {
            ProtectorScriptFlowMatch match;
            if (protector_startup_flow_match(cpu, cpu->gpr[26], &match)) {
                fprintf(stderr, "native_startup_skip frame=%" PRIu64
                    " name=%s base=0x%08X from=0x%08X to=0x%08X hash=%016" PRIx64 "\n",
                    cpu->presented_frame_count, match.rule->name, match.file_info_base,
                    cpu->gpr[26], match.destination, match.rule->normalized_hash);
                /* The original VM executes its own flag writes/package
                 * cleanup for startup screens, or its own Remove command
                 * for the Wii warning presenter. All routes precede panel
                 * creation and exclusivity; no gameplay input is bypassed. */
                cpu->gpr[26] = match.destination;
                instruction_pointer = match.destination;
                instruction = mem_read32(cpu, instruction_pointer);
            }
        }
        if (
            cpu->debug_memory_write_watch_address != 0u &&
            cpu->presented_frame_count >=
                cpu->debug_memory_write_watch_start_frame
        ) {
            const u32 script_manager = mem_read32(
                cpu, GAME_SCRIPT_MANAGER_POINTER
            );
            const u32 camera_object = guest_range_valid(
                cpu,
                script_manager + GAME_SCRIPT_MANAGER_CAMERA_OFFSET,
                sizeof(u32)
            )
                ? mem_read32(
                      cpu,
                      script_manager + GAME_SCRIPT_MANAGER_CAMERA_OFFSET
                  )
                : 0u;
            const u32 diagnostic_context =
                trace->script_vm_diagnostic_context != 0u
                    ? trace->script_vm_diagnostic_context
                    : camera_object;
            if (
                diagnostic_context != 0u &&
                cpu->gpr[24] == diagnostic_context
            ) {
                const u32 destination =
                    cpu->gpr[31] + ((instruction >> 16u) & 0xFFu) * 4u;
                const u32 operand_b =
                    cpu->gpr[30] + ((instruction >> 8u) & 0xFFu) * 4u;
                const u32 operand_c =
                    cpu->gpr[29] + (instruction & 0xFFu) * 4u;
                fprintf(
                    stderr,
                    "script_vm frame=%llu ip=0x%08X instruction=0x%08X "
                    "next=0x%08X "
                    "context=0x%08X base29=0x%08X base30=0x%08X "
                    "base31=0x%08X local27=0x%08X local28=0x%08X "
                    "destination=0x%08X:0x%08X "
                    "operand_b=0x%08X:0x%08X "
                    "operand_c=0x%08X:0x%08X\n",
                    (unsigned long long)cpu->presented_frame_count,
                    instruction_pointer,
                    instruction,
                    mem_read32(cpu, instruction_pointer + 4u),
                    cpu->gpr[24],
                    cpu->gpr[29],
                    cpu->gpr[30],
                    cpu->gpr[31],
                    mem_read32(cpu, cpu->gpr[29] + 0x9Cu),
                    mem_read32(cpu, cpu->gpr[29] + 0xA0u),
                    destination,
                    mem_read32(cpu, destination),
                    operand_b,
                    mem_read32(cpu, operand_b),
                    operand_c,
                    mem_read32(cpu, operand_c)
                );
            }
        }
        const u64 event_index = trace->script_vm_dispatch_count++;
        ScriptVmEvent* event =
            &trace->script_vm_ring[event_index % SCRIPT_VM_RING_SIZE];
        event->instruction_pointer = instruction_pointer;
        event->instruction = instruction;
        event->context = cpu->gpr[24];
        event->base29 = cpu->gpr[29];
        event->base30 = cpu->gpr[30];
        event->base31 = cpu->gpr[31];
        trace->script_vm_last_instruction_pointer =
            instruction_pointer;
        trace->script_vm_last_instruction = instruction;
        trace->script_vm_last_context = cpu->gpr[24];
        trace->script_vm_last_base29 = cpu->gpr[29];
        trace->script_vm_last_base30 = cpu->gpr[30];
        trace->script_vm_last_base31 = cpu->gpr[31];
        const u32 spawned_script_base =
            trace->script_spawn_object
                ? mem_read32(cpu, trace->script_spawn_object + 472u)
                : 0u;
        if (
            trace->script_spawn_object &&
            (
                cpu->gpr[24] == trace->script_spawn_object ||
                (spawned_script_base && cpu->gpr[29] == spawned_script_base)
            )
        ) {
            const u32 spawn_event_index =
                trace->sync_frame_script_spawn_vm_dispatch_count;
            if (spawn_event_index == 0u) {
                trace->sync_frame_script_spawn_vm_first_instruction_pointer =
                    instruction_pointer;
            }
            if (spawn_event_index < SCRIPT_SPAWN_VM_FRAME_SIZE) {
                ScriptVmEvent* spawn_event =
                    &trace->sync_frame_script_spawn_vm_events[
                        spawn_event_index
                    ];
                spawn_event->instruction_pointer = instruction_pointer;
                spawn_event->instruction = instruction;
                spawn_event->context = cpu->gpr[24];
                spawn_event->base29 = cpu->gpr[29];
                spawn_event->base30 = cpu->gpr[30];
                spawn_event->base31 = cpu->gpr[31];
            }
            trace->sync_frame_script_spawn_vm_dispatch_count++;
            trace->sync_frame_script_spawn_vm_last_instruction_pointer =
                instruction_pointer;
            trace->sync_frame_script_spawn_vm_last_instruction = instruction;
        }
        const u32 script_event_code =
            trace->script_event_node_handler
                ? mem_read32(
                      cpu,
                      trace->script_event_node_handler + 16u
                  )
                : 0u;
        if (
            script_event_code &&
            instruction_pointer >= script_event_code &&
            instruction_pointer < script_event_code + 0x200u
        ) {
            trace->script_event_vm_dispatch_count++;
            trace->sync_frame_script_event_vm_dispatch_count++;
            trace->sync_frame_script_event_vm_last_instruction_pointer =
                instruction_pointer;
            trace->sync_frame_script_event_vm_last_instruction =
                instruction;
            trace->sync_frame_script_event_vm_last_base29 = cpu->gpr[29];
            trace->sync_frame_script_event_vm_last_base30 = cpu->gpr[30];
            trace->sync_frame_script_event_vm_last_base31 = cpu->gpr[31];
        }
        if (
            event_index == 0u ||
            instruction_pointer <
                trace->script_vm_min_instruction_pointer
        ) {
            trace->script_vm_min_instruction_pointer =
                instruction_pointer;
        }
        if (
            event_index == 0u ||
            instruction_pointer >
                trace->script_vm_max_instruction_pointer
        ) {
            trace->script_vm_max_instruction_pointer =
                instruction_pointer;
        }
        if (
            instruction_pointer >= GAME_WII_STRAP_SCRIPT_START &&
            instruction_pointer <
                GAME_WII_STRAP_SCRIPT_START +
                    GAME_WII_STRAP_SCRIPT_SIZE
        ) {
            trace->script_vm_wii_strap_dispatch_count++;
        }
        if (instruction_pointer == GAME_WII_STRAP_LOOP_START) {
            const u64 loop_index =
                trace->script_wii_strap_loop_count++;
            ScriptLoopEvent* loop_event =
                &trace->script_wii_strap_loop_ring[
                    loop_index % SCRIPT_LOOP_RING_SIZE
                ];
            loop_event->completed_frame =
                trace->gx_completed_frame_count;
            for (u32 index = 0u; index < 11u; ++index) {
                loop_event->values[index] =
                    mem_read32(cpu, cpu->gpr[31] + index * 4u);
            }
        }
        if (
            cpu->gpr[24] == GAME_TRANSITION_SCRIPT_CONTEXT &&
            instruction_pointer == GAME_TRANSITION_SCRIPT_LOOP
        ) {
            const u64 loop_index =
                trace->script_transition_loop_count++;
            ScriptLoopEvent* loop_event =
                &trace->script_transition_loop_ring[
                    loop_index % SCRIPT_LOOP_RING_SIZE
                ];
            loop_event->completed_frame =
                trace->gx_completed_frame_count;
            for (u32 index = 0u; index < 11u; ++index) {
                loop_event->values[index] =
                    mem_read32(cpu, cpu->gpr[31] + index * 4u);
            }
        }
        if (
            cpu->gpr[24] == GAME_TRANSITION_SCRIPT_CONTEXT &&
            (
                instruction_pointer == 0x9038F52Cu ||
                instruction_pointer == 0x9038F5E8u ||
                instruction_pointer == 0x9038F688u ||
                instruction_pointer == 0x9038F690u ||
                instruction_pointer == 0x9038F694u ||
                instruction_pointer == 0x9038F6B4u ||
                instruction_pointer == 0x9038F6B8u ||
                instruction_pointer == 0x9038F6CCu
            )
        ) {
            const u64 probe_index =
                trace->script_transition_probe_count++;
            ScriptTransitionProbeEvent* probe =
                &trace->script_transition_probe_ring[
                    probe_index % SCRIPT_TRANSITION_PROBE_RING_SIZE
                ];
            probe->completed_frame =
                trace->gx_completed_frame_count;
            probe->instruction_pointer = instruction_pointer;
            probe->ui_manager = mem_read32(cpu, 0x80256A70u);
            probe->ui_manager_flag = probe->ui_manager
                ? mem_read8(cpu, probe->ui_manager + 2060u)
                : 0u;
            for (u32 index = 0u; index < 16u; ++index) {
                probe->values[index] =
                    mem_read32(cpu, cpu->gpr[31] + index * 4u);
            }
        }
    } else if (
        address == GAME_SCRIPT_GLOBAL_WRITE &&
        cpu->gpr[16] == 0x35u
    ) {
        const u32 value = mem_read32(cpu, cpu->gpr[25]);
        const u32 input_state = mem_read32(
            cpu,
            GAME_INPUT_STATE_POINTER
        );
        const u32 script_manager = mem_read32(
            cpu,
            GAME_SCRIPT_MANAGER_POINTER
        );
        const u64 write_index = trace->script_global_35_write_count++;
        ScriptGlobalWriteEvent* write_event =
            &trace->script_global_35_write_ring[
                write_index % SCRIPT_VM_RING_SIZE
            ];
        write_event->completed_frame = trace->gx_completed_frame_count;
        write_event->context = cpu->gpr[24];
        write_event->instruction_pointer = cpu->gpr[26] - 4u;
        write_event->value = value;
        write_event->input_state = input_state;
        write_event->input_hold = input_state
            ? mem_read32(cpu, input_state + 68u)
            : 0u;
        write_event->input_trigger = input_state
            ? mem_read32(cpu, input_state + 72u)
            : 0u;
        write_event->input_release = input_state
            ? mem_read32(cpu, input_state + 76u)
            : 0u;
        write_event->script_manager = script_manager;
        write_event->script_input_hold = script_manager
            ? mem_read32(cpu, script_manager + 8228u)
            : 0u;
        write_event->script_input_trigger = script_manager
            ? mem_read32(cpu, script_manager + 8232u)
            : 0u;
        write_event->script_input_release = script_manager
            ? mem_read32(cpu, script_manager + 8236u)
            : 0u;
        write_event->root_input_hold = mem_read32(
            cpu,
            GAME_ROOT_SCRIPT_VARIABLES + 0x29u * 4u
        );
        write_event->root_input_trigger = mem_read32(
            cpu,
            GAME_ROOT_SCRIPT_VARIABLES + 0x2Au * 4u
        );
        write_event->root_input_release = mem_read32(
            cpu,
            GAME_ROOT_SCRIPT_VARIABLES + 0x2Bu * 4u
        );
        if (value != 0u) {
            const u64 event_index =
                trace->script_global_35_nonzero_write_count++;
            ScriptGlobalWriteEvent* event =
                &trace->script_global_35_nonzero_ring[
                    event_index % SCRIPT_LOOP_RING_SIZE
                ];
            *event = *write_event;
        }
    } else if (address == GAME_SCRIPT_EVENT_DISPATCH) {
        trace->script_event_dispatch_count++;
        trace->script_event_dispatch_object = cpu->gpr[3];
        trace->script_event_dispatch_id = cpu->gpr[5];
        trace->script_event_dispatch_kind = cpu->gpr[6];
        trace->script_event_dispatch_payload = cpu->gpr[7];
    } else if (address == GAME_SCRIPT_EVENT_NODE_CREATE) {
        trace->script_event_node_create_count++;
        trace->script_event_node_list = cpu->gpr[4];
        trace->script_event_node_handler = cpu->gpr[5];
        trace->script_event_node_context = cpu->gpr[6];
        trace->script_event_node_owner = cpu->gpr[7];
    } else if (address == GAME_SCRIPT_EVENT_NODE_CREATE_RETURN) {
        trace->script_event_node_result = cpu->gpr[3];
    } else if (address == GAME_SCRIPT_SPAWN_RETURN) {
        trace->script_spawn_count++;
        trace->script_spawn_object = cpu->gpr[3];
        trace->script_spawn_handle =
            cpu->gpr[3] ? mem_read32(cpu, cpu->gpr[3] + 448u) : 0u;
        if (
            cpu->gpr[24] == 0x807829F0u &&
            cpu->gpr[26] >= 0x90388458u &&
            cpu->gpr[26] <= 0x9038846Cu
        ) {
            trace->r2_root_wait_spawn_object = cpu->gpr[3];
        }
    } else if (address == GAME_FRAME_TIMING_FINALIZED) {
        apply_sync_frame_delta_after_timing(trace, cpu);
    } else if (address == GAME_LOGICAL_UPDATE_POST_STORE) {
        if (
            trace->sync_trace_checkpoint_pc ==
            GAME_LOGICAL_UPDATE_POST_STORE
        ) {
            write_sync_trace_frame(
                trace, cpu, GAME_LOGICAL_UPDATE_POST_STORE
            );
        }
    } else if (address == GAME_LOGICAL_UPDATE_ENTRY) {
        if (
            trace->sync_trace_checkpoint_pc ==
            GAME_LOGICAL_UPDATE_ENTRY
        ) {
            write_sync_trace_frame(
                trace, cpu, GAME_LOGICAL_UPDATE_ENTRY
            );
        }
    } else if (address == GAME_LOGICAL_UPDATE_CHECKPOINT) {
        if (
            trace->sync_trace_checkpoint_pc ==
            GAME_LOGICAL_UPDATE_CHECKPOINT
        ) {
            write_sync_trace_frame(
                trace, cpu, GAME_LOGICAL_UPDATE_CHECKPOINT
            );
        }
    } else if (address == GAME_FRAME_LOOP_BACKEDGE) {
        trace->frame_loop_count++;
        finish_gx_frame(trace, cpu);
    } else if (address == GAME_CONTROLLER_MANAGER_CALL) {
        if (sync_trace_replay_ready(trace, cpu)) {
            trace->sync_frame_controller_manager_call_count++;
        }
    } else if (address == GAME_CONTROLLER_MANAGER_UPDATE) {
        trace->game_controller_manager_update_count++;
        if (sync_trace_replay_ready(trace, cpu)) {
            if (
                trace->sync_frame_controller_manager_update_count < 4u
            ) {
                trace->sync_frame_controller_manager_update_callers[
                    trace->sync_frame_controller_manager_update_count
                ] = cpu->lr;
            }
            trace->sync_frame_controller_manager_update_count++;
        }
        trace->game_controller_manager = cpu->gpr[3];
        if (
            trace->controller_connected &&
            !trace->controller_connection_seeded
        ) {
            bool pristine = true;
            for (u32 index = 0u; index < 8u; ++index) {
                pristine =
                    pristine &&
                    (s32)mem_read32(
                        cpu,
                        cpu->gpr[3] + index * 8u
                    ) == -1;
            }
            for (u32 index = 0u; index < 4u; ++index) {
                pristine =
                    pristine &&
                    (s8)mem_read8(
                        cpu,
                        cpu->gpr[3] + 9114u + index * 12u
                    ) == -2;
            }
            if (pristine) {
                /*
                 * The native touch backend is P1. Mirror the manager state
                 * measured at Dolphin's first controller update, above
                 * Bluetooth/IOS and below the original title consumer.
                 */
                mem_write32(cpu, cpu->gpr[3], 1u);
                mem_write32(cpu, cpu->gpr[3] + 4u, 0u);
                trace->controller_connection_seeded = true;
                trace->controller_connection_seed_count++;
            }
        }
        if (
            trace->controller_connected &&
            trace->controller_connection_seeded
        ) {
            /*
             * The translated WPAD background task has no Bluetooth transport,
             * so retain Dolphin's measured connected-channel view at the
             * title wrapper on every reconciliation.
             */
            mem_write8(cpu, cpu->gpr[3] + 9114u, 0u);
            for (u32 index = 1u; index < 4u; ++index) {
                mem_write8(
                    cpu,
                    cpu->gpr[3] + 9114u + index * 12u,
                    0xFFu
                );
            }
        }
        for (u32 index = 0u; index < 8u; ++index) {
            trace->game_controller_slot_states[index] =
                (s32)mem_read32(cpu, cpu->gpr[3] + index * 8u);
        }
        for (u32 index = 0u; index < 4u; ++index) {
            trace->game_controller_connection_states[index] =
                (s8)mem_read8(
                    cpu,
                    cpu->gpr[3] + 9114u + index * 12u
                );
        }
    } else if (address == GAME_CONTROLLER_RECONCILE) {
        trace->game_controller_reconcile_count++;
    } else if (address == GAME_CONTROLLER_UPDATE_CALL) {
        if (sync_trace_replay_ready(trace, cpu)) {
            if (trace->sync_frame_controller_update_call_count < 4u) {
                trace->sync_frame_controller_update_call_objects[
                    trace->sync_frame_controller_update_call_count
                ] = cpu->gpr[3];
                trace->sync_frame_controller_update_call_slots[
                    trace->sync_frame_controller_update_call_count
                ] = cpu->gpr[30];
            }
            trace->sync_frame_controller_update_call_count++;
        }
    } else if (address == GAME_CONTROLLER_UPDATE) {
        trace->game_controller_update_count++;
        if (sync_trace_replay_ready(trace, cpu)) {
            if (trace->sync_frame_controller_update_count < 4u) {
                trace->sync_frame_controller_update_callers[
                    trace->sync_frame_controller_update_count
                ] = cpu->lr;
                trace->sync_frame_controller_update_objects[
                    trace->sync_frame_controller_update_count
                ] = cpu->gpr[3];
            }
            trace->sync_frame_controller_update_count++;
        }
    } else if (address == GAME_CONTROLLER_POST_KPAD) {
        trace->game_controller_post_kpad_count++;
        if (sync_trace_replay_ready(trace, cpu)) {
            if (trace->sync_frame_controller_post_kpad_count < 4u) {
                trace->sync_frame_controller_post_kpad_callers[
                    trace->sync_frame_controller_post_kpad_count
                ] = cpu->lr;
            }
            trace->sync_frame_controller_post_kpad_count++;
        }
        trace->game_controller_post_kpad_result = cpu->gpr[3];
        trace->game_controller_post_kpad_hash =
            fnv1a_guest_bytes(
                cpu,
                trace->kpad_last_buffer,
                KPAD_STATUS_SIZE
            );
    } else if (address == WII_SDK_WPAD_PROBE) {
        trace->wpad_probe_count++;
    } else if (address == WII_SDK_WPAD_READ) {
        trace->wpad_read_count++;
    } else if (address == WII_SDK_BINK_OPEN) {
        trace->bink_open_count++;
        if (protector_cinematic_observe_open(&trace->cinematic, cpu)) {
            ProtectorCinematicOpening opening = {.open_serial = trace->cinematic.open_serial};
            memcpy(opening.movie, trace->cinematic.movie, sizeof(opening.movie));
            protector_live_gx_prepare_cinematic(opening);
        }
    } else if (address == GAME_SAVE_PACKAGED_ASSET_LOAD) {
        trace->save_packaged_asset_load_count++;
        if (sync_trace_replay_ready(trace, cpu)) {
            trace->sync_frame_save_asset_load_count++;
            trace->sync_frame_save_asset_load_caller = cpu->lr;
        }
    } else if (address == GAME_SAVE_METADATA_INIT) {
        trace->save_metadata_init_count++;
        if (sync_trace_replay_ready(trace, cpu)) {
            trace->sync_frame_save_metadata_init_count++;
            trace->sync_frame_save_metadata_init_caller = cpu->lr;
        }
    } else if (address == GAME_SAVE_OBJECT_CONSTRUCTOR) {
        trace->save_object_constructor_count++;
    } else if (address == GAME_SAVE_MANAGER_INIT) {
        trace->save_manager_init_count++;
        if (sync_trace_replay_ready(trace, cpu)) {
            trace->sync_frame_save_manager_init_count++;
            trace->sync_frame_save_manager_init_caller = cpu->lr;
        }
    } else if (address == GAME_SAVE_ASYNC_LOAD) {
        trace->save_async_load_count++;
        trace->save_async_load_last_caller = cpu->lr;
        trace->save_async_load_last_object = cpu->gpr[3];
        trace->save_async_load_last_enabled =
            mem_read8(cpu, cpu->gpr[3] + 8u);
    } else if (address == GAME_SAVE_SCRIPT_LOAD) {
        trace->save_script_load_count++;
        trace->save_script_load_last_r3 = cpu->gpr[3];
        trace->save_script_load_last_r4 = cpu->gpr[4];
        trace->save_script_load_last_context = cpu->gpr[24];
        trace->save_script_load_last_instruction_pointer =
            cpu->gpr[26];
        trace->save_script_load_last_instruction =
            mem_read32(cpu, cpu->gpr[26]);
        trace->save_script_load_last_base29 = cpu->gpr[29];
        trace->save_script_load_last_base30 = cpu->gpr[30];
        trace->save_script_load_last_base31 = cpu->gpr[31];
        if (sync_trace_replay_ready(trace, cpu)) {
            trace->sync_frame_save_script_load_count++;
            trace->sync_frame_save_script_load_caller = cpu->lr;
        }
    } else if (address == GAME_SAVE_SCRIPT_SAVE) {
        trace->save_script_save_count++;
    } else if (address == GAME_SAVE_SCRIPT_LOAD_SLOT) {
        trace->save_script_load_slot_count++;
    } else if (address == GAME_SAVE_SCRIPT_SAVE_SLOT) {
        trace->save_script_save_slot_count++;
    } else if (address == WII_SDK_NAND_INIT) {
        trace->nand_init_count++;
        trace->nand_init_last_caller = cpu->lr;
    } else if (address == WII_SDK_NAND_OPEN) {
        trace->nand_open_count++;
        trace->nand_open_last_caller = cpu->lr;
    } else if (address == WII_SDK_NAND_GET_STATUS) {
        trace->nand_get_status_count++;
        trace->nand_get_status_last_caller = cpu->lr;
    } else if (address == WII_SDK_NAND_CLOSE) {
        trace->nand_close_count++;
        trace->nand_close_last_caller = cpu->lr;
    } else if (
        address == WII_SDK_OS_INIT_PLAY_TIME_AFTER_NAND_INIT
    ) {
        trace->nand_init_last_result = (s32)cpu->gpr[3];
    } else if (address == GAME_SAVE_ASYNC_LOAD_AFTER_NAND_OPEN) {
        trace->nand_open_last_result = (s32)cpu->gpr[3];
    } else if (
        address == GAME_SAVE_ASYNC_LOAD_AFTER_NAND_GET_STATUS
    ) {
        trace->nand_get_status_last_result = (s32)cpu->gpr[3];
    }
    if (address == WII_OS_LOAD_CONTEXT) {
        if (trace->ax_frame_dispatch_active) {
            if (cpu->lr != WII_OS_LOAD_CONTEXT) {
                return false;
            }
            if (!trace->ax_audio) {
                trace->ax_last_running_voice_count = protector_ax_process_frame(
                    cpu,
                    trace->ax_dsp_pb_pool,
                    PROTECTOR_AX_SAMPLES_PER_FRAME
                );
            } else {
                /* The command list already decoded and committed these PBs at
                 * the mailbox boundary. Advancing here would consume twice. */
                trace->ax_last_running_voice_count = 0;
                for (u32 i = 0; i < PROTECTOR_AX_VOICE_COUNT; ++i)
                    trace->ax_last_running_voice_count += mem_read16(cpu,
                        trace->ax_dsp_pb_pool + i * PROTECTOR_AX_PB_SIZE + 0x10u) == 1u;
            }
            if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
                return true;
            }
            trace->ax_frame_dispatch_active = false;
            trace->ax_frame_count++;
            trace->ax_next_frame_timebase +=
                trace->ax_frame_interval_timebase;
            restore_execution_state(
                cpu, &trace->ax_interrupted_state
            );
            return true;
        }
        if (trace->dvd_async_callback_dispatch_active) {
            if (cpu->lr != WII_OS_LOAD_CONTEXT) {
                return false;
            }
            trace_dvd_async_state(
                cpu,
                trace,
                "post_callback",
                &trace->dvd_async_active_event
            );
            memset(
                &trace->dvd_async_active_event,
                0,
                sizeof(trace->dvd_async_active_event)
            );
            trace->dvd_async_callback_dispatch_active = false;
            restore_execution_state(
                cpu, &trace->dvd_async_interrupted_state
            );
            return true;
        }
        if (trace->ipc_dispatch_active) {
            trace->ipc_dispatch_active = false;
            if (cpu->lr != WII_OS_LOAD_CONTEXT) {
                return false;
            }
            restore_execution_state(
                cpu, &trace->ipc_interrupted_state
            );
            return true;
        }
        if (trace->vi_dispatch_active) {
            trace->vi_dispatch_active = false;
            if (cpu->lr != WII_OS_LOAD_CONTEXT) {
                return false;
            }
            restore_execution_state(
                cpu, &trace->vi_interrupted_state
            );
            trace->vi_reschedule_active = true;
            cpu->lr = WII_OS_LOAD_CONTEXT;
            cpu->pc = WII_OS_RESCHEDULE;
            return true;
        }
        if (trace->vi_reschedule_active) {
            trace->vi_reschedule_active = false;
            if (cpu->lr != WII_OS_LOAD_CONTEXT) {
                return false;
            }
            restore_execution_state(
                cpu, &trace->vi_interrupted_state
            );
            return true;
        }
        if (trace->pe_dispatch_active) {
            trace->pe_dispatch_active = false;
            trace->pe_run_queue_hint_after =
                mem_read32(cpu, cpu->gpr[13] - 17268u);
            trace->pe_run_queue_bits_after =
                mem_read32(cpu, cpu->gpr[13] - 17264u);
            trace->pe_current_context_after =
                mem_read32(cpu, 0x800000D4u);
            trace->pe_current_thread_after =
                mem_read32(cpu, 0x800000E4u);
            if (cpu->lr != WII_OS_LOAD_CONTEXT) {
                return false;
            }
            restore_execution_state(
                cpu, &trace->pe_interrupted_state
            );
            /*
             * __OSDispatchInterrupt runs __OSReschedule after the device
             * handler and before OSLoadContext. Our direct device-handler
             * seam must preserve that epilogue or a thread made runnable by
             * OSWakeupThread remains queued while the idle context resumes.
             */
            trace->pe_reschedule_active = true;
            cpu->lr = WII_OS_LOAD_CONTEXT;
            cpu->pc = WII_OS_RESCHEDULE;
            return true;
        }
        if (trace->pe_reschedule_active) {
            trace->pe_reschedule_active = false;
            if (cpu->lr != WII_OS_LOAD_CONTEXT) {
                return false;
            }
            restore_execution_state(
                cpu, &trace->pe_interrupted_state
            );
            return true;
        }
        trace->context_load_count++;
        trace->last_context_address = cpu->gpr[3];
        trace->last_context_state =
            mem_read16(cpu, cpu->gpr[3] + 418u);
        trace->last_context_gpr6 =
            mem_read32(cpu, cpu->gpr[3] + 24u);
        ContextLoadEvent* event =
            &trace->context_load_ring[
                (trace->context_load_count - 1u) % TRACE_RING_SIZE
            ];
        event->context = cpu->gpr[3];
        event->resume_pc = mem_read32(cpu, cpu->gpr[3] + 408u);
        event->stack_pointer = mem_read32(cpu, cpu->gpr[3] + 4u);
        ContextSummary* summary = NULL;
        for (
            u32 index = 0u;
            index < trace->context_summary_count;
            ++index
        ) {
            if (
                trace->context_summaries[index].context ==
                event->context
            ) {
                summary = &trace->context_summaries[index];
                break;
            }
        }
        if (
            !summary &&
            trace->context_summary_count <
                sizeof(trace->context_summaries) /
                    sizeof(trace->context_summaries[0])
        ) {
            summary =
                &trace->context_summaries[
                    trace->context_summary_count++
                ];
            summary->context = event->context;
        }
        if (summary) {
            summary->load_count++;
            summary->last_resume_pc = event->resume_pc;
            summary->last_stack_pointer = event->stack_pointer;
        }
    }
    if (address == WII_OS_SLEEP_THREAD) {
        SleepEvent* event =
            &trace->sleep_ring[
                trace->sleep_count % TRACE_RING_SIZE
            ];
        event->context =
            mem_read32(cpu, WII_OS_CURRENT_CONTEXT);
        event->queue = cpu->gpr[3];
        event->caller = cpu->lr;
        trace->sleep_count++;
    }
    if (address == 0x800A99C4u) {
        trace->hash_resume_count++;
        trace->last_hash_resume_gpr3 = cpu->gpr[3];
        trace->last_hash_resume_gpr6 = cpu->gpr[6];
    }
    if (
        trace->dispatch_breadcrumb_count == 0u ||
        trace->dispatch_breadcrumbs[
            (trace->dispatch_breadcrumb_count - 1u) %
            DISPATCH_BREADCRUMB_SIZE
        ].address != address
    ) {
        DispatchBreadcrumb* breadcrumb =
            &trace->dispatch_breadcrumbs[
                trace->dispatch_breadcrumb_count %
                DISPATCH_BREADCRUMB_SIZE
            ];
        breadcrumb->address = address;
        breadcrumb->lr = cpu->lr;
        breadcrumb->r1 = cpu->gpr[1];
        breadcrumb->r3 = cpu->gpr[3];
        breadcrumb->r4 = cpu->gpr[4];
        trace->dispatch_breadcrumb_count++;
    }
    if (
        trace->dvd_async_stack_depth > 0u &&
        cpu->lr == address &&
        trace->dvd_async_seam_stack[
            trace->dvd_async_stack_depth - 1u
        ] == address
    ) {
        /*
         * A translated async callback returns through this deliberately
         * hooked SDK entry. Complete the suspended API call with BOOL true.
         */
        cpu->pc =
            trace->dvd_async_return_stack[
                --trace->dvd_async_stack_depth
            ];
        cpu->gpr[3] = 1u;
        return true;
    }
    if (address == WII_SDK_DVD_READ_ASYNC_PRIO) {
        discard_cancelled_dvd_async_callbacks(cpu, trace);
        u32 file_info = cpu->gpr[3];
        u32 destination = cpu->gpr[4];
        u32 length = cpu->gpr[5];
        u32 file_offset = cpu->gpr[6];
        u32 callback = cpu->gpr[7];
        u32 disc_offset_words = mem_read32(cpu, file_info + 48u);
        bind_content_trace_clock(cpu, trace);
        if (
            cpu->stop_reason != PROTECTOR_STOP_NONE ||
            !trace->mount ||
            !protector_prepare_wii_file_read(
                cpu,
                trace->mount,
                disc_offset_words,
                file_offset,
                destination,
                length,
                &trace->last_file_read,
                trace->platform_error,
                sizeof(trace->platform_error)
            )
        ) {
            protector_stop(
                cpu,
                PROTECTOR_STOP_PLATFORM_ERROR,
                address,
                0,
                disc_offset_words
            );
            return true;
        }
        trace->file_read_count++;
        reset_sync_trace_gameplay_settle(trace);
        trace->dvd_async_read_count++;
        const bool sync_trace_anchor_completion =
            trace->sync_trace_anchor_path &&
            strcmp(
                trace->last_file_read.relative_path,
                trace->sync_trace_anchor_path
            ) == 0;
        if (trace->dvd_async_read_count == 1u) {
            trace->first_content_file_info = file_info;
            trace->first_content_disc_offset_words = disc_offset_words;
            trace->first_content_fst_entry_index =
                trace->last_file_read.fst_entry_index;
            trace->first_content_destination = destination;
            trace->first_content_callback = callback;
            trace->first_content_hash = 0u;
        }
        mem_write32(
            cpu,
            file_info + 16u,
            disc_offset_words + file_offset / 4u
        );
        mem_write32(cpu, file_info + 20u, length);
        mem_write32(cpu, file_info + 24u, destination);
        mem_write32(cpu, file_info + 32u, length);
        mem_write32(cpu, file_info + 40u, WII_SDK_DVD_COMMAND_BLOCK_CALLBACK);
        mem_write32(cpu, file_info + 56u, callback);
        /*
         * DVDCommandBlock::command is +8 and ::state is +12.  The translated
         * DVDGetCommandBlockStatus implementation polls +12, so preserve the
         * SDK layout exactly: command READ (1), state WAITING (2). Writing the
         * busy value into +8 makes an in-flight read look terminal and also
         * corrupts the command identifier.
         */
        mem_write32(cpu, file_info + 8u, 1u);
        mem_write32(cpu, file_info + 12u, 2u);
        if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
            return true;
        }
        if (
            trace->stop_after_first_content &&
            trace->dvd_async_read_count == 1u
        ) {
            protector_stop(
                cpu,
                PROTECTOR_STOP_HOST_SERVICE,
                address,
                0,
                address
            );
            return true;
        }
        if (callback >= GC_RAM_BASE) {
            if (
                !queue_dvd_async_callback(
                    cpu,
                    trace,
                    callback,
                    length,
                    file_info,
                    destination,
                    address,
                    !path_has_suffix(
                        trace->last_file_read.relative_path,
                        ".bik"
                    ),
                    sync_trace_anchor_completion,
                    &trace->last_file_read
                )
            ) {
                return true;
            }
            /*
             * DVDReadAsyncPrio returns before its callback runs. The frozen
             * title trace measures a four-presentation startup latency for a
             * new read burst, followed by one chained completion per frame.
             * Releasing every callback after one translated block collapses
             * the initial device latency and starts 99_95.gcs four reference
             * checkpoints early.
             */
        } else {
            /*
             * Bink uses DVDReadAsyncPrio with a null user callback and polls
             * the command block. There is no translated callback seam that
             * can promote this request, so complete its DMA before returning
             * and expose the same terminal command-block state.
             */
            if (
                !protector_complete_wii_file_read(
                    cpu,
                    trace->mount,
                    &trace->last_file_read,
                    destination,
                    trace->platform_error,
                    sizeof(trace->platform_error)
                )
            ) {
                protector_stop(
                    cpu,
                    PROTECTOR_STOP_PLATFORM_ERROR,
                    address,
                    0,
                    disc_offset_words
                );
                return true;
            }
            mem_write32(cpu, file_info + 12u, 0u);
            mem_write32(cpu, file_info + 28u, length);
            mem_write32(
                cpu,
                file_info + 40u,
                WII_SDK_DVD_COMMAND_BLOCK_CALLBACK
            );
            if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
                return true;
            }
            if (!protector_trace_wii_file_completion(
                    cpu,
                    &trace->last_file_read,
                    trace->file_read_count - 1u,
                    trace->file_read_completion_count,
                    fnv1a_guest_bytes(
                        cpu,
                        destination,
                        trace->last_file_read.requested_length
                    )
                )) {
                (void)snprintf(
                    trace->platform_error,
                    sizeof(trace->platform_error),
                    "cannot append file-read completion trace"
                );
                protector_stop(
                    cpu,
                    PROTECTOR_STOP_PLATFORM_ERROR,
                    address,
                    0,
                    destination
                );
                return true;
            }
            trace->file_read_completion_count++;
            trace->last_completed_file_read = trace->last_file_read;
            reset_sync_trace_gameplay_settle(trace);
        }
        cpu->gpr[3] = 1u;
        cpu->pc = cpu->lr;
        return true;
    }
    if (address == WII_SDK_DVD_SEEK_ASYNC_PRIO) {
        discard_cancelled_dvd_async_callbacks(cpu, trace);
        u32 file_info = cpu->gpr[3];
        u32 file_offset = cpu->gpr[4];
        u32 callback = cpu->gpr[5];
        u32 disc_offset_words = mem_read32(cpu, file_info + 48u);
        mem_write32(cpu, file_info + 8u, 2u);
        mem_write32(cpu, file_info + 12u, 2u);
        mem_write32(
            cpu,
            file_info + 16u,
            disc_offset_words + file_offset / 4u
        );
        mem_write32(cpu, file_info + 56u, callback);
        mem_write32(cpu, file_info + 40u, WII_SDK_DVD_SEEK_BLOCK_CALLBACK);
        if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
            return true;
        }
        if (callback >= GC_RAM_BASE) {
            if (
                !queue_dvd_async_callback(
                    cpu,
                    trace,
                    callback,
                    0u,
                    file_info,
                    0u,
                    address,
                    false,
                    false,
                    NULL
                )
            ) {
                return true;
            }
        }
        cpu->gpr[3] = 1u;
        cpu->pc = cpu->lr;
        return true;
    }
    if (address == WII_SDK_DVD_READ_PRIO) {
        u32 file_info = cpu->gpr[3];
        u32 destination = cpu->gpr[4];
        u32 length = cpu->gpr[5];
        u32 file_offset = cpu->gpr[6];
        u32 disc_offset_words = mem_read32(cpu, file_info + 48u);
        bind_content_trace_clock(cpu, trace);
        if (
            cpu->stop_reason != PROTECTOR_STOP_NONE ||
            !trace->mount ||
            !protector_read_wii_file(
                cpu,
                trace->mount,
                disc_offset_words,
                file_offset,
                destination,
                length,
                &trace->last_file_read,
                trace->platform_error,
                sizeof(trace->platform_error)
            )
        ) {
            protector_stop(
                cpu,
                PROTECTOR_STOP_PLATFORM_ERROR,
                address,
                0,
                disc_offset_words
            );
            return true;
        }
        trace->file_read_count++;
        trace->file_read_completion_count++;
        trace->last_completed_file_read = trace->last_file_read;
        if (
            trace->sync_trace_anchor_path &&
            strcmp(
                trace->last_file_read.relative_path,
                trace->sync_trace_anchor_path
            ) == 0
        ) {
            trace->sync_trace_content_ready = true;
        }
        reset_sync_trace_gameplay_settle(trace);
        /*
         * DVDReadPrio is synchronous. Mirror the material command-block
         * fields observed by callers without entering the Wii DI/IOS queue.
         */
        mem_write32(cpu, file_info + 8u, 1u);
        mem_write32(cpu, file_info + 12u, 0u);
        mem_write32(
            cpu,
            file_info + 16u,
            disc_offset_words + file_offset / 4u
        );
        mem_write32(cpu, file_info + 20u, length);
        mem_write32(cpu, file_info + 24u, destination);
        mem_write32(cpu, file_info + 32u, length);
        if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
            return true;
        }
        if (!protector_trace_wii_file_completion(
                cpu,
                &trace->last_file_read,
                trace->file_read_count - 1u,
                trace->file_read_completion_count - 1u,
                fnv1a_guest_bytes(
                    cpu,
                    destination,
                    trace->last_file_read.requested_length
                )
            )) {
            (void)snprintf(
                trace->platform_error,
                sizeof(trace->platform_error),
                "cannot append file-read completion trace"
            );
            protector_stop(
                cpu,
                PROTECTOR_STOP_PLATFORM_ERROR,
                address,
                0,
                destination
            );
            return true;
        }
        cpu->gpr[3] = length;
        cpu->pc = cpu->lr;
        return true;
    }
    if (address == WII_SDK_DSP_ADD_TASK) {
        u32 task = cpu->gpr[3];
        u32 init_callback = mem_read32(cpu, task + 40u);
        trace->stub_count++;
        trace->last_stub = address;
        trace->dsp_add_task_stub_count++;
        trace->dsp_task = task;
        trace->dsp_task_caller = cpu->lr;
        trace->dsp_task_init_callback = init_callback;
        trace->dsp_task_resume_callback = mem_read32(cpu, task + 44u);
        trace->dsp_task_done_callback = mem_read32(cpu, task + 48u);
        trace->dsp_task_request_callback = mem_read32(cpu, task + 52u);
        if (trace->ax_audio && !protector_ax_engine_configure(trace->ax_audio, cpu, task)) {
            stop_ax_audio(cpu, trace, trace->ax_audio->error);
            return true;
        }
        if (trace->ax_audio) {
            protector_ax_diagnostics_engine(&trace->ax_diagnostics, trace->ax_audio);
            protector_ax_diagnostics_publish(&trace->ax_diagnostics);
        }
        if (trace->ax_emulation_enabled) {
            if (!protector_ax_find_dsp_pb_pool(
                    cpu, task, &trace->ax_dsp_pb_pool
                )) {
                (void)snprintf(
                    trace->platform_error,
                    sizeof(trace->platform_error),
                    "DSP task has no discoverable AX PB pool"
                );
                protector_stop(
                    cpu,
                    PROTECTOR_STOP_PLATFORM_ERROR,
                    address,
                    0,
                    task
                );
                return true;
            }
            trace->ax_frame_armed = true;
            trace->ax_next_frame_timebase =
                cpu->timebase + trace->ax_frame_interval_timebase;
            if (trace->gameplay_call_diagnostics) {
                fprintf(
                    stderr,
                    "dsp_add_task task=0x%08X caller=0x%08X init=0x%08X "
                    "resume=0x%08X done=0x%08X request=0x%08X "
                    "ax_pb_pool=0x%08X next_ax_tb=%" PRIu64 "\n",
                    trace->dsp_task,
                    trace->dsp_task_caller,
                    trace->dsp_task_init_callback,
                    trace->dsp_task_resume_callback,
                    trace->dsp_task_done_callback,
                    trace->dsp_task_request_callback,
                    trace->ax_dsp_pb_pool,
                    trace->ax_next_frame_timebase
                );
            }
        }
        mem_write32(cpu, task, 0u);
        mem_write32(cpu, task + 8u, 1u);
        if (
            cpu->stop_reason != PROTECTOR_STOP_NONE ||
            init_callback < GC_RAM_BASE
        ) {
            protector_stop(
                cpu,
                PROTECTOR_STOP_PLATFORM_ERROR,
                address,
                0,
                init_callback
            );
            return true;
        }
        /*
         * The translated AX callback owns CPU-side voice synchronization.
         * Tail-call the SDK task initializer here; the silent host DSP seam
         * begins servicing its PB pool at periodic block boundaries.
         */
        cpu->gpr[3] = task;
        cpu->pc = init_callback;
        return true;
    }
    if (address == WII_SDK_KPAD_READ) {
        const u32 channel = cpu->gpr[3];
        const u32 buffer = cpu->gpr[4];
        const u32 capacity = cpu->gpr[5];
        trace->kpad_read_count++;
        trace->kpad_last_channel = channel;
        trace->kpad_last_buffer = buffer;
        trace->kpad_last_capacity = capacity;
        if (channel >= 4u || capacity == 0u ||
            (protector_live_input_enabled() && channel != 0u)) {
            cpu->gpr[3] = 0u;
            cpu->pc = cpu->lr;
            return true;
        }
        u32 sample_hold = 0u;
        u32 sample_trigger = 0u;
        u32 sample_release = 0u;
        for (u32 offset = 0u; offset < KPAD_STATUS_SIZE; ++offset) {
            mem_write8(
                cpu,
                buffer + offset,
                trace->kpad_status_template_valid
                    ? trace->kpad_status_template[offset]
                    : 0u
            );
        }
        ProtectorLiveInputSample live_sample;
        if (protector_live_input_sample(&live_sample)) {
            sample_hold = live_sample.hold;
            sample_trigger = live_sample.trigger;
            sample_release = live_sample.release;
            u8 live_status[KPAD_STATUS_SIZE];
            memcpy(live_status, trace->kpad_status_template, sizeof(live_status));
            if (!protector_live_input_encode_kpad(&live_sample, live_status,
                                                 sizeof(live_status))) {
                protector_stop(cpu, PROTECTOR_STOP_PLATFORM_ERROR, address, 0, buffer);
                return true;
            }
            for (u32 offset = 0; offset < KPAD_STATUS_SIZE; ++offset)
                mem_write8(cpu, buffer + offset, live_status[offset]);
        } else if (sync_trace_replay_ready(trace, cpu)) {
            if (!apply_sync_checkpoint_replay(trace, cpu)) {
                cpu->gpr[3] = 0u;
                cpu->pc = cpu->lr;
                return true;
            }
            if (trace->sync_frame_kpad_read_count == 0u) {
                trace->sync_frame_kpad_first_caller = cpu->lr;
            }
            trace->sync_frame_kpad_read_count++;
            trace->sync_frame_kpad_last_caller = cpu->lr;
            if (
                trace->sync_input_next_index >=
                trace->sync_input_sample_count &&
                !trace->sync_input_current_valid
            ) {
                trace->sync_trace_failed = true;
                cpu->gpr[3] = 0u;
                cpu->pc = cpu->lr;
                return true;
            }
            if (!trace->sync_input_current_valid) {
                trace->sync_input_current_index =
                    trace->sync_input_next_index;
                trace->sync_input_current =
                    trace->sync_input_samples[
                        trace->sync_input_next_index++
                    ];
                trace->sync_input_current_valid = true;
            }
            mem_write32(
                cpu,
                buffer,
                trace->sync_input_current.hold
            );
            mem_write32(
                cpu,
                buffer + 4u,
                trace->sync_input_current.trigger
            );
            mem_write32(
                cpu,
                buffer + 8u,
                trace->sync_input_current.release
            );
            mem_write8(
                cpu,
                buffer + 0x5Cu,
                trace->sync_input_current.device_type
            );
            mem_write8(
                cpu,
                buffer + 0x5Du,
                trace->sync_input_current.wpad_error
            );
            mem_write8(
                cpu,
                buffer + 0x5Eu,
                trace->sync_input_current.dpd_valid
            );
            mem_write8(
                cpu,
                buffer + 0x5Fu,
                trace->sync_input_current.data_format
            );
            if (trace->sync_input_current.has_nunchuk_stick) {
                mem_write32(
                    cpu,
                    buffer + 0x60u,
                    trace->sync_input_current.nunchuk_stick_x_bits
                );
                mem_write32(
                    cpu,
                    buffer + 0x64u,
                    trace->sync_input_current.nunchuk_stick_y_bits
                );
            }
            if (trace->sync_input_current.has_motion) {
                static const u32 motion_offsets[10] = {
                    0x0Cu, 0x10u, 0x14u, 0x18u, 0x1Cu,
                    0x68u, 0x6Cu, 0x70u, 0x74u, 0x78u,
                };
                for (u32 index = 0u; index < 10u; ++index) {
                    mem_write32(
                        cpu,
                        buffer + motion_offsets[index],
                        trace->sync_input_current.motion_bits[index]
                    );
                }
            }
            sample_hold = trace->sync_input_current.hold;
            sample_trigger = trace->sync_input_current.trigger;
            sample_release = trace->sync_input_current.release;
        } else if (trace->kpad_status_template_valid) {
            for (u32 offset = 0u; offset < KPAD_STATUS_SIZE; ++offset) {
                mem_write8(
                    cpu,
                    buffer + offset,
                    trace->kpad_status_template[offset]
                );
            }
            sample_hold =
                ((u32)trace->kpad_status_template[0] << 24) |
                ((u32)trace->kpad_status_template[1] << 16) |
                ((u32)trace->kpad_status_template[2] << 8) |
                (u32)trace->kpad_status_template[3];
            sample_trigger =
                ((u32)trace->kpad_status_template[4] << 24) |
                ((u32)trace->kpad_status_template[5] << 16) |
                ((u32)trace->kpad_status_template[6] << 8) |
                (u32)trace->kpad_status_template[7];
            sample_release =
                ((u32)trace->kpad_status_template[8] << 24) |
                ((u32)trace->kpad_status_template[9] << 16) |
                ((u32)trace->kpad_status_template[10] << 8) |
                (u32)trace->kpad_status_template[11];
            if (
                trace->kpad_pulse_mask != 0u &&
                trace->kpad_read_count >= trace->kpad_pulse_start
            ) {
                const u64 phase =
                    (trace->kpad_read_count - trace->kpad_pulse_start) %
                    trace->kpad_pulse_interval;
                if (phase == 0u) {
                    sample_hold = trace->kpad_pulse_mask;
                    sample_trigger = trace->kpad_pulse_mask;
                    sample_release = 0u;
                    trace->kpad_pulse_sample_count++;
                } else if (phase == 1u) {
                    sample_hold = 0u;
                    sample_trigger = 0u;
                    sample_release = trace->kpad_pulse_mask;
                }
                mem_write32(cpu, buffer, sample_hold);
                mem_write32(cpu, buffer + 4u, sample_trigger);
                mem_write32(cpu, buffer + 8u, sample_release);
            }
            for (u32 index = 0u;
                 index < trace->kpad_scheduled_pulse_count;
                 ++index) {
                const ScheduledKpadPulse* pulse =
                    &trace->kpad_scheduled_pulses[index];
                if (
                    trace->gx_completed_frame_count ==
                    pulse->checkpoint
                ) {
                    sample_hold |= pulse->mask;
                    sample_trigger |= pulse->mask;
                    trace->kpad_pulse_sample_count++;
                } else if (
                    trace->gx_completed_frame_count ==
                    pulse->checkpoint + 1u
                ) {
                    sample_release |= pulse->mask;
                }
            }
            if (trace->kpad_scheduled_pulse_count > 0u) {
                mem_write32(cpu, buffer, sample_hold);
                mem_write32(cpu, buffer + 4u, sample_trigger);
                mem_write32(cpu, buffer + 8u, sample_release);
            }
        }
        if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
            return true;
        }
        trace->kpad_last_hold = sample_hold;
        trace->kpad_last_trigger = sample_trigger;
        trace->kpad_last_release = sample_release;
        if (
            sample_hold == 0u &&
            sample_trigger == 0u &&
            sample_release == 0u
        ) {
            trace->kpad_neutral_sample_count++;
        } else {
            trace->kpad_non_neutral_sample_count++;
        }
        cpu->gpr[3] = 1u;
        cpu->pc = cpu->lr;
        return true;
    }
    for (size_t index = 0;
         index < sizeof(PLATFORM_STUBS) / sizeof(PLATFORM_STUBS[0]);
         ++index) {
        if (
            address == PLATFORM_STUBS[index].address &&
            address != WII_SDK_OS_INIT_PLAY_TIME
        ) {
            trace->stub_count++;
            trace->last_stub = address;
            trace->platform_stub_counts[index]++;
            if (address == WII_SDK_WUD_GET_STATUS) {
                if (trace->wud_status_first_caller == 0u) {
                    trace->wud_status_first_caller = cpu->lr;
                } else if (trace->wud_status_last_caller != cpu->lr) {
                    trace->wud_status_caller_changes++;
                }
                trace->wud_status_last_caller = cpu->lr;
            }
            if (address == WII_SDK_VI_WAIT_FOR_RETRACE) {
                trace->vi_retrace_armed = true;
                if (trace->next_vi_retrace_timebase == 0u) {
                    trace->next_vi_retrace_timebase =
                        cpu->timebase;
                }
            }
            if (
                address == WII_SDK_DVD_INIT &&
                !protector_bind_rbneg9_dvdfs(cpu)
            ) {
                protector_stop(
                    cpu,
                    PROTECTOR_STOP_PLATFORM_ERROR,
                    address,
                    0,
                    address
                );
                return true;
            }
            if (address == WII_SDK_DVD_INIT) {
                /*
                 * The native mount replaces DI/IOS transport, but callers
                 * still depend on DVDInit's software queue constructor.
                 * Tail-call the translated constructor and let it return
                 * directly to DVDInit's original caller.
                 */
                cpu->pc = WII_SDK_DVD_CLEAR_WAITING_QUEUE;
                return true;
            }
            cpu->gpr[3] =
                address == WII_SDK_WUD_GET_STATUS
                    ? (u32)trace->wud_status_result
                    : PLATFORM_STUBS[index].result;
            cpu->pc = cpu->lr;
            return true;
        }
    }
    return false;
}

static bool deliver_ax_frame(CPUState* cpu, BootTrace* trace) {
    if (
        !trace->ax_frame_armed ||
        trace->ax_frame_dispatch_active ||
        trace->dvd_async_callback_dispatch_active ||
        trace->ipc_dispatch_active ||
        trace->vi_dispatch_active ||
        trace->vi_reschedule_active ||
        trace->pe_dispatch_active ||
        trace->pe_reschedule_active ||
        (cpu->msr & PPC_MSR_EE) == 0u ||
        cpu->timebase < trace->ax_next_frame_timebase
    ) {
        return false;
    }
    if (trace->ax_dsp_pb_pool < GC_RAM_BASE) {
        (void)snprintf(
            trace->platform_error,
            sizeof(trace->platform_error),
            "AX frame fired without a DSP PB pool"
        );
        protector_stop(
            cpu,
            PROTECTOR_STOP_PLATFORM_ERROR,
            cpu->pc,
            0,
            trace->ax_dsp_pb_pool
        );
        return false;
    }

    bool mix_quiescent = trace->imported_checkpoint && !trace->ax_audio;
    const u32 r13 = cpu->gpr[13];
    const u32 mix_table_pointer_address = r13 - 16296u;
    const u32 mix_count_address = r13 - 16288u;
    const u32 mix_state_pointer_address = r13 - 16280u;
    const u32 frame_callback_address = r13 - 16444u;
    const u32 ax_mode_address = r13 - 16472u;
    const u32 aux_a_callback_address = r13 - 16536u;
    const u32 aux_b_callback_address = r13 - 16540u;
    const u32 aux_c_callback_address = r13 - 16544u;
    if (
        mix_quiescent &&
        (
            !guest_range_valid(cpu, mix_table_pointer_address, 4u) ||
            !guest_range_valid(cpu, mix_count_address, 4u) ||
            !guest_range_valid(cpu, mix_state_pointer_address, 4u) ||
            !guest_range_valid(cpu, frame_callback_address, 4u) ||
            !guest_range_valid(cpu, ax_mode_address, 4u) ||
            !guest_range_valid(cpu, aux_a_callback_address, 4u) ||
            !guest_range_valid(cpu, aux_b_callback_address, 4u) ||
            !guest_range_valid(cpu, aux_c_callback_address, 4u)
        )
    ) {
        mix_quiescent = false;
    }
    u32 mix_table = 0u;
    u32 mix_state = 0u;
    if (mix_quiescent) {
        mix_table = mem_read32(cpu, mix_table_pointer_address);
        mix_state = mem_read32(cpu, mix_state_pointer_address);
        mix_quiescent =
            mem_read32(cpu, frame_callback_address) == 0x8017D388u &&
            mem_read32(cpu, aux_a_callback_address) == 0u &&
            mem_read32(cpu, aux_b_callback_address) == 0u &&
            mem_read32(cpu, aux_c_callback_address) == 0u &&
            mem_read32(cpu, mix_count_address) == 96u &&
            guest_range_valid(cpu, mix_table, 96u * 112u) &&
            guest_range_valid(cpu, mix_state, 96u * 68u);
    }
    for (u32 index = 0u; mix_quiescent && index < 96u; ++index) {
        const u32 entry = mix_table + index * 112u;
        if (
            mem_read32(cpu, entry) != 0u &&
            (
                mem_read32(cpu, entry + 4u) != 0u ||
                mem_read32(cpu, mix_state + index * 68u) != 0u
            )
        ) {
            mix_quiescent = false;
        }
    }

    /*
     * Wii AX produces 96 output samples every three milliseconds. The
     * imported title callback is MIXUpdateSettings; while its populated MIX
     * slots are clean and AUX callbacks are absent, it is a persistent-state
     * no-op. Dispatch __AXSyncPBs directly in that proven state, but retain
     * the translated PB sync and the native 96-sample advance on every tick.
     * Any live MIX/AUX state falls back to the complete __AXOutNewFrame path.
     */
    save_execution_state(&trace->ax_interrupted_state, cpu);
    trace->ax_frame_dispatch_active = true;
    cpu->msr &= ~PPC_MSR_EE;
    cpu->lr = WII_OS_LOAD_CONTEXT;
    if (mix_quiescent) {
        cpu->gpr[3] =
            mem_read32(cpu, ax_mode_address) == 1u ? 0u : 24400u;
        cpu->pc = WII_SDK_AX_SYNC_PBS;
        trace->ax_fast_sync_frame_count++;
    } else {
        cpu->gpr[3] = 0u;
        cpu->pc = WII_SDK_AX_OUT_NEW_FRAME;
        trace->ax_full_frame_count++;
    }
    return true;
}

static bool initialize_imported_ax_state(
    CPUState* cpu,
    BootTrace* trace
) {
    static const u32 expected_callbacks[4] = {
        0x800DBB40u,
        0x800DBB4Cu,
        0x800DBBA0u,
        0x800DBBB0u,
    };
    for (u32 index = 0u; index < 4u; ++index) {
        if (
            mem_read32(cpu, RBNEG9_AX_DSP_TASK + 40u + index * 4u) !=
            expected_callbacks[index]
        ) {
            (void)snprintf(
                trace->platform_error,
                sizeof(trace->platform_error),
                "imported AX task callback %u is not RBNEG9 canonical",
                index
            );
            return false;
        }
    }
    trace->dsp_task = RBNEG9_AX_DSP_TASK;
    trace->dsp_task_init_callback = expected_callbacks[0];
    trace->dsp_task_resume_callback = expected_callbacks[1];
    trace->dsp_task_done_callback = expected_callbacks[2];
    trace->dsp_task_request_callback = expected_callbacks[3];
    if (!protector_ax_find_dsp_pb_pool(
            cpu,
            trace->dsp_task,
            &trace->ax_dsp_pb_pool
        )) {
        (void)snprintf(
            trace->platform_error,
            sizeof(trace->platform_error),
            "imported AX task has no discoverable PB pool"
        );
        return false;
    }
    const u64 phase = cpu->timebase % WII_AX_FRAME_TIMEBASE_TICKS;
    const u64 ticks_until_next =
        phase < RBNEG9_AX_TIMEBASE_PHASE
            ? RBNEG9_AX_TIMEBASE_PHASE - phase
            : WII_AX_FRAME_TIMEBASE_TICKS -
                  (phase - RBNEG9_AX_TIMEBASE_PHASE);
    trace->ax_next_frame_timebase = cpu->timebase + ticks_until_next;
    trace->ax_frame_armed = true;
    return true;
}

static bool deliver_ipc_reply(CPUState* cpu, BootTrace* trace) {
    if (
        !trace->ipc_reply_pending ||
        trace->ax_frame_dispatch_active ||
        trace->ipc_dispatch_active ||
        trace->vi_dispatch_active ||
        trace->vi_reschedule_active ||
        trace->pe_dispatch_active ||
        trace->pe_reschedule_active ||
        (cpu->msr & PPC_MSR_EE) == 0u ||
        cpu->pc != WII_OS_IDLE_WAIT
    ) {
        return false;
    }
    u32 context = mem_read32(cpu, WII_OS_CURRENT_CONTEXT);
    u32 handler =
        mem_read32(
            cpu,
            WII_OS_INTERRUPT_TABLE + IPC_INTERRUPT * 4u
        );
    if (
        cpu->stop_reason != PROTECTOR_STOP_NONE ||
        context == 0u ||
        handler < GC_RAM_BASE
    ) {
        (void)snprintf(
            trace->platform_error,
            sizeof(trace->platform_error),
            "IPC reply missing context or handler"
        );
        protector_stop(
            cpu,
            PROTECTOR_STOP_PLATFORM_ERROR,
            cpu->pc,
            0,
            handler
        );
        return false;
    }

    save_execution_state(&trace->ipc_interrupted_state, cpu);
    trace->ipc_reply_pending = false;
    trace->ipc_dispatch_active = true;
    trace->ipc_reply_count++;
    trace->ipc_handler_address = handler;
    cpu->msr &= ~PPC_MSR_EE;
    cpu->gpr[3] = IPC_INTERRUPT;
    cpu->gpr[4] = context;
    cpu->lr = WII_OS_LOAD_CONTEXT;
    cpu->pc = handler;
    return true;
}

static bool deliver_dvd_async_callback(
    CPUState* cpu, BootTrace* trace
) {
    discard_cancelled_dvd_async_callbacks(cpu, trace);
    if (
        trace->dvd_async_callback_queue_count == 0u ||
        trace->dvd_async_callback_dispatch_active ||
        trace->ax_frame_dispatch_active ||
        trace->ipc_dispatch_active ||
        trace->vi_dispatch_active ||
        trace->vi_reschedule_active ||
        trace->pe_dispatch_active ||
        trace->pe_reschedule_active
    ) {
        return false;
    }
    /*
     * Source completion checkpoints advance once per published synchronized
     * sample.  A source sample can contain multiple GX presentations, so the
     * raw native presentation counter is a different clock domain while
     * cadence replay is active.  Keep every queued DVD event on the canonical
     * source checkpoint clock so hidden presentations cannot deliver media
     * early or accumulate drift across chained reads.
     */
    const u64 frame_clock = current_dvd_frame_clock(trace);
    u32 selected_offset = UINT32_MAX;
    u64 selected_frame = UINT64_MAX;
    u64 selected_order = UINT64_MAX;
    for (
        u32 offset = 0u;
        offset < trace->dvd_async_callback_queue_count;
        ++offset
    ) {
        const u32 index =
            (trace->dvd_async_callback_queue_head + offset) %
            DVD_ASYNC_CALLBACK_QUEUE_SIZE;
        const DvdAsyncCallbackEvent* candidate =
            &trace->dvd_async_callback_queue[index];
        if (
            candidate->ready_frame <= frame_clock &&
            (
                candidate->ready_frame < selected_frame ||
                (
                    candidate->ready_frame == selected_frame &&
                    candidate->ready_order < selected_order
                )
            )
        ) {
            selected_offset = offset;
            selected_frame = candidate->ready_frame;
            selected_order = candidate->ready_order;
        }
    }
    if (selected_offset == UINT32_MAX) {
        return false;
    }
    const u32 selected_index =
        (trace->dvd_async_callback_queue_head + selected_offset) %
        DVD_ASYNC_CALLBACK_QUEUE_SIZE;
    DvdAsyncCallbackEvent event =
        trace->dvd_async_callback_queue[selected_index];
    bind_content_trace_clock(cpu, trace);
    if (event.file_read.relative_path[0]) {
        if (!start_dvd_async_transfer(cpu, trace, &event)) {
            return false;
        }
        mem_write32(cpu, event.file_info + 28u, event.result);
        mem_write32(
            cpu,
            event.file_info + 40u,
            WII_SDK_DVD_COMMAND_BLOCK_CALLBACK
        );
        if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
            (void)snprintf(
                trace->platform_error,
                sizeof(trace->platform_error),
                "DVD async completion command block is unmapped"
            );
            return false;
        }
    }
    /* DVD_STATE_END is zero for both completed reads and seeks. */
    mem_write32(cpu, event.file_info + 12u, 0u);
    if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
        (void)snprintf(
            trace->platform_error,
            sizeof(trace->platform_error),
            "DVD async completion state is unmapped"
        );
        return false;
    }
    if (
        event.file_read.relative_path[0] &&
        !protector_trace_wii_file_completion(
            cpu,
            &event.file_read,
            event.request_serial,
            trace->file_read_completion_count,
            fnv1a_guest_bytes(
                cpu,
                event.destination,
                event.file_read.requested_length
            )
        )
    ) {
        (void)snprintf(
            trace->platform_error,
            sizeof(trace->platform_error),
            "cannot append file-read completion trace"
        );
        protector_stop(
            cpu,
            PROTECTOR_STOP_PLATFORM_ERROR,
            cpu->pc,
            0,
            event.destination
        );
        return false;
    }
    trace_dvd_async_state(cpu, trace, "completion", &event);
    trace->dvd_async_active_event = event;
    save_execution_state(
        &trace->dvd_async_interrupted_state, cpu
    );
    remove_dvd_async_callback(trace, selected_offset);
    trace->dvd_async_callback_dispatch_active = true;
    trace->dvd_async_callback_count++;
    trace->dvd_async_last_completion_frame = frame_clock;
    if (event.file_read.relative_path[0]) {
        trace->file_read_completion_count++;
        trace->last_completed_file_read = event.file_read;
    }
    if (event.sync_trace_anchor_completion) {
        trace->sync_trace_content_ready = true;
    }
    reset_sync_trace_gameplay_settle(trace);
    cpu->gpr[3] = event.result;
    cpu->gpr[4] = event.file_info;
    cpu->lr = WII_OS_LOAD_CONTEXT;
    cpu->pc = event.callback;
    return true;
}

static bool deliver_vi_retrace(CPUState* cpu, BootTrace* trace) {
    if (
        !trace->vi_retrace_armed ||
        trace->ax_frame_dispatch_active ||
        trace->vi_dispatch_active ||
        trace->ipc_dispatch_active ||
        trace->pe_dispatch_active ||
        trace->pe_reschedule_active ||
        trace->vi_reschedule_active ||
        (cpu->msr & PPC_MSR_EE) == 0u ||
        cpu->timebase < trace->next_vi_retrace_timebase
    ) {
        return false;
    }
    u32 context = mem_read32(cpu, WII_OS_CURRENT_CONTEXT);
    if (
        cpu->stop_reason != PROTECTOR_STOP_NONE ||
        context == 0u
    ) {
        (void)snprintf(
            trace->platform_error,
            sizeof(trace->platform_error),
            "VI retrace fired without a current OS context"
        );
        protector_stop(
            cpu,
            PROTECTOR_STOP_PLATFORM_ERROR,
            cpu->pc,
            0,
            context
        );
        return false;
    }

    /*
     * VIInit installs __VIRetraceHandler at interrupt 24. Assert the first
     * VI interrupt status bit and run that translated handler so its real
     * pre/post callbacks and retrace queue wake execute. The handler normally
     * returns through the SDK external-interrupt frame; OSLoadContext is a
     * generated host boundary, so use it as the deterministic return seam and
     * restore the interrupted execution state there.
     */
    save_execution_state(&trace->vi_interrupted_state, cpu);
    trace->vi_interrupt_registers[0] |= 0x8000u;
    trace->vi_dispatch_active = true;
    trace->retrace_count++;
    trace->next_vi_retrace_timebase += WII_TIMEBASE_HZ / 60u;
    cpu->msr &= ~PPC_MSR_EE;
    cpu->gpr[3] = 24u;
    cpu->gpr[4] = context;
    cpu->lr = WII_OS_LOAD_CONTEXT;
    cpu->pc = WII_VI_RETRACE_HANDLER;
    return true;
}

static bool deliver_pe_finish(CPUState* cpu, BootTrace* trace) {
    if (
        !trace->pe_finish_pending ||
        trace->ax_frame_dispatch_active ||
        trace->pe_dispatch_active ||
        trace->pe_reschedule_active ||
        trace->ipc_dispatch_active ||
        trace->vi_dispatch_active ||
        trace->vi_reschedule_active ||
        (cpu->msr & PPC_MSR_EE) == 0u ||
        cpu->pc != WII_OS_IDLE_WAIT
    ) {
        return false;
    }
    u32 context = mem_read32(cpu, WII_OS_CURRENT_CONTEXT);
    u32 handler = mem_read32(
        cpu,
        WII_OS_INTERRUPT_TABLE + GX_PE_FINISH_INTERRUPT * 4u
    );
    if (
        cpu->stop_reason != PROTECTOR_STOP_NONE ||
        context == 0u ||
        handler < GC_RAM_BASE
    ) {
        (void)snprintf(
            trace->platform_error,
            sizeof(trace->platform_error),
            "PE finish missing current context or handler"
        );
        protector_stop(
            cpu,
            PROTECTOR_STOP_PLATFORM_ERROR,
            cpu->pc,
            0,
            handler
        );
        return false;
    }

    /*
     * GXSetDrawDone queued the command; now run the game's installed
     * GXFinishInterruptHandler. The handler clears PE status, sets DrawDone,
     * invokes any registered callback, and wakes the actual FinishQueue.
     */
    save_execution_state(&trace->pe_interrupted_state, cpu);
    trace->pe_scheduler_count_before =
        mem_read32(cpu, cpu->gpr[13] - 17272u);
    trace->pe_finish_pending = false;
    trace->pe_dispatch_active = true;
    trace->pe_finish_count++;
    trace->pe_finish_handler_address = handler;
    cpu->msr &= ~PPC_MSR_EE;
    cpu->gpr[3] = GX_PE_FINISH_INTERRUPT;
    cpu->gpr[4] = context;
    cpu->lr = WII_OS_LOAD_CONTEXT;
    cpu->pc = handler;
    return true;
}

static bool deliver_decrementer(CPUState* cpu, BootTrace* trace) {
    if (
        trace->ax_frame_dispatch_active ||
        trace->ipc_dispatch_active ||
        trace->vi_dispatch_active ||
        trace->vi_reschedule_active ||
        trace->pe_dispatch_active ||
        trace->pe_reschedule_active ||
        (cpu->msr & PPC_MSR_EE) == 0u ||
        !ppc_decrementer_pending(cpu)
    ) {
        return false;
    }
    u32 context = mem_read32(cpu, WII_OS_CURRENT_CONTEXT);
    if (
        cpu->stop_reason != PROTECTOR_STOP_NONE ||
        context == 0u
    ) {
        (void)snprintf(
            trace->platform_error,
            sizeof(trace->platform_error),
            "decrementer fired without a current OS context"
        );
        protector_stop(
            cpu,
            PROTECTOR_STOP_PLATFORM_ERROR,
            cpu->pc,
            0,
            context
        );
        return false;
    }

    for (u32 index = 0u; index < 32u; ++index) {
        mem_write32(cpu, context + index * 4u, cpu->gpr[index]);
    }
    mem_write32(cpu, context + 128u, cpu->cr);
    mem_write32(cpu, context + 132u, cpu->lr);
    mem_write32(cpu, context + 136u, cpu->ctr);
    mem_write32(cpu, context + 140u, cpu->xer);
    mem_write32(cpu, context + 408u, cpu->pc);
    mem_write32(cpu, context + 412u, cpu->msr);
    /*
     * This harness enters the SDK exception handler after materializing the
     * complete OSContext itself. Set OS_CONTEXT_STATE_EXC so OSLoadContext
     * restores volatile GPRs 5-12 as well as the nonvolatile registers, then
     * clears the flag as part of returning from the synthetic exception.
     */
    mem_write16(
        cpu,
        context + 418u,
        (u16)(mem_read16(cpu, context + 418u) | 2u)
    );
    if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
        return false;
    }

    ppc_decrementer_delivered(cpu);
    cpu->srr0 = cpu->pc;
    cpu->srr1 = cpu->msr;
    cpu->msr &= ~PPC_MSR_EE;
    cpu->gpr[3] = 8u;
    cpu->gpr[4] = context;
    cpu->pc = WII_OS_DECREMENTER_HANDLER;
    return true;
}

#if defined(PROTECTOR_IOS_PERF)
int protector_translated_boot_main(int argc, char** argv) {
#elif defined(PROTECTOR_IOS_LIVE_METAL)
int protector_translated_ios_live_metal_main(int argc, char** argv) {
#elif defined(PROTECTOR_LIVE_METAL)
int protector_translated_live_metal_main(int argc, char** argv) {
#else
int main(int argc, char** argv) {
#endif
    protector_save_status_reset(false);
    bool stop_after_first_content = false;
    const bool full_state_mode =
        argc >= 2 && strcmp(argv[1], "--full-state") == 0;
    if (
        (argc != 5 && argc != 6) ||
        (strcmp(argv[1], "--dol") != 0 && !full_state_mode) ||
        strcmp(argv[3], "--data-root") != 0 ||
        (argc == 6 &&
         strcmp(argv[5], "--stop-after-first-content") != 0)
    ) {
        fprintf(
            stderr,
            "usage: %s (--dol PATH | --full-state PATH) --data-root PATH "
            "[--stop-after-first-content]\n",
            argv[0]
        );
        return 2;
    }
    stop_after_first_content = argc == 6;
    if (protector_live_input_enabled()) {
        const char* incompatible[] = {
            "PROTECTOR_KPAD_SEQUENCE", "PROTECTOR_KPAD_PULSES",
            "PROTECTOR_KPAD_PULSE_MASK", "PROTECTOR_KPAD_PULSE_START",
            "PROTECTOR_KPAD_PULSE_INTERVAL", "PROTECTOR_SYNC_TRACE_PATH",
            "PROTECTOR_SYNC_CHECKPOINT_MEMORY_REPLAY",
            "PROTECTOR_SYNC_RNG_STATES", "PROTECTOR_SYNC_TITLE_VM_REGISTER_0",
            "PROTECTOR_SYNC_STRATEGY_VM_REGISTERS",
            "PROTECTOR_SYNC_FRAME_DELTAS", "PROTECTOR_SYNC_PRESENTATION_REPEATS",
            "PROTECTOR_SYNC_DVD_COMPLETIONS", "PROTECTOR_SYNC_INPUT_SAMPLE_OFFSET",
        };
        for (size_t index = 0; index < sizeof(incompatible) / sizeof(*incompatible);
             ++index) {
            if (getenv(incompatible[index])) {
                fprintf(stderr, "live input rejects replay option %s\n",
                        incompatible[index]);
                return 2;
            }
        }
        const char* live_template = getenv("PROTECTOR_KPAD_TEMPLATE_HEX");
        if (full_state_mode || stop_after_first_content ||
            !live_template || !live_template[0]) {
            fprintf(stderr, "live input requires cold boot and a KPAD template\n");
            return 2;
        }
    }
    if (getenv("PROTECTOR_SAVE_ROOT") && !protector_live_input_enabled()) {
        fprintf(stderr, "persistent saves are restricted to live cold-boot sessions\n");
        return 2;
    }
    if (
        full_state_mode &&
        (
            stop_after_first_content ||
            getenv("PROTECTOR_SYNC_CHECKPOINT_MEMORY_REPLAY") ||
            getenv("PROTECTOR_SYNC_RNG_STATES") ||
            getenv("PROTECTOR_SYNC_TITLE_VM_REGISTER_0") ||
            getenv("PROTECTOR_SYNC_STRATEGY_VM_REGISTERS") ||
            getenv("PROTECTOR_KPAD_PULSES") ||
            getenv("PROTECTOR_KPAD_PULSE_MASK") ||
            getenv("PROTECTOR_KPAD_PULSE_START") ||
            getenv("PROTECTOR_KPAD_PULSE_INTERVAL")
        )
    ) {
        fprintf(
            stderr,
            "full-state mode rejects cold-boot and partial-state overlays\n"
        );
        return 2;
    }

    CPUState cpu;
    if (!protector_cpu_init(&cpu)) {
        fprintf(stderr, "failed to allocate guest memory\n");
        return 3;
    }
    ProtectorDolInfo dol = {0};
    ProtectorFullStateMetadata full_state = {0};
    char error[256] = {0};
    if (!full_state_mode) {
        if (!protector_load_dol(
                &cpu, argv[2], &dol, error, sizeof(error)
            )) {
            fprintf(stderr, "%s\n", error);
            protector_cpu_destroy(&cpu);
            return 4;
        }
        if (dol.entry_point != RBNEG9_ENTRY) {
            fprintf(stderr, "unexpected entry 0x%08X\n", dol.entry_point);
            protector_cpu_destroy(&cpu);
            return 5;
        }
        protector_prepare_wii_boot(&cpu);
        if (cpu.stop_reason != PROTECTOR_STOP_NONE) {
            fprintf(stderr, "failed to establish Wii boot state\n");
            protector_cpu_destroy(&cpu);
            return 6;
        }
    }
    ProtectorDataMount mount;
    if (!protector_mount_wii_data(
            &cpu,
            argv[4],
            &mount,
            error,
            sizeof(error)
        )) {
        fprintf(stderr, "%s\n", error);
        protector_cpu_destroy(&cpu);
        return 7;
    }
    if (
        full_state_mode &&
        !protector_load_full_state(
            &cpu,
            argv[2],
            &full_state,
            error,
            sizeof(error)
        )
    ) {
        fprintf(stderr, "%s\n", error);
        protector_cpu_destroy(&cpu);
        return 7;
    }

    BootTrace trace = {0};
    trace.mount = &mount;
    trace.ax_frame_interval_timebase = WII_AX_FRAME_TIMEBASE_TICKS;
    const char* frustum_frame_text = getenv("PROTECTOR_FRUSTUM_AUDIT_FRAME");
    if (frustum_frame_text && frustum_frame_text[0]) {
        char* end = NULL;
        const unsigned long parsed = strtoul(frustum_frame_text, &end, 10);
        if (end == frustum_frame_text || *end != '\0' ||
            parsed == 0u || parsed > 100000u) {
            fprintf(stderr, "invalid PROTECTOR_FRUSTUM_AUDIT_FRAME\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        trace.frustum_audit_frame = (u32)parsed;
    }
    const char* ax_frame_interval_text = getenv(
        "PROTECTOR_AX_FRAME_INTERVAL_TICKS"
    );
    if (ax_frame_interval_text && ax_frame_interval_text[0]) {
        char* end = NULL;
        const unsigned long long parsed = strtoull(
            ax_frame_interval_text, &end, 10
        );
        if (
            end == ax_frame_interval_text || *end != '\0' ||
            parsed == 0u
        ) {
            fprintf(stderr, "invalid AX frame interval\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        trace.ax_frame_interval_timebase = (u64)parsed;
    }
    trace.stop_after_first_content = stop_after_first_content;
    trace.imported_checkpoint = full_state_mode;
    if (full_state_mode) {
        trace.gx_completed_frame_count = full_state.checkpoint;
        trace.sync_trace_content_ready = true;
        cpu.presented_frame_count = full_state.checkpoint;
        /*
         * The serialized guest is already past VIInit and is waiting for the
         * next retrace to wake its gameplay thread.  The Dolphin CoreTiming
         * event queue is host state, not MEM1/MEM2, so re-arm its semantic
         * equivalent at the next hardware tick when importing the seam.
         */
        trace.vi_retrace_armed = true;
        trace.next_vi_retrace_timebase =
            cpu.timebase + WII_TIMEBASE_HZ / 60u;
    }
    trace.wud_status_result = 3;
    trace.controller_connected = true;
    trace.gx_current_frame_hash = FNV1A64_OFFSET;
    trace.sync_trace_checkpoint_pc = GX_END_FRAME_WRITE;
    const char* gx_capture_path = getenv("PROTECTOR_GX_CAPTURE_PATH");
    if (gx_capture_path && gx_capture_path[0]) {
        trace.gx_capture_file = fopen(gx_capture_path, "wb");
        if (!trace.gx_capture_file) {
            fprintf(stderr, "failed to open GX capture path\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
    }
    const char* gx_memory_capture_path =
        getenv("PROTECTOR_GX_MEMORY_CAPTURE_PATH");
    const char* gx_memory_capture_frame =
        getenv("PROTECTOR_GX_MEMORY_CAPTURE_FRAME");
    if (
        (gx_memory_capture_path && gx_memory_capture_path[0]) !=
        (gx_memory_capture_frame && gx_memory_capture_frame[0])
    ) {
        fprintf(
            stderr,
            "GX memory capture path and frame must be provided together\n"
        );
        if (trace.gx_capture_file) {
            fclose(trace.gx_capture_file);
        }
        protector_cpu_destroy(&cpu);
        return 8;
    }
    if (gx_memory_capture_path && gx_memory_capture_path[0]) {
        char* end = NULL;
        unsigned long long parsed =
            strtoull(gx_memory_capture_frame, &end, 10);
        if (
            end == gx_memory_capture_frame ||
            *end != '\0' ||
            parsed > UINT32_MAX
        ) {
            fprintf(stderr, "invalid GX memory capture frame\n");
            if (trace.gx_capture_file) {
                fclose(trace.gx_capture_file);
            }
            protector_cpu_destroy(&cpu);
            return 8;
        }
        trace.gx_memory_capture_path = gx_memory_capture_path;
        trace.gx_memory_capture_frame = (u64)parsed;
    }
    const char* sync_memory_capture_path =
        getenv("PROTECTOR_SYNC_MEMORY_CAPTURE_PATH");
    const char* sync_memory_capture_frame =
        getenv("PROTECTOR_SYNC_MEMORY_CAPTURE_FRAME");
    if (
        (sync_memory_capture_path && sync_memory_capture_path[0]) !=
        (sync_memory_capture_frame && sync_memory_capture_frame[0])
    ) {
        fprintf(
            stderr,
            "sync memory capture path and frame must be provided together\n"
        );
        if (trace.gx_capture_file) {
            fclose(trace.gx_capture_file);
        }
        protector_cpu_destroy(&cpu);
        return 8;
    }
    if (sync_memory_capture_path && sync_memory_capture_path[0]) {
        char* end = NULL;
        unsigned long parsed =
            strtoul(sync_memory_capture_frame, &end, 10);
        if (
            end == sync_memory_capture_frame ||
            *end != '\0' ||
            parsed > UINT32_MAX
        ) {
            fprintf(stderr, "invalid sync memory capture frame\n");
            if (trace.gx_capture_file) {
                fclose(trace.gx_capture_file);
            }
            protector_cpu_destroy(&cpu);
            return 8;
        }
        trace.sync_memory_capture_path = sync_memory_capture_path;
        trace.sync_memory_capture_frame = (u32)parsed;
    }
    const char* vi_interrupt_registers_text =
        getenv("PROTECTOR_VI_INTERRUPT_REGISTERS");
    if (
        full_state_mode !=
            (vi_interrupt_registers_text &&
             vi_interrupt_registers_text[0])
    ) {
        fprintf(
            stderr,
            "full-state VI interrupt registers must be provided exactly once\n"
        );
        protector_cpu_destroy(&cpu);
        return 8;
    }
    if (full_state_mode) {
        const char* cursor = vi_interrupt_registers_text;
        for (u32 index = 0u; index < 4u; ++index) {
            char* end = NULL;
            const unsigned long parsed = strtoul(cursor, &end, 0);
            const char expected_separator = index == 3u ? '\0' : ',';
            if (
                end == cursor || parsed > UINT16_MAX ||
                *end != expected_separator
            ) {
                fprintf(
                    stderr,
                    "invalid PROTECTOR_VI_INTERRUPT_REGISTERS\n"
                );
                protector_cpu_destroy(&cpu);
                return 8;
            }
            trace.vi_interrupt_registers[index] = (u16)parsed;
            cursor = end + (index == 3u ? 0u : 1u);
        }
    }
    const char* pe_interrupt_control_text =
        getenv("PROTECTOR_PE_INTERRUPT_CONTROL");
    const char* pe_finish_pending_text =
        getenv("PROTECTOR_PE_FINISH_PENDING");
    if (
        full_state_mode !=
            (pe_interrupt_control_text && pe_interrupt_control_text[0]) ||
        full_state_mode !=
            (pe_finish_pending_text && pe_finish_pending_text[0])
    ) {
        fprintf(
            stderr,
            "full-state PE interrupt state must be provided exactly once\n"
        );
        protector_cpu_destroy(&cpu);
        return 8;
    }
    if (full_state_mode) {
        char* end = NULL;
        const unsigned long parsed =
            strtoul(pe_interrupt_control_text, &end, 0);
        if (
            end == pe_interrupt_control_text || *end != '\0' ||
            parsed > UINT16_MAX ||
            (
                strcmp(pe_finish_pending_text, "0") != 0 &&
                strcmp(pe_finish_pending_text, "1") != 0
            )
        ) {
            fprintf(stderr, "invalid full-state PE interrupt state\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        trace.pe_interrupt_control = (u16)parsed;
        trace.pe_finish_pending =
            strcmp(pe_finish_pending_text, "1") == 0;
    }
    const char* wud_status_text = getenv("PROTECTOR_WUD_STATUS");
    if (wud_status_text && wud_status_text[0]) {
        char* end = NULL;
        long parsed = strtol(wud_status_text, &end, 10);
        if (
            end == wud_status_text ||
            *end != '\0' ||
            parsed < -128 ||
            parsed > 127
        ) {
            fprintf(stderr, "invalid PROTECTOR_WUD_STATUS\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        trace.wud_status_result = (s32)parsed;
    }
    const char* controller_connected_text =
        getenv("PROTECTOR_CONTROLLER_CONNECTED");
    if (
        controller_connected_text &&
        controller_connected_text[0]
    ) {
        if (
            strcmp(controller_connected_text, "0") == 0
        ) {
            trace.controller_connected = false;
        } else if (
            strcmp(controller_connected_text, "1") != 0
        ) {
            fprintf(
                stderr,
                "invalid PROTECTOR_CONTROLLER_CONNECTED\n"
            );
            protector_cpu_destroy(&cpu);
            return 8;
        }
    }
    const char* kpad_template_text =
        getenv("PROTECTOR_KPAD_TEMPLATE_HEX");
    if (kpad_template_text && kpad_template_text[0]) {
        if (strlen(kpad_template_text) != KPAD_STATUS_SIZE * 2u) {
            fprintf(stderr, "invalid PROTECTOR_KPAD_TEMPLATE_HEX length\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        for (u32 index = 0u; index < KPAD_STATUS_SIZE; ++index) {
            int high = hexadecimal_nibble(kpad_template_text[index * 2u]);
            int low = hexadecimal_nibble(kpad_template_text[index * 2u + 1u]);
            if (high < 0 || low < 0) {
                fprintf(stderr, "invalid PROTECTOR_KPAD_TEMPLATE_HEX byte\n");
                protector_cpu_destroy(&cpu);
                return 8;
            }
            trace.kpad_status_template[index] =
                (u8)((u32)high << 4u | (u32)low);
        }
        trace.kpad_status_template_valid = true;
    }
    if (protector_live_input_enabled() &&
        (!trace.kpad_status_template_valid ||
         trace.kpad_status_template[0x5Cu] != 1u ||
         trace.kpad_status_template[0x5Du] != 0u)) {
        fprintf(stderr, "live input requires connected Nunchuk bytes, not only JSON labels\n");
        protector_cpu_destroy(&cpu);
        return 8;
    }
    const char* kpad_pulse_mask_text =
        getenv("PROTECTOR_KPAD_PULSE_MASK");
    const char* kpad_pulse_start_text =
        getenv("PROTECTOR_KPAD_PULSE_START");
    const char* kpad_pulse_interval_text =
        getenv("PROTECTOR_KPAD_PULSE_INTERVAL");
    const char* kpad_scheduled_pulses_text =
        getenv("PROTECTOR_KPAD_PULSES");
    const bool has_legacy_kpad_pulse =
        (kpad_pulse_mask_text && kpad_pulse_mask_text[0]) ||
        (kpad_pulse_start_text && kpad_pulse_start_text[0]) ||
        (kpad_pulse_interval_text && kpad_pulse_interval_text[0]);
    if (
        has_legacy_kpad_pulse
    ) {
        if (
            !trace.kpad_status_template_valid ||
            !kpad_pulse_mask_text ||
            !kpad_pulse_mask_text[0] ||
            !kpad_pulse_start_text ||
            !kpad_pulse_start_text[0] ||
            !kpad_pulse_interval_text ||
            !kpad_pulse_interval_text[0]
        ) {
            fprintf(stderr, "incomplete KPAD pulse configuration\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        char* pulse_end = NULL;
        unsigned long mask =
            strtoul(kpad_pulse_mask_text, &pulse_end, 0);
        if (
            pulse_end == kpad_pulse_mask_text ||
            *pulse_end != '\0' ||
            mask == 0u ||
            mask > UINT32_MAX
        ) {
            fprintf(stderr, "invalid PROTECTOR_KPAD_PULSE_MASK\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        pulse_end = NULL;
        unsigned long long start =
            strtoull(kpad_pulse_start_text, &pulse_end, 10);
        if (
            pulse_end == kpad_pulse_start_text ||
            *pulse_end != '\0' ||
            start == 0u
        ) {
            fprintf(stderr, "invalid PROTECTOR_KPAD_PULSE_START\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        pulse_end = NULL;
        unsigned long long interval =
            strtoull(kpad_pulse_interval_text, &pulse_end, 10);
        if (
            pulse_end == kpad_pulse_interval_text ||
            *pulse_end != '\0' ||
            interval < 3u
        ) {
            fprintf(stderr, "invalid PROTECTOR_KPAD_PULSE_INTERVAL\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        trace.kpad_pulse_mask = (u32)mask;
        trace.kpad_pulse_start = (u64)start;
        trace.kpad_pulse_interval = (u64)interval;
    }
    if (
        kpad_scheduled_pulses_text &&
        kpad_scheduled_pulses_text[0]
    ) {
        if (
            !trace.kpad_status_template_valid ||
            has_legacy_kpad_pulse
        ) {
            fprintf(
                stderr,
                "scheduled KPAD pulses require a template and "
                "cannot be mixed with legacy pulses\n"
            );
            protector_cpu_destroy(&cpu);
            return 8;
        }
        const char* cursor = kpad_scheduled_pulses_text;
        while (*cursor) {
            if (
                trace.kpad_scheduled_pulse_count >=
                KPAD_SCHEDULED_PULSE_CAPACITY
            ) {
                fprintf(stderr, "too many scheduled KPAD pulses\n");
                protector_cpu_destroy(&cpu);
                return 8;
            }
            char* end = NULL;
            const unsigned long long checkpoint =
                strtoull(cursor, &end, 10);
            if (
                end == cursor ||
                *end != ':' ||
                checkpoint == 0u ||
                checkpoint == UINT64_MAX
            ) {
                fprintf(
                    stderr,
                    "invalid scheduled KPAD pulse checkpoint\n"
                );
                protector_cpu_destroy(&cpu);
                return 8;
            }
            cursor = end + 1;
            const unsigned long mask =
                strtoul(cursor, &end, 0);
            if (
                end == cursor ||
                (*end != ',' && *end != '\0') ||
                mask == 0u ||
                mask > UINT32_MAX
            ) {
                fprintf(stderr, "invalid scheduled KPAD pulse mask\n");
                protector_cpu_destroy(&cpu);
                return 8;
            }
            if (
                trace.kpad_scheduled_pulse_count > 0u &&
                checkpoint <=
                    trace.kpad_scheduled_pulses[
                        trace.kpad_scheduled_pulse_count - 1u
                    ].checkpoint +
                        1u
            ) {
                fprintf(
                    stderr,
                    "scheduled KPAD pulses must be ordered "
                    "with a release checkpoint between them\n"
                );
                protector_cpu_destroy(&cpu);
                return 8;
            }
            ScheduledKpadPulse* pulse =
                &trace.kpad_scheduled_pulses[
                    trace.kpad_scheduled_pulse_count++
                ];
            pulse->checkpoint = (u64)checkpoint;
            pulse->mask = (u32)mask;
            cursor = *end == ',' ? end + 1 : end;
            if (*end == ',' && *cursor == '\0') {
                fprintf(stderr, "scheduled KPAD pulse list is incomplete\n");
                protector_cpu_destroy(&cpu);
                return 8;
            }
        }
    }
    const char* sync_trace_path =
        getenv("PROTECTOR_SYNC_TRACE_PATH");
    const char* sync_trace_frames =
        getenv("PROTECTOR_SYNC_TRACE_FRAMES");
    const char* sync_input_sequence =
        getenv("PROTECTOR_KPAD_SEQUENCE");
    const char* sync_trace_anchor_path =
        getenv("PROTECTOR_SYNC_TRACE_ANCHOR_PATH");
    const char* sync_trace_start_gx_frame =
        getenv("PROTECTOR_SYNC_TRACE_START_GX_FRAME");
    const char* sync_trace_checkpoint_pc =
        getenv("PROTECTOR_SYNC_TRACE_CHECKPOINT_PC");
    const char* sync_frame_deltas =
        getenv("PROTECTOR_SYNC_FRAME_DELTAS");
    const char* sync_presentation_repeats =
        getenv("PROTECTOR_SYNC_PRESENTATION_REPEATS");
    const char* sync_frame_delta_start_gx_frame =
        getenv("PROTECTOR_SYNC_FRAME_DELTA_START_GX_FRAME");
    const char* sync_input_sample_offset =
        getenv("PROTECTOR_SYNC_INPUT_SAMPLE_OFFSET");
    const char* sync_rng_states =
        getenv("PROTECTOR_SYNC_RNG_STATES");
    const char* sync_title_vm_register_0 =
        getenv("PROTECTOR_SYNC_TITLE_VM_REGISTER_0");
    const char* sync_strategy_vm_registers =
        getenv("PROTECTOR_SYNC_STRATEGY_VM_REGISTERS");
    const char* sync_checkpoint_memory_replay =
        getenv("PROTECTOR_SYNC_CHECKPOINT_MEMORY_REPLAY");
    const char* sync_dvd_completions =
        getenv("PROTECTOR_SYNC_DVD_COMPLETIONS");
    if (
        (sync_trace_path && sync_trace_path[0]) ||
        (sync_trace_frames && sync_trace_frames[0]) ||
        (sync_input_sequence && sync_input_sequence[0])
    ) {
        if (
            !sync_trace_path ||
            !sync_trace_path[0] ||
            !sync_trace_frames ||
            !sync_trace_frames[0] ||
            !sync_input_sequence ||
            !sync_input_sequence[0]
        ) {
            fprintf(stderr, "incomplete synchronized-trace configuration\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        if (
            sync_trace_checkpoint_pc &&
            sync_trace_checkpoint_pc[0]
        ) {
            char* checkpoint_end = NULL;
            const unsigned long checkpoint = strtoul(
                sync_trace_checkpoint_pc, &checkpoint_end, 0
            );
            if (
                checkpoint_end == sync_trace_checkpoint_pc ||
                *checkpoint_end != '\0' ||
                checkpoint > UINT32_MAX ||
                (
                    checkpoint != GX_END_FRAME_WRITE &&
                    checkpoint != GAME_LOGICAL_UPDATE_POST_STORE &&
                    checkpoint != GAME_LOGICAL_UPDATE_ENTRY &&
                    checkpoint != GAME_LOGICAL_UPDATE_CHECKPOINT
                )
            ) {
                fprintf(
                    stderr,
                    "invalid PROTECTOR_SYNC_TRACE_CHECKPOINT_PC\n"
                );
                protector_cpu_destroy(&cpu);
                return 8;
            }
            trace.sync_trace_checkpoint_pc = (u32)checkpoint;
        }
        if (
            sync_checkpoint_memory_replay &&
            sync_checkpoint_memory_replay[0]
        ) {
            trace.sync_checkpoint_memory_replay_path =
                sync_checkpoint_memory_replay;
        }
        char* frame_end = NULL;
        unsigned long frame_count =
            strtoul(sync_trace_frames, &frame_end, 10);
        if (
            frame_end == sync_trace_frames ||
            *frame_end != '\0' ||
            frame_count == 0u ||
            frame_count > SYNC_INPUT_SAMPLE_CAPACITY
        ) {
            fprintf(stderr, "invalid PROTECTOR_SYNC_TRACE_FRAMES\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        const char* cursor = sync_input_sequence;
        while (*cursor) {
            if (
                trace.sync_input_sample_count >=
                SYNC_INPUT_SAMPLE_CAPACITY
            ) {
                fprintf(stderr, "too many KPAD replay samples\n");
                protector_cpu_destroy(&cpu);
                return 8;
            }
            SyncInputSample* sample =
                &trace.sync_input_samples[
                    trace.sync_input_sample_count
                ];
            char* end = NULL;
            unsigned long hold = strtoul(cursor, &end, 16);
            if (end == cursor || *end != ':' || hold > UINT32_MAX) {
                fprintf(stderr, "invalid KPAD replay hold field\n");
                protector_cpu_destroy(&cpu);
                return 8;
            }
            cursor = end + 1;
            unsigned long trigger = strtoul(cursor, &end, 16);
            if (end == cursor || *end != ':' || trigger > UINT32_MAX) {
                fprintf(stderr, "invalid KPAD replay trigger field\n");
                protector_cpu_destroy(&cpu);
                return 8;
            }
            cursor = end + 1;
            unsigned long release = strtoul(cursor, &end, 16);
            if (
                end == cursor ||
                (*end != ':' && *end != ',' && *end != '\0') ||
                release > UINT32_MAX
            ) {
                fprintf(stderr, "invalid KPAD replay release field\n");
                protector_cpu_destroy(&cpu);
                return 8;
            }
            sample->hold = (u32)hold;
            sample->trigger = (u32)trigger;
            sample->release = (u32)release;
            if (
                sample->hold != 0u ||
                sample->trigger != 0u ||
                sample->release != 0u
            ) {
                trace.sync_input_has_non_neutral = true;
            }
            if (*end == ':') {
                unsigned long status_fields[4] = {0u, 0u, 0u, 0u};
                const char* field_names[] = {
                    "device type",
                    "WPAD error",
                    "DPD valid",
                    "data format",
                };
                for (u32 index = 0u; index < 4u; ++index) {
                    cursor = end + 1;
                    status_fields[index] = strtoul(cursor, &end, 16);
                    if (
                        end == cursor ||
                        status_fields[index] > UINT8_MAX ||
                        (
                            index < 3u
                                ? *end != ':'
                                : (
                                      *end != ':' &&
                                      *end != ',' &&
                                      *end != '\0'
                                  )
                        )
                    ) {
                        fprintf(
                            stderr,
                            "invalid KPAD replay %s field\n",
                            field_names[index]
                        );
                        protector_cpu_destroy(&cpu);
                        return 8;
                    }
                }
                sample->device_type = (u8)status_fields[0];
                sample->wpad_error = (u8)status_fields[1];
                sample->dpd_valid = (u8)status_fields[2];
                sample->data_format = (u8)status_fields[3];
                if (*end == ':') {
                    unsigned long stick_fields[2] = {0u, 0u};
                    const char* stick_names[] = {
                        "nunchuk stick X",
                        "nunchuk stick Y",
                    };
                    for (u32 index = 0u; index < 2u; ++index) {
                        cursor = end + 1;
                        stick_fields[index] =
                            strtoul(cursor, &end, 16);
                        if (
                            end == cursor ||
                            stick_fields[index] > UINT32_MAX ||
                            (
                                index == 0u
                                    ? *end != ':'
                                    : (
                                          *end != ':' &&
                                          *end != ',' &&
                                          *end != '\0'
                                      )
                            )
                        ) {
                            fprintf(
                                stderr,
                                "invalid KPAD replay %s field\n",
                                stick_names[index]
                            );
                            protector_cpu_destroy(&cpu);
                            return 8;
                        }
                    }
                    sample->nunchuk_stick_x_bits =
                        (u32)stick_fields[0];
                    sample->nunchuk_stick_y_bits =
                        (u32)stick_fields[1];
                    sample->has_nunchuk_stick = true;
                    trace.sync_input_has_non_neutral =
                        trace.sync_input_has_non_neutral ||
                        sample->nunchuk_stick_x_bits != 0u ||
                        sample->nunchuk_stick_y_bits != 0u;
                    if (*end == ':') {
                        const char* motion_names[10] = {
                            "Wiimote acceleration X",
                            "Wiimote acceleration Y",
                            "Wiimote acceleration Z",
                            "Wiimote acceleration value",
                            "Wiimote acceleration speed",
                            "Nunchuk acceleration X",
                            "Nunchuk acceleration Y",
                            "Nunchuk acceleration Z",
                            "Nunchuk acceleration value",
                            "Nunchuk acceleration speed",
                        };
                        for (u32 index = 0u; index < 10u; ++index) {
                            cursor = end + 1;
                            const unsigned long motion =
                                strtoul(cursor, &end, 16);
                            if (
                                end == cursor ||
                                motion > UINT32_MAX ||
                                (
                                    index < 9u
                                        ? *end != ':'
                                        : (
                                              *end != ',' &&
                                              *end != '\0'
                                          )
                                )
                            ) {
                                fprintf(
                                    stderr,
                                    "invalid KPAD replay %s field\n",
                                    motion_names[index]
                                );
                                protector_cpu_destroy(&cpu);
                                return 8;
                            }
                            sample->motion_bits[index] = (u32)motion;
                        }
                        sample->has_motion = true;
                        trace.sync_input_has_non_neutral = true;
                    }
                }
            }
            trace.sync_input_sample_count++;
            cursor = *end == ',' ? end + 1 : end;
        }
        if (
            trace.sync_input_sample_count <
            (u32)frame_count
        ) {
            fprintf(stderr, "too few KPAD replay samples\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        if (sync_frame_deltas && sync_frame_deltas[0]) {
            const char* delta_cursor = sync_frame_deltas;
            while (*delta_cursor) {
                if (
                    trace.sync_frame_delta_count >=
                    SYNC_INPUT_SAMPLE_CAPACITY
                ) {
                    fprintf(stderr, "too many synchronized frame deltas\n");
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                char* delta_end = NULL;
                const unsigned long delta =
                    strtoul(delta_cursor, &delta_end, 10);
                if (
                    delta_end == delta_cursor ||
                    (*delta_end != ',' && *delta_end != '\0') ||
                    (
                        delta == 0u &&
                        trace.sync_frame_delta_count != 0u
                    ) ||
                    delta > 1000000u
                ) {
                    fprintf(
                        stderr,
                        "invalid PROTECTOR_SYNC_FRAME_DELTAS\n"
                    );
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                trace.sync_frame_deltas[
                    trace.sync_frame_delta_count++
                ] = (u32)delta;
                delta_cursor =
                    *delta_end == ',' ? delta_end + 1 : delta_end;
            }
            if (trace.sync_frame_delta_count < (u32)frame_count) {
                fprintf(
                    stderr,
                    "too few synchronized frame deltas\n"
                );
                protector_cpu_destroy(&cpu);
                return 8;
            }
        }
        if (
            sync_presentation_repeats &&
            sync_presentation_repeats[0]
        ) {
            const char* repeat_cursor = sync_presentation_repeats;
            while (*repeat_cursor) {
                if (
                    trace.sync_presentation_repeat_count >=
                    SYNC_INPUT_SAMPLE_CAPACITY
                ) {
                    fprintf(
                        stderr,
                        "too many synchronized presentation repeats\n"
                    );
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                char* repeat_end = NULL;
                const unsigned long repeat = strtoul(
                    repeat_cursor,
                    &repeat_end,
                    10
                );
                if (
                    repeat_end == repeat_cursor ||
                    (*repeat_end != ',' && *repeat_end != '\0') ||
                    repeat == 0u || repeat > 8u
                ) {
                    fprintf(
                        stderr,
                        "invalid PROTECTOR_SYNC_PRESENTATION_REPEATS\n"
                    );
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                trace.sync_presentation_repeats[
                    trace.sync_presentation_repeat_count++
                ] = (u32)repeat;
                repeat_cursor =
                    *repeat_end == ',' ? repeat_end + 1 : repeat_end;
            }
            if (
                trace.sync_presentation_repeat_count <
                (u32)frame_count
            ) {
                fprintf(
                    stderr,
                    "too few synchronized presentation repeats\n"
                );
                protector_cpu_destroy(&cpu);
                return 8;
            }
        }
        if (sync_rng_states && sync_rng_states[0]) {
            const char* rng_cursor = sync_rng_states;
            for (
                u32 index = 0u;
                index < GAME_RANDOM_REPLAY_STATE_COUNT;
                ++index
            ) {
                char* rng_end = NULL;
                const unsigned long state =
                    strtoul(rng_cursor, &rng_end, 0);
                if (
                    rng_end == rng_cursor ||
                    state > UINT32_MAX ||
                    (
                        index + 1u < GAME_RANDOM_REPLAY_STATE_COUNT
                            ? *rng_end != ','
                            : *rng_end != '\0'
                    )
                ) {
                    fprintf(
                        stderr,
                        "invalid PROTECTOR_SYNC_RNG_STATES\n"
                    );
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                trace.sync_rng_replay_states[index] = (u32)state;
                rng_cursor = rng_end + 1;
            }
            trace.sync_rng_replay_enabled = true;
        }
        if (
            sync_title_vm_register_0 &&
            sync_title_vm_register_0[0]
        ) {
            char* title_vm_end = NULL;
            const unsigned long value = strtoul(
                sync_title_vm_register_0, &title_vm_end, 0
            );
            if (
                title_vm_end == sync_title_vm_register_0 ||
                *title_vm_end != '\0' ||
                value > UINT32_MAX
            ) {
                fprintf(
                    stderr,
                    "invalid PROTECTOR_SYNC_TITLE_VM_REGISTER_0\n"
                );
                protector_cpu_destroy(&cpu);
                return 8;
            }
            trace.sync_title_vm_register_0_replay_value = (u32)value;
            trace.sync_title_vm_register_0_replay_enabled = true;
        }
        if (
            sync_strategy_vm_registers &&
            sync_strategy_vm_registers[0]
        ) {
            const char* cursor = sync_strategy_vm_registers;
            u32 previous_context = 0u;
            while (*cursor) {
                if (
                    trace.sync_strategy_vm_replay_count >=
                    STRATEGY_VM_REPLAY_CAPACITY
                ) {
                    fprintf(stderr, "too many strategy VM replays\n");
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                unsigned long values[4];
                for (u32 field = 0u; field < 4u; ++field) {
                    char* end = NULL;
                    values[field] = strtoul(cursor, &end, 0);
                    const char expected = field == 3u ? '\0' : ':';
                    if (
                        end == cursor ||
                        values[field] > UINT32_MAX ||
                        (
                            field == 3u
                                ? *end != '\0' && *end != ','
                                : *end != expected
                        )
                    ) {
                        fprintf(
                            stderr,
                            "invalid PROTECTOR_SYNC_STRATEGY_VM_REGISTERS\n"
                        );
                        protector_cpu_destroy(&cpu);
                        return 8;
                    }
                    cursor = end + (field == 3u ? 0 : 1);
                }
                StrategyVmReplayEntry* entry =
                    &trace.sync_strategy_vm_replay[
                        trace.sync_strategy_vm_replay_count++
                    ];
                entry->context = (u32)values[0];
                entry->script_base = (u32)values[1];
                entry->instruction_pointer = (u32)values[2];
                entry->register_0 = (u32)values[3];
                if (
                    entry->context <= previous_context ||
                    entry->context < GC_RAM_BASE ||
                    entry->script_base < WII_MEM2_BASE ||
                    entry->instruction_pointer < WII_MEM2_BASE
                ) {
                    fprintf(
                        stderr,
                        "invalid strategy VM replay ordering or address\n"
                    );
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                previous_context = entry->context;
                if (*cursor == ',') {
                    cursor++;
                } else if (*cursor != '\0') {
                    fprintf(
                        stderr,
                        "invalid strategy VM replay separator\n"
                    );
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
            }
        }
        if (sync_dvd_completions && sync_dvd_completions[0]) {
            const char* completion_cursor = sync_dvd_completions;
            u64 last_serial = 0u;
            u64 last_checkpoint = 0u;
            bool have_previous = false;
            while (*completion_cursor) {
                if (
                    trace.dvd_completion_replay_count >=
                    DVD_COMPLETION_REPLAY_CAPACITY
                ) {
                    fprintf(stderr, "too many DVD completion replays\n");
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                char* serial_end = NULL;
                const unsigned long long serial = strtoull(
                    completion_cursor, &serial_end, 10
                );
                if (serial_end == completion_cursor || *serial_end != ':') {
                    fprintf(stderr, "invalid PROTECTOR_SYNC_DVD_COMPLETIONS\n");
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                char* requested_checkpoint_end = NULL;
                unsigned long long requested_checkpoint = strtoull(
                    serial_end + 1, &requested_checkpoint_end, 10
                );
                if (*requested_checkpoint_end != ':') {
                    fprintf(stderr, "invalid PROTECTOR_SYNC_DVD_COMPLETIONS\n");
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                char* completion_end = NULL;
                unsigned long long completion = strtoull(
                    requested_checkpoint_end + 1, &completion_end, 10
                );
                if (*completion_end != ':') {
                    fprintf(stderr, "invalid PROTECTOR_SYNC_DVD_COMPLETIONS\n");
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                char* hash_end = NULL;
                const unsigned long long path_hash = strtoull(
                    completion_end + 1, &hash_end, 0
                );
                if (*hash_end != ':') {
                    fprintf(stderr, "invalid PROTECTOR_SYNC_DVD_COMPLETIONS\n");
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                char* offset_end = NULL;
                const unsigned long file_offset = strtoul(
                    hash_end + 1, &offset_end, 10
                );
                if (*offset_end != ':') {
                    fprintf(stderr, "invalid PROTECTOR_SYNC_DVD_COMPLETIONS\n");
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                char* length_end = NULL;
                const unsigned long requested_length = strtoul(
                    offset_end + 1, &length_end, 10
                );
                if (
                    requested_checkpoint_end == serial_end + 1 ||
                    completion_end == requested_checkpoint_end + 1 ||
                    hash_end == completion_end + 1 ||
                    offset_end == hash_end + 1 ||
                    length_end == offset_end + 1 ||
                    (*length_end != ',' && *length_end != '\0') ||
                    file_offset > UINT32_MAX ||
                    requested_length > UINT32_MAX ||
                    completion < requested_checkpoint ||
                    (have_previous && serial <= last_serial) ||
                    (have_previous && completion < last_checkpoint)
                ) {
                    fprintf(stderr, "invalid PROTECTOR_SYNC_DVD_COMPLETIONS\n");
                    protector_cpu_destroy(&cpu);
                    return 8;
                }
                DvdCompletionReplayEntry* entry =
                    &trace.dvd_completion_replay[
                        trace.dvd_completion_replay_count++
                    ];
                entry->request_serial = (u64)serial;
                entry->requested_frame = (u64)requested_checkpoint;
                entry->ready_frame = (u64)completion;
                entry->path_fnv1a64 = (u64)path_hash;
                entry->file_offset = (u32)file_offset;
                entry->requested_length = (u32)requested_length;
                entry->consumed = false;
                last_serial = (u64)serial;
                last_checkpoint = (u64)completion;
                have_previous = true;
                completion_cursor =
                    *length_end == ',' ? length_end + 1 : length_end;
            }
        }
        trace.sync_trace_frame_limit = (u32)frame_count;
        trace.sync_trace_anchor_path =
            sync_trace_anchor_path && sync_trace_anchor_path[0]
                ? sync_trace_anchor_path
                : "99_99.gcs";
        if (
            sync_trace_start_gx_frame &&
            sync_trace_start_gx_frame[0]
        ) {
            char* start_end = NULL;
            const unsigned long long start_frame = strtoull(
                sync_trace_start_gx_frame,
                &start_end,
                10
            );
            if (
                start_end == sync_trace_start_gx_frame ||
                *start_end != '\0'
            ) {
                fprintf(
                    stderr,
                    "invalid PROTECTOR_SYNC_TRACE_START_GX_FRAME\n"
                );
                protector_cpu_destroy(&cpu);
                return 8;
            }
            trace.sync_trace_start_gx_frame = (u64)start_frame;
        }
        trace.sync_frame_delta_start_gx_frame =
            trace.sync_trace_start_gx_frame;
        if (
            sync_frame_delta_start_gx_frame &&
            sync_frame_delta_start_gx_frame[0]
        ) {
            char* delta_start_end = NULL;
            const unsigned long long delta_start = strtoull(
                sync_frame_delta_start_gx_frame,
                &delta_start_end,
                10
            );
            if (
                delta_start_end == sync_frame_delta_start_gx_frame ||
                *delta_start_end != '\0' ||
                delta_start > trace.sync_trace_start_gx_frame
            ) {
                fprintf(
                    stderr,
                    "invalid PROTECTOR_SYNC_FRAME_DELTA_START_GX_FRAME\n"
                );
                protector_cpu_destroy(&cpu);
                return 8;
            }
            trace.sync_frame_delta_start_gx_frame = (u64)delta_start;
        }
        if (
            trace.sync_frame_delta_count != 0u &&
            trace.sync_frame_deltas[0] == 0u &&
            trace.sync_frame_delta_start_gx_frame != 0u
        ) {
            fprintf(
                stderr,
                "zero initial frame delta requires GX frame zero\n"
            );
            protector_cpu_destroy(&cpu);
            return 8;
        }
        if (
            trace.sync_frame_delta_count != 0u &&
            trace.sync_frame_delta_count <
                trace.sync_trace_start_gx_frame -
                    trace.sync_frame_delta_start_gx_frame +
                    trace.sync_trace_frame_limit
        ) {
            fprintf(stderr, "too few synchronized frame deltas\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        trace.sync_trace_file = fopen(sync_trace_path, "w");
        if (!trace.sync_trace_file) {
            fprintf(stderr, "failed to open synchronized-trace path\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
    }
    if (full_state_mode) {
        char* input_offset_end = NULL;
        const unsigned long input_offset =
            sync_input_sample_offset && sync_input_sample_offset[0]
                ? strtoul(
                      sync_input_sample_offset,
                      &input_offset_end,
                      10
                  )
                : 0u;
        if (
            !trace.sync_trace_file ||
            trace.sync_trace_start_gx_frame != full_state.checkpoint ||
            trace.sync_frame_delta_start_gx_frame != full_state.checkpoint ||
            !trace.sync_trace_anchor_path ||
            strcmp(trace.sync_trace_anchor_path, full_state.anchor) != 0 ||
            !sync_input_sample_offset ||
            !sync_input_sample_offset[0] ||
            input_offset_end == sync_input_sample_offset ||
            *input_offset_end != '\0' ||
            input_offset != full_state.next_input_sample ||
            trace.kpad_scheduled_pulse_count != 0u
        ) {
            fprintf(
                stderr,
                "full-state synchronized seam differs from checkpoint metadata\n"
            );
            protector_cpu_destroy(&cpu);
            return 8;
        }
        for (
            u32 index = 0u;
            index < trace.dvd_completion_replay_count;
            ++index
        ) {
            if (
                trace.dvd_completion_replay[index].ready_frame <=
                    full_state.checkpoint
            ) {
                trace.dvd_completion_replay[index].consumed = true;
            }
        }
    }
    trace.ai_control = 0x00000002u;
    trace.dsp_mail_from_dsp = 0x8071FEEDu;
    trace.dsp_mail_from_dsp_pending = true;
    trace.ax_emulation_enabled =
        getenv("PROTECTOR_AX_EMULATION") != NULL ||
        getenv("PROTECTOR_AX_MIX_SILENT") != NULL ||
        getenv("PROTECTOR_AX_PCM_CAPTURE_PATH") != NULL;
    if (
        full_state_mode &&
        trace.ax_emulation_enabled &&
        !initialize_imported_ax_state(&cpu, &trace)
    ) {
        fprintf(stderr, "%s\n", trace.platform_error);
        protector_cpu_destroy(&cpu);
        return 8;
    }
    trace.motion_diagnostics =
        getenv("PROTECTOR_MOTION_DIAGNOSTICS") != NULL;
    trace.gameplay_call_diagnostics =
        getenv("PROTECTOR_GAMEPLAY_CALL_DIAGNOSTICS") != NULL;
    /* Keep resource ownership observable during long playtests without the
     * much larger per-frame strategy/manager trace. This does not change I/O. */
    trace.dvd_async_diagnostics =
        getenv("PROTECTOR_DVD_ASYNC_DIAGNOSTICS") != NULL;
    const char* gameplay_call_state_context =
        getenv("PROTECTOR_GAMEPLAY_CALL_STATE_CONTEXT");
    if (gameplay_call_state_context && gameplay_call_state_context[0]) {
        char* end = NULL;
        const unsigned long parsed = strtoul(
            gameplay_call_state_context, &end, 0
        );
        if (
            end == gameplay_call_state_context ||
            *end != '\0' ||
            parsed == 0u ||
            parsed > UINT32_MAX
        ) {
            fprintf(stderr, "invalid PROTECTOR_GAMEPLAY_CALL_STATE_CONTEXT\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        trace.gameplay_call_state_context = (u32)parsed;
    }
    const char* gameplay_call_state_start_frame =
        getenv("PROTECTOR_GAMEPLAY_CALL_STATE_START_FRAME");
    if (
        gameplay_call_state_start_frame &&
        gameplay_call_state_start_frame[0]
    ) {
        char* end = NULL;
        const unsigned long parsed = strtoul(
            gameplay_call_state_start_frame, &end, 0
        );
        if (
            end == gameplay_call_state_start_frame ||
            *end != '\0' ||
            parsed > UINT32_MAX
        ) {
            fprintf(
                stderr,
                "invalid PROTECTOR_GAMEPLAY_CALL_STATE_START_FRAME\n"
            );
            protector_cpu_destroy(&cpu);
            return 8;
        }
        trace.gameplay_call_state_start_frame = (u32)parsed;
    }
    trace.rng_checkpoint_diagnostics =
        getenv("PROTECTOR_RNG_CHECKPOINT_DIAGNOSTICS") != NULL;
    const char* script_vm_diagnostic_context =
        getenv("PROTECTOR_SCRIPT_VM_CONTEXT");
    if (
        script_vm_diagnostic_context &&
        script_vm_diagnostic_context[0]
    ) {
        char* end = NULL;
        const unsigned long parsed = strtoul(
            script_vm_diagnostic_context, &end, 0
        );
        if (
            end == script_vm_diagnostic_context ||
            *end != '\0' ||
            parsed > UINT32_MAX
        ) {
            fprintf(stderr, "invalid PROTECTOR_SCRIPT_VM_CONTEXT\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        trace.script_vm_diagnostic_context = (u32)parsed;
    }
    trace.sync_trace_require_gameplay_bindings =
        getenv("PROTECTOR_SYNC_REQUIRE_GAMEPLAY_BINDINGS") != NULL;
    const char* memory_write_watch =
        getenv("PROTECTOR_MEMORY_WRITE_WATCH");
    if (memory_write_watch && memory_write_watch[0]) {
        char* end = NULL;
        const unsigned long parsed =
            strtoul(memory_write_watch, &end, 0);
        if (
            end == memory_write_watch ||
            *end != '\0' ||
            parsed > UINT32_MAX
        ) {
            fprintf(
                stderr,
                "invalid PROTECTOR_MEMORY_WRITE_WATCH\n"
            );
            protector_cpu_destroy(&cpu);
            return 8;
        }
        cpu.debug_memory_write_watch_address = (u32)parsed;
        const char* watch_start =
            getenv("PROTECTOR_MEMORY_WRITE_WATCH_START_FRAME");
        if (watch_start && watch_start[0]) {
            end = NULL;
            const unsigned long long parsed_start =
                strtoull(watch_start, &end, 10);
            if (end == watch_start || *end != '\0') {
                fprintf(
                    stderr,
                    "invalid PROTECTOR_MEMORY_WRITE_WATCH_START_FRAME\n"
                );
                protector_cpu_destroy(&cpu);
                return 8;
            }
            cpu.debug_memory_write_watch_start_frame = parsed_start;
        }
    }
    cpu.external_user_data = &trace;
    cpu.host_call = trace_host_call;
    cpu.system_call = trace_system_call;
    cpu.stop_handler = abort_translated_dispatch;
    cpu.external_read = trace_external_read;
    cpu.external_write = trace_external_write;
    if (!full_state_mode) {
        cpu.pc = dol.entry_point;
    }
    cpu.downcount = 0;
    cpu.trap_privileged_boot = false;
    cpu.memory_read_count = 0;
    cpu.memory_write_count = 0;

    u64 blocks = 0;
    u64 maximum_blocks = 1000000u;
    const char* maximum_blocks_text =
        getenv("PROTECTOR_MAX_BLOCKS");
    if (maximum_blocks_text && maximum_blocks_text[0]) {
        char* end = NULL;
        unsigned long long parsed =
            strtoull(maximum_blocks_text, &end, 10);
        if (
            end == maximum_blocks_text ||
            *end != '\0' ||
            parsed == 0u
        ) {
            fprintf(stderr, "invalid PROTECTOR_MAX_BLOCKS\n");
            protector_cpu_destroy(&cpu);
            return 8;
        }
        maximum_blocks = (u64)parsed;
    }
    const char* save_root = getenv("PROTECTOR_SAVE_ROOT");
    if (save_root) {
        if (!protector_save_store_open(&trace.save_store, save_root, error, sizeof(error))) {
            fprintf(stderr, "%s\n", error);
            protector_cpu_destroy(&cpu);
            return PROTECTOR_RUNTIME_SAVE_DIRECTORY_FAILED;
        }
        trace.save_store_enabled = true;
        protector_save_status_reset(true);
        for (unsigned index = 0; index < NATIVE_NAND_FILE_COUNT; ++index) {
            NativeNandFile* file = &trace.nand_files[index];
            if (!protector_save_store_load(&trace.save_store, index, &file->data,
                    &file->size, &file->exists, error, sizeof(error))) {
                fprintf(stderr, "save load failed: %s\n", error);
                for (unsigned previous = 0; previous < index; ++previous)
                    free(trace.nand_files[previous].data);
                protector_save_store_close(&trace.save_store);
                protector_cpu_destroy(&cpu);
                return PROTECTOR_RUNTIME_SAVE_LOAD_FAILED;
            }
            file->capacity = file->size;
            fprintf(stderr, "save loaded: slot=%u exists=%u bytes=%zu\n",
                index, file->exists ? 1u : 0u, file->size);
        }
    }
    const char* ui_text_log_path = getenv("PROTECTOR_UI_TEXT_LOG");
    const char* native_ui_text = getenv("PROTECTOR_NATIVE_UI_TEXT");
    trace.native_ui_text = native_ui_text && !strcmp(native_ui_text, "1");
    const char* native_startup = getenv("PROTECTOR_NATIVE_STARTUP");
    trace.native_startup = native_startup && !strcmp(native_startup, "1");
    const char* static_visibility = getenv("PROTECTOR_ENHANCED_STATIC_VISIBILITY");
    trace.enhanced_static_visibility = static_visibility && !strcmp(static_visibility, "1");
    if (ui_text_log_path && ui_text_log_path[0]) {
        trace.ui_text_log = fopen(ui_text_log_path, "wx");
        if (!trace.ui_text_log) {
            fprintf(stderr, "cannot create exclusive PROTECTOR_UI_TEXT_LOG\n");
            for (u32 index = 0; index < NATIVE_NAND_FILE_COUNT; ++index) free(trace.nand_files[index].data);
            protector_save_store_close(&trace.save_store);
            protector_cpu_destroy(&cpu);
            return 14;
        }
    }
    const char* ui_context_log_path = getenv("PROTECTOR_UI_CONTEXT_LOG");
    const char* ui_context_after_prompt = getenv("PROTECTOR_UI_CONTEXT_LOG_AFTER_PROMPT");
    trace.ui_context_log_after_prompt = ui_context_after_prompt && !strcmp(ui_context_after_prompt, "1");
    if (ui_context_log_path && ui_context_log_path[0]) {
        trace.ui_context_log = fopen(ui_context_log_path, "wx");
        if (!trace.ui_context_log) {
            fprintf(stderr, "cannot create exclusive PROTECTOR_UI_CONTEXT_LOG\n");
            if (trace.ui_text_log) fclose(trace.ui_text_log);
            for (u32 index = 0; index < NATIVE_NAND_FILE_COUNT; ++index) free(trace.nand_files[index].data);
            protector_save_store_close(&trace.save_store);
            protector_cpu_destroy(&cpu);
            return 14;
        }
        setvbuf(trace.ui_context_log, NULL, _IOLBF, 0);
    }
    initialize_ax_audio(&cpu, &trace);
    bool interactive_stop_requested = false;
    while (
        cpu.stop_reason == PROTECTOR_STOP_NONE &&
        cpu.exception == 0 &&
        blocks < maximum_blocks &&
        !trace.sync_trace_complete &&
        !trace.sync_trace_failed
    ) {
        if (protector_live_gx_stop_requested()) {
            // A user closing a live session is not a failed bounded capture.
            // Capture errors below retain precedence over this normal exit.
            interactive_stop_requested = protector_live_input_enabled();
            protector_stop(&cpu, PROTECTOR_STOP_HOST_SERVICE, cpu.pc, 0u, 0u);
            break;
        }
        // This loop runs at every guest call/return boundary. Each inline gate
        // below is the first early-out of the delivery it guards, so an idle
        // source is not an out-of-line call per block.
        if (trace.dvd_async_callback_queue_count != 0u &&
            deliver_dvd_async_callback(&cpu, &trace)) {
            continue;
        }
        bool idle_has_runnable_thread =
            cpu.pc == WII_OS_IDLE_WAIT &&
            mem_read32(&cpu, cpu.gpr[13] - 17264u) != 0u;
        if (!idle_has_runnable_thread) {
            const bool ax_frame_due =
                trace.ax_frame_armed &&
                cpu.timebase >= trace.ax_next_frame_timebase;
            const bool vi_retrace_due =
                trace.vi_retrace_armed &&
                cpu.timebase >= trace.next_vi_retrace_timebase;
            if (
                vi_retrace_due &&
                (
                    !ax_frame_due ||
                    trace.next_vi_retrace_timebase <=
                        trace.ax_next_frame_timebase
                ) &&
                deliver_vi_retrace(&cpu, &trace)
            ) {
                continue;
            }
            if (trace.ax_frame_armed &&
                cpu.timebase >= trace.ax_next_frame_timebase &&
                deliver_ax_frame(&cpu, &trace)) {
                continue;
            }
            if (trace.ipc_reply_pending && cpu.pc == WII_OS_IDLE_WAIT &&
                deliver_ipc_reply(&cpu, &trace)) {
                continue;
            }
            if (trace.pe_finish_pending && cpu.pc == WII_OS_IDLE_WAIT &&
                deliver_pe_finish(&cpu, &trace)) {
                continue;
            }
            if (trace.vi_retrace_armed &&
                cpu.timebase >= trace.next_vi_retrace_timebase &&
                deliver_vi_retrace(&cpu, &trace)) {
                continue;
            }
        }
        if (
            !idle_has_runnable_thread &&
            cpu.pc == WII_OS_IDLE_WAIT &&
            cpu.decrementer_armed &&
            cpu.core_cycles < cpu.decrementer_deadline_core_cycles
        ) {
            ppc_advance_broadway_cycles(
                &cpu,
                cpu.decrementer_deadline_core_cycles - cpu.core_cycles
            );
            trace.deterministic_fast_forwards++;
        }
        if (
            !idle_has_runnable_thread &&
            cpu.decrementer_armed &&
            cpu.core_cycles >= cpu.decrementer_deadline_core_cycles &&
            deliver_decrementer(&cpu, &trace)
        ) {
            continue;
        }
        if (cpu.stop_reason != PROTECTOR_STOP_NONE) {
            break;
        }
        cpu.downcount = 0;
        trace.dispatch_blocks_started = blocks + 1u;
        cpu.translated_dispatch_count = trace.dispatch_blocks_started;
        if (
            trace.gameplay_call_diagnostics &&
            cpu.debug_memory_write_watch_address != 0u &&
            cpu.presented_frame_count >=
                cpu.debug_memory_write_watch_start_frame &&
            cpu.pc == 0x800A73FCu
        ) {
            const u32 context = cpu.gpr[3];
            fprintf(
                stderr,
                "strategy_update_entry sync_frame=%u frame=%llu "
                "context=0x%08X flags=0x%08X ip=0x%08X "
                "base=0x%08X lr=0x%08X\n",
                trace.sync_trace_frame_count,
                (unsigned long long)cpu.presented_frame_count,
                context,
                mem_read32(&cpu, context + 432u),
                mem_read32(&cpu, context + 464u),
                mem_read32(&cpu, context + 472u),
                cpu.lr
            );
        }
        if (
            trace.gameplay_call_diagnostics &&
            cpu.pc == 0x800A1F08u
        ) {
            const u32 pair_manager = cpu.gpr[3];
            fprintf(
                stderr,
                "game_pair_manager_entry frame=%u manager=0x%08X "
                "count=%u offset_2018=0x%08X offset_2094=0x%08X "
                "offset_2098=0x%08X r4=0x%08X lr=0x%08X\n",
                trace.sync_trace_frame_count,
                pair_manager,
                mem_read32(&cpu, pair_manager + 0x2004u),
                mem_read32(&cpu, pair_manager + 0x2018u),
                mem_read32(&cpu, pair_manager + 0x2094u),
                mem_read32(&cpu, pair_manager + 0x2098u),
                cpu.gpr[4],
                cpu.lr
            );
        }
        if (!run_translated_dispatch(&cpu, &trace)) {
            break;
        }
        if (cpu.stop_reason != PROTECTOR_STOP_NONE) {
            break;
        }
        const u64 elapsed =
            cpu.downcount < 0
                ? (u64)(-(cpu.downcount + 1)) + 1u
                : 1u;
        trace.guest_instructions_completed += elapsed;
        ppc_advance_broadway_cycles(&cpu, elapsed);
        blocks++;
    }
    if (
        trace.gx_capture_file &&
        fclose(trace.gx_capture_file) != 0
    ) {
        trace.gx_capture_failed = true;
    }
    if (
        trace.sync_trace_file &&
        fclose(trace.sync_trace_file) != 0
    ) {
        trace.sync_trace_failed = true;
    }
    trace.sync_trace_file = NULL;
    trace.gx_capture_file = NULL;
    if (trace.ui_context_log) {
        fclose(trace.ui_context_log);
        trace.ui_context_log = NULL;
        fprintf(stderr, "ui_context_log rows=%u capped=%u\n", trace.ui_context_log_count,
            trace.ui_context_log_count == 50000);
    }
    if (trace.ui_text_log) {
        if (fclose(trace.ui_text_log) != 0) trace.ui_text_log_failed = true;
        trace.ui_text_log = NULL;
        fprintf(stderr, "ui_text_log unique=%u rejected=%" PRIu64 " capped=%u failed=%u\n",
            trace.ui_text_count, trace.ui_text_rejected, trace.ui_text_count == 4096,
            trace.ui_text_log_failed);
    }
    free(trace.gx_capture_frame);
    trace.gx_capture_frame = NULL;

    printf(
        "blocks=%" PRIu64 " pc=0x%08X stop=%s address=0x%08X "
        "host_calls=%" PRIu64 " last_host=0x%08X reads=%" PRIu64
        " writes=%" PRIu64 " mmio_reads=%" PRIu64
        " mmio_writes=%" PRIu64 " last_mmio=0x%08X"
        " system_calls=%" PRIu64 " last_system_call=0x%08X"
        " stubs=%" PRIu64 " last_stub=0x%08X"
        " stub_write_gather=%" PRIu64
        " stub_stm=%" PRIu64
        " stub_play_time=%" PRIu64
        " stub_net=%" PRIu64
        " stub_dvd_init=%" PRIu64
        " stub_vi_wait=%" PRIu64
        " stub_sc_init=%" PRIu64
        " stub_sc_status=%" PRIu64
        " stub_sc_aspect_ratio=%" PRIu64
        " stub_wud_init=%" PRIu64
        " stub_wud_status=%" PRIu64
        " wud_status_result=%d"
        " wud_status_first_caller=0x%08X"
        " wud_status_last_caller=0x%08X"
        " wud_status_caller_changes=%" PRIu64
        " kpad_reads=%" PRIu64
        " kpad_neutral_samples=%" PRIu64
        " kpad_non_neutral_samples=%" PRIu64
        " kpad_pulse_samples=%" PRIu64
        " kpad_last_channel=%u"
        " kpad_last_buffer=0x%08X"
        " kpad_last_capacity=%u"
        " kpad_last_hold=0x%08X"
        " kpad_last_trigger=0x%08X"
        " kpad_last_release=0x%08X"
        " kpad_template_valid=%u"
        " frame_loops=%" PRIu64
        " controller_manager_updates=%" PRIu64
        " controller_reconciles=%" PRIu64
        " controller_manager=0x%08X"
        " controller_slot_0=%d controller_slot_1=%d"
        " controller_slot_2=%d controller_slot_3=%d"
        " controller_slot_4=%d controller_slot_5=%d"
        " controller_slot_6=%d controller_slot_7=%d"
        " controller_connection_0=%d controller_connection_1=%d"
        " controller_connection_2=%d controller_connection_3=%d"
        " controller_connected=%u"
        " controller_connection_seeds=%" PRIu64
        " game_controller_updates=%" PRIu64
        " controller_post_kpad=%" PRIu64
        " controller_post_kpad_result=%u"
        " controller_post_kpad_hash=%016" PRIX64
        " wpad_probes=%" PRIu64
        " wpad_reads=%" PRIu64
        " bink_opens=%" PRIu64
        " save_asset_loads=%" PRIu64
        " save_metadata_inits=%" PRIu64
        " save_object_constructors=%" PRIu64
        " save_manager_inits=%" PRIu64
        " save_object_pointer=0x%08X"
        " save_object_enabled=%u"
        " save_object_fnv1a64=%016" PRIX64
        " save_async_loads=%" PRIu64
        " save_async_last_caller=0x%08X"
        " save_async_last_object=0x%08X"
        " save_async_last_enabled=%u"
        " save_script_loads=%" PRIu64
        " save_script_saves=%" PRIu64
        " save_script_load_last_r3=0x%08X"
        " save_script_load_last_r4=0x%08X"
        " save_script_load_last_context=0x%08X"
        " save_script_load_last_ip=0x%08X"
        " save_script_load_last_instruction=0x%08X"
        " save_script_load_last_base29=0x%08X"
        " save_script_load_last_base30=0x%08X"
        " save_script_load_last_base31=0x%08X"
        " nand_inits=%" PRIu64
        " nand_init_last_caller=0x%08X"
        " nand_init_last_result=%d"
        " nand_opens=%" PRIu64
        " nand_open_last_caller=0x%08X"
        " nand_open_last_result=%d"
        " nand_get_statuses=%" PRIu64
        " nand_get_status_last_caller=0x%08X"
        " nand_get_status_last_result=%d"
        " nand_closes=%" PRIu64
        " nand_close_last_caller=0x%08X"
        " nand_global_state=%u"
        " gx_fifo_writes=%" PRIu64
        " gx_fifo_bytes=%" PRIu64
        " gx_completed_frames=%" PRIu64
        " gx_last_frame_writes=%" PRIu64
        " gx_last_frame_bytes=%" PRIu64
        " gx_last_frame_hash=%016" PRIX64
        " gx_frame_hash_changes=%" PRIu64
        " gx_capture_failed=%u"
        " gx_memory_captured=%u"
        " gx_memory_frame=%" PRIu64
        " gx_memory_capture_failed=%u"
        " sync_trace_frames=%u"
        " sync_trace_complete=%u"
        " sync_trace_failed=%u"
        " sync_trace_checkpoint_pc=0x%08X"
        " stub_iusb=%" PRIu64
        " stub_dsp_add_task=%" PRIu64
        " ax_frames=%" PRIu64
        " ax_fast_sync_frames=%" PRIu64
        " ax_full_frames=%" PRIu64
        " ax_pb_pool=0x%08X"
        " ax_running_voices=%u"
        " ax_next_tb=%" PRIu64
        " ax_interval_tb=%" PRIu64
        " ios_requests=%" PRIu64 " last_ios_command=%u"
        " last_ios_pc=0x%08X last_ios_fd=%u"
        " last_ios_ioctl=%u"
        " last_ios_in=0x%08X/%u"
        " last_ios_out=0x%08X/%u"
        " ipc_replies=%" PRIu64 " ipc_handler=0x%08X"
        " ipc_status=%d ipc_cb=0x%08X"
        " ipc_queue=0x%08X/0x%08X"
        " last_ios_path=%s"
        " file_reads=%" PRIu64
        " file_read_completions=%" PRIu64 " last_file=%s"
        " dvd_async_reads=%" PRIu64
        " dvd_async_callbacks=%" PRIu64
        " dvd_async_cancelled=%" PRIu64
        " dvd_async_depth=%u"
        " dvd_async_pending=%u"
        " first_content_destination=0x%08X"
        " first_content_callback=0x%08X"
        " first_content_file_info=0x%08X"
        " first_content_disc_words=%u"
        " first_content_fst_index=%u"
        " first_content_hash=%016" PRIX64
        " last_file_offset=%u last_file_length=%u"
        " fst_entries=%u fst_size=%u"
        " fpu_unavailable=%" PRIu64
        " decrementer_interrupts=%" PRIu64
        " fast_forwards=%" PRIu64
        " retraces=%" PRIu64
        " pe_finishes=%" PRIu64
        " pe_finish_handler=0x%08X"
        " pe_sched_before=%u"
        " pe_hint_after=%u pe_bits_after=0x%08X"
        " pe_context_after=0x%08X pe_thread_after=0x%08X"
        " context_loads=%" PRIu64
        " last_context=0x%08X"
        " last_context_state=0x%04X"
        " last_context_gpr6=0x%08X"
        " hash_resumes=%" PRIu64
        " last_hash_resume_r3=0x%08X"
        " last_hash_resume_r6=0x%08X"
        " r1=0x%08X r11=0x%08X"
        " msr=0x%08X exception=0x%08X\n",
        blocks,
        cpu.pc,
        protector_stop_reason_name(cpu.stop_reason),
        cpu.stop_address,
        trace.host_call_count,
        trace.last_host_call,
        cpu.memory_read_count,
        cpu.memory_write_count,
        trace.mmio_read_count,
        trace.mmio_write_count,
        trace.last_mmio_address,
        trace.system_call_count,
        trace.last_system_call,
        trace.stub_count,
        trace.last_stub,
        trace.platform_stub_counts[0],
        trace.platform_stub_counts[1],
        trace.platform_stub_counts[2],
        trace.platform_stub_counts[3],
        trace.platform_stub_counts[4],
        trace.platform_stub_counts[5],
        trace.platform_stub_counts[6],
        trace.platform_stub_counts[7],
        trace.platform_stub_counts[11],
        trace.platform_stub_counts[8],
        trace.platform_stub_counts[9],
        trace.wud_status_result,
        trace.wud_status_first_caller,
        trace.wud_status_last_caller,
        trace.wud_status_caller_changes,
        trace.kpad_read_count,
        trace.kpad_neutral_sample_count,
        trace.kpad_non_neutral_sample_count,
        trace.kpad_pulse_sample_count,
        trace.kpad_last_channel,
        trace.kpad_last_buffer,
        trace.kpad_last_capacity,
        trace.kpad_last_hold,
        trace.kpad_last_trigger,
        trace.kpad_last_release,
        trace.kpad_status_template_valid ? 1u : 0u,
        trace.frame_loop_count,
        trace.game_controller_manager_update_count,
        trace.game_controller_reconcile_count,
        trace.game_controller_manager,
        trace.game_controller_slot_states[0],
        trace.game_controller_slot_states[1],
        trace.game_controller_slot_states[2],
        trace.game_controller_slot_states[3],
        trace.game_controller_slot_states[4],
        trace.game_controller_slot_states[5],
        trace.game_controller_slot_states[6],
        trace.game_controller_slot_states[7],
        trace.game_controller_connection_states[0],
        trace.game_controller_connection_states[1],
        trace.game_controller_connection_states[2],
        trace.game_controller_connection_states[3],
        trace.controller_connected ? 1u : 0u,
        trace.controller_connection_seed_count,
        trace.game_controller_update_count,
        trace.game_controller_post_kpad_count,
        trace.game_controller_post_kpad_result,
        trace.game_controller_post_kpad_hash,
        trace.wpad_probe_count,
        trace.wpad_read_count,
        trace.bink_open_count,
        trace.save_packaged_asset_load_count,
        trace.save_metadata_init_count,
        trace.save_object_constructor_count,
        trace.save_manager_init_count,
        mem_read32(&cpu, GAME_SAVE_OBJECT_POINTER),
        mem_read32(&cpu, GAME_SAVE_OBJECT_POINTER) != 0u
            ? mem_read8(
                  &cpu,
                  mem_read32(&cpu, GAME_SAVE_OBJECT_POINTER) + 8u
              )
            : 0u,
        mem_read32(&cpu, GAME_SAVE_OBJECT_POINTER) != 0u
            ? fnv1a_guest_bytes(
                  &cpu,
                  mem_read32(&cpu, GAME_SAVE_OBJECT_POINTER),
                  64u
              )
            : FNV1A64_OFFSET,
        trace.save_async_load_count,
        trace.save_async_load_last_caller,
        trace.save_async_load_last_object,
        trace.save_async_load_last_enabled,
        trace.save_script_load_count,
        trace.save_script_save_count,
        trace.save_script_load_last_r3,
        trace.save_script_load_last_r4,
        trace.save_script_load_last_context,
        trace.save_script_load_last_instruction_pointer,
        trace.save_script_load_last_instruction,
        trace.save_script_load_last_base29,
        trace.save_script_load_last_base30,
        trace.save_script_load_last_base31,
        trace.nand_init_count,
        trace.nand_init_last_caller,
        trace.nand_init_last_result,
        trace.nand_open_count,
        trace.nand_open_last_caller,
        trace.nand_open_last_result,
        trace.nand_get_status_count,
        trace.nand_get_status_last_caller,
        trace.nand_get_status_last_result,
        trace.nand_close_count,
        trace.nand_close_last_caller,
        mem_read32(&cpu, cpu.gpr[13] + (u32)(s32)(-15904)),
        trace.gx_fifo_write_count,
        trace.gx_fifo_byte_count,
        trace.gx_completed_frame_count,
        trace.gx_last_frame_write_count,
        trace.gx_last_frame_byte_count,
        trace.gx_last_frame_hash,
        trace.gx_frame_hash_change_count,
        trace.gx_capture_failed ? 1u : 0u,
        trace.gx_memory_captured ? 1u : 0u,
        trace.gx_memory_capture_frame,
        trace.gx_memory_capture_failed ? 1u : 0u,
        trace.sync_trace_frame_count,
        trace.sync_trace_complete ? 1u : 0u,
        trace.sync_trace_failed ? 1u : 0u,
        trace.sync_trace_checkpoint_pc,
        trace.platform_stub_counts[10],
        trace.dsp_add_task_stub_count,
        trace.ax_frame_count,
        trace.ax_fast_sync_frame_count,
        trace.ax_full_frame_count,
        trace.ax_dsp_pb_pool,
        trace.ax_last_running_voice_count,
        trace.ax_next_frame_timebase,
        trace.ax_frame_interval_timebase,
        trace.ios_request_count,
        trace.last_ios_command,
        trace.last_ios_pc,
        trace.last_ios_fd,
        trace.last_ios_ioctl,
        trace.last_ios_input,
        trace.last_ios_input_length,
        trace.last_ios_output,
        trace.last_ios_output_length,
        trace.ipc_reply_count,
        trace.ipc_handler_address,
        trace.last_ios_request
            ? (s32)mem_read32(&cpu, trace.last_ios_request + 4u)
            : 0,
        trace.last_ios_request
            ? mem_read32(&cpu, trace.last_ios_request + 32u)
            : 0u,
        trace.last_ios_request
            ? mem_read32(&cpu, trace.last_ios_request + 44u)
            : 0u,
        trace.last_ios_request
            ? mem_read32(&cpu, trace.last_ios_request + 48u)
            : 0u,
        trace.last_ios_path[0] ? trace.last_ios_path : "-",
        trace.file_read_count,
        trace.file_read_completion_count,
        trace.last_file_read.relative_path[0]
            ? trace.last_file_read.relative_path
            : "-",
        trace.dvd_async_read_count,
        trace.dvd_async_callback_count,
        trace.dvd_async_cancelled_count,
        trace.dvd_async_stack_depth,
        trace.dvd_async_callback_queue_count,
        trace.first_content_destination,
        trace.first_content_callback,
        trace.first_content_file_info,
        trace.first_content_disc_offset_words,
        trace.first_content_fst_entry_index,
        trace.first_content_hash,
        trace.last_file_read.file_offset,
        trace.last_file_read.requested_length,
        mount.fst_entry_count,
        mount.fst_size,
        cpu.fpu_unavailable_count,
        cpu.decrementer_interrupt_count,
        trace.deterministic_fast_forwards,
        trace.retrace_count,
        trace.pe_finish_count,
        trace.pe_finish_handler_address,
        trace.pe_scheduler_count_before,
        trace.pe_run_queue_hint_after,
        trace.pe_run_queue_bits_after,
        trace.pe_current_context_after,
        trace.pe_current_thread_after,
        trace.context_load_count,
        trace.last_context_address,
        trace.last_context_state,
        trace.last_context_gpr6,
        trace.hash_resume_count,
        trace.last_hash_resume_gpr3,
        trace.last_hash_resume_gpr6,
        cpu.gpr[1],
        cpu.gpr[11],
        cpu.msr,
        cpu.exception
    );
    printf(
        "r2_script_vm dispatches=%" PRIu64
        " wii_strap_dispatches=%" PRIu64
        " last_ip=0x%08X last_instruction=0x%08X"
        " context=0x%08X"
        " base29=0x%08X base30=0x%08X base31=0x%08X"
        " min_ip=0x%08X max_ip=0x%08X"
        " memcard_load=%" PRIu64
        " memcard_save=%" PRIu64
        " memcard_load_slot=%" PRIu64
        " memcard_save_slot=%" PRIu64 "\n",
        trace.script_vm_dispatch_count,
        trace.script_vm_wii_strap_dispatch_count,
        trace.script_vm_last_instruction_pointer,
        trace.script_vm_last_instruction,
        trace.script_vm_last_context,
        trace.script_vm_last_base29,
        trace.script_vm_last_base30,
        trace.script_vm_last_base31,
        trace.script_vm_min_instruction_pointer,
        trace.script_vm_max_instruction_pointer,
        trace.save_script_load_count,
        trace.save_script_save_count,
        trace.save_script_load_slot_count,
        trace.save_script_save_slot_count
    );
    printf(
        "r2_script_event dispatches=%" PRIu64
        " object=0x%08X id=0x%08X kind=%u payload=0x%08X"
        " node_creates=%" PRIu64
        " list=0x%08X handler=0x%08X"
        " context=0x%08X owner=0x%08X result=0x%08X\n",
        trace.script_event_dispatch_count,
        trace.script_event_dispatch_object,
        trace.script_event_dispatch_id,
        trace.script_event_dispatch_kind,
        trace.script_event_dispatch_payload,
        trace.script_event_node_create_count,
        trace.script_event_node_list,
        trace.script_event_node_handler,
        trace.script_event_node_context,
        trace.script_event_node_owner,
        trace.script_event_node_result
    );
    printf("r2_script_event_handler_words");
    for (u32 index = 0u; index < 16u; ++index) {
        printf(
            " w%u=%08X",
            index,
            trace.script_event_node_handler
                ? mem_read32(
                      &cpu,
                      trace.script_event_node_handler + index * 4u
                  )
                : 0u
        );
    }
    printf("\n");
    const u32 script_event_code =
        trace.script_event_node_handler
            ? mem_read32(&cpu, trace.script_event_node_handler + 16u)
            : 0u;
    printf(
        "r2_script_event_code address=%08X",
        script_event_code
    );
    for (u32 index = 0u; index < 24u; ++index) {
        printf(
            " w%u=%08X",
            index,
            script_event_code
                ? mem_read32(&cpu, script_event_code + index * 4u)
                : 0u
        );
    }
    printf("\n");
    printf("r2_script_event_node_words");
    for (u32 index = 0u; index < 16u; ++index) {
        printf(
            " w%u=%08X",
            index,
            trace.script_event_node_result
                ? mem_read32(
                      &cpu,
                      trace.script_event_node_result + index * 4u
                  )
                : 0u
        );
    }
    printf("\n");
    const char* diagnostics = getenv("PROTECTOR_R2_DIAGNOSTICS");
    if (diagnostics && diagnostics[0] && strcmp(diagnostics, "0") != 0) {
        const u64 script_vm_start =
            trace.script_vm_dispatch_count > SCRIPT_VM_RING_SIZE
                ? trace.script_vm_dispatch_count - SCRIPT_VM_RING_SIZE
                : 0u;
        for (u64 index = script_vm_start;
             index < trace.script_vm_dispatch_count;
             ++index) {
            const ScriptVmEvent* event =
                &trace.script_vm_ring[index % SCRIPT_VM_RING_SIZE];
            printf(
                "r2_script_vm_event index=%" PRIu64
                " ip=0x%08X instruction=0x%08X"
                " context=0x%08X"
                " base29=0x%08X base30=0x%08X base31=0x%08X\n",
                index,
                event->instruction_pointer,
                event->instruction,
                event->context,
                event->base29,
                event->base30,
                event->base31
            );
        }
        const u32 script_spawn_vm_count =
            trace.sync_frame_script_spawn_vm_dispatch_count <
                    SCRIPT_SPAWN_VM_FRAME_SIZE
                ? trace.sync_frame_script_spawn_vm_dispatch_count
                : SCRIPT_SPAWN_VM_FRAME_SIZE;
        for (u32 index = 0u; index < script_spawn_vm_count; ++index) {
            const ScriptVmEvent* event =
                &trace.sync_frame_script_spawn_vm_events[index];
            printf(
                "r2_script_spawn_vm_event index=%u"
                " ip=0x%08X instruction=0x%08X"
                " context=0x%08X"
                " base29=0x%08X base30=0x%08X base31=0x%08X\n",
                index,
                event->instruction_pointer,
                event->instruction,
                event->context,
                event->base29,
                event->base30,
                event->base31
            );
        }
        const u64 script_loop_start =
            trace.script_wii_strap_loop_count > SCRIPT_LOOP_RING_SIZE
                ? trace.script_wii_strap_loop_count - SCRIPT_LOOP_RING_SIZE
                : 0u;
        for (u64 index = script_loop_start;
             index < trace.script_wii_strap_loop_count;
             ++index) {
            const ScriptLoopEvent* event =
                &trace.script_wii_strap_loop_ring[
                    index % SCRIPT_LOOP_RING_SIZE
                ];
            printf(
                "r2_script_loop index=%" PRIu64
                " frame=%" PRIu64
                " v0=%08X v1=%08X v2=%08X v3=%08X"
                " v4=%08X v5=%08X v6=%08X v7=%08X"
                " v8=%08X v9=%08X v10=%08X\n",
                index,
                event->completed_frame,
                event->values[0],
                event->values[1],
                event->values[2],
                event->values[3],
                event->values[4],
                event->values[5],
                event->values[6],
                event->values[7],
                event->values[8],
                event->values[9],
                event->values[10]
            );
        }
        const u64 transition_loop_start =
            trace.script_transition_loop_count > SCRIPT_LOOP_RING_SIZE
                ? trace.script_transition_loop_count -
                    SCRIPT_LOOP_RING_SIZE
                : 0u;
        for (u64 index = transition_loop_start;
             index < trace.script_transition_loop_count;
             ++index) {
            const ScriptLoopEvent* event =
                &trace.script_transition_loop_ring[
                    index % SCRIPT_LOOP_RING_SIZE
                ];
            printf(
                "r2_transition_loop index=%" PRIu64
                " frame=%" PRIu64
                " v0=%08X v1=%08X v2=%08X v3=%08X"
                " v4=%08X v5=%08X v6=%08X v7=%08X"
                " v8=%08X v9=%08X v10=%08X\n",
                index,
                event->completed_frame,
                event->values[0],
                event->values[1],
                event->values[2],
                event->values[3],
                event->values[4],
                event->values[5],
                event->values[6],
                event->values[7],
                event->values[8],
                event->values[9],
                event->values[10]
            );
        }
        const u64 transition_probe_start =
            trace.script_transition_probe_count >
                    SCRIPT_TRANSITION_PROBE_RING_SIZE
                ? trace.script_transition_probe_count -
                    SCRIPT_TRANSITION_PROBE_RING_SIZE
                : 0u;
        for (u64 index = transition_probe_start;
             index < trace.script_transition_probe_count;
             ++index) {
            const ScriptTransitionProbeEvent* event =
                &trace.script_transition_probe_ring[
                    index % SCRIPT_TRANSITION_PROBE_RING_SIZE
                ];
            printf(
                "r2_transition_probe index=%" PRIu64
                " frame=%" PRIu64 " ip=0x%08X"
                " ui=0x%08X ui_flag=%u"
                " v0=%08X v1=%08X v2=%08X v3=%08X"
                " v4=%08X v5=%08X v6=%08X v7=%08X"
                " v8=%08X v9=%08X v10=%08X v11=%08X"
                " v12=%08X v13=%08X v14=%08X v15=%08X\n",
                index,
                event->completed_frame,
                event->instruction_pointer,
                event->ui_manager,
                event->ui_manager_flag,
                event->values[0],
                event->values[1],
                event->values[2],
                event->values[3],
                event->values[4],
                event->values[5],
                event->values[6],
                event->values[7],
                event->values[8],
                event->values[9],
                event->values[10],
                event->values[11],
                event->values[12],
                event->values[13],
                event->values[14],
                event->values[15]
            );
        }
        const u64 script_global_start =
            trace.script_global_35_nonzero_write_count >
                    SCRIPT_LOOP_RING_SIZE
                ? trace.script_global_35_nonzero_write_count -
                    SCRIPT_LOOP_RING_SIZE
                : 0u;
        for (u64 index = script_global_start;
             index < trace.script_global_35_nonzero_write_count;
             ++index) {
            const ScriptGlobalWriteEvent* event =
                &trace.script_global_35_nonzero_ring[
                    index % SCRIPT_LOOP_RING_SIZE
                ];
            printf(
                "r2_script_global_35_nonzero index=%" PRIu64
                " frame=%" PRIu64 " context=0x%08X"
                " ip=0x%08X value=0x%08X"
                " input=0x%08X source=%08X/%08X/%08X"
                " manager=0x%08X script=%08X/%08X/%08X"
                " root=%08X/%08X/%08X\n",
                index,
                event->completed_frame,
                event->context,
                event->instruction_pointer,
                event->value,
                event->input_state,
                event->input_hold,
                event->input_trigger,
                event->input_release,
                event->script_manager,
                event->script_input_hold,
                event->script_input_trigger,
                event->script_input_release,
                event->root_input_hold,
                event->root_input_trigger,
                event->root_input_release
            );
        }
        const u64 script_global_write_start =
            trace.script_global_35_write_count > SCRIPT_VM_RING_SIZE
                ? trace.script_global_35_write_count -
                    SCRIPT_VM_RING_SIZE
                : 0u;
        for (u64 index = script_global_write_start;
             index < trace.script_global_35_write_count;
             ++index) {
            const ScriptGlobalWriteEvent* event =
                &trace.script_global_35_write_ring[
                    index % SCRIPT_VM_RING_SIZE
                ];
            printf(
                "r2_script_global_35_write index=%" PRIu64
                " frame=%" PRIu64 " context=0x%08X"
                " ip=0x%08X value=0x%08X"
                " input=0x%08X source=%08X/%08X/%08X"
                " manager=0x%08X script=%08X/%08X/%08X"
                " root=%08X/%08X/%08X\n",
                index,
                event->completed_frame,
                event->context,
                event->instruction_pointer,
                event->value,
                event->input_state,
                event->input_hold,
                event->input_trigger,
                event->input_release,
                event->script_manager,
                event->script_input_hold,
                event->script_input_trigger,
                event->script_input_release,
                event->root_input_hold,
                event->root_input_trigger,
                event->root_input_release
            );
        }
        printf(
            "r2_script_global_35_writes total=%" PRIu64
            " nonzero=%" PRIu64 "\n",
            trace.script_global_35_write_count,
            trace.script_global_35_nonzero_write_count
        );
        for (
            u32 address = 0x90388300u;
            address < 0x90388B00u;
            address += 4u
        ) {
            printf(
                "r2_root_script_code address=0x%08X"
                " value=0x%08X\n",
                address,
                mem_read32(&cpu, address)
            );
        }
        for (
            u32 address = 0x9038F400u;
            address < 0x9038FC00u;
            address += 4u
        ) {
            printf(
                "r2_transition_script_code address=0x%08X"
                " value=0x%08X\n",
                address,
                mem_read32(&cpu, address)
            );
        }
        for (
            u32 address = 0x9039A300u;
            address < 0x9039A700u;
            address += 4u
        ) {
            printf(
                "r2_transition_definition_data address=0x%08X"
                " value=0x%08X\n",
                address,
                mem_read32(&cpu, address)
            );
        }
        for (
            u32 address = 0x90386900u;
            address < 0x90387200u;
            address += 4u
        ) {
            printf(
                "r2_transition_definition_strings address=0x%08X"
                " value=0x%08X\n",
                address,
                mem_read32(&cpu, address)
            );
        }
        printf(
            "r2_root_wait_spawn object=0x%08X"
            " handle=0x%08X flags=0x%08X filter=0x%08X"
            " ip=0x%08X stack=0x%08X base=0x%08X"
            " wait=%u root_var53=0x%08X root_var55=0x%08X\n",
            trace.r2_root_wait_spawn_object,
            trace.r2_root_wait_spawn_object
                ? mem_read32(
                      &cpu,
                      trace.r2_root_wait_spawn_object + 448u
                  )
                : 0u,
            trace.r2_root_wait_spawn_object
                ? mem_read32(
                      &cpu,
                      trace.r2_root_wait_spawn_object + 432u
                  )
                : 0u,
            trace.r2_root_wait_spawn_object
                ? mem_read32(
                      &cpu,
                      trace.r2_root_wait_spawn_object + 436u
                  )
                : 0u,
            trace.r2_root_wait_spawn_object
                ? mem_read32(
                      &cpu,
                      trace.r2_root_wait_spawn_object + 464u
                  )
                : 0u,
            trace.r2_root_wait_spawn_object
                ? mem_read32(
                      &cpu,
                      trace.r2_root_wait_spawn_object + 468u
                  )
                : 0u,
            trace.r2_root_wait_spawn_object
                ? mem_read32(
                      &cpu,
                      trace.r2_root_wait_spawn_object + 472u
                  )
                : 0u,
            trace.r2_root_wait_spawn_object
                ? mem_read16(
                      &cpu,
                      trace.r2_root_wait_spawn_object + 608u
                  )
                : 0u,
            mem_read32(&cpu, 0x9041ECE0u + 0x53u * 4u),
            mem_read32(&cpu, 0x9041ECE0u + 0x55u * 4u)
        );
    }
#if defined(PROTECTOR_IOS_PERF)
    const bool emit_perf_samples = true;
#else
    const char* perf_samples = getenv("PROTECTOR_PERF_SAMPLES");
    const bool emit_perf_samples =
        perf_samples &&
        perf_samples[0] &&
        strcmp(perf_samples, "0") != 0;
#endif
    if (emit_perf_samples) {
        for (u32 index = 0u;
             index < trace.perf_frame_sample_count;
             ++index) {
            printf(
                "perf_sample index=%u host_ns=%" PRIu64
                " blocks=%" PRIu64
                " guest_instructions=%" PRIu64 "\n",
                index,
                trace.perf_host_ns[index],
                trace.perf_blocks[index],
                trace.perf_guest_instructions[index]
            );
        }
    }

    if (cpu.stop_reason != PROTECTOR_STOP_HOST_SERVICE) {
        if (trace.platform_error[0]) {
            fprintf(
                stderr,
                "platform error: %s\n",
                trace.platform_error
            );
        }
        u64 host_start = trace.host_call_count > TRACE_RING_SIZE
                             ? trace.host_call_count - TRACE_RING_SIZE
                             : 0;
        fprintf(stderr, "last dispatches:");
        for (u64 index = host_start; index < trace.host_call_count; ++index) {
            fprintf(
                stderr,
                " %08X",
                trace.host_call_ring[index % TRACE_RING_SIZE]
            );
        }
        fprintf(stderr, "\nlast MMIO events:\n");
        u64 mmio_start = trace.mmio_event_count > TRACE_RING_SIZE
                             ? trace.mmio_event_count - TRACE_RING_SIZE
                             : 0;
        for (u64 index = mmio_start;
             index < trace.mmio_event_count;
             ++index) {
            const MmioEvent* event =
                &trace.mmio_ring[index % TRACE_RING_SIZE];
            fprintf(
                stderr,
                "  pc=%08X %c%u [%08X] = %08X\n",
                event->pc,
                event->write ? 'W' : 'R',
                event->size * 8u,
                event->address,
                event->value
            );
        }
        fprintf(stderr, "last context loads:\n");
        u64 context_start =
            trace.context_load_count > TRACE_RING_SIZE
                ? trace.context_load_count - TRACE_RING_SIZE
                : 0;
        for (u64 index = context_start;
             index < trace.context_load_count;
             ++index) {
            const ContextLoadEvent* event =
                &trace.context_load_ring[index % TRACE_RING_SIZE];
            fprintf(
                stderr,
                "  context=%08X resume=%08X r1=%08X\n",
                event->context,
                event->resume_pc,
                event->stack_pointer
            );
        }
        fprintf(stderr, "context summary:\n");
        for (
            u32 index = 0u;
            index < trace.context_summary_count;
            ++index
        ) {
            const ContextSummary* summary =
                &trace.context_summaries[index];
            fprintf(
                stderr,
                "  context=%08X loads=%" PRIu64
                " resume=%08X r1=%08X"
                " state=%u suspend=%d priority=%d"
                " queue=%08X link=%08X/%08X\n",
                summary->context,
                summary->load_count,
                summary->last_resume_pc,
                summary->last_stack_pointer,
                mem_read16(&cpu, summary->context + 712u),
                (s32)mem_read32(&cpu, summary->context + 716u),
                (s32)mem_read32(&cpu, summary->context + 720u),
                mem_read32(&cpu, summary->context + 732u),
                mem_read32(&cpu, summary->context + 736u),
                mem_read32(&cpu, summary->context + 740u)
            );
        }
        fprintf(stderr, "last thread sleeps:\n");
        u64 sleep_start =
            trace.sleep_count > TRACE_RING_SIZE
                ? trace.sleep_count - TRACE_RING_SIZE
                : 0;
        for (u64 index = sleep_start;
             index < trace.sleep_count;
             ++index) {
            const SleepEvent* event =
                &trace.sleep_ring[index % TRACE_RING_SIZE];
            fprintf(
                stderr,
                "  context=%08X queue=%08X caller=%08X\n",
                event->context,
                event->queue,
                event->caller
            );
        }
        fprintf(stderr, "last distinct dispatches:\n");
        u64 dispatch_start =
            trace.dispatch_breadcrumb_count > DISPATCH_BREADCRUMB_SIZE
                ? trace.dispatch_breadcrumb_count -
                      DISPATCH_BREADCRUMB_SIZE
                : 0;
        for (u64 index = dispatch_start;
             index < trace.dispatch_breadcrumb_count;
             ++index) {
            const DispatchBreadcrumb* breadcrumb =
                &trace.dispatch_breadcrumbs[
                    index % DISPATCH_BREADCRUMB_SIZE
                ];
            fprintf(
                stderr,
                "  call=%08X lr=%08X r1=%08X r3=%08X r4=%08X\n",
                breadcrumb->address,
                breadcrumb->lr,
                breadcrumb->r1,
                breadcrumb->r3,
                breadcrumb->r4
            );
        }
    }

    if (trace.ax_pcm_capture && fclose(trace.ax_pcm_capture)) {
        trace.ax_audio_failed = true;
        (void)snprintf(trace.ax_diagnostics.error, sizeof(trace.ax_diagnostics.error),
            "cannot finish PCM capture");
    }
    if (trace.ax_audio) {
        // A normal silent-session quit before the first DSP output is valid.
        // Offline captures still require actual samples to count as a capture.
        if (trace.ax_pcm_capture && !trace.ax_audio->output_frames) {
            trace.ax_audio_failed = true;
            (void)snprintf(trace.ax_diagnostics.error, sizeof(trace.ax_diagnostics.error),
                "PCM capture produced no frames");
        }
        protector_ax_diagnostics_engine(&trace.ax_diagnostics, trace.ax_audio);
        printf("ax_pcm sample_rate=32000 channels=2 frames=%" PRIu64
            " command_lists=%" PRIu64 " voices=%" PRIu64
            " commands=0x%08X ucode=0x%08X failed=%u mode=%s pcm_fnv1a64=%016" PRIx64 "\n",
            trace.ax_audio->output_frames, trace.ax_audio->command_lists,
            trace.ax_audio->voices_processed, trace.ax_audio->command_mask,
            trace.ax_audio->ucode_hash, trace.ax_audio_failed ? 1u : 0u,
            trace.ax_pcm_capture ? "capture" : "silent", trace.ax_diagnostics.pcm_fnv1a64);
        free(trace.ax_audio);
        trace.ax_audio = NULL;
    }
    trace.ax_diagnostics.running = false;
    trace.ax_diagnostics.failed = trace.ax_audio_failed;
    protector_ax_diagnostics_publish(&trace.ax_diagnostics);
    bool reached =
        cpu.stop_reason == PROTECTOR_STOP_HOST_SERVICE &&
        cpu.exception == 0 &&
        (
            interactive_stop_requested ||
            cpu.stop_address == FIRST_ASSET_REQUEST ||
            (
                trace.live_gx_complete &&
                cpu.stop_pc == GAME_FRAME_LOOP_BACKEDGE
            ) ||
            (
                stop_after_first_content &&
                cpu.stop_address == WII_SDK_DVD_READ_ASYNC_PRIO &&
                trace.dvd_async_read_count == 1u
            )
        );
    for (u32 index = 0u; index < NATIVE_NAND_FILE_COUNT; ++index) {
        free(trace.nand_files[index].data);
        trace.nand_files[index].data = NULL;
    }
    if (trace.save_store_enabled) protector_save_store_close(&trace.save_store);
    if (trace.ax_audio_failed) {
        protector_cpu_destroy(&cpu);
        return 13;
    }
    if (trace.save_store_failed) {
        protector_cpu_destroy(&cpu);
        return PROTECTOR_RUNTIME_SAVE_COMMIT_FAILED;
    }
    if (trace.ui_text_log_failed) {
        protector_cpu_destroy(&cpu);
        return 14;
    }
    if (
        trace.gx_capture_failed ||
        trace.gx_memory_capture_failed ||
        trace.sync_memory_capture_failed ||
        (
            trace.sync_memory_capture_path &&
            !trace.sync_memory_captured
        ) ||
        trace.sync_trace_failed
    ) {
        fprintf(stderr, "GX capture failed\n");
        protector_cpu_destroy(&cpu);
        return 11;
    }
    protector_cpu_destroy(&cpu);
    return reached ? 0 : 10;
}
