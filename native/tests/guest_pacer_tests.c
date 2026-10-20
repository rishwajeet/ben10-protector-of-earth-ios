#include "protector/guest_pacer.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static void near(double actual, double expected) {
    assert(fabs(actual - expected) < 1e-8);
}

int main(void) {
    ProtectorGuestPacer pacer = {0};
    double deadline = -1;
    const u64 origin = UINT64_C(1) << 45;
    assert(protector_guest_pacer_deadline(&pacer, origin, 100, &deadline));
    near(deadline, 100);
    // A 30 Hz title stays at 30 Hz. Accumulated deadlines do not add render
    // cost or wait overshoot to every subsequent frame.
    for (u64 frame = 1; frame <= 3000; ++frame) {
        const double expected = 100.0 + (double)frame / 30.0;
        assert(protector_guest_pacer_deadline(&pacer,
            origin + frame * (PROTECTOR_WII_TIMEBASE_HZ / 30),
            expected - 0.015, &deadline));
        near(deadline, expected);
        assert(protector_guest_pacer_deadline(&pacer,
            origin + frame * (PROTECTOR_WII_TIMEBASE_HZ / 30),
            expected + 0.0003, &deadline));
        near(deadline, expected);
    }
    assert(pacer.late_rebases == 0);
    // Other guest rates and irregular loading intervals are not forced to 30.
    protector_guest_pacer_reset(&pacer);
    assert(protector_guest_pacer_deadline(&pacer, 0, 250, &deadline));
    assert(protector_guest_pacer_deadline(&pacer,
        PROTECTOR_WII_TIMEBASE_HZ / 60, 250.001, &deadline));
    near(deadline, 250.0 + 1.0 / 60.0);
    assert(protector_guest_pacer_deadline(&pacer,
        PROTECTOR_WII_TIMEBASE_HZ * 3 / 10, 250.02, &deadline));
    near(deadline, 250.3);
    // A slow host runs late but never accumulates seconds of catch-up work.
    assert(protector_guest_pacer_deadline(&pacer,
        PROTECTOR_WII_TIMEBASE_HZ / 2, 260, &deadline));
    near(deadline, 260);
    assert(pacer.late_rebases == 1);
    assert(protector_guest_pacer_deadline(&pacer,
        PROTECTOR_WII_TIMEBASE_HZ, 260.05, &deadline));
    near(deadline, 260.5);
    // Resume anchors at the current boundary, without replaying paused time.
    protector_guest_pacer_reset(&pacer);
    assert(protector_guest_pacer_deadline(&pacer,
        PROTECTOR_WII_TIMEBASE_HZ, 1000, &deadline));
    near(deadline, 1000);
    assert(pacer.late_rebases == 1);
    assert(protector_guest_pacer_deadline(&pacer,
        PROTECTOR_WII_TIMEBASE_HZ * 2u, 1000.5, &deadline));
    near(deadline, 1001);
    ProtectorGuestPacer before = pacer;
    deadline = -1;
    assert(!protector_guest_pacer_deadline(&pacer, 0, 1000, &deadline));
    assert(!protector_guest_pacer_deadline(&pacer,
        PROTECTOR_WII_TIMEBASE_HZ, 1000.6, &deadline));
    assert(!protector_guest_pacer_deadline(&pacer,
        PROTECTOR_WII_TIMEBASE_HZ * 2u, 1000.4, &deadline));
    assert(!protector_guest_pacer_deadline(&pacer, 0, NAN, &deadline));
    assert(!protector_guest_pacer_deadline(&pacer, 0, INFINITY, &deadline));
    assert(!protector_guest_pacer_deadline(&pacer, 0, -1, &deadline));
    assert(!protector_guest_pacer_deadline(NULL, 0, 0, &deadline));
    assert(!protector_guest_pacer_deadline(&pacer, 0, 0, NULL));
    assert(memcmp(&before, &pacer, sizeof(pacer)) == 0);
    assert(deadline == -1);
    protector_guest_pacer_reset(NULL);
    puts("Guest-clock pacing tests passed");
    return 0;
}
