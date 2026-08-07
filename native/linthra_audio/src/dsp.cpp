#include "linthra_audio/dsp.hpp"

#include <algorithm>
#include <cmath>

namespace linthra::audio {
namespace {
constexpr float kPi = 3.14159265358979323846F;

float db_to_linear(float db) noexcept {
    return std::pow(10.0F, db / 20.0F);
}
}  // namespace

DspChain::DspChain(float sample_rate) noexcept
    : sample_rate_(std::max(sample_rate, 1.0F)) {
    configure(DspConfig{});
}

void DspChain::configure(const DspConfig& config) noexcept {
    config_ = config;
    config_.preamp_db = std::clamp(config_.preamp_db, -24.0F, 12.0F);
    config_.band_count = std::min(config_.band_count, kMaxEqBands);
    config_.limiter_threshold_db =
        std::clamp(config_.limiter_threshold_db, -24.0F, 0.0F);
    config_.limiter_release_ms =
        std::clamp(config_.limiter_release_ms, 5.0F, 2000.0F);

    preamp_linear_ = db_to_linear(config_.preamp_db);
    limiter_threshold_linear_ = db_to_linear(config_.limiter_threshold_db);

    const float release_seconds = config_.limiter_release_ms / 1000.0F;
    limiter_release_step_ =
        1.0F - std::exp(-1.0F / (release_seconds * sample_rate_));

    for (std::size_t index = 0; index < kMaxEqBands; ++index) {
        if (index < config_.band_count && config_.bands[index].enabled) {
            biquads_[index].configure_peaking(sample_rate_, config_.bands[index]);
        } else {
            biquads_[index] = Biquad{};
        }
    }

    limiter_gain_ = 1.0F;
}

void DspChain::reset() noexcept {
    for (auto& biquad : biquads_) {
        biquad.reset();
    }
    limiter_gain_ = 1.0F;
}

void DspChain::process(
    float* interleaved,
    std::size_t frames,
    std::uint32_t channels) noexcept {
    if (interleaved == nullptr || frames == 0 || channels == 0 || channels > 2) {
        return;
    }

    for (std::size_t frame = 0; frame < frames; ++frame) {
        std::array<float, 2> processed{};
        float frame_peak = 0.0F;

        for (std::size_t channel = 0; channel < channels; ++channel) {
            const std::size_t sample_index = frame * channels + channel;
            float sample = interleaved[sample_index] * preamp_linear_;

            for (std::size_t band = 0; band < config_.band_count; ++band) {
                if (biquads_[band].enabled) {
                    sample = biquads_[band].process(sample, channel);
                }
            }

            if (!std::isfinite(sample)) {
                sample = 0.0F;
            }
            processed[channel] = sample;
            frame_peak = std::max(frame_peak, std::abs(sample));
        }

        float frame_gain = 1.0F;
        if (config_.limiter_enabled) {
            const float desired_gain = frame_peak > limiter_threshold_linear_
                ? limiter_threshold_linear_ / std::max(frame_peak, 1.0e-12F)
                : 1.0F;

            if (desired_gain < limiter_gain_) {
                // Peak protection attacks immediately; recovery is smooth so
                // gain does not chatter on consecutive loud frames.
                limiter_gain_ = desired_gain;
            } else {
                limiter_gain_ +=
                    (1.0F - limiter_gain_) * limiter_release_step_;
            }
            frame_gain = limiter_gain_;
        } else {
            limiter_gain_ = 1.0F;
        }

        for (std::size_t channel = 0; channel < channels; ++channel) {
            interleaved[frame * channels + channel] = processed[channel] * frame_gain;
        }
    }
}

void DspChain::Biquad::configure_peaking(
    float sample_rate,
    const PeakingEqBand& band) noexcept {
    const float frequency =
        std::clamp(band.frequency_hz, 10.0F, sample_rate * 0.49F);
    const float gain_db = std::clamp(band.gain_db, -24.0F, 24.0F);
    const float q = std::clamp(band.q, 0.1F, 20.0F);

    const float a = std::pow(10.0F, gain_db / 40.0F);
    const float omega = 2.0F * kPi * frequency / sample_rate;
    const float cosine = std::cos(omega);
    const float alpha = std::sin(omega) / (2.0F * q);

    const float raw_b0 = 1.0F + alpha * a;
    const float raw_b1 = -2.0F * cosine;
    const float raw_b2 = 1.0F - alpha * a;
    const float a0 = 1.0F + alpha / a;
    const float raw_a1 = -2.0F * cosine;
    const float raw_a2 = 1.0F - alpha / a;

    b0 = raw_b0 / a0;
    b1 = raw_b1 / a0;
    b2 = raw_b2 / a0;
    a1 = raw_a1 / a0;
    a2 = raw_a2 / a0;
    enabled = std::abs(gain_db) > 0.0001F;
    reset();
}

void DspChain::Biquad::reset() noexcept {
    z1 = {};
    z2 = {};
}

float DspChain::Biquad::process(float sample, std::size_t channel) noexcept {
    const float output = b0 * sample + z1[channel];
    z1[channel] = b1 * sample - a1 * output + z2[channel];
    z2[channel] = b2 * sample - a2 * output;
    return output;
}

}  // namespace linthra::audio
