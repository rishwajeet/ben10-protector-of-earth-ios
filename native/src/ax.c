#include "protector/ax.h"

#include <stddef.h>

#define AX_PB_NEXT_OFFSET 0x00u
#define AX_PB_CURRENT_SELF_OFFSET 0x04u
#define AX_PB_SRC_SELECT_OFFSET 0x08u
#define AX_PB_STATE_OFFSET 0x10u
#define AX_PB_ADDR_OFFSET 0x6Eu
#define AX_PB_LOOP_FLAG_OFFSET (AX_PB_ADDR_OFFSET + 0x00u)
#define AX_PB_FORMAT_OFFSET (AX_PB_ADDR_OFFSET + 0x02u)
#define AX_PB_LOOP_ADDRESS_OFFSET (AX_PB_ADDR_OFFSET + 0x04u)
#define AX_PB_END_ADDRESS_OFFSET (AX_PB_ADDR_OFFSET + 0x08u)
#define AX_PB_CURRENT_ADDRESS_OFFSET (AX_PB_ADDR_OFFSET + 0x0Cu)
#define AX_PB_SRC_OFFSET 0xA6u
#define AX_PB_SRC_RATIO_OFFSET (AX_PB_SRC_OFFSET + 0x00u)
#define AX_PB_SRC_FRACTION_OFFSET (AX_PB_SRC_OFFSET + 0x04u)

#define AX_VOICE_STOP 0u
#define AX_VOICE_RUN 1u
#define AX_SAMPLE_FORMAT_DSP_ADPCM 0u
#define AX_SAMPLE_FORMAT_PCM_S16 10u
#define AX_SAMPLE_FORMAT_PCM_S8 25u
#define AX_SRC_TYPE_NEAREST 2u

static bool guest_main_ram_range_valid(
    const CPUState* cpu, u32 address, u32 length
) {
    if (!cpu || address < GC_RAM_BASE || length > cpu->ram_size) {
        return false;
    }
    const u32 offset = address - GC_RAM_BASE;
    return offset <= cpu->ram_size - length;
}

static bool ax_pb_pool_matches(CPUState* cpu, u32 base) {
    const u32 span = PROTECTOR_AX_VOICE_COUNT * PROTECTOR_AX_PB_SIZE;
    if (!guest_main_ram_range_valid(cpu, base, span)) {
        return false;
    }
    const u32 probe_indices[] = {0u, 1u, 2u, 95u};
    for (
        size_t probe = 0u;
        probe < sizeof(probe_indices) / sizeof(probe_indices[0]);
        ++probe
    ) {
        const u32 index = probe_indices[probe];
        const u32 pb = base + index * PROTECTOR_AX_PB_SIZE;
        if (mem_read32(cpu, pb + AX_PB_CURRENT_SELF_OFFSET) != pb) {
            return false;
        }
        const u32 expected_next =
            index + 1u < PROTECTOR_AX_VOICE_COUNT
                ? pb + PROTECTOR_AX_PB_SIZE
                : 0u;
        if (mem_read32(cpu, pb + AX_PB_NEXT_OFFSET) != expected_next) {
            return false;
        }
    }
    return cpu->stop_reason == PROTECTOR_STOP_NONE;
}

static bool find_pool_in_range(
    CPUState* cpu, u32 start, u32 end, u32* pool_address
) {
    const u32 span = PROTECTOR_AX_VOICE_COUNT * PROTECTOR_AX_PB_SIZE;
    if (end < start || end - start < span) {
        return false;
    }
    u32 candidate = (start + 31u) & ~31u;
    const u32 last = end - span;
    while (candidate <= last) {
        if (ax_pb_pool_matches(cpu, candidate)) {
            *pool_address = candidate;
            return true;
        }
        if (candidate > UINT32_MAX - 32u) {
            break;
        }
        candidate += 32u;
    }
    return false;
}

bool protector_ax_find_dsp_pb_pool(
    CPUState* cpu, u32 address_hint, u32* pool_address
) {
    if (!cpu || !pool_address || !cpu->ram) {
        return false;
    }
    const u32 ram_end = GC_RAM_BASE + cpu->ram_size;
    if (address_hint >= GC_RAM_BASE && address_hint < ram_end) {
        const u32 window_end =
            address_hint <= ram_end - 0x200000u
                ? address_hint + 0x200000u
                : ram_end;
        if (find_pool_in_range(
                cpu, address_hint, window_end, pool_address
            )) {
            return true;
        }
    }
    return find_pool_in_range(
        cpu, GC_RAM_BASE, ram_end, pool_address
    );
}

u32 protector_ax_source_sample_count(
    u16 src_select,
    u32 ratio,
    u16* current_fraction,
    u16 output_samples
) {
    if (!current_fraction) {
        return 0u;
    }
    if (src_select == AX_SRC_TYPE_NEAREST) {
        return output_samples;
    }
    const u64 position =
        (u64)*current_fraction + (u64)ratio * output_samples;
    *current_fraction = (u16)position;
    return (u32)(position >> 16u);
}

static u32 advance_adpcm_address(
    u16 loop_flag,
    u32 loop_address,
    u32 end_address,
    u32 current_address,
    u32 source_samples,
    bool* running
) {
    for (u32 sample = 0u; sample < source_samples; ++sample) {
        u32 step_size = 2u;
        current_address++;
        if (
            (end_address & 0xFu) == 0u &&
            current_address == end_address
        ) {
            current_address = loop_address + 1u;
        } else if (
            (end_address & 0xFu) == 1u &&
            current_address == end_address - 1u
        ) {
            current_address = loop_address;
        } else if ((current_address & 0xFu) == 0u) {
            current_address += 2u;
            step_size += 2u;
        }
        if (current_address == end_address + step_size - 1u) {
            current_address = loop_address;
            if (loop_flag == 0u) {
                *running = false;
                break;
            }
        }
    }
    return current_address;
}

u32 protector_ax_advance_sample_address(
    u16 format,
    u16 loop_flag,
    u32 loop_address,
    u32 end_address,
    u32 current_address,
    u32 source_samples,
    bool* running
) {
    if (!running || !*running || source_samples == 0u) {
        return current_address;
    }
    if (format == AX_SAMPLE_FORMAT_DSP_ADPCM) {
        return advance_adpcm_address(
            loop_flag,
            loop_address,
            end_address,
            current_address,
            source_samples,
            running
        );
    }
    if (
        format != AX_SAMPLE_FORMAT_PCM_S16 &&
        format != AX_SAMPLE_FORMAT_PCM_S8
    ) {
        return current_address;
    }
    for (u32 sample = 0u; sample < source_samples; ++sample) {
        current_address++;
        if (current_address == end_address + 1u) {
            current_address = loop_address;
            if (loop_flag == 0u) {
                *running = false;
                break;
            }
        }
    }
    return current_address;
}

u32 protector_ax_process_frame(
    CPUState* cpu,
    u32 dsp_pb_pool,
    u16 output_samples
) {
    if (
        !cpu || output_samples == 0u ||
        !guest_main_ram_range_valid(
            cpu,
            dsp_pb_pool,
            PROTECTOR_AX_VOICE_COUNT * PROTECTOR_AX_PB_SIZE
        )
    ) {
        return 0u;
    }
    u32 running_voice_count = 0u;
    for (u32 index = 0u; index < PROTECTOR_AX_VOICE_COUNT; ++index) {
        const u32 pb = dsp_pb_pool + index * PROTECTOR_AX_PB_SIZE;
        if (mem_read16(cpu, pb + AX_PB_STATE_OFFSET) != AX_VOICE_RUN) {
            continue;
        }
        running_voice_count++;
        u16 fraction = mem_read16(cpu, pb + AX_PB_SRC_FRACTION_OFFSET);
        const u32 source_samples = protector_ax_source_sample_count(
            mem_read16(cpu, pb + AX_PB_SRC_SELECT_OFFSET),
            mem_read32(cpu, pb + AX_PB_SRC_RATIO_OFFSET),
            &fraction,
            output_samples
        );
        bool running = true;
        const u32 current = protector_ax_advance_sample_address(
            mem_read16(cpu, pb + AX_PB_FORMAT_OFFSET),
            mem_read16(cpu, pb + AX_PB_LOOP_FLAG_OFFSET),
            mem_read32(cpu, pb + AX_PB_LOOP_ADDRESS_OFFSET),
            mem_read32(cpu, pb + AX_PB_END_ADDRESS_OFFSET),
            mem_read32(cpu, pb + AX_PB_CURRENT_ADDRESS_OFFSET),
            source_samples,
            &running
        );
        mem_write16(cpu, pb + AX_PB_SRC_FRACTION_OFFSET, fraction);
        mem_write32(cpu, pb + AX_PB_CURRENT_ADDRESS_OFFSET, current);
        if (!running) {
            mem_write16(cpu, pb + AX_PB_STATE_OFFSET, AX_VOICE_STOP);
        }
        if (cpu->stop_reason != PROTECTOR_STOP_NONE) {
            return running_voice_count;
        }
    }
    return running_voice_count;
}
