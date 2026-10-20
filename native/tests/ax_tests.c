#include "protector/ax.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

static int failures = 0;

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(                                                          \
                stderr,                                                       \
                "check failed at %s:%d: %s\n",                              \
                __FILE__,                                                      \
                __LINE__,                                                      \
                #condition                                                     \
            );                                                                 \
            failures++;                                                        \
        }                                                                      \
    } while (0)

static void write_pb_identity(CPUState* cpu, u32 base) {
    for (u32 index = 0u; index < PROTECTOR_AX_VOICE_COUNT; ++index) {
        const u32 pb = base + index * PROTECTOR_AX_PB_SIZE;
        mem_write32(
            cpu,
            pb,
            index + 1u < PROTECTOR_AX_VOICE_COUNT
                ? pb + PROTECTOR_AX_PB_SIZE
                : 0u
        );
        mem_write32(cpu, pb + 4u, pb);
    }
}

static void test_pool_discovery(void) {
    CPUState cpu;
    CHECK(protector_cpu_init(&cpu));
    const u32 expected = GC_RAM_BASE + 0x12000u;
    write_pb_identity(&cpu, expected);
    u32 found = 0u;
    CHECK(protector_ax_find_dsp_pb_pool(
        &cpu, expected - 0x120u, &found
    ));
    CHECK(found == expected);
    protector_cpu_destroy(&cpu);
}

static void test_src_fraction_accumulates(void) {
    u16 fraction = 0u;
    CHECK(
        protector_ax_source_sample_count(
            0u, 0x000160C9u, &fraction, 96u
        ) == 132u
    );
    CHECK(fraction == 19296u);
    CHECK(
        protector_ax_source_sample_count(
            0u, 0x000160C9u, &fraction, 96u
        ) == 132u
    );
    CHECK(fraction == 38592u);
    fraction = 123u;
    CHECK(
        protector_ax_source_sample_count(
            2u, 0x000160C9u, &fraction, 96u
        ) == 96u
    );
    CHECK(fraction == 123u);
}

static void test_adpcm_headers_are_skipped(void) {
    bool running = true;
    const u32 start = 0x02341802u;
    const u32 current = protector_ax_advance_sample_address(
        0u,
        1u,
        start,
        0x023617FEu,
        start,
        132u,
        &running
    );
    CHECK(running);
    CHECK(current == start + 150u);
}

static void test_pcm_end_stops_or_loops(void) {
    bool running = true;
    CHECK(
        protector_ax_advance_sample_address(
            10u, 0u, 100u, 103u, 102u, 3u, &running
        ) == 100u
    );
    CHECK(!running);
    running = true;
    CHECK(
        protector_ax_advance_sample_address(
            25u, 1u, 100u, 103u, 102u, 3u, &running
        ) == 101u
    );
    CHECK(running);
}

int main(void) {
    test_pool_discovery();
    test_src_fraction_accumulates();
    test_adpcm_headers_are_skipped();
    test_pcm_end_stops_or_loops();
    if (failures != 0) {
        fprintf(stderr, "%d AX tests failed\n", failures);
        return EXIT_FAILURE;
    }
    puts("AX tests passed");
    return EXIT_SUCCESS;
}
