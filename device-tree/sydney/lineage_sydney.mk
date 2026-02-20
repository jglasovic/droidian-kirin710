#
# Copyright (C) 2024 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Inherit from those products. Most specific first.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/non_ab_device.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/languages_full.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/product_launched_with_p.mk)

# Inherit from sydney device
$(call inherit-product, device/huawei/sydney/device.mk)

# Inherit some common LineageOS stuff.
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

# Device identifier. This must come after all inclusions.
PRODUCT_DEVICE   := sydney
PRODUCT_NAME     := lineage_sydney
PRODUCT_BRAND    := HWSNE-H
PRODUCT_MODEL    := SNE-LX1
PRODUCT_MANUFACTURER := HUAWEI

# Match stock value: ro.product.board=SNE-L21
TARGET_BOOTLOADER_BOARD_NAME := SNE-L21

PRODUCT_GMS_CLIENTID_BASE := android-huawei

PRODUCT_BUILD_PROP_OVERRIDES += \
    PRODUCT_NAME=SNE \
    PRIVATE_BUILD_DESC="SNE-LX1-user 9 HUAWEISNE-LX1 262-OVS-LGRP2 release-keys"

BUILD_FINGERPRINT := HUAWEI/SNE-LX1/HWSNE-H:9/HUAWEISNE-LX1/262C10:user/release-keys
