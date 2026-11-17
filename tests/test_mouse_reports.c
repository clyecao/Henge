#include "vm.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Exercise the actual pointer queue and virtio event ring without running a
   guest CPU. The consumer deliberately retains omitted relative axes, as the
   macOS mouse driver does; scrolling/clicking must not replay an earlier move. */
static int checks, failures;
static void check(const char *what, int ok) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

static void fixture(const char *path, const void *data, size_t size) {
    int fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0 || (data && write(fd, data, size) != (ssize_t)size) || ftruncate(fd, size)) exit(1);
    close(fd);
}

/* Both axes nonzero: the final marker is detectable even with the old encoder. */
#define END_X 12345
#define END_Y (-23456)
static int marker_ready(HvVirtioInput *mouse) {
    int ready = 0;
    pthread_mutex_lock(&mouse->mu);
    if (mouse->tail - mouse->head >= 3) {
        uint32_t x = (mouse->tail - 3) % HV_VINPUT_RING;
        uint32_t y = (mouse->tail - 2) % HV_VINPUT_RING;
        uint32_t syn = (mouse->tail - 1) % HV_VINPUT_RING;
        ready = mouse->ring[x].type == HV_EV_REL && mouse->ring[x].code == HV_REL_X &&
                (int32_t)mouse->ring[x].value == END_X &&
                mouse->ring[y].type == HV_EV_REL && mouse->ring[y].code == HV_REL_Y &&
                (int32_t)mouse->ring[y].value == END_Y && mouse->ring[syn].type == HV_EV_SYN;
    }
    pthread_mutex_unlock(&mouse->mu);
    return ready;
}

typedef struct Report {
    int dx, dy;
    uint16_t type, code;
    int value;
} Report;

#define MOVE(x, y) {x, y, 0, 0, 0}
#define BUTTON(b, down) {0, 0, HV_EV_KEY, b, down}
#define WHEEL(axis, n) {0, 0, HV_EV_REL, axis, n}
static const Report expected[] = {
    MOVE(13, -7), WHEEL(HV_REL_WHEEL, 3), WHEEL(HV_REL_HWHEEL, -2),
    MOVE(5, 0), MOVE(0, 4), MOVE(0, 0),
    BUTTON(HV_BTN_LEFT, 1), BUTTON(HV_BTN_LEFT, 0),
    BUTTON(HV_BTN_MIDDLE, 1), BUTTON(HV_BTN_MIDDLE, 0),
    BUTTON(HV_BTN_LEFT, 1), /* right click: Control + left, including a 50 ms delay */
    WHEEL(HV_REL_WHEEL, 100), WHEEL(HV_REL_WHEEL, 100), WHEEL(HV_REL_WHEEL, 50),
    BUTTON(HV_BTN_LEFT, 0),
    WHEEL(HV_REL_WHEEL, -100), WHEEL(HV_REL_WHEEL, -100), WHEEL(HV_REL_WHEEL, -50),
    WHEEL(HV_REL_HWHEEL, 100), WHEEL(HV_REL_HWHEEL, 100), WHEEL(HV_REL_HWHEEL, 5),
    WHEEL(HV_REL_HWHEEL, -100), WHEEL(HV_REL_HWHEEL, -100), WHEEL(HV_REL_HWHEEL, -5),
    MOVE(-2, -3), MOVE(END_X, END_Y),
};

static void verify_reports(HvVirtioInput *mouse) {
    int dx = 0, dy = 0, x = 0, y = 0, want_x = 0, want_y = 0;
    unsigned axes = 0, report = 0;
    uint16_t type = 0, code = 0;
    int value = 0;
    pthread_mutex_lock(&mouse->mu);
    check("event ring did not overflow", mouse->dropped == 0);
    for (uint32_t at = mouse->head; at != mouse->tail; at++) {
        uint32_t i = at % HV_VINPUT_RING;
        uint16_t t = mouse->ring[i].type, c = mouse->ring[i].code;
        int32_t v = (int32_t)mouse->ring[i].value;
        if (t == HV_EV_REL && c == HV_REL_X) dx = v, axes |= 1;
        else if (t == HV_EV_REL && c == HV_REL_Y) dy = v, axes |= 2;
        else if (t != HV_EV_SYN) type = t, code = c, value = v;
        else {
            x += dx, y += dy;
            if (report < sizeof expected / sizeof *expected) {
                const Report *want = &expected[report];
                want_x += want->dx, want_y += want->dy;
                char label[100];
                snprintf(label, sizeof label, "report %u: both motion axes are explicit", report);
                check(label, axes == 3);
                snprintf(label, sizeof label, "report %u: scroll/click preserves pointer position", report);
                check(label, x == want_x && y == want_y);
                snprintf(label, sizeof label, "report %u: event order, button state and wheel direction", report);
                check(label, type == want->type && code == want->code && value == want->value);
            }
            report++;
            axes = 0, type = code = 0, value = 0;
            /* dx/dy intentionally persist across reports, matching the guest. */
        }
    }
    check("no reports lost or added for zero scroll", report == sizeof expected / sizeof *expected);
    check("no partial report at the end", axes == 0 && type == 0);
    pthread_mutex_unlock(&mouse->mu);
}

int main(void) {
    alarm(20);
    char dir[] = "/tmp/henge-mouse-XXXXXX", rom[256], disk[256], aux[256], ram[256], error[256];
    if (!mkdtemp(dir)) return 1;
    snprintf(rom, sizeof rom, "%s/rom", dir);
    snprintf(disk, sizeof disk, "%s/disk", dir);
    snprintf(aux, sizeof aux, "%s/aux", dir);
    snprintf(ram, sizeof ram, "%s/ram", dir);
    uint32_t nop = 0xd503201f;
    fixture(rom, &nop, sizeof nop); /* our own instruction, no Apple boot assets */
    fixture(disk, NULL, 1 << 20);
    fixture(aux, NULL, 1 << 20);
    setenv("HV_RAM_FILE", ram, 1);
    setenv("HV_BALLOON", "0", 1);
    HvVmConfig config = {.rom = rom, .disk = disk, .aux = aux, .ram_mb = 64, .ncpus = 1,
                         .no_net = 1, .no_sound = 1, .jit_bytes = 4 << 20};
    int rc = hv_vm_create(&config, error, sizeof error);
    check("create input devices without booting macOS", rc == 0);
    if (rc) fprintf(stderr, "%s\n", error);
    else {
        hv_vm_mouse_move(13, -7);
        hv_vm_mouse_wheel(3);
        hv_vm_mouse_hwheel(-2);
        hv_vm_mouse_move(5, 0);
        hv_vm_mouse_move(0, 4);
        hv_vm_mouse_move(0, 0);
        hv_vm_mouse_button(0, 1);
        hv_vm_mouse_button(0, 0);
        hv_vm_mouse_button(2, 1);
        hv_vm_mouse_button(2, 0);
        hv_vm_mouse_button(1, 1);
        hv_vm_mouse_wheel(250); /* must wait behind the delayed Control-click */
        hv_vm_mouse_button(1, 0);
        hv_vm_mouse_wheel(-250);
        hv_vm_mouse_hwheel(205);
        hv_vm_mouse_hwheel(-205);
        hv_vm_mouse_move(-2, -3);
        hv_vm_mouse_wheel(0);
        hv_vm_mouse_hwheel(0);
        hv_vm_mouse_move(END_X, END_Y);
        HvVirtioInput *mouse = hv_vm_board()->mouse;
        for (int i = 0; i < 5000 && !marker_ready(mouse); i++) usleep(1000);
        check("pointer queue reaches final marker", marker_ready(mouse));
        verify_reports(mouse);
        /* Teardown must drain or discard queued scrolls before freeing mouse. */
        hv_vm_mouse_button(1, 1);
        for (int i = 0; i < 50; i++) hv_vm_mouse_wheel(32), hv_vm_mouse_hwheel(-32);
        hv_vm_mouse_button(1, 0);
    }
    hv_vm_destroy();
    check("teardown releases input devices", hv_vm_board()->mouse == NULL);
    unlink(rom); unlink(disk); unlink(aux); unlink(ram); rmdir(dir);
    printf("Mouse reports: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
