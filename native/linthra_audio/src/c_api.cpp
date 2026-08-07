#include "linthra_audio/linthra_audio.h"

#include <algorithm>
#include <new>

#include "linthra_audio/dsp.hpp"

struct LinthraAudioDsp {
    explicit LinthraAudioDsp(float sample_rate) : chain(sample_rate) {}
    linthra::audio::DspChain chain;
};

extern "C" LinthraAudioDsp* linthra_audio_create(float sample_rate) {
    if (!(sample_rate > 0.0F)) {
        return nullptr;
    }
    return new (std::nothrow) LinthraAudioDsp(sample_rate);
}

extern "C" void linthra_audio_destroy(LinthraAudioDsp* dsp) {
    delete dsp;
}

extern "C" void linthra_audio_configure(
    LinthraAudioDsp* dsp,
    const LinthraAudioConfig* config) {
    if (dsp == nullptr || config == nullptr) {
        return;
    }

    linthra::audio::DspConfig native{};
    native.preamp_db = config->preamp_db;
    native.band_count = std::min(
        config->band_count,
        static_cast<size_t>(LINTHRA_AUDIO_MAX_EQ_BANDS));
    native.limiter_enabled = config->limiter_enabled != 0;
    native.limiter_threshold_db = config->limiter_threshold_db;
    native.limiter_release_ms = config->limiter_release_ms;

    for (size_t index = 0; index < native.band_count; ++index) {
        native.bands[index] = linthra::audio::PeakingEqBand{
            config->bands[index].enabled != 0,
            config->bands[index].frequency_hz,
            config->bands[index].gain_db,
            config->bands[index].q,
        };
    }

    dsp->chain.configure(native);
}

extern "C" void linthra_audio_reset(LinthraAudioDsp* dsp) {
    if (dsp != nullptr) {
        dsp->chain.reset();
    }
}

extern "C" void linthra_audio_process(
    LinthraAudioDsp* dsp,
    float* interleaved,
    size_t frames,
    uint32_t channels) {
    if (dsp != nullptr) {
        dsp->chain.process(interleaved, frames, channels);
    }
}
