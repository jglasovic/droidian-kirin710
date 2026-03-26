/*
 * libprop-fix.c — override Android property_set to use /dev/socket/property_service
 *
 * The Debian libcutils property_set uses Android shared memory (/dev/__properties__)
 * which doesn't exist in recovery.  This LD_PRELOAD shim replaces the two property
 * write functions with a real socket client so adbd's SetProperty("sys.powerctl")
 * reaches propd and triggers the actual reboot.
 */
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>

#define PROP_SERVICE_SOCKET "/dev/socket/property_service"
#define PROP_NAME_MAX 32
#define PROP_VALUE_MAX 92

static void w32(int fd, uint32_t v) { write(fd, &v, 4); }
static void wstr(int fd, const char *s) {
    uint32_t len = s ? strlen(s) : 0;
    w32(fd, len);
    if (len) write(fd, s, len);
}

static int propd_set(const char *key, const char *value) {
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, PROP_SERVICE_SOCKET, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    /* v2 protocol (PROP_MSG_SETPROP2 = 0x23) */
    w32(fd, 0x23u);
    wstr(fd, key);
    wstr(fd, value ? value : "");
    uint32_t result = 0;
    read(fd, &result, 4);
    close(fd);
    return (int)result;
}

int __system_property_set(const char *key, const char *value) {
    return propd_set(key, value);
}

int property_set(const char *key, const char *value) {
    return propd_set(key, value);
}

/* Stub read functions — adbd only needs to write sys.powerctl */
int __system_property_get(const char *name, char *value) {
    (void)name;
    if (value) value[0] = '\0';
    return 0;
}

int property_get(const char *key, char *value, const char *default_value) {
    (void)key;
    if (value) {
        if (default_value) strncpy(value, default_value, PROP_VALUE_MAX - 1);
        else value[0] = '\0';
    }
    return value ? (int)strlen(value) : 0;
}
