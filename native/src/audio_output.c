#include "protector/audio_output.h"
#include <stdatomic.h>
#include <string.h>

// The guest thread produces audio in 3 ms chunks, just in time. A deep ring
// plus a primed cushion absorbs producer hiccups (largest observed phone
// deficit: 310 frames); after any underrun the reader re-primes, and short
// fades replace hard cuts so a rare gap is soft rather than a click.
#define AUDIO_FRAMES 16384u
#define AUDIO_PRIME_FRAMES 1024u
#define AUDIO_FADE_FRAMES 48u
static int16_t pcm[AUDIO_FRAMES * 2];
static _Atomic uint64_t read_position;
static _Atomic uint64_t write_position;
static _Atomic uint64_t dropped;
static _Atomic uint64_t underrun;
static _Atomic uint64_t pushed;
static _Atomic uint64_t pulled;
static _Atomic uint64_t epoch;
static uint64_t reader_epoch;
static bool reader_primed;      // reader thread only
static size_t reader_fade_in;   // reader thread only
static _Atomic bool enabled;

void protector_audio_output_reset(void) {
    atomic_store(&enabled, false);
    atomic_store(&read_position, 0);
    atomic_store(&write_position, 0);
    atomic_store(&dropped, 0);
    atomic_store(&underrun, 0);
    atomic_store(&pushed, 0);
    atomic_store(&pulled, 0);
    atomic_store(&epoch, 0);
    reader_epoch = 0;
    reader_primed = false;
    reader_fade_in = 0;
}
void protector_audio_output_enable(bool value) {
    atomic_store_explicit(&enabled, value, memory_order_release);
    if (!value) atomic_fetch_add_explicit(&epoch, 1, memory_order_release);
}
void protector_audio_output_push(const int16_t* input, size_t frames) {
    if (!input || !frames || !atomic_load_explicit(&enabled, memory_order_acquire)) return;
    uint64_t write = atomic_load_explicit(&write_position, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&read_position, memory_order_acquire);
    const size_t free_frames = AUDIO_FRAMES - (size_t)(write - read);
    const size_t accepted = frames < free_frames ? frames : free_frames;
    for (size_t i = 0; i < accepted; ++i) {
        size_t index = (size_t)((write + i) % AUDIO_FRAMES) * 2;
        pcm[index] = input[i * 2];
        pcm[index + 1] = input[i * 2 + 1];
    }
    atomic_store_explicit(&write_position, write + accepted, memory_order_release);
    atomic_fetch_add_explicit(&dropped, frames - accepted, memory_order_relaxed);
    atomic_fetch_add_explicit(&pushed, accepted, memory_order_relaxed);
}
size_t protector_audio_output_pull(float* left, float* right, size_t frames) {
    if (!left || !right) return 0;
    memset(left, 0, frames * sizeof(float));
    memset(right, 0, frames * sizeof(float));
    uint64_t current_epoch = atomic_load_explicit(&epoch, memory_order_acquire);
    uint64_t write = atomic_load_explicit(&write_position, memory_order_acquire);
    uint64_t read = atomic_load_explicit(&read_position, memory_order_relaxed);
    if (reader_epoch != current_epoch || !atomic_load_explicit(&enabled, memory_order_acquire)) {
        atomic_store_explicit(&read_position, write, memory_order_release);
        reader_epoch = current_epoch;
        reader_primed = false;
        return 0;
    }
    const size_t available = (size_t)(write - read);
    if (!reader_primed) {
        // Silence (not an underrun) until the cushion exists.
        if (available < AUDIO_PRIME_FRAMES) return 0;
        reader_primed = true;
        reader_fade_in = AUDIO_FADE_FRAMES;
    }
    const size_t count = frames < available ? frames : available;
    for (size_t i = 0; i < count; ++i) {
        size_t index = (size_t)((read + i) % AUDIO_FRAMES) * 2;
        float gain = 1.0f;
        if (reader_fade_in) {
            gain = (float)(AUDIO_FADE_FRAMES - reader_fade_in + 1) / (float)(AUDIO_FADE_FRAMES + 1);
            --reader_fade_in;
        }
        left[i] = gain * pcm[index] / 32768.0f;
        right[i] = gain * pcm[index + 1] / 32768.0f;
    }
    if (count < frames) {
        const size_t fade = count < AUDIO_FADE_FRAMES ? count : AUDIO_FADE_FRAMES;
        for (size_t i = 0; i < fade; ++i) {
            const float gain = (float)(fade - i) / (float)(fade + 1);
            left[count - fade + i] *= gain;
            right[count - fade + i] *= gain;
        }
        reader_primed = false;
    }
    atomic_store_explicit(&read_position, read + count, memory_order_release);
    atomic_fetch_add_explicit(&underrun, frames - count, memory_order_relaxed);
    atomic_fetch_add_explicit(&pulled, count, memory_order_relaxed);
    return count;
}
uint64_t protector_audio_output_dropped(void) { return atomic_load(&dropped); }
uint64_t protector_audio_output_underrun(void) { return atomic_load(&underrun); }
bool protector_audio_output_enabled(void) { return atomic_load(&enabled); }
uint64_t protector_audio_output_pushed(void) { return atomic_load(&pushed); }
uint64_t protector_audio_output_pulled(void) { return atomic_load(&pulled); }
