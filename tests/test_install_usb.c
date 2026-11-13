#include "usb_host.h"
#include <libusb-1.0/libusb.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static HvMachine machine;
static int failures;

static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

static void attach(HvVirtioUsb *usb, uint16_t product) {
    usb->vio.m = &machine;
    hv_vusb_set_online(usb, 1);
    hv_libusb_shim_attach(usb);
    struct libusb_device_descriptor descriptor = {.bLength = 18, .bDescriptorType = 1, .idProduct = product};
    hv_vusb_put_response(usb, HV_VUSB_RSP_RESET, 0, NULL, 0);
    hv_vusb_put_response(usb, HV_VUSB_RSP_DATA, 0, &descriptor, sizeof descriptor);
}

static libusb_device_handle *open_port(HvVirtioUsb *usb, uint16_t product) {
    libusb_device **list = NULL;
    libusb_device_handle *handle = NULL;
    if (libusb_get_device_list(NULL, &list) == 1) {
        struct libusb_device_descriptor descriptor;
        check("enumerated the new VM", libusb_get_device_descriptor(list[0], &descriptor) == 0 && descriptor.idProduct == product);
        check("opened restore port", libusb_open(list[0], &handle) == 0);
    }
    libusb_free_device_list(list, 1);
    if (!handle) exit(1);
    HvVusbMsg msg;
    while (hv_vusb_take_request(usb, &msg)) free(msg.data);
    return handle;
}

static int reset_result;
static void *reset_port(void *handle) {
    reset_result = libusb_reset_device(handle);
    return NULL;
}

int main(void) {
    alarm(15);
    HvVirtioUsb first = {.mu = PTHREAD_MUTEX_INITIALIZER, .cv = PTHREAD_COND_INITIALIZER};
    HvVirtioUsb second = {.mu = PTHREAD_MUTEX_INITIALIZER, .cv = PTHREAD_COND_INITIALIZER};
    attach(&first, 1);
    libusb_device_handle *old = open_port(&first, 1);
    pthread_t waiter;
    if (pthread_create(&waiter, NULL, reset_port, old)) return 1;
    HvVusbMsg msg;
    while (!hv_vusb_take_request(&first, &msg)) usleep(1000);
    check("old reset is in flight", msg.type == HV_VUSB_REQ_RESET);
    free(msg.data);
    hv_libusb_shim_detach();
    pthread_join(waiter, NULL);
    check("detaching wakes the blocked caller", reset_result == LIBUSB_ERROR_NO_DEVICE);

    /* Reattach before libusb has polled the disconnect. Both ports have USB session number 1. */
    attach(&second, 2);
    check("old handle refused before re-enumeration", libusb_reset_device(old) == LIBUSB_ERROR_NO_DEVICE);
    check("old handle sent nothing to the new VM", !hv_vusb_take_request(&second, &msg));
    libusb_device_handle *current = open_port(&second, 2);
    hv_vusb_put_response(&second, HV_VUSB_RSP_RESET, 0, NULL, 0);
    check("new port accepts its own handle", libusb_reset_device(current) == 0);
    hv_libusb_shim_detach();
    libusb_close(old);
    libusb_close(current);
    libusb_device **list = NULL;
    check("no device after detach", libusb_get_device_list(NULL, &list) == 0);
    libusb_free_device_list(list, 1);
    printf("Installer USB: detach during I/O, stale handle and same-session reattach, %d failures\n", failures);
    return failures != 0;
}
