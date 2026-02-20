#!/usr/bin/env bash
# extract-vendor-sydney.sh
# Pull ODM blobs from a connected SNE-LX1 device (via ADB root) and generate
# the vendor/huawei/sydney directory tree that the Halium build system expects.
#
# Usage:
#   ./extract-vendor-sydney.sh [<out-dir>]   (default: vendor/huawei/sydney)
#
# Requirements:
#   adb in PATH, device connected and root accessible (Magisk su)

set -uo pipefail

DEVICE=sydney
VENDOR=huawei
OUT_DIR="${1:-vendor/huawei/sydney}"
TMP_ARCHIVE="/data/local/tmp/_odm_extract.tar.gz"
LOCAL_TMP="$(mktemp -d)"
trap 'rm -rf "$LOCAL_TMP"' EXIT

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# ── ADB sanity ────────────────────────────────────────────────────────────────
adb_check() {
    adb get-state &>/dev/null || die "No ADB device. Connect the phone."
    local uid
    uid=$(adb shell "su -c 'id -u'" </dev/null 2>/dev/null | tr -d '\r')
    [ "$uid" = "0" ] || die "Root not available. Ensure Magisk su is working."
    ok "ADB root confirmed"
}

# ── Binary-safe partition pull using tar ──────────────────────────────────────
pull_partition_tar() {
    local part_root="$1"    # e.g. /odm
    local part_name="$2"    # e.g. odm

    info "Archiving $part_root on device ..."
    # Create tar on device (suppress owner warnings), then pull
    adb shell "su -c 'tar -czf \"$TMP_ARCHIVE\" \"$part_root\" --exclude=\"$part_root/lost+found\" 2>/dev/null; echo \$?'" </dev/null | tr -d '\r'
    local rc
    rc=$(adb shell "[ -f \"$TMP_ARCHIVE\" ] && echo ok || echo fail" </dev/null | tr -d '\r')
    [ "$rc" = "ok" ] || die "tar creation failed on device"

    info "Pulling archive from device ..."
    adb pull "$TMP_ARCHIVE" "${LOCAL_TMP}/${part_name}.tar.gz" </dev/null 2>/dev/null
    adb shell "rm -f \"$TMP_ARCHIVE\"" </dev/null 2>/dev/null || true

    local size
    size=$(wc -c < "${LOCAL_TMP}/${part_name}.tar.gz")
    ok "Archive size: $(( size / 1024 / 1024 )) MB"

    info "Extracting archive ..."
    mkdir -p "${LOCAL_TMP}/${part_name}"
    tar -xzf "${LOCAL_TMP}/${part_name}.tar.gz" -C "${LOCAL_TMP}/${part_name}" 2>/dev/null || \
        tar -xf  "${LOCAL_TMP}/${part_name}.tar.gz" -C "${LOCAL_TMP}/${part_name}" 2>/dev/null || \
        die "tar extraction failed"

    local extracted_root="${LOCAL_TMP}/${part_name}${part_root}"
    [ -d "$extracted_root" ] || die "Expected $extracted_root after extraction"

    # Copy to vendor output tree
    local dest="${OUT_DIR}/proprietary/${part_name}"
    mkdir -p "$dest"
    cp -r "${extracted_root}/." "$dest/"
    # Remove selinux precompiled policies (host-arch incompatible, regenerated at build)
    rm -f "$dest/etc/selinux/precompiled_sepolicy"

    local n
    n=$(find "$dest" -type f | wc -l | tr -d ' ')
    ok "Extracted $n files to ${dest}/"
}

# ── Generate proprietary-files.txt ────────────────────────────────────────────
gen_proprietary_files_txt() {
    local pf="${OUT_DIR}/proprietary-files.txt"
    cat > "$pf" << HDR
#
# Vendor Blobs for sydney (SNE-LX1) - ODM partition
# Extracted from SNE-LX1 (HYJNW18A27001862) / Android 13 / kernel 4.9.337
# $(date +%Y-%m-%d)
#

HDR

    # Audio - SNE-specific tuning
    echo "# Audio" >> "$pf"
    find "${OUT_DIR}/proprietary/odm/etc/audio" -type f 2>/dev/null \
        | sed "s|${OUT_DIR}/proprietary/||" | sort >> "$pf"
    echo "" >> "$pf"

    # Camera configs
    echo "# Camera Configs" >> "$pf"
    find "${OUT_DIR}/proprietary/odm/etc/camera" -type f 2>/dev/null \
        | sed "s|${OUT_DIR}/proprietary/||" | sort >> "$pf"
    echo "" >> "$pf"

    # NFC
    echo "# NFC" >> "$pf"
    find "${OUT_DIR}/proprietary/odm/etc" -maxdepth 2 -name "*nfc*" -o -name "*nci*" 2>/dev/null \
        | sed "s|${OUT_DIR}/proprietary/||" | sort >> "$pf"
    echo "" >> "$pf"

    # VINTF manifests
    echo "# VINTF Manifests" >> "$pf"
    find "${OUT_DIR}/proprietary/odm/etc/vintf" -type f 2>/dev/null \
        | sed "s|${OUT_DIR}/proprietary/||" | sort >> "$pf"
    echo "" >> "$pf"

    # SWS (speaker protection)
    echo "# SWS Speaker Configs" >> "$pf"
    find "${OUT_DIR}/proprietary/odm/etc/sws" -type f 2>/dev/null \
        | sed "s|${OUT_DIR}/proprietary/||" | sort >> "$pf"
    echo "" >> "$pf"

    # Modem carrier configs (ncfg_def)
    echo "# Modem Carrier Configs" >> "$pf"
    find "${OUT_DIR}/proprietary/odm/etc/ncfg_def" -type f 2>/dev/null \
        | sed "s|${OUT_DIR}/proprietary/||" | sort >> "$pf"
    echo "" >> "$pf"

    # Dataservice certificates
    echo "# Dataservice CA certs" >> "$pf"
    find "${OUT_DIR}/proprietary/odm/etc/dataservice" -type f 2>/dev/null \
        | sed "s|${OUT_DIR}/proprietary/||" | sort >> "$pf"
    echo "" >> "$pf"

    # Camera HAL .so files (SNE-specific)
    echo "# Camera HAL Libraries (SNE)" >> "$pf"
    find "${OUT_DIR}/proprietary/odm/lib64/hwcam" -name "*.so" 2>/dev/null \
        | sed "s|${OUT_DIR}/proprietary/||" | sort >> "$pf"
    echo "" >> "$pf"

    # ODM shared libraries
    echo "# ODM Shared Libraries" >> "$pf"
    find "${OUT_DIR}/proprietary/odm/lib64" -maxdepth 1 -name "*.so" 2>/dev/null \
        | sed "s|${OUT_DIR}/proprietary/||" | sort >> "$pf"
    echo "" >> "$pf"

    # phone.prop
    if [ -f "${OUT_DIR}/proprietary/odm/phone.prop" ]; then
        echo "# ODM phone.prop" >> "$pf"
        echo "odm/phone.prop" >> "$pf"
        echo "" >> "$pf"
    fi

    ok "proprietary-files.txt written ($pf)"
}

# ── Generate Android.bp ───────────────────────────────────────────────────────
gen_android_bp() {
    cat > "${OUT_DIR}/Android.bp" << 'EOF'
soong_namespace {
}
EOF
}

# ── Generate Android.mk ───────────────────────────────────────────────────────
gen_android_mk() {
    cat > "${OUT_DIR}/Android.mk" << 'ANDROIDMK'
LOCAL_PATH := $(call my-dir)

ifeq ($(TARGET_DEVICE),sydney)
include $(call all-makefiles-under,$(LOCAL_PATH))
endif
ANDROIDMK
}

# ── Generate BoardConfigVendor.mk ─────────────────────────────────────────────
gen_boardconfig_vendor() {
    cat > "${OUT_DIR}/BoardConfigVendor.mk" << 'EOF'
# Vendor BoardConfig for sydney (SNE-LX1)
# Included automatically by device/huawei/sydney/BoardConfig.mk
# (add device-specific board flags here if needed)
EOF
}

# ── Generate sydney-vendor.mk ─────────────────────────────────────────────────
gen_vendor_mk() {
    local pf="${OUT_DIR}/proprietary-files.txt"

    {
        echo "# Auto-generated vendor makefile for sydney (SNE-LX1)"
        echo "# $(date +%Y-%m-%d)"
        echo ""
        echo "PRODUCT_SOONG_NAMESPACES += vendor/${VENDOR}/${DEVICE}"
        echo ""
        echo "PRODUCT_COPY_FILES += \\"
    } > "${OUT_DIR}/sydney-vendor.mk"

    local lines=()
    while IFS= read -r entry; do
        [[ "$entry" == \#* ]] && continue
        [[ -z "$entry" ]] && continue
        [[ "$entry" == *.so ]] && continue  # .so handled via PRODUCT_PACKAGES

        local dest
        if [[ "$entry" == odm/* ]]; then
            dest="\$(TARGET_COPY_OUT_ODM)/${entry#odm/}"
        else
            dest="\$(TARGET_COPY_OUT_VENDOR)/${entry#vendor/}"
        fi
        lines+=("    \$(LOCAL_PATH)/proprietary/${entry}:${dest}")
    done < "$pf"

    local i
    for (( i=0; i<${#lines[@]}; i++ )); do
        if (( i < ${#lines[@]} - 1 )); then
            echo "${lines[$i]} \\" >> "${OUT_DIR}/sydney-vendor.mk"
        else
            echo "${lines[$i]}" >> "${OUT_DIR}/sydney-vendor.mk"
        fi
    done

    # PRODUCT_PACKAGES for .so prebuilts
    local pkgs=()
    while IFS= read -r entry; do
        [[ "$entry" == \#* ]] && continue
        [[ -z "$entry" ]] && continue
        [[ "$entry" == *.so ]] || continue
        pkgs+=("$(basename "$entry" .so)")
    done < "$pf"

    if [ ${#pkgs[@]} -gt 0 ]; then
        echo "" >> "${OUT_DIR}/sydney-vendor.mk"
        echo "PRODUCT_PACKAGES += \\" >> "${OUT_DIR}/sydney-vendor.mk"
        for (( i=0; i<${#pkgs[@]}; i++ )); do
            if (( i < ${#pkgs[@]} - 1 )); then
                echo "    ${pkgs[$i]} \\" >> "${OUT_DIR}/sydney-vendor.mk"
            else
                echo "    ${pkgs[$i]}" >> "${OUT_DIR}/sydney-vendor.mk"
            fi
        done
    fi

    ok "sydney-vendor.mk written"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    adb_check

    # Clean up any stale archive on device
    adb shell "rm -f \"$TMP_ARCHIVE\"" </dev/null 2>/dev/null || true

    mkdir -p "${OUT_DIR}/proprietary"

    # Pull ODM partition (binary-safe via tar)
    pull_partition_tar "/odm" "odm"

    # Generate file listings and makefiles
    info "Generating makefiles ..."
    gen_proprietary_files_txt
    gen_android_bp
    gen_android_mk
    gen_boardconfig_vendor
    gen_vendor_mk

    echo ""
    ok "=== Extraction complete ==="
    local total
    total=$(find "${OUT_DIR}/proprietary" -type f | wc -l | tr -d ' ')
    info "Total files in ${OUT_DIR}/proprietary/: $total"
    info ""
    info "Next steps:"
    info "  1. git init ${OUT_DIR}/ and push to GitHub as android_vendor_huawei_sydney"
    info "  2. Add to .github/workflows/build-halium.yml local manifest:"
    info "       <project path=\"vendor/huawei/sydney\""
    info "                name=\"jglasovic/android_vendor_huawei_sydney\""
    info "                remote=\"gh\" revision=\"main\" />"
    info "  3. In device-tree/sydney/BoardConfig.mk ensure:"
    info "       include vendor/huawei/sydney/BoardConfigVendor.mk"
}

main "$@"
