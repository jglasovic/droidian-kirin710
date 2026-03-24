#!/bin/sh
# adbd-ffs-setup.sh — create USB gadget configfs structure and mount FunctionFS for ADB
#
# Safe to run without a cable / UDC connected — does NOT bind to UDC.
# UDC binding happens in adbd-udc-wait.sh after adbd writes its descriptors to ep0.

G=/sys/kernel/config/usb_gadget/g1
LOG="/dev/kmsg"

log() { echo "adbd-ffs-setup: $1" > "$LOG" 2>/dev/null || true; }

# Skip if already configured
if [ -d "$G" ]; then
    log "gadget already configured, skipping"
    exit 0
fi

log "configuring ADB gadget..."

mkdir -p "$G"
echo 0x18d1 > "$G/idVendor"    # Google
echo 0x4e26 > "$G/idProduct"   # ADB
mkdir -p "$G/strings/0x409"
echo "Droidian"   > "$G/strings/0x409/manufacturer"
echo "Kirin710"   > "$G/strings/0x409/product"
echo "0123456789" > "$G/strings/0x409/serialnumber"

mkdir -p "$G/functions/ffs.adb"

mkdir -p "$G/configs/c.1/strings/0x409"
echo "adb" > "$G/configs/c.1/strings/0x409/configuration"
echo 250    > "$G/configs/c.1/MaxPower"

ln -sf "$G/functions/ffs.adb" "$G/configs/c.1/ffs.adb"

mkdir -p /dev/usb-ffs/adb
mount -t functionfs adb /dev/usb-ffs/adb

log "gadget configured, FFS mounted at /dev/usb-ffs/adb"
