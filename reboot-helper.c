/*
 * reboot-helper.c — call reboot(2) syscall directly
 *
 * Usage: reboot-helper [target]
 *   reboot-helper            → LINUX_REBOOT_CMD_RESTART  (normal reboot)
 *   reboot-helper bootloader → LINUX_REBOOT_CMD_RESTART2("bootloader")
 *   reboot-helper recovery   → LINUX_REBOOT_CMD_RESTART2("recovery")
 */
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/reboot.h>

int main(int argc, char **argv) {
    sync();
    if (argc > 1 && argv[1][0]) {
        syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                LINUX_REBOOT_CMD_RESTART2, argv[1]);
    }
    syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
            LINUX_REBOOT_CMD_RESTART, 0);
    return 1;
}
