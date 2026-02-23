#!/usr/bin/env bash
# build-kernel.sh — build Halium kernel for Kirin 710
# Run on any ARM64 Ubuntu machine (Colima, GitHub Actions, bare metal):
#   bash build-kernel.sh
#
# Optional env vars:
#   SKIP_DEPS=1    — skip apt dependency installation
#   KERNEL_DIR=... — use existing kernel source directory
set -euo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_REPO="https://github.com/Huawei-Dev/android_kernel_huawei_kirin710"
KERNEL_BRANCH="android@13"

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

# ── Apply defconfig ───────────────────────────────────────────────────────────
echo "[*] Applying defconfig..."
cp kernel-configs/arch/arm64/configs/kirin710_defconfig \
   kernel/arch/arm64/configs/kirin710_defconfig

# ── Patch kernel source ───────────────────────────────────────────────────────
echo "[*] Patching kernel source..."

# linux/sched/debug.h stub
mkdir -p kernel/include/linux/sched
printf '#ifndef _LINUX_SCHED_DEBUG_H\n#define _LINUX_SCHED_DEBUG_H\n#include <linux/sched.h>\n#endif\n' \
  > kernel/include/linux/sched/debug.h

# Kirin 710 SoC platform headers (soc_sctrl_interface.h, global_ddr_map.h etc.)
PLATFORM=drivers/hisi/ap/platform/kirin710

# lcdkit hisi/: own dir + SoC platform headers
printf '\nccflags-y += -Idrivers/devkit/lcdkit/lcdkit1.0/core/common/hisi\n' \
  >> kernel/drivers/devkit/lcdkit/lcdkit1.0/core/common/hisi/Makefile
printf '\nccflags-y += -I%s\n' "$PLATFORM" \
  >> kernel/drivers/devkit/lcdkit/lcdkit1.0/core/common/hisi/Makefile

# tpkit core and 3_0
printf '\nccflags-y += -Idrivers/devkit/tpkit\n' \
  >> kernel/drivers/devkit/tpkit/Makefile
printf '\nccflags-y += -Idrivers/devkit/tpkit/3_0\n' \
  >> kernel/drivers/devkit/tpkit/3_0/Makefile

# tpkit/panel: each subdir needs tpkit root + itself
find kernel/drivers/devkit/tpkit/panel -name Makefile | while read mf; do
  reldir="${mf#kernel/}"; reldir="${reldir%/Makefile}"
  printf '\nccflags-y += -Idrivers/devkit/tpkit\n' >> "$mf"
  printf '\nccflags-y += -I%s\n' "$reldir" >> "$mf"
done

# hisi/ddrc: self + SoC platform headers + libhwsecurec
printf '\nccflags-y += -Idrivers/hisi/ddrc\n' \
  >> kernel/drivers/hisi/ddrc/Makefile
printf '\nccflags-y += -I%s\n' "$PLATFORM" \
  >> kernel/drivers/hisi/ddrc/Makefile
printf '\nccflags-y += -Idrivers/hisi/tzdriver/libhwsecurec\n' \
  >> kernel/drivers/hisi/ddrc/Makefile

# hisi/hi64xx_dsp: self
printf '\nccflags-y += -Idrivers/hisi/hi64xx_dsp\n' \
  >> kernel/drivers/hisi/hi64xx_dsp/Makefile

# hisi/hifi_dsp: self
printf '\nccflags-y += -Idrivers/hisi/hifi_dsp\n' \
  >> kernel/drivers/hisi/hifi_dsp/Makefile

# hisi/drmdriver, perf_ctrl, efuse: SoC platform headers
for mf in \
  kernel/drivers/hisi/drmdriver/Makefile \
  kernel/drivers/hisi/perf_ctrl/Makefile \
  kernel/drivers/hisi/efuse/Makefile; do
  printf '\nccflags-y += -I%s\n' "$PLATFORM" >> "$mf"
done

# charger_ap: charging_core.h is angle-bracket included but lives in same dir
printf '\nccflags-y += -Idrivers/huawei_platform/power/charger/charger_ap\n' \
  >> kernel/drivers/huawei_platform/power/charger/charger_ap/Makefile

# charger_ap/bq2560x: bq2560x_charger.h angle-bracket included, lives in same dir
printf '\nccflags-y += -Idrivers/huawei_platform/power/charger/charger_ap/bq2560x\n' \
  >> kernel/drivers/huawei_platform/power/charger/charger_ap/bq2560x/Makefile

# charger_ap/rt9466 and rt9471: use <../charging_core.h> (angle-bracket with ..)
printf '\nccflags-y += -Idrivers/huawei_platform/power/charger/charger_ap/rt9466\n' \
  >> kernel/drivers/huawei_platform/power/charger/charger_ap/rt9466/Makefile
printf '\nccflags-y += -Idrivers/huawei_platform/power/charger/charger_ap/rt9471\n' \
  >> kernel/drivers/huawei_platform/power/charger/charger_ap/rt9471/Makefile

# memory_dump: kernel_dump.h angle-bracket included, lives in same dir
printf '\nccflags-y += -Idrivers/hisi/memory_dump\n' \
  >> kernel/drivers/hisi/memory_dump/Makefile

# hicam_buf: hicam_buf_priv.h angle-bracket included, lives in same dir
printf '\nccflags-y += -Idrivers/media/huawei/camera/hicam_buf\n' \
  >> kernel/drivers/media/huawei/camera/hicam_buf/Makefile

# mntn: rdr_inner.h lives in blackbox/ subdir
printf '\nccflags-y += -Idrivers/hisi/mntn/blackbox\n' \
  >> kernel/drivers/hisi/mntn/Makefile

# touthscreen/panel/*: all use <../../huawei_touchscreen_chips.h> (angle + ..)
for panel_dir in atmel st synaptics; do
  printf '\nccflags-y += -Idrivers/huawei_platform/touthscreen/panel/%s\n' "$panel_dir" \
    >> "kernel/drivers/huawei_platform/touthscreen/panel/${panel_dir}/Makefile"
done
# fts_debug_lib is one level deeper, uses <../../../huawei_touchscreen_chips.h>
printf '\nccflags-y += -Idrivers/huawei_platform/touthscreen/panel/st/fts_debug_lib\n' \
  >> kernel/drivers/huawei_platform/touthscreen/panel/st/fts_debug_lib/Makefile

# modem/drv/nvim: nv_partition_img.h lives in same dir
printf '\nccflags-y += -Idrivers/hisi/modem/drv/nvim\n' \
  >> kernel/drivers/hisi/modem/drv/nvim/Makefile

# camera/hisp: trace_hisp.h uses TRACE_INCLUDE_PATH=. so needs -I$(src)
printf '\nccflags-y += -I$(src)\n' \
  >> kernel/drivers/media/huawei/camera/hisp/Makefile

# slimbus: slimbus_debug.h lives in slimbus/ root, used by vendor/candance/src/csmi.c
printf '\nccflags-y += -Idrivers/hisi/slimbus\n' \
  >> kernel/drivers/hisi/slimbus/Makefile

# power/hisi/coul and soh: local headers angle-bracket included
printf '\nccflags-y += -Idrivers/power/hisi/coul\n' \
  >> kernel/drivers/power/hisi/coul/Makefile
printf '\nccflags-y += -Idrivers/power/hisi/soh\n' \
  >> kernel/drivers/power/hisi/soh/Makefile
printf '\nccflags-y += -Idrivers/power/hisi/soh/hi6531\n' \
  >> kernel/drivers/power/hisi/soh/hi6531/Makefile

# hisi/pm: SoC platform headers
printf '\nccflags-y += -Idrivers/hisi/ap/platform/kirin710\n' \
  >> kernel/drivers/hisi/pm/Makefile

# hisi/hi64xx and slimbus: need blackbox/platform_hifi for audio rdr headers
printf '\nEXTRA_CFLAGS += -Idrivers/hisi/mntn/blackbox/platform_hifi\n' \
  >> kernel/drivers/hisi/hi64xx/Makefile
printf '\nccflags-y += -Idrivers/hisi/mntn/blackbox/platform_hifi\n' \
  >> kernel/drivers/hisi/slimbus/Makefile

# hisi/hw_vote: hisi_hw_vote.h lives here
printf '\nccflags-y += -Idrivers/hisi/hw_vote\n' \
  >> kernel/drivers/hisi/hw_vote/Makefile

# hisi/noc: hisi_noc.h / hisi_noc_info.h live here
printf '\nccflags-y += -Idrivers/hisi/noc\n' \
  >> kernel/drivers/hisi/noc/Makefile

# hisi/mntn/blackbox: SoC platform headers
printf '\nccflags-y += -Idrivers/hisi/ap/platform/kirin710\n' \
  >> kernel/drivers/hisi/mntn/blackbox/Makefile

# devfreq/hisi: governor.h lives in parent devfreq/
printf '\nccflags-y += -Idrivers/devfreq\n' \
  >> kernel/drivers/devfreq/hisi/Makefile

# clk/hisi: SoC platform headers
printf '\nccflags-y += -Idrivers/hisi/ap/platform/kirin710\n' \
  >> kernel/drivers/clk/hisi/Makefile

# ion/hisi: ion_priv.h and kirin710 platform headers
printf '\nccflags-y += -Idrivers/staging/android/ion\n' \
  >> kernel/drivers/staging/android/ion/hisi/Makefile
printf '\nccflags-y += -Idrivers/hisi/ap/platform/kirin710\n' \
  >> kernel/drivers/staging/android/ion/hisi/Makefile

# usb/dwc3/hisi: pmic_interface.h
printf '\nccflags-y += -Idrivers/hisi/ap/platform/kirin710\n' \
  >> kernel/drivers/usb/dwc3/hisi/Makefile

# video/fbdev/hisi/dss: existing EXTRA_CFLAGS has wrong path (missing fbdev), add correct one
printf '\nEXTRA_CFLAGS += -Idrivers/video/fbdev/hisi/dss -Idrivers/video/fbdev/hisi\n' \
  >> kernel/drivers/video/fbdev/hisi/dss/Makefile

# usb/gadget/function: u_ether.h lives here; f_rndis.c #includes function-hisi/f_rndis_hisi.c
printf '\nccflags-y += -Idrivers/usb/gadget/function\n' \
  >> kernel/drivers/usb/gadget/function/Makefile

# ion: ion_priv.h lives in ion/ root; ion_system_heap.c compiled by parent ion/Makefile
printf '\nccflags-y += -Idrivers/staging/android/ion\n' \
  >> kernel/drivers/staging/android/ion/Makefile

# dsm_audio: dsm_audio.h lives in same dir
printf '\nccflags-y += -Idrivers/devkit/audiokit/dsm_audio\n' \
  >> kernel/drivers/devkit/audiokit/dsm_audio/Makefile

# schargerV200/V300: header angle-bracket included, lives in same dir
printf '\nccflags-y += -Idrivers/power/hisi/charger/schargerV200\n' \
  >> kernel/drivers/power/hisi/charger/schargerV200/Makefile
printf '\nccflags-y += -Idrivers/power/hisi/charger/schargerV300\n' \
  >> kernel/drivers/power/hisi/charger/schargerV300/Makefile

# hisi/ivp: ivp_platform.h (in ivpv120/) includes ivp.h (in ivp/) via angle brackets
printf '\nccflags-y += -Idrivers/hisi/ivp\n' \
  >> kernel/drivers/hisi/ivp/Makefile

# hifi_mailbox/mailbox: mdrv_ipc_enum.h lives in mailbox/ but ipcm/bsp_drv_ipc.h includes it
printf '\nEXTRA_CFLAGS += -I$(srctree)/drivers/hisi/hifi_mailbox/mailbox\n' \
  >> kernel/drivers/hisi/hifi_mailbox/mailbox/Makefile

# inputhub/kirin710: shmem.h includes protocol.h which lives here
printf '\nccflags-y += -Idrivers/huawei_platform/inputhub/kirin710\n' \
  >> kernel/drivers/huawei_platform/inputhub/kirin710/Makefile

# selinux/hooks.c: fix #include "audit.h" → explicit path so GCC finds it
sed -i 's|#include "audit.h"|#include "include/audit.h"|' \
  kernel/security/selinux/hooks.c

# rdr_hisi_platform.h stub: fix missing semicolon in #else stub body
# (do NOT add static inline to the #if CONFIG_HISI_BB forward declaration on line 80)
sed -i \
  -e 's/{return -1}/{return -1;}/' \
  -e 's/{return -1;};/{return -1;}/' \
  kernel/include/linux/hisi/rdr_hisi_platform.h

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
