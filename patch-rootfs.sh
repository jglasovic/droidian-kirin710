#!/usr/bin/env bash
# patch-rootfs.sh — apply Kirin 710 device config to rootfs.img
#
# Bakes in static device configuration so that on first boot:
#   - ADB over USB works (connect via: adb shell)
#   - android-rootfs.img is loop-mounted at /android/system
#   - vendor partition is mounted (WiFi firmware)
#   - Hi1102 WiFi chip is initialized
#   - wpa_supplicant runs in safe interface mode (D-Bus mode masked)
#
# After first boot the user still needs to:
#   - Create /etc/wpa_supplicant/wpa_supplicant.conf with WiFi credentials
#   - Install dhcpcd5 (apt install dhcpcd5)
#
# Usage:
#   sudo bash patch-rootfs.sh [rootfs.img]
set -euo pipefail

ROOTFS="${1:-rootfs.img}"

if [ ! -f "$ROOTFS" ]; then
  echo "[FAIL] $ROOTFS not found"
  exit 1
fi

MNT=$(mktemp -d)
echo "[*] Mounting $ROOTFS at $MNT..."
mount -o loop "$ROOTFS" "$MNT"

cleanup() {
  umount "$MNT" 2>/dev/null || true
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

# ── 1. Enable ADB over USB ──────────────────────────────────────────────────
echo "[1/5] Enabling ADB over USB..."
# Replace TCP-only override with one that adds TCP alongside USB
mkdir -p "$MNT/etc/systemd/system/adbd.service.d"
cat > "$MNT/etc/systemd/system/adbd.service.d/tcp.conf" << 'UNIT'
[Service]
Environment=ADBD_SOCKET=tcp:5555
UNIT
# Enable adbd
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
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
echo "     - ADB over USB works (adb shell)"
echo "     - WiFi init runs automatically"
echo "     - User needs to add WiFi credentials and install dhcpcd"
