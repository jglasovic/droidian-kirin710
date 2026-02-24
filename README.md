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
│   ├── build-halium.yml              # CI — builds halium-boot.img (kernel + initramfs)
│   └── build-rootfs.yml              # CI — downloads, patches and uploads rootfs.img
├── build-bootimg.sh                  # Download kernel + Halium initramfs, patch for Kirin 710, pack boot image
├── patch-rootfs.sh                   # Patch rootfs.img with Kirin 710 device config (ADB, vendor, WiFi init)
└── setup-device.sh                   # Post-flash WiFi credentials setup over ADB
```

## Related Repositories

| Repository | Description |
|------------|-------------|
| [android_kernel_huawei_kirin710](https://github.com/jglasovic/android_kernel_huawei_kirin710) | Kernel fork — patches, defconfigs, CI-built `Image.gz` |

## Building

### GitHub Actions (recommended)

1. Run **Build rootfs.img** — downloads and patches the Droidian rootfs (cached, only re-runs when upstream or patch changes).
2. Run **Build halium-boot.img** — select a kernel branch and optionally publish a release.
3. Download the artifacts: `halium-boot` and `rootfs`.

### Local Build

Requires an ARM64 machine (or [Colima](https://github.com/abiosoft/colima) with `colima start --arch aarch64 --memory 8`):

```bash
bash build-bootimg.sh
```

Set `KERNEL_BRANCH` to choose a kernel config (`headless-kirin710` default, or `full-ui-kirin710`).

Output: timestamped images in `out/` with a `halium-boot.img` symlink to the latest build.

## Flashing

Boot into fastboot: hold **Volume Down + Power** while connecting USB.

```bash
fastboot flash kernel halium-boot.img
```

On first boot the initramfs will start a telnet server over USB (no rootfs yet). Set up the USB network and push the rootfs:

```bash
# Set up USB network
# macOS:
sudo ifconfig en8 10.15.19.1 netmask 255.255.255.0 up
# Linux:
sudo ip addr add 10.15.19.1/24 dev usb0

# Push rootfs
scp rootfs.img root@10.15.19.82:/tmpmnt/

# Reboot
telnet 10.15.19.82
# then: reboot
```

First boot takes 1-2 minutes (rootfs resize). After that, ADB works automatically:

```bash
# Over USB:
adb shell

# Over WiFi (after setup):
adb connect <device-ip>:5555
```

## Post-Flash Setup

The rootfs comes pre-configured with ADB, vendor mount, and WiFi init. Connect via USB and run the setup script to add WiFi credentials:

```bash
bash setup-device.sh "YOUR_WIFI_SSID" "YOUR_WIFI_PASSWORD"
adb reboot
```

After reboot the device will auto-connect to WiFi.

## Links

- [Droidian](https://droidian.org/)
- [Halium](https://halium.org/)
- [Droidian images](https://github.com/droidian-images/droidian/releases)
