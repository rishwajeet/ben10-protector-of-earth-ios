#include "protector/live_gx.h"
#include "protector/motion_identity.h"
#include <stdatomic.h>

static _Thread_local const ProtectorMotionIdentity* motion_identity;
static _Thread_local const CPUState* motion_cpu;
static _Thread_local const u8* motion_fifo;
static _Thread_local size_t motion_fifo_size;

static const u8* motion_memory(const CPUState* cpu, u32 address, size_t size) {
    if (!cpu || (address & 3u)) return NULL;
    if (cpu->ram && address >= GC_RAM_BASE && (u64)address + size <= (u64)GC_RAM_BASE + cpu->ram_size)
        return cpu->ram + (address - GC_RAM_BASE);
    if (cpu->mem2 && address >= WII_MEM2_BASE && (u64)address + size <= (u64)WII_MEM2_BASE + cpu->mem2_size)
        return cpu->mem2 + (address - WII_MEM2_BASE);
    return NULL;
}
static u32 motion_word(const u8* p) {
    return (u32)p[0]<<24 | (u32)p[1]<<16 | (u32)p[2]<<8 | p[3];
}
static ProtectorMotionSkin motion_skin_source(const CPUState* cpu, const u8* stack) {
    ProtectorMotionSkin skin = {0};
    // CAA4 iterates the source group's 56-byte draw records. Its r29 is
    // saved by GXCallDisplayList at +20; r25/r24 are outputs of 2C9D0,
    // subsequently passed to GXSetArray by 21A34. Rigid draws leave them zero.
    if (!cpu->gpr[25]) return skin;
    const u8* group = motion_memory(cpu, cpu->gpr[16], 60);
    const u32 record = motion_word(stack+20);
    const u8* draw = motion_memory(cpu, record, 56);
    if (!group || !draw || (u64)cpu->gpr[16]+44 != cpu->gpr[21]) return skin;
    const u32 table = motion_word(group+28), count = motion_word(group+36);
    if (!count || count > 4096 || cpu->gpr[20] != count || cpu->gpr[26] >= count ||
        (u64)table + 56u*(u64)cpu->gpr[26] != record ||
        !motion_memory(cpu, table, 56u*(size_t)count) ||
        motion_word(draw+16) != cpu->gpr[29] || motion_word(draw+12) != cpu->gpr[30] ||
        !(group[44] & 3u)) return skin;
    const u32 vertices = motion_word(draw+4);
    if (!vertices || vertices > 65535 ||
        !motion_memory(cpu, motion_word(draw+20), 4) ||
        !motion_memory(cpu, motion_word(draw+24), 4) ||
        !motion_memory(cpu, cpu->gpr[25], (size_t)vertices*12) ||
        (cpu->gpr[24] && (!motion_memory(cpu, motion_word(draw+28), 4) ||
            !motion_memory(cpu, cpu->gpr[24], (size_t)vertices*12)))) return skin;
    skin.source_draw = record;
    skin.output_position = cpu->gpr[25]; skin.output_normal = cpu->gpr[24];
    for (size_t i=0; i<14; ++i) skin.source_words[i] = motion_word(draw+4*i);
    for (size_t i=0; i<4; ++i) skin.source_words[14+i] = motion_word(group+44+4*i);
    return skin;
}
void protector_motion_identity_lifecycle(ProtectorMotionIdentity* state, const CPUState* cpu, u32 address) {
    if (!state || !cpu) return;
    const u32 object = cpu->gpr[3];
    if (address == 0x8009E6C0u || address == 0x8009E53Cu || address == 0x80039FE8u) {
        // These objects are an array/pool (880-byte slots), not one allocation
        // per actor. A1878 activates a slot; A13F8/A180C release it. All three
        // calls cross translation chunks. Model rebinding also breaks history,
        // even when it assigns the same resource address again.
        for (size_t i=0; i<PROTECTOR_MOTION_OWNER_LIMIT; ++i) {
            if (state->owners[i].object != object) continue;
            const u8* instance = motion_memory(cpu, object, 880);
            const bool typed = instance && motion_word(instance) == 0x801FF408u;
            const bool activate = address == 0x8009E6C0u && cpu->lr == 0x800A187Cu && typed;
            const bool rebind = address == 0x80039FE8u && state->owners[i].generation && typed;
            state->owners[i].generation = (activate || rebind) && state->serial != UINT64_MAX ? ++state->serial : 0;
            return;
        }
        return;
    }
    if (address != 0x80072520u && address != 0x800723DCu) return;
    size_t vacant = PROTECTOR_MOTION_OWNER_LIMIT;
    for (size_t i=0; i<PROTECTOR_MOTION_OWNER_LIMIT; ++i) {
        if (state->owners[i].object == object) state->owners[i].object = 0;
        if (!state->owners[i].object && vacant == PROTECTOR_MOTION_OWNER_LIMIT) vacant = i;
    }
    /* 9ECF8 -> 72520 and 9ED98 -> 723DC cross translated chunks;
     * observing 9ECDC itself would miss intra-chunk constructor calls. */
    if (address != 0x80072520u || cpu->lr != 0x8009ECFCu ||
        !motion_memory(cpu, object, 880) || vacant == PROTECTOR_MOTION_OWNER_LIMIT) return;
    state->owners[vacant].object = object;
    state->owners[vacant].generation = 0; // constructed pool storage is not an active actor
}
void protector_motion_identity_fifo(ProtectorMotionIdentity* state, const CPUState* cpu,
                                    size_t offset, u64 value, u8 size) {
    if (!state || !cpu || state->overflow || cpu->pc != 0x800E9B20u || size != 1 || value != 0x40) return;
    /* Exact GXCallDisplayList -> CAA4 -> BB14 -> dynamic model caller.
     * The helper saves BB14's r18 (object) at +56. Other paths reuse that
     * register for unrelated values, so never admit them by vtable alone. */
    const u32 sp = cpu->gpr[1];
    const u8* stack = motion_memory(cpu, sp, 840);
    if (!stack || motion_word(stack) != sp + 32 || motion_word(stack+36) != 0x8001CCBCu ||
        motion_word(stack+32) != sp+144 || motion_word(stack+148) != 0x8001C7C0u ||
        motion_word(stack+836) != 0x8003A9DCu) return;
    const u32 object = motion_word(stack+88);
    const u8* instance = motion_memory(cpu, object, 784);
    if (!instance || motion_word(instance) != 0x801FF408u) return;
    const u32 binding = motion_word(instance+316);
    if (!motion_memory(cpu, binding, 8) || !cpu->gpr[30]) return;
    u64 generation = 0;
    for (size_t i=0; i<PROTECTOR_MOTION_OWNER_LIMIT; ++i)
        if (state->owners[i].object == object) { generation = state->owners[i].generation; break; }
    if (!generation) return;
    if (state->count == PROTECTOR_MOTION_CALL_LIMIT || (state->count && state->calls[state->count-1].fifo_offset >= offset)) {
        state->overflow = true;
        return;
    }
    state->calls[state->count++] = (ProtectorMotionCall){offset, cpu->gpr[29], cpu->gpr[30],
                                                       {generation, object, binding, motion_skin_source(cpu, stack)}};
}
void protector_motion_identity_next_frame(ProtectorMotionIdentity* state) {
    if (state) { state->count = 0; state->overflow = false; }
}
void protector_motion_identity_publish(const ProtectorMotionIdentity* state, const CPUState* cpu,
                                       const u8* fifo, size_t size) {
    motion_identity = state; motion_cpu = cpu; motion_fifo = fifo; motion_fifo_size = size;
}
ProtectorMotionInstance protector_motion_identity_lookup(const CPUState* cpu, const u8* fifo, size_t size,
                                                         size_t offset, u32 address, u32 length) {
    const ProtectorMotionInstance none = {0};
    if (!motion_identity || motion_identity->overflow || cpu != motion_cpu || fifo != motion_fifo ||
        size != motion_fifo_size || offset > size || size-offset < 9 || !fifo || fifo[offset] != 0x40 ||
        motion_word(fifo+offset+1) != address || motion_word(fifo+offset+5) != length) return none;
    size_t low = 0, high = motion_identity->count;
    while (low < high) {
        size_t mid = low+(high-low)/2;
        if (motion_identity->calls[mid].fifo_offset < offset) low = mid+1; else high = mid;
    }
    if (low == motion_identity->count) return none;
    const ProtectorMotionCall* call = &motion_identity->calls[low];
    return call->fifo_offset == offset && call->display_list == address && call->length == length ? call->instance : none;
}

static ProtectorLiveGXSink live_gx_sink = NULL;
static void* live_gx_user_data = NULL;
static ProtectorLiveCinematicOpenSink cinematic_open_sink = NULL;
static void* cinematic_open_user_data = NULL;
static atomic_bool live_gx_stop;
static _Thread_local ProtectorCinematicFrame cinematic_frame;
static _Thread_local ProtectorLiveComboFrame combo_frame;
static _Thread_local ProtectorLiveInteractionFrame interaction_frame;
static _Thread_local ProtectorLiveUpgradeFrame upgrade_frame;

void protector_live_gx_set_combo_frame(ProtectorLiveComboFrame frame) { combo_frame = frame; }
ProtectorLiveComboFrame protector_live_gx_combo_frame(void) { return combo_frame; }
void protector_live_gx_set_interaction_frame(ProtectorLiveInteractionFrame frame) { interaction_frame=frame; }
ProtectorLiveInteractionFrame protector_live_gx_interaction_frame(void) { return interaction_frame; }
void protector_live_gx_set_upgrade_frame(ProtectorLiveUpgradeFrame frame) { upgrade_frame=frame; }
ProtectorLiveUpgradeFrame protector_live_gx_upgrade_frame(void) { return upgrade_frame; }

void protector_live_gx_set_cinematic_frame(ProtectorCinematicFrame frame) {
    cinematic_frame = frame;
}
ProtectorCinematicFrame protector_live_gx_cinematic_frame(void) {
    return cinematic_frame;
}

void protector_live_gx_set_cinematic_open_sink(ProtectorLiveCinematicOpenSink sink, void* user_data) {
    cinematic_open_sink = sink;
    cinematic_open_user_data = user_data;
}
void protector_live_gx_prepare_cinematic(ProtectorCinematicOpening opening) {
    if (cinematic_open_sink && !protector_live_gx_stop_requested() &&
        opening.open_serial && opening.movie[0] &&
        strnlen(opening.movie, sizeof(opening.movie)) < sizeof(opening.movie))
        cinematic_open_sink(opening, cinematic_open_user_data);
}

void protector_live_gx_set_sink(
    ProtectorLiveGXSink sink,
    void* user_data
) {
    live_gx_sink = sink;
    live_gx_user_data = user_data;
    if (!sink) protector_live_gx_set_cinematic_open_sink(NULL, NULL);
    combo_frame = (ProtectorLiveComboFrame){0};
    interaction_frame = (ProtectorLiveInteractionFrame){0};
    upgrade_frame = (ProtectorLiveUpgradeFrame){0};
    protector_motion_identity_publish(NULL, NULL, NULL, 0);
    atomic_store(&live_gx_stop, false);
}

void protector_live_gx_request_stop(void) {
    atomic_store_explicit(&live_gx_stop, true, memory_order_relaxed);
}

bool protector_live_gx_stop_requested(void) {
    return atomic_load_explicit(&live_gx_stop, memory_order_relaxed);
}

bool protector_live_gx_has_sink(void) {
    return live_gx_sink != NULL;
}

ProtectorLiveGXResult protector_live_gx_submit(
    u32 frame_index,
    const u8* fifo,
    size_t fifo_size,
    CPUState* cpu
) {
    if (!live_gx_sink) {
        return PROTECTOR_LIVE_GX_CONTINUE;
    }
    return live_gx_sink(
        frame_index,
        fifo,
        fifo_size,
        cpu,
        live_gx_user_data
    );
}
