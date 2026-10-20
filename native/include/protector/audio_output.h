#ifndef PROTECTOR_AUDIO_OUTPUT_H
#define PROTECTOR_AUDIO_OUTPUT_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Bounded single-producer/single-consumer PCM transport. 32 kHz stereo.
// Reset only before either endpoint starts. No allocation or OS audio calls.
void protector_audio_output_reset(void);
void protector_audio_output_enable(bool enabled);
void protector_audio_output_push(const int16_t* interleaved, size_t frames);
size_t protector_audio_output_pull(float* left, float* right, size_t frames);
uint64_t protector_audio_output_dropped(void);
uint64_t protector_audio_output_underrun(void);
bool protector_audio_output_enabled(void);
uint64_t protector_audio_output_pushed(void);
uint64_t protector_audio_output_pulled(void);
#ifdef __cplusplus
}
#endif
#endif
