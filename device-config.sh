#!/bin/sh
# device-config.sh — configure Droidian rootfs for Kirin 710 (SNE-LX1)
#
# Runs on device in recovery via ADB. Pure file writes — no chroot, no dpkg.
# Service unit files and scripts are pre-pushed to /tmp/device-files/ by setup-device.sh.
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
# Always runs: android-mount unmask, devtools fixups, boot-debug
set -eu

FLAGS="${1:-}"
FILES="/tmp/device-files"

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

ROOTFS="/tmpmnt/rootfs.img"
MNT="/mnt"

if [ ! -f "$ROOTFS" ]; then
    echo "[FAIL] $ROOTFS not found" | tee -a "$LOG"
    exit 1
fi

echo "[*] Mounting rootfs..."
mkdir -p "$MNT"
if ! mount -o loop "$ROOTFS" "$MNT"; then
    echo "[FAIL] mount -o loop $ROOTFS $MNT failed" | tee -a "$LOG"
    exit 1
fi
echo "rootfs mounted at $MNT" >> "$LOG"

cleanup() {
    umount "$MNT" 2>/dev/null || true
    sync
}
trap cleanup EXIT

SYSTEMD="$MNT/etc/systemd/system"
SBIN="$MNT/usr/local/sbin"
mkdir -p "$SYSTEMD/multi-user.target.wants"
mkdir -p "$SYSTEMD/basic.target.wants"
mkdir -p "$SYSTEMD/local-fs.target.wants"
mkdir -p "$SYSTEMD/local-fs.target.requires"
mkdir -p "$SBIN"

# Enable persistent journal logging
mkdir -p "$MNT/var/log/journal"
chmod 2755 "$MNT/var/log/journal"

# ── Helpers ───────────────────────────────────────────────────────────────────

install_service() {
    local name="$1"
    cp "$FILES/services/$name" "$SYSTEMD/$name"
    echo "    installed $name" >> "$LOG"
}

enable_service() {
    local name="$1" target="${2:-multi-user.target}"
    ln -sf "/etc/systemd/system/$name" "$SYSTEMD/${target}.wants/$name"
}

install_script() {
    local name="$1"
    cp "$FILES/scripts/$name" "$SBIN/$name"
    chmod +x "$SBIN/$name"
    echo "    installed script $name" >> "$LOG"
}

# ── Count steps ───────────────────────────────────────────────────────────────
TOTAL=4  # android-mount + devtools fixups + boot-debug + led always
if has_flag usb; then TOTAL=$((TOTAL + 1)); fi
if has_flag wifi || has_flag vendor; then TOTAL=$((TOTAL + 1)); fi
if has_flag wifi; then TOTAL=$((TOTAL + 4)); fi
if has_flag fixmac; then TOTAL=$((TOTAL + 1)); fi
if has_flag headless; then TOTAL=$((TOTAL + 5)); fi
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

# ── Always: Fix devtools side-effects ────────────────────────────────────────
next_step "Fixing devtools side-effects..."
ln -sf /dev/null "$SYSTEMD/usb-tethering.service"
ln -sf /dev/null "$SYSTEMD/mtp-configfs@.service"
ln -sf /dev/null "$SYSTEMD/isc-dhcp-server.service"
ln -sf /dev/null "$SYSTEMD/isc-dhcp-server6.service"
mkdir -p "$MNT/etc/systemd/coredump.conf.d"
cat > "$MNT/etc/systemd/coredump.conf.d/limit.conf" << 'EOF'
[Coredump]
Storage=none
EOF

# ── ADB over USB via FunctionFS (opt-in, flag: usb) ──────────────────────────
if has_flag usb; then
    next_step "ADB over USB (FunctionFS)..."
    install_script adbd-ffs-setup.sh
    install_script adbd-udc-bind.sh
    mkdir -p "$SYSTEMD/adbd.service.d"
    cp "$FILES/services/adbd-override.conf" "$SYSTEMD/adbd.service.d/override.conf"
    mkdir -p "$MNT/etc/udev/rules.d"
    cp "$FILES/services/99-adbd-udc.rules" "$MNT/etc/udev/rules.d/99-adbd-udc.rules"
    install_service usb-gadget-trigger.service
    enable_service  usb-gadget-trigger.service
    ln -sf /usr/lib/systemd/system/adbd.service "$SYSTEMD/multi-user.target.wants/adbd.service" 2>/dev/null || true
fi

# ── Vendor mount ──────────────────────────────────────────────────────────────
if has_flag wifi || has_flag vendor; then
    next_step "Vendor partition mount..."
    install_service android-system-vendor.mount
    enable_service  android-system-vendor.mount local-fs.target
fi

# ── WiFi: Hi1102 init ─────────────────────────────────────────────────────────
if has_flag wifi; then
    next_step "Hi1102 WiFi init..."
    install_service hisi-wifi-init.service
    enable_service  hisi-wifi-init.service
fi

# ── WiFi: wpa_supplicant ──────────────────────────────────────────────────────
if has_flag wifi; then
    next_step "wpa_supplicant (interface mode, D-Bus masked)..."
    ln -sf /dev/null "$SYSTEMD/wpa_supplicant.service"
    install_service wpa_supplicant-wlan0.service
    enable_service  wpa_supplicant-wlan0.service
fi

# ── WiFi: DHCP ────────────────────────────────────────────────────────────────
if has_flag wifi; then
    next_step "WiFi DHCP..."
    install_service wifi-dhcp.service
    enable_service  wifi-dhcp.service
fi

# ── WiFi: credentials ─────────────────────────────────────────────────────────
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

# ── WiFi: lock MAC address ────────────────────────────────────────────────────
if has_flag fixmac; then
    next_step "WiFi MAC lock service..."
    install_service wifi-mac-lock.service
    enable_service  wifi-mac-lock.service
    install_script  wifi-mac-lock.sh
fi

# ── Always: boot-debug service ────────────────────────────────────────────────
next_step "Boot debug logger..."
install_service boot-debug.service
enable_service  boot-debug.service
install_script  boot-debug.sh

# ── Always: LED status indicator ──────────────────────────────────────────────
next_step "LED status indicator..."
install_service led-status.service
enable_service  led-status.service  basic.target
install_script  led-status.sh

# ── Headless: disable battery charging ───────────────────────────────────────
if has_flag headless; then
    next_step "Disable battery charging (external PSU)..."
    install_service disable-charger.service
    enable_service  disable-charger.service
fi

# ── Headless: zram swap ───────────────────────────────────────────────────────
if has_flag headless; then
    next_step "zram swap (1GB, lz4)..."
    install_service zram-swap.service
    enable_service  zram-swap.service
fi

# ── Headless: mask Android/UI services ───────────────────────────────────────
if has_flag headless; then
    next_step "Masking unnecessary services (headless server)..."
    for svc in \
        lxc@android.service lxc.service lxc-monitord.service lxc-net.service \
        bluebinder.service bluetooth.service ModemManager.service ofono.service \
        droidian-fpd.service sensorfwd.service iio-sensor-proxy.service nfcd.service \
        phosh.service accounts-daemon.service cups.service cups.path \
        avahi-daemon.service strongswan-starter.service openvpn.service vnstat.service \
        droidian-boot-wlan.service droidian-boot-wlan.path droidian-ipa-enable.service \
        droidian-lmk-disable.service droidian-wcnss-enable.service \
        droidian_boot_completed.service android_boot_completed.service \
        android-cpuset.service android-service@hwcomposer.service \
    ; do
        ln -sf /dev/null "$SYSTEMD/$svc"
    done
    ln -sf /usr/lib/systemd/system/multi-user.target "$SYSTEMD/default.target"

    next_step "Performance tuning (headless server)..."
    install_service cpu-performance.service
    enable_service  cpu-performance.service
    install_script  cpu-performance.sh

    next_step "Display off (headless mode)..."
    install_service display-off.service
    enable_service  display-off.service
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "" >> "$LOG"
echo "=== done ===" >> "$LOG"

echo ""
echo "[OK] Device configured. Services enabled:"
if has_flag usb; then
    echo "     - ADB over USB (FunctionFS gadget)"
fi
echo "     - Android system mount"
echo "     - LED status indicator (blue=boot, green=wifi, yellow=no-wifi, red=shutdown)"
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
