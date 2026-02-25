#!/usr/bin/env bash
# setup-device.sh — configure WiFi and optional settings on Kirin 710 (SNE-LX1)
#
# The rootfs comes pre-configured with ADB, vendor mount, and WiFi init.
# This script sets up the remaining user-specific configuration over ADB.
#
# Usage:
#   bash setup-device.sh <wifi-ssid> <wifi-password>
#
# Optional env vars:
#   WIFI_COUNTRY  Country code for WiFi (default: SI)
set -euo pipefail

WIFI_SSID="${1:-}"
WIFI_PASS="${2:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-SI}"

if [ -z "$WIFI_SSID" ] || [ -z "$WIFI_PASS" ]; then
  echo "Usage: bash setup-device.sh <wifi-ssid> <wifi-password>"
  echo ""
  echo "  wifi-ssid      WiFi network name"
  echo "  wifi-password   WiFi password"
  echo ""
  echo "Optional env vars:"
  echo "  WIFI_COUNTRY  Country code for WiFi (default: SI)"
  exit 1
fi

echo "[*] Connecting to device via ADB..."
adb wait-for-device

adb shell "bash -s" << SETUP_EOF
set -euo pipefail

echo "[1/2] Configuring WiFi credentials..."
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
if ! grep -q "allowinterfaces wlan0" /etc/dhcpcd.conf 2>/dev/null; then
  echo "allowinterfaces wlan0" >> /etc/dhcpcd.conf
fi
echo "    wpa_supplicant.conf: OK"

echo "[2/2] Locking WiFi MAC address (Hi1102 randomizes on each boot)..."
WLAN_MAC=\$(cat /sys/class/net/wlan0/address 2>/dev/null || echo "")
if [ -z "\$WLAN_MAC" ] || [ "\$WLAN_MAC" = "00:00:00:00:00:00" ]; then
  echo "    WARNING: could not read wlan0 MAC, skipping"
  echo "    Run setup again after WiFi is initialized to lock MAC"
else
  mkdir -p /etc/systemd/network
  cat > /etc/systemd/network/10-wlan0-mac.link << UNIT
[Match]
OriginalName=wlan0

[Link]
MACAddress=\${WLAN_MAC}
UNIT
  echo "    MAC locked to \${WLAN_MAC}: OK"
fi

echo ""
echo "=== Setup complete ==="
echo "Reboot the device to apply all changes."
echo "After reboot, the device will auto-connect to WiFi."
SETUP_EOF

echo ""
echo "[OK] Device setup complete."
echo "     Reboot with: adb reboot"
echo "     After reboot, SSH will be available over WiFi."
