#!/bin/sh
# adbd-ffs-teardown.sh — unbind and remove ADB USB gadget on adbd stop

G=/sys/kernel/config/usb_gadget/g1
LOG="/dev/kmsg"

log() { echo "adbd-ffs-teardown: $1" > "$LOG" 2>/dev/null || true; }

log "tearing down ADB gadget..."

# Unbind UDC first
echo "" > "$G/UDC" 2>/dev/null || true

# Remove config link and config
rm -f "$G/configs/c.1/ffs.adb"
rmdir "$G/configs/c.1/strings/0x409" 2>/dev/null || true
rmdir "$G/configs/c.1" 2>/dev/null || true

# Remove function
rmdir "$G/functions/ffs.adb" 2>/dev/null || true

# Remove strings and gadget
rmdir "$G/strings/0x409" 2>/dev/null || true
rmdir "$G" 2>/dev/null || true

# Unmount FunctionFS
umount /dev/usb-ffs/adb 2>/dev/null || true

log "teardown complete"
