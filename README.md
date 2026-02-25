# Droidian for Huawei Mate 20 Lite (SNE-LX1) — Kirin 710

Build system and CI for the Droidian/Halium port on the Huawei Mate 20 Lite (codename **sydney**, SoC **HiSilicon Kirin 710**).

This is the **first Droidian port for any Kirin device**.

## Status

| Feature | Status |
|---------|--------|
| Boot to Droidian | Working |
| SSH over USB | Working (CDC-NCM gadget) |
| ADB over USB | Working (TCP:5555 over NCM) |
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
│   └── build-halium.yml       # CI — builds halium-boot.img (kernel + initramfs)
├── build-bootimg.sh            # Download kernel + Halium initramfs, patch for Kirin 710, pack boot image
├── setup-device.sh             # Interactive setup: download images, push rootfs, configure device, flash kernel
└── device-config.sh            # On-device config script (flag-based, pure file writes into mounted rootfs)
```

## Related Repositories

| Repository | Description |
|------------|-------------|
| [android_kernel_huawei_kirin710](https://github.com/jglasovic/android_kernel_huawei_kirin710) | Kernel fork — patches, defconfigs, CI-built `Image.gz` |

## Prerequisites

Install on your Mac/Linux host:

- `adb` + `fastboot` — Android platform tools
- `curl` — HTTP downloads
- `gh` (optional) — [GitHub CLI](https://cli.github.com/) for downloading CI artifacts

## Setup

Boot device to **recovery** with ADB enabled, then run the setup script.

### One-liner (no clone needed)

```bash
bash <(curl -sL https://raw.githubusercontent.com/jglasovic/droidian-kirin710/main/setup-device.sh)
```

### From cloned repo

```bash
git clone https://github.com/jglasovic/droidian-kirin710.git
cd droidian-kirin710
bash setup-device.sh
```

### Setup Options

The script prompts for each option before doing anything:

| Option | Default | Description |
|--------|---------|-------------|
| Push rootfs | Yes | Downloads Droidian rootfs, expands to 56GB, pushes to device |
| USB SSH | Yes | CDC-NCM USB network (10.15.19.82) with SSH and ADB over TCP |
| WiFi | No | Hi1102 WiFi with wpa_supplicant + DHCP (asks for SSID/password) |
| Lock MAC | No | Captures WiFi MAC on first boot and locks it permanently |
| Vendor mount | No | Mounts Android vendor partition (auto-enabled with WiFi) |
| Flash kernel | Yes | Flashes halium-boot.img — headless or full-ui variant |

In **headless** mode, the script also masks ~30 unnecessary services (Android container, Bluetooth, telephony, desktop UI, print server, etc.) to free resources and let the system boot cleanly. See [Headless Service Management](#headless-service-management) for the full list.

### What the script does

1. **Downloads** rootfs image, devtools bundle (SSH, git, strace), extras (adbd, dhcpcd), and kernel image
2. **Pushes rootfs** to device userdata partition, expands from ~4GB to 56GB
3. **Stages sideload bundles** — devtools tar + extras debs pushed into rootfs for first-boot installation
4. **Configures services** — USB gadget, WiFi, display-off, masks conflicting/unnecessary services
5. **Flashes kernel** via fastboot

### Boot sequence

After setup, the device reboots twice:

1. **First boot** — `package-sideload` installs all staged packages (devtools + extras), then auto-reboots
2. **Second boot** — normal boot with all services running, ready to use

### Connecting to the device

```bash
# USB SSH (set host IP first)
sudo ifconfig en11 10.15.19.1 netmask 255.255.255.0   # macOS
sudo ip addr add 10.15.19.1/24 dev usb0                # Linux
ssh droidian@10.15.19.82

# USB ADB
adb connect 10.15.19.82:5555

# WiFi SSH (IP assigned via DHCP — check your router)
ssh droidian@<device-wifi-ip>
```

Default credentials: `droidian` / `1234`

### Re-running

The script is re-runnable. Downloaded files are cached locally — select only the steps you want to repeat:
- Change WiFi credentials
- Reflash a different kernel variant
- Reconfigure device services

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WIFI_COUNTRY` | `SI` | Country code for WiFi regulatory domain |

## Technical Details

### USB Networking

The device uses a **CDC-NCM USB gadget** (not RNDIS) for USB networking. The host sees a new network interface (`en11` on macOS, `usb0` on Linux) that must be manually configured with IP `10.15.19.1/24`. The device side is `10.15.19.82/24`.

ADB runs over TCP:5555 on the same NCM link — no separate USB gadget function needed.

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
- `usb-tethering.service` — conflicts with NCM gadget
- `mtp-configfs@.service` — reconfigures USB gadget, tears down NCM
- `isc-dhcp-server.service` — DHCP server (not client) that crashes
- `wpa_supplicant.service` — D-Bus mode causes 100% CPU on Hi1102
- Coredump storage — disabled to prevent disk fill

The adbd service is overridden (`adbd.service.d/override.conf`) to skip its built-in USB gadget management, since our NCM gadget handles USB and adbd listens on TCP:5555 instead.

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
| `graphical.target` | Pulls in display manager + desktop |
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
Core system (dbus, polkit, journald, logind, udevd, timesyncd, resolved), networking (NetworkManager, ssh, adbd), storage (udisks2), hardware monitoring (lm-sensors), and all our custom services (USB NCM, WiFi, display-off, boot-debug).

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
