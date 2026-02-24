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

echo "[1/10] Setting up vendor partition mount..."
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

echo "[2/10] Setting up Hi1102 WiFi init service..."
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

echo "[3/10] Masking default wpa_supplicant (D-Bus mode causes CPU spin)..."
systemctl mask wpa_supplicant.service 2>/dev/null || true
echo "    wpa_supplicant masked: OK"

echo "[4/10] Setting up wpa_supplicant config..."
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

echo "[5/10] Installing and configuring dhcpcd..."
apt-get update -qq
apt-get install -y --no-install-recommends dhcpcd5 2>&1 | tail -3
if ! grep -q "allowinterfaces wlan0" /etc/dhcpcd.conf 2>/dev/null; then
  echo "allowinterfaces wlan0" >> /etc/dhcpcd.conf
fi
echo "    dhcpcd: OK"

echo "[6/10] Setting up display-off service..."
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

echo "[7/10] Locking WiFi MAC address (Hi1102 randomizes on each boot)..."
WLAN_MAC=$(cat /sys/class/net/wlan0/address 2>/dev/null || echo "")
if [ -z "$WLAN_MAC" ] || [ "$WLAN_MAC" = "00:00:00:00:00:00" ]; then
  echo "    WARNING: could not read wlan0 MAC, skipping"
else
  cat > /etc/systemd/network/10-wlan0-mac.link << UNIT
[Match]
OriginalName=wlan0

[Link]
MACAddress=${WLAN_MAC}
UNIT
  echo "    MAC locked to ${WLAN_MAC}: OK"
fi

echo "[8/10] Setting up USB gadget (SSH over USB fallback)..."
cat > /etc/systemd/system/usb-gadget-trigger.service << 'UNIT'
[Unit]
Description=Trigger USB gadget mode via HiSilicon DWC3
DefaultDependencies=no
After=sys-kernel-config.mount
Before=usb-rndis.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true

[Install]
WantedBy=sysinit.target
UNIT

cat > /etc/systemd/system/usb-rndis.service << 'UNIT'
[Unit]
Description=USB NCM Gadget (SSH over USB)
DefaultDependencies=no
After=sys-kernel-config.mount usb-gadget-trigger.service
Wants=usb-gadget-trigger.service
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/usb-rndis-setup.sh

[Install]
WantedBy=multi-user.target
UNIT

cat > /usr/local/sbin/usb-rndis-setup.sh << 'SCRIPT'
#!/bin/sh
set -e
exec > /tmp/usb-rndis.log 2>&1
set -x

GADGET=/sys/kernel/config/usb_gadget/g1

# Ensure configfs is mounted
if ! mount | grep -q "type configfs"; then
    mount -t configfs none /sys/kernel/config 2>/dev/null || true
fi

# Wait for UDC to appear
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

# Tear down any existing gadget
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

# Wait for interface
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
chmod +x /usr/local/sbin/usb-rndis-setup.sh

# udev rule: restart usb-rndis when USB cable is plugged in
cat > /etc/udev/rules.d/99-usb-gadget.rules << 'UDEV'
ACTION=="add", SUBSYSTEM=="udc", RUN+="/bin/systemctl restart usb-rndis.service"
UDEV

systemctl daemon-reload
systemctl enable usb-gadget-trigger.service
systemctl enable usb-rndis.service
echo "    usb-gadget + udev rule: OK"

echo "[9/10] Disabling LXC Android container (not needed)..."
systemctl stop lxc@android 2>/dev/null || true
systemctl mask lxc@android 2>/dev/null || true
echo "    lxc masked: OK"

echo "[10/10] Masking android_boot_completed (no container)..."
systemctl mask android_boot_completed.service 2>/dev/null || true
echo "    android_boot_completed masked: OK"

echo ""
echo "=== Setup complete ==="
echo "Reboot the device to apply all changes."
echo "After reboot, SSH will be available over WiFi."
SETUP_EOF

echo ""
echo "[OK] Device setup complete."
echo "     Reboot with: ssh ${DEVICE_USER}@${DEVICE_IP} 'echo ${DEVICE_PASS} | sudo -S reboot'"
echo "     After reboot, find the device IP on your router and SSH over WiFi."
