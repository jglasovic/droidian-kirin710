#!/bin/sh
# device-config.sh — configure Droidian rootfs for Kirin 710 (SNE-LX1)
#
# Runs on device in recovery via ADB. Pure file writes — no chroot, no dpkg.
# Accepts flags as $1 to control which steps run.
#
# Usage: sh device-config.sh "usb wifi headless"
#
# Flags:
#   usb      — USB gadget trigger + NCM network + adbd TCP
#   wifi     — Vendor mount + Hi1102 init + wpa_supplicant + DHCP + credentials
#   vendor   — Vendor mount only (without WiFi)
#   fixmac   — Lock WiFi MAC address (capture on first boot, reuse forever)
#   headless — Turn off display after boot
#
# Always runs: android-mount unmask
set -eu

FLAGS="${1:-}"

# Debug log — readable via: adb shell cat /tmpmnt/device-config.log
LOG="/tmpmnt/device-config.log"
echo "=== device-config.sh ===" > "$LOG"
echo "date: $(date 2>/dev/null || echo unknown)" >> "$LOG"
echo "flags: '$FLAGS'" >> "$LOG"

has_flag() {
    case " $FLAGS " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

echo "has usb: $(has_flag usb && echo yes || echo no)" >> "$LOG"
echo "has wifi: $(has_flag wifi && echo yes || echo no)" >> "$LOG"
echo "has vendor: $(has_flag vendor && echo yes || echo no)" >> "$LOG"
echo "has fixmac: $(has_flag fixmac && echo yes || echo no)" >> "$LOG"
echo "has headless: $(has_flag headless && echo yes || echo no)" >> "$LOG"

ROOTFS="/tmpmnt/rootfs.img"
MNT="/mnt"

if [ ! -f "$ROOTFS" ]; then
    echo "[FAIL] $ROOTFS not found" | tee -a "$LOG"
    exit 1
fi

echo "[*] Mounting rootfs..."
mount -o loop "$ROOTFS" "$MNT"
echo "rootfs mounted at $MNT" >> "$LOG"

cleanup() {
    umount "$MNT" 2>/dev/null || true
    sync
}
trap cleanup EXIT

SYSTEMD="$MNT/etc/systemd/system"
mkdir -p "$SYSTEMD/multi-user.target.wants"
mkdir -p "$SYSTEMD/local-fs.target.wants"
mkdir -p "$SYSTEMD/local-fs.target.requires"

# Enable persistent journal logging
mkdir -p "$MNT/var/log/journal"
chmod 2755 "$MNT/var/log/journal"

# ── Count steps ──────────────────────────────────────────────────────────────
TOTAL=3  # android-mount + devtools fixups + boot-debug always
if has_flag usb; then TOTAL=$((TOTAL + 3)); fi        # gadget trigger + NCM + adbd
if has_flag wifi || has_flag vendor; then TOTAL=$((TOTAL + 1)); fi  # vendor mount
if has_flag wifi; then TOTAL=$((TOTAL + 4)); fi        # hi1102 + wpa + dhcp + creds
if has_flag fixmac; then TOTAL=$((TOTAL + 1)); fi      # lock WiFi MAC
if has_flag headless; then TOTAL=$((TOTAL + 5)); fi    # charger + zram + mask services + performance + display-off
STEP=0

next_step() {
    STEP=$((STEP + 1))
    echo "[$STEP/$TOTAL] $1"
    echo "[$STEP/$TOTAL] $1" >> "$LOG"
}

# ── Always: Unmask android-mount service ─────────────────────────────────────
next_step "Unmasking android-mount..."
rm -f "$SYSTEMD/android-mount.service"
ln -sf /lib/systemd/system/android-mount.service "$SYSTEMD/local-fs.target.requires/android-mount.service"

# ── Always: Fix devtools side-effects ──────────────────────────────────────
next_step "Fixing devtools side-effects..."
# hybris-usb installs usb-tethering.service which conflicts with our NCM gadget
ln -sf /dev/null "$SYSTEMD/usb-tethering.service"
# mtp-configfs reconfigures USB gadget for MTP/RNDIS, wiping our NCM setup
ln -sf /dev/null "$SYSTEMD/mtp-configfs@.service"
# isc-dhcp-server is a DHCP *server* (not client) — crashes on boot with no config
ln -sf /dev/null "$SYSTEMD/isc-dhcp-server.service"
ln -sf /dev/null "$SYSTEMD/isc-dhcp-server6.service"
# Disable coredump storage — Android processes dump cores that fill disk
mkdir -p "$MNT/etc/systemd/coredump.conf.d"
cat > "$MNT/etc/systemd/coredump.conf.d/limit.conf" << 'EOF'
[Coredump]
Storage=none
EOF

# ── USB: gadget trigger ──────────────────────────────────────────────────────
if has_flag usb; then
next_step "USB gadget trigger..."
cat > "$SYSTEMD/usb-gadget-trigger.service" << 'UNIT'
[Unit]
Description=Trigger USB gadget mode via HiSilicon DWC3
DefaultDependencies=no
After=sys-kernel-config.mount
Before=usb-rndis.service adbd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo device > /sys/class/dual_role_usb/otg_default/mode 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/usb-gadget-trigger.service "$SYSTEMD/multi-user.target.wants/usb-gadget-trigger.service"
fi

# ── USB: NCM network ────────────────────────────────────────────────────────
if has_flag usb; then
next_step "USB NCM network (10.15.19.82/24)..."
cat > "$SYSTEMD/usb-rndis.service" << 'UNIT'
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
ln -sf /etc/systemd/system/usb-rndis.service "$SYSTEMD/multi-user.target.wants/usb-rndis.service"

mkdir -p "$MNT/usr/local/sbin"
cat > "$MNT/usr/local/sbin/usb-rndis-setup.sh" << 'SCRIPT'
#!/bin/sh
set -e
exec > /var/log/usb-rndis.log 2>&1
set -x

GADGET=/sys/kernel/config/usb_gadget/g1

if ! mount | grep -q "type configfs"; then
    mount -t configfs none /sys/kernel/config 2>/dev/null || true
fi

UDC=""
for i in $(seq 1 60); do
    UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
    [ -n "$UDC" ] && break
    sleep 2
done
if [ -z "$UDC" ]; then
    echo "ERROR: No UDC after 120s" > /dev/kmsg 2>/dev/null || true
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
# Brief disconnect/reconnect to force host re-enumeration
sleep 1
echo "" > $GADGET/UDC 2>/dev/null || true
sleep 1
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
fi

# ── USB: adbd TCP ────────────────────────────────────────────────────────────
if has_flag usb; then
next_step "adbd over TCP:5555..."
mkdir -p "$SYSTEMD/adbd.service.d"
cat > "$SYSTEMD/adbd.service.d/override.conf" << 'UNIT'
[Service]
Environment=ADBD_SOCKET=tcp:5555
# Clear gadget management — our usb-rndis-setup.sh handles NCM+ADB gadget
ExecStartPre=
ExecStartPost=
ExecStopPost=
UNIT
ln -sf /usr/lib/systemd/system/adbd.service "$SYSTEMD/multi-user.target.wants/adbd.service" 2>/dev/null || true
fi

# ── Vendor mount (needed by WiFi, or standalone) ────────────────────────────
if has_flag wifi || has_flag vendor; then
next_step "Vendor partition mount..."
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
fi

# ── WiFi: Hi1102 init ───────────────────────────────────────────────────────
if has_flag wifi; then
next_step "Hi1102 WiFi init..."
cat > "$SYSTEMD/hisi-wifi-init.service" << 'UNIT'
[Unit]
Description=Initialize Hi1102 WiFi
After=android-system-vendor.mount
Before=wpa_supplicant-wlan0.service NetworkManager.service
Requires=android-system-vendor.mount

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo init > /sys/hisys/boot/plat && sleep 2 && echo init > /sys/hisys/boot/wifi && sleep 3"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/hisi-wifi-init.service "$SYSTEMD/multi-user.target.wants/hisi-wifi-init.service"
fi

# ── WiFi: wpa_supplicant ────────────────────────────────────────────────────
if has_flag wifi; then
next_step "wpa_supplicant (interface mode, D-Bus masked)..."
# Mask D-Bus mode wpa_supplicant (causes 100% CPU spin with Hi1102)
ln -sf /dev/null "$SYSTEMD/wpa_supplicant.service"

cat > "$SYSTEMD/wpa_supplicant-wlan0.service" << 'UNIT'
[Unit]
Description=WPA supplicant for wlan0
After=hisi-wifi-init.service
Requires=hisi-wifi-init.service
Before=wifi-dhcp.service
ConditionPathExists=/etc/wpa_supplicant/wpa_supplicant.conf
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
ExecStart=/usr/sbin/wpa_supplicant -D nl80211 -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/wpa_supplicant-wlan0.service "$SYSTEMD/multi-user.target.wants/wpa_supplicant-wlan0.service"
fi

# ── WiFi: DHCP ──────────────────────────────────────────────────────────────
if has_flag wifi; then
next_step "WiFi DHCP..."
cat > "$SYSTEMD/wifi-dhcp.service" << 'UNIT'
[Unit]
Description=DHCP client for wlan0
After=wpa_supplicant-wlan0.service
Requires=wpa_supplicant-wlan0.service
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'sleep 5'
ExecStart=/bin/sh -c 'if command -v dhclient >/dev/null 2>&1; then exec dhclient -v -4 wlan0; elif command -v dhcpcd >/dev/null 2>&1; then exec dhcpcd -B -4 wlan0; elif command -v udhcpc >/dev/null 2>&1; then exec udhcpc -i wlan0; else echo "No DHCP client found" > /dev/kmsg; exit 1; fi'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/wifi-dhcp.service "$SYSTEMD/multi-user.target.wants/wifi-dhcp.service"
fi

# ── WiFi: credentials ──────────────────────────────────────────────────────
if has_flag wifi; then
next_step "WiFi credentials..."
mkdir -p "$MNT/etc/wpa_supplicant"
if [ -f /tmp/wpa_supplicant.conf ]; then
    cp /tmp/wpa_supplicant.conf "$MNT/etc/wpa_supplicant/wpa_supplicant.conf"
    chmod 600 "$MNT/etc/wpa_supplicant/wpa_supplicant.conf"
    SSID=$(grep 'ssid=' /tmp/wpa_supplicant.conf | head -1 | sed 's/.*ssid="\(.*\)"/\1/')
    echo "    WiFi: $SSID"
else
    echo "    WARNING: /tmp/wpa_supplicant.conf not found, skipping WiFi credentials"
fi
fi

# ── WiFi: lock MAC address ────────────────────────────────────────────────
if has_flag fixmac; then
next_step "WiFi MAC lock service..."
cat > "$SYSTEMD/wifi-mac-lock.service" << 'UNIT'
[Unit]
Description=Lock WiFi MAC address
After=hisi-wifi-init.service
Before=wpa_supplicant-wlan0.service
Requires=hisi-wifi-init.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/wifi-mac-lock.sh

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/wifi-mac-lock.service "$SYSTEMD/multi-user.target.wants/wifi-mac-lock.service"

mkdir -p "$MNT/usr/local/sbin"
cat > "$MNT/usr/local/sbin/wifi-mac-lock.sh" << 'SCRIPT'
#!/bin/sh
MAC_FILE="/etc/wlan0-mac"
IFACE="wlan0"

if [ -f "$MAC_FILE" ]; then
    # Apply saved MAC
    MAC=$(cat "$MAC_FILE")
    ip link set "$IFACE" down
    ip link set "$IFACE" address "$MAC"
    ip link set "$IFACE" up
    echo "wlan0 MAC locked to $MAC" > /dev/kmsg 2>/dev/null || true
else
    # First boot — capture current MAC and save it
    MAC=$(ip link show "$IFACE" 2>/dev/null | grep -o 'link/ether [^ ]*' | awk '{print $2}')
    if [ -n "$MAC" ] && [ "$MAC" != "00:00:00:00:00:00" ]; then
        echo "$MAC" > "$MAC_FILE"
        echo "wlan0 MAC saved: $MAC" > /dev/kmsg 2>/dev/null || true
    else
        echo "wlan0 MAC not available yet" > /dev/kmsg 2>/dev/null || true
        exit 1
    fi
fi
SCRIPT
chmod +x "$MNT/usr/local/sbin/wifi-mac-lock.sh"
fi

# ── Always: boot-debug service ─────────────────────────────────────────────
next_step "Boot debug logger..."
cat > "$SYSTEMD/boot-debug.service" << 'UNIT'
[Unit]
Description=Boot debug — capture system state after boot
After=multi-user.target usb-rndis.service hisi-wifi-init.service wpa_supplicant-wlan0.service wifi-dhcp.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 60
ExecStart=/usr/local/sbin/boot-debug.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/boot-debug.service "$SYSTEMD/multi-user.target.wants/boot-debug.service"

mkdir -p "$MNT/usr/local/sbin"
cat > "$MNT/usr/local/sbin/boot-debug.sh" << 'SCRIPT'
#!/bin/sh
LOG="/var/log/boot-debug.log"
exec > "$LOG" 2>&1
echo "=== boot-debug $(date) ==="

echo ""; echo "--- systemctl failed units ---"
systemctl --no-pager list-units --state=failed 2>/dev/null || true

echo ""; echo "--- systemctl all custom units ---"
for svc in usb-gadget-trigger usb-rndis adbd android-mount android-system-vendor.mount \
           hisi-wifi-init wpa_supplicant-wlan0 wifi-dhcp display-off package-sideload; do
    echo ""
    echo ">> $svc:"
    systemctl status "$svc" --no-pager -l 2>/dev/null || echo "  (not found)"
done

echo ""; echo "--- journalctl for USB ---"
journalctl -u usb-gadget-trigger -u usb-rndis --no-pager -n 50 2>/dev/null || true

echo ""; echo "--- journalctl for WiFi ---"
journalctl -u hisi-wifi-init -u wpa_supplicant-wlan0 -u wifi-dhcp --no-pager -n 50 2>/dev/null || true

echo ""; echo "--- journalctl for sshd ---"
journalctl -u ssh -u sshd --no-pager -n 30 2>/dev/null || true

echo ""; echo "--- journalctl for adbd ---"
journalctl -u adbd --no-pager -n 30 2>/dev/null || true

echo ""; echo "--- journalctl for package-sideload ---"
journalctl -u package-sideload --no-pager -n 30 2>/dev/null || true

echo ""; echo "--- network interfaces ---"
ip addr 2>/dev/null || ifconfig 2>/dev/null || true

echo ""; echo "--- USB gadget state ---"
ls -la /sys/class/udc/ 2>/dev/null || echo "no UDC"
cat /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null || echo "no gadget UDC"
ls -la /sys/kernel/config/usb_gadget/g1/configs/c.1/ 2>/dev/null || true

echo ""; echo "--- wlan state ---"
ip link show wlan0 2>/dev/null || echo "no wlan0"
wpa_cli -i wlan0 status 2>/dev/null || true
wpa_cli -i wlan0 scan_results 2>/dev/null || true

echo ""; echo "--- listening ports ---"
ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || true

echo ""; echo "--- usb-rndis log ---"
cat /var/log/usb-rndis.log 2>/dev/null || echo "(no usb-rndis log)"

echo ""; echo "--- dmesg USB/NCM/gadget ---"
dmesg 2>/dev/null | grep -iE 'usb|ncm|gadget|dwc3|udc' | tail -30 || true

echo ""; echo "--- dmesg wifi/wlan ---"
dmesg 2>/dev/null | grep -iE 'wifi|wlan|hi110|hisi' | tail -30 || true

echo ""; echo "--- journal errors ---"
journalctl -p err --no-pager -n 30 2>/dev/null || true

echo ""; echo "=== boot-debug done ==="
SCRIPT
chmod +x "$MNT/usr/local/sbin/boot-debug.sh"

# ── Headless: disable battery charging (no battery, external PSU) ─────────────
if has_flag headless; then
next_step "Disable battery charging (external PSU)..."
cat > "$SYSTEMD/disable-charger.service" << 'UNIT'
[Unit]
Description=Disable battery charging (no battery installed)
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo 0 > /sys/devices/platform/huawei_charger/enable_charger"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/disable-charger.service "$SYSTEMD/multi-user.target.wants/disable-charger.service"
fi

# ── Headless: zram swap (compressed RAM, avoids eMMC wear) ───────────────────
if has_flag headless; then
next_step "zram swap (1GB, lz4)..."
cat > "$SYSTEMD/zram-swap.service" << 'UNIT'
[Unit]
Description=Configure zram swap (1GB, lz4)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo lz4 > /sys/block/zram0/comp_algorithm && echo 1G > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon -p 100 /dev/zram0"
ExecStop=/bin/sh -c "swapoff /dev/zram0 && echo 1 > /sys/block/zram0/reset"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/zram-swap.service "$SYSTEMD/multi-user.target.wants/zram-swap.service"
fi

# ── Headless: mask Android/UI services ────────────────────────────────────────
if has_flag headless; then
next_step "Masking unnecessary services (headless server)..."
# Keeping: ssh, adbd, NetworkManager, systemd-resolved, dbus, polkit, udevd,
#          journald, logind, timesyncd, udisks2, lm-sensors, udev
# Keeping: our services (usb-rndis, wifi, gadget-trigger, display-off, boot-debug)
for svc in \
    lxc@android.service \
    lxc.service \
    lxc-monitord.service \
    lxc-net.service \
    bluebinder.service \
    bluetooth.service \
    ModemManager.service \
    ofono.service \
    droidian-fpd.service \
    sensorfwd.service \
    iio-sensor-proxy.service \
    nfcd.service \
    phosh.service \
    accounts-daemon.service \
    cups.service \
    cups.path \
    avahi-daemon.service \
    strongswan-starter.service \
    openvpn.service \
    vnstat.service \
    droidian-boot-wlan.service \
    droidian-boot-wlan.path \
    droidian-ipa-enable.service \
    droidian-lmk-disable.service \
    droidian-wcnss-enable.service \
    droidian_boot_completed.service \
    android_boot_completed.service \
    android-cpuset.service \
    android-service@hwcomposer.service \
; do
    ln -sf /dev/null "$SYSTEMD/$svc"
done
# Switch default target from graphical to multi-user (don't mask graphical — it's the default)
ln -sf /usr/lib/systemd/system/multi-user.target "$SYSTEMD/default.target"

next_step "Performance tuning (headless server)..."
cat > "$SYSTEMD/cpu-performance.service" << 'UNIT'
[Unit]
Description=CPU and system performance tuning
DefaultDependencies=no
After=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/cpu-performance.sh

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/cpu-performance.service "$SYSTEMD/multi-user.target.wants/cpu-performance.service"

mkdir -p "$MNT/usr/local/sbin"
cat > "$MNT/usr/local/sbin/cpu-performance.sh" << 'SCRIPT'
#!/bin/sh
# Performance tuning for headless server — battery life is not a concern

# ── CPU: force performance governor on all cores ──
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$cpu" 2>/dev/null
done

# ── CPU: ensure all cores stay online ──
for cpu in /sys/devices/system/cpu/cpu*/online; do
    echo 1 > "$cpu" 2>/dev/null
done

# ── I/O scheduler: deadline for better throughput ──
for dev in /sys/block/*/queue/scheduler; do
    echo deadline > "$dev" 2>/dev/null
done

# ── VM: optimize for server workload ──
echo 10 > /proc/sys/vm/swappiness                 # prefer keeping processes in RAM
echo 40 > /proc/sys/vm/dirty_ratio                 # buffer up to 40% RAM before sync
echo 20 > /proc/sys/vm/dirty_background_ratio      # start background flush at 20%
echo 50 > /proc/sys/vm/vfs_cache_pressure          # keep filesystem metadata cached longer

# ── Network: larger TCP buffers for WireGuard/file serving ──
echo "4096 87380 6291456" > /proc/sys/net/ipv4/tcp_rmem      # min default max (6MB)
echo "4096 65536 6291456" > /proc/sys/net/ipv4/tcp_wmem      # min default max (6MB)
echo 6291456 > /proc/sys/net/core/rmem_max
echo 6291456 > /proc/sys/net/core/wmem_max
echo 1 > /proc/sys/net/ipv4/tcp_window_scaling
echo 1 > /proc/sys/net/ipv4/tcp_timestamps
echo 1 > /proc/sys/net/ipv4/tcp_sack

echo "Performance tuning applied" > /dev/kmsg 2>/dev/null || true
SCRIPT
chmod +x "$MNT/usr/local/sbin/cpu-performance.sh"

next_step "Display off (headless mode)..."
cat > "$SYSTEMD/display-off.service" << 'UNIT'
[Unit]
Description=Turn off display (headless mode)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "dd if=/dev/zero of=/dev/fb0 bs=4096 count=1024 2>/dev/null; echo 4 > /sys/class/graphics/fb0/blank; echo 0 > /sys/class/leds/lcd_backlight0/brightness"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/display-off.service "$SYSTEMD/multi-user.target.wants/display-off.service"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo "" >> "$LOG"
echo "files written:" >> "$LOG"
ls -la "$SYSTEMD/"*.service "$SYSTEMD/"*.mount 2>/dev/null >> "$LOG" || true
echo "symlinks in multi-user.target.wants:" >> "$LOG"
ls -la "$SYSTEMD/multi-user.target.wants/" >> "$LOG" 2>/dev/null || true
echo "=== done ===" >> "$LOG"

echo ""
echo "[OK] Device configured. Services enabled:"
if has_flag usb; then
    echo "     - USB NCM network (10.15.19.82/24)"
    echo "     - adbd TCP:5555"
fi
echo "     - Android system mount"
if has_flag wifi || has_flag vendor; then
    echo "     - Vendor partition mount"
fi
if has_flag wifi; then
    echo "     - Hi1102 WiFi init"
    echo "     - wpa_supplicant (interface mode)"
    echo "     - WiFi DHCP"
fi
if has_flag headless; then
    echo "     - Disable battery charging (external PSU)"
    echo "     - zram swap (1GB, lz4)"
    echo "     - Display off"
fi
