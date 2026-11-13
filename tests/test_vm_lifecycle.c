#include "henge-vm.h"
#include "henge-ios-jit.h"
#include "install.h"
#include "jit_region.h"
#include "vm.h"

#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Real native bridge and device workers, with a test JIT mapping and restore service. */
static HvJitRegion jit;
static HengeDualMapping mapping;
static int failures;
static _Atomic int reader_done;
static int reservation_releases;
extern _Atomic int henge_tl_ran;
HengeDualMapping *henge_ios_jit_get_mapping(void) { return &mapping; }
void henge_ios_release_high_hold(void) { reservation_releases++; }
void hv_prof_ios_start(void) {}
static int install_result = -1;
int hv_install_start(HvVirtioUsb *usb, const char *ipsw, const char *work, uint64_t ecid,
                     HvInstallProgress progress, void *user) {
    (void)usb; (void)ipsw; (void)work; (void)ecid; (void)progress; (void)user;
    return install_result;
}
static int detached;
void hv_install_detach(void) { detached++; }
static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}
static int fds(void) {
    int n = 0;
    for (int i = 0; i < 2048; i++) if (fcntl(i, F_GETFD) != -1) n++;
    return n;
}
static unsigned threads(void) {
    thread_act_array_t list;
    mach_msg_type_number_t n;
    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return 0;
    for (unsigned i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), list[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof *list);
    return n;
}
static unsigned dead_ports(void) {
    mach_port_name_array_t names;
    mach_port_type_array_t types;
    mach_msg_type_number_t n, nt;
    if (mach_port_names(mach_task_self(), &names, &n, &types, &nt) != KERN_SUCCESS) exit(1);
    unsigned dead = 0;
    for (unsigned i = 0; i < nt; i++) if (types[i] & MACH_PORT_TYPE_DEAD_NAME) dead++;
    vm_deallocate(mach_task_self(), (vm_address_t)names, n * sizeof *names);
    vm_deallocate(mach_task_self(), (vm_address_t)types, nt * sizeof *types);
    return dead;
}
static void write_file(const char *path, const void *data, size_t bytes) {
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0 || (data && write(fd, data, bytes) != (ssize_t)bytes) || ftruncate(fd, bytes)) exit(1);
    close(fd);
}
static void *read_ui(void *unused) {
    (void)unused;
    while (!atomic_load(&reader_done)) {
        uint8_t image[16];
        int x, y, width, height, stride;
        const uint8_t *pixels;
        henge_vm_snapshot(image, 2, 2);
        henge_vm_pointer(&x, &y);
        henge_vm_cpus_on();
        henge_vm_gpu_frames();
        henge_vm_microphone_requested();
        const float sample = 0.25f;
        henge_vm_microphone(0, &sample, 1);
        henge_vm_balloon(-1);
        henge_vm_set_display_layer(NULL);
        if (!henge_vm_boot_display(&pixels, &width, &height, &stride)) henge_vm_free_display(pixels);
        usleep(500);
    }
    return NULL;
}
/* Seed a partly filled guest RX descriptor while the test VM is paused. */
static void seed_microphone(void) {
    HvVmapple *b = hv_vm_board();
    HvVirtioSnd *s = b->snd;
    const uint64_t base = 0x70000000;
    memset(b->ram + 0x10000, 0, 0x5000);
    s->vio.status = 4;
    s->vio.q[3] = (HvVirtq){.size = 8, .enabled = 1, .last_avail = 1,
        .desc = base + 0x10000, .avail = base + 0x11000, .used = base + 0x12000};
    s->vio.q[3].out[0] = 1;
    *(uint16_t *)(b->ram + 0x11002) = 1;
    *(uint32_t *)(b->ram + 0x13000) = 1;
    memset(b->ram + 0x14000, 0x42, 64);
    s->capture.format = HV_VSND_FMT_FLOAT;
    s->capture.frame_bytes = 4;
    s->capture.buffer_bytes = 7680;
    s->capture.period_bytes = 1920;
    s->capture.prepared = s->capture.running = s->capture.enabled = 1;
    s->capture.head = 7; s->capture.tail = 8; s->capture.offset = 64;
    s->capture.pending[7] = (HvVirtqElem){.head = 0, .nseg = 2,
        .seg = {{base + 0x13000, 4, 0}, {base + 0x14000, 1928, 1}}};
    s->capture.delivered = 480000;
    s->capture.samples[0] = 0.75f;
    s->capture.written = 1;
}

static void check_microphone_resume(void) {
    HvVmapple *b = hv_vm_board();
    HvVirtioSnd *s = b->snd;
    for (int n = 0; n < 200 && *(volatile uint16_t *)(b->ram + 0x12002) == 0; n++) usleep(1000);
    pthread_mutex_lock(&s->capture_mu);
    check("resumed RX period completes once", *(uint16_t *)(b->ram + 0x12002) == 1 && s->capture.head == 8 && s->capture.tail == 8);
    check("resumed microphone has a fresh clock and no saved permission", s->capture.delivered < 48000 && !s->capture.enabled && !s->capture.written);
    check("RX partial samples survive", b->ram[0x14000] == 0x42 && b->ram[0x1403f] == 0x42);
    check("resumed microphone emits gated silence", *(float *)(b->ram + 0x14040) == 0 && *(uint32_t *)(b->ram + 0x14780) == 0x8000);
    pthread_mutex_unlock(&s->capture_mu);
    const float sample = 0.5f;
    uint64_t generation = henge_vm_generation();
    check("macOS still requests recording", henge_vm_microphone_requested());
    henge_vm_microphone_enable(1);
    henge_vm_microphone(generation - 1, &sample, 1);
    henge_vm_microphone(generation, &sample, 1);
    pthread_mutex_lock(&s->capture_mu);
    check("only the current VM's microphone callback is accepted", s->capture.written == 1 && s->capture.samples[0] == sample);
    pthread_mutex_unlock(&s->capture_mu);
    henge_vm_microphone_enable(0);
}

int main(void) {
    alarm(60);
    char dir[] = "/tmp/henge-lifecycle-XXXXXX", rom[256], disk[256], aux[256], ram[256], error[256];
    if (!mkdtemp(dir) || hv_jit_region_open(&jit, 8 << 20)) return 1;
    snprintf(rom, sizeof rom, "%s/rom", dir);
    snprintf(disk, sizeof disk, "%s/disk", dir);
    snprintf(aux, sizeof aux, "%s/aux", dir);
    snprintf(ram, sizeof ram, "%s/ram", dir);
    setenv("HV_RAM_FILE", ram, 1);
    setenv("HV_RAM_NO_LEDGER", "1", 1);
    setenv("HV_BALLOON", "0", 1);
    write_file(disk, NULL, 1 << 20);
    write_file(aux, NULL, 1 << 20);
    mapping = (HengeDualMapping){.rx_addr = (uint8_t *)jit.base,
        .rw_addr = (uint8_t *)jit.base + jit.rw_diff, .size = jit.capacity * 4};
    check("memory preflight succeeds before boot", henge_vm_prepare_memory(error, sizeof error) == 0);
    check("memory preflight releases unused reservations", reservation_releases == 1);
    check("memory preflight does not boot the VM", henge_vm_state() == 0 && henge_vm_can_start());
    check("memory preflight preserves JIT", mapping.rx_addr == (uint8_t *)jit.base);
    check("memory preflight can be repeated", henge_vm_prepare_memory(error, sizeof error) == 0);
    atomic_store(&henge_tl_ran, 1);
    int releases = reservation_releases;
    check("Mac-app session refuses memory preflight", henge_vm_prepare_memory(error, sizeof error) != 0 && strstr(error, "Mac app"));
    check("Mac-app reservations are not released", reservation_releases == releases && !henge_vm_can_start());
    atomic_store(&henge_tl_ran, 0);
    pthread_t reader;
    if (pthread_create(&reader, NULL, read_ui, NULL)) return 1;
    /* Warm the process-wide pointer queue before counting worker threads. */
    hv_vm_mouse_move(0, 0);
    usleep(100000);
    int initial_fds = fds();
    unsigned initial_threads = threads();
    unsigned initial_dead_ports = dead_ports();
    /* Missing ROM fails after disks, RAM and device workers were created. */
    for (int i = 0; i < 3; i++) {
        releases = reservation_releases;
        check("failed boot reports an error", henge_vm_boot(rom, disk, aux, 1, 0, 64, 4, error, sizeof error) != 0);
        check("native boot releases unused reservations", reservation_releases == releases + 1);
        check("failed boot allows retry", henge_vm_state() == 0 && henge_vm_can_start());
        check("failed boot closes files", fds() == initial_fds);
        check("failed boot joins workers", threads() == initial_threads);
        releases = reservation_releases;
        check("failed install reports an error", henge_vm_install(rom, disk, aux, 1, "missing.ipsw", dir, 64, 4, error, sizeof error) != 0);
        check("native install releases unused reservations", reservation_releases == releases + 1);
        check("failed install allows retry", henge_vm_state() == 0 && henge_vm_can_start());
        check("failed install releases RAM", hv_vm_board()->ram == NULL && hv_vm_board()->ram_fd == -1);
        check("failed install closes files", fds() == initial_fds);
        check("failed install joins workers", threads() == initial_threads);
    }
    for (int i = 0; i < 12; i++) {
        int outcome = i % 3 == 2 ? HENGE_VM_OUTCOME_HOST_STOP : i % 3 == 1 ? HENGE_VM_OUTCOME_RESTART : HENGE_VM_OUTCOME_SHUTDOWN;
        uint32_t code[] = {outcome == HENGE_VM_OUTCOME_RESTART ? 0xd2800120 : 0xd2800100, 0xf2b08000, 0xd4000002};
        if (outcome == HENGE_VM_OUTCOME_HOST_STOP) code[0] = 0x14000000;
        write_file(rom, code, sizeof code);
        int rc = henge_vm_boot(rom, disk, aux, 1, 0, 64, 4, error, sizeof error);
        if (rc) fprintf(stderr, "boot %d: %s\n", i, error);
        check("boot succeeds without restarting app", rc == 0);
        if (rc) break;
        if (outcome == HENGE_VM_OUTCOME_HOST_STOP) {
            releases = reservation_releases;
            check("running VM refuses memory preflight", henge_vm_prepare_memory(error, sizeof error) != 0);
            check("running VM keeps its reservations", reservation_releases == releases);
            henge_vm_mouse_button(0, 1);
            henge_vm_mouse_button(1, 1);
            henge_vm_mouse_move(5, 7);
            henge_vm_mouse_scroll(12, -18);
            henge_vm_mouse_button(1, 0);
            henge_vm_mouse_scroll(-8, 6);
            henge_vm_stop();
        }
        for (int n = 0; n < 3000 && henge_vm_state() != 2; n++) usleep(1000);
        check("terminal state is published after cleanup", henge_vm_state() == 2);
        if (henge_vm_state() != 2) exit(1);
        check("power outcome preserved", henge_vm_exit_outcome() == outcome);
        check("start is available again", henge_vm_can_start());
        check("new generation", henge_vm_generation() == (uint64_t)i + 1);
        check("RAM released", hv_vm_board()->ram == NULL);
        check("RAM file closed", hv_vm_board()->ram_fd == -1);
        check("balloon released", hv_vm_board()->balloon == NULL);
        check("translation metadata released", hv_vm_machine()->blocks == NULL && hv_vm_machine()->jit.base == NULL);
        check("borrowed JIT mapping retained", mapping.rx_addr == (uint8_t *)jit.base);
        check("no disk or network descriptor leak", fds() == initial_fds);
        /* The last CPU thread can still be returning from its callback. */
        for (int n = 0; n < 1000 && threads() > initial_threads; n++) usleep(1000);
        check("no CPU, disk or network worker leak", threads() == initial_threads);
        check("no leaked CPU thread ports", dead_ports() == initial_dead_ports);
    }
    /* Instant resume: a counter in RAM goes on from where it was saved, in this machine and in a new one. */
    {
        char snap[300];
        snprintf(snap, sizeof snap, "%s/state.hsnap", dir);
        /* movz x1, #0x7000, lsl 16; loop: ldr x2, [x1]; add x2, x2, #1; str x2, [x1]; b loop */
        uint32_t code[] = {0xd2ae0001, 0xf9400022, 0x91000442, 0xf9000022, 0x17fffffd};
        write_file(rom, code, sizeof code);
        int rc = henge_vm_boot(rom, disk, aux, 1, 0, 64, 2, error, sizeof error);
        check("resume test boots", rc == 0);
        usleep(50000);
        rc = henge_vm_suspend(snap, "test", error, sizeof error);
        if (rc) fprintf(stderr, "suspend: %s\n", error);
        check("suspend saves", rc == 0 && henge_vm_state() == 4 && access(snap, F_OK) == 0);
        releases = reservation_releases;
        check("paused VM refuses memory preflight", henge_vm_prepare_memory(error, sizeof error) != 0);
        check("paused VM keeps its reservations", reservation_releases == releases);
        volatile uint64_t *count = (volatile uint64_t *)hv_vm_board()->ram;
        uint64_t c1 = *count;
        usleep(20000);
        check("paused: the counter stands still", c1 > 0 && *count == c1);
        seed_microphone();
        check("continue runs it on", henge_vm_continue() == 0 && henge_vm_state() == 1);
        for (int n = 0; n < 1000 && *count == c1; n++) usleep(1000);
        check_microphone_resume();
        check("continued: the counter moves", *count > c1);
        rc = henge_vm_suspend(snap, "test", error, sizeof error);
        uint64_t c2 = *count;
        check("second suspend saves", rc == 0 && c2 > c1);
        henge_vm_stop();
        check("a paused Mac stops", henge_vm_state() == 2 && hv_vm_board()->ram == NULL);
        uint64_t bytes = 0;
        check("the save is whole", henge_vm_saved_ok(snap, "test", &bytes, NULL) == 0 && bytes > 0);
        check("another ident is refused", henge_vm_saved_ok(snap, "other", NULL, NULL) != 0);
        rc = henge_vm_resume(rom, disk, aux, 1, 0, 64, 2, snap, "other", error, sizeof error);
        check("resume with another ident fails and leaves it startable", rc != 0 && henge_vm_can_start());
        check("a failed resume uses the file up too", access(snap, F_OK) != 0);
        /* Save again (the failed resume took the file), then resume it properly. */
        rc = henge_vm_boot(rom, disk, aux, 1, 0, 64, 2, error, sizeof error);
        usleep(30000);
        /* Older iOS snapshots can contain both touchscreen and hardware scroll contacts. */
        henge_vm_touch(1, 0, 1000, 1000, 100);
        henge_vm_touch(14, 0, 3000, 2000, 100);
        henge_vm_touch(15, 0, 3600, 2000, 100);
        for (int i = 0; i < HV_TP_REPORTS; i++) henge_vm_touch_frame(101 + i);
        rc |= henge_vm_pause(error, sizeof error);
        seed_microphone();
        rc |= henge_vm_save(snap, "test", error, sizeof error);
        c2 = *(volatile uint64_t *)hv_vm_board()->ram;
        henge_vm_stop();
        rc |= henge_vm_resume(rom, disk, aux, 1, 0, 64, 2, snap, "test", error, sizeof error);
        if (rc) fprintf(stderr, "resume: %s\n", error);
        check("resume starts the saved Mac", rc == 0 && henge_vm_state() == 1);
        check("the file is used once", access(snap, F_OK) != 0);
        if (rc == 0) {
            check_microphone_resume();
            HvXhci *usb = hv_vm_board()->usb;
            pthread_mutex_lock(&usb->mu);
            unsigned stop = (usb->tp_rtail - 2) % HV_TP_REPORTS, last = (usb->tp_rtail - 1) % HV_TP_REPORTS;
            const uint8_t *report = usb->tp_reports[stop];
            check("resume delivers both old contacts lifting", usb->tp_rlen[stop] == 12 + 3 * 9 &&
                  report[12 + 9 + 3] >> 5 == 7 && report[12 + 18 + 3] >> 5 == 7);
            check("resume keeps the touchscreen contact", usb->tp_rlen[last] == 12 + 9 &&
                  (usb->tp_reports[last][12 + 8] & 15) == 1 && usb->tp_reports[last][12 + 3] >> 5 == 4);
            pthread_mutex_unlock(&usb->mu);
        }
        count = (volatile uint64_t *)hv_vm_board()->ram;
        check("resumed: the counter is where it was", *count >= c2);
        for (int n = 0; n < 1000 && *count == c2; n++) usleep(1000);
        check("resumed: the counter moves on", *count > c2);
        henge_vm_stop();
        for (int n = 0; n < 3000 && henge_vm_state() != 2; n++) usleep(1000);
        check("resumed Mac stops", henge_vm_state() == 2);
        /* A disk written after the save: the saved Mac must not come back over it. */
        rc = henge_vm_boot(rom, disk, aux, 1, 0, 64, 2, error, sizeof error);
        usleep(30000);
        rc |= henge_vm_suspend(snap, "test", error, sizeof error);
        henge_vm_stop();
        int dfd = open(disk, O_WRONLY);
        check("disk changed", dfd >= 0 && pwrite(dfd, "x", 1, 4096) == 1);
        if (dfd >= 0) close(dfd);
        check("save before the disk changes", rc == 0);
        rc = henge_vm_resume(rom, disk, aux, 1, 0, 64, 2, snap, "test", error, sizeof error);
        check("a changed disk refuses the saved Mac", rc != 0 && strstr(error, "disk has changed") != NULL);
        check("refused, it can start from cold", henge_vm_state() == 0 && henge_vm_can_start());
        unlink(snap);
    }
    /* A device install: when its machine stops, the restore tools let go of its USB port and the machine is
       released, so a device starts in the same launch (it used to need Henge quit and opened again). */
    {
        uint32_t spin[] = {0x14000000};
        write_file(rom, spin, sizeof spin);
        setenv("HV_VUSB_PROBE", "1", 1);
        install_result = HV_INSTALL_BUSY;
        check("overlapping restore can retry without detaching the previous service",
              henge_vm_install(rom, disk, aux, 1, "none.ipsw", dir, 64, 2, error, sizeof error) != 0 &&
              strstr(error, "previous restore") && detached == 0 && henge_vm_can_start());
        install_result = -1;
        check("failed install start reports an error",
              henge_vm_install(rom, disk, aux, 1, "none.ipsw", dir, 64, 2, error, sizeof error) != 0);
        check("failed install detaches the restore tools and allows a start",
              detached == 1 && henge_vm_state() == 0 && henge_vm_can_start());
        install_result = 0;
        int rc = henge_vm_install(rom, disk, aux, 1, "none.ipsw", dir, 64, 2, error, sizeof error);
        if (rc) fprintf(stderr, "install: %s\n", error);
        check("install starts", rc == 0 && henge_vm_state() == 1);
        check("nothing else starts while it runs", !henge_vm_can_start());
        henge_vm_stop();
        for (int n = 0; n < 3000 && henge_vm_state() != 2; n++) usleep(1000);
        check("install's machine stops", henge_vm_state() == 2);
        check("restore tools detached", detached == 2);
        check("install's machine released", hv_vm_board()->ram == NULL && hv_vm_board()->vusb == NULL);
        check("a device can start after an install", henge_vm_can_start());
        unsetenv("HV_VUSB_PROBE");
        rc = henge_vm_boot(rom, disk, aux, 1, 0, 64, 2, error, sizeof error);
        check("a device boots after an install without quitting", rc == 0);
        henge_vm_stop();
        for (int n = 0; n < 3000 && henge_vm_state() != 2; n++) usleep(1000);
        check("and stops", henge_vm_state() == 2);
    }
    hv_vm_destroy();
    atomic_store(&reader_done, 1);
    pthread_join(reader, NULL);
    hv_jit_region_close(&jit);
    unlink(rom); unlink(disk); unlink(aux); rmdir(dir);
    printf("VM lifecycle: memory preparation, 12 power cycles, failed boots/installs, suspend/resume and boot after install, %d failures\n", failures);
    return failures != 0;
}
