#include "machine.h"
#include "gicv3.h"
#include "pcie.h"
#include "virtio_snd.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HvMachine machine;
static uint8_t *memory;
static int checks, failures;
#define RAM 0x80000000ull
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); failures++; } } while (0)
static uint64_t time_ns;
static uint64_t test_clock(void) { return time_ns; }
static void *at(uint64_t pa) { return memory + (pa - RAM); }
static uint32_t u32(const void *p) { uint32_t n; memcpy(&n, p, 4); return n; }
static uint16_t u16(const void *p) { uint16_t n; memcpy(&n, p, 2); return n; }
static void put(uint64_t pa, uint64_t value, unsigned size) { memcpy(at(pa), &value, size); }
struct Desc { uint64_t address; uint32_t length; uint16_t flags, next; };

static void queue(HvVirtio *v, unsigned q) {
    uint64_t base = RAM + q * 0x4000;
    memset(at(base), 0, 0x4000);
    v->q[q].size = 16;
    v->q[q].enabled = 1;
    v->q[q].desc = base;
    v->q[q].avail = base + 0x1000;
    v->q[q].used = base + 0x2000;
}
static void post(HvVirtio *v, unsigned q, const struct Desc *desc, unsigned count) {
    HvVirtq *vq = &v->q[q];
    memcpy(at(vq->desc), desc, count * sizeof *desc);
    uint16_t n = u16(at(vq->avail + 2));
    put(vq->avail + 4 + 2 * (n % 16), 0, 2);
    put(vq->avail + 2, n + 1, 2);
    v->notify(v, (int)q);
}
static uint32_t command(HvVirtioSnd *s, uint32_t code, unsigned stream, unsigned format) {
    const uint64_t request = RAM + 0x18000, response = RAM + 0x19000;
    uint8_t req[32] = {0};
    memcpy(req, &code, 4); memcpy(req + 4, &stream, 4);
    unsigned size = 8;
    if (code == 0x100 || code == 0x200) {
        uint32_t n = 2, item = code == 0x100 ? 32 : 24;
        memcpy(req + 8, &n, 4); memcpy(req + 12, &item, 4); size = 16;
    } else if (code == 0x101) {
        uint32_t buffer = 3840, period = 960;
        memcpy(req + 8, &buffer, 4); memcpy(req + 12, &period, 4);
        req[20] = 1; req[21] = (uint8_t)format; req[22] = HV_VSND_RATE_48000; size = 24;
    }
    memcpy(at(request), req, size);
    memset(at(response), 0xcc, 128);
    struct Desc d[] = {{request, size, 1, 1}, {response, 128, 2, 0}};
    post(&s->vio, 0, d, 2);
    return u32(at(response));
}
static void capture(HvVirtioSnd *s, unsigned bytes) {
    put(RAM + 0x20000, 1, 4);
    memset(at(RAM + 0x21000), 0xa5, bytes + 8);
    struct Desc d[] = {{RAM + 0x20000, 4, 1, 1}, {RAM + 0x21000, bytes, 3, 2}, {RAM + 0x21000 + bytes, 8, 2, 0}};
    post(&s->vio, 3, d, 3);
}

typedef struct { int available, starts, stops, resets; } TestPlayer;

static int start_player(void *opaque, unsigned channels, unsigned format, unsigned rate) {
    TestPlayer *player = opaque;
    CHECK(channels == 1 && format == HV_VSND_FMT_S16 && rate == 48000);
    player->starts++;
    return player->available ? 0 : -1;
}
static void stop_player(void *opaque) { ((TestPlayer *)opaque)->stops++; }
static void reset_player(void *opaque) { ((TestPlayer *)opaque)->resets++; }

static void output_recovery(HvVirtioSnd *s) {
    TestPlayer player = {0};
    s->backend = (HvVirtioSndBackend){start_player, stop_player, reset_player, &player};
    queue(&s->vio, 0); queue(&s->vio, 2); queue(&s->vio, 3);
    s->vio.status = 15;
    CHECK(command(s, 0x101, 0, HV_VSND_FMT_S16) == 0x8000);
    CHECK(command(s, 0x102, 0, 0) == 0x8000);
    CHECK(command(s, 0x104, 0, 0) == 0x8000);
    uint64_t attempt_time = time_ns;
    put(RAM + 0x22000, 0, 4);
    struct Desc tx[] = {{RAM + 0x22000, 36, 1, 1}, {RAM + 0x23000, 8, 2, 0}};
    post(&s->vio, 2, tx, 2);
    time_ns += 1000000;
    hv_virtio_snd_poll(s);
    CHECK(u16(at(s->vio.q[2].used + 2)) == 1); /* guest plays on the clock during failure */
    for (int failed = 1; failed <= 10; failed++) {
        unsigned delay = failed < 4 ? 1 : failed < 10 ? 4 : 15;
        time_ns = attempt_time + delay * 1000000000ull - 1;
        hv_virtio_snd_poll(s);
        CHECK(player.starts == failed && !s->host_on);
        player.available = failed == 10;
        attempt_time = ++time_ns;
        hv_virtio_snd_poll(s);
        CHECK(player.starts == failed + 1);
    }
    CHECK(s->host_on && !s->host_failures);

    CHECK(command(s, 0x101, 1, HV_VSND_FMT_FLOAT) == 0x8000);
    CHECK(command(s, 0x102, 1, 0) == 0x8000);
    CHECK(command(s, 0x104, 1, 0) == 0x8000);
    hv_virtio_snd_capture_enable(s, 1);
    float samples[480];
    for (unsigned i = 0; i < 480; i++) samples[i] = 0.25f;
    hv_virtio_snd_capture_push(s, samples, 480);
    hv_virtio_snd_capture_push(s, samples, 480);
    capture(s, sizeof samples);
    hv_virtio_snd_kick(s);
    hv_virtio_snd_kick(s);
    time_ns += 10000000;
    hv_virtio_snd_poll(s);
    CHECK(player.starts == 12 && player.stops == 1 && player.resets == 1);
    CHECK(u16(at(s->vio.q[3].used + 2)) == 1 && !memcmp(at(RAM + 0x21000), samples, sizeof samples));
    CHECK(command(s, 0x105, 0, 0) == 0x8000);
    hv_virtio_snd_kick(s);
    hv_virtio_snd_poll(s);
    CHECK(player.starts == 12 && player.stops == 2 && player.resets == 2);
    CHECK(command(s, 0x104, 0, 0) == 0x8000);
    CHECK(player.starts == 13 && s->host_on);
    s->vio.pci.bar_write(&s->vio.pci, 4, 0x14, 0, 1);
    CHECK(player.stops == 3 && !s->host_on && !hv_virtio_snd_capture_requested(s));
    s->backend = (HvVirtioSndBackend){0};
}

static void sound_test(HvPcie *pci) {
    HvVirtioSnd *s = hv_virtio_snd_create(&machine, pci);
    CHECK(s != NULL);
    s->now_ns = test_clock;
    queue(&s->vio, 0); queue(&s->vio, 2); queue(&s->vio, 3);
    s->vio.status = 15;
    CHECK(u32(s->vio.config + 4) == 2);
    CHECK(command(s, 0x100, 0, 0) == 0x8000);
    const uint8_t *info = at(RAM + 0x19000 + 4);
    CHECK(info[24] == 0 && info[32 + 24] == 1 && info[32 + 26] == 1);
    CHECK(command(s, 0x200, 0, 0) == 0x8000);
    info = at(RAM + 0x19000 + 4);
    CHECK(info[4] == 0 && info[24 + 4] == 1 && info[24 + 5] == 1);
    for (unsigned f = 0; f < 3; f++) {
        const unsigned formats[] = {HV_VSND_FMT_S16, HV_VSND_FMT_S32, HV_VSND_FMT_FLOAT};
        unsigned format = formats[f], bytes = format == HV_VSND_FMT_S16 ? 2 : 4;
        CHECK(command(s, 0x101, 1, format) == 0x8000);
        CHECK(command(s, 0x102, 1, 0) == 0x8000);
        hv_virtio_snd_capture_enable(s, 1);
        CHECK(command(s, 0x104, 1, 0) == 0x8000);
        CHECK(hv_virtio_snd_capture_requested(s));
        unsigned used = u16(at(s->vio.q[3].used + 2));
        capture(s, 480 * bytes);
        CHECK(u16(at(s->vio.q[3].used + 2)) == used); /* no early/empty period */
        float samples[480];
        for (unsigned i = 0; i < 480; i++) samples[i] = 0.5f;
        samples[0] = -1; samples[1] = 1; samples[2] = NAN;
        hv_virtio_snd_capture_push(s, samples, 480);
        hv_virtio_snd_capture_push(s, samples, 480); /* prime the input jitter buffer */
        time_ns = s->capture.start_ns + 20000000;
        hv_virtio_snd_poll(s);
        CHECK(u16(at(s->vio.q[3].used + 2)) == used + 1);
        CHECK(u32(at(RAM + 0x21000 + 480 * bytes)) == 0x8000);
        if (bytes == 2) {
            int16_t *pcm = at(RAM + 0x21000);
            CHECK(pcm[0] == INT16_MIN && pcm[1] == INT16_MAX && pcm[2] == 0 && pcm[3] == 16383);
        } else if (format == HV_VSND_FMT_FLOAT) {
            float *pcm = at(RAM + 0x21000);
            CHECK(pcm[0] == -1 && pcm[1] == 1 && pcm[2] == 0 && pcm[3] == 0.5f);
        } else {
            int32_t *pcm = at(RAM + 0x21000);
            CHECK(pcm[0] == INT32_MIN && pcm[1] == INT32_MAX && pcm[2] == 0 && pcm[3] == 1073741823);
        }
        hv_virtio_snd_capture_enable(s, 0);
        hv_virtio_snd_capture_push(s, samples, 480);
        capture(s, 480 * bytes);
        time_ns = s->capture.start_ns + 40000000;
        hv_virtio_snd_poll(s);
        const uint8_t *zero = at(RAM + 0x21000);
        int silent = 1;
        for (unsigned i = 0; i < 480 * bytes; i++) if (zero[i]) silent = 0;
        CHECK(silent);
        CHECK(command(s, 0x105, 1, 0) == 0x8000);
        CHECK(!hv_virtio_snd_capture_requested(s));
        CHECK(command(s, 0x103, 1, 0) == 0x8000);
    }
    /* Host taps arrive in blocks, while guest periods keep a stable clock.
       A one-block reserve bridges their boundaries without splicing silence. */
    CHECK(command(s, 0x101, 1, HV_VSND_FMT_FLOAT) == 0x8000);
    CHECK(command(s, 0x102, 1, 0) == 0x8000);
    CHECK(command(s, 0x104, 1, 0) == 0x8000);
    hv_virtio_snd_capture_enable(s, 1);
    unsigned used = u16(at(s->vio.q[3].used + 2));
    capture(s, 960 * 4);
    float blocks[960];
    for (unsigned i = 0; i < 960; i++) blocks[i] = 0.25f * sinf((float)i * 0.057595865f);
    uint64_t epoch = s->capture.start_ns;
    hv_virtio_snd_capture_push(s, blocks, 480);
    hv_virtio_snd_capture_push(s, blocks + 480, 480);
    CHECK(s->capture.start_ns == epoch); /* callbacks cannot move the guest clock */
    time_ns = s->capture.start_ns + 10000000;
    hv_virtio_snd_poll(s);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used);
    CHECK(s->capture.offset == 480 * 4);
    hv_virtio_snd_capture_push(s, blocks, 480);
    time_ns = s->capture.start_ns + 20000000;
    hv_virtio_snd_poll(s);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used + 1);
    CHECK(!memcmp(at(RAM + 0x21000), blocks, sizeof blocks));
    /* An available block must not make the next period complete early. */
    capture(s, 480 * 4);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used + 1);
    time_ns = s->capture.start_ns + 30000000;
    hv_virtio_snd_poll(s);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used + 2);
    CHECK(!memcmp(at(RAM + 0x21000), blocks, 480 * 4));
    /* A failed source supplies paced silence, and fresh audio can re-prime. */
    time_ns = s->capture.start_ns + 40000000;
    capture(s, 480 * 4);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used + 3);
    const float *silence = at(RAM + 0x21000);
    int all_zero = 1;
    for (unsigned i = 0; i < 480; i++) if (silence[i] != 0) all_zero = 0;
    CHECK(all_zero);
    hv_virtio_snd_capture_push(s, blocks, 480);
    hv_virtio_snd_capture_push(s, blocks + 480, 1);
    hv_virtio_snd_poll(s);
    CHECK(!s->capture.source_active && s->capture.input_block_frames == 480);
    hv_virtio_snd_capture_push(s, blocks + 481, 479);
    capture(s, 480 * 4);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used + 3);
    time_ns = s->capture.start_ns + 50000000;
    hv_virtio_snd_poll(s);
    CHECK(u16(at(s->vio.q[3].used + 2)) == used + 4);
    CHECK(!memcmp(at(RAM + 0x21000), blocks, 480 * 4));
    CHECK(command(s, 0x105, 1, 0) == 0x8000);
    CHECK(command(s, 0x103, 1, 0) == 0x8000);
    /* Output still transfers and completes only after playback consumes PCM. */
    CHECK(command(s, 0x101, 0, HV_VSND_FMT_S16) == 0x8000);
    CHECK(command(s, 0x102, 0, 0) == 0x8000);
    CHECK(command(s, 0x104, 0, 0) == 0x8000);
    uint8_t tx[36] = {0}, played[32];
    for (unsigned i = 4; i < sizeof tx; i++) tx[i] = (uint8_t)i;
    memcpy(at(RAM + 0x22000), tx, sizeof tx);
    struct Desc out[] = {{RAM + 0x22000, sizeof tx, 1, 1}, {RAM + 0x23000, 8, 2, 0}};
    post(&s->vio, 2, out, 2);
    CHECK(hv_virtio_snd_pull(s, played, sizeof played) == sizeof played);
    CHECK(!memcmp(played, tx + 4, sizeof played));
    hv_virtio_snd_poll(s);
    CHECK(u16(at(s->vio.q[2].used + 2)) == 1);
    CHECK(command(s, 0x101, 1, HV_VSND_FMT_FLOAT) == 0x8000);
    CHECK(command(s, 0x102, 1, 0) == 0x8000);
    CHECK(command(s, 0x104, 1, 0) == 0x8000);
    hv_virtio_snd_capture_enable(s, 1);
    /* Record one period while playing a second output buffer. The host mic
       starts 1 ms late, so precisely the first 48 input frames are silent. */
    capture(s, 480 * 4);
    time_ns += 1000000;
    hv_virtio_snd_poll(s);
    CHECK(s->capture.offset == 48 * 4);
    hv_virtio_snd_capture_push(s, blocks, 480);
    hv_virtio_snd_capture_push(s, blocks + 480, 480);
    post(&s->vio, 2, out, 2);
    CHECK(hv_virtio_snd_pull(s, played, sizeof played) == sizeof played);
    time_ns += 9000000;
    hv_virtio_snd_poll(s);
    CHECK(!memcmp(played, tx + 4, sizeof played) && u16(at(s->vio.q[2].used + 2)) == 2);
    const float zeros[48] = {0};
    const float *input = at(RAM + 0x21000);
    CHECK(!memcmp(input, zeros, sizeof zeros) && !memcmp(input + 48, blocks, 432 * sizeof(float)));
    CHECK(u32(at(RAM + 0x21000 + 480 * 4)) == 0x8000);
    float *overflow = calloc(HV_VSND_CAPTURE_FRAMES + 128, sizeof(float));
    hv_virtio_snd_capture_push(s, overflow, HV_VSND_CAPTURE_FRAMES + 128);
    CHECK(s->capture.written - s->capture.consumed == HV_VSND_CAPTURE_FRAMES);
    hv_virtio_snd_capture_push(s, overflow, 128);
    CHECK(s->capture.written - s->capture.consumed == HV_VSND_CAPTURE_FRAMES);
    free(overflow);
    capture(s, 1920);
    CHECK(command(s, 0x105, 1, 0) == 0x8000);
    CHECK(s->capture.head == s->capture.tail);
    CHECK(u32(at(RAM + 0x21000 + 1920)) == 0x8000);
    CHECK(command(s, 0x104, 1, 0) == 0x8000);
    s->vio.pci.bar_write(&s->vio.pci, 4, 0x14, 0, 1);
    CHECK(!s->capture.running && s->capture.head == s->capture.tail && !s->running);
    output_recovery(s);
    hv_virtio_snd_destroy(s);
}

int main(void) {
    if (hv_machine_init(&machine, 4 << 20)) return 1;
    memory = aligned_alloc(16384, 2 << 20);
    if (!memory) return 1;
    memset(memory, 0, 2 << 20);
    CHECK(!hv_machine_add_ram(&machine, RAM, 2 << 20, memory, 0));
    HvGic *gic = hv_gicv3_create(&machine, 0x1000000, 0x2000000);
    HvPcie *pci = hv_pcie_create(&machine, gic, 0x3000000, 1 << 20, 0x10000000, 0x10000000, 32);
    CHECK(gic && pci);
    sound_test(pci);
    hv_machine_free(&machine); free(pci); free(gic); free(memory);
    printf("microphone: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
