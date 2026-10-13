#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

class NoiseSharpener {
public:
    void reset() {
        for (float &p : prev_) p = 0.0f;
    }

    // Largest gain the processing can apply to a full-scale input: the sum of |taps| of the
    // filter times the stereo-width matrix gain, max(1, width).
    static float peakGain(float strength, float bass, float width = 1.0f) {
        const float filter = std::fabs(1.0f + strength + bass) + std::fabs(bass - strength);
        return filter * std::max(1.0f, width);
    }

    // Interleaved float PCM, in place. strength scales (x - prev), the high-frequency
    // boost; bass scales (x + prev), its mirror image (gain 1 + 2*bass at DC, 1 at Nyquist).
    // For stereo, width scales the side signal (L - R) / 2 after filtering; both channels use
    // the same filter, so the order of the two stages does not matter.
    // preventClipping scales the output by 1 / peakGain so output stays within the input's peak.
    void process(float *buf, size_t frames, size_t channels, float strength, float bass = 0.0f,
                 bool preventClipping = false, float width = 1.0f) {
        if (channels != 2) width = 1.0f;
        const float scale = preventClipping ? 1.0f / std::max(1.0f, peakGain(strength, bass, width)) : 1.0f;
        if (channels != prev_.size()) prev_.assign(channels, 0.0f);
        for (size_t i = 0; i < frames; ++i) {
            float *frame = buf + i * channels;
            for (size_t c = 0; c < channels; ++c) {
                const float x = frame[c];
                const float prev = prev_[c];
                const float d = x - prev;
                prev_[c] = x;
                frame[c] = (x + d * strength + (x + prev) * bass) * scale;
            }
            if (channels == 2 && width != 1.0f) {
                const float mid = (frame[0] + frame[1]) * 0.5f;
                const float side = (frame[0] - frame[1]) * 0.5f * width;
                frame[0] = mid + side;
                frame[1] = mid - side;
            }
        }
    }

private:
    std::vector<float> prev_;
};
