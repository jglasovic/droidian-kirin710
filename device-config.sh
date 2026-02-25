#!/bin/sh
# device-config.sh — configure Droidian rootfs for Kirin 710 (SNE-LX1)
#
# Runs on device in recovery via ADB. Pure file writes — no chroot, no dpkg.
# Expects /tmp/wpa_supplicant.conf to be pushed before running.
#
# Usage: sh device-config.sh
set -eu

ROOTFS="/tmpmnt/rootfs.img"
MNT="/mnt"

if [ ! -f "$ROOTFS" ]; then
    echo "[FAIL] $ROOTFS not found"
    exit 1
fi

echo "[*] Mounting rootfs..."
mount -o loop "$ROOTFS" "$MNT"

cleanup() {
    umount "$MNT" 2>/dev/null || true
    sync
}
trap cleanup EXIT

SYSTEMD="$MNT/etc/systemd/system"
mkdir -p "$SYSTEMD/multi-user.target.wants"
mkdir -p "$SYSTEMD/local-fs.target.wants"
mkdir -p "$SYSTEMD/local-fs.target.requires"

# ── 1. USB gadget trigger ────────────────────────────────────────────────────
echo "[1/8] USB gadget trigger..."
cat > "$SYSTEMD/usb-gadget-trigger.service" << 'UNIT'
[Unit]
Description=Trigger USB gadget mode via HiSilicon DWC3
DefaultDependencies=no
After=sys-kernel-config.mount
Before=usb-rndis.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo device > /sys/class/dual_role_usb/otg_default/mode 2>/dev/null || true; for i in 1 2 3 4 5; do [ -d /sys/class/udc/ff100000.dwc3 ] && exit 0; sleep 1; done'

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/usb-gadget-trigger.service "$SYSTEMD/multi-user.target.wants/usb-gadget-trigger.service"

# ── 2. USB NCM network ──────────────────────────────────────────────────────
echo "[2/8] USB NCM network (10.15.19.82/24)..."
cat > "$SYSTEMD/usb-rndis.service" << 'UNIT'
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
ln -sf /etc/systemd/system/usb-rndis.service "$SYSTEMD/multi-user.target.wants/usb-rndis.service"

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

# ── 3. Unmask android-mount service ──────────────────────────────────────────
echo "[3/8] Unmasking android-mount..."
rm -f "$SYSTEMD/android-mount.service"
ln -sf /lib/systemd/system/android-mount.service "$SYSTEMD/local-fs.target.requires/android-mount.service"

# ── 4. Vendor partition mount ────────────────────────────────────────────────
echo "[4/8] Vendor partition mount..."
cat > "$SYSTEMD/android-system-vendor.mount" << 'UNIT'
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
ln -sf /etc/systemd/system/android-system-vendor.mount "$SYSTEMD/local-fs.target.wants/android-system-vendor.mount"

# ── 5. Hi1102 WiFi init ─────────────────────────────────────────────────────
echo "[5/8] Hi1102 WiFi init..."
cat > "$SYSTEMD/hisi-wifi-init.service" << 'UNIT'
[Unit]
Description=Initialize Hi1102 WiFi
After=android-system-vendor.mount
Before=wpa_supplicant-wlan0.service
Requires=android-system-vendor.mount

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo init > /sys/hisys/boot/plat && sleep 2 && echo init > /sys/hisys/boot/wifi && sleep 3"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/hisi-wifi-init.service "$SYSTEMD/multi-user.target.wants/hisi-wifi-init.service"

# ── 6. wpa_supplicant interface mode ─────────────────────────────────────────
echo "[6/8] wpa_supplicant (interface mode, D-Bus masked)..."
# Mask D-Bus mode wpa_supplicant (causes 100% CPU spin with Hi1102)
ln -sf /dev/null "$SYSTEMD/wpa_supplicant.service"

cat > "$SYSTEMD/wpa_supplicant-wlan0.service" << 'UNIT'
[Unit]
Description=WPA supplicant for wlan0
After=hisi-wifi-init.service
Requires=hisi-wifi-init.service
Before=wifi-dhcp.service

[Service]
Type=simple
ExecStart=/usr/sbin/wpa_supplicant -D nl80211 -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/wpa_supplicant-wlan0.service "$SYSTEMD/multi-user.target.wants/wpa_supplicant-wlan0.service"

# ── 7. WiFi DHCP ────────────────────────────────────────────────────────────
echo "[7/8] WiFi DHCP..."
cat > "$SYSTEMD/wifi-dhcp.service" << 'UNIT'
[Unit]
Description=DHCP client for wlan0
After=wpa_supplicant-wlan0.service
Requires=wpa_supplicant-wlan0.service

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'sleep 5'
ExecStart=/bin/sh -c 'if command -v dhclient >/dev/null 2>&1; then exec dhclient -v -4 wlan0; elif command -v dhcpcd >/dev/null 2>&1; then exec dhcpcd -4 wlan0; elif command -v udhcpc >/dev/null 2>&1; then exec udhcpc -i wlan0; else echo "No DHCP client found" > /dev/kmsg; exit 1; fi'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/wifi-dhcp.service "$SYSTEMD/multi-user.target.wants/wifi-dhcp.service"

# ── 8. WiFi credentials ─────────────────────────────────────────────────────
echo "[8/8] WiFi credentials..."
mkdir -p "$MNT/etc/wpa_supplicant"
if [ -f /tmp/wpa_supplicant.conf ]; then
    cp /tmp/wpa_supplicant.conf "$MNT/etc/wpa_supplicant/wpa_supplicant.conf"
    chmod 600 "$MNT/etc/wpa_supplicant/wpa_supplicant.conf"
    SSID=$(grep 'ssid=' /tmp/wpa_supplicant.conf | head -1 | sed 's/.*ssid="\(.*\)"/\1/')
    echo "    WiFi: $SSID"
else
    echo "    WARNING: /tmp/wpa_supplicant.conf not found, skipping WiFi credentials"
fi

echo ""
echo "[OK] Device configured. Services enabled:"
echo "     - USB NCM network (10.15.19.82/24)"
echo "     - Android system + vendor mount"
echo "     - Hi1102 WiFi init"
echo "     - wpa_supplicant (interface mode)"
echo "     - WiFi DHCP"
