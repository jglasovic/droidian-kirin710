#
# Copyright (C) 2024 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

DEVICE_PATH := device/huawei/sydney

# Inherit from kirin710-common
include device/huawei/kirin710-9-common/BoardConfigCommon.mk

# Inherit the proprietary files
include vendor/huawei/kirin710-9-common/BoardConfigVendor.mk
include vendor/huawei/sydney/BoardConfigVendor.mk

# Display
# Actual density from device: ro.sf.lcd_density=480 (409 DPI physical)
TARGET_SCREEN_DENSITY := 480

# Properties
TARGET_VENDOR_PROP += $(DEVICE_PATH)/vendor.prop

# ODM SKUs (SNE-L01=mono SIM, SNE-L21=dual SIM - both with NFC)
ODM_MANIFEST_SKUS += SNE-L01 SNE-L21
ODM_MANIFEST_SNE-L01_FILES := $(DEVICE_PATH)/manifest_monosimnfc.xml
ODM_MANIFEST_SNE-L21_FILES := $(DEVICE_PATH)/manifest_dualsimnfc.xml

# Partitions — measured from actual device /proc/partitions (* 1024 bytes)
# mmcblk0p43  kernel (boot)      24576  blocks
# mmcblk0p45  recovery_ramdisk   32768  blocks
# mmcblk0p46  recovery_vendor    16384  blocks
# mmcblk0p61  vendor             778240 blocks
# mmcblk0p62  product            1024000 blocks
# mmcblk0p64  odm                180224 blocks
# mmcblk0p65  cache              106496 blocks
# mmcblk0p66  system             3743744 blocks
# mmcblk0p70  userdata           52994048 blocks
BOARD_BOOTIMAGE_PARTITION_SIZE        := 25165824     # 24576 * 1024
BOARD_RECOVERYIMAGE_PARTITION_SIZE    := 33554432     # 32768 * 1024
BOARD_RECVENDORIMAGE_PARTITION_SIZE   := 16777216     # 16384 * 1024
BOARD_VENDORIMAGE_PARTITION_SIZE      := 796917760    # 778240 * 1024
BOARD_PRODUCTIMAGE_PARTITION_SIZE     := 1048576000   # 1024000 * 1024
BOARD_ODMIMAGE_PARTITION_SIZE         := 184549376    # 180224 * 1024
BOARD_CACHEIMAGE_PARTITION_SIZE       := 109051904    # 106496 * 1024
BOARD_SYSTEMIMAGE_PARTITION_SIZE      := 3833593856   # 3743744 * 1024
BOARD_USERDATAIMAGE_PARTITION_SIZE    := 54265905152  # 52994048 * 1024

# Halium: boot partition on this device is named 'kernel', not 'boot'
# The fstab.kirin710 already handles this with /dev/block/by-name/kernel
