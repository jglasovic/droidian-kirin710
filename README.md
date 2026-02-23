# Droidian for Huawei Mate 20 Lite (SNE-LX1) — Kirin 710

Droidian/Halium port for the Huawei Mate 20 Lite (codename **sydney**, SoC **HiSilicon Kirin 710**).

This is the **first Droidian port for any Kirin device**. Unlike Qualcomm/MediaTek devices that have mature mainline or Halium support, Kirin 710 requires significant custom work — particularly around WiFi (Hi1102 chip) and vendor partition handling.

## Status

| Feature | Status |
|---------|--------|
| Boot to Droidian | Working |
| SSH (USB NCM) | Working |
| WiFi (2.4 GHz + 5 GHz) | Working (with workarounds) |
| SSH over WiFi | Working |
| Display | Working (can be turned off for headless use) |
| Bluetooth | Not tested |
| Audio | Not tested |
| Camera | Not tested |
| Modem / Calls | Not tested |
| GPS | Not tested |

## Repository Structure

```
.
├── .github/workflows/
│   └── build-halium.yml          # GitHub Actions CI — builds kernel + boot image
├── device-tree/sydney/           # Android device tree (BoardConfig, manifests, overlays)
├── kernel-configs/
│   └── arch/arm64/configs/
│       └── kirin710_defconfig    # Customized kernel config
├── build-kernel.sh               # Build script: clone kernel, patch, compile
├── build-bootimg.sh              # Build script: download GSI, patch ramdisk, pack boot image
├── collect_device_info.sh        # Dumps hardware info from device via ADB
└── extract-vendor-sydney.sh      # Extracts vendor blobs from device via ADB
```

## Prerequisites

### Hardware
- Huawei Mate 20 Lite (SNE-LX1 or SNE-L21)
- **Unlocked bootloader** (required for fastboot flashing)
- USB cable
- A WiFi network for post-setup connectivity

### Software
- `fastboot` and `adb` installed on your computer
- For local kernel builds: an ARM64 Linux machine or [Colima](https://github.com/abiosoft/colima) VM with Ubuntu
- For CI builds: just push to GitHub (Actions workflow handles everything)

### Images to Download
1. **Droidian rootfs** — from [droidian-images releases](https://github.com/droidian-images/droidian/releases) (API 33, arm64)
2. **Halium system image** — the CI workflow downloads this from UBports CI automatically, or get it manually from the [UBports CI](https://ci.ubports.com)

## Building

### Option A: GitHub Actions (recommended)

Push to the repo and trigger the `Build Halium` workflow manually from the Actions tab. It runs on a native ARM64 runner and:
1. Runs `build-kernel.sh` — clones kernel, patches ~40 broken include paths, compiles
2. Runs `build-bootimg.sh` — downloads Halium GSI, patches ramdisk (init=/init fix), packs boot image
3. Uploads artifacts (halium-boot.img, system.img)

### Option B: Local Build

Requires an ARM64 machine (or Colima with `colima start --arch aarch64 --memory 8`):

```bash
# SSH into Colima
colima ssh

# Step 1: Build the kernel
bash build-kernel.sh

# Step 2: Download GSI, patch ramdisk, pack boot image
bash build-bootimg.sh
```

Output: `halium-boot.img` and `system.img` in the project root.

## Flashing

Boot into fastboot mode (hold Volume Down + Power while connecting USB):

```bash
# Flash the kernel (boot partition is named "kernel" on Kirin 710, not "boot")
fastboot flash kernel halium-boot.img

# Flash the Android system image to userdata
# (Halium uses system.img on the userdata partition, NOT the system partition)
fastboot flash userdata system.img
```

Then flash the Droidian rootfs according to [Droidian installation docs](https://devices.droidian.org/).

## Post-Flash Setup

After first boot, connect via USB and SSH:

```bash
# Set USB NCM IP on your computer (the device gets 10.15.19.82)
# On macOS:
sudo ifconfig en8 10.15.19.1 netmask 255.255.255.0 up
# On Linux:
sudo ip addr add 10.15.19.1/24 dev usb0

ssh droidian@10.15.19.82
# Default password: droidian
```

### 1. Vendor Partition Mount

The vendor partition (contains WiFi firmware, configs) must be mounted before WiFi can work. Create this systemd mount unit:

```bash
sudo tee /etc/systemd/system/android-system-vendor.mount << 'EOF'
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
EOF

sudo systemctl daemon-reload
sudo systemctl enable android-system-vendor.mount
```

### 2. WiFi Initialization Service

The Hi1102 WiFi chip uses **deferred initialization** — it doesn't auto-init at boot because the vendor partition (with firmware) isn't mounted yet when the driver loads. We need a service to trigger init via sysfs:

```bash
sudo tee /etc/systemd/system/hisi-wifi-init.service << 'EOF'
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
EOF

sudo systemctl daemon-reload
sudo systemctl enable hisi-wifi-init.service
```

### 3. wpa_supplicant (Interface Mode)

The default D-Bus mode wpa_supplicant **must be masked** — it creates a P2P interface that triggers an infinite wait bug in the Hi1102 driver, causing 100% CPU and device overheating.

```bash
# Mask the default wpa_supplicant (D-Bus mode)
sudo systemctl mask wpa_supplicant.service

# Create wpa_supplicant config with p2p DISABLED
sudo tee /etc/wpa_supplicant/wpa_supplicant.conf << 'EOF'
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
p2p_disabled=1
country=SI

network={
    ssid="YOUR_WIFI_SSID"
    psk="YOUR_WIFI_PASSWORD"
}
EOF

# Create standalone wpa_supplicant service (interface mode, NOT D-Bus)
sudo tee /etc/systemd/system/wpa_supplicant-wlan0.service << 'EOF'
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
EOF

sudo systemctl daemon-reload
sudo systemctl enable wpa_supplicant-wlan0.service
```

### 4. DHCP Client

`systemd-networkd` cannot be used — it crashes with the Hi1102 driver (`Could not enumerate wireless LAN stations`). Use `dhcpcd` instead:

```bash
sudo apt install dhcpcd5

# Configure dhcpcd to only manage wlan0
echo "allowinterfaces wlan0" | sudo tee -a /etc/dhcpcd.conf
```

### 5. Display Off (Optional — for headless/server use)

```bash
sudo tee /etc/systemd/system/display-off.service << 'EOF'
[Unit]
Description=Turn off LCD display
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "dd if=/dev/zero of=/dev/fb0 bs=4096 count=1024 2>/dev/null; echo 4 > /sys/class/graphics/fb0/blank; echo 0 > /sys/class/leds/lcd_backlight0/brightness"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable display-off.service
```

### 6. Reboot and Verify

```bash
sudo reboot
```

After reboot, you should be able to SSH over WiFi. Verify all services:

```bash
systemctl status android-system-vendor.mount   # vendor mounted
systemctl status hisi-wifi-init.service         # wifi initialized
systemctl status wpa_supplicant-wlan0.service   # connected to wifi
systemctl status dhcpcd.service                 # DHCP IP obtained
ip addr show wlan0                              # should have an IP
```

## Known Issues & Workarounds

### Hi1102 WiFi Driver Bugs

The HiSilicon Hi1102 WiFi driver has several issues when used outside of Android:

| Issue | Impact | Workaround |
|-------|--------|------------|
| P2P interface creation hangs | wpa_supplicant (D-Bus mode) spins at 100% CPU, device overheats | Use `p2p_disabled=1` + interface mode wpa_supplicant |
| `wal_cfg80211_scan` uses infinite wait | Scan requests can hang forever if firmware doesn't respond | Use nl80211 (not wext), ensure firmware is loaded before scanning |
| `get_station` called repeatedly with 5s timeout | CPU usage spikes when NetworkManager polls station info | Don't use NetworkManager for WiFi management |
| systemd-networkd crashes | "Could not enumerate wireless LAN stations" timeout | Use dhcpcd instead |

### Kernel Threads in D State

After boot, ~26 kernel threads appear in D (uninterruptible sleep) state — modem, camera ISP, HISEE, etc. These are waiting for Android HAL services that aren't running. They consume **0% CPU** and are purely cosmetic (inflates load average to ~26). Fixing requires a kernel rebuild to disable unused subsystems.

### init=/init Override

The Kirin 710 kernel has `init=/init` hardcoded in its built-in command line. Without the patch applied by `build-bootimg.sh`, this would cause the initramfs to loop back into itself instead of booting systemd. The script patches the stock ramdisk's init to override `init=/init` → `/sbin/init`.

### 5 GHz WiFi

5 GHz works **only if the vendor partition is mounted before WiFi initialization**. The 5 GHz band is enabled by `band_5g_enable=1` in the vendor config file (`/vendor/firmware/hi1102/wifi_cfg/cfg_sne_lx1_hisi.ini`). If vendor isn't mounted at init time, only 2.4 GHz channels are available.

## Adapting for Other Kirin 710 Devices

Other Kirin 710 devices in the "sydney" family (P Smart+ 2019, Nova 3i, Honor 8X, etc.) share the same SoC and Hi1102 WiFi chip. To adapt:

1. Check your device's partition layout (`by-partlabel` names may differ)
2. Update the vendor mount unit with your partition label
3. The WiFi init and wpa_supplicant setup should work identically
4. Update the defconfig if your device has different peripherals
5. Check the vendor config INI filename — it's device-model-specific (e.g., `cfg_sne_lx1_hisi.ini`)

## Author

**Jure Glasovic** ([@jglasovic](https://github.com/jglasovic))

## Links

- **Kernel source**: [Huawei-Dev/android_kernel_huawei_kirin710](https://github.com/Huawei-Dev/android_kernel_huawei_kirin710) (branch `android@13`)
- **Droidian**: [droidian.org](https://droidian.org/)
- **Halium**: [halium.org](https://halium.org/)
- **Droidian images**: [droidian-images/droidian](https://github.com/droidian-images/droidian/releases)
