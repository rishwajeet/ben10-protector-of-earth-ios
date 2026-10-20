#ifndef PROTECTOR_GUEST_PACER_H
#define PROTECTOR_GUEST_PACER_H

#include "protector/cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PROTECTOR_WII_TIMEBASE_HZ 60750000u

/* Host-only throttle. It never changes the guest clock, drops a simulation
 * update, or determines how many samples the DSP must generate. */
typedef struct ProtectorGuestPacer {
    bool anchored;
    u64 anchor_ticks;
    double anchor_host_seconds;
    u64 last_ticks;
    double last_host_seconds;
    u64 late_rebases;
} ProtectorGuestPacer;

void protector_guest_pacer_reset(ProtectorGuestPacer* pacer);
/* Call with monotonic host time, then wait interruptibly until the returned
 * deadline. Repeated calls for the same boundary are safe. Host suspension
 * resets the anchor; >100 ms host stalls rebase instead of building an
 * unbounded fast-forward backlog. Returns false for invalid clock input. */
bool protector_guest_pacer_deadline(ProtectorGuestPacer* pacer,
                                   u64 guest_ticks, double host_seconds,
                                   double* deadline);

#ifdef __cplusplus
}
#endif
#endif
