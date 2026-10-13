#include <cmath>
#include <cstdio>
#include <vector>

#include "../core/noise_sharpening.h"
#include "../macos/Sources/CNoiseSharpening/include/CNoiseSharpening.h"

static int failures = 0;
#define CHECK(cond)                                                     \
    do {                                                                \
        if (!(cond)) {                                                  \
            std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #cond);  \
            ++failures;                                                 \
        }                                                               \
    } while (0)

static bool near(float a, float b) { return std::fabs(a - b) < 1e-5f; }

int main() {
    const float strengths[] = {-0.5f, 0.0f, 0.4f, 1.0f, 2.0f};
    for (float p : strengths) {
        NoiseSharpener s;
        std::vector<float> buf = {1.0f, 0.0f, 0.0f, 0.0f};
        s.process(buf.data(), 4, 1, p);
        CHECK(near(buf[0], 1.0f + p));
        CHECK(near(buf[1], -p));
        CHECK(near(buf[2], 0.0f));

        NoiseSharpener dc;
        std::vector<float> ones(8, 1.0f);
        dc.process(ones.data(), 8, 1, p);
        CHECK(near(ones[7], 1.0f));

        NoiseSharpener ny;
        std::vector<float> alt(8);
        for (int i = 0; i < 8; ++i) alt[i] = (i & 1) ? -1.0f : 1.0f;
        ny.process(alt.data(), 8, 1, p);
        CHECK(near(std::fabs(alt[7]), 1.0f + 2.0f * p));
    }

    // Bass term: mirror of the sharpener, impulse [1+b, b], DC gain 1+2b, Nyquist gain 1.
    for (float b : strengths) {
        NoiseSharpener s;
        std::vector<float> imp = {1.0f, 0.0f, 0.0f};
        s.process(imp.data(), 3, 1, 0.0f, b);
        CHECK(near(imp[0], 1.0f + b));
        CHECK(near(imp[1], b));
        CHECK(near(imp[2], 0.0f));

        NoiseSharpener dc;
        std::vector<float> ones(8, 1.0f);
        dc.process(ones.data(), 8, 1, 0.0f, b);
        CHECK(near(ones[7], 1.0f + 2.0f * b));

        NoiseSharpener ny;
        std::vector<float> alt(8);
        for (int i = 0; i < 8; ++i) alt[i] = (i & 1) ? -1.0f : 1.0f;
        ny.process(alt.data(), 8, 1, 0.0f, b);
        CHECK(near(std::fabs(alt[7]), 1.0f));
    }

    // Stereo width: identity at 1, mono at 0, mid preserved, side scaled.
    {
        const float lr[][2] = {{0.8f, -0.2f}, {0.1f, 0.5f}, {-0.6f, -0.6f}};
        for (float w : {0.0f, 0.5f, 1.0f, 1.5f, 2.0f}) {
            NoiseSharpener s;
            for (const auto &p : lr) {
                std::vector<float> f = {p[0], p[1]};
                s.process(f.data(), 1, 2, 0.0f, 0.0f, false, w);
                const float mid = (p[0] + p[1]) / 2, side = (p[0] - p[1]) / 2;
                CHECK(near(f[0], mid + w * side));
                CHECK(near(f[1], mid - w * side));
                CHECK(near((f[0] + f[1]) / 2, mid));
            }
        }
        // Not stereo: width ignored.
        NoiseSharpener m;
        std::vector<float> mono = {0.5f, -0.25f, 0.75f};
        const std::vector<float> ref = mono;
        m.process(mono.data(), 3, 1, 0.0f, 0.0f, false, 2.0f);
        CHECK(mono == ref);
        CHECK(near(NoiseSharpener::peakGain(0.4f, 0.0f, 1.5f), 1.8f * 1.5f));
        CHECK(near(NoiseSharpener::peakGain(0.4f, 0.0f, 0.5f), 1.8f));

        // Prevent clipping holds with width: worst-case stereo patterns stay within full scale.
        for (float w : {0.0f, 1.0f, 1.5f, 2.0f}) {
            NoiseSharpener s;
            float peak = 0.0f;
            for (int trial = 0; trial < 4; ++trial) {
                std::vector<float> sig(2 * 256);
                for (size_t i = 0; i < 256; ++i) {
                    const float a = (i & 1) ? -1.0f : 1.0f;
                    sig[2 * i] = trial == 0 ? a : (trial == 1 ? 1.0f : (trial == 2 ? a : 1.0f));
                    sig[2 * i + 1] = trial == 0 ? -a : (trial == 1 ? -1.0f : (trial == 2 ? a : -a));
                }
                s.process(sig.data(), 256, 2, 2.0f, 0.75f, true, w);
                for (float v : sig) peak = std::max(peak, std::fabs(v));
            }
            CHECK(peak <= 1.0f + 1e-5f);
        }
    }

    // Split buffers match a single call.
    {
        std::vector<float> in(2 * 64);
        for (size_t i = 0; i < in.size(); ++i) in[i] = std::sin(0.37f * i) * 0.5f;
        std::vector<float> whole = in, split = in;
        NoiseSharpener a, b;
        a.process(whole.data(), 64, 2, 0.4f);
        b.process(split.data(), 13, 2, 0.4f);
        b.process(split.data() + 26, 51, 2, 0.4f);
        for (size_t i = 0; i < in.size(); ++i) CHECK(whole[i] == split[i]);
    }

    // Channel-count change resets state.
    {
        NoiseSharpener s;
        std::vector<float> st = {1.0f, 1.0f};
        s.process(st.data(), 1, 2, 0.4f);
        std::vector<float> mono = {1.0f};
        s.process(mono.data(), 1, 1, 0.4f);
        CHECK(near(mono[0], 1.4f));
    }

    // Explicit reset.
    {
        NoiseSharpener s;
        std::vector<float> a = {1.0f}, b = {1.0f};
        s.process(a.data(), 1, 1, 1.0f);
        s.reset();
        s.process(b.data(), 1, 1, 1.0f);
        CHECK(near(b[0], 2.0f));
    }

    // Ring buffer: wraparound, underrun, overrun, trim.
    {
        ns_ring *r = ns_ring_create(8);
        float out[8];
        const float a[] = {1, 2, 3, 4, 5, 6};
        const float b[] = {7, 8, 9, 10, 11, 12};
        CHECK(ns_ring_write(r, a, 6) == 6);
        CHECK(ns_ring_read(r, out, 4) == 4);
        CHECK(out[0] == 1 && out[3] == 4);
        CHECK(ns_ring_write(r, b, 6) == 6);
        CHECK(ns_ring_available(r) == 8);
        CHECK(ns_ring_write(r, a, 1) == 0);
        CHECK(ns_ring_read(r, out, 8) == 8);
        CHECK(out[0] == 5 && out[7] == 12);
        CHECK(ns_ring_read(r, out, 4) == 0);
        ns_ring_write(r, a, 6);
        ns_ring_trim(r, 2);
        CHECK(ns_ring_read(r, out, 2) == 2);
        CHECK(out[0] == 5 && out[1] == 6);
        ns_ring_destroy(r);
    }

    CHECK(near(NoiseSharpener::peakGain(0.4f, 0.0f), 1.8f));
    CHECK(near(NoiseSharpener::peakGain(0.0f, 0.4f), 1.8f));
    CHECK(near(NoiseSharpener::peakGain(0.0f, 0.0f), 1.0f));

    // Prevent clipping: full-scale input stays within full scale; off leaves gain untouched.
    {
        const float cases[][2] = {{0.4f, 0.0f}, {0.0f, 0.75f}, {2.0f, 0.75f}, {-0.5f, 0.4f}, {0.0f, 0.0f}};
        for (const auto &cs : cases) {
            NoiseSharpener s;
            float peak = 0.0f;
            for (int trial = 0; trial < 3; ++trial) {
                std::vector<float> sig(512);
                for (size_t i = 0; i < sig.size(); ++i) {
                    if (trial == 0) sig[i] = (i & 1) ? -1.0f : 1.0f;
                    else if (trial == 1) sig[i] = 1.0f;
                    else sig[i] = (i % 7 < 3) ? 1.0f : -1.0f;
                }
                s.process(sig.data(), sig.size(), 1, cs[0], cs[1], true);
                for (float v : sig) peak = std::max(peak, std::fabs(v));
            }
            CHECK(peak <= 1.0f + 1e-5f);
        }
        NoiseSharpener plain, comp;
        std::vector<float> a = {1.0f, 0.5f, -0.25f}, b = a;
        plain.process(a.data(), 3, 1, 0.4f, 0.0f, false);
        comp.process(b.data(), 3, 1, 0.4f, 0.0f, true);
        CHECK(near(b[0] * 1.8f, a[0]));
        NoiseSharpener none;
        std::vector<float> c = {1.0f, 0.5f};
        none.process(c.data(), 2, 1, 0.0f, 0.0f, true);
        CHECK(c[0] == 1.0f && c[1] == 0.5f);
    }

    if (failures == 0) std::printf("all tests passed\n");
    return failures ? 1 : 0;
}
