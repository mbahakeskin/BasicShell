// A virtual pointer that stays: reads commands from stdin, one per line, and
// plays them on a wlroots compositor's seat through wlr-virtual-pointer.
//
//   vpointer <width> <height>
//   move X Y | down [left|right|middle] | up [...] | click [...] | scroll N | wait MS
#include <linux/input-event-codes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct zwlr_virtual_pointer_manager_v1 *manager;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version)
{
    if (!strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name))
        manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) { }

static const struct wl_registry_listener listener = { global, global_remove };

static uint32_t now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static uint32_t button(const char *name)
{
    if (name && !strcmp(name, "right"))
        return BTN_RIGHT;
    if (name && !strcmp(name, "middle"))
        return BTN_MIDDLE;
    return BTN_LEFT;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: vpointer <width> <height>\n");
        return 2;
    }
    uint32_t width = atoi(argv[1]), height = atoi(argv[2]);
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "no Wayland display\n");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &listener, NULL);
    wl_display_roundtrip(display);
    if (!manager) {
        fprintf(stderr, "the compositor has no wlr-virtual-pointer\n");
        return 1;
    }
    struct zwlr_virtual_pointer_v1 *pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, NULL);
    wl_display_roundtrip(display);

    char line[256];
    while (fgets(line, sizeof line, stdin)) {
        char verb[32] = "", arg1[32] = "", arg2[32] = "";
        if (sscanf(line, "%31s %31s %31s", verb, arg1, arg2) < 1)
            continue;
        if (!strcmp(verb, "move")) {
            zwlr_virtual_pointer_v1_motion_absolute(pointer, now(), atoi(arg1), atoi(arg2), width, height);
            zwlr_virtual_pointer_v1_frame(pointer);
        } else if (!strcmp(verb, "down") || !strcmp(verb, "up") || !strcmp(verb, "click")) {
            uint32_t which = button(arg1[0] ? arg1 : NULL);
            if (strcmp(verb, "up")) {
                zwlr_virtual_pointer_v1_button(pointer, now(), which, WL_POINTER_BUTTON_STATE_PRESSED);
                zwlr_virtual_pointer_v1_frame(pointer);
            }
            if (!strcmp(verb, "click")) {
                wl_display_flush(display);
                struct timespec pause = { 0, 50 * 1000000 };
                nanosleep(&pause, NULL);
            }
            if (strcmp(verb, "down")) {
                zwlr_virtual_pointer_v1_button(pointer, now(), which, WL_POINTER_BUTTON_STATE_RELEASED);
                zwlr_virtual_pointer_v1_frame(pointer);
            }
        } else if (!strcmp(verb, "scroll")) {
            zwlr_virtual_pointer_v1_axis_source(pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
            zwlr_virtual_pointer_v1_axis_discrete(pointer, now(), WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_int(15 * atoi(arg1)), atoi(arg1));
            zwlr_virtual_pointer_v1_frame(pointer);
        } else if (!strcmp(verb, "wait")) {
            wl_display_flush(display);
            int ms = atoi(arg1);
            struct timespec pause = { ms / 1000, (ms % 1000) * 1000000 };
            nanosleep(&pause, NULL);
        }
        wl_display_roundtrip(display);
    }
    zwlr_virtual_pointer_v1_destroy(pointer);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    return 0;
}
