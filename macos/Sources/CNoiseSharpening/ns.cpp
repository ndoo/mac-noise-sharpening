#include "CNoiseSharpening.h"

#include <atomic>
#include <vector>

#include "../../../core/noise_sharpening.h"

struct ns_sharpener {
    NoiseSharpener impl;
};

struct ns_ring {
    explicit ns_ring(size_t cap) : buf(cap + 1) {}
    std::vector<float> buf;
    std::atomic<size_t> head{0};
    std::atomic<size_t> tail{0};
};

ns_sharpener *ns_sharpener_create(void) { return new ns_sharpener(); }
void ns_sharpener_destroy(ns_sharpener *s) { delete s; }
void ns_sharpener_reset(ns_sharpener *s) { s->impl.reset(); }
void ns_sharpener_process(ns_sharpener *s, float *buf, size_t frames, size_t channels, float strength, float bass,
                         int prevent_clipping, float width) {
    s->impl.process(buf, frames, channels, strength, bass, prevent_clipping != 0, width);
}

float ns_peak_gain(float strength, float bass, float width) { return NoiseSharpener::peakGain(strength, bass, width); }

ns_ring *ns_ring_create(size_t capacity_samples) { return new ns_ring(capacity_samples); }
void ns_ring_destroy(ns_ring *r) { delete r; }

size_t ns_ring_available(const ns_ring *r) {
    const size_t h = r->head.load(std::memory_order_acquire);
    const size_t t = r->tail.load(std::memory_order_acquire);
    return (h + r->buf.size() - t) % r->buf.size();
}

size_t ns_ring_write(ns_ring *r, const float *src, size_t samples) {
    const size_t n = r->buf.size();
    const size_t h = r->head.load(std::memory_order_relaxed);
    const size_t t = r->tail.load(std::memory_order_acquire);
    const size_t free_slots = (t + n - h - 1) % n;
    if (samples > free_slots) samples = free_slots;
    for (size_t i = 0; i < samples; ++i) r->buf[(h + i) % n] = src[i];
    r->head.store((h + samples) % n, std::memory_order_release);
    return samples;
}

size_t ns_ring_read(ns_ring *r, float *dst, size_t samples) {
    const size_t n = r->buf.size();
    const size_t t = r->tail.load(std::memory_order_relaxed);
    const size_t h = r->head.load(std::memory_order_acquire);
    const size_t avail = (h + n - t) % n;
    if (samples > avail) samples = avail;
    for (size_t i = 0; i < samples; ++i) dst[i] = r->buf[(t + i) % n];
    r->tail.store((t + samples) % n, std::memory_order_release);
    return samples;
}

void ns_ring_trim(ns_ring *r, size_t keep_samples) {
    const size_t n = r->buf.size();
    const size_t t = r->tail.load(std::memory_order_relaxed);
    const size_t h = r->head.load(std::memory_order_acquire);
    const size_t avail = (h + n - t) % n;
    if (avail > keep_samples)
        r->tail.store((t + (avail - keep_samples)) % n, std::memory_order_release);
}
