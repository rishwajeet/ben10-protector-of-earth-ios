// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later
// AXWii command arithmetic adapted from Dolphin AX.cpp, AX.h and AXWii.cpp,
// e6f3ae17627e4344da95b13424af5baf4c892b08. Bounded parser, physical memory
// access, title admission and synchronous host-output API added locally.
#include "protector/ax_engine.h"

#include <stdio.h>
#include <string.h>

static s32 signed32(u32 n) { return n <= INT32_MAX ? (s32)n : (s32)((s64)n - 0x100000000LL); }
static s16 signed16(u16 n) { return (s16)(n <= INT16_MAX ? (s32)n : (s32)n - 65536); }
static s64 shr(s64 n, u32 bits) { return n >= 0 ? n >> bits : -1 - ((-1 - n) >> bits); }
static s16 clamp16(s64 n) { return (s16)(n < INT16_MIN ? INT16_MIN : n > INT16_MAX ? INT16_MAX : n); }
static s32 add32(s32 a, s32 b) { return signed32((u32)a + (u32)b); }
static u16 read16(const u8* p) { return ((u16)p[0] << 8) | p[1]; }
static u32 read32(const u8* p) { return ((u32)read16(p) << 16) | read16(p + 2); }
static void write16(u8* p, u16 n) { p[0] = n >> 8; p[1] = (u8)n; }
static void write32(u8* p, u32 n) { write16(p, (u16)(n >> 16)); write16(p + 2, (u16)n); }
static u32 address(const u16* words) { return ((u32)words[0] << 16) | words[1]; }

static bool fail(ProtectorAXEngine* e, const char* message, u32 where) {
    (void)snprintf(e->error, sizeof(e->error), "%s at 0x%08X", message, where);
    e->error_address = where;
    return false;
}

static u8* region(ProtectorAXEngine* e, CPUState* cpu, u32 addr, u32 length) {
    if ((addr >> 30) == 1u) {
        (void)fail(e, "invalid AX address alias", addr);
        return NULL;
    }
    const u32 physical = addr & 0x3fffffffu;
    if (cpu->ram && length <= cpu->ram_size && physical <= cpu->ram_size - length)
        return cpu->ram + physical;
    if (cpu->mem2 && physical >= 0x10000000u && length <= cpu->mem2_size &&
        physical - 0x10000000u <= cpu->mem2_size - length)
        return cpu->mem2 + physical - 0x10000000u;
    (void)fail(e, "unmapped AX memory", addr);
    return NULL;
}

void protector_ax_engine_init(ProtectorAXEngine* e,
    const u8* bytes, size_t count, ProtectorAXPCMConsumer consumer, void* context) {
    if (!e) return;
    memset(e, 0, sizeof(*e));
    e->main_volume = 32768;
    for (u32 i = 0; i < 3; ++i) e->aux_volume[i] = 32768;
    if (bytes && count == sizeof(e->coefficients)) {
        for (u32 i = 0; i < PROTECTOR_AX_AUDIO_COEFFICIENTS; ++i)
            e->coefficients[i] = signed16(read16(bytes + i * 2));
        e->coefficients_valid = true;
    }
    e->consumer = consumer;
    e->consumer_context = context;
}

bool protector_ax_engine_configure(ProtectorAXEngine* e, CPUState* cpu, u32 task) {
    if (!e || !cpu) return false;
    const u8* header = region(e, cpu, task, 0x38);
    if (!header) return false;
    const u32 ptr = read32(header + 12), length = read32(header + 16);
    if (!length || length > 65536) return fail(e, "invalid AX ucode length", length);
    const u8* ucode = region(e, cpu, ptr, length);
    if (!ucode) return false;
    u32 hash = 0;
    for (u32 i = 0; i < length; ++i) {
        hash ^= ucode[i];
        hash = (hash << 3) | (hash >> 29);
    }
    e->ucode_hash = hash;
    e->configured = hash == 0x347112bau;
    if (!e->configured) return fail(e, "unsupported AX ucode", hash);
    return true;
}

/* Match the upstream single-precision ramp, including truncation each sample. */
static void volume_ramp(u16 result[96], u16 from, u16 to) {
    float value = from;
    const float delta = ((float)to - from) / 96.0f;
    for (u32 i = 0; i < 96; ++i) { value += delta; result[i] = (u16)value; }
}

static bool process_chain(ProtectorAXEngine* e, CPUState* cpu, u32 pb) {
    u32 visited[96];
    u32 count = 0;
    while (pb) {
        if ((pb >> 30) == 1u) return fail(e, "invalid AX PB address alias", pb);
        pb = (pb & 0x3fffffffu) | GC_RAM_BASE;
        if (count == 96) return fail(e, "AX voice chain exceeds 96 nodes", pb);
        for (u32 i = 0; i < count; ++i)
            if (visited[i] == pb) return fail(e, "cyclic AX voice chain", pb);
        visited[count++] = pb;
        const u8* data = region(e, cpu, pb, 0x140);
        if (!data) return false;
        const u32 next = read32(data);
        const bool running = read16(data + 0x10) == 1;
        ProtectorAXAudioResult result = protector_ax_process_pb(cpu, pb, e->ucode_hash,
            e->coefficients_valid ? e->coefficients : NULL,
            e->coefficients_valid ? PROTECTOR_AX_AUDIO_COEFFICIENTS : 0, e->buses);
        if (result != PROTECTOR_AX_AUDIO_OK)
            return fail(e, protector_ax_audio_result_name(result), pb);
        if (running) e->voices_processed++;
        pb = next;
    }
    return true;
}

bool protector_ax_engine_execute(ProtectorAXEngine* e, CPUState* cpu,
    u32 command_address, u16 word_count) {
    if (!e || !cpu) return false;
    if (e->error[0]) return false;
    if (!e->configured) return fail(e, "AX task is not configured", command_address);
    if (!word_count || word_count > 512) return fail(e, "invalid AX command length", word_count);
    const u8* source = region(e, cpu, command_address, word_count * 2u);
    if (!source) return false;
    u16 words[512];
    for (u32 i = 0; i < word_count; ++i) words[i] = read16(source + i * 2);
    static const u8 operands[] = {2, 2, 2, 2, 2, 5, 5, 5, 13, 13, 4, 5, 5, 8, 0};
    u32 index = 0;
    while (index < word_count) {
        const u16 cmd = words[index++];
        if (cmd >= sizeof(operands)) return fail(e, "unknown AX command", cmd);
        const u32 size = operands[cmd];
        if (size > word_count - index) return fail(e, "truncated AX command", cmd);
        const u16* args = words + index;
        index += size;
        e->command_mask |= 1u << cmd;
        if (cmd == 14) { e->command_lists++; return true; }
        if (cmd == 0) {
            const u8* init = region(e, cpu, address(args), 20 * 6);
            if (!init) return false;
            for (u32 bus = 0; bus < 20; ++bus) {
                const s32 value = signed32(read32(init + bus * 6));
                const s16 delta = signed16(read16(init + bus * 6 + 4));
                const u32 n = bus < 12 ? 96 : 18;
                for (u32 i = 0; i < n; ++i)
                    e->buses[bus][i] = value ? add32(value, (s32)i * delta) : 0;
            }
        } else if (cmd >= 1 && cmd <= 3) {
            const u8* samples = region(e, cpu, address(args), cmd == 3 ? 768 : 384);
            if (!samples) return false;
            for (u32 i = 0; i < 96; ++i) {
                const s32 left = signed32(read32(samples + i * 4));
                const s32 right = cmd == 3 ? signed32(read32(samples + 384 + i * 4)) : left;
                e->buses[0][i] = add32(e->buses[0][i], cmd == 2 ? signed32(0u - (u32)left) : left);
                e->buses[1][i] = add32(e->buses[1][i], cmd >= 2 ? signed32(0u - (u32)right) : right);
            }
        } else if (cmd == 4) {
            if (!process_chain(e, cpu, address(args))) return false;
        } else if (cmd >= 5 && cmd <= 7) {
            const u32 aux = cmd - 5;
            u16 ramp[96]; volume_ramp(ramp, e->aux_volume[aux], args[0]);
            e->aux_volume[aux] = args[0];
            const u32 write_addr = address(args + 1), read_addr = address(args + 3);
            if (write_addr) {
                u8* dest = region(e, cpu, write_addr, 1152);
                if (!dest) return false;
                for (u32 bus = 0; bus < 3; ++bus)
                    for (u32 i = 0; i < 96; ++i)
                        write32(dest + bus * 384 + i * 4, (u32)e->buses[3 + aux * 3 + bus][i]);
            }
            const u8* samples = region(e, cpu, read_addr, 1152);
            if (!samples) return false;
            for (u32 bus = 0; bus < 3; ++bus)
                for (u32 i = 0; i < 96; ++i)
                    e->buses[bus][i] = add32(e->buses[bus][i], signed32((u32)shr(
                        (s64)signed32(read32(samples + bus * 384 + i * 4)) * ramp[i], 15)));
        } else if (cmd == 8 || cmd == 9) {
            const u32 aux = cmd - 8;
            const u32 first_bus = 3 + aux * 3;
            u8* aux_output = region(e, cpu, address(args + 1), 1152);
            u8* auxc_output = region(e, cpu, address(args + 3), 384);
            if (!aux_output || !auxc_output) return false;
            for (u32 bus = 0; bus < 3; ++bus)
                for (u32 i = 0; i < 96; ++i)
                    write32(aux_output + bus * 384 + i * 4, (u32)e->buses[first_bus + bus][i]);
            for (u32 i = 0; i < 96; ++i)
                write32(auxc_output + i * 4, (u32)e->buses[aux ? 11 : 10][i]);
            u16 ramp[96]; volume_ramp(ramp, e->aux_volume[aux], args[0]);
            e->aux_volume[aux] = args[0];
            const u32 destinations[4] = {0, 1, 2, 9};
            for (u32 input = 0; input < 4; ++input) {
                const u8* samples = region(e, cpu, address(args + 5 + input * 2), 384);
                if (!samples) return false;
                /* UPL uses AUX-left as scratch and leaves the fourth input in
                 * it; preserve that state for any later commands in the list. */
                for (u32 i = 0; i < 96; ++i)
                    e->buses[first_bus][i] = signed32(read32(samples + i * 4));
                for (u32 i = 0; i < 96; ++i)
                    e->buses[destinations[input]][i] = add32(e->buses[destinations[input]][i],
                        signed32((u32)shr((s64)e->buses[first_bus][i] * ramp[i], 15)));
            }
        } else if (cmd == 10) {
            bool triggered = false;
            for (u32 i = 0; i < 96; ++i)
                for (u32 bus = 0; bus < 2; ++bus) {
                    const s64 n = e->buses[bus][i];
                    if ((n < 0 ? -n : n) > args[0]) triggered = true;
                }
            u32 offset;
            if (triggered) { offset = e->compressor_position * 192u; e->compressor_position = args[1]; }
            else if (e->compressor_position) { --e->compressor_position; offset = (11u + e->compressor_position) * 192u; }
            else continue;
            const u32 table = address(args + 2);
            if (table > UINT32_MAX - offset) return fail(e, "AX compressor table overflow", table);
            const u8* ramp = region(e, cpu, table + offset, 192);
            if (!ramp) return false;
            for (u32 bus = 0; bus < 2; ++bus)
                for (u32 i = 0; i < 96; ++i)
                    e->buses[bus][i] = signed32((u32)shr((s64)e->buses[bus][i] * read16(ramp + i * 2), 15));
        } else if (cmd == 11 || cmd == 12) {
            u8* surround = region(e, cpu, address(args + 1), cmd == 12 ? 768 : 384);
            u8* lr = region(e, cpu, address(args + 3), 384);
            if (!surround || !lr) return false;
            u16 ramp[96]; volume_ramp(ramp, e->main_volume, args[0]);
            e->main_volume = args[0];
            s16 pcm[192];
            for (u32 i = 0; i < 96; ++i) {
                write32(surround + i * 4, (u32)e->buses[2][i]);
                if (cmd == 12) write32(surround + 384 + i * 4, (u32)e->buses[9][i]);
                const s16 left = clamp16(shr((s64)e->buses[0][i] * ramp[i], 15));
                const s16 right = clamp16(shr((s64)e->buses[1][i] * ramp[i], 15));
                e->buses[0][i] = left; e->buses[1][i] = right;
                write16(lr + i * 4, (u16)right); write16(lr + i * 4 + 2, (u16)left);
                pcm[i * 2] = left; pcm[i * 2 + 1] = right;
            }
            if (e->consumer && !e->consumer(e->consumer_context, pcm, 96))
                return fail(e, "AX PCM consumer failed", command_address);
            e->output_frames += 96;
        } else if (cmd == 13) {
            for (u32 remote = 0; remote < 4; ++remote) {
                u8* dest = region(e, cpu, address(args + remote * 2), 36);
                if (!dest) return false;
                for (u32 i = 0; i < 18; ++i) write16(dest + i * 2, (u16)clamp16(e->buses[12 + remote * 2][i]));
            }
        }
    }
    return fail(e, "AX command list has no END", command_address);
}

bool protector_ax_engine_mail(ProtectorAXEngine* e, CPUState* cpu, u32 mail) {
    if (!e || !cpu || !e->configured) return false;
    if (e->pending_words) {
        const u16 count = e->pending_words;
        e->pending_words = 0;
        return protector_ax_engine_execute(e, cpu, mail, count);
    }
    if ((mail & 0xffff0000u) == 0xbabe0000u) {
        const u16 count = (u16)mail;
        if (!count || count > 512) return fail(e, "invalid AX mail command length", count);
        e->pending_words = count;
        return true;
    }
    /* DSP task-control mails belong to the task scheduler, not this decoder. */
    if ((mail & 0xffff0000u) == 0xcdd10000u) return true;
    return fail(e, "unexpected AX mail", mail);
}
