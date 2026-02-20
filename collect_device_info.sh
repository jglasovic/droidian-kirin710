#!/usr/bin/env bash
# collect_device_info.sh
# Comprehensive device info collector for Halium/Droidian porting.
# Covers every hardware subsystem needed for a full working port.
#
# Requirements:
#   - adb installed on host
#   - Device connected with USB debugging enabled
#   - Device rooted (LineageOS with root access) for full coverage

set -uo pipefail

OUT="device_info"
LOG="$OUT/collection.log"
ERRORS=0

# ─── HELPERS ──────────────────────────────────────────────────────────────────

c_green='\033[0;32m'; c_yellow='\033[1;33m'; c_red='\033[0;31m'; c_dim='\033[2m'; c_nc='\033[0m'
info()  { echo -e "${c_green}[${section}]${c_nc} $*" | tee -a "$LOG"; }
warn()  { echo -e "${c_yellow}[${section}]${c_nc} WARN: $*" | tee -a "$LOG"; }
saved() { echo -e "  ${c_dim}-> $*${c_nc}" | tee -a "$LOG"; }

section="init"

# Run a command on device, suppress errors, always return 0
d() { adb shell "$@" 2>/dev/null | tr -d '\r' || true; }

# Run with root on device, always return 0
r() { adb shell "su -c '$*'" 2>/dev/null | tr -d '\r' || true; }

# Pull a single file from device to $OUT/<subdir>/<filename>
# Usage: pull_file <device_path> <local_subdir>
pull_file() {
    local dev_path="$1" subdir="$2"
    local fname
    fname=$(basename "$dev_path")
    local dest="$OUT/$subdir/$fname"
    # try normal pull first, then root-assisted
    if adb pull "$dev_path" "$dest" &>/dev/null; then
        saved "$subdir/$fname"
    else
        local tmp="/data/local/tmp/_pull_$$"
        if adb shell "su -c 'cp \"$dev_path\" $tmp && chmod 644 $tmp'" &>/dev/null; then
            adb pull "$tmp" "$dest" &>/dev/null && \
                adb shell "rm -f $tmp" &>/dev/null && \
                saved "$subdir/$fname (via root)" || true
        fi
    fi
}

# Pull a remote path recursively into a local subdir
pull_dir() {
    local dev_path="$1" subdir="$2"
    mkdir -p "$OUT/$subdir"
    adb pull "$dev_path" "$OUT/$subdir/" &>/dev/null || true
}

# Write output of a shell command to a file, skip if empty
capture() {
    local label="$1" dest="$OUT/$2" cmd="${*:3}"
    local tmp
    tmp=$(adb shell "$cmd" 2>/dev/null | tr -d '\r' || true)
    if [ -n "$tmp" ]; then
        echo "$tmp" > "$dest"
        saved "$2"
    fi
}

# Same but with root
rcapture() {
    local label="$1" dest="$OUT/$2" cmd="${*:3}"
    local tmp
    tmp=$(adb shell "su -c '$cmd'" 2>/dev/null | tr -d '\r' || true)
    if [ -n "$tmp" ]; then
        echo "$tmp" > "$dest"
        saved "$2 (root)"
    fi
}

# ─── PREFLIGHT ────────────────────────────────────────────────────────────────

preflight() {
    section="preflight"
    if ! command -v adb &>/dev/null; then
        echo "ERROR: adb not found. Install android-tools or platform-tools." >&2; exit 1
    fi
    if ! adb get-state &>/dev/null; then
        echo "ERROR: No device found. Check USB cable and enable USB debugging." >&2; exit 1
    fi

    # Wait for device to be fully ready
    adb wait-for-device

    MODEL=$(d getprop ro.product.model)
    ANDROID=$(d getprop ro.build.version.release)
    info "Connected: $MODEL (Android $ANDROID)"

    # Check root
    ROOT_CHECK=$(adb shell "su -c 'id'" 2>/dev/null | tr -d '\r' || true)
    if echo "$ROOT_CHECK" | grep -q "uid=0"; then
        info "Root access: YES"
        HAS_ROOT=1
    else
        warn "Root access: NO — some hardware info will be incomplete"
        warn "Grant ADB root in Developer Options (su) or use 'adb root' if eng build"
        HAS_ROOT=0
    fi

    mkdir -p "$OUT"
    echo "Collection started: $(date)" > "$LOG"
    echo "Device: $MODEL / Android $ANDROID / Root: $HAS_ROOT" >> "$LOG"
}

# ─── 1. DEVICE IDENTITY & PROPERTIES ─────────────────────────────────────────

collect_props() {
    section="props"
    info "Collecting all device properties..."
    mkdir -p "$OUT/props"

    d getprop > "$OUT/props/getprop_full.txt"
    saved "props/getprop_full.txt"

    # Grouped key properties
    {
        echo "=== IDENTITY ==="
        for p in ro.product.model ro.product.name ro.product.device ro.product.board \
                  ro.product.manufacturer ro.product.brand ro.build.product \
                  ro.build.fingerprint ro.build.description; do
            echo "$p=$(d getprop "$p")"
        done

        echo ""
        echo "=== PLATFORM ==="
        for p in ro.board.platform ro.hardware ro.hardware.chipname ro.boot.hardware \
                  ro.arch ro.product.cpu.abi ro.product.cpu.abilist; do
            echo "$p=$(d getprop "$p")"
        done

        echo ""
        echo "=== BUILD ==="
        for p in ro.build.version.release ro.build.version.sdk ro.build.version.security_patch \
                  ro.build.type ro.build.tags; do
            echo "$p=$(d getprop "$p")"
        done

        echo ""
        echo "=== DISPLAY ==="
        for p in ro.sf.lcd_density ro.vendor.display.resolution ro.product.display_size \
                  persist.display.native.mode; do
            echo "$p=$(d getprop "$p")"
        done

        echo ""
        echo "=== TREBLE / VNDK ==="
        for p in ro.treble.enabled ro.vndk.version ro.vndk.lite ro.product.vndk.version; do
            echo "$p=$(d getprop "$p")"
        done

        echo ""
        echo "=== NETWORKING ==="
        for p in wifi.interface ro.wifi.channels bluetooth.default_address persist.bluetooth.btsnoopenable \
                  net.dns1 net.dns2; do
            echo "$p=$(d getprop "$p")"
        done

        echo ""
        echo "=== TELEPHONY / MODEM ==="
        for p in ro.telephony.default_network ro.telephony.call_ring.multiple \
                  ro.ril.ecclist ro.ril.hsxpa ro.ril.gprsclass \
                  rild.libpath rild.libargs ro.baseband ro.boot.baseband; do
            echo "$p=$(d getprop "$p")"
        done

        echo ""
        echo "=== CAMERA ==="
        for p in ro.camera.notify_nfc persist.camera.HAL3.enabled \
                  ro.config.media_vol_steps; do
            echo "$p=$(d getprop "$p")"
        done

        echo ""
        echo "=== MISC ==="
        for p in ro.config.ringtone ro.config.notification_sound ro.tethering.usb.enable \
                  ro.bootloader ro.serialno ro.boot.serialno; do
            echo "$p=$(d getprop "$p")"
        done
    } > "$OUT/props/key_props.txt"
    saved "props/key_props.txt"

    # Android feature flags (hardware capability declarations)
    d pm list features > "$OUT/props/pm_features.txt" 2>/dev/null || true
    saved "props/pm_features.txt"
}

# ─── 2. KERNEL & BOOT ─────────────────────────────────────────────────────────

collect_kernel() {
    section="kernel"
    info "Collecting kernel and boot info..."
    mkdir -p "$OUT/kernel"

    d cat /proc/cmdline       > "$OUT/kernel/cmdline.txt"       || true
    d cat /proc/version       > "$OUT/kernel/version.txt"       || true
    d uname -a                > "$OUT/kernel/uname.txt"         || true
    d cat /proc/cpuinfo       > "$OUT/kernel/cpuinfo.txt"       || true
    d cat /proc/meminfo       > "$OUT/kernel/meminfo.txt"       || true
    d cat /proc/iomem         > "$OUT/kernel/iomem.txt"         || true
    d cat /proc/interrupts    > "$OUT/kernel/interrupts.txt"    || true
    d cat /proc/modules       > "$OUT/kernel/modules_proc.txt"  || true
    d lsmod                   > "$OUT/kernel/lsmod.txt"         || true
    d cat /proc/mounts        > "$OUT/kernel/mounts.txt"        || true

    # Loaded modules with paths
    d 'find /vendor/lib/modules /system/lib/modules /odm/lib/modules -name "*.ko" 2>/dev/null' \
        > "$OUT/kernel/module_files.txt" || true

    # Kernel config — check with plain adb shell, not through d() pipe
    if adb shell "ls /proc/config.gz" &>/dev/null; then
        adb pull /proc/config.gz "$OUT/kernel/config.gz" &>/dev/null && \
            gunzip -f "$OUT/kernel/config.gz" && \
            saved "kernel/config (from /proc/config.gz)" || \
            warn "Failed to pull/decompress /proc/config.gz"
    else
        warn "/proc/config.gz not available - will try to extract from boot image"
    fi

    # DT (device tree) info
    d 'ls /proc/device-tree/ 2>/dev/null'           > "$OUT/kernel/device_tree_root.txt" || true
    d 'cat /proc/device-tree/model 2>/dev/null'     > "$OUT/kernel/dt_model.txt"         || true
    d 'cat /proc/device-tree/compatible 2>/dev/null' > "$OUT/kernel/dt_compatible.txt"   || true

    # All platform devices (critical for understanding what hardware is present)
    d 'ls /sys/bus/platform/devices/' > "$OUT/kernel/platform_devices.txt" || true
    d 'ls /sys/bus/i2c/devices/'      > "$OUT/kernel/i2c_devices.txt"      || true
    d 'ls /sys/bus/spi/devices/'      > "$OUT/kernel/spi_devices.txt"      || true
    d 'ls /sys/bus/usb/devices/'      > "$OUT/kernel/usb_bus_devices.txt"  || true
    d 'ls /dev/'                      > "$OUT/kernel/dev_nodes.txt"         || true

    saved "kernel/*.txt"
}

collect_boot_image() {
    section="boot"
    info "Pulling boot image..."
    mkdir -p "$OUT/boot"

    # Find boot partition device node — strip any extra whitespace/newlines
    BOOT_DEV=$(adb shell 'for p in /dev/block/platform/*/by-name/boot /dev/block/by-name/boot; do
        [ -e "$p" ] && readlink -f "$p" && break
    done' 2>/dev/null | tr -d '\r\n ' || true)

    if [ -n "$BOOT_DEV" ]; then
        info "Boot partition: $BOOT_DEV"
        echo "$BOOT_DEV" > "$OUT/boot/boot_partition.txt"

        # Try root dd first, then plain dd
        if adb shell "su -c 'dd if=$BOOT_DEV of=/data/local/tmp/boot.img bs=4096'" &>/dev/null ||
           adb shell "dd if=$BOOT_DEV of=/data/local/tmp/boot.img bs=4096" &>/dev/null; then
            adb pull /data/local/tmp/boot.img "$OUT/boot/boot.img" &>/dev/null && \
                saved "boot/boot.img" || warn "Could not pull boot.img from device"
            adb shell "rm -f /data/local/tmp/boot.img" &>/dev/null || true
        else
            warn "dd failed — device may need root access to read boot partition"
        fi
    else
        warn "Could not find boot partition path — check device_info/partitions/by_name_all.txt manually"
    fi

    # Unpack if tools available
    if [ -f "$OUT/boot/boot.img" ]; then
        if command -v magiskboot &>/dev/null; then
            mkdir -p "$OUT/boot/unpacked"
            if (cd "$OUT/boot/unpacked" && magiskboot unpack ../boot.img) &>/dev/null; then
                saved "boot/unpacked/ (magiskboot)"
            else
                warn "magiskboot unpack failed"
            fi
        elif command -v unpackbootimg &>/dev/null; then
            mkdir -p "$OUT/boot/unpacked"
            if unpackbootimg --input "$OUT/boot/boot.img" --output "$OUT/boot/unpacked/" &>/dev/null; then
                saved "boot/unpacked/ (unpackbootimg)"
            else
                warn "unpackbootimg failed"
            fi
        else
            warn "No boot image unpack tool found (install magiskboot or unpackbootimg)"
        fi
        # Try to extract embedded kernel config
        if command -v extract-ikconfig &>/dev/null; then
            if extract-ikconfig "$OUT/boot/boot.img" > "$OUT/kernel/config_from_boot" 2>/dev/null; then
                saved "kernel/config_from_boot"
            fi
        fi
    fi
}

# ─── 3. PARTITIONS & STORAGE ──────────────────────────────────────────────────

collect_partitions() {
    section="partitions"
    info "Collecting partition layout..."
    mkdir -p "$OUT/partitions"

    d cat /proc/partitions > "$OUT/partitions/proc_partitions.txt" || true

    # by-name symlinks — the most important output for fstab
    d 'find /dev/block -name "by-name" 2>/dev/null | xargs ls -la 2>/dev/null' \
        > "$OUT/partitions/by_name_all.txt" || true
    d 'ls -la /dev/block/platform/*/by-name/ 2>/dev/null' \
        >> "$OUT/partitions/by_name_all.txt" || true

    d 'ls -la /dev/block/platform/' > "$OUT/partitions/platform_block.txt" || true

    # Mount points
    d cat /proc/mounts > "$OUT/partitions/mounts.txt" || true
    d mount             >> "$OUT/partitions/mounts.txt" || true

    # Storage info
    d df -h > "$OUT/partitions/df.txt" || true

    # fstab — try every known location
    {
        for f in \
            /vendor/etc/fstab.hi3670 /vendor/etc/fstab.hi6250 \
            /vendor/etc/fstab.kirin710 /vendor/etc/fstab \
            /fstab.hi3670 /fstab.kirin710 /fstab \
            /system/vendor/etc/fstab /odm/etc/fstab; do
            content=$(d "cat $f 2>/dev/null")
            [ -n "$content" ] && echo "=== $f ===" && echo "$content" && echo ""
        done
        echo "=== find results ==="
        d 'find /vendor /system /odm / -maxdepth 4 -name "fstab*" 2>/dev/null'
    } > "$OUT/partitions/fstab_all.txt"

    saved "partitions/*.txt"
}

# ─── 4. DISPLAY ───────────────────────────────────────────────────────────────

collect_display() {
    section="display"
    info "Collecting display info..."
    mkdir -p "$OUT/display"

    # Framebuffer
    d 'cat /sys/class/graphics/fb0/modes 2>/dev/null'    > "$OUT/display/fb0_modes.txt"
    d 'cat /sys/class/graphics/fb0/mode 2>/dev/null'     > "$OUT/display/fb0_current_mode.txt"
    d 'cat /sys/class/graphics/fb0/virtual_size 2>/dev/null' > "$OUT/display/fb0_virtual_size.txt"
    d 'cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null' > "$OUT/display/fb0_bpp.txt"
    d 'ls /sys/class/graphics/'                          > "$OUT/display/graphics_devices.txt"

    # DRM/KMS (modern)
    d 'ls /sys/class/drm/ 2>/dev/null'                  > "$OUT/display/drm_devices.txt"
    d 'find /sys/class/drm -name "status" -exec sh -c '\''echo "$1: $(cat $1)"'\'' _ {} \; 2>/dev/null' \
        > "$OUT/display/drm_connectors.txt"

    # Panel / backlight
    d 'ls /sys/class/backlight/ 2>/dev/null'             > "$OUT/display/backlight_devices.txt"
    d 'find /sys/class/backlight -name "max_brightness" -exec sh -c '\''echo "$1: $(cat $1)"'\'' _ {} \; 2>/dev/null' \
        > "$OUT/display/backlight_info.txt"
    d 'find /sys/devices -name "lcd_panel_info" -exec cat {} \; 2>/dev/null' \
        > "$OUT/display/lcd_panel_info.txt"
    d 'find /sys/devices -name "hisi_panel_info" -exec cat {} \; 2>/dev/null' \
        >> "$OUT/display/lcd_panel_info.txt"

    # dumpsys
    d 'dumpsys display 2>/dev/null'       > "$OUT/display/dumpsys_display.txt"
    d 'dumpsys SurfaceFlinger 2>/dev/null' | head -200 > "$OUT/display/dumpsys_surfaceflinger.txt"
    d 'dumpsys window 2>/dev/null' | head -100 > "$OUT/display/dumpsys_window.txt"

    # HWC HAL info
    d 'ls /vendor/lib/hw/hwcomposer* /vendor/lib64/hw/hwcomposer* 2>/dev/null' \
        > "$OUT/display/hwc_hal.txt"
    d 'ls /vendor/lib/hw/gralloc* /vendor/lib64/hw/gralloc* 2>/dev/null' \
        >> "$OUT/display/hwc_hal.txt"

    # HiSilicon display-specific
    d 'cat /proc/hisi_display/lcd_info 2>/dev/null'     > "$OUT/display/hisi_lcd_info.txt"
    d 'find /proc/hisi -name "*lcd*" -o -name "*dss*" 2>/dev/null | xargs cat 2>/dev/null' \
        >> "$OUT/display/hisi_lcd_info.txt"

    saved "display/*.txt"
}

# ─── 5. GPU ───────────────────────────────────────────────────────────────────

collect_gpu() {
    section="gpu"
    info "Collecting GPU info..."
    mkdir -p "$OUT/gpu"

    d 'cat /sys/class/misc/mali0/device/uevent 2>/dev/null'   > "$OUT/gpu/mali_uevent.txt"
    d 'cat /sys/kernel/gpu/gpu_freq 2>/dev/null'              > "$OUT/gpu/gpu_freq.txt"
    d 'find /sys -name "*mali*" -type f 2>/dev/null | head -40' > "$OUT/gpu/mali_sysfs.txt"
    d 'find /sys/devices -name "uevent" -path "*mali*" -exec cat {} \; 2>/dev/null' \
        >> "$OUT/gpu/mali_uevent.txt"
    d 'ls /vendor/lib/egl/ /vendor/lib64/egl/ 2>/dev/null'    > "$OUT/gpu/egl_libs.txt"
    d 'ls /vendor/lib/hw/*gpu* /vendor/lib64/hw/*gpu* 2>/dev/null' \
        > "$OUT/gpu/gpu_hal.txt"

    # OpenGL info via dumpsys
    d 'dumpsys SurfaceFlinger 2>/dev/null | grep -A 20 "GLES:"' \
        > "$OUT/gpu/gles_info.txt"

    saved "gpu/*.txt"
}

# ─── 6. WIFI ──────────────────────────────────────────────────────────────────

collect_wifi() {
    section="wifi"
    info "Collecting WiFi info..."
    mkdir -p "$OUT/wifi"

    # Interface
    d 'ip link show 2>/dev/null'                          > "$OUT/wifi/ip_link.txt"
    d 'ls /sys/class/net/'                                > "$OUT/wifi/net_interfaces.txt"
    d 'cat /sys/class/net/wlan0/device/uevent 2>/dev/null' > "$OUT/wifi/wlan0_uevent.txt"
    d 'cat /sys/class/net/wlan0/operstate 2>/dev/null'    > "$OUT/wifi/wlan0_state.txt"

    # HiSilicon specific
    d 'cat /proc/hisi_wifi_chip_info 2>/dev/null'         > "$OUT/wifi/hisi_chip_info.txt"
    d 'cat /proc/hisi_connectivity/wifi_chip_info 2>/dev/null' >> "$OUT/wifi/hisi_chip_info.txt"
    d 'cat /proc/hisi_connectivity/wifi_driver_info 2>/dev/null' >> "$OUT/wifi/hisi_chip_info.txt"
    d 'ls /proc/hisi_connectivity/ 2>/dev/null'           > "$OUT/wifi/hisi_connectivity_dir.txt"

    # Firmware files
    d 'find /vendor/firmware /system/etc/firmware /lib/firmware -name "*hisi*" -o -name "*hi11*" -o -name "*wcnss*" -o -name "*.bin" 2>/dev/null | sort' \
        > "$OUT/wifi/firmware_files.txt"

    # Config files
    d 'find /vendor/etc /system/etc -name "*wifi*" -o -name "wpa_supplicant*" -o -name "hostapd*" 2>/dev/null' \
        > "$OUT/wifi/config_locations.txt"
    for f in /vendor/etc/wifi/wpa_supplicant.conf /system/etc/wifi/wpa_supplicant.conf \
              /vendor/etc/hostapd.conf /vendor/etc/wifi/hostapd.conf; do
        content=$(d "cat $f 2>/dev/null")
        [ -n "$content" ] && echo "=== $f ===" && echo "$content" >> "$OUT/wifi/configs.txt"
    done

    # HAL lib
    d 'ls /vendor/lib/hw/wifi* /vendor/lib64/hw/wifi* 2>/dev/null' > "$OUT/wifi/hal_libs.txt"

    saved "wifi/*.txt"
}

# ─── 7. BLUETOOTH ─────────────────────────────────────────────────────────────

collect_bluetooth() {
    section="bluetooth"
    info "Collecting Bluetooth info..."
    mkdir -p "$OUT/bluetooth"

    d 'ls /sys/class/bluetooth/ 2>/dev/null'              > "$OUT/bluetooth/bt_class.txt"
    d 'cat /sys/class/bluetooth/hci0/type 2>/dev/null'    > "$OUT/bluetooth/hci0_type.txt"
    d 'hciconfig -a 2>/dev/null'                          > "$OUT/bluetooth/hciconfig.txt"

    # UART/serial device for BT (common on HiSilicon)
    d 'ls /dev/ttyAMA* /dev/ttyS* /dev/ttyHSL* 2>/dev/null' > "$OUT/bluetooth/uart_devices.txt"
    d 'ls /dev/bluetooth* 2>/dev/null'                    >> "$OUT/bluetooth/uart_devices.txt"

    # HiSilicon BT specific
    d 'cat /proc/hisi_connectivity/bt_chip_info 2>/dev/null' > "$OUT/bluetooth/hisi_bt_info.txt"
    d 'find /proc/hisi_connectivity -name "*bt*" 2>/dev/null | xargs cat 2>/dev/null' \
        >> "$OUT/bluetooth/hisi_bt_info.txt"

    # Firmware
    d 'find /vendor/firmware /lib/firmware -name "*bt*" -o -name "*bcm*" -o -name "*hisi_bt*" 2>/dev/null | sort' \
        > "$OUT/bluetooth/firmware_files.txt"

    # Config
    d 'find /vendor/etc -name "bt_vendor.conf" -o -name "*bluetooth*" 2>/dev/null' \
        > "$OUT/bluetooth/config_locations.txt"
    d 'cat /vendor/etc/bluetooth/bt_vendor.conf 2>/dev/null' > "$OUT/bluetooth/bt_vendor_conf.txt"

    # HAL
    d 'ls /vendor/lib/hw/bluetooth* /vendor/lib64/hw/bluetooth* /vendor/lib/hw/audio.bt* /vendor/lib64/hw/audio.bt* 2>/dev/null' \
        > "$OUT/bluetooth/hal_libs.txt"

    # Props
    d 'getprop | grep -i bluetooth' > "$OUT/bluetooth/props.txt"

    saved "bluetooth/*.txt"
}

# ─── 8. AUDIO ─────────────────────────────────────────────────────────────────

collect_audio() {
    section="audio"
    info "Collecting audio info..."
    mkdir -p "$OUT/audio"

    # ALSA
    d 'cat /proc/asound/cards 2>/dev/null'                > "$OUT/audio/alsa_cards.txt"
    d 'cat /proc/asound/devices 2>/dev/null'              > "$OUT/audio/alsa_devices.txt"
    d 'cat /proc/asound/pcm 2>/dev/null'                  > "$OUT/audio/alsa_pcm.txt"
    d 'ls /proc/asound/ 2>/dev/null'                      > "$OUT/audio/alsa_proc_dir.txt"

    # Sound devices
    d 'ls /dev/snd/ 2>/dev/null'                          > "$OUT/audio/sound_dev_nodes.txt"
    d 'ls /sys/class/sound/ 2>/dev/null'                  > "$OUT/audio/sound_class.txt"

    # Config files (critical for audio HAL)
    for f in \
        /vendor/etc/audio_policy.conf \
        /vendor/etc/audio_policy_configuration.xml \
        /vendor/etc/audio_effects.conf \
        /vendor/etc/audio_effects.xml \
        /vendor/etc/audio_output_policy.conf \
        /system/etc/audio_policy.conf \
        /system/etc/audio_policy_configuration.xml; do
        content=$(d "cat $f 2>/dev/null")
        if [ -n "$content" ]; then
            fname=$(basename "$f")
            echo "$content" > "$OUT/audio/$fname"
            saved "audio/$fname"
        fi
    done

    # All audio configs
    d 'find /vendor/etc /system/etc -name "*audio*" 2>/dev/null | sort' \
        > "$OUT/audio/all_audio_configs.txt"
    # Pull entire audio config directory
    pull_dir /vendor/etc/audio "$OUT/audio/vendor_etc_audio"

    # HAL libraries
    d 'ls /vendor/lib/hw/audio* /vendor/lib64/hw/audio* 2>/dev/null' \
        > "$OUT/audio/hal_libs.txt"
    d 'ls /vendor/lib/hw/sound* /vendor/lib64/hw/sound* 2>/dev/null' \
        >> "$OUT/audio/hal_libs.txt"

    # Codec / codec firmware
    d 'find /sys/devices -name "*codec*" -type d 2>/dev/null | head -20' \
        > "$OUT/audio/codec_sysfs.txt"
    d 'find /sys/bus/platform/devices -name "*hi6405*" -o -name "*hi6403*" -o -name "*hifi*" 2>/dev/null' \
        >> "$OUT/audio/codec_sysfs.txt"

    # DSP / HiFi firmware
    d 'find /vendor/firmware /system/etc/firmware -name "*hifi*" -o -name "*dsp*" -o -name "*hi64*" 2>/dev/null | sort' \
        > "$OUT/audio/dsp_firmware.txt"

    # dumpsys
    d 'dumpsys audio 2>/dev/null | head -150' > "$OUT/audio/dumpsys_audio.txt"
    d 'dumpsys media.audio_flinger 2>/dev/null | head -150' > "$OUT/audio/dumpsys_audioflinger.txt"

    # Props
    d 'getprop | grep -iE "audio|sound|codec|hifi"' > "$OUT/audio/props.txt"

    saved "audio/*.txt"
}

# ─── 9. CAMERA ────────────────────────────────────────────────────────────────

collect_camera() {
    section="camera"
    info "Collecting camera info..."
    mkdir -p "$OUT/camera"

    # V4L2 devices
    d 'ls /dev/video* /dev/media* 2>/dev/null'            > "$OUT/camera/video_dev_nodes.txt"
    d 'ls /sys/class/video4linux/ 2>/dev/null'            > "$OUT/camera/v4l2_class.txt"
    d 'find /sys/class/video4linux -name "name" -exec sh -c '\''echo "$1: $(cat $1)"'\'' _ {} \; 2>/dev/null' \
        > "$OUT/camera/v4l2_names.txt"

    # Camera HAL
    d 'ls /vendor/lib/hw/camera* /vendor/lib64/hw/camera* 2>/dev/null' \
        > "$OUT/camera/hal_libs.txt"

    # Camera config files
    d 'find /vendor/etc -name "camera*" -o -name "*camera*" 2>/dev/null | sort' \
        > "$OUT/camera/config_locations.txt"
    pull_dir /vendor/etc/camera "$OUT/camera/vendor_etc_camera"

    # Sensor info from kernel
    d 'find /sys/bus/i2c/devices -name "modalias" -exec sh -c '\''echo "$1: $(cat $1)"'\'' _ {} \; 2>/dev/null' \
        > "$OUT/camera/i2c_modaliases.txt"
    d 'find /sys/bus/platform/devices -name "*imx*" -o -name "*ov*" -o -name "*s5k*" -o -name "*ov13*" 2>/dev/null' \
        > "$OUT/camera/sensor_devices.txt"

    # dumpsys
    d 'dumpsys media.camera 2>/dev/null | head -200' > "$OUT/camera/dumpsys_camera.txt"

    # Props
    d 'getprop | grep -iE "camera|flash|torch|lens"' > "$OUT/camera/props.txt"

    saved "camera/*.txt"
}

# ─── 10. SENSORS ──────────────────────────────────────────────────────────────

collect_sensors() {
    section="sensors"
    info "Collecting all sensors..."
    mkdir -p "$OUT/sensors"

    # Android sensor service
    d 'dumpsys sensorservice 2>/dev/null' > "$OUT/sensors/dumpsys_sensorservice.txt"

    # sysfs sensor nodes
    d 'ls /sys/class/sensors/ 2>/dev/null'               > "$OUT/sensors/sensor_class.txt"
    d 'find /sys/class/sensors -name "name" -exec sh -c '\''echo "$1: $(cat $1)"'\'' _ {} \; 2>/dev/null' \
        > "$OUT/sensors/sensor_names.txt"

    # IIO (Industrial I/O) sensors - gyro, accel, etc.
    d 'ls /sys/bus/iio/devices/ 2>/dev/null'              > "$OUT/sensors/iio_devices.txt"
    d 'find /sys/bus/iio/devices -name "name" -exec sh -c '\''echo "$1: $(cat $1)"'\'' _ {} \; 2>/dev/null' \
        >> "$OUT/sensors/iio_devices.txt"

    # Input devices (touchscreen, buttons, proximity, hall)
    d 'getevent -pl 2>/dev/null'                          > "$OUT/sensors/getevent_pl.txt"
    d 'cat /proc/bus/input/devices 2>/dev/null'           > "$OUT/sensors/input_devices.txt"
    d 'ls /sys/class/input/ 2>/dev/null'                  > "$OUT/sensors/input_class.txt"
    d 'find /sys/class/input -name "name" -exec sh -c '\''echo "$1: $(cat $1)"'\'' _ {} \; 2>/dev/null' \
        > "$OUT/sensors/input_names.txt"

    # Accelerometer / Gyroscope
    d 'find /sys/devices -name "*accel*" -o -name "*gyro*" -o -name "*bmi*" -o -name "*lsm*" 2>/dev/null | head -20' \
        > "$OUT/sensors/accel_gyro_nodes.txt"

    # Proximity / Ambient Light
    d 'find /sys/devices -name "*prox*" -o -name "*als*" -o -name "*apds*" -o -name "*rohm*" 2>/dev/null | head -20' \
        > "$OUT/sensors/proximity_als_nodes.txt"

    # Magnetometer / Compass
    d 'find /sys/devices -name "*mag*" -o -name "*compass*" -o -name "*akm*" -o -name "*mmc*" 2>/dev/null | head -20' \
        > "$OUT/sensors/magnetometer_nodes.txt"

    # Barometer
    d 'find /sys/devices -name "*baro*" -o -name "*pressure*" -o -name "*bmp*" 2>/dev/null | head -10' \
        > "$OUT/sensors/barometer_nodes.txt"

    # Hall sensor (lid/flip detection)
    d 'find /sys/devices -name "*hall*" 2>/dev/null' > "$OUT/sensors/hall_nodes.txt"

    # Sensor HAL
    d 'ls /vendor/lib/hw/sensors* /vendor/lib64/hw/sensors* 2>/dev/null' \
        > "$OUT/sensors/hal_libs.txt"

    saved "sensors/*.txt"
}

# ─── 11. TOUCHSCREEN ──────────────────────────────────────────────────────────

collect_touchscreen() {
    section="touchscreen"
    info "Collecting touchscreen info..."
    mkdir -p "$OUT/touchscreen"

    # I2C touchscreen devices
    d 'find /sys/bus/i2c/devices -name "modalias" 2>/dev/null | xargs -I{} sh -c '\''echo "{}: $(cat {})"'\'' 2>/dev/null' \
        > "$OUT/touchscreen/i2c_modalias.txt"
    d 'find /sys/devices -name "*ts_kit*" -o -name "*touch*" -o -name "*ft*" -o -name "*synaptics*" -o -name "*goodix*" -o -name "*novatek*" 2>/dev/null | head -30' \
        > "$OUT/touchscreen/touch_devices.txt"

    # Input event nodes for touchscreen
    d 'grep -i -A5 "touch\|digitizer" /proc/bus/input/devices 2>/dev/null' \
        > "$OUT/touchscreen/input_touch.txt"

    # Panel ID (links display+touch together for in-display devices)
    d 'find /sys/devices -name "panel_id" -exec cat {} \; 2>/dev/null' \
        > "$OUT/touchscreen/panel_id.txt"
    d 'find /sys/devices -name "ts_panel_id" -exec cat {} \; 2>/dev/null' \
        >> "$OUT/touchscreen/panel_id.txt"

    # Firmware
    d 'find /vendor/firmware -name "*ts*" -o -name "*touch*" -o -name "*goodix*" 2>/dev/null | sort' \
        > "$OUT/touchscreen/firmware_files.txt"

    saved "touchscreen/*.txt"
}

# ─── 12. FINGERPRINT ──────────────────────────────────────────────────────────

collect_fingerprint() {
    section="fingerprint"
    info "Collecting fingerprint info..."
    mkdir -p "$OUT/fingerprint"

    d 'ls /dev/goodix_fp /dev/fingerprint* /dev/esfp0 /dev/fpc* /dev/silead* 2>/dev/null' \
        > "$OUT/fingerprint/dev_nodes.txt"
    d 'find /sys/devices -name "*fingerprint*" -o -name "*goodix_fp*" -o -name "*fpc*" 2>/dev/null | head -20' \
        > "$OUT/fingerprint/sysfs_nodes.txt"
    d 'ls /vendor/lib/hw/fingerprint* /vendor/lib64/hw/fingerprint* 2>/dev/null' \
        > "$OUT/fingerprint/hal_libs.txt"
    d 'getprop | grep -iE "finger|biometric|fp_"' \
        > "$OUT/fingerprint/props.txt"
    d 'find /vendor/firmware -name "*fp*" -o -name "*fingerprint*" 2>/dev/null | sort' \
        > "$OUT/fingerprint/firmware_files.txt"

    saved "fingerprint/*.txt"
}

# ─── 13. MODEM / TELEPHONY ────────────────────────────────────────────────────

collect_modem() {
    section="modem"
    info "Collecting modem and telephony info..."
    mkdir -p "$OUT/modem"

    # RIL
    d 'getprop | grep -iE "ril\.|rild\.|telephony\."'    > "$OUT/modem/ril_props.txt"
    d 'ls /dev/ttyAT* /dev/ttyHSL* /dev/modem* /dev/cdc* 2>/dev/null' \
        > "$OUT/modem/modem_dev_nodes.txt"

    # HiSilicon balong modem specific
    d 'ls /dev/hisi* 2>/dev/null'                        >> "$OUT/modem/modem_dev_nodes.txt"
    d 'find /proc/hisi -name "*modem*" 2>/dev/null | xargs cat 2>/dev/null' \
        > "$OUT/modem/hisi_modem_proc.txt"
    d 'cat /proc/hisi_modem/version 2>/dev/null'         >> "$OUT/modem/hisi_modem_proc.txt"

    # Modem firmware
    d 'ls /vendor/modem_fw/ /modem_fw/ /data/modem/ 2>/dev/null' \
        > "$OUT/modem/modem_fw_dir.txt"
    d 'find /vendor -name "*.nv" -o -name "*.img" -path "*modem*" 2>/dev/null | head -30' \
        >> "$OUT/modem/modem_fw_dir.txt"

    # RIL library
    d 'find /vendor/lib /system/lib /vendor/lib64 /system/lib64 -name "libril*" -o -name "librild*" 2>/dev/null | sort' \
        > "$OUT/modem/ril_libs.txt"

    # SIM / telephony state
    d 'dumpsys telephony.registry 2>/dev/null | head -100' > "$OUT/modem/dumpsys_telephony.txt"
    d 'dumpsys iphonesubinfo 2>/dev/null | head -30'       >> "$OUT/modem/dumpsys_telephony.txt"

    # Network interfaces (data)
    d 'ip link show 2>/dev/null | grep -E "rmnet|ccmni|ppp|wwan"' \
        > "$OUT/modem/data_interfaces.txt"

    # Props
    d 'getprop | grep -iE "baseband|imei|meid|isim|sim\.|radio\."' \
        > "$OUT/modem/radio_props.txt"

    saved "modem/*.txt"
}

# ─── 14. GPS / GNSS ───────────────────────────────────────────────────────────

collect_gps() {
    section="gps"
    info "Collecting GPS/GNSS info..."
    mkdir -p "$OUT/gps"

    d 'ls /dev/gnss* /dev/gps* /dev/ttyS* 2>/dev/null'    > "$OUT/gps/dev_nodes.txt"
    d 'find /sys/devices -name "*gnss*" -o -name "*gps*" 2>/dev/null | head -20' \
        > "$OUT/gps/sysfs_nodes.txt"

    # Config files
    for f in /vendor/etc/gps.conf /system/etc/gps.conf \
              /vendor/etc/gnss/gps.conf /vendor/etc/agps_config.conf; do
        content=$(d "cat $f 2>/dev/null")
        [ -n "$content" ] && fname=$(basename "$f") && echo "$content" > "$OUT/gps/$fname"
    done
    d 'find /vendor/etc -name "*gps*" -o -name "*gnss*" -o -name "*agps*" 2>/dev/null | sort' \
        > "$OUT/gps/config_locations.txt"

    # HAL
    d 'ls /vendor/lib/hw/gps* /vendor/lib64/hw/gps* /vendor/lib/hw/gnss* /vendor/lib64/hw/gnss* 2>/dev/null' \
        > "$OUT/gps/hal_libs.txt"

    # Firmware
    d 'find /vendor/firmware /lib/firmware -name "*gps*" -o -name "*gnss*" 2>/dev/null | sort' \
        > "$OUT/gps/firmware_files.txt"

    # Props
    d 'getprop | grep -iE "gps\.|gnss\."' > "$OUT/gps/props.txt"

    saved "gps/*.txt"
}

# ─── 15. NFC ──────────────────────────────────────────────────────────────────

collect_nfc() {
    section="nfc"
    info "Collecting NFC info..."
    mkdir -p "$OUT/nfc"

    d 'ls /dev/nfc* /dev/pn* /dev/st21* /dev/ese* 2>/dev/null' > "$OUT/nfc/dev_nodes.txt"
    d 'find /sys/devices -name "*nfc*" 2>/dev/null | head -20'  > "$OUT/nfc/sysfs_nodes.txt"

    # Config
    for f in /vendor/etc/libnfc-nci.conf /vendor/etc/libnfc-brcm.conf \
              /system/etc/libnfc-nxp.conf /vendor/etc/nfcee_access.xml; do
        content=$(d "cat $f 2>/dev/null")
        [ -n "$content" ] && fname=$(basename "$f") && echo "$content" > "$OUT/nfc/$fname"
    done
    d 'find /vendor/etc /system/etc -name "*nfc*" 2>/dev/null | sort' \
        > "$OUT/nfc/config_locations.txt"

    # HAL
    d 'ls /vendor/lib/hw/nfc* /vendor/lib64/hw/nfc* 2>/dev/null' > "$OUT/nfc/hal_libs.txt"

    # Props
    d 'getprop | grep -iE "nfc\."' > "$OUT/nfc/props.txt"

    saved "nfc/*.txt"
}

# ─── 16. BATTERY & CHARGING ───────────────────────────────────────────────────

collect_battery() {
    section="battery"
    info "Collecting battery and charging info..."
    mkdir -p "$OUT/battery"

    # All power supply info
    d 'ls /sys/class/power_supply/' > "$OUT/battery/power_supply_list.txt"
    for ps in battery usb ac wireless; do
        dir="/sys/class/power_supply/$ps"
        content=$(d "ls $dir 2>/dev/null | xargs -I{} sh -c 'echo \"{}=\$(cat $dir/{})\" 2>/dev/null'")
        [ -n "$content" ] && echo "$content" > "$OUT/battery/${ps}_info.txt"
    done

    # Full dump of all power supply attributes
    d 'find /sys/class/power_supply -type f -name "*.txt" -o -name "type" -o -name "status" \
       -o -name "capacity" -o -name "voltage_now" -o -name "current_now" \
       -o -name "temp" -o -name "technology" -o -name "health" 2>/dev/null | \
       xargs -I{} sh -c '\''echo "$1: $(cat $1 2>/dev/null)"'\'' _ {} 2>/dev/null' \
        > "$OUT/battery/power_supply_attrs.txt"

    # Charger IC info (HiSilicon uses hi6521 charger)
    d 'find /sys/devices -name "*charger*" -o -name "*hi65*" 2>/dev/null | head -20' \
        > "$OUT/battery/charger_devices.txt"

    # Fuel gauge
    d 'find /sys/devices -name "*fuel*" -o -name "*bq27*" -o -name "*max170*" 2>/dev/null | head -10' \
        > "$OUT/battery/fuel_gauge.txt"

    # HAL
    d 'ls /vendor/lib/hw/healthd* /vendor/lib64/hw/healthd* \
           /vendor/lib/hw/health* /vendor/lib64/hw/health* 2>/dev/null' \
        > "$OUT/battery/hal_libs.txt"

    # Props
    d 'getprop | grep -iE "battery|charging|health"' > "$OUT/battery/props.txt"

    saved "battery/*.txt"
}

# ─── 17. THERMAL ──────────────────────────────────────────────────────────────

collect_thermal() {
    section="thermal"
    info "Collecting thermal info..."
    mkdir -p "$OUT/thermal"

    # All thermal zones
    d 'find /sys/class/thermal -name "type" -exec sh -c '\''echo "$1: $(cat $1)"'\'' _ {} \; 2>/dev/null | sort' \
        > "$OUT/thermal/thermal_zone_types.txt"
    d 'find /sys/class/thermal -name "temp" -exec sh -c '\''echo "$1: $(cat $1)"'\'' _ {} \; 2>/dev/null' \
        > "$OUT/thermal/current_temps.txt"
    d 'ls /sys/class/thermal/'                           > "$OUT/thermal/thermal_class.txt"
    d 'ls /sys/class/cooling_device/'                    > "$OUT/thermal/cooling_devices.txt"

    # Config
    d 'find /vendor/etc -name "thermal*" -o -name "*thermal*" 2>/dev/null | sort' \
        > "$OUT/thermal/config_locations.txt"
    for f in /vendor/etc/thermal-engine.conf /vendor/etc/thermal_info_config.xml \
              /vendor/etc/thermal_zones.xml; do
        content=$(d "cat $f 2>/dev/null")
        [ -n "$content" ] && fname=$(basename "$f") && echo "$content" > "$OUT/thermal/$fname"
    done

    # HiSilicon thermal specific
    d 'find /sys/devices -name "*tsensor*" -o -name "*tmpsen*" 2>/dev/null | head -20' \
        > "$OUT/thermal/hisi_tsensors.txt"

    saved "thermal/*.txt"
}

# ─── 18. USB ──────────────────────────────────────────────────────────────────

collect_usb() {
    section="usb"
    info "Collecting USB info..."
    mkdir -p "$OUT/usb"

    # Android USB gadget
    d 'cat /sys/class/android_usb/android0/idVendor 2>/dev/null'   > "$OUT/usb/android0_vid.txt"
    d 'cat /sys/class/android_usb/android0/idProduct 2>/dev/null'  > "$OUT/usb/android0_pid.txt"
    d 'cat /sys/class/android_usb/android0/functions 2>/dev/null'  > "$OUT/usb/android0_functions.txt"
    d 'ls /sys/class/android_usb/ 2>/dev/null'                     > "$OUT/usb/android_usb_class.txt"

    # ConfigFS USB gadget (newer kernels)
    d 'ls /config/usb_gadget/ 2>/dev/null'                         > "$OUT/usb/configfs_gadget.txt"
    d 'find /config/usb_gadget -name "idVendor" -o -name "idProduct" 2>/dev/null | \
       xargs -I{} sh -c '\''echo "$1: $(cat $1)"'\'' _ {} 2>/dev/null' \
        >> "$OUT/usb/configfs_gadget.txt"

    # USB bus
    d 'ls /sys/bus/usb/devices/'                                    > "$OUT/usb/usb_bus_devices.txt"

    # OTG
    d 'find /sys/devices -name "*otg*" -type d 2>/dev/null | head -5' > "$OUT/usb/otg_nodes.txt"
    d 'cat /sys/class/android_usb/android0/state 2>/dev/null'      > "$OUT/usb/android0_state.txt"

    # Props
    d 'getprop | grep -iE "usb\.|persist.sys.usb"' > "$OUT/usb/props.txt"

    saved "usb/*.txt"
}

# ─── 19. VIBRATOR & LEDS ──────────────────────────────────────────────────────

collect_vibrator_leds() {
    section="leds"
    info "Collecting vibrator and LED info..."
    mkdir -p "$OUT/leds"

    # Vibrator
    d 'ls /sys/class/timed_output/ 2>/dev/null'          > "$OUT/leds/timed_output.txt"
    d 'cat /sys/class/timed_output/vibrator/enable 2>/dev/null' > "$OUT/leds/vibrator_enable.txt"
    d 'ls /sys/class/leds/ 2>/dev/null'                  > "$OUT/leds/leds_class.txt"
    d 'find /sys/class/leds -name "max_brightness" -exec sh -c '\''echo "$1: $(cat $1)"'\'' _ {} \; 2>/dev/null' \
        > "$OUT/leds/leds_brightness.txt"
    d 'find /sys/devices -name "*vibr*" -o -name "*haptic*" 2>/dev/null | head -10' \
        > "$OUT/leds/vibrator_nodes.txt"
    d 'ls /vendor/lib/hw/vibrator* /vendor/lib64/hw/vibrator* 2>/dev/null' \
        > "$OUT/leds/hal_libs.txt"

    saved "leds/*.txt"
}

# ─── 20. HAL MANIFESTS & LIBS ─────────────────────────────────────────────────

collect_hal() {
    section="hal"
    info "Collecting HAL manifests and library inventory..."
    mkdir -p "$OUT/hal"

    # VINTF manifests (defines all HALs the device implements - essential for Halium)
    for mf in \
        /vendor/etc/vintf/manifest.xml \
        /vendor/manifest.xml \
        /system/etc/vintf/manifest.xml \
        /odm/etc/vintf/manifest.xml \
        /vendor/etc/vintf/compatibility_matrix.xml \
        /system/etc/vintf/compatibility_matrix.xml; do
        content=$(d "cat $mf 2>/dev/null")
        if [ -n "$content" ]; then
            fname=$(echo "$mf" | tr '/' '_' | sed 's/^_//')
            echo "$content" > "$OUT/hal/$fname"
            saved "hal/$fname"
        fi
    done

    # Full HAL library inventory
    d 'find /vendor/lib/hw /vendor/lib64/hw -name "*.so" 2>/dev/null | sort' \
        > "$OUT/hal/vendor_hw_libs.txt"
    d 'find /vendor/lib /vendor/lib64 -maxdepth 1 -name "*.so" 2>/dev/null | sort' \
        > "$OUT/hal/vendor_libs.txt"
    d 'find /system/lib/hw /system/lib64/hw -name "*.so" 2>/dev/null | sort' \
        > "$OUT/hal/system_hw_libs.txt"

    # HIDL service processes
    d 'ps -A 2>/dev/null | grep -iE "hal\.|@\d"' > "$OUT/hal/running_hal_services.txt"
    d 'hwservicemanager 2>/dev/null' || true
    d 'lshal 2>/dev/null' > "$OUT/hal/lshal.txt" || true

    saved "hal/*.txt"
}

# ─── 21. FIRMWARE FILES ───────────────────────────────────────────────────────

collect_firmware() {
    section="firmware"
    info "Collecting firmware file inventory..."
    mkdir -p "$OUT/firmware"

    # List all firmware (don't pull binaries, just inventory)
    d 'find /vendor/firmware /system/etc/firmware /lib/firmware /odm/firmware 2>/dev/null | sort' \
        > "$OUT/firmware/all_firmware_files.txt"

    # Categorized
    for subsystem in wifi bt gps nfc hifi dsp audio hi11 hi6 audio camera; do
        d "find /vendor/firmware /system/etc/firmware /lib/firmware -iname \"*${subsystem}*\" 2>/dev/null | sort" \
            > "$OUT/firmware/${subsystem}_firmware.txt"
        [ -s "$OUT/firmware/${subsystem}_firmware.txt" ] || rm -f "$OUT/firmware/${subsystem}_firmware.txt"
    done

    saved "firmware/*.txt"
}

# ─── 22. INIT FILES ───────────────────────────────────────────────────────────

collect_init() {
    section="init"
    info "Collecting init scripts..."
    mkdir -p "$OUT/init"

    # All .rc files - these define services, permissions, device nodes
    d 'find /vendor/etc/init /system/etc/init /odm/etc/init 2>/dev/null | sort' \
        > "$OUT/init/rc_file_locations.txt"

    # Pull them all
    ALL_RC=$(d 'find /vendor/etc/init /system/etc/init /odm/etc/init -name "*.rc" 2>/dev/null')
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        fname=$(echo "$f" | tr '/' '_' | sed 's/^_//')
        content=$(d "cat $f 2>/dev/null")
        [ -n "$content" ] && echo "$content" > "$OUT/init/$fname"
    done <<< "$ALL_RC"

    # Root init scripts
    d 'ls /*.rc 2>/dev/null'                              > "$OUT/init/root_rc_list.txt"
    d 'cat /init.rc 2>/dev/null'                          > "$OUT/init/init.rc"
    # Device-specific root rc (e.g. init.hi3670.rc)
    d 'find / -maxdepth 1 -name "init.*.rc" 2>/dev/null | xargs -I{} sh -c '\''echo "=== {} ==="; cat {}'\'' 2>/dev/null' \
        > "$OUT/init/root_device_rc.txt"

    # ueventd rules (defines device node permissions - needed for Halium)
    d 'find / -maxdepth 1 -name "ueventd*.rc" 2>/dev/null | xargs cat 2>/dev/null' \
        > "$OUT/init/ueventd.txt"
    d 'find /vendor /system/etc -name "ueventd*" 2>/dev/null | xargs cat 2>/dev/null' \
        >> "$OUT/init/ueventd.txt"

    saved "init/ ($(ls "$OUT/init/" | wc -l | tr -d ' ') files)"
}

# ─── 23. SELINUX ──────────────────────────────────────────────────────────────

collect_selinux() {
    section="selinux"
    info "Collecting SELinux policy info..."
    mkdir -p "$OUT/selinux"

    d 'getenforce 2>/dev/null'                            > "$OUT/selinux/enforce_mode.txt"
    d 'ls /vendor/etc/selinux/ 2>/dev/null'              > "$OUT/selinux/vendor_selinux.txt"
    d 'ls /system/etc/selinux/ 2>/dev/null'              > "$OUT/selinux/system_selinux.txt"

    # file_contexts defines what label each path gets (needed for Halium udev rules)
    d 'cat /vendor/etc/selinux/vendor_file_contexts 2>/dev/null' \
        > "$OUT/selinux/vendor_file_contexts.txt"
    d 'cat /system/etc/selinux/plat_file_contexts 2>/dev/null' \
        > "$OUT/selinux/plat_file_contexts.txt"

    # property contexts
    d 'cat /vendor/etc/selinux/vendor_property_contexts 2>/dev/null' \
        > "$OUT/selinux/vendor_property_contexts.txt"

    saved "selinux/*.txt"
}

# ─── 24. POWER MANAGEMENT ─────────────────────────────────────────────────────

collect_power() {
    section="power"
    info "Collecting power management info..."
    mkdir -p "$OUT/power"

    d 'cat /sys/power/state 2>/dev/null'                  > "$OUT/power/pm_states.txt"
    d 'cat /sys/power/wakeup_count 2>/dev/null'           > "$OUT/power/wakeup_count.txt"
    d 'cat /proc/wakelocks 2>/dev/null'                   > "$OUT/power/wakelocks.txt"
    d 'ls /sys/class/wakelock/ 2>/dev/null'               > "$OUT/power/wakelock_class.txt"
    d 'find /sys/class/wakelock -exec sh -c '\''echo "$1: $(cat $1/active 2>/dev/null)"'\'' _ {} \; 2>/dev/null' \
        >> "$OUT/power/wakelock_class.txt"

    # CPU frequency scaling
    d 'find /sys/devices/system/cpu/cpu0/cpufreq -type f -exec sh -c '\''echo "$1: $(cat $1)"'\'' _ {} \; 2>/dev/null' \
        > "$OUT/power/cpu_freq.txt"

    # Power HAL
    d 'ls /vendor/lib/hw/power* /vendor/lib64/hw/power* 2>/dev/null' \
        > "$OUT/power/hal_libs.txt"

    # Regulator list
    d 'ls /sys/class/regulator/ 2>/dev/null'              > "$OUT/power/regulators.txt"
    d 'find /sys/class/regulator -name "name" -exec sh -c '\''echo "$1: $(cat $1)"'\'' _ {} \; 2>/dev/null' \
        >> "$OUT/power/regulators.txt"

    saved "power/*.txt"
}

# ─── 25. MISC & VENDOR CONFIGS ────────────────────────────────────────────────

collect_misc() {
    section="misc"
    info "Collecting vendor configs and misc info..."
    mkdir -p "$OUT/misc"

    # Full vendor/etc directory listing
    d 'find /vendor/etc -type f 2>/dev/null | sort' > "$OUT/misc/vendor_etc_all.txt"

    # Media codecs
    d 'cat /vendor/etc/media_codecs.xml 2>/dev/null'     > "$OUT/misc/media_codecs.xml"
    d 'cat /vendor/etc/media_profiles.xml 2>/dev/null'   > "$OUT/misc/media_profiles.xml"
    d 'cat /vendor/etc/media_profiles_V1_0.xml 2>/dev/null' >> "$OUT/misc/media_profiles.xml"
    d 'cat /system/etc/media_codecs.xml 2>/dev/null'     >> "$OUT/misc/media_codecs.xml"

    # DRM
    d 'getprop | grep -iE "drm\.|widevine\."'            > "$OUT/misc/drm_props.txt"
    d 'ls /vendor/lib/mediadrm/ /vendor/lib64/mediadrm/ 2>/dev/null' \
        > "$OUT/misc/drm_libs.txt"

    # SIM slots / dual SIM
    d 'getprop | grep -iE "sim|slot|msim"'               > "$OUT/misc/sim_props.txt"

    # Light HAL (notification LED, backlight, buttons)
    d 'ls /vendor/lib/hw/lights* /vendor/lib64/hw/lights* 2>/dev/null' \
        > "$OUT/misc/lights_hal.txt"

    # Keymaster / Gatekeeper
    d 'ls /vendor/lib/hw/keymaster* /vendor/lib64/hw/keymaster* \
           /vendor/lib/hw/gatekeeper* /vendor/lib64/hw/gatekeeper* 2>/dev/null' \
        > "$OUT/misc/security_hal.txt"

    # Dumpstate
    d 'getprop | grep -i dumpstate'                      > "$OUT/misc/dumpstate_props.txt"

    # logcat for HAL errors (last 500 lines)
    d 'logcat -d -b main -b system 2>/dev/null | tail -500' > "$OUT/misc/logcat_tail.txt"
    d 'logcat -d 2>/dev/null | grep -iE "fail|error|crash" | tail -200' > "$OUT/misc/logcat_errors.txt"

    saved "misc/*.txt"
}

# ─── SUMMARY ──────────────────────────────────────────────────────────────────

print_summary() {
    local total_files
    total_files=$(find "$OUT" -type f | wc -l | tr -d ' ')

    echo ""
    echo "══════════════════════════════════════════════════"
    echo " Collection complete"
    echo " Output directory : ./$OUT/"
    echo " Total files      : $total_files"
    echo "══════════════════════════════════════════════════"
    echo ""
    echo "Device identity:"
    grep -E "ro.product.(device|board|name|manufacturer)|ro.board.platform|ro.hardware=" \
        "$OUT/props/key_props.txt" 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "Quick status:"
    for subsys in display wifi bluetooth audio camera sensors modem gps nfc fingerprint battery thermal; do
        count=$(find "$OUT/$subsys" -type f 2>/dev/null | wc -l | tr -d ' ')
        echo "  $subsys: $count files"
    done
    echo ""
    echo "Next: review $OUT/props/key_props.txt and $OUT/partitions/by_name_all.txt"
    echo "      then fill in build_halium.sh configuration section"
    echo ""
    echo "Full collection log: $LOG"
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────

echo "══════════════════════════════════════════════════"
echo " Droidian/Halium Device Info Collector"
echo " Huawei Mate 20 Lite — Kirin 710"
echo "══════════════════════════════════════════════════"
echo ""

preflight
collect_props
collect_kernel
collect_boot_image
collect_partitions
collect_display
collect_gpu
collect_wifi
collect_bluetooth
collect_audio
collect_camera
collect_sensors
collect_touchscreen
collect_fingerprint
collect_modem
collect_gps
collect_nfc
collect_battery
collect_thermal
collect_usb
collect_vibrator_leds
collect_hal
collect_firmware
collect_init
collect_selinux
collect_power
collect_misc
print_summary
