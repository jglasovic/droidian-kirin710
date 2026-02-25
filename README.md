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

### Interactive flow

The script prompts for each step before doing anything:

```
=== Droidian Setup for Kirin 710 (SNE-LX1) ===

Checking: adb fastboot curl ... OK
Waiting for ADB device...

Push rootfs to device? [Y/n]:
Enable USB SSH (NCM at 10.15.19.82)? [Y/n]:
Enable WiFi? [y/N]:
  WiFi SSID: MyNetwork
  WiFi password: ****
Mount vendor partition? [y/N]:
Flash kernel? [Y/n]:
  Kernel variant:
    1) headless (SSH-only, no display)
    2) full-ui  (Phosh desktop)
  Choose [1]:

=== Plan ===
  Push rootfs:    yes
  USB SSH:        yes (10.15.19.82)
  WiFi:           MyNetwork
  Vendor mount:   yes (via WiFi)
  Flash kernel:   headless-kirin710
Proceed? [Y/n]:
```

Only selected steps are executed. Kernel variant determines which boot image to download.

### After setup

```bash
# SSH over USB
ssh droidian@10.15.19.82

# Default password: 1234
```

### Re-running

The script is re-runnable. Select only the steps you want to repeat:
- Change WiFi credentials
- Reflash a different kernel variant
- Reconfigure device services

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WIFI_COUNTRY` | `SI` | Country code for WiFi regulatory domain |

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
