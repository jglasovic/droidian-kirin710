#!/usr/bin/env bash
# setup-device.sh — configure a fresh Droidian install on Kirin 710 (SNE-LX1)
#
# Run from your computer with the device connected via USB:
#   bash setup-device.sh [<device-ip>] [<wifi-ssid>] [<wifi-password>]
#
# Defaults to USB NCM IP (10.15.19.82). After setup, the device will
# auto-connect to WiFi and be accessible via SSH over the network.
set -euo pipefail

DEVICE_IP="${1:-10.15.19.82}"
DEVICE_USER="droidian"
DEVICE_PASS="droidian"
WIFI_SSID="${2:-}"
WIFI_PASS="${3:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-SI}"

if [ -z "$WIFI_SSID" ] || [ -z "$WIFI_PASS" ]; then
  echo "Usage: bash setup-device.sh [device-ip] <wifi-ssid> <wifi-password>"
  echo ""
  echo "  device-ip    Device IP (default: 10.15.19.82 via USB)"
  echo "  wifi-ssid    WiFi network name"
  echo "  wifi-password WiFi password"
  echo ""
  echo "Optional env vars:"
  echo "  WIFI_COUNTRY  Country code for WiFi (default: SI)"
  exit 1
fi

echo "[*] Connecting to ${DEVICE_USER}@${DEVICE_IP}..."

# Run the setup commands on the device via SSH
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${DEVICE_USER}@${DEVICE_IP}" "echo ${DEVICE_PASS} | sudo -S bash -s" << SETUP_EOF
set -euo pipefail

echo "[1/7] Setting up vendor partition mount..."
cat > /etc/systemd/system/android-system-vendor.mount << 'UNIT'
[Unit]
Description=Mount Android vendor partition
RequiresMountsFor=/android/system
After=systemd-udevd.service
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
systemctl daemon-reload
systemctl enable android-system-vendor.mount
echo "    vendor mount: OK"

echo "[2/7] Setting up Hi1102 WiFi init service..."
cat > /etc/systemd/system/hisi-wifi-init.service << 'UNIT'
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
systemctl daemon-reload
systemctl enable hisi-wifi-init.service
echo "    wifi init: OK"

echo "[3/7] Masking default wpa_supplicant (D-Bus mode causes CPU spin)..."
systemctl mask wpa_supplicant.service 2>/dev/null || true
echo "    wpa_supplicant masked: OK"

echo "[4/7] Setting up wpa_supplicant config..."
mkdir -p /etc/wpa_supplicant
cat > /etc/wpa_supplicant/wpa_supplicant.conf << WPACFG
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
p2p_disabled=1
country=${WIFI_COUNTRY}

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PASS}"
}
WPACFG
chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf

cat > /etc/systemd/system/wpa_supplicant-wlan0.service << 'UNIT'
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
systemctl daemon-reload
systemctl enable wpa_supplicant-wlan0.service
echo "    wpa_supplicant (interface mode): OK"

echo "[5/7] Installing and configuring dhcpcd..."
apt-get update -qq
apt-get install -y --no-install-recommends dhcpcd5 2>&1 | tail -3
if ! grep -q "allowinterfaces wlan0" /etc/dhcpcd.conf 2>/dev/null; then
  echo "allowinterfaces wlan0" >> /etc/dhcpcd.conf
fi
echo "    dhcpcd: OK"

echo "[6/7] Setting up display-off service..."
cat > /etc/systemd/system/display-off.service << 'UNIT'
[Unit]
Description=Turn off LCD display
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "dd if=/dev/zero of=/dev/fb0 bs=4096 count=1024 2>/dev/null; echo 4 > /sys/class/graphics/fb0/blank; echo 0 > /sys/class/leds/lcd_backlight0/brightness"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable display-off.service
echo "    display-off: OK"

echo "[7/7] Disabling LXC Android container (not needed)..."
systemctl stop lxc@android 2>/dev/null || true
systemctl mask lxc@android 2>/dev/null || true
echo "    lxc masked: OK"

echo ""
echo "=== Setup complete ==="
echo "Reboot the device to apply all changes."
echo "After reboot, SSH will be available over WiFi."
SETUP_EOF

echo ""
echo "[OK] Device setup complete."
echo "     Reboot with: ssh ${DEVICE_USER}@${DEVICE_IP} 'echo ${DEVICE_PASS} | sudo -S reboot'"
echo "     After reboot, find the device IP on your router and SSH over WiFi."
