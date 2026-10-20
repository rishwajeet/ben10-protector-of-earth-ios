#ifndef PROTECTOR_MOTION_CLOCK_H
#define PROTECTOR_MOTION_CLOCK_H

#include "protector/cpu.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Presentation only. Never advances a guest clock or predicts future state.
 * Each new pair is presented over its original guest interval, starting at
 * the current frame's host deadline: one original-frame of visual latency. */
bool protector_motion_interval(u64 previous_ticks, u64 current_ticks,
                               double previous_deadline, double current_deadline,
                               double* interval);
double protector_motion_fraction(double current_deadline, double interval,
                                  double host_seconds);
/* MTKView picks a divisor of display refresh. Request the lowest divisor
 * cadence at least 60 instead of silently rounding 60 down to 48 on 144 Hz. */
int protector_motion_display_rate(int maximum_frames_per_second);

/* Steady presentation cadence. A GPU that cannot hold 60 Hz produces a mix of
 * 16.7/25/33 ms intervals, which reads as stutter; a steady 30 Hz reads as
 * smooth. Drop to 30 after sustained over-budget GPU work or a serious thermal
 * state; return to 60 only after sustained headroom. Times are seconds. */
typedef struct {
    int rate;
    double over_since;
    double under_since;
} ProtectorPresentationPacing;

void protector_pacing_init(ProtectorPresentationPacing* pacing);
/* thermal_state follows NSProcessInfoThermalState (0 nominal .. 3 critical). */
int protector_pacing_update(ProtectorPresentationPacing* pacing, double now,
                            double gpu_seconds, int thermal_state);

#ifdef __cplusplus
}
#endif
#endif
