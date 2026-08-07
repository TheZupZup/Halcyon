#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace linthra::audio {

constexpr std::size_t kMaxEqBands = 8;

struct PeakingEqBand {
    bool enabled = false;
    float frequency_hz = 1000.0F;
    float gain_db = 0.0F;
    float q = 1.0F;
};

struct DspConfig {
    float preamp_db = 0.0F;
    std::array<PeakingEqBand, kMaxEqBands> bands{};
    std::size_t band_count = 0;
    bool limiter_enabled = true;
    float limiter_threshold_db = -0.3F;
    float limiter_release_ms = 80.0F;
};

/// Allocation-free, lock-free processing chain for mono/stereo floating-point
/// PCM. Configuration work may calculate coefficients; process() only performs
/// bounded arithmetic over already-prepared state.
class DspChain {
  public:
    explicit DspChain(float sample_rate) noexcept;

    void configure(const DspConfig& config) noexcept;
    void reset() noexcept;

    /// Processes interleaved mono/stereo samples in place. Unsupported channel
    /// counts are bypassed rather than risking a bad audio callback.
    void process(float* interleaved, std::size_t frames, std::uint32_t channels) noexcept;

    [[nodiscard]] float sample_rate() const noexcept { return sample_rate_; }
    [[nodiscard]] DspConfig config() const noexcept { return config_; }

  private:
    struct Biquad {
        float b0 = 1.0F;
        float b1 = 0.0F;
        float b2 = 0.0F;
        float a1 = 0.0F;
        float a2 = 0.0F;
        std::array<float, 2> z1{};
        std::array<float, 2> z2{};
        bool enabled = false;

        void configure_peaking(float sample_rate, const PeakingEqBand& band) noexcept;
        void reset() noexcept;
        float process(float sample, std::size_t channel) noexcept;
    };

    float sample_rate_;
    DspConfig config_{};
    std::array<Biquad, kMaxEqBands> biquads_{};
    float preamp_linear_ = 1.0F;
    float limiter_threshold_linear_ = 1.0F;
    float limiter_gain_ = 1.0F;
    float limiter_release_step_ = 1.0F;
};

}  // namespace linthra::audio
