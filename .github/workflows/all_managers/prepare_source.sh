#!/usr/bin/env bash
set -e

# 直接 clone 公开 vendor 仓库到 kernel_platform/vendor，
# 与 build 阶段才克隆的私有 common 保持平级。
# AnyKernel3 / common / setlocalversion 等仍由 build 阶段单独处理。

if [ "${ANDROID_RELEASE:-16}" = "15" ]; then
  VENDOR_BRANCH="oneplus/sm8550_v_15.0.0_oneplus11"
else
  VENDOR_BRANCH="oneplus/sm8550_b_16.0.0_oneplus_11"
fi
VENDOR_URL="https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8550"

mkdir -p kernel_workspace/kernel_platform
cd kernel_workspace/kernel_platform

if [ -d vendor/.git ]; then
  echo "vendor 已存在，跳过 clone"
else
  git clone --depth=1 -b "$VENDOR_BRANCH" "$VENDOR_URL" vendor
fi

echo "vendor 已就绪 ($VENDOR_BRANCH)"
