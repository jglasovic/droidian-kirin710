#!/bin/sh
# adbd-udc-bind.sh — triggered by udev when UDC appears (cable connected)
#
# Called via udev rule: 99-adbd-udc.rules
# KERNEL env var is set by udev to the UDC device name (e.g. ff100000.dwc3)

G=/sys/kernel/config/usb_gadget/g1
LOG="/dev/kmsg"
log() { echo "adbd-udc-bind: $1" > "$LOG" 2>/dev/null || true; }

# Only act if our gadget is configured but not yet bound
[ -d "$G" ] || exit 0
CURRENT_UDC=$(cat "$G/UDC" 2>/dev/null)
[ -n "$CURRENT_UDC" ] && exit 0  # already bound

UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
log "UDC appeared: $UDC — waiting for FFS descriptors..."

# Wait for adbd to write FFS descriptors (ep1 appears after ep0 is written)
for i in $(seq 1 10); do
    [ -e /dev/usb-ffs/adb/ep1 ] && break
    sleep 1
done

if [ ! -e /dev/usb-ffs/adb/ep1 ]; then
    log "ep1 not ready after 10s — adbd may not be running"
    exit 1
fi

log "binding gadget to UDC: $UDC"
echo "$UDC" > "$G/UDC" && log "ADB gadget activated on $UDC" || log "bind failed"
