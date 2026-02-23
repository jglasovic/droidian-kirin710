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
├── build-bootimg.sh              # Build script: download Halium initramfs, patch for Kirin 710, pack boot image
├── setup-device.sh               # Post-flash setup: WiFi, vendor mount, SSH over network
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

You need 3 images (+ 1 optional):

1. **Halium boot image** (`halium-boot.img`) — built from this repo (see [Building](#building-the-boot-image) below), or download from [GitHub Actions artifacts](../../actions)
2. **Halium system image** — Halium 13 generic arm64 GSI from [UBports CI](https://ci.ubports.com/job/UBportsCommunityPortsJenkinsCI/job/ubports%252Fporting%252Fcommunity-ports%252Fjenkins-ci%252Fgeneric_arm64/job/halium-13.0/) — download the `halium_halium_arm64.tar.xz` artifact (extract to get `system.img`)
3. **Droidian rootfs** — from [droidian-images releases](https://github.com/droidian-images/droidian/releases) — download `droidian-OFFICIAL-phosh-phone-rootfs-api33-arm64-*.zip` (extract to get `data/rootfs.img`)
4. **Droidian devtools** (optional, recommended) — from the same [droidian-images releases](https://github.com/droidian-images/droidian/releases) — download `droidian-OFFICIAL-phosh-phone-devtools-api33-arm64-*.zip`

## Building the Boot Image

### Option A: GitHub Actions (recommended)

Push to the repo and trigger the `Build Halium` workflow manually from the Actions tab. It runs on a native ARM64 runner and:
1. Runs `build-kernel.sh` — clones kernel, patches ~40 broken include paths, compiles
2. Runs `build-bootimg.sh` — downloads Halium initramfs, applies Kirin 710 patches (switch_root, init override, non-ext4 userdata), packs boot image
3. Uploads `halium-boot.img` artifact

### Option B: Local Build

Requires an ARM64 machine (or Colima with `colima start --arch aarch64 --memory 8`):

```bash
# SSH into Colima
colima ssh

# Step 1: Build the kernel
bash build-kernel.sh

# Step 2: Download Halium initramfs, patch, pack boot image
bash build-bootimg.sh
```

Output: timestamped images in `out/` (e.g., `out/halium-boot-20260223-130716.img`) with a `halium-boot.img` symlink to the latest build.

## Flashing

### Kirin 710 Partition Layout

| Partition | Fastboot name | Description |
|-----------|--------------|-------------|
| `kernel_a` | `kernel` | Boot image (NOT called "boot" like on Qualcomm) |
| `system_a` | `system` | Halium system image (Android GSI) |
| `userdata` | `userdata` | User data (f2fs) — Droidian rootfs lives here as `/rootfs.img` |
| `vendor_a` | `vendor` | Stock EMUI vendor (do NOT flash — contains WiFi firmware) |

### Step 1: Flash system.img and boot image

Boot into fastboot mode: hold **Volume Down + Power** while connecting USB, or run `adb reboot bootloader` from a running system.

```bash
# Verify device is detected
fastboot devices

# Flash the Halium system image (Android 13 GSI)
fastboot flash system system.img

# Flash the kernel/boot image
fastboot flash kernel halium-boot.img

# Reboot into the new system
fastboot reboot
```

### Step 2: Push Droidian rootfs

On first boot, the device will boot into the Halium initramfs. It will mount userdata but won't find `rootfs.img` yet, so it will start a telnet server on the USB interface. From your computer:

```bash
# Set up the USB network interface
# macOS:
sudo ifconfig en8 10.15.19.1 netmask 255.255.255.0 up
# Linux:
sudo ip addr add 10.15.19.1/24 dev usb0

# Telnet into the initramfs
telnet 10.15.19.82

# Inside telnet, check that userdata is mounted
mount | grep userdata
# Should show: /dev/mmcblk0pXX on /tmpmnt type f2fs (...)

# Exit telnet
exit
```

Now push the rootfs from your computer using SCP or by extracting the zip:

```bash
# Extract the Droidian rootfs zip (contains rootfs.img)
unzip droidian-OFFICIAL-phosh-phone-rootfs-api33-arm64-nightly_YYYYMMDD.zip

# Push rootfs.img to the device via SCP (from the initramfs telnet/SSH)
scp data/rootfs.img root@10.15.19.82:/tmpmnt/

# If you downloaded devtools, also extract and push it
unzip droidian-OFFICIAL-phosh-phone-devtools-api33-arm64-nightly_YYYYMMDD.zip
scp data/devtools.img root@10.15.19.82:/tmpmnt/
```

Alternative — if SCP doesn't work from initramfs, use ADB:

```bash
# If the device shows up in adb
adb push data/rootfs.img /tmpmnt/
adb push data/devtools.img /tmpmnt/    # optional
```

### Step 3: Reboot

```bash
# From telnet on the device:
reboot

# Or from your computer:
adb reboot
```

The device will now boot into Droidian. First boot takes 1-2 minutes as it resizes the rootfs.

### Step 4: Verify boot

After boot, connect via USB SSH:

```bash
# Set up USB network (if not already done)
# macOS:
sudo ifconfig en8 10.15.19.1 netmask 255.255.255.0 up
# Linux:
sudo ip addr add 10.15.19.1/24 dev usb0

# SSH into Droidian
ssh droidian@10.15.19.82
# Default password: droidian
```

### Reflashing just the kernel

After the initial setup, you only need to reflash the kernel when updating:

```bash
# From the device:
sudo reboot bootloader

# From your computer:
fastboot flash kernel halium-boot.img
fastboot reboot
```

## Post-Flash Setup

After first boot, connect via USB and set your computer's USB NCM IP:

```bash
# On macOS:
sudo ifconfig en8 10.15.19.1 netmask 255.255.255.0 up
# On Linux:
sudo ip addr add 10.15.19.1/24 dev usb0
```

### Automated Setup (recommended)

Run the setup script from your computer — it configures everything over SSH:

```bash
bash setup-device.sh 10.15.19.82 "YOUR_WIFI_SSID" "YOUR_WIFI_PASSWORD"
```

Then reboot the device. After reboot, it will auto-connect to WiFi and SSH will be available over the network.

### Manual Setup

If you prefer to set things up manually, SSH into the device first:

```bash
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

### 6. Lock WiFi MAC Address

The Hi1102 driver randomizes the last 3 bytes of the MAC address on each boot. To get a stable MAC for static DHCP leases on your router:

```bash
sudo tee /etc/systemd/network/10-wlan0-mac.link << 'EOF'
[Match]
OriginalName=wlan0

[Link]
MACAddress=c0:11:02:e8:50:ea
EOF
```

Replace the MAC with the one assigned to your device (`ip link show wlan0`).

### 7. Reboot and Verify

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
| MAC address randomized on boot | Last 3 bytes change each reboot, breaks static DHCP | Lock MAC via systemd `.link` file |

### Kernel Threads in D State

The `headless-minimal` branch disables ~30 unused kernel subsystems (modem, camera, audio, HISEE, sensors, etc.), reducing D-state threads from ~26 to 5 and idle load average from ~26 to ~5. The remaining D-state threads are essential (eMMC, TEE, blackbox/reboot infrastructure). The `main` branch has the stock config with all subsystems enabled.

### Initramfs Patches

`build-bootimg.sh` downloads the stock [Halium initramfs](https://github.com/Halium/initramfs-tools-halium) and applies 4 patches required for Kirin 710:

1. **init=/init override** — the kernel has `init=/init` hardcoded in its cmdline, which loops back into the initramfs. Patched to use `/sbin/init` (systemd).
2. **switch_root** — stock Halium uses `run-init` which fails on Kirin 710. Replaced with `switch_root`.
3. **validate_init()** — rewritten to check if init exists in rootfs instead of using `run-init -n`.
4. **Non-ext4 userdata** — stock Halium assumes ext4 userdata and runs `e2fsck`. Patched to detect filesystem type and skip e2fsck for non-ext4.

### WiFi MAC Randomization

The Hi1102 driver assigns a random MAC address (last 3 bytes) on every boot, using the Huawei OUI `c0:11:02`. The `setup-device.sh` script locks the MAC via a systemd `.link` file. If you need a stable MAC for static DHCP, see the manual setup section above.

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
