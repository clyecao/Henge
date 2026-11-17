#include "jit_region.h"

#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

static int failures;
static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

typedef struct {
    HvJitRegion *region;
    _Atomic unsigned char *seen;
    _Atomic int bad;
} Reservations;

static void *reserve_parallel(void *opaque) {
    Reservations *r = opaque;
    uint32_t *p;
    while ((p = hv_jit_reserve(r->region, 2))) {
        size_t at = (size_t)(p - r->region->base);
        if (at >= r->region->capacity || (at & 1) ||
            atomic_exchange(&r->seen[at], 1)) atomic_store(&r->bad, 1);
    }
    return NULL;
}

static void reservations(void) {
    HvJitRegion r;
    if (hv_jit_region_open(&r, 128 << 10)) { failures++; return; }
    hv_jit_ring(&r, 4);
    size_t seg = r.seg_words;
    check("four equal segments", r.nseg == 4 && seg * 4 == r.capacity);
    check("zero reservation rejected", !hv_jit_reserve(&r, 0) && !r.used);
    check("overflow reservation rejected", !hv_jit_reserve(&r, SIZE_MAX) && !r.used);
    check("odd reservation is aligned", hv_jit_reserve(&r, 3) == r.base && r.used == 4);
    check("fill to segment edge", hv_jit_reserve(&r, seg - 6) == r.base + 4);
    check("reservation skips short tail", hv_jit_reserve(&r, 4) == r.base + seg);
    check("oversized reservation reports fallback", !hv_jit_reserve(&r, seg + 2) && r.too_big);
    hv_jit_reset(&r);
    check("reset clears fallback and occupancy", !r.too_big && !hv_jit_extent(&r));

    for (unsigned i = 0; i < 4; i++)
        check("fill each segment", hv_jit_reserve(&r, seg) == r.base + i * seg);
    check("full ring refuses overlap", !hv_jit_reserve(&r, 2));
    for (unsigned i = 0; i < 20; i++) {
        uint32_t epochs[HV_JIT_MAX_SEGS];
        memcpy(epochs, r.seg_epoch, sizeof epochs);
        unsigned taken = hv_jit_evict_next(&r);
        check("eviction follows ring order", taken == i % 4);
        for (unsigned j = 0; j < 4; j++)
            check("only reclaimed epoch changes", r.seg_epoch[j] == epochs[j] + (j == taken));
        check("wrap retains full diagnostic extent", hv_jit_extent(&r) == r.capacity);
        check("only reclaimed segment is reusable", hv_jit_reserve(&r, seg) == r.base + taken * seg);
        check("live next segment cannot be overwritten", !hv_jit_reserve(&r, 2));
    }

    /* Contended allocations must not overlap, in either allocator mode. */
    for (unsigned mode = 1; mode <= 4; mode += 3) {
        hv_jit_ring(&r, mode);
        Reservations work = {.region = &r, .seen = calloc(r.capacity, sizeof *work.seen)};
        if (!work.seen) exit(1);
        pthread_t threads[8];
        for (unsigned i = 0; i < 8; i++)
            if (pthread_create(&threads[i], NULL, reserve_parallel, &work)) exit(1);
        for (unsigned i = 0; i < 8; i++) pthread_join(threads[i], NULL);
        size_t count = 0;
        for (size_t i = 0; i < r.capacity; i++) count += atomic_load(&work.seen[i]);
        check("parallel reservations never overlap", !atomic_load(&work.bad));
        check("parallel reservations fill exactly the region", count * 2 == r.capacity && r.used == r.capacity);
        check("repeated failure preserves cursor", !hv_jit_reserve(&r, SIZE_MAX - 1) && r.used == r.capacity);
        free(work.seen);
    }
    hv_jit_reset(&r);
    r.limit = r.capacity / 2;
    hv_jit_ring(&r, 4);
    check("ring respects reduced capacity", r.seg_words * r.nseg == r.limit);
    hv_jit_region_close(&r);
}

/* Both shapes: macOS MAP_JIT, and the iOS split mapping (RX plus an RW alias). */
static int one(const char *what) {
    HvJitRegion region;
    if (hv_jit_region_open(&region, 1 << 20) != 0) {
        printf("%s: could not map the JIT region\n", what);
        return 1;
    }
    uint32_t *code = hv_jit_reserve(&region, 2);
    static const uint32_t body[2] = {0xd2800540, 0xd65f03c0}; /* mov x0, #42; ret */
    hv_jit_write(&region, code, body, sizeof body);
    hv_jit_finish(&region, code, 2);
    long (*fn)(void) = (long (*)(void))code;
    long got = fn();
    printf("%s: jit region returned %ld\n", what, got);
    hv_jit_region_close(&region);
    return got != 42;
}

int main(void) {
    int bad = one("MAP_JIT");
    reservations();
    setenv("HV_JIT_SPLIT", "1", 1);
    bad |= one("split");
    reservations();
    printf("JIT reservations: bounds, 20 wraps and 8 concurrent allocators per mapping; %d failures\n", failures);
    return bad || failures;
}
