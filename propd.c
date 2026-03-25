/*
 * propd.c — minimal Android property service for recovery
 *
 * Listens on /dev/socket/property_service so adbd can write sys.powerctl.
 * Handles:
 *   adb reboot            → LINUX_REBOOT_CMD_RESTART  (normal boot)
 *   adb reboot bootloader → LINUX_REBOOT_CMD_RESTART2("bootloader")
 *   adb reboot recovery   → LINUX_REBOOT_CMD_RESTART2("recovery")
 *
 * Protocol: Android property service v2 (PROP_MSG_SETPROP2 = 0x23)
 *   uint32_t cmd
 *   uint32_t key_len  + key bytes
 *   uint32_t val_len  + val bytes
 *   → respond uint32_t 0 (success)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <linux/reboot.h>
#include <stdint.h>

#define PROP_SERVICE_SOCKET "/dev/socket/property_service"
#define PROP_MSG_SETPROP2   0x00000023u

static int read_exact(int fd, void *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = read(fd, (char*)buf + done, len - done);
        if (n <= 0) return -1;
        done += n;
    }
    return 0;
}

static int write_exact(int fd, const void *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, (const char*)buf + done, len - done);
        if (n <= 0) return -1;
        done += n;
    }
    return 0;
}

static char *read_lpstring(int fd) {
    uint32_t len;
    if (read_exact(fd, &len, 4) < 0) return NULL;
    if (len > 4096) return NULL;
    char *buf = malloc(len + 1);
    if (!buf) return NULL;
    if (len > 0 && read_exact(fd, buf, len) < 0) { free(buf); return NULL; }
    buf[len] = '\0';
    return buf;
}

static void do_reboot(const char *arg) {
    sync();
    if (arg && *arg) {
        /* Named reboot — bootloader interprets the string */
        syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                LINUX_REBOOT_CMD_RESTART2, arg);
    }
    /* Plain reboot (normal boot) — fallback */
    int fd = open("/proc/sysrq-trigger", O_WRONLY);
    if (fd >= 0) { write(fd, "b", 1); close(fd); }
}

static void handle_powerctl(const char *value) {
    /* value: "reboot,<arg>" */
    const char *arg = "";
    const char *comma = strchr(value, ',');
    if (comma) arg = comma + 1;
    do_reboot(arg);
}

int main(void) {
    /* Enable sysrq just in case */
    int fd = open("/proc/sys/kernel/sysrq", O_WRONLY);
    if (fd >= 0) { write(fd, "1", 1); close(fd); }

    mkdir("/dev/socket", 0755);
    unlink(PROP_SERVICE_SOCKET);

    int srv = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (srv < 0) { perror("propd: socket"); return 1; }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, PROP_SERVICE_SOCKET, sizeof(addr.sun_path) - 1);
    if (bind(srv, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("propd: bind"); return 1;
    }
    chmod(PROP_SERVICE_SOCKET, 0777);
    listen(srv, 8);

    while (1) {
        int cli = accept(srv, NULL, NULL);
        if (cli < 0) continue;

        uint32_t cmd = 0;
        if (read_exact(cli, &cmd, 4) == 0 && cmd == PROP_MSG_SETPROP2) {
            char *key = read_lpstring(cli);
            char *val = read_lpstring(cli);
            uint32_t result = 0;
            write_exact(cli, &result, 4);
            close(cli);
            if (key && val && strcmp(key, "sys.powerctl") == 0) {
                handle_powerctl(val);
            }
            free(key);
            free(val);
        } else {
            close(cli);
        }
    }
    return 0;
}
