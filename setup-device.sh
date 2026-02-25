#!/usr/bin/env bash
# setup-device.sh — all-in-one setup for Droidian on Kirin 710 (SNE-LX1)
#
# Downloads boot image + rootfs, pushes to device, configures WiFi + services,
# flashes kernel. Device must be in recovery with ADB enabled.
#
# Re-runnable: skip rootfs push to just reconfigure WiFi or reflash kernel.
#
# Usage:
#   bash setup-device.sh
#
# Requires: adb, fastboot, curl on the host.
# Optional: gh (GitHub CLI) for downloading CI artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REPO="jglasovic/droidian-kirin710"
ROOTFS_REPO="droidian-images/droidian"
BOOT_IMG="halium-boot.img"
ROOTFS_IMG="rootfs.img"

# ── Check dependencies ───────────────────────────────────────────────────────
for cmd in adb fastboot curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[FAIL] '$cmd' not found. Install it and try again."
        exit 1
    fi
done

# ── 1. Download halium-boot.img ──────────────────────────────────────────────
if [ -f "$BOOT_IMG" ]; then
    echo "[OK] $BOOT_IMG already present ($(du -sh "$BOOT_IMG" | cut -f1)) — skipping download."
    echo "     Delete it to re-download."
else
    echo "[*] Downloading $BOOT_IMG..."
    DOWNLOADED=false

    # Try GitHub releases first (no auth needed)
    RELEASE_URL=$(curl -sf "https://api.github.com/repos/${REPO}/releases" \
        | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    for a in r.get('assets', []):
        if a['name'] == 'halium-boot.img':
            print(a['browser_download_url'])
            sys.exit(0)
sys.exit(1)
" 2>/dev/null) && {
        echo "    Found in GitHub releases."
        curl -fSL --retry 3 -o "$BOOT_IMG" "$RELEASE_URL"
        DOWNLOADED=true
    } || true

    # Fall back to CI artifacts via gh CLI
    if [ "$DOWNLOADED" = false ]; then
        if ! command -v gh &>/dev/null; then
            echo "[FAIL] No release found and 'gh' CLI not installed."
            echo "       Install gh (brew install gh) or download $BOOT_IMG manually from:"
            echo "       https://github.com/$REPO/actions"
            exit 1
        fi
        echo "    No release found, downloading from latest CI artifact..."
        RUN_ID=$(gh run list -R "$REPO" -w "Build halium-boot.img" -s completed -L 1 --json databaseId -q '.[0].databaseId')
        if [ -z "$RUN_ID" ]; then
            echo "[FAIL] No completed CI runs found."
            exit 1
        fi
        gh run download "$RUN_ID" -R "$REPO" -n halium-boot -D .
    fi

    if [ ! -f "$BOOT_IMG" ]; then
        echo "[FAIL] Download succeeded but $BOOT_IMG not found."
        exit 1
    fi
    echo "[OK] Downloaded $BOOT_IMG ($(du -sh "$BOOT_IMG" | cut -f1))"
fi

# ── 2. Download rootfs.img from Droidian releases ───────────────────────────
if [ -f "$ROOTFS_IMG" ]; then
    echo "[OK] $ROOTFS_IMG already present ($(du -sh "$ROOTFS_IMG" | cut -f1)) — skipping download."
    echo "     Delete it to re-download."
else
    echo "[*] Finding latest Droidian rootfs release..."
    ROOTFS_URL=$(curl -sf "https://api.github.com/repos/${ROOTFS_REPO}/releases/latest" \
        | python3 -c "import sys,json; assets=json.load(sys.stdin)['assets']; print(next(a['browser_download_url'] for a in assets if 'rootfs-api33-arm64' in a['name'] and a['name'].endswith('.zip')))")
    echo "[*] Downloading rootfs..."
    echo "    $ROOTFS_URL"
    curl -fSL --retry 3 -o rootfs.zip "$ROOTFS_URL"
    echo "[*] Extracting rootfs.img..."
    unzip -o rootfs.zip "data/rootfs.img" -d .
    mv data/rootfs.img "$ROOTFS_IMG"
    rm -rf data rootfs.zip
    echo "[OK] $ROOTFS_IMG ($(du -sh "$ROOTFS_IMG" | cut -f1))"
fi

# ── 3. Push rootfs to device ────────────────────────────────────────────────
echo ""
echo "[*] Waiting for ADB device (boot to recovery with ADB enabled)..."
adb wait-for-device

PUSH_ROOTFS=true
if adb shell "[ -f /tmpmnt/rootfs.img ]" 2>/dev/null; then
    echo "    rootfs.img already on device."
    read -rp "    Overwrite? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        PUSH_ROOTFS=false
        echo "    Skipping rootfs push."
    fi
fi

if [ "$PUSH_ROOTFS" = true ]; then
    echo "[*] Pushing rootfs.img to device (this takes a few minutes)..."
    adb push "$ROOTFS_IMG" /tmpmnt/rootfs.img
    echo "[OK] rootfs.img pushed."
fi

# ── 4. WiFi credentials ─────────────────────────────────────────────────────
echo ""
read -rp "[?] WiFi SSID: " WIFI_SSID
read -rsp "[?] WiFi password: " WIFI_PASS
echo ""

if [ -z "$WIFI_SSID" ] || [ -z "$WIFI_PASS" ]; then
    echo "[FAIL] WiFi SSID and password are required."
    exit 1
fi

WIFI_COUNTRY="${WIFI_COUNTRY:-SI}"
TMPCONF=$(mktemp)
cat > "$TMPCONF" << EOF
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
p2p_disabled=1
country=${WIFI_COUNTRY}

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PASS}"
}
EOF

# ── 5. Configure device ─────────────────────────────────────────────────────
echo "[*] Pushing config files to device..."
adb push "$TMPCONF" /tmp/wpa_supplicant.conf
rm -f "$TMPCONF"
adb push "$SCRIPT_DIR/device-config.sh" /tmp/device-config.sh

echo "[*] Running device configuration..."
adb shell sh /tmp/device-config.sh

# ── 6. Flash kernel ─────────────────────────────────────────────────────────
echo "[*] Rebooting to fastboot..."
adb reboot bootloader

echo "[*] Waiting for fastboot device..."
fastboot wait-for-device 2>/dev/null || sleep 10

echo "[*] Flashing $BOOT_IMG..."
fastboot flash kernel "$BOOT_IMG"

echo ""
echo "=== Setup complete ==="
echo "Device will boot with:"
echo "  SSH over USB:  ssh droidian@10.15.19.82"
echo "  WiFi:          $WIFI_SSID"
echo "  Default password: 1234"
