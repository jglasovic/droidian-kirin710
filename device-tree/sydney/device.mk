#
# Copyright (C) 2024 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

DEVICE_PATH := device/huawei/sydney

# Inherit from kirin710-9-common
$(call inherit-product, device/huawei/kirin710-9-common/common.mk)

# Call the proprietary setup (vendor blobs from kirin710-9-common + sydney ODM)
$(call inherit-product, vendor/huawei/kirin710-9-common/kirin710-9-common-vendor.mk)
$(call inherit-product, vendor/huawei/sydney/sydney-vendor.mk)

# Boot animation
TARGET_SCREEN_HEIGHT := 2340
TARGET_SCREEN_WIDTH  := 1080

# Overlays
PRODUCT_PACKAGES += \
    FrameworksResOverlaySydney \
    WifiResOverlaySydney

# Device-specific init rc
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/configs/init/sydney.rc:$(TARGET_COPY_OUT_ODM)/etc/init/sydney.rc

# Shipping API level (Android 9 / Pie launch)
PRODUCT_SHIPPING_API_LEVEL := 28

# Soong namespaces
PRODUCT_SOONG_NAMESPACES += \
    $(LOCAL_PATH)
