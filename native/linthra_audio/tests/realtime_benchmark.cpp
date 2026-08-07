#include "linthra_audio/dsp.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <iostream>
#include <vector>

int main() {
    using Clock = std::chrono::steady_clock;
    using linthra::audio::DspChain;
    using linthra::audio::DspConfig;

    constexpr float sample_rate = 48'000.0F;
    constexpr std::size_t seconds = 60;
    constexpr std::size_t channels = 2;
    constexpr std::size_t frames = static_cast<std::size_t>(sample_rate) * seconds;
    constexpr std::size_t block_frames = 256;
    constexpr float pi = 3.14159265358979323846F;

    std::vector<float> audio(frames * channels);
    for (std::size_t frame = 0; frame < frames; ++frame) {
        const float time = static_cast<float>(frame) / sample_rate;
        const float sample = 0.7F * std::sin(2.0F * pi * 440.0F * time);
        audio[frame * channels] = sample;
        audio[frame * channels + 1] = sample * 0.92F;
    }

    DspConfig config{};
    config.preamp_db = 1.0F;
    config.limiter_enabled = true;
    config.limiter_threshold_db = -0.3F;
    config.band_count = 5;
    config.bands[0] = {true, 80.0F, 1.5F, 0.8F};
    config.bands[1] = {true, 250.0F, -1.0F, 1.0F};
    config.bands[2] = {true, 1000.0F, 0.75F, 1.1F};
    config.bands[3] = {true, 4000.0F, 1.25F, 0.9F};
    config.bands[4] = {true, 12'000.0F, -0.5F, 0.7F};

    DspChain chain(sample_rate);
    chain.configure(config);

    const auto started = Clock::now();
    for (std::size_t offset = 0; offset < frames; offset += block_frames) {
        const std::size_t count = std::min(block_frames, frames - offset);
        chain.process(audio.data() + offset * channels, count, channels);
    }
    const auto elapsed = Clock::now() - started;

    const auto elapsed_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count();
    const double realtime_ratio =
        std::chrono::duration<double>(elapsed).count() / static_cast<double>(seconds);

    std::cout << "Processed " << seconds
              << " seconds of 48 kHz stereo / 5-band EQ + limiter in "
              << elapsed_ms << " ms (" << realtime_ratio << "x realtime)\n";

    // Shared runners vary widely. 0.25x realtime is deliberately a broad guard:
    // a regression must be extremely large before we risk an audio underrun on
    // ordinary hardware, while normal optimized builds should sit far below it.
    if (realtime_ratio >= 0.25) {
        std::cerr << "DSP exceeded realtime safety budget\n";
        return 1;
    }

    return 0;
}
