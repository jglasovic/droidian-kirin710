#!/bin/sh
# adbd-udc-wait.sh — wait for UDC + adbd descriptors, then bind the ADB gadget
#
# Runs as ExecStartPost of adbd.service.
# Waits up to 300s for a USB cable (UDC) and for adbd to write its FFS descriptors,
# then binds the gadget to activate ADB over USB.

G=/sys/kernel/config/usb_gadget/g1
LOG="/dev/kmsg"

log() { echo "adbd-udc-wait: $1" > "$LOG" 2>/dev/null || true; }

log "waiting for UDC and FFS descriptors..."

UDC=""
for i in $(seq 1 150); do
    UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
    # Also check adbd wrote its descriptors (ep1 + ep2 appear after ep0 is written)
    if [ -n "$UDC" ] && [ -e /dev/usb-ffs/adb/ep1 ]; then
        break
    fi
    sleep 2
done

if [ -z "$UDC" ]; then
    log "no UDC after 300s (no cable connected) — exiting"
    exit 0
fi

if [ ! -e /dev/usb-ffs/adb/ep1 ]; then
    log "UDC found ($UDC) but adbd has not written FFS descriptors yet — exiting"
    exit 1
fi

log "binding gadget to UDC: $UDC"
echo "$UDC" > "$G/UDC" && log "ADB gadget activated on $UDC" || log "bind failed"
