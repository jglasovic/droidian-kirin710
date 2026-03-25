#!/bin/sh
# adbd-ffs-setup.sh — set up configfs ADB gadget + mount FFS without requiring UDC
# Replaces adbd-usb-gadget setup, which exits early if no UDC is present at boot
# (causing adbd to fail when cable is connected after boot)
CONFIGFS_DIR="/sys/kernel/config/usb_gadget/g1"

# Trigger DWC3 device mode — on Kirin 710 the dual-role controller does not
# switch automatically at boot; without this the UDC never appears in sysfs.
if [ -w /sys/class/dual_role_usb/otg_default/mode ]; then
    echo device > /sys/class/dual_role_usb/otg_default/mode 2>/dev/null || true
fi

# Mount configfs if not already mounted
mount -t configfs none /sys/kernel/config 2>/dev/null || true

mkdir -p "${CONFIGFS_DIR}/configs/c.1"
cd "${CONFIGFS_DIR}"

mkdir -p strings/0x409
mkdir -p configs/c.1/strings/0x409

echo 0x0100 > idProduct
echo 0x18D1 > idVendor
echo "Debian"     > strings/0x409/manufacturer
echo "ADB device" > strings/0x409/product
echo "$(sha256sum < /etc/machine-id | cut -d' ' -f1)" > strings/0x409/serialnumber
echo "ADB Configuration" > configs/c.1/strings/0x409/configuration
echo 120 > configs/c.1/MaxPower

mkdir -p functions/ffs.adb
[ -e configs/c.1/ffs.adb ] || ln -s functions/ffs.adb configs/c.1

mkdir -p /dev/usb-ffs/adb
mount -t functionfs adb /dev/usb-ffs/adb 2>/dev/null || true
