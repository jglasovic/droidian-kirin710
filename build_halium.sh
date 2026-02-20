#!/usr/bin/env bash
# build_halium.sh
# Sets up Halium build environment and builds halium-boot + system image
# for Huawei Mate 20 Lite SNE-LX1 (codename: sydney, Kirin 710 / hi3670) targeting Droidian
#
# REQUIREMENTS:
#   - Ubuntu 20.04 or 22.04 (x86_64) - mandatory, AOSP build system requires it
#   - At least 16 GB RAM (32 GB recommended)
#   - At least 200 GB free disk space
#   - Run as a normal user (NOT root)
#
# REPOS FOUND (SNE-LX1 / sydney / Kirin 710):
#
#   KERNEL (choose one):
#     Primary:   https://github.com/Huawei-Dev/android_kernel_huawei_kirin710  branch: android@13
#                (EMUI 9.1 base, 4.9.x — used by the LOS20 maintainer directly)
#     Secondary: https://github.com/Iceows/android_kernel_huawei_kirin710-9   branch: lineage-20
#     With KSU:  https://github.com/Coconutat/android_kernel_huawei_kirin710_KSU
#     Newer 4.14:https://github.com/ViP3R-KERNELs/kernel_huawei_kirin710      (EMUI12/stock base)
#
#   DEVICE TREE:
#     No public sydney-specific tree exists. Use harry (Honor 10i / HRY-LX1)
#     as the base — same Kirin 710 SoC and very similar hardware:
#     https://github.com/Iceows/android_device_huawei_harry                   branch: lineage-20
#     Common base it inherits from:
#     https://github.com/Iceows/android_device_huawei_kirin710-9-common       branch: lineage-20
#     Compat layer:
#     https://github.com/Huawei-Dev/android_device_huawei_compat
#
#   VENDOR BLOBS:
#     https://github.com/Iceows/android_vendor_huawei_kirin710-9-common       branch: lineage-20
#     (Extract your own from the device using harry's extract-files.sh, or use this as base)
#
# WORKFLOW:
#   1. Run collect_device_info.sh on your SNE-LX1
#   2. Fork android_device_huawei_harry and adapt it for sydney (rename product,
#      adjust partition layout from device_info/partitions/by_name_all.txt, etc.)
#   3. Apply Halium patches to your kernel fork
#   4. Run this script

set -e

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
# Edit these to point to your forks after adapting harry → sydney

DEVICE_CODENAME="sydney"              # ro.product.device  (sydney for SNE-LX1)
DEVICE_MANUFACTURER="huawei"
HALIUM_VERSION="13"                   # LOS20 = Android 13 = halium-13.0
BUILD_DIR="$HOME/halium"

# Kernel: fork Huawei-Dev/android_kernel_huawei_kirin710, apply halium patches
KERNEL_REPO="https://github.com/Huawei-Dev/android_kernel_huawei_kirin710"
KERNEL_BRANCH="android@13"           # upstream branch; create halium branch from this

# Device tree: fork Iceows/android_device_huawei_harry, adapt for sydney
DEVICE_TREE_REPO="https://github.com/Iceows/android_device_huawei_harry"
DEVICE_TREE_BRANCH="lineage-20"

# Common device tree (harry inherits from this, sync it too)
COMMON_TREE_REPO="https://github.com/Iceows/android_device_huawei_kirin710-9-common"
COMMON_TREE_BRANCH="lineage-20"

# Compat layer
COMPAT_REPO="https://github.com/Huawei-Dev/android_device_huawei_compat"
COMPAT_BRANCH="main"

# Vendor blobs
VENDOR_REPO="https://github.com/Iceows/android_vendor_huawei_kirin710-9-common"
VENDOR_BRANCH="lineage-20"

# Number of parallel jobs
JOBS=$(nproc)

# ─── END CONFIGURATION ────────────────────────────────────────────────────────

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
info()    { echo -e "${GREEN}[*]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
require() { command -v "$1" &>/dev/null || error "Required tool '$1' not found."; }

check_config() {
    if [ -z "$KERNEL_REPO" ] || [ -z "$DEVICE_TREE_REPO" ] || [ -z "$VENDOR_REPO" ]; then
        error "KERNEL_REPO, DEVICE_TREE_REPO, and VENDOR_REPO must be set in the configuration section."
    fi
    if [ "$EUID" -eq 0 ]; then
        error "Do NOT run as root."
    fi
    if [[ "$(uname -m)" != "x86_64" ]]; then
        error "Must run on x86_64. Android build system does not support other architectures."
    fi
}

install_deps() {
    info "Installing build dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y \
        git-core gnupg flex bison gperf build-essential \
        zip curl zlib1g-dev libc6-dev-i386 \
        libncurses5-dev x11proto-core-dev libx11-dev \
        lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip \
        python3 python3-pip python-is-python3 \
        openjdk-11-jdk \
        ccache rsync lzop bc libssl-dev \
        repo \
        adb fastboot \
        android-sdk-libsparse-utils \
        simg2img img2simg \
        device-tree-compiler \
        schedtool patchelf \
        libncurses5 xmlstarlet

    # repo tool (official Google version, more reliable than distro package)
    mkdir -p ~/bin
    if ! command -v repo &>/dev/null || [[ "$(repo --version 2>&1 | head -1)" != *"repo launcher"* ]]; then
        curl -s https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
        chmod a+x ~/bin/repo
        export PATH="$HOME/bin:$PATH"
    fi

    # magiskboot for boot image manipulation
    if ! command -v magiskboot &>/dev/null; then
        warn "magiskboot not found. Attempting to install from Magisk release..."
        MAGISK_URL="https://github.com/topjohnwu/Magisk/releases/latest/download/Magisk.apk"
        curl -L -o /tmp/Magisk.apk "$MAGISK_URL" 2>/dev/null && \
        unzip -p /tmp/Magisk.apk lib/x86_64/libmagiskboot.so > ~/bin/magiskboot && \
        chmod +x ~/bin/magiskboot || \
        warn "Could not install magiskboot automatically. Download it manually if needed."
    fi

    info "Dependencies installed."
}

setup_ccache() {
    info "Configuring ccache..."
    ccache --max-size=50G
    export USE_CCACHE=1
    export CCACHE_EXEC=$(which ccache)
    echo 'export USE_CCACHE=1' >> ~/.bashrc
    echo "export CCACHE_EXEC=$(which ccache)" >> ~/.bashrc
}

init_halium_source() {
    info "Initializing Halium $HALIUM_VERSION source..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    if [ ! -d ".repo" ]; then
        repo init \
            -u https://github.com/Halium/android \
            -b "halium-${HALIUM_VERSION}.0" \
            --depth=1 \
            --no-clone-bundle
    fi

    # Create local manifest for device-specific repos
    mkdir -p .repo/local_manifests
    cat > .repo/local_manifests/device.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="local-device" fetch="." />

  <project
    path="kernel/${DEVICE_MANUFACTURER}/${DEVICE_CODENAME}"
    name="${KERNEL_REPO}"
    remote="local-device"
    revision="${KERNEL_BRANCH}" />

  <project
    path="device/${DEVICE_MANUFACTURER}/${DEVICE_CODENAME}"
    name="${DEVICE_TREE_REPO}"
    remote="local-device"
    revision="${DEVICE_TREE_BRANCH}" />

  <project
    path="vendor/${DEVICE_MANUFACTURER}/${DEVICE_CODENAME}"
    name="${VENDOR_REPO}"
    remote="local-device"
    revision="${VENDOR_BRANCH}" />
</manifest>
EOF

    # Replace placeholder with actual remote (repo URLs)
    python3 - <<'PYEOF'
import xml.etree.ElementTree as ET, os, sys

manifest_path = ".repo/local_manifests/device.xml"
tree = ET.parse(manifest_path)
root = tree.getroot()

kernel_repo = os.environ.get("KERNEL_REPO", "")
device_repo = os.environ.get("DEVICE_TREE_REPO", "")
vendor_repo = os.environ.get("VENDOR_REPO", "")

def is_url(s):
    return s.startswith("http://") or s.startswith("https://") or s.startswith("git@")

if is_url(kernel_repo) and is_url(device_repo) and is_url(vendor_repo):
    # Remove placeholder remote, set fetch per project
    for r in root.findall("remote"):
        root.remove(r)
    for proj in root.findall("project"):
        name = proj.get("name")
        proj.set("name", name.split("/")[-2] + "/" + name.split("/")[-1] if "/" in name else name)
        proj.attrib.pop("remote", None)
    # Just write the urls directly as 'name' with a real remote is complex in repo
    # Instead, emit warning - user should configure manifest properly
    print("NOTE: Using git URLs directly in manifest - ensure remote fetch base is correct.")

tree.write(manifest_path)
PYEOF

    info "Syncing Halium source (this downloads ~15-20 GB, be patient)..."
    repo sync \
        -j"$JOBS" \
        -c \
        --no-clone-bundle \
        --no-tags \
        --optimized-fetch \
        --retry-fetches=3
}

apply_halium_kernel_patches() {
    KERNEL_DIR="$BUILD_DIR/kernel/${DEVICE_MANUFACTURER}/${DEVICE_CODENAME}"
    info "Checking kernel for required Halium config options..."

    if [ ! -d "$KERNEL_DIR" ]; then
        warn "Kernel directory not found: $KERNEL_DIR"
        return
    fi

    # Required kernel config for Halium/Droidian (systemd + containers + LXC)
    REQUIRED_CONFIGS=(
        # Halium/Android base
        "CONFIG_DEVTMPFS=y"
        "CONFIG_CGROUPS=y"
        "CONFIG_CGROUP_DEVICE=y"
        "CONFIG_CGROUP_MEM_RES_CTLR=y"
        "CONFIG_MEMCG=y"
        "CONFIG_NAMESPACES=y"
        "CONFIG_NET_NS=y"
        "CONFIG_PID_NS=y"
        "CONFIG_IPC_NS=y"
        "CONFIG_UTS_NS=y"
        "CONFIG_USER_NS=y"
        "CONFIG_ANDROID_BINDERFS=y"
        "CONFIG_ANDROID_BINDER_IPC=y"
        # systemd requirements
        "CONFIG_TMPFS_XATTR=y"
        "CONFIG_SECCOMP=y"
        "CONFIG_SECCOMP_FILTER=y"
        "CONFIG_PSI=y"
        # Networking
        "CONFIG_TUN=y"
        "CONFIG_VETH=y"
        "CONFIG_BRIDGE=y"
        "CONFIG_NETFILTER=y"
        "CONFIG_IP_NF_IPTABLES=y"
        "CONFIG_IP_NF_FILTER=y"
        "CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y"
        # SSH / crypto
        "CONFIG_CRYPTO_AES=y"
        "CONFIG_CRYPTO_CBC=y"
        "CONFIG_CRYPTO_HMAC=y"
        "CONFIG_CRYPTO_SHA256=y"
        # LXC/containers for Droidian
        "CONFIG_CGROUP_FREEZER=y"
        "CONFIG_CPUSETS=y"
        "CONFIG_CGROUP_CPUACCT=y"
        # Overlay filesystem (for rootfs)
        "CONFIG_OVERLAY_FS=y"
        # ext4 / f2fs for data partition
        "CONFIG_EXT4_FS=y"
        "CONFIG_F2FS_FS=y"
        # VirtIO (optional but useful)
        # USB networking
        "CONFIG_USB_NET_RNDIS_WLAN=m"
        "CONFIG_USB_ETH=m"
    )

    MISSING_CONFIGS=()
    KCONFIG="$KERNEL_DIR/arch/arm64/configs/kirin710_defconfig"
    [ ! -f "$KCONFIG" ] && KCONFIG=$(find "$KERNEL_DIR/arch/arm64/configs/" -name "*defconfig" | head -1)

    if [ -f "$KCONFIG" ]; then
        info "Checking defconfig: $KCONFIG"
        for cfg in "${REQUIRED_CONFIGS[@]}"; do
            key=$(echo "$cfg" | cut -d= -f1)
            if ! grep -q "^$key=" "$KCONFIG" && ! grep -q "^# $key is not set" "$KCONFIG"; then
                MISSING_CONFIGS+=("$cfg")
            fi
        done

        if [ ${#MISSING_CONFIGS[@]} -gt 0 ]; then
            warn "Missing kernel configs (add to defconfig):"
            for cfg in "${MISSING_CONFIGS[@]}"; do
                echo "    $cfg"
            done
            echo ""
            warn "Appending missing configs to $KCONFIG"
            echo "" >> "$KCONFIG"
            echo "# Halium/Droidian additions" >> "$KCONFIG"
            for cfg in "${MISSING_CONFIGS[@]}"; do
                echo "$cfg" >> "$KCONFIG"
            done
        else
            info "All required kernel configs present."
        fi
    else
        warn "Could not find kernel defconfig. Check kernel directory structure."
    fi
}

build_halium() {
    info "Setting up build environment..."
    cd "$BUILD_DIR"

    # Source the envsetup
    # shellcheck disable=SC1091
    source build/envsetup.sh

    # breakfast configures the build for the target device
    breakfast "${DEVICE_CODENAME}"

    info "Building halium-boot.img..."
    mka halium-boot 2>&1 | tee "$BUILD_DIR/build_haliumboot.log"

    info "Building system image..."
    mka systemimage 2>&1 | tee "$BUILD_DIR/build_systemimage.log"
}

package_for_droidian() {
    info "Packaging outputs for Droidian..."
    mkdir -p "$BUILD_DIR/droidian_out"

    HALIUM_BOOT="$BUILD_DIR/out/target/product/${DEVICE_CODENAME}/halium-boot.img"
    SYSTEM_IMG="$BUILD_DIR/out/target/product/${DEVICE_CODENAME}/system.img"

    [ -f "$HALIUM_BOOT" ] && cp "$HALIUM_BOOT" "$BUILD_DIR/droidian_out/"
    [ -f "$SYSTEM_IMG" ]  && cp "$SYSTEM_IMG"  "$BUILD_DIR/droidian_out/"

    # Convert system.img to sparse if needed
    if command -v img2simg &>/dev/null && [ -f "$BUILD_DIR/droidian_out/system.img" ]; then
        img2simg "$BUILD_DIR/droidian_out/system.img" \
                 "$BUILD_DIR/droidian_out/system_sparse.img" 2>/dev/null || true
    fi

    echo ""
    echo "=========================================="
    echo " Build artifacts in: $BUILD_DIR/droidian_out/"
    echo "=========================================="
    ls -lh "$BUILD_DIR/droidian_out/" 2>/dev/null || true
    echo ""
    echo "Flashing to device:"
    echo "  fastboot flash boot   droidian_out/halium-boot.img"
    echo "  fastboot flash system droidian_out/system.img"
    echo ""
    echo "Then install Droidian rootfs:"
    echo "  1. Download droidian rootfs from https://github.com/droidian/droidian/releases"
    echo "     - Look for: droidian-RELEASE-phosh-phone-<arch>.zip"
    echo "     - Or the rootfs tarball for your architecture (arm64)"
    echo "  2. Flash via TWRP or extract to userdata partition"
    echo ""
    echo "SSH will be available on:"
    echo "  USB: ssh user@10.15.19.82 (default Droidian USB IP)"
    echo "  WiFi: check device IP after boot (HiSilicon Hi1103 firmware needed)"
    echo ""
    echo "Kirin 710 / Hi3670 known issues:"
    echo "  - WiFi firmware: copy from LineageOS vendor to /lib/firmware/hisilicon/"
    echo "  - Display: may need panel driver patches for DRM/KMS"
    echo "  - Modem: baseband blobs required from vendor partition"
}

print_prereqs() {
    echo ""
    echo "=========================================="
    echo " Pre-flight checklist"
    echo "=========================================="
    echo ""
    echo "Before running this script:"
    echo ""
    echo "  [ ] Ran collect_device_info.sh and reviewed output"
    echo "  [ ] Set DEVICE_CODENAME in this script (check device_info/key_props.txt)"
    echo "  [ ] Set KERNEL_REPO to your Halium-patched kernel repo"
    echo "  [ ] Set DEVICE_TREE_REPO to LineageOS device tree (needs halium patches):"
    echo "        - Remove PRODUCT_USE_DYNAMIC_PARTITIONS if present"
    echo "        - Add lineage.mk / halium.mk includes"
    echo "        - BoardConfig.mk: set TARGET_KERNEL_SOURCE, TARGET_KERNEL_CONFIG"
    echo "  [ ] Set VENDOR_REPO with blobs (extract via extract-files.sh from LOS)"
    echo "  [ ] Running on Ubuntu 20.04 or 22.04 x86_64"
    echo "  [ ] At least 200 GB free disk space"
    echo ""
    echo "Halium device tree patch requirements:"
    echo "  - https://github.com/Halium/halium-boot (add to PRODUCT_PACKAGES)"
    echo "  - Remove conflicting recovery entries"
    echo "  - Ensure BOARD_KERNEL_CMDLINE has: androidboot.halium=1"
    echo ""
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    deps)
        check_config
        install_deps
        setup_ccache
        ;;
    sync)
        check_config
        init_halium_source
        ;;
    kernel-check)
        apply_halium_kernel_patches
        ;;
    build)
        check_config
        apply_halium_kernel_patches
        build_halium
        package_for_droidian
        ;;
    all)
        check_config
        install_deps
        setup_ccache
        init_halium_source
        apply_halium_kernel_patches
        build_halium
        package_for_droidian
        ;;
    help|"")
        print_prereqs
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  deps         Install build dependencies (run first)"
        echo "  sync         Download Halium source and device repos"
        echo "  kernel-check Check and patch kernel defconfig for Halium"
        echo "  build        Build halium-boot.img and system.img"
        echo "  all          Run all steps in sequence"
        echo "  help         Show this message"
        ;;
    *)
        error "Unknown command: $1. Run '$0 help'"
        ;;
esac
