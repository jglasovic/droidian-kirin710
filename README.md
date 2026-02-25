# Droidian for Huawei Mate 20 Lite (SNE-LX1) — Kirin 710

Build system and CI for the Droidian/Halium port on the Huawei Mate 20 Lite (codename **sydney**, SoC **HiSilicon Kirin 710**).

This is the **first Droidian port for any Kirin device**.

## Status

| Feature | Status |
|---------|--------|
| Boot to Droidian | Working |
| ADB (USB + TCP) | Working |
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
│   └── build-halium.yml       # CI — builds halium-boot.img (kernel + initramfs)
├── build-bootimg.sh            # Download kernel + Halium initramfs, patch for Kirin 710, pack boot image
├── setup-device.sh             # All-in-one setup: download images, push rootfs, configure device, flash kernel
└── device-config.sh            # On-device config script (pure file writes into mounted rootfs)
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

1. Boot device to **recovery** with ADB enabled
2. Run the setup script:

```bash
bash setup-device.sh
```

The script will:
- Download `halium-boot.img` from CI (or GitHub release)
- Download `rootfs.img` from Droidian releases
- Push `rootfs.img` to device via ADB
- Ask for WiFi SSID + password
- Configure all device services (USB network, WiFi, vendor mount)
- Reboot to fastboot and flash the kernel

3. After reboot:

```bash
# SSH over USB
ssh droidian@10.15.19.82

# Default password: 1234
```

### Re-running

The script is re-runnable. If rootfs is already on the device, it will ask whether to overwrite or skip. Use this to:
- Change WiFi credentials
- Reflash the kernel
- Reconfigure device services

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WIFI_COUNTRY` | `SI` | Country code for WiFi regulatory domain |

## Building the Kernel

### GitHub Actions (recommended)

Run **Build halium-boot.img** — select a kernel branch and optionally publish a release.

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
