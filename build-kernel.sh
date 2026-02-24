#!/usr/bin/env bash
# build-kernel.sh — build Halium kernel for Kirin 710
# Run on any ARM64 Ubuntu machine (Colima, GitHub Actions, bare metal):
#   bash build-kernel.sh
#
# Optional env vars:
#   SKIP_DEPS=1        — skip apt dependency installation
#   KERNEL_DIR=...     — use existing kernel source directory
#   KERNEL_BRANCH=...  — kernel fork branch (default: headless-kirin710)
#                        Available branches:
#                          headless-kirin710  — minimal headless server config
#                          full-ui-kirin710   — full UI config (camera, audio, sensors)
set -euo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_REPO="https://github.com/jglasovic/android_kernel_huawei_kirin710"
KERNEL_BRANCH="${KERNEL_BRANCH:-headless-kirin710}"

cd "$WORK_DIR"

# Use sudo if not root
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

if [ "${SKIP_DEPS:-}" != "1" ]; then
  echo "[*] Installing dependencies..."
  $SUDO apt-get update -qq
  $SUDO apt-get install -y --no-install-recommends \
    git bc bison flex libssl-dev make libc6-dev libncurses5-dev \
    gcc binutils \
    python3 ccache zip unzip curl wget lzop \
    cpio 2>&1 | tail -5
fi

# ── Clone kernel if not already present ──────────────────────────────────────
if [ ! -d kernel/.git ]; then
  echo "[*] Cloning kernel (this takes a few minutes)..."
  git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" kernel
else
  echo "[*] Kernel already cloned, skipping."
fi

# ── Build kernel ──────────────────────────────────────────────────────────────
echo "[*] Building kernel..."
cd kernel
KDIR=$(pwd)

export ARCH=arm64

make ARCH=arm64 kirin710_defconfig

make ARCH=arm64 \
  "BALONG_INC=-I${KDIR}/kernel" \
  KCFLAGS="-Wno-error=maybe-uninitialized -Wno-error=address -Wno-error=sizeof-pointer-memaccess -Wno-error=misleading-indentation" \
  -j$(nproc) Image.gz 2>&1 | tee "${WORK_DIR}/kernel_build.log"

echo ""
echo "[OK] Kernel built: $(du -sh arch/arm64/boot/Image.gz)"
cd "$WORK_DIR"

# ── Save timestamped copy ─────────────────────────────────────────────────
BUILD_TAG="$(date +%Y%m%d-%H%M%S)"
mkdir -p out
cp kernel/arch/arm64/boot/Image.gz "out/Image-${BUILD_TAG}.gz"
echo "[OK] Saved: out/Image-${BUILD_TAG}.gz"
