#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LINTHRA_AUDIO_MAX_EQ_BANDS 8

typedef struct LinthraAudioEqBand {
    int32_t enabled;
    float frequency_hz;
    float gain_db;
    float q;
} LinthraAudioEqBand;

typedef struct LinthraAudioConfig {
    float preamp_db;
    LinthraAudioEqBand bands[LINTHRA_AUDIO_MAX_EQ_BANDS];
    size_t band_count;
    int32_t limiter_enabled;
    float limiter_threshold_db;
    float limiter_release_ms;
} LinthraAudioConfig;

typedef struct LinthraAudioDsp LinthraAudioDsp;

/// Creates one DSP instance for a fixed output sample rate.
LinthraAudioDsp* linthra_audio_create(float sample_rate);

void linthra_audio_destroy(LinthraAudioDsp* dsp);

/// Replaces all DSP parameters. Safe to call between audio callbacks; the
/// eventual mobile binding is responsible for serializing configuration against
/// process calls so this core never needs a lock in the realtime path.
void linthra_audio_configure(LinthraAudioDsp* dsp, const LinthraAudioConfig* config);

void linthra_audio_reset(LinthraAudioDsp* dsp);

/// Processes interleaved float PCM in place. The current core supports mono or
/// stereo and bypasses unsupported channel layouts.
void linthra_audio_process(
    LinthraAudioDsp* dsp,
    float* interleaved,
    size_t frames,
    uint32_t channels);

#ifdef __cplusplus
}
#endif
