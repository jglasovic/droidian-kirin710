# Droidian for Huawei Mate 20 Lite (SNE-LX1) — Kirin 710

Build system and CI for the Droidian/Halium port on the Huawei Mate 20 Lite (codename **sydney**, SoC **HiSilicon Kirin 710**).

This is the **first Droidian port for any Kirin device**.

## Status

| Feature | Status |
|---------|--------|
| Boot to Droidian | Working |
| ADB over USB | Working |
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
│   ├── build-halium.yml              # CI — builds boot image, patches and uploads rootfs
│   └── update-upstream-images.yml    # Mirror upstream rootfs.zip to a pinned release
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

1. Run the **Update upstream images** workflow once to mirror `rootfs.zip` to the `upstream-images` release.
2. Run the **Build Halium** workflow — select a kernel branch and optionally publish a release.
3. Download the 2 artifacts: `halium-boot` and `rootfs`.

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
fastboot reboot
```

On first boot the initramfs will start a telnet server over USB (no rootfs yet). Push the rootfs via ADB or telnet:

```bash
adb push rootfs.img /tmpmnt/
adb reboot
```

First boot takes 1-2 minutes (rootfs resize). After that, ADB over USB works automatically:

```bash
adb shell
```

## Post-Flash Setup

The rootfs comes pre-configured with ADB, vendor mount, and WiFi init. Run the setup script to add WiFi credentials:

```bash
bash setup-device.sh "YOUR_WIFI_SSID" "YOUR_WIFI_PASSWORD"
```

Reboot the device (`adb reboot`). After reboot it will auto-connect to WiFi.

## Links

- [Droidian](https://droidian.org/)
- [Halium](https://halium.org/)
- [Droidian images](https://github.com/droidian-images/droidian/releases)
