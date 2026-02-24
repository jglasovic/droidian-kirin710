#!/usr/bin/env bash
# build-kernel.sh — download pre-built kernel Image.gz from the kernel fork
#
# The kernel is built by CI in the fork repo and published as a GitHub Release.
# This script downloads the latest Image.gz for the selected branch.
#
# Usage:
#   bash build-kernel.sh
#
# Optional env vars:
#   KERNEL_BRANCH=...  — kernel fork branch (default: headless-kirin710)
#                        Available branches:
#                          headless-kirin710  — minimal headless server config
#                          full-ui-kirin710   — full UI config (camera, audio, sensors)
set -euo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_REPO="jglasovic/android_kernel_huawei_kirin710"
KERNEL_BRANCH="${KERNEL_BRANCH:-headless-kirin710}"
RELEASE_TAG="${KERNEL_BRANCH}-latest"
KERNEL_IMG="kernel/arch/arm64/boot/Image.gz"

cd "$WORK_DIR"

# Skip download if Image.gz already exists (local override / testing)
if [ -f "$KERNEL_IMG" ]; then
  echo "[OK] Kernel already present: $(du -sh "$KERNEL_IMG" | cut -f1) — skipping download."
  echo "     Delete $KERNEL_IMG to force re-download."
  exit 0
fi

echo "[*] Downloading Image.gz from ${KERNEL_REPO} release '${RELEASE_TAG}'..."

DOWNLOAD_URL="https://github.com/${KERNEL_REPO}/releases/download/${RELEASE_TAG}/Image.gz"

mkdir -p "$(dirname "$KERNEL_IMG")"
if command -v curl >/dev/null 2>&1; then
  curl -fSL --retry 3 -o "$KERNEL_IMG" "$DOWNLOAD_URL"
elif command -v wget >/dev/null 2>&1; then
  wget -q --show-progress -O "$KERNEL_IMG" "$DOWNLOAD_URL"
else
  echo "[FAIL] Neither curl nor wget found. Install one and retry."
  exit 1
fi

echo "[OK] Downloaded kernel: $(du -sh "$KERNEL_IMG" | cut -f1)"
