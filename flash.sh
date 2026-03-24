#!/usr/bin/env bash
# flash.sh — download and flash Droidian kernel + recovery for Kirin 710 (SNE-LX1)
#
# Usage:
#   bash flash.sh
#
# Downloads halium-boot.img and recovery.img from CI/releases,
# then flashes them via fastboot.
set -euo pipefail

REPO="jglasovic/droidian-kirin710"
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WORK_DIR"

die() { echo "[FAIL] $*"; exit 1; }

# ── Dependency check ──────────────────────────────────────────────────────────
printf "Checking:"
for cmd in fastboot curl; do
    command -v "$cmd" &>/dev/null || die "'$cmd' not found."
    printf " %s" "$cmd"
done
echo " ... OK"

# ── Choose kernel variant ─────────────────────────────────────────────────────
echo ""
echo "Kernel variant:"
echo "  1) headless (SSH-only, no display)"
echo "  2) full-ui  (Phosh desktop)"
printf "Choose [1]: "
read -r kv_input < /dev/tty
case "${kv_input:-1}" in
    2) KERNEL_VARIANT="full-ui-kirin710" ;;
    *) KERNEL_VARIANT="headless-kirin710" ;;
esac

BOOT_IMG="halium-boot-${KERNEL_VARIANT}.img"

# ── Download boot image ───────────────────────────────────────────────────────
if [ -f "$BOOT_IMG" ]; then
    echo "[OK] $BOOT_IMG already present ($(du -sh "$BOOT_IMG" | cut -f1)) — skipping download."
else
    echo "[*] Downloading $BOOT_IMG..."
    DOWNLOADED=false

    # Tier 1: GitHub releases
    if [ "$DOWNLOADED" = false ]; then
        RELEASE_URL=$(curl -sf "https://api.github.com/repos/${REPO}/releases" \
            | python3 -c "
import sys, json
variant = '${KERNEL_VARIANT}'
for r in json.load(sys.stdin):
    for a in r.get('assets', []):
        name = a['name']
        if variant in name and name.endswith('.img'):
            print(a['browser_download_url']); sys.exit(0)
        if name == 'halium-boot.img':
            print(a['browser_download_url']); sys.exit(0)
sys.exit(1)
" 2>/dev/null) && {
            curl -fSL --retry 3 -o "$BOOT_IMG" "$RELEASE_URL"
            DOWNLOADED=true
        } || true
    fi

    # Tier 2: CI artifacts via gh
    if [ "$DOWNLOADED" = false ] && command -v gh &>/dev/null; then
        RUN_ID=$(gh run list -R "$REPO" -w "Build halium-boot.img" -s completed -L 1 \
            --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
        if [ -n "$RUN_ID" ]; then
            if gh run download "$RUN_ID" -R "$REPO" -n "halium-boot-${KERNEL_VARIANT}" -D . 2>/dev/null; then
                [ -f "halium-boot.img" ] && [ ! -f "$BOOT_IMG" ] && mv "halium-boot.img" "$BOOT_IMG"
                [ -f "$BOOT_IMG" ] && DOWNLOADED=true
            fi
        fi
    fi

    [ "$DOWNLOADED" = false ] && die "Could not download $BOOT_IMG.
       Build locally: colima ssh -- bash build-bootimg.sh
       Or install 'gh' CLI and authenticate: brew install gh && gh auth login"

    echo "[OK] $BOOT_IMG ($(du -sh "$BOOT_IMG" | cut -f1))"
fi

# ── Download recovery image ───────────────────────────────────────────────────
if [ -f "recovery.img" ]; then
    echo "[OK] recovery.img already present ($(du -sh recovery.img | cut -f1)) — skipping download."
else
    echo "[*] Downloading recovery.img..."
    RECOVERY_DOWNLOADED=false

    # Tier 1: GitHub releases
    RECOVERY_URL=$(curl -sf "https://api.github.com/repos/${REPO}/releases" \
        | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    for a in r.get('assets', []):
        if a['name'] == 'recovery.img':
            print(a['browser_download_url']); sys.exit(0)
sys.exit(1)
" 2>/dev/null) && {
        curl -fSL --retry 3 -o recovery.img "$RECOVERY_URL"
        RECOVERY_DOWNLOADED=true
    } || true

    # Tier 2: CI artifacts via gh
    if [ "$RECOVERY_DOWNLOADED" = false ] && command -v gh &>/dev/null; then
        RUN_ID=$(gh run list -R "$REPO" -w "Build halium-boot.img" -s completed -L 1 \
            --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
        if [ -n "$RUN_ID" ]; then
            gh run download "$RUN_ID" -R "$REPO" -n "recovery" -D . 2>/dev/null && \
                [ -f "recovery.img" ] && RECOVERY_DOWNLOADED=true || true
        fi
    fi

    [ "$RECOVERY_DOWNLOADED" = false ] && die "Could not download recovery.img."
    echo "[OK] recovery.img ($(du -sh recovery.img | cut -f1))"
fi

# ── Flash via fastboot ────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Put the device into fastboot (bootloader) mode:"
echo "  1. Power off the device"
echo "  2. Hold Volume Down + Power until the bootloader screen appears"
echo "  3. Connect USB cable to this computer"
echo "================================================================"
echo ""
echo "[*] Waiting for fastboot device..."
fastboot wait-for-device

echo "[*] Flashing kernel and recovery..."
fastboot flash kernel "$BOOT_IMG"
fastboot flash recovery_ramdisk recovery.img
echo "[OK] Flashed successfully."

echo ""
echo "================================================================"
echo "  To enter recovery for device setup:"
echo "  1. Reboot the device (fastboot reboot, or hold Power)"
echo "  2. While it boots, hold Volume Up + Power"
echo "  3. Connect USB cable — then run: bash setup-device.sh"
echo "================================================================"
echo ""
fastboot reboot
