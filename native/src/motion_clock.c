#include "protector/motion_clock.h"
#include "protector/guest_pacer.h"
#include <math.h>

int protector_motion_display_rate(int maximum_frames_per_second) {
    if (maximum_frames_per_second <= 0) return 60;
    const int divisor = maximum_frames_per_second / 60;
    return maximum_frames_per_second / (divisor > 0 ? divisor : 1);
}

bool protector_motion_interval(u64 previous_ticks, u64 current_ticks,
                               double previous_deadline, double current_deadline,
                               double* interval) {
    if (!interval || current_ticks <= previous_ticks ||
        !isfinite(previous_deadline) || !isfinite(current_deadline) ||
        previous_deadline <= 0 || current_deadline <= previous_deadline) return false;
    const double guest_interval = (double)(current_ticks - previous_ticks) / PROTECTOR_WII_TIMEBASE_HZ;
    const double host_interval = current_deadline - previous_deadline;
    // A guest pause/loading step, or a host-pacer rebase, starts a new history.
    if (guest_interval < 1.0 / 240.0 || guest_interval > 0.1 ||
        fabs(host_interval - guest_interval) > 0.002) return false;
    *interval = guest_interval;
    return true;
}

double protector_motion_fraction(double current_deadline, double interval,
                                  double host_seconds) {
    if (!isfinite(current_deadline) || current_deadline <= 0 || !isfinite(interval) ||
        interval < 1.0 / 240.0 || interval > 0.1 || !isfinite(host_seconds) ||
        host_seconds < current_deadline) return 1.0;
    const double fraction = (host_seconds - current_deadline) / interval;
    return fraction >= 1.0 ? 1.0 : fraction;
}

enum { PACING_HIGH_RATE = 60, PACING_LOW_RATE = 30 };
static const double kPacingOverBudget = 0.85 / 60.0;   /* 14.2 ms */
static const double kPacingUnderBudget = 0.60 / 60.0;  /* 10.0 ms */
static const double kPacingDropAfter = 1.0;
static const double kPacingRiseAfter = 4.0;

void protector_pacing_init(ProtectorPresentationPacing* pacing) {
    if (!pacing) return;
    pacing->rate = PACING_HIGH_RATE;
    pacing->over_since = -1;
    pacing->under_since = -1;
}

int protector_pacing_update(ProtectorPresentationPacing* pacing, double now,
                            double gpu_seconds, int thermal_state) {
    if (!pacing) return PACING_HIGH_RATE;
    if (pacing->rate != PACING_HIGH_RATE && pacing->rate != PACING_LOW_RATE)
        protector_pacing_init(pacing);
    if (!isfinite(now)) return pacing->rate;
    if (thermal_state >= 2) {
        pacing->rate = PACING_LOW_RATE;
        pacing->over_since = pacing->under_since = -1;
        return pacing->rate;
    }
    if (!isfinite(gpu_seconds) || gpu_seconds <= 0) return pacing->rate;
    if (gpu_seconds > kPacingOverBudget) {
        pacing->under_since = -1;
        if (pacing->over_since < 0) pacing->over_since = now;
        if (pacing->rate == PACING_HIGH_RATE && now - pacing->over_since >= kPacingDropAfter) {
            pacing->rate = PACING_LOW_RATE;
            pacing->over_since = -1;
        }
    } else if (gpu_seconds < kPacingUnderBudget) {
        pacing->over_since = -1;
        if (pacing->under_since < 0) pacing->under_since = now;
        if (pacing->rate == PACING_LOW_RATE && now - pacing->under_since >= kPacingRiseAfter) {
            pacing->rate = PACING_HIGH_RATE;
            pacing->under_since = -1;
        }
    } else {
        pacing->over_since = pacing->under_since = -1;
    }
    return pacing->rate;
}
