#!/usr/bin/env bash
# patch-rootfs.sh — apply Kirin 710 device config to rootfs.img
#
# Bakes in static device configuration so that on first boot:
#   - USB NCM network (10.15.19.82/24) + ADB over TCP:5555
#   - android-rootfs.img is loop-mounted at /android/system
#   - vendor partition is mounted (WiFi firmware)
#   - Hi1102 WiFi chip is initialized
#   - wpa_supplicant runs in safe interface mode (D-Bus mode masked)
#
# After first boot the user still needs to:
#   - Create /etc/wpa_supplicant/wpa_supplicant.conf with WiFi credentials
#
# Usage:
#   sudo bash patch-rootfs.sh [rootfs.img]
set -euo pipefail

ROOTFS="${1:-rootfs.img}"

if [ ! -f "$ROOTFS" ]; then
  echo "[FAIL] $ROOTFS not found"
  exit 1
fi

# Expand image by 500MB so apt has room to install packages
echo "[*] Expanding $ROOTFS by 500MB..."
dd if=/dev/zero bs=1M count=500 >> "$ROOTFS"
e2fsck -f -y "$ROOTFS" || true
resize2fs "$ROOTFS"

MNT=$(mktemp -d)
echo "[*] Mounting $ROOTFS at $MNT..."
mount -o loop "$ROOTFS" "$MNT"

cleanup() {
  umount "$MNT/dev" 2>/dev/null || true
  umount "$MNT/sys" 2>/dev/null || true
  umount "$MNT/proc" 2>/dev/null || true
  umount "$MNT" 2>/dev/null || true
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

# ── 1. Install and enable ADB over USB ────────────────────────────────────────
echo "[1/5] Installing and enabling ADB over USB..."
# Install adbd into rootfs via chroot (needs qemu-user-static for ARM64 on x86 hosts)
if [ "$(uname -m)" != "aarch64" ] && [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  echo "    Installing qemu-user-static for cross-arch chroot..."
  apt-get update -qq
  apt-get install -y --no-install-recommends qemu-user-static
fi
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"
mount --bind /dev "$MNT/dev"
rm -f "$MNT/etc/resolv.conf"
cp /etc/resolv.conf "$MNT/etc/resolv.conf"
chroot "$MNT" apt-get update -qq
chroot "$MNT" apt-get install -y --no-install-recommends adbd dhcpcd5
chroot "$MNT" apt-get clean
umount "$MNT/dev" "$MNT/sys" "$MNT/proc"
# USB gadget trigger — switches HiSilicon DWC3 into device mode
cat > "$MNT/etc/systemd/system/usb-gadget-trigger.service" << 'UNIT'
[Unit]
Description=Trigger USB gadget mode via HiSilicon DWC3
DefaultDependencies=no
After=sys-kernel-config.mount
Before=usb-rndis.service adbd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo device > /sys/class/dual_role_usb/otg_default/mode 2>/dev/null || true; for i in 1 2 3 4 5; do [ -d /sys/class/udc/ff100000.dwc3 ] && exit 0; sleep 1; done'

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/usb-gadget-trigger.service "$MNT/etc/systemd/system/multi-user.target.wants/usb-gadget-trigger.service"
# USB NCM gadget — provides USB network interface (10.15.19.82/24)
cat > "$MNT/etc/systemd/system/usb-rndis.service" << 'UNIT'
[Unit]
Description=USB NCM Gadget (SSH over USB)
DefaultDependencies=no
After=sys-kernel-config.mount usb-gadget-trigger.service
Wants=usb-gadget-trigger.service
Before=network.target NetworkManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/usb-rndis-setup.sh

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/usb-rndis.service "$MNT/etc/systemd/system/multi-user.target.wants/usb-rndis.service"
mkdir -p "$MNT/usr/local/sbin"
cat > "$MNT/usr/local/sbin/usb-rndis-setup.sh" << 'SCRIPT'
#!/bin/sh
set -e
exec > /tmp/usb-rndis.log 2>&1
set -x

GADGET=/sys/kernel/config/usb_gadget/g1

if ! mount | grep -q "type configfs"; then
    mount -t configfs none /sys/kernel/config 2>/dev/null || true
fi

UDC=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
    [ -n "$UDC" ] && break
    sleep 1
done
if [ -z "$UDC" ]; then
    echo "ERROR: No UDC after 15s" > /dev/kmsg 2>/dev/null || true
    exit 1
fi
echo "UDC found: $UDC"

for g in /sys/kernel/config/usb_gadget/g_debug /sys/kernel/config/usb_gadget/g1; do
    if [ -d "$g" ]; then
        echo "" > $g/UDC 2>/dev/null || true
        rm -f $g/configs/c.1/ncm.usb0 2>/dev/null || true
        rmdir $g/configs/c.1/strings/0x409 2>/dev/null || true
        rmdir $g/configs/c.1 2>/dev/null || true
        rmdir $g/functions/ncm.usb0 2>/dev/null || true
        rmdir $g/strings/0x409 2>/dev/null || true
        rmdir $g 2>/dev/null || true
    fi
done

mkdir -p $GADGET
echo 0x1d6b > $GADGET/idVendor
echo 0x0104 > $GADGET/idProduct
echo 0x0100 > $GADGET/bcdDevice
echo 0x0200 > $GADGET/bcdUSB
mkdir -p $GADGET/strings/0x409
echo "droidian-sne"  > $GADGET/strings/0x409/serialnumber
echo "Droidian"      > $GADGET/strings/0x409/manufacturer
echo "USB Network"   > $GADGET/strings/0x409/product
mkdir -p $GADGET/functions/ncm.usb0
echo "DE:AD:BE:EF:00:01" > $GADGET/functions/ncm.usb0/host_addr
echo "DE:AD:BE:EF:00:02" > $GADGET/functions/ncm.usb0/dev_addr
mkdir -p $GADGET/configs/c.1/strings/0x409
echo "CDC-NCM" > $GADGET/configs/c.1/strings/0x409/configuration
echo 500       > $GADGET/configs/c.1/MaxPower
ln -s $GADGET/functions/ncm.usb0 $GADGET/configs/c.1/

echo "$UDC" > $GADGET/UDC
echo "USB CDC-NCM gadget on $UDC" > /dev/kmsg 2>/dev/null || true

sleep 2
IFACE=""
for i in 1 2 3 4 5 6 7 8 9 10; do
    IFACE=$(ip link show 2>/dev/null | grep -i "de:ad:be:ef:00:02" -B1 | head -1 | sed "s/^[0-9]*: \([^:@]*\).*/\1/")
    [ -n "$IFACE" ] && break
    sleep 1
done

if [ -n "$IFACE" ]; then
    ip link set "$IFACE" up
    ip addr flush dev "$IFACE" 2>/dev/null || true
    ip addr add 10.15.19.82/24 dev "$IFACE"
    echo "USB interface $IFACE up at 10.15.19.82/24" > /dev/kmsg 2>/dev/null || true
else
    echo "WARNING: NCM interface not found" > /dev/kmsg 2>/dev/null || true
    exit 1
fi
SCRIPT
chmod +x "$MNT/usr/local/sbin/usb-rndis-setup.sh"
# adbd TCP — listens on port 5555 (reachable over NCM network)
mkdir -p "$MNT/etc/systemd/system/adbd.service.d"
cat > "$MNT/etc/systemd/system/adbd.service.d/tcp.conf" << 'UNIT'
[Service]
Environment=ADBD_SOCKET=tcp:5555
UNIT
# Enable adbd
ln -sf /usr/lib/systemd/system/adbd.service "$MNT/etc/systemd/system/multi-user.target.wants/adbd.service"
echo "    adbd: OK"

# ── 2. Unmask android-mount service ─────────────────────────────────────────
echo "[2/5] Unmasking android-mount service..."
rm -f "$MNT/etc/systemd/system/android-mount.service"
mkdir -p "$MNT/etc/systemd/system/local-fs.target.requires"
ln -sf /lib/systemd/system/android-mount.service "$MNT/etc/systemd/system/local-fs.target.requires/android-mount.service"
echo "    android-mount: OK"

# ── 3. Vendor partition mount ───────────────────────────────────────────────
echo "[3/5] Adding vendor partition mount..."
cat > "$MNT/etc/systemd/system/android-system-vendor.mount" << 'UNIT'
[Unit]
Description=Mount Android vendor partition
RequiresMountsFor=/android/system
After=android-mount.service
Before=local-fs.target

[Mount]
What=/dev/disk/by-partlabel/vendor_a
Where=/android/system/vendor
Type=auto
Options=ro
TimeoutSec=30

[Install]
WantedBy=local-fs.target
UNIT
mkdir -p "$MNT/etc/systemd/system/local-fs.target.wants"
ln -sf /etc/systemd/system/android-system-vendor.mount "$MNT/etc/systemd/system/local-fs.target.wants/android-system-vendor.mount"
echo "    vendor mount: OK"

# ── 4. Hi1102 WiFi init service ────────────────────────────────────────────
echo "[4/5] Adding Hi1102 WiFi init service..."
cat > "$MNT/etc/systemd/system/hisi-wifi-init.service" << 'UNIT'
[Unit]
Description=Initialize Hi1102 WiFi
After=android-system-vendor.mount
Before=NetworkManager.service
Requires=android-system-vendor.mount

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo init > /sys/hisys/boot/plat && sleep 2 && echo init > /sys/hisys/boot/wifi && sleep 3"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/hisi-wifi-init.service "$MNT/etc/systemd/system/multi-user.target.wants/hisi-wifi-init.service"
echo "    hisi-wifi-init: OK"

# ── 5. wpa_supplicant in interface mode ─────────────────────────────────────
echo "[5/5] Setting up wpa_supplicant (interface mode, D-Bus masked)..."
# Mask D-Bus mode wpa_supplicant (causes 100% CPU spin with Hi1102)
ln -sf /dev/null "$MNT/etc/systemd/system/wpa_supplicant.service"

cat > "$MNT/etc/systemd/system/wpa_supplicant-wlan0.service" << 'UNIT'
[Unit]
Description=WPA supplicant for wlan0
After=hisi-wifi-init.service
Requires=hisi-wifi-init.service
Before=dhcpcd.service

[Service]
Type=simple
ExecStart=/usr/sbin/wpa_supplicant -D nl80211 -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/wpa_supplicant-wlan0.service "$MNT/etc/systemd/system/multi-user.target.wants/wpa_supplicant-wlan0.service"
echo "    wpa_supplicant: OK"

echo ""
echo "[OK] rootfs patched. On first boot:"
echo "     - USB NCM network at 10.15.19.82/24"
echo "     - ADB over TCP: adb connect 10.15.19.82:5555"
echo "     - WiFi init runs automatically"
echo "     - User needs to add WiFi credentials (bash setup-device.sh)"
