#include "protector/full_state.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#define FULL_STATE_HEADER_SIZE 212u
#define FULL_STATE_CPU_SIZE 4944u
#define SPR_XER 1u
#define SPR_LR 8u
#define SPR_CTR 9u
#define SPR_DEC 22u
#define SPR_TL 268u
#define SPR_TU 269u
#define SPR_PVR 287u
#define SPR_GQR0 912u
#define SPR_HID2 920u

static const u8 FULL_STATE_MAGIC[8] = {
    'P', 'N', 'R', '3', 'S', 'T', '0', '1'
};
static const u8 CPU_STATE_MAGIC[8] = {
    'P', 'N', 'C', 'P', 'U', 'V', '0', '1'
};

typedef struct Sha256Context {
    u32 state[8];
    u64 bit_length;
    u8 buffer[64];
    u32 buffer_length;
} Sha256Context;

typedef struct FullArchitecture {
    u32 gpr[32];
    u64 fpr_bits[32];
    u64 ps1_bits[32];
    u32 pc;
    u32 npc;
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
    u32 exception;
    s32 source_downcount;
    u32 sr[16];
    u32 gqr[8];
    u32 spr[1024];
    u64 core_ticks;
    u64 timebase;
    u64 decrementer_deadline_core_ticks;
    u32 decrementer;
    u32 timebase_cycle_remainder;
    u32 reservation_address;
    bool reservation_valid;
} FullArchitecture;

static void set_error(
    char* error, size_t error_capacity, const char* format, ...
) {
    if (!error || error_capacity == 0u) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    (void)vsnprintf(error, error_capacity, format, arguments);
    va_end(arguments);
}

static u32 read_u32_be(const u8* value) {
    return
        ((u32)value[0] << 24) |
        ((u32)value[1] << 16) |
        ((u32)value[2] << 8) |
        (u32)value[3];
}

static u64 read_u64_be(const u8* value) {
    return ((u64)read_u32_be(value) << 32) | read_u32_be(value + 4u);
}

static u32 rotate_right(u32 value, u32 count) {
    return (value >> count) | (value << (32u - count));
}

static void sha256_transform(Sha256Context* context, const u8 block[64]) {
    static const u32 constants[64] = {
        0x428A2F98u, 0x71374491u, 0xB5C0FBCFu, 0xE9B5DBA5u,
        0x3956C25Bu, 0x59F111F1u, 0x923F82A4u, 0xAB1C5ED5u,
        0xD807AA98u, 0x12835B01u, 0x243185BEu, 0x550C7DC3u,
        0x72BE5D74u, 0x80DEB1FEu, 0x9BDC06A7u, 0xC19BF174u,
        0xE49B69C1u, 0xEFBE4786u, 0x0FC19DC6u, 0x240CA1CCu,
        0x2DE92C6Fu, 0x4A7484AAu, 0x5CB0A9DCu, 0x76F988DAu,
        0x983E5152u, 0xA831C66Du, 0xB00327C8u, 0xBF597FC7u,
        0xC6E00BF3u, 0xD5A79147u, 0x06CA6351u, 0x14292967u,
        0x27B70A85u, 0x2E1B2138u, 0x4D2C6DFCu, 0x53380D13u,
        0x650A7354u, 0x766A0ABBu, 0x81C2C92Eu, 0x92722C85u,
        0xA2BFE8A1u, 0xA81A664Bu, 0xC24B8B70u, 0xC76C51A3u,
        0xD192E819u, 0xD6990624u, 0xF40E3585u, 0x106AA070u,
        0x19A4C116u, 0x1E376C08u, 0x2748774Cu, 0x34B0BCB5u,
        0x391C0CB3u, 0x4ED8AA4Au, 0x5B9CCA4Fu, 0x682E6FF3u,
        0x748F82EEu, 0x78A5636Fu, 0x84C87814u, 0x8CC70208u,
        0x90BEFFFAu, 0xA4506CEBu, 0xBEF9A3F7u, 0xC67178F2u,
    };
    u32 words[64];
    for (u32 index = 0u; index < 16u; ++index) {
        words[index] = read_u32_be(block + index * 4u);
    }
    for (u32 index = 16u; index < 64u; ++index) {
        const u32 before15 = words[index - 15u];
        const u32 before2 = words[index - 2u];
        const u32 small0 =
            rotate_right(before15, 7u) ^ rotate_right(before15, 18u) ^
            (before15 >> 3u);
        const u32 small1 =
            rotate_right(before2, 17u) ^ rotate_right(before2, 19u) ^
            (before2 >> 10u);
        words[index] =
            words[index - 16u] + small0 + words[index - 7u] + small1;
    }
    u32 a = context->state[0];
    u32 b = context->state[1];
    u32 c = context->state[2];
    u32 d = context->state[3];
    u32 e = context->state[4];
    u32 f = context->state[5];
    u32 g = context->state[6];
    u32 h = context->state[7];
    for (u32 index = 0u; index < 64u; ++index) {
        const u32 big1 =
            rotate_right(e, 6u) ^ rotate_right(e, 11u) ^
            rotate_right(e, 25u);
        const u32 choice = (e & f) ^ ((~e) & g);
        const u32 temporary1 =
            h + big1 + choice + constants[index] + words[index];
        const u32 big0 =
            rotate_right(a, 2u) ^ rotate_right(a, 13u) ^
            rotate_right(a, 22u);
        const u32 majority = (a & b) ^ (a & c) ^ (b & c);
        const u32 temporary2 = big0 + majority;
        h = g;
        g = f;
        f = e;
        e = d + temporary1;
        d = c;
        c = b;
        b = a;
        a = temporary1 + temporary2;
    }
    context->state[0] += a;
    context->state[1] += b;
    context->state[2] += c;
    context->state[3] += d;
    context->state[4] += e;
    context->state[5] += f;
    context->state[6] += g;
    context->state[7] += h;
}

static void sha256_init(Sha256Context* context) {
    const u32 initial[8] = {
        0x6A09E667u, 0xBB67AE85u, 0x3C6EF372u, 0xA54FF53Au,
        0x510E527Fu, 0x9B05688Cu, 0x1F83D9ABu, 0x5BE0CD19u,
    };
    memcpy(context->state, initial, sizeof(initial));
    context->bit_length = 0u;
    context->buffer_length = 0u;
}

static void sha256_update(
    Sha256Context* context, const u8* value, size_t length
) {
    for (size_t index = 0u; index < length; ++index) {
        context->buffer[context->buffer_length++] = value[index];
        if (context->buffer_length == sizeof(context->buffer)) {
            sha256_transform(context, context->buffer);
            context->bit_length += 512u;
            context->buffer_length = 0u;
        }
    }
}

static void sha256_finish(Sha256Context* context, u8 output[32]) {
    u32 index = context->buffer_length;
    context->buffer[index++] = 0x80u;
    if (index > 56u) {
        while (index < 64u) {
            context->buffer[index++] = 0u;
        }
        sha256_transform(context, context->buffer);
        index = 0u;
    }
    while (index < 56u) {
        context->buffer[index++] = 0u;
    }
    context->bit_length += (u64)context->buffer_length * 8u;
    for (u32 byte = 0u; byte < 8u; ++byte) {
        context->buffer[63u - byte] =
            (u8)(context->bit_length >> (byte * 8u));
    }
    sha256_transform(context, context->buffer);
    for (u32 word = 0u; word < 8u; ++word) {
        output[word * 4u] = (u8)(context->state[word] >> 24);
        output[word * 4u + 1u] = (u8)(context->state[word] >> 16);
        output[word * 4u + 2u] = (u8)(context->state[word] >> 8);
        output[word * 4u + 3u] = (u8)context->state[word];
    }
}

static void sha256(const u8* value, size_t length, u8 output[32]) {
    Sha256Context context;
    sha256_init(&context);
    sha256_update(&context, value, length);
    sha256_finish(&context, output);
}

static bool digest_matches(
    const u8* value, size_t length, const u8 expected[32]
) {
    u8 actual[32];
    sha256(value, length, actual);
    return memcmp(actual, expected, sizeof(actual)) == 0;
}

static bool mapped_pc(u32 pc) {
    return
        (pc & 3u) == 0u &&
        (
            (pc >= GC_RAM_BASE && pc < GC_RAM_BASE + GC_MAIN_RAM_SIZE) ||
            (pc >= WII_MEM2_BASE && pc < WII_MEM2_BASE + WII_MEM2_SIZE)
        );
}

static bool parse_architecture(
    const u8 payload[FULL_STATE_CPU_SIZE],
    FullArchitecture* state,
    char* error,
    size_t error_capacity
) {
    if (
        memcmp(payload, CPU_STATE_MAGIC, sizeof(CPU_STATE_MAGIC)) != 0 ||
        read_u32_be(payload + 8u) != 1u ||
        read_u32_be(payload + 12u) != FULL_STATE_CPU_SIZE
    ) {
        set_error(error, error_capacity, "%s", "invalid full-state CPU header");
        return false;
    }
    memset(state, 0, sizeof(*state));
    state->core_ticks = read_u64_be(payload + 16u);
    state->timebase = read_u64_be(payload + 24u);
    state->decrementer_deadline_core_ticks = read_u64_be(payload + 32u);
    state->decrementer = read_u32_be(payload + 40u);
    state->timebase_cycle_remainder = read_u32_be(payload + 44u);
    size_t offset = 48u;
    for (u32 index = 0u; index < 32u; ++index, offset += 4u) {
        state->gpr[index] = read_u32_be(payload + offset);
    }
    for (u32 index = 0u; index < 32u; ++index, offset += 8u) {
        state->fpr_bits[index] = read_u64_be(payload + offset);
    }
    for (u32 index = 0u; index < 32u; ++index, offset += 8u) {
        state->ps1_bits[index] = read_u64_be(payload + offset);
    }
    u32* scalar_fields[] = {
        &state->pc, &state->npc, &state->lr, &state->ctr,
        &state->cr, &state->xer, &state->fpscr, &state->msr,
        &state->srr0, &state->srr1, &state->ear, &state->hid2,
        &state->exception,
    };
    for (u32 index = 0u; index < 13u; ++index, offset += 4u) {
        *scalar_fields[index] = read_u32_be(payload + offset);
    }
    state->source_downcount = (s32)read_u32_be(payload + offset);
    offset += 4u;
    for (u32 index = 0u; index < 16u; ++index, offset += 4u) {
        state->sr[index] = read_u32_be(payload + offset);
    }
    for (u32 index = 0u; index < 8u; ++index, offset += 4u) {
        state->gqr[index] = read_u32_be(payload + offset);
    }
    for (u32 index = 0u; index < 1024u; ++index, offset += 4u) {
        state->spr[index] = read_u32_be(payload + offset);
    }
    state->reservation_address = read_u32_be(payload + offset);
    offset += 4u;
    const u32 reservation_valid = read_u32_be(payload + offset);
    offset += 4u;
    if (offset != FULL_STATE_CPU_SIZE || reservation_valid > 1u) {
        set_error(error, error_capacity, "%s", "invalid full-state CPU payload");
        return false;
    }
    state->reservation_valid = reservation_valid != 0u;
    if (
        state->timebase_cycle_remainder >=
            PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK ||
        !mapped_pc(state->pc) || state->npc != state->pc ||
        state->exception != 0u || state->spr[SPR_PVR] != PPC_BROADWAY_PVR ||
        state->spr[SPR_XER] != state->xer ||
        state->spr[SPR_LR] != state->lr ||
        state->spr[SPR_CTR] != state->ctr ||
        state->spr[SPR_DEC] != state->decrementer ||
        state->spr[SPR_TL] != (u32)state->timebase ||
        state->spr[SPR_TU] != (u32)(state->timebase >> 32) ||
        state->spr[SPR_HID2] != state->hid2
    ) {
        set_error(error, error_capacity, "%s", "inconsistent full-state CPU payload");
        return false;
    }
    if ((state->decrementer & 0x80000000u) == 0u) {
        if (
            state->decrementer_deadline_core_ticks < state->core_ticks ||
            (
                state->decrementer_deadline_core_ticks -
                    state->core_ticks +
                    PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK - 1u
            ) /
                    PPC_BROADWAY_CYCLES_PER_TIMEBASE_TICK !=
                state->decrementer
        ) {
            set_error(
                error,
                error_capacity,
                "%s",
                "inconsistent full-state decrementer deadline"
            );
            return false;
        }
    } else if (state->decrementer_deadline_core_ticks != 0u) {
        set_error(
            error,
            error_capacity,
            "%s",
            "inactive full-state decrementer has a deadline"
        );
        return false;
    }
    for (u32 index = 0u; index < 8u; ++index) {
        if (state->gqr[index] != state->spr[SPR_GQR0 + index]) {
            set_error(error, error_capacity, "%s", "inconsistent full-state GQR payload");
            return false;
        }
    }
    if (
        state->reservation_valid &&
        (
            (state->reservation_address & 3u) != 0u ||
            !mapped_pc(state->reservation_address)
        )
    ) {
        set_error(error, error_capacity, "%s", "invalid full-state reservation");
        return false;
    }
    return true;
}

static void commit_architecture(
    CPUState* cpu,
    const FullArchitecture* state,
    const u8* ram,
    const u8* mem2
) {
    memcpy(cpu->gpr, state->gpr, sizeof(cpu->gpr));
    for (u32 index = 0u; index < 32u; ++index) {
        memcpy(&cpu->fpr[index], &state->fpr_bits[index], sizeof(u64));
        memcpy(&cpu->ps1[index], &state->ps1_bits[index], sizeof(u64));
    }
    cpu->pc = state->pc;
    cpu->lr = state->lr;
    cpu->ctr = state->ctr;
    cpu->cr = state->cr;
    cpu->xer = state->xer;
    cpu->fpscr = state->fpscr;
    cpu->msr = state->msr;
    cpu->srr0 = state->srr0;
    cpu->srr1 = state->srr1;
    cpu->ear = state->ear;
    cpu->hid2 = state->hid2;
    cpu->timebase = state->timebase;
    cpu->timebase_cycle_remainder = (u8)state->timebase_cycle_remainder;
    cpu->core_cycles = state->core_ticks;
    cpu->decrementer_armed = (state->decrementer & 0x80000000u) == 0u;
    cpu->decrementer_deadline =
        cpu->decrementer_armed
            ? state->timebase + state->decrementer
            : 0u;
    cpu->decrementer_deadline_core_cycles =
        cpu->decrementer_armed
            ? state->decrementer_deadline_core_ticks
            : 0u;
    cpu->decrementer_interrupt_count = 0u;
    memcpy(cpu->sr, state->sr, sizeof(cpu->sr));
    memcpy(cpu->gqr, state->gqr, sizeof(cpu->gqr));
    memcpy(cpu->spr, state->spr, sizeof(cpu->spr));
    cpu->exception = state->exception;
    cpu->program_exception = 0u;
    cpu->downcount = 0;
    cpu->reservation_address = state->reservation_address;
    cpu->reservation_valid = state->reservation_valid;
    memcpy(cpu->ram, ram, cpu->ram_size);
    memcpy(cpu->mem2, mem2, cpu->mem2_size);
    cpu->stop_reason = PROTECTOR_STOP_NONE;
    cpu->stop_pc = 0u;
    cpu->stop_instruction = 0u;
    cpu->stop_address = 0u;
    cpu->memory_read_count = 0u;
    cpu->memory_write_count = 0u;
    cpu->cache_operation_count = 0u;
    cpu->translated_dispatch_count = 0u;
    cpu->presented_frame_count = 0u;
    cpu->atomic_success_count = 0u;
    cpu->atomic_failure_count = 0u;
    cpu->fpu_unavailable_count = 0u;
}

bool protector_load_full_state(
    CPUState* cpu,
    const char* path,
    ProtectorFullStateMetadata* metadata,
    char* error,
    size_t error_capacity
) {
    if (
        !cpu || !path || !metadata || !cpu->ram || !cpu->mem2 ||
        cpu->ram_size != GC_MAIN_RAM_SIZE || cpu->mem2_size != WII_MEM2_SIZE
    ) {
        set_error(error, error_capacity, "%s", "invalid full-state arguments");
        return false;
    }
    FILE* input = fopen(path, "rb");
    if (!input) {
        set_error(error, error_capacity, "cannot open full state: %s", path);
        return false;
    }
    u8 header[FULL_STATE_HEADER_SIZE];
    u8* cpu_payload = NULL;
    u8* ram = NULL;
    u8* mem2 = NULL;
    bool ok = false;
    if (fread(header, 1u, sizeof(header), input) != sizeof(header)) {
        set_error(error, error_capacity, "%s", "truncated full-state header");
        goto cleanup;
    }
    if (
        memcmp(header, FULL_STATE_MAGIC, sizeof(FULL_STATE_MAGIC)) != 0 ||
        read_u32_be(header + 8u) != 1u ||
        read_u32_be(header + 12u) != FULL_STATE_HEADER_SIZE ||
        read_u32_be(header + 16u) != FULL_STATE_CPU_SIZE ||
        read_u32_be(header + 20u) != GC_MAIN_RAM_SIZE ||
        read_u32_be(header + 24u) != WII_MEM2_SIZE ||
        memcmp(header + 28u, "RBNEG9\0\0", 8u) != 0 ||
        memchr(header + 48u, '\0', 32u) == NULL
    ) {
        set_error(error, error_capacity, "%s", "invalid full-state header");
        goto cleanup;
    }
    cpu_payload = (u8*)malloc(FULL_STATE_CPU_SIZE);
    ram = (u8*)malloc(GC_MAIN_RAM_SIZE);
    mem2 = (u8*)malloc(WII_MEM2_SIZE);
    if (!cpu_payload || !ram || !mem2) {
        set_error(error, error_capacity, "%s", "cannot allocate full-state staging memory");
        goto cleanup;
    }
    if (
        fread(cpu_payload, 1u, FULL_STATE_CPU_SIZE, input) !=
            FULL_STATE_CPU_SIZE ||
        fread(ram, 1u, GC_MAIN_RAM_SIZE, input) != GC_MAIN_RAM_SIZE ||
        fread(mem2, 1u, WII_MEM2_SIZE, input) != WII_MEM2_SIZE ||
        fgetc(input) != EOF
    ) {
        set_error(error, error_capacity, "%s", "full-state section sizes differ");
        goto cleanup;
    }
    if (
        !digest_matches(cpu_payload, FULL_STATE_CPU_SIZE, header + 116u) ||
        !digest_matches(ram, GC_MAIN_RAM_SIZE, header + 148u) ||
        !digest_matches(mem2, WII_MEM2_SIZE, header + 180u)
    ) {
        set_error(error, error_capacity, "%s", "full-state section hash differs");
        goto cleanup;
    }
    FullArchitecture architecture;
    if (
        !parse_architecture(
            cpu_payload, &architecture, error, error_capacity
        ) ||
        read_u32_be(header + 44u) != architecture.pc
    ) {
        if (error && error_capacity > 0u && error[0] == '\0') {
            set_error(error, error_capacity, "%s", "full-state saved PC differs");
        }
        goto cleanup;
    }
    ProtectorFullStateMetadata staged = {0};
    memcpy(staged.game_id, header + 28u, 8u);
    memcpy(staged.anchor, header + 48u, 32u);
    staged.checkpoint = read_u32_be(header + 36u);
    staged.next_input_sample = read_u32_be(header + 40u);
    staged.saved_pc = read_u32_be(header + 44u);
    staged.source_core_ticks = architecture.core_ticks;
    memcpy(staged.source_state_sha256, header + 84u, 32u);
    memcpy(staged.cpu_sha256, header + 116u, 32u);
    memcpy(staged.mem1_sha256, header + 148u, 32u);
    memcpy(staged.mem2_sha256, header + 180u, 32u);
    commit_architecture(cpu, &architecture, ram, mem2);
    *metadata = staged;
    ok = true;

cleanup:
    free(cpu_payload);
    free(ram);
    free(mem2);
    (void)fclose(input);
    return ok;
}
