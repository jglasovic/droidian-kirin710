#!/usr/bin/env bash
# setup-device.sh — interactive setup for Droidian on Kirin 710 (SNE-LX1)
#
# Works both from a cloned repo and directly from curl:
#   bash <(curl -sL https://raw.githubusercontent.com/jglasovic/droidian-kirin710/main/setup-device.sh)
#
# Prompts for each step upfront, shows a summary, then executes only selected steps.
# Requires: adb, fastboot, curl on the host.
# Optional: gh (GitHub CLI) for downloading CI artifacts.
set -euo pipefail

REPO="jglasovic/droidian-kirin710"
ROOTFS_REPO="droidian-images/droidian"
DEVTOOLS_REPO="droidian-images/droidian"
DROIDIAN_PKG_BASE="http://releases.droidian.org/snapshots/current"
ROOTFS_IMG="rootfs.img"
DEVTOOLS_PAYLOAD="devtools-payload.tar"
EXTRAS_LOCAL="sideload-extras"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"

# ── Working directory ────────────────────────────────────────────────────────
# When running from curl, BASH_SOURCE[0] won't be a real file — use a temp dir.
if [ -f "${BASH_SOURCE[0]:-}" ]; then
    WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    FROM_CURL=false
else
    WORK_DIR="$(mktemp -d)"
    FROM_CURL=true
    echo "(Running from curl — using temp dir: $WORK_DIR)"
fi
cd "$WORK_DIR"

# ── Helpers ──────────────────────────────────────────────────────────────────
# All reads go through /dev/tty so curl|bash works
ask() {
    local prompt="$1" default="$2" var="$3"
    local input
    if [ "$default" = "Y" ]; then
        printf "%s [Y/n]: " "$prompt" > /dev/tty
    else
        printf "%s [y/N]: " "$prompt" > /dev/tty
    fi
    read -r input < /dev/tty
    input="${input:-$default}"
    case "$input" in
        [Yy]*) eval "$var=yes" ;;
        *)     eval "$var=no" ;;
    esac
}

ask_text() {
    local prompt="$1" var="$2"
    printf "%s " "$prompt" > /dev/tty
    read -r input < /dev/tty
    eval "$var=\"\$input\""
}

ask_secret() {
    local prompt="$1" var="$2"
    printf "%s " "$prompt" > /dev/tty
    read -rs input < /dev/tty
    echo > /dev/tty
    eval "$var=\"\$input\""
}

die() { echo "[FAIL] $*"; exit 1; }

# ── Connection helpers (ADB or telnet fallback) ──────────────────────────────
CONN_MODE="adb"          # set by detect_connection()
TELNET_IP="10.15.19.82"
TELNET_PORT="23"
CMD_PORT="9999"          # nc command server port (clean scripted access)
NC_PORT="9998"           # netcat port for file transfers

# Run a shell command on the device
device_shell() {
    if [ "$CONN_MODE" = "adb" ]; then
        adb shell "$@"
    else
        # Port 9999: nc -e /bin/sh — clean I/O, no telnet noise
        printf '%s\nexit\n' "$*" | nc "$TELNET_IP" "$CMD_PORT"
    fi
}

# Push a local file to the device
device_push() {
    local src="$1" dst="$2"
    if [ "$CONN_MODE" = "adb" ]; then
        adb push "$src" "$dst"
    else
        local dir
        dir=$(dirname "$dst")
        # Ensure destination directory exists
        device_shell "mkdir -p '$dir'" >/dev/null 2>&1
        # Start nc listener on device via command server
        printf 'nc -l -p %s > %s\n' "$NC_PORT" "$dst" | nc "$TELNET_IP" "$CMD_PORT" >/dev/null &
        local BG=$!
        sleep 2  # give device nc time to start listening
        # Transfer file (macOS nc closes when stdin hits EOF)
        nc "$TELNET_IP" "$NC_PORT" < "$src"
        sleep 1
        kill "$BG" 2>/dev/null || true
        wait "$BG" 2>/dev/null || true
        echo "[OK] Pushed $(basename "$src") -> $dst"
    fi
}

# Push a directory (all files within it)
device_push_dir() {
    local src_dir="$1" dst_dir="$2"
    if [ "$CONN_MODE" = "adb" ]; then
        adb push "$src_dir"/. "$dst_dir/"
    else
        for f in "$src_dir"/*; do
            [ -f "$f" ] || continue
            device_push "$f" "$dst_dir/$(basename "$f")"
        done
    fi
}

# Reboot the device
device_reboot() {
    local mode="${1:-}"
    if [ "$CONN_MODE" = "adb" ]; then
        if [ "$mode" = "bootloader" ]; then
            adb reboot-bootloader
        else
            adb reboot
        fi
    else
        if [ "$mode" = "bootloader" ]; then
            device_shell "reboot bootloader" >/dev/null 2>&1 || true
        else
            device_shell "reboot" >/dev/null 2>&1 || true
        fi
    fi
}

# ── Banner + dependency check ────────────────────────────────────────────────
echo ""
echo "=== Droidian Setup for Kirin 710 (SNE-LX1) ==="
echo ""

printf "Checking:"
for cmd in adb fastboot curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo ""
        die "'$cmd' not found. Install it and try again."
    fi
    printf " %s" "$cmd"
done
echo " ... OK"

# ── Wait for device (ADB with telnet fallback) ───────────────────────────────
echo ""
echo "Waiting for device — ADB (5s) then nc fallback at $TELNET_IP:$CMD_PORT..."
ADB_DEADLINE=$(($(date +%s) + 5))
CONN_MODE=""
while [ -z "$CONN_MODE" ]; do
    if adb devices 2>/dev/null | grep -qE '\t(device|recovery)$'; then
        CONN_MODE="adb"
    elif [ "$(date +%s)" -gt "$ADB_DEADLINE" ]; then
        if nc -z -w2 "$TELNET_IP" "$CMD_PORT" 2>/dev/null; then
            CONN_MODE="nc"
        fi
    fi
    [ -z "$CONN_MODE" ] && sleep 1
done
echo "Device connected via $CONN_MODE."
echo ""

# ── Gather choices ───────────────────────────────────────────────────────────
DO_ROOTFS=""
DO_USB=""
DO_WIFI=""
DO_WIFI_FIXMAC=""
DO_VENDOR=""
DO_KERNEL=""
WIFI_SSID=""
WIFI_PASS=""
KERNEL_VARIANT=""

ask "Push rootfs to device?" "Y" DO_ROOTFS
ask "Enable USB SSH (NCM at 10.15.19.82)?" "Y" DO_USB

ask "Enable WiFi?" "N" DO_WIFI
if [ "$DO_WIFI" = "yes" ]; then
    ask_text "  WiFi SSID:" WIFI_SSID
    ask_secret "  WiFi password:" WIFI_PASS
    if [ -z "$WIFI_SSID" ] || [ -z "$WIFI_PASS" ]; then
        die "WiFi SSID and password are required when WiFi is enabled."
    fi
    ask "  Lock WiFi MAC address (use first-boot MAC permanently)?" "N" DO_WIFI_FIXMAC
    # WiFi auto-includes vendor mount
    DO_VENDOR="yes"
else
    ask "Mount vendor partition?" "N" DO_VENDOR
fi

ask "Flash kernel?" "Y" DO_KERNEL
if [ "$DO_KERNEL" = "yes" ]; then
    echo "  Kernel variant:" > /dev/tty
    echo "    1) headless (SSH-only, no display)" > /dev/tty
    echo "    2) full-ui  (Phosh desktop)" > /dev/tty
    printf "  Choose [1]: " > /dev/tty
    read -r kv_input < /dev/tty
    case "${kv_input:-1}" in
        2) KERNEL_VARIANT="full-ui-kirin710" ;;
        *) KERNEL_VARIANT="headless-kirin710" ;;
    esac
fi

# ── Summary ──────────────────────────────────────────────────────────────────
BOOT_IMG="halium-boot-${KERNEL_VARIANT}.img"

echo ""
echo "=== Plan ==="
printf "  Push rootfs:    %s\n" "$DO_ROOTFS"
if [ "$DO_USB" = "yes" ]; then
    printf "  USB SSH:        yes (10.15.19.82)\n"
else
    printf "  USB SSH:        no\n"
fi
if [ "$DO_WIFI" = "yes" ]; then
    printf "  WiFi:           %s\n" "$WIFI_SSID"
    printf "  Lock MAC:       %s\n" "$DO_WIFI_FIXMAC"
    printf "  Vendor mount:   yes (via WiFi)\n"
else
    printf "  WiFi:           no\n"
    printf "  Vendor mount:   %s\n" "$DO_VENDOR"
fi
if [ "$DO_KERNEL" = "yes" ]; then
    printf "  Flash kernel:   %s\n" "$KERNEL_VARIANT"
else
    printf "  Flash kernel:   no\n"
fi
echo ""
ask "Proceed?" "Y" CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi
echo ""

# ── Download rootfs ──────────────────────────────────────────────────────────
if [ "$DO_ROOTFS" = "yes" ]; then
    if [ -f "$ROOTFS_IMG" ]; then
        echo "[OK] $ROOTFS_IMG already present ($(du -sh "$ROOTFS_IMG" | cut -f1)) — skipping download."
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
fi

# ── Download devtools bundle ──────────────────────────────────────────────────
# Droidian snapshot images need the devtools bundle for SSH, adbd, etc.
if [ "$DO_ROOTFS" = "yes" ]; then
    if [ -f "$DEVTOOLS_PAYLOAD" ]; then
        echo "[OK] $DEVTOOLS_PAYLOAD already present — skipping download."
    else
        echo "[*] Finding latest Droidian devtools bundle..."
        DEVTOOLS_URL=$(curl -sf "https://api.github.com/repos/${DEVTOOLS_REPO}/releases/latest" \
            | python3 -c "import sys,json; assets=json.load(sys.stdin)['assets']; print(next(a['browser_download_url'] for a in assets if 'devtools-api33-arm64' in a['name'] and a['name'].endswith('.zip')))")
        echo "[*] Downloading devtools bundle..."
        echo "    $DEVTOOLS_URL"
        curl -fSL --retry 3 -o devtools.zip "$DEVTOOLS_URL"
        echo "[*] Extracting payload.tar..."
        unzip -o devtools.zip "payload.tar" -d .
        mv payload.tar "$DEVTOOLS_PAYLOAD"
        rm -f devtools.zip
        echo "[OK] $DEVTOOLS_PAYLOAD ($(du -sh "$DEVTOOLS_PAYLOAD" | cut -f1))"
    fi

    # Download extra packages (adbd, dhcpcd) — pushed to device later as raw debs
    if [ -d "$EXTRAS_LOCAL" ] && [ "$(ls "$EXTRAS_LOCAL"/*.deb 2>/dev/null | wc -l)" -gt 0 ]; then
        echo "[OK] $EXTRAS_LOCAL/ already has debs — skipping download."
    else
        echo "[*] Downloading extra packages (adbd, dhcpcd)..."
        mkdir -p "$EXTRAS_LOCAL"

        echo "[*] Fetching package index..."
        PKGINDEX=$(mktemp)
        curl -sfL "${DROIDIAN_PKG_BASE}/dists/rolling/main/binary-arm64/Packages.gz" | gunzip > "$PKGINDEX"

        for pkg in adbd android-liblog android-libbase android-libboringssl android-libcutils dhcpcd-base; do
            STANZA=$(awk "/^Package: ${pkg}\$/,/^\$/" "$PKGINDEX")
            FILE=$(echo "$STANZA" | grep '^Filename:' | head -1 | awk '{print $2}')
            VERSION=$(echo "$STANZA" | grep '^Version:' | head -1 | awk '{print $2}')
            ARCH=$(echo "$STANZA" | grep '^Architecture:' | head -1 | awk '{print $2}')
            if [ -n "$FILE" ]; then
                # apt cache expects epoch colon encoded as %3a in filenames
                CACHE_VER=$(echo "$VERSION" | sed 's/:/%3a/g')
                DEB_NAME="${pkg}_${CACHE_VER}_${ARCH:-arm64}.deb"
                echo "    $pkg ($VERSION)"
                curl -fSL --retry 3 -o "$EXTRAS_LOCAL/$DEB_NAME" "${DROIDIAN_PKG_BASE}/${FILE}"
            else
                echo "    WARNING: $pkg not found in repo"
            fi
        done
        rm -f "$PKGINDEX"
        echo "[OK] Downloaded $(ls "$EXTRAS_LOCAL"/*.deb 2>/dev/null | wc -l | tr -d ' ') debs"
    fi
fi

# ── Download boot image (multi-tier) ────────────────────────────────────────
if [ "$DO_KERNEL" = "yes" ]; then
    if [ -f "$BOOT_IMG" ]; then
        echo "[OK] $BOOT_IMG already present ($(du -sh "$BOOT_IMG" | cut -f1)) — skipping download."
    else
        echo "[*] Downloading $BOOT_IMG..."
        DOWNLOADED=false

        # Tier 1: Check for local halium-boot.img (generic name)
        if [ "$DOWNLOADED" = false ] && [ -f "halium-boot.img" ]; then
            echo "    Found local halium-boot.img, using as $BOOT_IMG."
            cp "halium-boot.img" "$BOOT_IMG"
            DOWNLOADED=true
        fi

        # Tier 2: GitHub releases — find asset matching variant name
        if [ "$DOWNLOADED" = false ]; then
            RELEASE_URL=$(curl -sf "https://api.github.com/repos/${REPO}/releases" \
                | python3 -c "
import sys, json
variant = '${KERNEL_VARIANT}'
for r in json.load(sys.stdin):
    for a in r.get('assets', []):
        name = a['name']
        if variant in name and name.endswith('.img'):
            print(a['browser_download_url'])
            sys.exit(0)
        if name == 'halium-boot.img':
            print(a['browser_download_url'])
            sys.exit(0)
sys.exit(1)
" 2>/dev/null) && {
                echo "    Found in GitHub releases."
                curl -fSL --retry 3 -o "$BOOT_IMG" "$RELEASE_URL"
                DOWNLOADED=true
            } || true
        fi

        # Tier 3: CI artifacts via gh — variant-named artifact
        if [ "$DOWNLOADED" = false ] && command -v gh &>/dev/null; then
            echo "    Trying CI artifact: halium-boot-${KERNEL_VARIANT}..."
            RUN_ID=$(gh run list -R "$REPO" -w "Build halium-boot.img" -s completed -L 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
            if [ -n "$RUN_ID" ]; then
                if gh run download "$RUN_ID" -R "$REPO" -n "halium-boot-${KERNEL_VARIANT}" -D . 2>/dev/null; then
                    # Artifact may contain halium-boot.img inside
                    if [ -f "halium-boot.img" ] && [ ! -f "$BOOT_IMG" ]; then
                        mv "halium-boot.img" "$BOOT_IMG"
                    fi
                    [ -f "$BOOT_IMG" ] && DOWNLOADED=true
                fi
            fi
        fi

        # Tier 4: CI artifacts via gh — generic artifact name (warn)
        if [ "$DOWNLOADED" = false ] && command -v gh &>/dev/null; then
            echo "    Trying CI artifact: halium-boot (generic)..."
            RUN_ID=$(gh run list -R "$REPO" -w "Build halium-boot.img" -s completed -L 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
            if [ -n "$RUN_ID" ]; then
                if gh run download "$RUN_ID" -R "$REPO" -n "halium-boot" -D . 2>/dev/null; then
                    if [ -f "halium-boot.img" ]; then
                        echo "    WARNING: Downloaded generic halium-boot.img — may not match variant '$KERNEL_VARIANT'."
                        mv "halium-boot.img" "$BOOT_IMG"
                        DOWNLOADED=true
                    fi
                fi
            fi
        fi

        # Tier 5: Fail
        if [ "$DOWNLOADED" = false ]; then
            die "Could not download $BOOT_IMG.
       Options:
         - Place $BOOT_IMG (or halium-boot.img) in the working directory
         - Create a GitHub release with the boot image
         - Install 'gh' CLI and authenticate (brew install gh && gh auth login)
         - Download manually from: https://github.com/$REPO/actions"
        fi

        echo "[OK] $BOOT_IMG ($(du -sh "$BOOT_IMG" | cut -f1))"
    fi
fi

# ── Mount userdata on device ──────────────────────────────────────────────────
echo "[*] Mounting userdata partition on device..."
device_shell "mkdir -p /tmpmnt && mount /dev/block/by-name/userdata /tmpmnt 2>/dev/null || mount /dev/mmcblk0p70 /tmpmnt 2>/dev/null || true"

if [ "$DO_ROOTFS" = "yes" ]; then
    PUSH=true
    if device_shell "[ -f /tmpmnt/rootfs.img ]" 2>/dev/null; then
        echo "    rootfs.img already on device."
        ask "    Overwrite?" "N" OVERWRITE
        if [ "$OVERWRITE" = "yes" ]; then
            echo "[*] Wiping userdata partition..."
            device_shell "rm -rf /tmpmnt/*"
            echo "[OK] Userdata wiped."
        else
            PUSH=false
            echo "    Skipping rootfs push."
        fi
    fi

    if [ "$PUSH" = true ]; then
        echo "[*] Pushing rootfs.img to device (this takes a few minutes)..."
        device_push "$ROOTFS_IMG" /tmpmnt/rootfs.img
        echo "[OK] rootfs.img pushed."
    fi

    # Expand rootfs on device to use most of userdata (~56GB)
    # Stock rootfs.img is ~3.9GB and nearly full. The img is a fixed-size ext4
    # filesystem — usable space inside Droidian is limited to the image size.
    # Recovery has mkfs.ext4 but no resize2fs, so we create a new larger image
    # and copy the contents over.
    echo "[*] Expanding rootfs to 56GB on device (this takes a minute)..."
    device_shell "
        CURRENT=\$(stat -c%s /tmpmnt/rootfs.img 2>/dev/null || echo 0)
        TARGET=60129542144  # 56GB
        if [ \"\$CURRENT\" -lt \"\$TARGET\" ]; then
            truncate -s 56G /tmpmnt/rootfs-new.img
            mkfs.ext4 -q /tmpmnt/rootfs-new.img
            mkdir -p /mnt-old /mnt-new
            mount -o loop /tmpmnt/rootfs.img /mnt-old
            mount -o loop /tmpmnt/rootfs-new.img /mnt-new
            cp -a /mnt-old/. /mnt-new/
            umount /mnt-old
            umount /mnt-new
            mv /tmpmnt/rootfs-new.img /tmpmnt/rootfs.img
            rmdir /mnt-old /mnt-new 2>/dev/null || true
            sync
            echo 'expanded to 56GB'
        else
            echo 'already 56GB+'
        fi
    "

    # Push sideload payloads into rootfs (installed on first boot)
    device_shell "mount -o loop /tmpmnt/rootfs.img /mnt"
    if [ -f "$DEVTOOLS_PAYLOAD" ]; then
        echo "[*] Installing devtools bundle (SSH, git, strace, etc.)..."
        device_push "$DEVTOOLS_PAYLOAD" /tmp/devtools-payload.tar
        device_shell "cd /mnt && tar -oxf /tmp/devtools-payload.tar; ln -sf /var/cache/package-sideload system-update"
    fi
    if [ -d "$EXTRAS_LOCAL" ] && [ "$(ls "$EXTRAS_LOCAL"/*.deb 2>/dev/null | wc -l)" -gt 0 ]; then
        echo "[*] Installing extras (adbd, dhcpcd)..."
        device_shell "mkdir -p /tmp/extras"
        device_push_dir "$EXTRAS_LOCAL" /tmp/extras
        device_shell "
            BUNDLE=/mnt/var/cache/package-sideload/bundles/kirin710-extras
            mkdir -p \$BUNDLE/archives
            mv /tmp/extras/*.deb \$BUNDLE/archives/
            printf 'adbd\ndhcpcd-base\n' > \$BUNDLE/packages
            rm -rf /tmp/extras
        "
    fi
    device_shell "umount /mnt && sync"
    echo "[OK] Sideload bundles staged for first-boot install."
fi

# ── Build flags for device-config.sh ─────────────────────────────────────────
FLAGS=""
[ "$DO_USB" = "yes" ] && FLAGS="$FLAGS usb"
[ "$DO_WIFI" = "yes" ] && FLAGS="$FLAGS wifi"
[ "$DO_WIFI_FIXMAC" = "yes" ] && FLAGS="$FLAGS fixmac"
[ "$DO_VENDOR" = "yes" ] && [ "$DO_WIFI" != "yes" ] && FLAGS="$FLAGS vendor"
[ "$KERNEL_VARIANT" = "headless-kirin710" ] && FLAGS="$FLAGS headless"
FLAGS="${FLAGS# }"  # trim leading space

# ── Push WiFi credentials if needed ─────────────────────────────────────────
if [ "$DO_WIFI" = "yes" ]; then
    WIFI_COUNTRY="${WIFI_COUNTRY:-SI}"
    TMPCONF=$(mktemp)
    # Generate hashed PSK (WPA2 PSK = PBKDF2-SHA1 with SSID as salt, 4096 iterations, 32 bytes)
    HASHED_PSK=$(openssl kdf -keylen 32 -kdfopt digest:SHA1 -kdfopt pass:"$WIFI_PASS" -kdfopt salt:"$WIFI_SSID" -kdfopt iter:4096 PBKDF2 2>/dev/null | tr -d ':' | tr 'A-F' 'a-f' || true)
    if [ -z "$HASHED_PSK" ] || [ ${#HASHED_PSK} -ne 64 ]; then
        echo "    WARNING: PSK hashing failed, falling back to plaintext"
        PSK_LINE="    psk=\"${WIFI_PASS}\""
    else
        PSK_LINE="    psk=${HASHED_PSK}"
    fi
    cat > "$TMPCONF" << EOF
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
p2p_disabled=1
country=${WIFI_COUNTRY}

network={
    ssid="${WIFI_SSID}"
${PSK_LINE}
}
EOF
    device_push "$TMPCONF" /tmp/wpa_supplicant.conf
    rm -f "$TMPCONF"
fi

# ── Configure device ─────────────────────────────────────────────────────────
if [ -n "$FLAGS" ]; then
    echo "[*] Configuring device (flags: $FLAGS)..."

    # Get device-config.sh — local or remote
    if [ "$FROM_CURL" = true ] || [ ! -f "device-config.sh" ]; then
        echo "    Fetching device-config.sh from GitHub..."
        curl -sfL "${RAW_BASE}/device-config.sh" -o "$WORK_DIR/device-config.sh"
    fi

    device_push "$WORK_DIR/device-config.sh" /tmp/device-config.sh
    device_shell "sh /tmp/device-config.sh '$FLAGS'"
else
    echo "[*] No device configuration selected — skipping."
fi

# ── Flash kernel ─────────────────────────────────────────────────────────────
if [ "$DO_KERNEL" = "yes" ]; then
    echo "[*] Rebooting to fastboot..."
    sleep 10
    device_reboot bootloader

    echo "[*] Waiting for fastboot device..."
    fastboot wait-for-device 2>/dev/null || sleep 10

    echo "[*] Flashing $BOOT_IMG and recovery..."
    fastboot flash kernel "$BOOT_IMG"
    fastboot flash recovery_ramdisk recovery.img
    IN_FASTBOOT=true
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== Setup complete ==="
if [ "$DO_USB" = "yes" ]; then
    echo ""
    echo "  USB SSH:  ssh droidian@10.15.19.82"
    echo "  USB ADB:  adb connect 10.15.19.82:5555"
    echo ""
    echo "  NOTE: You must set the host IP on the USB NCM interface first:"
    echo "    sudo ifconfig en11 10.15.19.1 netmask 255.255.255.0   (macOS)"
    echo "    sudo ip addr add 10.15.19.1/24 dev usb0               (Linux)"
fi
if [ "$DO_WIFI" = "yes" ]; then
    echo ""
    echo "  WiFi:     $WIFI_SSID (IP assigned via DHCP)"
fi
if [ "$DO_KERNEL" = "yes" ]; then
    echo "  Kernel:   $KERNEL_VARIANT"
fi
echo ""
echo "  User:     droidian"
echo "  Password: 1234"
echo ""
echo "  The device will reboot twice: first boot installs sideloaded"
echo "  packages, second boot is ready to use."

# Reboot device if any changes were made
DID_CHANGE=false
[ "$DO_ROOTFS" = "yes" ] && DID_CHANGE=true
[ -n "$FLAGS" ] && DID_CHANGE=true
[ "$DO_KERNEL" = "yes" ] && DID_CHANGE=true

if [ "$DID_CHANGE" = true ]; then
    echo ""
    echo "[*] Rebooting device..."
    if [ "${IN_FASTBOOT:-false}" = true ]; then
        fastboot reboot
    else
        device_reboot
    fi
fi

# Clean up temp dir if running from curl
if [ "$FROM_CURL" = true ]; then
    rm -rf "$WORK_DIR"
fi
