#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ns_sharpener ns_sharpener;
typedef struct ns_ring ns_ring;

ns_sharpener *ns_sharpener_create(void);
void ns_sharpener_destroy(ns_sharpener *s);
void ns_sharpener_reset(ns_sharpener *s);
void ns_sharpener_process(ns_sharpener *s, float *buf, size_t frames, size_t channels, float strength, float bass,
                         int prevent_clipping, float width);

float ns_peak_gain(float strength, float bass, float width);

// Single-producer single-consumer ring of interleaved float samples.
ns_ring *ns_ring_create(size_t capacity_samples);
void ns_ring_destroy(ns_ring *r);
size_t ns_ring_available(const ns_ring *r);
// Returns samples written; excess beyond free space is dropped.
size_t ns_ring_write(ns_ring *r, const float *src, size_t samples);
// Returns samples read; the remainder of dst is left untouched.
size_t ns_ring_read(ns_ring *r, float *dst, size_t samples);
// Consumer side: discard the oldest samples, keeping at most keep_samples.
void ns_ring_trim(ns_ring *r, size_t keep_samples);

#ifdef __cplusplus
}
#endif
