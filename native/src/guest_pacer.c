#include "protector/guest_pacer.h"
#include <math.h>

void protector_guest_pacer_reset(ProtectorGuestPacer* pacer) {
    if (pacer) pacer->anchored = false;
}

bool protector_guest_pacer_deadline(ProtectorGuestPacer* pacer,
                                   u64 guest_ticks, double host_seconds,
                                   double* deadline) {
    if (!pacer || !deadline || !isfinite(host_seconds) || host_seconds < 0.0)
        return false;
    if (pacer->anchored && (guest_ticks < pacer->last_ticks ||
                           host_seconds < pacer->last_host_seconds)) return false;
    if (!pacer->anchored) {
        pacer->anchored = true;
        pacer->anchor_ticks = guest_ticks;
        pacer->anchor_host_seconds = host_seconds;
    }
    double target = pacer->anchor_host_seconds +
        (double)(guest_ticks - pacer->anchor_ticks) / PROTECTOR_WII_TIMEBASE_HZ;
    if (host_seconds - target > 0.100) {
        ++pacer->late_rebases;
        pacer->anchor_ticks = guest_ticks;
        pacer->anchor_host_seconds = host_seconds;
        target = host_seconds;
    }
    pacer->last_ticks = guest_ticks;
    pacer->last_host_seconds = host_seconds;
    *deadline = target;
    return true;
}
