#!/usr/bin/env bash
# build-bootimg.sh — download Halium GSI, patch ramdisk, pack halium-boot.img
# Requires: kernel already built (kernel/arch/arm64/boot/Image.gz)
#
# Usage:
#   bash build-bootimg.sh
set -euo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WORK_DIR"

# UBports CI — Halium 13 generic arm64 GSI (system + ramdisk)
UBPORTS_GSI_URL="https://ci.ubports.com/job/UBportsCommunityPortsJenkinsCI/job/ubports%252Fporting%252Fcommunity-ports%252Fjenkins-ci%252Fgeneric_arm64/job/halium-13.0/836/artifact/halium_halium_arm64.tar.xz"

# Boot image parameters for Kirin 710 / SNE-LX1 (from BoardConfigCommon.mk)
BOARD_KERNEL_BASE="0x00078000"
BOARD_KERNEL_PAGESIZE="2048"
BOARD_KERNEL_OFFSET="0x00008000"
BOARD_RAMDISK_OFFSET="0x07b88000"
BOARD_TAGS_OFFSET="0x07988000"
BOARD_SECOND_OFFSET="0x00e88000"
BOARD_BOOTIMG_HEADER_VERSION="1"
BOARD_KERNEL_CMDLINE="loglevel=4 initcall_debug=n page_tracker=on unmovable_isolate1=2:192M,3:224M,4:256M printktimer=0xfff0a000,0x534,0x538 androidboot.init_fatal_reboot_target=recovery"

KERNEL_IMG="kernel/arch/arm64/boot/Image.gz"

# ── Check prerequisites ──────────────────────────────────────────────────────
if [ ! -f "$KERNEL_IMG" ]; then
  echo "[FAIL] Kernel not built. Run build-kernel.sh first."
  exit 1
fi

command -v mkbootimg >/dev/null 2>&1 || {
  echo "[FAIL] mkbootimg not found. Install: apt install android-tools-mkbootimg"
  exit 1
}

# ── Download Halium GSI ──────────────────────────────────────────────────────
if [ ! -f halium_arm64.tar.xz ]; then
  echo "[*] Downloading Halium GSI..."
  wget -q --show-progress "$UBPORTS_GSI_URL" -O halium_arm64.tar.xz
else
  echo "[*] Halium GSI archive already downloaded, skipping."
fi

# ── Extract system.img and ramdisk ───────────────────────────────────────────
echo "[*] Extracting GSI archive..."
mkdir -p gsi
tar -xJf halium_arm64.tar.xz -C gsi/

if [ -f gsi/system.img ]; then
  cp gsi/system.img system.img
elif [ -f gsi/android-rootfs.img ]; then
  cp gsi/android-rootfs.img system.img
else
  echo "[FAIL] No system.img or android-rootfs.img in archive"
  exit 1
fi
echo "[OK] system.img: $(du -sh system.img | cut -f1)"

# Find the ramdisk
if [ -f gsi/ramdisk.img ]; then
  cp gsi/ramdisk.img ramdisk-stock.img
elif [ -f gsi/boot.img ]; then
  echo "[*] Extracting ramdisk from boot.img..."
  mkdir -p bootimg_unpacked
  unpackbootimg -i gsi/boot.img -o bootimg_unpacked/
  cp bootimg_unpacked/*ramdisk* ramdisk-stock.img
else
  echo "[FAIL] No ramdisk.img or boot.img in archive"
  exit 1
fi
echo "[OK] ramdisk-stock.img: $(du -sh ramdisk-stock.img | cut -f1)"

# ── Patch ramdisk ────────────────────────────────────────────────────────────
# The Kirin 710 kernel has init=/init hardcoded in its built-in cmdline.
# /init points back to the initramfs, causing a boot loop.
# We patch the init script to override init=/init → /sbin/init (systemd).
echo "[*] Patching ramdisk..."
RAMDISK_WORK=$(mktemp -d)
trap 'rm -rf "$RAMDISK_WORK" gsi bootimg_unpacked' EXIT

cd "$RAMDISK_WORK"
gzip -dc "$WORK_DIR/ramdisk-stock.img" | cpio -id 2>/dev/null

# Patch: insert init=/init override after the cmdline parsing loop (after "esac" + "done")
# Find the line "done" that ends the cmdline parsing, then insert our override after it.
if ! grep -q "Override init.*Kirin" init 2>/dev/null; then
  sed -i '/^done$/,/^$/{
    /^$/a\
# Override init: the Kirin 710 kernel has init=/init built-in in its cmdline.\
# /init refers to the initramfs itself, NOT the Droidian rootfs init.\
# Always use /sbin/init (systemd) for the real rootfs.\
if [ "$init" = "/init" ] || [ -z "$init" ]; then\
\tinit=/sbin/init\
fi
    /^$/q
  }' init
  echo "[OK] Patched init: override init=/init → /sbin/init"
else
  echo "[OK] init already patched, skipping."
fi

# Repack ramdisk
find . | cpio -o -H newc 2>/dev/null | gzip > "$WORK_DIR/ramdisk.img"
cd "$WORK_DIR"
echo "[OK] ramdisk.img: $(du -sh ramdisk.img | cut -f1)"

# ── Build halium-boot.img ────────────────────────────────────────────────────
echo "[*] Building halium-boot.img..."
mkbootimg \
  --kernel  "$KERNEL_IMG" \
  --ramdisk ramdisk.img \
  --base            "$BOARD_KERNEL_BASE" \
  --pagesize        "$BOARD_KERNEL_PAGESIZE" \
  --kernel_offset   "$BOARD_KERNEL_OFFSET" \
  --ramdisk_offset  "$BOARD_RAMDISK_OFFSET" \
  --tags_offset     "$BOARD_TAGS_OFFSET" \
  --second_offset   "$BOARD_SECOND_OFFSET" \
  --header_version  "$BOARD_BOOTIMG_HEADER_VERSION" \
  --cmdline         "$BOARD_KERNEL_CMDLINE" \
  --output          halium-boot.img

echo ""
echo "[OK] halium-boot.img: $(du -sh halium-boot.img | cut -f1)"
echo "[OK] system.img:      $(du -sh system.img | cut -f1)"
echo ""
echo "Flash with:"
echo "  fastboot flash kernel halium-boot.img"
echo "  fastboot flash userdata system.img"
