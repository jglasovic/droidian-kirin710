# Droidian for Huawei Mate 20 Lite (SNE-LX1) — Kirin 710

Build system and CI for the Droidian/Halium port on the Huawei Mate 20 Lite (codename **sydney**, SoC **HiSilicon Kirin 710**).

This is the **first Droidian port for any Kirin device**.

## Status

| Feature | Status |
|---------|--------|
| Boot to Droidian | Working |
| ADB over USB | Working (FunctionFS gadget, plug/replug to connect) |
| WiFi (2.4 GHz + 5 GHz) | Working |
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
│   └── build-halium.yml       # CI — builds halium-boot.img (kernel + initramfs) and recovery.img
├── scripts/                   # Shell scripts installed to /usr/local/sbin on device
│   ├── adbd-ffs-setup.sh      # Sets up configfs ADB gadget + mounts FunctionFS at boot
│   ├── adbd-udc-bind.sh       # Binds gadget to UDC when cable is connected (udev-triggered)
│   ├── boot-debug.sh          # Captures system state after first boot (journald + dmesg)
│   ├── cpu-performance.sh     # CPU/IO/VM tuning for headless server use
│   └── wifi-mac-lock.sh       # Locks WiFi MAC address on first boot
├── services/                  # systemd units and udev rules installed on device
├── build-bootimg.sh           # Download kernel + Halium initramfs, patch for Kirin 710, pack boot image
├── build-recovery.sh          # Build recovery ramdisk with ADB + sideload support
├── flash.sh                   # Download latest CI images and flash to device via fastboot
├── setup-device.sh            # Interactive setup: push rootfs, configure device services
└── device-config.sh           # On-device config script (flag-based, pure file writes into mounted rootfs)
```

## Related Repositories

| Repository | Description |
|------------|-------------|
| [android_kernel_huawei_kirin710](https://github.com/jglasovic/android_kernel_huawei_kirin710) | Kernel fork — patches, defconfigs, CI-built `Image.gz` |

## Prerequisites

Install on your Mac/Linux host:

- `adb` + `fastboot` — Android platform tools
- `curl` — HTTP downloads
- `gh` (optional) — [GitHub CLI](https://cli.github.com/) for downloading the latest CI build artifacts; without it, `flash.sh` falls back to the latest GitHub release

## Setup

The setup is split into two scripts:

1. **`flash.sh`** — downloads the latest CI build of the boot image and recovery, flashes both via fastboot
2. **`setup-device.sh`** — pushes the Droidian rootfs, configures device services, installs extras

### Step 1 — Flash images

Boot device to **fastboot mode**, then run:

```bash
bash <(curl -sL https://raw.githubusercontent.com/jglasovic/droidian-kirin710/main/flash.sh)
```

Or from a cloned repo:

```bash
git clone https://github.com/jglasovic/droidian-kirin710.git
cd droidian-kirin710
bash flash.sh
```

This flashes the headless kernel image and a recovery with ADB + sideload support.

### Step 2 — Configure device

After flashing, the device boots into recovery. Connect a USB cable, wait for ADB, then run:

```bash
bash setup-device.sh
```

### Setup Options

The script prompts for each option before doing anything:

| Option | Default | Description |
|--------|---------|-------------|
| Push rootfs | Yes | Downloads Droidian rootfs, expands to 56GB, pushes to device |
| USB | Yes | ADB over USB via FunctionFS gadget (plug/replug to connect) |
| WiFi | No | Hi1102 WiFi with wpa_supplicant + DHCP (asks for SSID/password) |
| Lock MAC | No | Captures WiFi MAC on first boot and locks it permanently |
| Vendor mount | No | Mounts Android vendor partition (auto-enabled with WiFi) |
| Headless | Yes | Masks UI/Android services, enables display-off + performance tuning |

### What the script does

1. **Downloads** rootfs image, devtools bundle (SSH, git, strace), extras (adbd, dhcpcd), and kernel image
2. **Pushes rootfs** to device userdata partition, expands from ~4GB to 56GB
3. **Stages sideload bundles** — devtools tar + extras debs pushed into rootfs for first-boot installation
4. **Configures services** — ADB gadget, WiFi, display-off, masks conflicting/unnecessary services

### Boot sequence

After setup, the device reboots twice:

1. **First boot** — `package-sideload` installs all staged packages (devtools + extras), then auto-reboots
2. **Second boot** — normal boot with all services running, ready to use

### Connecting to the device

```bash
# ADB over USB (plug or replug cable after boot)
adb devices
adb shell

# SSH over WiFi (IP assigned via DHCP — check your router or boot-debug log)
ssh droidian@<device-wifi-ip>
```

Default credentials: `droidian` / `1234`

### Re-running

Both scripts are re-runnable. Downloaded files are cached locally — select only the steps you want to repeat:
- Change WiFi credentials
- Reconfigure device services
- Re-flash images

## Technical Details

### ADB over USB

The device uses a **FunctionFS ADB gadget** managed via configfs:

- **`adbd-ffs-setup.sh`** runs as `ExecStartPre` for adbd — creates the configfs gadget structure and mounts FunctionFS at `/dev/usb-ffs/adb` without requiring a UDC. This lets adbd write its descriptors immediately at boot regardless of whether a cable is connected.
- **`adbd-udc-bind.sh`** is triggered by udev (`99-adbd-udc.rules`) when a USB Device Controller appears in sysfs (cable connected). It waits for adbd to finish writing FFS descriptors (`ep1` appears), then binds the gadget to the UDC.

This two-part design means ADB works reliably whether the cable is connected before or after boot — just plug or replug the cable and `adb devices` will show the device.

**Kirin 710 quirk**: The HiSilicon `hisi_usb3otg` driver manages a DWC3 dual-role controller that does not auto-switch to device mode. `usb-gadget-trigger.service` writes `device` to the dual-role sysfs node early in boot while the file is still writable.

### WiFi (Hi1102)

The Kirin 710 uses a HiSilicon Hi1102 WiFi chip that requires:
1. Android vendor partition mounted (for firmware)
2. Platform init via `/sys/hisys/boot/plat` and `/sys/hisys/boot/wifi`
3. Interface-mode wpa_supplicant (D-Bus mode causes 100% CPU)
4. DHCP client (`dhcpcd-base`, installed via sideload)

### Rootfs Expansion

The stock Droidian rootfs image is ~4GB and nearly full. The setup script expands it to 56GB using the device's 60GB userdata partition. Since recovery lacks `resize2fs`, it creates a new ext4 image and copies contents over.

### Devtools Side-Effects

The devtools bundle installs packages that conflict with our setup. The script automatically masks:
- `usb-tethering.service` — reconfigures USB gadget, tears down ADB
- `mtp-configfs@.service` — reconfigures USB gadget, tears down ADB
- `isc-dhcp-server.service` — DHCP server (not client) that crashes
- `wpa_supplicant.service` — D-Bus mode causes 100% CPU on Hi1102
- Coredump storage — disabled to prevent disk fill

### Headless Service Management

In headless mode, the script masks ~30 services that are unnecessary for a headless server. This lets `multi-user.target` complete quickly and frees resources.

**Android container stack** (no Halium in headless kernel):

| Service | What it does |
|---------|-------------|
| `lxc@android.service` | Android container (Halium userspace) |
| `lxc.service` | LXC container autostart |
| `lxc-monitord.service` | LXC container state monitor |
| `lxc-net.service` | LXC network bridge (`lxcbr0`) |
| `bluebinder.service` | Bluetooth via Android HAL |
| `ModemManager.service` | Mobile broadband via Android RIL |
| `ofono.service` | Telephony stack (calls, SMS) |
| `droidian-fpd.service` | Fingerprint daemon |
| `sensorfwd.service` | Sensors (accelerometer, gyro, proximity) |
| `android_boot_completed.service` | Android boot completion signal |
| `droidian_boot_completed.service` | Droidian boot completion stamp |
| `android-cpuset.service` | CPU affinity for Android container |
| `android-service@hwcomposer.service` | Android GPU/display compositor |

**UI/Desktop:**

| Service | What it does |
|---------|-------------|
| `phosh.service` | Phosh phone shell (the UI) |
| `accounts-daemon.service` | GUI user account management |

**Unnecessary hardware:**

| Service | What it does |
|---------|-------------|
| `nfcd.service` | NFC daemon |
| `bluetooth.service` | BlueZ Bluetooth |
| `iio-sensor-proxy.service` | Sensor proxy for desktop apps |

**Unnecessary network services:**

| Service | What it does |
|---------|-------------|
| `cups.service` / `cups.path` | Print server |
| `strongswan-starter.service` | IPsec VPN |
| `openvpn.service` | OpenVPN |
| `avahi-daemon.service` | mDNS/DNS-SD |
| `vnstat.service` | Network traffic monitor |

**Droidian helpers for other chipsets:**

| Service | What it does |
|---------|-------------|
| `droidian-boot-wlan.service` / `.path` | Qualcomm WLAN enabler (we use `hisi-wifi-init`) |
| `droidian-ipa-enable.service` | Qualcomm Internet Packet Accelerator |
| `droidian-lmk-disable.service` | Android low-memory-killer (no Android running) |
| `droidian-wcnss-enable.service` | Qualcomm Prima WLAN chip |

**Services kept for headless server use:**
Core system (dbus, polkit, journald, logind, udevd, timesyncd, resolved), networking (NetworkManager, ssh, adbd), storage (udisks2), hardware monitoring (lm-sensors), and all custom services (ADB gadget, WiFi, display-off, boot-debug, cpu-performance).

### Performance Tuning

In headless mode, `cpu-performance.service` runs at boot to optimize for server workloads:

| Setting | Default | Tuned | Effect |
|---------|---------|-------|--------|
| CPU governor | varies | `performance` | All 8 cores locked at max clock (LITTLE: 1709 MHz, big: 2189 MHz) |
| CPU cores | may hotplug | all online | Forces all 8 cores to stay active |
| I/O scheduler | `row` | `deadline` | Better throughput for storage (external HDD) |
| `vm.swappiness` | 60 | 10 | Keep processes in RAM |
| `vm.dirty_ratio` | 20 | 40 | Allow more write buffering before flush |
| `vm.dirty_background_ratio` | 10 | 20 | Start background flush later |
| `vm.vfs_cache_pressure` | 100 | 50 | Keep filesystem metadata cached longer |
| TCP buffer sizes | ~128KB | 6MB | Better throughput for WireGuard/file serving |

## Building the Kernel

### GitHub Actions (recommended)

Run **Build halium-boot.img** — select a kernel branch (`headless-kirin710` or `full-ui-kirin710`) and optionally publish a release.

Artifacts are named by variant: `halium-boot-headless-kirin710` or `halium-boot-full-ui-kirin710`.

### Local Build

Requires an ARM64 machine (or [Colima](https://github.com/abiosoft/colima) with `colima start --arch aarch64 --memory 8`):

```bash
bash build-bootimg.sh
```

Set `KERNEL_BRANCH` to choose a kernel config (`headless-kirin710` default, or `full-ui-kirin710`).

## Links

- [Droidian](https://droidian.org/)
- [Halium](https://halium.org/)
- [Droidian images](https://github.com/droidian-images/droidian/releases)
