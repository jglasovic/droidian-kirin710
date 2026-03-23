#!/bin/sh
# adbd-udc-wait.sh — wait for UDC to appear then activate the ADB gadget
#
# Kirin 710 DWC3 UDC takes ~110s to appear in sysfs after boot.
# adbd-usb-gadget setup mounts FFS and creates the gadget config but does
# not bind to UDC. This script polls for the UDC then calls activate.
set -e

CONFIGFS_DIR="/sys/kernel/config/usb_gadget/g1"

echo "adbd-udc-wait: polling for UDC..." > /dev/kmsg 2>/dev/null || true

UDC=""
for i in $(seq 1 60); do
    UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
    [ -n "$UDC" ] && break
    sleep 2
done

if [ -z "$UDC" ]; then
    echo "adbd-udc-wait: ERROR: no UDC after 120s" > /dev/kmsg 2>/dev/null || true
    exit 1
fi

echo "adbd-udc-wait: UDC found: $UDC" > /dev/kmsg 2>/dev/null || true
echo "$UDC" > "$CONFIGFS_DIR/UDC"
echo "adbd-udc-wait: ADB gadget activated on $UDC" > /dev/kmsg 2>/dev/null || true
