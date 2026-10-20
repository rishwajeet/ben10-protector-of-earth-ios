#include "protector/cinematic.h"
#include <stdatomic.h>

static _Atomic u64 requested_movie_serial;

bool protector_cinematic_is_opening_logo(const ProtectorCinematicFrame* frame) {
    if (!frame || !frame->active || !frame->open_serial ||
        strnlen(frame->movie,sizeof(frame->movie)) == sizeof(frame->movie)) return false;
    const char* names[] = {"Legal.bik", "legal.bik", "ESRB.bik", "CN.bik", "D3.bik", "HVSIntro.bik", "Logo_2K.bik", "Dolby.bik"};
    for (size_t i=0; i<sizeof(names)/sizeof(names[0]); ++i)
        if (!strcmp(frame->movie,names[i])) return true;
    return false;
}
bool protector_cinematic_request_logo_skip(const ProtectorCinematicFrame* frame) {
    if (!protector_cinematic_is_opening_logo(frame)) return false;
    return protector_cinematic_request_skip(frame);
}
bool protector_cinematic_can_skip(const ProtectorCinematicFrame* frame) {
    if (protector_cinematic_is_opening_logo(frame)) return true;
    if (!frame || !frame->active || !frame->open_serial ||
        strnlen(frame->movie,sizeof(frame->movie)) == sizeof(frame->movie)) return false;
    const char* movie=frame->movie;
    // The source inventory's 25 numbered level intro/outro pairs. Do not
    // treat looping menu backgrounds or arbitrary active Bink media as story.
    if (movie[0]>='1' && movie[0]<='5' && movie[1]>='1' && movie[1]<='5' &&
        (!strcmp(movie+2,"_intro.bik") || !strcmp(movie+2,"_outro.bik"))) return true;
    return !strcmp(movie,"55_outro_B.bik") || !strcmp(movie,"HVS_Kid_Intro.bik") ||
        !strcmp(movie,"attract.bik") || !strcmp(movie,"credits.bik");
}
bool protector_cinematic_request_skip(const ProtectorCinematicFrame* frame) {
    if (!protector_cinematic_can_skip(frame)) return false;
    atomic_store(&requested_movie_serial,frame->open_serial);
    return true;
}
void protector_cinematic_clear_logo_skip(void) { atomic_store(&requested_movie_serial,0); }

/* Verified source instruction anchors: CBinkPlayer::Play, its global handle,
 * dimensions, decode/advance calls and BinkDoFrame's completed-frame stores.
 * In particular +12 may already point to the NEXT frame when GX is submitted;
 * +16 and +724 identify the last decoded picture. No time-based guessing. */
static const ProtectorCinematicSourceWord words[] = {
    {0x800BB168u, 0x9421FFD0u}, {0x800BB198u, 0x800DBA78u},
    {0x800BB1C0u, 0x38801400u}, {0x800BB1C4u, 0x480C791Du},
    {0x800BB1CCu, 0x906DBA78u}, {0x800BB810u, 0x480C83ADu},
    {0x800BB85Cu, 0x806DBA78u}, {0x800BB894u, 0x8083000Cu},
    {0x800BB898u, 0x80030008u}, {0x800BB9B8u, 0x800DBA78u},
    {0x800BBA30u, 0x80870000u}, {0x800BBA48u, 0x80A70004u},
    {0x80183BE8u, 0x8003000Cu}, {0x80184128u, 0x8097000Cu},
    {0x80184154u, 0x909702D4u}, {0x80184158u, 0x90970010u},
};

static const u8* bytes_at(const CPUState* cpu, u32 address, u32 size) {
    if (!cpu || !size) return NULL;
    const u32 bases[] = {GC_RAM_BASE, GC_RAM_UNCACHED, WII_MEM2_BASE, WII_MEM2_UNCACHED};
    for (u32 i = 0; i < 4; ++i) {
        const u8* bytes = i < 2 ? cpu->ram : cpu->mem2;
        const u32 capacity = i < 2 ? cpu->ram_size : cpu->mem2_size;
        if (bytes && address >= bases[i]) {
            const u32 offset = address - bases[i];
            if (offset < capacity && size <= capacity - offset) return bytes + offset;
        }
    }
    return NULL;
}
static bool word_at(const CPUState* cpu, u32 address, u32* out) {
    const u8* p = bytes_at(cpu, address, 4);
    if (!p || (address & 3u)) return false;
    *out = (u32)p[0] << 24 | (u32)p[1] << 16 | (u32)p[2] << 8 | p[3];
    return true;
}
const ProtectorCinematicSourceWord* protector_cinematic_source_words(size_t* count) {
    if (count) *count = sizeof(words) / sizeof(words[0]);
    return words;
}
bool protector_cinematic_source_valid(const CPUState* cpu) {
    for (size_t i = 0; i < sizeof(words) / sizeof(words[0]); ++i) {
        u32 value = 0;
        if (!word_at(cpu, words[i].address, &value) || value != words[i].value) return false;
    }
    return true;
}

static bool movie_at(const CPUState* cpu, u32 address, char* out) {
    char path[128] = {0};
    if (address > UINT32_MAX - sizeof(path)) return false;
    size_t n = 0;
    for (; n < sizeof(path); ++n) {
        const u8* p = bytes_at(cpu, address + (u32)n, 1);
        if (!p) return false;
        if (!*p) break;
        path[n] = *p == '\\' ? '/' : (char)*p;
    }
    if (!n || n == sizeof(path)) return false;
    const char* name = path;
    if (*name == '/') ++name;
    if (!strncmp(name, "Movies/", 7) || !strncmp(name, "movies/", 7)) name += 7;
    const size_t length = strlen(name);
    if (length < 5 || length >= 96 || strcmp(name + length - 4, ".bik")) return false;
    for (size_t i = 0; i < length - 4; ++i) {
        const char c = name[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_')) return false;
    }
    memcpy(out, name, length + 1);
    return true;
}

bool protector_cinematic_observe_open(ProtectorCinematicTracker* tracker, const CPUState* cpu) {
    if (!tracker) return false;
    const u64 serial = tracker->open_serial;
    *tracker = (ProtectorCinematicTracker){0};
    tracker->open_serial = serial;
    u32 handle = 0;
    if (!cpu || cpu->lr != 0x800BB1C8u || cpu->gpr[4] != 0x1400u ||
        cpu->gpr[13] < 17800u || !protector_cinematic_source_valid(cpu) ||
        !word_at(cpu, cpu->gpr[13] - 17800u, &handle) || handle ||
        !movie_at(cpu, cpu->gpr[3], tracker->movie)) return false;
    tracker->small_data_base = cpu->gpr[13];
    tracker->open_serial = serial + 1;
    tracker->pending = true;
    return true;
}

ProtectorCinematicFrame protector_cinematic_observe_frame(ProtectorCinematicTracker* tracker,
        const CPUState* cpu, u64 frame) {
    ProtectorCinematicFrame result = {.presentation_frame = frame};
    if (!tracker || !cpu || !tracker->pending) return result;
    u32 handle = 0;
    if (!word_at(cpu, tracker->small_data_base - 17800u, &handle)) goto reject;
    if (!handle) {
        if (tracker->bound_handle) goto reject; /* completed/closed; never resurrect */
        return result; /* still opening */
    }
    if (tracker->bound_handle && tracker->bound_handle != handle) goto reject;
    if ((handle & 3u) || handle > UINT32_MAX - 728u || !bytes_at(cpu, handle, 728u)) goto reject;
    tracker->bound_handle = handle;
    result.handle = handle;
    u32* fields[] = {&result.width, &result.height, &result.frame_count,
        &result.next_frame_one_based, &result.decoded_frame_one_based,
        &result.rate_numerator, &result.rate_denominator};
    for (u32 i = 0; i < 7; ++i)
        if (!word_at(cpu, handle + 4u * i, fields[i])) goto reject;
    u32 completed = 0, error = 0;
    if (!word_at(cpu, handle + 724u, &completed) || !word_at(cpu, handle + 28u, &error) || error ||
        !result.width || result.width > 7680 || !result.height || result.height > 4800 ||
        !result.frame_count || result.frame_count > 1000000 ||
        !result.next_frame_one_based || result.next_frame_one_based > result.frame_count ||
        result.decoded_frame_one_based > result.frame_count ||
        completed != result.decoded_frame_one_based || !result.rate_denominator ||
        result.rate_numerator < result.rate_denominator ||
        (u64)result.rate_numerator > 120ull * result.rate_denominator) goto reject;
    if (!completed) return (ProtectorCinematicFrame){.presentation_frame = frame};
    memcpy(result.movie, tracker->movie, sizeof(result.movie));
    result.open_serial = tracker->open_serial;
    result.active = true;
    return result;
reject:
    tracker->pending = false;
    return (ProtectorCinematicFrame){.presentation_frame = frame};
}

bool protector_cinematic_apply_logo_skip(ProtectorCinematicTracker* tracker, CPUState* cpu, u32 address) {
    if (address != 0x800BB8B8u || !atomic_load(&requested_movie_serial)) return false;
    const u64 requested=atomic_exchange(&requested_movie_serial,0);
    u32 instruction=0;
    if (!tracker || !cpu || requested != tracker->open_serial ||
        !word_at(cpu,address,&instruction) || instruction != 0x2c000000u ||
        !protector_cinematic_source_valid(cpu)) return false;
    const ProtectorCinematicFrame frame=protector_cinematic_observe_frame(tracker,cpu,cpu->presented_frame_count);
    if (!protector_cinematic_can_skip(&frame) || frame.open_serial != requested) return false;
    // CBinkPlayer::Update has finished the current decode/advance. A zero
    // continuation result takes its ordinary completion/close path, including
    // audio and resource cleanup. Guest frame counters and memory are untouched.
    cpu->gpr[0]=0;
    return true;
}
