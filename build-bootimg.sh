#!/usr/bin/env bash
# build-bootimg.sh — pack halium-boot.img from kernel + ramdisk
# Requires: kernel already built (kernel/arch/arm64/boot/Image.gz)
#
# If halium-initramfs/ doesn't exist, it will be automatically downloaded
# from the Halium initramfs-tools release and patched for Kirin 710.
#
# Usage:
#   bash build-bootimg.sh
set -euo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WORK_DIR"

# Pre-built Halium initramfs (from halium/initramfs-tools-halium)
HALIUM_INITRD_URL="https://github.com/Halium/initramfs-tools-halium/releases/download/continuous/initrd.img-touch-arm64"

# Boot image parameters for Kirin 710 / SNE-LX1 (from BoardConfigCommon.mk)
BOARD_KERNEL_BASE="0x00078000"
BOARD_KERNEL_PAGESIZE="2048"
BOARD_KERNEL_OFFSET="0x00008000"
BOARD_RAMDISK_OFFSET="0x07b88000"
BOARD_TAGS_OFFSET="0x07988000"
BOARD_SECOND_OFFSET="0x00e88000"
BOARD_BOOTIMG_HEADER_VERSION="1"
BOARD_KERNEL_CMDLINE="loglevel=4 initcall_debug=n page_tracker=on unmovable_isolate1=2:192M,3:224M,4:256M printktimer=0xfff0a000,0x534,0x538 androidboot.selinux=permissive buildvariant=user"

KERNEL_IMG="kernel/arch/arm64/boot/Image.gz"
INITRAMFS_DIR="halium-initramfs"

# ── Check prerequisites ──────────────────────────────────────────────────────
if [ ! -f "$KERNEL_IMG" ]; then
  echo "[FAIL] Kernel not built. Run build-kernel.sh first."
  exit 1
fi

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

command -v mkbootimg >/dev/null 2>&1 || {
  echo "[*] Installing mkbootimg..."
  $SUDO apt-get update -qq
  $SUDO apt-get install -y --no-install-recommends mkbootimg 2>&1 | tail -3
}

# Fix mkbootimg GKI import error on Ubuntu 24.04+ (we don't use GKI certificates)
if grep -q "^from gki" "$(which mkbootimg)" 2>/dev/null; then
  $SUDO sed -i 's/^from gki.generate_gki_certificate import generate_gki_certificate$/try:\n    from gki.generate_gki_certificate import generate_gki_certificate\nexcept ImportError:\n    generate_gki_certificate = None/' "$(which mkbootimg)"
fi

# ── Download Halium initramfs if needed ───────────────────────────────────────
if [ ! -d "$INITRAMFS_DIR" ] || [ ! -f "$INITRAMFS_DIR/init" ]; then
  echo "[*] halium-initramfs/ not found, downloading from Halium project..."

  wget -q --show-progress "$HALIUM_INITRD_URL" -O /tmp/initrd-halium.img

  mkdir -p "$INITRAMFS_DIR"
  cd "$INITRAMFS_DIR"
  gzip -dc /tmp/initrd-halium.img | cpio -id 2>/dev/null
  rm -f /tmp/initrd-halium.img
  cd "$WORK_DIR"

  echo "[OK] Extracted initramfs to ${INITRAMFS_DIR}/"
fi

# ── Patch initramfs for Kirin 710 / Droidian ─────────────────────────────────
if ! grep -q "switch_root" "$INITRAMFS_DIR/init" 2>/dev/null; then
  echo "[*] Applying Droidian + Kirin 710 patches to initramfs..."

  INIT="$INITRAMFS_DIR/init"
  HALIUM="$INITRAMFS_DIR/scripts/halium"

  # Patch 1: Kirin 710 init override
  # Patch 2+3: Replace run-init with switch_root (run-init fails on Kirin 710)
  python3 - "$INIT" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Patch 1: Insert init override after the cmdline parsing loop (esac\ndone)
# The kernel has init=/init hardcoded which loops back to initramfs.
init_override = '''
# Override init: the Kirin 710 kernel has init=/init built-in in its cmdline.
# /init refers to the initramfs itself, NOT the Droidian rootfs init.
# Always use /sbin/init (systemd) for the real rootfs.
if [ "$init" = "/init" ] || [ -z "$init" ]; then
\tinit=/sbin/init
fi'''
content = content.replace('\tesac\ndone\n', '\tesac\ndone\n' + init_override + '\n', 1)
print("  - init: added init=/sbin/init override after cmdline parsing")

# Replace validate_init() body
content = content.replace(
    '\trun-init -n "${rootmnt}" "${1}"',
    '\tchecktarget="${1}"\n'
    '\n'
    '\t# Work around absolute symlinks\n'
    '\tif [ -d "${rootmnt}" ] && [ -e "${rootmnt}${checktarget}" ]; then\n'
    '\t\treturn 0\n'
    '\tfi\n'
    '\n'
    '\treturn 1'
)

# Replace exec run-init with switch_root
content = content.replace(
    'exec run-init ${drop_caps} ${rootmnt} ${init} "$@" <${rootmnt}/dev/console >${rootmnt}/dev/console 2>&1',
    'exec switch_root ${rootmnt} ${init} "$@"\n'
    'echo "initrd: exec switch_root RETURNED - this is bad!" > /dev/kmsg 2>/dev/null || true'
)

with open(path, 'w') as f:
    f.write(content)
print("  - init: replaced run-init with switch_root")
PYEOF

  # Patch 4: Non-ext4 userdata support + additional fixes in halium script
  python3 - "$HALIUM" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

old_block = '''\ttell_kmsg "checking filesystem integrity for the userdata partition"
\t# Mounting and umounting first, let the kernel handle the journal and
\t# orphaned inodes (faster than e2fsck). Then, just run e2fsck forcing -y.
\t# Also check the amount of time used by to check the filesystem.
\tfsck_start=$(date +%s)
\tmount -o errors=remount-ro $path /tmpmnt
\tumount /tmpmnt
\te2fsck -y $path >/run/e2fsck.out 2>&1
\tfsck_end=$(date +%s)
\ttell_kmsg "checking filesystem for userdata took (including e2fsck) $((fsck_end - fsck_start)) seconds"

\tresize_userdata_if_needed ${path}

\ttell_kmsg "mounting $path"

\t# Mount the data partition to a temporary mount point
\t# FIXME: data=journal used on ext4 as a workaround for bug 1387214
\t[ `blkid $path -o value -s TYPE` = "ext4" ] && OPTIONS="data=journal,"
\tmount -o discard,$OPTIONS $path /tmpmnt'''

new_block = '''\ttell_kmsg "checking filesystem type for userdata partition"
\t_userdata_fs=$(blkid $path -o value -s TYPE 2>/dev/null || echo "unknown")
\ttell_kmsg "userdata filesystem type: $_userdata_fs"

\tif [ "$_userdata_fs" = "ext4" ]; then
\t\ttell_kmsg "running e2fsck on ext4 userdata"
\t\tfsck_start=$(date +%s)
\t\tmount -o errors=remount-ro $path /tmpmnt
\t\tumount /tmpmnt
\t\te2fsck -y $path >/run/e2fsck.out 2>&1
\t\tfsck_end=$(date +%s)
\t\ttell_kmsg "e2fsck took $((fsck_end - fsck_start)) seconds"
\t\tresize_userdata_if_needed ${path}
\t\tOPTIONS="data=journal,"
\t\tmount -o discard,$OPTIONS $path /tmpmnt
\telse
\t\ttell_kmsg "skipping e2fsck for non-ext4 ($userdata_fs) userdata, mounting directly"
\t\tmount -t $_userdata_fs $path /tmpmnt
\tfi'''

if old_block in content:
    content = content.replace(old_block, new_block)
    print("  - halium: added non-ext4 userdata support")
else:
    print("  - halium: WARNING - mount block not found, skipping")

# Patch 5: Add mountroot debug log after pre_mountroot
content = content.replace(
    '\tpre_mountroot\n\n\t[ "$quiet"',
    '\tpre_mountroot\n\ttell_kmsg "[HALIUM] mountroot started"\n\n\t[ "$quiet"'
)
print("  - halium: added mountroot started log")

# Patch 6: Remove stale comment before "Halium rootfs is" log
content = content.replace(
    '\t# If both $imagefile and $_syspart are set, something is wrong. The strange\n'
    '\t# output from this could be a clue in that situation.\n'
    '\ttell_kmsg "Halium rootfs is',
    '\ttell_kmsg "Halium rootfs is'
)
print("  - halium: removed stale comment")

# Patch 7: Fix trailing whitespace/blank lines
content = content.replace('\t\n\t# Identify image mode', '\n\t# Identify image mode')
content = content.replace('\t\tdone\n\n\telse', '\t\tdone\n\telse')

with open(path, 'w') as f:
    f.write(content)
PYEOF

  # Ensure switch_root exists (busybox provides it, just needs a symlink)
  if [ ! -e "$INITRAMFS_DIR/bin/switch_root" ] && [ -e "$INITRAMFS_DIR/bin/busybox" ]; then
    ln -s busybox "$INITRAMFS_DIR/bin/switch_root"
    echo "  - added switch_root -> busybox symlink"
  fi

  echo "[OK] All patches applied."
else
  echo "[OK] initramfs already patched."
fi

# ── Pack ramdisk ─────────────────────────────────────────────────────────────
echo "[*] Packing ramdisk from ${INITRAMFS_DIR}/..."
cd "$INITRAMFS_DIR"
find . | sort | cpio -o -H newc -R 0:0 2>/dev/null | gzip > "$WORK_DIR/ramdisk.img"
cd "$WORK_DIR"
echo "[OK] ramdisk.img: $(du -sh ramdisk.img | cut -f1)"

# ── Build halium-boot.img ────────────────────────────────────────────────────
BUILD_TAG="$(date +%Y%m%d-%H%M%S)"
mkdir -p out

echo "[*] Building halium-boot-${BUILD_TAG}.img..."
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
  --output          "out/halium-boot-${BUILD_TAG}.img"

# Symlink latest build for convenience
ln -sf "out/halium-boot-${BUILD_TAG}.img" halium-boot.img

echo ""
echo "[OK] out/halium-boot-${BUILD_TAG}.img ($(du -sh "out/halium-boot-${BUILD_TAG}.img" | cut -f1))"
echo "[OK] halium-boot.img -> out/halium-boot-${BUILD_TAG}.img"
echo ""
echo "Flash with:"
echo "  fastboot flash kernel halium-boot.img"
