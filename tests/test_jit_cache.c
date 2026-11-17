#include "dispatch.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* Real translated branches shared by 1, 2 and 5 CPUs, with a cache much smaller
   than their working set. No ROM, OS image, or graphics device is required. */
static HvMachine machine;
static HvCpu cpus[5];
static int failures;

static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

static void *run_cpu(void *opaque) {
    return (void *)(intptr_t)hv_run(opaque);
}

static void pressure(unsigned ncpu, unsigned segments) {
    enum { hops = 2048, rounds = 3 };
    const uint64_t pa = 0x10000;
    uint32_t *code = aligned_alloc(16384, 32768);
    if (!code || hv_machine_init(&machine, 128 << 10)) exit(1);
    hv_knob[HV_K_JITSEGS] = (int)segments;
    hv_jit_ring(&machine.jit, segments);
    code[0] = 0xd2800000; /* mov x0, #0 */
    code[1] = 0xd2800001 | (rounds << 5); /* mov x1, #rounds */
    unsigned end = 2;
    for (unsigned i = 0; i < hops; i++) {
        code[end++] = 0x91000400; /* add x0, x0, #1 */
        code[end++] = 0x14000001; /* b next */
    }
    code[end++] = 0xf1000421; /* subs x1, x1, #1 */
    int back = 2 - (int)end;
    code[end++] = 0x54000001 | (((uint32_t)back & 0x7ffff) << 5); /* b.ne first hop */
    hv_machine_add_ram(&machine, pa, 32768, code, 1);
    machine.stop_pc = pa + end * 4;
    pthread_t threads[5];
    /* Publish every CPU before any of them can request a stop-the-world eviction. */
    for (unsigned i = 0; i < ncpu; i++) {
        hv_cpu_reset_index(&cpus[i], &machine, (int)i);
        cpus[i].pc = pa;
    }
    for (unsigned i = 0; i < ncpu; i++)
        if (pthread_create(&threads[i], NULL, run_cpu, &cpus[i])) exit(1);
    for (unsigned i = 0; i < ncpu; i++) {
        void *result;
        pthread_join(threads[i], &result);
        check("every CPU reaches the guest's end", (intptr_t)result == HV_EXIT_HALT);
        check("reclaimed code never changes guest result", cpus[i].x[0] == hops * rounds && cpus[i].x[1] == 0);
    }
    if (segments > 1) {
        check("pressure causes segment eviction", machine.stats.evictions > 0);
        check("ring does not fall back to full flush", machine.stats.block_flushes == 0);
        check("live incoming branches were detached", machine.stats.evict_unchained > 0);
    } else {
        check("legacy mode still fully flushes", machine.stats.block_flushes > 0 && !machine.stats.evictions);
    }
    printf("JIT pressure: %u CPUs, %u segments, %llu evictions, %llu full flushes, %llu detached exits\n",
           ncpu, segments, (unsigned long long)machine.stats.evictions,
           (unsigned long long)machine.stats.block_flushes, (unsigned long long)machine.stats.evict_unchained);
    hv_machine_free(&machine);
    free(code);
}

static void oversized(void) {
    if (hv_machine_init(&machine, 128 << 10)) exit(1);
    hv_jit_ring(&machine.jit, 8);
    size_t words = machine.jit.seg_words + 2;
    check("oversized block requests a fallback", !hv_jit_reserve(&machine.jit, words));
    hv_evict_blocks(&machine); /* no CPU running */
    check("full flush actually makes room for oversized block", hv_jit_reserve(&machine.jit, words) != NULL);
    check("oversized fallback is counted", machine.stats.block_flushes == 1 && !machine.stats.evictions);
    hv_machine_free(&machine);
}

int main(void) {
    alarm(120); /* a stale chain or a missed stop-the-world acknowledgement must fail CI */
    setvbuf(stdout, NULL, _IONBF, 0);
    oversized();
    for (unsigned segments = 1; segments <= 8; segments *= 8) {
        pressure(1, segments);
        pressure(2, segments);
        pressure(5, segments);
    }
    printf("JIT cache: %d failures\n", failures);
    return failures != 0;
}
